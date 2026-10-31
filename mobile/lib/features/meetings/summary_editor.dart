import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../api/api_client.dart';
import '../../models/api_models.dart';

class SummaryEditor extends ChangeNotifier {
  SummaryEditor(
    this.api,
    this.summary, {
    this.debounce = const Duration(milliseconds: 800),
  }) : title = summary.title,
       content = summary.content,
       _savedTitle = summary.title,
       _savedContent = summary.content;
  final ApiClient api;
  final Duration debounce;
  MeetingSummary summary;
  String title;
  String content;
  String _savedTitle;
  String _savedContent;
  String? error;
  String? _contentError;
  bool saving = false;
  bool _disposed = false;
  bool _autosavePaused = false;
  Timer? _timer;
  Future<bool>? _inFlight;
  ({String title, String content, String? version})? _uncertainSave;
  bool get dirty =>
      _uncertainSave != null ||
      title.trim() != _savedTitle ||
      content != _savedContent;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void edit({String? title, String? content}) {
    if (title != null) this.title = title;
    if (content != null) {
      this.content = content;
      if (_contentError != null) error = null;
      _contentError = null;
    }
    _timer?.cancel();
    if (_contentError == null && !_autosavePaused) {
      _timer = Timer(debounce, () => unawaited(flush(automatic: true)));
    }
    _notify();
  }

  void blockContentSave(String message) {
    _timer?.cancel();
    _contentError = message;
    error = message;
    _notify();
  }

  Future<bool> flush({bool automatic = false}) async {
    _timer?.cancel();
    while (!_disposed) {
      if (automatic && _autosavePaused) return !hasUnsavedChanges;
      if (_contentError != null) {
        error = _contentError;
        _notify();
        return false;
      }
      final active = _inFlight;
      if (active != null) {
        if (!await active) return false;
        // A different waiter may own the next request. Always recheck.
        if (identical(_inFlight, active)) _inFlight = null;
        continue;
      }
      if (!dirty) {
        error = null;
        _notify();
        return true;
      }
      if (title.trim().isEmpty || title.trim().runes.length > 200) {
        error = 'Название должно содержать от 1 до 200 символов.';
        _notify();
        return false;
      }
      final request = _save(title.trim(), content);
      _inFlight = request;
      final succeeded = await request;
      if (identical(_inFlight, request)) _inFlight = null;
      if (!succeeded) return false;
    }
    return false;
  }

  bool _matches(
    MeetingSummary current,
    ({String title, String content, String? version}) intent,
  ) => current.title == intent.title && current.content == intent.content;

  void _acknowledge(
    MeetingSummary current,
    ({String title, String content, String? version}) intent,
  ) {
    summary = current;
    _savedTitle = intent.title;
    _savedContent = intent.content;
    _uncertainSave = null;
    // Never replace title/content typed while the request or GET was in flight.
  }

  Future<bool> _save(String capturedTitle, String capturedContent) async {
    saving = true;
    error = null;
    _notify();
    final intent =
        _uncertainSave ??
        (
          title: capturedTitle,
          content: capturedContent,
          version: summary.version,
        );
    var attemptedWrite = false;
    try {
      if (_uncertainSave != null) {
        final current = await api.summary(summary.id);
        if (_matches(current, intent)) {
          _acknowledge(current, intent);
          return true;
        }
        if (current.version != intent.version) {
          error = 'Встреча изменена в другом редакторе. Ваш текст остаётся здесь; сохранение без проверки версии не выполняется.';
          return false;
        }
        // The original version is still current: retry the old captured intent,
        // never newer typed text, under the same CAS. flush() saves newer edits
        // only after this operation has been acknowledged.
      }
      attemptedWrite = true;
      final current = await api.saveSummary(
        summary.id,
        title: intent.title,
        content: intent.content,
        expectedVersion: intent.version,
      );
      _acknowledge(current, intent);
      return true;
    } catch (e) {
      if (attemptedWrite &&
          e is ApiException &&
          (e.retryable ||
              e.code == 'invalid_response' ||
              e.code == 'summary_version_conflict')) {
        _uncertainSave = intent;
        try {
          final current = await api.summary(summary.id);
          if (_matches(current, intent)) {
            _acknowledge(current, intent);
            return true;
          }
        } catch (_) {
          // Preserve the captured intent and the original error for a retry.
        }
      }
      error = e.toString();
      return false;
    } finally {
      saving = false;
      _notify();
    }
  }

  // Stop the debounce before deciding whether to leave. An already accepted
  // PATCH must finish before choosing which saved snapshot to restore.
  Future<void> pauseAutosave() async {
    _autosavePaused = true;
    _timer?.cancel();
    final pending = _inFlight;
    if (pending != null) await pending;
    _timer?.cancel();
  }

  void resumeAutosave() {
    _autosavePaused = false;
    if (dirty && _contentError == null && error == null) {
      _timer?.cancel();
      _timer = Timer(debounce, () => unawaited(flush(automatic: true)));
    }
  }

  bool get hasUnsavedChanges => dirty || _contentError != null;

  void discardUnsaved() {
    _timer?.cancel();
    _uncertainSave = null;
    title = _savedTitle;
    content = _savedContent;
    error = null;
    _contentError = null;
    _notify();
  }

  void setFolders(MeetingSummary updated) {
    summary = updated;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

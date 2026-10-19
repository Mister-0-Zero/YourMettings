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
  bool get dirty => title.trim() != _savedTitle || content != _savedContent;
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

  Future<bool> _save(String capturedTitle, String capturedContent) async {
    saving = true;
    error = null;
    _notify();
    try {
      summary = await api.saveSummary(
        summary.id,
        title: capturedTitle,
        content: capturedContent,
      );
      _savedTitle = capturedTitle;
      _savedContent = capturedContent;
      // Never replace text typed while this request was in flight.
      return true;
    } catch (e) {
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

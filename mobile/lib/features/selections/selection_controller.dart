import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../api/api_client.dart';
import '../../models/api_models.dart';
import '../../models/processing_options.dart';
import '../../models/summary_template.dart';
import '../../services/operation_store.dart';

class SelectionController extends ChangeNotifier {
  SelectionController({
    required this.api,
    required this.store,
    required this.slot,
    required this.source,
    required this.initialOptions,
    this.original,
  });
  final ApiClient api;
  final OperationStore store;
  final String slot;
  final Future<Json> Function() source;
  final ProcessingOptions initialOptions;
  final MeetingSummary? original;
  Json state = {};
  Json? session;
  final Map<String, Json> candidates = {};
  MeetingSummary? accepted;
  String? error;
  bool busy = false, disposed = false, paused = false, terminal = false;
  Timer? _timer;
  bool _retryNetwork = false;
  bool get frozen =>
      state['accept_id'] != null ||
      state['accepted_summary_id'] != null ||
      state['cancel_pending'] == true;
  bool get hasPending => state['candidate_pending'] != null;
  List<String> get ids =>
      (state['candidate_ids'] as List? ?? []).cast<String>();
  String? get activeId => state['active_id'] as String?;
  Json? get active => candidates[activeId];
  bool get showingOriginal => activeId == null && original != null;
  String? get content =>
      showingOriginal ? original!.content : active?['content'] as String?;
  List<SummaryHeading> get navigation => showingOriginal
      ? original!.navigation
      : [
          for (final j in active?['navigation'] as List? ?? [])
            SummaryHeading.fromJson(j as Json),
        ];
  bool get ready => showingOriginal || active?['status'] == 'ready';
  bool get generating => candidates.values.any(
    (c) => ['queued', 'generating'].contains(c['status']),
  );
  int get position => activeId == null ? -1 : ids.indexOf(activeId!);
  bool get canBack =>
      !busy && !frozen && (position > 0 || position == 0 && original != null);
  bool get canForward => !busy && !frozen && position < ids.length - 1;
  void _notify() {
    if (!disposed) notifyListeners();
  }

  Future<void> _save() async {
    await store.put(slot, state);
  }

  Future<void> initialize() => _run(() async {
    state = store[slot] ?? {};
    if (state.isEmpty) {
      final body = await source();
      state = {
        'key': newSectionId(),
        'source': body,
        'initial_options': initialOptions.toJson(),
        'candidate_ids': <String>[],
      };
      await _save();
    }
    await _ensureSession();
    if (state['cancel_pending'] == true) {
      await _cancel();
      return;
    }
    if (frozen) {
      await _accept();
      return;
    }
    await _refresh();
    if (terminal) return;
    if (hasPending) {
      await _sendCandidate();
    } else if (state['initial_requested'] != true && original == null) {
      await _prepareCandidate(state['initial_options'] as Json);
      await _sendCandidate();
    }
  });
  Future<void> _ensureSession() async {
    if (state['session_id'] != null) return;
    await _save();
    final result = await api.createSelection(
      state['source'] as Json,
      state['key'] as String,
    );
    state = {
      ...state,
      'session_id': result['id'],
      'transcript_id': result['transcript_id'],
      'summary_version': result['summary_version'],
      'expires_at': result['expires_at'],
    };
    // Acknowledged source remains in the draft until confirmed accept/cancel.
    await _save();
    session = result;
  }

  Future<void> _refresh() async {
    session = await api.selection(state['session_id'] as String);
    final status = session!['status'];
    terminal = ['expired', 'cancelled'].contains(status);
    if (terminal) {
      error = 'Срок выбора истёк или выбор отменён. Исходный текст сохранён. Вернитесь к нему и начните выбор заново.';
      return;
    }
    if (status == 'accepted') {
      final id = session!['accepted_candidate_id'] as String?;
      if (id == null) {
        throw const FormatException('Сервер не вернул выбранный вариант.');
      }
      state = {...state, 'accept_id': id};
      await _save();
      await _accept();
      return;
    }
    final ordered = [...ids];
    for (final raw in session!['candidates'] as List? ?? []) {
      final c = raw as Json;
      final id = c['id'] as String;
      candidates[id] = c;
      if (!ordered.contains(id)) ordered.add(id);
    }
    state = {...state, 'candidate_ids': ordered};
    await _save();
  }

  Future<void> _prepareCandidate(Json options) async {
    state = {
      ...state,
      'initial_requested': true,
      'candidate_pending': {'key': newSectionId(), 'options': options},
    };
    await _save();
  }

  Future<void> _sendCandidate() async {
    await _save();
    final pending = state['candidate_pending'] as Json;
    final c = await api.createCandidate(
      state['session_id'] as String,
      pending['options'] as Json,
      pending['key'] as String,
    );
    final id = c['id'] as String;
    candidates[id] = c;
    state = {
      ...state,
      'candidate_ids': [...ids, if (!ids.contains(id)) id],
      'active_id': id,
      'candidate_pending': null,
    };
    await _save();
  }

  Future<void> generate(ProcessingOptions options) => _run(() async {
    if (frozen || terminal) return;
    if (!hasPending) await _prepareCandidate(options.toJson());
    await _sendCandidate();
  });
  Future<void> refresh() {
    if (state.isEmpty) return initialize();
    return _run(() async {
      await _ensureSession();
      if (state['cancel_pending'] == true) {
        await _cancel();
        return;
      }
      if (frozen) {
        await _accept();
        return;
      }
      if (hasPending) await _sendCandidate();
      await _refresh();
    });
  }

  Future<void> move(int delta) => _run(() async {
    if (frozen) return;
    final next = position + delta;
    if (next < (original == null ? 0 : -1) || next >= ids.length) return;
    state = {...state, 'active_id': next == -1 ? null : ids[next]};
    await _save();
  });
  Future<void> accept() => _run(() async {
    if (state['cancel_pending'] == true) {
      await _cancel();
      return;
    }
    if (!ready && !frozen) return;
    if (showingOriginal && !frozen) {
      state = {...state, 'cancel_pending': true, 'keep_original': true};
      await _save();
      await api.cancelSelection(state['session_id'] as String);
      accepted = await api.summary(original!.id);
      return;
    }
    // Freeze this exact choice BEFORE POST, including after process death.
    if (!frozen) {
      state = {...state, 'accept_id': activeId};
      await _save();
    }
    await _accept();
  });
  Future<void> _accept() async {
    await _save();
    final receipt = await api.acceptSelection(
      state['session_id'] as String,
      state['accept_id'] as String,
      state['summary_version'] as String?,
    );
    state = {...state, 'accepted_summary_id': receipt.id};
    await _save();
    // Receipt is immutable; a later manual edit must be read with GET.
    accepted = await api.summary(receipt.id);
  }

  Future<void> _cancel() async {
    if (!terminal && state['key'] != null) {
      await _ensureSession();
      await _save();
      await api.cancelSelection(state['session_id'] as String);
    }
    if (state['keep_original'] == true && original != null) {
      accepted = await api.summary(original!.id);
    } else {
      await store.remove(slot);
      terminal = true;
    }
  }

  Future<bool> cancel() async {
    if (busy || frozen && state['cancel_pending'] != true) return false;
    await _run(() async {
      state = {...state, 'cancel_pending': true};
      await _save();
      await _cancel();
    });
    return store[slot] == null;
  }

  Future<void> complete() async {
    await store.remove(slot);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy || disposed) return;
    _timer?.cancel();
    busy = true;
    _retryNetwork = false;
    error = null;
    _notify();
    try {
      await action();
    } catch (e) {
      error = e.toString();
      _retryNetwork =
          e is ApiException && (e.isNetwork || (e.statusCode ?? 0) >= 500);
      if (e is ApiException &&
          ['summary_version_conflict', 'source_conflict'].contains(e.code)) {
        error = 'Встреча изменена в другом редакторе. Вернитесь к актуальному документу и откройте новый выбор шаблона.';
        // A definite conflict did not accept anything. Never change base version.
        state = {...state, 'accept_id': null};
        await _save();
      } else if (e is ApiException && e.statusCode == 410) {
        terminal = true;
        state = {...state, 'accept_id': null};
        await _save();
        error = 'Срок выбора истёк. Исходный текст сохранён; отмените этот выбор и начните заново.';
      } else if (e is ApiException &&
          [404, 409, 410, 413, 422, 429].contains(e.statusCode) &&
          hasPending) {
        state = {...state, 'candidate_pending': null};
        await _save();
      }
    } finally {
      busy = false;
      _notify();
      if (!disposed &&
          !paused &&
          accepted == null &&
          !terminal &&
          (generating ||
              hasPending ||
              frozen ||
              _retryNetwork &&
                  state['key'] != null &&
                  state['session_id'] == null)) {
        _timer = Timer(const Duration(seconds: 4), refresh);
      }
    }
  }

  void pause() {
    paused = true;
    _timer?.cancel();
  }

  void resume() {
    paused = false;
    if (accepted == null && !terminal) unawaited(refresh());
  }

  @override
  void dispose() {
    disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

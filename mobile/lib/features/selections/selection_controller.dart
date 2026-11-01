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
    this.autoPoll = true,
    this.onFailure,
  });
  final ApiClient api;
  final OperationStore store;
  final bool autoPoll;
  final FutureOr<void> Function(Object)? onFailure;
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
  Future<void>? _active;
  Future<void> drain() async {
    await _active;
  }

  bool _retryNetwork = false;
  bool _baselineConflict = false;
  bool _pollAllowed = true;
  int _failures = 0;
  Duration _pollDelay = const Duration(seconds: 2);
  bool get frozen =>
      state['accept_id'] != null ||
      state['accepted_summary_id'] != null ||
      state['cancel_pending'] == true;
  bool get hasPending => state['candidate_pending'] != null;
  List<String> get ids =>
      (state['candidate_ids'] as List? ?? []).cast<String>();
  String? get activeId => state['active_id'] as String?;
  Json? get active =>
      candidates[activeId] ??
      (state['receipt'] != null && activeId == state['accept_id']
          ? {
              'status': 'ready',
              'content': (state['receipt'] as Json)['content'],
              'template_snapshot':
                  (state['receipt'] as Json)['template_snapshot'],
              'generation_options':
                  (state['receipt'] as Json)['generation_options'],
            }
          : null);
  bool get showingOriginal => activeId == null && original != null;
  String get _draftKey => activeId ?? 'original';
  Json get activeEdit => ((state['edits'] as Json?)?[_draftKey] as Json?) ?? {};
  Json? get _originalBase => state['original_baseline'] as Json?;
  String get title =>
      activeEdit['title'] as String? ??
      (state['receipt'] as Json?)?['title'] as String? ??
      _originalBase?['title'] as String? ??
      original?.title ??
      (state['source'] as Json?)?['title'] as String? ??
      '';
  String? get content =>
      activeEdit['content'] as String? ??
      (showingOriginal
          ? ((_originalBase?['content'] as String?) ?? original!.content)
          : active?['content'] as String?);
  bool get hasLocalEdits => activeEdit.isNotEmpty;
  bool get canEdit =>
      ready && !busy && !terminal && accepted == null && !frozen;
  Future<void> editActive({
    required String title,
    required String content,
  }) async {
    if (!canEdit) {
      throw StateError('Вариант пока недоступен для редактирования.');
    }
    if (title.trim().isEmpty ||
        title.runes.length > 200 ||
        content.trim().isEmpty) {
      throw const FormatException(
        'Заполните название (до 200 символов) и содержание.',
      );
    }
    final baseTitle =
        _originalBase?['title'] as String? ??
        original?.title ??
        (state['source'] as Json?)?['title'] as String? ??
        '';
    final baseContent = showingOriginal
        ? ((_originalBase?['content'] as String?) ?? original!.content)
        : active!['content'] as String;
    final edits = {...?state['edits'] as Json?};
    final edit = <String, dynamic>{
      if (title != baseTitle) 'title': title,
      if (content != baseContent) 'content': content,
    };
    if (edit.isEmpty) {
      edits.remove(_draftKey);
    } else {
      edits[_draftKey] = edit;
    }
    final previous = state;
    state = {...state, 'edits': edits};
    try {
      await _save();
    } catch (_) {
      state = previous;
      rethrow;
    }
    _notify();
  }

  List<SummaryHeading> get navigation => activeEdit.containsKey('content')
      ? []
      : showingOriginal
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
        if (original != null)
          'original_baseline': {
            'id': original!.id,
            'title': original!.title,
            'content': original!.content,
            'version': original!.version,
          },
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
    _checkOriginalVersion();
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

  void _checkOriginalVersion() {
    // Frozen accept/cancel recovery must replay its original durable intent.
    if (frozen || original == null) return;
    final shownVersion = _originalBase?['version'] ?? original!.version;
    if (shownVersion == null || shownVersion != state['summary_version']) {
      terminal = true;
      _baselineConflict = true;
      throw const ApiException(
        'selection_baseline_conflict',
        'Встреча изменилась до открытия выбора шаблона. Отмените этот выбор и вернитесь к актуальному документу. Локальные правки сохранены; генерация и сохранение заблокированы.',
        statusCode: 409,
      );
    }
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
    await api.verifyCandidateTemplateVersion(options);
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
    _checkOriginalVersion();
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
      _checkOriginalVersion();
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
    if (terminal && !frozen) return;
    if (!ready && !frozen) return;
    _checkOriginalVersion();
    if (showingOriginal && !frozen) {
      state = {
        ...state,
        'cancel_pending': true,
        'keep_original': true,
        'accept_edit': {...activeEdit},
      };
      await _save();
      await _cancel();
      return;
    }
    // Freeze this exact choice BEFORE POST, including after process death.
    if (!frozen) {
      state = {
        ...state,
        'accept_id': activeId,
        'accept_edit': {...activeEdit},
        'accept_protocol': 'atomic-v1',
      };
      await _save();
    }
    await _accept();
  });
  Json _snapshot(MeetingSummary value) => {
    'id': value.id,
    'transcript_id': value.transcriptId,
    'title': value.title,
    'content': value.content,
    'folder_ids': value.folderIds,
    'created_at': value.createdAt.toIso8601String(),
    'updated_at': value.updatedAt.toIso8601String(),
    'version': value.version,
    'template_snapshot': value.templateSnapshot,
    'generation_options': value.generationOptions,
    'navigation': [
      for (final h in value.navigation)
        {
          'id': h.id,
          'title': h.title,
          'level': h.level,
          'heading_index': h.headingIndex,
          'line_index': h.lineIndex,
        },
    ],
  };

  Future<void> _accept() async {
    final legacy = state['accept_protocol'] != 'atomic-v1';
    await _save();
    if (state['receipt'] == null) {
      final edit = state['accept_edit'] as Json? ?? {};
      final receipt = await api.acceptSelection(
        state['session_id'] as String,
        state['accept_id'] as String,
        state['summary_version'] as String?,
        title: legacy ? null : edit['title'] as String?,
        content: legacy ? null : edit['content'] as String?,
      );
      state = {
        ...state,
        'accepted_summary_id': receipt.id,
        'receipt': _snapshot(receipt),
      };
      await _save();
    }
    final receipt = state['receipt'] as Json;
    if (legacy) {
      // Migration only: replay the exact old accept, then finish its owed edits
      // with CAS. New atomic accept never enters this path.
      accepted = await _applyEdits(receipt);
      return;
    }
    accepted = MeetingSummary.fromJson(receipt);
  }

  bool get editConflict => state['edit_conflict'] == true;
  Future<void> retryEditsOverCurrent() => _run(() async {
    // Atomic-v1 is immutable. Only an unfinished legacy PATCH or keeping the
    // original can ask for consent to replace current fields.
    if (!editConflict ||
        (state['accept_protocol'] == 'atomic-v1' &&
            state['keep_original'] != true)) {
      return;
    }
    final base = state['receipt'] as Json? ?? _originalBase!;
    final current = await api.summary(base['id'] as String);
    state = {
      ...state,
      'edit_conflict': false,
      // Never rewrite the immutable accept receipt or opening baseline.
      'edit_baseline': _snapshot(current),
    };
    await _save();
    if (state['keep_original'] == true) {
      await _cancel();
    } else {
      await _accept();
    }
  });

  Future<Never> _editConflict() async {
    state = {...state, 'edit_conflict': true};
    await _save();
    throw const ApiException(
      'local_edit_conflict',
      'Документ уже изменён. Ваши правки сохранены на устройстве. Повторное сохранение потребует подтверждения замены текущего текста.',
    );
  }

  Future<MeetingSummary> _applyEdits(Json originalBaseline) async {
    if (editConflict) await _editConflict();
    final baseline = state['edit_baseline'] as Json? ?? originalBaseline;
    final edit = state['accept_edit'] as Json? ?? {};
    final current = await api.summary(baseline['id'] as String);
    if (edit.isEmpty ||
        edit.entries.every(
          (e) =>
              e.value == (e.key == 'title' ? current.title : current.content),
        )) {
      return current;
    }
    // A lost PATCH reply is reconciled by reading first. Never blindly replay
    // local text over an already visible change by another editor.
    if (edit.keys.any(
      (key) =>
          baseline[key] != (key == 'title' ? current.title : current.content) &&
          !(state['edit_alternatives'] as List? ?? []).any(
            (old) =>
                (old as Json)[key] ==
                (key == 'title' ? current.title : current.content),
          ),
    )) {
      await _editConflict();
    }
    // Unrelated fields may have changed since the receipt. Protect the exact
    // document we just read, rather than repeatedly submitting its old version.
    final version = current.version;
    if (version == null || version.isEmpty) {
      throw const FormatException(
        'Сервер не вернул версию документа. Правки сохранены; обновите сервер и повторите.',
      );
    }
    try {
      return await api.patchSummary(
        current.id,
        title: edit['title'] as String?,
        content: edit['content'] as String?,
        expectedVersion: version,
      );
    } on ApiException catch (e) {
      if (['summary_version_conflict', 'source_conflict'].contains(e.code)) {
        await _editConflict();
      }
      rethrow;
    }
  }

  Future<void> _cancel() async {
    // A local baseline block does not mean that the server session is closed.
    if ((!terminal || _baselineConflict) && state['key'] != null) {
      await _ensureSession();
      await _save();
      await api.cancelSelection(state['session_id'] as String);
      _baselineConflict = false;
    }
    if (state['keep_original'] == true && original != null) {
      accepted = await _applyEdits(
        _originalBase ??
            {
              'id': original!.id,
              'title': original!.title,
              'content': original!.content,
              'version': original!.version,
            },
      );
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

  Future<void> _run(Future<void> Function() action) {
    if (busy || disposed) return Future.value();
    return _active = _doRun(action).whenComplete(() => _active = null);
  }

  Future<void> _doRun(Future<void> Function() action) async {
    if (busy || disposed) return;
    _timer?.cancel();
    busy = true;
    _retryNetwork = false;
    _pollAllowed = true;
    error = null;
    _notify();
    try {
      await action();
      _failures = 0;
      _pollDelay = const Duration(seconds: 2);
    } catch (e) {
      await onFailure?.call(e);
      error = e.toString();
      _retryNetwork = e is ApiException && e.retryable;
      _pollAllowed = _retryNetwork;
      _pollDelay = retryDelay(
        ++_failures,
        minimum: e is ApiException ? e.retryAfter : null,
      );
      if (e is ApiException && e.code == 'selection_baseline_conflict') {
        terminal =
            true; // Keep all edits/checkpoints until explicit cancellation.
      } else if (e is ApiException &&
          ['summary_version_conflict', 'source_conflict'].contains(e.code)) {
        error = 'Встреча изменена в другом редакторе. Вернитесь к актуальному документу и откройте новый выбор шаблона.';
        // A definite original PATCH conflict requires explicit consent and a new CAS.
        state = {
          ...state,
          'accept_id': null,
          if (state['keep_original'] == true) 'edit_conflict': true,
        };
        await _save();
      } else if (e is ApiException && e.statusCode == 410) {
        terminal = true;
        _baselineConflict = false;
        state = {...state, 'accept_id': null};
        await _save();
        error = 'Срок выбора истёк. Исходный текст сохранён; отмените этот выбор и начните заново.';
      } else if (e is ApiException &&
          [404, 409, 410, 413, 422].contains(e.statusCode) &&
          hasPending) {
        state = {...state, 'candidate_pending': null};
        await _save();
      }
    } finally {
      busy = false;
      _notify();
      if (autoPoll &&
          !disposed &&
          _pollAllowed &&
          !paused &&
          accepted == null &&
          (!terminal || _baselineConflict && state['cancel_pending'] == true) &&
          (generating ||
              hasPending ||
              frozen ||
              _retryNetwork &&
                  state['key'] != null &&
                  state['session_id'] == null)) {
        _timer = Timer(_pollDelay, refresh);
      }
    }
  }

  void pause() {
    paused = true;
    _timer?.cancel();
  }

  void resume() {
    paused = false;
    if (accepted == null &&
        (!terminal || _baselineConflict && state['cancel_pending'] == true)) {
      unawaited(refresh());
    }
  }

  @override
  void dispose() {
    disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

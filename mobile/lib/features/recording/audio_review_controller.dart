import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../api/api_client.dart';
import '../../models/api_models.dart';
import '../../models/processing_options.dart';
import '../../services/recovery_store.dart';
import '../../services/audio_draft_store.dart';
import '../new_meeting/meeting_controller.dart';
import 'audio_api.dart';
import 'recorder_coordinator.dart';

/// Separate draft/operation store: an audio review never overwrites pasted text.
class AudioReviewController extends MeetingController {
  AudioReviewController(
    super.api,
    super.store,
    this.recorder, {
    this.audioApiFactory,
    this.drafts,
    this.fixedSessionId,
  });
  final AudioApi Function()? audioApiFactory;
  final RecorderCoordinator recorder;
  final AudioDraftRepository? drafts;
  final String? fixedSessionId;
  String? _boundSessionId;
  Json? _session;
  bool _closed = false;
  void _signal() {
    if (!_closed) notifyListeners();
  }

  String get sessionId =>
      fixedSessionId ?? _boundSessionId ?? recorder.state['id'] as String;
  Json get session =>
      _session ??
      (fixedSessionId == null ? recorder.state['session'] as Json? ?? {} : {});
  bool get needsBoundaryReview =>
      (session['boundary_warnings'] as List? ?? []).isNotEmpty ||
      (fixedSessionId != null &&
          drafts?[fixedSessionId!]?.hasBoundaryWarnings == true);
  bool get deletionPending {
    final id =
        fixedSessionId ?? _boundSessionId ?? recorder.state['id'] as String?;
    return id != null && drafts?[id]?.deletePending == true;
  }

  bool get serverDeleted {
    final id =
        fixedSessionId ?? _boundSessionId ?? recorder.state['id'] as String?;
    return id != null && drafts?[id]?.serverDeleted == true;
  }

  bool boundariesReviewed = false;
  Future<void> openReview() async {
    _boundSessionId ??= fixedSessionId ?? recorder.state['id'] as String;
    if (deletionPending) {
      error = 'Удаление ещё не подтверждено. Повторите «Удалить встречу»; обработка Qwen заблокирована.';
      _signal();
      return;
    }
    try {
      _session = await withAudioApi((api) => api.json('GET', '/$sessionId'));
      if (session['status'] == 'completed') {
        await acceptAudio(
          ProcessingStatus.fromJson(session['processing'] as Json),
        );
        return;
      }
      if (draft.text.isEmpty) {
        final source = await api.transcript(session['transcript_id'] as String);
        final parameters = session['parameters'] as Json;
        await saveDraft(
          Draft(
            text: source.text,
            title: parameters['title'] as String,
            folderIds: (parameters['folder_ids'] as List).cast<String>(),
            options: ProcessingOptions.fromJson(parameters),
          ),
        );
      }
    } catch (_) {
      if (draft.text.isEmpty && !hasOperation) rethrow;
      error = 'Не удалось проверить состояние сервера. Локальный текст сохранён; подключитесь перед обработкой.';
      _signal();
    }
  }

  SavedAudioDraft _snapshot({required bool handoff, bool deleting = false}) {
    final previous = drafts?[sessionId];
    return SavedAudioDraft(
      sessionId: sessionId,
      transcriptId:
          previous?.transcriptId ?? session['transcript_id'] as String,
      creationKey: previous?.creationKey ?? recorder.state['key'] as String,
      recovery: recovery,
      updatedAt: DateTime.now().toUtc(),
      boundariesReviewed: boundariesReviewed,
      hasBoundaryWarnings: needsBoundaryReview,
      handoff: handoff,
      deletePending: deleting || previous?.deletePending == true,
      serverDeleted: previous?.serverDeleted == true,
    );
  }

  Future<void> _completeHandoff(SavedAudioDraft entry) async {
    final repository = drafts!;
    recorder.handoffPending = true;
    // A different active recording must never be touched by an old checkpoint.
    var clearedActive = false;
    if (recorder.state['id'] == entry.sessionId || !recorder.active) {
      if (recovery.operation != null &&
          recovery.operation!.id != entry.transcriptId) {
        throw StateError('Another accepted operation owns the legacy store');
      }
      await recorder.releaseReview(entry.sessionId);
      await store.save(RecoveryState());
      clearedActive = true;
    }
    if (entry.serverDeleted) {
      await repository.remove(entry.sessionId);
    } else {
      await repository.update(
        entry.sessionId,
        (value) => value.copy(handoff: false),
      );
    }
    if (clearedActive) {
      recovery = RecoveryState();
      status = null;
      result = null;
      _boundSessionId = null;
      _session = null;
      boundariesReviewed = false;
    }
    recorder.handoffPending = repository.hasHandoff;
  }

  /// Replays only durable checkpoints, never creates a session or starts Qwen.
  Future<void> recoverHandoffs() async {
    if (drafts == null || fixedSessionId != null) return;
    recorder.handoffPending = drafts!.hasHandoff;
    for (final entry in drafts!.items.where((e) => e.handoff)) {
      try {
        await _completeHandoff(entry);
        storageError = null;
      } catch (_) {
        storageError = 'Не удалось завершить сохранение черновика. Повторите в «Пространстве».';
      }
    }
    recorder.handoffPending = drafts!.hasHandoff;
    _signal();
  }

  Future<bool> defer() async {
    if (working || hasOperation || drafts == null) return false;
    working = true;
    storageError = null;
    error = null;
    _signal();
    try {
      final entry = _snapshot(handoff: fixedSessionId == null);
      await drafts!.put(entry);
      if (fixedSessionId == null) await _completeHandoff(entry);
      return true;
    } catch (_) {
      storageError = 'Не удалось сохранить черновик и освободить диктофон. Данные не удалены; повторите действие.';
      return false;
    } finally {
      working = false;
      _signal();
    }
  }

  Future<bool> deleteMeeting() async {
    if (working || hasOperation || drafts == null) return false;
    working = true;
    error = null;
    storageError = null;
    _signal();
    try {
      await cancelOpenSelection();
      var entry = drafts![sessionId];
      // Persist intent before HTTP. A lost reply must not permit confirm/POST.
      if (entry?.serverDeleted != true) {
        await drafts!.put(_snapshot(handoff: false, deleting: true));
        await withAudioApi((client) => client.deleteSession(sessionId));
        await drafts!.update(
          sessionId,
          (value) =>
              value.copy(serverDeleted: true, handoff: fixedSessionId == null),
        );
      }
      entry = drafts![sessionId]!;
      if (fixedSessionId == null) {
        await _completeHandoff(entry);
      } else {
        await drafts!.remove(sessionId);
      }
      return true;
    } catch (e) {
      // A definite rejection did not delete anything; ambiguous network/5xx
      // keeps the intent so confirm can never race an uncertain deletion.
      if (e is ApiException &&
          !e.isNetwork &&
          e.statusCode != null &&
          e.statusCode! >= 400 &&
          e.statusCode! < 500 &&
          drafts![sessionId] != null) {
        try {
          await drafts!.update(
            sessionId,
            (value) => value.copy(deletePending: false),
          );
        } catch (_) {}
      }
      error = e is ApiException
          ? '${e.message} Данные на устройстве сохранены. Удаление можно повторить.'
          : 'Не удалось подтвердить удаление и очистить локальное состояние. Повторите действие; данные сохранены.';
      return false;
    } finally {
      working = false;
      _signal();
    }
  }

  Future<T> withAudioApi<T>(Future<T> Function(AudioApi) action) async {
    final client = audioApiFactory?.call() ?? AudioApi(api.baseUri);
    try {
      return await action(client);
    } finally {
      client.close();
    }
  }

  Future<void> acceptAudio(ProcessingStatus accepted) async {
    if (recovery.operation?.id == accepted.transcriptId) {
      status = accepted;
      _signal();
      await check();
      return;
    }
    recovery = RecoveryState(
      operation: AcceptedOperation(
        accepted.transcriptId,
        draft.title,
        draft.folderIds,
        draft.options,
      ),
    );
    await store.save(recovery);
    status = accepted;
    _signal();
    await check();
  }

  @override
  String get selectionSlot =>
      'audio-selection:${fixedSessionId ?? _boundSessionId ?? recorder.state['id'] ?? 'unbound'}';
  @override
  Future<Json> selectionSource() async {
    if (deletionPending) {
      throw const ApiException(
        'deletion_pending',
        'Сначала завершите удаление этой встречи.',
      );
    }
    if (needsBoundaryReview && !boundariesReviewed) {
      throw const ApiException(
        'boundary_review_required',
        'Проверьте отмеченные стыки распознанного текста.',
      );
    }
    final id = sessionId;
    final sourceId = session['transcript_id'] as String;
    await api.updateTranscript(sourceId, draft.text);
    final fresh = await withAudioApi((client) => client.json('GET', '/$id'));
    final hash = sha256.convert(utf8.encode(draft.text)).toString();
    if (fresh['transcript_sha256'] != hash) {
      throw const ApiException(
        'review_outdated',
        'Текст на сервере изменился. Проверьте его перед повторным подтверждением.',
      );
    }
    return {
      'audio_session_id': id,
      'title': draft.title,
      'folder_ids': draft.folderIds,
      'confirm': true,
      'reviewed_text_sha256': hash,
      'boundaries_reviewed': boundariesReviewed,
    };
  }

  @override
  Future<void> selectionAccepted(MeetingSummary summary) async {
    // Keep a ready result until the existing durable audio cleanup completes.
    error = null;
    storageError = null;
    result = summary;
    status = ProcessingStatus(
      transcriptId: summary.transcriptId,
      phase: ProcessingPhase.ready,
      summaryId: summary.id,
    );
    await finish();
    if (result != null || storageError != null || error != null) {
      throw StateError('Audio cleanup must be retried after confirmed accept');
    }
  }

  @override
  Future<void> submit() async {
    if (working || hasOperation) return;
    if (deletionPending) {
      error = 'Сначала завершите подтверждённое удаление этой встречи.';
      _signal();
      return;
    }
    if (needsBoundaryReview && !boundariesReviewed) {
      error = 'Проверьте отмеченные стыки распознанного текста перед подтверждением.';
      _signal();
      return;
    }
    working = true;
    error = null;
    _signal();
    try {
      await store.save(recovery);
      final id = sessionId;
      final accepted = await withAudioApi((client) async {
        var session = await client.json('GET', '/$id');
        if (session['status'] == 'completed') {
          return ProcessingStatus.fromJson(session['processing'] as Json);
        }
        await api.updateTranscript(
          session['transcript_id'] as String,
          draft.text,
        );
        session = await client.json('GET', '/$id');
        final hash = sha256.convert(utf8.encode(draft.text)).toString();
        if (session['transcript_sha256'] != hash) {
          throw const ApiException(
            'review_outdated',
            'Текст на сервере изменился. Проверьте его перед повторным подтверждением.',
          );
        }
        return ProcessingStatus.fromJson(
          await client.json(
            'POST',
            '/$id/confirm',
            body: {
              'confirm': true,
              'reviewed_text_sha256': hash,
              'boundaries_reviewed': boundariesReviewed,
              'title': draft.title,
              'folder_ids': draft.folderIds,
              ...draft.options.toJson(),
            },
          ),
        );
      });
      await acceptAudio(accepted);
    } catch (_) {
      error = 'Не удалось подтвердить текст. Черновик сохранён; проверьте соединение и повторите.';
    } finally {
      working = false;
      _signal();
    }
    if (hasOperation) await check();
  }

  @override
  Future<void> finish() async {
    if (working) return;
    if (fixedSessionId != null) {
      if (result == null &&
          status?.phase != ProcessingPhase.error &&
          status?.phase != ProcessingPhase.notStarted) {
        return;
      }
      try {
        await drafts!.remove(fixedSessionId!);
        pause();
        recovery = RecoveryState();
        status = null;
        result = null;
      } catch (_) {
        storageError =
            'Не удалось завершить работу с черновиком. Повторите действие.';
      }
      _signal();
      return;
    }
    await recorder.command('done');
    if (recorder.phase != 'done') {
      error = 'Не удалось завершить встречу. Повторите действие.';
      _signal();
      return;
    }
    await super.finish();
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}

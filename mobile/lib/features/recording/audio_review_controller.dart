import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../api/api_client.dart';
import '../../models/api_models.dart';
import '../../models/processing_options.dart';
import '../../services/recovery_store.dart';
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
  });
  final AudioApi Function()? audioApiFactory;
  final RecorderCoordinator recorder;
  bool get needsBoundaryReview =>
      ((recorder.state['session'] as Json?)?['boundary_warnings'] as List? ??
              [])
          .isNotEmpty;
  bool boundariesReviewed = false;
  Future<void> openReview() async {
    final session = await withAudioApi(
      (api) => api.json('GET', '/${recorder.state['id']}'),
    );
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
      notifyListeners();
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
    notifyListeners();
    await check();
  }

  @override
  Future<void> submit() async {
    if (working || hasOperation) return;
    if (needsBoundaryReview && !boundariesReviewed) {
      error = 'Проверьте отмеченные стыки распознанного текста перед подтверждением.';
      notifyListeners();
      return;
    }
    working = true;
    error = null;
    notifyListeners();
    try {
      await store.save(recovery);
      final id = recorder.state['id'] as String;
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
      notifyListeners();
    }
    if (hasOperation) await check();
  }

  @override
  Future<void> finish() async {
    if (working) return;
    await recorder.command('done');
    if (recorder.phase != 'done') {
      error = 'Не удалось завершить встречу. Повторите действие.';
      notifyListeners();
      return;
    }
    await super.finish();
  }
}

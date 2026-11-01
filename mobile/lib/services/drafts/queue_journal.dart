import 'dart:convert';
import 'dart:math';

import '../../api/api_error.dart';
import '../../models/api_models.dart';
import '../../models/processing_options.dart';
import '../../models/summary_template.dart' show newSectionId;
import 'draft_record.dart';
import 'draft_repository.dart';

Json draftQueue(LocalDraftRecord record) =>
    (record.toJson()['checkpoints'] as Json)['queue'] as Json? ?? {};

String audioCreateSlot(LocalDraftRecord r) =>
    draftQueue(r)['audio_create_slot'] as String? ?? 'audio-create';
String textCreateSlot(LocalDraftRecord r) =>
    draftQueue(r)['text_create_slot'] as String? ?? 'text-create';
FrozenDraftRequest? audioCreate(LocalDraftRecord r) =>
    r.requests[audioCreateSlot(r)];

Json draftParameters(LocalDraftInput input) => {
  'title': input.title.trim(),
  'folder_ids': input.folderIds,
  ...ProcessingOptions.fromJson(input.options).toJson(),
};

String draftInputFingerprint(LocalDraftInput input) => jsonEncode({
  'title': input.title,
  'text': input.text,
  'folder_ids': input.folderIds,
  'options': ProcessingOptions.fromJson(input.options).toJson(),
  'processing_mode': input.processingMode,
});

/// Journaling only; HTTP must never run inside authority.serialized().
Json queueErrorFields(Object? error, {String fallback = 'processing_error'}) {
  if (error is Json) {
    return {
      'error_code': error['code'] is String ? error['code'] : fallback,
      'error_message': error['message'] is String ? error['message'] : null,
    };
  }
  return {
    'error_code': error is String && error.isNotEmpty ? error : fallback,
    'error_message': null,
  };
}

class QueueJournal {
  QueueJournal(this.repository, this.id);
  final LocalDraftRepository repository;
  final String id;
  Future<LocalDraftRecord> read() => repository.read(id);
  Future<LocalDraftRecord> change(void Function(Json) change) async {
    final current = await read();
    return repository.update(
      id,
      expectedRevision: current.revision,
      change: change,
    );
  }

  Future<void> status(
    String stage, {
    Json fields = const {},
    String? state,
  }) async {
    await change((j) {
      final checkpoints = j['checkpoints'] as Json;
      checkpoints['queue'] = {
        ...?(checkpoints['queue'] as Json?),
        'stage': stage,
        ...fields,
      };
      if (state != null) j['state'] = state;
    });
  }

  Future<FrozenDraftRequest> freeze(
    String slot,
    String method,
    String path,
    Json body, {
    Map<String, String> query = const {},
    String? key,
    Json? boundaryInput,
  }) async {
    final record = await read();
    final existing = record.requests[slot];
    if (existing != null) return existing;
    final request = FrozenDraftRequest(
      method: method,
      path: path,
      key: key ?? newSectionId(),
      body: body,
      query: query,
    );
    await repository.update(
      id,
      expectedRevision: record.revision,
      change: (json) {
        (json['requests'] as Json)[slot] = request.toJson();
        if (boundaryInput != null) {
          final checkpoints = json['checkpoints'] as Json;
          final queue = checkpoints['queue'] as Json? ?? {};
          checkpoints['queue'] = {...queue, 'input_at_boundary': boundaryInput};
        }
      },
    );
    return request;
  }

  Future<void> receipt(String slot, Json value, {Json ids = const {}}) async {
    await change((j) {
      final receipts = j['receipts'] as Json;
      if (receipts.containsKey(slot)) {
        if (jsonEncode(receipts[slot]) != jsonEncode(value)) {
          throw StateError('Receipt differs');
        }
      } else {
        receipts[slot] = value;
      }
      (j['server_ids'] as Json).addAll(ids);
    });
  }

  Future<bool> acknowledged(String slot) async =>
      ((await read()).toJson()['receipts'] as Json).containsKey(slot);
}

class QueueRetryPolicy {
  QueueRetryPolicy({DateTime Function()? now, double Function()? jitter})
    : now = now ?? DateTime.now,
      jitter = jitter ?? Random.secure().nextDouble;
  final DateTime Function() now;
  final double Function() jitter;
  Json failure(Object failure, Json previous) {
    final error = failure is ApiException ? failure : null;
    final attempt = (previous['attempt'] as int? ?? 0) + 1;
    final retryable =
        error?.retryable == true ||
        ['audio_session_busy', 'pipeline_busy'].contains(error?.code);
    final seconds = min(900, 2 * (1 << min(9, attempt - 1)));
    final backoff = Duration(
      milliseconds: (seconds * 1000 * (0.8 + 0.4 * jitter())).round(),
    );
    // Retry-After is a minimum, capped to one day to avoid unbounded scheduling.
    final minimum = error?.retryAfter ?? Duration.zero;
    final delay = minimum > backoff ? minimum : backoff;
    return {
      'attempt': attempt,
      'stage': error?.isAccess == true
          ? 'auth_blocked'
          : retryable
          ? 'retry_wait'
          : [404, 410].contains(error?.statusCode)
          ? 'remote_unavailable'
          : 'needs_action',
      'error_code': error?.code ?? 'local_storage_or_protocol',
      'next_attempt_at': retryable
          ? now()
                .toUtc()
                .add(
                  delay > const Duration(days: 1)
                      ? const Duration(days: 1)
                      : delay,
                )
                .toIso8601String()
          : null,
    };
  }

  bool due(Json queue) {
    if ([
      'auth_blocked',
      'needs_action',
      'remote_unavailable',
      'saved',
      'saved_with_changes',
      'review_required',
      'manual_ready',
      'cancelled',
      'paused',
      'deleted',
    ].contains(queue['stage'])) {
      return false;
    }
    final next = DateTime.tryParse(queue['next_attempt_at'] as String? ?? '');
    return next == null || !next.isAfter(now().toUtc());
  }
}

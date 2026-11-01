import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:queue_owner/queue_owner.dart';

import '../../api/api_client.dart';
import '../../api/demo_connection.dart';
import '../../features/selections/selection_controller.dart';
import '../../models/api_models.dart';
import '../../models/processing_options.dart';
import 'audio_wire_plan.dart';
import 'draft_access.dart';
import 'draft_record.dart';
import 'draft_repository.dart';
import 'draft_selection_store.dart';
import 'queue_journal.dart';
import 'queue_transport.dart';

/// An isolate-local runner; the native lease is authoritative across engines.
/// The lease never expires/gets stolen: yield aborts HTTP and drains writes first.
class DraftQueueRunner {
  DraftQueueRunner({
    required this.directory,
    required this.connection,
    AcquireDraftOwner? acquireOwner,
    http.Client Function()? clientFactory,
    Future<bool> Function()? isActive,
    Future<bool> Function()? capturePending,
    QueueRetryPolicy? policy,
    this.budget = const Duration(minutes: 4),
  }) : acquireOwner = acquireOwner ?? NativeQueueOwner.acquire,
       clientFactory = clientFactory ?? platformHttpClient,
       isActive = isActive ?? (() => activeQueueScope(directory, connection)),
       capturePending =
           capturePending ??
           (() => pendingCaptureHandoff(directory, connection.scopeId)),
       policy = policy ?? QueueRetryPolicy();
  final Directory directory;
  final DemoConnection connection;
  final AcquireDraftOwner acquireOwner;
  final http.Client Function() clientFactory;
  final Future<bool> Function() isActive, capturePending;
  bool get wasStopped => _stopping;
  final QueueRetryPolicy policy;
  final Duration budget;
  bool _stopping = false;
  bool ownerUnavailable = false;
  QueueCancellation? _cancellation;
  Future<void>? _running;
  Future<void> run() {
    if (_running != null) return _running!;
    _stopping = false;
    return _running = _run().whenComplete(() => _running = null);
  }

  Future<void> stop() async {
    _stopping = true;
    _cancellation?.stop();
    await _running;
  }

  Future<void> _run() async {
    ownerUnavailable = false;
    if (!await isActive()) return;
    if (await capturePending()) {
      ownerUnavailable = true;
      return;
    }
    final lease = await acquireOwner(connection.scopeId);
    if (lease == null) {
      ownerUnavailable = true;
      return;
    }
    final cancel = QueueCancellation();
    _cancellation = cancel;
    final transport = QueueTransport(
      connection,
      cancel,
      inner: clientFactory(),
    );
    final repository = LocalDraftRepository(
      scopeDirectory: directory,
      authority: lease,
    );
    final elapsed = Stopwatch()..start();
    var verified = false, watching = false;
    Future<void> checkpoint() async {
      cancel.check();
      if (_stopping ||
          elapsed.elapsed >= budget ||
          await lease.shouldYield() ||
          !await isActive()) {
        cancel.stop();
        throw const QueueStopped();
      }
    }

    final watch = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      if (watching || cancel.stopped) return;
      watching = true;
      try {
        await checkpoint();
      } catch (_) {
        cancel.stop();
      } finally {
        watching = false;
      }
    });
    try {
      await repository.recoverLocalDeletions();
      final listing = await repository.list();
      // Round-robin: one journal/HTTP step per draft per turn. A long Qwen poll
      // cannot monopolize delivery of a second independent source.
      for (var turn = 0; turn < 32; turn++) {
        var progressed = false;
        for (final initial in listing.items.reversed) {
          await checkpoint();
          LocalDraftRecord record;
          try {
            record = await repository.read(initial.localId);
          } on FileSystemException {
            continue;
          }
          final q = draftQueue(record);
          if (!_eligible(record, q) || !policy.due(q)) continue;
          final journal = QueueJournal(repository, record.localId);
          try {
            if (q['online_finish_pending'] == true) {
              // This one-shot check is NOT consent to start a new offline draft
              // later. Once accepted/frozen, exact reconciliation is durable.
              await journal.status(
                'checking_connection',
                fields: {'online_finish_pending': false},
              );
            }
            if (!verified) {
              await transport.verifyIdentity();
              await checkpoint();
              verified = true;
            }
            if (record.requests.isEmpty && q['online_finish_pending'] == true) {
              await journal.status('queued', fields: {'requested': true});
            }
            await _step(journal, lease, transport, checkpoint);
            progressed = true;
          } on QueueStopped {
            rethrow;
          } on QueueOwnerLost {
            rethrow;
          } catch (error) {
            final current = await journal.read();
            final old = draftQueue(current);
            // A failed online-finish probe without opt-in leaves an OFFLINE
            // draft. It must not become a delayed new submission on reconnect.
            if (current.requests.isEmpty &&
                q['online_finish_pending'] == true &&
                !current.autoStart &&
                q['requested'] != true &&
                error is ApiException &&
                error.retryable) {
              await journal.status(
                'draft',
                fields: {
                  'requested': false,
                  'online_finish_pending': false,
                  'next_attempt_at': null,
                  'error_code': error.code,
                },
              );
            } else {
              final fields = policy.failure(error, old);
              await journal.status(fields['stage'] as String, fields: fields);
            }
            if (error is ApiException && error.isAccess) verified = false;
          }
        }
        if (!progressed) break;
      }
    } on QueueStopped {
      /* Immutable unknown intents stay replayable. */
    } on QueueOwnerLost {
      /* No stale publication is permitted by native token. */
    } finally {
      watch.cancel();
      cancel.stop();
      transport.close();
      await lease.close();
      _cancellation = null;
    }
  }

  bool _eligible(LocalDraftRecord r, Json q) {
    if ([
          'draft',
          'recording',
          'paused',
          'capturing',
          'interrupted',
          'legacy_bridge',
          'migration_pending',
          'migration_prepared',
        ].contains(r.toJson()['state']) &&
        !(r.kind == LocalDraftKind.text && r.toJson()['state'] == 'draft')) {
      return false;
    }
    return r.requests.isNotEmpty ||
        r.serverIds.isNotEmpty ||
        r.autoStart ||
        q['requested'] == true ||
        q['online_finish_pending'] == true ||
        q['command'] != null;
  }

  Future<void> _progress(
    QueueJournal j,
    String stage, {
    Json fields = const {},
  }) => j.status(
    stage,
    fields: {
      'attempt': 0,
      'next_attempt_at': null,
      'error_code': null,
      ...fields,
    },
    state: 'processing',
  );
  Future<Json> _operation(
    QueueJournal j,
    QueueTransport t,
    String slot,
    String method,
    String path,
    Json body, {
    Map<String, String> query = const {},
  }) async {
    final r = await j.read();
    final receipt = (r.toJson()['receipts'] as Json)[slot] as Json?;
    if (receipt?['_rejected'] == true) {
      throw ApiException(
        receipt!['code'] as String,
        'Исправьте параметры и подтвердите новую попытку.',
        statusCode: receipt['status'] as int,
      );
    }
    if (receipt != null) return receipt;
    Json? boundary;
    if (slot == textCreateSlot(r) ||
        slot.startsWith('review-confirm:') ||
        slot.startsWith('retry:') &&
            path.endsWith('/pipeline/retry') &&
            body['parameters'] != null) {
      boundary = r.input.toJson();
    }
    if (slot == 'audio-complete' &&
        audioCreate(r)?.body['processing_mode'] == 'automatic') {
      final parameters =
          draftQueue(r)['applied_parameters'] as Json? ?? audioCreate(r)!.body;
      boundary = LocalDraftInput(
        title: parameters['title'] as String,
        text: r.input.text,
        folderIds: (parameters['folder_ids'] as List).cast<String>(),
        options: ProcessingOptions.fromJson(parameters).toJson(),
        processingMode: 'automatic',
      ).toJson();
    }
    final frozen = await j.freeze(
      slot,
      method,
      path,
      body,
      query: query,
      boundaryInput: boundary,
    );
    try {
      final response = await t.frozen(frozen);
      await j.receipt(slot, response);
      return response;
    } on ApiException catch (error) {
      // Definite validation rejection is not an unknown accepted operation.
      // A user repair can use a NEW slot/key while retaining the old proof.
      if ([400, 422].contains(error.statusCode) ||
          error.code == 'template_version_conflict' ||
          error.code == 'pipeline_parameters_locked' ||
          error.statusCode == 404 &&
              (path == 'audio-sessions' ||
                  path == 'transcripts/process' ||
                  path.endsWith('/parameters'))) {
        await j.receipt(slot, {
          '_rejected': true,
          'code': error.code,
          'status': error.statusCode,
        });
      }
      rethrow;
    }
  }

  bool _hasUnknown(LocalDraftRecord record) => record.requests.keys.any(
    (slot) =>
        !slot.startsWith('selection-') &&
        !slot.startsWith('candidate:') &&
        !(record.toJson()['receipts'] as Json).containsKey(slot),
  );
  Future<void> _step(
    QueueJournal j,
    QueueOwnerLease lease,
    QueueTransport t,
    Future<void> Function() checkpoint,
  ) async {
    var r = await j.read();
    var q = draftQueue(r);
    final selection = (r.toJson()['checkpoints'] as Json)['selection'] as Json?;
    if (selection?['accept_id'] != null && selection?['receipt'] == null) {
      await _manual(j, t);
      return;
    }
    for (final entry in r.requests.entries) {
      if (!(r.toJson()['receipts'] as Json).containsKey(entry.key) &&
          (entry.key == 'remote-delete' ||
              entry.key == 'pipeline-cancel' ||
              entry.key.startsWith('retry:') ||
              entry.key.startsWith('review-confirm:'))) {
        final response = await t.frozen(entry.value);
        await j.receipt(entry.key, response);
        if (entry.key == 'remote-delete') {
          final current = await j.read();
          await j.repository.deleteLocal(
            r.localId,
            expectedRevision: current.revision,
            confirmed: true,
            remoteOutcomeConfirmed: true,
          );
        } else {
          await _progress(
            j,
            'reconciling',
            fields: {if (entry.key.startsWith('retry:')) 'retry_kind': null},
          );
        }
        return;
      }
    }
    if (r.serverIds['summary_id'] != null) {
      await _finish(j, t);
      return;
    }
    if ((q['paused'] == true || q['command'] != null) && !_hasUnknown(r)) {
      await _control(j, t);
      return;
    }
    if (r.kind == LocalDraftKind.text) {
      if ((r.requests.keys.any((slot) => slot.startsWith('selection-create')) ||
              r.input.processingMode == 'review') &&
          r.requests[textCreateSlot(r)] == null) {
        await _manual(j, t);
        return;
      }
      if (r.serverIds['transcript_id'] == null) {
        final response = await _operation(
          j,
          t,
          textCreateSlot(r),
          'POST',
          'transcripts/process',
          {'text': r.input.text, ...draftParameters(r.input)},
        );
        final id = response['transcript_id'];
        if (id is! String || id.isEmpty) {
          throw const FormatException('Missing transcript identity');
        }
        await j.receipt(
          'text-bind',
          {'transcript_id': id},
          ids: {'transcript_id': id},
        );
        await _progress(
          j,
          'generating_qwen',
          fields: {
            'submitted_input':
                r.requests[textCreateSlot(r)]?.body ??
                {'text': r.input.text, ...draftParameters(r.input)},
          },
        );
        return;
      }
      await _pollText(j, t);
      return;
    }
    final sessionId = r.serverIds['audio_session_id'] as String?;
    if (sessionId == null) {
      final response = await _operation(
        j,
        t,
        audioCreateSlot(r),
        'POST',
        'audio-sessions',
        {
          ...draftParameters(r.input),
          'processing_mode': r.input.processingMode,
        },
      );
      final id = response['id'];
      if (id is! String || id.isEmpty) {
        throw const FormatException('Missing audio identity');
      }
      await j.receipt(
        'audio-bind',
        {'audio_session_id': id},
        ids: {'audio_session_id': id},
      );
      await _progress(j, 'uploading');
      return;
    }
    final create = audioCreate(r)!;
    final receipts = r.toJson()['receipts'] as Json;
    final completed = receipts.containsKey('audio-complete');
    final unknownPut = r.requests.entries.where(
      (e) => e.key.startsWith('parameters:') && !receipts.containsKey(e.key),
    );
    if (unknownPut.isNotEmpty) {
      final entry = unknownPut.first;
      final response = await t.frozen(entry.value);
      await j.receipt(entry.key, response);
      await _progress(
        j,
        'uploading',
        fields: {'applied_parameters': entry.value.body},
      );
      return;
    }
    if (!completed &&
        r.requests['audio-complete'] == null &&
        q['paused'] != true &&
        q['command'] == null &&
        q['keep_accepted_parameters'] != true) {
      final initial = {...create.body}..remove('processing_mode');
      final applied = q['applied_parameters'] as Json? ?? initial;
      final desired = draftParameters(r.input);
      if (create.body['processing_mode'] != r.input.processingMode) {
        throw const ApiException(
          'processing_mode_locked',
          'Режим уже принят сервером. Отмените старую операцию перед сменой режима.',
          statusCode: 409,
        );
      }
      if (jsonEncode(applied) != jsonEncode(desired) &&
          create.body['processing_mode'] == 'automatic') {
        final slot = 'parameters:${r.revision}';
        await _operation(
          j,
          t,
          slot,
          'PUT',
          'audio-sessions/$sessionId/pipeline/parameters',
          desired,
        );
        await _progress(
          j,
          'uploading',
          fields: {'applied_parameters': desired},
        );
        return;
      }
    }
    if (!completed) {
      final planner = AudioWirePlanner(
        j.repository,
        lease,
        checkpoint: checkpoint,
      );
      final plan = await planner.prepare(
        r.localId,
        AudioWireLimits.fromJson(receipts[audioCreateSlot(r)] as Json),
      );
      r = await j.read();
      for (final chunk in (plan['chunks'] as List).cast<Json>()) {
        final slot = 'chunk:${chunk['sequence']}';
        if ((r.toJson()['receipts'] as Json).containsKey(slot)) continue;
        if ((q['paused'] == true || q['command'] != null) &&
            r.requests[slot] == null) {
          continue;
        }
        final request = await j.freeze(
          slot,
          'POST',
          'audio-sessions/$sessionId/chunks',
          chunk,
          query: {
            'sequence_number': '${chunk['sequence']}',
            'start_ms': '${chunk['start_ms']}',
            'overlap_ms': '0',
            'duration_ms': '${chunk['duration_ms']}',
            'content_sha256': chunk['sha256'] as String,
          },
        );
        final response = await t.upload(
          sessionId,
          planner.file(
            r.localId,
            chunk['sequence'] as int,
            planId: plan['plan_id'] as String,
          ),
          request.body,
        );
        final ack = response['chunk'] as Json?;
        if (response['accepted'] != true ||
            response['safe_to_delete_local'] != true ||
            ack?['sequence_number'] != chunk['sequence'] ||
            ack?['sha256'] != chunk['sha256'] ||
            ack?['byte_count'] != chunk['byte_count']) {
          throw const FormatException('Invalid chunk receipt');
        }
        await j.receipt(slot, response);
        await _progress(j, 'uploading');
        return;
      }
      r = await j.read();
      q = draftQueue(r);
      if ((q['paused'] == true || q['command'] != null) &&
          r.requests['audio-complete'] == null) {
        await _control(j, t);
        return;
      }
      await _operation(
        j,
        t,
        'audio-complete',
        'POST',
        'audio-sessions/$sessionId/complete',
        {'expected_chunk_count': (plan['chunks'] as List).length},
      );
      await _progress(j, 'asr');
      return;
    }
    // All accepted intent is reconciled before pause/cancel/delete can advance.
    r = await j.read();
    q = draftQueue(r);
    if (q['paused'] == true || q['command'] != null) {
      await _control(j, t);
      return;
    }
    if (q['retry_kind'] != null) {
      final attempt = q['retry_attempt'] as String;
      final pipeline = q['retry_kind'] == 'pipeline';
      await _operation(
        j,
        t,
        'retry:$attempt',
        'POST',
        'audio-sessions/$sessionId/${pipeline ? 'pipeline/retry' : 'retry'}',
        pipeline && q['repair_parameters'] == true
            ? {'parameters': draftParameters(r.input)}
            : {},
      );
      await _progress(
        j,
        pipeline ? 'generating_qwen' : 'asr',
        fields: {'retry_kind': null},
      );
      return;
    }
    final session = await t.json('GET', 'audio-sessions/$sessionId');
    final transcript = session['transcript_id'] as String?;
    if (transcript != null && r.serverIds['transcript_id'] == null) {
      await j.receipt(
        'asr-source',
        {'transcript_id': transcript},
        ids: {'transcript_id': transcript},
      );
    }
    final pipeline = session['pipeline'] as Json?;
    final summary = pipeline?['summary_id'] as String?;
    if (pipeline?['phase'] == 'completed' && summary != null) {
      await j.receipt(
        'saved-result',
        {'summary_id': summary},
        ids: {'summary_id': summary},
      );
      return;
    }
    final phase = pipeline?['phase'] as String?;
    if (phase == 'review_required' ||
        session['status'] == 'ready_for_review' && pipeline == null) {
      await _review(j, t, session);
      return;
    }
    if (['needs_input', 'error', 'cancelled'].contains(phase) ||
        session['status'] == 'failed') {
      await j.status(
        phase == 'cancelled' ? 'cancelled' : 'needs_action',
        fields: {
          'server_phase': phase,
          'error_code': pipeline?['error_code'] ?? session['error_code'],
          'next_attempt_at': null,
        },
        state: 'processing',
      );
      return;
    }
    await _pollLater(j, phase ?? 'asr');
  }

  Future<void> _pollLater(QueueJournal j, String stage) async {
    final q = draftQueue(await j.read());
    final count = (q['poll_count'] as int? ?? 0) + 1;
    await j.status(
      stage,
      fields: {
        'poll_count': count,
        'attempt': 0,
        'error_code': null,
        'next_attempt_at': policy
            .now()
            .toUtc()
            .add(Duration(seconds: count > 15 ? 10 : 2))
            .toIso8601String(),
      },
      state: 'processing',
    );
  }

  Future<void> _pollText(QueueJournal j, QueueTransport t) async {
    final r = await j.read();
    final id = r.serverIds['transcript_id'];
    final q = draftQueue(r);
    if (q['retry_kind'] == 'text') {
      await _operation(
        j,
        t,
        'retry:${q['retry_attempt']}',
        'POST',
        'transcripts/$id/process',
        draftParameters(r.input),
      );
      await _progress(j, 'generating_qwen', fields: {'retry_kind': null});
      return;
    }
    final response = await t.json('GET', 'transcripts/$id/processing');
    if (response['status'] == 'ready' && response['summary_id'] is String) {
      await j.receipt(
        'saved-result',
        {'summary_id': response['summary_id']},
        ids: {'summary_id': response['summary_id']},
      );
      return;
    }
    if (response['status'] == 'error') {
      await j.status(
        'needs_action',
        fields: {
          ...queueErrorFields(response['error']),
          'next_attempt_at': null,
        },
      );
      return;
    }
    await _pollLater(j, 'generating_qwen');
  }

  Future<void> _review(QueueJournal j, QueueTransport t, Json session) async {
    var r = await j.read();
    final q = draftQueue(r);
    final id = session['transcript_id'] as String;
    var remote = await t.json('GET', 'transcripts/$id');
    final source =
        (r.toJson()['checkpoints'] as Json)['review_source'] as Json?;
    if (source == null) {
      await j.change((json) {
        final input = json['input'] as Json;
        input['text'] = remote['text'];
        (json['checkpoints'] as Json)['review_source'] = {
          'text': remote['text'],
          'sha256': session['transcript_sha256'],
          'boundary_warnings': session['boundary_warnings'] ?? [],
        };
      });
      await j.status(
        'review_required',
        fields: {'review_confirmed': false, 'next_attempt_at': null},
      );
      return;
    }
    if (q['review_confirmed'] != true) {
      await j.status('review_required', fields: {'next_attempt_at': null});
      return;
    }
    if ((session['boundary_warnings'] as List? ?? []).isNotEmpty &&
        q['boundaries_reviewed'] != true) {
      throw const ApiException(
        'boundary_review_required',
        'Проверьте стыки распознанного текста.',
        statusCode: 409,
      );
    }
    var baseline = source['applied_text'] ?? source['text'];
    // Reconcile a lost PATCH reply by reading exact content before any newer
    // edit. Never blindly replay over a third-party version of this source.
    for (final entry in r.requests.entries.where(
      (e) => e.key.startsWith('review-patch:'),
    )) {
      if ((r.toJson()['receipts'] as Json).containsKey(entry.key)) continue;
      if (remote['text'] != entry.value.body['text']) {
        if (remote['text'] != baseline) {
          throw const ApiException(
            'review_outdated',
            'Источник изменился. Ваши локальные правки сохранены.',
            statusCode: 409,
          );
        }
        final response = await t.frozen(entry.value);
        await j.receipt(entry.key, response);
        remote = await t.json('GET', 'transcripts/$id');
      } else {
        await j.receipt(entry.key, remote);
      }
      baseline = entry.value.body['text'];
      await j.change((json) {
        ((json['checkpoints'] as Json)['review_source']
                as Json)['applied_text'] =
            baseline;
      });
    }
    if (remote['text'] != r.input.text) {
      if (remote['text'] != baseline) {
        throw const ApiException(
          'review_outdated',
          'Источник изменён на сервере. Локальные правки сохранены.',
          statusCode: 409,
        );
      }
      final slot = 'review-patch:${q['review_attempt']}';
      await _operation(j, t, slot, 'PATCH', 'transcripts/$id', {
        'text': r.input.text,
      });
      await j.change((json) {
        ((json['checkpoints'] as Json)['review_source']
                as Json)['applied_text'] =
            r.input.text;
      });
    }
    final fresh = await t.json('GET', 'audio-sessions/${session['id']}');
    final sha = fresh['transcript_sha256'];
    if (sha is! String || sha.isEmpty) {
      throw const FormatException('Review hash absent');
    }
    await j.status('review_confirmed', fields: {'reviewed_sha256': sha});
    r = await j.read();
    if (audioCreate(r)!.body['processing_mode'] == 'automatic') {
      await _operation(
        j,
        t,
        'review-confirm:${q['review_attempt']}',
        'POST',
        'audio-sessions/${session['id']}/confirm',
        {
          ...draftParameters(r.input),
          'confirm': true,
          'reviewed_text_sha256': sha,
          'boundaries_reviewed': q['boundaries_reviewed'] == true,
        },
      );
      await _progress(j, 'generating_qwen');
    } else {
      await _manual(j, t);
    }
  }

  Future<void> _manual(QueueJournal j, QueueTransport t) async {
    final r = await j.read();
    final q = draftQueue(r);
    if (r.kind == LocalDraftKind.audio && q['review_confirmed'] != true) {
      await j.status('review_required', fields: {'next_attempt_at': null});
      return;
    }
    final store = DraftSelectionStore(j);
    await store.load();
    final api = ApiClient(connection.base, client: t.client, operations: store);
    Object? failure;
    final c = SelectionController(
      api: api,
      store: store,
      slot: store.selectionSlot,
      source: () async => {
        if (r.kind == LocalDraftKind.audio) ...{
          'audio_session_id': r.serverIds['audio_session_id'],
          'confirm': q['review_confirmed'] == true,
          'reviewed_text_sha256': q['reviewed_sha256'],
          'boundaries_reviewed': q['boundaries_reviewed'] == true,
        } else if (_borrowedTextSource(r) != null)
          'transcript_id': _borrowedTextSource(r)
        else
          'text': r.input.text,
        'title': r.input.title.trim(),
        'folder_ids': r.input.folderIds,
      },
      initialOptions: ProcessingOptions.fromJson(r.input.options),
      autoPoll: false,
      onFailure: (error) {
        failure = error;
      },
    );
    try {
      await c.initialize();
      if (failure is ApiException &&
          c.state['session_id'] == null &&
          [400, 404, 422].contains((failure as ApiException).statusCode)) {
        final error = failure as ApiException;
        await j.receipt('selection-reject:${c.state['key']}', {
          '_rejected': true,
          'code': error.code,
          'status': error.statusCode,
        });
        await j.status(
          'needs_action',
          fields: {'selection_source_rejected': true},
        );
        throw ApiException(
          'source_input_rejected',
          error.message,
          statusCode: 422,
        );
      }
      if (failure != null) throw failure!;
      if (c.accepted != null) {
        await _finish(j, t);
        return;
      }
      if (q['retry_kind'] == 'candidate' &&
          !c.generating &&
          !c.hasPending &&
          !c.frozen) {
        await c.generate(ProcessingOptions.fromJson(r.input.options));
        if (failure != null) throw failure!;
        await j.status('generating_qwen', fields: {'retry_kind': null});
      }
      if (c.active?['status'] == 'error') {
        await j.status(
          'needs_action',
          fields: {
            'server_phase': 'candidate_error',
            ...queueErrorFields(
              c.active?['error'],
              fallback: 'candidate_error',
            ),
            'next_attempt_at': null,
          },
        );
        return;
      }

      if (c.terminal && store[store.selectionSlot] == null) return;
      if (c.terminal) {
        throw const ApiException(
          'selection_closed',
          'Выбор вариантов закрыт. Исходник сохранён.',
          statusCode: 410,
        );
      }
      if (c.ready) {
        await j.status('manual_ready', fields: {'next_attempt_at': null});
      } else {
        await _pollLater(j, 'generating_qwen');
      }
    } finally {
      c.dispose();
      store.dispose();
    }
    // t owns the client; ApiClient is a lightweight view, never closes it here.
  }

  Future<void> _control(QueueJournal j, QueueTransport t) async {
    final r = await j.read();
    final q = draftQueue(r);
    final command = q['command'];
    final id = r.serverIds['audio_session_id'] as String?;
    if (command == null) {
      await j.status('paused', fields: {'next_attempt_at': null});
      return;
    }
    if (r.serverIds['summary_id'] != null) {
      await _finish(j, t);
      return;
    }
    final rejectedSource =
        q['selection_source_rejected'] == true ||
        r.requests.isNotEmpty &&
            r.requests.keys.every(
              (key) =>
                  ((r.toJson()['receipts'] as Json)[key]
                      as Json?)?['_rejected'] ==
                  true,
            );
    if (id == null &&
        r.serverIds.isEmpty &&
        (r.requests.isEmpty || rejectedSource)) {
      if (command == 'delete') {
        await j.repository.deleteLocal(
          r.localId,
          expectedRevision: r.revision,
          confirmed: true,
          remoteOutcomeConfirmed: true,
        );
      } else {
        await j.status('paused', fields: {'command': null, 'paused': true});
      }
      return;
    }
    if (id == null) {
      throw const ApiException(
        'remote_cancel_unavailable',
        'Принятый текст сохранён. Удаление этого источника недоступно.',
        statusCode: 409,
      );
    }
    final review = audioCreate(r)?.body['processing_mode'] != 'automatic';
    if (review && command != 'delete') {
      await j.status(
        'paused',
        fields: {
          'paused': true,
          'command': null,
          'error_code': 'review_remote_cancel_unavailable',
          'next_attempt_at': null,
        },
      );
      return;
    }
    if (!review) {
      await _operation(
        j,
        t,
        'pipeline-cancel',
        'POST',
        'audio-sessions/$id/pipeline/cancel',
        {'confirm': true},
      );
    }
    if (command == 'delete') {
      await _operation(
        j,
        t,
        'remote-delete',
        'DELETE',
        'audio-sessions/$id',
        {},
        query: {'confirm': 'true', if (review) 'discard_unprocessed': 'true'},
      );
      final current = await j.read();
      await j.repository.deleteLocal(
        r.localId,
        expectedRevision: current.revision,
        confirmed: true,
        remoteOutcomeConfirmed: true,
      );
    } else {
      await j.status(
        'cancelled',
        fields: {'command': null, 'paused': true, 'next_attempt_at': null},
      );
    }
  }

  Future<void> _finish(QueueJournal j, QueueTransport t) async {
    final r = await j.read();
    final id = r.serverIds['summary_id'] as String;
    final result = await t.json('GET', 'summaries/$id');
    if (result['id'] != id ||
        result['transcript_id'] != r.serverIds['transcript_id']) {
      throw const FormatException('Saved summary identity differs');
    }
    // Do not erase edits made while an immutable request was in flight.
    final q = draftQueue(r);
    final baseline = q['submitted_input'] as Json?;
    final create = audioCreate(r);
    final expected =
        baseline ??
        q['applied_parameters'] as Json? ??
        (create == null ? null : ({...create.body}..remove('processing_mode')));
    final current = r.kind == LocalDraftKind.text
        ? {'text': r.input.text, ...draftParameters(r.input)}
        : draftParameters(r.input);
    final boundary = q['input_at_boundary'] as Json?;
    final changed =
        boundary == null &&
            (r.requests.containsKey('audio-complete') ||
                r.requests.keys.any(
                  (slot) => slot.startsWith('selection-create'),
                ))
        ? true
        : boundary != null
        ? draftInputFingerprint(LocalDraftInput.fromJson(boundary)) !=
              draftInputFingerprint(r.input)
        : expected != null && jsonEncode(expected) != jsonEncode(current);
    await j.receipt('verified-result', {
      'summary_id': id,
      'transcript_id': result['transcript_id'],
    });
    // Tiny bounded delivery notices, not a local contents library.
    final file = File('${directory.path}/queue-completions.json');
    await j.repository.authority.serialized(() async {
      final raw = await file.exists()
          ? jsonDecode(await file.readAsString()) as Json
          : {'schema': 1, 'items': <dynamic>[]};
      final items = (raw['items'] as List).cast<Json>();
      if (!items.any((e) => e['local_id'] == r.localId)) {
        items.add({
          'local_id': r.localId,
          'summary_id': id,
          'title': result['title'],
          'saved_at': policy.now().toUtc().toIso8601String(),
        });
      }
      await j.repository.authority.writeSnapshot(
        file,
        jsonEncode({
          'schema': 1,
          'items': items.length > 20 ? items.sublist(items.length - 20) : items,
        }),
      );
    });
    if (changed) {
      await j.status(
        'saved_with_changes',
        fields: {'next_attempt_at': null},
        state: 'saved_with_changes',
      );
      return;
    }
    final currentRecord = await j.read();
    await j.repository.deleteLocal(
      r.localId,
      expectedRevision: currentRecord.revision,
      confirmed: true,
      remoteOutcomeConfirmed: true,
    );
  }
}

/// Headless jobs carry only scope/local IDs; origin/account come from this
/// immutable binding and must still match the currently selected profile.
Future<bool> activeQueueScope(
  Directory directory,
  DemoConnection connection,
) async {
  try {
    final root = directory.parent.parent;
    final settings = File('${root.path}/connection-settings.json');
    final binding = File('${directory.path}/queue-binding.json');
    final control = File('${directory.path}/queue-control.json');
    for (final entity in [directory, settings, binding, control]) {
      if (await FileSystemEntity.isLink(entity.path)) return false;
    }
    final active = jsonDecode(await settings.readAsString()) as Json;
    if (jsonEncode(active['active']) != jsonEncode(connection.toJson())) {
      return false;
    }
    final saved = jsonDecode(await binding.readAsString()) as Json;
    if (saved['scope_id'] != connection.scopeId ||
        jsonEncode(saved['connection']) != jsonEncode(connection.toJson())) {
      return false;
    }
    if (await control.exists() &&
        (jsonDecode(await control.readAsString()) as Json)['paused'] == true) {
      return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

Future<bool> pendingCaptureHandoff(Directory directory, String scope) async {
  final ticket = await NativeQueueOwner.captureTicket();
  if (ticket?['scope'] != scope) return false;
  final id = ticket?['local_id'];
  if (id == null || !localDraftIdPattern.hasMatch(id)) return true;
  try {
    final repository = LocalDraftRepository(
      scopeDirectory: directory,
      authority: ReadOnlyDraftAuthority(scope),
    );
    final record = await repository.read(id);
    final launch =
        (record.toJson()['checkpoints'] as Json)['capture_launch'] as Json?;
    return launch?['nonce'] == ticket?['nonce'] && launch?['consumed'] == false;
  } catch (_) {
    return true;
  }
}

String? _borrowedTextSource(LocalDraftRecord record) {
  final history =
      (record.toJson()['checkpoints'] as Json)['selection_history'] as Json? ??
      {};
  final active = draftQueue(record)['active_selection_key'];
  final state = history[active] as Json?;
  final source = state?['source'] as Json?;
  return source?['transcript_id'] as String?;
}

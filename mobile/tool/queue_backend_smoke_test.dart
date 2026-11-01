import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'package:your_mettings/features/selections/selection_controller.dart';
import 'package:your_mettings/models/processing_options.dart';
import 'package:your_mettings/services/drafts/draft_selection_store.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/api/demo_connection.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/demo_key_vault.dart';
import 'package:your_mettings/services/drafts/draft_record.dart';
import 'package:your_mettings/services/drafts/draft_workspace.dart';
import 'package:your_mettings/services/drafts/queue_journal.dart';
import 'package:your_mettings/services/drafts/queue_runner.dart';
import 'package:your_mettings/services/drafts/queue_transport.dart';

import '../test/support/draft_test_fixture.dart' show TestDraftOwnerPool;

/// Opt-in host integration, not part of the normal unit suite. Only a PRIVATE
/// key FILE PATH is accepted, never a key command-line argument or test log.
class _FileVault implements DemoKeyVault {
  _FileVault(this.file, this.origin);
  final File file;
  final String origin;
  @override
  Future<String?> read(String target) async =>
      target == origin ? (await file.readAsString()).trim() : null;
  @override
  Future<void> write(String origin, String key) =>
      throw UnsupportedError('Read-only private credential');
}

Uint8List _pcm(Uint8List wav) {
  final data = ByteData.sublistView(wav);
  if (ascii.decode(wav.sublist(0, 4)) != 'RIFF' ||
      ascii.decode(wav.sublist(8, 12)) != 'WAVE') {
    throw StateError('Synthetic WAV header');
  }
  var position = 12;
  Uint8List? result;
  var valid = false;
  while (position + 8 <= wav.length) {
    final name = ascii.decode(wav.sublist(position, position + 4));
    final count = data.getUint32(position + 4, Endian.little),
        start = position + 8;
    if (start + count > wav.length) throw StateError('Truncated synthetic WAV');
    if (name == 'fmt ') {
      valid =
          data.getUint16(start, Endian.little) == 1 &&
          data.getUint16(start + 2, Endian.little) == 1 &&
          data.getUint32(start + 4, Endian.little) == 16000 &&
          data.getUint16(start + 14, Endian.little) == 16;
    }
    if (name == 'data') {
      result = Uint8List.sublistView(wav, start, start + count);
    }
    position = start + count + (count % 2);
  }
  if (!valid || result == null || result.isEmpty) {
    throw StateError('Synthetic PCM format');
  }
  return result;
}

class _DropCommittedAck extends http.BaseClient {
  _DropCommittedAck(this.inner, this.lost, this.fingerprints, this.replayed);
  final http.Client inner;
  final Set<String> lost, replayed;
  final Map<String, String> fingerprints;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final tag =
        request.method == 'DELETE' && path.contains('/summary-selections/')
        ? 'cancel'
        : request.method == 'POST' && path.endsWith('/pipeline/retry')
        ? 'pipeline-retry'
        : request.method == 'POST' && path.endsWith('/audio-sessions')
        ? 'audio-create'
        : request.method == 'POST' && path.endsWith('/transcripts/process')
        ? 'text-create'
        : request.method == 'PUT' && path.endsWith('/parameters')
        ? 'parameters'
        : request.method == 'POST' && path.endsWith('/chunks')
        ? 'chunk'
        : request.method == 'POST' && path.endsWith('/complete')
        ? 'complete'
        : request.method == 'POST' && path.endsWith('/accept')
        ? 'accept'
        : request.method == 'POST' && path.endsWith('/candidates')
        ? 'candidate'
        : null;
    if (tag != null && request is http.Request) {
      final identity =
          '${request.method}|${request.url}|${request.headers['Idempotency-Key']}|${sha256.convert(request.bodyBytes)}';
      if (fingerprints.containsKey(tag)) {
        if (!replayed.contains(tag) && fingerprints[tag] != identity) {
          throw StateError('Exact committed replay differs for $tag');
        }
        replayed.add(tag);
      } else {
        fingerprints[tag] = identity;
      }
    }
    final streamed = await inner.send(request);
    if (tag != null &&
        streamed.statusCode >= 200 &&
        streamed.statusCode < 300 &&
        lost.add(tag)) {
      await http.Response.fromStream(streamed);
      throw http.ClientException('Synthetic ACK loss after server commit');
    }
    return streamed;
  }

  @override
  void close() => inner.close();
}

void main() {
  test('host production queue: real synthetic ASR/Qwen automatic + independent text + review discard', () async {
    final keyPath = Platform.environment['YM_QUEUE_QA_KEY_FILE'];
    final wavPath = Platform.environment['YM_QUEUE_QA_WAV'];
    if (keyPath == null || wavPath == null) {
      throw StateError(
        'Provide PRIVATE YM_QUEUE_QA_KEY_FILE and synthetic YM_QUEUE_QA_WAV paths',
      );
    }
    final base = Uri.parse('http://127.0.0.1:8001/api/v1/');
    final vault = _FileVault(File(keyPath), base.origin);
    final probeCancel = QueueCancellation();
    final probe = QueueTransport(
      DemoConnection(
        base: base,
        accountId: 'probe',
        accessMode: 'demo',
        vault: vault,
      ),
      probeCancel,
    );
    final identity = await probe.json('GET', 'auth/me');
    probe.close();
    if (identity['id'] is! String || identity['access_mode'] != 'demo') {
      throw StateError('Expected local demo identity');
    }
    final binding = DemoConnection(
      base: base,
      accountId: identity['id'] as String,
      accessMode: 'demo',
      vault: vault,
    );
    final root = await Directory.systemTemp.createTemp('ym-live-queue-');
    final pool = TestDraftOwnerPool();
    final cancel = QueueCancellation();
    final transport = QueueTransport(binding, cancel);
    final api = ApiClient(base, client: transport.client);
    final workspace = DraftWorkspace(
      directory: Directory('${root.path}/scopes/${binding.scopeId}'),
      connection: binding,
      api: api,
      acquireOwner: pool.acquire,
      yieldOwner: pool.requestYield,
    );
    final stamp = DateTime.now().microsecondsSinceEpoch.toString();
    final result = <String, dynamic>{
      'run': stamp,
      'authority': 'host test authority; production queue/HTTP/planner/journal',
      'phone_tested': false,
      'passed': false,
      'summary_ids': <String>[],
    };
    final output = File('build/queue-backend-smoke-result.json');
    String? folderId;
    final created = <String>[];
    final lost = <String>{}, replayed = <String>{};
    final fingerprints = <String, String>{};
    Future<void> checkpoint() async {
      await output.parent.create(recursive: true);
      await output.writeAsString(jsonEncode(result), flush: true);
    }

    Future<void> cycle() async {
      // New runner each cycle models isolate/process restart from durable files.
      await DraftQueueRunner(
        directory: workspace.directory,
        connection: binding,
        acquireOwner: pool.acquire,
        capturePending: () async => false,
        clientFactory: () => _DropCommittedAck(
          platformHttpClient(),
          lost,
          fingerprints,
          replayed,
        ),
      ).run();
      await workspace.reload();
      await checkpoint();
    }

    try {
      await workspace.initialize();
      await File('${root.path}/connection-settings.json').writeAsString(
        jsonEncode({'version': 1, 'active': binding.toJson()}),
        flush: true,
      );
      final folder = await api.createFolder('QA offline queue $stamp');
      folderId = folder.id;
      result['folder_id'] = folder.id;
      await checkpoint();
      final templates = await api.templates();
      final template = templates.where((t) => t.isDefault).first;
      final options = {
        'template_id': template.id,
        'expected_template_version': template.version,
        'detail_level': 'brief',
        'focus_areas': <String>[],
        'additional_instructions': '',
      };
      final audio = await workspace.create(
        LocalDraftKind.audio,
        input: LocalDraftInput(
          title: 'QA synthetic audio $stamp',
          folderIds: [folder.id],
          options: options,
          processingMode: 'automatic',
        ),
      );
      final text = await workspace.create(
        LocalDraftKind.text,
        input: LocalDraftInput(
          title: 'QA synthetic text $stamp',
          text: 'Иван: тестовую версию выпустим в пятницу. Мария: проверю Android до четверга. Решение принято. Ответственный за выпуск Иван.',
          folderIds: [folder.id],
          options: options,
          processingMode: 'automatic',
        ),
      );
      created.addAll([audio.localId, text.localId]);
      result['local_ids'] = created;
      await checkpoint();
      final pcm = _pcm(await File(wavPath).readAsBytes());
      await workspace.withOwner((repo, lease) async {
        final source = File(
          '${repo.draftDirectory(audio.localId).path}/source.pcm',
        );
        for (var offset = 0; offset < pcm.length; offset += 65536) {
          final end = (offset + 65536).clamp(0, pcm.length);
          await lease.serialized(
            () => lease.appendPcm(
              source,
              offset,
              Uint8List.sublistView(pcm, offset, end),
            ),
          );
        }
        await repo.update(
          audio.localId,
          expectedRevision: audio.revision,
          change: (j) {
            j['state'] = 'ready';
            (j['checkpoints'] as Json)['queue'] = {
              'online_finish_pending': true,
            };
          },
        );
      });
      await workspace.queueAction(text.localId, 'start');
      final elapsed = Stopwatch()..start();
      final seen = <String>{};
      while (elapsed.elapsed < const Duration(minutes: 12)) {
        await cycle();
        final audioDraft = workspace.items
            .where((r) => r.localId == audio.localId)
            .firstOrNull;
        if (audioDraft != null &&
            audioDraft.requests.isNotEmpty &&
            audioDraft.serverIds.isEmpty &&
            audioDraft.input.title == 'QA synthetic audio $stamp') {
          await workspace.save(
            audioDraft.localId,
            revision: audioDraft.revision,
            input: LocalDraftInput(
              title: 'QA changed after lost ACK $stamp',
              folderIds: audioDraft.input.folderIds,
              options: audioDraft.input.options,
              processingMode: 'automatic',
            ),
            autoStart: audioDraft.autoStart,
          );
        }
        final notices = workspace.completions
            .where((e) => created.contains(e['local_id']))
            .toList();
        result['summary_ids'] = notices
            .map((e) => e['summary_id'] as String)
            .toList();
        for (final draft in workspace.items.where(
          (e) => created.contains(e.localId),
        )) {
          final q = draftQueue(draft);
          final stage = q['stage'];
          if (seen.add('${draft.kind.name}:$stage')) {
            debugPrint('HOST_QUEUE ${draft.kind.name} $stage');
          }
          if ([
            'needs_action',
            'auth_blocked',
            'remote_unavailable',
          ].contains(stage)) {
            result['failure_code'] = q['error_code'];
            await checkpoint();
            throw StateError('Host queue blocked: ${q['error_code']}');
          }
        }
        if (notices.length == 2) break;
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      expect(
        (result['summary_ids'] as List).length,
        2,
        reason: 'Both independent operations must reach saved summary',
      );
      expect(
        workspace.items.where((e) => created.contains(e.localId)),
        isEmpty,
      );
      for (final id in (result['summary_ids'] as List).cast<String>()) {
        final summary = await api.summary(id);
        expect(summary.folderIds, contains(folder.id));
        expect(summary.content.trim(), isNotEmpty);
        expect(summary.transcriptId, isNotEmpty);
      }
      result['automatic_without_accept'] = true;
      result['independent_sources'] = true;
      result['source_cleanup_after_saved'] = true;
      final manual = await workspace.create(
        LocalDraftKind.text,
        input: LocalDraftInput(
          title: 'QA manual $stamp',
          text: 'Иван: Мария проверит Android до четверга, а я выпущу версию в пятницу. Решение согласовано.',
          folderIds: [folder.id],
          options: options,
        ),
      );
      created.add(manual.localId);
      await workspace.queueAction(manual.localId, 'start');
      final manualTime = Stopwatch()..start();
      while (manualTime.elapsed < const Duration(minutes: 6)) {
        await cycle();
        final current = workspace.items
            .where((e) => e.localId == manual.localId)
            .first;
        final stage = draftQueue(current)['stage'];
        if (stage == 'manual_ready') break;
        if ([
          'needs_action',
          'remote_unavailable',
          'auth_blocked',
        ].contains(stage)) {
          throw StateError(
            'Manual queue blocked: ${draftQueue(current)['error_code']}',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      expect(
        draftQueue(await workspace.reader.read(manual.localId))['stage'],
        'manual_ready',
      );
      await workspace.withOwner((repo, _) async {
        final store = DraftSelectionStore(QueueJournal(repo, manual.localId));
        await store.load();
        final manualCancel = QueueCancellation();
        final manualTransport = QueueTransport(
          binding,
          manualCancel,
          inner: _DropCommittedAck(
            platformHttpClient(),
            lost,
            fingerprints,
            replayed,
          ),
        );
        final controller = SelectionController(
          api: ApiClient(
            base,
            client: manualTransport.client,
            operations: store,
          ),
          store: store,
          slot: store.selectionSlot,
          source: () async => throw StateError('Must recover'),
          initialOptions: ProcessingOptions.fromJson(options),
          autoPoll: false,
        );
        try {
          await controller.initialize();
          expect(controller.ready, isTrue);
          await controller.editActive(
            title: 'QA accepted edit $stamp',
            content:
                '${controller.content}\n\n**Проверка:** правка после генерации.',
          );
          await controller.accept();
          expect(controller.accepted, isNull);
          final pending = await repo.read(manual.localId);
          expect(pending.requests['selection-accept'], isNotNull);
          expect(pending.serverIds['summary_id'], isNull);
        } finally {
          controller.dispose();
          manualCancel.stop();
          await controller.drain();
          manualTransport.close();
          store.dispose();
        }
      });
      await cycle();
      expect(
        await workspace.reader.draftDirectory(manual.localId).exists(),
        isFalse,
      );
      final manualNotice = workspace.completions
          .where((e) => e['local_id'] == manual.localId)
          .single;
      final manualSaved = await api.summary(
        manualNotice['summary_id'] as String,
      );
      expect(manualSaved.title, 'QA accepted edit $stamp');
      expect(manualSaved.content, contains('правка после генерации'));
      result['summary_ids'] = [
        ...(result['summary_ids'] as List),
        manualSaved.id,
      ];
      result['manual_real_atomic_accept'] = true;
      result['committed_ack_losses'] = lost.toList()..sort();
      result['exact_replays'] = replayed.toList()..sort();
      expect(
        replayed,
        containsAll([
          'audio-create',
          'text-create',
          'parameters',
          'chunk',
          'complete',
          'candidate',
          'accept',
        ]),
      );
      // Real review audio: user gate, cancelled choice + lost204, explicit
      // new template on the SAME ASR source, then atomic edited acceptance.
      final reviewed = await workspace.create(
        LocalDraftKind.audio,
        input: LocalDraftInput(
          title: 'QA review audio $stamp',
          folderIds: [folder.id],
          options: options,
        ),
      );
      created.add(reviewed.localId);
      await workspace.withOwner((repo, lease) async {
        final file = File(
          '${repo.draftDirectory(reviewed.localId).path}/source.pcm',
        );
        for (var offset = 0; offset < pcm.length; offset += 65536) {
          final end = (offset + 65536).clamp(0, pcm.length);
          await lease.serialized(
            () => lease.appendPcm(
              file,
              offset,
              Uint8List.sublistView(pcm, offset, end),
            ),
          );
        }
        await repo.update(
          reviewed.localId,
          expectedRevision: reviewed.revision,
          change: (j) {
            j['state'] = 'ready';
            (j['checkpoints'] as Json)['queue'] = {
              'online_finish_pending': true,
            };
          },
        );
      });
      Future<LocalDraftRecord> awaitStage(String id, String wanted) async {
        final elapsed = Stopwatch()..start();
        while (elapsed.elapsed < const Duration(minutes: 6)) {
          await cycle();
          final current = await workspace.reader.read(id);
          final stage = draftQueue(current)['stage'];
          if (stage == wanted) return current;
          if ([
            'needs_action',
            'auth_blocked',
            'remote_unavailable',
          ].contains(stage)) {
            throw StateError(
              'Review queue blocked: ${draftQueue(current)['error_code']}',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 800));
        }
        throw StateError('Review queue deadline $wanted');
      }

      final awaitingReview = await awaitStage(
        reviewed.localId,
        'review_required',
      );
      expect(awaitingReview.input.text.trim(), isNotEmpty);
      expect(
        awaitingReview.requests.keys.any(
          (key) => key.startsWith('selection-create'),
        ),
        isFalse,
      );
      final sourceId = awaitingReview.serverIds['transcript_id'] as String;
      final sessionId = awaitingReview.serverIds['audio_session_id'] as String;
      final beforeSession = await transport.json(
        'GET',
        'audio-sessions/$sessionId',
      );
      final attemptsBefore = [
        for (final c in beforeSession['chunks'] as List) (c as Json)['attempt'],
      ];
      await workspace.queueAction(
        reviewed.localId,
        'start',
        boundariesReviewed: true,
      );
      await awaitStage(reviewed.localId, 'manual_ready');
      Future<void> reviewController(
        Future<void> Function(SelectionController) act,
      ) async {
        await workspace.withOwner((repo, _) async {
          final store = DraftSelectionStore(
            QueueJournal(repo, reviewed.localId),
          );
          await store.load();
          final localCancel = QueueCancellation();
          final client = QueueTransport(
            binding,
            localCancel,
            inner: _DropCommittedAck(
              platformHttpClient(),
              lost,
              fingerprints,
              replayed,
            ),
          );
          final c = SelectionController(
            api: ApiClient(base, client: client.client, operations: store),
            store: store,
            slot: store.selectionSlot,
            source: () async => throw StateError('Must reuse source'),
            initialOptions: const ProcessingOptions(),
            autoPoll: false,
          );
          try {
            await c.initialize();
            expect(c.ready, isTrue);
            await act(c);
          } finally {
            c.dispose();
            localCancel.stop();
            await c.drain();
            client.close();
            store.dispose();
          }
        });
      }

      final firstChoice = (await workspace.reader.read(reviewed.localId))
          .serverIds['selection_id'];
      await reviewController((c) async {
        expect(await c.cancel(), isFalse);
      });
      await awaitStage(reviewed.localId, 'paused');
      var resumed = await workspace.reader.read(reviewed.localId);
      final alternate = templates.where((t) => t.id != template.id).first;
      resumed = await workspace.save(
        resumed.localId,
        revision: resumed.revision,
        input: LocalDraftInput(
          title: resumed.input.title,
          text: resumed.input.text,
          folderIds: resumed.input.folderIds,
          options: {
            ...options,
            'template_id': alternate.id,
            'expected_template_version': alternate.version,
          },
        ),
        autoStart: false,
      );
      await workspace.queueAction(
        resumed.localId,
        'start',
        boundariesReviewed: true,
      );
      resumed = await awaitStage(resumed.localId, 'manual_ready');
      expect(resumed.serverIds['selection_id'], isNot(firstChoice));
      expect(resumed.serverIds['transcript_id'], sourceId);
      expect(resumed.serverIds['audio_session_id'], sessionId);
      final afterSession = await transport.json(
        'GET',
        'audio-sessions/$sessionId',
      );
      expect([
        for (final c in afterSession['chunks'] as List) (c as Json)['attempt'],
      ], attemptsBefore);
      await reviewController((c) async {
        await c.editActive(
          title: 'QA reviewed audio $stamp',
          content:
              '${c.content}\n\n**Проверено:** исходник и выбранный шаблон.',
        );
        await c.accept();
        expect(c.accepted, isNotNull);
        await c.complete();
      });
      await cycle();
      expect(
        await workspace.reader.draftDirectory(reviewed.localId).exists(),
        isFalse,
      );
      final audioNotice = workspace.completions
          .where((e) => e['local_id'] == reviewed.localId)
          .single;
      final audioSaved = await api.summary(audioNotice['summary_id'] as String);
      expect(audioSaved.transcriptId, sourceId);
      expect(audioSaved.title, 'QA reviewed audio $stamp');
      result['summary_ids'] = [
        ...(result['summary_ids'] as List),
        audioSaved.id,
      ];
      result['real_review_confirm'] = true;
      result['cancel_replay_resumed_new_template'] = true;
      result['asr_source_and_attempts_unchanged'] = true;
      result['committed_ack_losses'] = lost.toList()..sort();
      result['exact_replays'] = replayed.toList()..sort();
      expect(replayed, contains('cancel'));
      // Real automatic repair through a legitimate missing target folder:
      // retain ASR source, change only explicit target/options, replay retry.
      final vanished = await api.createFolder('QA disappearing target $stamp');
      final repair = await workspace.create(
        LocalDraftKind.audio,
        input: LocalDraftInput(
          title: 'QA pipeline repair $stamp',
          folderIds: [vanished.id],
          options: options,
          processingMode: 'automatic',
        ),
      );
      created.add(repair.localId);
      await workspace.withOwner((repo, lease) async {
        final file = File(
          '${repo.draftDirectory(repair.localId).path}/source.pcm',
        );
        for (var offset = 0; offset < pcm.length; offset += 65536) {
          final end = (offset + 65536).clamp(0, pcm.length);
          await lease.serialized(
            () => lease.appendPcm(
              file,
              offset,
              Uint8List.sublistView(pcm, offset, end),
            ),
          );
        }
        final journal = QueueJournal(repo, repair.localId);
        final request = await journal.freeze(
          'audio-create',
          'POST',
          'audio-sessions',
          {...draftParameters(repair.input), 'processing_mode': 'automatic'},
        );
        final receipt = await transport.frozen(request);
        await journal.receipt(
          'audio-create',
          receipt,
          ids: {'audio_session_id': receipt['id']},
        );
        await journal.status(
          'uploading',
          fields: {'requested': true},
          state: 'ready',
        );
      });
      await api.deleteFolder(vanished.id);
      var needsRepair = await awaitStage(repair.localId, 'needs_action');
      expect(draftQueue(needsRepair)['error_code'], 'folders_unavailable');
      final repairSource = needsRepair.serverIds['transcript_id'] as String;
      final repairSession = needsRepair.serverIds['audio_session_id'] as String;
      final beforeRepair = await transport.json(
        'GET',
        'audio-sessions/$repairSession',
      );
      final oldAttempts = [
        for (final c in beforeRepair['chunks'] as List) (c as Json)['attempt'],
      ];
      needsRepair = await workspace.save(
        needsRepair.localId,
        revision: needsRepair.revision,
        input: LocalDraftInput(
          title: needsRepair.input.title,
          text: needsRepair.input.text,
          folderIds: [folder.id],
          options: options,
          processingMode: 'automatic',
        ),
        autoStart: false,
      );
      await workspace.queueAction(needsRepair.localId, 'retry', repair: true);
      final repairTime = Stopwatch()..start();
      while (repairTime.elapsed < const Duration(minutes: 6)) {
        await cycle();
        if (workspace.completions.any((e) => e['local_id'] == repair.localId)) {
          break;
        }
        final current = await workspace.reader.read(repair.localId);
        if ([
          'needs_action',
          'auth_blocked',
          'remote_unavailable',
        ].contains(draftQueue(current)['stage'])) {
          throw StateError(
            'Repair failed: ${draftQueue(current)['error_code']}',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      final repairNotice = workspace.completions
          .where((e) => e['local_id'] == repair.localId)
          .single;
      final repairedSummary = await api.summary(
        repairNotice['summary_id'] as String,
      );
      expect(repairedSummary.transcriptId, repairSource);
      expect(repairedSummary.folderIds, [folder.id]);
      final afterRepair = await transport.json(
        'GET',
        'audio-sessions/$repairSession',
      );
      expect([
        for (final c in afterRepair['chunks'] as List) (c as Json)['attempt'],
      ], oldAttempts);
      result['summary_ids'] = [
        ...(result['summary_ids'] as List),
        repairedSummary.id,
      ];
      result['real_pipeline_repair_same_source'] = true;
      result['committed_ack_losses'] = lost.toList()..sort();
      result['exact_replays'] = replayed.toList()..sort();
      expect(replayed, contains('pipeline-retry'));
      final allSaved = await api.summaries(folder.id);
      expect(
        allSaved.items.map((e) => e.id).toSet(),
        (result['summary_ids'] as List).toSet(),
      );
      result['no_duplicate_summaries'] = true;
      // Real review partial session deletion: no complete/Qwen needed.
      final review = await workspace.create(
        LocalDraftKind.audio,
        input: LocalDraftInput(title: 'QA discard $stamp'),
      );
      created.add(review.localId);
      await workspace.withOwner((repo, _) async {
        final journal = QueueJournal(repo, review.localId);
        final request = await journal.freeze(
          'audio-create',
          'POST',
          'audio-sessions',
          {...draftParameters(review.input), 'processing_mode': 'review'},
        );
        final receipt = await transport.frozen(request);
        await journal.receipt(
          'audio-create',
          receipt,
          ids: {'audio_session_id': receipt['id']},
        );
        await journal.status(
          'paused',
          fields: {'paused': true},
          state: 'ready',
        );
      });
      await workspace.queueAction(review.localId, 'delete');
      await cycle();
      expect(
        await workspace.reader.draftDirectory(review.localId).exists(),
        isFalse,
      );
      result['review_discard204'] = true;
      result['passed'] = true;
      await checkpoint();
    } finally {
      // Only own QA summaries/folder; keep source proof on unexpected failure.
      for (final id in (result['summary_ids'] as List).cast<String>()) {
        try {
          await api.deleteSummary(id);
          try {
            await api.summary(id);
            throw StateError('Own QA summary still exists');
          } on ApiException catch (error) {
            if (error.statusCode != 404) rethrow;
          }
        } catch (_) {
          result['cleanup_failed'] = true;
        }
      }
      if (folderId != null && result['passed'] == true) {
        try {
          await api.deleteFolder(folderId);
        } catch (_) {
          result['cleanup_failed'] = true;
        }
      }
      result['cleanup_confirmed'] = result['cleanup_failed'] != true;
      result['host_temp'] = root.path;
      await checkpoint();
      await workspace.drain();
      workspace.dispose();
      cancel.stop();
      api.close();
      if (result['passed'] == true && result['cleanup_failed'] != true) {
        await root.delete(recursive: true);
      }
    }
  }, timeout: const Timeout(Duration(minutes: 16)));
}

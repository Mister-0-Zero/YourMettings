import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/api/demo_connection.dart';
import 'package:your_mettings/features/selections/selection_controller.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/models/processing_options.dart';
import 'package:your_mettings/services/demo_key_vault.dart';
import 'package:your_mettings/services/drafts/draft_record.dart';
import 'package:your_mettings/services/drafts/draft_selection_store.dart';
import 'package:your_mettings/services/drafts/queue_journal.dart';
import 'package:your_mettings/services/drafts/queue_runner.dart';
import 'package:your_mettings/services/drafts/queue_transport.dart';

import 'support/draft_test_fixture.dart';

class _Vault implements DemoKeyVault {
  @override
  Future<String?> read(String origin) async => 'synthetic-test';
  @override
  Future<void> write(String origin, String key) async {}
}

class _Backend {
  final sessions = <String, Json>{}, keys = <String, String>{};
  final calls = <http.Request>[];
  bool loseCancel = false, lostCancel = false, rejectSource = false;
  String? audioSha;
  Json? saved;
  int textSources = 0;
  Future<http.Response> send(http.Request request) async {
    calls.add(request);
    final path = request.url.path.replaceFirst('/api/v1/', '').split('/');
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(request.body) as Json;
    Json response;
    if (path.join('/') == 'auth/me') {
      response = {'id': 'known-account', 'access_mode': 'demo'};
    } else if (path.first == 'audio-sessions') {
      response = {
        'id': 'audio-1',
        'status': 'ready_for_review',
        'pipeline': null,
        'transcript_id': 'audio-transcript',
        'transcript_sha256': audioSha ?? 'review-sha',
        'boundary_warnings': [],
      };
    } else if (path.first == 'transcripts') {
      response = {
        'id': 'audio-transcript',
        'text': 'Audio source kept across selections.',
      };
    } else if (path.first == 'summaries') {
      response = saved!;
    } else if (path.first == 'summary-selections' &&
        path.length == 1 &&
        request.method == 'POST') {
      if (rejectSource) {
        return http.Response('{"error":{"code":"confirmation_required"}}', 422);
      }
      if (body.containsKey('audio_session_id')) {
        if (body['confirm'] != true ||
            body['reviewed_text_sha256'] != 'review-sha') {
          return http.Response(
            '{"error":{"code":"confirmation_required"}}',
            422,
          );
        }
      }
      final key = request.headers['Idempotency-Key']!;
      final id = keys.putIfAbsent(key, () => 'selection-${keys.length + 1}');
      response = sessions.putIfAbsent(
        id,
        () => {
          'id': id,
          'status': 'open',
          'transcript_id': body.containsKey('audio_session_id')
              ? 'audio-transcript'
              : body['transcript_id'] ?? 'text-${++textSources}',
          'summary_version': null,
          'expires_at': '2026-11-02T00:00:00Z',
          'candidates': <Json>[],
        },
      );
    } else if (path.first == 'summary-selections' &&
        path.length == 2 &&
        request.method == 'GET') {
      response = sessions[path[1]]!;
    } else if (path.first == 'summary-selections' &&
        path.length == 2 &&
        request.method == 'DELETE') {
      expect(request.url.queryParameters, {'confirm': 'true'});
      sessions[path[1]]!['status'] = 'cancelled';
      if (loseCancel && !lostCancel) {
        lostCancel = true;
        throw http.ClientException('cancel204 lost');
      }
      return http.Response('', 204);
    } else if (path.first == 'summary-selections' &&
        path.last == 'candidates') {
      final session = sessions[path[1]]!;
      final candidates = session['candidates'] as List;
      if (candidates.isEmpty) {
        candidates.add({
          'id': 'candidate-${path[1]}',
          'status': 'ready',
          'content': '# Synthetic task',
          'template_snapshot': {},
          'generation_options': body,
          'navigation': [],
        });
      }
      response = candidates.single as Json;
    } else if (path.first == 'summary-selections' && path.last == 'accept') {
      final source = sessions[path[1]]!;
      saved = {
        'id': 'saved-summary',
        'transcript_id': source['transcript_id'],
        'title': body['title'] ?? 'Synthetic title',
        'content': body['content'] ?? '# Kept',
        'folder_ids': ['folder-1'],
        'created_at': '2026-11-01T00:00:00Z',
        'updated_at': '2026-11-01T00:00:00Z',
        'version': 'v1',
        'navigation': [],
      };
      response = saved!;
    } else {
      throw StateError('Unexpected ${request.method} ${request.url.path}');
    }
    return http.Response(jsonEncode(response), 200);
  }
}

void main() {
  late DraftTestFixture f;
  late DemoConnection binding;
  setUp(() async {
    f = await DraftTestFixture.create();
    await f.workspace.initialize();
    binding = DemoConnection(
      base: f.connection.base,
      accountId: 'known-account',
      accessMode: 'demo',
      vault: _Vault(),
    );
  });
  tearDown(() async => f.close());
  DraftQueueRunner run(_Backend b) => DraftQueueRunner(
    directory: f.workspace.directory,
    connection: binding,
    acquireOwner: f.pool.acquire,
    capturePending: () async => false,
    isActive: () async => true,
    clientFactory: () => MockClient(b.send),
  );
  Future<void> controller(
    String id,
    _Backend backend,
    Future<void> Function(SelectionController) action,
  ) async {
    await f.workspace.withOwner((repo, _) async {
      final store = DraftSelectionStore(QueueJournal(repo, id));
      await store.load();
      final cancel = QueueCancellation(),
          transport = QueueTransport(
            binding,
            QueueCancellation(),
            inner: MockClient(backend.send),
          );
      final c = SelectionController(
        api: ApiClient(
          binding.base,
          client: transport.client,
          operations: store,
        ),
        store: store,
        slot: store.selectionSlot,
        source: () async => throw StateError('Recover only'),
        initialOptions: const ProcessingOptions(),
        autoPoll: false,
      );
      try {
        await c.initialize();
        await action(c);
      } finally {
        c.dispose();
        cancel.stop();
        transport.close();
        await c.drain();
        store.dispose();
      }
    });
  }

  Future<LocalDraftRecord> audio({bool reviewed = false}) async {
    final r = await f.workspace.create(
      LocalDraftKind.audio,
      input: LocalDraftInput(
        title: 'Synthetic title',
        text: 'Audio source kept across selections.',
        folderIds: ['folder-1'],
      ),
    );
    return f.workspace.withOwner(
      (repo, _) => repo.update(
        r.localId,
        expectedRevision: r.revision,
        change: (j) {
          j['state'] = 'processing';
          (j['requests'] as Json)['audio-create'] = FrozenDraftRequest(
            method: 'POST',
            path: 'audio-sessions',
            key: 'audio-key',
            body: {...draftParameters(r.input), 'processing_mode': 'review'},
          ).toJson();
          (j['receipts'] as Json).addAll({
            'audio-create': {'id': 'audio-1'},
            'audio-complete': {'id': 'audio-1'},
          });
          (j['server_ids'] as Json).addAll({
            'audio_session_id': 'audio-1',
            'transcript_id': 'audio-transcript',
          });
          (j['checkpoints'] as Json).addAll({
            'review_source': {
              'text': r.input.text,
              'sha256': 'review-sha',
              'boundary_warnings': [],
            },
            'queue': {
              'requested': true,
              'review_confirmed': reviewed,
              'boundaries_reviewed': reviewed,
              'reviewed_sha256': 'review-sha',
            },
          });
        },
      ),
    );
  }

  test('audio review source requires actual consent and sends confirm:true only after explicit review', () async {
    final b = _Backend();
    final r = await audio();
    await run(b).run();
    expect(b.calls.where((r) => r.method == 'POST'), isEmpty);
    expect(
      draftQueue(await f.workspace.reader.read(r.localId))['stage'],
      'review_required',
    );
    await f.workspace.queueAction(r.localId, 'start', boundariesReviewed: true);
    await run(b).run();
    final source = b.calls
        .where(
          (r) =>
              r.method == 'POST' && r.url.path.endsWith('/summary-selections'),
        )
        .single;
    expect(jsonDecode(source.body), {
      'audio_session_id': 'audio-1',
      'confirm': true,
      'reviewed_text_sha256': 'review-sha',
      'boundaries_reviewed': true,
      'title': 'Synthetic title',
      'folder_ids': ['folder-1'],
    });
    expect(
      draftQueue(await f.workspace.reader.read(r.localId))['stage'],
      'manual_ready',
    );
  });
  for (final audioSource in [false, true]) {
    test(
      'confirmed cancel resumes namespaced choice, lost204 replay and preserved source; audio=$audioSource',
      () async {
        final b = _Backend()..loseCancel = true;
        final r = audioSource
            ? await audio(reviewed: true)
            : await f.workspace.create(
                LocalDraftKind.text,
                input: LocalDraftInput(
                  title: 'Synthetic title',
                  text: 'Text source stays local after cancelling temporary server copy.',
                  folderIds: ['folder-1'],
                ),
              );
        if (!audioSource) await f.workspace.queueAction(r.localId, 'start');
        await run(b).run();
        final first = await f.workspace.reader.read(r.localId),
            firstSource = first.serverIds['transcript_id'];
        await controller(r.localId, b, (c) async {
          expect(await c.cancel(), isFalse);
        });
        final pending = await f.workspace.reader.read(r.localId);
        expect(
          ((pending.toJson()['checkpoints'] as Json)['selection']
              as Json)['cancel_pending'],
          isTrue,
        );
        await run(b).run();
        final cancelled = await f.workspace.reader.read(r.localId);
        expect(
          (cancelled.toJson()['checkpoints'] as Json)['selection'],
          isNull,
        );
        expect(draftQueue(cancelled)['stage'], 'paused');
        await f.workspace.queueAction(
          r.localId,
          'start',
          boundariesReviewed: true,
        );
        await run(b).run();
        final second = await f.workspace.reader.read(r.localId);
        expect(
          second.requests.keys.where((s) => s.startsWith('selection-create')),
          hasLength(2),
        );
        expect(
          second.serverIds['selection_id'],
          isNot(first.serverIds['selection_id']),
        );
        if (audioSource) {
          expect(second.serverIds['transcript_id'], firstSource);
          expect(b.textSources, 0);
        } else {
          expect(b.textSources, 2);
          expect(second.input.text, first.input.text);
        }
        await controller(r.localId, b, (c) async {
          await c.editActive(title: 'Final choice', content: '# User edit');
          await c.accept();
        });
        await run(b).run();
        expect(
          await f.workspace.reader.draftDirectory(r.localId).exists(),
          isFalse,
        );
        expect(b.saved!['title'], 'Final choice');
        expect(b.keys, hasLength(2));
        expect(b.calls.where((r) => r.method == 'DELETE'), hasLength(2));
        expect(
          b.calls.where(
            (r) =>
                r.url.path.endsWith('/chunks') ||
                r.url.path.endsWith('/complete'),
          ),
          isEmpty,
        );
      },
    );
  }
  test('definite invalid audio source can be repaired with new intent only after persisted rejection proof', () async {
    final b = _Backend()..rejectSource = true;
    final r = await audio(reviewed: true);
    await run(b).run();
    final rejected = await f.workspace.reader.read(r.localId);
    expect(draftQueue(rejected)['selection_source_rejected'], isTrue);
    final original = rejected.requests.entries
        .where((e) => e.key.startsWith('selection-create'))
        .single;
    b.rejectSource = false;
    await f.workspace.queueAction(r.localId, 'start', boundariesReviewed: true);
    await run(b).run();
    final repaired = await f.workspace.reader.read(r.localId);
    expect(
      repaired.requests[original.key]!.encodedBody,
      original.value.encodedBody,
    );
    expect(
      repaired.requests.keys.where((e) => e.startsWith('selection-create')),
      hasLength(2),
    );
    expect(repaired.serverIds['audio_session_id'], 'audio-1');
    expect(draftQueue(repaired)['stage'], 'manual_ready');
  });
}

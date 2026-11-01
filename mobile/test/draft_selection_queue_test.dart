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
import 'package:your_mettings/services/drafts/queue_scheduler.dart';
import 'package:your_mettings/services/drafts/queue_transport.dart';

import 'support/draft_test_fixture.dart';

class _Vault implements DemoKeyVault {
  @override
  Future<String?> read(String origin) async => 'synthetic-test-key';
  @override
  Future<void> write(String origin, String key) async {}
}

class _SelectionBackend {
  final calls = <http.Request>[];
  final lose = <String>{}, lost = <String>{};
  final candidates = <Json>[];
  Json? saved;
  bool candidateError = false;
  Json session() => {
    'id': 'selection-1',
    'transcript_id': 'transcript-1',
    'summary_version': null,
    'status': saved == null ? 'open' : 'accepted',
    'accepted_candidate_id': saved == null ? null : 'candidate-1',
    'expires_at': '2026-11-02T00:00:00Z',
    'candidates': candidates,
  };
  Future<http.Response> response(http.Request request) async {
    calls.add(request);
    final route =
        '${request.method} ${request.url.path.replaceFirst('/api/v1/', '')}';
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(request.body) as Json;
    Json result;
    switch (route) {
      case 'GET auth/me':
        result = {'id': 'known-account', 'access_mode': 'demo'};
      case 'POST summary-selections':
        result = session();
      case 'GET summary-selections/selection-1':
        result = session();
      case 'POST summary-selections/selection-1/candidates':
        if (candidates.isEmpty) {
          candidates.add({
            'id': 'candidate-1',
            'selection_id': 'selection-1',
            'status': candidateError ? 'error' : 'ready',
            'error': candidateError
                ? {
                    'code': 'llm_unavailable',
                    'message': 'Synthetic model unavailable',
                  }
                : null,
            'content': '# Plan\n\n**Owner:** Alexey; due Friday.',
            'template_snapshot': {},
            'generation_options': body,
            'navigation': [],
          });
        }
        result = candidates.single;
      case 'POST summary-selections/selection-1/accept':
        saved ??= {
          'id': 'summary-1',
          'transcript_id': 'transcript-1',
          'title': body['title'] ?? 'Synthetic meeting',
          'content': body['content'] ?? candidates.single['content'],
          'folder_ids': ['folder-1'],
          'created_at': '2026-11-01T00:00:00Z',
          'updated_at': '2026-11-01T00:00:00Z',
          'version': 'v1',
          'template_snapshot': {},
          'generation_options': {},
          'navigation': [],
        };
        result = saved!;
      case 'GET summaries/summary-1':
        result = saved!;
      default:
        throw StateError(route);
    }
    if (lose.contains(route) && lost.add(route)) {
      throw http.ClientException('ACK lost after commit');
    }
    return http.Response(jsonEncode(result), 200);
  }
}

void main() {
  late DraftTestFixture f;
  late DemoConnection binding;
  late DateTime now;
  setUp(() async {
    f = await DraftTestFixture.create();
    await f.workspace.initialize();
    now = DateTime.utc(2026, 11, 1);
    binding = DemoConnection(
      base: f.connection.base,
      accountId: 'known-account',
      accessMode: 'demo',
      vault: _Vault(),
    );
  });
  tearDown(() async {
    await f.close();
  });
  DraftQueueRunner runner(_SelectionBackend b) => DraftQueueRunner(
    directory: f.workspace.directory,
    connection: binding,
    acquireOwner: f.pool.acquire,
    clientFactory: () => MockClient(b.response),
    isActive: () async => true,
    capturePending: () async => false,
    policy: QueueRetryPolicy(now: () => now, jitter: () => 0.5),
  );
  Future<LocalDraftRecord> draft() async {
    final r = await f.workspace.create(
      LocalDraftKind.text,
      input: LocalDraftInput(
        title: 'Synthetic meeting',
        text: 'Synthetic transcript with decisions and tasks.',
        folderIds: ['folder-1'],
      ),
    );
    await f.workspace.queueAction(r.localId, 'start');
    return r;
  }

  for (final lostStep in [
    'POST summary-selections',
    'POST summary-selections/selection-1/candidates',
  ]) {
    test(
      'manual $lostStep lost ACK replays frozen source/key without automatic acceptance',
      () async {
        final r = await draft();
        final b = _SelectionBackend()..lose.add(lostStep);
        await runner(b).run();
        now = now.add(const Duration(minutes: 20));
        await runner(b).run();
        final stored = await f.workspace.reader.read(r.localId);
        expect(draftQueue(stored)['stage'], 'manual_ready');
        expect(b.saved, isNull);
        final repeated = b.calls
            .where(
              (r) =>
                  '${r.method} ${r.url.path.replaceFirst('/api/v1/', '')}' ==
                  lostStep,
            )
            .toList();
        expect(repeated, hasLength(2));
        expect(repeated.first.body, repeated.last.body);
        expect(
          repeated.first.headers['Idempotency-Key'],
          repeated.last.headers['Idempotency-Key'],
        );
        expect(stored.serverIds['transcript_id'], 'transcript-1');
        expect(stored.serverIds['selection_id'], 'selection-1');
        expect(
          stored.requests.keys.any((s) => s.startsWith('candidate:')),
          isTrue,
        );
      },
    );
  }
  test('manual edited atomic accept lost ACK resumes same choice, saves one summary and cleans only after receipt', () async {
    final r = await draft();
    final b = _SelectionBackend();
    await runner(b).run();
    b.lose.add('POST summary-selections/selection-1/accept');
    await f.workspace.withOwner((repo, _) async {
      final journal = QueueJournal(repo, r.localId),
          cancel = QueueCancellation();
      final store = DraftSelectionStore(journal);
      await store.load();
      final transport = QueueTransport(
        binding,
        cancel,
        inner: MockClient(b.response),
      );
      final api = ApiClient(
        binding.base,
        client: transport.client,
        operations: store,
      );
      final c = SelectionController(
        api: api,
        store: store,
        slot: store.selectionSlot,
        source: () async => throw StateError('Must recover'),
        initialOptions: const ProcessingOptions(),
        autoPoll: false,
      );
      await c.initialize();
      await c.editActive(
        title: 'Reviewed title',
        content: '# Edited\n\n**Task:** deliver by Friday.',
      );
      await c.accept();
      await c.drain();
      final frozen = await journal.read();
      expect(frozen.serverIds.containsKey('summary_id'), isFalse);
      expect(
        frozen.requests['selection-accept']!.body['content'],
        '# Edited\n\n**Task:** deliver by Friday.',
      );
      expect(
        ((frozen.toJson()['checkpoints'] as Json)['selection']
            as Json)['accept_id'],
        'candidate-1',
      );
      c.dispose();
      cancel.stop();
      transport.close();
      store.dispose();
    });
    await runner(b).run();
    final accept = b.calls
        .where((r) => r.url.path.endsWith('/accept'))
        .toList();
    expect(accept, hasLength(2));
    expect(accept.first.body, accept.last.body);
    expect(b.saved!['title'], 'Reviewed title');
    expect(b.saved!['content'], '# Edited\n\n**Task:** deliver by Friday.');
    expect(
      await f.workspace.reader.draftDirectory(r.localId).exists(),
      isFalse,
    );
    expect(
      b.calls.where(
        (r) => r.method == 'POST' && r.url.path.endsWith('/candidates'),
      ),
      hasLength(1),
    );
  });
  test('summary ID and receipt survive failed completion callback, next run does not accept again', () async {
    final r = await draft();
    final b = _SelectionBackend();
    await runner(b).run();
    await f.workspace.withOwner((repo, _) async {
      final store = DraftSelectionStore(QueueJournal(repo, r.localId));
      await store.load();
      final transport = QueueTransport(
        binding,
        QueueCancellation(),
        inner: MockClient(b.response),
      );
      final c = SelectionController(
        api: ApiClient(
          binding.base,
          client: transport.client,
          operations: store,
        ),
        store: store,
        slot: store.selectionSlot,
        source: () async => {},
        initialOptions: const ProcessingOptions(),
        autoPoll: false,
      );
      await c.initialize();
      await c.accept();
      final accepted = await repo.read(r.localId);
      expect(accepted.serverIds['summary_id'], 'summary-1');
      expect(
        (accepted.toJson()['receipts'] as Json)['selection-accept'],
        isNotNull,
      );
      // c.complete has not run: process could die before callback/route closure.
      c.dispose();
      transport.close();
      store.dispose();
    });
    await runner(b).run();
    expect(b.calls.where((r) => r.url.path.endsWith('/accept')), hasLength(1));
    expect(
      await f.workspace.reader.draftDirectory(r.localId).exists(),
      isFalse,
    );
  });
  test('scheduler ignores blocked/legacy/plain drafts, persists due time and active binding guards', () async {
    final r = await draft();
    await f.workspace.withOwner(
      (repo, _) => QueueJournal(repo, r.localId).status(
        'retry_wait',
        fields: {
          'next_attempt_at': now
              .add(const Duration(seconds: 85))
              .toIso8601String(),
        },
      ),
    );
    expect(
      await nextQueueDelay(f.workspace.directory, binding.scopeId, now: now),
      const Duration(seconds: 85),
    );
    await f.workspace.withOwner(
      (repo, _) => QueueJournal(
        repo,
        r.localId,
      ).status('auth_blocked', fields: {'next_attempt_at': null}),
    );
    expect(
      await nextQueueDelay(f.workspace.directory, binding.scopeId, now: now),
      isNull,
    );
    expect(await activeQueueScope(f.workspace.directory, binding), isFalse);
  });
  test('terminal candidate error stops polling until explicit retry, never sends text/process', () async {
    final r = await draft();
    final b = _SelectionBackend()..candidateError = true;
    await runner(b).run();
    final first = b.calls.length;
    expect(
      draftQueue(await f.workspace.reader.read(r.localId))['stage'],
      'needs_action',
    );
    now = now.add(const Duration(hours: 1));
    await runner(b).run();
    expect(b.calls.length, first);
    b.candidateError = false;
    b.candidates.clear();
    await f.workspace.queueAction(r.localId, 'retry');
    await runner(b).run();
    expect(
      draftQueue(await f.workspace.reader.read(r.localId))['stage'],
      'manual_ready',
    );
    expect(
      b.calls.any((r) => r.url.path.endsWith('/transcripts/process')),
      isFalse,
    );
    expect(
      b.calls.where(
        (r) => r.method == 'POST' && r.url.path.endsWith('/summary-selections'),
      ),
      hasLength(1),
    );
    expect(
      b.calls.where(
        (r) => r.method == 'POST' && r.url.path.endsWith('/candidates'),
      ),
      hasLength(2),
    );
  });
  test('candidate version is checked before freezing once; lostACK exact replay uses real CandidateInput fields', () async {
    final b = _SelectionBackend()
      ..lose.add('POST summary-selections/selection-1/candidates');
    var version = 'a' * 64, lookups = 0;
    Future<http.Response> response(http.Request request) async {
      if (request.url.path.endsWith('/summary-templates/template-1')) {
        lookups++;
        return http.Response(
          jsonEncode({
            'id': 'template-1',
            'name': 'Synthetic template',
            'sections': <dynamic>[],
            'is_system': true,
            'is_default': true,
            'version': version,
          }),
          200,
        );
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/candidates')) {
        final body = jsonDecode(request.body) as Json;
        expect(body.keys.toSet(), {
          'detail_level',
          'focus_areas',
          'additional_instructions',
          'template_id',
        });
      }
      return b.response(request);
    }

    final r = await f.workspace.create(
      LocalDraftKind.text,
      input: LocalDraftInput(
        title: 'Version check',
        text: 'Synthetic text',
        folderIds: ['folder-1'],
        options: {
          'template_id': 'template-1',
          'expected_template_version': version,
        },
      ),
    );
    await f.workspace.queueAction(r.localId, 'start');
    DraftQueueRunner live() => DraftQueueRunner(
      directory: f.workspace.directory,
      connection: binding,
      acquireOwner: f.pool.acquire,
      capturePending: () async => false,
      isActive: () async => true,
      clientFactory: () => MockClient(response),
      policy: QueueRetryPolicy(now: () => now, jitter: () => 0.5),
    );
    await live().run();
    expect(lookups, 1);
    version = 'b' * 64;
    now = now.add(const Duration(minutes: 20));
    await live().run();
    expect(lookups, 1);
    expect(
      draftQueue(await f.workspace.reader.read(r.localId))['stage'],
      'manual_ready',
    );
    final requests = (await f.workspace.reader.read(r.localId)).requests.values
        .where((r) => r.path.endsWith('/candidates'));
    expect(
      requests.single.body.containsKey('expected_template_version'),
      isFalse,
    );
  });
}

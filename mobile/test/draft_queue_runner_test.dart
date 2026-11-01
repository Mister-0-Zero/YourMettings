import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_error.dart';
import 'package:your_mettings/api/demo_connection.dart';
import 'package:your_mettings/services/demo_key_vault.dart';
import 'package:your_mettings/services/drafts/draft_record.dart';
import 'package:your_mettings/services/drafts/queue_journal.dart';
import 'package:your_mettings/services/drafts/queue_runner.dart';
import 'package:your_mettings/services/drafts/queue_transport.dart';

import 'support/draft_test_fixture.dart';

class _Vault implements DemoKeyVault {
  @override
  Future<String?> read(String origin) async => 'synthetic-test-key';
  @override
  Future<void> write(String origin, String key) async {}
}

class _Backend {
  final calls = <http.Request>[];
  final lose = <String>{};
  final alreadyLost = <String>{};
  JsonMap parameters = {};
  JsonMap? chunk;
  bool complete = false;
  String? get overrideError => null;
  Future<http.Response> response(http.Request request) async {
    calls.add(request);
    final path = request.url.path.replaceFirst('/api/v1/', '');
    final route = '${request.method} $path';
    final body =
        request.bodyBytes.isEmpty ||
            request.headers['content-type'] == 'application/octet-stream'
        ? <String, dynamic>{}
        : jsonDecode(request.body) as JsonMap;
    JsonMap result;
    if (path == 'auth/me') {
      result = {'id': 'known-account', 'access_mode': 'demo'};
    } else if (route == 'POST audio-sessions') {
      parameters = body;
      result = session();
    } else if (route == 'PUT audio-sessions/audio-1/pipeline/parameters') {
      parameters = {...body, 'processing_mode': 'automatic'};
      result = session();
    } else if (route == 'POST audio-sessions/audio-1/chunks') {
      chunk = {
        'id': 'chunk-0',
        'sequence_number': int.parse(
          request.url.queryParameters['sequence_number']!,
        ),
        'sha256': request.url.queryParameters['content_sha256'],
        'byte_count': request.bodyBytes.length,
      };
      result = {'accepted': true, 'safe_to_delete_local': true, 'chunk': chunk};
    } else if (route == 'POST audio-sessions/audio-1/complete') {
      complete = true;
      result = session();
    } else if (route == 'GET audio-sessions/audio-1') {
      result = session();
    } else if (route == 'GET summaries/summary-1') {
      result = {
        'id': 'summary-1',
        'transcript_id': 'transcript-1',
        'title': parameters['title'],
      };
    } else if (route == 'POST transcripts/process') {
      parameters = body;
      result = {
        'transcript_id': 'transcript-1',
        'status': 'summarizing',
        'summary_id': null,
      };
    } else if (route == 'GET transcripts/transcript-1/processing') {
      result = {
        'transcript_id': 'transcript-1',
        'status': 'ready',
        'summary_id': 'summary-1',
      };
    } else {
      throw StateError('Unexpected $route');
    }
    if (lose.contains(route) && alreadyLost.add(route)) {
      throw http.ClientException('ACK lost after server commit');
    }
    return http.Response(jsonEncode(result), 200);
  }

  JsonMap session() => {
    'id': 'audio-1',
    'status': complete ? 'completed' : 'recording',
    'transcript_id': complete ? 'transcript-1' : null,
    'parameters': parameters,
    'pipeline': {
      'mode': 'automatic',
      'phase': complete ? 'completed' : 'receiving',
      'summary_id': complete ? 'summary-1' : null,
    },
    'chunk_target_seconds': 300,
    'max_chunk_seconds': 360,
    'max_upload_bytes': 33554432,
    'max_chunks': 240,
  };
}

typedef JsonMap = Map<String, dynamic>;

void main() {
  late DraftTestFixture f;
  late DemoConnection binding;
  late DateTime now;
  setUp(() async {
    f = await DraftTestFixture.create(
      acquireTimeout: const Duration(seconds: 3),
    );
    await f.workspace.initialize();
    binding = DemoConnection(
      base: f.connection.base,
      accountId: f.connection.accountId,
      accessMode: 'demo',
      vault: _Vault(),
    );
    now = DateTime.utc(2026, 11, 1, 16);
  });
  tearDown(() async {
    await f.close();
  });
  DraftQueueRunner runner(
    Future<http.Response> Function(http.Request) handler, {
    Future<bool> Function()? active,
  }) => DraftQueueRunner(
    directory: f.workspace.directory,
    connection: binding,
    acquireOwner: f.pool.acquire,
    clientFactory: () => MockClient(handler),
    isActive: active ?? () async => true,
    capturePending: () async => false,
    policy: QueueRetryPolicy(now: () => now, jitter: () => 0.5),
  );
  Future<LocalDraftRecord> draft({
    LocalDraftKind kind = LocalDraftKind.audio,
    bool requested = true,
    bool autoStart = false,
    String mode = 'automatic',
  }) async {
    var r = await f.workspace.create(
      kind,
      input: LocalDraftInput(
        title: 'Original',
        text: kind == LocalDraftKind.text ? 'A synthetic meeting.' : '',
        folderIds: ['folder-1'],
        processingMode: mode,
      ),
    );
    r = await f.workspace.withOwner((repo, lease) async {
      if (kind == LocalDraftKind.audio) {
        final file = File('${repo.draftDirectory(r.localId).path}/source.pcm');
        await lease.serialized(
          () => lease.appendPcm(file, 0, Uint8List(32000)),
        );
      }
      return repo.update(
        r.localId,
        expectedRevision: r.revision,
        change: (j) {
          j['state'] = kind == LocalDraftKind.audio ? 'ready' : 'draft';
          j['auto_start_when_online'] = autoStart;
          (j['checkpoints'] as JsonMap)['queue'] = {'requested': requested};
        },
      );
    });
    return r;
  }

  Future<void> edit(String id, String title) async {
    final r = await f.workspace.reader.read(id);
    await f.workspace.save(
      id,
      revision: r.revision,
      input: LocalDraftInput(
        title: title,
        text: r.input.text,
        folderIds: r.input.folderIds,
        options: r.input.options,
        processingMode: r.input.processingMode,
      ),
      autoStart: r.autoStart,
    );
  }

  test('audio lost create/PUT/chunk/complete ACK: exact replay, one source and saved result', () async {
    final b = _Backend()
      ..lose.addAll([
        'POST audio-sessions',
        'PUT audio-sessions/audio-1/pipeline/parameters',
        'POST audio-sessions/audio-1/chunks',
        'POST audio-sessions/audio-1/complete',
      ]);
    final r = await draft();
    await runner(b.response).run();
    expect((await f.workspace.reader.read(r.localId)).serverIds, isEmpty);
    await edit(r.localId, 'Changed after lost ACK');
    for (var i = 0; i < 5; i++) {
      now = now.add(const Duration(minutes: 20));
      await runner(b.response).run();
    }
    final create = b.calls
        .where(
          (r) => r.method == 'POST' && r.url.path.endsWith('/audio-sessions'),
        )
        .toList();
    expect(create, hasLength(2));
    expect(create[0].body, create[1].body);
    expect(
      create[0].headers['Idempotency-Key'],
      create[1].headers['Idempotency-Key'],
    );
    final put = b.calls.where((r) => r.method == 'PUT').toList();
    expect(put, hasLength(2));
    expect(put[0].body, put[1].body);
    expect(jsonDecode(put[0].body)['title'], 'Changed after lost ACK');
    expect(
      put[0].headers['Idempotency-Key'],
      put[1].headers['Idempotency-Key'],
    );
    expect(
      put[0].headers['Idempotency-Key'],
      isNot(create[0].headers['Idempotency-Key']),
    );
    final chunks = b.calls
        .where((r) => r.url.path.endsWith('/chunks'))
        .toList();
    expect(chunks, hasLength(2));
    expect(chunks[0].bodyBytes, chunks[1].bodyBytes);
    expect(chunks[0].url, chunks[1].url);
    final complete = b.calls
        .where((r) => r.method == 'POST' && r.url.path.endsWith('/complete'))
        .toList();
    expect(complete, hasLength(2));
    expect(complete[0].body, complete[1].body);
    expect(b.calls.indexOf(put.last), lessThan(b.calls.indexOf(chunks.first)));
    expect(
      await f.workspace.reader.draftDirectory(r.localId).exists(),
      isFalse,
    );
    final notices = jsonDecode(
      await File('${f.workspace.directory.path}/queue-completions.json')
          .readAsString(),
    );
    expect(notices['items'].single['summary_id'], 'summary-1');
  });
  test(
    'atomic complete freezes exact submitted input and intent in one snapshot',
    () async {
      final b = _Backend()..lose.add('POST audio-sessions/audio-1/complete');
      final r = await draft();
      await runner(b.response).run();
      final frozen = await f.workspace.reader.read(r.localId);
      expect(frozen.requests.containsKey('audio-complete'), isTrue);
      expect(draftQueue(frozen)['input_at_boundary'], isNotNull);
      await edit(r.localId, 'Late unsent metadata');
      now = now.add(const Duration(minutes: 20));
      await runner(b.response).run();
      final kept = await f.workspace.reader.read(r.localId);
      expect(draftQueue(kept)['stage'], 'saved_with_changes');
      expect(kept.input.title, 'Late unsent metadata');
      expect(kept.serverIds['summary_id'], 'summary-1');
    },
  );
  test('legacy crash after complete freeze without boundary never erases later edits', () async {
    final b = _Backend()..lose.add('POST audio-sessions/audio-1/complete');
    final r = await draft();
    await runner(b.response).run();
    await f.workspace.withOwner((repo, _) async {
      final current = await repo.read(r.localId);
      await repo.update(
        r.localId,
        expectedRevision: current.revision,
        change: (j) {
          ((j['checkpoints'] as JsonMap)['queue'] as JsonMap).remove(
            'input_at_boundary',
          );
        },
      );
    });
    await edit(r.localId, 'Crash window local edit');
    now = now.add(const Duration(minutes: 20));
    await runner(b.response).run();
    final kept = await f.workspace.reader.read(r.localId);
    expect(draftQueue(kept)['stage'], 'saved_with_changes');
    expect(draftQueue(kept)['input_at_boundary'], isNull);
    expect(kept.input.title, 'Crash window local edit');
  });
  test('definite create validation failure permits explicit new frozen attempt, unknown does not', () async {
    final b = _Backend();
    final r = await draft();
    var rejected = false;
    Future<http.Response> handler(http.Request request) async {
      if (request.url.path.endsWith('/audio-sessions') && !rejected) {
        rejected = true;
        b.calls.add(request);
        return http.Response('{"error":{"code":"validation_error"}}', 422);
      }
      return b.response(request);
    }

    await runner(handler).run();
    final old = (await f.workspace.reader.read(r.localId))
        .requests['audio-create']!;
    await edit(r.localId, 'Corrected metadata');
    await f.workspace.queueAction(r.localId, 'retry');
    await runner(handler).run();
    expect(
      await f.workspace.reader.draftDirectory(r.localId).exists(),
      isFalse,
    );
    final creates = b.calls
        .where(
          (r) => r.method == 'POST' && r.url.path.endsWith('/audio-sessions'),
        )
        .toList();
    expect(creates, hasLength(2));
    expect(creates.last.headers['Idempotency-Key'], isNot(old.key));
    expect(jsonDecode(creates.last.body)['title'], 'Corrected metadata');
  });
  test('text automatic uses process without processing_mode, preserves later local edits', () async {
    final b = _Backend()..lose.add('POST transcripts/process');
    final r = await draft(kind: LocalDraftKind.text);
    await runner(b.response).run();
    await edit(r.localId, 'Unsubmitted edit');
    now = now.add(const Duration(minutes: 20));
    await runner(b.response).run();
    final sent = b.calls.where((r) => r.method == 'POST').toList();
    expect(sent, hasLength(2));
    expect(sent.first.body, sent.last.body);
    expect(jsonDecode(sent.first.body).containsKey('processing_mode'), isFalse);
    final kept = await f.workspace.reader.read(r.localId);
    expect(kept.input.title, 'Unsubmitted edit');
    expect(draftQueue(kept)['stage'], 'saved_with_changes');
    expect(kept.serverIds['summary_id'], 'summary-1');
  });
  test(
    'offline draft without opt-in never sends; opt-in sends independently',
    () async {
      final b = _Backend();
      final local = await draft(requested: false);
      await runner(b.response).run();
      expect(b.calls, isEmpty);
      final opted = await draft(
        kind: LocalDraftKind.text,
        requested: false,
        autoStart: true,
      );
      await runner(b.response).run();
      expect(
        await f.workspace.reader.draftDirectory(opted.localId).exists(),
        isFalse,
      );
      expect(
        await f.workspace.reader.draftDirectory(local.localId).exists(),
        isTrue,
      );
      expect(
        b.calls.any((r) => r.url.path.endsWith('/audio-sessions')),
        isFalse,
      );
    },
  );
  test(
    'failed online-finish check does not submit later without opt-in',
    () async {
      final r = await draft(requested: false);
      await f.workspace.withOwner(
        (repo, _) => QueueJournal(
          repo,
          r.localId,
        ).status('ready', fields: {'online_finish_pending': true}),
      );
      var calls = 0;
      await runner((request) async {
        calls++;
        throw http.ClientException('offline');
      }).run();
      expect(calls, 1);
      now = now.add(const Duration(hours: 1));
      final b = _Backend();
      await runner(b.response).run();
      expect(b.calls, isEmpty);
      expect((await f.workspace.reader.read(r.localId)).requests, isEmpty);
    },
  );
  for (final status in [401, 403, 404, 410, 422, 409]) {
    test(
      '$status blocks repeated delivery until explicit user action',
      () async {
        final r = await draft();
        var calls = 0;
        await runner((request) async {
          calls++;
          return http.Response(
            jsonEncode({
              'error': {'code': 'test_error', 'message': 'test'},
            }),
            status,
          );
        }).run();
        final first = calls;
        now = now.add(const Duration(days: 3));
        await runner((request) async {
          calls++;
          return http.Response('{}', 200);
        }).run();
        expect(calls, first);
        expect(
          await f.workspace.reader.draftDirectory(r.localId).exists(),
          isTrue,
        );
      },
    );
  }
  test(
    '429 persists Retry-After and fake clock prevents premature replay',
    () async {
      final r = await draft();
      var calls = 0;
      final run = runner((request) async {
        calls++;
        return http.Response(
          '{"error":{"code":"busy"}}',
          429,
          headers: {'retry-after': '120'},
        );
      });
      await run.run();
      expect(calls, 1);
      expect(
        DateTime.parse(
          draftQueue(
            await f.workspace.reader.read(r.localId),
          )['next_attempt_at'],
        ),
        now.add(const Duration(seconds: 120)),
      );
      now = now.add(const Duration(seconds: 119));
      await run.run();
      expect(calls, 1);
      now = now.add(const Duration(seconds: 1));
      await run.run();
      expect(calls, 2);
    },
  );
  test('different active scope sends no auth or source HTTP', () async {
    await draft();
    var calls = 0;
    await runner((request) async {
      calls++;
      return http.Response('{}', 200);
    }, active: () async => false).run();
    expect(calls, 0);
    expect(f.pool.held, isEmpty);
  });
  test(
    'hung HTTP yields to second draft; late ACK cannot publish after handoff',
    () async {
      final first = await draft();
      f.pool.cooperativeYield = true;
      final entered = Completer<void>(), late = Completer<http.Response>();
      final run = runner((request) async {
        if (request.url.path.endsWith('/auth/me')) {
          return http.Response(
            '{"id":"known-account","access_mode":"demo"}',
            200,
          );
        }
        entered.complete();
        return late.future;
      });
      final running = run.run();
      await entered.future.timeout(const Duration(seconds: 3));
      final stopwatch = Stopwatch()..start();
      final second = await f.workspace
          .create(LocalDraftKind.audio)
          .timeout(const Duration(seconds: 3));
      await running;
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
      final frozen = await f.workspace.reader.read(first.localId);
      final revision = frozen.revision;
      expect(frozen.requests.containsKey('audio-create'), isTrue);
      expect(frozen.serverIds, isEmpty);
      late.complete(http.Response('{"id":"wrong-late-identity"}', 200));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect((await f.workspace.reader.read(first.localId)).revision, revision);
      expect(second.localId, isNot(first.localId));
      expect(f.pool.held, isEmpty);
    },
  );
  test(
    'cancel transport while response body is hung releases promptly',
    () async {
      final cancel = QueueCancellation();
      final body = StreamController<List<int>>();
      final inner = MockClient.streaming(
        (request, stream) async => http.StreamedResponse(body.stream, 200),
      );
      final transport = QueueTransport(binding, cancel, inner: inner);
      final work = transport.json('GET', 'auth/me');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      cancel.stop();
      await expectLater(work, throwsA(isA<QueueStopped>()));
      await body.close();
      transport.close();
    },
  );
  test('HTTP-date retry and bounded exponential jitter', () {
    final policy = QueueRetryPolicy(now: () => now, jitter: () => 0.5);
    final retry = retryAfterDuration(
      HttpDate.format(now.add(const Duration(minutes: 3))),
      now: now,
    );
    final result = policy.failure(
      ApiException('busy', 'busy', statusCode: 503, retryAfter: retry),
      {'attempt': 100},
    );
    expect(
      DateTime.parse(result['next_attempt_at']),
      now.add(const Duration(seconds: 900)),
    );
    final capped = policy.failure(
      const ApiException(
        'busy',
        'busy',
        statusCode: 429,
        retryAfter: Duration(days: 4),
      ),
      {},
    );
    expect(
      DateTime.parse(capped['next_attempt_at']),
      now.add(const Duration(days: 1)),
    );
  });
  test(
    'frozen DELETE query survives JSON roundtrip and caller map mutation',
    () {
      final flags = {'confirm': 'true', 'discard_unprocessed': 'true'};
      final request = FrozenDraftRequest(
        method: 'DELETE',
        path: 'audio-sessions/a',
        key: 'test',
        body: {},
        query: flags,
      );
      flags['confirm'] = 'false';
      final copy = FrozenDraftRequest.fromJson(
        jsonDecode(jsonEncode(request.toJson())),
      );
      expect(copy.query, {'confirm': 'true', 'discard_unprocessed': 'true'});
    },
  );
  test('automatic cancel after unknown create first binds exact old session, never uploads new chunks', () async {
    final r = await draft();
    final b = _Backend()..lose.add('POST audio-sessions');
    var cancels = 0;
    Future<http.Response> handler(http.Request request) async {
      if (request.url.path.endsWith('/pipeline/cancel')) {
        cancels++;
        expect(jsonDecode(request.body), {'confirm': true});
        return http.Response(
          jsonEncode({
            ...b.session(),
            'pipeline': {'mode': 'automatic', 'phase': 'cancelled'},
          }),
          200,
        );
      }
      return b.response(request);
    }

    await runner(handler).run();
    await f.workspace.queueAction(r.localId, 'cancel');
    await runner(handler).run();
    final kept = await f.workspace.reader.read(r.localId);
    expect(kept.serverIds['audio_session_id'], 'audio-1');
    expect(draftQueue(kept)['stage'], 'cancelled');
    expect(cancels, 1);
    expect(b.calls.any((r) => r.url.path.endsWith('/chunks')), isFalse);
    expect(
      await File(
        '${f.workspace.reader.draftDirectory(r.localId).path}/source.pcm',
      ).exists(),
      isTrue,
    );
  });
  test('automatic DELETE lost ACK repeats DELETE204 before any GET and removes source only after confirmation', () async {
    final r = await draft();
    final b = _Backend()..lose.add('POST audio-sessions');
    var deletes = 0, deleted = false;
    Future<http.Response> handler(http.Request request) async {
      if (request.url.path.endsWith('/pipeline/cancel')) {
        return http.Response(jsonEncode(b.session()), 200);
      }
      if (request.method == 'DELETE') {
        deletes++;
        expect(request.url.queryParameters, {'confirm': 'true'});
        expect(request.body, isEmpty);
        expect(request.headers.containsKey('Idempotency-Key'), isFalse);
        deleted = true;
        if (deletes == 1) throw http.ClientException('delete ACK lost');
        return http.Response('', 204);
      }
      if (deleted && request.url.path.endsWith('/audio-sessions/audio-1')) {
        throw StateError('Must replay DELETE before GET404');
      }
      return b.response(request);
    }

    await runner(handler).run();
    await f.workspace.queueAction(r.localId, 'delete');
    await runner(handler).run();
    expect(await f.workspace.reader.draftDirectory(r.localId).exists(), isTrue);
    now = now.add(const Duration(minutes: 20));
    await runner(handler).run();
    expect(deletes, 2);
    expect(
      await f.workspace.reader.draftDirectory(r.localId).exists(),
      isFalse,
    );
  });
  test(
    'busy cancel/delete retries boundedly without dropping command or source',
    () async {
      final r = await draft();
      final b = _Backend()..lose.add('POST audio-sessions');
      var busy = true, calls = 0;
      Future<http.Response> handler(http.Request request) async {
        if (request.url.path.endsWith('/pipeline/cancel')) {
          calls++;
          if (busy) {
            return http.Response(
              '{"error":{"code":"audio_session_busy"}}',
              409,
            );
          }
          return http.Response(jsonEncode(b.session()), 200);
        }
        if (request.method == 'DELETE') return http.Response('', 204);
        return b.response(request);
      }

      await runner(handler).run();
      await f.workspace.queueAction(r.localId, 'delete');
      await runner(handler).run();
      final kept = await f.workspace.reader.read(r.localId);
      expect(draftQueue(kept)['command'], 'delete');
      expect(draftQueue(kept)['stage'], 'retry_wait');
      await runner(handler).run();
      expect(calls, 1);
      busy = false;
      now = now.add(const Duration(minutes: 20));
      await runner(handler).run();
      expect(
        await f.workspace.reader.draftDirectory(r.localId).exists(),
        isFalse,
      );
    },
  );
  test('capture handoff prevents queue acquiring scope between UI release and FGS start', () async {
    await draft();
    var requests = 0;
    final run = DraftQueueRunner(
      directory: f.workspace.directory,
      connection: binding,
      acquireOwner: f.pool.acquire,
      clientFactory: () => MockClient((request) async {
        requests++;
        return http.Response('{}', 200);
      }),
      isActive: () async => true,
      capturePending: () async => true,
    );
    await run.run();
    expect(requests, 0);
    expect(run.ownerUnavailable, isTrue);
    expect(f.pool.held, isEmpty);
  });
  test('review partial upload delete freezes explicit discard flags, busy/lost204 replay never creates complete', () async {
    final r = await draft(mode: 'review');
    final b = _Backend()..lose.add('POST audio-sessions');
    var deletes = 0;
    Future<http.Response> handler(http.Request request) async {
      if (request.method == 'DELETE') {
        deletes++;
        expect(request.url.queryParameters, {
          'confirm': 'true',
          'discard_unprocessed': 'true',
        });
        expect(request.body, isEmpty);
        expect(request.headers.containsKey('Idempotency-Key'), isFalse);
        if (deletes == 1) {
          return http.Response('{"error":{"code":"audio_session_busy"}}', 409);
        }
        if (deletes == 2) throw http.ClientException('204 lost after delete');
        return http.Response('', 204);
      }
      return b.response(request);
    }

    await runner(handler).run();
    await f.workspace.queueAction(r.localId, 'delete');
    await runner(handler).run();
    expect(await f.workspace.reader.draftDirectory(r.localId).exists(), isTrue);
    now = now.add(const Duration(minutes: 20));
    await runner(handler).run();
    final kept = await f.workspace.reader.read(r.localId);
    expect(kept.requests['remote-delete']!.query, {
      'confirm': 'true',
      'discard_unprocessed': 'true',
    });
    now = now.add(const Duration(minutes: 20));
    await runner(handler).run();
    expect(deletes, 3);
    expect(
      await f.workspace.reader.draftDirectory(r.localId).exists(),
      isFalse,
    );
    expect(
      b.calls.any(
        (r) =>
            r.url.path.endsWith('/chunks') ||
            r.url.path.endsWith('/complete') ||
            r.url.path.endsWith('/confirm'),
      ),
      isFalse,
    );
  });
  for (final sourceReady in [false, true]) {
    test(
      'explicit ${sourceReady ? 'Qwen pipeline' : 'ASR'} retry preserves existing session and bytes; lost receipt replays same request',
      () async {
        final b = _Backend();
        final r = await draft();
        var failed = true, retries = 0;
        final retryBodies = <String>[], retryKeys = <String?>[];
        Future<http.Response> handler(http.Request request) async {
          if (request.method == 'GET' &&
              request.url.path.endsWith('/audio-sessions/audio-1')) {
            return http.Response(
              jsonEncode({
                ...b.session(),
                'status': failed ? 'failed' : 'completed',
                'transcript_id': sourceReady || !failed ? 'transcript-1' : null,
                'pipeline': {
                  'mode': 'automatic',
                  'phase': failed ? 'error' : 'completed',
                  'error_code': failed
                      ? (sourceReady ? 'llm_unavailable' : 'chunk_failed')
                      : null,
                  'summary_id': failed ? null : 'summary-1',
                },
              }),
              200,
            );
          }
          if (request.method == 'POST' && request.url.path.endsWith('/retry')) {
            retries++;
            expect(
              request.url.path,
              endsWith(sourceReady ? '/pipeline/retry' : '/audio-1/retry'),
            );
            retryBodies.add(request.body);
            retryKeys.add(request.headers['Idempotency-Key']);
            failed = false;
            if (retries == 1) throw http.ClientException('retry receipt lost');
            return http.Response(jsonEncode(b.session()), 200);
          }
          return b.response(request);
        }

        await runner(handler).run();
        final failedDraft = await f.workspace.reader.read(r.localId);
        expect(draftQueue(failedDraft)['stage'], 'needs_action');
        final chunks = b.calls
            .where((r) => r.url.path.endsWith('/chunks'))
            .length;
        await f.workspace.queueAction(r.localId, 'retry', repair: sourceReady);
        await runner(handler).run();
        now = now.add(const Duration(minutes: 20));
        await runner(handler).run();
        expect(retries, 2);
        expect(retryBodies.first, retryBodies.last);
        expect(retryKeys.first, retryKeys.last);
        expect(
          b.calls.where((r) => r.url.path.endsWith('/chunks')),
          hasLength(chunks),
        );
        expect(
          b.calls.where(
            (r) => r.method == 'POST' && r.url.path.endsWith('/audio-sessions'),
          ),
          hasLength(1),
        );
        expect(
          await f.workspace.reader.draftDirectory(r.localId).exists(),
          isFalse,
        );
      },
    );
  }
  test('automatic boundary requires user review; lost PATCH/confirm receipts keep real edited text and SHA, never manual candidate', () async {
    final b = _Backend();
    final r = await draft();
    var text = 'Original recognized source',
        sha = 'a' * 64,
        confirmed = false,
        patches = 0,
        confirms = 0;
    final confirmsBody = <String>[];
    Future<http.Response> handler(http.Request request) async {
      if (request.method == 'GET' &&
          request.url.path.endsWith('/audio-sessions/audio-1')) {
        return http.Response(
          jsonEncode({
            ...b.session(),
            'status': confirmed ? 'completed' : 'ready_for_review',
            'transcript_id': 'transcript-1',
            'transcript_sha256': sha,
            'boundary_warnings': [
              {'sequence_number': 1, 'code': 'overlap_not_aligned'},
            ],
            'pipeline': {
              'mode': 'automatic',
              'phase': confirmed ? 'completed' : 'review_required',
              'summary_id': confirmed ? 'summary-1' : null,
            },
          }),
          200,
        );
      }
      if (request.method == 'GET' &&
          request.url.path.endsWith('/transcripts/transcript-1')) {
        return http.Response(
          jsonEncode({'id': 'transcript-1', 'text': text, 'is_locked': false}),
          200,
        );
      }
      if (request.method == 'PATCH') {
        patches++;
        text = (jsonDecode(request.body) as JsonMap)['text'] as String;
        sha = 'b' * 64;
        throw http.ClientException('PATCH applied but reply lost');
      }
      if (request.url.path.endsWith('/confirm')) {
        confirms++;
        confirmsBody.add(request.body);
        final body = jsonDecode(request.body) as JsonMap;
        expect(body['confirm'], isTrue);
        expect(body['boundaries_reviewed'], isTrue);
        expect(body['reviewed_text_sha256'], sha);
        confirmed = true;
        if (confirms == 1) {
          throw http.ClientException('confirm accepted but reply lost');
        }
        return http.Response(
          '{"transcript_id":"transcript-1","status":"ready","summary_id":"summary-1"}',
          200,
        );
      }
      expect(request.url.path.contains('summary-selections'), isFalse);
      return b.response(request);
    }

    await runner(handler).run();
    expect(confirms, 0);
    final ready = await f.workspace.reader.read(r.localId);
    expect(ready.input.text, text);
    await f.workspace.save(
      ready.localId,
      revision: ready.revision,
      input: LocalDraftInput(
        title: ready.input.title,
        text: 'Reviewed text with corrected boundary.',
        folderIds: ready.input.folderIds,
        processingMode: 'automatic',
      ),
      autoStart: false,
    );
    await f.workspace.queueAction(
      r.localId,
      'start',
      boundariesReviewed: false,
    );
    await runner(handler).run();
    expect(patches, 0);
    expect(confirms, 0);
    expect(
      draftQueue(await f.workspace.reader.read(r.localId))['error_code'],
      'boundary_review_required',
    );
    await f.workspace.queueAction(r.localId, 'start', boundariesReviewed: true);
    for (var i = 0; i < 4; i++) {
      await runner(handler).run();
      now = now.add(const Duration(minutes: 20));
    }
    expect(patches, 1);
    expect(confirms, 2);
    expect(confirmsBody.first, confirmsBody.last);
    expect(text, 'Reviewed text with corrected boundary.');
    expect(
      await f.workspace.reader.draftDirectory(r.localId).exists(),
      isFalse,
    );
  });
  test(
    'headless restart finishes a confirmed local cleanup marker without HTTP',
    () async {
      final r = await draft(requested: false);
      final marker = File(
        '${f.workspace.directory.path}/draft-deletions/${r.localId}.json',
      );
      await marker.parent.create(recursive: true);
      await marker.writeAsString(
        jsonEncode({
          'schema': 1,
          'confirmed': true,
          'local_id': r.localId,
          'scope_id': r.scopeId,
          'revision': r.revision,
          'remote_outcome_confirmed': false,
        }),
        flush: true,
      );
      final b = _Backend();
      await runner(b.response).run();
      expect(await marker.exists(), isFalse);
      expect(
        await f.workspace.reader.draftDirectory(r.localId).exists(),
        isFalse,
      );
      expect(b.calls, isEmpty);
    },
  );
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/recording/audio_api.dart';
import 'package:your_mettings/features/recording/audio_engine.dart';
import 'package:your_mettings/features/recording/audio_journal.dart';
import 'package:your_mettings/features/recording/audio_review_controller.dart';
import 'package:your_mettings/features/recording/recorder_coordinator.dart';
import 'package:your_mettings/services/audio_draft_store.dart';
import 'package:your_mettings/services/recovery_store.dart';

import 'audio_drafts_test.dart' show MemoryStore, entry;

class FailedClearStore implements RecoveryStore {
  FailedClearStore(this.inner);
  final RecoveryStore inner;
  bool fail = true;
  @override
  Future<RecoveryState> load() => inner.load();
  @override
  Future<void> save(RecoveryState state) async {
    if (fail && state.draft.text.isEmpty) {
      throw const FileSystemException('Injected cleanup failure');
    }
    await inner.save(state);
  }
}

class FailedReceiptRepository extends AudioDraftRepository {
  FailedReceiptRepository({super.file});
  bool failReceipt = true;
  @override
  Future<void> persist(Map<String, dynamic> value) async {
    if (failReceipt &&
        (value['items'] as List).any(
          (item) => item['server_deleted'] == true,
        )) {
      throw const FileSystemException('Injected receipt write failure');
    }
    await super.persist(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const record = MethodChannel('com.llfbandit.record/messages');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(record, (_) async => null);
  });
  tearDown(() async {
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(record, null);
  });
  AudioJournal journal(Directory root) =>
      AudioJournal(Directory('${root.path}/active-audio'))
        ..data = {
          'version': 1,
          'id': 'A',
          'key': 'test-key-A',
          'phase': 'review',
          'chunks': <Map<String, dynamic>>[
            {'sequence': 0, 'acked': true},
          ],
          'limits': {
            'chunk_target_seconds': 30,
            'max_chunk_seconds': 60,
            'max_upload_bytes': 33554432,
            'max_chunks': 240,
          },
          'session': {'transcript_id': 'source-A', 'boundary_warnings': []},
        };
  for (final loseReply in [false, true]) {
    test(
      'restart finishes only deleted session after ${loseReply ? 'lost DELETE reply' : '204 and local cleanup failure'}',
      () async {
        final dir = await Directory.systemTemp.createTemp('ym-delete-restart-');
        addTearDown(() => dir.delete(recursive: true));
        journal(dir).saveSync();
        final requests = <String>[];
        var deletes = 0;
        Future<http.Response> backend(http.Request r) async {
          requests.add('${r.method} ${r.url.path}');
          if (r.method == 'DELETE') {
            deletes++;
            expect(r.url.queryParameters, {'confirm': 'true'});
            if (loseReply && deletes == 1) {
              throw http.ClientException('Lost DELETE ACK');
            }
            return http.Response('', 204);
          }
          if (r.method == 'GET' &&
              r.url.path.endsWith('/audio-sessions/A') &&
              deletes == 0) {
            return http.Response(
              jsonEncode({
                'status': 'ready_for_review',
                'transcript_id': 'source-A',
              }),
              200,
            );
          }
          if (r.url.path.endsWith('/folders')) {
            return http.Response(jsonEncode({'items': []}), 200);
          }
          throw StateError(
            'No upload, complete, GET-deleted or ASR/Qwen request allowed during maintenance',
          );
        }

        AudioApi audio() => AudioApi(
          Uri.parse('http://example/api/v1/'),
          client: MockClient(backend),
        );
        final regular = ApiClient(
          Uri.parse('http://example/api/v1/'),
          client: MockClient(backend),
        );
        addTearDown(regular.close);
        final file = File('${dir.path}/audio-drafts.json');
        final repo = AudioDraftRepository(file: file);
        await repo.put(entry('unrelated'));
        final legacyFile = FileRecoveryStore(
          File('${dir.path}/audio-review-recovery.json'),
        );
        final fault = FailedClearStore(legacyFile)..fail = !loseReply;
        final rec = RecorderCoordinator(directory: dir, audioApiFactory: audio);
        await rec.initialize();
        final review = AudioReviewController(
          regular,
          fault,
          rec,
          drafts: repo,
          audioApiFactory: audio,
        );
        await review.saveDraft(entry('A').recovery.draft);
        expect(await review.deleteMeeting(), isFalse);
        expect(repo['A']!.deletePending, isTrue);
        expect(repo['A']!.serverDeleted, !loseReply);
        if (!loseReply) expect(rec.phase, 'done');
        expect(
          review.error,
          contains(
            loseReply
                ? 'Подтверждение удаления не получено'
                : 'Сервер удалил встречу',
          ),
        );
        rec.dispose();
        review.dispose();
        repo.dispose();
        final restored = AudioDraftRepository(file: file);
        await restored.load();
        final next = RecorderCoordinator(
          directory: dir,
          audioApiFactory: audio,
        );
        final controller = AudioReviewController(
          regular,
          legacyFile,
          next,
          drafts: restored,
          audioApiFactory: audio,
        );
        controller.recovery = await legacyFile.load();
        await next.initialize();
        await controller.recoverHandoffs();
        expect(restored['A'], isNull);
        expect(restored['unrelated']!.recovery.draft.text, 'Текст unrelated');
        expect(next.phase, 'done');
        expect(next.active, isFalse);
        expect(next.handoffPending, isFalse);
        expect((await legacyFile.load()).draft.text, isEmpty);
        expect(deletes, loseReply ? 2 : 1);
        expect(requests.where((r) => r.startsWith('POST')), isEmpty);
        controller.dispose();
        next.dispose();
        restored.dispose();
      },
    );
  }
  test('offline retry retains the same intent, journal and WAV without any new POST', () async {
    final dir = await Directory.systemTemp.createTemp('ym-delete-offline-');
    addTearDown(() => dir.delete(recursive: true));
    final j = journal(dir);
    j.saveSync();
    await j.chunkFile(0).writeAsBytes([1, 2, 3]);
    final repo = AudioDraftRepository(
      file: File('${dir.path}/audio-drafts.json'),
    );
    await repo.put(entry('A').copy(deletePending: true));
    final methods = <String>[];
    AudioApi audio() => AudioApi(
      Uri.parse('http://example/api/v1/'),
      client: MockClient((r) async {
        methods.add(r.method);
        throw http.ClientException('Offline');
      }),
    );
    final rec = RecorderCoordinator(directory: dir, audioApiFactory: audio);
    final api = ApiClient(Uri.parse('http://example/api/v1/'));
    final review = AudioReviewController(
      api,
      MemoryStore(),
      rec,
      drafts: repo,
      audioApiFactory: audio,
    );
    await rec.initialize();
    await review.recoverHandoffs();
    expect(repo['A']!.deletePending, isTrue);
    expect(repo['A']!.serverDeleted, isFalse);
    expect(j.chunkFile(0).readAsBytesSync(), [1, 2, 3]);
    expect(methods, ['DELETE']);
    expect(rec.phase, 'review');
    expect(review.storageError, isNotNull);
    review.dispose();
    rec.dispose();
    repo.dispose();
    api.close();
  });
  test('deletion A never releases or clears active recording and accepted operation B', () async {
    final dir = await Directory.systemTemp.createTemp('ym-delete-other-');
    addTearDown(() => dir.delete(recursive: true));
    final repo = AudioDraftRepository(
      file: File('${dir.path}/audio-drafts.json'),
    );
    await repo.put(
      entry('A').copy(deletePending: true, serverDeleted: true, handoff: true),
    );
    final rec = RecorderCoordinator(directory: dir)
      ..state = {'id': 'A', 'phase': 'review'};
    final store = MemoryStore();
    final api = ApiClient(Uri.parse('http://example/api/v1/'));
    final review = AudioReviewController(api, store, rec, drafts: repo);
    await review.openReview(); // Bind A before another accepted operation owns the legacy store.
    rec.state = {'id': 'B', 'phase': 'recording'};
    review.recovery = RecoveryState(
      operation: AcceptedOperation('source-B', 'B', ['folder']),
    );
    await store.save(review.recovery);
    await review.recoverHandoffs();
    expect(repo['A'], isNull);
    expect(rec.state['id'], 'B');
    expect(rec.phase, 'recording');
    expect(store.value.operation!.id, 'source-B');
    review.dispose();
    rec.dispose();
    repo.dispose();
    api.close();
  });
  test(
    'maintenance barrier prevents startup upload, completion and ASR retry',
    () async {
      final dir = await Directory.systemTemp.createTemp('ym-delete-barrier-');
      addTearDown(() => dir.delete(recursive: true));
      final j = journal(dir)..data['phase'] = 'sending';
      j.saveSync();
      var calls = 0;
      final api = AudioApi(
        Uri.parse('http://example/api/v1/'),
        client: MockClient((_) async {
          calls++;
          throw StateError('Unexpected HTTP');
        }),
      );
      final engine = AudioEngine(j, api, maintenanceRequired: () async => true);
      await engine.initialize();
      await engine.sync(force: true);
      await engine.retryAsr();
      expect(calls, 0);
      expect(engine.phase, 'sending');
      await engine.dispose();
    },
  );
  test('lost durable 204 marker retains intent and repeats only DELETE before safe release', () async {
    final dir = await Directory.systemTemp.createTemp('ym-delete-receipt-');
    addTearDown(() => dir.delete(recursive: true));
    final j = journal(dir);
    j.saveSync();
    final repo = FailedReceiptRepository(
      file: File('${dir.path}/audio-drafts.json'),
    );
    var deletes = 0;
    AudioApi audio() => AudioApi(
      Uri.parse('http://example/api/v1/'),
      client: MockClient((r) async {
        if (r.method == 'DELETE') {
          deletes++;
          return http.Response('', 204);
        }
        expect(r.method, 'GET');
        return http.Response(
          jsonEncode({
            'status': 'ready_for_review',
            'transcript_id': 'source-A',
          }),
          200,
        );
      }),
    );
    final rec = RecorderCoordinator(directory: dir, audioApiFactory: audio);
    await rec.initialize();
    final api = ApiClient(Uri.parse('http://example/api/v1/'));
    final review = AudioReviewController(
      api,
      MemoryStore(),
      rec,
      drafts: repo,
      audioApiFactory: audio,
    );
    await review.saveDraft(entry('A').recovery.draft);
    expect(await review.deleteMeeting(), isFalse);
    expect(repo['A']!.deletePending, isTrue);
    expect(repo['A']!.serverDeleted, isFalse);
    expect(rec.phase, 'review');
    expect(review.error, contains('Сервер удалил встречу'));
    repo.failReceipt = false;
    await review.recoverHandoffs();
    expect(deletes, 2);
    expect(repo['A'], isNull);
    expect(rec.active, isFalse);
    review.dispose();
    rec.dispose();
    repo.dispose();
    api.close();
  });
  test(
    'concurrent recovery is serialized and repeats a deletion only once',
    () async {
      final repo = AudioDraftRepository();
      await repo.put(entry('A').copy(deletePending: true));
      final rec = RecorderCoordinator()
        ..state = {'id': 'B', 'phase': 'recording'};
      final api = ApiClient(Uri.parse('http://example/api/v1/'));
      final started = Completer<void>(), reply = Completer<void>();
      var deletes = 0;
      final review = AudioReviewController(
        api,
        MemoryStore(),
        rec,
        drafts: repo,
        audioApiFactory: () => AudioApi(
          api.baseUri,
          client: MockClient((r) async {
            expect(r.method, 'DELETE');
            deletes++;
            if (!started.isCompleted) started.complete();
            await reply.future;
            return http.Response('', 204);
          }),
        ),
      );
      final first = review.recoverHandoffs();
      await started.future;
      await review.recoverHandoffs();
      reply.complete();
      await first;
      expect(deletes, 1);
      expect(repo['A'], isNull);
      expect(rec.state['id'], 'B');
      expect(review.working, isFalse);
      review.dispose();
      rec.dispose();
      repo.dispose();
      api.close();
    },
  );
}

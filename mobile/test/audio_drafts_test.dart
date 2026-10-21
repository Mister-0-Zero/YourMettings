import 'package:crypto/crypto.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/recording/audio_api.dart';
import 'package:your_mettings/features/recording/audio_review_controller.dart';
import 'package:your_mettings/features/recording/recorder_coordinator.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/audio_draft_store.dart';
import 'package:your_mettings/services/recovery_store.dart';

class MemoryStore implements RecoveryStore {
  RecoveryState value = RecoveryState();
  bool fail = false;
  @override
  Future<RecoveryState> load() async => value;
  @override
  Future<void> save(RecoveryState state) async {
    if (fail) throw StateError('disk full');
    value = RecoveryState.fromJson(
      jsonDecode(jsonEncode(state.toJson())) as Json,
    );
  }
}

class FailingRepository extends AudioDraftRepository {
  int saves = 0;
  int? failAt;
  @override
  Future<void> persist(Json value) async {
    if (++saves == failAt) throw StateError('disk failure');
    await super.persist(value);
  }
}

class Recorder extends RecorderCoordinator {
  final releases = <String>[];
  bool failRelease = false;
  @override
  Future<void> releaseReview(String expectedId) async {
    if (!active) return;
    expect(state['id'], expectedId);
    if (failRelease) throw StateError('no ACK');
    releases.add(expectedId);
    state = {'phase': 'done'};
    notifyListeners();
  }
}

SavedAudioDraft entry(String id, {bool handoff = false}) => SavedAudioDraft(
  sessionId: id,
  transcriptId: 'source-$id',
  creationKey: 'key-$id',
  recovery: RecoveryState(
    draft: Draft(
      title: 'Встреча $id',
      text: 'Текст $id',
      folderIds: ['folder'],
    ),
  ),
  updatedAt: DateTime.utc(2026, 10, 22),
  handoff: handoff,
);
http.Response response(Object json) =>
    http.Response.bytes(utf8.encode(jsonEncode(json)), 200);

void main() {
  test('multiple draft snapshots persist independently and accepted source is cleared', () async {
    final dir = Directory.systemTemp.createTempSync('ym-drafts-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/drafts.json');
    final repo = AudioDraftRepository(file: file);
    await Future.wait([repo.put(entry('A')), repo.put(entry('B'))]);
    await DeferredAudioRecoveryStore(repo, 'A').save(
      RecoveryState(operation: AcceptedOperation('source-A', 'A', ['folder'])),
    );
    final restored = AudioDraftRepository(file: file);
    await restored.load();
    expect(restored.items.length, 2);
    expect(restored['A']!.recovery.draft.text, isEmpty);
    expect(restored['A']!.recovery.operation!.id, 'source-A');
    expect(restored['B']!.recovery.draft.text, 'Текст B');
    expect(file.readAsStringSync(), isNot(contains('Текст A')));
    repo.dispose();
    restored.dispose();
  });
  test('failed repository write never publishes partial state', () async {
    final repo = FailingRepository();
    await repo.put(entry('A'));
    repo.failAt = 2;
    await expectLater(repo.put(entry('B')), throwsStateError);
    expect(repo['B'], isNull);
    expect(repo['A']!.recovery.draft.text, 'Текст A');
    repo.dispose();
  });
  for (final failClear in [false, true]) {
    test(
      'handoff recovers after ${failClear ? 'release before legacy cleanup' : 'snapshot before release'}',
      () async {
        final repo = AudioDraftRepository();
        final store = MemoryStore();
        final rec = Recorder()
          ..state = {
            'id': 'A',
            'phase': 'review',
            'key': 'key-A',
            'session': {'transcript_id': 'source-A', 'boundary_warnings': []},
          };
        final api = ApiClient(
          Uri.parse('http://example/api/v1/'),
          client: MockClient((_) async => response({'items': []})),
        );
        final c = AudioReviewController(api, store, rec, drafts: repo);
        await c.saveDraft(entry('A').recovery.draft);
        if (failClear) {
          store.fail = true;
        } else {
          rec.failRelease = true;
        }
        expect(await c.defer(), false);
        expect(repo['A']!.handoff, true);
        expect(repo['A']!.recovery.draft.text, 'Текст A');
        expect(rec.handoffPending, true);
        rec.failRelease = false;
        store.fail = false;
        await c.recoverHandoffs();
        expect(repo['A']!.handoff, false);
        expect(store.value.draft.text, isEmpty);
        expect(rec.phase, 'done');
        expect(rec.handoffPending, false);
        c.dispose();
        rec.dispose();
        api.close();
        repo.dispose();
      },
    );
  }
  test('failed initial snapshot does not release the active review', () async {
    final repo = FailingRepository()..failAt = 1;
    final rec = Recorder()
      ..state = {
        'id': 'A',
        'phase': 'review',
        'key': 'key-A',
        'session': {'transcript_id': 'source-A'},
      };
    final api = ApiClient(Uri.parse('http://example/api/v1/'));
    final c = AudioReviewController(api, MemoryStore(), rec, drafts: repo);
    await c.saveDraft(entry('A').recovery.draft);
    expect(await c.defer(), false);
    expect(rec.releases, isEmpty);
    expect(rec.state['id'], 'A');
    expect(c.draft.text, 'Текст A');
    c.dispose();
    rec.dispose();
    api.close();
    repo.dispose();
  });
  test(
    'old handoff checkpoint never clears another active recording or its draft',
    () async {
      final repo = AudioDraftRepository();
      await repo.put(entry('A', handoff: true));
      final rec = Recorder()..state = {'id': 'B', 'phase': 'recording'};
      final store = MemoryStore();
      final api = ApiClient(Uri.parse('http://example/api/v1/'));
      final c = AudioReviewController(api, store, rec, drafts: repo);
      await c.saveDraft(entry('B').recovery.draft);
      await c.recoverHandoffs();
      expect(rec.state['id'], 'B');
      expect(rec.releases, isEmpty);
      expect(store.value.draft.text, 'Текст B');
      expect(repo['A']!.recovery.draft.text, 'Текст A');
      c.dispose();
      rec.dispose();
      api.close();
      repo.dispose();
    },
  );
  for (final replyCode in [404, 409, 422, 503, 200]) {
    test(
      'DELETE $replyCode retains data and never releases new recording B',
      () async {
        final repo = AudioDraftRepository();
        await repo.put(entry('A'));
        final rec = Recorder()..state = {'id': 'B', 'phase': 'recording'};
        final api = ApiClient(Uri.parse('http://example/api/v1/'));
        final c = AudioReviewController(
          api,
          DeferredAudioRecoveryStore(repo, 'A'),
          rec,
          fixedSessionId: 'A',
          drafts: repo,
          audioApiFactory: () => AudioApi(
            api.baseUri,
            client: MockClient((r) async {
              expect(r.method, 'DELETE');
              expect(r.url.path, '/api/v1/audio-sessions/A');
              expect(r.url.queryParameters, {'confirm': 'true'});
              expect(r.body, isEmpty);
              return http.Response(
                jsonEncode({
                  'error': {'code': 'failure', 'message': 'Not deleted'},
                }),
                replyCode,
              );
            }),
          ),
        );
        c.recovery = repo['A']!.recovery;
        expect(await c.deleteMeeting(), false);
        expect(repo['A']!.recovery.draft.text, 'Текст A');
        expect(rec.state['id'], 'B');
        expect(rec.releases, isEmpty);
        c.dispose();
        rec.dispose();
        api.close();
        repo.dispose();
      },
    );
  }
  test('lost DELETE reply survives restart, blocks confirm and retries identical ID only', () async {
    final dir = Directory.systemTemp.createTempSync('ym-delete-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/drafts.json');
    final repo = AudioDraftRepository(file: file);
    await repo.put(entry('A'));
    final rec = Recorder()
      ..state = {
        'id': 'B',
        'phase': 'recording',
        'chunks': ['protected'],
      };
    final requests = <String>[];
    Future<http.Response> backend(http.Request r) async {
      requests.add('${r.method} ${r.url.path}');
      if (r.method == 'GET') return response({'items': []});
      expect(r.method, 'DELETE');
      expect(r.url.path, '/api/v1/audio-sessions/A');
      if (requests.where((p) => p.startsWith('DELETE')).length == 1) {
        throw http.ClientException('lost response');
      }
      return http.Response('', 204);
    }

    final api = ApiClient(
      Uri.parse('http://example/api/v1/'),
      client: MockClient(backend),
    );
    AudioReviewController make(AudioDraftRepository data) =>
        AudioReviewController(
          api,
          DeferredAudioRecoveryStore(data, 'A'),
          rec,
          drafts: data,
          fixedSessionId: 'A',
          audioApiFactory: () =>
              AudioApi(api.baseUri, client: MockClient(backend)),
        );
    final c = make(repo);
    c.recovery = repo['A']!.recovery;
    expect(await c.deleteMeeting(), false);
    c.dispose();
    final restarted = AudioDraftRepository(file: file);
    await restarted.load();
    final second = make(restarted);
    await second.initialize();
    await second.openReview();
    await second.submit();
    expect(second.deletionPending, true);
    expect(requests.where((r) => r.startsWith('POST')), isEmpty);
    expect(await second.deleteMeeting(), true);
    expect(restarted['A'], isNull);
    expect(rec.state['id'], 'B');
    expect(rec.state['chunks'], ['protected']);
    expect(rec.releases, isEmpty);
    second.dispose();
    rec.dispose();
    api.close();
    repo.dispose();
    restarted.dispose();
  });
  test(
    'server ACK followed by local write failure safely repeats DELETE',
    () async {
      final repo = FailingRepository();
      await repo.put(entry('A'));
      repo.failAt = 3;
      final rec = Recorder()..state = {'id': 'B', 'phase': 'recording'};
      final api = ApiClient(Uri.parse('http://example/api/v1/'));
      var calls = 0;
      final c = AudioReviewController(
        api,
        DeferredAudioRecoveryStore(repo, 'A'),
        rec,
        fixedSessionId: 'A',
        drafts: repo,
        audioApiFactory: () => AudioApi(
          api.baseUri,
          client: MockClient((_) async {
            calls++;
            return http.Response('', 204);
          }),
        ),
      )..recovery = repo['A']!.recovery;
      expect(await c.deleteMeeting(), false);
      expect(repo['A']!.deletePending, true);
      repo.failAt = null;
      expect(await c.deleteMeeting(), true);
      expect(calls, 2);
      expect(rec.state['id'], 'B');
      expect(rec.releases, isEmpty);
      c.dispose();
      rec.dispose();
      api.close();
      repo.dispose();
    },
  );
  test(
    'finishing old accepted operation removes its tracking without stopping B',
    () async {
      final repo = AudioDraftRepository();
      await repo.put(entry('A'));
      final rec = Recorder()..state = {'id': 'B', 'phase': 'recording'};
      final api = ApiClient(Uri.parse('http://example/api/v1/'));
      final c = AudioReviewController(
        api,
        DeferredAudioRecoveryStore(repo, 'A'),
        rec,
        fixedSessionId: 'A',
        drafts: repo,
      );
      c.recovery = RecoveryState(
        operation: AcceptedOperation('source-A', 'A', ['folder']),
      );
      c.status = ProcessingStatus.fromJson({
        'transcript_id': 'source-A',
        'status': 'error',
        'summary_id': null,
        'error': null,
      });
      await c.finish();
      expect(repo['A'], isNull);
      expect(rec.state['id'], 'B');
      expect(rec.releases, isEmpty);
      c.dispose();
      rec.dispose();
      api.close();
      repo.dispose();
    },
  );
  test(
    'confirming archived A uses its own IDs and retains recording B',
    () async {
      final repo = AudioDraftRepository();
      await repo.put(entry('A'));
      final rec = Recorder()
        ..state = {
          'id': 'B',
          'phase': 'recording',
          'chunks': ['B.wav'],
        };
      var speech = 'Текст A';
      var posts = 0;
      Future<http.Response> backend(http.Request r) async {
        expect(r.url.path, isNot(contains('/B')));
        if (r.url.path.endsWith('/folders')) return response({'items': []});
        if (r.url.path.endsWith('/audio-sessions/A')) {
          return response({
            'status': 'ready_for_review',
            'transcript_id': 'source-A',
            'transcript_sha256': sha256.convert(utf8.encode(speech)).toString(),
            'parameters': {
              'title': 'A',
              'folder_ids': ['folder'],
            },
            'boundary_warnings': [],
          });
        }
        if (r.url.path.endsWith('/transcripts/source-A')) {
          if (r.method == 'PATCH') {
            speech = (jsonDecode(r.body) as Json)['text'] as String;
          }
          return response({
            'id': 'source-A',
            'text': speech,
            'is_locked': false,
          });
        }
        if (r.url.path.endsWith('/A/confirm')) {
          posts++;
          expect(r.method, 'POST');
          expect(speech, 'Изменённый текст A');
          return response({
            'transcript_id': 'source-A',
            'status': 'ready',
            'summary_id': 'summary-A',
            'error': null,
          });
        }
        if (r.url.path.endsWith('/source-A/processing')) {
          return response({
            'transcript_id': 'source-A',
            'status': 'ready',
            'summary_id': 'summary-A',
            'error': null,
          });
        }
        if (r.url.path.endsWith('/summaries/summary-A')) {
          return response({
            'id': 'summary-A',
            'transcript_id': 'source-A',
            'title': 'A',
            'content': 'Result A',
            'folder_ids': ['folder'],
            'created_at': '2026-10-22T00:00:00Z',
            'updated_at': '2026-10-22T00:00:00Z',
          });
        }
        fail('Unexpected request: ${r.method} ${r.url.path}');
      }

      final api = ApiClient(
        Uri.parse('http://example/api/v1/'),
        client: MockClient(backend),
      );
      final c = AudioReviewController(
        api,
        DeferredAudioRecoveryStore(repo, 'A'),
        rec,
        drafts: repo,
        fixedSessionId: 'A',
        audioApiFactory: () =>
            AudioApi(api.baseUri, client: MockClient(backend)),
      );
      await c.initialize();
      await c.openReview();
      await c.saveDraft(
        Draft(title: 'A', text: 'Изменённый текст A', folderIds: ['folder']),
      );
      await c.submit();
      expect(posts, 1);
      expect(c.result!.id, 'summary-A');
      expect(repo['A']!.recovery.draft.text, isEmpty);
      expect(repo['A']!.recovery.operation!.id, 'source-A');
      await c.finish();
      expect(repo['A'], isNull);
      expect(rec.state['id'], 'B');
      expect(rec.state['chunks'], ['B.wav']);
      expect(rec.releases, isEmpty);
      c.dispose();
      rec.dispose();
      repo.dispose();
      api.close();
    },
  );
}

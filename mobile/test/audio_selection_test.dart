import 'package:your_mettings/services/audio_draft_store.dart';
import 'package:your_mettings/services/operation_store.dart';

import 'audio_drafts_test.dart' show Recorder, entry;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/recording/audio_api.dart';
import 'package:your_mettings/features/recording/audio_review_controller.dart';
import 'package:your_mettings/features/recording/recorder_coordinator.dart';
import 'package:your_mettings/services/recovery_store.dart';

import 'audio_review_test.dart' show MemoryStore;

void main() {
  test('audio selection PATCHes checked text, verifies hash and keeps draft without confirm or ASR', () async {
    var source = 'Original';
    final calls = <http.Request>[];
    Future<http.Response> backend(http.Request r) async {
      calls.add(r);
      if (r.method == 'PATCH') {
        source = jsonDecode(r.body)['text'] as String;
        return http.Response(
          jsonEncode({'id': 'transcript', 'text': source, 'is_locked': false}),
          200,
        );
      }
      expect(r.url.path, '/api/v1/audio-sessions/session');
      return http.Response(
        jsonEncode({
          'status': 'ready_for_review',
          'transcript_sha256': sha256.convert(utf8.encode(source)).toString(),
        }),
        200,
      );
    }

    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      client: MockClient(backend),
    );
    addTearDown(api.close);
    final recorder = RecorderCoordinator()
      ..state = {
        'id': 'session',
        'session': {'transcript_id': 'transcript', 'boundary_warnings': []},
      };
    addTearDown(recorder.dispose);
    final store = MemoryStore();
    final review = AudioReviewController(
      api,
      store,
      recorder,
      audioApiFactory: () => AudioApi(api.baseUri, client: MockClient(backend)),
    );
    addTearDown(review.dispose);
    await review.saveDraft(
      Draft(text: 'Edited speech', title: 'Audio', folderIds: ['folder']),
    );
    final body = await review.selectionSource();
    expect(body, {
      'audio_session_id': 'session',
      'title': 'Audio',
      'folder_ids': ['folder'],
      'confirm': true,
      'reviewed_text_sha256': sha256
          .convert(utf8.encode('Edited speech'))
          .toString(),
      'boundaries_reviewed': false,
    });
    expect(calls.map((r) => r.method), ['PATCH', 'GET']);
    expect(store.value.draft.text, 'Edited speech');
    expect(review.hasOperation, isFalse);
  });
  test('unreviewed boundaries cannot open audio selection', () async {
    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      client: MockClient((_) async => throw StateError('No HTTP allowed')),
    );
    addTearDown(api.close);
    final recorder = RecorderCoordinator()
      ..state = {
        'id': 'session',
        'session': {
          'transcript_id': 'transcript',
          'boundary_warnings': [
            {'reason': 'boundary'},
          ],
        },
      };
    addTearDown(recorder.dispose);
    final review = AudioReviewController(api, MemoryStore(), recorder);
    addTearDown(review.dispose);
    await expectLater(
      review.selectionSource(),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          'boundary_review_required',
        ),
      ),
    );
  });
  test('deferred audio retains its selection and frees recorder for another meeting', () async {
    final operations = OperationStore(), drafts = AudioDraftRepository();
    final rec = Recorder()
      ..state = {
        'id': 'A',
        'phase': 'review',
        'key': 'key-A',
        'session': {'transcript_id': 'source-A', 'boundary_warnings': []},
      };
    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      operations: operations,
    );
    final review = AudioReviewController(
      api,
      MemoryStore(),
      rec,
      drafts: drafts,
    );
    addTearDown(review.dispose);
    addTearDown(rec.dispose);
    addTearDown(drafts.dispose);
    addTearDown(api.close);
    await review.saveDraft(entry('A').recovery.draft);
    await operations.put('audio-selection:A', {
      'key': 'key',
      'session_id': 'selection',
    });
    expect(await review.defer(), isTrue);
    expect(rec.state['phase'], 'done');
    expect(drafts['A']!.recovery.draft.text, 'Текст A');
    expect(operations['audio-selection:A']!['session_id'], 'selection');
    final reopened = AudioReviewController(
      api,
      DeferredAudioRecoveryStore(drafts, 'A'),
      rec,
      drafts: drafts,
      fixedSessionId: 'A',
    );
    addTearDown(reopened.dispose);
    expect(reopened.selectionActive, isTrue);
  });
  test('deleting reviewed audio cancels selection first and preserves other active recording', () async {
    final operations = OperationStore(), drafts = AudioDraftRepository();
    await drafts.put(entry('A'));
    await operations.put('audio-selection:A', {
      'key': 'key',
      'session_id': 'selection',
    });
    final calls = <String>[];
    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      operations: operations,
      client: MockClient((r) async {
        calls.add(r.url.path);
        return http.Response('', 204);
      }),
    );
    final rec = Recorder()..state = {'id': 'B', 'phase': 'recording'};
    final review = AudioReviewController(
      api,
      DeferredAudioRecoveryStore(drafts, 'A'),
      rec,
      drafts: drafts,
      fixedSessionId: 'A',
      audioApiFactory: () => AudioApi(
        api.baseUri,
        client: MockClient((r) async {
          calls.add(r.url.path);
          return http.Response('', 204);
        }),
      ),
    )..recovery = entry('A').recovery;
    addTearDown(review.dispose);
    addTearDown(rec.dispose);
    addTearDown(drafts.dispose);
    addTearDown(api.close);
    expect(await review.deleteMeeting(), isTrue);
    expect(calls, [
      '/api/v1/summary-selections/selection',
      '/api/v1/audio-sessions/A',
    ]);
    expect(drafts['A'], isNull);
    expect(operations['audio-selection:A'], isNull);
    expect(rec.state, {'id': 'B', 'phase': 'recording'});
  });
}

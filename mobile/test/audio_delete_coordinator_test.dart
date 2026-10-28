import 'package:your_mettings/services/recovery_store.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/recording/audio_review_controller.dart';
import 'package:your_mettings/services/audio_draft_store.dart';

import 'audio_drafts_test.dart' show MemoryStore;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/demo_connection.dart';
import 'package:your_mettings/features/recording/audio_api.dart';
import 'package:your_mettings/features/recording/audio_engine.dart';
import 'package:your_mettings/features/recording/audio_journal.dart';
import 'package:your_mettings/features/recording/recorder_coordinator.dart';
import 'package:your_mettings/models/api_models.dart';

import 'demo_connection_test.dart' show MemoryKeyVault;

class AndroidRecorder extends RecorderCoordinator {
  AndroidRecorder({
    super.connection,
    super.directory,
    super.audioApiFactory,
    super.contextWriter,
  });
  @override
  bool get usesAndroidService => true;
}

void emit(Json snapshot) {
  for (final callback in FlutterForegroundTask.dataCallbacks.toList()) {
    callback(snapshot);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fgs = MethodChannel('flutter_foreground_task/methods');
  const record = MethodChannel('com.llfbandit.record/messages');
  for (final (stopped, delayedSnapshot) in [
    (false, false),
    (false, true),
    (true, false),
  ]) {
    test(
      'scoped start and real engine release with service stopped=$stopped delayedSnapshot=$delayedSnapshot allows a new recording',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'ym-delete-coordinator-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final connection = DemoConnection(
          base: Uri.parse('https://example.test/api/v1/'),
          accountId: 'test-account',
          accessMode: 'demo',
          vault: MemoryKeyVault(),
        );
        var running = false;
        var creations = 0, deletes = 0;
        Json scoped(Json value) => {
          ...value,
          'connection_scope': connection.scopeId,
          'owner_session_id': 'A',
          'service_instance': 'instance-A',
        };
        late AudioEngine engine;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          record,
          (call) async => call.method == 'hasPermission' ? true : null,
        );
        messenger.setMockMethodCallHandler(fgs, (call) async {
          if (call.method == 'isRunningService') return running;
          if (call.method == 'checkNotificationPermission') return 0;
          if (call.method == 'startService') {
            running = true;
            return null;
          }
          if (call.method == 'sendData' && call.arguments is Map) {
            final data = call.arguments as Map;
            if (data['command'] == 'releaseReview') {
              await engine.releaseReview(data['session_id'] as String);
              emit(
                scoped({
                  'command_reply': data['request'],
                  'ok': true,
                  'snapshot': scoped(engine.snapshot),
                }),
              );
            }
          }
          return null;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(record, null);
          messenger.setMockMethodCallHandler(fgs, null);
        });
        AudioApi api() => AudioApi(
          connection.base,
          client: MockClient((r) async {
            if (r.method == 'DELETE') {
              deletes++;
              return http.Response('', 204);
            }
            if (deletes > 0 && r.method == 'GET') {
              return http.Response(
                jsonEncode({
                  'error': {'code': 'not_found', 'message': 'Deleted'},
                }),
                404,
              );
            }
            if (r.method == 'POST') creations++;
            return http.Response(
              jsonEncode({
                'id': creations <= 1 ? 'A' : 'B',
                'status': 'ready_for_review',
                'transcript_id': 'source-A',
                'chunk_target_seconds': 30,
                'max_chunk_seconds': 60,
                'max_upload_bytes': 33554432,
                'max_chunks': 240,
              }),
              200,
            );
          }),
        );
        final rec = AndroidRecorder(
          connection: connection,
          directory: dir,
          contextWriter: (_) async {},
          audioApiFactory: api,
        );
        await rec.initialize();
        addTearDown(rec.dispose);
        await rec.start({'title': 'Test', 'folder_ids': []});
        final journal = AudioJournal(Directory('${dir.path}/active-audio'));
        await journal.load();
        journal.data['phase'] = 'review';
        journal.data['session'] = {
          'transcript_id': 'source-A',
          'boundary_warnings': [],
        };
        journal.saveSync();
        engine = AudioEngine(journal, api(), changed: (j) => emit(scoped(j)));
        addTearDown(engine.dispose);
        emit(scoped(journal.data));
        if (stopped) running = false;
        final repository = AudioDraftRepository(
          file: File('${dir.path}/audio-drafts.json'),
        );
        final regularApi = ApiClient(connection.base);
        final review = AudioReviewController(
          regularApi,
          MemoryStore(),
          rec,
          drafts: repository,
          audioApiFactory: api,
        );
        addTearDown(review.dispose);
        addTearDown(repository.dispose);
        addTearDown(regularApi.close);
        await review.saveDraft(Draft(title: 'Test', text: 'Test speech'));
        expect(await review.deleteMeeting(), isTrue);
        expect(deletes, 1);
        expect(repository.items, isEmpty);
        expect(review.draft.text, isEmpty);
        expect(rec.phase, 'done');
        expect(rec.active, isFalse);
        expect(rec.error, isNull);
        emit(scoped({'id': 'A', 'phase': 'review'}));
        expect(rec.active, isFalse);
        running = false;
        await rec.start({'title': 'Next', 'folder_ids': []});
        expect(rec.error, isNull);
        expect(rec.state['id'], 'B');
        expect(creations, 2);
        emit(scoped({'phase': 'done'}));
        expect(rec.state['id'], 'B');
      },
    );
  }
  test('foreign scope, stale service instance and another session cannot authorize service commands', () {
    final packet = {
      'connection_scope': 'scope-A',
      'service_instance': 'engine-A',
      'session_id': 'A',
    };
    expect(
      recorderCommandMatches(
        packet,
        scope: 'scope-B',
        instance: 'engine-A',
        sessionId: 'A',
      ),
      isFalse,
    );
    expect(
      recorderCommandMatches(
        packet,
        scope: 'scope-A',
        instance: 'engine-B',
        sessionId: 'A',
      ),
      isFalse,
    );
    expect(
      recorderCommandMatches(
        packet,
        scope: 'scope-A',
        instance: 'engine-A',
        sessionId: 'B',
      ),
      isFalse,
    );
    expect(
      recorderCommandMatches(
        packet,
        scope: 'scope-A',
        instance: 'engine-A',
        sessionId: 'A',
      ),
      isTrue,
    );
  });
}

import 'package:your_mettings/models/processing_options.dart';

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

class MemoryStore implements RecoveryStore {
  RecoveryState value = RecoveryState();
  @override
  Future<RecoveryState> load() async => value;
  @override
  Future<void> save(RecoveryState state) async {
    value = RecoveryState.fromJson(state.toJson());
  }
}

void main() {
  test('explicit confirmation PATCHes reviewed text and uses audio confirm only; lost ACK recovered', () async {
    var text = 'Original speech';
    var confirmed = false;
    var confirms = 0;
    final paths = <String>[];
    final store = MemoryStore();
    final recorder = RecorderCoordinator()
      ..state = {
        'id': 'session',
        'session': {'boundary_warnings': []},
      };
    final processing = {
      'transcript_id': 'transcript',
      'status': 'summarizing',
      'summary_id': null,
      'error': null,
    };
    http.Response response(Object json) => http.Response(jsonEncode(json), 200);
    Future<http.Response> backend(http.Request request) async {
      paths.add('${request.method} ${request.url.path}');
      final path = request.url.path;
      if (path.endsWith('/audio-sessions/session')) {
        return response({
          'status': confirmed ? 'completed' : 'ready_for_review',
          'transcript_id': 'transcript',
          'transcript_sha256': sha256.convert(utf8.encode(text)).toString(),
          'processing': processing,
          'parameters': {
            'title': 'Meeting',
            'folder_ids': ['folder'],
          },
        });
      }
      if (path.endsWith('/transcripts/transcript/processing')) {
        return response(processing);
      }
      if (path.endsWith('/transcripts/transcript')) {
        if (request.method == 'PATCH') {
          text = jsonDecode(request.body)['text'] as String;
        }
        return response({'id': 'transcript', 'text': text, 'is_locked': false});
      }
      if (path.endsWith('/confirm')) {
        confirms++;
        final input = jsonDecode(request.body);
        expect(
          input['reviewed_text_sha256'],
          sha256.convert(utf8.encode('Edited speech')).toString(),
        );
        expect(input['confirm'], true);
        expect(input['template_id'], 'chosen-template');
        confirmed = true;
        throw http.ClientException('response lost after commit');
      }
      if (path.endsWith('/folders')) return response({'items': []});
      fail('Unexpected endpoint $path');
    }

    final api = ApiClient(
      Uri.parse('http://example/api/v1/'),
      client: MockClient(backend),
    );
    final controller = AudioReviewController(
      api,
      store,
      recorder,
      audioApiFactory: () => AudioApi(api.baseUri, client: MockClient(backend)),
    );
    await controller.initialize();
    await controller.openReview();
    expect(confirms, 0);
    expect(controller.draft.text, 'Original speech');
    await controller.saveDraft(
      Draft(
        text: 'Edited speech',
        title: 'Meeting',
        folderIds: ['folder'],
        options: const ProcessingOptions(templateId: 'chosen-template'),
      ),
    );
    await controller.submit();
    expect(controller.error, isNotNull);
    expect(store.value.draft.text, 'Edited speech');
    await controller.submit();
    expect(controller.hasOperation, true);
    expect(confirms, 1);
    expect(store.value.operation!.id, 'transcript');
    expect(store.value.draft.text, isEmpty);
    expect(paths.any((p) => p.contains('transcripts/process')), false);
    expect(
      paths.where((p) => p == 'PATCH /api/v1/transcripts/transcript').length,
      1,
    );
    controller.dispose();
    api.close();
    recorder.dispose();
  });
}

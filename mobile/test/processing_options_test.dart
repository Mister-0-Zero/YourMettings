import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/models/processing_options.dart';
import 'package:your_mettings/services/recovery_store.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';

const chosen = ProcessingOptions(
  templateId: '019a0120-0000-7000-8000-000000000005',
  detailLevel: 'detailed',
  focusAreas: ['risks', 'tasks'],
  additionalInstructions: '  Сохрани технические детали.  ',
);
http.Response statusResponse([int code = 202]) => http.Response(
  jsonEncode({
    'transcript_id': 't1',
    'status': 'summarizing',
    'summary_id': null,
    'error': null,
  }),
  code,
);
void main() {
  test(
    'legacy recovery drafts and accepted operations use contract defaults',
    () {
      final old = RecoveryState.fromJson({
        'version': 1,
        'draft': {
          'text': 'Старый текст',
          'title': 'План',
          'folder_ids': ['f1'],
        },
        'pending': null,
        'operation': {
          'id': 't1',
          'title': 'План',
          'folder_ids': ['f1'],
        },
      });
      expect(old.draft.options.toJson(), const ProcessingOptions().toJson());
      expect(
        old.operation!.options.toJson(),
        const ProcessingOptions().toJson(),
      );
    },
  );
  test(
    'draft, pending and accepted settings survive real atomic storage',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yourmettings-options-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = FileRecoveryStore(File('${directory.path}/recovery.json'));
      final draft = Draft(
        text: 'Текст',
        title: 'План',
        folderIds: ['f1'],
        options: chosen,
      );
      await store.save(
        RecoveryState(draft: draft, pending: PendingRequest('stable', draft)),
      );
      final pending = await store.load();
      expect(pending.draft.options.toJson(), chosen.toJson());
      expect(pending.pending!.draft.options.toJson(), chosen.toJson());
      await store.save(
        RecoveryState(
          operation: AcceptedOperation('t1', 'План', ['f1'], chosen),
        ),
      );
      expect((await store.load()).operation!.options.toJson(), chosen.toJson());
    },
  );
  test('network replay retains all options and key even after attempted draft edits', () async {
    final requests = <http.Request>[];
    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      client: MockClient((request) async {
        requests.add(request);
        if (requests.length == 1) throw http.ClientException('Lost response');
        return statusResponse();
      }),
    );
    final controller = MeetingController(api, _MemoryStore());
    addTearDown(() {
      controller.dispose();
      api.close();
    });
    await controller.saveDraft(
      Draft(text: 'Текст', title: 'План', folderIds: ['f1'], options: chosen),
    );
    await controller.submit();
    await controller.saveDraft(
      Draft(
        text: 'Другой текст',
        options: const ProcessingOptions(detailLevel: 'brief'),
      ),
    );
    await controller.check();
    expect(requests.first.body, requests.last.body);
    expect(
      requests.first.headers['Idempotency-Key'],
      requests.last.headers['Idempotency-Key'],
    );
    final json = jsonDecode(requests.first.body) as Map<String, dynamic>;
    for (final entry in chosen.toJson().entries) {
      expect(json[entry.key], entry.value);
    }
  });
  test(
    'explicit error retry uses settings retained for accepted operation',
    () async {
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((request) async {
          if (request.method == 'POST') {
            expect(request.url.path, '/api/v1/transcripts/t1/process');
            expect(jsonDecode(request.body), {
              'title': 'План',
              'folder_ids': ['f1'],
              ...chosen.toJson(),
            });
          }
          return statusResponse(request.method == 'POST' ? 202 : 200);
        }),
      );
      final controller = MeetingController(api, _MemoryStore());
      controller.recovery = RecoveryState(
        operation: AcceptedOperation('t1', 'План', ['f1'], chosen),
      );
      addTearDown(() {
        controller.dispose();
        api.close();
      });
      await controller.retry();
    },
  );
  test(
    'changing options before a new accepted request uses a new operation key',
    () async {
      final keys = <String>[];
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((request) async {
          keys.add(request.headers['Idempotency-Key']!);
          if (keys.length == 1) {
            return http.Response(
              jsonEncode({
                'error': {
                  'code': 'validation_error',
                  'message': 'Ошибка ввода',
                },
              }),
              422,
              headers: {'content-type': 'application/json'},
            );
          }
          expect(jsonDecode(request.body)['detail_level'], 'brief');
          return statusResponse();
        }),
      );
      final controller = MeetingController(api, _MemoryStore());
      addTearDown(() {
        controller.dispose();
        api.close();
      });
      await controller.saveDraft(
        Draft(text: 'Текст', title: 'План', folderIds: ['f1'], options: chosen),
      );
      await controller.submit();
      await controller.saveDraft(
        Draft(
          text: 'Текст',
          title: 'План',
          folderIds: ['f1'],
          options: const ProcessingOptions(detailLevel: 'brief'),
        ),
      );
      await controller.submit();
      expect(keys.length, 2);
      expect(keys.first, isNot(keys.last));
    },
  );
}

class _MemoryStore implements RecoveryStore {
  RecoveryState state = RecoveryState();
  @override
  Future<RecoveryState> load() async => state;
  @override
  Future<void> save(RecoveryState value) async {
    state = value;
  }
}

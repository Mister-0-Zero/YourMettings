import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/services/recovery_store.dart';

http.Response response(Object value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status);
const processing = {
  'transcript_id': 't1',
  'status': 'summarizing',
  'summary_id': null,
  'error': null,
};
const ready = {
  'transcript_id': 't1',
  'status': 'ready',
  'summary_id': 's1',
  'error': null,
};
const summary = {
  'id': 's1',
  'transcript_id': 't1',
  'title': 'План',
  'content': '## Решения\nВыпустить продукт.',
  'folder_ids': ['f1'],
  'created_at': '2026-10-13T12:00:00Z',
  'updated_at': '2026-10-13T12:00:00Z',
};

void main() {
  late Directory directory;
  late FileRecoveryStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'yourmettings-recovery-test-',
    );
    store = FileRecoveryStore(File('${directory.path}/recovery.json'));
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('serialized atomic saves retain the latest unfinished input', () async {
    await Future.wait([
      store.save(RecoveryState(draft: Draft(text: 'Первый текст'))),
      store.save(
        RecoveryState(
          draft: Draft(
            text: 'Последний текст',
            title: 'План',
            folderIds: ['f1'],
          ),
        ),
      ),
    ]);
    final restored = await store.load();
    expect(restored.draft.text, 'Последний текст');
    expect(restored.draft.title, 'План');
    expect(restored.draft.folderIds, ['f1']);
    expect(await File('${store.file.path}.tmp').exists(), isFalse);
  });

  test('ambiguous network failure retains replay key/payload; acceptance replaces text with id', () async {
    final requests = <http.Request>[];
    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      client: MockClient((request) async {
        requests.add(request);
        if (requests.length == 1) throw http.ClientException('lost response');
        return response(processing, 202);
      }),
    );
    final controller = MeetingController(api, store);
    addTearDown(() {
      controller.dispose();
      api.close();
    });
    await controller.saveDraft(
      Draft(text: 'Тестовый транскрипт', title: 'План', folderIds: ['f1']),
    );
    await controller.submit();
    final before = await store.load();
    expect(before.pending, isNotNull);
    expect(before.draft.text, 'Тестовый транскрипт');
    await controller.check();
    expect(requests.first.body, requests.last.body);
    expect(
      requests.first.headers['Idempotency-Key'],
      requests.last.headers['Idempotency-Key'],
    );
    final after = await store.load();
    expect(after.operation!.id, 't1');
    expect(after.pending, isNull);
    expect(after.draft.text, isEmpty);
    expect(
      await store.file.readAsString(),
      isNot(contains('Тестовый транскрипт')),
    );
  });

  test('app restart checks accepted id and loads ready summary without another POST', () async {
    await store.save(
      RecoveryState(operation: AcceptedOperation('t1', 'План', ['f1'])),
    );
    final requests = <http.Request>[];
    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      client: MockClient((request) async {
        requests.add(request);
        return response(switch (request.url.path) {
          '/api/v1/transcripts/t1/processing' => ready,
          '/api/v1/summaries/s1' => summary,
          '/api/v1/folders' => {'items': []},
          _ => throw StateError('Unexpected endpoint ${request.url}'),
        });
      }),
    );
    final controller = MeetingController(api, store);
    addTearDown(() {
      controller.dispose();
      api.close();
    });
    await controller.initialize();
    for (var i = 0; i < 100 && controller.working; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(controller.result!.content, contains('## Решения'));
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    await controller.finish();
    expect((await store.load()).operation, isNull);
  });

  test('validation rejection retains editable draft instead of a pending operation', () async {
    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      client: MockClient(
        (_) async => response({
          'error': {
            'code': 'validation_error',
            'message': 'Неверный ввод',
            'details': {},
          },
        }, 422),
      ),
    );
    final controller = MeetingController(api, store);
    addTearDown(() {
      controller.dispose();
      api.close();
    });
    await controller.saveDraft(
      Draft(text: 'Сохранить меня', title: 'План', folderIds: ['f1']),
    );
    await controller.submit();
    expect(controller.hasOperation, isFalse);
    expect((await store.load()).draft.text, 'Сохранить меня');
  });

  test('storage failure prevents sending a new server operation', () async {
    var sends = 0;
    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      client: MockClient((_) async {
        sends++;
        return response(processing, 202);
      }),
    );
    final controller = MeetingController(api, _BrokenStore());
    addTearDown(() {
      controller.dispose();
      api.close();
    });
    await controller.saveDraft(
      Draft(text: 'Тест', title: 'План', folderIds: ['f1']),
    );
    await controller.submit();
    expect(sends, 0);
    expect(controller.storageError, isNotNull);
    expect(controller.draft.text, 'Тест');
  });
}

class _BrokenStore implements RecoveryStore {
  @override
  Future<RecoveryState> load() async => RecoveryState();
  @override
  Future<void> save(RecoveryState state) async =>
      throw const FileSystemException('Disk unavailable');
}

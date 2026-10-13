import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/app/config.dart';
import 'package:your_mettings/models/api_models.dart';

const base = 'http://localhost:8000/api/v1/';
Map<String, dynamic> status({String phase = 'summarizing'}) => {
  'transcript_id': 't1',
  'status': phase,
  'summary_id': phase == 'ready' ? 's1' : null,
  'error': null,
};
http.Response jsonResponse(Object body, [int code = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), code);

void main() {
  test('submit and network replay use one atomic endpoint and identical payload/key', () async {
    final requests = <http.Request>[];
    final api = ApiClient(
      Uri.parse(base),
      client: MockClient((request) async {
        requests.add(request);
        return jsonResponse(
          status(phase: requests.length == 1 ? 'summarizing' : 'ready'),
          202,
        );
      }),
    );
    addTearDown(api.close);
    for (var i = 0; i < 2; i++) {
      await api.submitTranscript(
        text: 'Иван: решение',
        title: 'План',
        folderIds: ['f1'],
        idempotencyKey: 'stable-key',
      );
    }
    expect(
      requests.map((r) => r.url.path),
      everyElement('/api/v1/transcripts/process'),
    );
    expect(requests.map((r) => r.method), everyElement('POST'));
    expect(
      requests.map((r) => r.headers['Idempotency-Key']),
      everyElement('stable-key'),
    );
    expect(requests.first.body, requests.last.body);
    expect(jsonDecode(requests.first.body), {
      'text': 'Иван: решение',
      'title': 'План',
      'folder_ids': ['f1'],
    });
  });

  test('generation retry uses existing transcript id without creating another transcript', () async {
    final api = ApiClient(
      Uri.parse(base),
      client: MockClient((request) async {
        expect(request.url.path, '/api/v1/transcripts/t1/process');
        expect(jsonDecode(request.body), {
          'title': 'План',
          'folder_ids': ['f1'],
        });
        expect(request.headers.containsKey('Idempotency-Key'), isFalse);
        return jsonResponse(status(), 202);
      }),
    );
    addTearDown(api.close);
    expect(
      (await api.retryProcessing('t1', 'План', ['f1'])).phase,
      ProcessingPhase.summarizing,
    );
  });

  test('folder list preserves nesting and paths', () async {
    final api = ApiClient(
      Uri.parse(base),
      client: MockClient(
        (_) async => jsonResponse({
          'items': [
            {
              'id': 'f1',
              'name': 'Проект',
              'parent_id': null,
              'children': [
                {'id': 'f2', 'name': 'План', 'parent_id': 'f1', 'children': []},
              ],
            },
          ],
        }),
      ),
    );
    addTearDown(api.close);
    final entries = flattenFolders(await api.folders());
    expect(entries.map((e) => e.depth), [0, 1]);
    expect(entries.last.path, 'Проект / План');
  });

  test(
    'summary listing sends immediate folder and pagination parameters',
    () async {
      final api = ApiClient(
        Uri.parse(base),
        client: MockClient((request) async {
          expect(request.url.queryParameters, {
            'folder_id': 'f2',
            'limit': '20',
            'offset': '20',
          });
          return jsonResponse({
            'items': [],
            'total': 20,
            'limit': 20,
            'offset': 20,
          });
        }),
      );
      addTearDown(api.close);
      expect((await api.summaries('f2', offset: 20)).hasMore, isFalse);
    },
  );

  test('204 delete supports an empty response', () async {
    final api = ApiClient(
      Uri.parse(base),
      client: MockClient((request) async {
        expect(request.method, 'DELETE');
        expect(request.url.path, '/api/v1/summaries/s1');
        return http.Response('', 204);
      }),
    );
    addTearDown(api.close);
    await api.deleteSummary('s1');
  });

  test('server errors preserve code, status and Russian message', () async {
    final api = ApiClient(
      Uri.parse(base),
      client: MockClient(
        (_) async => jsonResponse({
          'error': {
            'code': 'idempotency_conflict',
            'message': 'Параметры изменились.',
            'details': {},
          },
        }, 409),
      ),
    );
    addTearDown(api.close);
    await expectLater(
      api.processing('t1'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', 'idempotency_conflict')
            .having((e) => e.statusCode, 'status', 409)
            .having((e) => e.message, 'message', 'Параметры изменились.'),
      ),
    );
  });

  test('network timeout is distinguishable from a generation error', () async {
    final api = ApiClient(
      Uri.parse(base),
      timeout: const Duration(milliseconds: 5),
      client: MockClient((_) => Completer<http.Response>().future),
    );
    addTearDown(api.close);
    await expectLater(
      api.processing('t1'),
      throwsA(
        isA<ApiException>().having((e) => e.isNetwork, 'network', isTrue),
      ),
    );
  });

  test(
    'unknown processing phases and ready without summary id are rejected',
    () {
      expect(
        () => ProcessingStatus.fromJson(status(phase: 'uploaded')),
        throwsFormatException,
      );
      expect(
        () => ProcessingStatus.fromJson({
          ...status(phase: 'ready'),
          'summary_id': null,
        }),
        throwsFormatException,
      );
    },
  );

  test('configuration normalizes base URL and rejects HTTP in release', () {
    expect(
      AppConfig.apiBaseUri(value: 'http://localhost:8000/api/v1').toString(),
      base,
    );
    expect(
      () => AppConfig.apiBaseUri(value: base, release: true),
      throwsFormatException,
    );
    expect(
      () => AppConfig.apiBaseUri(value: 'http://localhost:8000'),
      throwsFormatException,
    );
    expect(
      AppConfig.apiBaseUri(
        value: 'https://example.com/api/v1',
        release: true,
      ).scheme,
      'https',
    );
  });
}

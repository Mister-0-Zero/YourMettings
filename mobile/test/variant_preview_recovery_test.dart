import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/models/summary_template.dart';
import 'package:your_mettings/services/operation_store.dart';
import 'package:your_mettings/features/templates/template_preview_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final input = TemplateInput(
    name: 'Plan',
    sections: [
      TemplateSection(
        id: '10000000-0000-4000-8000-000000000001',
        title: 'Results',
        instruction: 'Keep facts',
      ),
    ],
  );
  test('full bundled source is sent exactly and unknown POST reuses its key after restart', () async {
    final source = await File('assets/meeting_examples/weekly_planning.txt')
        .readAsString();
    final store = OperationStore();
    final requests = <http.Request>[];
    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      operations: store,
      client: MockClient((r) async {
        requests.add(r);
        if (requests.length == 1) throw http.ClientException('lost response');
        return http.Response(
          jsonEncode({
            'id': 'preview',
            'status': 'ready',
            'content': '## Result',
            'navigation': [],
            'error': null,
          }),
          202,
        );
      }),
    );
    addTearDown(api.close);
    final first = TemplatePreviewSession(api);
    first.text.text = source;
    await first.start(input);
    expect(first.uncertain, isTrue);
    first.dispose();
    final restored = TemplatePreviewSession(api);
    addTearDown(restored.dispose);
    expect(restored.text.text, source);
    await restored.start(input);
    expect(requests.length, 2);
    expect(jsonDecode(requests.last.body)['text'], source);
    expect(requests.first.bodyBytes, requests.last.bodyBytes);
    expect(
      requests.first.headers['Idempotency-Key'],
      requests.last.headers['Idempotency-Key'],
    );
    expect(restored.preview!.status, 'ready');
    await restored.start(input);
    expect(
      requests.last.headers['Idempotency-Key'],
      isNot(requests.first.headers['Idempotency-Key']),
    );
  });
  test('switching to a bundled example does not overwrite custom text', () {
    final api = ApiClient(Uri.parse('http://localhost/api/v1/'));
    addTearDown(api.close);
    final session = TemplatePreviewSession(api);
    addTearDown(session.dispose);
    session.text.text = 'My own meeting';
    session.chooseExample(
      id: 'example',
      title: 'Meeting',
      content: 'Example source',
    );
    expect(session.source, 'Example source');
    session.chooseExample();
    expect(session.source, 'My own meeting');
  });
}

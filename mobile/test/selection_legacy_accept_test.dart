import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:your_mettings/features/selections/selection_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/selections/selection_controller.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/models/processing_options.dart';
import 'package:your_mettings/services/operation_store.dart';

import 'selection_recovery_test.dart' show response;

class LegacyServer {
  String title = 'Meeting', content = '**Candidate**';
  int revision = 1;
  bool loseAccept = false, losePatch = false, race = false;
  Json? receipt;
  final calls = <http.Request>[];
  Json summary() => {
    'id': 'summary',
    'transcript_id': 'source',
    'title': title,
    'content': content,
    'version': 'v$revision',
    'folder_ids': ['folder'],
    'created_at': '2026-10-31T00:00:00Z',
    'updated_at': '2026-10-31T00:00:00Z',
    'template_snapshot': {'name': 'Selected'},
    'navigation': [],
  };
  Future<http.Response> handle(http.Request r) async {
    calls.add(r);
    if (r.method == 'GET' && r.url.path.endsWith('/summaries/summary')) {
      final snapshot = summary();
      if (race) {
        race = false;
        title = 'Racing title';
        revision++;
      }
      return response(snapshot);
    }
    if (r.url.path.endsWith('/accept')) {
      expect(jsonDecode(r.body), {
        'candidate_id': 'candidate',
        'expected_version': 'opening-version',
      });
      receipt ??= summary();
      if (loseAccept) {
        loseAccept = false;
        throw http.ClientException('lost legacy accept');
      }
      return response(receipt!);
    }
    if (r.method == 'PATCH') {
      final body = jsonDecode(r.body) as Json;
      if (body['expected_version'] != 'v$revision') {
        return response({
          'error': {
            'code': 'summary_version_conflict',
            'message': 'CAS conflict',
          },
        }, 409);
      }
      title = body['title'] as String? ?? title;
      content = body['content'] as String? ?? content;
      revision++;
      if (losePatch) {
        losePatch = false;
        throw http.ClientException('lost PATCH');
      }
      return response(summary());
    }
    throw StateError('Unexpected request: ${r.method} ${r.url.path}');
  }
}

Json checkpoint({Json? receipt}) => {
  'session_id': 'selection',
  'summary_version': 'opening-version',
  'accept_id': 'candidate',
  'active_id': 'candidate',
  'candidate_ids': ['candidate'],
  'accept_edit': {'content': '**Edited locally**'},
  'edits': {
    'candidate': {'content': '**Edited locally**'},
  },
  if (receipt != null) ...{
    'accepted_summary_id': 'summary',
    'receipt': receipt,
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SelectionController create(LegacyServer server, OperationStore store) {
    final api = ApiClient(
      Uri.parse('http://example/api/v1/'),
      client: MockClient(server.handle),
    );
    addTearDown(api.close);
    final c = SelectionController(
      api: api,
      store: store,
      slot: 'legacy',
      source: () async =>
          throw StateError('Do not recreate accepted selection'),
      initialOptions: const ProcessingOptions(),
    );
    addTearDown(c.dispose);
    return c;
  }

  test('legacy receipt preserves concurrent unrelated title and CAS patches only content', () async {
    final server = LegacyServer();
    final receipt = server.summary()
      ..remove('transcript_id')
      ..remove('folder_ids')
      ..remove('created_at')
      ..remove('updated_at');
    server.title = 'External title';
    server.revision++;
    final store = OperationStore();
    await store.put('legacy', checkpoint(receipt: receipt));
    final c = create(server, store);
    await c.initialize();
    expect(c.accepted?.content, '**Edited locally**');
    expect(c.accepted?.title, 'External title');
    expect(c.state['accept_id'], 'candidate');
    expect(c.state['receipt'], receipt);
    expect(server.calls.where((r) => r.url.path.endsWith('/accept')), isEmpty);
    final body = jsonDecode(server.calls.last.body) as Json;
    expect(body, {'content': '**Edited locally**', 'expected_version': 'v2'});
  });

  test('legacy CAS race gets visible conflict and explicit retry survives disk restart', () async {
    final dir = Directory.systemTemp.createTempSync('ym-legacy-cas-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/operations.json');
    final server = LegacyServer()..race = true;
    final receipt = server.summary();
    final store = OperationStore(file: file);
    await store.put('legacy', checkpoint(receipt: receipt));
    final c = create(server, store);
    await c.initialize();
    c.pause();
    expect(c.accepted, isNull);
    expect(c.editConflict, isTrue);
    expect(c.state['accept_id'], 'candidate');
    expect(c.frozen, isTrue);
    expect(c.content, '**Edited locally**');
    final patchCount = server.calls.where((r) => r.method == 'PATCH').length;
    final restoredStore = OperationStore(file: file);
    await restoredStore.load();
    final next = create(server, restoredStore);
    await next.initialize();
    next.pause();
    expect(next.editConflict, isTrue);
    expect(
      server.calls.where((r) => r.method == 'PATCH'),
      hasLength(patchCount),
    );
    await next.retryEditsOverCurrent();
    expect(next.accepted?.content, '**Edited locally**');
    expect(next.accepted?.title, 'Racing title');
    expect(next.state['receipt'], receipt);
    expect(server.calls.where((r) => r.url.path.endsWith('/accept')), isEmpty);
  });

  test('legacy lost accept replays old exact payload and reconciles lost CAS PATCH', () async {
    final server = LegacyServer()..loseAccept = true;
    final store = OperationStore();
    await store.put('legacy', checkpoint());
    final c = create(server, store);
    await c.initialize();
    c.pause();
    expect(c.accepted, isNull);
    expect(c.frozen, isTrue);
    server.losePatch = true;
    await c.refresh();
    c.pause();
    expect(c.accepted, isNull);
    final acceptedReceipt = c.state['receipt'];
    await c.refresh();
    expect(c.accepted?.content, '**Edited locally**');
    expect(c.state['receipt'], acceptedReceipt);
    expect(server.calls.where((r) => r.method == 'PATCH'), hasLength(1));
    final accepts = server.calls
        .where((r) => r.url.path.endsWith('/accept'))
        .toList();
    expect(accepts, hasLength(2));
    expect(accepts[0].body, accepts[1].body);
  });
  testWidgets(
    'legacy CAS conflict exposes working confirmation rather than an endless retry',
    (tester) async {
      final server = LegacyServer()..race = true;
      final store = OperationStore();
      await store.put('legacy', checkpoint(receipt: server.summary()));
      final api = ApiClient(
        Uri.parse('http://example/api/v1/'),
        operations: store,
        client: MockClient(server.handle),
      );
      addTearDown(api.close);
      MeetingSummary? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SelectionPage(
                      api: api,
                      slot: 'legacy',
                      source: () async => throw StateError('No new session'),
                      options: const ProcessingOptions(),
                      title: 'Meeting',
                      onAccepted: (summary) async {
                        saved = summary;
                      },
                    ),
                  ),
                ),
                child: const Text('Resume'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();
      expect(find.text('Повторить сохранение'), findsOneWidget);
      expect(find.text('Edited locally'), findsOneWidget);
      await tester.tap(find.text('Повторить сохранение'));
      await tester.pumpAndSettle();
      expect(find.text('Заменить изменённые поля?'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(server.calls.where((r) => r.method == 'PATCH'), hasLength(1));
      await tester.tap(find.text('Повторить сохранение'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить мои правки'));
      await tester.pumpAndSettle();
      expect(saved?.content, '**Edited locally**');
      expect(saved?.title, 'Racing title');
      expect(find.byType(SelectionPage), findsNothing);
      expect(store['legacy'], isNull);
      expect(
        server.calls.where((r) => r.url.path.endsWith('/accept')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('visible legacy content conflict requires consent and never changes frozen edit intent', () async {
    final server = LegacyServer();
    final receipt = server.summary();
    server.content = '**External change**';
    server.revision++;
    final store = OperationStore();
    await store.put('legacy', checkpoint(receipt: receipt));
    final c = create(server, store);
    await c.initialize();
    c.pause();
    expect(c.editConflict, isTrue);
    final intent = jsonEncode(c.state['accept_edit']);
    expect(server.calls.where((r) => r.method == 'PATCH'), isEmpty);
    await c.refresh();
    c.pause();
    expect(server.calls.where((r) => r.method == 'PATCH'), isEmpty);
    await c.retryEditsOverCurrent();
    expect(c.accepted?.content, '**Edited locally**');
    expect(jsonEncode(c.state['accept_edit']), intent);
    expect(c.state['receipt'], receipt);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/selections/selection_controller.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/models/processing_options.dart';
import 'package:your_mettings/services/operation_store.dart';

import 'selection_recovery_test.dart' show Server, response;

class DraftServer extends Server {
  bool losePatch = false, rejectPatch = false;
  String currentTitle = 'Meeting';
  @override
  Json summary() => {...super.summary(), 'title': currentTitle};
  @override
  Future<http.Response> handle(http.Request r) async {
    if (r.method == 'PATCH' && r.url.path.endsWith('/summaries/summary')) {
      calls.add(r);
      if (rejectPatch) {
        return response({
          'error': {'code': 'storage_busy', 'message': 'Try again'},
        }, 409);
      }
      final body = jsonDecode(r.body) as Json;
      if (body.containsKey('content')) content = body['content'] as String;
      if (body.containsKey('title')) currentTitle = body['title'] as String;
      if (losePatch) {
        losePatch = false;
        throw http.ClientException('Lost PATCH reply');
      }
      return response(summary());
    }
    return super.handle(r);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SelectionController create(
    DraftServer server,
    OperationStore store, {
    MeetingSummary? original,
  }) {
    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      client: MockClient(server.handle),
    );
    addTearDown(api.close);
    final c = SelectionController(
      api: api,
      store: store,
      slot: 'drafts',
      source: () async => original == null
          ? {
              'text': 'Full source',
              'title': 'Meeting',
              'folder_ids': ['folder'],
            }
          : {'summary_id': original.id},
      initialOptions: const ProcessingOptions(),
      original: original,
    );
    addTearDown(c.dispose);
    return c;
  }

  test('separate edited variants survive reload; only the active fields are patched after accept', () async {
    final dir = await Directory.systemTemp.createTemp('ym-variant-edits-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/operations.json');
    final store = OperationStore(file: file), server = DraftServer();
    final c = create(server, store);
    await c.initialize();
    await c.editActive(title: 'Meeting', content: '## Edited A');
    await c.generate(const ProcessingOptions(templateId: 'B'));
    await c.editActive(title: 'Title B', content: '## Edited B');
    await c.move(-1);
    expect(c.content, '## Edited A');
    expect(c.title, 'Meeting');
    expect(server.calls.where((r) => r.method == 'PATCH'), isEmpty);
    c.pause();
    final restoredStore = OperationStore(file: file);
    await restoredStore.load();
    final restored = create(server, restoredStore);
    await restored.initialize();
    expect(restored.content, '## Edited A');
    server.currentTitle = 'Server renamed';
    await restored.accept();
    expect(restored.accepted!.content, '## Edited A');
    expect(restored.accepted!.title, 'Server renamed');
    expect(server.acceptedId, 'A');
    final patches = server.calls.where((r) => r.method == 'PATCH');
    expect(patches.length, 1);
    expect(jsonDecode(patches.single.body), {'content': '## Edited A'});
  });
  test('lost PATCH reply is reconciled after restart without a second accept or overwrite', () async {
    final server = DraftServer()..losePatch = true;
    final store = OperationStore();
    // Use a shared durable checkpoint for the restored controller.
    final first = create(server, store);
    await first.initialize();
    await first.editActive(title: 'Meeting', content: '## Local text');
    await first.accept();
    first.pause();
    expect(first.accepted, isNull);
    expect(first.frozen, isTrue);
    final restored = create(server, store);
    await restored.initialize();
    expect(restored.accepted!.content, '## Local text');
    expect(server.calls.where((r) => r.url.path.endsWith('/accept')).length, 1);
    expect(server.calls.where((r) => r.method == 'PATCH').length, 1);
  });
  test(
    'definite PATCH failure retains frozen choice and edits for explicit retry',
    () async {
      final server = DraftServer()..rejectPatch = true;
      final c = create(server, OperationStore());
      await c.initialize();
      await c.editActive(title: 'Edited title', content: '## Edited content');
      await c.accept();
      expect(c.accepted, isNull);
      expect(c.frozen, isTrue);
      expect(c.content, '## Edited content');
      expect(c.error, contains('Try again'));
      expect(c.canEdit, isTrue);
      await c.editActive(
        title: 'Corrected title',
        content: '## Corrected content',
      );
      server.rejectPatch = false;
      await c.accept();
      expect(c.accepted!.title, 'Corrected title');
      expect(c.accepted!.content, '## Corrected content');
      expect(
        server.calls.where((r) => r.url.path.endsWith('/accept')).length,
        1,
      );
    },
  );
  test('saved original uses its opening baseline and requires consent over concurrent edits', () async {
    final server = DraftServer()..content = '## Original';
    final c = create(
      server,
      OperationStore(),
      original: MeetingSummary.fromJson(server.summary()),
    );
    await c.initialize();
    await c.editActive(title: 'Meeting', content: '## Local edit');
    server.content = '## External edit';
    await c.accept();
    expect(c.accepted, isNull);
    expect(c.editConflict, isTrue);
    expect(c.content, '## Local edit');
    expect(server.content, '## External edit');
    expect(server.calls.where((r) => r.method == 'PATCH'), isEmpty);
    await c.retryEditsOverCurrent();
    expect(c.accepted!.content, '## Local edit');
  });
}

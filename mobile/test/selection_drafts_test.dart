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
  bool losePatch = false, rejectPatch = false, oldBackend = false;
  @override
  Future<http.Response> handle(http.Request r) async {
    if (oldBackend && r.url.path.endsWith('/accept')) {
      calls.add(r);
      return response({
        'error': {
          'code': 'validation_error',
          'message': 'Unsupported edit fields',
        },
      }, 422);
    }
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

class IntentFaultStore extends OperationStore {
  bool fail = false;
  @override
  Future<void> put(String slot, Json value) {
    if (fail) throw const FileSystemException('Checkpoint failed');
    return super.put(slot, value);
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

  test('edited variants survive reload and active title/content are accepted atomically', () async {
    final dir = await Directory.systemTemp.createTemp('ym-variant-edits-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/operations.json');
    final store = OperationStore(file: file), server = DraftServer();
    final c = create(server, store);
    await c.initialize();
    await c.editActive(title: 'Title A', content: '## Edited A');
    await c.generate(const ProcessingOptions(templateId: 'B'));
    await c.editActive(title: 'Title B', content: '## Edited B');
    await c.move(-1);
    c.pause();
    final restoredStore = OperationStore(file: file);
    await restoredStore.load();
    final restored = create(server, restoredStore);
    await restored.initialize();
    await restored.accept();
    expect(restored.accepted!.content, '## Edited A');
    expect(restored.accepted!.title, 'Title A');
    expect(server.calls.where((r) => r.method == 'PATCH'), isEmpty);
    expect(server.acceptIntent, {
      'candidate_id': 'A',
      'expected_version': 'original-version',
      'title': 'Title A',
      'content': '## Edited A',
    });
  });
  test('lost atomic accept freezes exact edited payload across disk restart and returns immutable receipt', () async {
    final dir = await Directory.systemTemp.createTemp('ym-accept-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/operations.json');
    final server = DraftServer()..loseAccept = true;
    final first = create(server, OperationStore(file: file));
    await first.initialize();
    await first.editActive(title: 'Local title', content: '## Local text');
    await first.accept();
    first.pause();
    expect(first.accepted, isNull);
    expect(first.frozen, isTrue);
    expect(first.canEdit, isFalse);
    await expectLater(
      first.editActive(title: 'Different', content: 'Different'),
      throwsStateError,
    );
    // Another editor changes the live summary after our accept committed.
    server.content = '## External edit';
    server.currentTitle = 'External title';
    final restoredStore = OperationStore(file: file);
    await restoredStore.load();
    final restored = create(server, restoredStore);
    await restored.initialize();
    expect(restored.accepted!.content, '## Local text');
    expect(restored.accepted!.title, 'Local title');
    final accepts = server.calls
        .where((r) => r.url.path.endsWith('/accept'))
        .toList();
    expect(accepts.length, 2);
    expect(accepts[0].body, accepts[1].body);
    expect(server.content, '## External edit');
    expect(server.calls.where((r) => r.method == 'PATCH'), isEmpty);
  });
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
  test('atomic accept never posts before durable exact intent and never falls back to PATCH on rejection', () async {
    final server = DraftServer();
    final store = IntentFaultStore();
    final c = create(server, store);
    await c.initialize();
    await c.editActive(title: 'Edited', content: '**Content**');
    store.fail = true;
    await c.accept();
    c.pause();
    expect(server.calls.where((r) => r.url.path.endsWith('/accept')), isEmpty);
    expect(c.accepted, isNull);
    expect(c.frozen, isTrue);
    expect(c.canEdit, isFalse);
    store.fail = false;
    server.conflict = true;
    await c.refresh();
    c.pause();
    expect(c.accepted, isNull);
    expect(server.calls.where((r) => r.method == 'PATCH'), isEmpty);
    final accept = server.calls.lastWhere(
      (r) => r.url.path.endsWith('/accept'),
    );
    expect(jsonDecode(accept.body), {
      'candidate_id': 'A',
      'expected_version': 'original-version',
      'title': 'Edited',
      'content': '**Content**',
    });
    expect(c.state['accept_edit'], {
      'title': 'Edited',
      'content': '**Content**',
    });
  });
  test('old backend 422 retains frozen draft and exact request until upgraded, without PATCH fallback', () async {
    final dir = await Directory.systemTemp.createTemp('ym-atomic-upgrade-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/operations.json');
    final server = DraftServer()..oldBackend = true;
    final c = create(server, OperationStore(file: file));
    await c.initialize();
    await c.editActive(title: 'Local title', content: '**Edited content**');
    await c.accept();
    c.pause();
    expect(c.frozen, isTrue);
    expect(c.accepted, isNull);
    expect(c.activeId, 'A');
    expect(c.content, '**Edited content**');
    final originalRequest = server.calls
        .lastWhere((r) => r.url.path.endsWith('/accept'))
        .body;
    final restoredStore = OperationStore(file: file);
    await restoredStore.load();
    expect(restoredStore['drafts']!['accept_protocol'], 'atomic-v1');
    final next = create(server, restoredStore);
    await next.initialize();
    next.pause();
    expect(next.frozen, isTrue);
    expect(next.content, '**Edited content**');
    expect(server.calls.where((r) => r.method == 'PATCH'), isEmpty);
    server.oldBackend = false;
    await next.refresh();
    expect(next.accepted?.content, '**Edited content**');
    expect(next.accepted?.title, 'Local title');
    expect(server.calls.where((r) => r.method == 'PATCH'), isEmpty);
    expect(
      server.calls
          .where((r) => r.url.path.endsWith('/accept'))
          .every((r) => r.body == originalRequest),
      isTrue,
    );
  });
}

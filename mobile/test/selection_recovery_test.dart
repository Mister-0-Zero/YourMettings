import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/models/processing_options.dart';
import 'package:your_mettings/models/generation_source.dart';
import 'package:your_mettings/services/operation_store.dart';
import 'package:your_mettings/features/selections/selection_controller.dart';

http.Response response(Object value, [int code = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), code);

class Server {
  final calls = <http.Request>[];
  final keys = <String, String>{};
  final variants = <String, Json>{};
  String status = 'open', content = 'initial';
  String? acceptedId;
  bool loseOpen = false,
      loseCandidate = false,
      loseAccept = false,
      loseCancel = false,
      conflict = false;
  Json summary() => {
    'id': 'summary',
    'transcript_id': 'source',
    'title': 'Meeting',
    'content': content,
    'folder_ids': ['folder'],
    'created_at': '2026-10-24T00:00:00Z',
    'updated_at': '2026-10-24T00:00:00Z',
    'version': 'latest-version',
    'template_snapshot': {'name': acceptedId},
    'navigation': [],
  };
  Json selection() => {
    'id': 'selection',
    'status': status,
    'transcript_id': 'source',
    'summary_id': null,
    'summary_version': 'original-version',
    'expires_at': '2026-10-25T00:00:00Z',
    'accepted_candidate_id': acceptedId,
    'candidates': variants.values.toList(),
  };
  Future<http.Response> handle(http.Request r) async {
    calls.add(r);
    final path = r.url.path;
    if (r.method == 'GET' && path.endsWith('/summaries/summary')) {
      return response(summary());
    }
    if (r.method == 'POST' && path.endsWith('/summary-selections')) {
      if (loseOpen) {
        loseOpen = false;
        throw http.ClientException('lost reply');
      }
      return response(selection(), 201);
    }
    if (r.method == 'GET' && path.endsWith('/summary-selections/selection')) {
      return response(selection());
    }
    if (r.method == 'DELETE') {
      expect(r.url.queryParameters['confirm'], 'true');
      status = 'cancelled';
      if (loseCancel) {
        loseCancel = false;
        throw http.ClientException('lost cancel');
      }
      return http.Response('', 204);
    }
    if (path.endsWith('/candidates')) {
      final key = r.headers['Idempotency-Key']!;
      final body = jsonDecode(r.body) as Json;
      final template = body['template_id'] as String? ?? 'A';
      final id = keys.putIfAbsent(key, () => template);
      variants.putIfAbsent(
        id,
        () => {
          'id': id,
          'selection_id': 'selection',
          'status': 'ready',
          'content': '## Variant $id',
          'template_snapshot': {'name': template},
          'generation_options': body,
          'navigation': [],
          'error': null,
        },
      );
      if (loseCandidate) {
        loseCandidate = false;
        throw http.ClientException('lost candidate');
      }
      return response(variants[id]!, 202);
    }
    if (path.endsWith('/accept')) {
      if (conflict) {
        return response({
          'error': {'code': 'summary_version_conflict', 'message': 'Conflict'},
        }, 409);
      }
      final body = jsonDecode(r.body) as Json;
      expect(body['expected_version'], 'original-version');
      acceptedId ??= body['candidate_id'] as String;
      status = 'accepted';
      content = variants[acceptedId]!['content'] as String;
      if (loseAccept) {
        loseAccept = false;
        throw http.ClientException('lost accept');
      }
      return response(summary());
    }
    throw StateError('Unexpected request: ${r.method} $path');
  }
}

class FailingStore extends OperationStore {
  @override
  Future<void> put(String slot, Json value) =>
      Future.error(const FileSystemException('disk full'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SelectionController create(Server server, OperationStore store) {
    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      client: MockClient(server.handle),
    );
    addTearDown(api.close);
    final controller = SelectionController(
      api: api,
      store: store,
      slot: 'test',
      source: () async => {
        'text': 'Full source',
        'title': 'Meeting',
        'folder_ids': ['folder'],
      },
      initialOptions: const ProcessingOptions(),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test(
    'A to B to A only navigates, then accept sends exactly the active ID',
    () async {
      final server = Server(), store = OperationStore();
      final c = create(server, store);
      await c.initialize();
      await c.generate(const ProcessingOptions(templateId: 'B'));
      expect(c.activeId, 'B');
      final before = server.calls.length;
      await c.move(-1);
      expect(c.activeId, 'A');
      await c.move(1);
      expect(c.activeId, 'B');
      await c.move(-1);
      expect(server.calls.length, before);
      await c.accept();
      expect(c.accepted!.content, '## Variant A');
      expect(server.acceptedId, 'A');
      expect(server.variants.length, 2);
      expect(
        server.calls.where((r) => r.url.path.contains('/transcripts')),
        isEmpty,
      );
      expect(server.calls.where((r) => r.method == 'PATCH'), isEmpty);
    },
  );
  test('lost session reply replays durable source and same key after process restart', () async {
    final dir = await Directory.systemTemp.createTemp('ym-selection-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/operation.json');
    final firstStore = OperationStore(file: file);
    final server = Server()..loseOpen = true;
    final first = create(server, firstStore);
    await first.initialize();
    first.pause();
    expect(first.error, isNotNull);
    final restored = OperationStore(file: file);
    await restored.load();
    final next = create(server, restored);
    await next.initialize();
    final opens = server.calls
        .where((r) => r.url.path.endsWith('/summary-selections'))
        .toList();
    expect(opens.length, 2);
    expect(
      opens[0].headers['Idempotency-Key'],
      opens[1].headers['Idempotency-Key'],
    );
    expect(opens[0].body, opens[1].body);
    expect(next.activeId, 'A');
  });
  test(
    'lost candidate reply retries exact key without a second generation',
    () async {
      final server = Server()..loseCandidate = true;
      final store = OperationStore();
      final first = create(server, store);
      await first.initialize();
      first.pause();
      expect(first.hasPending, isTrue);
      final restored = create(server, store);
      await restored.initialize();
      expect(server.variants.length, 1);
      expect(server.keys.length, 1);
      expect(restored.activeId, 'A');
    },
  );
  test(
    'ambiguous accept freezes choice across restart and reads current summary',
    () async {
      final server = Server(), store = OperationStore();
      final first = create(server, store);
      await first.initialize();
      await first.generate(const ProcessingOptions(templateId: 'B'));
      await first.move(-1);
      server.loseAccept = true;
      await first.accept();
      first.pause();
      expect(first.frozen, isTrue);
      await first.move(1);
      await first.generate(const ProcessingOptions(templateId: 'C'));
      expect(first.activeId, 'A');
      expect(server.variants.length, 2);
      final restored = create(server, store);
      await restored.initialize();
      expect(server.acceptedId, 'A');
      expect(restored.accepted!.id, 'summary');
      expect(restored.state['summary_version'], 'original-version');
    },
  );
  test(
    'version conflict preserves original version and allows cancellation',
    () async {
      final server = Server(), store = OperationStore();
      final c = create(server, store);
      await c.initialize();
      server.conflict = true;
      await c.accept();
      expect(c.accepted, isNull);
      expect(c.frozen, isFalse);
      expect(c.state['summary_version'], 'original-version');
      expect(c.error, contains('другом редакторе'));
      expect(await c.cancel(), isTrue);
      expect(store['test'], isNull);
      expect(server.content, 'initial');
    },
  );
  test(
    'lost cancel reply is recovered without generating or accepting',
    () async {
      final server = Server(), store = OperationStore();
      final c = create(server, store);
      await c.initialize();
      server.loseCancel = true;
      expect(await c.cancel(), isFalse);
      c.pause();
      expect(c.frozen, isTrue);
      final restored = create(server, store);
      await restored.initialize();
      expect(store['test'], isNull);
      expect(server.variants.length, 1);
      expect(server.acceptedId, isNull);
    },
  );
  test('failed checkpoint never sends a modifying request', () async {
    final server = Server();
    final c = create(server, FailingStore());
    await c.initialize();
    c.pause();
    expect(server.calls, isEmpty);
    await c.refresh();
    c.pause();
    expect(server.calls, isEmpty);
  });
  test('all source limits apply, without truncation', () {
    expect(validateGenerationSource('слово ' * 15000), isNull);
    expect(validateGenerationSource('слово ' * 15001), isNotNull);
    expect(validateGenerationSource('a' * 200001), isNotNull);
    expect(validateGenerationSource('😀' * 100001), isNotNull);
  });
}

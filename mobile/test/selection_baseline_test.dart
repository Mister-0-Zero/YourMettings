import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/selections/selection_controller.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/models/processing_options.dart';
import 'package:your_mettings/services/operation_store.dart';

import 'selection_recovery_test.dart' show Server;

class OpeningServer extends Server {
  String openingVersion = 'original-version';
  @override
  Json selection() => {...super.selection(), 'summary_version': openingVersion};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SelectionController create(
    OpeningServer server,
    OperationStore store,
    MeetingSummary original,
  ) {
    final api = ApiClient(
      Uri.parse('http://example/api/v1/'),
      client: MockClient(server.handle),
    );
    addTearDown(api.close);
    final c = SelectionController(
      api: api,
      store: store,
      slot: 'saved',
      source: () async => {'summary_id': original.id},
      initialOptions: const ProcessingOptions(),
      original: original,
    );
    addTearDown(c.dispose);
    return c;
  }

  MeetingSummary original(OpeningServer server) => MeetingSummary.fromJson({
    ...server.summary(),
    'version': 'original-version',
  });

  for (final lostReply in [false, true]) {
    test(
      'local baseline conflict closes server selection before removing checkpoint (lostReply=$lostReply)',
      () async {
        final server = OpeningServer()..openingVersion = 'external-version';
        final store = OperationStore();
        final c = create(server, store, original(server));
        await c.initialize();
        expect(c.terminal, isTrue);
        server.loseCancel = lostReply;
        final cancelled = await c.cancel();
        expect(server.status, 'cancelled');
        if (lostReply) {
          expect(cancelled, isFalse);
          expect(store['saved'], isNotNull);
          expect(store['saved']!['cancel_pending'], isTrue);
          await c.refresh();
        } else {
          expect(cancelled, isTrue);
        }
        expect(store['saved'], isNull);
        final deletes = server.calls
            .where((r) => r.method == 'DELETE')
            .toList();
        expect(deletes, hasLength(lostReply ? 2 : 1));
        expect(
          deletes.every(
            (r) =>
                r.url.path.endsWith('/summary-selections/selection') &&
                r.url.queryParameters['confirm'] == 'true',
          ),
          isTrue,
        );
        expect(server.variants, isEmpty);
        expect(server.acceptIntent, isNull);
      },
    );
  }
  test('fresh selection with a different opening version blocks generation and accept without changing baseline', () async {
    final server = OpeningServer()..openingVersion = 'external-version';
    final store = OperationStore();
    final c = create(server, store, original(server));
    await c.initialize();
    expect(c.terminal, isTrue);
    expect(c.error, contains('Встреча изменилась до открытия выбора шаблона'));
    await c.generate(const ProcessingOptions(templateId: 'B'));
    await c.accept();
    expect(server.variants, isEmpty);
    expect(server.acceptIntent, isNull);
    expect(store['saved']!['summary_version'], 'external-version');
    expect(
      (store['saved']!['original_baseline'] as Json)['version'],
      'original-version',
    );
  });

  test('lost open reply and restart preserve edited original while refusing a mismatching opening version', () async {
    final directory = await Directory.systemTemp.createTemp('ym-baseline-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/operations.json');
    final server = OpeningServer()..loseOpen = true;
    final c = create(server, OperationStore(file: file), original(server));
    await c.initialize();
    await c.editActive(title: 'Local title', content: 'Local unsent edits');
    c.pause();
    server.openingVersion = 'external-version';
    final restored = OperationStore(file: file);
    await restored.load();
    final next = create(
      server,
      restored,
      MeetingSummary.fromJson({
        ...server.summary(),
        'version': 'external-version',
        'content': 'External content',
      }),
    );
    await next.initialize();
    expect(next.terminal, isTrue);
    expect(next.content, 'Local unsent edits');
    expect(next.title, 'Local title');
    await next.refresh();
    expect(next.content, 'Local unsent edits');
    expect(server.variants, isEmpty);
    expect(server.acceptIntent, isNull);
    final opens = server.calls
        .where((r) => r.url.path.endsWith('/summary-selections'))
        .toList();
    expect(opens, hasLength(2));
    expect(opens.first.body, opens.last.body);
    expect(
      opens.first.headers['Idempotency-Key'],
      opens.last.headers['Idempotency-Key'],
    );
  });

  test('frozen atomic accept recovery replays captured intent despite a different reopened original snapshot', () async {
    final server = OpeningServer();
    final store = OperationStore();
    final c = create(server, store, original(server));
    await c.initialize();
    await c.generate(const ProcessingOptions(templateId: 'A'));
    c.pause();
    await store.put('saved', {
      ...store['saved']!,
      'accept_id': 'A',
      'accept_protocol': 'atomic-v1',
      'accept_edit': {'content': 'Frozen edit'},
    });
    final restored = create(
      server,
      store,
      MeetingSummary.fromJson({
        ...server.summary(),
        'version': 'new-display-version',
      }),
    );
    await restored.initialize();
    expect(restored.accepted!.content, 'Frozen edit');
    expect(server.acceptIntent!['expected_version'], 'original-version');
    expect(server.variants, hasLength(1));
  });
}

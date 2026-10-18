import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/features/new_meeting/transcript_page.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/recovery_store.dart';

void main() {
  testWidgets('long summary actions stay visible before and after scrolling', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = ApiClient(
      Uri.parse('http://localhost/'),
      client: MockClient((_) async => throw StateError('Unexpected request')),
    );
    final c = MeetingController(api, MemoryStore());
    addTearDown(() {
      c.dispose();
      api.close();
    });
    c.result = MeetingSummary.fromJson({
      'id': 's',
      'transcript_id': 't',
      'title': 'План',
      'content': List.filled(200, 'Абзац документа.').join('\n\n'),
      'folder_ids': ['f'],
      'created_at': '2026-10-19T12:00:00Z',
      'updated_at': '2026-10-19T12:00:00Z',
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ProcessingPanel(controller: c)),
      ),
    );
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.text('Принять'));
    expect(find.text('Редактировать').hitTestable(), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Принять')), before);
    expect(tester.takeException(), isNull);
  });
  testWidgets('automatic loading, network recovery and Qwen retry UI', (
    tester,
  ) async {
    final api = ApiClient(Uri.parse('http://localhost/'));
    final c = MeetingController(api, MemoryStore());
    addTearDown(() {
      c.dispose();
      api.close();
    });
    Future<void> render() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ProcessingPanel(controller: c)),
        ),
      );
      await tester.pump();
    }

    await render();
    expect(find.text('Qwen обрабатывает совещание…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Проверить состояние'), findsNothing);
    c.error = 'Сеть недоступна';
    await render();
    expect(find.text('Восстановить соединение'), findsOneWidget);
    c.status = ProcessingStatus.fromJson({
      'transcript_id': 't',
      'status': 'error',
      'summary_id': null,
      'error': {'code': 'llm_error', 'message': 'Qwen недоступен'},
    });
    await render();
    expect(find.text('Повторить обработку'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
  testWidgets(
    'polling survives more than four network failures without a POST',
    (tester) async {
      var attempts = 0;
      final methods = <String>[];
      final api = ApiClient(
        Uri.parse('http://localhost/'),
        client: MockClient((r) async {
          attempts++;
          methods.add(r.method);
          throw const ApiException('network_error', 'offline', isNetwork: true);
        }),
      );
      final c = MeetingController(api, MemoryStore());
      addTearDown(() {
        c.dispose();
        api.close();
      });
      c.recovery = RecoveryState(
        operation: AcceptedOperation('t', 'Test', ['f']),
      );
      await c.check();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 10));
      }
      expect(attempts, greaterThan(4));
      expect(methods, everyElement('GET'));
      c.pause();
    },
  );
}

class MemoryStore implements RecoveryStore {
  @override
  Future<RecoveryState> load() async => RecoveryState();
  @override
  Future<void> save(RecoveryState state) async {}
}

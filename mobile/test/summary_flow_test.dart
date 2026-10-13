import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/new_meeting/transcript_page.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/features/meetings/summary_page.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/recovery_store.dart';

const summaryJson = {
  'id': 's1',
  'transcript_id': 't1',
  'title': 'План',
  'content': '## Решения\nИсходный текст',
  'folder_ids': ['f1'],
  'created_at': '2026-10-13T12:00:00Z',
  'updated_at': '2026-10-13T12:00:00Z',
};
http.Response response(Object value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status);
void main() {
  testWidgets(
    'ready-result edit opens with one click; check saves and returns to Markdown',
    (tester) async {
      final methods = <String>[];
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((request) async {
          methods.add(request.method);
          return response(
            request.method == 'PATCH'
                ? {
                    ...summaryJson,
                    ...jsonDecode(request.body) as Map<String, dynamic>,
                  }
                : summaryJson,
          );
        }),
      );
      final controller = MeetingController(api, _MemoryStore());
      controller.result = MeetingSummary.fromJson(summaryJson);
      controller.recovery = RecoveryState(
        operation: AcceptedOperation('t1', 'План', ['f1']),
      );
      addTearDown(() {
        controller.dispose();
        api.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ProcessingPanel(controller: controller)),
        ),
      );
      await tester.ensureVisible(find.text('Редактировать'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Редактировать'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNWidgets(2));
      await tester.enterText(
        find.byType(TextField).last,
        '## Обновлено\n**Поручение:** проверить приложение.',
      );
      await tester.tap(find.byTooltip('Сохранить изменения'));
      await tester.pumpAndSettle();
      expect(methods.where((method) => method == 'PATCH').length, 1);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Обновлено'), findsOneWidget);
    },
  );
  testWidgets('failed check keeps the editor and edited text', (tester) async {
    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      client: MockClient((request) async {
        if (request.method == 'PATCH') {
          return response({
            'error': {
              'code': 'database_unavailable',
              'message': 'База недоступна',
            },
          }, 503);
        }
        return response(summaryJson);
      }),
    );
    final controller = MeetingController(api, _MemoryStore());
    addTearDown(() {
      controller.dispose();
      api.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: SummaryPageView(
          controller: controller,
          summary: MeetingSummary.fromJson(summaryJson),
          startEditing: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Новое название');
    await tester.tap(find.byTooltip('Сохранить изменения'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'Новое название',
    );
    expect(find.text('База недоступна'), findsOneWidget);
  });
  test(
    'missing accepted transcript clears recovery without another POST',
    () async {
      final methods = <String>[];
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((request) async {
          methods.add(request.method);
          return response({
            'error': {'code': 'not_found', 'message': 'Не найдено'},
          }, 404);
        }),
      );
      final controller = MeetingController(api, _MemoryStore());
      controller.recovery = RecoveryState(
        operation: AcceptedOperation('t1', 'План', ['f1']),
      );
      addTearDown(() {
        controller.dispose();
        api.close();
      });
      await controller.check();
      expect(controller.hasOperation, isFalse);
      await controller.check();
      expect(methods, ['GET']);
    },
  );
}

class _MemoryStore implements RecoveryStore {
  @override
  Future<RecoveryState> load() async => RecoveryState();
  @override
  Future<void> save(RecoveryState state) async {}
}

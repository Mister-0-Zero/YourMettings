import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/app/your_mettings_app.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/recovery_store.dart';

void main() {
  testWidgets(
    'form submits one operation, opens Markdown and clears accepted draft for next meeting',
    (tester) async {
      final store = _MemoryStore();
      var posts = 0;
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((request) async {
          if (request.method == 'POST') {
            posts++;
            expect(request.url.path, '/api/v1/transcripts/process');
            expect(jsonDecode(request.body), {
              'text': 'Тестовый ввод',
              'title': 'План',
              'folder_ids': ['f1'],
              'detail_level': 'normal',
              'focus_areas': [],
              'additional_instructions': '',
            });
            expect(request.headers['Idempotency-Key'], isNotEmpty);
            return http.Response(
              jsonEncode({
                'transcript_id': 't1',
                'status': 'ready',
                'summary_id': 's1',
                'error': null,
              }),
              202,
            );
          }
          if (request.url.path.endsWith('/transcripts/t1')) {
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'id': 't1',
                  'text': 'Тестовый ввод',
                  'is_locked': true,
                }),
              ),
              200,
            );
          }
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'id': 's1',
                'transcript_id': 't1',
                'title': 'План',
                'content': '## Решения\nГотовый результат',
                'folder_ids': ['f1'],
                'created_at': '2026-10-13T12:00:00Z',
                'updated_at': '2026-10-13T12:00:00Z',
              }),
            ),
            200,
          );
        }),
      );
      final controller = MeetingController(api, store);
      controller.folders = [Folder(id: 'f1', name: 'Проект')];
      addTearDown(() {
        controller.dispose();
        api.close();
      });
      await tester.pumpWidget(YourMettingsApp(controller: controller));
      await tester.tap(find.text('Загрузить транскрипт'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'План');
      await tester.enterText(find.byType(TextFormField).last, 'Тестовый ввод');
      await tester.ensureVisible(find.text('Выбрать или создать папки'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Выбрать или создать папки'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Выбрать'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Обработать'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Обработать'));
      await tester.pumpAndSettle();
      expect(posts, 1);
      expect(find.text('Решения'), findsOneWidget);
      expect(store.state.draft.text, isEmpty);
      expect(store.state.operation!.id, 't1');
      await tester.tap(find.text('Редактировать'));
      await tester.pumpAndSettle();
      expect(find.byType(q.QuillEditor), findsOneWidget);
      await tester.tap(find.byTooltip('Сохранить изменения'));
      await tester.pumpAndSettle();
      expect(find.byType(q.QuillEditor), findsNothing);
      expect(find.text('Решения'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Тестовый ввод'), findsOneWidget);
      expect(find.text('Открыть summary'), findsOneWidget);
      expect(posts, 1);
      await tester.tap(find.text('Открыть summary'));
      await tester.pumpAndSettle();
      expect(find.text('Решения'), findsOneWidget);
      await tester.ensureVisible(find.text('Готово'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      expect(store.state.operation, isNull);
      expect(controller.draft.text, isEmpty);
      expect(find.text('Загрузить транскрипт'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

class _MemoryStore implements RecoveryStore {
  RecoveryState state = RecoveryState();
  @override
  Future<RecoveryState> load() async => state;
  @override
  Future<void> save(RecoveryState value) async {
    state = value;
  }
}

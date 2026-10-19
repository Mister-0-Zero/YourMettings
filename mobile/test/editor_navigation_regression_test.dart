import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/meetings/summary_page.dart';
import 'package:your_mettings/features/meetings/meetings_page.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/models/api_models.dart';

import 'summary_editor_test.dart' as fixture;
import 'visual_editor_test.dart' show MemoryStore;

http.Response response(Object value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status);
void main() {
  for (final discard in [false, true]) {
    testWidgets(
      'back ${discard ? 'discards' : 'saves'} dirty content and returns to view',
      (tester) async {
        var patches = 0;
        var current = Map<String, dynamic>.from(fixture.summaryJson);
        final api = ApiClient(
          Uri.parse('http://localhost/api/v1/'),
          client: MockClient((r) async {
            if (r.method == 'PATCH') {
              patches++;
              current = {
                ...current,
                ...jsonDecode(r.body) as Map<String, dynamic>,
              };
            }
            return response(current);
          }),
        );
        final controller = MeetingController(api, MemoryStore());
        addTearDown(() {
          controller.dispose();
          api.close();
        });
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: const [
              q.FlutterQuillLocalizations.delegate,
            ],
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => SummaryPageView(
                        controller: controller,
                        summary: MeetingSummary.fromJson(current),
                      ),
                    ),
                  ),
                  child: const Text('Открыть'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Открыть'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Редактировать'));
        await tester.pumpAndSettle();
        expect(find.byType(PopupMenuButton<String>), findsNothing);
        await tester.enterText(find.byType(TextField).first, 'Изменено');
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.text('Сохранить изменения?'), findsOneWidget);
        expect(patches, 0);
        await tester.tap(
          discard
              ? find.text('Отменить изменения')
              : find.widgetWithText(FilledButton, 'Сохранить'),
        );
        await tester.pumpAndSettle();
        expect(patches, discard ? 0 : 1);
        expect(find.byType(q.QuillEditor), findsNothing);
        expect(find.byType(PopupMenuButton<String>), findsOneWidget);
        expect(find.text(discard ? 'План' : 'Изменено'), findsOneWidget);
        await tester.tap(find.byTooltip('Редактировать'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          discard ? 'План' : 'Изменено',
        );
      },
    );
  }
  testWidgets(
    'complex real summary saves through API, retries failure and reopens without loss',
    (tester) async {
      var current = {
        ...fixture.summaryJson,
        'content': File('test/fixtures/qwen_summary.md').readAsStringSync(),
      };
      var attempts = 0;
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((r) async {
          if (r.method == 'PATCH') {
            attempts++;
            if (attempts == 1) {
              return response({
                'error': {
                  'code': 'database_unavailable',
                  'message': 'Повторите сохранение',
                },
              }, 503);
            }
            current = {
              ...current,
              ...jsonDecode(r.body) as Map<String, dynamic>,
            };
          }
          return response(current);
        }),
      );
      final controller = MeetingController(api, MemoryStore());
      addTearDown(() {
        controller.dispose();
        api.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [q.FlutterQuillLocalizations.delegate],
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => SummaryPageView(
                      controller: controller,
                      summary: MeetingSummary.fromJson(current),
                    ),
                  ),
                ),
                child: const Text('Открыть'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Редактировать'));
      await tester.pumpAndSettle();
      expect(find.byType(q.QuillEditor), findsOneWidget);
      expect(find.text('Неизменяемый блок'), findsNothing);
      final doc = tester
          .widget<q.QuillEditor>(find.byType(q.QuillEditor))
          .controller
          .document;
      final before = doc.toPlainText();
      final offset = before.indexOf('Мария');
      doc.delete(offset, 5);
      doc.insert(offset, 'Алексей');
      doc.format(offset, 7, q.Attribute.bold);
      final expected = doc.toDelta().toJson();
      await tester.pump();
      await tester.tap(find.byTooltip('Сохранить изменения'));
      await tester.pumpAndSettle();
      expect(find.byType(q.QuillEditor), findsOneWidget);
      expect(find.text('Повторите сохранение'), findsWidgets);
      await tester.tap(find.byTooltip('Сохранить изменения'));
      await tester.pumpAndSettle();
      expect(find.byType(q.QuillEditor), findsNothing);
      expect(attempts, 2);
      await tester.tap(find.byTooltip('Редактировать'));
      await tester.pumpAndSettle();
      final reopened = tester
          .widget<q.QuillEditor>(find.byType(q.QuillEditor))
          .controller
          .document;
      expect(reopened.toPlainText(), before.replaceFirst('Мария', 'Алексей'));
      expect(reopened.toDelta().toJson(), expected);
    },
  );
  testWidgets(
    'view menu loads correct source, replaces folders and confirms delete before refreshing list',
    (tester) async {
      var current = Map<String, dynamic>.from(fixture.summaryJson);
      var deleted = false;
      var deletes = 0;
      var puts = 0;
      var lists = 0;
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((r) async {
          if (r.url.path.endsWith('/transcripts/t1')) {
            return response({
              'id': 't1',
              'text': 'Правильный исходный транскрипт',
              'is_locked': true,
            });
          }
          if (r.url.path.endsWith('/summaries')) {
            lists++;
            return response({
              'items': deleted ? [] : [current],
              'total': deleted ? 0 : 1,
              'limit': 20,
              'offset': 0,
            });
          }
          if (r.method == 'PUT') {
            expect(r.url.path, '/api/v1/summaries/s1/folders');
            expect(jsonDecode(r.body), {
              'folder_ids': ['f1', 'f2'],
            });
            puts++;
            current = {
              ...current,
              'folder_ids': ['f1', 'f2'],
            };
          }
          if (r.method == 'DELETE') {
            deletes++;
            deleted = true;
            return http.Response('', 204);
          }
          return response(current);
        }),
      );
      final controller = MeetingController(api, MemoryStore());
      controller.folders = [
        Folder(id: 'f1', name: 'Первая'),
        Folder(id: 'f2', name: 'Вторая'),
      ];
      addTearDown(() {
        controller.dispose();
        api.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [q.FlutterQuillLocalizations.delegate],
          home: FolderContentsPage(
            controller: controller,
            folder: controller.folders.first,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('План'));
      await tester.pumpAndSettle();
      Future<void> menu(String action) async {
        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
      }

      await menu('Исходный транскрипт');
      expect(find.text('Правильный исходный транскрипт'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await menu('Папки встречи');
      await tester.tap(find.text('Вторая'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Выбрать'));
      await tester.pumpAndSettle();
      expect(puts, 1);
      await menu('Удалить summary');
      expect(deletes, 0);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(deletes, 0);
      await menu('Удалить summary');
      await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
      await tester.pumpAndSettle();
      expect(deletes, 1);
      expect(lists, 2);
      expect(find.text('В этой папке пока нет встреч.'), findsOneWidget);
      expect(find.text('План'), findsNothing);
    },
  );
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart' as q;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/meetings/summary_editor.dart';
import 'package:your_mettings/features/meetings/summary_page.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
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
  test(
    'in-flight saves serialize and preserve text typed during a request',
    () async {
      final first = Completer<http.Response>();
      final bodies = <Map<String, dynamic>>[];
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          if (bodies.length == 1) return first.future;
          return response({...summaryJson, ...bodies.last});
        }),
      );
      final editor = SummaryEditor(api, MeetingSummary.fromJson(summaryJson));
      addTearDown(() {
        editor.dispose();
        api.close();
      });
      editor.edit(content: 'Первое изменение');
      final flush = editor.flush();
      await Future<void>.delayed(Duration.zero);
      editor.edit(content: 'Последнее изменение');
      final concurrentFlush = editor.flush();
      expect(bodies.length, 1);
      first.complete(response({...summaryJson, ...bodies.first}));
      expect(await flush, isTrue);
      expect(await concurrentFlush, isTrue);
      expect(bodies.length, 2);
      expect(bodies.last['content'], 'Последнее изменение');
      expect(editor.content, 'Последнее изменение');
      expect(editor.dirty, isFalse);
    },
  );

  testWidgets('debounce coalesces edits into one PATCH after 800 ms', (
    tester,
  ) async {
    final bodies = <Map<String, dynamic>>[];
    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      client: MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return response({...summaryJson, ...bodies.last});
      }),
    );
    final editor = SummaryEditor(api, MeetingSummary.fromJson(summaryJson));
    addTearDown(() {
      editor.dispose();
      api.close();
    });
    editor.edit(content: 'А');
    editor.edit(content: 'АБ');
    await tester.pump(const Duration(milliseconds: 799));
    expect(bodies, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(bodies.single['content'], 'АБ');
  });

  testWidgets(
    'discard waits for an active autosave and cancels its queued edits',
    (tester) async {
      final first = Completer<http.Response>();
      final bodies = <Map<String, dynamic>>[];
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return first.future;
        }),
      );
      final editor = SummaryEditor(api, MeetingSummary.fromJson(summaryJson));
      addTearDown(() {
        editor.dispose();
        api.close();
      });
      editor.edit(content: 'Уже отправлено');
      await tester.pump(const Duration(milliseconds: 800));
      expect(bodies.length, 1);
      editor.edit(content: 'Ещё не сохранено');
      final paused = editor.pauseAutosave();
      first.complete(response({...summaryJson, ...bodies.first}));
      await tester.pump();
      await paused;
      expect(editor.hasUnsavedChanges, isTrue);
      editor.discardUnsaved();
      editor.resumeAutosave();
      await tester.pump(const Duration(seconds: 2));
      expect(editor.content, 'Уже отправлено');
      expect(editor.hasUnsavedChanges, isFalse);
      expect(bodies.length, 1);
    },
  );

  test('failed save retains edits and can be retried', () async {
    var attempts = 0;
    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      client: MockClient((request) async {
        attempts++;
        if (attempts == 1) {
          return response({
            'error': {
              'code': 'database_unavailable',
              'message': 'База недоступна',
            },
          }, 503);
        }
        return response({
          ...summaryJson,
          ...jsonDecode(request.body) as Map<String, dynamic>,
        });
      }),
    );
    final editor = SummaryEditor(api, MeetingSummary.fromJson(summaryJson));
    addTearDown(() {
      editor.dispose();
      api.close();
    });
    editor.edit(title: 'Изменённое название');
    expect(await editor.flush(), isFalse);
    expect(editor.dirty, isTrue);
    expect(editor.title, 'Изменённое название');
    expect(await editor.flush(), isTrue);
    expect(editor.dirty, isFalse);
  });

  testWidgets('back asks before saving and returns to formatted view', (
    tester,
  ) async {
    var patches = 0;
    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      client: MockClient((request) async {
        if (request.method == 'PATCH') {
          patches++;
          return response({
            ...summaryJson,
            ...jsonDecode(request.body) as Map<String, dynamic>,
          });
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
        localizationsDelegates: const [q.FlutterQuillLocalizations.delegate],
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => SummaryPageView(
                    controller: controller,
                    summary: MeetingSummary.fromJson(summaryJson),
                  ),
                ),
              ),
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Редактировать'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Новое название');
    expect(patches, 0);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Сохранить изменения?'), findsOneWidget);
    expect(patches, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
    await tester.pumpAndSettle();
    expect(patches, 1);
    expect(find.byType(q.QuillEditor), findsNothing);
    expect(find.text('Новое название'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Открыть'), findsOneWidget);
  });

  testWidgets(
    'deletion is not sent until confirmation; cancel preserves summary',
    (tester) async {
      var deletes = 0;
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((request) async {
          if (request.method == 'DELETE') {
            deletes++;
            return http.Response('', 204);
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
          localizationsDelegates: const [q.FlutterQuillLocalizations.delegate],
          home: SummaryPageView(
            controller: controller,
            summary: MeetingSummary.fromJson(summaryJson),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить summary'));
      await tester.pumpAndSettle();
      expect(deletes, 0);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(deletes, 0);
      expect(find.text('Решения'), findsOneWidget);
    },
  );
}

class _MemoryStore implements RecoveryStore {
  @override
  Future<RecoveryState> load() async => RecoveryState();
  @override
  Future<void> save(RecoveryState state) async {}
}

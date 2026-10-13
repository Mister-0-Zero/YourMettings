import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/meetings/meetings_page.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/recovery_store.dart';

http.Response response(Object body, [int code = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), code);
const summaryJson = {
  'id': 's1',
  'transcript_id': 't1',
  'title': 'План выпуска',
  'content': '## Решения\nВыпустить продукт.',
  'folder_ids': ['f2'],
  'created_at': '2026-10-13T12:00:00Z',
  'updated_at': '2026-10-13T12:00:00Z',
};
void main() {
  testWidgets(
    'nested folder opens its own paginated summaries and Markdown result',
    (tester) async {
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((request) async {
          if (request.url.path == '/api/v1/summaries/s1') {
            return response(summaryJson);
          }
          expect(request.url.path, '/api/v1/summaries');
          expect(request.url.queryParameters['folder_id'], 'f2');
          return response({
            'items': [summaryJson],
            'total': 1,
            'limit': 20,
            'offset': 0,
          });
        }),
      );
      final controller = MeetingController(api, _MemoryStore());
      controller.folders = [
        Folder(
          id: 'f1',
          name: 'Проект',
          children: [Folder(id: 'f2', name: 'Команда', parentId: 'f1')],
        ),
      ];
      addTearDown(() {
        controller.dispose();
        api.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MeetingsPage(controller: controller)),
        ),
      );
      await tester.tap(find.text('Проект'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Команда'));
      await tester.pumpAndSettle();
      expect(find.text('План выпуска'), findsOneWidget);
      await tester.tap(find.text('План выпуска'));
      await tester.pumpAndSettle();
      expect(find.text('Решения'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'creating a root folder refreshes the tree and sends no user id',
    (tester) async {
      final folders = <Map<String, dynamic>>[];
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((request) async {
          if (request.method == 'POST') {
            expect(jsonDecode(request.body), {
              'name': 'Новая папка',
              'parent_id': null,
            });
            folders.add({
              'id': 'f1',
              'name': 'Новая папка',
              'parent_id': null,
              'children': [],
            });
            return response(folders.single, 201);
          }
          return response({'items': folders});
        }),
      );
      final controller = MeetingController(api, _MemoryStore());
      addTearDown(() {
        controller.dispose();
        api.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MeetingsPage(controller: controller)),
        ),
      );
      await tester.tap(find.byTooltip('Создать папку'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Новая папка');
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(find.text('Новая папка'), findsOneWidget);
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

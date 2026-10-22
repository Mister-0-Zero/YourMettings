import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/meetings/folder_picker.dart';
import 'package:your_mettings/features/meetings/meetings_page.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/recovery_store.dart';

class Store implements RecoveryStore {
  @override
  Future<RecoveryState> load() async => RecoveryState();
  @override
  Future<void> save(RecoveryState state) async {}
}

http.Response jsonResponse(Object value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status);
Map<String, dynamic> tree({bool added = false}) => {
  'items': [
    {
      'id': 'root',
      'name': 'Root',
      'children': [
        {
          'id': 'child',
          'name': 'Child',
          'parent_id': 'root',
          'children': [
            {
              'id': 'grand',
              'name': 'Grand',
              'parent_id': 'child',
              'children': [],
            },
          ],
        },
        if (added)
          {
            'id': 'new',
            'name': 'New child',
            'parent_id': 'root',
            'children': [],
          },
      ],
    },
  ],
};
Map<String, dynamic> summary(String folder) => {
  'id': 'summary-$folder',
  'transcript_id': 'transcript-$folder',
  'title': 'Summary $folder',
  'content': 'Text',
  'folder_ids': [folder],
  'created_at': '2026-10-22T10:00:00Z',
  'updated_at': '2026-10-22T10:00:00Z',
};

void main() {
  testWidgets(
    'title opens mixed contents, arrow only expands, and child creation refreshes current folder',
    (tester) async {
      var added = false;
      final opened = <String>[];
      final api = ApiClient(
        Uri.parse('http://example/api/v1/'),
        client: MockClient((r) async {
          if (r.method == 'POST') {
            expect(jsonDecode(r.body), {
              'name': 'New child',
              'parent_id': 'root',
            });
            added = true;
            return jsonResponse({
              'id': 'new',
              'name': 'New child',
              'parent_id': 'root',
            }, 201);
          }
          if (r.url.path.endsWith('/folders')) {
            return jsonResponse(tree(added: added));
          }
          final id = r.url.queryParameters['folder_id']!;
          opened.add(id);
          return jsonResponse({
            'items': [summary(id)],
            'total': 1,
            'limit': 20,
            'offset': 0,
          });
        }),
      );
      final c = MeetingController(api, Store());
      await c.loadFolders();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MeetingsPage(controller: c)),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('expand-root')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('expand-child')));
      await tester.pumpAndSettle();
      expect(find.text('Grand'), findsOneWidget);
      expect(opened, isEmpty);
      await tester.tap(find.text('Root'));
      await tester.pumpAndSettle();
      expect(opened, ['root']);
      expect(find.text('Child'), findsOneWidget);
      expect(find.text('Summary root'), findsOneWidget);
      expect(find.textContaining('открываются отдельно'), findsNothing);
      await tester.tap(find.text('Создать подпапку'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'New child');
      await tester.tap(find.widgetWithText(FilledButton, 'Создать'));
      await tester.pumpAndSettle();
      expect(find.text('New child'), findsOneWidget);
      await tester.tap(find.text('Child'));
      await tester.pumpAndSettle();
      expect(opened, ['root', 'child']);
      expect(find.text('Grand'), findsOneWidget);
      expect(find.text('Summary child'), findsOneWidget);
      expect(find.text('Summary root'), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('New child'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      api.close();
    },
  );

  testWidgets(
    'picker refreshes, selects deep UUIDs and creates under chosen parent without losing selection on failure',
    (tester) async {
      var posts = 0;
      var added = false;
      List<String>? selected;
      final api = ApiClient(
        Uri.parse('http://example/api/v1/'),
        client: MockClient((r) async {
          if (r.method == 'POST') {
            posts++;
            expect(jsonDecode(r.body), {
              'name': 'New child',
              'parent_id': 'child',
            });
            if (posts == 1) {
              return jsonResponse({
                'error': {'code': 'network_test', 'message': 'Retry test'},
              }, 503);
            }
            added = true;
            return jsonResponse({
              'id': 'new',
              'name': 'New child',
              'parent_id': 'child',
            }, 201);
          }
          final value = tree();
          if (added) {
            (value['items'][0]['children'][0]['children'] as List).add({
              'id': 'new',
              'name': 'New child',
              'parent_id': 'child',
            });
          }
          return jsonResponse(value);
        }),
      );
      final c = MeetingController(api, Store());
      // Intentionally start with a stale root-only controller.
      c.folders = [Folder(id: 'root', name: 'Root')];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    selected = await chooseFolders(context, c, ['grand']),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Root / Child / Grand'), findsOneWidget);
      await tester.tap(find.byTooltip('Создать подпапку в «Root / Child»'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'New child');
      await tester.tap(find.widgetWithText(FilledButton, 'Создать'));
      await tester.pumpAndSettle();
      expect(find.text('Retry test'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        'New child',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Создать'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Выбрать'));
      await tester.pumpAndSettle();
      expect(selected, unorderedEquals(['grand', 'new']));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      api.close();
    },
  );

  test(
    'GET started before create cannot hide the newly committed child',
    () async {
      final old = Completer<http.Response>();
      var reads = 0;
      final api = ApiClient(
        Uri.parse('http://example/api/v1/'),
        client: MockClient((r) async {
          if (r.method == 'POST') {
            return jsonResponse({
              'id': 'new',
              'name': 'New child',
              'parent_id': 'root',
            }, 201);
          }
          if (++reads == 1) return old.future;
          return jsonResponse(tree(added: true));
        }),
      );
      final c = MeetingController(api, Store());
      await c.saveDraft(
        Draft(text: 'keep', title: 'keep', folderIds: ['grand']),
      );
      final loading = c.loadFolders();
      final creating = c.createFolder('New child', parentId: 'root');
      await Future<void>.delayed(Duration.zero);
      old.complete(jsonResponse(tree()));
      await loading;
      await creating;
      expect(
        flattenFolders(c.folders).map((e) => e.folder.id),
        contains('new'),
      );
      expect(c.draft.folderIds, ['grand']);
      expect(reads, 2);
      c.dispose();
      api.close();
    },
  );
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/app/your_mettings_app.dart';
import 'package:your_mettings/features/meetings/folder_picker.dart';
import 'package:your_mettings/features/meetings/summary_editor.dart';
import 'package:your_mettings/features/meetings/summary_folders.dart';
import 'package:your_mettings/features/meetings/summary_page.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/recovery_store.dart';
import 'package:your_mettings/services/operation_store.dart';

class MemoryStore implements RecoveryStore {
  @override
  Future<RecoveryState> load() async => RecoveryState();
  @override
  Future<void> save(RecoveryState state) async {}
}

http.Response response(Object value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status);

class FolderServer {
  Json current = {
    'id': 'summary',
    'transcript_id': 'transcript',
    'title': 'Одна встреча',
    'content': '## Решения\n**Ручной текст** и задачи.',
    'version': List.filled(64, '1').join(),
    'folder_ids': ['a', 'c'],
    'created_at': '2026-11-01T00:00:00Z',
    'updated_at': '2026-11-01T00:00:00Z',
    'template_snapshot': {'id': 'template', 'name': 'Планёрка'},
  };
  final calls = <http.Request>[];
  String? failure;
  bool externalContentOnPut = false;
  List<http.Request> get puts => calls.where((r) => r.method == 'PUT').toList();
  MeetingSummary get summary => MeetingSummary.fromJson(current);
  Json get folders => {
    'items': [
      {
        'id': 'a',
        'name': 'Папка A',
        'children': [
          {'id': 'b', 'name': 'Подпапка B', 'parent_id': 'a', 'children': []},
        ],
      },
      {'id': 'c', 'name': 'Папка C', 'children': []},
      {'id': 'd', 'name': 'Папка D', 'children': []},
    ],
  };
  Future<http.Response> handle(http.Request r) async {
    calls.add(r);
    if (r.url.path == '/api/v1/folders') return response(folders);
    if (r.url.path == '/api/v1/summary-templates') {
      return response({
        'items': [
          {
            'id': 'template',
            'name': 'Планёрка',
            'is_default': true,
            'is_system': true,
            'sections': [],
          },
        ],
      });
    }
    if (r.method == 'POST' && r.url.path == '/api/v1/summary-selections') {
      return response({
        'id': 'selection',
        'transcript_id': 'transcript',
        'summary_id': 'summary',
        'summary_version': current['version'],
        'status': 'open',
        'candidates': [],
      }, 201);
    }

    if (r.url.path == '/api/v1/summaries') {
      final included = (current['folder_ids'] as List).contains(
        r.url.queryParameters['folder_id'],
      );
      return response({
        'items': included ? [current] : [],
        'total': included ? 1 : 0,
        'limit': 20,
        'offset': 0,
      });
    }
    if (r.method == 'GET' && r.url.path == '/api/v1/summaries/summary') {
      return response(current);
    }
    if (r.method == 'PUT' &&
        r.url.path == '/api/v1/summaries/summary/folders') {
      final body = jsonDecode(r.body) as Json;
      expect(body.keys, unorderedEquals(['folder_ids', 'expected_folder_ids']));
      if (failure == 'conflict') {
        failure = null;
        current = {
          ...current,
          'folder_ids': ['a', 'c', 'd'],
        };
        return response({
          'error': {'code': 'summary_folders_conflict', 'message': 'Conflict'},
        }, 409);
      }
      if (failure == 'server') {
        return response({
          'error': {'code': 'test_unavailable', 'message': 'Попробуйте позже'},
        }, 503);
      }
      expect(
        body['expected_folder_ids'],
        unorderedEquals(current['folder_ids'] as List),
      );
      if (externalContentOnPut) {
        current = {
          ...current,
          'content': 'Чужая новая правка',
          'version': List.filled(64, '2').join(),
        };
      }
      current = {...current, 'folder_ids': body['folder_ids']};
      if (failure == 'lost_reply') {
        failure = null;
        throw http.ClientException('lost response');
      }
      return response(current);
    }
    if (r.method == 'PATCH') {
      final body = jsonDecode(r.body) as Json;
      if (body['expected_version'] != current['version']) {
        return response({
          'error': {
            'code': 'summary_version_conflict',
            'message': 'Документ изменён другим клиентом',
          },
        }, 409);
      }
      current = {
        ...current,
        'title': body['title'],
        'content': body['content'],
        'version': List.filled(64, '3').join(),
      };
      return response(current);
    }
    fail('Unexpected endpoint: ${r.method} ${r.url.path}');
  }
}

Future<void> menu(WidgetTester tester, String label) async {
  await tester.tap(find.byType(PopupMenuButton<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, String folder, String button) async {
  await tester.tap(find.byKey(ValueKey('select-folder-$folder')));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, button));
  await tester.pumpAndSettle();
}

Future<void> mountFolder(WidgetTester tester, FolderServer server) async {
  final api = ApiClient(
    Uri.parse('http://example/api/v1/'),
    client: MockClient(server.handle),
    operations: OperationStore(),
  );
  final c = MeetingController(api, MemoryStore());
  addTearDown(c.dispose);
  addTearDown(api.close);
  await c.loadFolders();
  await tester.pumpWidget(YourMettingsApp(controller: c));
  await tester.tap(find.text('Встречи'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Папка A'));
  await tester.pumpAndSettle();
}

Future<void> openSummary(WidgetTester tester) async {
  await tester.tap(find.text('Одна встреча'));
  await tester.pumpAndSettle();
}

Future<void> back(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();
}

void main() {
  test('retry proposals preserve the intended delta without reintroducing externally removed links', () {
    final current = MeetingSummary.fromJson({
      ...FolderServer().current,
      'folder_ids': ['a', 'd'],
    });
    expect(
      SummaryFolderIntent(
        FolderSelectionMode.add,
        ['a', 'c'],
        ['a', 'b', 'c'],
      ).selectionFor(current),
      unorderedEquals(['a', 'b', 'd']),
    );
    expect(
      SummaryFolderIntent(
        FolderSelectionMode.replace,
        ['a', 'c'],
        ['b', 'c'],
      ).selectionFor(current),
      unorderedEquals(['b', 'd']),
    );
    expect(
      SummaryFolderIntent(
        FolderSelectionMode.move,
        ['a', 'c'],
        ['b'],
      ).selectionFor(current),
      ['b'],
    );
  });

  test('confirmed unchanged selection still uses server CAS and detects a concurrent membership change', () async {
    final server = FolderServer()..failure = 'conflict';
    final api = ApiClient(
      Uri.parse('http://example/api/v1/'),
      client: MockClient(server.handle),
    );
    addTearDown(api.close);
    await expectLater(
      saveSummaryFolders(api, server.summary, ['a', 'c']),
      throwsA(
        isA<SummaryFoldersConflict>().having(
          (e) => e.current.folderIds,
          'refreshed memberships',
          ['a', 'c', 'd'],
        ),
      ),
    );
    expect(server.puts, hasLength(1));
    expect(jsonDecode(server.puts.single.body), {
      'folder_ids': ['a', 'c'],
      'expected_folder_ids': ['a', 'c'],
    });
    expect(server.current['folder_ids'], ['a', 'c', 'd']);
  });

  testWidgets(
    'incidental folder response v2 cannot pair original v1 with a fresh v2 template selection',
    (tester) async {
      final server = FolderServer()..externalContentOnPut = true;
      await mountFolder(tester, server);
      await openSummary(tester);
      await menu(tester, 'Добавить в другую папку');
      await choose(tester, 'b', 'Добавить');
      await menu(tester, 'Изменить шаблон');
      expect(
        find.textContaining('Встреча изменилась до открытия выбора шаблона'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == 'Сохранить встречу',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        server.calls.where(
          (r) =>
              r.url.path.endsWith('/candidates') ||
              r.url.path.endsWith('/accept') ||
              r.method == 'PATCH',
        ),
        isEmpty,
      );
      expect(server.current['content'], 'Чужая новая правка');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'return refresh waits for an older pagination request before rereading moved summary',
    (tester) async {
      final server = FolderServer();
      final delayedPage = Completer<http.Response>();
      var listReads = 0;
      final api = ApiClient(
        Uri.parse('http://example/api/v1/'),
        client: MockClient((r) async {
          if (r.url.path == '/api/v1/summaries') {
            listReads++;
            if (listReads == 1) {
              return response({
                'items': [server.current],
                'total': 2,
                'offset': 0,
                'limit': 1,
              });
            }
            if (listReads == 2) return delayedPage.future;
          }
          return server.handle(r);
        }),
      );
      final c = MeetingController(api, MemoryStore());
      addTearDown(c.dispose);
      addTearDown(api.close);
      await c.loadFolders();
      await tester.pumpWidget(YourMettingsApp(controller: c));
      await tester.tap(find.text('Встречи'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Папка A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Загрузить ещё'));
      await tester.pump();
      await openSummary(tester);
      await menu(tester, 'Переместить');
      await choose(tester, 'b', 'Переместить');
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      delayedPage.complete(
        response({'items': [], 'total': 2, 'offset': 1, 'limit': 1}),
      );
      await tester.pumpAndSettle();
      expect(listReads, 3);
      expect(find.text('В этой папке пока нет встреч.'), findsOneWidget);
      expect(find.text('Одна встреча'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'source removed before opening picker is not silently treated as move-all',
    (tester) async {
      final server = FolderServer();
      await mountFolder(tester, server);
      await openSummary(tester);
      server.current = {
        ...server.current,
        'folder_ids': ['c'],
      };
      await menu(tester, 'Переместить');
      expect(
        find.textContaining('Встреча больше не находится в исходной папке'),
        findsOneWidget,
      );
      expect(server.puts, isEmpty);
      expect(server.current['folder_ids'], ['c']);
      expect(find.byKey(const ValueKey('select-folder-b')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'folder picker fits narrow phone and prevents removal of assigned add links',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final server = FolderServer();
      final api = ApiClient(
        Uri.parse('http://example/api/v1/'),
        client: MockClient(server.handle),
      );
      final c = MeetingController(api, MemoryStore());
      addTearDown(c.dispose);
      addTearDown(api.close);
      await c.loadFolders();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => chooseFolders(context, c, [
                  'a',
                  'c',
                ], mode: FolderSelectionMode.add),
                child: const Text('Открыть'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Добавить'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('select-folder-a')))
            .enabled,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('membership updates preserve dirty local text, old saved text and content CAS version', () async {
    final server = FolderServer();
    final api = ApiClient(
      Uri.parse('http://example/api/v1/'),
      client: MockClient(server.handle),
    );
    addTearDown(api.close);
    final original = server.summary;
    final editor = SummaryEditor(api, original);
    addTearDown(editor.dispose);
    await editor.pauseAutosave();
    editor.edit(title: 'Local title', content: 'Local text');
    server.current = {
      ...server.current,
      'title': 'External title',
      'content': 'External text',
      'version': List.filled(64, '2').join(),
      'folder_ids': ['c', 'd'],
    };
    editor.setFolders(server.summary);
    expect(editor.title, 'Local title');
    expect(editor.content, 'Local text');
    expect(editor.summary.title, original.title);
    expect(editor.summary.content, original.content);
    expect(editor.summary.version, original.version);
    expect(editor.summary.folderIds, ['c', 'd']);
    expect(await editor.flush(), isFalse);
    expect(server.current['content'], 'External text');
    expect(editor.content, 'Local text');
    expect(editor.hasUnsavedChanges, isTrue);
  });

  test('membership limit, duplicate IDs and empty replacement are checked before PUT', () {
    final server = FolderServer();
    expect(
      () => summaryFolderDestinations(
        server.summary,
        [],
        FolderSelectionMode.replace,
      ),
      throwsA(isA<ApiException>()),
    );
    expect(
      () => summaryFolderDestinations(
        server.summary,
        List.generate(101, (i) => 'f-i$i'),
        FolderSelectionMode.replace,
      ),
      throwsA(isA<ApiException>()),
    );
    expect(
      summaryFolderDestinations(
        server.summary,
        ['b', 'b'],
        FolderSelectionMode.move,
        sourceFolderId: 'a',
      ),
      unorderedEquals(['b', 'c']),
    );
    expect(
      () => summaryFolderDestinations(
        server.summary,
        ['b', 'd'],
        FolderSelectionMode.move,
        sourceFolderId: 'a',
      ),
      throwsA(isA<ApiException>()),
    );
  });

  test('legacy API caller may omit CAS, but failed CAS refresh never causes unconditional retry', () async {
    var puts = 0;
    final api = ApiClient(
      Uri.parse('http://example/api/v1/'),
      client: MockClient((r) async {
        if (r.method == 'PUT') {
          puts++;
          if (puts == 1) {
            expect(jsonDecode(r.body), {
              'folder_ids': ['b'],
            });
            return response({
              ...FolderServer().current,
              'folder_ids': ['b'],
            });
          }
          expect(jsonDecode(r.body), {
            'folder_ids': ['a', 'b', 'c'],
            'expected_folder_ids': ['a', 'c'],
          });
          return response({
            'error': {
              'code': 'summary_folders_conflict',
              'message': 'Conflict',
            },
          }, 409);
        }
        throw http.ClientException('cannot refresh');
      }),
    );
    addTearDown(api.close);
    await api.setSummaryFolders('summary', ['b']);
    await expectLater(
      saveSummaryFolders(api, FolderServer().summary, ['a', 'b', 'c']),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          'folder_update_unconfirmed',
        ),
      ),
    );
    expect(puts, 2);
  });

  testWidgets(
    'real folder entry adds a shared nested link, moves only source A, edits same document in B and C',
    (tester) async {
      final server = FolderServer();
      final initialContent = server.current['content'];
      final initialVersion = server.current['version'];
      await mountFolder(tester, server);
      await openSummary(tester);
      final view = tester.widget<SummaryPageView>(find.byType(SummaryPageView));
      expect(view.sourceFolderId, 'a');
      await menu(tester, 'Добавить в другую папку');
      expect(find.textContaining('Это одна встреча'), findsOneWidget);
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('select-folder-a')))
            .onTap,
        isNull,
      );
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('select-folder-c')))
            .onTap,
        isNull,
      );
      expect(
        tester.getTopLeft(find.text('Подпапка B')).dx,
        greaterThan(tester.getTopLeft(find.text('Папка A')).dx),
      );
      await choose(tester, 'b', 'Добавить');
      expect(server.current['folder_ids'], unorderedEquals(['a', 'b', 'c']));
      expect(server.puts.single.body, contains('expected_folder_ids'));
      expect(server.current['content'], initialContent);
      expect(server.current['version'], initialVersion);
      await back(tester);
      expect(find.text('Одна встреча'), findsOneWidget);
      // Nested B shows the same summary, not a separate copy.
      await tester.tap(find.text('Подпапка B'));
      await tester.pumpAndSettle();
      expect(find.text('Одна встреча'), findsOneWidget);
      await back(tester);
      await openSummary(tester);
      await menu(tester, 'Переместить');
      await choose(tester, 'b', 'Переместить');
      expect(server.current['folder_ids'], unorderedEquals(['b', 'c']));
      expect(server.current['id'], 'summary');
      expect(server.current['transcript_id'], 'transcript');
      expect(server.current['content'], initialContent);
      await back(tester);
      expect(find.text('В этой папке пока нет встреч.'), findsOneWidget);
      await tester.tap(find.text('Подпапка B'));
      await tester.pumpAndSettle();
      await openSummary(tester);
      await tester.tap(find.byTooltip('Редактировать'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'Общее новое название',
      );
      await tester.tap(find.byTooltip('Сохранить изменения'));
      await tester.pumpAndSettle();
      await back(tester);
      expect(find.text('Общее новое название'), findsOneWidget);
      await back(tester);
      await back(tester);
      await tester.tap(find.text('Папка C'));
      await tester.pumpAndSettle();
      expect(find.text('Общее новое название'), findsOneWidget);
      expect(server.calls.where((r) => r.method == 'POST'), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'list action carries the actual source folder and opens the move picker',
    (tester) async {
      final server = FolderServer();
      await mountFolder(tester, server);
      await tester.tap(find.byTooltip('Папки встречи «Одна встреча»'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Переместить'));
      await tester.pumpAndSettle();
      expect(find.text('Исходная папка'), findsOneWidget);
      await choose(tester, 'b', 'Переместить');
      expect(server.current['folder_ids'], unorderedEquals(['b', 'c']));
      expect(server.puts, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'cancel and a failed write preserve memberships; an explicit retry can succeed',
    (tester) async {
      final server = FolderServer()..failure = 'server';
      await mountFolder(tester, server);
      await openSummary(tester);
      await menu(tester, 'Добавить в другую папку');
      await tester.tap(find.byKey(const ValueKey('select-folder-b')));
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(server.puts, isEmpty);
      expect(server.current['folder_ids'], ['a', 'c']);
      await menu(tester, 'Добавить в другую папку');
      await choose(tester, 'b', 'Добавить');
      expect(find.text('Попробуйте позже'), findsOneWidget);
      expect(server.current['folder_ids'], ['a', 'c']);
      server.failure = null;
      await tester.tap(find.text('Проверить выбор папок'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Добавить'));
      await tester.pumpAndSettle();
      expect(server.current['folder_ids'], unorderedEquals(['a', 'b', 'c']));
      expect(server.puts, hasLength(2));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    '409 refreshes memberships without replay, explicit reselection preserves external D',
    (tester) async {
      final server = FolderServer()..failure = 'conflict';
      await mountFolder(tester, server);
      await openSummary(tester);
      await menu(tester, 'Добавить в другую папку');
      await choose(tester, 'b', 'Добавить');
      expect(find.text('Папки встречи изменились'), findsOneWidget);
      expect(server.puts, hasLength(1));
      expect(server.current['folder_ids'], ['a', 'c', 'd']);
      await tester.tap(find.text('Понятно'));
      await tester.pumpAndSettle();
      await menu(tester, 'Добавить в другую папку');
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('select-folder-d')))
            .onTap,
        isNull,
      );
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(
                of: find.byKey(const ValueKey('select-folder-b')),
                matching: find.byType(Checkbox),
              ),
            )
            .value,
        isTrue,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Добавить'));
      await tester.pumpAndSettle();
      expect(
        jsonDecode(server.puts.last.body)['expected_folder_ids'],
        unorderedEquals(['a', 'c', 'd']),
      );
      expect(
        server.current['folder_ids'],
        unorderedEquals(['a', 'b', 'c', 'd']),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'incidental newer content in folder PUT cannot authorize stale local text overwrite',
    (tester) async {
      final server = FolderServer()..externalContentOnPut = true;
      final oldVersion = server.current['version'];
      await mountFolder(tester, server);
      await openSummary(tester);
      await menu(tester, 'Добавить в другую папку');
      await choose(tester, 'b', 'Добавить');
      await tester.tap(find.byTooltip('Редактировать'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'Моя локальная правка',
      );
      await tester.tap(find.byTooltip('Сохранить изменения'));
      await tester.pumpAndSettle();
      final patch = server.calls.singleWhere((r) => r.method == 'PATCH');
      expect(jsonDecode(patch.body)['expected_version'], oldVersion);
      expect(server.current['content'], 'Чужая новая правка');
      expect(server.current['title'], 'Одна встреча');
      expect(find.byTooltip('Сохранить изменения'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Моя локальная правка',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'lost PUT reply is reconciled by GET without a second PUT or content write',
    () async {
      final server = FolderServer()..failure = 'lost_reply';
      final api = ApiClient(
        Uri.parse('http://example/api/v1/'),
        client: MockClient(server.handle),
      );
      addTearDown(api.close);
      final result = await saveSummaryFolders(api, server.summary, [
        'a',
        'b',
        'c',
      ]);
      expect(result.folderIds, unorderedEquals(['a', 'b', 'c']));
      expect(server.puts, hasLength(1));
      expect(server.calls.where((r) => r.method == 'PATCH'), isEmpty);
    },
  );

  test('move without genuine source is rejected; union and confirmed no-op do not duplicate memberships', () async {
    final server = FolderServer();
    expect(
      () => summaryFolderDestinations(server.summary, [
        'b',
      ], FolderSelectionMode.move),
      throwsA(isA<ApiException>()),
    );
    expect(
      () => summaryFolderDestinations(
        server.summary,
        ['b'],
        FolderSelectionMode.move,
        sourceFolderId: 'missing',
      ),
      throwsA(isA<ApiException>()),
    );
    expect(
      summaryFolderDestinations(server.summary, [
        'b',
        'b',
        'c',
      ], FolderSelectionMode.add),
      unorderedEquals(['a', 'b', 'c']),
    );
    expect(
      summaryFolderDestinations(
        server.summary,
        ['c'],
        FolderSelectionMode.move,
        sourceFolderId: 'a',
      ),
      ['c'],
    );
    final api = ApiClient(
      Uri.parse('http://example/api/v1/'),
      client: MockClient(server.handle),
    );
    addTearDown(api.close);
    final editor = SummaryEditor(api, server.summary);
    addTearDown(editor.dispose);
    final result = await saveSummaryFolders(api, server.summary, [
      'c',
      'a',
      'a',
    ]);
    editor.setFolders(result);
    expect(server.puts, hasLength(1));
    expect(editor.summary.version, server.current['version']);
  });

  testWidgets(
    'generic summary offers add/manage, never an ambiguous move-all',
    (tester) async {
      final server = FolderServer();
      final api = ApiClient(
        Uri.parse('http://example/api/v1/'),
        client: MockClient(server.handle),
      );
      final c = MeetingController(api, MemoryStore());
      addTearDown(c.dispose);
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: SummaryPageView(controller: c, summary: server.summary),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('Переместить'), findsNothing);
      expect(find.text('Добавить в другую папку'), findsOneWidget);
      expect(find.text('Папки встречи'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

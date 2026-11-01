import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/app/appearance.dart';
import 'package:your_mettings/app/your_mettings_app.dart';
import 'package:your_mettings/features/meetings/summary_page.dart';
import 'package:your_mettings/features/selections/selection_page.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/services/operation_store.dart';

import 'selection_flow_test.dart' show MemoryStore;
import 'visual_accent_regression_test.dart' show expectAccent, renderedStyles;

import 'package:your_mettings/features/meetings/visual_editor.dart';

import 'selection_recovery_test.dart' show Server, response;

class MultiFolderServer extends Server {
  List<String> folderIds = ['folder', 'other'];
  @override
  Map<String, dynamic> summary() => {
    ...super.summary(),
    'folder_ids': List<String>.of(folderIds),
    'version': acceptedId == null ? 'original-version' : 'latest-version',
  };
}

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'saved folder meeting compares original and new, keeps accent after accept ($dark)',
      (tester) async {
        final fixture = File('test/fixtures/template_short_real_2026-10-23.md')
            .readAsStringSync();
        final server = MultiFolderServer()..content = '**Original bold**';
        var queued = true;
        final api = ApiClient(
          Uri.parse('http://localhost/api/v1/'),
          operations: OperationStore(),
          client: MockClient((r) async {
            if (r.url.path.endsWith('/folders')) {
              return response({
                'items': [
                  {'id': 'folder', 'name': 'Project', 'children': []},
                  {'id': 'other', 'name': 'Other', 'children': []},
                  {'id': 'third', 'name': 'Third', 'children': []},
                ],
              });
            }
            if (r.url.path.endsWith('/summaries')) {
              return response({
                'items': [server.summary()],
                'total': 1,
                'limit': 20,
                'offset': 0,
              });
            }
            if (r.url.path.endsWith('/summary-templates')) {
              return response({
                'items': [
                  {
                    'id': 'A',
                    'name': 'Original template',
                    'is_default': true,
                    'is_system': true,
                    'sections': [],
                  },
                  {
                    'id': 'B',
                    'name': 'New template',
                    'is_default': false,
                    'is_system': true,
                    'sections': [],
                  },
                ],
              });
            }
            if (r.url.path.endsWith('/summary-templates/B')) {
              return response({
                'id': 'B',
                'name': 'New template',
                'is_default': false,
                'is_system': true,
                'sections': [],
              });
            }
            final result = await server.handle(r);
            if (r.method == 'POST' && r.url.path.endsWith('/candidates')) {
              server.variants['B'] = {
                ...server.variants['B']!,
                'status': queued ? 'queued' : 'ready',
                'content': queued ? null : fixture,
              };
              return response(server.variants['B']!, 202);
            }
            return result;
          }),
        );
        final c = MeetingController(api, MemoryStore());
        final appearance = AppearanceController()
          ..themeMode = dark ? ThemeMode.dark : ThemeMode.light;
        appearance.documentAccent = DocumentAccent.purple;
        addTearDown(api.close);
        addTearDown(c.dispose);
        addTearDown(appearance.dispose);
        await c.loadFolders();
        await tester.pumpWidget(
          YourMettingsApp(controller: c, appearance: appearance),
        );
        Future<void> open() async {
          await tester.tap(find.text('Встречи'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Project'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(server.currentTitle).last);
          await tester.pumpAndSettle();
        }

        void accent() {
          final body = tester.widget<MarkdownBody>(
            find
                .descendant(
                  of: find.byType(SummaryPageView),
                  matching: find.byType(MarkdownBody),
                )
                .last,
          );
          expect(
            body.styleSheet!.strong!.color,
            DocumentAccent.purple.forBrightness(
              dark ? Brightness.dark : Brightness.light,
            ),
          );
          expect(body.styleSheet!.strong!.fontWeight, FontWeight.bold);
        }

        await open();
        accent();
        await tester.tap(find.byType(PopupMenuButton<String>).last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Изменить шаблон'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Шаблон обработки'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('New template'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        // Saved content must remain reachable while its replacement is processing.
        expect(find.byTooltip('Предыдущий вариант'), findsOneWidget);
        await tester.tap(find.byTooltip('Предыдущий вариант'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('Original bold'), findsOneWidget);
        queued = false;
        server.variants['B'] = {
          ...server.variants['B']!,
          'status': 'ready',
          'content': fixture,
        };
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Следующий вариант'));
        await tester.pumpAndSettle();
        expectAccent(
          tester,
          'Релиз API',
          DocumentAccent.purple.forBrightness(
            dark ? Brightness.dark : Brightness.light,
          ),
        );
        await tester.tap(find.byTooltip('Предыдущий вариант'));
        await tester.pumpAndSettle();
        expect(find.text('Original bold'), findsOneWidget);
        await tester.tap(find.byTooltip('Следующий вариант'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Редактировать'));
        await tester.pumpAndSettle();
        final color = DocumentAccent.purple.forBrightness(
          dark ? Brightness.dark : Brightness.light,
        );
        expectAccent(tester, 'Релиз API', color);
        final visual = tester
            .widget<VisualEditorBody>(find.byType(VisualEditorBody))
            .document;
        visual.active!.controller!.replaceText(
          0,
          0,
          'Edited ',
          const TextSelection.collapsed(offset: 7),
        );
        await tester.pump();
        await appearance.update(documentBold: false);
        await tester.pumpAndSettle();
        expect(
          renderedStyles(tester, 'Релиз API')
              .where((s) => s.fontWeight == FontWeight.bold)
              .every((s) => s.color != color),
          isTrue,
        );
        await appearance.update(documentBold: true);
        await tester.pumpAndSettle();
        expectAccent(tester, 'Релиз API', color);
        expect(
          visual.sections
              .where((s) => s.controller != null)
              .every(
                (s) => !s.controller!.document.toDelta().toJson().any(
                  (op) =>
                      (op['attributes'] as Map?)?.containsKey('color') ?? false,
                ),
              ),
          isTrue,
        );
        await tester.tap(find.text('Применить'));
        await tester.pumpAndSettle();
        expectAccent(tester, 'Релиз API', color);
        // Folder membership can change while comparing templates without
        // changing content CAS. Acceptance must preserve the current links.
        server.folderIds = ['folder', 'other', 'third'];
        await tester.tap(find.byTooltip('Сохранить встречу'));
        await tester.pumpAndSettle();
        expect(find.byType(SelectionPage), findsNothing);
        await open();
        accent();
        expectAccent(
          tester,
          'Релиз API',
          DocumentAccent.purple.forBrightness(
            dark ? Brightness.dark : Brightness.light,
          ),
        );
        expect(server.calls.where((r) => r.method == 'PATCH'), isEmpty);
        final accept = server.calls.singleWhere(
          (r) => r.url.path.endsWith('/accept'),
        );
        expect(accept.body, contains('content'));
        expect(accept.body, isNot(contains('folder_ids')));
        expect(server.calls.where((r) => r.method == 'PUT'), isEmpty);
        expect(
          tester
              .widget<SummaryPageView>(find.byType(SummaryPageView))
              .summary
              .folderIds,
          unorderedEquals(['folder', 'other', 'third']),
        );
        expect(appearance.colorDocumentBold, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

import 'dart:async';

import 'package:your_mettings/features/meetings/visual_editor.dart';

import 'dart:convert';

import 'package:your_mettings/features/meetings/summary_page.dart';
import 'package:flutter/material.dart';
import 'package:your_mettings/models/processing_options.dart';
import 'package:your_mettings/features/selections/selection_page.dart';
import 'package:your_mettings/features/selections/selection_controller.dart';
import 'package:your_mettings/features/templates/template_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/app/your_mettings_app.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/operation_store.dart';
import 'package:your_mettings/services/recovery_store.dart';

import 'selection_recovery_test.dart' show Server, response;

class MemoryStore implements RecoveryStore {
  RecoveryState value = RecoveryState();
  @override
  Future<RecoveryState> load() async => value;
  @override
  Future<void> save(RecoveryState state) async {
    value = state;
  }
}

void main() {
  testWidgets(
    'new transcript keeps draft until check, accepts once, and returns home',
    (tester) async {
      final server = Server(),
          operations = OperationStore(),
          store = MemoryStore();
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        operations: operations,
        client: MockClient(server.handle),
      );
      final controller = MeetingController(api, store);
      addTearDown(controller.dispose);
      addTearDown(api.close);
      await controller.saveDraft(
        Draft(text: 'Full source', title: 'Meeting', folderIds: ['folder']),
      );
      controller.folders = [Folder(id: 'folder', name: 'Project')];
      await tester.pumpWidget(YourMettingsApp(controller: controller));
      await tester.tap(find.text('Загрузить транскрипт'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Обработать'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Обработать'));
      await tester.pumpAndSettle();
      expect(find.text('Вариант 1 из 1'), findsNothing);
      expect(find.text('Variant A'), findsOneWidget);
      expect(store.value.draft.text, 'Full source');
      expect(controller.selectionActive, isTrue);
      expect(server.acceptedId, isNull);
      await tester.tap(find.byTooltip('Сохранить встречу'));
      await tester.pumpAndSettle();
      expect(server.acceptedId, 'A');
      expect(controller.draft.text, isEmpty);
      expect(controller.selectionActive, isFalse);
      expect(find.text('Записать встречу'), findsOneWidget);
      expect(find.byType(SelectionPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'restored selection displays the template of the active candidate',
    (tester) async {
      final server = Server(), operations = OperationStore();
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        operations: operations,
        client: MockClient((r) async {
          if (r.url.path.endsWith('/summary-templates/B')) {
            return response({
              'id': 'B',
              'name': 'Second',
              'is_system': true,
              'is_default': false,
              'sections': [],
            });
          }
          return server.handle(r);
        }),
      );
      addTearDown(api.close);
      final preparation = SelectionController(
        api: api,
        store: operations,
        slot: 'restored',
        source: () async => {
          'text': 'source',
          'title': 'Meeting',
          'folder_ids': ['folder'],
        },
        initialOptions: const ProcessingOptions(),
      );
      await preparation.initialize();
      await preparation.generate(const ProcessingOptions(templateId: 'B'));
      preparation.dispose();
      await tester.pumpWidget(
        MaterialApp(
          home: SelectionPage(
            api: api,
            slot: 'restored',
            source: () async =>
                throw StateError('Do not create another source'),
            options: const ProcessingOptions(),
            title: 'Meeting',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TemplateSelector>(find.byType(TemplateSelector)).value,
        'B',
      );
      expect(find.text('Вариант 2 из 2'), findsOneWidget);
      expect(server.variants.length, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'accepting a variant for saved meeting closes selection and summary routes',
    (tester) async {
      final server = Server()..content = '## Old result';
      final operations = OperationStore();
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        operations: operations,
        client: MockClient((r) async {
          if (r.url.path.endsWith('/folders')) return response({'items': []});
          return server.handle(r);
        }),
      );
      final controller = MeetingController(api, MemoryStore());
      addTearDown(controller.dispose);
      addTearDown(api.close);
      await tester.pumpWidget(YourMettingsApp(controller: controller));
      await tester.tap(find.text('Встречи'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1,
      );
      unawaited(
        Navigator.of(tester.element(find.byType(NavigationBar))).push<void>(
          MaterialPageRoute(
            builder: (_) => SummaryPageView(
              controller: controller,
              summary: MeetingSummary.fromJson(server.summary()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Old result'), findsOneWidget);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Изменить шаблон'));
      await tester.pumpAndSettle();
      tester
          .widget<TemplateSelector>(find.byType(TemplateSelector))
          .onChanged('B');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Сохранить встречу'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(server.acceptedId, 'B');
      expect(server.content, '## Variant B');
      expect(find.byType(SelectionPage), findsNothing);
      expect(find.byType(SummaryPageView), findsNothing);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'loading is minimal; edited variants switch locally and the check returns home',
    (tester) async {
      final server = Server(), operations = OperationStore();
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        operations: operations,
        client: MockClient((r) async {
          if (r.url.path.endsWith('/summary-templates')) {
            return response({
              'items': [
                {
                  'id': 'A',
                  'name': 'First template',
                  'is_system': true,
                  'is_default': true,
                  'sections': [],
                },
                {
                  'id': 'B',
                  'name': 'Second template',
                  'is_system': true,
                  'is_default': false,
                  'sections': [],
                },
              ],
            });
          }
          if (r.url.path.endsWith('/summary-templates/B')) {
            return response({
              'id': 'B',
              'name': 'Second template',
              'is_system': true,
              'is_default': false,
              'sections': [],
            });
          }
          final result = await server.handle(r);
          if (r.method == 'POST' && r.url.path.endsWith('/candidates')) {
            final id = (jsonDecode(result.body) as Json)['id'] as String;
            server.variants[id] = {
              ...server.variants[id]!,
              'status': 'queued',
              'content': null,
            };
            return response(server.variants[id]!, 202);
          }
          return result;
        }),
      );
      final controller = MeetingController(api, MemoryStore());
      addTearDown(controller.dispose);
      addTearDown(api.close);
      await controller.saveDraft(
        Draft(text: 'Full source', title: 'Meeting', folderIds: ['folder']),
      );
      controller.folders = [Folder(id: 'folder', name: 'Project')];
      await tester.pumpWidget(YourMettingsApp(controller: controller));
      await tester.tap(find.text('Загрузить транскрипт'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Обработать'));
      await tester.tap(find.text('Обработать'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Qwen обрабатывает транскрипт'), findsOneWidget);
      expect(find.text('Выбранный шаблон: A'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byType(TemplateSelector), findsNothing);
      expect(find.byTooltip('Сохранить встречу'), findsNothing);
      expect(find.byTooltip('Предыдущий вариант'), findsNothing);
      server.variants['A'] = {
        ...server.variants['A']!,
        'status': 'ready',
        'content': '## Variant A',
      };
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Редактировать'));
      await tester.pumpAndSettle();
      final visual = tester
          .widget<VisualEditorBody>(find.byType(VisualEditorBody))
          .document;
      visual.active!.controller!.replaceText(
        0,
        0,
        'Edited ',
        const TextSelection.collapsed(offset: 7),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Применить'));
      await tester.pumpAndSettle();
      expect(find.text('Edited Variant A'), findsOneWidget);
      expect(server.calls.where((r) => r.method == 'PATCH'), isEmpty);
      tester
          .widget<TemplateSelector>(find.byType(TemplateSelector))
          .onChanged('B');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Qwen обрабатывает транскрипт'), findsOneWidget);
      expect(find.text('Edited Variant A'), findsNothing);
      server.variants['B'] = {
        ...server.variants['B']!,
        'status': 'ready',
        'content': '## Variant B',
      };
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      final generations = server.calls
          .where((r) => r.url.path.endsWith('/candidates'))
          .length;
      await tester.tap(find.byTooltip('Предыдущий вариант'));
      await tester.pumpAndSettle();
      expect(find.text('Edited Variant A'), findsOneWidget);
      await tester.tap(find.byTooltip('Следующий вариант'));
      await tester.pumpAndSettle();
      expect(find.text('Variant B'), findsOneWidget);
      expect(
        server.calls.where((r) => r.url.path.endsWith('/candidates')).length,
        generations,
      );
      await tester.tap(find.byTooltip('Сохранить встречу'));
      await tester.pumpAndSettle();
      expect(server.acceptedId, 'B');
      expect(server.content, '## Variant B');
      expect(find.text('Записать встречу'), findsOneWidget);
      expect(operations['text-selection'], isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'cancelling selection rereads a concurrently edited saved summary',
    (tester) async {
      final server = Server()..content = '## Old result';
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        operations: OperationStore(),
        client: MockClient(server.handle),
      );
      final controller = MeetingController(api, MemoryStore());
      addTearDown(controller.dispose);
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: SummaryPageView(
            controller: controller,
            summary: MeetingSummary.fromJson(server.summary()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Изменить шаблон'));
      await tester.pumpAndSettle();
      server.content = '## Externally edited';
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отменить выбор'));
      await tester.pumpAndSettle();
      expect(find.text('Externally edited'), findsOneWidget);
      expect(find.text('Old result'), findsNothing);
      expect(tester.takeException(), isNull);
      expect(server.acceptedId, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

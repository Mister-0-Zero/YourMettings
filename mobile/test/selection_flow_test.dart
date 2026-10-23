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
    'new transcript keeps draft until Done, accepts once, and opens formatted result',
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
      expect(find.text('Вариант 1 из 1'), findsOneWidget);
      expect(store.value.draft.text, 'Full source');
      expect(controller.selectionActive, isTrue);
      expect(server.acceptedId, isNull);
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      expect(server.acceptedId, 'A');
      expect(controller.draft.text, isEmpty);
      expect(controller.selectionActive, isFalse);
      expect(find.text('Все изменения сохранены'), findsOneWidget);
      expect(find.text('Редактировать'), findsOneWidget);
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
    'accepting a variant for saved meeting immediately refreshes formatted content',
    (tester) async {
      final server = Server()..content = '## Old result';
      final operations = OperationStore();
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        operations: operations,
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
      expect(find.text('Old result'), findsOneWidget);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Изменить шаблон'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Создать вариант по шаблону'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Variant A'), findsOneWidget);
      expect(find.text('Old result'), findsNothing);
      expect(find.text('Все изменения сохранены'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

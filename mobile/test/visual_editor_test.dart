import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/features/meetings/summary_page.dart';
import 'package:your_mettings/features/meetings/summary_editor.dart';
import 'package:your_mettings/features/meetings/visual_document.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/recovery_store.dart';

const table = '| A | B |\n|---|---|\n| keep | **exact** |\n';
const data = {
  'id': 's',
  'transcript_id': 't',
  'title': 'План',
  'content': '## План\n\nРедактируемый текст\n\n$table\nПосле таблицы.',
  'folder_ids': ['f'],
  'created_at': '2026-10-19T12:00:00Z',
  'updated_at': '2026-10-19T12:00:00Z',
};
void main() {
  for (final brightness in Brightness.values) {
    testWidgets('visual formatting and protected table in ${brightness.name}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final bodies = <Map<String, dynamic>>[];
      var current = Map<String, dynamic>.from(data);
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((r) async {
          if (r.method == 'PATCH') {
            final body = jsonDecode(r.body) as Map<String, dynamic>;
            bodies.add(body);
            current = {...current, ...body};
          }
          return http.Response.bytes(utf8.encode(jsonEncode(current)), 200);
        }),
      );
      final controller = MeetingController(api, MemoryStore());
      addTearDown(() {
        controller.dispose();
        api.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          localizationsDelegates: const [q.FlutterQuillLocalizations.delegate],
          home: SummaryPageView(
            controller: controller,
            summary: MeetingSummary.fromJson(data),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Редактировать'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(q.QuillEditor), findsNWidgets(2));
      expect(find.text('Неизменяемый блок'), findsOneWidget);
      final rich = tester
          .widget<q.QuillEditor>(find.byType(q.QuillEditor).first)
          .controller;
      final plain = rich.document.toPlainText();
      final start = plain.indexOf('Редактируемый');
      rich.updateSelection(
        TextSelection(baseOffset: start, extentOffset: start + 13),
        q.ChangeSource.local,
      );
      await tester.pump();
      final bold = find.byWidgetPredicate(
        (w) =>
            w is q.QuillToolbarToggleStyleButton &&
            w.attribute == q.Attribute.bold,
      );
      await tester.tap(bold);
      await tester.pump();
      await tester.tap(find.byTooltip('Сохранить изменения'));
      await tester.pumpAndSettle();
      expect(find.byType(q.QuillEditor), findsNothing);
      expect(bodies.last['content'], contains('**Редактируемый**'));
      expect(bodies.last['content'], contains(table));
      await tester.tap(find.byTooltip('Редактировать'));
      await tester.pumpAndSettle();
      final reopened = tester
          .widget<q.QuillEditor>(find.byType(q.QuillEditor).first)
          .controller
          .document
          .toDelta()
          .toJson();
      expect(reopened.toString(), contains('bold: true'));
      expect(tester.takeException(), isNull);
    });
  }
  test(
    'invalid conversion blocks autosave, explicit save and title changes',
    () async {
      var patches = 0;
      final api = ApiClient(
        Uri.parse('http://localhost/'),
        client: MockClient((r) async {
          patches++;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                ...data,
                ...jsonDecode(r.body) as Map<String, dynamic>,
              }),
            ),
            200,
          );
        }),
      );
      final editor = SummaryEditor(api, MeetingSummary.fromJson(data));
      addTearDown(() {
        editor.dispose();
        api.close();
      });
      editor.edit(content: 'Последний безопасный текст');
      editor.blockContentSave('Неподдерживаемое форматирование');
      editor.edit(title: 'Правка названия');
      expect(await editor.flush(), isFalse);
      expect(patches, 0);
      editor.edit(content: 'Исправлено');
      expect(await editor.flush(), isTrue);
      expect(patches, 1);
    },
  );
  test('editing after a table preserves the source boundary', () {
    final model = VisualDocument(
      '$table\nПосле таблицы.',
      onChanged: (_, _) {},
    );
    addTearDown(model.dispose);
    model.sections.last.controller!.document.insert(0, 'Правка ');
    final result = model.export();
    expect(result, startsWith(table));
    expect(result, contains('\n\nПравка После таблицы'));
    final reopened = VisualDocument(result, onChanged: (_, _) {});
    addTearDown(reopened.dispose);
    expect(
      reopened.sections.where((s) => s.protected).map((s) => s.source).join(),
      contains(table),
    );
    expect(
      reopened.sections.last.controller!.document.toPlainText(),
      contains('Правка После таблицы'),
    );
  });
}

class MemoryStore implements RecoveryStore {
  @override
  Future<RecoveryState> load() async => RecoveryState();
  @override
  Future<void> save(RecoveryState state) async {}
}

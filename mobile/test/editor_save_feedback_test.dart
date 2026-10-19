import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/meetings/summary_page.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/models/api_models.dart';

import 'summary_editor_test.dart' as fixture;
import 'visual_editor_test.dart' show MemoryStore;

void main() {
  testWidgets('save error stays visible at the bottom of a long document', (
    tester,
  ) async {
    var patches = 0;
    final data = {
      ...fixture.summaryJson,
      'content': List.filled(80, 'Длинный обычный абзац.').join('\n\n'),
    };
    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      client: MockClient((r) async {
        if (r.method == 'PATCH') patches++;
        return http.Response.bytes(utf8.encode(jsonEncode(data)), 200);
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
        home: SummaryPageView(
          controller: controller,
          summary: MeetingSummary.fromJson(data),
          startEditing: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final doc = tester
        .widget<q.QuillEditor>(find.byType(q.QuillEditor))
        .controller
        .document;
    await tester.drag(find.byType(ListView), const Offset(0, -20000));
    await tester.pumpAndSettle();
    doc.format(0, 6, q.Attribute.underline);
    await tester.pump();
    await tester.tap(find.byTooltip('Сохранить изменения'));
    await tester.pumpAndSettle();
    expect(patches, 0);
    expect(find.byType(q.QuillEditor), findsOneWidget);
    expect(
      find
          .text(
            'Это форматирование нельзя безопасно сохранить в Markdown. Отмените последнее изменение.',
          )
          .hitTestable(),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });
}

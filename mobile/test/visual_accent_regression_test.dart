import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/app/appearance.dart';
import 'package:your_mettings/features/meetings/summary_page.dart';
import 'package:your_mettings/features/meetings/summary_document.dart';
import 'package:your_mettings/features/meetings/visual_editor.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/features/selections/selection_editor.dart';
import 'package:your_mettings/models/api_models.dart';

import 'selection_flow_test.dart' show MemoryStore;
import 'selection_recovery_test.dart' show response;

List<TextStyle> renderedStyles(WidgetTester tester, String text) {
  final result = <TextStyle>[];
  for (final e
      in find
          .byWidgetPredicate((w) => w is RichText || w is EditableText)
          .evaluate()) {
    final widget = e.widget;
    final span = widget is RichText
        ? widget.text
        : (widget as EditableText).controller.buildTextSpan(
            context: e,
            style: widget.style,
            withComposing: false,
          );
    void visit(InlineSpan span, TextStyle inherited) {
      final style = inherited.merge(span.style);
      if (span is TextSpan) {
        if ((span.text ?? '').contains(text)) result.add(style);
        for (final child in span.children ?? <InlineSpan>[]) {
          visit(child, style);
        }
      }
    }

    visit(span, DefaultTextStyle.of(e).style);
  }
  return result;
}

void expectAccent(WidgetTester tester, String text, Color color) {
  final runs = renderedStyles(tester, text);
  expect(runs, isNotEmpty, reason: 'Rendered text $text');
  expect(
    runs.any(
      (style) => style.fontWeight == FontWeight.bold && style.color == color,
    ),
    isTrue,
    reason: '$text must render bold in $color; actual: $runs',
  );
}

void main() {
  for (final dark in [false, true]) {
    final brightness = dark ? Brightness.dark : Brightness.light;
    testWidgets(
      'real Qwen fixture keeps rendered accent through saved editor and save $dark',
      (tester) async {
        final source = File('test/fixtures/template_short_real_2026-10-23.md')
            .readAsStringSync();
        var data = <String, dynamic>{
          'id': 'summary',
          'transcript_id': 'source',
          'title': 'Meeting',
          'content': source,
          'folder_ids': ['folder'],
          'created_at': '2026-10-31T00:00:00Z',
          'updated_at': '2026-10-31T00:00:00Z',
          'version': 'v1',
          'navigation': [],
        };
        final api = ApiClient(
          Uri.parse('http://example/api/v1/'),
          client: MockClient((request) async {
            if (request.method == 'PATCH') {
              // ApiClient.saveSummary sends title/content; response returns unchanged styling preferences.
              final body = request.body;
              data = {...data, ...(jsonDecode(body) as Map<String, dynamic>)};
            }
            return response(data);
          }),
        );
        final controller = MeetingController(api, MemoryStore());
        final prefs = AppearanceController()
          ..documentAccent = DocumentAccent.purple;
        await tester.pumpWidget(
          MaterialApp(
            theme: prefs.theme(brightness),
            localizationsDelegates: const [
              q.FlutterQuillLocalizations.delegate,
            ],
            builder: (context, child) =>
                AppearanceScope(controller: prefs, child: child!),
            home: SummaryPageView(
              controller: controller,
              summary: MeetingSummary.fromJson(data),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final accent = DocumentAccent.purple.forBrightness(brightness);
        expectAccent(tester, 'Релиз API', accent);
        await tester.tap(find.byTooltip('Редактировать'));
        await tester.pumpAndSettle();
        expectAccent(tester, 'Релиз API', accent);
        final visual = tester
            .widget<VisualEditorBody>(find.byType(VisualEditorBody))
            .document;
        expect(visual.hasProtected, isFalse);
        visual.active!.controller!.replaceText(
          0,
          0,
          'Note: ',
          const TextSelection.collapsed(offset: 6),
        );
        await tester.pump();
        await tester.tap(find.byTooltip('Сохранить изменения'));
        await tester.pumpAndSettle();
        expect(find.byType(q.QuillEditor), findsNothing);
        expectAccent(tester, 'Релиз API', accent);
        expect(prefs.colorDocumentBold, isTrue);
        await tester.tap(find.byTooltip('Редактировать'));
        await tester.pumpAndSettle();
        expectAccent(tester, 'Релиз API', accent);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        api.close();
        prefs.dispose();
      },
    );

    testWidgets(
      'candidate editor apply keeps bold accent and respects preference toggle $dark',
      (tester) async {
        final prefs = AppearanceController()
          ..documentAccent = DocumentAccent.purple;
        final content = ValueNotifier('## Heading\n\n**Decision** with text.');
        await tester.pumpWidget(
          MaterialApp(
            theme: prefs.theme(brightness),
            localizationsDelegates: const [
              q.FlutterQuillLocalizations.delegate,
            ],
            builder: (context, child) =>
                AppearanceScope(controller: prefs, child: child!),
            home: Builder(
              builder: (context) => Scaffold(
                body: ValueListenableBuilder<String>(
                  valueListenable: content,
                  builder: (context, value, _) => ListView(
                    children: [
                      TextButton(
                        onPressed: () => Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => SelectionEditor(
                              title: 'Meeting',
                              content: value,
                              onApply: (title, text) async {
                                content.value = text;
                              },
                            ),
                          ),
                        ),
                        child: const Text('Open editor'),
                      ),
                      SummaryDocument(content: value),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final accent = DocumentAccent.purple.forBrightness(brightness);
        expectAccent(tester, 'Decision', accent);
        await tester.tap(find.text('Open editor'));
        await tester.pumpAndSettle();
        expectAccent(tester, 'Decision', accent);
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
        await tester.tap(find.text('Применить'));
        await tester.pumpAndSettle();
        expectAccent(tester, 'Decision', accent);
        await prefs.update(documentBold: false);
        await tester.pumpAndSettle();
        expect(
          renderedStyles(tester, 'Decision')
              .where((s) => s.fontWeight == FontWeight.bold)
              .every((s) => s.color != accent),
          isTrue,
        );
        await tester.tap(find.text('Open editor'));
        await tester.pumpAndSettle();
        expect(
          renderedStyles(tester, 'Decision')
              .where((s) => s.fontWeight == FontWeight.bold)
              .every((s) => s.color != accent),
          isTrue,
        );
        expect(content.value, contains('**'));
        await tester.pumpWidget(const SizedBox());
        content.dispose();
        prefs.dispose();
      },
    );
  }
}

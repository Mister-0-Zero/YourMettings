import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:your_mettings/app/appearance.dart';
import 'package:your_mettings/features/meetings/summary_document.dart';
import 'package:your_mettings/models/api_models.dart';

void main() {
  test('document preferences migrate, persist independently and have readable contrast', () async {
    final directory = await Directory.systemTemp.createTemp('ym-doc-style-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/appearance.json');
    await file.writeAsString('{"theme_mode":"dark","accent":"green"}');
    final prefs = AppearanceController(file: file);
    addTearDown(prefs.dispose);
    await prefs.load();
    expect(prefs.documentAccent, DocumentAccent.orange);
    expect(prefs.colorDocumentBold, true);
    await prefs.update(
      documentColor: DocumentAccent.purple,
      documentBold: false,
    );
    final restarted = AppearanceController(file: file);
    addTearDown(restarted.dispose);
    await restarted.load();
    expect(restarted.documentAccent, DocumentAccent.purple);
    expect(restarted.colorDocumentBold, false);
    expect(restarted.accent, AccentColor.green);
    for (final brightness in Brightness.values) {
      final background = prefs.theme(brightness).colorScheme.surface;
      for (final c in DocumentAccent.values) {
        final x = c.forBrightness(brightness).computeLuminance(),
            y = background.computeLuminance();
        expect(
          ((x > y ? x : y) + 0.05) / ((x < y ? x : y) + 0.05),
          greaterThanOrEqualTo(4.5),
          reason: '${c.name}/$brightness',
        );
      }
    }
  });
  for (final brightness in Brightness.values) {
    testWidgets(
      'TOC targets duplicate Cyrillic headings with code, quote, setext and scale $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final content =
            '# Начало **важно**\n\n```text\n## Не заголовок\n```\n\nСтарый заголовок\n---\n\n> ## Цитата\n\n## Повтор\n\n${List.filled(45, 'Длинный абзац с **решением** и *пояснением*.\n\n').join()}## Повтор\n\nФинальный абзац.\n';
        final lines = content.split('\n');
        final indices = [
          0,
          lines.indexOf('## Повтор'),
          lines.lastIndexOf('## Повтор'),
        ];
        final navigation = [
          for (var i = 0; i < indices.length; i++)
            SummaryHeading(
              id: 'ym-h-$i',
              title: i == 0 ? 'Начало важно' : 'Повтор',
              level: i == 0 ? 1 : 2,
              headingIndex: i,
              lineIndex: indices[i],
            ),
        ];
        final prefs = AppearanceController();
        addTearDown(prefs.dispose);
        await tester.pumpWidget(
          AnimatedBuilder(
            animation: prefs,
            builder: (context, _) => MaterialApp(
              theme: prefs.theme(brightness),
              home: AppearanceScope(
                controller: prefs,
                child: Scaffold(
                  body: MediaQuery(
                    data: const MediaQueryData(
                      textScaler: TextScaler.linear(1.5),
                    ),
                    child: ListView(
                      children: [
                        SummaryDocument(
                          content: content,
                          navigation: navigation,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('heading-ym-h-2')), findsOneWidget);
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('heading-ym-h-2'))).dy,
          greaterThan(844),
        );
        await tester.tap(find.text('Оглавление'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('toc-ym-h-2')));
        await tester.pumpAndSettle();
        final target = tester.getRect(
          find.byKey(const ValueKey('heading-ym-h-2')),
        );
        expect(target.top, lessThan(844));
        expect(target.bottom, greaterThan(0));
        expect(tester.takeException(), isNull);
        await prefs.update(documentColor: DocumentAccent.pink);
        await tester.pumpAndSettle();
        final body = tester.widget<MarkdownBody>(
          find.byType(MarkdownBody).first,
        );
        expect(body.data, content);
        expect(
          body.styleSheet!.strong!.color,
          DocumentAccent.pink.forBrightness(brightness),
        );
        await prefs.update(documentBold: false);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<MarkdownBody>(find.byType(MarkdownBody).first)
              .styleSheet!
              .strong!
              .color,
          isNull,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

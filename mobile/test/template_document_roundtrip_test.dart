import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:your_mettings/features/meetings/visual_document.dart';
import 'package:your_mettings/features/meetings/visual_markdown.dart';

String plain(String source) =>
    md.Document(encodeHtml: false, extensionSet: md.ExtensionSet.gitHubFlavored)
        .parseLines(source.split('\n'))
        .map((n) => n.textContent)
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
List<String> structure(String source) {
  final result = <String>[];
  void visit(md.Node n) {
    if (n is md.Element) {
      if ([
        'h1',
        'h2',
        'h3',
        'h4',
        'h5',
        'h6',
        'strong',
        'em',
        'ul',
        'ol',
        'li',
        'a',
      ].contains(n.tag)) {
        result.add('${n.tag}:${n.attributes['href'] ?? ''}');
      }
      for (final c in n.children ?? <md.Node>[]) {
        visit(c);
      }
    }
  }

  md.Document(
    encodeHtml: false,
    extensionSet: md.ExtensionSet.gitHubFlavored,
  ).parseLines(source.split('\n')).forEach(visit);
  return result;
}

void main() {
  test('real Qwen preview with topic blocks edits and reopens without text or formatting loss', () {
    final source =
        '${File('test/fixtures/template_preview_real_2026-10-23.md').readAsStringSync()}\n\n[К выпуску](#ym-h-3)\n\n## Проверка форматирования\n\n**Важное решение**, *пояснение* и [ссылка](https://example.com/path).\n\n1. Первый пункт\n2. Второй пункт\n\n- Задача: проверить приложение\n- Ответственный: Анна\n- Срок: 29 октября\n';
    final model = VisualDocument(source, onChanged: (_, _) {});
    addTearDown(model.dispose);
    expect(model.hasProtected, false);
    expect(model.export(), source);
    final controller = model.sections.first.controller!;
    controller.document.insert(0, 'Проверено ');
    final edited = model.export();
    expect(plain(edited), 'Проверено ${plain(source)}');
    expect(structure(edited), structure(source));
    expect(edited, contains('#ym-h-'));
    expect(edited, contains('https://example.com/path'));
    expect(edited, isNot(contains('<span')));
    final reopened = VisualDocument(edited, onChanged: (_, _) {});
    addTearDown(reopened.dispose);
    expect(reopened.hasProtected, false);
    expect(reopened.export(), edited);
  });
  test(
    'real short summary with loose nested task lists is entirely editable',
    () {
      final source = File('test/fixtures/template_short_real_2026-10-23.md')
          .readAsStringSync();
      final model = VisualDocument(source, onChanged: (_, _) {});
      addTearDown(model.dispose);
      expect(model.hasProtected, false);
      expect(model.export(), source);
      model.sections.first.controller!.document.insert(0, 'Проверено ');
      final edited = model.export();
      expect(plain(edited), 'Проверено ${plain(source)}');
      expect(structure(edited), structure(source));
      final reopened = VisualDocument(edited, onChanged: (_, _) {});
      addTearDown(reopened.dispose);
      expect(reopened.hasProtected, false);
      expect(reopened.export(), edited);
    },
  );
  test(
    'full-size preview result edits and reopens without text or structure loss',
    () {
      final source = File(
        'test/fixtures/template_long_preview_real_2026-10-24.md',
      ).readAsStringSync();
      final model = VisualDocument(source, onChanged: (_, _) {});
      addTearDown(model.dispose);
      expect(model.hasProtected, isFalse);
      expect(model.export(), source);
      model.sections.first.controller!.document.insert(0, 'Проверено ');
      final edited = model.export();
      expect(plain(edited), 'Проверено ${plain(source)}');
      expect(structure(edited), structure(source));
      final reopened = VisualDocument(edited, onChanged: (_, _) {});
      addTearDown(reopened.dispose);
      expect(reopened.export(), edited);
    },
  );
  test(
    'loose-list normalization does not permit merging distinct paragraphs',
    () {
      const source =
          '- Первый абзац\n\n  Отдельный второй абзац.\n\n- Следующий пункт\n';
      expect(() => VisualMarkdown(source), throwsFormatException);
      final model = VisualDocument(source, onChanged: (_, _) {});
      addTearDown(model.dispose);
      expect(model.hasProtected, true);
      expect(model.export(), source);
    },
  );
}

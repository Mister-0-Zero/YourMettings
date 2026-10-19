import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:your_mettings/features/meetings/visual_document.dart';
import 'package:your_mettings/features/meetings/visual_markdown.dart';

void main() {
  test('setext heading and table use actual source boundaries', () {
    const source =
        'Before\n\nHeading\n=======\n\n|A|B|\n|-|-|\n|1|2|\n\nAfter\n';
    final model = VisualDocument(source, onChanged: (_, _) {});
    addTearDown(model.dispose);
    expect(model.export(), source);
    expect(
      model.sections.where((s) => s.protected).map((s) => s.source).join(),
      contains('|A|B|\n|-|-|\n|1|2|\n'),
    );
    expect(
      model.sections.first.controller!.document.toDelta().toJson().toString(),
      contains('header: 1'),
    );
  });
  test('CR-only reference definitions keep their dependency group', () {
    const source = '[link][id]\r\r[id]: https://example.com\r';
    final model = VisualDocument(source, onChanged: (_, _) {});
    addTearDown(model.dispose);
    expect(model.sections.single.protected, isTrue);
    expect(model.export(), source);
  });

  for (final attribute in [
    q.Attribute.h1,
    q.Attribute.h2,
    q.Attribute.ul,
    q.Attribute.ol,
    q.Attribute.italic,
  ]) {
    test('create formatting ${attribute.key}:${attribute.value}', () {
      final bridge = VisualMarkdown('Первый абзац');
      addTearDown(bridge.document.close);
      bridge.document.format(0, bridge.document.length - 1, attribute);
      final result = bridge.export(bridge.document);
      final reopened = VisualDocument(result, onChanged: (_, _) {});
      addTearDown(reopened.dispose);
      expect(reopened.hasProtected, isFalse);
      expect(
        reopened.sections.first.controller!.document
            .toDelta()
            .toJson()
            .toString(),
        contains('${attribute.key}: ${attribute.value}'),
      );
    });
  }
  test('new embeds are blocked and deletion of all ordinary text is valid', () {
    final bridge = VisualMarkdown('Текст');
    addTearDown(bridge.document.close);
    bridge.document.delete(0, bridge.document.length - 1);
    expect(bridge.export(bridge.document).trim(), isEmpty);
    bridge.document.insert(
      0,
      q.BlockEmbed.image('https://example.com/test.png'),
    );
    expect(() => bridge.export(bridge.document), throwsFormatException);
  });

  final simple = [
    '# Заголовок\n\nАбзац с **жирным**, *курсивом* и [ссылкой](https://example.com).\n\n- Один\n- Два\n\n1. Первый\n2. Второй\n',
    '#### H4\n\n##### H5\n\n###### H6\n',
    '> Цитата\n\n```dart\nprint(1);\n```\n',
    'Строка один\nстрока два\n',
  ];
  for (final source in simple) {
    test('supported roundtrip $source', () {
      final model = VisualDocument(source, onChanged: (_, _) {});
      addTearDown(model.dispose);
      expect(model.hasProtected, isFalse);
      expect(model.export(), source);
      final controller = model.sections.first.controller!;
      controller.document.insert(0, 'Проверено ');
      final result = model.export();
      expect(result, contains('Проверено'));
      final reopened = VisualDocument(result, onChanged: (_, _) {});
      addTearDown(reopened.dispose);
      expect(reopened.hasProtected, isFalse);
      expect(reopened.export(), result);
    });
  }
  final complex = [
    '| A | B |\n| :--- | ---: |\n| **one** | two |\n',
    '![подпись](https://example.com/a.png "title")\n',
    '<div>\n\nHTML content\n\n</div>\n',
    '> # Заголовок\n> продолжение\n',
  ];
  for (final block in complex) {
    test('protected block preserved exactly: $block', () {
      final source =
          '## До\n\nРедактируемый текст.\n\n$block\n## После\n\nКонец.\n';
      final model = VisualDocument(source, onChanged: (_, _) {});
      addTearDown(model.dispose);
      expect(model.export(), source);
      expect(model.hasProtected, isTrue);
      final protected = model.sections
          .where((s) => s.protected)
          .map((s) => s.source)
          .join();
      expect(protected, contains(block));
      for (final section in model.sections.where((s) => !s.protected)) {
        section.controller!.document.insert(0, 'Правка ');
      }
      final result = model.export();
      expect(result, contains(block));
      if (model.sections.any((s) => !s.protected)) {
        expect(result, contains('Правка'));
      }
      final reopened = VisualDocument(result, onChanged: (_, _) {});
      addTearDown(reopened.dispose);
      expect(reopened.export(), result);
      expect(
        reopened.sections.where((s) => s.protected).map((s) => s.source).join(),
        contains(block),
      );
    });
  }
  test('CRLF, blank lines inside fences and nested containers remain intact', () {
    const source =
        'Before\r\n\r\n~~~text\r\na\r\n\r\nb\r\n~~~\r\n\r\n> | A | B |\r\n> |---|---|\r\n> |1|2|\r\n\r\nAfter\r\n';
    final model = VisualDocument(source, onChanged: (_, _) {});
    addTearDown(model.dispose);
    expect(model.export(), source);
    final block = model.sections
        .where((s) => s.protected)
        .map((s) => s.source)
        .join();
    expect(block, contains('> | A | B |\r\n> |---|---|\r\n> |1|2|\r\n'));
  });
  test('reference-link dependency group is preserved without conversion', () {
    const source =
        'A [link][target].\n\nOther paragraph\n\n[target]: https://example.com "title"\n';
    final model = VisualDocument(source, onChanged: (_, _) {});
    addTearDown(model.dispose);
    expect(model.sections.single.protected, isTrue);
    expect(model.export(), source);
  });
  test('new paragraph and selected bold/italic/list formatting export', () {
    final bridge = VisualMarkdown('Обычный текст');
    addTearDown(bridge.document.close);
    bridge.document.format(0, 7, q.Attribute.bold);
    bridge.document.format(8, 5, q.Attribute.italic);
    bridge.document.insert(bridge.document.length - 1, '\nНовый абзац');
    final output = bridge.export(bridge.document);
    expect(output, contains('**Обычный**'));
    expect(output, contains('*текст*'));
    expect(output, contains('Новый абзац'));
  });
  test('unsupported new formatting is rejected before autosave', () async {
    String? error;
    String? content;
    final model = VisualDocument(
      'Текст',
      onChanged: (text, message) {
        content = text;
        error = message;
      },
    );
    addTearDown(model.dispose);
    model.sections.first.controller!.document.format(
      0,
      5,
      q.Attribute.underline,
    );
    await Future<void>.delayed(Duration.zero);
    expect(error, isNotNull);
    expect(content, isNull);
  });
}

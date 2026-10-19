import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:markdown/markdown.dart' as md;
import 'package:markdown_quill/markdown_quill.dart';

/// Never allow a lossy conversion to reach autosave.
class VisualMarkdown {
  VisualMarkdown(this.original) {
    if (RegExp(r'(^|[\r\n]) {0,3}\[[^\]]+\]:|<[/!a-zA-Z]|!\[|\$\$')
        .hasMatch(original)) {
      throw const FormatException(
        'Изображения, HTML, определения ссылок и формулы пока доступны только для просмотра.',
      );
    }
    const allowed = {
      'p',
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
      'br',
      'code',
      'pre',
      'blockquote',
      'hr',
      'del',
      'input',
    };
    void check(md.Node n) {
      if (n is md.Element) {
        if (!allowed.contains(n.tag)) {
          throw const FormatException(
            'Таблицы и сложные конструкции пока доступны только для просмотра.',
          );
        }
        for (final child in n.children ?? <md.Node>[]) {
          check(child);
        }
      }
    }

    _parse(original).forEach(check);
    final delta = _importer.convert(original);
    document = delta.isEmpty ? q.Document() : q.Document.fromDelta(delta);
    if (_tree(original) != _tree(_exporter.convert(document.toDelta()))) {
      document.close();
      throw const FormatException('Конвертация меняет структуру Markdown.');
    }
    if (document.toDelta().toList().any((op) => !_supportedInsert(op.data))) {
      document.close();
      throw const FormatException(
        'Встроенный объект сохраняется неизменяемым.',
      );
    }
    _originalDelta = _signature(document);
  }
  final String original;
  late final q.Document document;
  late final String _originalDelta;
  static List<md.Node> _parse(String text) => md.Document(
    extensionSet: md.ExtensionSet.gitHubWeb,
    encodeHtml: false,
  ).parseLines(text.replaceAll('\r\n', '\n').split('\n'));
  static final _importer = _MarkdownImporter(
    markdownDocument: md.Document(
      extensionSet: md.ExtensionSet.gitHubWeb,
      encodeHtml: false,
    ),
    customElementToBlockAttribute: {
      'h4': (_) => [q.Attribute.h4],
      'h5': (_) => [q.Attribute.h5],
      'h6': (_) => [q.Attribute.h6],
    },
  );
  static final _exporter = DeltaToMarkdown(
    customContentHandler: (text, out) {
      final escaped = StringBuffer();
      DeltaToMarkdown.escapeSpecialCharacters(text, escaped);
      out.write(escaped.toString().replaceAll('\u2028', '  \n'));
    },
  );
  static String _tree(String text) {
    late Object Function(md.Node, bool) node;
    // Escaping punctuation changes AST text-node boundaries, not content.
    // Merge adjacent text before normalizing whitespace; keep every element,
    // attribute, hard break and literal code boundary in the comparison.
    List<Object> children(List<md.Node> nodes, bool literal) {
      final result = <Object>[];
      var text = '';
      void flush() {
        if (text.isEmpty) return;
        result.add(
          literal ? text : text.replaceAll(RegExp(r'[ \t\r\n]+'), ' '),
        );
        text = '';
      }

      for (final child in nodes) {
        if (child is md.Text) {
          text += child.textContent;
        } else {
          flush();
          result.add(node(child, literal));
        }
      }
      flush();
      return result;
    }

    node = (md.Node n, bool literal) {
      if (n is md.Element) {
        final preserve = literal || n.tag == 'pre' || n.tag == 'code';
        return [
          n.tag,
          _sorted(n.attributes),
          children(n.children ?? <md.Node>[], preserve),
        ];
      }
      return literal
          ? n.textContent
          : n.textContent.replaceAll(RegExp(r'[ \t\r\n]+'), ' ');
    };

    return jsonEncode(children(_parse(text), false));
  }

  static Object? _sorted(Object? value) {
    if (value is Map) {
      return {
        for (final key in value.keys.toList()..sort()) key: _sorted(value[key]),
      };
    }
    if (value is List) return value.map(_sorted).toList();
    return value;
  }

  static bool _supportedInsert(Object? data) =>
      data is String ||
      (data is Map && data.length == 1 && data['divider'] == 'hr');

  static String _signature(q.Document value) {
    final runs = <(StringBuffer, String, bool)>[];
    void append(String text, String attributes, {bool literal = false}) {
      if (text.isEmpty) return;
      if (runs.isNotEmpty &&
          runs.last.$2 == attributes &&
          runs.last.$3 == literal) {
        runs.last.$1.write(text);
      } else {
        runs.add((StringBuffer(text), attributes, literal));
      }
    }

    void trimParagraphEnd() {
      while (runs.isNotEmpty && !runs.last.$3) {
        final last = runs.last;
        final text = last.$1.toString();
        final trimmed = text.replaceFirst(RegExp(r'[ \t]+$'), '');
        if (trimmed == text) break;
        runs.removeLast();
        if (trimmed.isNotEmpty) {
          runs.add((StringBuffer(trimmed), last.$2, last.$3));
          break;
        }
      }
    }

    const inlineKeys = {
      'bold',
      'italic',
      'underline',
      'strike',
      'link',
      'code',
      'color',
      'background',
      'font',
      'size',
      'script',
      'small',
    };
    for (final operation in value.toDelta().toList()) {
      final data = operation.data;
      if (data is! String) {
        append(
          '\uFFFC',
          'embed:${jsonEncode([data, operation.attributes])}',
          literal: true,
        );
        continue;
      }
      final attributes = {...?operation.attributes}
        ..removeWhere(
          (key, value) =>
              value == null ||
              value == false ||
              (key == 'indent' && value == 0),
        );
      final inline = jsonEncode(_sorted(attributes));
      final literal = attributes['code'] == true;
      final lineAttributes = {...attributes}
        ..removeWhere((key, _) => inlineKeys.contains(key));
      final newline = jsonEncode(_sorted(lineAttributes));
      // Markdown ignores normal trailing paragraph spaces. IMEs report them
      // after every typed word; they must not trigger a false data-loss alarm.
      // Literal code whitespace and editable hard line breaks remain distinct.
      var offset = 0;
      for (
        var end = data.indexOf('\n');
        end >= 0;
        end = data.indexOf('\n', offset)
      ) {
        append(data.substring(offset, end), inline, literal: literal);
        if (!lineAttributes.containsKey('code-block')) trimParagraphEnd();
        append('\n', newline);
        offset = end + 1;
      }
      append(data.substring(offset), inline, literal: literal);
    }
    return jsonEncode([
      for (final run in runs) [run.$1.toString(), run.$2],
    ]);
  }

  String export(q.Document value) {
    if (_signature(value) == _originalDelta) return original;
    if (value.toDelta().toList().any((op) => !_supportedInsert(op.data))) {
      throw const FormatException(
        'Вставка новых изображений и объектов пока не поддерживается. Отмените вставку.',
      );
    }
    final output = _exporter.convert(value.toDelta());
    final restoredDelta = _importer.convert(output);
    final restored = restoredDelta.isEmpty
        ? q.Document()
        : q.Document.fromDelta(restoredDelta);
    final restoredSignature = _signature(restored);
    restored.close();
    if (_signature(value) != restoredSignature) {
      throw const FormatException(
        'Это форматирование нельзя безопасно сохранить в Markdown. Отмените последнее изменение.',
      );
    }
    return output;
  }
}

/// A hard line break belongs inside a paragraph, not a new Quill paragraph.
/// Unicode LINE SEPARATOR is editable text and renders as an actual line break.
class _MarkdownImporter extends MarkdownToDelta {
  _MarkdownImporter({
    required super.markdownDocument,
    super.customElementToBlockAttribute,
  });
  @override
  void visitElementAfter(md.Element element) {
    if (element.tag == 'br') {
      super.visitText(md.Text('\u2028'));
    } else {
      super.visitElementAfter(element);
    }
  }
}

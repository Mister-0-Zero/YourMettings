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
    if (document.toDelta().toList().any((op) => op.data is! String)) {
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
  static final _importer = MarkdownToDelta(
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
  static final _exporter = DeltaToMarkdown();
  static String _tree(String text) {
    Object node(md.Node n, [bool literal = false]) {
      if (n is md.Element) {
        final preserve = literal || n.tag == 'pre' || n.tag == 'code';
        return [
          n.tag,
          _sorted(n.attributes),
          (n.children ?? <md.Node>[])
              .map((child) => node(child, preserve))
              .toList(),
        ];
      }
      return literal
          ? n.textContent
          : n.textContent.replaceAll(RegExp(r'[ \t\r\n]+'), ' ');
    }

    return jsonEncode(_parse(text).map(node).toList());
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

  static String _signature(q.Document value) =>
      jsonEncode(_sorted(value.toDelta().toJson()));
  String export(q.Document value) {
    if (_signature(value) == _originalDelta) return original;
    if (value.toDelta().toList().any((op) => op.data is! String)) {
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

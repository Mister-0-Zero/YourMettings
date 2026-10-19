import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_quill/quill_delta.dart';
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
    try {
      if (_tree(original) != _tree(_convert(document))) {
        throw const FormatException('Конвертация меняет структуру Markdown.');
      }
      if (document.toDelta().toList().any((op) => !_supportedInsert(op.data))) {
        throw const FormatException(
          'Встроенный объект сохраняется неизменяемым.',
        );
      }
      _originalDelta = _signature(document, normaliseEmpty: false);
    } catch (_) {
      document.close();
      rethrow;
    }
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
  static final _exporter = _createExporter();
  static final _boundaryExporter = DeltaToMarkdown(
    customTextAttrsHandlers: {
      for (final key in ['bold', 'italic', 'strike', 'link', 'code'])
        key: CustomAttributeHandler(),
    },
    customContentHandler: _writeInline,
  );
  static DeltaToMarkdown _createExporter() => DeltaToMarkdown(
    customTextAttrsHandlers: {
      'italic': CustomAttributeHandler(
        beforeContent: (attribute, node, out) {
          if (node.previous?.style.attributes['italic']?.value != true) {
            out.write('*');
          }
        },
        afterContent: (attribute, node, out) {
          if (node.next?.style.attributes['italic']?.value != true) {
            out.write('*');
          }
        },
      ),
    },
    customContentHandler: (text, out) {
      final literal =
          text.style.attributes.containsKey('code') ||
          text.parent?.style.attributes.containsKey('code-block') == true;
      out.write(literal ? text.value : _escape(text.value));
    },
  );
  static String _escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAllMapped(
        RegExp(r'[\\`*_{}\[\]()#+.!,><|\-]'),
        (match) => '\\${match[0]}',
      )
      .replaceAll('\u2028', '  \n');
  static List<(String, Object)> _inlineChain(q.Node? node) => [
    for (final key in ['link', 'bold', 'italic', 'strike', 'code'])
      if (node?.style.attributes[key]?.value != null &&
          node?.style.attributes[key]?.value != false)
        (key, node!.style.attributes[key]!.value as Object),
  ];
  static int _common(List<(String, Object)> a, List<(String, Object)> b) {
    var count = 0;
    while (count < a.length && count < b.length && a[count] == b[count]) {
      count++;
    }
    return count;
  }

  static String _linkDestination(String value) =>
      value.replaceAllMapped(RegExp(r'[\()]'), (match) => '\\${match[0]}');

  static void _writeInline(q.QuillText text, StringSink out) {
    if (text.parent?.style.attributes.containsKey('code-block') == true) {
      out.write(text.value);
      return;
    }
    final chain = _inlineChain(text);
    String marker((String, Object) entry, bool close) => switch (entry.$1) {
      'bold' => '**',
      'italic' => '_',
      'strike' => '~~',
      'code' => '`',
      'link' => close ? '](${_linkDestination(entry.$2.toString())})' : '[',
      _ => '',
    };
    for (
      var i = _common(chain, _inlineChain(text.previous));
      i < chain.length;
      i++
    ) {
      out.write(marker(chain[i], false));
    }
    final runes = text.value.runes.toList();
    if (chain.any((e) => e.$1 == 'code')) {
      out.write(text.value);
    } else if (runes.isNotEmpty) {
      String edge(int rune) => rune == 0x2028 ? '  \n' : '&#$rune;';
      out.write(edge(runes.first));
      if (runes.length > 2) {
        out.write(
          _escape(String.fromCharCodes(runes.sublist(1, runes.length - 1))),
        );
      }
      if (runes.length > 1) out.write(edge(runes.last));
    }
    final shared = _common(chain, _inlineChain(text.next));
    for (var i = chain.length - 1; i >= shared; i--) {
      out.write(marker(chain[i], true));
    }
  }

  /// Compare semantic inline styles, not parser node segmentation or nesting
  /// order: **_text_** and _**text**_ express the same document.
  static String _tree(String text) {
    List<Map<String, Object?>> children(
      List<md.Node> nodes,
      Map<String, Object?> styles,
      bool literal,
    ) {
      final result = <Map<String, Object?>>[];
      void add(Map<String, Object?> item) {
        if (item.containsKey('text') &&
            result.isNotEmpty &&
            result.last.containsKey('text') &&
            jsonEncode(result.last['styles']) == jsonEncode(item['styles'])) {
          result.last['text'] = '${result.last['text']}${item['text']}';
        } else {
          result.add(item);
        }
      }

      for (final n in nodes) {
        if (n is md.Element) {
          final key = {
            'strong': 'bold',
            'em': 'italic',
            'del': 'strike',
            'a': 'link',
          }[n.tag];
          if (key != null) {
            final nested = {
              ...styles,
              key: n.tag == 'a' ? _sorted(n.attributes) : true,
            };
            for (final item in children(n.children ?? [], nested, literal)) {
              add(item);
            }
          } else {
            add({
              'tag': n.tag,
              'attributes': _sorted(n.attributes),
              'children': children(
                n.children ?? [],
                styles,
                literal || n.tag == 'code' || n.tag == 'pre',
              ),
            });
          }
        } else {
          add({
            'text': literal
                ? n.textContent
                : n.textContent.replaceAll(RegExp(r'[ \t\r\n]+'), ' '),
            'styles': _sorted(styles),
          });
        }
      }
      if (!literal) {
        for (final item in result) {
          if (item.containsKey('text')) {
            item['text'] = (item['text'] as String).replaceAll(
              RegExp(r'[ \t\r\n]+'),
              ' ',
            );
          }
        }
      }
      return result;
    }

    return jsonEncode(children(_parse(text), {}, false));
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

  /// Markdown emphasis cannot enclose leading/trailing spaces. Move only those
  /// spaces outside emphasis; text and formatting of every non-space stay intact.
  static Delta _markdownDelta(q.Document value, {bool removeEmpty = false}) {
    final tokens = <(Object, Map<String, dynamic>)>[];
    for (final op in value.toDelta().toList()) {
      final data = op.data;
      if (data is! String) {
        tokens.add((data!, {...?op.attributes}));
        continue;
      }
      for (final match in RegExp(r'\n|[^\S\n]+|[^\s]+').allMatches(data)) {
        tokens.add((match.group(0)!, {...?op.attributes}));
      }
    }
    for (final key in ['bold', 'italic', 'strike']) {
      var start = 0;
      while (start < tokens.length) {
        if (tokens[start].$1 == '\n' || tokens[start].$2[key] != true) {
          start++;
          continue;
        }
        var end = start + 1;
        while (end < tokens.length &&
            tokens[end].$1 != '\n' &&
            tokens[end].$2[key] == true) {
          end++;
        }
        bool blank(int i) =>
            tokens[i].$1 is String && (tokens[i].$1 as String).trim().isEmpty;
        for (var i = start; i < end && blank(i); i++) {
          tokens[i].$2.remove(key);
        }
        for (var i = end - 1; i >= start && blank(i); i--) {
          tokens[i].$2.remove(key);
        }
        start = end;
      }
    }
    final result = Delta();
    var line = <(Object, Map<String, dynamic>)>[];
    for (final token in tokens) {
      if (token.$1 != '\n') {
        line.add(token);
        continue;
      }
      // Leading ASCII indentation in an ordinary paragraph is Markdown layout,
      // not text. Keep literal inline/code-block whitespace untouched.
      if (!token.$2.containsKey('code-block')) {
        while (line.isNotEmpty &&
            line.first.$1 is String &&
            !line.first.$2.containsKey('code') &&
            RegExp(r'^[ \t]+$').hasMatch(line.first.$1 as String)) {
          line.removeAt(0);
        }
      }
      final empty =
          token.$2.isEmpty &&
          line.every(
            (t) =>
                t.$1 is String &&
                (t.$1 as String).trim().isEmpty &&
                !(t.$1 as String).contains('\u2028') &&
                t.$2.isEmpty,
          );
      if (!removeEmpty || !empty) {
        for (final t in [...line, token]) {
          result.insert(t.$1, t.$2.isEmpty ? null : t.$2);
        }
      }
      line = [];
    }
    for (final t in line) {
      result.insert(t.$1, t.$2.isEmpty ? null : t.$2);
    }
    if (result.isEmpty) result.insert('\n');
    return result;
  }

  static String _signature(q.Document value, {bool normaliseEmpty = true}) {
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
    for (final operation in _markdownDelta(
      value,
      removeEmpty: normaliseEmpty,
    ).toList()) {
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
    if (_signature(value, normaliseEmpty: false) == _originalDelta) {
      return original;
    }
    if (value.toDelta().toList().any((op) => !_supportedInsert(op.data))) {
      throw const FormatException(
        'Вставка новых изображений и объектов пока не поддерживается. Отмените вставку.',
      );
    }
    return _convert(value);
  }

  static String _convert(q.Document value) {
    final delta = _markdownDelta(value);
    for (final exporter in [_exporter, _boundaryExporter]) {
      final output = exporter.convert(delta);
      final restoredDelta = _importer.convert(output);
      final restored = restoredDelta.isEmpty
          ? q.Document()
          : q.Document.fromDelta(restoredDelta);
      final restoredSignature = _signature(restored);
      restored.close();
      if (_signature(value) == restoredSignature) return output;
    }
    throw const FormatException(
      'Это форматирование нельзя безопасно сохранить в Markdown. Отмените последнее изменение.',
    );
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

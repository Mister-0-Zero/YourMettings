import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../../app/appearance.dart';
import '../../models/api_models.dart';
import '../../services/external_links.dart';

/// One eager Markdown body: every heading has a laid-out target even in a long
/// document inside a scroll view. Rendering never changes the saved Markdown.
class SummaryDocument extends StatefulWidget {
  const SummaryDocument({
    super.key,
    required this.content,
    this.navigation = const [],
  });
  final String content;
  final List<SummaryHeading> navigation;
  @override
  State<SummaryDocument> createState() => _SummaryDocumentState();
}

class _SummaryDocumentState extends State<SummaryDocument> {
  final _targets = <String, GlobalKey>{};
  void _link(String? href) {
    if (href != null && href.startsWith('#ym-h-')) {
      final target = _targets[href.substring(1)]?.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 280),
          alignment: 0.08,
        );
      } else {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Этот раздел больше недоступен.')),
        );
      }
      return;
    }
    openExternalLink(context, href);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prefs = AppearanceScope.maybeOf(context);
    final accent = (prefs?.documentAccent ?? DocumentAccent.orange)
        .forBrightness(theme.brightness);
    final base = MarkdownStyleSheet.fromTheme(theme);
    final style = base.copyWith(
      p: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
      h1: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
      h2: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
      h3: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
      h4: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
      h5: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
      h6: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold),
      strong: TextStyle(
        fontWeight: FontWeight.bold,
        color: (prefs?.colorDocumentBold ?? true) ? accent : null,
      ),
      blockSpacing: 14,
      tableColumnWidth: const IntrinsicColumnWidth(),
    );
    _targets.removeWhere((id, _) => !widget.navigation.any((h) => h.id == id));
    for (final heading in widget.navigation) {
      _targets.putIfAbsent(heading.id, GlobalKey.new);
    }
    final headingBuilder = _HeadingBuilder(_targets, style, _link);
    final minLevel = widget.navigation.isEmpty
        ? 1
        : widget.navigation.map((h) => h.level).reduce((a, b) => a < b ? a : b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.navigation.length > 1) ...[
          Card(
            margin: const EdgeInsets.only(bottom: 20),
            child: ExpansionTile(
              title: const Text('Оглавление'),
              initiallyExpanded: false,
              children: [
                for (final heading in widget.navigation)
                  Padding(
                    padding: EdgeInsets.only(
                      left: ((heading.level - minLevel).clamp(0, 4)) * 12.0,
                    ),
                    child: ListTile(
                      dense: true,
                      key: ValueKey('toc-${heading.id}'),
                      title: Text(
                        md.Document(encodeHtml: false)
                            .parseInline(heading.title)
                            .map((node) => node.textContent)
                            .join(),
                      ),
                      onTap: () => _link('#${heading.id}'),
                    ),
                  ),
              ],
            ),
          ),
        ],
        MarkdownBody(
          data: widget.content,
          selectable: true,
          styleSheet: style,
          blockSyntaxes: [
            _IndexedHeadingSyntax(widget.content, widget.navigation),
            const _MetadataSyntax(),
          ],
          builders: {
            for (var i = 1; i <= 6; i++) 'h$i': headingBuilder,
            'ym-meta': _MetadataBuilder(style, _link),
          },
          onTapLink: (_, href, _) => _link(href),
          imageBuilder: (uri, title, alt) => Text(alt ?? 'Изображение'),
        ),
      ],
    );
  }
}

/// Source line indices, not heading titles, connect the server navigation to
/// the AST. Setext headings, blockquotes and code samples cannot shift targets.
class _IndexedHeadingSyntax extends md.HeaderSyntax {
  _IndexedHeadingSyntax(String source, List<SummaryHeading> headings)
    : _source = const LineSplitter().convert(source).join('\n'),
      _byLine = {for (final h in headings) h.lineIndex: h.id};
  final String _source;
  final Map<int, String> _byLine;
  final _rootParsers = <md.BlockParser, bool>{};
  @override
  md.Node parse(md.BlockParser parser) {
    final root = _rootParsers.putIfAbsent(
      parser,
      () => parser.lines.map((l) => l.content).join('\n') == _source,
    );
    final line = root ? parser.lines.indexOf(parser.current) : -1;
    final element = super.parse(parser) as md.Element;
    final id = _byLine[line];
    if (id != null) {
      element.attributes['data-ym-id'] = id;
    }
    return element;
  }
}

class _HeadingBuilder extends MarkdownElementBuilder {
  _HeadingBuilder(this.targets, this.style, this.link);
  final Map<String, GlobalKey> targets;
  final MarkdownStyleSheet style;
  final void Function(String?) link;
  @override
  bool isBlockElement() => true;
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    return Padding(
      key: targets[element.attributes['data-ym-id']],
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Semantics(
        key: ValueKey(
          'heading-${element.attributes['data-ym-id'] ?? element.textContent}',
        ),
        header: true,
        child: MarkdownBody(
          data: _inline(element.children ?? []),
          selectable: true,
          styleSheet: style.copyWith(p: preferredStyle),
          onTapLink: (_, href, _) => link(href),
        ),
      ),
    );
  }

  String _inline(List<md.Node> nodes) => nodes.map((n) {
    if (n is md.Text) {
      return n.text.replaceAllMapped(
        RegExp(r'[\\`*_{}\[\]<>#~]'),
        (m) => String.fromCharCode(92) + m[0]!,
      );
    }
    if (n is! md.Element) {
      return n.textContent;
    }
    final text = _inline(n.children ?? []);
    return switch (n.tag) {
      'strong' => '**$text**',
      'em' => '*$text*',
      'del' => '~~$text~~',
      'a' => '[$text](<${n.attributes['href'] ?? ''}>)',
      'code' => '`` ${n.textContent} ``',
      'br' => '  \n',
      'img' => n.attributes['alt'] ?? '',
      _ => text,
    };
  }).join();
}

/// Styles metadata explicitly labelled by the summary author/Qwen. It neither
/// reads the transcript nor infers dates or people from ordinary prose.
class _MetadataBuilder extends _HeadingBuilder {
  _MetadataBuilder(MarkdownStyleSheet style, void Function(String?) link)
    : super(const {}, style, link);
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return MarkdownBody(
      data: _inline(element.children ?? []),
      selectable: true,
      styleSheet: style.copyWith(
        p: theme.textTheme.bodySmall?.copyWith(color: muted, height: 1.5),
        strong: TextStyle(fontWeight: FontWeight.bold, color: muted),
      ),
      onTapLink: (_, href, _) => link(href),
    );
  }
}

class _MetadataSyntax extends md.BlockSyntax {
  const _MetadataSyntax();
  @override
  RegExp get pattern => RegExp(
    r'^ {0,3}[*][*](?:Дата|Дата встречи|Участники|Участники встречи):[*][*]',
  );
  @override
  bool canEndBlock(md.BlockParser parser) => false;
  @override
  md.Node? parse(md.BlockParser parser) {
    final node = const md.ParagraphSyntax().parse(parser);
    return node is md.Element && node.tag == 'p'
        ? md.Element('ym-meta', node.children)
        : node;
  }
}

import '../../services/external_links.dart';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;

import 'visual_document.dart';

class VisualEditorToolbar extends StatelessWidget {
  const VisualEditorToolbar({
    super.key,
    required this.document,
    required this.enabled,
  });
  final VisualDocument document;
  final bool enabled;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: document,
    builder: (context, _) {
      final active = document.active;
      if (active == null) {
        return const Padding(
          padding: EdgeInsets.all(12),
          child: Text('Сложные блоки сохранены без изменений.'),
        );
      }
      return IgnorePointer(
        ignoring: !enabled,
        child: q.QuillSimpleToolbar(
          key: ValueKey(active),
          controller: active.controller!,
          config: const q.QuillSimpleToolbarConfig(
            multiRowsDisplay: false,
            showDividers: false,
            showFontFamily: false,
            showFontSize: false,
            showUnderLineButton: false,
            showStrikeThrough: false,
            showInlineCode: false,
            showColorButton: false,
            showBackgroundColorButton: false,
            showClearFormat: false,
            showListCheck: false,
            showCodeBlock: false,
            showQuote: false,
            showIndent: false,
            showSearchButton: false,
            showSubscript: false,
            showSuperscript: false,
          ),
        ),
      );
    },
  );
}

class VisualEditorBody extends StatelessWidget {
  const VisualEditorBody({
    super.key,
    required this.document,
    required this.enabled,
  });
  final VisualDocument document;
  final bool enabled;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: document,
    builder: (context, _) => _body(context),
  );
  Widget _body(BuildContext context) {
    for (final section in document.sections) {
      section.controller?.readOnly = !enabled;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (document.hasProtected)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'Блоки с замком доступны только для просмотра и сохраняются без изменений.',
            ),
          ),
        for (final section in document.sections)
          if (section.protected)
            Container(
              key: ValueKey(section),
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.lock_outline, size: 18),
                      SizedBox(width: 6),
                      Expanded(child: Text('Неизменяемый блок')),
                    ],
                  ),
                  const SizedBox(height: 8),
                  MarkdownBody(
                    data: section.source,
                    onTapLink: (_, href, _) => openExternalLink(context, href),
                    selectable: true,
                    styleSheet: MarkdownStyleSheet.fromTheme(
                      Theme.of(context),
                    ).copyWith(tableColumnWidth: const IntrinsicColumnWidth()),
                    imageBuilder: (uri, title, alt) =>
                        Text(alt ?? 'Изображение'),
                  ),
                ],
              ),
            )
          else
            q.QuillEditor(
              key: ValueKey(section),
              controller: section.controller!,
              focusNode: section.focus,
              scrollController: section.scroll,
              config: q.QuillEditorConfig(
                onLaunchUrl: (url) => openExternalLink(context, url),
                scrollable: false,
                embedBuilders: const [_DividerBuilder()],
                unknownEmbedBuilder: const _UnsupportedEmbedBuilder(),
                minHeight: 64,
                padding: const EdgeInsets.symmetric(vertical: 8),
                placeholder: 'Текст встречи…',
                enableScribble: false,
              ),
            ),
      ],
    );
  }
}

class _UnsupportedEmbedBuilder extends q.EmbedBuilder {
  const _UnsupportedEmbedBuilder();
  @override
  String get key => 'unsupported';
  @override
  Widget build(BuildContext context, q.EmbedContext embedContext) =>
      const Text('Вставленный объект не поддерживается. Отмените вставку.');
}

class _DividerBuilder extends q.EmbedBuilder {
  const _DividerBuilder();
  @override
  String get key => 'divider';
  @override
  Widget build(BuildContext context, q.EmbedContext embedContext) =>
      const Divider(height: 24);
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:markdown/markdown.dart' as md;

import 'visual_markdown.dart';

class VisualSection {
  VisualSection.protected(this.source) : bridge = null, controller = null;
  VisualSection.editable(this.source, this.bridge)
    : controller = q.QuillController(
        document: bridge!.document,
        selection: const TextSelection.collapsed(offset: 0),
      );
  final String source;
  final VisualMarkdown? bridge;
  final q.QuillController? controller;
  final editorKey = GlobalKey<q.EditorState>();
  final focus = FocusNode();
  final scroll = ScrollController();
  StreamSubscription<q.DocChange>? subscription;
  bool get protected => controller == null;
  String export() => bridge?.export(controller!.document) ?? source;
  void dispose() {
    subscription?.cancel();
    controller?.dispose();
    focus.dispose();
    scroll.dispose();
  }
}

/// Protected sections never enter the converter or an editable text input.
class VisualDocument extends ChangeNotifier {
  VisualDocument(String source, {required this.onChanged}) {
    final units = _units(source);
    var editable = '';
    void flush() {
      if (editable.isEmpty) return;
      try {
        sections.add(
          VisualSection.editable(editable, VisualMarkdown(editable)),
        );
      } on FormatException {
        sections.add(VisualSection.protected(editable));
      }
      editable = '';
    }

    for (final unit in units) {
      try {
        final candidate = VisualMarkdown(unit);
        candidate.document.close();
        editable += unit;
      } on FormatException {
        flush();
        sections.add(VisualSection.protected(unit));
      }
    }
    flush();
    if (sections.isEmpty) {
      sections.add(VisualSection.editable('', VisualMarkdown('')));
    }
    active = sections.where((s) => !s.protected).firstOrNull;
    for (final section in sections) {
      _wire(section);
    }
  }
  void _wire(VisualSection section) {
    section.focus.addListener(() {
      if (section.focus.hasFocus && active != section) {
        active = section;
        notifyListeners();
      }
    });
    section.subscription = section.controller?.document.changes.listen((_) {
      try {
        onChanged(export(), null);
      } on FormatException catch (e) {
        onChanged(null, e.message);
      }
    });
  }

  final void Function(String? content, String? error) onChanged;
  final List<VisualSection> sections = [];
  VisualSection? active;
  bool get hasProtected => sections.any((s) => s.protected);
  String export() {
    final parts = sections.map((s) => s.export()).toList();
    for (var i = 0; i < sections.length; i++) {
      if (sections[i].protected || parts[i] == sections[i].source) continue;
      // Canonical converters trim leading blank lines. Keep an edited paragraph
      // from becoming an extra table row, list item or code continuation.
      if (i > 0 && sections[i - 1].protected) parts[i] = '\n\n${parts[i]}';
      if (i + 1 < sections.length && sections[i + 1].protected) {
        parts[i] = '${parts[i]}\n\n';
      }
    }
    return parts.join();
  }

  @override
  void dispose() {
    for (final section in sections) {
      section.dispose();
    }
    super.dispose();
  }

  static List<String> _units(String source) {
    // References carry document-wide context. Keep the dependency group intact.
    if (RegExp(r'(^|[\r\n]) {0,3}\[[^\]]+\]:').hasMatch(source)) {
      return [source];
    }
    final raw = RegExp(r'[^\r\n]*(?:\r\n|\n|\r|$)')
        .allMatches(source)
        .where((m) => m.end > m.start)
        .map((m) => m.group(0)!)
        .toList();
    if (raw.isEmpty) return [''];
    final lines = raw
        .map((s) => md.Line(s.replaceFirst(RegExp(r'[\r\n]+$'), '')))
        .toList();
    final doc = md.Document(
      extensionSet: md.ExtensionSet.gitHubWeb,
      encodeHtml: false,
    );
    final units = <String>[];
    var offset = 0;
    while (offset < lines.length) {
      final parser = _SpanParser(lines.sublist(offset), doc);
      final count = parser.readBlock();
      if (count <= 0) {
        return [
          source,
        ]; // Unknown parser behavior: preserve the dependency group.
      }
      units.add(raw.sublist(offset, offset + count).join());
      offset += count;
    }
    // Raw HTML can span Markdown blocks with document-wide nesting.
    if (units.any(
      (unit) => RegExp(r'^ {0,3}<(?:!--|/?[A-Za-z])').hasMatch(unit),
    )) {
      return [source];
    }
    return units;
  }
}

/// The package exposes block parsers but not source offsets. Track only root-line
/// advancement; nested blocks still use the package's own parsing implementation.
class _SpanParser extends md.BlockParser {
  _SpanParser(super.lines, super.document);
  int position = 0;
  md.BlockSyntax? active;
  md.BlockSyntax? previous;
  @override
  md.BlockSyntax? get currentSyntax => active;
  @override
  md.BlockSyntax? get previousSyntax => previous;
  @override
  void advance() {
    super.advance();
    position++;
  }

  @override
  void retreat() {
    super.retreat();
    position--;
  }

  @override
  void retreatBy(int count) {
    super.retreatBy(count);
    position -= count;
  }

  int readBlock() {
    md.BlockSyntax? neverMatch;
    var stalled = 0;
    while (!isDone) {
      final before = position;
      for (final syntax in blockSyntaxes) {
        if (identical(syntax, neverMatch) || !syntax.canParse(this)) continue;
        previous = active;
        active = syntax;
        final node = syntax.parse(this);
        neverMatch = position == before ? syntax : null;
        if (node != null ||
            syntax is md.EmptyBlockSyntax ||
            syntax is md.LinkReferenceDefinitionSyntax) {
          return position;
        }
        break;
      }
      stalled = position == before ? stalled + 1 : 0;
      if (stalled > 2) return 0;
    }
    return position;
  }
}

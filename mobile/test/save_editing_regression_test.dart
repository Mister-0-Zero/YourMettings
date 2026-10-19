import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:your_mettings/features/meetings/visual_markdown.dart';

void main() {
  for (final entry in <String, void Function(q.Document)>{
    'empty paragraph': (d) => d.insert(3, '\n\n'),
    'leading empty paragraph': (d) => d.insert(0, '\n'),
    'bold with trailing space': (d) => d.format(0, 4, q.Attribute.bold),
    'italic inside word': (d) => d.format(1, 2, q.Attribute.italic),
    'bold inside word': (d) => d.format(1, 2, q.Attribute.bold),
    'nested bold italic': (d) {
      d.format(0, 8, q.Attribute.bold);
      d.format(2, 3, q.Attribute.italic);
    },
    'blank heading': (d) {
      d.delete(0, d.length - 1);
      d.format(0, 0, q.Attribute.h2);
    },
  }.entries) {
    test(entry.key, () {
      final bridge = VisualMarkdown('One word text');
      addTearDown(bridge.document.close);
      entry.value(bridge.document);
      expect(() => bridge.export(bridge.document), returnsNormally);
    });
  }
}

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:your_mettings/features/meetings/visual_markdown.dart';

void main() {
  test('selection boundary stress', () {
    final random = Random(20261020);
    final failures = <Object>[];
    for (var n = 0; n < 400; n++) {
      final bridge = VisualMarkdown('Раз два, три.');
      final d = bridge.document;
      for (var j = 0; j < 3; j++) {
        final start = random.nextInt(d.length - 1);
        final count = 1 + random.nextInt(d.length - 1 - start);
        d.format(
          start,
          count,
          <q.Attribute>[
            q.Attribute.bold,
            q.Attribute.italic,
            q.LinkAttribute('https://example.com/plan'),
          ][random.nextInt(3)],
        );
      }
      try {
        final output = bridge.export(d);
        final reopened = VisualMarkdown(output);
        expect(reopened.document.toPlainText(), d.toPlainText());
        expect(reopened.export(reopened.document), output);
        reopened.document.close();
      } catch (e) {
        failures.add('$n: $e');
      }
      d.close();
    }
    expect(failures, isEmpty, reason: 'failed ${failures.length}/400');
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:your_mettings/features/meetings/visual_document.dart';

void main() {
  test(
    'real Qwen tasks and escaped punctuation stay in one editable document',
    () {
      final source = File('test/fixtures/qwen_summary.md').readAsStringSync();
      final model = VisualDocument(source, onChanged: (_, _) {});
      addTearDown(model.dispose);
      expect(model.hasProtected, isFalse);
      expect(model.sections.length, 1);
      expect(model.export(), source);
      final doc = model.sections.single.controller!.document;
      final before = doc.toPlainText();
      final offset = before.indexOf('Мария');
      doc.delete(offset, 5);
      doc.insert(offset, 'Алексей');
      doc.format(before.indexOf('Краткое содержание'), 18, q.Attribute.italic);
      final output = model.export();
      final reopened = VisualDocument(output, onChanged: (_, _) {});
      addTearDown(reopened.dispose);
      expect(reopened.hasProtected, isFalse);
      expect(
        reopened.sections.single.controller!.document.toPlainText(),
        before.replaceFirst('Мария', 'Алексей'),
      );
      expect(
        reopened.sections.single.controller!.document.toDelta().toJson(),
        doc.toDelta().toJson(),
      );
    },
  );
  test('hard breaks and checklists stay editable and survive editing', () {
    const source =
        'Первая  \nвторая\n\n- [x] Мария: тесты до четверга\n- [ ] Иван: релиз в пятницу\n';
    final model = VisualDocument(source, onChanged: (_, _) {});
    addTearDown(model.dispose);
    expect(model.hasProtected, isFalse);
    model.sections.single.controller!.document.insert(0, 'Правка ');
    final output = model.export();
    final reopened = VisualDocument(output, onChanged: (_, _) {});
    addTearDown(reopened.dispose);
    expect(reopened.hasProtected, isFalse);
    expect(
      reopened.sections.single.controller!.document.toDelta().toJson(),
      model.sections.single.controller!.document.toDelta().toJson(),
    );
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:your_mettings/features/meetings/visual_document.dart';
import 'package:your_mettings/features/meetings/visual_editor.dart';

void main() {
  testWidgets('new visual paragraph accepts Android text input', (
    tester,
  ) async {
    String? error;
    final model = VisualDocument(
      '|A|B|\n|-|-|\n|1|2|\n',
      onChanged: (_, message) {
        error = message;
      },
    );
    addTearDown(model.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [q.FlutterQuillLocalizations.delegate],
        home: Scaffold(
          body: Column(
            children: [
              VisualEditorToolbar(document: model, enabled: true),
              Expanded(
                child: ListView(
                  children: [VisualEditorBody(document: model, enabled: true)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Добавить абзац после'));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.hasAnyClients, isTrue);
    const text = 'New paragraph after table.';
    for (var offset = 1; offset <= text.length; offset++) {
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '${text.substring(0, offset)}\n',
          selection: TextSelection.collapsed(offset: offset),
        ),
      );
      await tester.pump();
      expect(error, isNull, reason: 'IME prefix: ${text.substring(0, offset)}');
    }
    expect(tester.takeException(), isNull);
    expect(model.export(), contains('New paragraph after table'));
  });
}

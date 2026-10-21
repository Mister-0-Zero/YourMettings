import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/meetings/summary_page.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/models/api_models.dart';

import 'visual_editor_test.dart' show MemoryStore;
import 'summary_editor_test.dart' as fixture;

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'toolbar and heading menu remain above keyboard in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(1264, 2736);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        final api = ApiClient(
          Uri.parse('http://localhost/api/v1/'),
          client: MockClient(
            (r) async => http.Response.bytes(
              utf8.encode(jsonEncode(fixture.summaryJson)),
              200,
            ),
          ),
        );
        final c = MeetingController(api, MemoryStore());
        addTearDown(() {
          c.dispose();
          api.close();
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            localizationsDelegates: const [
              q.FlutterQuillLocalizations.delegate,
            ],
            home: SummaryPageView(
              controller: c,
              summary: MeetingSummary.fromJson(fixture.summaryJson),
              startEditing: true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final editor = tester.widget<q.QuillEditor>(
          find.byType(q.QuillEditor).first,
        );
        editor.focusNode.requestFocus();
        editor.controller.updateSelection(
          const TextSelection(baseOffset: 0, extentOffset: 3),
          q.ChangeSource.local,
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 960);
        await tester.pumpAndSettle();
        final selection = editor.controller.selection;
        final toolbar = find.byKey(const Key('editor-formatting-toolbar'));
        const keyboardTop = (2736 - 960) / 3;
        expect(tester.getBottomRight(toolbar).dy, closeTo(keyboardTop, 1));
        await tester.tap(
          find.byWidgetPredicate(
            (w) =>
                w is q.QuillToolbarToggleStyleButton &&
                w.attribute == q.Attribute.bold,
          ),
        );
        await tester.pump();
        expect(editor.controller.selection, selection);
        await tester.tap(
          find.byType(q.QuillToolbarSelectHeaderStyleDropdownButton),
        );
        await tester.pumpAndSettle();
        final menu = find.byType(MenuItemButton);
        expect(menu, findsNWidgets(4));
        for (final element in menu.evaluate()) {
          expect(
            tester.getBottomRight(find.byWidget(element.widget)).dy,
            lessThanOrEqualTo(keyboardTop),
          );
        }
        await tester.tap(menu.first);
        await tester.pumpAndSettle();
        expect(editor.controller.selection, selection);
        expect(
          editor.controller
              .getSelectionStyle()
              .attributes[q.Attribute.header.key]
              ?.value,
          1,
        );
        tester.view.viewInsets = FakeViewPadding.zero;
        await tester.pumpAndSettle();
        expect(tester.getBottomRight(toolbar).dy, greaterThan(keyboardTop));
        expect(tester.takeException(), isNull);
      },
    );
  }
}

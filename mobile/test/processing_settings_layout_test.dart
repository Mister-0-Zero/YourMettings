import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/features/new_meeting/transcript_page.dart';

import 'visual_editor_test.dart' show MemoryStore;

void main() {
  for (final brightness in Brightness.values) {
    for (final width in [320.0, 390.0, 430.0]) {
      testWidgets(
        'settings fit $width ${brightness.name}, including keyboard',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 900));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final api = ApiClient(Uri.parse('http://localhost/'));
          final controller = MeetingController(api, MemoryStore());
          addTearDown(() {
            controller.dispose();
            api.close();
          });
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(1.3)),
                child: child!,
              ),
              home: TranscriptPage(controller: controller),
            ),
          );
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text('Настройки обработки'),
            250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Настройки обработки'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Детализация summary'));
          await tester.pumpAndSettle();
          final label = tester.getRect(find.text('Детализация summary'));
          final heading = tester.getRect(
            find.text('Подробность и акценты итогового документа'),
          );
          expect(label.top, greaterThan(heading.bottom));
          expect(label.left, greaterThanOrEqualTo(0));
          expect(label.right, lessThanOrEqualTo(width));
          expect(tester.takeException(), isNull);
          tester.view.viewInsets = FakeViewPadding(bottom: 300);
          addTearDown(tester.view.resetViewInsets);
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Детализация summary'));
          await tester.pumpAndSettle();
          expect(
            tester.getRect(find.text('Детализация summary')).bottom,
            lessThan(600),
          );
          await tester.ensureVisible(find.byType(TextFormField).last);
          await tester.pumpAndSettle();
          await tester.tap(find.byType(TextFormField).last);
          await tester.pump();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

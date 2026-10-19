import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/features/new_meeting/transcript_page.dart';
import 'package:your_mettings/services/recovery_store.dart';

import 'visual_editor_test.dart' show MemoryStore;

void main() {
  for (final brightness in Brightness.values) {
    for (final keyboard in [0.0, 300.0]) {
      testWidgets(
        'jump skips long transcript ${brightness.name} keyboard=$keyboard',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(320, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final api = ApiClient(Uri.parse('http://localhost/'));
          final controller = MeetingController(api, MemoryStore());
          addTearDown(() {
            controller.dispose();
            api.close();
          });
          final text = List.filled(
            500,
            'Строка длинного транскрипта встречи.',
          ).join('\n');
          controller.recovery = RecoveryState(
            draft: Draft(title: 'QA jump', text: text, folderIds: []),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: TranscriptPage(controller: controller),
            ),
          );
          await tester.pumpAndSettle();
          tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
          addTearDown(tester.view.resetViewInsets);
          await tester.pump();
          expect(
            find.byTooltip('К папкам и настройкам').hitTestable(),
            findsOneWidget,
          );
          await tester.tap(find.byTooltip('К папкам и настройкам'));
          await tester.pumpAndSettle();
          expect(
            find.text('Выбрать или создать папки').hitTestable(),
            findsOneWidget,
          );
          expect(
            find.text('Настройки обработки').hitTestable(),
            findsOneWidget,
          );
          expect(find.byType(FloatingActionButton), findsNothing);
          expect(controller.draft.text, text);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

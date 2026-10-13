import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/app/appearance.dart';
import 'package:your_mettings/features/meetings/summary_page.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/recovery_store.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'structured Markdown and wide table at 320px in ${brightness.name}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final json = {
          'id': 's',
          'transcript_id': 't',
          'title': 'Очень длинное название встречи для проверки верхней панели',
          'content': '## Решения\nАбзац.\n\n### Задача 1\n**Ответственный:** Мария\n\n**Срок:** четверг\n\n- Проверить Android\n\n1. Подготовить отчёт\n\n| VeryLongColumnHeadingWithoutSpaces | SecondVeryLongHeadingWithoutSpaces |\n|---|---|\n| WideValueWithoutSpacesAndWrapping | AnotherWideValueWithoutSpaces |',
          'folder_ids': ['f'],
          'created_at': '2026-10-13T12:00:00Z',
          'updated_at': '2026-10-13T12:00:00Z',
        };
        final api = ApiClient(
          Uri.parse('http://localhost/api/v1/'),
          client: MockClient(
            (_) async =>
                http.Response.bytes(utf8.encode(jsonEncode(json)), 200),
          ),
        );
        final controller = MeetingController(api, MemoryStore());
        addTearDown(() {
          controller.dispose();
          api.close();
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: AppearanceController().theme(brightness),
            home: SummaryPageView(
              controller: controller,
              summary: MeetingSummary.fromJson(json),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Решения'), findsOneWidget);
        expect(find.text('Задача 1'), findsOneWidget);
        final horizontal = find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              (widget.axisDirection == AxisDirection.right ||
                  widget.axisDirection == AxisDirection.left),
        );
        expect(horizontal, findsOneWidget);
        final state = tester.state<ScrollableState>(horizontal);
        expect(state.position.maxScrollExtent, greaterThan(0));
        await tester.drag(horizontal, const Offset(-120, 0));
        await tester.pumpAndSettle();
        expect(state.position.pixels, greaterThan(0));
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class MemoryStore implements RecoveryStore {
  @override
  Future<RecoveryState> load() async => RecoveryState();
  @override
  Future<void> save(RecoveryState value) async {}
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/meetings/summary_page.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/features/new_meeting/transcript_page.dart';
import 'package:your_mettings/models/api_models.dart';

import 'summary_editor_test.dart' as fixture;
import 'visual_editor_test.dart' show MemoryStore;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? copied;
  var failClipboard = false;
  var writes = 0;
  setUp(() {
    copied = null;
    failClipboard = false;
    writes = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            writes++;
            if (failClipboard) {
              throw PlatformException(code: 'clipboard_unavailable');
            }
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  final markdown =
      '${File('test/fixtures/qwen_summary.md').readAsStringSync()}\n'
      '| Задача | Срок |\n|---|---|\n| Сохранить всё | пятница |\n'
      '```text\n  indented  \n```\n';
  final latest = MeetingSummary.fromJson({
    ...fixture.summaryJson,
    'title': 'Актуальный итог',
    'content': markdown,
  });

  for (final generated in [false, true]) {
    testWidgets(
      'copy exact confirmed source from ${generated ? 'generation result' : 'saved summary'}, with no extra HTTP',
      (tester) async {
        final requests = <String>[];
        final api = ApiClient(
          Uri.parse('http://example/api/v1/'),
          client: MockClient((r) async {
            requests.add('${r.method} ${r.url.path}');
            expect(r.method, 'GET');
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  ...fixture.summaryJson,
                  'title': latest.title,
                  'content': markdown,
                }),
              ),
              200,
            );
          }),
        );
        final c = MeetingController(api, MemoryStore())..result = latest;
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: const [FlutterQuillLocalizations.delegate],
            home: generated
                ? GeneratedSummaryPage(controller: c)
                : SummaryPageView(
                    controller: c,
                    summary: MeetingSummary.fromJson(fixture.summaryJson),
                  ),
          ),
        );
        await tester.pumpAndSettle();
        if (!generated) {
          await tester.tap(find.byType(PopupMenuButton<String>));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('Копировать итог'));
        await tester.pumpAndSettle();
        expect(copied, '${latest.title}\n\n$markdown');
        expect(writes, 1);
        expect(find.text('Итог встречи скопирован'), findsOneWidget);
        expect(requests.length, generated ? 0 : 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        api.close();
      },
    );
  }

  testWidgets(
    'clipboard error shows failure and supports retry without changing result',
    (tester) async {
      final api = ApiClient(
        Uri.parse('http://example/api/v1/'),
        client: MockClient(
          (_) async => throw StateError('Clipboard must be local'),
        ),
      );
      final c = MeetingController(api, MemoryStore())..result = latest;
      failClipboard = true;
      await tester.pumpWidget(
        MaterialApp(home: GeneratedSummaryPage(controller: c)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Копировать итог'));
      await tester.pumpAndSettle();
      expect(copied, isNull);
      expect(find.text('Итог встречи скопирован'), findsNothing);
      expect(
        find.text('Не удалось скопировать итог. Повторите попытку.'),
        findsOneWidget,
      );
      expect(c.result, same(latest));
      failClipboard = false;
      await tester.tap(find.text('Копировать итог'));
      await tester.pumpAndSettle();
      expect(copied, '${latest.title}\n\n$markdown');
      expect(writes, 2);
      expect(find.text('Итог встречи скопирован'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      api.close();
    },
  );
}

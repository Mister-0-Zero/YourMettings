import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/meetings/summary_page.dart';
import 'package:your_mettings/features/meetings/visual_document.dart';
import 'package:your_mettings/features/meetings/visual_editor.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/features/new_meeting/transcript_page.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/external_links.dart';

import 'summary_editor_test.dart' as fixture;
import 'visual_editor_test.dart' show MemoryStore;

const link = '[Открыть план](https://example.com/plan)';
void main() {
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  for (final mode in ['summary', 'processing', 'protected', 'editor']) {
    testWidgets('link launches externally from $mode', (tester) async {
      final launches = <Map>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'launch');
        launches.add(call.arguments as Map);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final data = {...fixture.summaryJson, 'content': link};
      final api = ApiClient(
        Uri.parse('http://localhost/'),
        client: MockClient(
          (_) async => http.Response.bytes(utf8.encode(jsonEncode(data)), 200),
        ),
      );
      final controller = MeetingController(api, MemoryStore());
      addTearDown(() {
        controller.dispose();
        api.close();
      });
      controller.result = MeetingSummary.fromJson(data);
      Widget child;
      if (mode == 'summary') {
        child = SummaryPageView(
          controller: controller,
          summary: controller.result!,
        );
      } else if (mode == 'processing') {
        child = Scaffold(body: ProcessingPanel(controller: controller));
      } else {
        final model = VisualDocument(
          mode == 'protected' ? '| A | B |\n|---|---|\n|$link|text|\n' : link,
          onChanged: (_, _) {},
        );
        addTearDown(model.dispose);
        child = Scaffold(
          body: VisualEditorBody(document: model, enabled: true),
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [q.FlutterQuillLocalizations.delegate],
          home: child,
        ),
      );
      await tester.pumpAndSettle();
      if (mode == 'editor') {
        tester
            .widget<q.QuillEditor>(find.byType(q.QuillEditor))
            .config
            .onLaunchUrl!('https://example.com/plan');
      } else {
        await tester.tap(find.text('Открыть план', findRichText: true));
      }
      await tester.pumpAndSettle();
      expect(launches.single['url'], 'https://example.com/plan');
      expect(launches.single['useWebView'], false);
      expect(launches.single['useSafariVC'], false);
    });
  }
  for (final failure in ['rejected', 'false', 'exception']) {
    testWidgets('link $failure gives visible feedback', (tester) async {
      var launches = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        launches++;
        if (failure == 'exception') {
          throw PlatformException(code: 'NO_ACTIVITY');
        }
        return false;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => openExternalLink(
                  context,
                  failure == 'rejected'
                      ? 'javascript:alert(1)'
                      : 'https://example.com',
                ),
                child: const Text('Ссылка'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Ссылка'));
      await tester.pumpAndSettle();
      expect(find.text('Не удалось открыть ссылку.'), findsOneWidget);
      expect(launches, failure == 'rejected' ? 0 : 1);
    });
  }
}

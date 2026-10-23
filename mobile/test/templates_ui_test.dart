import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/models/summary_template.dart';
import 'package:your_mettings/features/templates/templates_page.dart';
import 'package:your_mettings/features/templates/template_selector.dart';
import 'package:your_mettings/features/templates/template_preview_page.dart';

http.Response response(Object json, [int code = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(json)), code);
final section = TemplateSection(
  id: '10000000-0000-4000-8000-000000000001',
  title: 'Итоги',
  instruction: 'Сохрани решения',
);
TemplateInput input() => TemplateInput(
  name: 'План',
  sections: [
    section,
    TemplateSection(
      id: '10000000-0000-4000-8000-000000000002',
      title: 'Темы',
      instruction: 'Выдели темы',
      repeated: true,
      children: [
        TemplateSection(
          id: '10000000-0000-4000-8000-000000000003',
          title: 'Задачи',
          instruction: 'Сохрани сроки',
        ),
      ],
    ),
  ],
);
Map<String, dynamic> record(TemplateInput data, {bool system = false}) => {
  ...data.toJson(),
  'id': 'tpl',
  'is_system': system,
  'is_default': system,
};
Future<void> openEditor(
  WidgetTester tester,
  ApiClient api, {
  SummaryTemplate? template,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push<SummaryTemplate>(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    TemplateEditorPage(api: api, template: template),
              ),
            ),
            child: const Text('Открыть'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Открыть'));
  await tester.pumpAndSettle();
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'system templates read only; copy creates user template and save uses PUT',
    (tester) async {
      final requests = <http.Request>[];
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((r) async {
          requests.add(r);
          if (r.url.path.endsWith('/copy')) {
            return response(record(input()), 201);
          }
          if (r.method == 'PUT') {
            return response(
              record(TemplateInput.fromJson(jsonDecode(r.body))),
              200,
            );
          }
          return response(record(input(), system: true));
        }),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: TemplateDetailsPage(
            api: api,
            template: SummaryTemplate.fromJson(record(input(), system: true)),
          ),
        ),
      );
      expect(find.text('Редактировать'), findsNothing);
      expect(find.text('Удалить шаблон'), findsNothing);
      await reveal(tester, find.text('Копировать и настроить'));
      await tester.tap(find.text('Копировать и настроить'));
      await tester.pumpAndSettle();
      expect(requests.single.url.path, '/api/v1/summary-templates/tpl/copy');
      await tester.enterText(find.byType(TextFormField).first, 'Моя копия');
      await tester.tap(find.byTooltip('Сохранить шаблон'));
      await tester.pumpAndSettle();
      expect(requests.last.method, 'PUT');
      expect(jsonDecode(requests.last.body)['name'], 'Моя копия');
      expect(jsonDecode(requests.last.body).containsKey('is_system'), false);
    },
  );
  testWidgets(
    'editor reorders nested sections, preserves IDs and stays on failed save',
    (tester) async {
      var fail = true;
      Map<String, dynamic>? sent;
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((r) async {
          sent = jsonDecode(r.body) as Map<String, dynamic>;
          if (fail) {
            return response({
              'error': {
                'code': 'database_unavailable',
                'message': 'Нет связи с базой',
              },
            }, 503);
          }
          return response(record(TemplateInput.fromJson(sent!)));
        }),
      );
      addTearDown(api.close);
      await openEditor(
        tester,
        api,
        template: SummaryTemplate.fromJson(record(input())),
      );
      await reveal(tester, find.byTooltip('Переместить ниже').first);
      await tester.tap(find.byTooltip('Переместить ниже').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Сохранить шаблон'));
      await tester.pumpAndSettle();
      expect(sent!['sections'][0]['type'], 'repeated');
      expect(sent!['sections'][0]['position'], 0);
      expect(
        sent!['sections'][0]['id'],
        '10000000-0000-4000-8000-000000000002',
      );
      expect(
        sent!['sections'][0]['children'][0]['id'],
        '10000000-0000-4000-8000-000000000003',
      );
      expect(find.byType(TemplateEditorPage), findsOneWidget);
      await reveal(tester, find.text('Нет связи с базой'));
      expect(find.text('Нет связи с базой'), findsOneWidget);
      fail = false;
      await tester.tap(find.byTooltip('Сохранить шаблон'));
      await tester.pumpAndSettle();
      expect(find.text('Открыть'), findsOneWidget);
    },
  );
  testWidgets(
    'new template protects unsaved changes and cancel retains editing',
    (tester) async {
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((_) async => throw StateError('No API on cancel')),
      );
      addTearDown(api.close);
      await openEditor(tester, api);
      await tester.enterText(find.byType(TextFormField).first, 'Несохранённый');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Продолжить редактирование'));
      await tester.pumpAndSettle();
      expect(find.text('Несохранённый'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Не сохранять'));
      await tester.pumpAndSettle();
      expect(find.text('Открыть'), findsOneWidget);
    },
  );
  testWidgets(
    'section editor supports repeated topic children without exposing JSON',
    (tester) async {
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((_) async => response({})),
      );
      addTearDown(api.close);
      await openEditor(tester, api);
      await reveal(tester, find.text('Блок по темам'));
      await tester.tap(find.text('Блок по темам'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).first,
        'Темы обсуждения',
      );
      await tester.enterText(
        find.byType(TextFormField).last,
        'Объедини повторные обсуждения',
      );
      await reveal(tester, find.text('Добавить подраздел'));
      await tester.tap(find.text('Добавить подраздел'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'Решения');
      await tester.enterText(
        find.byType(TextFormField).last,
        'Сохрани решения и сроки',
      );
      await tester.tap(find.byTooltip('Готово'));
      await tester.pumpAndSettle();
      expect(find.text('Решения'), findsOneWidget);
      await tester.tap(find.byTooltip('Готово'));
      await tester.pumpAndSettle();
      expect(find.text('Темы обсуждения'), findsOneWidget);
      expect(find.text('Для каждой темы · подразделов: 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'selector retains missing choice until user explicitly replaces it',
    (tester) async {
      String? selected = 'deleted';
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient(
          (r) async => r.url.path.endsWith('/deleted')
              ? response({
                  'error': {'code': 'not_found', 'message': 'Удалён'},
                }, 404)
              : response({
                  'items': [record(input(), system: true)],
                }),
        ),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TemplateSelector(
              api: api,
              value: 'deleted',
              onChanged: (v) => selected = v,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(selected, 'deleted');
      expect(
        find.textContaining('Выбранный шаблон недоступен'),
        findsOneWidget,
      );
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('План'));
      await tester.pumpAndSettle();
      expect(selected, null);
    },
  );
  testWidgets(
    'preview blocks duplicate POST, polls its own ID and expiry preserves text',
    (tester) async {
      final accepted = Completer<http.Response>();
      var posts = 0, gets = 0;
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((r) async {
          expect(r.url.path, startsWith('/api/v1/template-previews'));
          if (r.method == 'POST') {
            posts++;
            expect(jsonDecode(r.body)['template'], input().toJson());
            return accepted.future;
          }
          gets++;
          return response({
            'error': {'code': 'not_found', 'message': 'Истёк'},
          }, 404);
        }),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: TemplatePreviewPage(api: api, input: input()),
        ),
      );
      await tester.enterText(
        find.byType(TextField),
        'Анна подготовит отчёт к пятнице.',
      );
      await tester.tap(find.text('Протестировать'));
      await tester.pump();
      await tester.tap(find.text('Протестировать'));
      await tester.pump();
      expect(posts, 1);
      accepted.complete(
        response({
          'id': 'preview',
          'status': 'queued',
          'content': null,
          'navigation': [],
          'error': null,
        }, 202),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(gets, 1);
      expect(find.textContaining('Тест больше недоступен'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Анна подготовит отчёт к пятнице.',
      );
      expect(posts, 1);
    },
  );
}

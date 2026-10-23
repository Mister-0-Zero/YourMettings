import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/models/summary_template.dart';

void main() {
  final section = TemplateSection(
    id: newSectionId(),
    title: 'Темы',
    instruction: 'Выдели темы',
    repeated: true,
    children: [
      TemplateSection(
        id: newSectionId(),
        title: 'Решения',
        instruction: 'Сохрани решения',
      ),
    ],
  );
  final input = TemplateInput(name: 'Мой шаблон', sections: [section]);
  final template = {
    ...input.toJson(),
    'id': 'tpl',
    'is_system': false,
    'is_default': false,
    'owner_user_id': 'owner',
    'created_at': '2026-10-23',
    'updated_at': '2026-10-23',
  };
  test('catalog CRUD/copy and preview use only contract endpoints and editable fields', () async {
    final calls = <http.Request>[];
    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      client: MockClient((r) async {
        calls.add(r);
        Object body = template;
        var code = 200;
        if (r.method == 'DELETE') return http.Response('', 204);
        if (r.url.path == '/api/v1/summary-templates' && r.method == 'GET') {
          body = {
            'items': [template],
          };
        }
        if (r.url.path.contains('template-previews')) {
          body = {
            'id': 'preview',
            'status': r.method == 'POST' ? 'queued' : 'ready',
            'content': r.method == 'POST' ? null : '## Решения',
            'navigation': [],
            'error': null,
          };
          if (r.method == 'POST') code = 202;
        } else if (r.method == 'POST') {
          code = 201;
        }
        return http.Response.bytes(utf8.encode(jsonEncode(body)), code);
      }),
    );
    addTearDown(api.close);
    expect((await api.templates()).single.input.name, input.name);
    final read = await api.template('tpl');
    await api.saveTemplate(read.input);
    await api.saveTemplate(read.input, id: 'tpl');
    await api.copyTemplate('tpl');
    await api.deleteTemplate('tpl');
    expect(
      (await api.startTemplatePreview(input, 'Тест', 'brief')).finished,
      false,
    );
    expect((await api.templatePreview('preview')).content, '## Решения');
    expect(calls.map((r) => r.method), [
      'GET',
      'GET',
      'POST',
      'PUT',
      'POST',
      'DELETE',
      'POST',
      'GET',
    ]);
    expect(jsonDecode(calls[2].body), input.toJson());
    expect(jsonDecode(calls[3].body).containsKey('is_system'), false);
    expect(jsonDecode(calls[6].body), {
      'template': input.toJson(),
      'text': 'Тест',
      'detail_level': 'brief',
    });
    expect(calls[6].headers.containsKey('Idempotency-Key'), false);
    expect(calls.where((r) => r.url.path.contains('transcripts')), isEmpty);
  });
  test(
    'section reorder preserves IDs and rewrites positions at both levels',
    () {
      final other = TemplateSection(
        id: newSectionId(),
        title: 'Итог',
        instruction: 'Подведи итог',
      );
      final changed = TemplateInput(
        name: input.name,
        sections: [other, section],
      );
      final j = changed.toJson();
      expect(changed.validate(), null);
      expect(j['sections'][1]['id'], section.id);
      expect(j['sections'][1]['position'], 1);
      expect(j['sections'][1]['children'][0]['position'], 0);
      expect(TemplateInput.fromJson(j).toJson(), j);
      expect(
        TemplateInput(name: 'Без разделов', sections: []).validate(),
        isNotNull,
      );
      expect(
        TemplateInput(
          name: 'Без детей',
          sections: [
            TemplateSection(
              id: newSectionId(),
              title: 'Темы',
              instruction: 'Темы',
              repeated: true,
            ),
          ],
        ).validate(),
        isNotNull,
      );
    },
  );
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/models/summary_template.dart';

// Uses only isolated synthetic templates and the non-persistent preview API.
Future<void> main() async {
  final base = Uri.parse('http://127.0.0.1:8000/api/v1/');
  final api = ApiClient(base);
  final created = <String>[];
  Future<int> total() async =>
      (jsonDecode((await http.get(base.resolve('summaries?limit=1'))).body)
              as Map<String, dynamic>)['total']
          as int;
  void require(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  final before = await total();
  try {
    final catalog = await api.templates();
    require(
      catalog.where((t) => t.isSystem).length == 7,
      'Seven system templates expected',
    );
    for (final item in catalog.where((t) => t.isSystem)) {
      await api.template(item.id);
    }
    final standard = catalog.singleWhere((t) => t.isDefault);
    final copy = await api.copyTemplate(standard.id);
    created.add(copy.id);
    require(!copy.isSystem && copy.id != standard.id, 'Copy must be editable');
    final source = TemplateInput(
      name: 'QA Flutter template 20261023',
      description: 'Synthetic QA; cleaned by this script.',
      sections: copy.input.sections.reversed.toList(),
    );
    final custom = await api.saveTemplate(source);
    created.add(custom.id);
    final update = TemplateInput(
      name: 'QA Flutter updated 20261023',
      structureMode: 'flexible',
      sections: source.sections,
    );
    final saved = await api.saveTemplate(update, id: custom.id);
    final reopened = await api.template(saved.id);
    require(
      jsonEncode(reopened.input.toJson()) == jsonEncode(update.toJson()),
      'Saved structure changed',
    );
    final unsaved = TemplateInput(
      name: 'Несохранённый тест',
      sections: standard.input.sections,
      generalInstructions: 'Сохрани названные сроки и ответственных.',
    );
    var preview = await api.startTemplatePreview(
      unsaved,
      'Анна: сегодня 23 октября обсуждаем выпуск API и проверку интерфейса. Решили выпустить API 3 ноября. Борис подготовит тест отката к 28 октября. По интерфейсу решили проверить навигацию. Анна проверит мобильное приложение к 29 октября. Итог: сроки согласованы, других решений нет.',
      'normal',
    );
    stdout.writeln('Preview accepted; CRUD and section order verified.');
    final timer = Stopwatch()..start();
    var phase = preview.status;
    while (!preview.finished && timer.elapsed < const Duration(minutes: 7)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      preview = await api.templatePreview(preview.id);
      if (preview.status != phase) {
        phase = preview.status;
        stdout.writeln('Preview: $phase');
      }
    }
    require(
      preview.status == 'ready',
      'Preview failed: ${preview.error ?? preview.status}',
    );
    require(
      preview.content?.isNotEmpty == true && preview.navigation.isNotEmpty,
      'Missing content/navigation',
    );
    final after = await total();
    require(before == after, 'Preview must not create meeting history');
    final directory = Directory('build/device-check')
      ..createSync(recursive: true);
    File('${directory.path}/template-live-preview.md')
        .writeAsStringSync(preview.content!);
    File('${directory.path}/template-live-preview.json').writeAsStringSync(
      jsonEncode({
        'status': preview.status,
        'navigation': [
          for (final h in preview.navigation)
            {
              'id': h.id,
              'title': h.title,
              'level': h.level,
              'heading_index': h.headingIndex,
              'line_index': h.lineIndex,
            },
        ],
        'history_before': before,
        'history_after': after,
        'seconds': timer.elapsed.inSeconds,
      }),
    );
    stdout.writeln(
      'PASS: seven templates, CRUD, copy, reorder, inline preview, unchanged history ($before).',
    );
  } finally {
    for (final id in created.reversed) {
      await api.deleteTemplate(id);
    }
    api.close();
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/models/processing_options.dart';

// Own non-confidential fixtures only. Never replay a key after intentional deletion.
Future<void> main(List<String> arguments) async {
  final value = arguments.isEmpty
      ? 'http://127.0.0.1:8000/api/v1/'
      : arguments.single;
  final api = ApiClient(Uri.parse(value.endsWith('/') ? value : '$value/'));
  final run = DateTime.now().microsecondsSinceEpoch;
  final metadata = <String, dynamic>{'run': run};
  final file = File('build/mobile-smoke-$run.json');
  Future<void> checkpoint() async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(metadata), flush: true);
  }

  void verify(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  Future<void> missing(Future<Object?> Function() read) async {
    try {
      await read();
      throw StateError('Expected 404');
    } on ApiException catch (e) {
      verify(e.statusCode == 404, 'Expected 404: $e');
    }
  }

  try {
    final root = await api.createFolder('Mobile check $run');
    metadata['root_id'] = root.id;
    await checkpoint();
    final child = await api.createFolder('Child', parentId: root.id);
    metadata['child_id'] = child.id;
    final outside = await api.createFolder('Mobile outside $run');
    metadata['outside_id'] = outside.id;
    await checkpoint();
    const text =
        'Иван: Выпускаем тестовую версию в пятницу. Мария: Я проверю Android до четверга. Иван: Согласовано. Риск: недостаточно времени на проверку.';
    const title = 'Проверка Flutter v2';
    const options = ProcessingOptions(
      detailLevel: 'detailed',
      focusAreas: ['tasks', 'owners', 'deadlines', 'risks'],
      additionalInstructions: 'Выдели задачи отдельными блоками.',
    );
    final key = 'mobile-v2-$run';
    var status = await api.submitTranscript(
      text: text,
      title: title,
      folderIds: [child.id],
      idempotencyKey: key,
      options: options,
    );
    metadata['transcript_id'] = status.transcriptId;
    metadata['key'] = key;
    await checkpoint();
    final replay = await api.submitTranscript(
      text: text,
      title: title,
      folderIds: [child.id],
      idempotencyKey: key,
      options: options,
    );
    verify(replay.transcriptId == status.transcriptId, 'Replay changed ID');
    try {
      await api.submitTranscript(
        text: text,
        title: title,
        folderIds: [child.id],
        idempotencyKey: key,
        options: const ProcessingOptions(detailLevel: 'brief'),
      );
      throw StateError('Changed payload accepted');
    } on ApiException catch (e) {
      verify(e.statusCode == 409, 'Expected idempotency 409');
    }
    if (status.phase == ProcessingPhase.summarizing) {
      try {
        await api.deleteFolder(root.id);
        throw StateError('Active folder deleted');
      } on ApiException catch (e) {
        verify(
          e.statusCode == 409 && e.code == 'folder_processing',
          'Expected folder_processing',
        );
      }
      stdout.writeln('PASS active-generation folder 409');
    }
    final deadline = DateTime.now().add(const Duration(minutes: 4));
    while (status.phase == ProcessingPhase.summarizing &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      status = await api.processing(status.transcriptId);
    }
    verify(
      status.phase == ProcessingPhase.ready,
      'Generation failed: ${status.errorMessage}',
    );
    final summary = await api.summary(status.summaryId!);
    metadata['summary_id'] = summary.id;
    await checkpoint();
    verify(summary.content.trim().isNotEmpty, 'Empty summary');
    final source = await api.transcript(status.transcriptId);
    verify(source.text == text, 'Source mismatch');
    final content =
        '## Решения\nТестовый выпуск.\n\n### Задача 1\n**Ответственный:** Мария\n\n**Срок:** четверг\n\n- Проверить Android\n\n1. Подготовить отчёт\n\n| Поле | Значение |\n|---|---|\n| Статус | Проверено |';
    await api.saveSummary(summary.id, title: title, content: content);
    verify(
      (await api.summary(summary.id)).content == content,
      'PATCH readback failed',
    );
    await api.setSummaryFolders(summary.id, [child.id, outside.id]);
    await api.deleteFolder(root.id);
    metadata['root_deleted'] = true;
    await checkpoint();
    verify(
      (await api.summary(summary.id)).folderIds.length == 1,
      'Shared summary not preserved',
    );
    verify(
      (await api.summaries(outside.id)).items.any((s) => s.id == summary.id),
      'Outside link missing',
    );
    verify(
      !flattenFolders(await api.folders())
          .any((f) => f.folder.id == root.id || f.folder.id == child.id),
      'Tree retained',
    );
    await api.deleteSummary(summary.id);
    metadata['summary_deleted'] = true;
    await checkpoint();
    await missing(() => api.summary(summary.id));
    await missing(() => api.transcript(source.id));
    await missing(() => api.processing(source.id));
    await api.deleteFolder(outside.id);
    metadata['outside_deleted'] = true;
    metadata['passed'] = true;
    await checkpoint();
    stdout.writeln(
      'PASS Qwen options, stable replay, changed-payload 409, polling, Markdown PATCH, shared links, folder tree deletion, summary/transcript cleanup.',
    );
  } catch (e) {
    stderr.writeln('FAIL $e; own fixture metadata: ${file.path}');
    exitCode = 1;
  } finally {
    api.close();
  }
}

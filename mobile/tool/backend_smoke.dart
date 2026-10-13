import 'dart:convert';
import 'dart:io';

import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/models/api_models.dart';

// Explicit real-backend check: creates/reuses two test folders and one transcript.
// Deletes its own summary after verification; the API retains folders/transcript.
Future<void> main(List<String> arguments) async {
  final baseValue = arguments.isEmpty
      ? 'http://127.0.0.1:8000/api/v1/'
      : arguments.single;
  final base = Uri.parse(baseValue.endsWith('/') ? baseValue : '$baseValue/');
  final api = ApiClient(base);
  final metadataFile = File('build/mobile-smoke.json');
  await metadataFile.parent.create(recursive: true);
  Map<String, dynamic> metadata = {};
  if (await metadataFile.exists()) {
    metadata =
        jsonDecode(await metadataFile.readAsString()) as Map<String, dynamic>;
    if (metadata['base_url'] != base.toString()) metadata = {};
  }
  void verify(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  try {
    var folders = flattenFolders(await api.folders());
    var root = folders
        .where(
          (e) => e.folder.parentId == null && e.folder.name == 'Mobile smoke',
        )
        .firstOrNull
        ?.folder;
    root ??= await api.createFolder('Mobile smoke');
    folders = flattenFolders(await api.folders());
    var child = folders
        .where(
          (e) =>
              e.folder.parentId == root!.id &&
              e.folder.name == 'Mobile smoke child',
        )
        .firstOrNull
        ?.folder;
    child ??= await api.createFolder('Mobile smoke child', parentId: root.id);
    final renamed = await api.renameFolder(
      child.id,
      'Mobile smoke child checked',
    );
    verify(
      renamed.name == 'Mobile smoke child checked',
      'Folder rename failed',
    );
    await api.renameFolder(child.id, 'Mobile smoke child');
    const text =
        'Иван: Выпускаем тестовую версию в пятницу. Мария: Я проверю Android-приложение до четверга. Иван: Согласовано.';
    const title = 'Проверка Flutter API';
    final key =
        metadata['key'] as String? ??
        'mobile-smoke-${DateTime.now().microsecondsSinceEpoch}';
    metadata = {'base_url': base.toString(), 'key': key, 'folder_id': root.id};
    await metadataFile.writeAsString(jsonEncode(metadata), flush: true);
    var status = await api.submitTranscript(
      text: text,
      title: title,
      folderIds: [root.id],
      idempotencyKey: key,
    );
    metadata['transcript_id'] = status.transcriptId;
    await metadataFile.writeAsString(jsonEncode(metadata), flush: true);
    stdout.writeln(
      'Accepted transcript ${status.transcriptId}; status=${status.phase.name}',
    );
    if (status.phase == ProcessingPhase.notStarted ||
        status.phase == ProcessingPhase.error) {
      status = await api.retryProcessing(status.transcriptId, title, [root.id]);
    }
    final deadline = DateTime.now().add(const Duration(minutes: 4));
    var interval = 2;
    while (status.phase == ProcessingPhase.summarizing &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(Duration(seconds: interval));
      interval = interval < 10 ? interval + 2 : 10;
      status = await api.processing(status.transcriptId);
    }
    verify(
      status.phase == ProcessingPhase.ready,
      'Generation not ready: ${status.errorCode} ${status.errorMessage}',
    );
    final generated = await api.summary(status.summaryId!);
    verify(generated.content.trim().isNotEmpty, 'Empty summary');
    verify(
      generated.title == title && generated.folderIds.contains(root.id),
      'Summary metadata mismatch',
    );
    stdout.writeln('Real generation ready; summary ${generated.id}');
    final replay = await api.submitTranscript(
      text: text,
      title: title,
      folderIds: [root.id],
      idempotencyKey: key,
    );
    verify(
      replay.transcriptId == status.transcriptId &&
          replay.summaryId == generated.id,
      'Idempotent replay changed IDs',
    );
    final source = await api.transcript(status.transcriptId);
    verify(
      source.text == text && source.isLocked,
      'Original transcript missing/unlocked',
    );
    final listed = await api.summaries(root.id);
    verify(
      listed.items.any((item) => item.id == generated.id),
      'Summary absent from folder',
    );
    final editedContent =
        '${generated.content}\n\nПроверка мобильного клиента.';
    await api.saveSummary(
      generated.id,
      title: 'Flutter API проверен',
      content: editedContent,
    );
    final edited = await api.summary(generated.id);
    verify(
      edited.title == 'Flutter API проверен' && edited.content == editedContent,
      'Summary edit/readback failed',
    );
    final linked = await api.setSummaryFolders(generated.id, [
      root.id,
      child.id,
    ]);
    verify(
      linked.folderIds.toSet().containsAll([root.id, child.id]),
      'Folder links failed',
    );
    verify(
      (await api.summaries(child.id)).items
          .any((item) => item.id == generated.id),
      'Child folder listing failed',
    );
    await api.deleteSummary(generated.id);
    verify(
      (await api.transcript(source.id)).isLocked,
      'Deletion lost original transcript',
    );
    verify(
      (await api.processing(source.id)).phase == ProcessingPhase.notStarted,
      'Post-delete state mismatch',
    );
    metadata['verified_at'] = DateTime.now().toUtc().toIso8601String();
    metadata['summary_deleted'] = true;
    await metadataFile.writeAsString(jsonEncode(metadata), flush: true);
    stdout.writeln(
      'PASS: real generation, idempotency, folders, transcript, edit, links, deletion.',
    );
    stdout.writeln(
      'Test folders and locked transcript remain according to API contract.',
    );
  } catch (error) {
    stderr.writeln('FAIL: $error');
    stderr.writeln(
      'Operation metadata retained in build/mobile-smoke.json for safe retry.',
    );
    exitCode = 1;
  } finally {
    api.close();
  }
}

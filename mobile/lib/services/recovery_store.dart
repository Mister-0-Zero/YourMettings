import '../models/processing_options.dart';

import 'dart:convert';
import 'dart:io';

import '../models/api_models.dart';

class Draft {
  Draft({
    this.text = '',
    this.title = '',
    this.folderIds = const [],
    this.options = const ProcessingOptions(),
  });
  final String text;
  final String title;
  final List<String> folderIds;
  final ProcessingOptions options;
  Json toJson() => {
    'text': text,
    'title': title,
    'folder_ids': folderIds,
    'options': options.toJson(),
  };
  factory Draft.fromJson(Json json) => Draft(
    text: json['text'] as String,
    title: json['title'] as String,
    folderIds: (json['folder_ids'] as List).cast<String>(),
    options: ProcessingOptions.fromJson((json['options'] as Json?) ?? {}),
  );
}

class PendingRequest {
  PendingRequest(this.key, this.draft);
  final String key;
  final Draft draft;
  Json toJson() => {'key': key, 'draft': draft.toJson()};
  factory PendingRequest.fromJson(Json json) => PendingRequest(
    json['key'] as String,
    Draft.fromJson(json['draft'] as Json),
  );
}

class AcceptedOperation {
  AcceptedOperation(
    this.id,
    this.title,
    this.folderIds, [
    this.options = const ProcessingOptions(),
  ]);
  final String id;
  final String title;
  final List<String> folderIds;
  final ProcessingOptions options;
  Json toJson() => {
    'id': id,
    'title': title,
    'folder_ids': folderIds,
    'options': options.toJson(),
  };
  factory AcceptedOperation.fromJson(Json json) => AcceptedOperation(
    json['id'] as String,
    json['title'] as String,
    (json['folder_ids'] as List).cast<String>(),
    ProcessingOptions.fromJson((json['options'] as Json?) ?? {}),
  );
}

class RecoveryState {
  RecoveryState({Draft? draft, this.pending, this.operation})
    : draft = draft ?? Draft();
  final Draft draft;
  final PendingRequest? pending;
  final AcceptedOperation? operation;
  Json toJson() => {
    'version': 1,
    'draft': draft.toJson(),
    'pending': pending?.toJson(),
    'operation': operation?.toJson(),
  };
  factory RecoveryState.fromJson(Json json) {
    if (json['version'] != 1) {
      throw const FormatException('Неизвестный формат черновика.');
    }
    return RecoveryState(
      draft: Draft.fromJson(json['draft'] as Json),
      pending: json['pending'] == null
          ? null
          : PendingRequest.fromJson(json['pending'] as Json),
      operation: json['operation'] == null
          ? null
          : AcceptedOperation.fromJson(json['operation'] as Json),
    );
  }
}

abstract class RecoveryStore {
  Future<RecoveryState> load();
  Future<void> save(RecoveryState state);
}

class FileRecoveryStore implements RecoveryStore {
  FileRecoveryStore(this.file);
  final File file;
  Future<void> _queue = Future.value();
  @override
  Future<RecoveryState> load() async {
    if (!await file.exists()) return RecoveryState();
    return RecoveryState.fromJson(
      jsonDecode(await file.readAsString()) as Json,
    );
  }

  @override
  Future<void> save(RecoveryState state) {
    // Capture now: later UI mutations must not affect this queued snapshot.
    final content = jsonEncode(state.toJson());
    final task = _queue.then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(content, flush: true);
      await temporary.rename(file.path);
    });
    _queue = task.catchError((Object _) {});
    return task;
  }
}

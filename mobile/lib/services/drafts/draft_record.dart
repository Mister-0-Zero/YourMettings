import 'dart:convert';

import '../../models/api_models.dart';
import '../../models/summary_template.dart' show newSectionId;

Json copyJson(Json value) => jsonDecode(jsonEncode(value)) as Json;
final localDraftIdPattern = RegExp(
  r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
);
final draftScopePattern = RegExp(r'^[a-f0-9]{64}$');

enum LocalDraftKind { text, audio }

/// Editable input is never used to reconstruct an already submitted request.
class LocalDraftInput {
  LocalDraftInput({
    this.title = '',
    this.text = '',
    List<String> folderIds = const [],
    Json options = const {},
    this.processingMode = 'review',
  }) : folderIds = List.unmodifiable(folderIds),
       _options = jsonEncode(options) {
    if (!['review', 'automatic'].contains(processingMode)) {
      throw const FormatException('Draft processing mode');
    }
  }
  final String title, text, processingMode;
  final List<String> folderIds;
  final String _options;
  Json get options => jsonDecode(_options) as Json;
  Json toJson() => {
    'title': title,
    'text': text,
    'folder_ids': folderIds,
    'options': options,
    'processing_mode': processingMode,
  };
  factory LocalDraftInput.fromJson(Json j) => LocalDraftInput(
    title: j['title'] as String,
    text: j['text'] as String,
    folderIds: (j['folder_ids'] as List).cast<String>(),
    options: j['options'] as Json,
    processingMode: j['processing_mode'] as String,
  );
}

/// The serialized body/key are durable immutable intent, not editable settings.
/// No headers or credentials are stored here.
class FrozenDraftRequest {
  FrozenDraftRequest({
    required this.method,
    required this.path,
    required this.key,
    required Json body,
  }) : encodedBody = jsonEncode(body) {
    _validate();
  }
  FrozenDraftRequest._(this.method, this.path, this.key, this.encodedBody) {
    _validate();
  }
  final String method, path, key, encodedBody;
  Json get body => jsonDecode(encodedBody) as Json;
  void _validate() {
    if (!['POST', 'PUT', 'PATCH', 'DELETE'].contains(method) ||
        key.isEmpty ||
        key.length > 256 ||
        path.isEmpty ||
        path.startsWith('/') ||
        path.contains(':') ||
        path.contains('?') ||
        path.contains('#') ||
        path.contains('\\') ||
        path.split('/').any((p) => p.isEmpty || p == '.' || p == '..')) {
      throw const FormatException('Frozen request identity');
    }
    body; // Verify an object body without normalizing its persisted representation.
  }

  Json toJson() => {
    'method': method,
    'path': path,
    'key': key,
    'encoded_body': encodedBody,
  };
  factory FrozenDraftRequest.fromJson(Json j) => FrozenDraftRequest._(
    j['method'] as String,
    j['path'] as String,
    j['key'] as String,
    j['encoded_body'] as String,
  );
}

class LocalDraftRecord {
  LocalDraftRecord._(Json json) : _encoded = jsonEncode(json) {
    final j = toJson();
    if (j['schema'] != 1 ||
        !localDraftIdPattern.hasMatch(j['local_id'] as String) ||
        !draftScopePattern.hasMatch(j['scope_id'] as String) ||
        (j['revision'] as int) < 1 ||
        (j['state'] as String).isEmpty ||
        j['auto_start_when_online'] is! bool) {
      throw const FormatException('Draft manifest identity/version');
    }
    LocalDraftKind.values.byName(j['kind'] as String);
    DateTime.parse(j['created_at'] as String);
    DateTime.parse(j['updated_at'] as String);
    LocalDraftInput.fromJson(j['input'] as Json);
    for (final value in (j['requests'] as Json).values) {
      FrozenDraftRequest.fromJson(value as Json);
    }
    for (final entry in (j['server_ids'] as Json).entries) {
      if (![
            'audio_session_id',
            'transcript_id',
            'summary_id',
            'selection_id',
          ].contains(entry.key) ||
          entry.value is! String ||
          (entry.value as String).isEmpty) {
        throw const FormatException('Server reference');
      }
    }
    if (j['checkpoints'] is! Json || j['receipts'] is! Json) {
      throw const FormatException('Draft checkpoint');
    }
  }
  factory LocalDraftRecord.create({
    required String scopeId,
    required LocalDraftKind kind,
    LocalDraftInput? input,
    String? localId,
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now()).toUtc().toIso8601String();
    return LocalDraftRecord._({
      'schema': 1,
      'local_id': localId ?? newSectionId(),
      'scope_id': scopeId,
      'kind': kind.name,
      'revision': 1,
      'created_at': timestamp,
      'updated_at': timestamp,
      'state': 'draft',
      'auto_start_when_online': false,
      'input': (input ?? LocalDraftInput()).toJson(),
      'requests': <String, dynamic>{},
      'server_ids': <String, dynamic>{},
      'checkpoints': <String, dynamic>{},
      'receipts': <String, dynamic>{},
    });
  }
  factory LocalDraftRecord.fromJson(Json value) => LocalDraftRecord._(value);
  final String _encoded;
  Json toJson() => jsonDecode(_encoded) as Json;
  String get localId => toJson()['local_id'] as String;
  String get scopeId => toJson()['scope_id'] as String;
  LocalDraftKind get kind =>
      LocalDraftKind.values.byName(toJson()['kind'] as String);
  int get revision => toJson()['revision'] as int;
  bool get autoStart => toJson()['auto_start_when_online'] as bool;
  LocalDraftInput get input =>
      LocalDraftInput.fromJson(toJson()['input'] as Json);
  Map<String, FrozenDraftRequest> get requests =>
      (toJson()['requests'] as Json).map(
        (key, value) =>
            MapEntry(key, FrozenDraftRequest.fromJson(value as Json)),
      );
  Json get serverIds => toJson()['server_ids'] as Json;
}

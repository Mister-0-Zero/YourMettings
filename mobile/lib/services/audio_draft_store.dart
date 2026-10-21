import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/api_models.dart';
import 'recovery_store.dart';

/// Only deferred review text/operation IDs; no copied audio or meeting library.
class SavedAudioDraft {
  SavedAudioDraft({
    required this.sessionId,
    required this.transcriptId,
    required this.creationKey,
    required this.recovery,
    required this.updatedAt,
    this.boundariesReviewed = false,
    this.hasBoundaryWarnings = false,
    this.handoff = false,
    this.deletePending = false,
    this.serverDeleted = false,
  });
  final String sessionId, transcriptId, creationKey;
  final RecoveryState recovery;
  final DateTime updatedAt;
  final bool boundariesReviewed,
      hasBoundaryWarnings,
      handoff,
      deletePending,
      serverDeleted;
  String get title => recovery.operation?.title ?? recovery.draft.title;
  Json toJson() => {
    'session_id': sessionId,
    'transcript_id': transcriptId,
    'creation_key': creationKey,
    'recovery': recovery.toJson(),
    'updated_at': updatedAt.toIso8601String(),
    'boundaries_reviewed': boundariesReviewed,
    'has_boundary_warnings': hasBoundaryWarnings,
    'handoff': handoff,
    'delete_pending': deletePending,
    'server_deleted': serverDeleted,
  };
  factory SavedAudioDraft.fromJson(Json j) => SavedAudioDraft(
    sessionId: j['session_id'] as String,
    transcriptId: j['transcript_id'] as String,
    creationKey: j['creation_key'] as String,
    recovery: RecoveryState.fromJson(j['recovery'] as Json),
    updatedAt: DateTime.parse(j['updated_at'] as String),
    boundariesReviewed: j['boundaries_reviewed'] == true,
    hasBoundaryWarnings: j['has_boundary_warnings'] == true,
    handoff: j['handoff'] == true,
    deletePending: j['delete_pending'] == true,
    serverDeleted: j['server_deleted'] == true,
  );
  SavedAudioDraft copy({
    RecoveryState? recovery,
    bool? handoff,
    bool? deletePending,
    bool? serverDeleted,
    bool? boundariesReviewed,
  }) => SavedAudioDraft(
    sessionId: sessionId,
    transcriptId: transcriptId,
    creationKey: creationKey,
    recovery: recovery ?? this.recovery,
    updatedAt: DateTime.now().toUtc(),
    boundariesReviewed: boundariesReviewed ?? this.boundariesReviewed,
    hasBoundaryWarnings: hasBoundaryWarnings,
    handoff: handoff ?? this.handoff,
    deletePending: deletePending ?? this.deletePending,
    serverDeleted: serverDeleted ?? this.serverDeleted,
  );
}

class AudioDraftRepository extends ChangeNotifier {
  AudioDraftRepository({this.file});
  final File? file;
  Map<String, SavedAudioDraft> _items = {};
  Future<void> _queue = Future.value();
  bool _disposed = false;
  List<SavedAudioDraft> get items =>
      _items.values.toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  SavedAudioDraft? operator [](String id) => _items[id];
  bool get hasHandoff => _items.values.any((entry) => entry.handoff);
  Future<void> load() async {
    if (file == null || !await file!.exists()) return;
    final j = jsonDecode(await file!.readAsString()) as Json;
    if (j['version'] != 1) {
      throw const FormatException('Unknown deferred drafts version');
    }
    final values = (j['items'] as List).cast<Json>().map(
      SavedAudioDraft.fromJson,
    );
    _items = {for (final entry in values) entry.sessionId: entry};
    if (!_disposed) notifyListeners();
  }

  /// Stage mutations in a serialized queue; publish only after durable storage.
  Future<void> _change(void Function(Map<String, SavedAudioDraft>) action) {
    final next = _queue.then((_) async {
      final staged = Map<String, SavedAudioDraft>.from(_items);
      action(staged);
      await persist({
        'version': 1,
        'items': staged.values.map((e) => e.toJson()).toList(),
      });
      _items = staged;
      if (!_disposed) notifyListeners();
    });
    _queue = next.catchError((Object _) {});
    return next;
  }

  @visibleForTesting
  Future<void> persist(Json value) async {
    if (file == null) return;
    await file!.parent.create(recursive: true);
    final temporary = File('${file!.path}.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename(file!.path);
  }

  Future<void> put(SavedAudioDraft entry) {
    final snapshot = SavedAudioDraft.fromJson(
      jsonDecode(jsonEncode(entry.toJson())) as Json,
    );
    return _change((items) => items[snapshot.sessionId] = snapshot);
  }

  Future<void> update(
    String id,
    SavedAudioDraft Function(SavedAudioDraft) action,
  ) => _change((items) {
    final entry = items[id];
    if (entry == null) throw StateError('Deferred draft missing');
    items[id] = action(entry);
  });
  Future<void> remove(String id) => _change((items) => items.remove(id));
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class DeferredAudioRecoveryStore implements RecoveryStore {
  DeferredAudioRecoveryStore(this.repository, this.id);
  final AudioDraftRepository repository;
  final String id;
  @override
  Future<RecoveryState> load() async =>
      repository[id]?.recovery ?? (throw StateError('Deferred draft missing'));
  @override
  Future<void> save(RecoveryState state) {
    final snapshot = RecoveryState.fromJson(
      jsonDecode(jsonEncode(state.toJson())) as Json,
    );
    return repository.update(id, (entry) => entry.copy(recovery: snapshot));
  }
}

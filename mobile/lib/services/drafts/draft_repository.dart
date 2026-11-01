import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:queue_owner/queue_owner.dart';

import '../../models/api_models.dart';
import 'draft_record.dart';

class DraftRevisionConflict implements Exception {
  const DraftRevisionConflict();
}

class DraftLoadIssue {
  const DraftLoadIssue(this.localId, this.code);
  final String localId, code;
}

class DraftListing {
  const DraftListing(this.items, this.issues);
  final List<LocalDraftRecord> items;
  final List<DraftLoadIssue> issues;
}

/// One authority covers the whole scope across UI/capture/headless engines.
/// The per-draft manifest is authoritative; no second writable contents index.
class LocalDraftRepository {
  LocalDraftRepository({
    required this.scopeDirectory,
    required this.authority,
  }) {
    if (!draftScopePattern.hasMatch(authority.scopeId) ||
        scopeDirectory.uri.pathSegments.where((s) => s.isNotEmpty).last !=
            authority.scopeId) {
      throw ArgumentError('Repository scope differs from owner');
    }
  }
  final Directory scopeDirectory;
  final QueueWriteAuthority authority;
  Directory get directory => Directory('${scopeDirectory.path}/drafts');
  Directory draftDirectory(String id) {
    if (!localDraftIdPattern.hasMatch(id)) {
      throw ArgumentError('Invalid local draft ID');
    }
    return Directory('${directory.path}/$id');
  }

  File _deletion(String id) {
    draftDirectory(id); // Validate before constructing a cleanup path.
    return File('${scopeDirectory.path}/draft-deletions/$id.json');
  }

  File _manifest(String id) => File('${draftDirectory(id).path}/draft.json');
  Future<void> _checkPath(String id) async {
    for (final dir in [scopeDirectory, directory, draftDirectory(id)]) {
      if (await FileSystemEntity.isLink(dir.path)) {
        throw const FileSystemException('Draft path is a link');
      }
    }
  }

  Future<LocalDraftRecord> read(String id) async {
    await _checkPath(id);
    final value = LocalDraftRecord.fromJson(
      jsonDecode(await _manifest(id).readAsString()) as Json,
    );
    if (value.localId != id || value.scopeId != authority.scopeId) {
      throw const FormatException('Draft scope mismatch');
    }
    return value;
  }

  Future<DraftListing> list() async {
    if (!await directory.exists()) return const DraftListing([], []);
    if (await FileSystemEntity.isLink(scopeDirectory.path) ||
        await FileSystemEntity.isLink(directory.path)) {
      throw const FileSystemException('Draft path is a link');
    }
    final records = <LocalDraftRecord>[], issues = <DraftLoadIssue>[];
    await for (final entry in directory.list(followLinks: false)) {
      final id = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!localDraftIdPattern.hasMatch(id)) {
        issues.add(const DraftLoadIssue('', 'unknown_draft_directory'));
        continue;
      }
      try {
        if (await _deletion(id).exists()) {
          issues.add(DraftLoadIssue(id, 'deletion_pending'));
          continue;
        }
        records.add(await read(id));
        if (await draftDirectory(id)
            .list(followLinks: false)
            .any(
              (entry) =>
                  entry.uri.pathSegments.last.startsWith('draft.json.') &&
                  entry.uri.pathSegments.last.endsWith('.tmp'),
            )) {
          issues.add(DraftLoadIssue(id, 'uncommitted_snapshot'));
        }
      } catch (_) {
        issues.add(DraftLoadIssue(id, 'manifest_unreadable'));
      }
    }
    records.sort(
      (a, b) => (b.toJson()['updated_at'] as String).compareTo(
        a.toJson()['updated_at'] as String,
      ),
    );
    return DraftListing(List.unmodifiable(records), List.unmodifiable(issues));
  }

  @visibleForTesting
  Future<void> writeSnapshot(File file, Json json) =>
      authority.writeSnapshot(file, jsonEncode(json));
  Future<LocalDraftRecord> create(LocalDraftRecord record) =>
      authority.serialized(() async {
        if (record.scopeId != authority.scopeId) {
          throw const FormatException('Draft scope mismatch');
        }
        await _checkPath(record.localId);
        if (await _deletion(record.localId).exists()) {
          throw StateError('Draft deletion is pending');
        }
        if (await draftDirectory(record.localId).exists()) {
          throw const FileSystemException(
            'Draft already exists or needs recovery',
          );
        }
        await writeSnapshot(_manifest(record.localId), record.toJson());
        return record;
      });
  Future<LocalDraftRecord> update(
    String id, {
    required int expectedRevision,
    required void Function(Json next) change,
  }) => authority.serialized(() async {
    if (await _deletion(id).exists()) {
      throw StateError('Draft deletion is pending');
    }
    final current = await read(id);
    if (current.revision != expectedRevision) {
      throw const DraftRevisionConflict();
    }
    final old = current.toJson(), next = current.toJson();
    change(next);
    for (final field in [
      'schema',
      'local_id',
      'scope_id',
      'kind',
      'created_at',
      'revision',
    ]) {
      if (next[field] != old[field]) {
        throw StateError('Immutable draft identity changed');
      }
    }
    // ACK loss must never turn a pending request into a fresh key/body. New
    // explicit attempts get a different slot; old intents/receipts remain.
    for (final field in ['requests', 'receipts']) {
      final original = old[field] as Json, updated = next[field] as Json;
      for (final key in original.keys) {
        if (jsonEncode(original[key]) != jsonEncode(updated[key])) {
          throw StateError('Frozen intent/receipt changed');
        }
      }
    }
    for (final key in (old['server_ids'] as Json).keys) {
      if ((next['server_ids'] as Json)[key] !=
          (old['server_ids'] as Json)[key]) {
        throw StateError('Bound server identity changed');
      }
    }
    final frozenPlan = (old['checkpoints'] as Json)['wire_plan'];
    if (frozenPlan != null &&
        jsonEncode(frozenPlan) !=
            jsonEncode((next['checkpoints'] as Json)['wire_plan'])) {
      throw StateError('Frozen audio wire plan changed');
    }
    next['revision'] = current.revision + 1;
    next['updated_at'] = DateTime.now().toUtc().toIso8601String();
    final record = LocalDraftRecord.fromJson(next);
    await writeSnapshot(_manifest(id), record.toJson());
    return record;
  });
  Future<LocalDraftRecord> freezeRequest(
    String id,
    int revision,
    String slot,
    FrozenDraftRequest request,
  ) => update(
    id,
    expectedRevision: revision,
    change: (json) => (json['requests'] as Json)[slot] = request.toJson(),
  );

  /// Only the queue owner may authorize final local cleanup after reconciling
  /// remote operations (or saving the resulting summary). Not a server DELETE.
  Future<void> deleteLocal(
    String id, {
    required int expectedRevision,
    required bool confirmed,
    required bool remoteOutcomeConfirmed,
  }) => authority.serialized(() async {
    if (!confirmed) {
      throw StateError('Deletion requires confirmation');
    }
    final current = await read(id);
    if (current.revision != expectedRevision) {
      throw const DraftRevisionConflict();
    }
    if ([
      'recording',
      'paused',
      'capturing',
    ].contains(current.toJson()['state'])) {
      throw StateError('Capture writer has not stopped');
    }
    if ((current.requests.isNotEmpty || current.serverIds.isNotEmpty) &&
        !remoteOutcomeConfirmed) {
      throw StateError('Remote operation is not reconciled');
    }
    // Outside the bytes directory: this proof survives a crash after draft.json
    // has been removed but before the final WAV can be deleted.
    final marker = _deletion(id);
    if (await FileSystemEntity.isLink(marker.parent.path)) {
      throw const FileSystemException('Deletion path is a link');
    }
    await writeSnapshot(marker, {
      'schema': 1,
      'confirmed': true,
      'local_id': id,
      'scope_id': authority.scopeId,
      'revision': current.revision,
      'remote_outcome_confirmed': remoteOutcomeConfirmed,
    });
    await deleteBytes(id);
    await authority.eraseFile(marker);
  });

  @visibleForTesting
  Future<void> deleteBytes(String id) async {
    await _checkPath(id);
    final target = draftDirectory(id);
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return;
    }
    if (type != FileSystemEntityType.directory) {
      throw const FileSystemException('Deletion target changed');
    }
    final parent = await directory.resolveSymbolicLinks();
    final resolved = await target.resolveSymbolicLinks();
    if (!resolved.startsWith('$parent${Platform.pathSeparator}') ||
        resolved.split(Platform.pathSeparator).last != id) {
      throw const FileSystemException('Deletion escaped draft directory');
    }
    await authority.eraseDraft(target);
  }

  Future<List<DraftLoadIssue>> recoverLocalDeletions() =>
      authority.serialized(() async {
        final markers = Directory('${scopeDirectory.path}/draft-deletions');
        if (await FileSystemEntity.isLink(markers.path)) {
          throw const FileSystemException('Deletion path is a link');
        }
        if (!await markers.exists()) {
          return [];
        }
        final issues = <DraftLoadIssue>[];
        await for (final file in markers.list(followLinks: false)) {
          final name = file.uri.pathSegments.last;
          final id = name.endsWith('.json')
              ? name.substring(0, name.length - 5)
              : '';
          try {
            if (!localDraftIdPattern.hasMatch(id) || file is! File) {
              throw const FormatException('Deletion marker filename');
            }
            final marker = jsonDecode(await file.readAsString()) as Json;
            if (marker['schema'] != 1 ||
                marker['confirmed'] != true ||
                marker['scope_id'] != authority.scopeId ||
                marker['local_id'] != id ||
                (marker['revision'] as int) < 1 ||
                marker['remote_outcome_confirmed'] is! bool) {
              throw const FormatException('Deletion marker identity');
            }
            if (await _manifest(id).exists()) {
              final current = await read(id);
              if (current.revision != marker['revision']) {
                throw const DraftRevisionConflict();
              }
            }
            await deleteBytes(id);
            await authority.eraseFile(file);
          } catch (_) {
            issues.add(DraftLoadIssue(id, 'deletion_recovery_failed'));
          }
        }
        return issues;
      });
}

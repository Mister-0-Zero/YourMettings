import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../models/api_models.dart';
import '../recovery_store.dart';
import 'draft_record.dart';
import 'draft_repository.dart';

class LegacySourceChanged implements Exception {
  const LegacySourceChanged();
}

/// Read-only staging. Legacy sources are never removed or re-submitted here.
/// Production activation still needs a stopped legacy owner and crash-safe
/// pointer handoff; all imported records remain dispatch-blocked until then.
class LegacyDraftImporter {
  const LegacyDraftImporter(this.repository);
  final LocalDraftRepository repository;
  String _id(String source) {
    final hex = sha256
        .convert(
          utf8.encode('${repository.authority.scopeId}|legacy-v1|$source'),
        )
        .toString()
        .substring(0, 32);
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<File> _source(String name) async {
    final file = File('${repository.scopeDirectory.path}/$name');
    if (await FileSystemEntity.isLink(repository.scopeDirectory.path) ||
        await FileSystemEntity.isLink(file.path)) {
      throw const FileSystemException('Legacy source is a link');
    }
    return file;
  }

  Future<LocalDraftRecord?> stageTextRecovery() async {
    const name = 'meeting-recovery.json';
    final file = await _source(name);
    if (!await file.exists()) {
      return null;
    }
    final bytes = await file.readAsBytes();
    final digest = sha256.convert(bytes).toString();
    // Parse one captured snapshot; a changed second read is checked below.
    final raw = jsonDecode(utf8.decode(bytes)) as Json;
    final state = RecoveryState.fromJson(raw);
    if (state.draft.text.isEmpty &&
        state.pending == null &&
        state.operation == null) {
      return null;
    }
    final id = _id(name);
    final initial = LocalDraftRecord.create(
      scopeId: repository.authority.scopeId,
      kind: LocalDraftKind.text,
      localId: id,
      input: LocalDraftInput(
        title: state.draft.title,
        text: state.draft.text,
        folderIds: state.draft.folderIds,
        options: state.draft.options.toJson(),
      ),
    );
    final pending = state.pending;
    final request = pending == null
        ? null
        : FrozenDraftRequest(
            method: 'POST',
            path: 'transcripts/process',
            key: pending.key,
            body: {
              'text': pending.draft.text,
              'title': pending.draft.title,
              'folder_ids': pending.draft.folderIds,
              ...pending.draft.options.toJson(),
            },
          );
    final staged = LocalDraftRecord.fromJson({
      ...initial.toJson(),
      'state': 'migration_pending',
      'requests': {if (request != null) 'legacy-text-submit': request.toJson()},
      'server_ids': {
        if (state.operation != null) 'transcript_id': state.operation!.id,
      },
      'checkpoints': {
        'legacy': {
          'source': name,
          'sha256': digest,
          'recovery': raw,
          'owner': 'legacy-v1',
          'activation': 'blocked',
        },
      },
    });
    LocalDraftRecord result;
    if (await File('${repository.draftDirectory(id).path}/draft.json')
        .exists()) {
      result = await repository.read(id);
      final legacy =
          (result.toJson()['checkpoints'] as Json)['legacy'] as Json?;
      if (legacy?['sha256'] != digest) {
        throw const LegacySourceChanged();
      }
    } else {
      result = await repository.create(staged);
    }
    if (sha256.convert(await file.readAsBytes()).toString() != digest) {
      throw const LegacySourceChanged();
    }
    return result;
  }

  Future<void> stageOperationCheckpoints() async {
    const name = 'generation-operations.json';
    final source = await _source(name);
    if (!await source.exists()) {
      return;
    }
    final bytes = await source.readAsBytes();
    final digest = sha256.convert(bytes).toString();
    final payload = jsonDecode(utf8.decode(bytes)) as Json;
    if (payload['version'] != 1 || payload['items'] is! Json) {
      throw const FormatException('Legacy operations schema');
    }
    await repository.authority.serialized(() async {
      final folder = Directory(
        '${repository.scopeDirectory.path}/drafts-migration',
      );
      if (await FileSystemEntity.isLink(folder.path)) {
        throw const FileSystemException('Legacy archive path is a link');
      }
      final file = File('${folder.path}/legacy-operations.json');
      if (await file.exists()) {
        final old = jsonDecode(await file.readAsString()) as Json;
        if (old['scope_id'] != repository.authority.scopeId ||
            old['sha256'] != digest) {
          throw const LegacySourceChanged();
        }
        return;
      }
      await repository.authority.writeSnapshot(
        file,
        jsonEncode({
          'schema': 1,
          'scope_id': repository.authority.scopeId,
          'sha256': digest,
          'source': name,
          'dispatch': 'blocked',
          'payload': payload,
        }),
      );
    });
    if (sha256.convert(await source.readAsBytes()).toString() != digest) {
      throw const LegacySourceChanged();
    }
  }
}

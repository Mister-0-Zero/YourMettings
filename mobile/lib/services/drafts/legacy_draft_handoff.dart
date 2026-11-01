import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../models/api_models.dart';
import '../../models/processing_options.dart';
import '../recovery_store.dart';
import 'draft_record.dart';
import 'draft_repository.dart';
import 'legacy_draft_import.dart';

/// Invoked before legacy UI controllers are created. A live microphone service
/// prevents audio adoption. Pending operations stay owned by the legacy flow;
/// their frozen checkpoints are not converted into new queue submissions.
class LegacyDraftHandoff {
  LegacyDraftHandoff(this.repository);
  final LocalDraftRepository repository;
  File _file(String name) => File('${repository.scopeDirectory.path}/$name');
  String _id(String source) {
    final hex = sha256
        .convert(
          utf8.encode('${repository.authority.scopeId}|bridge-v1|$source'),
        )
        .toString()
        .substring(0, 32);
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<bool> _exists(String id) =>
      File('${repository.draftDirectory(id).path}/draft.json').exists();
  Future<void> _safe(File file) async {
    if (await FileSystemEntity.isLink(file.path) ||
        await FileSystemEntity.isLink(file.parent.path)) {
      throw const FileSystemException('Legacy source is a link');
    }
  }

  Future<List<String>> run({
    required bool textOwnerStopped,
    required bool audioOwnerStopped,
  }) async {
    final notices = <String>[];
    if (!textOwnerStopped) return ['legacy_owner_not_stopped'];
    final importer = LegacyDraftImporter(repository);
    // A deliberately retained legacy bridge can evolve under its old owner.
    // Do not replace its initial archive or present its snapshot as current text.
    try {
      await importer.stageOperationCheckpoints();
    } on LegacySourceChanged {
      notices.add('legacy_operations_remain_owned');
    }
    await _resumePreparedText();
    LocalDraftRecord? text;
    try {
      text = await importer.stageTextRecovery();
    } on LegacySourceChanged {
      notices.add('legacy_text_remains_owned');
    }
    if (text != null && text.toJson()['state'] == 'migration_pending') {
      final recovery = RecoveryState.fromJson(
        ((text.toJson()['checkpoints'] as Json)['legacy'] as Json)['recovery']
            as Json,
      );
      var selection = false;
      final operations = _file('generation-operations.json');
      if (await operations.exists()) {
        await _safe(operations);
        final raw = jsonDecode(await operations.readAsString()) as Json;
        selection = (raw['items'] as Json).containsKey('text-selection');
      }
      if (recovery.pending != null || recovery.operation != null || selection) {
        await repository.update(
          text.localId,
          expectedRevision: text.revision,
          change: (j) {
            j['state'] = 'legacy_bridge';
            ((j['checkpoints'] as Json)['legacy'] as Json)['activation'] =
                'legacy_route';
          },
        );
      } else {
        text = await repository.update(
          text.localId,
          expectedRevision: text.revision,
          change: (j) {
            j['state'] = 'migration_prepared';
            ((j['checkpoints'] as Json)['legacy'] as Json)['activation'] =
                'clear_source_then_activate';
          },
        );
        await _finishText(text);
      }
    }
    if (audioOwnerStopped) {
      await _bridgeAudio();
    } else {
      notices.add('legacy_audio_writer_live');
    }
    return notices;
  }

  Future<void> _resumePreparedText() async {
    for (final record in (await repository.list()).items) {
      if (record.toJson()['state'] == 'migration_prepared') {
        try {
          await _finishText(record);
        } on LegacySourceChanged {
          // A later legacy operation is authoritative. Never clear or resubmit
          // it from the older migration snapshot.
          await repository.update(
            record.localId,
            expectedRevision: record.revision,
            change: (j) {
              j['state'] = 'legacy_bridge';
              ((j['checkpoints'] as Json)['legacy'] as Json).addAll({
                'owner': 'legacy-v1',
                'activation': 'legacy_route',
              });
            },
          );
        }
      }
    }
  }

  Future<void> _finishText(LocalDraftRecord record) async {
    final legacy = (record.toJson()['checkpoints'] as Json)['legacy'] as Json;
    if (legacy['source'] != 'meeting-recovery.json' ||
        record.requests.isNotEmpty ||
        record.serverIds.isNotEmpty) {
      throw const FormatException('Unsafe legacy text activation');
    }
    final source = _file('meeting-recovery.json');
    await _safe(source);
    await repository.authority.serialized(() async {
      final raw = await source.readAsBytes();
      final state = RecoveryState.fromJson(
        jsonDecode(utf8.decode(raw)) as Json,
      );
      final alreadyCleared =
          jsonEncode(state.toJson()) == jsonEncode(RecoveryState().toJson());
      if (sha256.convert(raw).toString() != legacy['sha256'] &&
          !alreadyCleared) {
        throw const LegacySourceChanged();
      }
      if (!alreadyCleared) {
        await repository.authority.writeSnapshot(
          source,
          jsonEncode(RecoveryState().toJson()),
        );
      }
    });
    // Crash after clearing is recovered above from this already committed intent.
    await repository.update(
      record.localId,
      expectedRevision: record.revision,
      change: (j) {
        j['state'] = 'draft';
        final entry = (j['checkpoints'] as Json)['legacy'] as Json;
        entry['owner'] = 'local-draft';
        entry['activation'] = 'complete';
      },
    );
  }

  Future<void> _bridgeAudio() async {
    final source = _file('active-audio/session.json');
    if (!await source.exists()) return;
    await _safe(source);
    final raw = await source.readAsBytes();
    final journal = jsonDecode(utf8.decode(raw)) as Json;
    if (journal.isEmpty) return;
    if (journal['version'] != 1) {
      throw const FormatException('Legacy audio schema');
    }
    if (journal['phase'] == 'done' || journal.isEmpty) return;
    final identity = journal['id'] as String? ?? journal['key'] as String?;
    if (identity == null) throw const FormatException('Legacy audio identity');
    final id = _id('active-audio/$identity');
    if (await _exists(id)) return; // Original journal remains authoritative.
    final files = <Json>[];
    await for (final entity in source.parent.list(followLinks: false)) {
      if (entity is File &&
          RegExp(r'^\d+\.wav$').hasMatch(entity.uri.pathSegments.last)) {
        await _safe(entity);
        files.add({
          'name': entity.uri.pathSegments.last,
          'bytes': await entity.length(),
          'sha256': (await sha256.bind(entity.openRead()).first).toString(),
        });
      }
    }
    if (sha256.convert(await source.readAsBytes()).toString() !=
        sha256.convert(raw).toString()) {
      throw const LegacySourceChanged();
    }
    final parameters = journal['parameters'] as Json? ?? {};
    final initial = LocalDraftRecord.create(
      scopeId: repository.authority.scopeId,
      kind: LocalDraftKind.audio,
      localId: id,
      input: LocalDraftInput(
        title: parameters['title'] as String? ?? 'Прежняя запись',
        folderIds: (parameters['folder_ids'] as List? ?? []).cast<String>(),
        options: ProcessingOptions.fromJson(parameters).toJson(),
      ),
    );
    await repository.create(
      LocalDraftRecord.fromJson({
        ...initial.toJson(),
        'state': 'legacy_bridge',
        'requests': {
          if (journal['key'] is String)
            'legacy-audio-create': FrozenDraftRequest(
              method: 'POST',
              path: 'audio-sessions',
              key: journal['key'] as String,
              body: parameters,
            ).toJson(),
        },
        'server_ids': {
          if (journal['id'] is String) 'audio_session_id': journal['id'],
        },
        'checkpoints': {
          'legacy': {
            'source': 'active-audio/session.json',
            'owner': 'legacy-v1',
            'activation': 'legacy_route',
            'sha256': sha256.convert(raw).toString(),
            'journal': journal,
            'files': files,
            'source_preserved': true,
          },
        },
      }),
    );
    // No move/delete/resubmit: existing service/coordinator still owns its exact
    // journal, WAVs, server ID, ACKs and unknown create key. UI opens that flow.
  }
}

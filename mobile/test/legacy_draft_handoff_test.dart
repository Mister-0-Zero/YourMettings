import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/recovery_store.dart';

import 'support/draft_test_fixture.dart';

void main() {
  late DraftTestFixture fixture;
  setUp(() async {
    fixture = await DraftTestFixture.create();
  });
  tearDown(() async {
    await fixture.close();
  });
  File source() =>
      File('${fixture.workspace.directory.path}/meeting-recovery.json');
  Future<void> seed(RecoveryState value) async {
    await FileRecoveryStore(source()).save(value);
  }

  test('local-only legacy text activates after durable mapping/source clear and remains idempotent', () async {
    await seed(
      RecoveryState(
        draft: Draft(title: 'Old', text: 'Never lose', folderIds: ['nested']),
      ),
    );
    await fixture.workspace.initialize(
      legacyTextOwnerStopped: true,
      legacyAudioOwnerStopped: true,
    );
    final item = fixture.workspace.items.single;
    expect(item.toJson()['state'], 'draft');
    expect(item.input.text, 'Never lose');
    expect(item.input.folderIds, ['nested']);
    expect((await FileRecoveryStore(source()).load()).draft.text, isEmpty);
    expect(
      (item.toJson()['checkpoints']
          as Json)['legacy']['recovery']['draft']['text'],
      'Never lose',
    );
    await fixture.workspace.initialize(
      legacyTextOwnerStopped: true,
      legacyAudioOwnerStopped: true,
    );
    expect(fixture.workspace.items.single.localId, item.localId);
    expect(fixture.httpCalls, isEmpty);
  });
  test(
    'no stopped-owner proof means no staging, source clear or activation',
    () async {
      await seed(RecoveryState(draft: Draft(text: 'Live owner')));
      final before = await source().readAsBytes();
      await fixture.workspace.initialize();
      expect(fixture.workspace.items, isEmpty);
      expect(await source().readAsBytes(), before);
    },
  );
  test('crash after source clear but before activation restores the same local draft', () async {
    await seed(RecoveryState(draft: Draft(text: 'Crash-safe')));
    fixture.pool.rejectSnapshot = (file, encoded) =>
        file.uri.pathSegments.last == 'draft.json' &&
        (jsonDecode(encoded) as Json)['state'] == 'draft';
    await fixture.workspace.initialize(legacyTextOwnerStopped: true);
    final prepared = fixture.workspace.items.single;
    expect(prepared.toJson()['state'], 'migration_prepared');
    expect(fixture.workspace.legacyTextHandoffPending, isTrue);
    expect((await FileRecoveryStore(source()).load()).draft.text, isEmpty);
    fixture.pool.rejectSnapshot = null;
    await fixture.workspace.initialize(legacyTextOwnerStopped: true);
    expect(fixture.workspace.items.single.localId, prepared.localId);
    expect(fixture.workspace.items.single.input.text, 'Crash-safe');
    expect(fixture.workspace.items.single.toJson()['state'], 'draft');
  });
  test('crash before clearing retains old source; a later pending operation is never cleared/resubmitted', () async {
    await seed(RecoveryState(draft: Draft(text: 'Original')));
    fixture.pool.rejectSnapshot = (file, _) => file.path == source().path;
    await fixture.workspace.initialize(legacyTextOwnerStopped: true);
    expect((await FileRecoveryStore(source()).load()).draft.text, 'Original');
    final frozen = Draft(text: 'Later accepted request', title: 'Later');
    await seed(
      RecoveryState(
        draft: frozen,
        pending: PendingRequest('later-key', frozen),
      ),
    );
    fixture.pool.rejectSnapshot = null;
    await fixture.workspace.initialize(legacyTextOwnerStopped: true);
    expect(fixture.workspace.items.single.toJson()['state'], 'legacy_bridge');
    expect(
      (await FileRecoveryStore(source()).load()).pending!.key,
      'later-key',
    );
    expect(fixture.httpCalls, isEmpty);
  });
  test('pending request and accepted transcript remain owned by legacy flow with exact frozen state', () async {
    final draft = Draft(text: 'Editable', title: 'Title', folderIds: ['a']);
    final pending = Draft(text: 'Frozen', title: 'Before', folderIds: ['b']);
    await seed(
      RecoveryState(
        draft: draft,
        pending: PendingRequest('keep-key', pending),
        operation: AcceptedOperation('accepted-id', 'Before', ['b']),
      ),
    );
    final original = await source().readAsBytes();
    await fixture.workspace.initialize(legacyTextOwnerStopped: true);
    final entry = fixture.workspace.items.single;
    expect(entry.toJson()['state'], 'legacy_bridge');
    expect(entry.requests['legacy-text-submit']!.key, 'keep-key');
    expect(entry.requests['legacy-text-submit']!.body['text'], 'Frozen');
    expect(entry.input.text, 'Editable');
    expect(entry.serverIds['transcript_id'], 'accepted-id');
    expect(await source().readAsBytes(), original);
    expect(fixture.httpCalls, isEmpty);
  });
  test('selection and accept receipt are archived separately, still on original legacy owner', () async {
    await seed(RecoveryState(draft: Draft(text: 'Selection text')));
    final operations = File(
      '${fixture.workspace.directory.path}/generation-operations.json',
    );
    final raw = <String, dynamic>{
      'version': 1,
      'items': {
        'text-selection': {
          'key': 'old-create',
          'source': {'text': 'Frozen selection'},
          'session_id': 'selection-id',
          'accept_id': 'accept-key',
          'accepted_summary_id': 'saved-id',
          'receipt': {'summary_id': 'saved-id'},
        },
      },
    };
    await operations.writeAsString(jsonEncode(raw));
    final digest = sha256.convert(await operations.readAsBytes()).toString();
    await fixture.workspace.initialize(legacyTextOwnerStopped: true);
    expect(fixture.workspace.items.single.toJson()['state'], 'legacy_bridge');
    expect(sha256.convert(await operations.readAsBytes()).toString(), digest);
    final archive = jsonDecode(
      await File(
        '${fixture.workspace.directory.path}/drafts-migration/legacy-operations.json',
      ).readAsString(),
    ) as Json;
    expect(archive['payload'], raw);
    expect(archive['dispatch'], 'blocked');
    expect(fixture.httpCalls, isEmpty);
  });
  test('legacy WAV/ACK/session/key remain at original owner; live audio writer prevents adoption', () async {
    final directory = Directory(
      '${fixture.workspace.directory.path}/active-audio',
    );
    await directory.create(recursive: true);
    final journal = <String, dynamic>{
      'version': 1,
      'id': 'old-session',
      'key': 'old-create-key',
      'phase': 'paused',
      'parameters': {'title': 'Legacy audio', 'folder_ids': <String>[]},
      'closed_ms': 100,
      'chunks': [
        {
          'sequence': 0,
          'start_ms': 0,
          'duration_ms': 100,
          'acked': false,
          'sha256': 'saved-sha',
        },
      ],
    };
    final file = File('${directory.path}/session.json');
    await file.writeAsString(jsonEncode(journal));
    final pcm = File('${directory.path}/0.wav');
    await pcm.writeAsBytes(Uint8List(3244)..[0] = 82);
    final original = await file.readAsBytes(), audio = await pcm.readAsBytes();
    await fixture.workspace.initialize(
      legacyTextOwnerStopped: true,
      legacyAudioOwnerStopped: false,
    );
    expect(fixture.workspace.items, isEmpty);
    expect(await file.readAsBytes(), original);
    expect(await pcm.readAsBytes(), audio);
    await fixture.workspace.initialize(
      legacyTextOwnerStopped: true,
      legacyAudioOwnerStopped: true,
    );
    final item = fixture.workspace.items.single;
    expect(item.toJson()['state'], 'legacy_bridge');
    expect(item.serverIds['audio_session_id'], 'old-session');
    expect(item.requests['legacy-audio-create']!.key, 'old-create-key');
    expect(
      (item.toJson()['checkpoints'] as Json)['legacy']['journal'],
      journal,
    );
    expect(
      (item.toJson()['checkpoints'] as Json)['legacy']['files']
          .single['sha256'],
      sha256.convert(audio).toString(),
    );
    expect(await file.readAsBytes(), original);
    expect(await pcm.readAsBytes(), audio);
    expect(fixture.httpCalls, isEmpty);
  });
}

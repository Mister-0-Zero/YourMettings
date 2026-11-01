import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:queue_owner/queue_owner.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/drafts/draft_record.dart';
import 'package:your_mettings/services/drafts/draft_repository.dart';

class TestAuthority implements QueueWriteAuthority {
  TestAuthority(this.scopeId);
  @override
  final String scopeId;
  Future<void> tail = Future.value();
  @override
  Future<T> serialized<T>(Future<T> Function() action) {
    final task = tail.then((_) => action());
    tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  @override
  Future<void> writeSnapshot(File file, String encoded) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(encoded, flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<void> eraseFile(File file) async {
    await file.delete();
  }

  @override
  Future<void> eraseDraft(Directory directory) async {
    await directory.delete(recursive: true);
  }
}

class FaultRepository extends LocalDraftRepository {
  FaultRepository({required super.scopeDirectory, required super.authority});
  bool failWrite = false, failDelete = false;
  @override
  Future<void> writeSnapshot(File file, Json json) async {
    if (failWrite) {
      failWrite = false;
      await File('${file.path}.tmp')
          .writeAsString(jsonEncode(json), flush: true);
      throw const FileSystemException('synthetic disk full');
    }
    await super.writeSnapshot(file, json);
  }

  @override
  Future<void> deleteBytes(String id) async {
    if (failDelete) {
      failDelete = false;
      await File('${draftDirectory(id).path}/draft.json').delete();
      throw const FileSystemException('synthetic cleanup interruption');
    }
    await super.deleteBytes(id);
  }
}

void main() {
  final scope = List.filled(64, 'a').join();
  late Directory temporary, scoped;
  late TestAuthority authority;
  late FaultRepository repo;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('ym-drafts-');
    scoped = Directory('${temporary.path}/$scope');
    authority = TestAuthority(scope);
    repo = FaultRepository(scopeDirectory: scoped, authority: authority);
  });
  tearDown(() async {
    await authority.tail;
    await temporary.delete(recursive: true);
  });
  LocalDraftRecord text(String value) => LocalDraftRecord.create(
    scopeId: scope,
    kind: LocalDraftKind.text,
    input: LocalDraftInput(title: value, text: value),
  );
  test('two audio and two text drafts survive cold reload independently without server IDs or opt-in', () async {
    final records = [
      text('one'),
      text('two'),
      LocalDraftRecord.create(scopeId: scope, kind: LocalDraftKind.audio),
      LocalDraftRecord.create(scopeId: scope, kind: LocalDraftKind.audio),
    ];
    for (final record in records) {
      await repo.create(record);
    }
    final cold = LocalDraftRepository(
      scopeDirectory: scoped,
      authority: authority,
    );
    final loaded = await cold.list();
    expect(
      loaded.items.map((r) => r.localId).toSet(),
      records.map((r) => r.localId).toSet(),
    );
    expect(loaded.issues, isEmpty);
    expect(
      loaded.items.every(
        (r) => !r.autoStart && r.serverIds.isEmpty && r.requests.isEmpty,
      ),
      isTrue,
    );
    expect((await cold.read(records[0].localId)).input.text, 'one');
    expect((await cold.read(records[1].localId)).input.text, 'two');
  });
  test('lost create reply, edited input, cold restart retain exact frozen body/key and bind one server ID', () async {
    final original = await repo.create(text('old title'));
    final body = <String, dynamic>{
      'title': 'old title',
      'folder_ids': ['old-folder'],
      'processing_mode': 'automatic',
    };
    final request = FrozenDraftRequest(
      method: 'POST',
      path: 'audio-sessions',
      key: 'stable-key',
      body: body,
    );
    final frozen = await repo.freezeRequest(
      original.localId,
      original.revision,
      'create',
      request,
    );
    body['title'] = 'mutated caller';
    final edited = await repo.update(
      original.localId,
      expectedRevision: frozen.revision,
      change: (j) {
        j['input'] = LocalDraftInput(
          title: 'new title',
          text: 'new text',
          folderIds: ['new-folder'],
        ).toJson();
        j['auto_start_when_online'] = true;
      },
    );
    final cold = LocalDraftRepository(
      scopeDirectory: scoped,
      authority: authority,
    );
    final restored = await cold.read(original.localId);
    expect(restored.input.title, 'new title');
    expect(restored.input.folderIds, ['new-folder']);
    expect(restored.requests['create']!.encodedBody, request.encodedBody);
    expect(restored.requests['create']!.body['title'], 'old title');
    expect(restored.requests['create']!.key, 'stable-key');
    expect(restored.autoStart, isTrue);
    await cold.update(
      original.localId,
      expectedRevision: edited.revision,
      change: (j) =>
          (j['server_ids'] as Json)['audio_session_id'] = 'server-one',
    );
    final rebound = await cold.read(original.localId);
    expect(rebound.localId, original.localId);
    expect(rebound.serverIds['audio_session_id'], 'server-one');
    await expectLater(
      cold.update(
        original.localId,
        expectedRevision: rebound.revision,
        change: (j) =>
            (j['server_ids'] as Json)['audio_session_id'] = 'server-two',
      ),
      throwsStateError,
    );
    await expectLater(
      cold.freezeRequest(
        original.localId,
        rebound.revision,
        'create',
        FrozenDraftRequest(
          method: 'POST',
          path: 'audio-sessions',
          key: 'another-key',
          body: body,
        ),
      ),
      throwsStateError,
    );
  });
  test('concurrent local edits use revision CAS; failed disk commit preserves old manifest and exposes pending snapshot', () async {
    final original = await repo.create(text('saved'));
    final first = repo.update(
      original.localId,
      expectedRevision: original.revision,
      change: (j) => j['input'] = LocalDraftInput(title: 'first').toJson(),
    );
    final second = repo.update(
      original.localId,
      expectedRevision: original.revision,
      change: (j) => j['input'] = LocalDraftInput(title: 'stale').toJson(),
    );
    await first;
    await expectLater(second, throwsA(isA<DraftRevisionConflict>()));
    repo.failWrite = true;
    final current = await repo.read(original.localId);
    await expectLater(
      repo.update(
        original.localId,
        expectedRevision: current.revision,
        change: (j) => j['input'] = LocalDraftInput(title: 'unsaved').toJson(),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect((await repo.read(original.localId)).input.title, 'first');
    expect((await repo.list()).issues.single.code, 'uncommitted_snapshot');
  });
  test('unreadable manifest and unknown schema preserve audio bytes and never promote tmp as committed data', () async {
    final record = await repo.create(
      LocalDraftRecord.create(scopeId: scope, kind: LocalDraftKind.audio),
    );
    final bytes = File('${repo.draftDirectory(record.localId).path}/0.wav');
    await bytes.writeAsBytes([1, 2, 3, 4], flush: true);
    final manifest = File(
      '${repo.draftDirectory(record.localId).path}/draft.json',
    );
    await manifest.writeAsString(
      jsonEncode({...record.toJson(), 'schema': 999}),
      flush: true,
    );
    final listed = await repo.list();
    expect(listed.items, isEmpty);
    expect(listed.issues.single.code, 'manifest_unreadable');
    expect(await bytes.readAsBytes(), [1, 2, 3, 4]);
    await expectLater(
      repo.read(record.localId),
      throwsA(isA<FormatException>()),
    );
  });
  test('scope/local identity mismatch and path traversal fail without changing stored data', () async {
    final record = await repo.create(text('owned'));
    expect(() => repo.draftDirectory('../escape'), throwsArgumentError);
    final other = List.filled(64, 'b').join();
    await expectLater(
      repo.create(
        LocalDraftRecord.create(scopeId: other, kind: LocalDraftKind.text),
      ),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      repo.update(
        record.localId,
        expectedRevision: record.revision,
        change: (j) => j['scope_id'] = other,
      ),
      throwsStateError,
    );
    expect((await repo.read(record.localId)).scopeId, scope);
  });
  test('cleanup proof survives crash after manifest deletion; new draft with same ID is blocked until recovery', () async {
    final record = await repo.create(text('test cleanup'));
    final bytes = File('${repo.draftDirectory(record.localId).path}/0.wav');
    await bytes.writeAsBytes([1, 2, 3, 4], flush: true);
    repo.failDelete = true;
    await expectLater(
      repo.deleteLocal(
        record.localId,
        expectedRevision: record.revision,
        confirmed: true,
        remoteOutcomeConfirmed: false,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await bytes.exists(), isTrue);
    await expectLater(repo.create(record), throwsStateError);
    expect(await repo.recoverLocalDeletions(), isEmpty);
    expect(await repo.draftDirectory(record.localId).exists(), isFalse);
    expect((await repo.list()).items, isEmpty);
  });
  test('local cleanup requires explicit confirmation, stopped capture and known remote outcome', () async {
    final original = await repo.create(
      LocalDraftRecord.create(scopeId: scope, kind: LocalDraftKind.audio),
    );
    await expectLater(
      repo.deleteLocal(
        original.localId,
        expectedRevision: original.revision,
        confirmed: false,
        remoteOutcomeConfirmed: false,
      ),
      throwsStateError,
    );
    final active = await repo.update(
      original.localId,
      expectedRevision: original.revision,
      change: (j) => j['state'] = 'recording',
    );
    await expectLater(
      repo.deleteLocal(
        active.localId,
        expectedRevision: active.revision,
        confirmed: true,
        remoteOutcomeConfirmed: true,
      ),
      throwsStateError,
    );
    final pending = await repo.update(
      active.localId,
      expectedRevision: active.revision,
      change: (j) {
        j['state'] = 'queued';
        (j['server_ids'] as Json)['audio_session_id'] = 'server-one';
      },
    );
    await expectLater(
      repo.deleteLocal(
        pending.localId,
        expectedRevision: pending.revision,
        confirmed: true,
        remoteOutcomeConfirmed: false,
      ),
      throwsStateError,
    );
    await repo.deleteLocal(
      pending.localId,
      expectedRevision: pending.revision,
      confirmed: true,
      remoteOutcomeConfirmed: true,
    );
    expect(await repo.draftDirectory(pending.localId).exists(), isFalse);
  });
}

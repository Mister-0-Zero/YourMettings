import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:queue_owner/queue_owner.dart';
import 'package:record/record.dart';
import 'package:your_mettings/features/recording/microphone_capture.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/models/processing_options.dart';
import 'package:your_mettings/services/drafts/audio_wire_plan.dart';
import 'package:your_mettings/services/drafts/draft_record.dart';
import 'package:your_mettings/services/drafts/draft_repository.dart';
import 'package:your_mettings/services/drafts/local_audio_capture.dart';

class _Authority implements QueueAudioAuthority {
  @override
  final scopeId = 'a' * 64;
  int? failAtOffset;
  Completer<void>? firstAudioEntered, releaseFirstAudio, secondMutationQueued;
  int _pending = 0;
  bool _audioGated = false;
  Future<void> _tail = Future.value();
  @override
  Future<T> serialized<T>(Future<T> Function() action) {
    _pending++;
    if (_pending == 2 &&
        secondMutationQueued != null &&
        !secondMutationQueued!.isCompleted) {
      secondMutationQueued!.complete();
    }
    final task = _tail.then((_) => action()).whenComplete(() => _pending--);
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  @override
  Future<void> writeSnapshot(File file, String encoded) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.test.tmp');
    await tmp.writeAsString(encoded, flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<void> eraseFile(File file) => file.delete();
  @override
  Future<void> eraseDraft(Directory dir) => dir.delete(recursive: true);
  @override
  Future<void> writeAudio(File file, Uint8List bytes) async {
    if (firstAudioEntered != null && !_audioGated) {
      _audioGated = true;
      firstAudioEntered!.complete();
      await releaseFirstAudio!.future;
    }
    if (await file.exists()) throw StateError('Immutable audio exists');
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<int> appendPcm(File file, int offset, Uint8List bytes) async {
    final current = await file.exists() ? await file.length() : 0;
    if (current != offset) throw StateError('Offset conflict');
    if (failAtOffset == offset) {
      throw const FileSystemException('Injected disk full');
    }
    await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
    return file.length();
  }
}

class _Mic extends MicrophoneCapture {
  final data = StreamController<Uint8List>.broadcast(sync: true);
  final changes = StreamController<RecordState>.broadcast(sync: true);
  bool permission = true, opened = false;
  @override
  Future<bool> allowed() async => permission;
  @override
  Stream<RecordState> get states => changes.stream;
  @override
  Future<Stream<Uint8List>> start() async {
    opened = true;
    return data.stream;
  }

  @override
  Future<void> pause() async {
    changes.add(RecordState.pause);
  }

  @override
  Future<void> resume() async {
    changes.add(RecordState.record);
  }

  @override
  Future<void> stop() async {
    opened = false;
    changes.add(RecordState.stop);
  }

  @override
  Future<void> dispose() async {
    await data.close();
    await changes.close();
  }
}

void main() {
  late Directory root;
  late _Authority owner;
  late LocalDraftRepository repo;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ym-local-capture-');
    owner = _Authority();
    repo = LocalDraftRepository(
      scopeDirectory: Directory('${root.path}/${owner.scopeId}'),
      authority: owner,
    );
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  Future<LocalDraftRecord> draft() => repo.create(
    LocalDraftRecord.create(scopeId: owner.scopeId, kind: LocalDraftKind.audio),
  );
  AudioWireLimits limits({int target = 1, int max = 2, int bytes = 64044}) =>
      AudioWireLimits.fromJson({
        'chunk_target_seconds': target,
        'max_chunk_seconds': max,
        'max_upload_bytes': bytes,
        'max_chunks': 240,
      });
  test('offline mic starts without server ID, limits or HTTP and drains before ready', () async {
    final record = await draft(), mic = _Mic();
    final capture = LocalAudioCapture(
      repository: repo,
      localId: record.localId,
      authority: owner,
      microphone: mic,
    );
    await capture.start();
    expect(mic.opened, isTrue);
    expect((await repo.read(record.localId)).serverIds, isEmpty);
    mic.data.add(Uint8List(3200));
    mic.data.add(Uint8List(3200)..[0] = 42);
    await capture.pause();
    expect(capture.snapshot['phase'], 'paused');
    await capture.resume();
    mic.data.add(Uint8List(3200)..[1] = 3);
    await capture.stop();
    expect(capture.snapshot['byte_count'], 9600);
    final stored = await repo.read(record.localId);
    expect(stored.toJson()['state'], 'ready');
    expect(stored.autoStart, isFalse);
    expect((await capture.source.readAsBytes())[3200], 42);
    await capture.dispose();
  });
  test(
    'process death restores actual durable bytes without opening microphone',
    () async {
      final first = await draft(), second = await draft();
      await repo.update(
        first.localId,
        expectedRevision: first.revision,
        change: (j) => j['state'] = 'recording',
      );
      final source = File(
        '${repo.draftDirectory(first.localId).path}/source.pcm',
      );
      await source.writeAsBytes(Uint8List(9600), flush: true);
      final restored = await LocalAudioCapture.recover(repo, first.localId);
      expect(restored.toJson()['state'], 'interrupted');
      expect(
        (restored.toJson()['checkpoints'] as Json)['capture']['byte_count'],
        9600,
      );
      expect((await repo.read(second.localId)).toJson()['state'], 'draft');
      expect(await source.length(), 9600);
    },
  );
  test('denied permission keeps draft and never claims recording', () async {
    final record = await draft(), mic = _Mic()..permission = false;
    final capture = LocalAudioCapture(
      repository: repo,
      localId: record.localId,
      authority: owner,
      microphone: mic,
    );
    await expectLater(capture.start(), throwsStateError);
    expect((await repo.read(record.localId)).toJson()['state'], 'draft');
    expect(mic.opened, isFalse);
    await capture.dispose();
  });
  test('negotiated wire plan preserves every PCM sample, container and timestamps', () async {
    var record = await draft();
    final source = Uint8List(32000 * 5 + 2);
    // Non-silent first 2 sec, then silence provides a boundary after target.
    final values = ByteData.sublistView(source);
    for (var i = 0; i < 64000; i += 2) {
      values.setInt16(i, 1800, Endian.little);
    }
    await File('${repo.draftDirectory(record.localId).path}/source.pcm')
        .writeAsBytes(source);
    record = await repo.update(
      record.localId,
      expectedRevision: record.revision,
      change: (j) => j['state'] = 'ready',
    );
    final planner = AudioWirePlanner(repo, owner);
    final plan = await planner.prepare(record.localId, limits());
    final reconstructed = BytesBuilder(copy: false);
    var expectedStart = 0;
    for (final item in (plan['chunks'] as List).cast<Json>()) {
      final bytes = await planner
          .file(
            record.localId,
            item['sequence'] as int,
            planId: plan['plan_id'] as String,
          )
          .readAsBytes();
      expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
      expect(
        ByteData.sublistView(bytes).getUint32(40, Endian.little),
        bytes.length - 44,
      );
      expect(item['start_ms'], expectedStart);
      expect(item['duration_ms'], greaterThan(0));
      expectedStart += item['duration_ms'] as int;
      reconstructed.add(bytes.sublist(44));
      expect(bytes.length, lessThanOrEqualTo(64044));
    }
    expect(reconstructed.takeBytes(), source);
    expect(expectedStart, 5000);
    // Different limits after restart cannot resegment a potentially sent plan.
    final repeated = await AudioWirePlanner(
      repo,
      owner,
    ).prepare(record.localId, limits(target: 2, max: 3, bytes: 96044));
    expect(jsonEncode(repeated), jsonEncode(plan));
  });
  test(
    'changed frozen wire bytes stop transmission and preserve source',
    () async {
      var record = await draft();
      final source = File(
        '${repo.draftDirectory(record.localId).path}/source.pcm',
      );
      await source.writeAsBytes(Uint8List(32000));
      record = await repo.update(
        record.localId,
        expectedRevision: record.revision,
        change: (j) => j['state'] = 'ready',
      );
      final planner = AudioWirePlanner(repo, owner);
      final plan = await planner.prepare(record.localId, limits());
      await planner
          .file(record.localId, 0, planId: plan['plan_id'] as String)
          .writeAsBytes(Uint8List(32044));
      await expectLater(
        planner.prepare(record.localId, limits()),
        throwsFormatException,
      );
      expect(await source.length(), 32000);
    },
  );
  test(
    'audio disk failure preserves durable prefix and marks interruption',
    () async {
      final record = await draft(), mic = _Mic();
      final capture = LocalAudioCapture(
        repository: repo,
        localId: record.localId,
        authority: owner,
        microphone: mic,
      );
      await capture.start();
      owner.failAtOffset = 3200;
      mic.data.add(Uint8List(3200)..[0] = 29);
      mic.data.add(Uint8List(3200));
      await capture.stop();
      expect(
        (await repo.read(record.localId)).toJson()['state'],
        'interrupted',
      );
      expect(capture.snapshot['error_code'], 'local_audio_write_failed');
      expect(await capture.source.length(), 3200);
      expect((await capture.source.readAsBytes()).first, 29);
      await capture.dispose();
    },
  );
  test(
    'published wire plan is immutable and cannot be appended by a new capture',
    () async {
      var record = await draft();
      await File('${repo.draftDirectory(record.localId).path}/source.pcm')
          .writeAsBytes(Uint8List(32000));
      record = await repo.update(
        record.localId,
        expectedRevision: record.revision,
        change: (j) => j['state'] = 'interrupted',
      );
      await AudioWirePlanner(repo, owner).prepare(record.localId, limits());
      record = await repo.read(record.localId);
      await expectLater(
        repo.update(
          record.localId,
          expectedRevision: record.revision,
          change: (j) {
            (j['checkpoints'] as Json).remove('wire_plan');
          },
        ),
        throwsStateError,
      );
      final mic = _Mic();
      final capture = LocalAudioCapture(
        repository: repo,
        localId: record.localId,
        authority: owner,
        microphone: mic,
      );
      await expectLater(capture.start(), throwsStateError);
      expect(mic.opened, isFalse);
      await capture.dispose();
    },
  );
  test('concurrent planners with different limits cannot overwrite the committed WAVs', () async {
    var record = await draft();
    final source = File(
      '${repo.draftDirectory(record.localId).path}/source.pcm',
    );
    await source.writeAsBytes(Uint8List(32000 * 5));
    record = await repo.update(
      record.localId,
      expectedRevision: record.revision,
      change: (j) => j['state'] = 'ready',
    );
    owner.firstAudioEntered = Completer<void>();
    owner.releaseFirstAudio = Completer<void>();
    owner.secondMutationQueued = Completer<void>();
    Future<Object> settled(Future<Json> value) =>
        value.then<Object>((j) => j, onError: (Object error) => error);
    final first = settled(
      AudioWirePlanner(repo, owner).prepare(record.localId, limits()),
    );
    await owner.firstAudioEntered!.future;
    final second = settled(
      AudioWirePlanner(
        repo,
        owner,
      ).prepare(record.localId, limits(target: 2, max: 3, bytes: 96044)),
    );
    // Both saw no plan. B's first write is queued while A's first write is held.
    await owner.secondMutationQueued!.future;
    owner.releaseFirstAudio!.complete();
    final results = await Future.wait([first, second]);
    expect(results.whereType<Json>().length, 1);
    expect(results.whereType<DraftRevisionConflict>().length, 1);
    final committed =
        ((await repo.read(record.localId)).toJson()['checkpoints']
                as Json)['wire_plan']
            as Json;
    final planner = AudioWirePlanner(repo, owner);
    await planner.verify(record.localId, committed);
    final reconstructed = BytesBuilder(copy: false);
    for (final item in (committed['chunks'] as List).cast<Json>()) {
      final wav = await planner
          .file(
            record.localId,
            item['sequence'] as int,
            planId: committed['plan_id'] as String,
          )
          .readAsBytes();
      expect(sha256.convert(wav).toString(), item['sha256']);
      expect(wav.length, item['byte_count']);
      reconstructed.add(wav.sublist(44));
    }
    expect(reconstructed.takeBytes(), await source.readAsBytes());
    final reopened = await AudioWirePlanner(
      repo,
      owner,
    ).prepare(record.localId, limits(target: 2, max: 3, bytes: 96044));
    expect(jsonEncode(reopened), jsonEncode(committed));
  });
  test('template version follows selected template and legacy JSON stays unchanged', () {
    final version = 'b' * 64;
    final options = ProcessingOptions(
      templateId: 'one',
      expectedTemplateVersion: version,
    );
    expect(
      options.copyWith(detailLevel: 'brief').expectedTemplateVersion,
      version,
    );
    expect(options.copyWith(templateId: 'two').expectedTemplateVersion, isNull);
    expect(
      options
          .copyWith(useDefaultTemplate: true)
          .toJson()
          .containsKey('expected_template_version'),
      isFalse,
    );
    expect(
      ProcessingOptions.fromJson(options.toJson()).expectedTemplateVersion,
      version,
    );
    expect(
      const ProcessingOptions().toJson().containsKey(
        'expected_template_version',
      ),
      isFalse,
    );
  });
}

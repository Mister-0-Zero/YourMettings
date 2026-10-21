import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:record/record.dart';
import 'package:your_mettings/features/recording/audio_api.dart';
import 'package:your_mettings/features/recording/audio_engine.dart';
import 'package:your_mettings/features/recording/audio_journal.dart';
import 'package:your_mettings/features/recording/microphone_capture.dart';
import 'package:your_mettings/features/recording/pcm_chunk_writer.dart';

class FakeMic implements MicrophoneCapture {
  final audio = StreamController<Uint8List>();
  final events = StreamController<RecordState>.broadcast();
  int starts = 0, pauses = 0, resumes = 0;
  @override
  Future<bool> allowed() async => true;
  @override
  Stream<RecordState> get states => events.stream;
  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    return audio.stream;
  }

  @override
  Future<void> pause() async {
    pauses++;
    events.add(RecordState.pause);
  }

  @override
  Future<void> resume() async {
    resumes++;
    events.add(RecordState.record);
  }

  @override
  Future<void> stop() async {
    await audio.close();
  }

  @override
  Future<void> dispose() async {
    if (!audio.isClosed) await audio.close();
    await events.close();
  }
}

class FaultJournal extends AudioJournal {
  FaultJournal(super.directory);
  bool fail = false;
  @override
  void saveSync() {
    if (fail) throw FileSystemException('Injected disk full');
    super.saveSync();
  }
}

void main() {
  late Directory dir;
  late AudioJournal journal;
  const limits = {
    'chunk_target_seconds': 1,
    'max_chunk_seconds': 2,
    'max_upload_bytes': 64044,
    'max_chunks': 240,
  };
  setUp(() {
    dir = Directory.systemTemp.createTempSync('yourmettings-audio-');
    journal = AudioJournal(dir)
      ..data = {
        'version': 1,
        'id': 'session',
        'phase': 'sending',
        'chunks': <Map<String, dynamic>>[],
        'closed_ms': 0,
        'limits': limits,
      };
  });
  tearDown(() => dir.deleteSync(recursive: true));
  http.Response reply(Object value, [int status = 200]) =>
      http.Response(jsonEncode(value), status);
  void seed() {
    final w = PcmChunkWriter(
      journal,
      targetSeconds: 1,
      maxSeconds: 2,
      maxBytes: 64044,
      maxChunks: 240,
    );
    w.add(Uint8List(32000));
    w.closeChunk();
    journal.saveSync();
  }

  test(
    'no deletion before a verified durable ACK, retry same bytes and metadata',
    () async {
      seed();
      var calls = 0;
      final hashes = <String>[];
      final api = AudioApi(
        Uri.parse('http://example/api/v1/'),
        client: MockClient((r) async {
          if (r.url.path.endsWith('/chunks')) {
            calls++;
            hashes.add(sha256.convert(r.bodyBytes).toString());
            expect(r.headers['content-type'], 'application/octet-stream');
            expect(r.url.queryParameters['sequence_number'], '0');
            return reply({
              'accepted': true,
              'safe_to_delete_local': calls > 1,
              'chunk': {'sequence_number': 0, 'sha256': hashes.last},
            }, calls == 1 ? 201 : 200);
          }
          return reply({'status': 'transcribing'});
        }),
      );
      final engine = AudioEngine(journal, api);
      await engine.sync(force: true);
      expect(journal.chunkFile(0).existsSync(), true);
      expect(journal.chunks.single['acked'], false);
      await engine.sync(force: true);
      expect(journal.chunkFile(0).existsSync(), false);
      expect(journal.chunks.single['acked'], true);
      expect(hashes[0], hashes[1]);
      expect(engine.phase, 'transcribing');
      await engine.dispose();
    },
  );
  test(
    'offline queue survives a fresh engine and completes once on recovery',
    () async {
      seed();
      final offline = AudioEngine(
        journal,
        AudioApi(
          Uri.parse('http://example/'),
          client: MockClient(
            (_) async => throw http.ClientException('offline'),
          ),
        ),
      );
      await offline.sync(force: true);
      expect(journal.data['network_error'], true);
      await offline.dispose();
      final restored = AudioJournal(dir);
      await restored.load();
      var completes = 0;
      final engine = AudioEngine(
        restored,
        AudioApi(
          Uri.parse('http://example/'),
          client: MockClient((r) async {
            if (r.url.path.endsWith('/chunks')) {
              return reply({
                'accepted': true,
                'safe_to_delete_local': true,
                'chunk': {
                  'sequence_number': 0,
                  'sha256': sha256.convert(r.bodyBytes).toString(),
                },
              });
            }
            if (r.url.path.endsWith('/complete')) {
              completes++;
              expect(jsonDecode(r.body)['expected_chunk_count'], 1);
            }
            return reply({
              'status': 'ready_for_review',
              'transcript_id': 'transcript',
            });
          }),
        ),
      );
      await engine.sync(force: true);
      await engine.sync(force: true);
      expect(completes, 1);
      expect(engine.phase, 'review');
      await engine.dispose();
    },
  );
  test(
    'continuous microphone, repeated pause/resume, timer follows samples',
    () async {
      journal.data['phase'] = 'prepared';
      journal.saveSync();
      final mic = FakeMic();
      final engine = AudioEngine(
        journal,
        AudioApi(
          Uri.parse('http://example/'),
          client: MockClient(
            (_) async => throw http.ClientException('offline'),
          ),
        ),
        capture: mic,
      );
      await engine.initialize();
      for (var i = 0; i < 4; i++) {
        mic.audio.add(Uint8List(16000));
        await Future<void>.delayed(Duration.zero);
        await engine.pause();
        expect(engine.phase, 'paused');
        await engine.resume();
      }
      expect(mic.starts, 1);
      expect(mic.pauses, 4);
      expect(mic.resumes, 4);
      await engine.stop();
      expect(engine.snapshot['elapsed_ms'], 2000);
      expect(engine.phase, 'sending');
      await engine.dispose();
    },
  );
  test(
    'crash after closing file but before manifest publish recovers it',
    () async {
      journal.data['phase'] = 'recording';
      journal.saveSync();
      journal.chunkFile(0).writeAsBytesSync([
        ...PcmChunkWriter.header(0),
        ...Uint8List(32000),
      ], flush: true);
      final engine = AudioEngine(
        journal,
        AudioApi(
          Uri.parse('http://example/'),
          client: MockClient(
            (_) async => throw http.ClientException('offline'),
          ),
        ),
      );
      await engine.initialize();
      expect(engine.phase, 'interrupted');
      expect(journal.chunks.length, 1);
      expect(journal.chunkFile(0).lengthSync(), 32044);
      await engine.dispose();
    },
  );
  test('create replay retains stable key after a lost response', () async {
    journal.data = {};
    if (journal.manifest.existsSync()) journal.manifest.deleteSync();
    var calls = 0;
    final keys = <String>[];
    final api = AudioApi(
      Uri.parse('http://example/'),
      client: MockClient((r) async {
        calls++;
        keys.add(r.headers['Idempotency-Key']!);
        if (calls == 1) throw http.ClientException('lost response');
        return reply({'id': 'same-session', ...limits}, 200);
      }),
    );
    await expectLater(
      AudioEngine.prepare(journal, api, {
        'title': 'Test',
        'folder_ids': ['folder'],
      }),
      throwsException,
    );
    final restored = AudioJournal(dir);
    await AudioEngine.prepare(restored, api, {
      'title': 'Test',
      'folder_ids': ['folder'],
    });
    expect(keys[0], keys[1]);
    expect(restored.data['id'], 'same-session');
    api.close();
  });
  test(
    'new chunk while an upload is pending is sent on next pass before complete',
    () async {
      seed();
      journal.data['phase'] = 'recording';
      final uploadStarted = Completer<void>();
      final release = Completer<void>();
      var uploads = 0, completes = 0;
      final engine = AudioEngine(
        journal,
        AudioApi(
          Uri.parse('http://example/'),
          client: MockClient((r) async {
            if (r.url.path.endsWith('/chunks')) {
              uploads++;
              if (uploads == 1) {
                uploadStarted.complete();
                await release.future;
              }
              return reply({
                'accepted': true,
                'safe_to_delete_local': true,
                'chunk': {
                  'sequence_number': int.parse(
                    r.url.queryParameters['sequence_number']!,
                  ),
                  'sha256': sha256.convert(r.bodyBytes).toString(),
                },
              });
            }
            if (r.url.path.endsWith('/complete')) completes++;
            return reply({'status': 'transcribing'});
          }),
        ),
      );
      final first = engine.sync(force: true);
      await uploadStarted.future;
      final writer = PcmChunkWriter(
        journal,
        targetSeconds: 1,
        maxSeconds: 2,
        maxBytes: 64044,
        maxChunks: 240,
      );
      writer.add(Uint8List(32000));
      writer.closeChunk();
      journal.data['phase'] = 'sending';
      release.complete();
      await first;
      expect(completes, 0);
      await engine.sync(force: true);
      expect(uploads, 2);
      expect(completes, 1);
      await engine.dispose();
    },
  );
  test(
    'disk write failure stops microphone and retains recoverable bytes',
    () async {
      final failing = FaultJournal(dir)
        ..data = {...journal.data, 'phase': 'prepared'};
      failing.saveSync();
      final mic = FakeMic();
      final engine = AudioEngine(
        failing,
        AudioApi(
          Uri.parse('http://example/'),
          client: MockClient(
            (_) async => throw http.ClientException('offline'),
          ),
        ),
        capture: mic,
      );
      await engine.initialize();
      failing.fail = true;
      mic.audio.add(Uint8List(32000));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(mic.audio.isClosed, true);
      expect(engine.phase, 'interrupted');
      expect(failing.chunkFile(0).existsSync(), true);
      failing.fail = false;
      await engine.dispose();
    },
  );
  test(
    'accepting result waits for in-flight polling and cannot resurrect session',
    () async {
      journal.data['phase'] = 'review';
      final started = Completer<void>();
      final release = Completer<void>();
      final engine = AudioEngine(
        journal,
        AudioApi(
          Uri.parse('http://example/'),
          client: MockClient((_) async {
            started.complete();
            await release.future;
            return reply({'status': 'completed'});
          }),
        ),
      );
      final polling = engine.sync(force: true);
      await started.future;
      final accepting = engine.markDone();
      release.complete();
      await polling;
      await accepting;
      expect(engine.phase, 'done');
      await engine.sync(force: true);
      expect(engine.phase, 'done');
      await engine.dispose();
    },
  );
}

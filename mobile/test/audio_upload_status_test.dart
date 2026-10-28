import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/features/recording/audio_api.dart';
import 'package:your_mettings/features/recording/audio_engine.dart';
import 'package:your_mettings/features/recording/audio_journal.dart';
import 'package:your_mettings/features/recording/pcm_chunk_writer.dart';
import 'package:your_mettings/features/recording/recorder_coordinator.dart';

import 'audio_engine_test.dart' show FaultJournal;

import 'package:your_mettings/models/api_models.dart';

const limits = {
  'chunk_target_seconds': 1,
  'max_chunk_seconds': 2,
  'max_upload_bytes': 64044,
  'max_chunks': 240,
};

AudioJournal seed(Directory dir) {
  final journal = AudioJournal(dir)
    ..data = {
      'version': 1,
      'id': 'same-session',
      'key': 'same-creation-key',
      'phase': 'sending',
      'chunks': <Json>[],
      'closed_ms': 0,
      'limits': limits,
    };
  final writer = PcmChunkWriter(
    journal,
    targetSeconds: 1,
    maxSeconds: 2,
    maxBytes: 64044,
    maxChunks: 240,
  );
  writer.add(Uint8List(64000));
  writer.closeChunk();
  writer.release();
  journal.saveSync();
  return journal;
}

http.Response reply(Object value, [int code = 200]) =>
    http.Response(jsonEncode(value), code);

void main() {
  for (final restart in [false, true]) {
    test(
      'ACK clears stale error before the next upload finishes, restart=$restart',
      () async {
        final dir = Directory.systemTemp.createTempSync('ym-upload-status-');
        addTearDown(() => dir.deleteSync(recursive: true));
        var journal = seed(dir);
        expect(journal.chunks, hasLength(2));
        final originalBytes = [
          for (var n = 0; n < 2; n++) journal.chunkFile(n).readAsBytesSync(),
        ];
        final originalMetadata = jsonEncode(journal.chunks);
        var attempt = 0, active = 0, maxActive = 0, completeCalls = 0;
        final secondStarted = Completer<void>();
        final secondReply = Completer<void>();
        addTearDown(() {
          if (!secondReply.isCompleted) secondReply.complete();
        });
        Future<http.Response> backend(http.Request request) async {
          expect(
            request.url.path,
            startsWith('/api/v1/audio-sessions/same-session'),
          );
          if (request.url.path.endsWith('/chunks')) {
            active++;
            if (active > maxActive) maxActive = active;
            try {
              final sequence = int.parse(
                request.url.queryParameters['sequence_number']!,
              );
              expect(request.bodyBytes, originalBytes[sequence]);
              final hash = sha256.convert(request.bodyBytes).toString();
              expect(request.url.queryParameters['content_sha256'], hash);
              final metadata =
                  (jsonDecode(originalMetadata) as List)[sequence] as Json;
              for (final key in ['start_ms', 'duration_ms']) {
                expect(request.url.queryParameters[key], '${metadata[key]}');
              }
              if (attempt == 0) throw http.ClientException('offline');
              if (attempt == 1 && sequence == 1) {
                secondStarted.complete();
                await secondReply.future;
                throw http.ClientException('connection lost again');
              }
              return reply({
                'accepted': true,
                'safe_to_delete_local': true,
                'chunk': {'sequence_number': sequence, 'sha256': hash},
              });
            } finally {
              active--;
            }
          }
          if (request.url.path.endsWith('/complete')) {
            completeCalls++;
            expect(jsonDecode(request.body), {'expected_chunk_count': 2});
          }
          return reply({'status': 'transcribing'});
        }

        AudioEngine buildEngine() => AudioEngine(
          journal,
          AudioApi(
            Uri.parse('http://example/api/v1/'),
            client: MockClient(backend),
          ),
        );
        var engine = buildEngine();
        await engine.sync(force: true);
        expect(journal.data['network_error'], isTrue);
        expect(
          journal.chunks.every((chunk) => chunk['acked'] == false),
          isTrue,
        );
        if (restart) {
          await engine.dispose();
          journal = AudioJournal(dir);
          await journal.load();
          expect(journal.data['upload_error'], isNotNull);
          engine = buildEngine();
        }
        attempt = 1;
        final retry = engine.sync(force: true);
        await secondStarted.future.timeout(const Duration(seconds: 5));
        // Real ACK published durably, while sequence 1 is still in flight.
        final durable = jsonDecode(journal.manifest.readAsStringSync()) as Json;
        expect((durable['chunks'] as List)[0]['acked'], isTrue);
        expect(durable['upload_error'], isNull);
        expect(durable['network_error'], isNull);
        expect(engine.snapshot['sync_stage'], 'uploading');
        expect(engine.snapshot['sync_active'], isTrue);
        expect(audioServiceCanStop(engine.snapshot), isFalse);
        expect(durable.containsKey('sync_active'), isFalse);
        expect(durable.containsKey('sync_stage'), isFalse);
        expect(journal.chunkFile(0).existsSync(), isFalse);
        expect(journal.chunkFile(1).readAsBytesSync(), originalBytes[1]);
        await engine.sync(
          force: true,
        ); // Duplicate retry cannot start a second upload.
        expect(maxActive, 1);
        secondReply.complete();
        await retry;
        expect(engine.snapshot['sync_active'], isFalse);
        expect(engine.snapshot['sync_stage'], isNull);
        expect(journal.data['network_error'], isTrue);
        expect(
          journal.chunks.where((chunk) => chunk['acked'] == true),
          hasLength(1),
        );
        expect(journal.chunkFile(1).existsSync(), isTrue);
        attempt = 2;
        await engine.sync(force: true);
        expect(engine.phase, 'transcribing');
        expect(journal.data['upload_error'], isNull);
        expect(journal.data['network_error'], isNull);
        expect(journal.chunks.every((chunk) => chunk['acked'] == true), isTrue);
        expect(completeCalls, 1);
        expect(journal.data['id'], 'same-session');
        expect(journal.data['key'], 'same-creation-key');
        expect(maxActive, 1);
        await engine.dispose();
      },
    );
  }
  test('complete and polling errors describe server-held audio and clear on their own success', () async {
    final dir = Directory.systemTemp.createTempSync('ym-upload-complete-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final journal = seed(dir);
    var completeCalls = 0, uploadCalls = 0, polls = 0;
    final pollStarted = Completer<void>();
    final pollReply = Completer<void>();
    final engine = AudioEngine(
      journal,
      AudioApi(
        Uri.parse('http://example/api/v1/'),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/chunks')) {
            uploadCalls++;
            return reply({
              'accepted': true,
              'safe_to_delete_local': true,
              'chunk': {
                'sequence_number': int.parse(
                  request.url.queryParameters['sequence_number']!,
                ),
                'sha256': sha256.convert(request.bodyBytes).toString(),
              },
            });
          }
          if (request.url.path.endsWith('/complete')) {
            if (++completeCalls == 1) return reply({}, 503);
            return reply({'status': 'transcribing'}, 202);
          }
          if (++polls == 1) {
            pollStarted.complete();
            await pollReply.future;
            return reply({}, 503);
          }
          return reply({
            'status': 'ready_for_review',
            'transcript_id': 'source',
          });
        }),
      ),
    );
    await engine.sync(force: true);
    expect(
      journal.data['upload_error'],
      contains('Все фрагменты аудио приняты сервером'),
    );
    expect(journal.data['upload_error'], contains('завершение отправки'));
    expect(
      journal.data['upload_error'],
      isNot(contains('сохранены на устройстве')),
    );
    expect(dir.listSync().where((file) => file.path.endsWith('.wav')), isEmpty);
    final retry = engine.sync(force: true);
    await pollStarted.future;
    expect(engine.phase, 'transcribing');
    expect(
      journal.data['upload_error'],
      isNull,
    ); // complete success already published.
    expect(engine.snapshot['sync_stage'], 'polling');
    expect(audioServiceCanStop(engine.snapshot), isFalse);
    pollReply.complete();
    await retry;
    expect(journal.data['upload_error'], contains('проверить распознавание'));
    expect(journal.data['network_error'], isTrue);
    expect(audioServiceCanStop(engine.snapshot), isTrue);
    await engine.sync(force: true);
    expect(journal.data['upload_error'], isNull);
    expect(engine.phase, 'review');
    expect(uploadCalls, 2);
    expect(completeCalls, 2);
    expect(polls, 2);
    await engine.dispose();
  });

  test(
    'invalid ACK or failed durable write never deletes or advances a chunk',
    () async {
      final dir = Directory.systemTemp.createTempSync('ym-upload-ack-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final initial = seed(dir);
      final journal = FaultJournal(dir)..data = initial.data;
      var valid = false;
      final engine = AudioEngine(
        journal,
        AudioApi(
          Uri.parse('http://example/api/v1/'),
          client: MockClient(
            (request) async => reply(
              valid
                  ? {
                      'accepted': true,
                      'safe_to_delete_local': true,
                      'chunk': {
                        'sequence_number': 0,
                        'sha256': sha256.convert(request.bodyBytes).toString(),
                      },
                    }
                  : {'status': 'healthy'},
            ),
          ),
        ),
      );
      await engine.sync(force: true);
      expect(journal.data['upload_error'], isNotNull);
      expect(journal.data['blocked'], isTrue);
      expect(journal.chunks.first['acked'], isFalse);
      expect(journal.chunkFile(0).existsSync(), isTrue);
      valid = true;
      journal.fail = true;
      await engine.sync(force: true);
      expect(journal.chunks.first['acked'], isFalse);
      expect(journal.chunkFile(0).existsSync(), isTrue);
      expect(journal.data['upload_error'], isNotNull);
      expect(
        (jsonDecode(journal.manifest.readAsStringSync())['chunks'] as List)
            .first['acked'],
        isFalse,
      );
      journal.fail = false;
      await engine.dispose();
    },
  );

  test(
    'no network call means neither active transport nor an invented recovery',
    () async {
      final dir = Directory.systemTemp.createTempSync('ym-upload-idle-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final journal = AudioJournal(dir)
        ..data = {
          'version': 1,
          'phase': 'recording',
          'id': 'session',
          'chunks': <Json>[],
          'network_error': true,
          'upload_error': 'old error',
        };
      final snapshots = <Json>[];
      var calls = 0;
      final engine = AudioEngine(
        journal,
        AudioApi(
          Uri.parse('http://example/api/v1/'),
          client: MockClient((_) async {
            calls++;
            return reply({});
          }),
        ),
        changed: (value) => snapshots.add(value),
      );
      await engine.sync(force: true);
      expect(calls, 0);
      expect(journal.data['upload_error'], 'old error');
      expect(snapshots.every((value) => value['sync_stage'] == null), isTrue);
      await engine.dispose();
    },
  );

  test(
    'service never stops in-flight sync even with a restored error marker',
    () {
      for (final phase in [
        'sending',
        'transcribing',
        'interrupted',
        'review',
      ]) {
        expect(
          audioServiceCanStop({
            'phase': phase,
            'network_error': true,
            'sync_active': true,
          }),
          isFalse,
        );
        expect(
          audioServiceCanStop({
            'phase': phase,
            'network_error': true,
            'sync_active': false,
          }),
          isTrue,
        );
      }
      expect(
        audioServiceCanStop({'phase': 'sending', 'sync_active': false}),
        isFalse,
      );
      expect(
        audioServiceCanStop({'phase': 'recording', 'network_error': true}),
        isFalse,
      );
    },
  );
  test('initialize automatically resumes an old failed journal without keeping its stale error', () async {
    final dir = Directory.systemTemp.createTempSync('ym-upload-startup-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final old = seed(dir);
    old.data['network_error'] = true;
    old.data['upload_error'] = 'Запись сохранена на устройстве. Отправим её, когда соединение восстановится';
    old.saveSync();
    final restored = AudioJournal(dir);
    final secondStarted = Completer<void>();
    final release = Completer<void>();
    final finished = Completer<void>();
    final engine = AudioEngine(
      restored,
      AudioApi(
        Uri.parse('http://example/api/v1/'),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/chunks')) {
            final n = int.parse(
              request.url.queryParameters['sequence_number']!,
            );
            if (n == 1) {
              secondStarted.complete();
              await release.future;
            }
            return reply({
              'accepted': true,
              'safe_to_delete_local': true,
              'chunk': {
                'sequence_number': n,
                'sha256': sha256.convert(request.bodyBytes).toString(),
              },
            });
          }
          return reply({'status': 'transcribing'});
        }),
      ),
      changed: (value) {
        if (value['phase'] == 'transcribing' &&
            value['sync_active'] == false &&
            !finished.isCompleted) {
          finished.complete();
        }
      },
    );
    await engine.initialize();
    await secondStarted.future.timeout(const Duration(seconds: 5));
    expect(restored.data['upload_error'], isNull);
    expect(restored.data['network_error'], isNull);
    expect(restored.chunks.first['acked'], isTrue);
    expect(restored.chunks.last['acked'], isFalse);
    expect(engine.snapshot['sync_stage'], 'uploading');
    release.complete();
    await finished.future.timeout(const Duration(seconds: 5));
    expect(engine.phase, 'transcribing');
    await engine.dispose();
  });
}

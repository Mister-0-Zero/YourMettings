import 'dart:async';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../../api/api_client.dart';
import '../../models/api_models.dart';
import 'audio_api.dart';
import 'audio_journal.dart';
import 'pcm_chunk_writer.dart';
import 'microphone_capture.dart';

/// Single owner of capture, journal and upload state. Runs in the Android
/// foreground-service isolate; on iOS it is kept alive by the audio session.
class AudioEngine {
  AudioEngine(
    this.journal,
    this.api, {
    this.changed,
    MicrophoneCapture? capture,
    this.allowCapture = true,
  }) : recorder = capture ?? RecordMicrophone();
  final bool allowCapture;
  final AudioJournal journal;
  final AudioApi api;
  final void Function(Json)? changed;
  final MicrophoneCapture recorder;
  PcmChunkWriter? writer;
  StreamSubscription<Uint8List>? _stream;
  StreamSubscription<RecordState>? _states;
  Completer<void>? _streamDone;
  Timer? _timer;
  Completer<void>? _idle;
  bool _captureFailed = false;
  bool _syncing = false, _command = false, _stopping = false, _disposed = false;
  int _failures = 0;
  DateTime _nextAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  void log(String event) => debugPrint('Audio: $event');
  Json get snapshot => {
    ...journal.data,
    'level': phase == 'recording' ? writer?.level ?? 0.0 : 0.0,
    'elapsed_ms': writer?.elapsedMs ?? journal.data['closed_ms'] ?? 0,
  };
  void emit() {
    if (!_disposed) changed?.call(snapshot);
  }

  void save() {
    journal.saveSync();
    emit();
  }

  String get phase => journal.data['phase'] as String? ?? 'empty';

  static Future<void> prepare(
    AudioJournal journal,
    AudioApi api,
    Json parameters,
  ) async {
    await journal.load();
    if (journal.data['phase'] == 'done') journal.data = {};
    if (journal.data.isEmpty) {
      journal.data = {
        'version': 1,
        'key': List.generate(
          24,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
        'parameters': parameters,
        'phase': 'preparing',
        'chunks': <Json>[],
        'closed_ms': 0,
      };
      journal.saveSync();
    }
    if (journal.data['phase'] == 'interrupted' && journal.chunks.isEmpty) {
      journal.data['phase'] = 'prepared';
      journal.saveSync();
    }
    if (journal.data['id'] == null) {
      final session = await api.json(
        'POST',
        '',
        body: journal.data['parameters'] as Json,
        key: journal.data['key'] as String,
      );
      // Never guess a server limit. Capture starts only after negotiation.
      for (final field in [
        'chunk_target_seconds',
        'max_chunk_seconds',
        'max_upload_bytes',
        'max_chunks',
      ]) {
        if (session[field] is! int || (session[field] as int) <= 0) {
          throw const FormatException('Missing audio limits');
        }
      }
      journal.data.addAll({
        'id': session['id'],
        'limits': session,
        'phase': 'prepared',
      });
      journal.saveSync();
    }
  }

  Future<void> initialize() async {
    await journal.load();
    if (journal.data.isEmpty || journal.data['id'] == null) {
      emit();
      return;
    }
    final limits = journal.data['limits'] as Json;
    writer = PcmChunkWriter(
      journal,
      targetSeconds: limits['chunk_target_seconds'] as int,
      maxSeconds: limits['max_chunk_seconds'] as int,
      maxBytes: limits['max_upload_bytes'] as int,
      maxChunks: limits['max_chunks'] as int,
    );
    if (['recording', 'paused', 'stopping'].contains(phase)) {
      writer!.recover();
      journal.data['phase'] = 'interrupted';
      journal.data['message'] = 'Запись была прервана. Сохранённое аудио восстановлено; микрофон сейчас выключен.';
      log('recovery_interrupted');
      save();
    } else if (phase == 'prepared') {
      if (allowCapture) {
        await startCapture();
      } else {
        journal.data['phase'] = 'interrupted';
        journal.data['message'] = 'Запись не была запущена. Микрофон выключен.';
        save();
      }
    }
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      emit();
      unawaited(sync());
    });
    unawaited(sync());
    emit();
  }

  Future<void> startCapture() async {
    if (writer!.atLimit) throw StateError('Session limit');
    if (!await recorder.allowed()) {
      throw StateError('Microphone permission');
    }
    _states ??= recorder.states.listen(
      (state) {
        if (_stopping || _disposed || _command) return;
        if (state == RecordState.pause && phase == 'recording') {
          journal.data['phase'] = 'paused';
          journal.data['message'] = 'Запись приостановлена. Нажмите «Продолжить», когда микрофон снова доступен.';
          log('microphone_interruption');
          save();
        } else if (state == RecordState.stop &&
            ['recording', 'paused'].contains(phase)) {
          unawaited(stop(interrupted: true));
        }
      },
      onError: (Object _) {
        unawaited(stop(interrupted: true));
      },
    );
    final stream = await recorder.start();
    _streamDone = Completer<void>();
    _stream = stream.listen(
      (bytes) {
        if (_captureFailed) return;
        try {
          final previous = journal.chunks.length;
          if (!writer!.add(bytes)) {
            journal.data['message'] = 'Достигнут предел длительности одной встречи на сервере. Запись остановлена и сохранена.';
            unawaited(stop());
          }
          if (previous != journal.chunks.length) {
            log('chunk_closed');
            emit();
            unawaited(sync());
          }
        } catch (_) {
          _captureFailed = true;
          journal.data['message'] = 'Не удалось записать аудио на устройство. Запись остановлена; сохранённые файлы не удалены.';
          unawaited(stop(interrupted: true));
        }
      },
      onDone: () {
        if (!_streamDone!.isCompleted) _streamDone!.complete();
      },
      onError: (Object _) {
        unawaited(stop(interrupted: true));
      },
    );
    journal.data['phase'] = 'recording';
    journal.data.remove('message');
    log('start');
    save();
  }

  Future<void> pause() async {
    if (_command || phase != 'recording') return;
    _command = true;
    try {
      await recorder.pause();
      writer!.flush();
      journal.data['phase'] = 'paused';
      log('pause');
      save();
    } finally {
      _command = false;
    }
  }

  Future<void> resume() async {
    if (_command || phase != 'paused') return;
    _command = true;
    try {
      await recorder.resume();
      journal.data['phase'] = 'recording';
      journal.data.remove('message');
      log('resume');
      save();
    } finally {
      _command = false;
    }
  }

  Future<void> stop({bool interrupted = false}) async {
    if (_stopping || !['recording', 'paused', 'prepared'].contains(phase)) {
      return;
    }
    _stopping = true;
    try {
      journal.data['phase'] = 'stopping';
      try {
        save();
      } catch (_) {
        emit();
      }
      await recorder.stop();
      if (_streamDone != null) {
        await _streamDone!.future.timeout(const Duration(seconds: 5));
      }
      writer!.closeChunk();
      journal.data['phase'] = interrupted ? 'interrupted' : 'sending';
      if (interrupted) {
        journal.data['message'] ??=
            'Запись прервана. Сохранённое аудио доступно для отправки.';
      }
      log(interrupted ? 'interrupted' : 'stop');
      save();
      unawaited(sync());
    } catch (_) {
      journal.data['phase'] = 'interrupted';
      journal.data['message'] = 'Запись остановлена. Не удалось завершить сохранение на устройстве. Освободите место и повторно откройте запись; файлы не удалены.';
      try {
        writer?.release();
      } catch (_) {
        /* Keep the repairable file. */
      }
      try {
        journal.saveSync();
      } catch (_) {
        /* Recovery uses the existing file length. */
      }
      emit();
    } finally {
      _stopping = false;
    }
  }

  Future<void> finishRecovered() async {
    if (phase != 'interrupted') return;
    journal.data['phase'] = 'sending';
    journal.data.remove('message');
    save();
    unawaited(sync(force: true));
  }

  Future<void> sync({bool force = false}) async {
    if (_disposed ||
        ['completed', 'done'].contains(phase) ||
        _syncing ||
        journal.data['id'] == null ||
        (!force &&
            (journal.data['blocked'] == true ||
                DateTime.now().isBefore(_nextAttempt)))) {
      return;
    }
    _syncing = true;
    _idle = Completer<void>();
    if (force) journal.data.remove('blocked');
    try {
      final id = journal.data['id'] as String;
      for (final chunk in List<Json>.of(journal.chunks)) {
        if (chunk['acked'] == true) {
          final acknowledged = journal.chunkFile(chunk['sequence'] as int);
          if (await acknowledged.exists()) await acknowledged.delete();
          continue;
        }
        final file = journal.chunkFile(chunk['sequence'] as int);
        final hash = (await sha256.bind(file.openRead()).first).toString();
        log('upload_start sequence=${chunk['sequence']}');
        if (_disposed) return;
        final response = await api.upload(id, file, chunk, hash);
        if (_disposed) return;
        final accepted = response['chunk'] as Json?;
        if (response['accepted'] != true ||
            response['safe_to_delete_local'] != true ||
            accepted?['sha256'] != hash ||
            accepted?['sequence_number'] != chunk['sequence']) {
          throw const ApiException(
            'audio_ack',
            'Сервер не подтвердил сохранение аудио. Файл оставлен на устройстве.',
          );
        }
        chunk['acked'] = true;
        try {
          save();
        } catch (_) {
          chunk['acked'] = false;
          rethrow;
        } // Publish ACK before deletion.
        await file.delete();
        log('upload_ack sequence=${chunk['sequence']}');
      }
      if (phase == 'sending' &&
          journal.chunks.isNotEmpty &&
          journal.chunks.every((c) => c['acked'] == true)) {
        final session = await api.json(
          'POST',
          '/$id/complete',
          body: {'expected_chunk_count': journal.chunks.length},
        );
        if (_disposed) return;
        journal.data['session'] = session;
        journal.data['phase'] = 'transcribing';
        save();
        log('complete_ack');
      }
      if (['transcribing', 'review', 'completed', 'failed'].contains(phase)) {
        final session = await api.json('GET', '/$id');
        if (_disposed) return;
        final previousPhase = phase;
        journal.data['session'] = session;
        journal.data['phase'] = switch (session['status']) {
          'ready_for_review' => 'review',
          'completed' => 'completed',
          'failed' => 'failed',
          _ => 'transcribing',
        };
        if (previousPhase != phase) log('asr_state $phase');
        save();
      }
      if (_failures > 0) log('network_restored');
      _failures = 0;
      journal.data.remove('network_error');
      journal.data.remove('upload_error');
      save();
    } catch (e) {
      if (_disposed) return;
      _failures++;
      _nextAttempt = DateTime.now().add(
        Duration(seconds: min(60, 2 << min(_failures, 5))),
      );
      final transient =
          e is ApiException && (e.isNetwork || (e.statusCode ?? 0) >= 500);
      journal.data['network_error'] = transient;
      journal.data['upload_error'] = 'Запись сохранена на устройстве. Отправим её, когда соединение восстановится';
      if (!transient) {
        journal.data['blocked'] = true;
        journal.data['upload_error'] = 'Не удалось отправить запись. Аудио сохранено на устройстве. Повторите отправку.';
      }
      log('upload_retry transient=$transient');
      try {
        save();
      } catch (_) {
        journal.data['message'] = 'Не удалось сохранить состояние записи. Освободите место на устройстве; аудио не удалено.';
        emit();
      }
    } finally {
      _syncing = false;
      _idle?.complete();
      emit();
    }
  }

  Future<void> markDone() async {
    await _idle?.future;
    if (!['review', 'completed'].contains(phase) && journal.chunks.isNotEmpty) {
      return;
    }
    journal.data['phase'] = 'done';
    journal.data.remove('session');
    journal.data.remove('parameters');
    save();
  }

  Future<void> retryAsr() async {
    if (_syncing) return;
    try {
      await api.json('POST', '/${journal.data['id']}/retry', body: {});
      await sync(force: true);
    } catch (_) {
      journal.data['message'] =
          'Распознавание пока недоступно. Запись сохранена.';
      emit();
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    api.close();
    await _idle?.future;
    await _states?.cancel();
    await _stream?.cancel();
    await recorder.dispose();
    writer?.release();
  }
}

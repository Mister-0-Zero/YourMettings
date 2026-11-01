import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:queue_owner/queue_owner.dart';
import 'package:record/record.dart';

import '../../features/recording/microphone_capture.dart';
import '../../features/recording/audio_meter.dart';
import '../../models/api_models.dart';
import 'draft_record.dart';
import 'draft_repository.dart';
import 'queue_journal.dart';

/// Local storage profile, independent of server limits/capability cache.
/// Source is append-only PCM16 little endian, mono, 16 kHz. Remote WAVs are
/// derived later under negotiated limits, never by changing this source.
class LocalAudioCapture {
  LocalAudioCapture({
    required this.repository,
    required this.localId,
    required this.authority,
    required this.microphone,
    this.changed,
    this.meterChanged,
    this.maxSeconds = 4 * 60 * 60,
  }) {
    if (repository.authority != authority || maxSeconds < 1) {
      throw ArgumentError('Capture authority/limit');
    }
  }
  static const bytesPerSecond = 32000;
  final LocalDraftRepository repository;
  final QueueAudioAuthority authority;
  final String localId;
  final MicrophoneCapture microphone;
  final void Function(Json snapshot)? changed;
  final void Function(List<AudioPeak>)? meterChanged;
  final _meter = AudioMeter();
  final int maxSeconds;
  File get source =>
      File('${repository.draftDirectory(localId).path}/source.pcm');
  int _bytes = 0;
  String _phase = 'draft';
  String? _error;
  bool _closing = false, _disposed = false;
  int _buffered = 0;
  StreamSubscription<Uint8List>? _stream;
  StreamSubscription<RecordState>? _states;
  Future<void> _pcmTail = Future.value(), _commandTail = Future.value();
  Json get snapshot => {
    'local_id': localId,
    'phase': _phase,
    'duration_ms': _bytes * 1000 ~/ bytesPerSecond,
    'byte_count': _bytes,
    if (_error != null) 'error_code': _error,
  };
  void _emit() {
    if (!_disposed) changed?.call(snapshot);
  }

  Future<void> _command(Future<void> Function() action) {
    final future = _commandTail.then((_) => action());
    _commandTail = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return future;
  }

  Future<void> _checkpoint(String phase) async {
    final current = await repository.read(localId);
    await repository.update(
      localId,
      expectedRevision: current.revision,
      change: (json) {
        if (phase == 'capturing' &&
            ((json['checkpoints'] as Json)['wire_plan'] != null ||
                (json['requests'] as Json).isNotEmpty)) {
          throw StateError('Draft became frozen before capture started');
        }
        json['state'] = phase;
        (json['checkpoints'] as Json)['capture'] = {
          'format': 'pcm_s16le',
          'sample_rate': 16000,
          'channels': 1,
          'byte_count': _bytes,
          'local_max_seconds': maxSeconds,
          if (_error != null) 'error_code': _error,
        };
      },
    );
    _phase = phase;
    _emit();
  }

  /// Invoked after an explicit foreground permission/start action. No HTTP.
  Future<void> start() => _command(() async {
    if (_disposed || _stream != null) {
      throw StateError('Capture already started');
    }
    final current = await repository.read(localId);
    if (current.kind != LocalDraftKind.audio ||
        current.requests.isNotEmpty ||
        (current.toJson()['checkpoints'] as Json)['wire_plan'] != null ||
        !['draft', 'interrupted'].contains(current.toJson()['state'])) {
      throw StateError('Draft is not available for capture');
    }
    _bytes = await source.exists() ? await source.length() : 0;
    if (_bytes.isOdd) {
      throw const FormatException('Incomplete PCM sample; source preserved');
    }
    if (_bytes >= maxSeconds * bytesPerSecond) {
      throw StateError('Local capture limit');
    }
    if (!await microphone.allowed()) {
      throw StateError('Microphone permission required');
    }
    if (authority is QueueOwnerLease &&
        await (authority as QueueOwnerLease).availableBytes() <
            2 * 1024 * 1024) {
      throw const QueueStorageFailure();
    }
    _error = null;
    await _checkpoint('capturing'); // Durable identity before microphone opens.
    try {
      _states ??= microphone.states.listen((state) {
        if (_closing || _disposed) return;
        if (state == RecordState.pause && _phase == 'recording') {
          unawaited(_command(() => _checkpoint('paused')));
        } else if (state == RecordState.stop && _phase == 'recording') {
          unawaited(stop(interrupted: true));
        }
      });
      final stream = await microphone.start();
      await _checkpoint('recording');
      _stream = stream.listen(
        _receive,
        onError: (Object _) => _fail('microphone_failed'),
        onDone: () {
          if (!_closing) _fail('microphone_interrupted');
        },
      );
    } catch (_) {
      await microphone.stop();
      _error = 'microphone_start_failed';
      await _checkpoint('interrupted');
      rethrow;
    }
  });

  void _fail(String code) {
    _error ??= code;
    if (!_closing && !_disposed) {
      unawaited(
        stop(interrupted: true).catchError((Object _) {
          // A failed checkpoint must not claim success. The last committed manifest
          // and append-only source remain recoverable on the next foreground open.
          _phase = 'interrupted';
          _emit();
        }),
      );
    }
  }

  void _receive(Uint8List bytes) {
    if (_closing || _disposed || _error != null) return;
    // Bounded backlog. Native source writes flush before ACK, not before mic IO.
    if (bytes.length.isOdd || _buffered + bytes.length > 2 * 1024 * 1024) {
      _fail('capture_backlog');
      return;
    }
    final stable = Uint8List.fromList(bytes);
    final peaks = _meter.add(stable);
    if (peaks.isNotEmpty) meterChanged?.call(peaks);
    _buffered += stable.length;
    _pcmTail = _pcmTail
        .then((_) async {
          if (_error != null) return;
          for (var offset = 0; offset < stable.length; offset += 65536) {
            final end = (offset + 65536).clamp(0, stable.length);
            final block = Uint8List.sublistView(stable, offset, end);
            if (_bytes + block.length > maxSeconds * bytesPerSecond) {
              _fail('local_capture_limit');
              return;
            }
            _bytes = await authority.serialized(
              () => authority.appendPcm(source, _bytes, block),
            );
          }
          _emit();
        })
        .catchError((Object _) {
          _fail('local_audio_write_failed');
        })
        .whenComplete(() => _buffered -= stable.length);
  }

  Future<void> saveSettings(
    LocalDraftInput input,
    bool autoStart,
    String originalFingerprint,
  ) => _command(() async {
    final current = await repository.read(localId);
    if (draftInputFingerprint(current.input) != originalFingerprint) {
      throw const DraftRevisionConflict();
    }
    await repository.update(
      localId,
      expectedRevision: current.revision,
      change: (j) {
        j['input'] = input.toJson();
        j['auto_start_when_online'] = autoStart;
      },
    );
  });
  Future<void> finishIntent() => _command(() async {
    final current = await repository.read(localId);
    if (current.toJson()['state'] != 'ready') return;
    await QueueJournal(
      repository,
      localId,
    ).status('ready', fields: {'online_finish_pending': true});
  });

  Future<void> pause() => _command(() async {
    if (_phase != 'recording') return;
    await microphone.pause();
    await _pcmTail;
    await _checkpoint('paused');
  });
  Future<void> resume() => _command(() async {
    if (_phase != 'paused' || _error != null) return;
    await microphone.resume();
    await _checkpoint('recording');
  });
  Future<void> stop({bool interrupted = false}) => _command(() async {
    if (_closing || _disposed) return;
    _closing = true;
    try {
      await microphone.stop();
      await _stream?.cancel();
      _stream = null;
      await _pcmTail;
      await _checkpoint(
        interrupted || _error != null ? 'interrupted' : 'ready',
      );
    } finally {
      _closing = false;
    }
  });
  Future<void> dispose() async {
    if (_disposed) return;
    if (_stream != null) await stop(interrupted: true);
    await _commandTail;
    await _pcmTail;
    await _states?.cancel();
    await microphone.dispose();
    _disposed = true;
    // Lifetime lease belongs to the dispatcher, which drains capture/HTTP first.
  }

  /// Never resumes the microphone after process death.
  static Future<LocalDraftRecord> recover(
    LocalDraftRepository repository,
    String id,
  ) async {
    final record = await repository.read(id);
    if (![
      'recording',
      'paused',
      'capturing',
    ].contains(record.toJson()['state'])) {
      return record;
    }
    final source = File('${repository.draftDirectory(id).path}/source.pcm');
    final bytes = await source.exists() ? await source.length() : 0;
    if (bytes.isOdd) {
      throw const FormatException('Incomplete PCM sample; source preserved');
    }
    return repository.update(
      id,
      expectedRevision: record.revision,
      change: (json) {
        json['state'] = 'interrupted';
        (json['checkpoints'] as Json)['capture'] = {
          'format': 'pcm_s16le',
          'sample_rate': 16000,
          'channels': 1,
          'byte_count': bytes,
          'error_code': 'process_interrupted',
        };
      },
    );
  }
}

import 'dart:typed_data';

import 'package:record/record.dart';

abstract class MicrophoneCapture {
  Future<bool> allowed();
  Stream<RecordState> get states;
  Future<Stream<Uint8List>> start();
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> dispose();
}

class RecordMicrophone implements MicrophoneCapture {
  RecordMicrophone({this.permissionCheckedInForeground = false});
  final bool permissionCheckedInForeground;
  AudioRecorder? _recorder;
  AudioRecorder get recorder => _recorder ??= AudioRecorder();
  @override
  Future<bool> allowed() async =>
      permissionCheckedInForeground ||
      await recorder.hasPermission(request: false);
  @override
  Stream<RecordState> get states => recorder.onStateChanged();
  @override
  Future<Stream<Uint8List>> start() async {
    var invalid = false;
    await recorder.setOnConfigChanged((config) {
      if (config.sampleRate != 16000 ||
          config.numChannels != 1 ||
          config.encoder != AudioEncoder.pcm16bits) {
        // Refuse incorrect sample metadata instead of uploading mis-timed audio.
        invalid = true;
      }
    });
    final stream = await recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        streamBufferSize: 3200,
        audioInterruption: AudioInterruptionMode.pause,
        iosConfig: IosRecordConfig(
          categoryOptions: [IosAudioCategoryOption.mixWithOthers],
        ),
      ),
    );
    return stream.map((data) {
      if (invalid) throw StateError('Unsupported microphone PCM configuration');
      return data;
    });
  }

  @override
  Future<void> pause() => recorder.pause();
  @override
  Future<void> resume() => recorder.resume();
  @override
  Future<void> stop() async {
    await _recorder?.stop();
  }

  @override
  Future<void> dispose() async {
    await _recorder?.dispose();
  }
}

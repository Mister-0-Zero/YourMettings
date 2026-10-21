import 'dart:io';
import 'dart:typed_data';

import '../../models/api_models.dart';
import 'audio_journal.dart';

/// PCM16 mono 16kHz. Splits samples, never restarts the microphone. The active
/// file has a repairable WAV header; its actual length is the recovery authority.
class PcmChunkWriter {
  PcmChunkWriter(
    this.journal, {
    required this.targetSeconds,
    required this.maxSeconds,
    required this.maxBytes,
    required this.maxChunks,
  });
  static const rate = 16000;
  static const bytesPerSecond = rate * 2;
  final AudioJournal journal;
  final int targetSeconds, maxSeconds, maxBytes, maxChunks;
  RandomAccessFile? _file;
  int _bytes = 0, _silence = 0, _syncBytes = 0;
  int? _odd;
  int get sequence => journal.chunks.length;
  int get elapsedMs =>
      (journal.data['closed_ms'] as int? ?? 0) +
      _bytes * 1000 ~/ bytesPerSecond;
  int get hardBytes =>
      ((maxBytes - 44) ~/ 2 * 2).clamp(0, maxSeconds * bytesPerSecond);
  bool get atLimit => sequence >= maxChunks;

  static Uint8List header(int bytes) {
    final result = Uint8List(44);
    final b = ByteData.sublistView(result);
    void ascii(int offset, String text) {
      result.setAll(offset, text.codeUnits);
    }

    ascii(0, 'RIFF');
    b.setUint32(4, bytes + 36, Endian.little);
    ascii(8, 'WAVEfmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little);
    b.setUint16(22, 1, Endian.little);
    b.setUint32(24, rate, Endian.little);
    b.setUint32(28, bytesPerSecond, Endian.little);
    b.setUint16(32, 2, Endian.little);
    b.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    b.setUint32(40, bytes, Endian.little);
    return result;
  }

  void recover() {
    if (atLimit) return;
    final active = journal.chunkFile(sequence);
    if (!active.existsSync()) return;
    _bytes = ((active.lengthSync() - 44).clamp(0, hardBytes) ~/ 2) * 2;
    if (_bytes == 0) {
      active.deleteSync();
      return;
    }
    _file = active.openSync(mode: FileMode.append);
    _file!.truncateSync(44 + _bytes);
    closeChunk();
  }

  /// Returns false only at the server's session limit; caller stops capture.
  bool add(Uint8List input) {
    var bytes = input;
    if (_odd != null) {
      bytes = Uint8List.fromList([_odd!, ...input]);
      _odd = null;
    }
    if (bytes.length.isOdd) {
      _odd = bytes.last;
      bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
    }
    var offset = 0;
    while (offset < bytes.length) {
      if (atLimit) return false;
      _file ??= journal.chunkFile(sequence).openSync(mode: FileMode.write)
        ..writeFromSync(header(0));
      // Scan small frames to find >=400ms quiet near the target, bounded by
      // hard duration/size. All samples on either side go to exactly one file.
      final remaining = bytes.length - offset;
      final count = remaining.clamp(0, (hardBytes - _bytes).clamp(0, 640));
      if (count == 0) {
        closeChunk();
        continue;
      }
      final frame = Uint8List.sublistView(bytes, offset, offset + count);
      final data = ByteData.sublistView(frame);
      var peak = 0;
      for (var i = 0; i < frame.length; i += 2) {
        final level = data.getInt16(i, Endian.little).abs();
        if (level > peak) peak = level;
      }
      _silence = peak < 320 ? _silence + count : 0;
      _file!.writeFromSync(frame);
      _bytes += count;
      _syncBytes += count;
      offset += count;
      if (_syncBytes >= bytesPerSecond) {
        _file!.flushSync();
        _syncBytes = 0;
      }
      if (_bytes >= hardBytes ||
          (_bytes >= targetSeconds * bytesPerSecond && _silence >= 12800)) {
        closeChunk();
      }
    }
    return true;
  }

  void flush() {
    _file?.flushSync();
  }

  void closeChunk() {
    if (_file == null || _bytes == 0) return;
    _file!.setPositionSync(0);
    _file!.writeFromSync(header(_bytes));
    _file!.flushSync();
    _file!.closeSync();
    _file = null;
    final start = journal.data['closed_ms'] as int? ?? 0;
    final duration = _bytes * 1000 ~/ bytesPerSecond;
    final Json chunk = {
      'sequence': sequence,
      'start_ms': start,
      'duration_ms': duration,
      'acked': false,
    };
    journal.chunks.add(chunk);
    journal.data['closed_ms'] = start + duration;
    journal
        .saveSync(); // File is durable BEFORE it is published to upload queue.
    _bytes = 0;
    _silence = 0;
    _syncBytes = 0;
  }
}

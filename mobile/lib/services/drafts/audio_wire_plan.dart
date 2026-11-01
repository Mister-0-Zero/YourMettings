import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:queue_owner/queue_owner.dart';

import '../../features/recording/pcm_chunk_writer.dart';
import '../../models/api_models.dart';
import 'draft_record.dart';
import 'draft_repository.dart';

class AudioWireLimits {
  AudioWireLimits.fromJson(Json json)
    : targetSeconds = json['chunk_target_seconds'] as int,
      maxSeconds = json['max_chunk_seconds'] as int,
      maxBytes = json['max_upload_bytes'] as int,
      maxChunks = json['max_chunks'] as int {
    if (targetSeconds < 1 ||
        maxSeconds < targetSeconds ||
        maxBytes < 76 ||
        maxChunks < 1 ||
        maxChunks > 240) {
      throw const FormatException('Unsupported server audio limits');
    }
  }
  final int targetSeconds, maxSeconds, maxBytes, maxChunks;
  Json toJson() => {
    'chunk_target_seconds': targetSeconds,
    'max_chunk_seconds': maxSeconds,
    'max_upload_bytes': maxBytes,
    'max_chunks': maxChunks,
  };
}

/// Called only after capture stops. A committed wire plan is never resegmented:
/// the first upload may have reached the server even when its ACK was lost.
class AudioWirePlanner {
  AudioWirePlanner(this.repository, this.authority, {this.checkpoint}) {
    if (repository.authority != authority) throw ArgumentError('Wire owner');
  }
  final LocalDraftRepository repository;
  final QueueAudioAuthority authority;
  final Future<void> Function()? checkpoint;
  Future<void> _check() async {
    await checkpoint?.call();
  }

  Future<String> _hash(File file) async {
    final stream = file.openRead().asyncMap((bytes) async {
      await _check();
      return bytes;
    });
    return (await sha256.bind(stream).first).toString();
  }

  static const bytesPerSecond = 32000;
  File file(String id, int sequence, {required String planId}) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(planId)) {
      throw const FormatException('Invalid wire plan identity');
    }
    return File(
      '${repository.draftDirectory(id).path}/wire-$planId-${sequence.toString().padLeft(6, '0')}.wav',
    );
  }

  Future<Json> prepare(String id, AudioWireLimits limits) async {
    await _check();
    var record = await repository.read(id);
    final existing =
        (record.toJson()['checkpoints'] as Json)['wire_plan'] as Json?;
    if (existing != null) {
      await verify(id, existing);
      return existing;
    }
    if (record.kind != LocalDraftKind.audio ||
        [
          'draft',
          'recording',
          'paused',
          'capturing',
        ].contains(record.toJson()['state'])) {
      throw StateError('Capture must finish before wire planning');
    }
    final source = File('${repository.draftDirectory(id).path}/source.pcm');
    final length = await source.length();
    // Each duration/start is exact to integer milliseconds; last sub-ms samples
    // are retained, with <1ms rounding error accepted by the backend contract.
    if (length < 32 || length.isOdd) {
      throw const FormatException('Empty/incomplete PCM');
    }
    final sourceSha = await _hash(source);
    final planId = sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'version': 1,
              'source_sha256': sourceSha,
              'source_bytes': length,
              'limits': limits.toJson(),
            }),
          ),
        )
        .toString();
    final hard = math.min(
      limits.maxSeconds * bytesPerSecond,
      (limits.maxBytes - 44) ~/ 2 * 2,
    );
    final target = math.min(hard, limits.targetSeconds * bytesPerSecond);
    if (hard < 32) throw const FormatException('Server chunk size too small');
    final spans = await _spans(source, length, target, hard);
    if (spans.length > limits.maxChunks) {
      throw StateError(
        'Recording exceeds server chunk capacity; source preserved',
      );
    }
    final chunks = <Json>[];
    final input = await source.open();
    try {
      for (var i = 0; i < spans.length; i++) {
        await _check();
        final (start, end) = spans[i];
        final size = end - start;
        final bytes = Uint8List(44 + size);
        bytes.setRange(0, 44, PcmChunkWriter.header(size));
        await input.setPosition(start);
        var read = 0;
        while (read < size) {
          await _check();
          final part = await input.readInto(bytes, 44 + read);
          if (part == 0) {
            throw const FileSystemException('PCM source shortened');
          }
          read += part;
        }
        final hash = sha256.convert(bytes).toString();
        final targetFile = file(id, i, planId: planId);
        if (await targetFile.exists()) {
          // A crash before plan commit can leave complete immutable files.
          // Reuse only byte-identical files; never overwrite a published WAV.
          if (await targetFile.length() != bytes.length ||
              await _hash(targetFile) != hash) {
            throw const FormatException('Existing immutable wire bytes differ');
          }
        } else {
          await authority.serialized(
            () => authority.writeAudio(targetFile, bytes),
          );
        }

        chunks.add({
          'sequence': i,
          'start_ms': start * 1000 ~/ bytesPerSecond,
          'duration_ms':
              (end * 1000 ~/ bytesPerSecond) - (start * 1000 ~/ bytesPerSecond),
          'byte_count': bytes.length,
          'sha256': hash,
          'source_start': start,
          'source_end': end,
        });
      }
    } finally {
      await input.close();
    }
    if (await source.length() != length || await _hash(source) != sourceSha) {
      throw StateError('Source changed during planning');
    }
    final plan = <String, dynamic>{
      'version': 1,
      'plan_id': planId,
      'format': 'wav_pcm_s16le',
      'sample_rate': 16000,
      'channels': 1,
      'source_bytes': length,
      'source_sha256': sourceSha,
      'limits': limits.toJson(),
      'chunks': chunks,
    };
    record = await repository.read(id);
    if ([
      'recording',
      'paused',
      'capturing',
    ].contains(record.toJson()['state'])) {
      throw StateError('Capture resumed during wire preparation');
    }
    if ((record.toJson()['checkpoints'] as Json)['wire_plan'] != null) {
      throw const DraftRevisionConflict();
    }
    await repository.update(
      id,
      expectedRevision: record.revision,
      change: (json) {
        (json['checkpoints'] as Json)['wire_plan'] = plan;
      },
    );
    // Only a committed plan may be used for HTTP; leftovers before commit can
    // safely be deterministically recreated because no upload has been allowed.
    return plan;
  }

  Future<List<(int, int)>> _spans(
    File source,
    int length,
    int target,
    int hard,
  ) async {
    final result = <(int, int)>[];
    final input = await source.open();
    var start = 0, position = 0, silence = 0;
    try {
      while (position < length) {
        await _check();
        final block = await input.read(math.min(65536, length - position));
        if (block.isEmpty || block.length.isOdd) {
          throw const FormatException('PCM source truncated');
        }
        final data = ByteData.sublistView(block);
        for (var offset = 0; offset < block.length; offset += 2) {
          final amplitude = data.getInt16(offset, Endian.little).abs();
          silence = amplitude < 320 ? silence + 2 : 0;
          position += 2;
          if (position - start >= hard ||
              (position - start >= target && silence >= 12800)) {
            result.add((start, position));
            start = position;
            silence = 0;
          }
        }
      }
      if (position > start) {
        // Preserve even a short final tail. Tiny final tails are folded into the
        // preceding span if possible rather than creating a zero-duration chunk.
        if (position - start < 32 &&
            result.isNotEmpty &&
            position - result.last.$1 <= hard) {
          result[result.length - 1] = (result.last.$1, position);
        } else if (position - start < 32) {
          // Rebalance one millisecond from previous chunk, preserving all samples.
          final previous = result.removeLast();
          if (start - previous.$1 < 64) {
            throw const FormatException(
              'Chunk limit cannot hold all PCM samples',
            );
          }
          result.add((previous.$1, start - 32));
          result.add((start - 32, position));
        } else {
          result.add((start, position));
        }
      }
      return result;
    } finally {
      await input.close();
    }
  }

  Future<void> verify(String id, Json plan) async {
    if (plan['version'] != 1 || plan['format'] != 'wav_pcm_s16le') {
      throw const FormatException('Unknown wire plan');
    }
    var expected = 0, end = 0;
    for (final entry in (plan['chunks'] as List).cast<Json>()) {
      await _check();
      final chunk = file(
        id,
        entry['sequence'] as int,
        planId: plan['plan_id'] as String,
      );
      if (entry['sequence'] != expected++ ||
          entry['source_start'] != end ||
          await chunk.length() != entry['byte_count'] ||
          await _hash(chunk) != entry['sha256']) {
        throw const FormatException(
          'Frozen audio bytes changed; source preserved',
        );
      }
      end = entry['source_end'] as int;
    }
    if (expected == 0 || end != plan['source_bytes']) {
      throw const FormatException('Wire coverage');
    }
  }
}

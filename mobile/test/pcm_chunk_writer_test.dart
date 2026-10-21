import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:your_mettings/features/recording/audio_journal.dart';
import 'package:your_mettings/features/recording/pcm_chunk_writer.dart';

void main() {
  late Directory dir;
  late AudioJournal journal;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('yourmettings-pcm-');
    journal = AudioJournal(dir)
      ..data = {
        'version': 1,
        'chunks': <Map<String, dynamic>>[],
        'closed_ms': 0,
      };
  });
  tearDown(() => dir.deleteSync(recursive: true));
  PcmChunkWriter writer({int count = 240}) => PcmChunkWriter(
    journal,
    targetSeconds: 1,
    maxSeconds: 2,
    maxBytes: 200000,
    maxChunks: count,
  );
  test('sample-exact continuity across boundaries and odd buffers', () {
    final pcm = Uint8List.fromList(
      List.generate(160003, (i) => (i * 37) % 256),
    );
    final w = writer();
    for (var i = 0; i < pcm.length; i += 777) {
      w.add(Uint8List.sublistView(pcm, i, (i + 777).clamp(0, pcm.length)));
    }
    w.closeChunk();
    final output = BytesBuilder();
    for (final chunk in journal.chunks) {
      final bytes = journal
          .chunkFile(chunk['sequence'] as int)
          .readAsBytesSync();
      expect(
        ByteData.sublistView(bytes).getUint32(40, Endian.little),
        bytes.length - 44,
      );
      output.add(bytes.sublist(44));
    }
    expect(output.takeBytes(), pcm.sublist(0, pcm.length - 1));
    expect(journal.chunks.length, 3);
    expect(journal.chunks[1]['start_ms'], 2000);
  });
  test('quiet boundary near target; repair unfinalized WAV', () {
    final w = writer();
    w.add(Uint8List(32000));
    expect(journal.chunks.length, 1);
    journal.chunkFile(1).writeAsBytesSync([
      ...PcmChunkWriter.header(0),
      ...Uint8List(22000),
    ], flush: true);
    final recovery = writer();
    recovery.recover();
    expect(journal.chunks.length, 2);
    expect(journal.data['closed_ms'], 1687);
  });
  test('pauses retain current chunk; session limit stops safely', () {
    final w = writer(count: 1);
    for (var i = 0; i < 10; i++) {
      w.add(Uint8List(320));
      w.flush();
    }
    expect(journal.chunks, isEmpty);
    expect(w.add(Uint8List(64000)), false);
    expect(journal.chunks.length, 1);
  });
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:your_mettings/features/recording/audio_meter.dart';

void main() {
  test(
    '40 ms real PCM extrema preserve polarity across arbitrary buffer splits',
    () {
      final bytes = Uint8List(640 * 2 * 3);
      final data = ByteData.sublistView(bytes);
      data.setInt16(0, -16000, Endian.little);
      data.setInt16(200, 8000, Endian.little);
      data.setInt16(2560, 32000, Endian.little);
      final before = Uint8List.fromList(bytes);
      final meter = AudioMeter();
      final peaks = <AudioPeak>[];
      for (var i = 0; i < bytes.length; i += 137) {
        peaks.addAll(
          meter.add(
            Uint8List.sublistView(bytes, i, (i + 137).clamp(0, bytes.length)),
          ),
        );
      }
      expect(peaks.length, 3);
      expect(peaks.first.low, -16000 / 32768);
      expect(peaks.first.high, 8000 / 32768);
      expect(peaks[1].low, 0);
      expect(peaks[1].high, 0);
      expect(peaks[2].high, 32000 / 32768);
      expect(bytes, before);
    },
  );
  test(
    'wave history uses measured extrema, retains silence and bounds backlog',
    () {
      final history = WaveformHistory();
      history.add([
        const AudioPeak(-0.7, 0.3),
        AudioPeak.silence,
        const AudioPeak(-0.1, 0.9),
      ]);
      history.advance(0.12);
      expect(history.peaks.length, WaveformHistory.capacity);
      expect(history.peaks[history.peaks.length - 3].low, -0.7);
      expect(history.peaks[history.peaks.length - 2].high, 0);
      expect(history.peaks.last.high, 0.9);
      history.add(List.generate(1000, (i) => AudioPeak(0, i / 1000)));
      history.advance(0.4);
      expect(history.peaks.last.high, 0.999);
      history.suspend();
      final last = history.peaks.last;
      history.advance(10);
      expect(history.peaks.last, same(last));
    },
  );
}

import 'dart:typed_data';
import 'dart:collection';
import 'dart:math' as math;

/// Display-only extrema. No PCM or waveform history is persisted.
class AudioPeak {
  const AudioPeak(this.low, this.high);
  static const silence = AudioPeak(0, 0);
  final double low, high;
}

/// 40 ms windows from the existing PCM stream; never changes captured bytes.
class AudioMeter {
  static const samplesPerPeak = 640; // PCM16 mono, 16 kHz.
  int _samples = 0, _low = 0, _high = 0;
  int? _odd;
  List<AudioPeak> add(Uint8List input) {
    final peaks = <AudioPeak>[];
    var offset = 0;
    void sample(int value) {
      if (value < _low) _low = value;
      if (value > _high) _high = value;
      if (++_samples == samplesPerPeak) {
        peaks.add(AudioPeak(_low / 32768, _high / 32768));
        _samples = 0;
        _low = _high = 0;
      }
    }

    if (_odd != null && input.isNotEmpty) {
      final value = _odd! | (input[0] << 8);
      sample(value >= 32768 ? value - 65536 : value);
      _odd = null;
      offset = 1;
    }
    final data = ByteData.sublistView(input);
    while (offset + 1 < input.length) {
      sample(data.getInt16(offset, Endian.little));
      offset += 2;
    }
    if (offset < input.length) _odd = input[offset];
    return peaks;
  }
}

/// Bounded display history: 1.92 s, plus at most 400 ms of pending telemetry.
class WaveformHistory {
  static const capacity = 48;
  final peaks = List<AudioPeak>.filled(
    capacity,
    AudioPeak.silence,
    growable: true,
  );
  final _pending = Queue<AudioPeak>();
  double _position = 0;
  double get scrollFraction => _pending.isEmpty ? 0 : _position;
  AudioPeak get next => _pending.isEmpty ? peaks.last : _pending.first;
  void add(List<AudioPeak> samples) {
    _pending.addAll(samples);
    while (_pending.length > 10) {
      _pending.removeFirst();
    }
  }

  void advance(double seconds) {
    _position += seconds / 0.04;
    while (_position + 1e-9 >= 1 && _pending.isNotEmpty) {
      peaks.removeAt(0);
      peaks.add(_pending.removeFirst());
      _position = math.max(0, _position - 1);
    }
    if (_pending.isEmpty) _position = math.min(_position, 1);
  }

  void suspend() {
    _pending.clear();
    _position = 0;
  }
}

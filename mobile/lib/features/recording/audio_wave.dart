import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'audio_meter.dart';

/// Recent microphone extrema, scrolled at their actual 40 ms sample interval.
class AudioWave extends StatefulWidget {
  const AudioWave({
    super.key,
    required this.samples,
    required this.active,
    this.onVisibilityChanged,
  });
  final ValueListenable<List<AudioPeak>> samples;
  final bool active;
  final ValueChanged<bool>? onVisibilityChanged;
  @override
  State<AudioWave> createState() => _AudioWaveState();
}

class _AudioWaveState extends State<AudioWave>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..addListener(_tick);
  final _history = WaveformHistory();
  Duration _last = Duration.zero;
  bool _foreground = true, _visible = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.samples.addListener(_samples);
  }

  void _samples() {
    if (_visible) _history.add(widget.samples.value);
  }

  void _tick() {
    final elapsed = _motion.lastElapsedDuration ?? Duration.zero;
    final dt = ((elapsed - _last).inMicroseconds / 1000000).clamp(0.0, 0.05);
    _last = elapsed;
    _history.advance(dt);
  }

  void _update() {
    final visible =
        widget.active && _foreground && TickerMode.valuesOf(context).enabled;
    if (visible != _visible) {
      _visible = visible;
      widget.onVisibilityChanged?.call(visible);
    }
    if (visible) {
      if (!_motion.isAnimating) {
        _last = Duration.zero;
        _motion.repeat();
      }
    } else {
      _motion.stop();
      _history.suspend();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _update();
  }

  @override
  void didUpdateWidget(covariant AudioWave old) {
    super.didUpdateWidget(old);
    if (old.samples != widget.samples) {
      old.samples.removeListener(_samples);
      widget.samples.addListener(_samples);
    }
    _update();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _update();
  }

  @override
  void dispose() {
    widget.samples.removeListener(_samples);
    if (_visible) widget.onVisibilityChanged?.call(false);
    WidgetsBinding.instance.removeObserver(this);
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Уровень микрофона',
    child: RepaintBoundary(
      child: SizedBox(
        height: 88,
        width: double.infinity,
        child: CustomPaint(
          painter: _WavePainter(
            _motion,
            _history,
            widget.active
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline,
          ),
        ),
      ),
    ),
  );
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.motion, this.history, this.color) : super(repaint: motion);
  final Animation<double> motion;
  final WaveformHistory history;
  final Color color;
  double _height(double value, double height) {
    // Perceptual display gain only. Quiet speech remains visible; PCM is intact.
    if (value <= 0.001) return 0.5;
    final normal = ((20 * math.log(value) / math.ln10 + 60) / 60).clamp(
      0.0,
      1.0,
    );
    return 0.5 + math.pow(normal, 0.65) * height * 0.44;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final step = size.width / WaveformHistory.capacity;
    final points = <Offset>[];
    final peaks = [...history.peaks, history.next];
    for (var i = 0; i < peaks.length; i++) {
      final x = (i - history.scrollFraction) * step;
      points.add(
        Offset(
          x + step * 0.25,
          size.height / 2 - _height(peaks[i].high, size.height),
        ),
      );
      points.add(
        Offset(
          x + step * 0.75,
          size.height / 2 + _height(-peaks[i].low, size.height),
        ),
      );
    }
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      final previous = points[i - 1];
      final next = points[i];
      final rounding = (next.dx - previous.dx) * 0.25;
      path.cubicTo(
        previous.dx + rounding,
        previous.dy,
        next.dx - rounding,
        next.dy,
        next.dx,
        next.dy,
      );
    }
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.color != color || old.history != history;
}

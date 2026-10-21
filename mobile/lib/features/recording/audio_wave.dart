import 'dart:math' as math;

import 'package:flutter/material.dart';

/// UI-only animation. Capture and upload never depend on this widget's ticker.
class AudioWave extends StatefulWidget {
  const AudioWave({super.key, required this.level, required this.active});
  final double level;
  final bool active;
  @override
  State<AudioWave> createState() => _AudioWaveState();
}

class _AudioWaveState extends State<AudioWave>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..addListener(_tick);
  double _amplitude = 0;
  Duration _last = Duration.zero;
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _tick() {
    final elapsed = _motion.lastElapsedDuration ?? Duration.zero;
    final dt = ((elapsed - _last).inMicroseconds / 1000000).clamp(0.0, 0.05);
    _last = elapsed;
    final target = widget.active ? widget.level.clamp(0.0, 1.0) : 0.0;
    _amplitude += (target - _amplitude) * (1 - math.exp(-dt / 0.22));
  }

  void _update() {
    if (widget.active && _foreground && TickerMode.valuesOf(context).enabled) {
      if (!_motion.isAnimating) {
        _last = Duration.zero;
        _motion.repeat();
      }
    } else {
      _motion.stop();
      if (!widget.active) _amplitude = 0;
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
    _update();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _update();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Уровень микрофона',
    child: SizedBox(
      height: 64,
      width: double.infinity,
      child: CustomPaint(
        painter: _WavePainter(
          _motion,
          () => _amplitude,
          widget.active
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outline,
        ),
      ),
    ),
  );
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.motion, this.amplitude, this.color)
    : super(repaint: motion);
  final Animation<double> motion;
  final double Function() amplitude;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final path = Path();
    final phase = motion.value * 2 * math.pi;
    final height = 3 + amplitude() * size.height * 0.34;
    for (var i = 0; i <= 120; i++) {
      final t = i / 120;
      final envelope = math.pow(math.sin(math.pi * t), 1.2);
      final y =
          size.height / 2 +
          height *
              envelope *
              (math.sin(t * math.pi * 5 - phase) +
                  0.2 * math.sin(t * math.pi * 9 + phase));
      if (i == 0) {
        path.moveTo(0, y);
      } else {
        path.lineTo(size.width * t, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.color != color || old.amplitude != amplitude;
}

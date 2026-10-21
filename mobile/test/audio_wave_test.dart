import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:your_mettings/features/recording/audio_wave.dart';
import 'package:your_mettings/features/recording/audio_meter.dart';

void main() {
  testWidgets(
    'quiet line becomes a tall irregular waveform from real extrema',
    (tester) async {
      final samples = ValueNotifier<List<AudioPeak>>([]);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox(
                width: 360,
                height: 88,
                child: AudioWave(samples: samples, active: true),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      Future<int> paintedHeight() async {
        final image = await boundary.toImage();
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        var top = image.height, bottom = 0;
        for (var y = 0; y < image.height; y++) {
          for (var x = 0; x < image.width; x++) {
            if (bytes.getUint8((y * image.width + x) * 4 + 3) > 20) {
              if (y < top) top = y;
              if (y > bottom) bottom = y;
            }
          }
        }
        image.dispose();
        return bottom - top + 1;
      }

      final quiet = await tester.runAsync(paintedHeight);
      for (var i = 0; i < 24; i++) {
        samples.value = [
          AudioPeak(
            -[0.001, 0.06, 0.6, 0.12][i % 4],
            [0.05, 0.5, 0.1, 0.8][i % 4],
          ),
          AudioPeak(-[0.4, 0.008, 0.03][i % 3], [0.02, 0.3, 0.08][i % 3]),
        ];
        for (var step = 0; step < 5; step++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }
      final loud = await tester.runAsync(paintedHeight);
      expect(quiet, lessThan(8));
      expect(loud, greaterThan(60));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await Directory('build/device-check').create(recursive: true);
        await File('build/device-check/ui-wave-preview.png')
            .writeAsBytes(png.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
      samples.dispose();
    },
  );
  testWidgets('wave ticks only during visible foreground recording', (
    tester,
  ) async {
    final meter = ValueNotifier<List<AudioPeak>>([]);
    final visibilityChanges = <bool>[];
    addTearDown(meter.dispose);
    Future<void> show({bool active = true, bool visible = true}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TickerMode(
            enabled: visible,
            child: AudioWave(
              samples: meter,
              active: active,
              onVisibilityChanged: visibilityChanges.add,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    await show();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await show(active: false);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    await show();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.transientCallbackCount, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await show(visible: false);
    expect(tester.binding.transientCallbackCount, 0);
    expect(visibilityChanges, [true, false, true, false, true, false]);
    expect(tester.takeException(), isNull);
  });
}

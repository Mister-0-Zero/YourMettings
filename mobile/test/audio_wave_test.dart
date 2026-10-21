import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:your_mettings/features/recording/audio_wave.dart';

void main() {
  testWidgets('wave ticks only during visible foreground recording', (
    tester,
  ) async {
    Future<void> show({bool active = true, bool visible = true}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TickerMode(
            enabled: visible,
            child: AudioWave(level: 0.8, active: active),
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
    expect(tester.takeException(), isNull);
  });
}

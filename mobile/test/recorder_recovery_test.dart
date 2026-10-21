import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:your_mettings/features/recording/recorder_coordinator.dart';

class AndroidCoordinator extends RecorderCoordinator {
  @override
  bool get usesAndroidService => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_foreground_task/methods');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'isRunningService') return true;
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('unknown recorder state cannot acknowledge a draft handoff', () async {
    final recorder = RecorderCoordinator();
    await expectLater(recorder.releaseReview('A'), throwsStateError);
    recorder.dispose();
  });

  testWidgets(
    'startup waits for a live service snapshot, ignoring meter packets',
    (tester) async {
      final recorder = AndroidCoordinator();
      var ready = false;
      final initialization = recorder.initialize().then((_) => ready = true);
      await tester.pump();
      expect(ready, false);
      // Use the plugin callback transport; no service state is guessed locally.
      for (final callback in FlutterForegroundTask.dataCallbacks.toList()) {
        callback({'meter': <List<double>>[]});
      }
      await tester.pump(const Duration(seconds: 3));
      expect(ready, false);
      for (final callback in FlutterForegroundTask.dataCallbacks.toList()) {
        callback({'id': 'A', 'phase': 'review'});
      }
      await tester.pump();
      await initialization;
      expect(ready, true);
      expect(recorder.state['id'], 'A');
      recorder.dispose();
    },
  );

  testWidgets(
    'missing snapshot fails safely and initialization can be retried',
    (tester) async {
      final recorder = AndroidCoordinator();
      final first = expectLater(recorder.initialize(), throwsStateError);
      await tester.pump();
      await tester.pump(const Duration(seconds: 16));
      await first;
      await expectLater(recorder.releaseReview('A'), throwsStateError);
      final retry = recorder.initialize();
      await tester.pump();
      expect(FlutterForegroundTask.dataCallbacks.length, 1);
      for (final callback in FlutterForegroundTask.dataCallbacks.toList()) {
        callback({'id': 'B', 'phase': 'recording'});
      }
      await tester.pump();
      await retry;
      expect(recorder.state['id'], 'B');
      recorder.dispose();
    },
  );
}

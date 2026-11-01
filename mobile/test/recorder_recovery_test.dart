import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:your_mettings/features/recording/recorder_coordinator.dart';

class AndroidCoordinator extends RecorderCoordinator {
  AndroidCoordinator({super.directory});
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
  testWidgets('new local FGS protocol never becomes the legacy journal owner', (
    tester,
  ) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('ym-protocol-recovery-'),
    ))!;
    await tester.runAsync(() async {
      final active = Directory('${directory.path}/active-audio');
      await active.create();
      await File('${active.path}/session.json')
          .writeAsString(jsonEncode({'version': 1, 'phase': 'done'}));
    });
    final recorder = AndroidCoordinator(directory: directory);
    var ready = false;
    final initialization = recorder.initialize().then((_) => ready = true);
    await tester.pump();
    for (final callback in FlutterForegroundTask.dataCallbacks.toList()) {
      callback({
        'queue_protocol': 2,
        'scope_id': 'other-scope',
        'local_id': 'new-local-id',
        'service_instance': 'new-instance',
        'phase': 'recording',
      });
    }
    for (var n = 0; n < 30 && !ready; n++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(ready, isTrue);
    await initialization;
    expect(recorder.phase, 'done');
    expect(recorder.state['id'], isNot('new-local-id'));
    expect(recorder.state.containsKey('queue_protocol'), isFalse);
    recorder.dispose();
    await tester.runAsync(() => directory.delete(recursive: true));
  });
}

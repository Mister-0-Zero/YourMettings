import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:queue_owner/queue_owner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final scope = List.filled(64, 'a').join();
  String? held;
  var generation = 0;
  setUp(() {
    held = null;
    generation = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeQueueOwner.channel, (call) async {
          switch (call.method) {
            case 'acquire':
              if (held != null) return null;
              return held = 'owner-${++generation}';
            case 'publish':
              if (held != call.arguments['token']) {
                throw PlatformException(code: 'owner_unavailable');
              }
              await File(call.arguments['temporary'] as String)
                  .rename(call.arguments['path'] as String);
              return null;
            case 'valid':
              return held == call.arguments['token'];
            case 'release':
              if (held != call.arguments['token']) return false;
              held = null;
              return true;
            default:
              throw StateError('Unexpected method');
          }
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeQueueOwner.channel, null),
  );

  test(
    'close drains in-flight mutation before releasing and denies new writes',
    () async {
      final first = (await NativeQueueOwner.acquire(scope))!;
      final pending = Completer<void>();
      final entered = Completer<void>();
      final write = first.serialized(() async {
        entered.complete();
        await pending.future;
      });
      await entered.future;
      final closing = first.close();
      expect(await NativeQueueOwner.acquire(scope), isNull);
      await expectLater(
        first.serialized(() async {}),
        throwsA(isA<QueueOwnerLost>()),
      );
      pending.complete();
      await write;
      await closing;
      final second = (await NativeQueueOwner.acquire(scope))!;
      await second.close();
    },
  );
  test(
    'writes are serialized and one failure does not poison the queue',
    () async {
      final lease = (await NativeQueueOwner.acquire(scope))!;
      final calls = <int>[];
      final first = lease.serialized(() async {
        calls.add(1);
        throw StateError('test storage failure');
      });
      final failed = expectLater(first, throwsStateError);
      final next = lease.serialized(() async {
        calls.add(2);
        return 42;
      });
      await failed;
      expect(await next, 42);
      expect(calls, [1, 2]);
      await lease.close();
    },
  );
  test('lost native ownership prevents an operation from starting', () async {
    final lease = (await NativeQueueOwner.acquire(scope))!;
    held = 'other-engine';
    var wrote = false;
    await expectLater(
      lease.serialized(() async => wrote = true),
      throwsA(isA<QueueOwnerLost>()),
    );
    expect(wrote, isFalse);
    await expectLater(lease.close(), throwsA(isA<QueueOwnerLost>()));
  });
  test('invalid scope is rejected before invoking native ownership', () async {
    await expectLater(NativeQueueOwner.acquire('../bad'), throwsArgumentError);
    expect(held, isNull);
  });
  test('stale owner may finish only its unique tmp; native publish cannot replace committed manifest', () async {
    final directory = await Directory.systemTemp.createTemp('ym-publish-');
    addTearDown(() => directory.delete(recursive: true));
    final target = File('${directory.path}/draft.json');
    final lease = (await NativeQueueOwner.acquire(scope))!;
    await lease.serialized(() => lease.writeSnapshot(target, '{"revision":1}'));
    await lease.serialized(() => lease.writeSnapshot(target, '{"revision":2}'));
    await lease.close();
    await expectLater(
      lease.writeSnapshot(target, '{"revision":-1}'),
      throwsA(isA<QueueOwnerLost>()),
    );
    expect(await target.readAsString(), '{"revision":2}');
    final pending = await directory
        .list()
        .where((entry) => entry.path.endsWith('.tmp'))
        .toList();
    expect(pending, hasLength(1));
  });
}

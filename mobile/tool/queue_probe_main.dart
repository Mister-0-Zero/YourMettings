// Device-only probe. Build in a separate dev.yourmettings.queue_probe app;
// never replace the user's YourMettings application with this entry point.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:queue_owner/queue_owner.dart';
import 'package:workmanager/workmanager.dart';

String? _foregroundMarker;
const _task = 'yourmettings.queue_probe';
String get _scope => sha256
    .convert(utf8.encode('YourMettings isolated queue probe v1'))
    .toString();
Future<void> _json(File file, Map<String, dynamic> value) async {
  await file.parent.create(recursive: true);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(jsonEncode(value), flush: true);
  await tmp.rename(file.path);
}

Future<bool> _worker(
  Map<String, dynamic> input,
  bool Function() stopped,
) async {
  final nonce = input['nonce'] as String;
  if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(nonce)) return true;
  final support = await getApplicationSupportDirectory();
  final root = Directory('${support.path}/queue-probe/$nonce');
  final lease = await NativeQueueOwner.acquire(_scope);
  if (lease == null) return false;
  try {
    return await lease.serialized(() async {
      const vault = FlutterSecureStorage(
        aOptions: AndroidOptions(
          storageNamespace: 'ym_isolated_probe',
          resetOnError: false,
        ),
      );
      var vaultOk = false;
      try {
        vaultOk = await vault.read(key: 'probe') == nonce;
      } finally {
        await vault.delete(key: 'probe');
      }
      final owned = File('${support.path}/scopes/$_scope/probe-manifest.json');
      await lease.writeSnapshot(owned, jsonEncode({'revision': 1}));
      await lease.writeSnapshot(owned, jsonEncode({'revision': 2}));
      final publishOk =
          (jsonDecode(await owned.readAsString()) as Map)['revision'] == 2;
      await _json(File('${root.path}/started.json'), {
        'headless': _foregroundMarker == null,
        'secure_storage': vaultOk,
        'owned_atomic_publish': publishOk,
      });
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (!await File('${root.path}/release.signal').exists()) {
        if (stopped() || DateTime.now().isAfter(deadline)) return false;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await _json(File('${root.path}/done.json'), {
        'headless': _foregroundMarker == null,
        'secure_storage': vaultOk,
        'owned_atomic_publish': publishOk,
      });
      return true;
    });
  } finally {
    await lease.close();
  }
}

@pragma('vm:entry-point')
void queueProbeDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  var stopped = false;
  Future<bool>? active;
  Workmanager().executeTask(
    (task, input) {
      if (task != _task || input == null) return Future.value(true);
      return active = _worker(input, () => stopped);
    },
    onTaskStopped: (_, _) async {
      stopped = true;
      try {
        await active;
      } catch (_) {
        /* Probe result records failure. */
      }
    },
  );
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _foregroundMarker = 'UI engine';
  runApp(const ProbeApp());
}

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});
  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> {
  String status = 'Проверка отдельной фоновой очереди…';
  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _wait(File file) async {
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (!await file.exists()) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('probe');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _run() async {
    final support = await getApplicationSupportDirectory();
    final nonce = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final root = Directory('${support.path}/queue-probe/$nonce');
    final unique = 'ym-queue-probe-$nonce';
    final result = <String, dynamic>{'probe': nonce};
    const vault = FlutterSecureStorage(
      aOptions: AndroidOptions(
        storageNamespace: 'ym_isolated_probe',
        resetOnError: false,
      ),
    );
    try {
      // Synthetic UI-written value must be readable by the separate headless
      // engine, as credentials will be in the actual queue (different namespace).
      await vault.write(key: 'probe', value: nonce);
      await Workmanager().initialize(queueProbeDispatcher);
      await Workmanager().registerOneOffTask(
        unique,
        _task,
        inputData: {'nonce': nonce},
        constraints: Constraints(networkType: NetworkType.notRequired),
        existingWorkPolicy: ExistingWorkPolicy.keep,
      );
      final started = File('${root.path}/started.json');
      await _wait(started);
      result.addAll(
        jsonDecode(await started.readAsString()) as Map<String, dynamic>,
      );
      final competing = await NativeQueueOwner.acquire(_scope);
      result['ui_excluded_while_worker_owns'] = competing == null;
      if (competing != null) await competing.close();
      await File('${root.path}/release.signal')
          .writeAsString('release', flush: true);
      await _wait(File('${root.path}/done.json'));
      NativeQueueLease? next;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (next == null && DateTime.now().isBefore(deadline)) {
        next = await NativeQueueOwner.acquire(_scope);
        if (next == null) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      result['ui_acquires_after_worker_drain'] = next != null;
      if (next != null) await next.close();
      result['passed'] = [
        'headless',
        'secure_storage',
        'ui_excluded_while_worker_owns',
        'ui_acquires_after_worker_drain',
        'owned_atomic_publish',
      ].every((name) => result[name] == true);
    } catch (error) {
      result['passed'] = false;
      result['error_type'] = error.runtimeType.toString();
    } finally {
      await Workmanager().cancelByUniqueName(unique);
      await vault.delete(key: 'probe');
      await _json(File('${support.path}/queue-probe-result.json'), result);
      if (mounted) setState(() => status = jsonEncode(result));
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('Queue probe — отдельное приложение')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: SelectableText(status),
      ),
    ),
  );
}

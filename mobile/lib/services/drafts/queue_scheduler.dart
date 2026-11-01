import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import '../../api/demo_connection.dart';
import '../../models/api_models.dart';
import '../demo_key_vault.dart';
import 'draft_access.dart';
import 'draft_record.dart';
import 'draft_repository.dart';
import 'draft_workspace.dart';
import 'queue_journal.dart';
import 'queue_runner.dart';

final _workerRuns = <String, DraftQueueRunner>{};

@pragma('vm:entry-point')
void draftQueueDispatcher() {
  Workmanager().executeTask(
    (task, data) async {
      final scope = data?['scope_id'];
      if (scope is! String ||
          !draftScopePattern.hasMatch(scope) ||
          data!.keys.any((key) => key != 'scope_id') ||
          task != 'draft-queue:$scope') {
        return true;
      }
      final support = await getApplicationSupportDirectory();
      final directory = Directory('${support.path}/scopes/$scope');
      DraftQueueRunner? runner;
      try {
        final file = File('${directory.path}/queue-binding.json');
        if (await FileSystemEntity.isLink(file.path)) return true;
        final json = jsonDecode(await file.readAsString()) as Json;
        final binding = DemoConnection.fromJson(
          json['connection'] as Json,
          const DeviceDemoKeyVault(),
        );
        if (json['schema'] != 1 ||
            json['scope_id'] != scope ||
            binding.scopeId != scope ||
            !await activeQueueScope(directory, binding)) {
          return true;
        }
        runner = DraftQueueRunner(directory: directory, connection: binding);
        // WorkManager may deliver another scoped job to this engine. No nested
        // ownership: native acquire is decisive; stopping is always scoped.
        if (_workerRuns.containsKey(scope)) return true;
        _workerRuns[scope] = runner;
        await runner.run();
        var delay = await nextQueueDelay(directory, scope);
        if (delay != null &&
            runner.ownerUnavailable &&
            delay < const Duration(seconds: 30)) {
          delay = const Duration(seconds: 30);
        }
        if (delay != null && await activeQueueScope(directory, binding)) {
          await scheduleDraftQueue(scope, delay: delay, append: true);
        }
        return true;
      } catch (_) {
        // Files/source survive. Periodic fallback retries local read/registration
        // failures; malformed identity never becomes an unscoped HTTP request.
        return true;
      } finally {
        await runner?.stop();
        if (identical(_workerRuns[scope], runner)) _workerRuns.remove(scope);
      }
    },
    onTaskStopped: (task, reason) async {
      final scope = task.startsWith('draft-queue:')
          ? task.substring('draft-queue:'.length)
          : '';
      await _workerRuns[scope]?.stop();
    },
  );
}

Future<void> initializeDraftQueue() async {
  if (Platform.isAndroid) await Workmanager().initialize(draftQueueDispatcher);
}

Future<void> scheduleDraftQueue(
  String scope, {
  Duration delay = Duration.zero,
  bool append = false,
}) async {
  if (!draftScopePattern.hasMatch(scope)) {
    throw ArgumentError('Queue job scope');
  }
  if (!Platform.isAndroid) return;
  await Workmanager().registerOneOffTask(
    'draft-queue:$scope',
    'draft-queue:$scope',
    inputData: {'scope_id': scope},
    initialDelay: delay,
    existingWorkPolicy: append
        ? ExistingWorkPolicy.update
        : ExistingWorkPolicy.keep,
    constraints: Constraints(networkType: NetworkType.notRequired),
    backoffPolicy: BackoffPolicy.exponential,
    backoffPolicyDelay: const Duration(seconds: 10),
    tag: 'draft-queue:$scope',
  );
}

Future<void> registerDraftQueueFallback(String scope) async {
  if (!Platform.isAndroid) return;
  await Workmanager().registerPeriodicTask(
    'draft-queue-fallback:$scope',
    'draft-queue:$scope',
    inputData: {'scope_id': scope},
    frequency: const Duration(minutes: 15),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    constraints: Constraints(networkType: NetworkType.notRequired),
    tag: 'draft-queue:$scope',
  );
}

Future<Duration?> nextQueueDelay(
  Directory directory,
  String scope, {
  DateTime? now,
}) async {
  final repository = LocalDraftRepository(
    scopeDirectory: directory,
    authority: ReadOnlyDraftAuthority(scope),
  );
  Duration? next;
  final clock = (now ?? DateTime.now()).toUtc();
  for (final record in (await repository.list()).items) {
    final queue = draftQueue(record);
    if (record.kind == LocalDraftKind.audio &&
        record.toJson()['state'] == 'draft') {
      continue;
    }
    if ([
      'recording',
      'capturing',
      'paused',
      'interrupted',
      'legacy_bridge',
      'migration_pending',
      'migration_prepared',
    ].contains(record.toJson()['state'])) {
      continue;
    }
    if (record.requests.isEmpty &&
        record.serverIds.isEmpty &&
        !record.autoStart &&
        queue['requested'] != true &&
        queue['online_finish_pending'] != true &&
        queue['command'] == null) {
      continue;
    }
    final due = DateTime.tryParse(queue['next_attempt_at'] as String? ?? '');
    if (!QueueRetryPolicy(now: () => clock)
        .due({...queue, 'next_attempt_at': null})) {
      continue;
    }
    final raw = due?.difference(clock) ?? Duration.zero;
    final delay = raw.isNegative ? Duration.zero : raw;
    if (next == null || delay < next) next = delay;
  }
  return next;
}

class DraftQueueCoordinator with WidgetsBindingObserver {
  DraftQueueCoordinator(this.workspace)
    : runner = DraftQueueRunner(
        directory: workspace.directory,
        connection: workspace.connection,
      );
  final DraftWorkspace workspace;
  final DraftQueueRunner runner;
  Timer? _timer;
  Future<void>? _waking;
  bool _closed = false, _foreground = true;
  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    workspace.wakeQueue = wake;
    try {
      await registerDraftQueueFallback(workspace.connection.scopeId);
    } catch (_) {
      workspace.reportQueueSchedulingError();
    }
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_foreground) unawaited(wake());
    });
    unawaited(wake());
  }

  Future<void> wake() {
    if (_closed) return Future.value();
    return _waking ??= _wake().whenComplete(() => _waking = null);
  }

  Future<void> _wake() async {
    try {
      if (_foreground) await runner.run();
      if (_closed) return;
      await workspace.reload();
      final delay = await nextQueueDelay(
        workspace.directory,
        workspace.connection.scopeId,
      );
      if (delay != null) {
        await scheduleDraftQueue(workspace.connection.scopeId, delay: delay);
      }
    } catch (_) {
      workspace.reportQueueSchedulingError();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      unawaited(wake());
    } else {
      unawaited(runner.stop());
    }
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    workspace.wakeQueue = null;
    WidgetsBinding.instance.removeObserver(this);
    await runner.stop();
    await _waking;
  }
}

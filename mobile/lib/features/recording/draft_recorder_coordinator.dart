import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:queue_owner/queue_owner.dart';
import 'package:record/record.dart';

import '../../api/demo_connection.dart';
import '../../models/api_models.dart';
import '../../models/summary_template.dart' show newSectionId;
import '../../services/demo_key_vault.dart';
import '../../services/drafts/draft_record.dart';
import '../../services/drafts/draft_repository.dart';
import '../../services/drafts/draft_workspace.dart';
import '../../services/drafts/local_audio_capture.dart';
import '../../services/drafts/queue_journal.dart';
import '../../services/drafts/queue_scheduler.dart';
import 'audio_meter.dart';
import 'microphone_capture.dart';

Future<bool> localCaptureServiceRunning() async =>
    await FlutterForegroundTask.isRunningService &&
    await NativeQueueOwner.captureTicket() != null;

@visibleForTesting
bool draftCaptureCommandMatches(
  Json command, {
  required String scope,
  required String localId,
  required String instance,
}) =>
    command['queue_protocol'] == 2 &&
    command['scope_id'] == scope &&
    command['local_id'] == localId &&
    command['service_instance'] == instance;

@pragma('vm:entry-point')
void localAudioTaskEntry() =>
    FlutterForegroundTask.setTaskHandler(_LocalAudioTask());

/// The FGS is the only writer during capture. UI releases the native scope
/// lease BEFORE starting it; commands are scoped to this launch/engine instance.
class _LocalAudioTask extends TaskHandler {
  QueueOwnerLease? _lease;
  LocalAudioCapture? _capture;
  String? _scope, _id, _nonce;
  final _instance = newSectionId();
  bool _finished = false, _meterEnabled = false, _releasing = false;
  String? _error;
  Future<void> _commands = Future.value();
  Json get _snapshot => {
    'queue_protocol': 2,
    'scope_id': _scope,
    'local_id': _id,
    'launch_nonce': _nonce,
    'service_instance': _instance,
    ...?_capture?.snapshot,
    if (_error != null) 'service_error': _error,
  };
  void _emit() => FlutterForegroundTask.sendDataToMain(_snapshot);
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      final ticket = await NativeQueueOwner.captureTicket();
      _scope = ticket?['scope'];
      _id = ticket?['local_id'];
      _nonce = ticket?['nonce'];
      if (_scope == null ||
          !draftScopePattern.hasMatch(_scope!) ||
          _id == null ||
          !localDraftIdPattern.hasMatch(_id!) ||
          _nonce == null ||
          !localDraftIdPattern.hasMatch(_nonce!)) {
        throw const FormatException('Capture launch identity');
      }
      final support = await getApplicationSupportDirectory();
      final directory = Directory('${support.path}/scopes/$_scope');
      final bindingFile = File('${directory.path}/queue-binding.json');
      if (await FileSystemEntity.isLink(directory.path) ||
          await FileSystemEntity.isLink(bindingFile.path)) {
        throw const FileSystemException('Capture binding is a link');
      }
      final raw = jsonDecode(await bindingFile.readAsString()) as Json;
      final binding = DemoConnection.fromJson(
        raw['connection'] as Json,
        const DeviceDemoKeyVault(),
      );
      if (raw['schema'] != 1 ||
          raw['scope_id'] != _scope ||
          binding.scopeId != _scope) {
        throw const FormatException('Capture scope differs');
      }
      _lease = await NativeQueueOwner.acquire(_scope!);
      if (_lease == null) throw const QueueOwnerLost();
      final repo = LocalDraftRepository(
        scopeDirectory: directory,
        authority: _lease!,
      );
      var record = await repo.read(_id!);
      final intent =
          (record.toJson()['checkpoints'] as Json)['capture_launch'] as Json?;
      if (starter != TaskStarter.developer ||
          intent?['nonce'] != _nonce ||
          intent?['consumed'] != false) {
        await LocalAudioCapture.recover(repo, _id!);
        throw StateError('An explicit foreground launch is required');
      }
      record = await repo.update(
        _id!,
        expectedRevision: record.revision,
        change: (json) {
          ((json['checkpoints'] as Json)['capture_launch'] as Json).addAll({
            'consumed': true,
            'service_instance': _instance,
          });
        },
      );
      _capture = LocalAudioCapture(
        repository: repo,
        localId: _id!,
        authority: _lease!,
        microphone: RecordMicrophone(permissionCheckedInForeground: true),
        changed: (_) => _emit(),
        meterChanged: (peaks) {
          if (_meterEnabled) {
            FlutterForegroundTask.sendDataToMain({
              'queue_protocol': 2,
              'scope_id': _scope,
              'local_id': _id,
              'service_instance': _instance,
              'meter': [
                for (final peak in peaks) [peak.low, peak.high],
              ],
            });
          }
        },
      );
      await _capture!.start();
      _emit();
    } catch (_) {
      _error = 'Не удалось включить микрофон. Черновик и сохранённое аудио не удалены.';
      _emit();
      await _release(interrupted: true);
      _finished = true;
      unawaited(FlutterForegroundTask.stopService());
    }
  }

  @override
  void onReceiveData(Object value) {
    if (value == 'snapshot') {
      _emit();
      return;
    }
    if (value is! Map) return;
    final data = Map<String, dynamic>.from(value);
    if (data['queue_protocol'] != 2 || data['scope_id'] != _scope) return;
    if (data['query'] == 'snapshot') {
      _emit();
      return;
    }
    if (!draftCaptureCommandMatches(
      data,
      scope: _scope!,
      localId: _id!,
      instance: _instance,
    )) {
      return;
    }
    final task = _commands.then((_) => _command(data));
    _commands = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }

  Future<void> _command(Json data) async {
    var ok = false;
    try {
      switch (data['command']) {
        case 'pause':
          await _capture?.pause();
        case 'resume':
          await _capture?.resume();
        case 'meter':
          _meterEnabled = data['enabled'] == true;
        case 'settings':
          await _capture?.saveSettings(
            LocalDraftInput.fromJson(data['input'] as Json),
            data['auto_start'] == true,
            data['original_fingerprint'] as String,
          );
        case 'stop':
          await _capture?.stop();
          await _capture?.finishIntent();
          await _release(interrupted: false);
          _finished = true;
        default:
          throw StateError('Unknown capture command');
      }
      ok = true;
      _emit();
      if (!_finished) {
        await FlutterForegroundTask.updateService(
          notificationTitle: 'YourMettings',
          notificationText: _capture?.snapshot['phase'] == 'paused'
              ? 'Запись приостановлена'
              : 'Идёт запись совещания',
        );
      }
    } catch (_) {
      _error = 'Не удалось выполнить действие. Сохранённое аудио осталось на устройстве.';
    }
    FlutterForegroundTask.sendDataToMain({
      ..._snapshot,
      'command_reply': data['request'],
      'ok': ok,
    });
    if (_finished) {
      try {
        await scheduleDraftQueue(_scope!);
      } catch (_) {
        /* Foreground/resume retries scheduling. */
      }
      unawaited(FlutterForegroundTask.stopService());
    }
  }

  Future<void> _release({required bool interrupted}) async {
    if (_lease == null) return;
    try {
      if (interrupted) await _capture?.stop(interrupted: true);
      await _capture?.dispose();
    } finally {
      try {
        if (_nonce != null) await _lease?.clearCaptureTicket(_nonce!);
      } finally {
        await _lease?.close();
        _lease = null;
      }
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _emit();
    if (_capture?.snapshot['phase'] == 'interrupted' &&
        !_finished &&
        !_releasing) {
      _releasing = true;
      final task = _commands.then((_) async {
        await _release(interrupted: true);
        _finished = true;
        unawaited(FlutterForegroundTask.stopService());
      });
      _commands = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _commands;
    await _release(interrupted: true);
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();
}

class DraftRecorderCoordinator extends ChangeNotifier
    with WidgetsBindingObserver {
  DraftRecorderCoordinator(this.workspace);
  final DraftWorkspace workspace;
  Json state = {};
  String? error;
  bool busy = false, _closed = false, _meterVisible = false;
  Timer? _watch;
  bool _watching = false, _visible = true;
  bool get _canObserve => _visible && !_closed && !busy;
  Future<void>? _foregroundTask, _restoringTask, _closing;
  final meter = ValueNotifier<List<AudioPeak>>([]);
  final _replies = <int, Completer<bool>>{};
  int _request = 0;
  String? get localId => state['local_id'] as String?;
  String get phase => state['phase'] as String? ?? 'draft';
  bool get recording => ['recording', 'paused', 'capturing'].contains(phase);
  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> initialize() async {
    final binding = WidgetsBinding.instance;
    _visible =
        (binding.lifecycleState ?? AppLifecycleState.resumed) ==
        AppLifecycleState.resumed;
    binding.addObserver(this);
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.addTaskDataCallback(_receive);
    await _restoreForeground();
    _watch = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_watching || !_canObserve) return;
      _watching = true;
      try {
        await _restoreForeground();
      } finally {
        _watching = false;
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    if (_canObserve) unawaited(_restoreForeground());
  }

  Future<void> _restoreForeground() => _restoringTask ??= _doRestoreForeground()
      .whenComplete(() => _restoringTask = null);
  Future<void> _doRestoreForeground() async {
    try {
      await foreground();
    } catch (_) {
      error = 'Не удалось проверить диктофон. Локальные черновики доступны; повторите восстановление.';
      await workspace.reload();
      _notify();
    }
  }

  Future<void> foreground() {
    if (!_canObserve) return Future.value();
    return _foregroundTask ??= _readForeground().whenComplete(
      () => _foregroundTask = null,
    );
  }

  Future<void> _readForeground() async {
    if (!_canObserve) return;
    final serviceRunning = await localCaptureServiceRunning();
    if (!_canObserve) return;
    if (serviceRunning) {
      final serviceScope = (await NativeQueueOwner.captureTicket())?['scope'];
      if (!_canObserve) return;
      if (serviceScope != workspace.connection.scopeId) {
        error = 'Микрофон используется другим подключением. Сначала завершите ту запись.';
        _notify();
        return;
      }
      FlutterForegroundTask.sendDataToTask({
        'queue_protocol': 2,
        'scope_id': workspace.connection.scopeId,
        'query': 'snapshot',
      });
    } else {
      try {
        final ticket = await NativeQueueOwner.captureTicket();
        final needsRecovery =
            ticket?['scope'] == workspace.connection.scopeId ||
            (await workspace.reader.list()).items.any(_hasInterruptedCapture);
        if (!_canObserve) return;
        if (needsRecovery) {
          // The passive UI must not interrupt uploads or polling in another
          // engine. Explicit start/settings actions still request handoff.
          await workspace.withOwner((repo, lease) async {
            if (!_canObserve || await localCaptureServiceRunning()) return;
            if (!_canObserve) return;
            for (final record in (await repo.list()).items) {
              if (!_canObserve) return;
              if (_hasInterruptedCapture(record)) {
                await LocalAudioCapture.recover(repo, record.localId);
              }
            }
            final current = await NativeQueueOwner.captureTicket();
            if (_canObserve &&
                current?['scope'] == workspace.connection.scopeId &&
                current?['nonce'] != null &&
                current?['nonce'] == ticket?['nonce']) {
              await lease.clearCaptureTicket(current!['nonce']!);
            }
          }, requestHandoff: false);
        }
      } on QueueOwnerLost {
        /* A concurrent worker owns recovery. */
      } catch (_) {
        error = 'Не удалось восстановить запись. Файлы сохранены.';
      }
      if (recording && localId != null) {
        try {
          final record = await workspace.reader.read(localId!);
          state = {
            'local_id': record.localId,
            'phase': record.toJson()['state'],
          };
        } catch (_) {
          /* Preserve last UI state rather than claiming success. */
        }
      }
    }
    await workspace.reload();
    _notify();
  }

  bool _hasInterruptedCapture(LocalDraftRecord record) =>
      ['recording', 'paused', 'capturing'].contains(record.toJson()['state']);

  void _receive(Object value) {
    if (_closed ||
        value is! Map ||
        value['queue_protocol'] != 2 ||
        value['scope_id'] != workspace.connection.scopeId) {
      return;
    }
    final data = Map<String, dynamic>.from(value);
    if (localId != null && data['local_id'] != localId) return;
    if (state['launch_nonce'] != null &&
        data['launch_nonce'] != null &&
        data['launch_nonce'] != state['launch_nonce']) {
      return;
    }
    final known = state['service_instance'];
    if (known != null && data['service_instance'] != known) return;
    if (data['meter'] is List) {
      if (_meterVisible) {
        meter.value = [
          for (final pair in data['meter'] as List)
            AudioPeak((pair[0] as num).toDouble(), (pair[1] as num).toDouble()),
        ];
      }
      return;
    }
    state = data;
    if (known == null && _meterVisible) {
      unawaited(command('meter', enabled: true));
    }
    if (data['service_error'] is String) {
      error = data['service_error'] as String;
    }
    if (data['command_reply'] is int) {
      _replies.remove(data['command_reply'])?.complete(data['ok'] == true);
    }
    _notify();
  }

  void setMeterVisible(bool visible) {
    _meterVisible = visible;
    if (!visible) meter.value = [];
    if (state['service_instance'] != null) {
      unawaited(command('meter', enabled: visible));
    }
  }

  Future<LocalDraftRecord?> start({String? resumeId}) async {
    if (busy || _closed) return null;
    busy = true;
    error = null;
    _notify();
    try {
      if (await FlutterForegroundTask.isRunningService) {
        throw StateError('Microphone service already active');
      }
      final permission = AudioRecorder();
      final allowed = await permission.hasPermission();
      await permission.dispose();
      if (!allowed) throw StateError('Microphone permission denied');
      if (await FlutterForegroundTask.checkNotificationPermission() !=
              NotificationPermission.granted &&
          await FlutterForegroundTask.requestNotificationPermission() !=
              NotificationPermission.granted) {
        throw StateError('Notification permission denied');
      }
      final nonce = newSectionId();
      final record = await workspace.withOwner<LocalDraftRecord>((
        repo,
        lease,
      ) async {
        var item = resumeId == null
            ? await repo.create(
                LocalDraftRecord.create(
                  scopeId: workspace.connection.scopeId,
                  kind: LocalDraftKind.audio,
                  input: LocalDraftInput(
                    title:
                        'Совещание ${DateTime.now().toLocal().toString().substring(0, 16)}',
                  ),
                ),
              )
            : await repo.read(resumeId);
        if (item.kind != LocalDraftKind.audio ||
            item.requests.isNotEmpty ||
            (item.toJson()['checkpoints'] as Json)['wire_plan'] != null ||
            !['draft', 'interrupted'].contains(item.toJson()['state'])) {
          throw StateError('Draft cannot resume capture');
        }
        item = await repo.update(
          item.localId,
          expectedRevision: item.revision,
          change: (j) {
            (j['checkpoints'] as Json)['capture_launch'] = {
              'nonce': nonce,
              'consumed': false,
            };
          },
        );
        await lease.saveCaptureTicket(item.localId, nonce);
        return item;
      }); // Native lease released here; task acquires it before mic opens.
      state = {
        'local_id': record.localId,
        'phase': 'capturing',
        'launch_nonce': nonce,
      };
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'meeting_recording',
          channelName: 'Запись совещания',
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(1000),
          autoRunOnBoot: false,
          autoRunOnMyPackageReplaced: false,
          allowAutoRestart: false,
          allowWakeLock: true,
          stopWithTask: false,
        ),
      );
      final response = await FlutterForegroundTask.startService(
        serviceId: 410,
        serviceTypes: [ForegroundServiceTypes.microphone],
        notificationTitle: 'YourMettings',
        notificationText: 'Идёт запись совещания',
        callback: localAudioTaskEntry,
      );
      if (response is ServiceRequestFailure) {
        throw StateError('Foreground start rejected');
      }
      _notify();
      await workspace.reload();
      return record;
    } catch (_) {
      error = 'Не удалось начать запись. Проверьте разрешения микрофона и уведомлений. Сохранённые черновики не удалены.';
      await foreground();
      return null;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<bool> command(String command, {bool? enabled, Json? payload}) async {
    if (_closed || state['service_instance'] == null) return false;
    final id = ++_request, reply = Completer<bool>();
    _replies[id] = reply;
    FlutterForegroundTask.sendDataToTask({
      'queue_protocol': 2,
      'scope_id': workspace.connection.scopeId,
      'local_id': localId,
      'service_instance': state['service_instance'],
      'command': command,
      'request': id,
      'enabled': ?enabled,
      ...?payload,
    });
    try {
      final ok = await reply.future.timeout(const Duration(seconds: 15));
      if (!ok) {
        error =
            'Действие не завершено. Сохранённое аудио осталось на устройстве.';
      }
      if (command == 'stop') {
        await workspace.reload();
        unawaited(workspace.wakeQueue?.call());
      }
      _notify();
      return ok;
    } catch (_) {
      error = 'Ответ диктофона пока не получен. Не начинайте новую запись до проверки состояния.';
      _notify();
      return false;
    } finally {
      _replies.remove(id);
    }
  }

  Future<LocalDraftRecord> saveSettings(
    LocalDraftRecord original,
    LocalDraftInput input,
    bool autoStart,
  ) async {
    if (original.localId != localId || !recording) {
      throw StateError('Capture differs');
    }
    final ok = await command(
      'settings',
      payload: {
        'input': input.toJson(),
        'auto_start': autoStart,
        'original_fingerprint': draftInputFingerprint(original.input),
      },
    );
    if (!ok) throw const QueueStorageFailure();
    return workspace.reader.read(original.localId);
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    WidgetsBinding.instance.removeObserver(this);
    _watch?.cancel();
    FlutterForegroundTask.removeTaskDataCallback(_receive);
    // Closing an Activity does not stop the foreground microphone service.
    _closed = true;
    for (final reply in _replies.values) {
      if (!reply.isCompleted) reply.complete(false);
    }
    _replies.clear();
    try {
      await _foregroundTask;
      await _restoringTask;
    } catch (_) {
      /* Restore error remains local. */
    }
  }

  @override
  void dispose() {
    unawaited(close());
    meter.dispose();
    super.dispose();
  }
}

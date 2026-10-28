import '../../services/audio_draft_store.dart';

import 'dart:math';

import '../../api/api_error.dart';
import '../../api/demo_connection.dart';
import '../../services/recorder_context.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../app/config.dart';
import '../../models/api_models.dart';
import 'audio_api.dart';
import 'audio_meter.dart';
import 'audio_engine.dart';
import 'audio_journal.dart';
import 'microphone_capture.dart';

@pragma('vm:entry-point')
void audioTaskEntry() => FlutterForegroundTask.setTaskHandler(_AudioTask());

Future<AudioJournal> openAudioJournal({Directory? directory}) async {
  if (directory != null) {
    return AudioJournal(Directory('${directory.path}/active-audio'));
  }
  final support = await getApplicationSupportDirectory();
  return AudioJournal(Directory('${support.path}/active-audio'));
}

Future<bool> _maintenanceRequired(Directory? root, String? id) async {
  if (root == null || id == null) return false;
  final repository = AudioDraftRepository(
    file: File('${root.path}/audio-drafts.json'),
  );
  try {
    await repository.load();
    final entry = repository[id];
    return entry != null &&
        (entry.handoff || entry.deletePending || entry.serverDeleted);
  } finally {
    repository.dispose();
  }
}

@visibleForTesting
bool recorderCommandMatches(
  Map data, {
  required String scope,
  required String instance,
  required String sessionId,
}) =>
    data['connection_scope'] == scope &&
    data['service_instance'] == instance &&
    data['session_id'] == sessionId;

class _AudioTask extends TaskHandler {
  AudioEngine? engine;
  late String _scope, _owner;
  final _instance =
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  Json _snapshot() => {
    ...engine!.snapshot,
    'connection_scope': _scope,
    'owner_session_id': _owner,
    'service_instance': _instance,
  };
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final context = await readRecorderContext();
    final journal = await openAudioJournal(directory: context.directory);
    await journal.load();
    _scope = context.connection.scopeId;
    _owner = journal.data['id'] as String;
    engine = AudioEngine(
      journal,
      AudioApi(context.connection.base, connection: context.connection),
      changed: (value) => FlutterForegroundTask.sendDataToMain({
        ...value,
        'connection_scope': _scope,
        'owner_session_id': _owner,
        'service_instance': _instance,
      }),
      meterChanged: (peaks) => FlutterForegroundTask.sendDataToMain({
        'meter': [
          for (final peak in peaks) [peak.low, peak.high],
        ],
      }),
      maintenanceRequired: () =>
          _maintenanceRequired(context.directory, _owner),
      // record_android 2.2 requires an Activity even for a permission CHECK.
      // Permission was requested by UI; Android enforces it when starting this
      // microphone FGS and again when opening AudioRecord. No permission bypass.
      capture: RecordMicrophone(permissionCheckedInForeground: true),
    );
    try {
      await engine!.initialize();
    } catch (e) {
      debugPrint('Audio: capture_start_failed type=${e.runtimeType}');
      journal.data['phase'] = 'interrupted';
      journal.data['message'] =
          'Не удалось включить микрофон. Сохранённые данные не удалены.';
      journal.saveSync();
      engine!.emit();
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    engine?.emit();
    final phase = engine?.phase;
    if ([
          'interrupted',
          'transcribing',
          'review',
          'completed',
          'failed',
          'done',
        ].contains(phase) ||
        (phase == 'sending' && engine?.journal.data['network_error'] == true)) {
      unawaited(FlutterForegroundTask.stopService());
    }
  }

  @override
  void onReceiveData(Object data) {
    if (engine == null) return;
    if (data is Map && data['meter_enabled'] is bool) {
      engine!.setMeterEnabled(data['meter_enabled'] as bool);
      return;
    }
    if (data == 'snapshot') unawaited(_command('snapshot'));
    if (data is Map && data['command'] is String) {
      if (!recorderCommandMatches(
        data,
        scope: _scope,
        instance: _instance,
        sessionId: _owner,
      )) {
        debugPrint('AudioCleanup: stage=service_command_owner_rejected');
        return;
      }
      unawaited(
        _command(
          data['command'] as String,
          reply: data['request'] as int?,
          sessionId: data['session_id'] as String?,
        ),
      );
    }
  }

  Future<void> _command(String command, {int? reply, String? sessionId}) async {
    try {
      switch (command) {
        case 'pause':
          await engine!.pause();
        case 'resume':
          await engine!.resume();
        case 'stop':
          await engine!.stop();
        case 'finishRecovered':
          await engine!.finishRecovered();
        case 'retry':
          unawaited(engine!.sync(force: true));
        case 'retryAsr':
          await engine!.retryAsr();
        case 'done':
          await engine!.markDone();
        case 'releaseReview':
          await engine!.releaseReview(sessionId ?? '');
        case 'snapshot':
          engine!.emit();
      }
      final phase = engine!.phase;
      try {
        await FlutterForegroundTask.updateService(
          notificationTitle: 'YourMettings',
          notificationText: phase == 'recording'
              ? 'Идёт запись совещания'
              : phase == 'paused'
              ? 'Запись приостановлена'
              : 'Запись сохранена. Нажмите, чтобы открыть',
        );
      } catch (e) {
        debugPrint('AudioCleanup: stage=notification type=${e.runtimeType}');
      }
      if (reply != null) {
        FlutterForegroundTask.sendDataToMain({
          'command_reply': reply,
          'connection_scope': _scope,
          'owner_session_id': _owner,
          'service_instance': _instance,
          'snapshot': _snapshot(),
          'ok': true,
        });
      }
    } catch (_) {
      if (reply != null) {
        FlutterForegroundTask.sendDataToMain({
          'command_reply': reply,
          'connection_scope': _scope,
          'owner_session_id': _owner,
          'service_instance': _instance,
          'snapshot': _snapshot(),
          'ok': false,
        });
      }
      engine!.journal.data['message'] =
          'Не удалось выполнить действие. Запись сохранена; повторите попытку.';
      engine!.emit();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await engine?.stop(interrupted: true);
    await engine?.dispose();
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();
}

/// UI bridge. Android disk writes belong exclusively to the task isolate.
/// iOS uses the actual record/AVAudioSession engine, not periodic background fetch.
class RecorderCoordinator extends ChangeNotifier {
  RecorderCoordinator({
    this.connection,
    this.directory,
    this.audioApiFactory,
    this.contextWriter,
  });
  final AudioApi Function()? audioApiFactory;
  final Future<void> Function(DemoConnection)? contextWriter;
  AudioApi _api() =>
      audioApiFactory?.call() ??
      AudioApi(
        connection?.base ?? AppConfig.apiBaseUri(),
        connection: connection,
      );
  final DemoConnection? connection;
  final Directory? directory;
  @visibleForTesting
  bool get usesAndroidService => Platform.isAndroid;
  Completer<void>? _firstSnapshot;
  Json state = {};
  final meter = ValueNotifier<List<AudioPeak>>([]);
  bool _meterVisible = false;
  void setMeterVisible(bool visible) {
    if (_meterVisible == visible) return;
    _meterVisible = visible;
    if (_local != null) {
      _local!.setMeterEnabled(visible);
    } else if (usesAndroidService) {
      FlutterForegroundTask.sendDataToTask({'meter_enabled': visible});
    }
    if (!visible) meter.value = [];
  }

  AudioEngine? _local;
  Timer? _poll;
  int _requestId = 0;
  final Map<int, Completer<bool>> _replies = {};
  final Map<int, String?> _replySessions = {};
  bool busy = false;
  bool handoffPending = false;
  bool _foreignOwner = false;
  String? _serviceInstance;
  Future<void>? _attaching;
  final _releasedSessions = <String>{};
  String? error;
  String get phase => state['phase'] as String? ?? 'empty';
  bool get active => _foreignOwner || !['empty', 'done'].contains(phase);
  Future<void> initialize() async {
    _poll?.cancel();
    if (usesAndroidService) {
      FlutterForegroundTask.initCommunicationPort();
      FlutterForegroundTask.addTaskDataCallback(_receive);
      if (await FlutterForegroundTask.isRunningService) {
        // Do not recover/close a live file owned by another engine.
        final ready = _firstSnapshot = Completer<void>();
        FlutterForegroundTask.sendDataToTask('snapshot');
        try {
          await ready.future.timeout(const Duration(seconds: 15));
        } on TimeoutException {
          // The service may have stopped while its snapshot was in transit.
          // Never interpret an unknown owner as an empty/done journal.
          if (await FlutterForegroundTask.isRunningService) {
            throw StateError('Recorder state has not been confirmed');
          }
          await _attachLocal();
        } finally {
          _firstSnapshot = null;
        }
      } else {
        await _attachLocal();
      }
    } else {
      await _attachLocal();
    }
    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!busy &&
          usesAndroidService &&
          _local == null &&
          !await FlutterForegroundTask.isRunningService) {
        try {
          await _attachLocal();
        } catch (e) {
          error = 'Не удалось восстановить диктофон. Повторите завершение операции в «Черновиках».';
          debugPrint('AudioCleanup: stage=attach_local type=${e.runtimeType}');
          notifyListeners();
        }
      }
    });
  }

  void _receive(Object value, {bool local = false}) {
    if (!local && _local != null) return;
    if (value is Map && value['meter'] is List) {
      if (_meterVisible) {
        meter.value = [
          for (final pair in value['meter'] as List)
            AudioPeak((pair[0] as num).toDouble(), (pair[1] as num).toDouble()),
        ];
      }
      return;
    }
    if (value is Map && value['command_reply'] is int) {
      if (!_replies.containsKey(value['command_reply'])) return;
      if (connection != null &&
          (value['connection_scope'] != connection!.scopeId ||
              value['service_instance'] != _serviceInstance ||
              value['owner_session_id'] !=
                  _replySessions[value['command_reply']])) {
        return;
      }
      if (value['snapshot'] is Map) _receive(value['snapshot'] as Map);
      _replies.remove(value['command_reply'])?.complete(value['ok'] == true);
      return;
    }
    if (value is Map) {
      final owner = value['owner_session_id'] ?? value['id'];
      if (!local && _releasedSessions.contains(owner)) return;
      if (!local &&
          _serviceInstance != null &&
          value['service_instance'] != null &&
          value['service_instance'] != _serviceInstance) {
        return;
      }
      if (connection != null &&
          value['connection_scope'] != connection!.scopeId) {
        _foreignOwner = true;
        final ready = _firstSnapshot;
        if (ready != null && !ready.isCompleted) {
          ready.completeError(
            StateError(
              'Другой профиль владеет текущей записью. Завершите её перед переключением.',
            ),
          );
        }
        return;
      }
      // Only a scoped task snapshot or a trusted local journal can establish ownership.
      _foreignOwner = false;
      if (!local && value['service_instance'] is String) {
        _serviceInstance = value['service_instance'] as String;
      }
      state = Map<String, dynamic>.from(value);
      final ready = _firstSnapshot;
      if (ready != null && !ready.isCompleted) ready.complete();
      notifyListeners();
    }
  }

  Future<void> _attachLocal() {
    if (_local != null) return Future.value();
    return _attaching ??= _loadLocal().whenComplete(() => _attaching = null);
  }

  Future<void> _loadLocal() async {
    final journal = await openAudioJournal(directory: directory);
    _local = AudioEngine(
      journal,
      _api(),
      changed: (value) => _receive({
        ...value,
        if (connection != null) 'connection_scope': connection!.scopeId,
      }, local: true),
      meterChanged: (peaks) {
        if (_meterVisible) meter.value = peaks;
      },
      allowCapture: !usesAndroidService,
      maintenanceRequired: () => _maintenanceRequired(
        directory,
        _local?.journal.data['id'] as String?,
      ),
    );
    try {
      await _local!.initialize();
      _local!.setMeterEnabled(_meterVisible);
    } catch (_) {
      await _local!.dispose();
      _local = null;
      rethrow;
    }
  }

  Future<void> start(Json parameters) async {
    if (busy) return;
    if (handoffPending) {
      error = 'Завершите сохранение черновика в «Пространстве» перед новой записью.';
      notifyListeners();
      return;
    }
    if (active && !['preparing', 'interrupted'].contains(phase)) {
      error = 'Сначала продолжите сохранённую встречу.';
      notifyListeners();
      return;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      if (usesAndroidService && await FlutterForegroundTask.isRunningService) {
        throw StateError('Recording already running');
      }
      final permissionRecorder = AudioRecorder();
      final allowed = await permissionRecorder.hasPermission();
      debugPrint('Audio: microphone_permission granted=$allowed');
      await permissionRecorder.dispose();
      if (!allowed) {
        error = 'Разрешите доступ к микрофону в настройках приложения.';
        return;
      }
      if (usesAndroidService) {
        final permission =
            await FlutterForegroundTask.checkNotificationPermission();
        if (permission != NotificationPermission.granted) {
          if (await FlutterForegroundTask.requestNotificationPermission() !=
              NotificationPermission.granted) {
            error =
                'Разрешите уведомления, чтобы видеть состояние фоновой записи.';
            return;
          }
        }
      }
      await _local?.dispose();
      _local = null;
      final journal = await openAudioJournal(directory: directory);
      final api = _api();
      try {
        if (connection != null) {
          await (contextWriter ?? saveRecorderContext)(connection!);
        }
        await AudioEngine.prepare(journal, api, parameters);
      } finally {
        api.close();
      }
      _serviceInstance = null;
      _receive({
        ...journal.data,
        if (connection != null) 'connection_scope': connection!.scopeId,
      }, local: true);
      if (usesAndroidService) {
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
            eventAction: ForegroundTaskEventAction.repeat(2000),
            autoRunOnBoot: false,
            autoRunOnMyPackageReplaced: false,
            allowAutoRestart: false,
            allowWakeLock: true,
            stopWithTask: false,
          ),
        );
        final result = await FlutterForegroundTask.startService(
          serviceId: 410,
          serviceTypes: [ForegroundServiceTypes.microphone],
          notificationTitle: 'YourMettings',
          notificationText: 'Идёт запись совещания',
          callback: audioTaskEntry,
        );
        if (result is ServiceRequestFailure) {
          throw StateError('Could not start foreground recorder');
        }
      } else {
        await _attachLocal();
      }
    } catch (e) {
      error = e is ApiException ? e.message : 'Не удалось начать запись. Проверьте подключение к серверу и разрешения. Данные не удалены.';
      await _attachLocal();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> command(String command, {String? sessionId}) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      if (usesAndroidService &&
          _local == null &&
          !await FlutterForegroundTask.isRunningService) {
        await _attachLocal();
      }
      if (usesAndroidService && _local == null) {
        final id = ++_requestId;
        final reply = Completer<bool>();
        _replies[id] = reply;
        _replySessions[id] = sessionId ?? state['id'] as String?;
        FlutterForegroundTask.sendDataToTask({
          'command': command,
          'request': id,
          'session_id': sessionId ?? state['id'],
          if (connection != null) 'connection_scope': connection!.scopeId,
          'service_instance': _serviceInstance,
        });
        try {
          if (!await reply.future.timeout(const Duration(seconds: 15))) {
            throw StateError('Recorder command failed');
          }
        } on TimeoutException {
          if (command != 'releaseReview' ||
              await FlutterForegroundTask.isRunningService) {
            rethrow;
          }
          await _attachLocal();
          if (active) await _local!.releaseReview(sessionId!);
        } finally {
          _replies.remove(id);
          _replySessions.remove(id);
        }
      } else {
        switch (command) {
          case 'pause':
            await _local?.pause();
          case 'resume':
            await _local?.resume();
          case 'stop':
            await _local?.stop();
          case 'retry':
            await _local?.sync(force: true);
          case 'retryAsr':
            await _local?.retryAsr();
          case 'done':
            await _local?.markDone();
          case 'finishRecovered':
            await _local?.finishRecovered();
          case 'releaseReview':
            await _local?.releaseReview(sessionId ?? '');
        }
      }
    } catch (e) {
      debugPrint(
        'AudioCleanup: stage=coordinator_command type=${e.runtimeType}',
      );
      error = 'Не удалось выполнить действие. Сохранённое аудио не удалено.';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> releaseReview(String expectedId) async {
    if (busy) throw StateError('Recorder command already running');
    if (usesAndroidService &&
        _local == null &&
        !await FlutterForegroundTask.isRunningService) {
      await _attachLocal();
    }
    if (state.isEmpty) {
      throw StateError('Recorder state has not been confirmed');
    }
    if (!active) {
      error = null;
      _releasedSessions.add(expectedId);
      return;
    }
    if (_foreignOwner) throw StateError('Another profile owns the recorder');
    if (state['id'] != expectedId) {
      throw StateError('Another recording owns the journal');
    }
    await command('releaseReview', sessionId: expectedId);
    if (active || error != null) {
      throw StateError('Review handoff not acknowledged');
    }
    _releasedSessions.add(expectedId);
  }

  Future<void> foreground() async {
    if (usesAndroidService && _local == null) {
      FlutterForegroundTask.sendDataToTask('snapshot');
    } else {
      await _local?.sync(force: true);
    }
  }

  Future<void> detachIdle() async {
    if (active || busy || handoffPending) {
      throw StateError('Сначала завершите текущую запись.');
    }
    _poll?.cancel();
    if (usesAndroidService && await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
    await _local?.dispose();
    _local = null;
  }

  @override
  void dispose() {
    _poll?.cancel();
    if (usesAndroidService) {
      FlutterForegroundTask.removeTaskDataCallback(_receive);
    }
    setMeterVisible(false);
    meter.dispose();
    // Recording lifetime belongs to the app/service, not to its current route.
    unawaited(_local?.dispose());
    super.dispose();
  }
}

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

Future<AudioJournal> openAudioJournal() async {
  final support = await getApplicationSupportDirectory();
  return AudioJournal(Directory('${support.path}/active-audio'));
}

class _AudioTask extends TaskHandler {
  AudioEngine? engine;
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final journal = await openAudioJournal();
    engine = AudioEngine(
      journal,
      AudioApi(AppConfig.apiBaseUri()),
      changed: FlutterForegroundTask.sendDataToMain,
      meterChanged: (peaks) => FlutterForegroundTask.sendDataToMain({
        'meter': [
          for (final peak in peaks) [peak.low, peak.high],
        ],
      }),
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
    if (data is String) unawaited(_command(data));
    if (data is Map && data['command'] is String) {
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
      await FlutterForegroundTask.updateService(
        notificationTitle: 'YourMettings',
        notificationText: phase == 'recording'
            ? 'Идёт запись совещания'
            : phase == 'paused'
            ? 'Запись приостановлена'
            : 'Запись сохранена. Нажмите, чтобы открыть',
      );
      if (reply != null) {
        FlutterForegroundTask.sendDataToMain({
          'command_reply': reply,
          'ok': true,
        });
      }
    } catch (_) {
      if (reply != null) {
        FlutterForegroundTask.sendDataToMain({
          'command_reply': reply,
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
  RecorderCoordinator();
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
  bool busy = false;
  bool handoffPending = false;
  String? error;
  String get phase => state['phase'] as String? ?? 'empty';
  bool get active => !['empty', 'done'].contains(phase);
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
        await _attachLocal();
      }
    });
  }

  void _receive(Object value) {
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
      _replies.remove(value['command_reply'])?.complete(value['ok'] == true);
      return;
    }
    if (value is Map) {
      state = Map<String, dynamic>.from(value);
      final ready = _firstSnapshot;
      if (ready != null && !ready.isCompleted) ready.complete();
      notifyListeners();
    }
  }

  Future<void> _attachLocal() async {
    if (_local != null) return;
    final journal = await openAudioJournal();
    _local = AudioEngine(
      journal,
      AudioApi(AppConfig.apiBaseUri()),
      changed: _receive,
      meterChanged: (peaks) {
        if (_meterVisible) meter.value = peaks;
      },
      allowCapture: !usesAndroidService,
    );
    await _local!.initialize();
    _local!.setMeterEnabled(_meterVisible);
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
      final journal = await openAudioJournal();
      final api = AudioApi(AppConfig.apiBaseUri());
      try {
        await AudioEngine.prepare(journal, api, parameters);
      } finally {
        api.close();
      }
      _receive(journal.data);
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
    } catch (_) {
      error = 'Не удалось начать запись. Проверьте подключение к серверу и разрешения. Данные не удалены.';
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
      if (usesAndroidService && _local == null) {
        final id = ++_requestId;
        final reply = Completer<bool>();
        _replies[id] = reply;
        FlutterForegroundTask.sendDataToTask({
          'command': command,
          'request': id,
          'session_id': ?sessionId,
        });
        try {
          if (!await reply.future.timeout(const Duration(seconds: 15))) {
            throw StateError('Recorder command failed');
          }
        } finally {
          _replies.remove(id);
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
    } catch (_) {
      error = 'Не удалось выполнить действие. Сохранённое аудио не удалено.';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> releaseReview(String expectedId) async {
    if (state.isEmpty) {
      throw StateError('Recorder state has not been confirmed');
    }
    if (!active) return;
    if (state['id'] != expectedId) {
      throw StateError('Another recording owns the journal');
    }
    await command('releaseReview', sessionId: expectedId);
    if (active || error != null) {
      throw StateError('Review handoff not acknowledged');
    }
  }

  Future<void> foreground() async {
    if (usesAndroidService && _local == null) {
      FlutterForegroundTask.sendDataToTask('snapshot');
    } else {
      await _local?.sync(force: true);
    }
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

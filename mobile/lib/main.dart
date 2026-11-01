import 'services/recorder_context.dart';
import 'services/drafts/draft_workspace.dart';
import 'features/recording/draft_recorder_coordinator.dart';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'api/api_client.dart';
import 'api/demo_connection.dart';
import 'app/appearance.dart';
import 'app/your_mettings_app.dart';
import 'features/settings/connection_page.dart';
import 'features/new_meeting/meeting_controller.dart';
import 'features/recording/recorder_coordinator.dart';
import 'features/recording/audio_review_controller.dart';
import 'services/audio_draft_store.dart';
import 'services/recovery_store.dart';
import 'services/operation_store.dart';
import 'services/connection_settings.dart';
import 'services/demo_key_vault.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _Bootstrap());
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late Directory _support;
  final _appearance = AppearanceController();
  AppearanceController? _loadedAppearance;
  ConnectionSettings? _settings;
  MeetingController? _controller;
  RecorderCoordinator? _recorder;
  AudioReviewController? _review;
  AudioDraftRepository? _drafts;
  DraftWorkspace? _localDrafts;
  DraftRecorderCoordinator? _localRecorder;
  bool _switching = false;
  String? _graphError;
  late final Future<void> _startup = _start();
  Future<void> _start() async {
    _support = await getApplicationSupportDirectory();
    _loadedAppearance = AppearanceController(
      file: File('${_support.path}/appearance.json'),
    );
    await _loadedAppearance!.load();
    final settings = ConnectionSettings(
      vault: const DeviceDemoKeyVault(),
      file: File('${_support.path}/connection-settings.json'),
    );
    await settings.load();
    settings.beforeApply = (next) async {
      final current = _controller?.api.connection;
      if (current?.scopeId == next.scopeId && current?.base == next.base) {
        return null;
      }
      if (_localRecorder?.recording == true ||
          _localRecorder?.busy == true ||
          await FlutterForegroundTask.isRunningService) {
        return 'Сначала завершите текущую запись. Остальные черновики сохранятся в этом подключении.';
      }
      if (_recorder?.active == true ||
          _recorder?.busy == true ||
          _recorder?.handoffPending == true) {
        return 'Сначала завершите запись и передачу аудио. Готовый транскрипт можно сохранить в черновики и выйти, затем сменить профиль.';
      }
      if (_controller?.working == true || _review?.working == true) {
        return 'Дождитесь завершения текущего запроса и повторите переключение. Данные не перенесены.';
      }
      return null;
    };
    settings.onApply = (next, same) async {
      if (same && _controller != null && _graphError == null) {
        await _localRecorder?.foreground();
        unawaited(_localDrafts?.refreshCatalogs());
        await _recorder?.foreground();
        return;
      }
      await _replaceGraph(next);
    };
    _settings = settings;
    if (settings.active != null) await _replaceGraph(settings.active!);
  }

  Future<void> _closeGraph() async {
    await _localRecorder?.close();
    await _localDrafts?.drain();
    _localRecorder?.dispose();
    _localDrafts?.dispose();
    _localRecorder = null;
    _localDrafts = null;
    final controller = _controller;
    if (controller != null) {
      await controller.store.save(controller.recovery);
      await _review?.store.save(_review!.recovery);
    }
    await _recorder?.detachIdle();
    _review?.dispose();
    _recorder?.dispose();
    _drafts?.dispose();
    controller?.dispose();
    controller?.api.operations?.dispose();
    controller?.api.close();
    _review = null;
    _recorder = null;
    _drafts = null;
    _controller = null;
  }

  Future<void> _replaceGraph(DemoConnection binding) async {
    if (mounted) {
      setState(() {
        _switching = true;
        _graphError = null;
      });
    }
    var stage = 'close';
    try {
      await _closeGraph();
      // No migration from unscoped legacy/personal files. A new verified identity
      // always receives its own empty or previously preserved directory.
      final directory = connectionDirectory(_support, binding);
      await directory.create(recursive: true);
      final operations = OperationStore(
        file: File('${directory.path}/generation-operations.json'),
      );
      await operations.load();
      final api = ApiClient(
        binding.base,
        connection: binding,
        operations: operations,
      );
      final localDrafts = DraftWorkspace(
        directory: directory,
        connection: binding,
        api: api,
      );
      _localDrafts = localDrafts;
      // No legacy UI controller exists yet. A running FGS keeps audio ownership.
      stage = 'local-drafts';
      await localDrafts.initialize(
        legacyTextOwnerStopped: true,
        legacyAudioOwnerStopped: !await FlutterForegroundTask.isRunningService,
      );
      final controller = MeetingController(
        api,
        localDrafts.legacyTextHandoffPending
            ? _PendingHandoffRecoveryStore()
            : FileRecoveryStore(
                File('${directory.path}/meeting-recovery.json'),
              ),
      );
      stage = 'legacy-text';
      try {
        await controller.initialize();
      } catch (_) {
        controller.dispose();
        rethrow;
      }
      _controller = controller;
      final drafts = AudioDraftRepository(
        file: File('${directory.path}/audio-drafts.json'),
      );
      _drafts = drafts;
      await drafts.load();
      final recorder = RecorderCoordinator(
        connection: binding,
        directory: directory,
      );
      _recorder = recorder;
      final review = AudioReviewController(
        api,
        FileRecoveryStore(File('${directory.path}/audio-review-recovery.json')),
        recorder,
        drafts: drafts,
      );
      stage = 'legacy-review';
      try {
        await review.initialize();
      } catch (_) {
        review.dispose();
        rethrow;
      }
      _review = review;
      stage = 'legacy-recorder';
      try {
        await recorder.initialize();
      } catch (_) {
        localDrafts.reportLegacyError();
      }
      // Network recovery must never gate local cold launch.
      unawaited(
        review.recoverHandoffs().catchError((Object _) {
          localDrafts.reportLegacyError();
        }),
      );
      final localRecorder = DraftRecorderCoordinator(localDrafts);
      _localRecorder = localRecorder;
      stage = 'local-recorder';
      await localRecorder.initialize();
      unawaited(localDrafts.refreshCatalogs());
    } catch (error) {
      debugPrint('LocalGraph: stage=$stage type=${error.runtimeType}');
      _graphError = 'Не удалось открыть данные этого подключения. Они сохранены; повторите подключение.';
      rethrow;
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  void dispose() {
    _localRecorder?.dispose();
    _localDrafts?.dispose();
    _review?.dispose();
    _recorder?.dispose();
    _drafts?.dispose();
    _controller?.dispose();
    _controller?.api.close();
    _settings?.dispose();
    _loadedAppearance?.dispose();
    _appearance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _startup,
    builder: (context, snapshot) {
      final appearance = _loadedAppearance ?? _appearance;
      if (snapshot.connectionState != ConnectionState.done || _switching) {
        return MaterialApp(
          theme: appearance.theme(Brightness.light),
          darkTheme: appearance.theme(Brightness.dark),
          themeMode: appearance.themeMode,
          home: const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
        );
      }
      if (snapshot.hasError && _settings == null) {
        return MaterialApp(
          home: Scaffold(
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Не удалось открыть настройки подключения. Данные не удалены.',
                  ),
                ),
              ),
            ),
          ),
        );
      }
      final settings = _settings!;
      if (_controller != null && _graphError == null) {
        return YourMettingsApp(
          key: ValueKey(_controller!.api.connection!.scopeId),
          controller: _controller,
          appearance: appearance,
          recorder: _recorder,
          audioReview: _review,
          drafts: _drafts,
          connectionSettings: settings,
          localDrafts: _localDrafts,
          localRecorder: _localRecorder,
        );
      }
      if (settings.active != null) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appearance.theme(Brightness.light),
          darkTheme: appearance.theme(Brightness.dark),
          themeMode: appearance.themeMode,
          home: Scaffold(
            appBar: AppBar(title: const Text('Локальные данные')),
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _graphError ?? 'Не удалось открыть сохранённые данные. Они не удалены.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () async {
                        try {
                          await _replaceGraph(settings.active!);
                        } catch (_) {
                          /* Error remains visible. */
                        }
                      },
                      child: const Text('Повторить открытие'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appearance.theme(Brightness.light),
        darkTheme: appearance.theme(Brightness.dark),
        themeMode: appearance.themeMode,
        home: ConnectionPage(controller: settings, initial: true),
      );
    },
  );
}

// A failed local handoff must not let a freshly created legacy controller clear
// or edit the authoritative source before recovery finishes on the next launch.
class _PendingHandoffRecoveryStore implements RecoveryStore {
  RecoveryState _value = RecoveryState();
  @override
  Future<RecoveryState> load() async => _value;
  @override
  Future<void> save(RecoveryState state) async {
    _value = state;
  }
}

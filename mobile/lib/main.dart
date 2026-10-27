import 'services/recorder_context.dart';

import 'dart:io';

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
        await _recorder?.foreground();
        return;
      }
      await _replaceGraph(next);
    };
    _settings = settings;
    if (settings.active != null) await _replaceGraph(settings.active!);
  }

  Future<void> _closeGraph() async {
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
      final controller = MeetingController(
        api,
        FileRecoveryStore(File('${directory.path}/meeting-recovery.json')),
      );
      _controller = controller;
      await controller.initialize();
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
      _review = review;
      await review.initialize();
      await recorder.initialize();
      await review.recoverHandoffs();
    } catch (_) {
      _graphError = 'Не удалось открыть данные этого подключения. Они сохранены; повторите подключение.';
      rethrow;
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  void dispose() {
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

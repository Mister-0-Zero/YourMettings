import 'services/operation_store.dart';
import 'features/recording/recorder_coordinator.dart';
import 'features/recording/audio_review_controller.dart';
import 'app/appearance.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'api/api_client.dart';
import 'app/config.dart';
import 'app/your_mettings_app.dart';
import 'features/new_meeting/meeting_controller.dart';
import 'services/recovery_store.dart';
import 'services/audio_draft_store.dart';

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
  MeetingController? _controller;
  AppearanceController? _appearance;
  RecorderCoordinator? _recorder;
  AudioReviewController? _audioReview;
  AudioDraftRepository? _drafts;
  late Future<MeetingController> _initialization = _initialize();
  Future<MeetingController> _initialize() async {
    final directory = await getApplicationSupportDirectory();
    _appearance ??= AppearanceController(
      file: File('${directory.path}/appearance.json'),
    );
    await _appearance!.load();
    final operations = OperationStore(
      file: File('${directory.path}/generation-operations.json'),
    );
    await operations.load();
    final controller = MeetingController(
      ApiClient(AppConfig.apiBaseUri(), operations: operations),
      FileRecoveryStore(File('${directory.path}/meeting-recovery.json')),
    );
    try {
      await controller.initialize();
    } catch (_) {
      controller.dispose();
      controller.api.close();
      rethrow;
    }
    _drafts ??= AudioDraftRepository(
      file: File('${directory.path}/audio-drafts.json'),
    );
    await _drafts!.load();
    _recorder ??= RecorderCoordinator();
    _audioReview ??= AudioReviewController(
      controller.api,
      FileRecoveryStore(File('${directory.path}/audio-review-recovery.json')),
      _recorder!,
      drafts: _drafts,
    );
    await _audioReview!.initialize();
    await _recorder!.initialize();
    await _audioReview!.recoverHandoffs();
    _controller = controller;
    return controller;
  }

  @override
  void dispose() {
    _audioReview?.dispose();
    _recorder?.dispose();
    _drafts?.dispose();
    _appearance?.dispose();
    _controller?.dispose();
    _controller?.api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<MeetingController>(
    future: _initialization,
    builder: (context, snapshot) {
      if (snapshot.hasData) {
        return YourMettingsApp(
          controller: snapshot.data,
          appearance: _appearance,
          recorder: _recorder,
          audioReview: _audioReview,
          drafts: _drafts,
        );
      }
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: snapshot.hasError
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Не удалось открыть локальный черновик или конфигурацию приложения. Данные не удалены.',
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () => setState(() {
                            _initialization = _initialize();
                          }),
                          child: const Text('Повторить'),
                        ),
                      ],
                    ),
                  )
                : const CircularProgressIndicator(),
          ),
        ),
      );
    },
  );
}

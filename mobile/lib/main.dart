import 'app/appearance.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'api/api_client.dart';
import 'app/config.dart';
import 'app/your_mettings_app.dart';
import 'features/new_meeting/meeting_controller.dart';
import 'services/recovery_store.dart';

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
  late Future<MeetingController> _initialization = _initialize();
  Future<MeetingController> _initialize() async {
    final directory = await getApplicationSupportDirectory();
    _appearance ??= AppearanceController(
      file: File('${directory.path}/appearance.json'),
    );
    await _appearance!.load();
    final controller = MeetingController(
      ApiClient(AppConfig.apiBaseUri()),
      FileRecoveryStore(File('${directory.path}/meeting-recovery.json')),
    );
    try {
      await controller.initialize();
    } catch (_) {
      controller.dispose();
      controller.api.close();
      rethrow;
    }
    _controller = controller;
    return controller;
  }

  @override
  void dispose() {
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
                          onPressed: () =>
                              setState(() => _initialization = _initialize()),
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

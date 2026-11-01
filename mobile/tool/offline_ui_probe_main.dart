// Isolated Android package only: dev.yourmettings.offline_ui_probe.
// Starts the production bootstrap with a synthetic, previously verified local
// identity and an intentionally unavailable server. No real key/user data.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:your_mettings/main.dart' as production;
import 'package:your_mettings/api/demo_connection.dart';
import 'package:your_mettings/services/demo_key_vault.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final settings = File('${support.path}/connection-settings.json');
  if (!await settings.exists()) {
    final binding = DemoConnection(
      base: Uri.parse('http://127.0.0.1:65531/api/v1/'),
      accountId: 'isolated-offline-probe',
      accessMode: 'demo',
      vault: const DeviceDemoKeyVault(),
    );
    await settings.writeAsString(
      jsonEncode({
        'version': 1,
        'profile': 'usb',
        'addresses': {
          'usb': 'http://127.0.0.1:65531/api/v1',
          'https': httpsAddress,
        },
        'active': binding.toJson(),
      }),
      flush: true,
    );
  }
  production.main();
}

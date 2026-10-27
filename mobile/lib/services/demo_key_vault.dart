import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class DemoKeyVault {
  Future<String?> read(String origin);
  Future<void> write(String origin, String key);
}

class DeviceDemoKeyVault implements DemoKeyVault {
  const DeviceDemoKeyVault();
  static const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      storageNamespace: 'yourmettings_demo',
      resetOnError: false,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  String _name(String origin) =>
      'demo-key-${sha256.convert(utf8.encode(origin))}';
  @override
  Future<String?> read(String origin) => storage.read(key: _name(origin));
  @override
  Future<void> write(String origin, String key) =>
      storage.write(key: _name(origin), value: key);
}

import 'package:flutter/foundation.dart';

class AppConfig {
  static const _configuredUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://192.168.1.100:8000/api/v1',
  );

  static Uri apiBaseUri({
    String value = _configuredUrl,
    bool release = kReleaseMode,
  }) {
    final uri = Uri.parse(value);
    if (!uri.hasAuthority ||
        uri.host.isEmpty ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path.replaceAll(RegExp(r'/+$'), '') != '/api/v1') {
      throw const FormatException(
        'API_BASE_URL должен быть HTTP(S)-адресом с путём /api/v1.',
      );
    }
    if (release && uri.scheme != 'https') {
      throw const FormatException(
        'Для release-сборки требуется HTTPS backend.',
      );
    }
    return uri.replace(path: '/api/v1/');
  }
}

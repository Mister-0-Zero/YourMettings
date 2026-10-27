import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../models/api_models.dart';
import '../services/demo_key_vault.dart';
import 'api_error.dart';

enum ServerProfile { usb, https }

String profileLabel(ServerProfile p) =>
    p == ServerProfile.usb ? 'USB' : 'Удалённый HTTPS';
const usbAddress = 'http://127.0.0.1:8000/api/v1';
const httpsAddress = 'https://194.117.80.169/api/v1';

Uri normalizeBackend(String value, ServerProfile profile) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !['http', 'https'].contains(uri.scheme) ||
      !['', '/', '/api/v1'].contains(uri.path.replaceAll(RegExp(r'/+$'), ''))) {
    throw const FormatException(
      'Укажите адрес сервера или путь /api/v1 без параметров и повторения пути.',
    );
  }
  final local = [
    '127.0.0.1',
    'localhost',
    '::1',
  ].contains(uri.host.toLowerCase());
  if (uri.scheme != 'https' && (profile != ServerProfile.usb || !local)) {
    throw const FormatException(
      'HTTPS обязателен. HTTP разрешён только для локального USB-подключения.',
    );
  }
  return Uri(
    scheme: uri.scheme,
    host: uri.host.toLowerCase(),
    port: uri.hasPort && uri.port != (uri.scheme == 'https' ? 443 : 80)
        ? uri.port
        : null,
    path: '/api/v1/',
  );
}

http.Client platformHttpClient() =>
    IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 20));

/// URI/account are fixed for an operation graph. Secrets are never serialized.
class DemoConnection {
  DemoConnection({
    required this.base,
    required this.accountId,
    required this.accessMode,
    required this.vault,
    this.onAccessError,
  });
  final Uri base;
  final String accountId, accessMode;
  final DemoKeyVault vault;
  final void Function(ApiException)? onAccessError;
  String get origin => base.origin;
  String get scopeId =>
      sha256.convert(utf8.encode('$origin|$accessMode|$accountId')).toString();
  Json toJson() => {
    'base': base.toString(),
    'account_id': accountId,
    'access_mode': accessMode,
  };
  factory DemoConnection.fromJson(
    Json j,
    DemoKeyVault vault, {
    void Function(ApiException)? onAccessError,
  }) {
    final base = normalizeBackend(
      j['base'] as String,
      (j['base'] as String).startsWith('http:')
          ? ServerProfile.usb
          : ServerProfile.https,
    );
    return DemoConnection(
      base: base,
      accountId: j['account_id'] as String,
      accessMode: j['access_mode'] as String,
      vault: vault,
      onAccessError: onAccessError,
    );
  }
  void report(ApiException error) {
    if (error.isAccess) onAccessError?.call(error);
  }

  http.Client client({http.Client? inner}) =>
      _BoundClient(this, inner ?? platformHttpClient());
}

class _BoundClient extends http.BaseClient {
  _BoundClient(this.connection, this.inner);
  final DemoConnection connection;
  final http.Client inner;
  static final _notBefore = <String, DateTime>{};
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.origin != connection.origin) {
      throw const ApiException(
        'origin_mismatch',
        'Адрес запроса отличается от выбранного сервера. Ключ не отправлен.',
      );
    }
    final until = _notBefore[connection.origin];
    if (until != null && until.isAfter(DateTime.now())) {
      await Future<void>.delayed(until.difference(DateTime.now()));
    }
    final key = await connection.vault.read(connection.origin) ?? '';
    request.headers.removeWhere(
      (name, _) => name.toLowerCase() == 'x-demo-key',
    );
    request.headers['X-Demo-Key'] = key;
    request.followRedirects = false;
    final result = await inner.send(request);
    if (result.statusCode == 429) {
      final raw = result.headers['retry-after'];
      var delay = retryAfterDuration(raw);
      if (delay == null && raw != null) {
        try {
          final d = HttpDate.parse(raw).difference(DateTime.now());
          delay = d.isNegative ? Duration.zero : d;
        } catch (_) {}
      }
      _notBefore[connection.origin] = DateTime.now().add(
        delay ?? const Duration(seconds: 2),
      );
    }
    return result;
  }

  @override
  void close() => inner.close();
}

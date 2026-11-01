import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../api/api_error.dart';
import '../../api/demo_connection.dart';
import '../../models/api_models.dart';
import 'draft_record.dart';

class QueueStopped implements Exception {
  const QueueStopped();
  @override
  String toString() => 'Передача приостановлена; данные сохранены.';
}

class QueueCancellation {
  final _stop = Completer<void>();
  bool get stopped => _stop.isCompleted;
  Future<void> get signal => _stop.future;
  final _closers = <void Function()>[];
  void check() {
    if (stopped) throw const QueueStopped();
  }

  void onStop(void Function() close) {
    if (stopped) {
      close();
    } else {
      _closers.add(close);
    }
  }

  void stop() {
    if (stopped) return;
    _stop.complete();
    for (final close in _closers) {
      close();
    }
    _closers.clear();
  }

  Future<T> wait<T>(Future<T> work) =>
      Future.any([work, signal.then<T>((_) => throw const QueueStopped())]);
}

/// One immutable origin/identity, no redirects and no uninterruptible global
/// Retry-After delay. Durable retry timing belongs to the scoped queue manifest.
class QueueAuthorizedClient extends http.BaseClient {
  QueueAuthorizedClient(this.binding, this.cancel, {http.Client? inner})
    : inner = inner ?? platformHttpClient() {
    cancel.onStop(this.inner.close);
  }
  final DemoConnection binding;
  final QueueCancellation cancel;
  final http.Client inner;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    cancel.check();
    if (request.url.origin != binding.origin) {
      throw const ApiException(
        'origin_mismatch',
        'Адрес запроса не совпал с сервером. Ключ не отправлен.',
      );
    }
    final key = await cancel.wait(binding.vault.read(binding.origin));
    cancel.check();
    if (key == null || key.isEmpty) {
      throw const ApiException(
        'demo_key_required',
        'Восстановите доступ к этому подключению.',
        statusCode: 401,
      );
    }
    request.headers.removeWhere((key, _) => key.toLowerCase() == 'x-demo-key');
    request.headers['X-Demo-Key'] = key;
    request.followRedirects = false;
    return cancel.wait(inner.send(request));
  }

  @override
  void close() => inner.close();
}

class QueueTransport {
  QueueTransport(
    this.binding,
    this.cancel, {
    http.Client? inner,
    this.jsonTimeout = const Duration(seconds: 20),
    this.uploadTimeout = const Duration(seconds: 360),
  }) : client = QueueAuthorizedClient(binding, cancel, inner: inner);
  final DemoConnection binding;
  final QueueCancellation cancel;
  final QueueAuthorizedClient client;
  final Duration jsonTimeout, uploadTimeout;
  Future<Json> _send(http.BaseRequest request, Duration timeout) async {
    cancel.check();
    try {
      final response = await cancel
          .wait(client.send(request).then(http.Response.fromStream))
          .timeout(timeout);
      if (request.method == 'DELETE' &&
          response.statusCode >= 200 &&
          response.statusCode < 300 &&
          (response.statusCode != 204 || response.bodyBytes.isNotEmpty)) {
        throw const ApiException(
          'invalid_delete_receipt',
          'Удаление не подтверждено пустым ответом204.',
        );
      }
      return decodeResponse(
        response.bodyBytes,
        response.statusCode,
        response.headers,
      );
    } on QueueStopped {
      rethrow;
    } on TimeoutException {
      // Close this client: do not leave a timed-out body transmitting in parallel
      // with the next owner. A later run creates a fresh transport and replays.
      cancel.stop();
      throw const ApiException(
        'queue_timeout',
        'Сервер не ответил. Данные сохранены.',
        isNetwork: true,
      );
    } on http.ClientException {
      throw const ApiException(
        'queue_network',
        'Сервер временно недоступен. Данные сохранены.',
        isNetwork: true,
      );
    } on SocketException {
      throw const ApiException(
        'queue_network',
        'Сервер временно недоступен. Данные сохранены.',
        isNetwork: true,
      );
    }
  }

  Future<Json> json(
    String method,
    String path, {
    String? encodedBody,
    String? key,
    Map<String, String>? query,
  }) {
    if (path.startsWith('/') || path.contains('://')) {
      throw ArgumentError('Only relative queue paths');
    }
    final request = http.AbortableRequest(
      method,
      binding.base.resolve(path).replace(queryParameters: query),
      abortTrigger: cancel.signal,
    );
    request.headers['Accept'] = 'application/json';
    if (key != null && method != 'DELETE') {
      request.headers['Idempotency-Key'] = key;
    }
    if (encodedBody != null && method != 'DELETE') {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = encodedBody;
    }
    return _send(request, jsonTimeout);
  }

  Future<Json> frozen(FrozenDraftRequest request) => json(
    request.method,
    request.path,
    encodedBody: request.encodedBody,
    key: request.key,
    query: request.query.isEmpty ? null : request.query,
  );
  Future<void> verifyIdentity() async {
    final identity = await json('GET', 'auth/me');
    if (identity['id'] != binding.accountId ||
        identity['access_mode'] != binding.accessMode) {
      throw const ApiException(
        'account_changed',
        'Сервер подтвердил другой аккаунт. Отправка приостановлена.',
        statusCode: 403,
      );
    }
  }

  Future<Json> upload(String sessionId, File file, Json chunk) async {
    cancel.check();
    final bytes = await cancel.wait(file.readAsBytes());
    cancel.check();
    final request = http.AbortableRequest(
      'POST',
      binding.base
          .resolve('audio-sessions/$sessionId/chunks')
          .replace(
            queryParameters: {
              'sequence_number': '${chunk['sequence']}',
              'start_ms': '${chunk['start_ms']}',
              'overlap_ms': '0',
              'duration_ms': '${chunk['duration_ms']}',
              'content_sha256': chunk['sha256'] as String,
            },
          ),
      abortTrigger: cancel.signal,
    );
    request.headers['Content-Type'] = 'application/octet-stream';
    request.bodyBytes = bytes;
    return _send(request, uploadTimeout);
  }

  void close() => client.close();
}

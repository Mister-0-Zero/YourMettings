import '../../api/api_error.dart';
import '../../api/demo_connection.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../api/api_client.dart';
import '../../models/api_models.dart';

/// Independent client: audio uploads must never block capture or JSON requests.
class AudioApi {
  AudioApi(
    this.base, {
    http.Client? client,
    this.connection,
    this.uploadTimeout = const Duration(seconds: 360),
    this.jsonTimeout = const Duration(seconds: 20),
  }) : client =
           connection?.client(inner: client) ?? client ?? platformHttpClient();
  final DemoConnection? connection;
  final Duration uploadTimeout, jsonTimeout;
  final Uri base;
  final http.Client client;
  Future<Json> _send(http.BaseRequest request, Completer<void> abort) async {
    try {
      final response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(
            request is http.StreamedRequest ? uploadTimeout : jsonTimeout,
            onTimeout: () {
              if (!abort.isCompleted) abort.complete();
              throw TimeoutException('Audio HTTP deadline');
            },
          );
      if (request.method == 'DELETE') {
        if (response.statusCode == 204 && response.bodyBytes.isEmpty) return {};
        if (response.statusCode >= 200 && response.statusCode < 300) {
          throw const FormatException('Deletion requires confirmed empty 204');
        }
      }
      try {
        return decodeResponse(
          response.bodyBytes,
          response.statusCode,
          response.headers,
        );
      } on ApiException catch (e) {
        connection?.report(e);
        rethrow;
      }
    } on TimeoutException {
      throw const ApiException(
        'audio_timeout',
        'Соединение с сервером потеряно.',
        isNetwork: true,
      );
    } on http.ClientException {
      throw const ApiException(
        'audio_network',
        'Соединение с сервером потеряно.',
        isNetwork: true,
      );
    } on FormatException {
      throw const ApiException(
        'audio_response',
        'Сервер вернул некорректный ответ. Запись сохранена.',
      );
    }
  }

  Future<Json> json(String method, String path, {Json? body, String? key}) {
    final abort = Completer<void>();
    final request = http.AbortableRequest(
      method,
      base.resolve('audio-sessions$path'),
      abortTrigger: abort.future,
    );
    request.headers['Accept'] = 'application/json';
    if (key != null) request.headers['Idempotency-Key'] = key;
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    return _send(request, abort);
  }

  Future<void> deleteSession(String id) async {
    await json('DELETE', '/$id?confirm=true');
  }

  Future<Json> upload(String id, File file, Json chunk, String hash) async {
    final abort = Completer<void>();
    final request = http.AbortableStreamedRequest(
      'POST',
      base
          .resolve('audio-sessions/$id/chunks')
          .replace(
            queryParameters: {
              'sequence_number': '${chunk['sequence']}',
              'start_ms': '${chunk['start_ms']}',
              'overlap_ms': '0',
              'duration_ms': '${chunk['duration_ms']}',
              'content_sha256': hash,
            },
          ),
      abortTrigger: abort.future,
    );
    request.headers['Content-Type'] = 'application/octet-stream';
    request.contentLength = await file.length();
    final sending = _send(request, abort);
    unawaited(
      file.openRead().pipe(request.sink).catchError((Object e) {
        if (!abort.isCompleted) abort.complete();
      }),
    );
    return sending;
  }

  void close() => client.close();
}

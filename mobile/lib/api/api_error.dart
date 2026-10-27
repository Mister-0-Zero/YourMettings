import 'dart:io';
import 'dart:convert';
import 'dart:math';

import '../models/api_models.dart';

class ApiException implements Exception {
  const ApiException(
    this.code,
    this.message, {
    this.statusCode,
    this.isNetwork = false,
    this.retryAfter,
  });
  final String code, message;
  final int? statusCode;
  final bool isNetwork;
  final Duration? retryAfter;
  bool get isAccess => statusCode == 401 || statusCode == 403;
  bool get retryable =>
      isNetwork || statusCode == 429 || (statusCode ?? 0) >= 500;
  @override
  String toString() => message;
}

Duration? retryAfterDuration(String? value, {DateTime? now}) {
  if (value == null) return null;
  final seconds = int.tryParse(value.trim());
  if (seconds != null) return Duration(seconds: max(0, seconds));
  try {
    // HTTP dates are parsed by the transport; integer seconds are the normal API case.
    final date = HttpDate.parse(value);
    final duration = date.difference(now ?? DateTime.now());
    return duration.isNegative ? Duration.zero : duration;
  } catch (_) {
    return null;
  }
}

Duration retryDelay(int failures, {Duration? minimum}) {
  final base = Duration(seconds: min(30, 1 << failures.clamp(1, 5)));
  return minimum != null && minimum > base ? minimum : base;
}

Json decodeResponse(List<int> bytes, int status, Map<String, String> headers) {
  Json value = {};
  if (bytes.isNotEmpty) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Json) {
        value = decoded;
      } else if (status >= 200 && status < 300) {
        throw const FormatException();
      }
    } on FormatException {
      if (status >= 200 && status < 300) {
        throw const ApiException(
          'invalid_response',
          'Сервер вернул некорректный ответ.',
        );
      }
    }
  }
  if (status >= 200 && status < 300) return value;
  final rawError = value['error'];
  final e = rawError is Json ? rawError : null;
  final code = e?['code'] as String? ?? 'http_error';
  final message = switch (code) {
    'demo_key_required' =>
      'Введите демонстрационный ключ в настройках подключения.',
    'demo_key_invalid' =>
      'Демонстрационный ключ неверен. Исправьте его в настройках подключения.',
    'demo_access_expired' => 'Демонстрационный доступ истёк. Нужен новый ключ или продление владельцем.',
    'auth_unavailable_demo' =>
      'Вход по почте недоступен в демонстрационном режиме.',
    _ => switch (status) {
      401 => 'Нет доступа. Проверьте ключ в настройках подключения.',
      403 => 'Доступ запрещён. Проверьте разрешение и ключ подключения.',
      429 => 'Слишком много запросов. Подождите перед повтором.',
      502 || 503 || 504 => e?['message'] as String? ?? 'Сервер или туннель временно недоступен. Данные сохранены; повторим позже.',
      413 => 'Превышен допустимый размер. Локальный файл сохранён.',
      >= 300 && < 400 => 'Сервер перенаправляет запрос. Укажите конечный адрес в настройках; ключ не переслан.',
      _ => e?['message'] as String? ?? 'Ошибка сервера ($status).',
    },
  };
  throw ApiException(
    code,
    message,
    statusCode: status,
    retryAfter: retryAfterDuration(headers['retry-after']),
  );
}

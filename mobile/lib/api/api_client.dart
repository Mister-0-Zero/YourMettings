import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/api_models.dart';

class ApiException implements Exception {
  const ApiException(
    this.code,
    this.message, {
    this.statusCode,
    this.isNetwork = false,
  });
  final String code;
  final String message;
  final int? statusCode;
  final bool isNetwork;
  @override
  String toString() => message;
}

class ApiClient {
  ApiClient(
    this.baseUri, {
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();
  final Uri baseUri;
  final http.Client _client;
  final Duration timeout;

  Future<Json> _request(
    String method,
    String path, {
    Json? body,
    Map<String, String>? query,
    String? idempotencyKey,
  }) async {
    final uri = baseUri.resolve(path).replace(queryParameters: query);
    final request = http.Request(method, uri);
    request.headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
    }
    if (idempotencyKey != null) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    try {
      final response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
      Json json = {};
      if (response.bodyBytes.isNotEmpty) {
        try {
          final decoded = jsonDecode(utf8.decode(response.bodyBytes));
          if (decoded is Map<String, dynamic>) {
            json = decoded;
          } else if (response.statusCode >= 200 && response.statusCode < 300) {
            throw const FormatException('Ожидался JSON-объект.');
          }
        } on FormatException {
          if (response.statusCode >= 200 && response.statusCode < 300) rethrow;
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = json['error'];
        throw ApiException(
          error is Json
              ? (error['code'] as String? ?? 'http_error')
              : 'http_error',
          error is Json
              ? (error['message'] as String? ??
                    'Ошибка сервера (${response.statusCode}).')
              : 'Ошибка сервера (${response.statusCode}).',
          statusCode: response.statusCode,
        );
      }
      return json;
    } on TimeoutException {
      throw const ApiException(
        'network_timeout',
        'Сервер не ответил вовремя. Проверьте подключение.',
        isNetwork: true,
      );
    } on http.ClientException {
      throw const ApiException(
        'network_error',
        'Не удалось связаться с сервером. Проверьте подключение.',
        isNetwork: true,
      );
    } on FormatException {
      throw const ApiException(
        'invalid_response',
        'Сервер вернул некорректный ответ.',
      );
    }
  }

  Future<ProcessingStatus> submitTranscript({
    required String text,
    required String title,
    required List<String> folderIds,
    required String idempotencyKey,
  }) async => ProcessingStatus.fromJson(
    await _request(
      'POST',
      'transcripts/process',
      body: {'text': text, 'title': title, 'folder_ids': folderIds},
      idempotencyKey: idempotencyKey,
    ),
  );
  Future<ProcessingStatus> processing(String id) async =>
      ProcessingStatus.fromJson(
        await _request('GET', 'transcripts/$id/processing'),
      );
  Future<ProcessingStatus> retryProcessing(
    String id,
    String title,
    List<String> folderIds,
  ) async => ProcessingStatus.fromJson(
    await _request(
      'POST',
      'transcripts/$id/process',
      body: {'title': title, 'folder_ids': folderIds},
    ),
  );
  Future<Transcript> transcript(String id) async =>
      Transcript.fromJson(await _request('GET', 'transcripts/$id'));
  Future<MeetingSummary> summary(String id) async =>
      MeetingSummary.fromJson(await _request('GET', 'summaries/$id'));
  Future<SummaryPage> summaries(
    String folderId, {
    int offset = 0,
    int limit = 20,
  }) async => SummaryPage.fromJson(
    await _request(
      'GET',
      'summaries',
      query: {'folder_id': folderId, 'limit': '$limit', 'offset': '$offset'},
    ),
  );
  Future<MeetingSummary> saveSummary(
    String id, {
    required String title,
    required String content,
  }) async => MeetingSummary.fromJson(
    await _request(
      'PATCH',
      'summaries/$id',
      body: {'title': title, 'content': content},
    ),
  );
  Future<MeetingSummary> setSummaryFolders(
    String id,
    List<String> folderIds,
  ) async => MeetingSummary.fromJson(
    await _request(
      'PUT',
      'summaries/$id/folders',
      body: {'folder_ids': folderIds},
    ),
  );
  Future<void> deleteSummary(String id) async {
    await _request('DELETE', 'summaries/$id');
  }

  Future<List<Folder>> folders() async {
    final json = await _request('GET', 'folders');
    return (json['items'] as List)
        .map((e) => Folder.fromJson(e as Json))
        .toList();
  }

  Future<Folder> createFolder(String name, {String? parentId}) async =>
      Folder.fromJson(
        await _request(
          'POST',
          'folders',
          body: {'name': name, 'parent_id': parentId},
        ),
      );
  Future<Folder> renameFolder(String id, String name) async => Folder.fromJson(
    await _request('PATCH', 'folders/$id', body: {'name': name}),
  );
  void close() => _client.close();
}

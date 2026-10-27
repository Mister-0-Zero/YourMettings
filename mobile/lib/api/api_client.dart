export 'api_error.dart';
import 'api_error.dart';
import 'demo_connection.dart';
import '../services/operation_store.dart';
import '../models/summary_template.dart';
import '../models/processing_options.dart';

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/api_models.dart';

class ApiClient {
  ApiClient(
    this.baseUri, {
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    this.operations,
    this.connection,
  }) : _client =
           connection?.client(inner: client) ?? client ?? platformHttpClient();
  final Uri baseUri;
  final DemoConnection? connection;
  final http.Client _client;
  final Duration timeout;
  final OperationStore? operations;

  Future<Json> _request(
    String method,
    String path, {
    Json? body,
    Map<String, String>? query,
    String? idempotencyKey,
  }) async {
    final uri = baseUri.resolve(path).replace(queryParameters: query);
    final abort = Completer<void>();
    final request = http.AbortableRequest(
      method,
      uri,
      abortTrigger: abort.future,
    );
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
          .timeout(
            timeout,
            onTimeout: () {
              if (!abort.isCompleted) abort.complete();
              throw TimeoutException('JSON request timeout');
            },
          );
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

  Future<Json> health() =>
      _request('GET', baseUri.resolve('/health').toString());
  Future<Json> authMe() => _request('GET', 'auth/me');
  Future<ProcessingStatus> submitTranscript({
    required String text,
    required String title,
    required List<String> folderIds,
    required String idempotencyKey,
    ProcessingOptions options = const ProcessingOptions(),
  }) async => ProcessingStatus.fromJson(
    await _request(
      'POST',
      'transcripts/process',
      body: {
        'text': text,
        'title': title,
        'folder_ids': folderIds,
        ...options.toJson(),
      },
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
    List<String> folderIds, {
    ProcessingOptions options = const ProcessingOptions(),
  }) async => ProcessingStatus.fromJson(
    await _request(
      'POST',
      'transcripts/$id/process',
      body: {'title': title, 'folder_ids': folderIds, ...options.toJson()},
    ),
  );
  Future<Transcript> transcript(String id) async =>
      Transcript.fromJson(await _request('GET', 'transcripts/$id'));
  Future<Transcript> updateTranscript(String id, String text) async =>
      Transcript.fromJson(
        await _request('PATCH', 'transcripts/$id', body: {'text': text}),
      );
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

  Future<void> deleteFolder(String id) async {
    await _request(
      'DELETE',
      'folders/$id',
      query: {'mode': 'with_contents', 'confirm': 'true'},
    );
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
  Future<List<SummaryTemplate>> templates() async {
    final json = await _request('GET', 'summary-templates');
    return [
      for (final item in json['items'] as List)
        SummaryTemplate.fromJson(item as Json),
    ];
  }

  Future<SummaryTemplate> template(String id) async =>
      SummaryTemplate.fromJson(await _request('GET', 'summary-templates/$id'));
  Future<SummaryTemplate> saveTemplate(
    TemplateInput input, {
    String? id,
  }) async => SummaryTemplate.fromJson(
    await _request(
      id == null ? 'POST' : 'PUT',
      id == null ? 'summary-templates' : 'summary-templates/$id',
      body: input.toJson(),
    ),
  );
  Future<SummaryTemplate> copyTemplate(String id) async =>
      SummaryTemplate.fromJson(
        await _request('POST', 'summary-templates/$id/copy', body: {}),
      );
  Future<void> deleteTemplate(String id) async {
    await _request('DELETE', 'summary-templates/$id');
  }

  Future<TemplatePreview> startTemplatePreview(
    TemplateInput input,
    String text,
    String detailLevel, {
    String? idempotencyKey,
  }) async => TemplatePreview.fromJson(
    await _request(
      'POST',
      'template-previews',
      idempotencyKey: idempotencyKey,
      body: {
        'template': input.toJson(),
        'text': text,
        'detail_level': detailLevel,
      },
    ),
  );
  Future<TemplatePreview> templatePreview(String id) async =>
      TemplatePreview.fromJson(await _request('GET', 'template-previews/$id'));
  Future<void> cancelTemplatePreview(String id) async {
    await _request(
      'DELETE',
      'template-previews/$id',
      query: {'confirm': 'true'},
    );
  }

  Future<Json> createSelection(Json source, String key) =>
      _request('POST', 'summary-selections', body: source, idempotencyKey: key);
  Future<Json> selection(String id) =>
      _request('GET', 'summary-selections/$id');
  Future<Json> createCandidate(String id, Json options, String key) => _request(
    'POST',
    'summary-selections/$id/candidates',
    body: options,
    idempotencyKey: key,
  );
  Future<Json> candidate(String id) =>
      _request('GET', 'summary-candidates/$id');
  Future<MeetingSummary> acceptSelection(
    String id,
    String candidateId,
    String? version,
  ) async => MeetingSummary.fromJson(
    await _request(
      'POST',
      'summary-selections/$id/accept',
      body: {'candidate_id': candidateId, 'expected_version': version},
    ),
  );
  Future<void> cancelSelection(String id) async {
    await _request(
      'DELETE',
      'summary-selections/$id',
      query: {'confirm': 'true'},
    );
  }

  void close() => _client.close();
}

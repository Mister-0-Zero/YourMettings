import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/meetings/summary_editor.dart';
import 'package:your_mettings/models/api_models.dart';

import 'summary_editor_test.dart' show summaryJson, response;

class SaveServer {
  String title = 'План', content = 'Initial';
  int revision = 1, writes = 0, reads = 0;
  bool lose = false, offlineRead = false, failBeforeWrite = false;
  Completer<void>? gate, started;
  void Function()? afterWrite;
  final patches = <Json>[];
  Json summary() => {
    ...summaryJson,
    'title': title,
    'content': content,
    'version': 'v$revision',
  };
  Future<http.Response> handle(http.Request r) async {
    if (r.method == 'GET') {
      reads++;
      if (offlineRead) throw http.ClientException('offline GET');
      return response(summary());
    }
    final body = jsonDecode(r.body) as Json;
    patches.add(body);
    if (failBeforeWrite) {
      failBeforeWrite = false;
      throw http.ClientException('lost before commit');
    }
    if (body['expected_version'] != 'v$revision') {
      return response({
        'error': {
          'code': 'summary_version_conflict',
          'message': 'Stale version',
        },
      }, 409);
    }
    title = body['title'] as String;
    content = body['content'] as String;
    revision++;
    writes++;
    if (started != null && !started!.isCompleted) started!.complete();
    await gate?.future;
    afterWrite?.call();
    if (lose) {
      lose = false;
      throw http.ClientException('lost committed PATCH reply');
    }
    return response(summary());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SummaryEditor editor(SaveServer server) {
    final api = ApiClient(
      Uri.parse('http://example/api/v1/'),
      client: MockClient(server.handle),
    );
    final e = SummaryEditor(api, MeetingSummary.fromJson(server.summary()));
    addTearDown(e.dispose);
    addTearDown(api.close);
    return e;
  }

  test('lost committed ordinary PATCH reconciles exact title AND content without duplicate write', () async {
    final server = SaveServer()..lose = true;
    final e = editor(server);
    e.edit(title: 'Local', content: '**Saved**');
    expect(await e.flush(), isTrue);
    expect(e.dirty, isFalse);
    expect(e.summary.version, 'v2');
    expect(server.writes, 1);
    expect(server.patches, hasLength(1));
    expect(await e.flush(), isTrue);
    expect(server.patches, hasLength(1));
  });
  test('lost PATCH and GET, then newer typed text: retry acknowledges old intent before saving new edit', () async {
    final server = SaveServer()
      ..lose = true
      ..offlineRead = true;
    final e = editor(server);
    e.edit(title: 'First title', content: 'First content');
    expect(await e.flush(), isFalse);
    e.edit(title: 'New title', content: 'New content');
    server.offlineRead = false;
    expect(await e.flush(), isTrue);
    expect(e.title, 'New title');
    expect(e.content, 'New content');
    expect(e.dirty, isFalse);
    expect(server.title, 'New title');
    expect(server.content, 'New content');
    expect(server.writes, 2);
    expect(server.patches, hasLength(2));
    expect(server.patches.last['expected_version'], 'v2');
  });
  test('text typed while uncertain PATCH is in flight is not replaced by GET reconciliation', () async {
    final gate = Completer<void>(), started = Completer<void>();
    final server = SaveServer()
      ..lose = true
      ..gate = gate
      ..started = started;
    final e = editor(server);
    e.edit(title: 'First', content: 'First');
    final pending = e.flush();
    await started.future;
    e.edit(title: 'Typed later', content: 'Later content');
    gate.complete();
    expect(await pending, isTrue);
    expect(e.content, 'Later content');
    expect(e.title, 'Typed later');
    expect(server.content, 'Later content');
    expect(server.writes, 2);
    expect(server.patches[1]['expected_version'], 'v2');
    expect(e.dirty, isFalse);
  });
  for (final changedField in ['title', 'content']) {
    test(
      'a real external $changedField change is not acknowledged or overwritten after lost reply',
      () async {
        final server = SaveServer()..lose = true;
        final e = editor(server);
        e.edit(title: 'Local title', content: 'Local content');
        server.afterWrite = () {
          if (changedField == 'title') {
            server.title = 'External title';
          } else {
            server.content = 'External content';
          }
          server.revision++;
          server.afterWrite = null;
        };
        expect(await e.flush(), isFalse);
        expect(e.title, 'Local title');
        expect(e.content, 'Local content');
        expect(e.dirty, isTrue);
        expect(await e.flush(), isFalse);
        expect(server.writes, 1);
        expect(
          server.patches.every((p) => p['expected_version'] == 'v1'),
          isTrue,
        );
        expect(e.error, isNotNull);
      },
    );
  }
  test('typing back to the old baseline still resolves an unknown write before saving the reversal', () async {
    final server = SaveServer()
      ..lose = true
      ..offlineRead = true;
    final e = editor(server);
    e.edit(content: 'Temporary');
    expect(await e.flush(), isFalse);
    e.edit(title: 'План', content: 'Initial');
    expect(e.dirty, isTrue);
    server.offlineRead = false;
    expect(await e.flush(), isTrue);
    expect(server.content, 'Initial');
    expect(server.writes, 2);
    expect(server.patches.last['expected_version'], 'v2');
    expect(e.dirty, isFalse);
  });

  test('explicit discard never replays an unknown old edit later', () async {
    final server = SaveServer()
      ..lose = true
      ..offlineRead = true;
    final e = editor(server);
    e.edit(content: 'Unknown write');
    expect(await e.flush(), isFalse);
    e.discardUnsaved();
    expect(e.dirty, isFalse);
    server.offlineRead = false;
    expect(await e.flush(), isTrue);
    expect(server.patches, hasLength(1));
  });
  test('unknown uncommitted PATCH retries the old exact intent before later typed changes', () async {
    final server = SaveServer()..failBeforeWrite = true;
    final e = editor(server);
    e.edit(title: 'First', content: 'First content');
    expect(await e.flush(), isFalse);
    expect(server.writes, 0);
    e.edit(title: 'Later', content: 'Later content');
    expect(await e.flush(), isTrue);
    expect(server.patches, hasLength(3));
    expect(server.patches[0], server.patches[1]);
    expect(server.patches[2]['expected_version'], 'v2');
    expect(server.writes, 2);
    expect(e.content, 'Later content');
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/api/demo_connection.dart';
import 'package:your_mettings/features/recording/audio_api.dart';
import 'package:your_mettings/features/recording/audio_engine.dart';
import 'package:your_mettings/features/recording/audio_journal.dart';
import 'package:your_mettings/features/recording/pcm_chunk_writer.dart';

import 'dart:typed_data';

import 'audio_engine_test.dart' show FakeMic;

import 'package:your_mettings/services/connection_settings.dart';
import 'package:your_mettings/services/demo_key_vault.dart';
import 'package:your_mettings/services/recorder_context.dart';
import 'package:your_mettings/services/recovery_store.dart';

class MemoryKeyVault implements DemoKeyVault {
  final values = <String, String>{};
  @override
  Future<String?> read(String origin) async => values[origin];
  @override
  Future<void> write(String origin, String key) async {
    values[origin] = key;
  }
}

const canary = 'TestOnly-CaNaRy-key-NOT-a-real-secret';
const demoUser = {
  'id': '00000000-0000-0000-0000-000000000002',
  'access_mode': 'demo',
  'email_verified_at': null,
};
http.Response response(
  Object value, [
  int code = 200,
  Map<String, String> headers = const {},
]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), code, headers: headers);

void main() {
  test('addresses normalize root/API suffix once and reject unsafe forms', () {
    for (final source in [
      'https://194.117.80.169',
      'https://194.117.80.169/',
      'https://194.117.80.169/api/v1',
      'https://194.117.80.169/api/v1/',
    ]) {
      expect(
        normalizeBackend(source, ServerProfile.https).toString(),
        '$httpsAddress/',
      );
    }
    expect(
      normalizeBackend('http://localhost:8000', ServerProfile.usb).path,
      '/api/v1/',
    );
    expect(
      normalizeBackend(
        'https://EXAMPLE.com:443/api/v1',
        ServerProfile.https,
      ).origin,
      'https://example.com',
    );
    for (final source in [
      'https://example.com/api/v1/api/v1',
      'https://user:password@example.com',
      'https://example.com?key=x',
      'http://194.117.80.169/api/v1',
      'https://example.com/#secret',
    ]) {
      expect(
        () => normalizeBackend(source, ServerProfile.https),
        throwsFormatException,
      );
    }
  });
  test('one origin-bound key on health, account, catalogs, polling and binary upload', () async {
    final vault = MemoryKeyVault()..values['https://example.com'] = canary;
    final connection = DemoConnection(
      base: Uri.parse('https://example.com/api/v1/'),
      accountId: demoUser['id'] as String,
      accessMode: 'demo',
      vault: vault,
    );
    final requests = <http.Request>[];
    final bytes = utf8.encode('synthetic audio bytes');
    final hash = sha256.convert(bytes).toString();
    Future<http.Response> backend(http.Request r) async {
      requests.add(r);
      final headers = r.headers.entries
          .where((e) => e.key.toLowerCase() == 'x-demo-key')
          .toList();
      expect(headers.length, 1);
      expect(headers.single.value, canary);
      expect(r.followRedirects, isFalse);
      expect(r.url.toString(), isNot(contains(canary)));
      if (r.url.path == '/health') return response({'status': 'ok'});
      if (r.url.path.endsWith('/auth/me')) return response(demoUser);
      if (r.url.path.endsWith('/chunks')) {
        expect(r.bodyBytes, bytes);
        expect(r.headers['Content-Type'], 'application/octet-stream');
        expect(r.url.queryParameters['content_sha256'], hash);
        expect(r.url.queryParameters['sequence_number'], '0');
        return response({
          'accepted': true,
          'safe_to_delete_local': true,
          'chunk': {'sha256': hash, 'sequence_number': 0},
        }, 201);
      }
      if (r.url.path.contains('template-previews')) {
        return response({
          'id': 'p',
          'status': 'ready',
          'content': 'Result',
          'navigation': [],
          'error': null,
        });
      }
      return response({'items': []});
    }

    final api = ApiClient(
      connection.base,
      connection: connection,
      client: MockClient(backend),
    );
    final audio = AudioApi(
      connection.base,
      connection: connection,
      client: MockClient(backend),
    );
    addTearDown(api.close);
    addTearDown(audio.close);
    await api.health();
    await api.authMe();
    await api.folders();
    await api.templates();
    await api.templatePreview('p');
    await api.candidate('c');
    await audio.json('GET', '/session');
    await audio.json('POST', '', body: {'title': 'Test'}, key: 'stable');
    final dir = await Directory.systemTemp.createTemp('ym-demo-audio-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/0.wav');
    await file.writeAsBytes(bytes);
    await audio.upload('session', file, {
      'sequence': 0,
      'start_ms': 0,
      'duration_ms': 1000,
    }, hash);
    expect(requests.length, 9);
    expect(requests.first.url.path, '/health');
    expect(requests[1].url.path, '/api/v1/auth/me');
    expect(audio.uploadTimeout, const Duration(seconds: 360));
    expect(await file.exists(), isTrue);
  });
  test(
    'key replacement applies to live clients; another origin never inherits it',
    () async {
      final vault = MemoryKeyVault()..values['https://example.com'] = canary;
      final seen = <String>[];
      http.Client client() => MockClient((r) async {
        seen.add(r.headers['X-Demo-Key']!);
        return response({'status': 'ok'});
      });
      final binding = DemoConnection(
        base: Uri.parse('https://example.com/api/v1/'),
        accountId: 'demo',
        accessMode: 'demo',
        vault: vault,
      );
      final api = ApiClient(
        binding.base,
        connection: binding,
        client: client(),
      );
      addTearDown(api.close);
      await api.health();
      await vault.write(binding.origin, 'Replacement-Test-Key');
      await api.health();
      final other = DemoConnection(
        base: Uri.parse('https://other.example/api/v1/'),
        accountId: 'demo',
        accessMode: 'demo',
        vault: vault,
      );
      final second = ApiClient(other.base, connection: other, client: client());
      addTearDown(second.close);
      await second.health();
      expect(seen, [canary, 'Replacement-Test-Key', '']);
      expect(jsonEncode(binding.toJson()), isNot(contains(canary)));
    },
  );
  test(
    'actual redirect is not followed and key never reaches another listener',
    () async {
      final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => first.close(force: true));
      addTearDown(() => second.close(force: true));
      var targetRequests = 0;
      final target = second.listen((r) {
        targetRequests++;
        r.response.statusCode = 200;
        r.response.close();
      });
      final original = first.listen((r) {
        expect(r.headers['x-demo-key'], [canary]);
        r.response.statusCode = 302;
        r.response.headers.set(
          'Location',
          'http://127.0.0.1:${second.port}/capture',
        );
        r.response.close();
      });
      addTearDown(target.cancel);
      addTearDown(original.cancel);
      final uri = Uri.parse('http://127.0.0.1:${first.port}/api/v1/');
      final vault = MemoryKeyVault()..values[uri.origin] = canary;
      final binding = DemoConnection(
        base: uri,
        accountId: 'demo',
        accessMode: 'demo',
        vault: vault,
      );
      final api = ApiClient(uri, connection: binding);
      addTearDown(api.close);
      await expectLater(
        api.health(),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 302)),
      );
      expect(targetRequests, 0);
      final client = binding.client();
      addTearDown(client.close);
      await expectLater(
        client.get(Uri.parse('http://other.example/health')),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'origin_mismatch'),
        ),
      );
      expect(targetRequests, 0);
    },
  );
  test('Retry-After is observed by the next actual request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final arrived = <DateTime>[];
    final sub = server.listen((r) {
      arrived.add(DateTime.now());
      if (arrived.length == 1) {
        r.response.statusCode = 429;
        r.response.headers.set('Retry-After', '1');
      } else {
        r.response.write(jsonEncode({'status': 'ok'}));
      }
      r.response.close();
    });
    addTearDown(sub.cancel);
    final uri = Uri.parse('http://127.0.0.1:${server.port}/api/v1/');
    final vault = MemoryKeyVault()..values[uri.origin] = canary;
    final binding = DemoConnection(
      base: uri,
      accountId: 'demo',
      accessMode: 'demo',
      vault: vault,
    );
    final api = ApiClient(uri, connection: binding);
    addTearDown(api.close);
    await expectLater(
      api.health(),
      throwsA(
        isA<ApiException>().having(
          (e) => e.retryAfter,
          'retryAfter',
          const Duration(seconds: 1),
        ),
      ),
    );
    await api.health();
    expect(
      arrived[1].difference(arrived[0]).inMilliseconds,
      greaterThanOrEqualTo(900),
    );
  });
  test('access codes remain distinct; gateway HTML and documented errors are readable', () async {
    final cases = [
      (401, 'demo_key_required'),
      (401, 'demo_key_invalid'),
      (403, 'demo_access_expired'),
      (403, 'auth_unavailable_demo'),
      (429, 'demo_rate_limited'),
      (409, 'selection_in_progress'),
      (422, 'validation_error'),
    ];
    for (final c in cases) {
      final api = ApiClient(
        Uri.parse('https://example.com/api/v1/'),
        client: MockClient(
          (_) async => response(
            {
              'error': {'code': c.$2, 'message': 'Documented reason'},
            },
            c.$1,
            {'retry-after': '42'},
          ),
        ),
      );
      await expectLater(
        api.health(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', c.$2)
              .having((e) => e.statusCode, 'status', c.$1),
        ),
      );
      api.close();
    }
    for (final status in [502, 503, 504]) {
      final api = ApiClient(
        Uri.parse('https://example.com/api/v1/'),
        client: MockClient(
          (_) async =>
              http.Response('<html>upstream unavailable</html>', status),
        ),
      );
      await expectLater(
        api.health(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.retryable, 'retryable', true)
              .having((e) => e.message, 'message', isNot(contains('<html>'))),
        ),
      );
      api.close();
    }
    expect(
      [for (var n = 1; n <= 7; n++) retryDelay(n).inSeconds],
      [2, 4, 8, 16, 30, 30, 30],
    );
    expect(retryDelay(2, minimum: const Duration(seconds: 42)).inSeconds, 42);
    expect(
      retryAfterDuration(
        HttpDate.format(DateTime.utc(2026, 10, 27, 12, 0, 30)),
        now: DateTime.utc(2026, 10, 27, 12),
      )!.inSeconds,
      30,
    );
  });
  test('settings persist without key; account/origin scopes preserve legacy and separate drafts', () async {
    final dir = await Directory.systemTemp.createTemp('ym-demo-scopes-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/connection-settings.json');
    final vault = MemoryKeyVault();
    final settings = ConnectionSettings(
      vault: vault,
      file: file,
      probeClient: () => MockClient((r) async {
        expect(r.headers['X-Demo-Key'], canary);
        return response(r.url.path == '/health' ? {'status': 'ok'} : demoUser);
      }),
    );
    addTearDown(settings.dispose);
    final legacy = FileRecoveryStore(File('${dir.path}/meeting-recovery.json'));
    await legacy.save(
      RecoveryState(draft: Draft(text: 'Personal legacy source')),
    );
    await settings.apply(ServerProfile.usb, usbAddress, canary);
    final usb = settings.active!;
    final usbDirectory = connectionDirectory(dir, usb);
    final usbStore = FileRecoveryStore(
      File('${usbDirectory.path}/meeting-recovery.json'),
    );
    expect((await usbStore.load()).draft.text, isEmpty);
    await usbStore.save(RecoveryState(draft: Draft(text: 'USB-only draft')));
    await settings.apply(ServerProfile.https, httpsAddress, canary);
    final remoteDirectory = connectionDirectory(dir, settings.active!);
    expect(remoteDirectory.path, isNot(usbDirectory.path));
    expect(
      (await FileRecoveryStore(
        File('${remoteDirectory.path}/meeting-recovery.json'),
      ).load()).draft.text,
      isEmpty,
    );
    expect((await legacy.load()).draft.text, 'Personal legacy source');
    expect((await usbStore.load()).draft.text, 'USB-only draft');
    final restored = ConnectionSettings(vault: vault, file: file);
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.profile, ServerProfile.https);
    expect(restored.active!.scopeId, settings.active!.scopeId);
    final contents = await file.readAsString();
    expect(contents, isNot(contains(canary)));
    expect(contents, isNot(contains('Personal legacy source')));
    final otherAccount = DemoConnection(
      base: usb.base,
      accountId: 'different-account',
      accessMode: 'demo',
      vault: vault,
    );
    expect(otherAccount.scopeId, isNot(usb.scopeId));
  });
  test('active-operation guard blocks profile change before credentials or settings mutate', () async {
    final vault = MemoryKeyVault();
    final settings = ConnectionSettings(
      vault: vault,
      probeClient: () => MockClient(
        (r) async =>
            response(r.url.path == '/health' ? {'status': 'ok'} : demoUser),
      ),
    );
    addTearDown(settings.dispose);
    await settings.apply(ServerProfile.usb, usbAddress, canary);
    settings.beforeApply = (_) async => 'Finish recording first';
    await expectLater(
      settings.apply(ServerProfile.https, httpsAddress, 'Another-Test-Key'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'connection_busy'),
      ),
    );
    expect(settings.profile, ServerProfile.usb);
    expect(vault.values.containsKey('https://194.117.80.169'), isFalse);
  });
  test('authenticated binary upload survives gateway failure and lost ACK with identical payload until confirmed', () async {
    final dir = await Directory.systemTemp.createTemp('ym-demo-ack-');
    addTearDown(() => dir.delete(recursive: true));
    final journal = AudioJournal(dir)
      ..data = {
        'version': 1,
        'id': 'same-session',
        'phase': 'sending',
        'chunks': <Map<String, dynamic>>[],
        'closed_ms': 0,
        'limits': {
          'chunk_target_seconds': 1,
          'max_chunk_seconds': 2,
          'max_upload_bytes': 64044,
          'max_chunks': 240,
        },
      };
    final writer = PcmChunkWriter(
      journal,
      targetSeconds: 1,
      maxSeconds: 2,
      maxBytes: 64044,
      maxChunks: 240,
    );
    writer.add(Uint8List(32000));
    writer.closeChunk();
    journal.saveSync();
    writer.release();
    final vault = MemoryKeyVault()..values['https://example.com'] = canary;
    final binding = DemoConnection(
      base: Uri.parse('https://example.com/api/v1/'),
      accountId: 'demo-account',
      accessMode: 'demo',
      vault: vault,
    );
    final requests = <http.Request>[];
    var uploads = 0;
    final api = AudioApi(
      binding.base,
      connection: binding,
      client: MockClient((r) async {
        expect(r.headers['X-Demo-Key'], canary);
        expect(r.followRedirects, isFalse);
        if (r.url.path.endsWith('/chunks')) {
          uploads++;
          requests.add(r);
          if (uploads == 1) {
            return http.Response('<html>gateway timeout</html>', 504);
          }
          if (uploads == 2) {
            throw http.ClientException('ACK lost after server accepted');
          }
          return response({
            'accepted': true,
            'safe_to_delete_local': true,
            'chunk': {
              'sequence_number': 0,
              'sha256': sha256.convert(r.bodyBytes).toString(),
            },
          }, 200);
        }
        return response({'status': 'transcribing'});
      }),
    );
    final mic = FakeMic();
    mic.audio.stream.listen((_) {});
    final engine = AudioEngine(journal, api, capture: mic);
    addTearDown(engine.dispose);
    for (var attempt = 0; attempt < 2; attempt++) {
      await engine.sync(force: true);
      expect(journal.chunkFile(0).existsSync(), isTrue);
      expect(journal.chunks.single['acked'], isFalse);
      expect(journal.data['network_error'], isTrue);
    }
    await engine.sync(force: true);
    expect(journal.chunks.single['acked'], isTrue);
    expect(journal.chunkFile(0).existsSync(), isFalse);
    expect(uploads, 3);
    for (final r in requests.skip(1)) {
      expect(r.url, requests.first.url);
      expect(r.bodyBytes, requests.first.bodyBytes);
      expect(r.headers['content-type'], 'application/octet-stream');
    }
    expect(engine.phase, 'transcribing');
  });
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:queue_owner/queue_owner.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/api/demo_connection.dart';
import 'package:your_mettings/services/demo_key_vault.dart';
import 'package:your_mettings/services/drafts/draft_workspace.dart';

class EmptyDraftVault implements DemoKeyVault {
  int reads = 0;
  @override
  Future<String?> read(String origin) async {
    reads++;
    return null;
  }

  @override
  Future<void> write(String origin, String key) async =>
      throw UnsupportedError('No test credential');
}

class TestDraftOwnerPool {
  final held = <String>{};
  bool failWrites = false, cooperativeYield = false;
  final yielding = <String>{};
  bool Function(File file, String encoded)? rejectSnapshot;
  int freeBytes = 1024 * 1024 * 1024;
  Future<void> requestYield(String scope) async {
    if (cooperativeYield) yielding.add(scope);
  }

  Future<QueueOwnerLease?> acquire(String scope) async {
    if (!held.add(scope)) return null;
    yielding.remove(scope);
    return TestDraftLease(this, scope);
  }
}

class TestDraftLease implements QueueOwnerLease {
  TestDraftLease(this.pool, this.scopeId);
  final TestDraftOwnerPool pool;
  @override
  final String scopeId;
  bool closed = false;
  Future<void> _tail = Future.value();
  @override
  Future<T> serialized<T>(Future<T> Function() action) {
    if (closed) return Future.error(const QueueOwnerLost());
    final future = _tail.then((_) => action());
    _tail = future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return future;
  }

  void _check() {
    if (closed) throw const QueueOwnerLost();
    if (pool.failWrites) throw const FileSystemException('Injected disk full');
  }

  @override
  Future<void> saveCaptureTicket(String localId, String nonce) async {
    _check();
  }

  @override
  Future<void> clearCaptureTicket(String nonce) async {
    _check();
  }

  @override
  Future<bool> shouldYield() async => closed || pool.yielding.contains(scopeId);
  @override
  Future<int> availableBytes() async => pool.freeBytes;
  @override
  Future<void> writeSnapshot(File file, String encoded) async {
    _check();
    if (pool.rejectSnapshot?.call(file, encoded) == true) {
      throw const FileSystemException('Injected handoff failure');
    }
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.test.tmp');
    await tmp.writeAsString(encoded, flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<void> eraseFile(File file) async {
    _check();
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> eraseDraft(Directory directory) async {
    _check();
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  @override
  Future<void> writeAudio(File file, Uint8List bytes) async {
    _check();
    if (await file.exists()) throw StateError('Immutable audio');
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<int> appendPcm(File file, int expectedOffset, Uint8List bytes) async {
    _check();
    if ((await file.exists() ? await file.length() : 0) != expectedOffset) {
      throw StateError('PCM offset');
    }
    await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
    return file.length();
  }

  @override
  Future<void> close() async {
    await _tail;
    closed = true;
    pool.held.remove(scopeId);
  }
}

class DraftTestFixture {
  DraftTestFixture._(
    this.root,
    this.pool,
    this.vault,
    this.connection,
    this.api,
    this.workspace,
    this.httpCalls,
  );
  final Directory root;
  final TestDraftOwnerPool pool;
  final EmptyDraftVault vault;
  final DemoConnection connection;
  final ApiClient api;
  final DraftWorkspace workspace;
  final List<Uri> httpCalls;
  static Future<DraftTestFixture> create({
    http.Response Function(http.Request request)? response,
    Duration acquireTimeout = const Duration(milliseconds: 50),
  }) async {
    final root = await Directory.systemTemp.createTemp('ym-workspace-');
    final pool = TestDraftOwnerPool(),
        vault = EmptyDraftVault(),
        calls = <Uri>[];
    final binding = DemoConnection(
      base: Uri.parse('http://127.0.0.1:65531/api/v1/'),
      accountId: 'known-account',
      accessMode: 'demo',
      vault: vault,
    );
    final api = ApiClient(
      binding.base,
      connection: binding,
      client: MockClient((request) async {
        calls.add(request.url);
        if (response != null) return response(request);
        throw http.ClientException('Intentionally offline');
      }),
    );
    final workspace = DraftWorkspace(
      directory: Directory('${root.path}/scopes/${binding.scopeId}'),
      connection: binding,
      api: api,
      acquireOwner: pool.acquire,
      yieldOwner: pool.requestYield,
      acquireTimeout: acquireTimeout,
    );
    return DraftTestFixture._(
      root,
      pool,
      vault,
      binding,
      api,
      workspace,
      calls,
    );
  }

  Future<void> close() async {
    await workspace.drain();
    workspace.dispose();
    api.close();
    await root.delete(recursive: true);
  }
}

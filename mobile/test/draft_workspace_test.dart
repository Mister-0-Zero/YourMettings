import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:queue_owner/queue_owner.dart';
import 'package:your_mettings/api/demo_connection.dart';
import 'package:your_mettings/api/api_error.dart';
import 'package:your_mettings/features/recording/draft_recorder_coordinator.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/models/summary_template.dart';
import 'package:your_mettings/services/connection_settings.dart';
import 'package:your_mettings/services/drafts/catalog_cache.dart';
import 'package:your_mettings/services/drafts/draft_record.dart';
import 'package:your_mettings/services/drafts/draft_workspace.dart';
import 'package:your_mettings/services/drafts/local_audio_capture.dart';

import 'support/draft_test_fixture.dart';
import 'audio_engine_test.dart' show FakeMic;

void main() {
  late DraftTestFixture fixture;
  setUp(() async {
    fixture = await DraftTestFixture.create();
  });
  tearDown(() async {
    await fixture.close();
  });
  test('known scope cold startup reads local drafts/cache with no credential or HTTP prerequisite', () async {
    final w = fixture.workspace;
    await w.initialize();
    final record = await w.create(
      LocalDraftKind.text,
      input: LocalDraftInput(
        title: 'Offline',
        text: 'Keep input',
        folderIds: ['nested'],
      ),
    );
    await w.withOwner((_, lease) async {
      final cache = ScopedCatalogCache(
        scopeDirectory: w.directory,
        authority: lease,
      );
      await cache.saveFolders([
        Folder(
          id: 'root',
          name: 'Root',
          children: [Folder(id: 'nested', name: 'Nested', parentId: 'root')],
        ),
      ], fetchedAt: DateTime.utc(2020));
      await cache.saveTemplates([
        SummaryTemplate(
          id: 't',
          isSystem: true,
          isDefault: true,
          input: const TemplateInput(name: 'Plan', sections: []),
          version: 'a' * 64,
        ),
      ], fetchedAt: DateTime.utc(2020));
    });
    final cold = DraftWorkspace(
      directory: w.directory,
      connection: fixture.connection,
      api: fixture.api,
      acquireOwner: fixture.pool.acquire,
    );
    addTearDown(cold.dispose);
    await cold.initialize();
    expect(cold.items.single.localId, record.localId);
    expect(cold.folders!.isStale(DateTime.now()), isTrue);
    expect(cold.templates!.items.single.version, 'a' * 64);
    expect(cold.items.single.input.folderIds, ['nested']);
    expect(fixture.httpCalls, isEmpty);
    expect(fixture.vault.reads, 0);
  });
  test('settings restore previously verified identity even when vault has no readable key', () async {
    final file = File('${fixture.root.path}/connection-settings.json');
    await file.writeAsString(
      jsonEncode({
        'version': 1,
        'profile': 'usb',
        'addresses': {'usb': usbAddress, 'https': httpsAddress},
        'active': fixture.connection.toJson(),
      }),
    );
    final settings = ConnectionSettings(vault: fixture.vault, file: file);
    addTearDown(settings.dispose);
    await settings.load();
    expect(settings.active!.scopeId, fixture.connection.scopeId);
    expect(fixture.vault.reads, 0);
    expect(fixture.httpCalls, isEmpty);
    final fresh = ConnectionSettings(vault: fixture.vault);
    addTearDown(fresh.dispose);
    await fresh.load();
    expect(fresh.active, isNull);
  });
  test('two audio captures and two text drafts stay independent; mic has no server/caps/HTTP', () async {
    final w = fixture.workspace;
    await w.initialize();
    final ids = <String>[];
    for (var n = 0; n < 2; n++) {
      final draft = await w.create(
        LocalDraftKind.audio,
        input: LocalDraftInput(title: 'Audio $n'),
      );
      ids.add(draft.localId);
      await w.withOwner((repo, lease) async {
        final mic = FakeMic();
        final capture = LocalAudioCapture(
          repository: repo,
          authority: lease,
          localId: draft.localId,
          microphone: mic,
        );
        await capture.start();
        mic.audio.add(Uint8List(3200)..[0] = n + 1);
        await capture.pause();
        await capture.resume();
        mic.audio.add(Uint8List(3200));
        await capture.stop();
        await capture.dispose();
      });
    }
    for (var n = 0; n < 2; n++) {
      ids.add(
        (await w.create(
          LocalDraftKind.text,
          input: LocalDraftInput(title: 'Text $n', text: 'Body $n'),
        )).localId,
      );
    }
    await w.reload();
    expect(ids.toSet().length, 4);
    expect(w.items.length, 4);
    for (var n = 0; n < 2; n++) {
      final pcm = await File(
        '${w.reader.draftDirectory(ids[n]).path}/source.pcm',
      ).readAsBytes();
      expect(pcm.length, 6400);
      expect(pcm.first, n + 1);
      final record = await w.reader.read(ids[n]);
      expect(record.serverIds, isEmpty);
      expect(record.requests, isEmpty);
      expect(record.autoStart, isFalse);
    }
    expect((await w.reader.read(ids[2])).input.text, 'Body 0');
    expect((await w.reader.read(ids[3])).input.text, 'Body 1');
    expect(fixture.httpCalls, isEmpty);
  });
  test('settings persist independently; default review ON, automatic and opt-in are separate', () async {
    final w = fixture.workspace;
    await w.initialize();
    var item = await w.create(LocalDraftKind.audio);
    expect(item.input.processingMode, 'review');
    expect(item.autoStart, isFalse);
    item = await w.save(
      item.localId,
      revision: item.revision,
      input: LocalDraftInput(
        title: 'Automatic',
        folderIds: ['nested'],
        processingMode: 'automatic',
        options: {
          'template_id': 't',
          'expected_template_version': 'b' * 64,
          'detail_level': 'detailed',
        },
      ),
      autoStart: false,
    );
    final restored = await w.reader.read(item.localId);
    expect(restored.input.processingMode, 'automatic');
    expect(restored.autoStart, isFalse);
    expect(restored.input.options['expected_template_version'], 'b' * 64);
    expect(restored.input.folderIds, ['nested']);
  });
  test(
    'disk failure cannot claim saved or replace previous committed input',
    () async {
      final w = fixture.workspace;
      await w.initialize();
      final item = await w.create(
        LocalDraftKind.text,
        input: LocalDraftInput(text: 'old'),
      );
      fixture.pool.failWrites = true;
      await expectLater(
        w.save(
          item.localId,
          revision: item.revision,
          input: LocalDraftInput(text: 'unsaved'),
          autoStart: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect((await w.reader.read(item.localId)).input.text, 'old');
      fixture.pool.failWrites = false;
      await w.save(
        item.localId,
        revision: item.revision,
        input: LocalDraftInput(text: 'unsaved'),
        autoStart: true,
      );
      expect((await w.reader.read(item.localId)).input.text, 'unsaved');
    },
  );
  test('local deletion explicit; pending remote intent remains frozen and cannot be removed', () async {
    final w = fixture.workspace;
    await w.initialize();
    final clean = await w.create(LocalDraftKind.text);
    await expectLater(w.deleteLocal(clean, confirmed: false), throwsStateError);
    await w.deleteLocal(clean, confirmed: true);
    expect(await w.reader.draftDirectory(clean.localId).exists(), isFalse);
    final remote = await w.create(
      LocalDraftKind.text,
      input: LocalDraftInput(text: 'editable'),
    );
    await w.withOwner(
      (repo, _) => repo.freezeRequest(
        remote.localId,
        remote.revision,
        'submit',
        FrozenDraftRequest(
          method: 'POST',
          path: 'transcripts/process',
          key: 'old-key',
          body: {'text': 'frozen'},
        ),
      ),
    );
    final pending = await w.reader.read(remote.localId);
    final edited = await w.save(
      pending.localId,
      revision: pending.revision,
      input: LocalDraftInput(text: 'new edits'),
      autoStart: false,
    );
    await expectLater(w.deleteLocal(edited, confirmed: true), throwsStateError);
    final stored = await w.reader.read(pending.localId);
    expect(stored.requests['submit']!.key, 'old-key');
    expect(stored.requests['submit']!.body, {'text': 'frozen'});
  });
  test(
    'live capture owner permits read-only local UI but excludes new writers',
    () async {
      final w = fixture.workspace;
      await w.initialize();
      await w.create(LocalDraftKind.text, input: LocalDraftInput(text: 'Keep'));
      final held = await fixture.pool.acquire(fixture.connection.scopeId);
      final cold = DraftWorkspace(
        directory: w.directory,
        connection: fixture.connection,
        api: fixture.api,
        acquireOwner: fixture.pool.acquire,
        yieldOwner: fixture.pool.requestYield,
        acquireTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(cold.dispose);
      await cold.initialize(legacyTextOwnerStopped: true);
      expect(cold.items.single.input.text, 'Keep');
      await expectLater(
        cold.create(LocalDraftKind.audio),
        throwsA(isA<QueueOwnerLost>()),
      );
      await held!.close();
      expect(
        (await cold.create(LocalDraftKind.audio)).kind,
        LocalDraftKind.audio,
      );
    },
  );
  test('new account/origin has no draft/cache transfer and stale service commands fail', () async {
    final w = fixture.workspace;
    await w.initialize();
    await w.create(LocalDraftKind.text, input: LocalDraftInput(text: 'Scoped'));
    final other = DemoConnection(
      base: fixture.connection.base,
      accountId: 'other',
      accessMode: 'demo',
      vault: fixture.vault,
    );
    final empty = DraftWorkspace(
      directory: Directory('${fixture.root.path}/scopes/${other.scopeId}'),
      connection: other,
      api: fixture.api,
      acquireOwner: fixture.pool.acquire,
    );
    addTearDown(empty.dispose);
    await empty.initialize();
    expect(empty.items, isEmpty);
    expect(empty.folders, isNull);
    final command = <String, dynamic>{
      'queue_protocol': 2,
      'scope_id': fixture.connection.scopeId,
      'local_id': 'local',
      'service_instance': 'old',
    };
    expect(
      draftCaptureCommandMatches(
        command,
        scope: fixture.connection.scopeId,
        localId: 'local',
        instance: 'old',
      ),
      isTrue,
    );
    expect(
      draftCaptureCommandMatches(
        command,
        scope: other.scopeId,
        localId: 'local',
        instance: 'old',
      ),
      isFalse,
    );
    expect(
      draftCaptureCommandMatches(
        command,
        scope: fixture.connection.scopeId,
        localId: 'next',
        instance: 'old',
      ),
      isFalse,
    );
    expect(
      draftCaptureCommandMatches(
        command,
        scope: fixture.connection.scopeId,
        localId: 'local',
        instance: 'new',
      ),
      isFalse,
    );
  });
  test('failed auth/catalog refresh preserves stale cache and selected unavailable IDs', () async {
    final w = fixture.workspace;
    await w.initialize();
    await w.withOwner(
      (_, lease) =>
          ScopedCatalogCache(
            scopeDirectory: w.directory,
            authority: lease,
          ).saveFolders([
            Folder(id: 'old', name: 'Old'),
          ], fetchedAt: DateTime.utc(2020)),
    );
    final item = await w.create(
      LocalDraftKind.text,
      input: LocalDraftInput(
        folderIds: ['old', 'missing'],
        options: {'template_id': 'missing-template'},
      ),
    );
    await w.initialize();
    await w.refreshCatalogs();
    expect(w.catalogError, isNotNull);
    expect(w.folders!.items.single.id, 'old');
    expect((await w.reader.read(item.localId)).input.folderIds, [
      'old',
      'missing',
    ]);
    expect(
      (await w.reader.read(item.localId)).input.options['template_id'],
      'missing-template',
    );
  });
  test(
    'low disk refuses mic before opening and preserves durable draft',
    () async {
      final w = fixture.workspace;
      await w.initialize();
      final item = await w.create(LocalDraftKind.audio);
      fixture.pool.freeBytes = 1;
      await w.withOwner((repo, lease) async {
        final mic = FakeMic();
        final capture = LocalAudioCapture(
          repository: repo,
          authority: lease,
          localId: item.localId,
          microphone: mic,
        );
        await expectLater(capture.start(), throwsA(isA<QueueStorageFailure>()));
        expect((await repo.read(item.localId)).toJson()['state'], 'draft');
        mic.audio.stream.listen((_) {});
        await capture.dispose();
      });
    },
  );
  test('late authorization error of restored old scope does not affect the new account', () async {
    final file = File('${fixture.root.path}/connection-settings.json');
    await file.writeAsString(
      jsonEncode({
        'version': 1,
        'profile': 'usb',
        'addresses': {'usb': usbAddress, 'https': httpsAddress},
        'active': fixture.connection.toJson(),
      }),
    );
    final settings = ConnectionSettings(vault: fixture.vault, file: file);
    addTearDown(settings.dispose);
    await settings.load();
    final old = settings.active!;
    settings.active = DemoConnection(
      base: old.base,
      accountId: 'next-account',
      accessMode: 'demo',
      vault: fixture.vault,
    );
    old.report(
      const ApiException(
        'demo_access_expired',
        'Old access expired',
        statusCode: 401,
      ),
    );
    expect(settings.accessError, isNull);
  });
}

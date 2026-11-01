import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/models/processing_options.dart';
import 'package:your_mettings/models/summary_template.dart';
import 'package:your_mettings/services/drafts/catalog_cache.dart';
import 'package:your_mettings/services/drafts/draft_repository.dart';
import 'package:your_mettings/services/drafts/legacy_draft_import.dart';
import 'package:your_mettings/services/recovery_store.dart';

import 'draft_repository_test.dart' show TestAuthority;

void main() {
  final scope = List.filled(64, 'a').join();
  late Directory root, scoped;
  late LocalDraftRepository repo;
  late ScopedCatalogCache cache;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ym-cache-migration-');
    scoped = Directory('${root.path}/$scope');
    await scoped.create();
    final authority = TestAuthority(scope);
    repo = LocalDraftRepository(scopeDirectory: scoped, authority: authority);
    cache = ScopedCatalogCache(scopeDirectory: scoped, authority: authority);
  });
  tearDown(() async => root.delete(recursive: true));

  test('nested folders/template metadata/version load offline from last good scoped cache', () async {
    final now = DateTime.utc(2026, 11, 1, 12);
    await cache.saveFolders([
      Folder(
        id: 'a',
        name: 'A',
        children: [Folder(id: 'b', name: 'B', parentId: 'a')],
      ),
    ], fetchedAt: now);
    final version = List.filled(64, 'f').join();
    await cache.saveTemplates([
      SummaryTemplate(
        id: 't',
        input: const TemplateInput(name: 'Plan', sections: []),
        isSystem: true,
        isDefault: true,
        version: version,
      ),
    ], fetchedAt: now);
    final cold = ScopedCatalogCache(
      scopeDirectory: scoped,
      authority: repo.authority,
    );
    final folders = (await cold.loadFolders())!;
    expect(flattenFolders(folders.items).map((e) => e.path), ['A', 'A / B']);
    expect(folders.isStale(now.add(const Duration(hours: 1))), isFalse);
    expect(folders.isStale(now.add(const Duration(days: 2))), isTrue);
    expect(folders.isStale(now.subtract(const Duration(minutes: 1))), isTrue);
    final templates = (await cold.loadTemplates())!;
    expect(templates.items.single.version, version);
    expect(templates.items.single.input.name, 'Plan');
  });
  test('failed/invalid refresh does not overwrite good cache; foreign scope cannot be read', () async {
    await cache.saveFolders([Folder(id: 'a', name: 'A')]);
    await expectLater(
      cache.saveFolders([
        Folder(id: 'a', name: 'A'),
        Folder(id: 'a', name: 'duplicate'),
      ]),
      throwsA(isA<FormatException>()),
    );
    expect((await cache.loadFolders())!.items.single.name, 'A');
    final file = File('${scoped.path}/catalog-folders.json');
    final j = jsonDecode(await file.readAsString()) as Json;
    j['scope_id'] = List.filled(64, 'b').join();
    await file.writeAsString(jsonEncode(j));
    await expectLater(cache.loadFolders(), throwsA(isA<FormatException>()));
    expect(await file.exists(), isTrue);
  });
  test(
    'different account/origin scope has no implicit catalog or draft transfer',
    () async {
      await cache.saveFolders([Folder(id: 'a', name: 'A')]);
      final other = List.filled(64, 'b').join();
      final isolated = ScopedCatalogCache(
        scopeDirectory: Directory('${root.path}/$other'),
        authority: TestAuthority(other),
      );
      expect(await isolated.loadFolders(), isNull);
      expect(await isolated.loadTemplates(), isNull);
    },
  );
  test('legacy pending text survives cold staging with exact old payload/key and editable input separated', () async {
    final old = File('${scoped.path}/meeting-recovery.json');
    final state = RecoveryState(
      draft: Draft(
        text: 'new editable input',
        title: 'new title',
        folderIds: ['new-folder'],
      ),
      pending: PendingRequest(
        'existing-key',
        Draft(
          text: 'frozen old request',
          title: 'old title',
          folderIds: ['old-folder'],
          options: const ProcessingOptions(detailLevel: 'brief'),
        ),
      ),
    );
    await FileRecoveryStore(old).save(state);
    final bytes = await old.readAsBytes();
    final staged = (await LegacyDraftImporter(repo).stageTextRecovery())!;
    expect(staged.input.text, 'new editable input');
    expect(staged.input.title, 'new title');
    expect(staged.requests['legacy-text-submit']!.key, 'existing-key');
    expect(staged.requests['legacy-text-submit']!.body, {
      'text': 'frozen old request',
      'title': 'old title',
      'folder_ids': ['old-folder'],
      'detail_level': 'brief',
      'focus_areas': [],
      'additional_instructions': '',
    });
    expect(staged.toJson()['state'], 'migration_pending');
    expect(staged.autoStart, isFalse);
    final cold = LocalDraftRepository(
      scopeDirectory: scoped,
      authority: repo.authority,
    );
    final repeated = (await LegacyDraftImporter(cold).stageTextRecovery())!;
    expect(repeated.localId, staged.localId);
    expect((await cold.list()).items, hasLength(1));
    expect(await old.readAsBytes(), bytes);
    expect(
      repeated.requests['legacy-text-submit']!.encodedBody,
      staged.requests['legacy-text-submit']!.encodedBody,
    );
  });
  test('accepted legacy transcript is preserved as an accepted ID and never a fresh submit', () async {
    final file = File('${scoped.path}/meeting-recovery.json');
    await FileRecoveryStore(file).save(
      RecoveryState(
        operation: AcceptedOperation('existing-transcript', 'accepted title', [
          'f',
        ]),
      ),
    );
    final staged = (await LegacyDraftImporter(repo).stageTextRecovery())!;
    expect(staged.serverIds, {'transcript_id': 'existing-transcript'});
    expect(staged.requests, isEmpty);
    expect(staged.toJson()['state'], 'migration_pending');
    final current = await FileRecoveryStore(file).load();
    expect(current.operation!.id, 'existing-transcript');
  });
  test('legacy selections and accept receipts stage separately without being imported as submit tasks', () async {
    final source = File('${scoped.path}/generation-operations.json');
    final operations = {
      'version': 1,
      'items': {
        'text-selection': {
          'key': 'selection-key',
          'source': {'text': 'kept'},
          'session_id': 'selected',
          'accept_id': 'candidate',
          'receipt': {'id': 'summary', 'content': 'accepted body'},
          'accept_protocol': 'atomic-v1',
        },
        'summary-selection:other': {
          'session_id': 'other',
          'cancel_pending': true,
        },
      },
    };
    await source.writeAsString(jsonEncode(operations), flush: true);
    final original = await source.readAsBytes();
    await LegacyDraftImporter(repo).stageOperationCheckpoints();
    await LegacyDraftImporter(repo).stageOperationCheckpoints();
    final archived = jsonDecode(
      await File('${scoped.path}/drafts-migration/legacy-operations.json')
          .readAsString(),
    ) as Json;
    expect(archived['payload'], operations);
    expect(archived['dispatch'], 'blocked');
    expect((await repo.list()).items, isEmpty);
    expect(await source.readAsBytes(), original);
  });
  test('legacy source changed during adoption is blocked without creating a duplicate or deleting original', () async {
    final source = File('${scoped.path}/meeting-recovery.json');
    final old = FileRecoveryStore(source);
    await old.save(RecoveryState(draft: Draft(text: 'one')));
    await LegacyDraftImporter(repo).stageTextRecovery();
    await old.save(RecoveryState(draft: Draft(text: 'two')));
    await expectLater(
      LegacyDraftImporter(repo).stageTextRecovery(),
      throwsA(isA<LegacySourceChanged>()),
    );
    expect((await repo.list()).items, hasLength(1));
    expect((await old.load()).draft.text, 'two');
  });
}

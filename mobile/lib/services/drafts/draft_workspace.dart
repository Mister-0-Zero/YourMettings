import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:queue_owner/queue_owner.dart';

import '../../api/api_client.dart';
import '../../api/demo_connection.dart';
import '../../models/api_models.dart';
import '../../models/summary_template.dart';
import 'catalog_cache.dart';
import 'draft_access.dart';
import 'draft_record.dart';
import 'draft_repository.dart';
import 'legacy_draft_handoff.dart';

class DraftWorkspace extends ChangeNotifier {
  DraftWorkspace({
    required this.directory,
    required this.connection,
    required this.api,
    AcquireDraftOwner? acquireOwner,
  }) : acquireOwner = acquireOwner ?? NativeQueueOwner.acquire;
  final Directory directory;
  final DemoConnection connection;
  final ApiClient api;
  final AcquireDraftOwner acquireOwner;
  bool _closed = false, refreshing = false;
  Future<void> _mutations = Future.value();
  List<LocalDraftRecord> items = [];
  List<DraftLoadIssue> issues = [];
  CachedCatalog<Folder>? folders;
  CachedCatalog<SummaryTemplate>? templates;
  String? catalogError, localError;
  List<String> migrationNotices = [];
  LocalDraftRepository get reader => LocalDraftRepository(
    scopeDirectory: directory,
    authority: ReadOnlyDraftAuthority(connection.scopeId),
  );
  ScopedCatalogCache get _cacheReader => ScopedCatalogCache(
    scopeDirectory: directory,
    authority: ReadOnlyDraftAuthority(connection.scopeId),
  );
  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<T> withOwner<T>(
    Future<T> Function(LocalDraftRepository repository, QueueOwnerLease lease)
    action,
  ) {
    if (_closed) return Future.error(StateError('Workspace closed'));
    final task = _mutations.then((_) async {
      final lease = await acquireOwner(connection.scopeId);
      if (lease == null) throw const QueueOwnerLost();
      try {
        return await action(
          LocalDraftRepository(scopeDirectory: directory, authority: lease),
          lease,
        );
      } finally {
        await lease.close();
      }
    });
    _mutations = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  /// All awaited startup work is local. HTTP/catalog refresh is a later trigger.
  Future<void> initialize({
    bool legacyTextOwnerStopped = false,
    bool legacyAudioOwnerStopped = false,
  }) async {
    await directory.create(recursive: true);
    await reload();
    try {
      folders = await _cacheReader.loadFolders();
    } catch (_) {
      localError = 'Не удалось открыть кэш папок. Выбранные папки сохранены в черновиках.';
    }
    try {
      templates = await _cacheReader.loadTemplates();
    } catch (_) {
      localError =
          'Не удалось открыть кэш шаблонов. Настройки черновиков сохранены.';
    }
    try {
      await withOwner((repository, lease) async {
        final binding = File('${directory.path}/queue-binding.json');
        await lease.serialized(() async {
          if (await FileSystemEntity.isLink(binding.path)) {
            throw const FileSystemException('Binding is a link');
          }
          if (await binding.exists()) {
            final raw = jsonDecode(await binding.readAsString()) as Json;
            if (raw['schema'] != 1 ||
                raw['scope_id'] != connection.scopeId ||
                jsonEncode(raw['connection']) !=
                    jsonEncode(connection.toJson())) {
              throw const FormatException('Immutable scope binding differs');
            }
          } else {
            await lease.writeSnapshot(
              binding,
              jsonEncode({
                'schema': 1,
                'scope_id': connection.scopeId,
                'connection': connection.toJson(),
              }),
            );
          }
        });
        await repository.recoverLocalDeletions();
        if (legacyTextOwnerStopped) {
          migrationNotices = await LegacyDraftHandoff(repository).run(
            textOwnerStopped: true,
            audioOwnerStopped: legacyAudioOwnerStopped,
          );
        }
      });
    } on QueueOwnerLost {
      // Live FGS/headless ownership does not block read-only local UI.
      migrationNotices = ['owner_live'];
    } catch (_) {
      localError = 'Прежние данные сохранены. Не удалось завершить их перенос; откройте прежнюю встречу или повторите запуск.';
    }
    await reload();
    _notify();
  }

  Future<void> reload() async {
    try {
      final listing = await reader.list();
      if (_closed) return;
      items = listing.items;
      issues = listing.issues;
    } catch (_) {
      localError = 'Не удалось прочитать черновики. Файлы не удалены.';
    }
    _notify();
  }

  Future<LocalDraftRecord> create(
    LocalDraftKind kind, {
    LocalDraftInput? input,
  }) async {
    final result = await withOwner(
      (repo, _) => repo.create(
        LocalDraftRecord.create(
          scopeId: connection.scopeId,
          kind: kind,
          input: input,
        ),
      ),
    );
    await reload();
    return result;
  }

  Future<LocalDraftRecord> save(
    String id, {
    required int revision,
    required LocalDraftInput input,
    required bool autoStart,
  }) async {
    final result = await withOwner((repo, _) async {
      final current = await repo.read(id);
      if ([
        'recording',
        'paused',
        'capturing',
        'legacy_bridge',
        'migration_pending',
        'migration_prepared',
      ].contains(current.toJson()['state'])) {
        throw StateError('Draft owner must complete handoff before editing');
      }
      return repo.update(
        id,
        expectedRevision: revision,
        change: (json) {
          json['input'] = input.toJson();
          json['auto_start_when_online'] = autoStart;
        },
      );
    });
    await reload();
    return result;
  }

  Future<void> deleteLocal(
    LocalDraftRecord record, {
    required bool confirmed,
  }) async {
    if (record.toJson()['state'] == 'legacy_bridge') {
      throw StateError('Legacy flow owns this source');
    }
    await withOwner(
      (repo, _) => repo.deleteLocal(
        record.localId,
        expectedRevision: record.revision,
        confirmed: confirmed,
        remoteOutcomeConfirmed: false,
      ),
    );
    await reload();
  }

  /// Failure never clears selected IDs or the last-good catalog. Verify identity
  /// on this immutable origin before persisting metadata for this scope.
  Future<void> refreshCatalogs() async {
    if (refreshing || _closed) return;
    refreshing = true;
    _notify();
    try {
      final identity = await api.authMe();
      if (identity['id'] != connection.accountId ||
          identity['access_mode'] != connection.accessMode) {
        throw const ApiException(
          'scope_changed',
          'Сервер подтвердил другой аккаунт. Отправка приостановлена.',
        );
      }
      final result = await Future.wait<Object>([
        api.folders(),
        api.templates(),
      ]);
      final nextFolders = result[0] as List<Folder>,
          nextTemplates = result[1] as List<SummaryTemplate>;
      await withOwner((_, lease) async {
        final cache = ScopedCatalogCache(
          scopeDirectory: directory,
          authority: lease,
        );
        await cache.saveFolders(nextFolders);
        await cache.saveTemplates(nextTemplates);
      });
      folders = await _cacheReader.loadFolders();
      templates = await _cacheReader.loadTemplates();
      catalogError = null;
    } on QueueOwnerLost {
      catalogError = 'Кэш обновится после завершения записи. Сохранённые варианты доступны.';
    } catch (error) {
      catalogError = error is ApiException
          ? error.message
          : 'Сервер недоступен. Используются сохранённые папки и шаблоны.';
    } finally {
      refreshing = false;
      _notify();
    }
  }

  bool get legacyTextHandoffPending => items.any(
    (record) =>
        record.toJson()['state'] == 'migration_prepared' &&
        ((record.toJson()['checkpoints'] as Json)['legacy']
                as Json?)?['source'] ==
            'meeting-recovery.json',
  );
  void reportLegacyError() {
    localError = 'Прежняя операция пока не восстановлена. Её данные сохранены; подключитесь к серверу и повторите.';
    _notify();
  }

  Future<void> drain() => _mutations;
  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}

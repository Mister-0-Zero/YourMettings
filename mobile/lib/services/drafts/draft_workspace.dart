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
import 'queue_journal.dart';

class DraftWorkspace extends ChangeNotifier {
  DraftWorkspace({
    required this.directory,
    required this.connection,
    required this.api,
    AcquireDraftOwner? acquireOwner,
    Future<void> Function(String)? yieldOwner,
    this.acquireTimeout = const Duration(seconds: 3),
  }) : acquireOwner = acquireOwner ?? NativeQueueOwner.acquire,
       yieldOwner = yieldOwner ?? NativeQueueOwner.requestYield;
  final Directory directory;
  final DemoConnection connection;
  final ApiClient api;
  final AcquireDraftOwner acquireOwner;
  final Future<void> Function(String) yieldOwner;
  final Duration acquireTimeout;
  bool _closed = false, refreshing = false;
  Future<void> Function()? wakeQueue;
  List<Json> completions = [];
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
    action, {
    bool requestHandoff = true,
  }) {
    if (_closed) return Future.error(StateError('Workspace closed'));
    final task = _mutations.then((_) async {
      var lease = await acquireOwner(connection.scopeId);
      if (lease == null && requestHandoff) {
        await yieldOwner(connection.scopeId);
        final until = DateTime.now().add(acquireTimeout);
        while (lease == null && DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          lease = await acquireOwner(connection.scopeId);
        }
      }
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
      final completed = File('${directory.path}/queue-completions.json');
      completions =
          await completed.exists() &&
              !await FileSystemEntity.isLink(completed.path)
          ? ((jsonDecode(await completed.readAsString()) as Json)['items']
                    as List)
                .cast<Json>()
          : [];
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
    LocalDraftInput? originalInput,
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
        expectedRevision:
            current.revision == revision ||
                originalInput != null &&
                    draftInputFingerprint(current.input) ==
                        draftInputFingerprint(originalInput)
            ? current.revision
            : revision,
        change: (json) {
          json['input'] = input.toJson();
          json['auto_start_when_online'] = autoStart;
        },
      );
    });
    await reload();
    unawaited(wakeQueue?.call());
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

  Future<void> queueAction(
    String id,
    String action, {
    bool boundariesReviewed = false,
    bool repair = false,
  }) async {
    await withOwner((repo, _) async {
      final journal = QueueJournal(repo, id);
      final record = await journal.read();
      if ([
        'legacy_bridge',
        'migration_pending',
        'migration_prepared',
        'recording',
        'paused',
        'capturing',
      ].contains(record.toJson()['state'])) {
        throw StateError('Another flow owns source');
      }
      final q = draftQueue(record);
      final fields = <String, dynamic>{
        'next_attempt_at': null,
        'attempt': 0,
        'error_code': null,
      };
      switch (action) {
        case 'start':
        case 'retry':
        case 'reconcile':
          if (record.input.title.trim().isEmpty ||
              (record.kind == LocalDraftKind.text ||
                      record.input.processingMode == 'automatic' ||
                      q['stage'] == 'review_required') &&
                  record.input.folderIds.isEmpty) {
            throw const FormatException(
              'Укажите название и хотя бы одну папку.',
            );
          }
          fields.addAll({'requested': true, 'paused': false, 'command': null});
          if (action == 'reconcile') fields['keep_accepted_parameters'] = true;
          if (q['selection_source_rejected'] == true &&
              record.serverIds['selection_id'] == null &&
              action != 'reconcile') {
            final state =
                (record.toJson()['checkpoints'] as Json)['selection'] as Json?;
            if (state != null &&
                (record.toJson()['receipts']
                        as Json)['selection-reject:${state['key']}'] !=
                    null) {
              await journal.change((j) {
                final c = j['checkpoints'] as Json;
                final history = c['rejected_selections'] as Json? ?? {};
                history[state['key'] as String] = state;
                c['rejected_selections'] = history;
                c['selection'] = null;
              });
              fields.addAll({
                'selection_source_rejected': false,
                'input_at_boundary': null,
              });
            }
          }

          if (record.serverIds.isEmpty && action != 'reconcile') {
            final slot = record.kind == LocalDraftKind.audio
                ? audioCreateSlot(record)
                : textCreateSlot(record);
            if ((record.toJson()['receipts'] as Json)[slot] is Json &&
                ((record.toJson()['receipts'] as Json)[slot]
                        as Json)['_rejected'] ==
                    true) {
              fields[record.kind == LocalDraftKind.audio
                      ? 'audio_create_slot'
                      : 'text_create_slot'] =
                  '${record.kind.name}-create:${newSectionId()}';
            }
          }

          if (q['selection_cancelled_key'] != null &&
              (record.toJson()['checkpoints'] as Json)['selection'] == null) {
            final receipt =
                (record.toJson()['receipts']
                        as Json)['selection-cancel:${q['selection_cancelled_key']}']
                    as Json?;
            if (receipt?['cancel_confirmed'] == true) {
              fields.addAll({
                'selection_cancelled_key': null,
                'input_at_boundary': null,
                'retry_kind': null,
                'error_code': null,
              });
            }
          }
          if ((record.toJson()['checkpoints'] as Json)['review_source'] !=
                  null &&
              action != 'reconcile') {
            fields.addAll({
              'review_confirmed': true,
              'boundaries_reviewed': boundariesReviewed,
              'review_attempt': newSectionId(),
            });
          }
          if (action == 'retry' &&
              record.serverIds['transcript_id'] != null &&
              q['stage'] == 'needs_action' &&
              ![
                'boundary_review_required',
                'review_outdated',
              ].contains(q['error_code'])) {
            fields.addAll({
              'retry_kind': record.kind == LocalDraftKind.text
                  ? 'text'
                  : audioCreate(record)?.body['processing_mode'] == 'automatic'
                  ? 'pipeline'
                  : 'asr',
              'retry_attempt': newSectionId(),
              'repair_parameters': repair,
            });
          } else if (action == 'retry' &&
              record.kind == LocalDraftKind.audio &&
              record.serverIds['audio_session_id'] != null &&
              q['stage'] == 'needs_action' &&
              q['error_code'] != 'pipeline_parameters_locked') {
            fields.addAll({
              'retry_kind': 'asr',
              'retry_attempt': newSectionId(),
            });
          }
          if (action == 'retry' &&
              (record.toJson()['checkpoints'] as Json)['selection'] != null &&
              q['stage'] == 'needs_action') {
            fields.addAll({
              'retry_kind': 'candidate',
              'retry_attempt': newSectionId(),
            });
          }
        case 'pause':
          fields['paused'] = true;
        case 'cancel':
        case 'delete':
          fields.addAll({'paused': true, 'command': action});
        default:
          throw ArgumentError('Unknown queue action');
      }
      // Preserve interrupted audio: resume/finish is explicit, never open mic.
      await journal.status(
        'queued',
        fields: fields,
        state:
            record.kind == LocalDraftKind.audio &&
                record.toJson()['state'] == 'interrupted'
            ? 'ready'
            : null,
      );
    });
    await reload();
    unawaited(wakeQueue?.call());
  }

  Future<void> pauseQueueScope(bool paused) async {
    await withOwner(
      (_, lease) => lease.serialized(
        () => lease.writeSnapshot(
          File('${directory.path}/queue-control.json'),
          jsonEncode({'schema': 1, 'paused': paused}),
        ),
      ),
    );
  }

  Future<void> accessRestored() async {
    await withOwner((repo, _) async {
      for (final record in (await repo.list()).items) {
        if (draftQueue(record)['stage'] == 'auth_blocked') {
          await QueueJournal(repo, record.localId).status(
            'queued',
            fields: {'next_attempt_at': null, 'attempt': 0, 'error_code': null},
          );
        }
      }
    });
    unawaited(wakeQueue?.call());
  }

  void reportQueueSchedulingError() {
    localError = 'Фоновое продолжение пока недоступно. Данные сохранены; откройте приложение для продолжения.';
    _notify();
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

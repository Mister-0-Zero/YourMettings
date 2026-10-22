import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../api/api_client.dart';
import '../../models/api_models.dart';
import '../../services/recovery_store.dart';

class MeetingController extends ChangeNotifier {
  MeetingController(this.api, this.store);
  final ApiClient api;
  final RecoveryStore store;
  RecoveryState recovery = RecoveryState();
  List<Folder> folders = [];
  ProcessingStatus? status;
  MeetingSummary? result;
  bool working = false;
  bool loadingFolders = false;
  Completer<void>? _folderLoad;
  String? error;
  String? folderError;
  String? storageError;
  Timer? _timer;
  int _interval = 2;
  bool _paused = false;
  bool _disposed = false;
  int _failures = 0;
  bool get hasOperation =>
      recovery.pending != null || recovery.operation != null;
  Draft get draft => recovery.draft;

  Future<void> initialize() async {
    recovery = await store.load();
    notifyListeners();
    if (hasOperation) unawaited(check());
    unawaited(loadFolders());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _persist() async {
    try {
      await store.save(recovery);
      storageError = null;
    } catch (_) {
      storageError =
          'Не удалось сохранить состояние на устройстве. Повторите сохранение.';
      rethrow;
    } finally {
      _notify();
    }
  }

  Future<void> saveDraft(Draft value) async {
    if (hasOperation) return;
    recovery = RecoveryState(draft: value);
    try {
      await _persist();
    } catch (_) {
      /* UI exposes storageError; keep input. */
    }
  }

  Future<void> loadFolders() async {
    if (loadingFolders) {
      await _folderLoad?.future;
      return;
    }
    final completed = _folderLoad = Completer<void>();
    loadingFolders = true;
    folderError = null;
    _notify();
    try {
      folders = await api.folders();
    } catch (e) {
      folderError = e.toString();
    } finally {
      loadingFolders = false;
      _folderLoad = null;
      completed.complete();
      _notify();
    }
  }

  Future<Folder> createFolder(String name, {String? parentId}) async {
    final folder = await api.createFolder(name, parentId: parentId);
    // An older GET may have captured the tree before this POST committed.
    await _folderLoad?.future;
    await loadFolders();
    return folder;
  }

  Future<void> deleteFolder(Folder folder) async {
    if (working) {
      throw const ApiException(
        'operation_busy',
        'Дождитесь завершения текущего запроса и повторите удаление.',
      );
    }
    final removed = flattenFolders([folder])
        .map((entry) => entry.folder.id)
        .toSet();
    await api.deleteFolder(
      folder.id,
    ); // Update local state only after confirmed 204.
    final pending = recovery.pending;
    final original = pending?.draft ?? draft;
    if (original.folderIds.any(removed.contains)) {
      _timer?.cancel();
      recovery = RecoveryState(
        draft: Draft(
          text: original.text,
          title: original.title,
          folderIds: original.folderIds
              .where((id) => !removed.contains(id))
              .toList(),
          options: original.options,
        ),
        operation: recovery.operation,
      ); // An intentionally deleted ambiguous operation must never be replayed.
      try {
        await _persist();
      } catch (_) {}
    }
    await loadFolders();
    if (recovery.operation != null) {
      await check(); // GET only; 404 clears tracking.
    }
    _notify();
  }

  Future<void> submit() async {
    if (working || recovery.operation != null) return;
    if (recovery.pending == null) {
      final key = List.generate(
        16,
        (_) => Random.secure().nextInt(256),
      ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
      recovery = RecoveryState(
        draft: draft,
        pending: PendingRequest(key, draft),
      );
    }
    await check();
  }

  Future<void> check() async {
    if (working || !hasOperation || _disposed) return;
    _timer?.cancel();
    working = true;
    error = null;
    _notify();
    var retryLater = true;
    try {
      final pending = recovery.pending;
      if (pending != null) {
        // Never send a new operation until its replay payload/key are durable.
        await _persist();
        status = await api.submitTranscript(
          text: pending.draft.text,
          title: pending.draft.title,
          folderIds: pending.draft.folderIds,
          idempotencyKey: pending.key,
          options: pending.draft.options,
        );
        recovery = RecoveryState(
          operation: AcceptedOperation(
            status!.transcriptId,
            pending.draft.title,
            pending.draft.folderIds,
            pending.draft.options,
          ),
        );
        await _persist(); // Atomically retain ID and remove accepted source draft.
      } else {
        await _persist();
        status = await api.processing(recovery.operation!.id);
      }
      if (status!.phase == ProcessingPhase.ready) {
        result = await api.summary(status!.summaryId!);
      }
      if (status!.phase != ProcessingPhase.ready) result = null;
      _failures = 0;
      if (status!.phase == ProcessingPhase.error) {
        error = status!.errorMessage ?? 'Обработка завершилась с ошибкой.';
      }
    } catch (e) {
      error = storageError ?? e.toString();
      _failures++;
      retryLater =
          (e is ApiException && e.isNetwork || _failures < 4) &&
          !(e is ApiException && e.statusCode == 409);
      if (e is ApiException &&
          e.statusCode == 404 &&
          recovery.operation != null) {
        final missingId = recovery.operation!.id;
        await summaryDeleted(missingId);
        error = 'Встреча удалена или больше недоступна.';
        retryLater = false;
      }
      // Validation rejection is unambiguous: preserve the editable draft.
      if (e is ApiException &&
          recovery.pending != null &&
          [404, 413, 422].contains(e.statusCode)) {
        recovery = RecoveryState(draft: recovery.pending!.draft);
        try {
          await _persist();
        } catch (_) {}
      }
    } finally {
      working = false;
      _notify();
      if (retryLater &&
          hasOperation &&
          result == null &&
          status?.phase != ProcessingPhase.error &&
          !_paused) {
        _timer = Timer(Duration(seconds: _interval), () => unawaited(check()));
        _interval = min(10, _interval + 2);
      }
    }
  }

  Future<void> retry() async {
    final operation = recovery.operation;
    if (working || operation == null) return;
    working = true;
    error = null;
    _notify();
    try {
      await _persist();
      status = await api.retryProcessing(
        operation.id,
        operation.title,
        operation.folderIds,
        options: operation.options,
      );
      _interval = 2;
    } catch (e) {
      error = e.toString();
    } finally {
      working = false;
      _notify();
    }
    // A timeout may hide accepted retry; check its state, do not POST repeatedly.
    await check();
  }

  void summaryUpdated(MeetingSummary updated) {
    if (result?.id == updated.id) {
      result = updated;
      _notify();
    }
  }

  Future<void> summaryDeleted(String transcriptId) async {
    if (recovery.operation?.id != transcriptId) return;
    _timer?.cancel();
    recovery = RecoveryState();
    status = null;
    result = null;
    error = null;
    try {
      await _persist();
    } catch (_) {
      /* Accepted ID on disk is safe: restart only GETs it. */
    }
    _notify();
  }

  Future<void> finish() async {
    if (working ||
        (result == null &&
            status?.phase != ProcessingPhase.error &&
            status?.phase != ProcessingPhase.notStarted)) {
      return;
    }
    _timer?.cancel();
    final previous = recovery;
    recovery = RecoveryState();
    try {
      await _persist();
      status = null;
      result = null;
      error = null;
    } catch (_) {
      recovery = previous;
    }
    _notify();
  }

  void pause() {
    _paused = true;
    _timer?.cancel();
  }

  void resume() {
    _paused = false;
    if (hasOperation && result == null) unawaited(check());
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

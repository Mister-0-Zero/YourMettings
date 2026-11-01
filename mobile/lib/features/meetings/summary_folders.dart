import 'package:flutter/foundation.dart';

import '../../api/api_client.dart';
import '../../models/api_models.dart';
import 'folder_picker.dart';

/// No write is replayed against a newly read membership set automatically.
class SummaryFoldersConflict implements Exception {
  const SummaryFoldersConflict(this.current);
  final MeetingSummary current;
}

/// The user's unsent choice survives error/conflict until explicit reselection.
class SummaryFolderIntent {
  SummaryFolderIntent(this.mode, List<String> expected, List<String> selected)
    : expected = Set.unmodifiable(expected),
      selected = Set.unmodifiable(selected);
  final FolderSelectionMode mode;
  final Set<String> expected, selected;

  List<String> selectionFor(MeetingSummary current) {
    if (mode == FolderSelectionMode.move) return selected.toList();
    final ids = current.folderIds.toSet();
    if (mode == FolderSelectionMode.replace) {
      ids.removeAll(expected.difference(selected));
    }
    ids.addAll(selected.difference(expected));
    return ids.toList();
  }
}

List<String> summaryFolderDestinations(
  MeetingSummary baseline,
  List<String> selected,
  FolderSelectionMode mode, {
  String? sourceFolderId,
}) {
  final ids = baseline.folderIds.toSet();
  final chosen = selected.toSet();
  switch (mode) {
    case FolderSelectionMode.replace:
      ids
        ..clear()
        ..addAll(chosen);
    case FolderSelectionMode.add:
      ids.addAll(selected);
    case FolderSelectionMode.move:
      if (sourceFolderId == null || !ids.contains(sourceFolderId)) {
        throw const ApiException(
          'source_folder_missing',
          'Встреча больше не находится в исходной папке. Обновите список и выберите действие заново.',
        );
      }
      if (chosen.length != 1 || chosen.single == sourceFolderId) {
        throw const ApiException(
          'invalid_destination',
          'Выберите другую папку.',
        );
      }
      ids
        ..remove(sourceFolderId)
        ..addAll(chosen);
  }
  if (ids.isEmpty || ids.length > 100) {
    throw const ApiException(
      'invalid_folder_count',
      'Для встречи нужно выбрать от 1 до 100 папок.',
    );
  }
  return ids.toList();
}

Future<MeetingSummary> saveSummaryFolders(
  ApiClient api,
  MeetingSummary baseline,
  List<String> destinations,
) async {
  final expected = baseline.folderIds.toSet();
  final intended = destinations.toSet();
  try {
    return await api.setSummaryFolders(
      baseline.id,
      intended.toList(),
      expectedFolderIds: expected.toList(),
    );
  } on ApiException catch (e) {
    final conflict =
        e.statusCode == 409 && e.code == 'summary_folders_conflict';
    if (conflict || e.retryable || e.code == 'invalid_response') {
      MeetingSummary current;
      try {
        current = await api.summary(baseline.id);
      } catch (_) {
        throw const ApiException(
          'folder_update_unconfirmed',
          'Не удалось подтвердить изменение папок. Ваш выбор сохранён. Проверьте подключение и повторите действие.',
        );
      }
      // A lost successful response may be acknowledged by GET. A reported
      // conflict always requires the user to review and select again.
      if (!conflict && setEquals(current.folderIds.toSet(), intended)) {
        return current;
      }
      if (conflict || !setEquals(current.folderIds.toSet(), expected)) {
        throw SummaryFoldersConflict(current);
      }
    }
    rethrow;
  }
}

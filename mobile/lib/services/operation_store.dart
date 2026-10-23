import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/api_models.dart';

/// Only unfinished operation checkpoints; no local library of meeting results.
class OperationStore extends ChangeNotifier {
  OperationStore({this.file});
  final File? file;
  Map<String, Json> _items = {};
  Future<void> _queue = Future.value();
  Json? operator [](String slot) => _items[slot] == null
      ? null
      : jsonDecode(jsonEncode(_items[slot])) as Json;
  Future<void> load() async {
    if (file == null || !await file!.exists()) return;
    final j = jsonDecode(await file!.readAsString()) as Json;
    if (j['version'] != 1) {
      throw const FormatException('Неизвестный формат операций.');
    }
    _items = (j['items'] as Json).map((k, v) => MapEntry(k, v as Json));
  }

  Future<void> put(String slot, Json value) =>
      _change(slot, jsonDecode(jsonEncode(value)) as Json);
  Future<void> remove(String slot) => _change(slot, null);
  Future<void> _change(String slot, Json? value) {
    final task = _queue.then((_) async {
      final updated = {..._items};
      if (value == null) {
        updated.remove(slot);
      } else {
        updated[slot] = value;
      }
      if (file != null) {
        await file!.parent.create(recursive: true);
        final temporary = File('${file!.path}.tmp');
        await temporary.writeAsString(
          jsonEncode({'version': 1, 'items': updated}),
          flush: true,
        );
        await temporary.rename(file!.path);
      }
      _items = updated;
      notifyListeners();
    });
    _queue = task.catchError((Object _) {});
    return task;
  }
}

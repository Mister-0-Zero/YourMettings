import 'dart:convert';
import 'dart:io';

import '../../models/api_models.dart';

/// One writer (capture engine) owns this file. UI never writes this manifest.
class AudioJournal {
  AudioJournal(this.directory);
  final Directory directory;
  Json data = {};
  File get manifest => File('${directory.path}/session.json');
  Future<void> load() async {
    if (await manifest.exists()) {
      data = jsonDecode(await manifest.readAsString()) as Json;
      if (data['version'] != 1) {
        throw const FormatException('Audio journal version');
      }
    }
  }

  void saveSync() {
    directory.createSync(recursive: true);
    final temporary = File('${manifest.path}.tmp');
    temporary.writeAsStringSync(jsonEncode(data), flush: true);
    temporary.renameSync(manifest.path);
  }

  List<Json> get chunks => (data['chunks'] as List).cast<Json>();
  File chunkFile(int sequence) => File('${directory.path}/$sequence.wav');
}


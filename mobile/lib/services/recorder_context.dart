import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../api/demo_connection.dart';
import '../models/api_models.dart';
import 'demo_key_vault.dart';

Directory connectionDirectory(Directory support, DemoConnection binding) =>
    Directory('${support.path}/scopes/${binding.scopeId}');

Future<void> saveRecorderContext(DemoConnection connection) async {
  final support = await getApplicationSupportDirectory();
  final file = File('${support.path}/audio-context.json');
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(
    jsonEncode({'version': 1, 'connection': connection.toJson()}),
    flush: true,
  );
  await tmp.rename(file.path);
}

Future<({DemoConnection connection, Directory directory})>
readRecorderContext() async {
  final support = await getApplicationSupportDirectory();
  final file = File('${support.path}/audio-context.json');
  final j = jsonDecode(await file.readAsString()) as Json;
  if (j['version'] != 1) {
    throw const FormatException('Неизвестный контекст записи.');
  }
  final connection = DemoConnection.fromJson(
    j['connection'] as Json,
    const DeviceDemoKeyVault(),
  );
  return (
    connection: connection,
    directory: connectionDirectory(support, connection),
  );
}

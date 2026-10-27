import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../api/api_client.dart';
import '../api/demo_connection.dart';
import '../models/api_models.dart';
import 'demo_key_vault.dart';

class _ProbeVault implements DemoKeyVault {
  _ProbeVault(this.origin, this._key);
  final String origin, _key;
  @override
  Future<String?> read(String target) async => target == origin ? _key : null;
  @override
  Future<void> write(String origin, String key) =>
      throw UnsupportedError('Read only');
}

/// Settings contain addresses and verified account identity, never a credential.
class ConnectionSettings extends ChangeNotifier {
  ConnectionSettings({required this.vault, this.file, this.probeClient});
  final DemoKeyVault vault;
  final File? file;
  final http.Client Function()? probeClient;
  ServerProfile profile = ServerProfile.usb;
  final addresses = <ServerProfile, String>{
    ServerProfile.usb: usbAddress,
    ServerProfile.https: httpsAddress,
  };
  DemoConnection? active;
  String? accessError;
  Future<String?> Function(DemoConnection next)? beforeApply;
  Future<void> Function(DemoConnection next, bool sameScope)? onApply;
  String address(ServerProfile p) => addresses[p]!;
  Future<void> load() async {
    if (file == null || !await file!.exists()) return;
    final j = jsonDecode(await file!.readAsString()) as Json;
    if (j['version'] != 1) {
      throw const FormatException('Неизвестный формат подключения.');
    }
    profile = ServerProfile.values.byName(j['profile'] as String);
    for (final p in ServerProfile.values) {
      addresses[p] = (j['addresses'] as Json)[p.name] as String;
    }
    if (j['active'] != null) {
      final binding = DemoConnection.fromJson(
        j['active'] as Json,
        vault,
        onAccessError: reportAccess,
      );
      if ((await vault.read(binding.origin))?.isNotEmpty == true) {
        active = binding;
      }
    }
  }

  void reportAccess(ApiException e) {
    accessError = e.message;
    notifyListeners();
  }

  Future<DemoConnection> check(
    ServerProfile profile,
    String address,
    String value,
  ) async {
    final base = normalizeBackend(address, profile);
    final key = value.trim();
    if (key.isEmpty) {
      throw const ApiException(
        'demo_key_required',
        'Введите демонстрационный ключ. Не отправляйте его в чат.',
      );
    }
    if (key.runes.any((c) => c < 33 || c > 126)) {
      throw const ApiException(
        'demo_key_invalid',
        'Проверьте ключ: внутри него не должно быть пробелов, переносов или нелатинских символов.',
      );
    }
    final probe = DemoConnection(
      base: base,
      accountId: 'probe',
      accessMode: 'demo',
      vault: _ProbeVault(base.origin, key),
    );
    final api = ApiClient(base, connection: probe, client: probeClient?.call());
    try {
      final health = await api.health();
      if (health['status'] != 'ok') {
        throw const ApiException(
          'health_failed',
          'Сервер отвечает, но ещё не готов.',
        );
      }
      final user = await api.authMe();
      if (user['access_mode'] != 'demo' ||
          user['id'] is! String ||
          (user['id'] as String).isEmpty) {
        throw const ApiException(
          'unexpected_account',
          'Сервер не подтвердил демонстрационный аккаунт. Локальные данные не переключены.',
        );
      }
      return DemoConnection(
        base: base,
        accountId: user['id'] as String,
        accessMode: user['access_mode'] as String,
        vault: vault,
        onAccessError: (error) {
          if (active?.origin == base.origin &&
              active?.accountId == user['id']) {
            reportAccess(error);
          }
        },
      );
    } finally {
      api.close();
    }
  }

  Future<void> apply(
    ServerProfile selected,
    String address,
    String value,
  ) async {
    final next = await check(selected, address, value);
    final same = active?.scopeId == next.scopeId && active?.base == next.base;
    final blocked = await beforeApply?.call(next);
    if (blocked != null) throw ApiException('connection_busy', blocked);
    // Check account before replacing a key used by live requests.
    try {
      await vault.write(next.origin, value.trim());
    } catch (_) {
      throw const ApiException(
        'secure_storage_failed',
        'Не удалось защищённо сохранить ключ. Подключение не переключено.',
      );
    }
    final updated = {
      ...addresses,
      selected: next.base.toString().replaceAll(RegExp(r'/+$'), ''),
    };
    final j = {
      'version': 1,
      'profile': selected.name,
      'addresses': {for (final e in updated.entries) e.key.name: e.value},
      'active': next.toJson(),
    };
    if (file != null) {
      await file!.parent.create(recursive: true);
      final temporary = File('${file!.path}.tmp');
      await temporary.writeAsString(jsonEncode(j), flush: true);
      await temporary.rename(file!.path);
    }
    active = next;
    profile = selected;
    addresses.addAll(updated);
    await onApply?.call(next, same);
    accessError = null;
    notifyListeners();
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

abstract interface class QueueWriteAuthority {
  String get scopeId;
  Future<T> serialized<T>(Future<T> Function() action);
  // Called inside serialized mutations, never a nested serialized() call.
  Future<void> writeSnapshot(File file, String encoded);
  Future<void> eraseFile(File file);
  Future<void> eraseDraft(Directory directory);
}

abstract interface class QueueAudioAuthority implements QueueWriteAuthority {
  Future<int> appendPcm(File file, int expectedOffset, Uint8List bytes);
  Future<void> writeAudio(File file, Uint8List bytes);
}

abstract interface class QueueOwnerLease implements QueueAudioAuthority {
  Future<bool> shouldYield();
  Future<int> availableBytes();
  Future<void> saveCaptureTicket(String localId, String nonce);
  Future<void> clearCaptureTicket(String nonce);
  Future<void> close();
}

class QueueOwnerLost implements Exception {
  const QueueOwnerLost();
  @override
  String toString() =>
      'Запись черновика сейчас выполняет другой процесс. Повторите действие.';
}

class QueueStorageFailure implements Exception {
  const QueueStorageFailure();
  @override
  String toString() =>
      'Не удалось сохранить данные на устройстве. Проверьте свободное место и повторите.';
}

class NativeQueueOwner {
  static const channel = MethodChannel('yourmettings/queue_owner');
  static Future<Map<String, String>?> captureTicket() =>
      channel.invokeMapMethod<String, String>('captureTicket');

  static Future<void> requestYield(String scopeId) async {
    await channel.invokeMethod<bool>('requestYield', {'scope': scopeId});
  }

  static Future<NativeQueueLease?> acquire(String scopeId) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(scopeId)) {
      throw ArgumentError('Invalid queue scope');
    }
    final token = await channel.invokeMethod<String>('acquire', {
      'scope': scopeId,
    });
    return token == null ? null : NativeQueueLease._(scopeId, token);
  }
}

/// Owns ALL mutations for this scope. Closing first drains outstanding work;
/// ownership cannot be handed to another runner while a write/upload is alive.
class NativeQueueLease implements QueueOwnerLease {
  NativeQueueLease._(this.scopeId, this._token);
  @override
  final String scopeId;
  final String _token;
  Future<void> _tail = Future.value();
  bool _closing = false;
  Future<void>? _close;
  Map<String, String> get _arguments => {'scope': scopeId, 'token': _token};
  @override
  Future<T> serialized<T>(Future<T> Function() action) {
    if (_closing) return Future.error(const QueueOwnerLost());
    final task = _tail.then((_) async {
      final valid = await NativeQueueOwner.channel.invokeMethod<bool>(
        'valid',
        _arguments,
      );
      if (valid != true) throw const QueueOwnerLost();
      return action();
    });
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  Future<void> _nativeMutation(
    String method,
    Map<String, String> values,
  ) async {
    try {
      await NativeQueueOwner.channel.invokeMethod<void>(method, {
        ..._arguments,
        ...values,
      });
    } on PlatformException catch (e) {
      if (e.code == 'owner_unavailable') {
        throw const QueueOwnerLost();
      }
      if (e.code == 'storage_failure') {
        throw const QueueStorageFailure();
      }
      rethrow;
    }
  }

  @override
  Future<void> writeSnapshot(File file, String encoded) async {
    final nonce = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final temporary = File('${file.path}.$_token.$nonce.tmp');
    await file.parent.create(recursive: true);
    await temporary.writeAsString(encoded, flush: true);
    await _nativeMutation('publish', {
      'path': file.absolute.path,
      'temporary': temporary.absolute.path,
    });
  }

  @override
  Future<void> saveCaptureTicket(String localId, String nonce) =>
      _nativeMutation('captureTicketWrite', {
        'local_id': localId,
        'nonce': nonce,
      });
  @override
  Future<void> clearCaptureTicket(String nonce) =>
      _nativeMutation('captureTicketClear', {'nonce': nonce});

  @override
  Future<bool> shouldYield() async =>
      await NativeQueueOwner.channel.invokeMethod<bool>(
        'shouldYield',
        _arguments,
      ) ??
      true;
  @override
  Future<int> availableBytes() async => (await NativeQueueOwner.channel
      .invokeMethod<int>('availableBytes', _arguments))!;

  @override
  Future<int> appendPcm(File file, int expectedOffset, Uint8List bytes) async {
    try {
      return (await NativeQueueOwner.channel.invokeMethod<int>('appendPcm', {
        ..._arguments,
        'path': file.absolute.path,
        'offset': expectedOffset,
        'bytes': bytes,
      }))!;
    } on PlatformException catch (e) {
      if (e.code == 'owner_unavailable') throw const QueueOwnerLost();
      if (e.code == 'storage_failure') throw const QueueStorageFailure();
      rethrow;
    }
  }

  @override
  Future<void> writeAudio(File file, Uint8List bytes) async {
    final nonce = Random.secure().nextInt(1 << 32).toRadixString(16);
    final temporary = File('${file.path}.$_token.$nonce.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await _nativeMutation('publish', {
      'path': file.absolute.path,
      'temporary': temporary.absolute.path,
    });
  }

  @override
  Future<void> eraseFile(File file) =>
      _nativeMutation('eraseFile', {'path': file.absolute.path});
  @override
  Future<void> eraseDraft(Directory directory) =>
      _nativeMutation('eraseDraft', {'path': directory.absolute.path});

  @override
  Future<void> close() {
    _closing = true;
    return _close ??= _tail.then((_) async {
      if (await NativeQueueOwner.channel.invokeMethod<bool>(
            'release',
            _arguments,
          ) !=
          true) {
        throw const QueueOwnerLost();
      }
    });
  }
}

import 'dart:io';

import 'package:queue_owner/queue_owner.dart';

/// UI lists only committed snapshots when another engine owns the scope.
/// Mutations always acquire an actual native lifetime lease.
class ReadOnlyDraftAuthority implements QueueWriteAuthority {
  ReadOnlyDraftAuthority(this.scopeId);
  @override
  final String scopeId;
  Never _denied() => throw const QueueOwnerLost();
  @override
  Future<T> serialized<T>(Future<T> Function() action) async => _denied();
  @override
  Future<void> writeSnapshot(File file, String encoded) async => _denied();
  @override
  Future<void> eraseFile(File file) async => _denied();
  @override
  Future<void> eraseDraft(Directory directory) async => _denied();
}

typedef AcquireDraftOwner = Future<QueueOwnerLease?> Function(String scopeId);

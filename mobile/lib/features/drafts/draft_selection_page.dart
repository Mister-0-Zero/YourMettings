import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../app/home_navigation.dart';
import '../../models/api_models.dart';
import '../../models/processing_options.dart';
import '../../services/drafts/draft_selection_store.dart';
import '../../services/drafts/draft_workspace.dart';
import '../../services/drafts/queue_journal.dart';
import '../../services/drafts/queue_transport.dart';
import '../selections/selection_controller.dart';
import '../selections/selection_page.dart';

class DraftSelectionPage extends StatefulWidget {
  const DraftSelectionPage({
    super.key,
    required this.workspace,
    required this.localId,
  });
  final DraftWorkspace workspace;
  final String localId;
  @override
  State<DraftSelectionPage> createState() => _DraftSelectionPageState();
}

class _DraftSelectionPageState extends State<DraftSelectionPage> {
  String? _error;
  QueueCancellation? _cancel;
  bool _closed = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    try {
      MeetingSummary? accepted;
      await widget.workspace.withOwner((repo, lease) async {
        final cancel = QueueCancellation();
        _cancel = cancel;
        final transport = QueueTransport(widget.workspace.connection, cancel);
        final journal = QueueJournal(repo, widget.localId);
        final store = DraftSelectionStore(journal);
        SelectionController? controller;
        var yielding = false;
        final watch = Timer.periodic(const Duration(milliseconds: 100), (
          _,
        ) async {
          if (yielding) return;
          if (await lease.shouldYield()) {
            yielding = true;
            cancel.stop();
            controller?.pause();
            if (mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          }
        });
        try {
          await store.load();
          await transport.verifyIdentity();
          if (_closed || !mounted) return;
          final record = await repo.read(widget.localId);
          if (!mounted || _closed) return;
          final api = ApiClient(
            widget.workspace.connection.base,
            client: transport.client,
            operations: store,
          );
          accepted = await Navigator.of(context).push<MeetingSummary>(
            MaterialPageRoute(
              builder: (_) => SelectionPage(
                api: api,
                slot: store.selectionSlot,
                title: record.input.title,
                source: () async =>
                    throw StateError('Queue selection must exist'),
                options: ProcessingOptions.fromJson(record.input.options),
                onController: (value) => controller = value,
                onFailure: (error) async {
                  await journal.status(
                    'needs_action',
                    fields: QueueRetryPolicy().failure(
                      error,
                      draftQueue(record),
                    ),
                  );
                },
              ),
            ),
          );
        } finally {
          watch.cancel();
          cancel.stop();
          controller?.pause();
          await controller?.drain();
          transport.close();
          store.dispose();
          _cancel = null;
        }
      });
      unawaited(widget.workspace.wakeQueue?.call());
      if (mounted) {
        if (accepted != null) {
          returnToHome(context);
        } else {
          Navigator.pop(context);
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  void dispose() {
    _closed = true;
    _cancel?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Summary')),
    body: Center(
      child: _error == null
          ? const CircularProgressIndicator()
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!),
                TextButton(onPressed: _open, child: const Text('Повторить')),
              ],
            ),
    ),
  );
}

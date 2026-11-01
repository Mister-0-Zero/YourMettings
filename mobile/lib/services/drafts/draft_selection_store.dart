import 'dart:convert';

import '../../models/api_models.dart';
import '../operation_store.dart';
import 'draft_record.dart';
import 'queue_journal.dart';

/// One local draft, one selection checkpoint, the SAME native queue authority.
/// Exact source/candidate/accept intent survives before ApiClient sends HTTP.
class DraftSelectionStore extends OperationStore {
  DraftSelectionStore(this.journal);
  final QueueJournal journal;
  Json? _value;
  String get selectionSlot => 'draft:${journal.id}';
  @override
  Json? operator [](String slot) =>
      slot == selectionSlot && _value != null ? copyJson(_value!) : null;
  @override
  Future<void> load() async {
    _value =
        ((await journal.read()).toJson()['checkpoints'] as Json)['selection']
            as Json?;
  }

  @override
  Future<void> put(String slot, Json value) async {
    if (slot != selectionSlot) throw StateError('Selection slot differs');
    final state = copyJson(value);
    await journal.change((json) {
      final requests = json['requests'] as Json;
      void freeze(String name, FrozenDraftRequest request) {
        if (requests[name] != null &&
            jsonEncode(requests[name]) != jsonEncode(request.toJson())) {
          throw StateError('Selection immutable intent differs');
        }
        requests[name] = request.toJson();
      }

      final oldCreate = requests['selection-create'] as Json?;
      final sourceSlot = oldCreate?['key'] == state['key']
          ? 'selection-create'
          : 'selection-create:${state['key']}';
      freeze(
        sourceSlot,
        FrozenDraftRequest(
          method: 'POST',
          path: 'summary-selections',
          key: state['key'] as String,
          body: state['source'] as Json,
        ),
      );
      final pending = state['candidate_pending'] as Json?;
      final sessionId = state['session_id'] as String?;
      if (sessionId != null && pending != null) {
        freeze(
          'candidate:${pending['key']}',
          FrozenDraftRequest(
            method: 'POST',
            path: 'summary-selections/$sessionId/candidates',
            key: pending['key'] as String,
            body: {...pending['options'] as Json}
              ..remove('expected_template_version'),
          ),
        );
      }
      if (sessionId != null && state['accept_id'] != null) {
        final edit = state['accept_edit'] as Json? ?? {};
        // The accept endpoint uses its immutable candidate/body receipt, not an
        // Idempotency-Key header. This journal key is local identity only.
        freeze(
          'selection-accept',
          FrozenDraftRequest(
            method: 'POST',
            path: 'summary-selections/$sessionId/accept',
            key: state['accept_id'] as String,
            body: {
              'candidate_id': state['accept_id'],
              'expected_version': state['summary_version'],
              if (edit['title'] != null) 'title': edit['title'],
              if (edit['content'] != null) 'content': edit['content'],
            },
          ),
        );
      }
      final ids = json['server_ids'] as Json;
      final receipts = json['receipts'] as Json;
      if (sessionId != null && state['transcript_id'] != null) {
        final binding = {
          'selection_id': sessionId,
          'transcript_id': state['transcript_id'],
        };
        final receiptSlot = 'selection-bind:${state['key']}';
        if (receipts[receiptSlot] != null &&
            jsonEncode(receipts[receiptSlot]) != jsonEncode(binding)) {
          throw StateError('Selection identity changed');
        }
        receipts[receiptSlot] = binding;
        ids.putIfAbsent('selection_id', () => sessionId);
        ids.putIfAbsent('transcript_id', () => state['transcript_id']);
      }
      if (sessionId != null && state['cancel_pending'] == true) {
        freeze(
          'selection-cancel:${state['key']}',
          FrozenDraftRequest(
            method: 'DELETE',
            path: 'summary-selections/$sessionId',
            key: state['key'] as String,
            body: {},
            query: {'confirm': 'true'},
          ),
        );
      }
      if (state['receipt'] != null && state['accepted_summary_id'] != null) {
        ids['summary_id'] = state['accepted_summary_id'];
        final receipts = json['receipts'] as Json;
        receipts.putIfAbsent('selection-accept', () => state['receipt']);
      }
      final checkpoints = json['checkpoints'] as Json;
      final queue = checkpoints['queue'] as Json? ?? {};
      if (sessionId != null) queue['active_selection_key'] = state['key'];
      checkpoints['queue'] = queue;
      if (queue['input_at_boundary'] == null &&
          checkpoints['selection'] == null) {
        checkpoints['queue'] = {...queue, 'input_at_boundary': json['input']};
      }
      final liveQueue = checkpoints['queue'] as Json? ?? {};
      if (state['receipt'] != null && state['accepted_summary_id'] != null) {
        checkpoints['queue'] = {
          ...liveQueue,
          'stage': 'result_pending',
          'next_attempt_at': null,
        };
      } else if (state['cancel_pending'] == true) {
        checkpoints['queue'] = {
          ...liveQueue,
          'stage': 'selection_cancelling',
          'next_attempt_at': null,
          'paused': false,
        };
      } else if (state['accept_id'] != null ||
          state['candidate_pending'] != null) {
        checkpoints['queue'] = {
          ...liveQueue,
          'stage': state['accept_id'] != null
              ? 'accept_pending'
              : 'generating_qwen',
          'next_attempt_at': null,
          'requested': true,
        };
      }
      checkpoints['selection'] = state;
    });
    _value = state;
    notifyListeners();
  }

  @override
  Future<void> remove(String slot) async {
    if (slot != selectionSlot) throw StateError('Selection slot differs');
    // Preserve receipt + summary_id before the UI callback clears checkpoint.
    await journal.change((j) {
      final c = j['checkpoints'] as Json;
      final state = c['selection'] as Json?;
      if (state?['accepted_summary_id'] != null &&
          (j['server_ids'] as Json)['summary_id'] == null) {
        throw StateError('Accepted summary is not bound');
      }
      if (state != null && state['accepted_summary_id'] == null) {
        if (state['cancel_pending'] != true) {
          throw StateError('Cancellation is not confirmed');
        }
        final history = c['selection_history'] as Json? ?? {};
        history[state['key'] as String] = {...state, 'cancel_confirmed': true};
        c['selection_history'] = history;
        (j['receipts'] as Json).putIfAbsent(
          'selection-cancel:${state['key']}',
          () => {
            'selection_id': state['session_id'],
            'cancel_confirmed': true,
            'source_temporary': (state['source'] as Json).containsKey('text'),
          },
        );
      }
      c['selection'] = null;
      c['queue'] = {
        ...?(c['queue'] as Json?),
        'stage': state?['accepted_summary_id'] != null
            ? 'result_pending'
            : 'paused',
        'paused': state?['accepted_summary_id'] == null,
        if (state?['accepted_summary_id'] == null)
          'selection_cancelled_key': state?['key'],
        'next_attempt_at': null,
      };
    });
    _value = null;
    notifyListeners();
  }
}

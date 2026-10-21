import 'package:flutter/material.dart';

import '../../services/audio_draft_store.dart';
import '../new_meeting/meeting_controller.dart';
import '../new_meeting/transcript_page.dart';
import 'audio_review_controller.dart';
import 'recorder_coordinator.dart';
import 'recorder_page.dart';

class WorkspacePage extends StatefulWidget {
  const WorkspacePage({
    super.key,
    this.controller,
    this.recorder,
    this.review,
    this.drafts,
    this.visible = true,
  });
  final MeetingController? controller;
  final RecorderCoordinator? recorder;
  final AudioReviewController? review;
  final AudioDraftRepository? drafts;
  final bool visible;
  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  String? _opening;
  Future<void> _open(SavedAudioDraft entry) async {
    if (_opening != null || widget.review == null || widget.recorder == null) {
      return;
    }
    setState(() => _opening = entry.sessionId);
    AudioReviewController? owned;
    try {
      if (entry.handoff) {
        await widget.review!.recoverHandoffs();
        final remaining = widget.drafts![entry.sessionId];
        if (remaining == null) return;
        if (remaining.handoff) throw StateError('Handoff incomplete');
        entry = remaining;
      }
      if (!mounted || !widget.visible) return;
      if (widget.recorder!.state['id'] == entry.sessionId) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => RecorderPage(
              recorder: widget.recorder!,
              review: widget.review!,
            ),
          ),
        );
        return;
      }
      final review = AudioReviewController(
        widget.review!.api,
        DeferredAudioRecoveryStore(widget.drafts!, entry.sessionId),
        widget.recorder!,
        drafts: widget.drafts,
        fixedSessionId: entry.sessionId,
        audioApiFactory: widget.review!.audioApiFactory,
      )..boundariesReviewed = entry.boundariesReviewed;
      owned = review;
      await review.initialize();
      await review.openReview();
      if (!mounted || !widget.visible) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => TranscriptPage(
            controller: review,
            audioReview: true,
            reviewNotice: review.needsBoundaryReview
                ? AudioBoundaryReview(review: review)
                : null,
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.review!.storageError ?? 'Не удалось открыть черновик. Данные не удалены; повторите действие.',
            ),
          ),
        );
      }
    } finally {
      owned?.dispose();
      if (mounted) setState(() => _opening = null);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.drafts ?? const AlwaysStoppedAnimation(0),
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Черновики', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'На этом устройстве. Можно продолжить работу после новой записи.',
        ),
        const SizedBox(height: 16),
        if (widget.drafts?.items.isEmpty ?? true)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('Сохранённых черновиков пока нет.'),
          ),
        for (final entry in widget.drafts?.items ?? <SavedAudioDraft>[])
          Card(
            child: ListTile(
              key: ValueKey('draft-${entry.sessionId}'),
              leading: Icon(
                entry.deletePending
                    ? Icons.delete_outline
                    : Icons.description_outlined,
              ),
              title: Text(
                entry.title.isEmpty ? 'Без названия' : entry.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                entry.handoff
                    ? 'Завершить сохранение'
                    : entry.deletePending
                    ? 'Удаление не завершено — повторить'
                    : entry.recovery.operation != null
                    ? 'Открыть обработку'
                    : 'Продолжить редактирование',
              ),
              trailing: _opening == entry.sessionId
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: _opening == null && widget.review != null
                  ? () => _open(entry)
                  : null,
            ),
          ),
        const SizedBox(height: 24),
        const ListTile(
          enabled: false,
          leading: Icon(Icons.article_outlined),
          title: Text('Шаблоны'),
          subtitle: Text('Будет доступно позже'),
        ),
        const ListTile(
          enabled: false,
          leading: Icon(Icons.share_outlined),
          title: Text('Отправка и доступ'),
          subtitle: Text('Почта и обмен встречами будут доступны позже'),
        ),
      ],
    ),
  );
}

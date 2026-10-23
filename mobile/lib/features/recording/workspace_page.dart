import '../templates/templates_page.dart';

import 'package:flutter/material.dart';

import '../../services/audio_draft_store.dart';
import '../new_meeting/meeting_controller.dart';
import '../new_meeting/transcript_page.dart';
import 'audio_review_controller.dart';
import 'recorder_coordinator.dart';
import 'recorder_page.dart';

class WorkspacePage extends StatelessWidget {
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

  void _open(BuildContext context, String section) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) {
          if (section == 'Черновики') {
            return AudioDraftsPage(
              recorder: recorder,
              review: review,
              drafts: drafts,
            );
          }
          if (section == 'Шаблоны' && controller != null) {
            return TemplatesPage(api: controller!.api);
          }
          return Scaffold(
            appBar: AppBar(title: Text(section)),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  section == 'Шаблоны'
                      ? 'Работа с шаблонами пока недоступна.'
                      : 'Отправка на почту и обмен встречами пока недоступны.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: drafts ?? const AlwaysStoppedAnimation(0),
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(20),
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final columns =
                constraints.maxWidth >= 300 &&
                    MediaQuery.textScalerOf(context).scale(14) <= 18
                ? 2
                : 1;
            final width = (constraints.maxWidth - 16 * (columns - 1)) / columns;
            final sections = [
              (
                'Черновики',
                Icons.description_outlined,
                'Сохранено: ${drafts?.items.length ?? 0}',
                'drafts',
              ),
              (
                'Шаблоны',
                Icons.article_outlined,
                'Структура итогов встреч',
                'templates',
              ),
              ('Отправка и доступ', Icons.share_outlined, 'Скоро', 'sharing'),
            ];
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (final section in sections)
                  SizedBox(
                    width: width,
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Card(
                        margin: EdgeInsets.zero,
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          key: ValueKey('workspace-${section.$4}'),
                          onTap: visible
                              ? () => _open(context, section.$1)
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(section.$2, size: 28),
                                const SizedBox(height: 4),
                                Text(
                                  section.$1,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  section.$3,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    ),
  );
}

class AudioDraftsPage extends StatefulWidget {
  const AudioDraftsPage({super.key, this.recorder, this.review, this.drafts});
  final RecorderCoordinator? recorder;
  final AudioReviewController? review;
  final AudioDraftRepository? drafts;
  @override
  State<AudioDraftsPage> createState() => _AudioDraftsPageState();
}

class _AudioDraftsPageState extends State<AudioDraftsPage> {
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
      if (!mounted) return;
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
      if (!mounted) return;
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Черновики')),
    body: SafeArea(
      child: AnimatedBuilder(
        animation: widget.drafts ?? const AlwaysStoppedAnimation(0),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(20),
          children: [
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
                        : widget
                                  .review
                                  ?.api
                                  .operations?['audio-selection:${entry.sessionId}'] !=
                              null
                        ? 'Продолжить выбор результата'
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
          ],
        ),
      ),
    ),
  );
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/api_models.dart';
import '../new_meeting/transcript_page.dart';
import 'audio_review_controller.dart';
import 'recorder_coordinator.dart';

class RecorderPage extends StatefulWidget {
  const RecorderPage({super.key, required this.recorder, required this.review});
  final RecorderCoordinator recorder;
  final AudioReviewController review;
  @override
  State<RecorderPage> createState() => _RecorderPageState();
}

class _RecorderPageState extends State<RecorderPage> {
  bool _opening = false;
  @override
  void initState() {
    super.initState();
    widget.recorder.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  @override
  void dispose() {
    widget.recorder.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
    if (['review', 'completed'].contains(widget.recorder.phase) &&
        !_opening &&
        mounted) {
      unawaited(_review());
    }
  }

  Future<void> _review() async {
    _opening = true;
    try {
      await widget.review.openReview();
      if (!mounted) return;
      await Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute(
          builder: (_) => TranscriptPage(
            controller: widget.review,
            audioReview: true,
            reviewNotice: widget.review.needsBoundaryReview
                ? _BoundaryReview(review: widget.review)
                : null,
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(() => _opening = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось открыть текст. Проверьте соединение и повторите.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _setup() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TranscriptPage(
          controller: widget.review,
          onRecord: (draft) async {
            FocusManager.instance.primaryFocus?.unfocus();
            await widget.recorder.start({
              'title': draft.title,
              'folder_ids': draft.folderIds,
              ...draft.options.toJson(),
            });
            if (mounted && widget.recorder.error == null) {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final recorder = widget.recorder;
    final phase = recorder.phase;
    final assemblyError = (recorder.state['session'] as Json?)?['error_code'];
    final canRetryAsr = phase == 'failed' && assemblyError == 'chunk_failed';
    final ms = recorder.state['elapsed_ms'] as int? ?? 0;
    final seconds = ms ~/ 1000;
    final time =
        '${(seconds ~/ 3600).toString().padLeft(2, '0')}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
    return Scaffold(
      appBar: AppBar(title: const Text('Запись совещания')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Используйте только неконфиденциальные тестовые данные.',
            ),
            const SizedBox(height: 32),
            if (['empty', 'done', 'preparing'].contains(phase)) ...[
              const Icon(Icons.mic_none, size: 64),
              const SizedBox(height: 20),
              const Text('Выберите название и папку перед началом записи.'),
              FilledButton(
                onPressed: recorder.busy ? null : _setup,
                child: const Text('Настроить запись'),
              ),
            ] else if ([
              'recording',
              'paused',
              'prepared',
              'stopping',
            ].contains(phase)) ...[
              Icon(
                phase == 'recording'
                    ? Icons.fiber_manual_record
                    : Icons.pause_circle_outline,
                size: 48,
                color: phase == 'recording'
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  time,
                  style: Theme.of(context).textTheme.displayMedium,
                ),
              ),
              Center(
                child: Text(
                  phase == 'recording'
                      ? 'Идёт запись'
                      : phase == 'paused'
                      ? 'Запись приостановлена'
                      : 'Подождите…',
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: SizedBox(
                  width: 180,
                  child: LinearProgressIndicator(
                    value: (recorder.state['level'] as num? ?? 0)
                        .toDouble()
                        .clamp(0, 1),
                    semanticsLabel: 'Уровень микрофона',
                    minHeight: 8,
                  ),
                ),
              ),
              const SizedBox(height: 32),
              if (['recording', 'paused'].contains(phase)) ...[
                OutlinedButton.icon(
                  onPressed: recorder.busy
                      ? null
                      : () => recorder.command(
                          phase == 'paused' ? 'resume' : 'pause',
                        ),
                  icon: Icon(
                    phase == 'paused' ? Icons.play_arrow : Icons.pause,
                  ),
                  label: Text(phase == 'paused' ? 'Продолжить' : 'Пауза'),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: recorder.busy
                      ? null
                      : () => recorder.command('stop'),
                  icon: const Icon(Icons.stop),
                  label: const Text('Завершить запись'),
                ),
              ],
              const SizedBox(height: 24),
              const Text(
                'Можно свернуть приложение или выключить экран. Стрелка назад сохраняет текущую запись.',
              ),
            ] else if (phase == 'interrupted') ...[
              const Icon(Icons.mic_off_outlined, size: 48),
              const Text(
                'Запись прервана. Сохранённое аудио восстановлено. Микрофон выключен.',
              ),
              FilledButton(
                onPressed: recorder.busy
                    ? null
                    : () => (recorder.state['chunks'] as List).isEmpty
                          ? recorder.start(recorder.state['parameters'] as Json)
                          : recorder.command('finishRecovered'),
                child: Text(
                  (recorder.state['chunks'] as List).isEmpty
                      ? 'Повторить начало записи'
                      : 'Отправить сохранённую запись',
                ),
              ),
            ] else ...[
              if (phase != 'failed')
                const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 24),
              Text(
                phase == 'failed'
                    ? 'Не удалось распознать речь'
                    : phase == 'sending'
                    ? 'Сохраняем запись…'
                    : 'Распознаём речь…',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              if (phase == 'failed' && !canRetryAsr)
                Text(
                  assemblyError == 'empty_transcript'
                      ? 'Речь не обнаружена. Проверьте доступ к микрофону и сделайте новую запись.'
                      : 'Сервер не смог собрать текст записи. Сохранённые части не удалены; требуется проверка записи и ограничений сервера.',
                ),
              if (canRetryAsr)
                FilledButton(
                  onPressed: recorder.busy
                      ? null
                      : () => recorder.command('retryAsr'),
                  child: const Text('Повторить распознавание'),
                ),
              if (['review', 'completed'].contains(phase))
                FilledButton(
                  onPressed: _opening ? null : _review,
                  child: const Text('Открыть транскрипт'),
                ),
            ],
            for (final message in [
              recorder.error,
              recorder.state['message'],
              recorder.state['upload_error'],
            ])
              if (message is String)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(message),
                ),
            if (recorder.state['upload_error'] != null)
              TextButton(
                onPressed: recorder.busy
                    ? null
                    : () => recorder.command('retry'),
                child: const Text('Повторить отправку'),
              ),
          ],
        ),
      ),
    );
  }
}

class _BoundaryReview extends StatefulWidget {
  const _BoundaryReview({required this.review});
  final AudioReviewController review;
  @override
  State<_BoundaryReview> createState() => _BoundaryReviewState();
}

class _BoundaryReviewState extends State<_BoundaryReview> {
  @override
  Widget build(BuildContext context) {
    final session = widget.review.recorder.state['session'] as Json;
    final chunks = (session['chunks'] as List).cast<Json>();
    return Column(
      children: [
        const Text(
          'Распознавание стыков неоднозначно. Проверьте, нет ли повторённых или пропущенных слов:',
        ),
        for (final warning
            in (session['boundary_warnings'] as List).cast<Json>()) ...[
          for (final chunk in chunks.where(
            (c) =>
                c['sequence_number'] == warning['sequence_number'] ||
                c['sequence_number'] == (warning['sequence_number'] as int) - 1,
          ))
            Text('${chunk['text'] ?? ''}'),
        ],
        CheckboxListTile(
          value: widget.review.boundariesReviewed,
          title: const Text('Я проверил стыки текста'),
          onChanged: (value) =>
              setState(() => widget.review.boundariesReviewed = value ?? false),
        ),
      ],
    );
  }
}

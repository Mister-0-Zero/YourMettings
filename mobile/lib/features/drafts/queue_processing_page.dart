import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/home_navigation.dart';
import '../../models/api_models.dart';
import '../../services/drafts/draft_record.dart';
import '../../services/drafts/draft_workspace.dart';
import '../../services/drafts/queue_journal.dart';
import '../../services/recovery_store.dart';
import '../meetings/summary_page.dart';
import '../new_meeting/meeting_controller.dart';
import '../recording/draft_recorder_coordinator.dart';
import 'draft_selection_page.dart';
import 'local_draft_pages.dart';

String queueStageLabel(Json queue) => switch (queue['stage']) {
  'uploading' || 'submitting' => 'Отправляем запись',
  'asr' => 'Распознаём речь',
  'generating_qwen' || 'queued_qwen' => 'Qwen обрабатывает транскрипт',
  'review_required' => 'Транскрипт готов к проверке',
  'manual_ready' => 'Summary готов к просмотру',
  'retry_wait' => 'Нет связи. Повторим отправку автоматически',
  'auth_blocked' => 'Доступ к серверу приостановлен',
  'remote_unavailable' =>
    'Серверная встреча недоступна. Локальный источник сохранён',
  'needs_action' => 'Для продолжения нужно ваше решение',
  'paused' => 'Передача приостановлена',
  'cancelled' => 'Обработка отменена. Источник сохранён',
  'saved_with_changes' =>
    'Summary сохранён; более поздние правки остались в черновике',
  'draft' => 'Запись сохранена на устройстве',
  _ => 'Проверяем подключение',
};

class QueueProcessingPage extends StatefulWidget {
  const QueueProcessingPage({
    super.key,
    required this.workspace,
    required this.localId,
    this.recorder,
  });
  final DraftWorkspace workspace;
  final String localId;
  final DraftRecorderCoordinator? recorder;
  @override
  State<QueueProcessingPage> createState() => _QueueProcessingPageState();
}

class _QueueProcessingPageState extends State<QueueProcessingPage> {
  bool _opening = false, _busy = false;
  String? _error;
  LocalDraftRecord? get _record => widget.workspace.items
      .where((r) => r.localId == widget.localId)
      .firstOrNull;
  Json? get _completion => widget.workspace.completions
      .where((r) => r['local_id'] == widget.localId)
      .firstOrNull;
  @override
  void initState() {
    super.initState();
    widget.workspace.addListener(_changed);
    _changed();
    unawaited(widget.workspace.wakeQueue?.call());
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_completion != null &&
        !_opening &&
        (_record == null ? null : draftQueue(_record!)['stage']) !=
            'saved_with_changes') {
      _opening = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (mounted) await _openResult(_completion!['summary_id'] as String);
      });
    }
  }

  Future<void> _openResult(String id) async {
    try {
      final summary = await widget.workspace.api.summary(id);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute(
          builder: (_) => QueueSavedSummaryPage(
            workspace: widget.workspace,
            summary: summary,
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _opening = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _edit() async {
    final r = _record;
    if (r == null) return;
    if (![
      'review_required',
      'needs_action',
      'auth_blocked',
      'paused',
      'cancelled',
      'draft',
      'saved_with_changes',
    ].contains(draftQueue(r)['stage'])) {
      await widget.workspace.queueAction(r.localId, 'pause');
    }
    if (!mounted) return;
    final fresh = await widget.workspace.reader.read(r.localId);
    if (mounted) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => LocalDraftEditorPage(
            workspace: widget.workspace,
            record: fresh,
            recorder: widget.recorder,
          ),
        ),
      );
    }
  }

  Future<void> _action(String action) async {
    if (_busy) return;
    if (action == 'delete' || action == 'cancel') {
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            action == 'delete' ? 'Удалить встречу?' : 'Отменить обработку?',
          ),
          content: Text(
            action == 'delete'
                ? 'Сначала подтвердим удаление на сервере. До подтверждения исходник останется на устройстве.'
                : 'Уже принятые запросы будут проверены. Исходная запись останется на устройстве.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Назад'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                action == 'delete' ? 'Удалить' : 'Отменить обработку',
              ),
            ),
          ],
        ),
      );
      if (yes != true) return;
    }
    setState(() => _busy = true);
    try {
      await widget.workspace.queueAction(
        widget.localId,
        action,
        repair: action == 'retry',
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    widget.workspace.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = _record;
    final q = r == null ? <String, dynamic>{} : draftQueue(r);
    final stage = q['stage'];
    final stopped = [
      'auth_blocked',
      'needs_action',
      'remote_unavailable',
      'paused',
      'cancelled',
      'draft',
      'saved_with_changes',
    ].contains(stage);
    final review = stage == 'review_required', manual = stage == 'manual_ready';
    final template = widget.workspace.templates?.items
        .where((t) => t.id == r?.input.options['template_id'])
        .firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(r?.input.title ?? 'Совещание')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (!stopped && !review && !manual && r != null) ...[
              Text(
                'Шаблон: ${template?.input.name ?? 'По умолчанию'}',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 24),
            ],
            Text(
              r == null && _completion == null
                  ? 'Встреча удалена'
                  : queueStageLabel(q),
              textAlign: TextAlign.center,
            ),
            if (q['error_code'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(queueErrorExplanation(q['error_code'] as String)),
              ),
            if (q['next_attempt_at'] != null && stage == 'retry_wait')
              Text(
                'Следующая попытка: ${DateTime.parse(q['next_attempt_at'] as String).toLocal()}',
              ),
            if (_error != null) Text(_error!),
            if (review)
              FilledButton(
                onPressed: _edit,
                child: const Text('Проверить транскрипт'),
              ),
            if (manual)
              FilledButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => DraftSelectionPage(
                      workspace: widget.workspace,
                      localId: widget.localId,
                    ),
                  ),
                ),
                child: const Text('Открыть summary'),
              ),
            if (stopped && r != null) ...[
              if (stage != 'saved_with_changes' &&
                  stage != 'remote_unavailable')
                FilledButton(
                  onPressed: _busy ? null : () => _action('retry'),
                  child: const Text('Продолжить обработку'),
                ),
              OutlinedButton(
                onPressed: _busy ? null : _edit,
                child: const Text('Открыть черновик'),
              ),
            ],
            if (q['error_code'] == 'pipeline_parameters_locked')
              FilledButton(
                onPressed: _busy ? null : () => _action('reconcile'),
                child: const Text('Продолжить с принятыми настройками'),
              ),
            if (_completion != null)
              FilledButton(
                onPressed: () =>
                    _openResult(_completion!['summary_id'] as String),
                child: const Text('Открыть сохранённое summary'),
              ),
            if (r != null && !stopped && !review && !manual)
              TextButton(
                onPressed: _busy ? null : () => _action('pause'),
                child: const Text('Приостановить передачу'),
              ),
            if (r?.kind == LocalDraftKind.audio) ...[
              TextButton(
                onPressed: _busy ? null : () => _action('cancel'),
                child: const Text('Отменить обработку'),
              ),
              TextButton(
                onPressed: _busy ? null : () => _action('delete'),
                child: const Text('Удалить встречу'),
              ),
            ],
            if (r == null && _completion == null)
              TextButton(
                onPressed: () => returnToHome(context),
                child: const Text('На главную'),
              ),
          ],
        ),
      ),
    );
  }
}

String queueErrorExplanation(String code) => switch (code) {
  'review_remote_cancel_unavailable' => 'Сервер пока не разрешает удаление этой незавершённой записи. Передача приостановлена; аудио сохранено.',
  'pipeline_parameters_locked' => 'Сервер уже принял прежние настройки. Новые правки сохранены в черновике; автоматической замены не будет.',
  'processing_mode_locked' => 'Режим уже принят сервером. Для его изменения сначала отмените и удалите прежнюю операцию.',
  'demo_access_expired' || 'demo_key_required' || 'demo_key_invalid' => 'Проверьте доступ в настройках подключения. Автоматические запросы остановлены.',
  'boundary_review_required' =>
    'Нужно прочитать распознанный текст и проверить стыки фрагментов.',
  _ => 'Данные сохранены. Причина остановки: $code',
};

class QueueSavedSummaryPage extends StatefulWidget {
  const QueueSavedSummaryPage({
    super.key,
    required this.workspace,
    required this.summary,
  });
  final DraftWorkspace workspace;
  final MeetingSummary summary;
  @override
  State<QueueSavedSummaryPage> createState() => _QueueSavedSummaryPageState();
}

class _QueueMemoryStore extends RecoveryStore {
  RecoveryState value = RecoveryState();
  @override
  Future<RecoveryState> load() async => value;
  @override
  Future<void> save(RecoveryState state) async {
    value = state;
  }
}

class _QueueSavedSummaryPageState extends State<QueueSavedSummaryPage> {
  late final controller = MeetingController(
    widget.workspace.api,
    _QueueMemoryStore(),
  );
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SummaryPageView(controller: controller, summary: widget.summary);
}

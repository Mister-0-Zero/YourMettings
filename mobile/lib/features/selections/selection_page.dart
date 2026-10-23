import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../models/api_models.dart';
import '../../models/processing_options.dart';
import '../meetings/summary_document.dart';
import '../templates/template_scaffold.dart';
import '../templates/template_selector.dart';
import 'selection_controller.dart';

class SelectionPage extends StatefulWidget {
  const SelectionPage({
    super.key,
    required this.api,
    required this.slot,
    required this.source,
    required this.options,
    required this.title,
    this.original,
    this.onAccepted,
  });
  final ApiClient api;
  final String slot, title;
  final Future<Json> Function() source;
  final ProcessingOptions options;
  final MeetingSummary? original;
  final Future<void> Function(MeetingSummary)? onAccepted;
  @override
  State<SelectionPage> createState() => _SelectionPageState();
}

class _SelectionPageState extends State<SelectionPage>
    with WidgetsBindingObserver {
  late final c = SelectionController(
    api: widget.api,
    store: widget.api.operations!,
    slot: widget.slot,
    source: widget.source,
    initialOptions: widget.options,
    original: widget.original,
  );
  late ProcessingOptions _options = widget.options;
  bool _finishing = false, _allowExit = false;
  String? _finishError;
  String? _optionsCandidate;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_changed);
    unawaited(c.initialize());
  }

  void _changed() {
    if (c.activeId != _optionsCandidate) {
      _optionsCandidate = c.activeId;
      final options = c.active?['generation_options'] as Json?;
      setState(
        () => _options = options == null
            ? widget.options
            : ProcessingOptions.fromJson(options),
      );
    }
    if (c.accepted != null && !_finishing && _finishError == null) {
      unawaited(_finish());
    }
  }

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    try {
      final summary = c.accepted!;
      await widget.onAccepted?.call(summary);
      await c.complete();
      if (!mounted) return;
      setState(() => _allowExit = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context, summary);
    } catch (_) {
      if (mounted) {
        setState(
          () => _finishError = 'Встреча сохранена на сервере. Не удалось завершить локальное сохранение; повторите действие.',
        );
      }
    } finally {
      _finishing = false;
    }
  }

  Future<void> _leave() async {
    if (c.busy || _finishing) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Выйти из выбора?'),
        content: Text(
          c.state['cancel_pending'] == true
              ? 'Отмена выбора ещё не подтверждена. При возвращении проверим её состояние.'
              : c.frozen
              ? 'Подтверждение сохранения ещё не завершено. Выбор сохранён на устройстве; при возвращении проверим тот же вариант.'
              : 'Можно вернуться к вариантам позже или отменить выбор. Исходная встреча и транскрипт сохранятся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Продолжить выбор'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'keep'),
            child: const Text('Продолжить позже'),
          ),
          if (!c.frozen)
            TextButton(
              onPressed: () => Navigator.pop(context, 'cancel'),
              child: const Text('Отменить выбор'),
            ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'cancel' && !await c.cancel()) return;
    if (!mounted) return;
    setState(() => _allowExit = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      c.resume();
    } else {
      c.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(_changed);
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => PopScope(
      canPop: _allowExit,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: TemplateScaffold(
        appBar: AppBar(
          title: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: Column(
          children: [
            if (c.busy) const LinearProgressIndicator(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const Text(
                    'Сохранится только вариант, на котором вы нажмёте «Готово».',
                  ),
                  const SizedBox(height: 12),
                  TemplateSelector(
                    api: widget.api,
                    value: _options.templateId,
                    enabled:
                        !c.busy && !c.frozen && !c.terminal && !c.hasPending,
                    onChanged: (id) => setState(
                      () => _options = _options.copyWith(
                        templateId: id,
                        useDefaultTemplate: id == null,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed:
                        c.busy ||
                            c.frozen ||
                            c.terminal ||
                            c.state['session_id'] == null ||
                            c.generating
                        ? null
                        : () => c.generate(_options),
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(
                      c.hasPending
                          ? 'Повторить запрос'
                          : 'Создать вариант по шаблону',
                    ),
                  ),
                  Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: [
                      IconButton(
                        onPressed: c.canBack ? () => c.move(-1) : null,
                        tooltip: 'Предыдущий вариант',
                        icon: const Icon(Icons.arrow_back),
                      ),
                      Text(
                        c.showingOriginal
                            ? 'Сохранённый вариант'
                            : c.activeId == null
                            ? 'Варианты ещё не созданы'
                            : 'Вариант ${c.position + 1} из ${c.ids.length}',
                      ),
                      IconButton(
                        onPressed: c.canForward ? () => c.move(1) : null,
                        tooltip: 'Следующий вариант',
                        icon: const Icon(Icons.arrow_forward),
                      ),
                    ],
                  ),
                  if (c.active?['template_snapshot']
                      case final Map<String, dynamic> template)
                    Text(
                      template['name'] as String? ?? '',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  if (c.error != null) ...[
                    Text(
                      c.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    TextButton(
                      onPressed: c.busy ? null : c.refresh,
                      child: const Text('Повторить проверку'),
                    ),
                  ],
                  if (_finishError != null) ...[
                    Text(_finishError!),
                    TextButton(
                      onPressed: () => _finish(),
                      child: const Text('Завершить сохранение'),
                    ),
                  ],
                  if (c.active != null &&
                      ['queued', 'generating'].contains(c.active!['status']))
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Column(
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Qwen обрабатывает совещание…'),
                        ],
                      ),
                    ),
                  if (c.active?['status'] == 'error')
                    Text(
                      (c.active!['error'] as Map<String, dynamic>?)?['message']
                              as String? ??
                          'Обработка завершилась с ошибкой. Можно создать новый вариант.',
                    ),
                  if (c.content != null)
                    SummaryDocument(
                      key: ValueKey(c.activeId ?? 'original'),
                      content: c.content!,
                      navigation: c.navigation,
                    ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed:
                        c.busy ||
                            _finishing ||
                            c.terminal ||
                            !c.ready && !c.frozen
                        ? null
                        : c.accept,
                    icon: const Icon(Icons.check),
                    label: Text(c.frozen ? 'Подтвердить сохранение' : 'Готово'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

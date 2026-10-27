import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../models/api_models.dart';
import '../../models/processing_options.dart';
import '../meetings/summary_document.dart';
import '../templates/template_scaffold.dart';
import '../templates/template_selector.dart';
import 'selection_controller.dart';
import 'selection_editor.dart';

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
  String? _pendingTemplateName;
  bool _requesting = false;
  int _nameGeneration = 0;
  String get _templateName {
    if (_requesting || c.hasPending) {
      return _pendingTemplateName ?? 'Загружаем название шаблона…';
    }
    return (c.active?['template_snapshot'] as Json?)?['name'] as String? ??
        widget.original?.templateSnapshot?['name'] as String? ??
        _pendingTemplateName ??
        'Шаблон по умолчанию';
  }

  Future<void> _resolveName(String? id) async {
    final generation = ++_nameGeneration;
    try {
      final template = id == null
          ? (await widget.api.templates()).where((t) => t.isDefault).firstOrNull
          : await widget.api.template(id);
      if (mounted && generation == _nameGeneration) {
        setState(() => _pendingTemplateName = template?.input.name);
      }
    } catch (_) {
      /* Generation errors are reported by the operation itself. */
    }
  }

  Future<void> _generate(String? id) async {
    if (c.busy || c.frozen || c.generating || c.hasPending || c.terminal) {
      return;
    }
    setState(() {
      _options = _options.copyWith(
        templateId: id,
        useDefaultTemplate: id == null,
      );
      _pendingTemplateName = null;
      _requesting = true;
    });
    unawaited(_resolveName(id));
    try {
      await c.generate(_options);
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  Future<void> _edit() async {
    if (!c.canEdit || _finishing) return;
    c.pause();
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => SelectionEditor(
            title: c.title.isEmpty ? widget.title : c.title,
            content: c.content!,
            onApply: (title, content) =>
                c.editActive(title: title, content: content),
          ),
        ),
      );
    } finally {
      if (mounted) c.resume();
    }
  }

  Future<void> _accept() async {
    if (c.editConflict) {
      final overwrite = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Заменить изменённые поля?'),
          content: const Text(
            'На сервере уже есть другая правка. Сохранить ваши изменения поверх текущего текста?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Сохранить мои правки'),
            ),
          ],
        ),
      );
      if (overwrite == true && mounted) await c.retryEditsOverCurrent();
    } else {
      await c.accept();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_changed);
    unawaited(_resolveName(_options.templateId));
    unawaited(c.initialize());
  }

  void _changed() {
    final candidateKey = c.hasPending
        ? 'pending:${(c.state['candidate_pending'] as Json)['key']}'
        : c.activeId;
    if (candidateKey != _optionsCandidate) {
      _optionsCandidate = candidateKey;
      final options = c.hasPending
          ? (c.state['candidate_pending'] as Json)['options'] as Json?
          : c.active?['generation_options'] as Json?;
      setState(
        () => _options = options == null
            ? widget.options
            : ProcessingOptions.fromJson(options),
      );
      if (c.hasPending) unawaited(_resolveName(_options.templateId));
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

  Widget _errors(BuildContext context) => Column(
    children: [
      if (c.error != null) ...[
        Text(
          c.error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        TextButton(
          onPressed: c.busy
              ? null
              : c.editConflict
              ? _accept
              : c.refresh,
          child: Text(c.editConflict ? 'Повторить сохранение' : 'Повторить'),
        ),
      ],
      if (_finishError != null) ...[
        Text(_finishError!),
        TextButton(
          onPressed: _finish,
          child: const Text('Завершить сохранение'),
        ),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      final processing =
          _requesting ||
          c.hasPending ||
          c.generating ||
          (c.busy && !c.ready && !c.frozen);
      final canAct =
          c.ready && !c.busy && !c.frozen && !_finishing && !c.terminal;
      final hasHistory = c.ids.length + (widget.original == null ? 0 : 1) > 1;
      return PopScope(
        canPop: _allowExit,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _leave();
        },
        child: TemplateScaffold(
          appBar: AppBar(
            title: Text(
              c.title.isEmpty ? widget.title : c.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: processing
                ? null
                : [
                    if (c.ready)
                      IconButton(
                        onPressed: c.canEdit && !_finishing ? _edit : null,
                        tooltip: 'Редактировать',
                        icon: const Icon(Icons.edit_outlined),
                      ),
                    if (c.ready || c.frozen)
                      IconButton(
                        onPressed: c.busy || _finishing || c.terminal
                            ? null
                            : _accept,
                        tooltip: 'Сохранить встречу',
                        icon: const Icon(Icons.check),
                      ),
                  ],
          ),
          body: processing
              ? Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Выбранный шаблон: $_templateName',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 24),
                        const CircularProgressIndicator(),
                        const SizedBox(height: 20),
                        const Text(
                          'Qwen обрабатывает транскрипт',
                          textAlign: TextAlign.center,
                        ),
                        if (c.error != null) ...[
                          const SizedBox(height: 24),
                          _errors(context),
                        ],
                      ],
                    ),
                  ),
                )
              : Column(
                  children: [
                    if (c.busy || _finishing) const LinearProgressIndicator(),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(20),
                        children: [
                          TemplateSelector(
                            api: widget.api,
                            value: _options.templateId,
                            enabled:
                                canAct ||
                                (!c.busy &&
                                    !c.frozen &&
                                    !c.terminal &&
                                    c.active?['status'] == 'error'),
                            onChanged: (id) => _generate(id),
                          ),
                          if (hasHistory)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                IconButton(
                                  onPressed: c.canBack
                                      ? () => c.move(-1)
                                      : null,
                                  tooltip: 'Предыдущий вариант',
                                  icon: const Icon(Icons.arrow_back),
                                ),
                                Flexible(
                                  child: Text(
                                    c.showingOriginal
                                        ? 'Сохранённый вариант'
                                        : 'Вариант ${c.position + 1} из ${c.ids.length}',
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                                IconButton(
                                  onPressed: c.canForward
                                      ? () => c.move(1)
                                      : null,
                                  tooltip: 'Следующий вариант',
                                  icon: const Icon(Icons.arrow_forward),
                                ),
                              ],
                            ),
                          if (c.hasLocalEdits)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Text(
                                'Есть правки. Галочка сохранит открытый вариант.',
                              ),
                            ),
                          _errors(context),
                          if (c.active?['status'] == 'error') ...[
                            Text(
                              (c.active!['error'] as Json?)?['message']
                                      as String? ??
                                  'Не удалось обработать транскрипт.',
                            ),
                            TextButton(
                              onPressed: c.busy || c.frozen
                                  ? null
                                  : () => _generate(_options.templateId),
                              child: const Text('Повторить генерацию'),
                            ),
                          ],
                          const SizedBox(height: 16),
                          if (c.content != null)
                            SummaryDocument(
                              key: ValueKey(c.activeId ?? 'original'),
                              content: c.content!,
                              navigation: c.navigation,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      );
    },
  );
}

import '../../models/generation_source.dart';

import 'dart:async';

import '../selections/selection_page.dart';
import '../templates/template_selector.dart';
import '../../services/summary_clipboard.dart';
import '../../models/processing_options.dart';
import '../meetings/summary_page.dart';
import '../recording/audio_review_controller.dart';

import 'dart:typed_data';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../meetings/summary_document.dart';

import '../../models/api_models.dart';
import '../../services/recovery_store.dart';
import '../meetings/folder_picker.dart';
import 'meeting_controller.dart';

class TranscriptPage extends StatefulWidget {
  const TranscriptPage({
    super.key,
    required this.controller,
    this.onRecord,
    this.audioReview = false,
    this.reviewNotice,
  });
  final Future<void> Function(Draft)? onRecord;
  final bool audioReview;
  final Widget? reviewNotice;
  final MeetingController controller;
  @override
  State<TranscriptPage> createState() => _TranscriptPageState();
}

class _TranscriptPageState extends State<TranscriptPage> {
  final _form = GlobalKey<FormState>();
  final _settingsAnchor = GlobalKey();
  final _pageScroll = ScrollController();
  bool _settingsReached = false;
  bool _operationOpen = false;
  bool _cancelling = false;
  bool _allowExit = false;
  late final _text = TextEditingController(text: widget.controller.draft.text);
  late final _title = TextEditingController(
    text: widget.controller.draft.title,
  );
  late List<String> _folderIds = [...widget.controller.draft.folderIds];
  late bool _hadOperation = widget.controller.hasOperation;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_operationChanged);
    _pageScroll.addListener(_updateJumpVisibility);
    if (widget.controller.selectionActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openSelection();
      });
    } else if (_hadOperation) {
      _scheduleOperation();
    }
  }

  void _scheduleOperation() {
    if (_operationOpen) return;
    _operationOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !widget.controller.hasOperation) {
        _operationOpen = false;
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => GeneratedSummaryPage(controller: widget.controller),
        ),
      );
      _operationOpen = false;
    });
  }

  void _operationChanged() {
    if (!_hadOperation && widget.controller.hasOperation) _scheduleOperation();
    if (_hadOperation && !widget.controller.hasOperation) {
      _text.text = widget.controller.draft.text;
      _title.text = widget.controller.draft.title;
      _folderIds = [...widget.controller.draft.folderIds];
      _options = widget.controller.draft.options;
      _instructions.text = _options.additionalInstructions;
    }
    if (!widget.controller.hasOperation) {
      _folderIds = [...widget.controller.draft.folderIds];
    }
    if (_hadOperation != widget.controller.hasOperation && mounted) {
      setState(() => _hadOperation = widget.controller.hasOperation);
    }
  }

  late ProcessingOptions _options = widget.controller.draft.options;
  late final _instructions = TextEditingController(
    text: _options.additionalInstructions,
  );
  String? _inputError;
  bool _importing = false;
  bool _recordStarting = false;
  Future<void> _save() => widget.controller.saveDraft(
    Draft(
      text: _text.text,
      title: _title.text,
      folderIds: [..._folderIds],
      options: _options,
    ),
  );

  Future<void> _cancelCreation() async {
    if (_cancelling || widget.controller.working) return;
    final review = widget.controller as AudioReviewController;
    final alreadyDeleted = review.serverDeleted;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Что сделать со встречей?'),
        content: const Text(
          'Сохранённый черновик будет доступен в «Пространстве». После выхода можно начать новую запись.',
        ),
        actions: [
          SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextButton(
                  onPressed: alreadyDeleted
                      ? null
                      : () => Navigator.pop(context),
                  child: const Text(
                    'Продолжить редактирование',
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: alreadyDeleted
                      ? null
                      : () => Navigator.pop(context, 'save'),
                  child: const Text(
                    'Сохранить черновик и выйти',
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => Navigator.pop(context, 'delete'),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text(
                    'Удалить встречу',
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'delete' && !alreadyDeleted) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Удалить встречу?'),
          content: const Text(
            'Данные этой встречи будут удалены с сервера и этого устройства. Это действие нельзя отменить.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Удалить'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() {
      _cancelling = true;
      _inputError = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    await WidgetsBinding.instance.endOfFrame;
    await _save();
    if (!mounted) return;
    var success = false;
    if (widget.controller.storageError == null) {
      success = choice == 'delete'
          ? await review.deleteMeeting()
          : await review.defer();
    }
    if (!mounted) return;
    setState(() {
      _cancelling = false;
      _allowExit = success;
    });
    if (success) {
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } else {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              widget.controller.storageError ??
                  widget.controller.error ??
                  'Не удалось завершить действие. Данные не удалены.',
            ),
          ),
        );
    }
  }

  Future<void> _import() async {
    setState(() {
      _importing = true;
      _inputError = null;
    });
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['txt'],
      );
      if (file == null || !mounted) return;
      if (!file.name.toLowerCase().endsWith('.txt')) {
        throw const FormatException('Выберите файл .txt.');
      }
      final size = await file.length();
      if (size != null && size > 400000) {
        throw const FormatException('Файл превышает допустимый размер текста.');
      }
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in file.readAsByteStream()) {
        if (buffer.length + chunk.length > 400000) {
          throw const FormatException(
            'Файл превышает допустимый размер текста.',
          );
        }
        buffer.add(chunk);
      }
      final bytes = buffer.takeBytes();
      final text = utf8.decode(bytes).replaceFirst(RegExp(r'^\uFEFF'), '');
      final sourceError = _validateSource(text);
      if (sourceError != null) throw FormatException(sourceError);
      _text.text = text;
      _save();
    } catch (e) {
      if (mounted) {
        setState(
          () => _inputError = e is FormatException
              ? e.message
              : 'Не удалось загрузить файл.',
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _updateJumpVisibility() {
    if (!mounted) return;
    final box = _settingsAnchor.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final bottom =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom -
        MediaQuery.viewPaddingOf(context).bottom;
    final reached =
        box.localToGlobal(Offset.zero).dy + box.size.height <= bottom;
    if (_settingsReached != reached) setState(() => _settingsReached = reached);
  }

  Future<void> _scrollToSettings() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await WidgetsBinding.instance.endOfFrame;
    final anchor = _settingsAnchor.currentContext;
    if (anchor == null || !anchor.mounted) return;
    await Scrollable.ensureVisible(
      anchor,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
    );
  }

  Future<void> _folders() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final selected = await chooseFolders(
      context,
      widget.controller,
      _folderIds,
    );
    if (selected != null && mounted) {
      setState(() => _folderIds = selected);
      _save();
    }
  }

  Future<void> _openSelection() async {
    if (_operationOpen) return;
    _operationOpen = true;
    final controller = widget.controller;
    final navigator = Navigator.of(context);
    try {
      final result = await navigator.push<MeetingSummary>(
        MaterialPageRoute(
          builder: (_) => SelectionPage(
            api: controller.api,
            slot: controller.selectionSlot,
            source: controller.selectionSource,
            options: controller.draft.options,
            title: controller.draft.title,
            onAccepted: controller.selectionAccepted,
          ),
        ),
      );
      if (!mounted) return;
      if (result != null) {
        navigator.popUntil((r) => r.isFirst);
        unawaited(
          navigator.push<MeetingSummary>(
            MaterialPageRoute(
              builder: (_) =>
                  SummaryPageView(controller: controller, summary: result),
            ),
          ),
        );
      }
    } finally {
      _operationOpen = false;
    }
  }

  String? _validateSource(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Добавьте текст транскрипта';
    }
    if (widget.audioReview || widget.controller.api.operations == null) {
      return value.runes.length > 100000 ? 'Максимум 100 000 символов' : null;
    }
    return validateGenerationSource(value);
  }

  Future<void> _submit() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (!_form.currentState!.validate()) return;
    if (_folderIds.isEmpty) {
      setState(() => _inputError = 'Выберите хотя бы одну папку.');
      return;
    }
    setState(() => _inputError = null);
    await widget.controller.saveDraft(
      Draft(
        text: _text.text,
        title: _title.text.trim(),
        folderIds: [..._folderIds],
        options: _options,
      ),
    );
    if (widget.controller.storageError == null) {
      if (widget.onRecord != null) {
        setState(() => _recordStarting = true);
        try {
          await widget.onRecord!(widget.controller.draft);
        } finally {
          if (mounted) setState(() => _recordStarting = false);
        }
      } else {
        if (widget.controller.api.operations != null) {
          await _openSelection();
        } else {
          await widget.controller.submit();
        }
      }
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_operationChanged);
    _pageScroll.dispose();
    _instructions.dispose();
    _text.dispose();
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !widget.audioReview || _allowExit || widget.controller.hasOperation,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _cancelCreation();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          widget.onRecord == null ? 'Транскрипт встречи' : 'Перед записью',
        ),
      ),
      floatingActionButton: AnimatedBuilder(
        animation: Listenable.merge([widget.controller, _text]),
        builder: (context, _) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _updateJumpVisibility(),
          );
          return !widget.controller.hasOperation &&
                  !widget.controller.selectionActive &&
                  _text.text.trim().isNotEmpty &&
                  !_settingsReached
              ? FloatingActionButton.small(
                  heroTag: 'transcript-settings',
                  tooltip: 'К папкам и настройкам',
                  onPressed: _scrollToSettings,
                  child: const Icon(Icons.arrow_downward),
                )
              : const SizedBox.shrink();
        },
      ),
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final controller = widget.controller;
          if (controller.selectionActive) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: FilledButton(
                  onPressed: _openSelection,
                  child: const Text('Продолжить выбор результата'),
                ),
              ),
            );
          }
          if (controller.hasOperation) {
            return _AcceptedTranscriptPanel(
              key: ValueKey(controller.recovery.operation?.id ?? 'pending'),
              controller: controller,
              onOpen: _scheduleOperation,
            );
          }
          final folders = flattenFolders(controller.folders);
          return Form(
            key: _form,
            child: SingleChildScrollView(
              controller: _pageScroll,
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                20 + MediaQuery.viewPaddingOf(context).bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Черновик сохраняется на этом устройстве до принятия сервером. Используйте только неконфиденциальные тестовые данные.',
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _title,
                    readOnly:
                        controller.working ||
                        _cancelling ||
                        (controller is AudioReviewController &&
                            controller.serverDeleted),
                    onChanged: (_) => _save(),
                    maxLength: 200,
                    decoration: const InputDecoration(
                      labelText: 'Название встречи',
                    ),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? 'Введите название встречи'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  if (widget.onRecord == null && !widget.audioReview)
                    OutlinedButton.icon(
                      onPressed: _importing || controller.working
                          ? null
                          : _import,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Выбрать файл .txt'),
                    ),
                  const SizedBox(height: 12),
                  if (widget.onRecord == null)
                    TextFormField(
                      controller: _text,
                      readOnly:
                          controller.working ||
                          _cancelling ||
                          (controller is AudioReviewController &&
                              controller.serverDeleted),
                      onChanged: (_) => _save(),
                      minLines: 8,
                      maxLines: 18,
                      decoration: const InputDecoration(
                        labelText: 'Текст транскрипта',
                        hintText: 'Вставьте текст или загрузите файл .txt',
                      ),
                      validator: _validateSource,
                    ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    key: _settingsAnchor,
                    onPressed: controller.working ? null : _folders,
                    icon: const Icon(Icons.folder_outlined),
                    label: const Text('Выбрать или создать папки'),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final id in _folderIds)
                        Chip(
                          label: Text(
                            folders
                                    .where((entry) => entry.folder.id == id)
                                    .firstOrNull
                                    ?.path ??
                                'Выбранная папка',
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TemplateSelector(
                    api: controller.api,
                    value: _options.templateId,
                    enabled: !controller.working && !controller.hasOperation,
                    onChanged: (value) {
                      setState(
                        () => _options = _options.copyWith(
                          templateId: value,
                          useDefaultTemplate: value == null,
                        ),
                      );
                      _save();
                    },
                  ),
                  const SizedBox(height: 12),
                  ExpansionTile(
                    title: const Text('Настройки обработки'),
                    subtitle: const Text(
                      'Подробность и акценты итогового документа',
                    ),
                    childrenPadding: const EdgeInsets.all(16),
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: _options.detailLevel,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Детализация summary',
                          helperText:
                              'Определяет подробность итогового документа',
                          helperMaxLines: 3,
                        ),
                        items: ProcessingOptions.detailLevels.entries
                            .map(
                              (e) => DropdownMenuItem(
                                value: e.key,
                                child: Text(e.value),
                              ),
                            )
                            .toList(),
                        onChanged: controller.working
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(
                                    () => _options = _options.copyWith(
                                      detailLevel: value,
                                    ),
                                  );
                                  _save();
                                }
                              },
                      ),
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Акценты обработки',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final entry
                              in ProcessingOptions.focusLabels.entries)
                            FilterChip(
                              label: Text(entry.value),
                              selected: _options.focusAreas.contains(entry.key),
                              onSelected: controller.working
                                  ? null
                                  : (selected) {
                                      final areas = {..._options.focusAreas};
                                      if (selected) {
                                        areas.add(entry.key);
                                      } else {
                                        areas.remove(entry.key);
                                      }
                                      setState(
                                        () => _options = _options.copyWith(
                                          focusAreas: areas.toList(),
                                        ),
                                      );
                                      _save();
                                    },
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Дополнительные указания для ИИ'),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _instructions,
                        readOnly:
                            controller.working ||
                            _cancelling ||
                            (controller is AudioReviewController &&
                                controller.serverDeleted),
                        minLines: 3,
                        maxLines: 6,
                        maxLength: 2000,
                        decoration: const InputDecoration(
                          hintText: 'Отдельно выдели поручения конкретным сотрудникам, сохрани технические подробности обсуждения',
                        ),
                        validator: (value) =>
                            (value ?? '').trim().runes.length > 2000
                            ? 'Максимум 2000 символов'
                            : RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]')
                                  .hasMatch(value ?? '')
                            ? 'Удалите управляющие символы из указаний'
                            : null,
                        onChanged: (value) {
                          _options = _options.copyWith(
                            additionalInstructions: value,
                          );
                          _save();
                        },
                      ),
                    ],
                  ),
                  if (widget.reviewNotice != null) widget.reviewNotice!,
                  if (_inputError != null ||
                      controller.error != null ||
                      controller.storageError != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _inputError ??
                            controller.storageError ??
                            controller.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  if (widget.audioReview)
                    TextButton(
                      onPressed: controller.working || _cancelling
                          ? null
                          : _cancelCreation,
                      child: const Text('Отменить создание встречи'),
                    ),
                  FilledButton.icon(
                    onPressed:
                        controller.working ||
                            _recordStarting ||
                            _cancelling ||
                            (controller is AudioReviewController &&
                                controller.deletionPending)
                        ? null
                        : _submit,
                    icon: const Icon(Icons.auto_awesome_outlined),
                    label: Text(
                      widget.onRecord != null
                          ? 'Начать запись'
                          : widget.audioReview
                          ? 'Подтвердить и создать summary'
                          : 'Обработать',
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// A separate route keeps the source transcript in the navigation stack.
class GeneratedSummaryPage extends StatelessWidget {
  const GeneratedSummaryPage({super.key, required this.controller});
  final MeetingController controller;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Результат встречи')),
    body: AnimatedBuilder(
      animation: controller,
      builder: (_, _) => ProcessingPanel(controller: controller),
    ),
  );
}

class _AcceptedTranscriptPanel extends StatefulWidget {
  const _AcceptedTranscriptPanel({
    super.key,
    required this.controller,
    required this.onOpen,
  });
  final MeetingController controller;
  final VoidCallback onOpen;
  @override
  State<_AcceptedTranscriptPanel> createState() =>
      _AcceptedTranscriptPanelState();
}

class _AcceptedTranscriptPanelState extends State<_AcceptedTranscriptPanel> {
  late Future<Transcript>? _source = _load();
  Future<Transcript>? _load() {
    final id = widget.controller.recovery.operation?.id;
    return id == null ? null : widget.controller.api.transcript(id);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return SafeArea(
      top: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: widget.onOpen,
              child: Text(
                c.result == null ? 'Открыть обработку' : 'Открыть summary',
              ),
            ),
          ),
          Expanded(
            child: FutureBuilder<Transcript>(
              future: _source,
              builder: (_, snapshot) => ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    c.recovery.operation?.title ?? c.draft.title,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  if (_source == null)
                    SelectableText(
                      c.recovery.pending?.draft.text ?? c.draft.text,
                    )
                  else if (snapshot.hasData)
                    SelectableText(snapshot.data!.text)
                  else if (snapshot.hasError) ...[
                    const Text('Не удалось загрузить исходный транскрипт.'),
                    TextButton(
                      onPressed: () => setState(() {
                        _source = _load();
                      }),
                      child: const Text('Повторить загрузку'),
                    ),
                  ] else
                    const Center(child: CircularProgressIndicator()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ProcessingPanel extends StatelessWidget {
  const ProcessingPanel({super.key, required this.controller});
  final MeetingController controller;
  Future<void> _openResult(BuildContext context, MeetingSummary summary) async {
    final updated = await Navigator.of(context).push<MeetingSummary>(
      MaterialPageRoute(
        builder: (_) => SummaryPageView(
          controller: controller,
          summary: summary,
          startEditing: true,
        ),
      ),
    );
    if (updated != null) controller.summaryUpdated(updated);
  }

  Future<void> _dismiss(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Начать другую встречу?'),
        content: const Text(
          'Транскрипт останется на сервере, но приложение перестанет отслеживать эту обработку.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Новая встреча'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.finish();
  }

  Future<void> _accept(BuildContext context) async {
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    await controller.finish();
    if (!controller.hasOperation &&
        navigator.mounted &&
        route?.isCurrent == true) {
      navigator.popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = controller.result;
    final failed = controller.status?.phase == ProcessingPhase.error;
    final notStarted = controller.status?.phase == ProcessingPhase.notStarted;
    final message = controller.storageError ?? controller.error;
    return SafeArea(
      top: false,
      child: Column(
        children: [
          if (result != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  OutlinedButton.icon(
                    onPressed: controller.working
                        ? null
                        : () => _openResult(context, result),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Редактировать'),
                  ),
                  FilledButton.icon(
                    onPressed: controller.working
                        ? null
                        : () => _accept(context),
                    icon: const Icon(Icons.check),
                    label: const Text('Готово'),
                  ),
                  OutlinedButton.icon(
                    onPressed: controller.working
                        ? null
                        : () => copySummaryToClipboard(context, result),
                    icon: const Icon(Icons.copy_outlined),
                    label: const Text('Копировать итог'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (result != null) ...[
                  Text(
                    result.title,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  if (message != null) Text(message),
                  const SizedBox(height: 20),
                  SummaryDocument(
                    content: result.content,
                    navigation: result.navigation,
                  ),
                ] else ...[
                  if (!failed && !notStarted) ...[
                    const Center(child: CircularProgressIndicator()),
                    const SizedBox(height: 20),
                    Text(
                      message == null
                          ? 'Qwen обрабатывает совещание…'
                          : 'Соединение с сервером потеряно',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    const Text('Это может занять некоторое время'),
                  ] else
                    Text(
                      failed
                          ? 'Ошибка обработки Qwen'
                          : 'Обработка не запущена',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  if (message != null) ...[
                    const SizedBox(height: 12),
                    Text(message),
                  ],
                  if (failed || notStarted) ...[
                    if (controller.recovery.operation != null) ...[
                      TemplateSelector(
                        api: controller.api,
                        value:
                            controller.recovery.operation!.options.templateId,
                        enabled: !controller.working,
                        onChanged: controller.chooseRetryTemplate,
                      ),
                      const SizedBox(height: 16),
                    ],
                    FilledButton(
                      onPressed: controller.working ? null : controller.retry,
                      child: const Text('Повторить обработку'),
                    ),
                    TextButton(
                      onPressed: controller.working
                          ? null
                          : () => _dismiss(context),
                      child: const Text('Начать другую встречу'),
                    ),
                  ] else if (message != null)
                    TextButton(
                      onPressed: controller.working ? null : controller.check,
                      child: const Text('Восстановить соединение'),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

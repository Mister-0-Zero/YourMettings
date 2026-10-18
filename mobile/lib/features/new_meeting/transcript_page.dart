import '../../models/processing_options.dart';
import '../meetings/summary_page.dart';

import 'dart:typed_data';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../models/api_models.dart';
import '../../services/recovery_store.dart';
import '../meetings/folder_picker.dart';
import 'meeting_controller.dart';

class TranscriptPage extends StatefulWidget {
  const TranscriptPage({super.key, required this.controller});
  final MeetingController controller;
  @override
  State<TranscriptPage> createState() => _TranscriptPageState();
}

class _TranscriptPageState extends State<TranscriptPage> {
  final _form = GlobalKey<FormState>();
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
  }

  void _operationChanged() {
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
    _hadOperation = widget.controller.hasOperation;
  }

  late ProcessingOptions _options = widget.controller.draft.options;
  late final _instructions = TextEditingController(
    text: _options.additionalInstructions,
  );
  String? _inputError;
  bool _importing = false;
  void _save() {
    widget.controller.saveDraft(
      Draft(
        text: _text.text,
        title: _title.text,
        folderIds: [..._folderIds],
        options: _options,
      ),
    );
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
      if (text.runes.length > 100000) {
        throw const FormatException('Максимум 100 000 символов.');
      }
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

  Future<void> _folders() async {
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

  Future<void> _submit() async {
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
      await widget.controller.submit();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_operationChanged);
    _instructions.dispose();
    _text.dispose();
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Транскрипт встречи')),
    body: AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        if (controller.hasOperation) {
          return ProcessingPanel(controller: controller);
        }
        final folders = flattenFolders(controller.folders);
        return Form(
          key: _form,
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              20 + MediaQuery.viewPaddingOf(context).bottom,
            ),
            children: [
              const Text(
                'Черновик сохраняется на этом устройстве до принятия сервером. Используйте только неконфиденциальные тестовые данные.',
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _title,
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
              OutlinedButton.icon(
                onPressed: _importing ? null : _import,
                icon: const Icon(Icons.upload_file),
                label: const Text('Выбрать файл .txt'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _text,
                onChanged: (_) => _save(),
                minLines: 8,
                maxLines: 18,
                decoration: const InputDecoration(
                  labelText: 'Текст транскрипта',
                  hintText: 'Вставьте текст или загрузите файл .txt',
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Добавьте текст транскрипта'
                    : value.runes.length > 100000
                    ? 'Максимум 100 000 символов'
                    : null,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _folders,
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
              ExpansionTile(
                title: const Text('Настройки обработки'),
                subtitle: const Text(
                  'Подробность и акценты итогового документа',
                ),
                childrenPadding: const EdgeInsets.only(bottom: 16),
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _options.detailLevel,
                    decoration: const InputDecoration(
                      labelText: 'Детализация summary',
                      helperText: 'Определяет подробность итогового документа',
                    ),
                    items: ProcessingOptions.detailLevels.entries
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(
                          () =>
                              _options = _options.copyWith(detailLevel: value),
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
                      for (final entry in ProcessingOptions.focusLabels.entries)
                        FilterChip(
                          label: Text(entry.value),
                          selected: _options.focusAreas.contains(entry.key),
                          onSelected: (selected) {
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
                  TextFormField(
                    controller: _instructions,
                    minLines: 3,
                    maxLines: 6,
                    maxLength: 2000,
                    decoration: const InputDecoration(
                      labelText: 'Дополнительные указания для ИИ',
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
              if (_inputError != null ||
                  controller.error != null ||
                  controller.storageError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _inputError ?? controller.storageError ?? controller.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: controller.working ? null : _submit,
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('Обработать'),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class ProcessingPanel extends StatelessWidget {
  const ProcessingPanel({super.key, required this.controller});
  final MeetingController controller;
  Future<void> _openResult(BuildContext context, MeetingSummary summary) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SummaryPageView(
          controller: controller,
          summary: summary,
          startEditing: true,
        ),
      ),
    );
    if (controller.hasOperation) await controller.check();
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
    await controller.finish();
    if (!controller.hasOperation && context.mounted) {
      await Navigator.of(context).maybePop();
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
                    label: const Text('Принять'),
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
                  MarkdownBody(
                    data: result.content,
                    selectable: true,
                    styleSheet: MarkdownStyleSheet.fromTheme(
                      Theme.of(context),
                    ).copyWith(tableColumnWidth: const IntrinsicColumnWidth()),
                    imageBuilder: (uri, title, alt) =>
                        Text(alt ?? 'Изображение'),
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
                    const Text(
                      'Состояние проверяется автоматически и восстановится после перезапуска.',
                    ),
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

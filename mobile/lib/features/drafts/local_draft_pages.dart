import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:queue_owner/queue_owner.dart' show QueueOwnerLost;

import '../../models/api_models.dart';
import '../../models/processing_options.dart';
import '../../services/drafts/draft_record.dart';
import '../../services/drafts/draft_repository.dart';
import '../../services/drafts/draft_workspace.dart';
import '../recording/draft_recorder_coordinator.dart';
import '../recording/audio_wave.dart';

String draftStateLabel(LocalDraftRecord record) =>
    switch (record.toJson()['state']) {
      'recording' || 'capturing' => 'Идёт запись',
      'paused' => 'На паузе',
      'interrupted' => 'Запись прервана — аудио сохранено',
      'legacy_bridge' => 'Прежняя встреча — продолжить восстановление',
      'migration_prepared' ||
      'migration_pending' => 'Перенос не завершён — исходник сохранён',
      'ready' => 'Запись сохранена',
      _ => 'Черновик',
    };

class LocalDraftsPage extends StatelessWidget {
  const LocalDraftsPage({
    super.key,
    required this.workspace,
    required this.recorder,
    this.legacyBuilder,
  });
  final DraftWorkspace workspace;
  final DraftRecorderCoordinator recorder;
  final Widget Function(BuildContext context, LocalDraftRecord? legacy)?
  legacyBuilder;
  Future<void> _open(BuildContext context, LocalDraftRecord item) async {
    if (item.toJson()['state'] == 'legacy_bridge') {
      if (legacyBuilder != null) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (context) => legacyBuilder!(context, item),
          ),
        );
      }
      return;
    }
    if ([
      'migration_pending',
      'migration_prepared',
    ].contains(item.toJson()['state'])) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Перенос ещё не завершён. Данные сохранены; повторите запуск приложения.',
          ),
        ),
      );
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => item.localId == recorder.localId && recorder.recording
            ? LocalRecorderPage(
                workspace: workspace,
                recorder: recorder,
                localId: item.localId,
              )
            : LocalDraftEditorPage(
                workspace: workspace,
                record: item,
                recorder: recorder,
              ),
      ),
    );
    await workspace.reload();
  }

  Future<void> _newText(BuildContext context) async {
    try {
      final item = await workspace.create(LocalDraftKind.text);
      if (context.mounted) await _open(context, item);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось создать черновик. Проверьте свободное место или завершите запись.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Черновики'),
      actions: [
        IconButton(
          tooltip: 'Новый текстовый черновик',
          onPressed: () => _newText(context),
          icon: const Icon(Icons.note_add_outlined),
        ),
      ],
    ),
    body: SafeArea(
      child: AnimatedBuilder(
        animation: Listenable.merge([workspace, recorder]),
        builder: (context, _) => RefreshIndicator(
          onRefresh: workspace.reload,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (workspace.localError != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(workspace.localError!),
                ),
              if (workspace.issues.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    'Некоторые файлы требуют восстановления. Они сохранены на устройстве.',
                  ),
                ),
              if (workspace.items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Здесь сохраняются незавершённые встречи и записи.',
                  ),
                ),
              for (final item in workspace.items)
                Card(
                  child: ListTile(
                    leading: Icon(
                      item.kind == LocalDraftKind.audio
                          ? Icons.mic_none
                          : Icons.description_outlined,
                    ),
                    title: Text(
                      item.input.title.isEmpty
                          ? 'Без названия'
                          : item.input.title,
                    ),
                    subtitle: Text(draftStateLabel(item)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(context, item),
                  ),
                ),
              if (legacyBuilder != null)
                ListTile(
                  leading: const Icon(Icons.history),
                  title: const Text('Прежние незавершённые встречи'),
                  subtitle: const Text(
                    'Обработка, проверка транскрипта и сохранённые ранее черновики',
                  ),
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (context) => legacyBuilder!(context, null),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class LocalDraftEditorPage extends StatefulWidget {
  const LocalDraftEditorPage({
    super.key,
    required this.workspace,
    required this.record,
    this.recorder,
  });
  final DraftWorkspace workspace;
  final LocalDraftRecord record;
  final DraftRecorderCoordinator? recorder;
  @override
  State<LocalDraftEditorPage> createState() => _LocalDraftEditorPageState();
}

class _LocalDraftEditorPageState extends State<LocalDraftEditorPage>
    with WidgetsBindingObserver {
  late LocalDraftRecord _record = widget.record;
  late final _title = TextEditingController(text: _record.input.title);
  late final _text = TextEditingController(text: _record.input.text);
  late final _instructions = TextEditingController(
    text: ProcessingOptions.fromJson(_record.input.options)
        .additionalInstructions,
  );
  late final List<String> _folders = [..._record.input.folderIds];
  late ProcessingOptions _options = ProcessingOptions.fromJson(
    _record.input.options,
  );
  late bool _review = _record.input.processingMode == 'review',
      _autoStart = _record.autoStart;
  bool _dirty = false, _saving = false, _allowExit = false, _closed = false;
  bool _transitioning = false;
  String? _error;
  Timer? _debounce;
  Future<bool>? _saveFuture;
  final _settingsKey = GlobalKey();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _title.addListener(_changed);
    _text.addListener(_changed);
    _instructions.addListener(_changed);
  }

  void _changed() {
    if (_closed) return;
    setState(() {
      _dirty = true;
      _error = null;
    });
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_save()),
    );
  }

  LocalDraftInput _input() => LocalDraftInput(
    title: _title.text,
    text: _text.text,
    folderIds: _folders,
    options: _options
        .copyWith(additionalInstructions: _instructions.text)
        .toJson(),
    processingMode: _review ? 'review' : 'automatic',
  );
  String _fingerprint() =>
      jsonEncode({'input': _input().toJson(), 'auto': _autoStart});
  Future<bool> _save() {
    _debounce?.cancel();
    return _saveFuture ??= _saveLoop().whenComplete(() => _saveFuture = null);
  }

  Future<bool> _saveLoop() async {
    if (!_dirty) return true;
    if (mounted) setState(() => _saving = true);
    try {
      while (_dirty) {
        final fingerprint = _fingerprint(), input = _input(), auto = _autoStart;
        final next = await widget.workspace.save(
          _record.localId,
          revision: _record.revision,
          input: input,
          autoStart: auto,
        );
        _record = next;
        _dirty = _fingerprint() != fingerprint;
        _error = null;
        if (mounted && !_closed) setState(() {});
      }
      return true;
    } catch (error) {
      _error = error is QueueOwnerLost
          ? 'Диктофон сейчас сохраняет запись. Ввод остался на экране; повторите сохранение после её завершения.'
          : error is DraftRevisionConflict
          ? 'Черновик обновлён в другом месте. Ввод остался на экране; повторите открытие после копирования нужных правок.'
          : 'Не удалось сохранить черновик. Ввод остался на экране; проверьте свободное место и повторите.';
      return false;
    } finally {
      if (mounted && !_closed) setState(() => _saving = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_save());
  }

  Future<void> _leave() async {
    if (!_dirty) {
      setState(() => _allowExit = true);
      Navigator.pop(context);
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Выйти из черновика?'),
        content: const Text('Сохраните изменения, чтобы продолжить позже.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'continue'),
            child: const Text('Продолжить редактирование'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('Сохранить черновик и выйти'),
          ),
          if (_record.requests.isEmpty && _record.serverIds.isEmpty)
            TextButton(
              onPressed: () => Navigator.pop(context, 'delete'),
              child: const Text('Удалить встречу'),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'delete') {
      await _delete();
      return;
    }
    if (action == 'save' && await _save() && mounted) {
      setState(() => _allowExit = true);
      Navigator.pop(context);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить встречу?'),
        content: const Text('Локальный текст и аудиозапись будут удалены.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _debounce?.cancel();
    if (_saveFuture != null) await _saveFuture;
    try {
      await widget.workspace.deleteLocal(_record, confirmed: true);
      if (mounted) {
        _dirty = false;
        setState(() => _allowExit = true);
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Удаление не завершено. Данные сохранены; проверьте состояние встречи и повторите.',
        );
      }
    }
  }

  Future<void> _resumeRecording() async {
    if (_transitioning || widget.recorder == null) return;
    setState(() => _transitioning = true);
    try {
      // Programmatic replacement bypasses PopScope. It needs the same durable
      // save gate as an explicit back/save action, including a pending autosave.
      if (!await _save() || !mounted) return;
      await Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute(
          builder: (_) => LocalRecorderPage(
            workspace: widget.workspace,
            recorder: widget.recorder!,
            localId: _record.localId,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _transitioning = false);
    }
  }

  Future<void> _import() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['txt', 'md'],
      );
      if (file == null) return;
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in file.readAsByteStream()) {
        if (buffer.length + chunk.length > 10 * 1024 * 1024) {
          throw const FormatException('Text file size');
        }
        buffer.add(chunk);
      }
      final bytes = buffer.takeBytes();
      final text = utf8.decode(bytes).replaceFirst(RegExp('^\uFEFF'), '');
      if (mounted) _text.text = text;
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Не удалось прочитать UTF-8 файл. Предыдущий текст сохранён.',
        );
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    _debounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _title.dispose();
    _text.dispose();
    _instructions.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowExit || !_dirty,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_leave());
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          _record.kind == LocalDraftKind.audio
              ? 'Черновик записи'
              : 'Транскрипт встречи',
        ),
        actions: [
          IconButton(
            tooltip: 'Сохранить черновик',
            onPressed: _saving
                ? null
                : () async {
                    if (await _save() && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Черновик сохранён')),
                      );
                    }
                  },
            icon: _saving
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _saving
                      ? 'Сохраняем…'
                      : _dirty
                      ? 'Есть несохранённые изменения'
                      : 'Черновик сохранён на устройстве',
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    TextButton(
                      onPressed: _saving ? null : _save,
                      child: const Text('Повторить сохранение'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: AnimatedBuilder(
                animation: widget.workspace,
                builder: (context, _) => ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    TextField(
                      key: const Key('local-draft-title'),
                      controller: _title,
                      decoration: const InputDecoration(
                        labelText: 'Название встречи',
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_record.kind == LocalDraftKind.text) ...[
                      OutlinedButton.icon(
                        onPressed: _import,
                        icon: const Icon(Icons.upload_file),
                        label: const Text('Выбрать текстовый файл'),
                      ),
                      TextField(
                        key: const Key('local-draft-text'),
                        controller: _text,
                        minLines: 8,
                        maxLines: 16,
                        decoration: const InputDecoration(
                          labelText: 'Транскрипт',
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => Scrollable.ensureVisible(
                          _settingsKey.currentContext!,
                          duration: const Duration(milliseconds: 250),
                        ),
                        icon: const Icon(Icons.arrow_downward),
                        label: const Text('К папкам и настройкам'),
                      ),
                    ] else ...[
                      Text(
                        'Аудиозапись сохранена на этом устройстве. ${(((_record.toJson()['checkpoints'] as Json)['capture'] as Json?)?['byte_count'] as int? ?? 0) ~/ 32000} сек.',
                      ),
                      if (_record.toJson()['state'] == 'interrupted' &&
                          widget.recorder != null &&
                          _record.requests.isEmpty)
                        OutlinedButton.icon(
                          onPressed: _saving || _transitioning
                              ? null
                              : _resumeRecording,
                          icon: const Icon(Icons.mic),
                          label: const Text('Продолжить запись'),
                        ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      'Папки встречи',
                      key: _settingsKey,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (widget.workspace.folders == null)
                      const Text(
                        'Список папок появится после подключения к серверу. Черновик можно сохранить сейчас.',
                      ),
                    if (widget.workspace.folders?.isStale(DateTime.now()) ==
                        true)
                      const Text(
                        'Показаны ранее сохранённые папки. Список может быть устаревшим.',
                      ),
                    for (final entry in flattenFolders(
                      widget.workspace.folders?.items ?? <Folder>[],
                    ))
                      CheckboxListTile(
                        contentPadding: EdgeInsets.only(
                          left: entry.depth * 20.0,
                          right: 0,
                        ),
                        dense: true,
                        title: Text(entry.folder.name),
                        value: _folders.contains(entry.folder.id),
                        onChanged: (checked) {
                          if (checked == true) {
                            _folders.add(entry.folder.id);
                          } else {
                            _folders.remove(entry.folder.id);
                          }
                          _changed();
                        },
                      ),
                    for (final missing in _folders.where(
                      (id) => !flattenFolders(
                        widget.workspace.folders?.items ?? <Folder>[],
                      ).any((f) => f.folder.id == id),
                    ))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('Выбранная папка: $missing'),
                        subtitle: const Text('Пока нет в сохранённом списке'),
                        trailing: IconButton(
                          tooltip: 'Убрать выбранную папку',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _folders.remove(missing);
                            _changed();
                          },
                        ),
                      ),
                    OutlinedButton.icon(
                      onPressed: widget.workspace.refreshing
                          ? null
                          : widget.workspace.refreshCatalogs,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Обновить папки и шаблоны'),
                    ),
                    if (widget.workspace.catalogError != null)
                      Text(widget.workspace.catalogError!),
                    const SizedBox(height: 20),
                    DropdownButtonFormField<String>(
                      key: ValueKey('local-template-${_options.templateId}'),
                      initialValue: _options.templateId ?? '',
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Шаблон обработки',
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('Шаблон по умолчанию'),
                        ),
                        for (final template
                            in widget.workspace.templates?.items ?? [])
                          DropdownMenuItem(
                            value: template.id,
                            child: Text(template.input.name),
                          ),
                        if (_options.templateId != null &&
                            !(widget.workspace.templates?.items.any(
                                  (t) => t.id == _options.templateId,
                                ) ??
                                false))
                          DropdownMenuItem(
                            value: _options.templateId,
                            child: const Text(
                              'Выбранный шаблон пока недоступен',
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        final selected =
                            (widget.workspace.templates?.items ?? [])
                                .where((t) => t.id == value)
                                .firstOrNull;
                        _options = value.isEmpty
                            ? _options.copyWith(useDefaultTemplate: true)
                            : _options.copyWith(
                                templateId: value,
                                expectedTemplateVersion: selected?.version,
                              );
                        _changed();
                      },
                    ),
                    if (widget.workspace.templates?.isStale(DateTime.now()) ==
                        true)
                      const Text(
                        'Каталог шаблонов сохранён ранее; его версия проверится перед обработкой.',
                      ),
                    const SizedBox(height: 12),
                    ExpansionTile(
                      title: const Text('Настройки обработки'),
                      childrenPadding: const EdgeInsets.fromLTRB(0, 16, 0, 16),
                      children: [
                        DropdownButtonFormField<String>(
                          initialValue: _options.detailLevel,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Детализация summary',
                            floatingLabelBehavior: FloatingLabelBehavior.always,
                          ),
                          items: [
                            for (final entry
                                in ProcessingOptions.detailLevels.entries)
                              DropdownMenuItem(
                                value: entry.key,
                                child: Text(entry.value),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              _options = _options.copyWith(detailLevel: value);
                              _changed();
                            }
                          },
                        ),
                        const SizedBox(height: 16),
                        for (final entry
                            in ProcessingOptions.focusLabels.entries)
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(entry.value),
                            value: _options.focusAreas.contains(entry.key),
                            onChanged: (checked) {
                              final areas = [..._options.focusAreas];
                              checked == true
                                  ? areas.add(entry.key)
                                  : areas.remove(entry.key);
                              _options = _options.copyWith(focusAreas: areas);
                              _changed();
                            },
                          ),
                        TextField(
                          controller: _instructions,
                          minLines: 2,
                          maxLines: 5,
                          decoration: const InputDecoration(
                            labelText: 'Дополнительные пожелания',
                          ),
                        ),
                      ],
                    ),
                    if (_record.kind == LocalDraftKind.audio)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Показать транскрипт'),
                        subtitle: Text(
                          _review ? 'Проверить распознанный текст перед Qwen' : 'Сформировать и сохранить summary автоматически',
                        ),
                        value: _review,
                        onChanged: (value) {
                          _review = value;
                          _changed();
                        },
                      ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Начать обработку при подключении'),
                      subtitle: const Text(
                        'Только для этой встречи, когда её сервер снова станет доступен',
                      ),
                      value: _autoStart,
                      onChanged: (value) {
                        _autoStart = value;
                        _changed();
                      },
                    ),
                    const SizedBox(height: 12),
                    if (_record.requests.isEmpty && _record.serverIds.isEmpty)
                      TextButton.icon(
                        onPressed: _saving ? null : _delete,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Удалить встречу'),
                      ),
                    if (_record.requests.isNotEmpty ||
                        _record.serverIds.isNotEmpty)
                      const Text(
                        'Есть принятая или неподтверждённая серверная операция. Локальные данные сохраняются до проверки её результата.',
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class LocalRecorderPage extends StatefulWidget {
  const LocalRecorderPage({
    super.key,
    required this.workspace,
    required this.recorder,
    this.localId,
  });
  final DraftWorkspace workspace;
  final DraftRecorderCoordinator recorder;
  final String? localId;
  @override
  State<LocalRecorderPage> createState() => _LocalRecorderPageState();
}

class _LocalRecorderPageState extends State<LocalRecorderPage> {
  late String? _id = widget.localId;
  bool _working = false;
  Future<void> _start() async {
    setState(() => _working = true);
    final item = await widget.recorder.start(resumeId: _id);
    if (mounted) {
      setState(() {
        _id = item?.localId ?? _id;
        _working = false;
      });
    }
  }

  Future<void> _finish() async {
    setState(() => _working = true);
    final ok = await widget.recorder.command('stop');
    if (!mounted) return;
    setState(() => _working = false);
    if (!ok || _id == null) return;
    final record = await widget.workspace.reader.read(_id!);
    if (mounted) {
      await Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute(
          builder: (_) => LocalDraftEditorPage(
            workspace: widget.workspace,
            record: record,
            recorder: widget.recorder,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.recorder,
    builder: (context, _) {
      final owns = _id != null && _id == widget.recorder.localId;
      final phase = owns ? widget.recorder.phase : 'draft';
      final active = ['recording', 'paused', 'capturing'].contains(phase);
      final seconds =
          (owns ? widget.recorder.state['duration_ms'] as int? ?? 0 : 0) ~/
          1000;
      return Scaffold(
        appBar: AppBar(title: const Text('Запись совещания')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Запись сохраняется на устройстве. Интернет для микрофона не требуется.',
              ),
              const SizedBox(height: 32),
              Center(
                child: IconButton(
                  key: const Key('local-record-start'),
                  tooltip: active ? 'Микрофон включён' : 'Начать запись',
                  icon: Icon(
                    active ? Icons.mic : Icons.mic_none,
                    size: 80,
                    color: active ? Colors.red : null,
                  ),
                  onPressed: active || _working ? null : _start,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                '${(seconds ~/ 3600).toString().padLeft(2, '0')}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.displaySmall,
              ),
              AudioWave(
                samples: widget.recorder.meter,
                active: phase == 'recording',
                onVisibilityChanged: widget.recorder.setMeterVisible,
              ),
              if (active) ...[
                OutlinedButton.icon(
                  onPressed: _working || phase == 'capturing'
                      ? null
                      : () => widget.recorder.command(
                          phase == 'paused' ? 'resume' : 'pause',
                        ),
                  icon: Icon(
                    phase == 'paused' ? Icons.play_arrow : Icons.pause,
                  ),
                  label: Text(phase == 'paused' ? 'Продолжить' : 'Пауза'),
                ),
                FilledButton.icon(
                  onPressed: _working || phase == 'capturing' ? null : _finish,
                  icon: const Icon(Icons.stop),
                  label: const Text('Завершить запись'),
                ),
                const Text(
                  'Можно закрыть этот экран: запись продолжится с уведомлением.',
                ),
              ],
              if (_working) const Center(child: CircularProgressIndicator()),
              if (widget.recorder.error != null) Text(widget.recorder.error!),
            ],
          ),
        ),
      );
    },
  );
}

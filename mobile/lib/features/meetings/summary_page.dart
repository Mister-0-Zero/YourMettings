import '../selections/selection_page.dart';
import '../../models/processing_options.dart';

import 'package:flutter/material.dart';

import 'summary_document.dart';

import '../../models/api_models.dart';
import '../../services/summary_clipboard.dart';
import '../new_meeting/meeting_controller.dart';
import 'folder_picker.dart';
import 'summary_editor.dart';
import 'visual_document.dart';
import 'visual_editor.dart';

class SummaryPageView extends StatefulWidget {
  const SummaryPageView({
    super.key,
    required this.controller,
    required this.summary,
    this.startEditing = false,
  });
  final MeetingController controller;
  final MeetingSummary summary;
  final bool startEditing;
  @override
  State<SummaryPageView> createState() => _SummaryPageViewState();
}

class _SummaryPageViewState extends State<SummaryPageView> {
  SummaryEditor? _editor;
  late Future<void> _loading = _load();
  final _title = TextEditingController();
  VisualDocument? _visual;
  late bool _editing = widget.startEditing;
  bool _busy = false;
  bool _allowExit = false;
  Future<void> _load() async {
    final latest = await widget.controller.api.summary(widget.summary.id);
    if (!mounted) return;
    _visual?.dispose();
    _editor?.dispose();
    _editor = SummaryEditor(widget.controller.api, latest);
    _title.text = latest.title;
    _visual = VisualDocument(
      latest.content,
      onChanged: (content, error) {
        if (error != null) {
          _editor!.blockContentSave(error);
        } else {
          _editor!.edit(content: content!);
        }
      },
    );
  }

  Future<bool> _flush() async {
    final editor = _editor;
    if (editor == null) return true;
    if (_editing) {
      FocusManager.instance.primaryFocus?.unfocus();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return false;
      editor.edit(title: _title.text);
      try {
        editor.edit(content: _visual!.export());
      } on FormatException catch (e) {
        editor.blockContentSave(e.message);
      }
    }
    final saved = await editor.flush();
    if (!saved && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              editor.error ??
                  'Не удалось сохранить изменения. Повторите попытку.',
            ),
          ),
        );
    }
    return saved;
  }

  void _resetVisual() {
    final editor = _editor!;
    _visual?.dispose();
    _title.text = editor.title;
    _visual = VisualDocument(
      editor.content,
      onChanged: (content, error) {
        if (error != null) {
          editor.blockContentSave(error);
        } else {
          editor.edit(content: content!);
        }
      },
    );
  }

  Future<void> _closeEditing() async {
    _editor!.resumeAutosave();
    FocusManager.instance.primaryFocus?.unfocus();
    if (widget.startEditing) {
      setState(() => _allowExit = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop(_editor!.summary);
    } else {
      _resetVisual();
      setState(() => _editing = false);
    }
  }

  Future<void> _leave() async {
    if (_busy || !mounted) return;
    if (!_editing) {
      setState(() => _allowExit = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() => _busy = true);
    try {
      await _editor!.pauseAutosave();
      if (!mounted) return;
      if (_editor!.hasUnsavedChanges) {
        final choice = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Сохранить изменения?'),
            content: const Text('Есть несохранённые изменения в документе.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Продолжить редактирование'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'discard'),
                child: const Text('Отменить изменения'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, 'save'),
                child: const Text('Сохранить'),
              ),
            ],
          ),
        );
        if (!mounted || choice == null) return;
        if (choice == 'save') {
          if (!await _flush() || !mounted) return;
        } else {
          _editor!.discardUnsaved();
        }
      }
      if (mounted) await _closeEditing();
    } finally {
      if (mounted) {
        if (_editing && !_allowExit) _editor!.resumeAutosave();
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _confirmEditing() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (await _flush() && mounted) await _closeEditing();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeFolders() async {
    if (!await _flush() || !mounted) return;
    final selected = await chooseFolders(
      context,
      widget.controller,
      _editor!.summary.folderIds,
    );
    if (selected == null || !mounted) return;
    setState(() => _busy = true);
    try {
      _editor!.setFolders(
        await widget.controller.api.setSummaryFolders(
          widget.summary.id,
          selected,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить результат встречи?'),
        content: const Text(
          'Удалить этот результат встречи? Если исходный транскрипт больше нигде не используется, он также будет удалён.',
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
    if (confirmed != true || !mounted || !await _flush()) return;
    setState(() => _busy = true);
    try {
      await widget.controller.api.deleteSummary(widget.summary.id);
      await widget.controller.summaryDeleted(widget.summary.transcriptId);
      if (!mounted) return;
      setState(() => _allowExit = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeTemplate() async {
    if (_busy) return;
    final summary = _editor!.summary;
    final selected = await Navigator.of(context).push<MeetingSummary>(
      MaterialPageRoute(
        builder: (_) => SelectionPage(
          api: widget.controller.api,
          slot: 'summary-selection:${summary.id}',
          source: () async => {'summary_id': summary.id},
          options: ProcessingOptions.fromJson(summary.generationOptions ?? {}),
          title: summary.title,
          original: summary,
        ),
      ),
    );
    if (selected != null && mounted) {
      widget.controller.summaryUpdated(selected);
      setState(() {
        _loading = _load();
      });
    }
  }

  void _action(String action) {
    if (action == 'template') _changeTemplate();
    if (action == 'copy') copySummaryToClipboard(context, _editor!.summary);
    if (action == 'folders') _changeFolders();
    if (action == 'delete') _delete();
    if (action == 'transcript') {
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => _TranscriptView(
            controller: widget.controller,
            id: widget.summary.transcriptId,
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _editor?.dispose();
    _title.dispose();
    _visual?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _loading,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done ||
          snapshot.hasError) {
        return Scaffold(
          appBar: AppBar(title: Text(widget.summary.title)),
          body: Center(
            child: snapshot.hasError
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(snapshot.error.toString()),
                        TextButton(
                          onPressed: () => setState(() {
                            _loading = _load();
                          }),
                          child: const Text('Повторить'),
                        ),
                      ],
                    ),
                  )
                : const CircularProgressIndicator(),
          ),
        );
      }
      final editor = _editor!;
      return AnimatedBuilder(
        animation: editor,
        builder: (context, _) => PopScope<void>(
          canPop: _allowExit,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _leave();
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(
                editor.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                if (_editing)
                  IconButton(
                    onPressed: _busy ? null : _confirmEditing,
                    icon: const Icon(Icons.check),
                    tooltip: 'Сохранить изменения',
                  )
                else
                  Tooltip(
                    message: 'Редактировать',
                    child: TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () {
                              _resetVisual();
                              setState(() => _editing = true);
                            },
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Редактировать'),
                    ),
                  ),
                if (!_editing)
                  PopupMenuButton<String>(
                    enabled: !_busy,
                    onSelected: _action,
                    itemBuilder: (_) => [
                      if (widget.controller.api.operations != null)
                        const PopupMenuItem(
                          value: 'template',
                          child: Text('Изменить шаблон'),
                        ),
                      PopupMenuItem(
                        value: 'copy',
                        child: Text('Копировать итог'),
                      ),
                      PopupMenuItem(
                        value: 'transcript',
                        child: Text('Исходный транскрипт'),
                      ),
                      PopupMenuItem(
                        value: 'folders',
                        child: Text('Папки встречи'),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text('Удалить summary'),
                      ),
                    ],
                  ),
              ],
            ),
            body: Column(
              children: [
                if (editor.saving) const LinearProgressIndicator(),
                if (editor.error != null)
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Text(
                        editor.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(
                      20,
                      20,
                      20,
                      20 + MediaQuery.viewPaddingOf(context).bottom,
                    ),
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              editor.error != null
                                  ? 'Изменения не сохранены'
                                  : editor.saving
                                  ? 'Сохраняем…'
                                  : editor.dirty
                                  ? 'Несохранённые изменения'
                                  : 'Все изменения сохранены',
                            ),
                          ),
                          if (editor.dirty || editor.error != null)
                            TextButton(
                              onPressed: editor.saving || _busy
                                  ? null
                                  : _confirmEditing,
                              child: const Text('Сохранить'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (_editing) ...[
                        TextField(
                          controller: _title,
                          maxLength: 200,
                          enabled: !_busy,
                          decoration: const InputDecoration(
                            labelText: 'Название встречи',
                          ),
                          onChanged: (value) => editor.edit(title: value),
                        ),
                        const SizedBox(height: 16),
                        VisualEditorBody(document: _visual!, enabled: !_busy),
                      ] else
                        SummaryDocument(
                          content: editor.content,
                          navigation: editor.summary.navigation,
                        ),
                    ],
                  ),
                ),
                if (_editing)
                  SafeArea(
                    top: false,
                    child: Material(
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      child: VisualEditorToolbar(
                        key: const Key('editor-formatting-toolbar'),
                        document: _visual!,
                        enabled: !_busy,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _TranscriptView extends StatefulWidget {
  const _TranscriptView({required this.controller, required this.id});
  final MeetingController controller;
  final String id;
  @override
  State<_TranscriptView> createState() => _TranscriptViewState();
}

class _TranscriptViewState extends State<_TranscriptView> {
  late Future<Transcript> _request = widget.controller.api.transcript(
    widget.id,
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Исходный транскрипт')),
    body: FutureBuilder<Transcript>(
      future: _request,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              20 + MediaQuery.viewPaddingOf(context).bottom,
            ),
            child: SelectableText(snapshot.data!.text),
          );
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(snapshot.error.toString()),
                  TextButton(
                    onPressed: () => setState(
                      () => _request = widget.controller.api.transcript(
                        widget.id,
                      ),
                    ),
                    child: const Text('Повторить'),
                  ),
                ],
              ),
            ),
          );
        }
        return const Center(child: CircularProgressIndicator());
      },
    ),
  );
}

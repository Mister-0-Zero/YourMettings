import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../models/api_models.dart';
import '../new_meeting/meeting_controller.dart';
import 'folder_picker.dart';
import 'summary_editor.dart';

class SummaryPageView extends StatefulWidget {
  const SummaryPageView({
    super.key,
    required this.controller,
    required this.summary,
  });
  final MeetingController controller;
  final MeetingSummary summary;
  @override
  State<SummaryPageView> createState() => _SummaryPageViewState();
}

class _SummaryPageViewState extends State<SummaryPageView> {
  SummaryEditor? _editor;
  late Future<void> _loading = _load();
  final _title = TextEditingController();
  final _content = TextEditingController();
  bool _editing = false;
  bool _busy = false;
  bool _allowExit = false;
  Future<void> _load() async {
    final latest = await widget.controller.api.summary(widget.summary.id);
    _editor?.dispose();
    _editor = SummaryEditor(widget.controller.api, latest);
    _title.text = latest.title;
    _content.text = latest.content;
  }

  Future<void> _leave() async {
    if (_busy || !mounted) return;
    final ok = await _editor?.flush() ?? true;
    if (!ok || !mounted) return;
    setState(() => _allowExit = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _toggleEditor() async {
    if (_editing && !await _editor!.flush()) return;
    if (mounted) setState(() => _editing = !_editing);
  }

  Future<void> _changeFolders() async {
    if (!await _editor!.flush() || !mounted) return;
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
          'Summary будет удалён из всех связанных папок. Исходный транскрипт останется на сервере.',
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
    if (confirmed != true || !mounted || !await _editor!.flush()) return;
    setState(() => _busy = true);
    try {
      await widget.controller.api.deleteSummary(widget.summary.id);
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

  void _action(String action) {
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
    _content.dispose();
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
                          onPressed: () => setState(() => _loading = _load()),
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
              title: Text(editor.title),
              actions: [
                IconButton(
                  onPressed: _busy ? null : _toggleEditor,
                  icon: Icon(
                    _editing ? Icons.visibility_outlined : Icons.edit_outlined,
                  ),
                  tooltip: _editing ? 'Предпросмотр' : 'Редактировать',
                ),
                PopupMenuButton<String>(
                  enabled: !_busy,
                  onSelected: _action,
                  itemBuilder: (_) => const [
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
            body: ListView(
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                20 + MediaQuery.viewPaddingOf(context).bottom,
              ),
              children: [
                if (_busy || editor.saving) const LinearProgressIndicator(),
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
                        onPressed: editor.saving || _busy ? null : editor.flush,
                        child: const Text('Сохранить'),
                      ),
                  ],
                ),
                if (editor.error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      editor.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
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
                  TextField(
                    controller: _content,
                    minLines: 12,
                    maxLines: null,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Содержание (Markdown)',
                    ),
                    onChanged: (value) => editor.edit(content: value),
                  ),
                ] else
                  MarkdownBody(
                    data: editor.content,
                    selectable: true,
                    styleSheet: MarkdownStyleSheet.fromTheme(
                      Theme.of(context),
                    ).copyWith(tableColumnWidth: const IntrinsicColumnWidth()),
                    imageBuilder: (uri, title, alt) =>
                        Text(alt ?? 'Изображение'),
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

import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../app/appearance.dart';
import '../../models/api_models.dart';
import '../new_meeting/meeting_controller.dart';
import 'folder_picker.dart';
import 'summary_page.dart';

class MeetingsPage extends StatelessWidget {
  const MeetingsPage({super.key, required this.controller});
  final MeetingController controller;
  Future<void> _newFolder(BuildContext context) async {
    await createFolderDialog(context, controller);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => RefreshIndicator(
      onRefresh: controller.loadFolders,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Папки',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              IconButton(
                onPressed: controller.loadingFolders
                    ? null
                    : controller.loadFolders,
                icon: const Icon(Icons.refresh),
                tooltip: 'Обновить папки',
              ),
              IconButton(
                onPressed: () => _newFolder(context),
                icon: const Icon(Icons.create_new_folder_outlined),
                tooltip: 'Создать папку',
              ),
            ],
          ),
          if (controller.loadingFolders) const LinearProgressIndicator(),
          if (controller.folderError != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(controller.folderError!),
            ),
          if (controller.folders.isEmpty &&
              !controller.loadingFolders &&
              controller.folderError == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Папок пока нет. Создайте первую папку для своих встреч.',
              ),
            ),
          for (final folder in controller.folders)
            _FolderNode(
              key: ValueKey(folder.id),
              folder: folder,
              controller: controller,
            ),
        ],
      ),
    ),
  );
}

class _FolderNode extends StatefulWidget {
  const _FolderNode({
    super.key,
    this.depth = 0,
    required this.folder,
    required this.controller,
  });
  final Folder folder;
  final int depth;
  final MeetingController controller;
  @override
  State<_FolderNode> createState() => _FolderNodeState();
}

class _FolderNodeState extends State<_FolderNode> {
  bool _busy = false;
  bool _expanded = false;
  Future<void> _action(String action) async {
    if (action == 'delete') {
      setState(() => _busy = true);
      await deleteFolderWithConfirmation(
        context,
        widget.controller,
        widget.folder,
      );
      if (mounted) setState(() => _busy = false);
      return;
    }
    setState(() => _busy = true);
    try {
      if (action == 'create') {
        await createFolderDialog(
          context,
          widget.controller,
          parentId: widget.folder.id,
        );
      } else {
        final name = await folderNameDialog(
          context,
          initial: widget.folder.name,
        );
        if (name == null || !mounted) return;
        await widget.controller.api.renameFolder(widget.folder.id, name);
        await widget.controller.loadFolders();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => FolderContentsPage(
        controller: widget.controller,
        folder: widget.folder,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      children: [
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(
            widget.folder.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: _busy ? null : _open,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.folder.children.isNotEmpty)
                IconButton(
                  key: ValueKey('expand-${widget.folder.id}'),
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                  tooltip: _expanded
                      ? 'Свернуть подпапки'
                      : 'Показать подпапки',
                ),
              if (_busy)
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                PopupMenuButton<String>(
                  onSelected: _action,
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'create',
                      child: Text('Создать вложенную папку'),
                    ),
                    PopupMenuItem(
                      value: 'rename',
                      child: Text('Переименовать'),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('Удалить папку'),
                    ),
                  ],
                ),
            ],
          ),
        ),
        if (_expanded)
          Padding(
            padding: EdgeInsets.only(left: widget.depth < 3 ? 12 : 0),
            child: Column(
              children: [
                for (final child in widget.folder.children)
                  _FolderNode(
                    key: ValueKey(child.id),
                    folder: child,
                    depth: widget.depth + 1,
                    controller: widget.controller,
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

class FolderContentsPage extends StatefulWidget {
  const FolderContentsPage({
    super.key,
    required this.controller,
    required this.folder,
  });
  final MeetingController controller;
  final Folder folder;
  @override
  State<FolderContentsPage> createState() => _FolderContentsPageState();
}

class _FolderContentsPageState extends State<FolderContentsPage> {
  final List<MeetingSummary> _items = [];
  int _total = 0;
  bool _loading = false;
  bool _deleting = false;
  bool _creating = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.controller.loadFolders());
    });
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.controller.api.summaries(
        widget.folder.id,
        offset: reset ? 0 : _items.length,
      );
      if (!mounted || !context.mounted) return;
      setState(() {
        if (reset) _items.clear();
        _items.addAll(page.items);
        _total = page.total;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(MeetingSummary summary) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            SummaryPageView(controller: widget.controller, summary: summary),
      ),
    );
    await _load(reset: true);
  }

  Folder? get _currentFolder {
    for (final entry in flattenFolders(widget.controller.folders)) {
      if (entry.folder.id == widget.folder.id) return entry.folder;
    }
    return null;
  }

  Future<void> _refresh() async {
    await Future.wait<void>([
      widget.controller.loadFolders(),
      _load(reset: true),
    ]);
  }

  Future<void> _createChild() async {
    if (_creating || _currentFolder == null) return;
    setState(() => _creating = true);
    await createFolderDialog(
      context,
      widget.controller,
      parentId: widget.folder.id,
    );
    if (mounted) setState(() => _creating = false);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final folder = _currentFolder;
      return Scaffold(
        appBar: AppBar(
          title: Text(
            folder?.name ?? widget.folder.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: 'Удалить папку',
              icon: const Icon(Icons.delete_outline),
              onPressed: _loading || _deleting || _creating || folder == null
                  ? null
                  : () async {
                      setState(() => _deleting = true);
                      final deleted = await deleteFolderWithConfirmation(
                        context,
                        widget.controller,
                        folder,
                      );
                      if (!mounted || !context.mounted) return;
                      setState(() => _deleting = false);
                      if (deleted) Navigator.of(context).pop();
                    },
            ),
            IconButton(
              onPressed: _loading || widget.controller.loadingFolders
                  ? null
                  : _refresh,
              icon: const Icon(Icons.refresh),
              tooltip: 'Обновить содержимое',
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              16 + MediaQuery.viewPaddingOf(context).bottom,
            ),
            children: [
              Text(
                'Вложенные папки',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _creating || _deleting || folder == null
                    ? null
                    : _createChild,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Создать подпапку'),
              ),
              if (widget.controller.folderError != null)
                Text(widget.controller.folderError!),
              if (folder == null && !widget.controller.loadingFolders)
                const Text(
                  'Папка больше недоступна. Вернитесь к списку папок.',
                ),
              if (folder != null && folder.children.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('Вложенных папок пока нет.'),
                ),
              for (final child in folder?.children ?? <Folder>[])
                _FolderNode(
                  key: ValueKey(child.id),
                  folder: child,
                  controller: widget.controller,
                ),
              const SizedBox(height: 24),
              Text('Встречи', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              if (_loading) const LinearProgressIndicator(),
              if (_error != null) ...[
                Text(_error!),
                TextButton(
                  onPressed: _loading ? null : () => _load(reset: true),
                  child: const Text('Повторить'),
                ),
              ],
              if (_items.isEmpty && !_loading && _error == null)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('В этой папке пока нет встреч.'),
                ),
              for (final item in _items)
                Card(
                  child: ListTile(
                    title: Text(item.title),
                    subtitle: Text(_date(item.createdAt)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(item),
                  ),
                ),
              if (_items.length < _total)
                TextButton(
                  onPressed: _loading ? null : _load,
                  child: const Text('Загрузить ещё'),
                ),
            ],
          ),
        ),
      );
    },
  );
  String _date(DateTime value) {
    final date = value.toLocal();
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
  }
}

Future<bool> deleteFolderWithConfirmation(
  BuildContext context,
  MeetingController controller,
  Folder folder,
) async {
  final skip =
      AppearanceScope.maybeOf(context)?.skipFolderDeleteConfirmation ?? false;
  final confirmed =
      skip ||
      await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Удалить папку?'),
              content: const Text(
                'Папка и все summary, которые хранятся в ней, будут удалены. Вы уверены в удалении?',
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
          ) ==
          true;
  if (!confirmed) return false;
  try {
    await controller.deleteFolder(folder);
    return true;
  } catch (e) {
    final message = e is ApiException && e.code == 'folder_processing'
        ? 'В этой папке или вложенных папках ещё обрабатывается встреча. Дождитесь завершения обработки и повторите удаление.'
        : e.toString();
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
    return false;
  }
}

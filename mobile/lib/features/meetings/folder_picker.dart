import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/api_models.dart';
import '../new_meeting/meeting_controller.dart';

Future<String?> folderNameDialog(BuildContext context, {String? initial}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _FolderNameDialog(initial: initial),
    );

class _FolderNameDialog extends StatefulWidget {
  const _FolderNameDialog({this.initial});
  final String? initial;
  @override
  State<_FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<_FolderNameDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.initial == null ? 'Создать папку' : 'Переименовать папку',
    ),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _name,
        autofocus: true,
        maxLength: 200,
        decoration: const InputDecoration(labelText: 'Название папки'),
        validator: (value) =>
            value == null || value.trim().isEmpty ? 'Введите название' : null,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(context, _name.text.trim());
          }
        },
        child: const Text('Сохранить'),
      ),
    ],
  );
}

/// All creation entry points use the same explicit parent selection.
Future<Folder?> createFolderDialog(
  BuildContext context,
  MeetingController controller, {
  String? parentId,
}) => showDialog<Folder>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      _CreateFolderDialog(controller: controller, parentId: parentId),
);

class _CreateFolderDialog extends StatefulWidget {
  const _CreateFolderDialog({required this.controller, this.parentId});
  final MeetingController controller;
  final String? parentId;
  @override
  State<_CreateFolderDialog> createState() => _CreateFolderDialogState();
}

class _CreateFolderDialogState extends State<_CreateFolderDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  late String? _parent = widget.parentId;
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final folder = await widget.controller.createFolder(
        _name.text.trim(),
        parentId: _parent,
      );
      if (mounted) Navigator.pop(context, folder);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      scrollable: true,
      title: const Text('Создать папку'),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _name,
              enabled: !_saving,
              autofocus: true,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'Название папки'),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Введите название' : null,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _parent ?? '',
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Расположение'),
              items: [
                const DropdownMenuItem(
                  value: '',
                  child: Text('Верхний уровень'),
                ),
                for (final entry in flattenFolders(widget.controller.folders))
                  DropdownMenuItem(
                    value: entry.folder.id,
                    child: Text(
                      entry.path,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (v) => setState(() => _parent = v == '' ? null : v),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Создаём…' : 'Создать'),
        ),
      ],
    ),
  );
}

Future<List<String>?> chooseFolders(
  BuildContext context,
  MeetingController controller,
  List<String> initial,
) {
  // Audio review and the meeting list have different controller instances.
  // Always refresh the API tree when opening a selection, preserving UUIDs.
  unawaited(controller.loadFolders());
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _FolderPicker(controller: controller, initial: initial),
  );
}

class _FolderPicker extends StatefulWidget {
  const _FolderPicker({required this.controller, required this.initial});
  final MeetingController controller;
  final List<String> initial;
  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  late final Set<String> _selected = widget.initial.toSet();
  bool _creating = false;
  Future<void> _create({String? parentId}) async {
    if (_creating) return;
    setState(() => _creating = true);
    final folder = await createFolderDialog(
      context,
      widget.controller,
      parentId: parentId,
    );
    if (!mounted) return;
    setState(() {
      _creating = false;
      if (folder != null) _selected.add(folder.id);
    });
  }

  void _toggle(String id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  @override
  Widget build(BuildContext context) => SafeArea(
    child: FractionallySizedBox(
      heightFactor: .8,
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final controller = widget.controller;
          final entries = flattenFolders(controller.folders);
          final knownIds = entries.map((entry) => entry.folder.id).toSet();
          final selectionValid =
              _selected.isNotEmpty &&
              _selected.length <= 100 &&
              knownIds.containsAll(_selected);
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Папки встречи',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      onPressed: controller.loadingFolders
                          ? null
                          : controller.loadFolders,
                      tooltip: 'Обновить',
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
              ),
              if (controller.loadingFolders) const LinearProgressIndicator(),
              if (controller.folderError != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(controller.folderError!),
                ),
              Expanded(
                child: entries.isEmpty
                    ? const Center(
                        child: Text('Создайте первую папку для встречи.'),
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) => ListView(
                          children: [
                            for (final entry in entries)
                              ListTile(
                                key: ValueKey(
                                  'select-folder-${entry.folder.id}',
                                ),
                                contentPadding: EdgeInsetsDirectional.only(
                                  start:
                                      16 +
                                      (entry.depth * 20.0).clamp(
                                        0.0,
                                        (constraints.maxWidth * .25).clamp(
                                          0.0,
                                          96.0,
                                        ),
                                      ),
                                  end: 16,
                                ),
                                leading: Checkbox(
                                  value: _selected.contains(entry.folder.id),
                                  onChanged: (_) => _toggle(entry.folder.id),
                                ),
                                title: Tooltip(
                                  message: entry.path,
                                  excludeFromSemantics: true,
                                  child: Text(
                                    entry.folder.name,
                                    semanticsLabel: entry.path,
                                  ),
                                ),
                                onTap: () => _toggle(entry.folder.id),
                                trailing: IconButton(
                                  tooltip: 'Создать подпапку в «${entry.path}»',
                                  onPressed:
                                      _creating || controller.loadingFolders
                                      ? null
                                      : () =>
                                            _create(parentId: entry.folder.id),
                                  icon: const Icon(
                                    Icons.create_new_folder_outlined,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: _creating || controller.loadingFolders
                          ? null
                          : () => _create(),
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: const Text('Новая папка'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: selectionValid
                          ? () => Navigator.pop(context, _selected.toList())
                          : null,
                      child: const Text('Выбрать'),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

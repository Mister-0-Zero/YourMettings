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

Future<List<String>?> chooseFolders(
  BuildContext context,
  MeetingController controller,
  List<String> initial,
) => showModalBottomSheet<List<String>>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _FolderPicker(controller: controller, initial: initial),
);

class _FolderPicker extends StatefulWidget {
  const _FolderPicker({required this.controller, required this.initial});
  final MeetingController controller;
  final List<String> initial;
  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  late final Set<String> _selected = widget.initial.toSet();
  String? _error;
  bool _creating = false;
  Future<void> _create() async {
    final name = await folderNameDialog(context);
    if (name == null || !mounted) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      await widget.controller.createFolder(name);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

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
              if (controller.folderError != null || _error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error ?? controller.folderError!),
                ),
              Expanded(
                child: entries.isEmpty
                    ? const Center(
                        child: Text('Создайте первую папку для встречи.'),
                      )
                    : ListView(
                        children: [
                          for (final entry in entries)
                            CheckboxListTile(
                              title: Text(entry.path),
                              value: _selected.contains(entry.folder.id),
                              onChanged: (checked) => setState(() {
                                if (checked == true) {
                                  _selected.add(entry.folder.id);
                                } else {
                                  _selected.remove(entry.folder.id);
                                }
                              }),
                            ),
                        ],
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: _creating ? null : _create,
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

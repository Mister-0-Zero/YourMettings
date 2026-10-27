import 'package:flutter/material.dart';

import '../meetings/visual_document.dart';
import '../meetings/visual_editor.dart';

/// Edits one variant locally. The meeting is accepted only on the preview check.
class SelectionEditor extends StatefulWidget {
  const SelectionEditor({
    super.key,
    required this.title,
    required this.content,
    required this.onApply,
  });
  final String title, content;
  final Future<void> Function(String title, String content) onApply;
  @override
  State<SelectionEditor> createState() => _SelectionEditorState();
}

class _SelectionEditorState extends State<SelectionEditor> {
  late final _title = TextEditingController(text: widget.title);
  late final _visual = VisualDocument(
    widget.content,
    onChanged: (_, error) {
      if (mounted) {
        setState(() {
          _dirty = true;
          _error = error;
        });
      }
    },
  );
  bool _dirty = false, _busy = false, _allowExit = false;
  String? _error;
  Future<void> _apply() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      FocusManager.instance.primaryFocus?.unfocus();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      await widget.onApply(_title.text, _visual.export());
      if (!mounted) return;
      setState(() => _allowExit = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is FormatException ? e.message : e.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_busy) return;
    if (_dirty) {
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Применить правки к варианту?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Продолжить редактирование'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'discard'),
              child: const Text('Отменить правки'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'apply'),
              child: const Text('Применить'),
            ),
          ],
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == 'apply') {
        await _apply();
        return;
      }
    }
    if (!mounted) return;
    setState(() => _allowExit = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _title.dispose();
    _visual.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowExit,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _leave();
    },
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Редактирование'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _apply,
            child: const Text('Применить'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Правки относятся к этому варианту. Сохраните встречу галочкой на экране просмотра.',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _title,
                    enabled: !_busy,
                    maxLength: 200,
                    decoration: const InputDecoration(
                      labelText: 'Название встречи',
                    ),
                    onChanged: (_) => setState(() => _dirty = true),
                  ),
                  const SizedBox(height: 16),
                  VisualEditorBody(document: _visual, enabled: !_busy),
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: VisualEditorToolbar(document: _visual, enabled: !_busy),
          ),
        ],
      ),
    ),
  );
}

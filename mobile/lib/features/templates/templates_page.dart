import 'template_preview_session.dart';

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../models/summary_template.dart';
import 'template_preview_page.dart';

class TemplatesPage extends StatefulWidget {
  const TemplatesPage({super.key, required this.api});
  final ApiClient api;
  @override
  State<TemplatesPage> createState() => _TemplatesPageState();
}

class _TemplatesPageState extends State<TemplatesPage> {
  late Future<List<SummaryTemplate>> _items = widget.api.templates();
  void _reload() => setState(() => _items = widget.api.templates());
  Future<void> _open(SummaryTemplate item) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TemplateDetailsPage(api: widget.api, template: item),
      ),
    );
    if (mounted) _reload();
  }

  Future<void> _create() async {
    await Navigator.of(context).push<SummaryTemplate>(
      MaterialPageRoute(builder: (_) => TemplateEditorPage(api: widget.api)),
    );
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Шаблоны'),
      actions: [
        IconButton(
          onPressed: _create,
          icon: const Icon(Icons.add),
          tooltip: 'Создать шаблон',
        ),
      ],
    ),
    body: FutureBuilder<List<SummaryTemplate>>(
      future: _items,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(snapshot.error.toString()),
                  TextButton(
                    onPressed: _reload,
                    child: const Text('Повторить'),
                  ),
                ],
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return RefreshIndicator(
          onRefresh: () async {
            _reload();
            await _items;
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final system in [true, false]) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    system ? 'Готовые шаблоны' : 'Мои шаблоны',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (!snapshot.data!.any((t) => t.isSystem == system))
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Создайте свой шаблон или скопируйте готовый.'),
                  ),
                for (final item in snapshot.data!.where(
                  (t) => t.isSystem == system,
                ))
                  Card(
                    child: ListTile(
                      title: Text(item.input.name),
                      subtitle: Text(item.input.description),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _open(item),
                    ),
                  ),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add),
                label: const Text('Создать шаблон'),
              ),
            ],
          ),
        );
      },
    ),
  );
}

class TemplateDetailsPage extends StatefulWidget {
  const TemplateDetailsPage({
    super.key,
    required this.api,
    required this.template,
  });
  final ApiClient api;
  final SummaryTemplate template;
  @override
  State<TemplateDetailsPage> createState() => _TemplateDetailsPageState();
}

class _TemplateDetailsPageState extends State<TemplateDetailsPage> {
  late SummaryTemplate _item = widget.template;
  bool _busy = false;
  String? _error;
  Future<void> _edit({bool copy = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final item = copy
          ? await widget.api.copyTemplate(_item.id)
          : await widget.api.template(_item.id);
      if (!mounted) return;
      final saved = await Navigator.of(context).push<SummaryTemplate>(
        MaterialPageRoute(
          builder: (_) => TemplateEditorPage(api: widget.api, template: item),
        ),
      );
      if (!mounted) return;
      if (copy) {
        Navigator.of(context).pop();
      } else if (saved != null) {
        setState(() => _item = saved);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить шаблон?'),
        content: const Text('Созданные встречи сохранятся.'),
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
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.deleteTemplate(_item.id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_item.input.name)),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Text(_item.input.description),
        const SizedBox(height: 16),
        Text(
          _item.input.structureMode == 'strict'
              ? 'Строгая структура'
              : 'Гибкая структура',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (_item.input.generalInstructions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(_item.input.generalInstructions),
          ),
        for (final s in _item.input.sections) _SectionDescription(section: s),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _busy ? null : () => _edit(copy: true),
          icon: const Icon(Icons.copy_outlined),
          label: const Text('Копировать и настроить'),
        ),
        if (!_item.isSystem) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _edit(),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Редактировать'),
          ),
          TextButton.icon(
            onPressed: _busy ? null : _delete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Удалить шаблон'),
          ),
        ],
      ],
    ),
  );
}

class _SectionDescription extends StatelessWidget {
  const _SectionDescription({required this.section});
  final TemplateSection section;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(section.title, style: Theme.of(context).textTheme.titleMedium),
          Text(
            section.repeated
                ? 'Для каждой темы'
                : section.required
                ? 'Обязательный раздел'
                : 'Необязательный раздел',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Text(section.instruction),
          for (final child in section.children)
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 8),
              child: _SectionDescription(section: child),
            ),
        ],
      ),
    ),
  );
}

class TemplateEditorPage extends StatefulWidget {
  const TemplateEditorPage({super.key, required this.api, this.template});
  final ApiClient api;
  final SummaryTemplate? template;
  @override
  State<TemplateEditorPage> createState() => _TemplateEditorPageState();
}

class _TemplateEditorPageState extends State<TemplateEditorPage> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(
    text: widget.template?.input.name ?? '',
  );
  late final _description = TextEditingController(
    text: widget.template?.input.description ?? '',
  );
  late final _instructions = TextEditingController(
    text: widget.template?.input.generalInstructions ?? '',
  );
  late String _mode = widget.template?.input.structureMode ?? 'strict';
  late final List<TemplateSection> _sections = [
    ...?widget.template?.input.sections,
  ];
  late final String _original = jsonEncode(_input.toJson());
  bool _busy = false, _canPop = false;
  TemplatePreviewSession? _previewSession;
  String? _error;
  TemplateInput get _input => TemplateInput(
    name: _name.text,
    description: _description.text,
    generalInstructions: _instructions.text,
    structureMode: _mode,
    sections: List.unmodifiable(_sections),
  );
  bool get _dirty => jsonEncode(_input.toJson()) != _original;
  @override
  void initState() {
    super.initState();
    _original;
  }

  @override
  void dispose() {
    _previewSession?.dispose();
    _name.dispose();
    _description.dispose();
    _instructions.dispose();
    super.dispose();
  }

  Future<bool> _save() async {
    if (_busy || !_form.currentState!.validate()) return false;
    final input = _input;
    final error = input.validate();
    if (error != null) {
      setState(() => _error = error);
      return false;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await widget.api.saveTemplate(
        input,
        id: widget.template?.id,
      );
      if (!mounted) return false;
      setState(() => _canPop = true);
      Navigator.pop(context, saved);
      return true;
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_busy) return;
    if (!_dirty) {
      setState(() => _canPop = true);
      Navigator.pop(context);
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Сохранить изменения?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'continue'),
            child: const Text('Продолжить редактирование'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('Не сохранять'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'save') {
      await _save();
    } else if (choice == 'discard') {
      setState(() => _canPop = true);
      Navigator.pop(context);
    }
  }

  Future<void> _section({int? index, bool repeated = false}) async {
    final result = await Navigator.of(context).push<TemplateSection>(
      MaterialPageRoute(
        builder: (_) => TemplateSectionPage(
          section: index == null ? null : _sections[index],
          repeated: repeated,
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (index == null) {
        _sections.add(result);
      } else {
        _sections[index] = result;
      }
    });
  }

  Future<void> _preview() async {
    if (!_form.currentState!.validate()) return;
    final error = _input.validate();
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TemplatePreviewPage(
          api: widget.api,
          input: _input,
          session: _previewSession ??= TemplatePreviewSession(widget.api),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope<SummaryTemplate>(
    canPop: _canPop,
    onPopInvokedWithResult: (popped, _) {
      if (!popped) _leave();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          widget.template == null ? 'Новый шаблон' : 'Редактирование шаблона',
        ),
        leading: BackButton(onPressed: _leave),
        actions: [
          IconButton(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.check),
            tooltip: 'Сохранить шаблон',
          ),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (_busy) const LinearProgressIndicator(),
            _field(_name, 'Название', 200),
            const SizedBox(height: 16),
            _field(_description, 'Описание', 2000, required: false, lines: 3),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _mode,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Режим структуры'),
              items: const [
                DropdownMenuItem(value: 'strict', child: Text('Строгий')),
                DropdownMenuItem(value: 'flexible', child: Text('Гибкий')),
              ],
              onChanged: _busy ? null : (v) => setState(() => _mode = v!),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _mode == 'strict'
                    ? 'Только заданные разделы в выбранном порядке.'
                    : 'Основные разделы сохраняются; после них можно добавить другие темы.',
              ),
            ),
            _field(
              _instructions,
              'Общие инструкции для Qwen',
              8000,
              required: false,
              lines: 4,
            ),
            const SizedBox(height: 20),
            Text('Разделы', style: Theme.of(context).textTheme.titleLarge),
            for (var i = 0; i < _sections.length; i++)
              _SectionRow(
                section: _sections[i],
                index: i,
                count: _sections.length,
                enabled: !_busy,
                onEdit: () => _section(index: i),
                onMove: (delta) => setState(() {
                  final item = _sections.removeAt(i);
                  _sections.insert(i + delta, item);
                }),
                onDelete: () => setState(() => _sections.removeAt(i)),
              ),
            if (_sections.length < 20)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _section(),
                    icon: const Icon(Icons.add),
                    label: const Text('Добавить раздел'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _section(repeated: true),
                    icon: const Icon(Icons.repeat),
                    label: const Text('Блок по темам'),
                  ),
                ],
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _busy ? null : _preview,
              icon: const Icon(Icons.play_arrow_outlined),
              label: const Text('Протестировать'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Сохранить шаблон'),
            ),
            TextButton(
              onPressed: _busy ? null : _leave,
              child: const Text('Отмена'),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _field(
    TextEditingController c,
    String label,
    int limit, {
    bool required = true,
    int lines = 1,
  }) => TextFormField(
    controller: c,
    enabled: !_busy,
    decoration: InputDecoration(labelText: label, alignLabelWithHint: true),
    maxLength: limit,
    minLines: lines,
    maxLines: lines == 1 ? 1 : 6,
    validator: (v) => required && (v ?? '').trim().isEmpty
        ? 'Заполните поле'
        : (v ?? '').runes.length > limit
        ? 'Максимум $limit символов'
        : null,
  );
}

class _SectionRow extends StatelessWidget {
  const _SectionRow({
    required this.section,
    required this.index,
    required this.count,
    required this.enabled,
    required this.onEdit,
    required this.onMove,
    required this.onDelete,
  });
  final TemplateSection section;
  final int index, count;
  final bool enabled;
  final VoidCallback onEdit, onDelete;
  final void Function(int) onMove;
  @override
  Widget build(BuildContext context) => Card(
    key: ValueKey('section-${section.id}'),
    child: Column(
      children: [
        ListTile(
          onTap: enabled ? onEdit : null,
          title: Text(section.title),
          subtitle: Text(
            section.repeated
                ? 'Для каждой темы · подразделов: ${section.children.length}'
                : section.required
                ? 'Обязательный'
                : 'Необязательный',
          ),
          trailing: const Icon(Icons.edit_outlined),
        ),
        Wrap(
          alignment: WrapAlignment.end,
          children: [
            IconButton(
              onPressed: enabled && index > 0 ? () => onMove(-1) : null,
              icon: const Icon(Icons.arrow_upward),
              tooltip: 'Переместить выше',
            ),
            IconButton(
              onPressed: enabled && index < count - 1 ? () => onMove(1) : null,
              icon: const Icon(Icons.arrow_downward),
              tooltip: 'Переместить ниже',
            ),
            IconButton(
              onPressed: enabled ? onDelete : null,
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Удалить раздел',
            ),
          ],
        ),
      ],
    ),
  );
}

class TemplateSectionPage extends StatefulWidget {
  const TemplateSectionPage({super.key, this.section, this.repeated = false});
  final TemplateSection? section;
  final bool repeated;
  @override
  State<TemplateSectionPage> createState() => _TemplateSectionPageState();
}

class _TemplateSectionPageState extends State<TemplateSectionPage> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.section?.title ?? '');
  late final _instruction = TextEditingController(
    text: widget.section?.instruction ?? '',
  );
  late bool _required = widget.section?.required ?? true;
  late final bool _repeated = widget.section?.repeated ?? widget.repeated;
  late final String _id = widget.section?.id ?? newSectionId();
  late final List<TemplateSection> _children = [...?widget.section?.children];
  late final String _original = jsonEncode(_value.toJson(0));
  bool _canPop = false;
  String? _error;
  TemplateSection get _value => TemplateSection(
    id: _id,
    title: _title.text,
    instruction: _instruction.text,
    required: _required,
    repeated: _repeated,
    children: List.unmodifiable(_children),
  );
  @override
  void initState() {
    super.initState();
    _original;
  }

  @override
  void dispose() {
    _title.dispose();
    _instruction.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    if (jsonEncode(_value.toJson(0)) != _original) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Отменить изменения раздела?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Продолжить'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Отменить изменения'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    setState(() => _canPop = true);
    Navigator.pop(context);
  }

  Future<void> _child([int? index]) async {
    final item = await Navigator.push<TemplateSection>(
      context,
      MaterialPageRoute(
        builder: (_) => TemplateSectionPage(
          section: index == null ? null : _children[index],
        ),
      ),
    );
    if (item == null || !mounted) return;
    setState(() {
      if (index == null) {
        _children.add(item);
      } else {
        _children[index] = item;
      }
    });
  }

  void _done() {
    if (!_form.currentState!.validate()) return;
    if (_repeated && _children.isEmpty) {
      setState(() => _error = 'Добавьте хотя бы один подраздел.');
      return;
    }
    setState(() => _canPop = true);
    Navigator.pop(context, _value);
  }

  @override
  Widget build(BuildContext context) => PopScope<TemplateSection>(
    canPop: _canPop,
    onPopInvokedWithResult: (popped, _) {
      if (!popped) _leave();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(_repeated ? 'Тематический блок' : 'Раздел'),
        leading: BackButton(onPressed: _leave),
        actions: [
          IconButton(
            onPressed: _done,
            icon: const Icon(Icons.check),
            tooltip: 'Готово',
          ),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextFormField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'Название раздела'),
              maxLength: 200,
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Укажите название' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _instruction,
              decoration: InputDecoration(
                labelText: _repeated
                    ? 'Как выделять темы'
                    : 'Что включить в раздел',
                alignLabelWithHint: true,
              ),
              minLines: 4,
              maxLines: 8,
              maxLength: 4000,
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Добавьте инструкцию' : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Обязательный раздел'),
              value: _required,
              onChanged: (v) => setState(() => _required = v),
            ),
            if (_repeated) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Подразделы повторяются для каждой найденной темы.',
                ),
              ),
              for (var i = 0; i < _children.length; i++)
                _SectionRow(
                  section: _children[i],
                  index: i,
                  count: _children.length,
                  enabled: true,
                  onEdit: () => _child(i),
                  onMove: (d) => setState(() {
                    final item = _children.removeAt(i);
                    _children.insert(i + d, item);
                  }),
                  onDelete: () => setState(() => _children.removeAt(i)),
                ),
              if (_children.length < 12)
                OutlinedButton.icon(
                  onPressed: () => _child(),
                  icon: const Icon(Icons.add),
                  label: const Text('Добавить подраздел'),
                ),
            ],
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 20),
            FilledButton(onPressed: _done, child: const Text('Готово')),
          ],
        ),
      ),
    ),
  );
}

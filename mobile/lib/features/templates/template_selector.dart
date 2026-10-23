import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../models/summary_template.dart';

class TemplateSelector extends StatefulWidget {
  const TemplateSelector({
    super.key,
    required this.api,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });
  final ApiClient api;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool enabled;
  @override
  State<TemplateSelector> createState() => _TemplateSelectorState();
}

class _TemplateSelectorState extends State<TemplateSelector> {
  String? _name, _error;
  bool _busy = false;
  bool _loading = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(TemplateSelector old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      _name = null;
      _error = null;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final value = widget.value;
    final generation = ++_generation;
    if (value == null) return;
    try {
      final item = await widget.api.template(value);
      if (mounted && generation == _generation) {
        setState(() => _name = item.input.name);
      }
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = e is ApiException && e.statusCode == 404
              ? 'Выбранный шаблон недоступен. Выберите другой.'
              : 'Не удалось загрузить название шаблона.',
        );
      }
    }
  }

  Future<void> _choose() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _loading = true;
    });
    try {
      final items = await widget.api.templates();
      if (!mounted) return;
      setState(() => _loading = false);
      final selected = await showDialog<SummaryTemplate>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Шаблон обработки'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final system in [true, false]) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      system ? 'Готовые шаблоны' : 'Мои шаблоны',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  for (final item in items.where((t) => t.isSystem == system))
                    ListTile(
                      title: Text(item.input.name),
                      subtitle: Text(item.input.description),
                      trailing:
                          (item.id == widget.value ||
                              (widget.value == null && item.isDefault))
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => Navigator.pop(context, item),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
          ],
        ),
      );
      if (selected != null && mounted) {
        setState(() {
          _name = selected.input.name;
          _error = null;
        });
        widget.onChanged(selected.isDefault ? null : selected.id);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      OutlinedButton(
        onPressed: widget.enabled && !_busy ? _choose : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.article_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Шаблон обработки',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    Text(
                      widget.value == null
                          ? 'Универсальное совещание'
                          : _name ?? 'Выбранный шаблон',
                    ),
                  ],
                ),
              ),
              if (_loading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                const Icon(Icons.expand_more),
            ],
          ),
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
    ],
  );
}

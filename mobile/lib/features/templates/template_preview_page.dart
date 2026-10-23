import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../models/summary_template.dart';
import '../../models/processing_options.dart';
import '../meetings/summary_document.dart';

class TemplatePreviewPage extends StatefulWidget {
  const TemplatePreviewPage({
    super.key,
    required this.api,
    required this.input,
  });
  final ApiClient api;
  final TemplateInput input;
  @override
  State<TemplatePreviewPage> createState() => _TemplatePreviewPageState();
}

class _TemplatePreviewPageState extends State<TemplatePreviewPage>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
  String _detail = 'normal';
  TemplatePreview? _preview;
  String? _error;
  bool _sending = false, _checking = false, _paused = false;
  Timer? _timer;
  int _failures = 0;
  bool get _active => _preview != null && !_preview!.finished;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _text.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _paused = state != AppLifecycleState.resumed;
    if (_paused) {
      _timer?.cancel();
    } else if (_active) {
      _poll();
    }
  }

  Future<void> _start() async {
    if (_sending || _active) return;
    final text = _text.text.trim();
    if (text.isEmpty || text.runes.length > 12000) {
      setState(() => _error = 'Добавьте текст: от 1 до 12 000 символов.');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _sending = true;
      _error = null;
      _preview = null;
      _failures = 0;
    });
    try {
      final result = await widget.api.startTemplatePreview(
        widget.input,
        text,
        _detail,
      );
      if (!mounted) return;
      setState(() => _preview = result);
      _schedule();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException && e.code == 'preview_busy'
              ? 'Сейчас выполняются другие тесты. Попробуйте немного позже.'
              : e.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (mounted && !_paused && _active) {
      _timer = Timer(Duration(seconds: _failures == 0 ? 2 : 5), _poll);
    }
  }

  Future<void> _poll() async {
    if (_checking || !_active || !mounted) return;
    _checking = true;
    try {
      final result = await widget.api.templatePreview(_preview!.id);
      if (!mounted) return;
      setState(() {
        _preview = result;
        _error = null;
        _failures = 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failures++;
        if (e is ApiException && e.statusCode == 404) {
          _preview = null;
          _error = 'Тест больше недоступен. Ваш текст сохранён на этом экране; запустите тест ещё раз.';
        } else {
          _error =
              'Не удалось получить результат. Проверим соединение ещё раз.';
        }
      });
    } finally {
      _checking = false;
      _schedule();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Тест шаблона')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(widget.input.name, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        TextField(
          controller: _text,
          readOnly: _sending || _active,
          minLines: 6,
          maxLines: 12,
          maxLength: 12000,
          decoration: const InputDecoration(
            labelText: 'Небольшой транскрипт',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: _detail,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Детализация'),
          items: [
            for (final e in ProcessingOptions.detailLevels.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: _sending || _active
              ? null
              : (v) => setState(() => _detail = v!),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _sending || _active ? null : _start,
          icon: const Icon(Icons.play_arrow_outlined),
          label: Text(
            _preview?.finished == true
                ? 'Протестировать ещё раз'
                : 'Протестировать',
          ),
        ),
        if (_sending || _active)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Column(
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Qwen готовит пример документа…'),
              ],
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_preview?.status == 'error')
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              _preview!.error ??
                  'Не удалось подготовить пример. Попробуйте ещё раз.',
            ),
          ),
        if (_preview?.status == 'ready') ...[
          const SizedBox(height: 24),
          SummaryDocument(
            content: _preview!.content ?? '',
            navigation: _preview!.navigation,
          ),
        ],
      ],
    ),
  );
}

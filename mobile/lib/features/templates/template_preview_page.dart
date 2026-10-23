import '../../models/meeting_example.dart';
import 'template_scaffold.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/api_client.dart';
import '../../models/summary_template.dart';
import '../../models/processing_options.dart';
import '../meetings/summary_document.dart';
import 'template_preview_session.dart';

class TemplatePreviewPage extends StatefulWidget {
  const TemplatePreviewPage({
    super.key,
    required this.api,
    required this.input,
    this.session,
  });
  final ApiClient api;
  final TemplateInput input;
  final TemplatePreviewSession? session;
  @override
  State<TemplatePreviewPage> createState() => _TemplatePreviewPageState();
}

class _TemplatePreviewPageState extends State<TemplatePreviewPage> {
  late final _session = widget.session ?? TemplatePreviewSession(widget.api);
  late Future<List<MeetingExample>> _examples = MeetingExample.catalog();
  bool _loadingExample = false;
  String? _sourceError;
  Future<void> _chooseExample(String? id, List<MeetingExample> examples) async {
    if (_session.locked || _loadingExample) return;
    if (id == null) {
      _session.chooseExample();
      return;
    }
    setState(() {
      _loadingExample = true;
      _sourceError = null;
    });
    try {
      final example = examples.firstWhere((e) => e.id == id);
      final text = await example.loadText();
      if (mounted) {
        _session.chooseExample(id: id, title: example.title, content: text);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _sourceError =
              'Не удалось открыть полный пример. Повторите выбор.',
        );
      }
    } finally {
      if (mounted) setState(() => _loadingExample = false);
    }
  }

  void _readSource() {
    final paragraphs = _session.source.split('\n\n');
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TemplateScaffold(
          appBar: AppBar(title: Text(_session.exampleTitle ?? 'Транскрипт')),
          body: ListView.builder(
            padding: const EdgeInsets.all(20),
            itemCount: paragraphs.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: SelectableText(paragraphs[i]),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    if (widget.session == null) _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _session,
    builder: (context, _) => TemplateScaffold(
      appBar: AppBar(title: const Text('Тест шаблона')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            widget.input.name,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          FutureBuilder<List<MeetingExample>>(
            future: _examples,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return TextButton(
                  onPressed: () => setState(() {
                    _examples = MeetingExample.catalog();
                  }),
                  child: const Text('Повторить загрузку примеров'),
                );
              }
              if (!snapshot.hasData) return const LinearProgressIndicator();
              return DropdownButtonFormField<String>(
                initialValue: _session.exampleId ?? 'custom',
                itemHeight: null,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Источник транскрипта',
                ),
                items: [
                  const DropdownMenuItem(
                    value: 'custom',
                    child: Text('Вставить свой текст'),
                  ),
                  for (final example in snapshot.data!)
                    DropdownMenuItem(
                      value: example.id,
                      child: Text(
                        example.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _session.locked || _loadingExample
                    ? null
                    : (id) => _chooseExample(
                        id == 'custom' ? null : id,
                        snapshot.data!,
                      ),
              );
            },
          ),
          if (_loadingExample) const LinearProgressIndicator(),
          if (_sourceError != null) Text(_sourceError!),
          const SizedBox(height: 16),
          if (_session.exampleId == null)
            TextField(
              controller: _session.text,
              readOnly: _session.locked,
              minLines: 6,
              maxLines: 12,
              maxLength: 200000,
              maxLengthEnforcement: MaxLengthEnforcement.none,
              decoration: const InputDecoration(
                labelText: 'Ваш транскрипт',
                helperText: 'До 15 000 слов, 200 000 символов и 400 000 байт.',
                helperMaxLines: 2,
                alignLabelWithHint: true,
              ),
            )
          else
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_session.exampleTitle ?? 'Учебная встреча'),
                    const SizedBox(height: 8),
                    const Text(
                      'Вымышленная встреча. Тест использует весь текст и не создаёт запись в истории.',
                    ),
                    TextButton.icon(
                      onPressed: _readSource,
                      icon: const Icon(Icons.description_outlined),
                      label: const Text('Посмотреть транскрипт'),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _session.detail,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Детализация'),
            items: [
              for (final e in ProcessingOptions.detailLevels.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: _session.locked || _loadingExample
                ? null
                : (v) => _session.changeDetail(v!),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _session.sending || _session.active || _loadingExample
                ? null
                : () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    _session.start(widget.input);
                  },
            icon: const Icon(Icons.play_arrow_outlined),
            label: Text(
              _session.uncertain && !_session.sending
                  ? 'Повторить запрос'
                  : _session.preview?.finished == true
                  ? 'Протестировать ещё раз'
                  : 'Протестировать',
            ),
          ),
          if (_session.sending || _session.active)
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
          if (_session.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                _session.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_session.preview?.status == 'error')
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                _session.preview!.error ??
                    'Не удалось подготовить пример. Попробуйте ещё раз.',
              ),
            ),
          if (_session.preview?.status == 'ready') ...[
            const SizedBox(height: 24),
            if (!_session.uses(widget.input))
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  'Результат предыдущего теста',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            SummaryDocument(
              content: _session.preview!.content ?? '',
              navigation: _session.preview!.navigation,
            ),
          ],
        ],
      ),
    ),
  );
}

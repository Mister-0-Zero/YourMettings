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
          TextField(
            controller: _session.text,
            readOnly: _session.sending || _session.active,
            minLines: 6,
            maxLines: 12,
            maxLength: 12000,
            maxLengthEnforcement: MaxLengthEnforcement.none,
            decoration: const InputDecoration(
              labelText: 'Ваш транскрипт',
              alignLabelWithHint: true,
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
            onChanged: _session.sending || _session.active
                ? null
                : (v) => _session.changeDetail(v!),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _session.sending || _session.active
                ? null
                : () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    _session.start(widget.input);
                  },
            icon: const Icon(Icons.play_arrow_outlined),
            label: Text(
              _session.preview?.finished == true
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

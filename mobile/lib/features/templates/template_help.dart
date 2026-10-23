import 'package:flutter/material.dart';

const structureHelp =
    'Строгая структура: итог содержит только заданные вами разделы в указанном порядке. Например, «Решения» и «Задачи».\n\nГибкая структура: эти разделы сохраняются, а после них могут появиться дополнительные важные темы встречи.';
const topicHelp =
    'Один и тот же набор подразделов будет создан отдельно для каждой обсуждённой темы.\n\nНапример, встреча о сайте и рекламе: у темы «Сайт» будут свои решения и задачи, а у темы «Реклама» — свои. Добавьте нужные подразделы: «Решения», «Задачи», «Ответственные», «Сроки».';
const requiredHelp =
    'Обязательный раздел будет в итоге даже при отсутствии сведений: тогда в нём появится «Не указано».\n\nНеобязательный раздел можно пропустить, если на встрече его не обсуждали.';
const instructionsHelp =
    'Напишите, что особенно важно сохранить в итоге. Например: «Подробно опиши причины решений» или «Сохраняй названия наших проектов».\n\nСтруктуру документа задают разделы ниже.';

class TemplateHelp extends StatelessWidget {
  const TemplateHelp({super.key, required this.title, required this.message});
  final String title, message;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: message,
    icon: const Icon(Icons.help_outline),
    onPressed: () => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Понятно'),
          ),
        ],
      ),
    ),
  );
}

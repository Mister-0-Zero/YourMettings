import 'package:flutter/material.dart';

import '../../models/api_models.dart';

/// Progress counts only ACKs persisted by AudioEngine, never health or ASR.
class AudioTransferStatus extends StatelessWidget {
  const AudioTransferStatus({super.key, required this.snapshot});
  final Json snapshot;

  @override
  Widget build(BuildContext context) {
    final chunks = (snapshot['chunks'] as List? ?? []).cast<Json>();
    final total = chunks.length;
    final acked = chunks.where((chunk) => chunk['acked'] == true).length;
    final stage = snapshot['sync_stage'];
    final active = stage != null;
    final error = snapshot['upload_error'] as String?;
    final waiting = error != null && !active;
    final sending = snapshot['phase'] == 'sending';
    final transcribing = snapshot['phase'] == 'transcribing';
    final title = waiting
        ? transcribing
              ? 'Ожидаем повторной проверки'
              : 'Ожидаем повторной отправки'
        : stage == 'completing'
        ? 'Завершаем отправку…'
        : transcribing
        ? 'Распознаём речь…'
        : stage == 'uploading'
        ? error != null
              ? 'Повторяем отправку…'
              : 'Отправляем запись…'
        : 'Подготавливаем отправку…';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sending || transcribing) ...[
          Center(
            child: waiting
                ? const Icon(Icons.cloud_off_outlined, size: 40)
                : const CircularProgressIndicator(),
          ),
          const SizedBox(height: 24),
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
        ] else if (active) ...[
          Text(title),
          const SizedBox(height: 12),
        ],
        if (total > 0) ...[
          Text('Отправлено фрагментов: $acked из $total'),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: acked / total),
          const SizedBox(height: 12),
        ],
        if (waiting) Text(error),
        if (transcribing && !waiting)
          const Text(
            'Все фрагменты приняты сервером. Ожидаем готовый транскрипт.',
          ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/api_models.dart';

/// Copy the confirmed source, never the editor conversion or rendered selection.
Future<void> copySummaryToClipboard(
  BuildContext context,
  MeetingSummary summary,
) async {
  var message = 'Итог встречи скопирован';
  try {
    await Clipboard.setData(
      ClipboardData(text: '${summary.title}\n\n${summary.content}'),
    );
  } catch (_) {
    message = 'Не удалось скопировать итог. Повторите попытку.';
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

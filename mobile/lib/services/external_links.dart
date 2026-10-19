import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> openExternalLink(BuildContext context, String? href) async {
  var opened = false;
  try {
    final uri = Uri.tryParse(href?.trim() ?? '');
    if (uri != null &&
        {'http', 'https', 'mailto', 'tel'}.contains(uri.scheme.toLowerCase())) {
      final web = uri.scheme == 'http' || uri.scheme == 'https';
      if ((web && uri.host.isNotEmpty) || (!web && uri.path.isNotEmpty)) {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
  } catch (_) {
    opened = false;
  }
  if (!opened && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Не удалось открыть ссылку.')),
    );
  }
}

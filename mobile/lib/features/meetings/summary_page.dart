import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../models/api_models.dart';
import '../new_meeting/meeting_controller.dart';

class SummaryPageView extends StatelessWidget {
  const SummaryPageView({
    super.key,
    required this.controller,
    required this.summary,
  });
  final MeetingController controller;
  final MeetingSummary summary;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(summary.title)),
    body: Markdown(
      data: summary.content,
      selectable: true,
      imageBuilder: (uri, title, alt) => Text(alt ?? 'Изображение'),
    ),
  );
}

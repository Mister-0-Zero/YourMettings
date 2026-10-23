import 'package:flutter/material.dart';

class TemplateScaffold extends StatelessWidget {
  const TemplateScaffold({super.key, required this.appBar, required this.body});
  final PreferredSizeWidget appBar;
  final Widget body;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: appBar,
    body: SafeArea(top: false, child: body),
  );
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

enum AccentColor { blue, green }

enum DocumentAccent {
  orange('Оранжевый', Color(0xFF964000), Color(0xFFFFB77D)),
  blue('Синий', Color(0xFF15549C), Color(0xFF9DC9FF)),
  green('Зелёный', Color(0xFF146337), Color(0xFF8DD9A4)),
  purple('Фиолетовый', Color(0xFF7134A5), Color(0xFFDAB3FF)),
  pink('Розовый', Color(0xFF9F2860), Color(0xFFFFACD0));

  const DocumentAccent(this.label, this.light, this.dark);
  final String label;
  final Color light;
  final Color dark;
  Color forBrightness(Brightness b) => b == Brightness.dark ? dark : light;
}

class AppearanceController extends ChangeNotifier {
  AppearanceController({this.file});
  final File? file;
  ThemeMode themeMode = ThemeMode.system;
  AccentColor accent = AccentColor.blue;
  bool skipFolderDeleteConfirmation = false;
  DocumentAccent documentAccent = DocumentAccent.orange;
  bool colorDocumentBold = true;
  String? error;
  Future<void> _queue = Future.value();
  bool _disposed = false;
  Future<void> load() async {
    if (file == null || !await file!.exists()) return;
    final json = jsonDecode(await file!.readAsString()) as Map<String, dynamic>;
    themeMode = ThemeMode.values.byName(json['theme_mode'] as String);
    accent = AccentColor.values.byName(json['accent'] as String);
    documentAccent = DocumentAccent.values.byName(
      json['document_accent'] as String? ?? 'orange',
    );
    colorDocumentBold = json['color_document_bold'] as bool? ?? true;
    skipFolderDeleteConfirmation =
        json['skip_folder_delete_confirmation'] as bool? ?? false;
  }

  Future<void> update({
    ThemeMode? mode,
    DocumentAccent? documentColor,
    bool? documentBold,
    AccentColor? color,
    bool? skipFolderConfirmation,
  }) async {
    themeMode = mode ?? themeMode;
    documentAccent = documentColor ?? documentAccent;
    colorDocumentBold = documentBold ?? colorDocumentBold;
    accent = color ?? accent;
    skipFolderDeleteConfirmation =
        skipFolderConfirmation ?? skipFolderDeleteConfirmation;
    error = null;
    notifyListeners();
    final content = jsonEncode({
      'theme_mode': themeMode.name,
      'accent': accent.name,
      'document_accent': documentAccent.name,
      'color_document_bold': colorDocumentBold,
      'skip_folder_delete_confirmation': skipFolderDeleteConfirmation,
    });
    final task = _queue.then((_) async {
      if (file == null) return;
      await file!.parent.create(recursive: true);
      final temporary = File('${file!.path}.tmp');
      await temporary.writeAsString(content, flush: true);
      await temporary.rename(file!.path);
    });
    _queue = task.catchError((Object _) {});
    try {
      await task;
    } catch (_) {
      error = 'Не удалось сохранить настройки. Повторите выбор.';
    }
    if (!_disposed) notifyListeners();
  }

  ThemeData theme(Brightness brightness) => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: accent == AccentColor.blue
          ? const Color(0xFF365E7D)
          : const Color(0xFF297558),
      brightness: brightness,
    ),
    appBarTheme: const AppBarTheme(centerTitle: true),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
  );
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key, required this.controller});
  final AppearanceController controller;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text('Оформление', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 20),
      DropdownButtonFormField<ThemeMode>(
        initialValue: controller.themeMode,
        decoration: const InputDecoration(labelText: 'Режим темы'),
        items: const [
          DropdownMenuItem(value: ThemeMode.system, child: Text('Системная')),
          DropdownMenuItem(value: ThemeMode.light, child: Text('Светлая')),
          DropdownMenuItem(value: ThemeMode.dark, child: Text('Тёмная')),
        ],
        onChanged: (mode) {
          if (mode != null) controller.update(mode: mode);
        },
      ),
      const SizedBox(height: 20),
      DropdownButtonFormField<AccentColor>(
        initialValue: controller.accent,
        decoration: const InputDecoration(labelText: 'Акцентный цвет'),
        items: const [
          DropdownMenuItem(value: AccentColor.blue, child: Text('Синий')),
          DropdownMenuItem(value: AccentColor.green, child: Text('Зелёный')),
        ],
        onChanged: (color) {
          if (color != null) controller.update(color: color);
        },
      ),
      const SizedBox(height: 20),
      DropdownButtonFormField<DocumentAccent>(
        initialValue: controller.documentAccent,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Цвет акцентов в документах',
        ),
        items: [
          for (final color in DocumentAccent.values)
            DropdownMenuItem(value: color, child: Text(color.label)),
        ],
        onChanged: (value) {
          if (value != null) controller.update(documentColor: value);
        },
      ),
      const SizedBox(height: 12),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Выделять жирный текст цветом'),
        value: controller.colorDocumentBold,
        onChanged: (value) => controller.update(documentBold: value),
      ),
      const SizedBox(height: 20),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Не спрашивать подтверждение при удалении папок'),
        value: controller.skipFolderDeleteConfirmation,
        onChanged: (value) => controller.update(skipFolderConfirmation: value),
      ),
      if (controller.error != null)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(
            controller.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      const SizedBox(height: 28),
      Text('Тестовый профиль', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      const Text('Первая версия использует тестового пользователя сервера.'),
    ],
  );
}

class AppearanceScope extends InheritedNotifier<AppearanceController> {
  const AppearanceScope({
    super.key,
    required AppearanceController controller,
    required super.child,
  }) : super(notifier: controller);
  static AppearanceController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

enum AccentColor { blue, green }

class AppearanceController extends ChangeNotifier {
  AppearanceController({this.file});
  final File? file;
  ThemeMode themeMode = ThemeMode.system;
  AccentColor accent = AccentColor.blue;
  bool skipFolderDeleteConfirmation = false;
  String? error;
  Future<void> _queue = Future.value();
  bool _disposed = false;
  Future<void> load() async {
    if (file == null || !await file!.exists()) return;
    final json = jsonDecode(await file!.readAsString()) as Map<String, dynamic>;
    themeMode = ThemeMode.values.byName(json['theme_mode'] as String);
    accent = AccentColor.values.byName(json['accent'] as String);
    skipFolderDeleteConfirmation =
        json['skip_folder_delete_confirmation'] as bool? ?? false;
  }

  Future<void> update({
    ThemeMode? mode,
    AccentColor? color,
    bool? skipFolderConfirmation,
  }) async {
    themeMode = mode ?? themeMode;
    accent = color ?? accent;
    skipFolderDeleteConfirmation =
        skipFolderConfirmation ?? skipFolderDeleteConfirmation;
    error = null;
    notifyListeners();
    final content = jsonEncode({
      'theme_mode': themeMode.name,
      'accent': accent.name,
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

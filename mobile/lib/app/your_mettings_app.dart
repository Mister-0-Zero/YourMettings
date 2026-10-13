import '../features/meetings/meetings_page.dart';
import '../features/new_meeting/meeting_controller.dart';
import '../features/new_meeting/transcript_page.dart';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

class YourMettingsApp extends StatelessWidget {
  const YourMettingsApp({super.key, this.controller});
  final MeetingController? controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'YourMettings',
    debugShowCheckedModeBanner: false,
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF365E7D)),
      scaffoldBackgroundColor: const Color(0xFFF7F9FC),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: MeetingShell(controller: controller),
  );
}

class MeetingShell extends StatefulWidget {
  const MeetingShell({super.key, this.controller});
  final MeetingController? controller;

  @override
  State<MeetingShell> createState() => _MeetingShellState();
}

class _MeetingShellState extends State<MeetingShell>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.controller?.resume();
    } else {
      widget.controller?.pause();
    }
  }

  int _selected = 0;
  static const _titles = ['Новая встреча', 'Встречи', 'Инструменты', 'Профиль'];

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_titles[_selected])),
    body: SafeArea(
      child: IndexedStack(
        index: _selected,
        children: [
          NewMeetingPage(controller: widget.controller),
          widget.controller == null
              ? const PlaceholderPage(
                  icon: Icons.folder_open_outlined,
                  title: 'Ваши встречи',
                  message:
                      'Здесь появятся папки и результаты обработки встреч.',
                )
              : MeetingsPage(controller: widget.controller!),
          PlaceholderPage(
            icon: Icons.tune_outlined,
            title: 'Инструменты',
            message:
                'Шаблоны и дополнительные инструменты будут доступны позже.',
          ),
          PlaceholderPage(
            icon: Icons.person_outline,
            title: 'Тестовый профиль',
            message: 'Первая версия использует тестового пользователя сервера.',
          ),
        ],
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _selected,
      onDestinationSelected: (index) => setState(() => _selected = index),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.add_circle_outline),
          label: 'Новая встреча',
        ),
        NavigationDestination(
          icon: Icon(Icons.folder_outlined),
          label: 'Встречи',
        ),
        NavigationDestination(
          icon: Icon(Icons.tune_outlined),
          label: 'Инструменты',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          label: 'Профиль',
        ),
      ],
    ),
  );
}

class NewMeetingPage extends StatelessWidget {
  const NewMeetingPage({super.key, this.controller});
  final MeetingController? controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller ?? const AlwaysStoppedAnimation<int>(0),
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Сохраните главное',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Text(
          controller?.hasOperation == true
              ? controller?.result != null
                    ? 'Результат готов. Откройте обработку, чтобы прочитать его.'
                    : 'Есть незавершённая обработка. Её состояние сохраняется при перезапуске.'
              : 'Загрузите готовый транскрипт, чтобы получить решения и задачи встречи.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.description_outlined, size: 32),
                const SizedBox(height: 12),
                Text(
                  'Готовый транскрипт',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text('Текстовый файл .txt или текст из буфера обмена.'),
                const SizedBox(height: 16),
                FilledButton.icon(
                  icon: const Icon(Icons.upload_file),
                  label: Text(
                    controller?.hasOperation == true
                        ? 'Открыть обработку'
                        : 'Загрузить транскрипт',
                  ),
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => controller == null
                          ? const TranscriptDraftPage()
                          : TranscriptPage(controller: controller!),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text('Другие способы', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const _UnavailableAction(
          icon: Icons.mic_none,
          title: 'Записать встречу',
        ),
        const _UnavailableAction(
          icon: Icons.audio_file_outlined,
          title: 'Загрузить аудио',
        ),
        const _UnavailableAction(
          icon: Icons.videocam_outlined,
          title: 'Подключиться к видеоконференции',
        ),
      ],
    ),
  );
}

class _UnavailableAction extends StatelessWidget {
  const _UnavailableAction({required this.icon, required this.title});
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) => ListTile(
    enabled: false,
    leading: Icon(icon),
    title: Text(title),
    subtitle: const Text('Недоступно в первой версии'),
  );
}

class TranscriptDraftPage extends StatelessWidget {
  const TranscriptDraftPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Транскрипт встречи')),
    body: const PlaceholderPage(
      icon: Icons.description_outlined,
      title: 'Загрузка транскрипта',
      message:
          'Форма ввода и подключение к серверу — следующий этап разработки.',
    ),
  );
}

class PlaceholderPage extends StatelessWidget {
  const PlaceholderPage({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 20),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    ),
  );
}

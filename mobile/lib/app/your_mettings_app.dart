import '../features/recording/recorder_coordinator.dart';
import '../features/recording/audio_review_controller.dart';
import '../features/recording/recorder_page.dart';
import 'appearance.dart';
import '../services/audio_draft_store.dart';
import '../features/recording/workspace_page.dart';

import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;

import '../features/meetings/meetings_page.dart';
import '../features/new_meeting/meeting_controller.dart';
import '../features/new_meeting/transcript_page.dart';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

class YourMettingsApp extends StatefulWidget {
  const YourMettingsApp({
    super.key,
    this.controller,
    this.appearance,
    this.recorder,
    this.audioReview,
    this.drafts,
  });
  final MeetingController? controller;
  final AppearanceController? appearance;
  final RecorderCoordinator? recorder;
  final AudioReviewController? audioReview;
  final AudioDraftRepository? drafts;
  @override
  State<YourMettingsApp> createState() => _YourMettingsAppState();
}

class _YourMettingsAppState extends State<YourMettingsApp> {
  late final AppearanceController _appearance =
      widget.appearance ?? AppearanceController();
  @override
  void dispose() {
    if (widget.appearance == null) _appearance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _appearance,
    builder: (context, _) => MaterialApp(
      title: 'YourMettings',
      builder: (context, child) =>
          AppearanceScope(controller: _appearance, child: child!),
      debugShowCheckedModeBanner: false,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: const [
        FlutterQuillLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      theme: _appearance.theme(Brightness.light),
      darkTheme: _appearance.theme(Brightness.dark),
      themeMode: _appearance.themeMode,
      home: MeetingShell(
        controller: widget.controller,
        appearance: _appearance,
        recorder: widget.recorder,
        audioReview: widget.audioReview,
        drafts: widget.drafts,
      ),
    ),
  );
}

class MeetingShell extends StatefulWidget {
  const MeetingShell({
    super.key,
    this.controller,
    required this.appearance,
    this.recorder,
    this.audioReview,
    this.drafts,
  });
  final MeetingController? controller;
  final AppearanceController appearance;
  final RecorderCoordinator? recorder;
  final AudioReviewController? audioReview;
  final AudioDraftRepository? drafts;

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
      widget.audioReview?.resume();
      widget.recorder?.foreground();
    } else {
      widget.controller?.pause();
      widget.audioReview?.pause();
    }
  }

  int _selected = 0;
  static const _titles = [
    'Новая встреча',
    'Встречи',
    'Рабочее пространство',
    'Профиль',
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_titles[_selected])),
    body: SafeArea(
      child: IndexedStack(
        index: _selected,
        children: [
          NewMeetingPage(
            controller: widget.controller,
            recorder: widget.recorder,
            audioReview: widget.audioReview,
          ),
          widget.controller == null
              ? const PlaceholderPage(
                  icon: Icons.folder_open_outlined,
                  title: 'Ваши встречи',
                  message:
                      'Здесь появятся папки и результаты обработки встреч.',
                )
              : MeetingsPage(controller: widget.controller!),
          WorkspacePage(
            controller: widget.controller,
            recorder: widget.recorder,
            review: widget.audioReview,
            drafts: widget.drafts,
            visible: _selected == 2,
          ),
          AppearancePage(controller: widget.appearance),
        ],
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _selected,
      onDestinationSelected: (index) => setState(() => _selected = index),
      destinations: [
        DefaultTextStyle.merge(
          textAlign: TextAlign.center,
          child: const NavigationDestination(
            icon: Icon(Icons.add_circle_outline),
            label: 'Новая встреча',
          ),
        ),
        DefaultTextStyle.merge(
          textAlign: TextAlign.center,
          child: const NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            label: 'Встречи',
          ),
        ),
        DefaultTextStyle.merge(
          textAlign: TextAlign.center,
          child: const NavigationDestination(
            icon: Icon(Icons.workspaces_outline),
            label: 'Пространство',
          ),
        ),
        DefaultTextStyle.merge(
          textAlign: TextAlign.center,
          child: const NavigationDestination(
            icon: Icon(Icons.person_outline),
            label: 'Профиль',
          ),
        ),
      ],
    ),
  );
}

class NewMeetingPage extends StatelessWidget {
  const NewMeetingPage({
    super.key,
    this.controller,
    this.recorder,
    this.audioReview,
  });
  final RecorderCoordinator? recorder;
  final AudioReviewController? audioReview;
  final MeetingController? controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([?controller, ?recorder]),
    builder: (context, _) => ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Icon(Icons.mic_none, size: 64),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.mic),
                    label: Text(
                      recorder?.active == true
                          ? ['review', 'completed'].contains(recorder?.phase)
                                ? 'Продолжить встречу'
                                : 'Открыть запись'
                          : 'Записать встречу',
                    ),
                    onPressed: recorder == null || audioReview == null
                        ? null
                        : () => Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => RecorderPage(
                                recorder: recorder!,
                                review: audioReview!,
                              ),
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text('Другие способы', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: Text(
            controller?.hasOperation == true ||
                    controller?.selectionActive == true
                ? 'Открыть обработку'
                : 'Загрузить транскрипт',
          ),
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => controller == null
                  ? const TranscriptDraftPage()
                  : TranscriptPage(controller: controller!),
            ),
          ),
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

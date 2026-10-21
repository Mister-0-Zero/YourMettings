import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/app/your_mettings_app.dart';
import 'package:your_mettings/app/appearance.dart';
import 'package:your_mettings/features/recording/audio_review_controller.dart';
import 'package:your_mettings/features/recording/recorder_coordinator.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/recovery_store.dart';

class MemoryStore implements RecoveryStore {
  RecoveryState state = RecoveryState();
  @override
  Future<RecoveryState> load() async => state;
  @override
  Future<void> save(RecoveryState value) async {
    state = value;
  }
}

class FakeRecorder extends RecorderCoordinator {
  Map<String, dynamic>? started;
  @override
  Future<void> start(Map<String, dynamic> parameters) async {
    started = parameters;
    state = {'phase': 'recording', 'elapsed_ms': 1000, 'chunks': []};
    notifyListeners();
  }

  @override
  Future<void> command(String command) async {
    state['phase'] = command == 'pause'
        ? 'paused'
        : command == 'resume'
        ? 'recording'
        : 'sending';
    notifyListeners();
  }
}

void main() {
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('one tap recording and safe back/reentry in $mode', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1264, 2736);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = ApiClient(
        Uri.parse('http://example/api/v1/'),
        client: MockClient(
          (_) async => http.Response(jsonEncode({'items': []}), 200),
        ),
      );
      final appearance = AppearanceController()..themeMode = mode;
      final recorder = FakeRecorder();
      final store = MemoryStore();
      final review = AudioReviewController(api, store, recorder)
        ..folders = [Folder(id: 'folder', name: 'Project')];
      review.recovery = RecoveryState(
        draft: Draft(title: 'Audio QA', folderIds: ['folder']),
      );
      await tester.pumpWidget(
        YourMettingsApp(
          recorder: recorder,
          audioReview: review,
          appearance: appearance,
        ),
      );
      await tester.tap(find.text('Записать встречу'));
      await tester.pumpAndSettle();
      expect(find.text('Настроить запись'), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      await tester.tap(find.byKey(const Key('record-start-button')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(recorder.started!['title'], startsWith('Совещание '));
      expect(recorder.started!['folder_ids'], isEmpty);
      expect(recorder.started!.containsKey('text'), false);
      expect(find.text('Идёт запись'), findsOneWidget);
      await tester.tap(find.text('Пауза'));
      await tester.pumpAndSettle();
      expect(find.text('Запись приостановлена'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(recorder.phase, 'paused');
      await tester.tap(find.text('Открыть запись'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Продолжить'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(recorder.phase, 'recording');
      await tester.pumpWidget(const SizedBox());
      review.dispose();
      recorder.dispose();
      api.close();
      appearance.dispose();
    });
  }
}

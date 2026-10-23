import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/app/appearance.dart';
import 'package:your_mettings/features/meetings/meetings_page.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/recovery_store.dart';

void main() {
  test('old preferences default to confirmation enabled', () async {
    final directory = await Directory.systemTemp.createTemp('meeting-prefs-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/appearance.json');
    await file.writeAsString('{"theme_mode":"dark","accent":"green"}');
    final prefs = AppearanceController(file: file);
    addTearDown(prefs.dispose);
    await prefs.load();
    expect(prefs.skipFolderDeleteConfirmation, isFalse);
  });
  for (final skip in [false, true]) {
    testWidgets('explicit folder delete respects skip=$skip', (tester) async {
      var deletes = 0;
      final api = ApiClient(
        Uri.parse('http://localhost/api/v1/'),
        client: MockClient((r) async {
          if (r.method == 'DELETE') {
            deletes++;
            return http.Response('', 204);
          }
          return http.Response('{"items":[]}', 200);
        }),
      );
      final controller = MeetingController(api, MemoryStore());
      final prefs = AppearanceController()..skipFolderDeleteConfirmation = skip;
      addTearDown(() {
        prefs.dispose();
        controller.dispose();
        api.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) =>
              AppearanceScope(controller: prefs, child: child!),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => deleteFolderWithConfirmation(
                  context,
                  controller,
                  Folder(id: 'f', name: 'Own'),
                ),
                child: const Text('Удалить папку'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(deletes, 0);
      await tester.tap(find.text('Удалить папку'));
      await tester.pumpAndSettle();
      if (!skip) {
        expect(find.text('Удалить папку?'), findsOneWidget);
        expect(deletes, 0);
        await tester.tap(find.text('Удалить'));
        await tester.pumpAndSettle();
      } else {
        expect(find.byType(AlertDialog), findsNothing);
      }
      expect(deletes, 1);
    });
  }
  testWidgets('profile switch changes preference', (tester) async {
    final prefs = AppearanceController();
    addTearDown(prefs.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: prefs,
            builder: (_, _) => AppearancePage(controller: prefs),
          ),
        ),
      ),
    );
    expect(prefs.skipFolderDeleteConfirmation, isFalse);
    final preference = find.widgetWithText(
      SwitchListTile,
      'Не спрашивать подтверждение при удалении папок',
    );
    await tester.ensureVisible(preference);
    await tester.tap(preference);
    await tester.pumpAndSettle();
    expect(prefs.skipFolderDeleteConfirmation, isTrue);
  });
}

class MemoryStore implements RecoveryStore {
  @override
  Future<RecoveryState> load() async => RecoveryState();
  @override
  Future<void> save(RecoveryState state) async {}
}

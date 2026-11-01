import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:queue_owner/queue_owner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:your_mettings/app/your_mettings_app.dart';
import 'package:your_mettings/features/drafts/local_draft_pages.dart';
import 'package:your_mettings/features/recording/draft_recorder_coordinator.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/drafts/catalog_cache.dart';
import 'package:your_mettings/services/drafts/draft_record.dart';

import 'support/draft_test_fixture.dart';

Future<void> io(WidgetTester tester, {int turns = 60}) async {
  for (var n = 0; n < turns; n++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  testWidgets(
    'main UI opens and creates independent local text with offline API and no vault key',
    (tester) async {
      final fixture = (await tester.runAsync(DraftTestFixture.create))!;
      final recorder = DraftRecorderCoordinator(fixture.workspace);
      await tester.runAsync(() => fixture.workspace.initialize());
      await tester.pumpWidget(
        YourMettingsApp(
          localDrafts: fixture.workspace,
          localRecorder: recorder,
        ),
      );
      expect(find.text('Записать встречу'), findsOneWidget);
      expect(find.text('Загрузить транскрипт'), findsOneWidget);
      await tester.tap(find.text('Загрузить транскрипт'));
      await io(tester);
      expect(find.byKey(const Key('local-draft-text')), findsOneWidget);
      expect(fixture.workspace.items.single.kind, LocalDraftKind.text);
      expect(fixture.httpCalls, isEmpty);
      expect(fixture.vault.reads, 0);
      await tester.pumpWidget(const SizedBox());
      final closing = recorder.close();
      await io(tester, turns: 24);
      await closing;
      recorder.dispose();
      await tester.runAsync(fixture.close);
    },
  );
  testWidgets(
    'autosave and background flush show saved only after durable write; reopening keeps text',
    (tester) async {
      final fixture = (await tester.runAsync(DraftTestFixture.create))!;
      await tester.runAsync(() => fixture.workspace.initialize());
      final record = (await tester.runAsync(
        () => fixture.workspace.create(LocalDraftKind.text),
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          home: LocalDraftEditorPage(
            workspace: fixture.workspace,
            record: record,
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('local-draft-title')),
        'Local title',
      );
      await tester.enterText(
        find.byKey(const Key('local-draft-text')),
        'Background preserved input',
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await io(tester);
      final restored = (await tester.runAsync(
        () => fixture.workspace.reader.read(record.localId),
      ))!;
      expect(restored.input.title, 'Local title');
      expect(restored.input.text, 'Background preserved input');
      expect(find.text('Черновик сохранён на устройстве'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(fixture.close);
    },
  );
  testWidgets(
    'failed storage leaves edited input available and explicit retry persists it',
    (tester) async {
      final fixture = (await tester.runAsync(DraftTestFixture.create))!;
      await tester.runAsync(() => fixture.workspace.initialize());
      final record = (await tester.runAsync(
        () => fixture.workspace.create(
          LocalDraftKind.text,
          input: LocalDraftInput(text: 'Before'),
        ),
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          home: LocalDraftEditorPage(
            workspace: fixture.workspace,
            record: record,
          ),
        ),
      );
      fixture.pool.failWrites = true;
      await tester.enterText(
        find.byKey(const Key('local-draft-text')),
        'Typed but not saved',
      );
      await tester.tap(find.byTooltip('Сохранить черновик'));
      await io(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('local-draft-text')))
            .controller!
            .text,
        'Typed but not saved',
      );
      expect(
        (await tester.runAsync(
          () => fixture.workspace.reader.read(record.localId),
        ))!.input.text,
        'Before',
      );
      expect(
        find.textContaining('Не удалось сохранить черновик'),
        findsOneWidget,
      );
      expect(find.text('Черновик сохранён на устройстве'), findsNothing);
      fixture.pool.failWrites = false;
      await tester.tap(find.byTooltip('Сохранить черновик'));
      await io(tester);
      expect(
        (await tester.runAsync(
          () => fixture.workspace.reader.read(record.localId),
        ))!.input.text,
        'Typed but not saved',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(fixture.close);
    },
  );
  testWidgets(
    'cached nested folders show indentation/staleness and keep unavailable selection',
    (tester) async {
      final fixture = (await tester.runAsync(DraftTestFixture.create))!;
      await tester.runAsync(() => fixture.workspace.initialize());
      await tester.runAsync(
        () => fixture.workspace.withOwner(
          (_, lease) =>
              ScopedCatalogCache(
                scopeDirectory: fixture.workspace.directory,
                authority: lease,
              ).saveFolders([
                Folder(
                  id: 'a',
                  name: 'Root',
                  children: [Folder(id: 'b', name: 'Nested', parentId: 'a')],
                ),
              ], fetchedAt: DateTime.utc(2020)),
        ),
      );
      await tester.runAsync(() => fixture.workspace.initialize());
      final record = (await tester.runAsync(
        () => fixture.workspace.create(
          LocalDraftKind.audio,
          input: LocalDraftInput(folderIds: ['b', 'unavailable']),
        ),
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          home: LocalDraftEditorPage(
            workspace: fixture.workspace,
            record: record,
          ),
        ),
      );
      final root = find.widgetWithText(CheckboxListTile, 'Root'),
          nested = find.widgetWithText(CheckboxListTile, 'Nested');
      expect(
        tester.widget<CheckboxListTile>(root).contentPadding,
        EdgeInsets.zero,
      );
      expect(
        tester.widget<CheckboxListTile>(nested).contentPadding,
        const EdgeInsets.only(left: 20),
      );
      expect(tester.widget<CheckboxListTile>(nested).value, isTrue);
      expect(
        find.textContaining('Список может быть устаревшим'),
        findsOneWidget,
      );
      expect(find.text('Выбранная папка: unavailable'), findsOneWidget);
      expect(fixture.httpCalls, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(fixture.close);
    },
  );
  for (final diskFailure in [false, true]) {
    testWidgets(
      'resume recording waits for durable fast edits; diskFailure=$diskFailure',
      (tester) async {
        final fixture = (await tester.runAsync(DraftTestFixture.create))!;
        await tester.runAsync(() => fixture.workspace.initialize());
        var record = (await tester.runAsync(
          () => fixture.workspace.create(
            LocalDraftKind.audio,
            input: LocalDraftInput(title: 'Before'),
          ),
        ))!;
        record = (await tester.runAsync(
          () => fixture.workspace.withOwner(
            (repo, _) => repo.update(
              record.localId,
              expectedRevision: record.revision,
              change: (j) => j['state'] = 'interrupted',
            ),
          ),
        ))!;
        final recorder = DraftRecorderCoordinator(fixture.workspace);
        await tester.pumpWidget(
          MaterialApp(
            home: LocalDraftEditorPage(
              workspace: fixture.workspace,
              record: record,
              recorder: recorder,
            ),
          ),
        );
        fixture.pool.failWrites = diskFailure;
        await tester.enterText(
          find.byKey(const Key('local-draft-title')),
          'Immediately before resume',
        );
        // No 350ms debounce advance: replacement itself must save these changes.
        await tester.tap(find.text('Продолжить запись'));
        await io(tester);
        final durable = (await tester.runAsync(
          () => fixture.workspace.reader.read(record.localId),
        ))!;
        if (diskFailure) {
          expect(find.byType(LocalDraftEditorPage), findsOneWidget);
          expect(find.byType(LocalRecorderPage), findsNothing);
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('local-draft-title')))
                .controller!
                .text,
            'Immediately before resume',
          );
          expect(durable.input.title, 'Before');
          expect(
            find.textContaining('Не удалось сохранить черновик'),
            findsOneWidget,
          );
        } else {
          expect(find.byType(LocalRecorderPage), findsOneWidget);
          expect(durable.input.title, 'Immediately before resume');
        }
        await tester.pumpWidget(const SizedBox());
        final closing = recorder.close();
        await io(tester, turns: 24);
        await closing;
        recorder.dispose();
        await io(tester, turns: 4);
        await tester.runAsync(fixture.close);
      },
    );
  }
  for (final unavailable in [false, true]) {
    testWidgets(
      'fresh UI restores live local FGS without SharedPreferences/auth gate; ticketFailure=$unavailable',
      (tester) async {
        final fixture = (await tester.runAsync(DraftTestFixture.create))!;
        await tester.runAsync(() => fixture.workspace.initialize());
        var record = (await tester.runAsync(
          () => fixture.workspace.create(LocalDraftKind.audio),
        ))!;
        record = (await tester.runAsync(
          () => fixture.workspace.withOwner(
            (repo, _) => repo.update(
              record.localId,
              expectedRevision: record.revision,
              change: (j) => j['state'] = 'recording',
            ),
          ),
        ))!;
        var reads = 0;
        const foreground = MethodChannel('flutter_foreground_task/methods');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(NativeQueueOwner.channel, (
          call,
        ) async {
          expect(call.method, 'captureTicket');
          reads++;
          if (unavailable) throw PlatformException(code: 'storage_failure');
          return {
            'scope': fixture.connection.scopeId,
            'local_id': record.localId,
            'nonce': '12345678-1234-1234-1234-123456789abc',
          };
        });
        messenger.setMockMethodCallHandler(foreground, (call) async {
          if (call.method == 'isRunningService') return true;
          if (call.method == 'sendData') {
            for (final callback in FlutterForegroundTask.dataCallbacks.toList()) {
              callback({
                'queue_protocol': 2,
                'scope_id': fixture.connection.scopeId,
                'local_id': record.localId,
                'launch_nonce': '12345678-1234-1234-1234-123456789abc',
                'service_instance': 'service-kept-alive',
                'phase': 'recording',
                'duration_ms': 1200,
              });
            }
          }
          return null;
        });
        final recorder = DraftRecorderCoordinator(fixture.workspace);
        final init = recorder.initialize();
        await io(tester);
        await init;
        await tester.pumpWidget(
          YourMettingsApp(
            localDrafts: fixture.workspace,
            localRecorder: recorder,
          ),
        );
        await tester.pump();
        expect(reads, greaterThan(0));
        expect(fixture.httpCalls, isEmpty);
        expect(fixture.vault.reads, 0);
        expect(find.text('Подключение'), findsNothing);
        if (unavailable) {
          expect(recorder.error, isNotNull);
          expect(find.text('Записать встречу'), findsOneWidget);
        } else {
          expect(recorder.localId, record.localId);
          expect(recorder.recording, isTrue);
          expect(find.text('Открыть запись'), findsOneWidget);
        }
        expect(
          (await tester.runAsync(
            () => fixture.workspace.reader.read(record.localId),
          ))!.toJson()['state'],
          'recording',
        );
        await tester.pumpWidget(const SizedBox());
        final closing = recorder.close();
        await io(tester, turns: 24);
        await closing;
        recorder.dispose();
        messenger.setMockMethodCallHandler(foreground, null);
        messenger.setMockMethodCallHandler(NativeQueueOwner.channel, null);
        await io(tester, turns: 4);
        await tester.runAsync(fixture.close);
      },
    );
  }
}

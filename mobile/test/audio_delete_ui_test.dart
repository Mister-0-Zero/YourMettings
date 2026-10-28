import 'package:your_mettings/features/recording/recorder_page.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/app/your_mettings_app.dart';
import 'package:your_mettings/features/new_meeting/transcript_page.dart';
import 'package:your_mettings/features/recording/audio_api.dart';
import 'package:your_mettings/features/recording/audio_review_controller.dart';
import 'package:your_mettings/services/audio_draft_store.dart';

import 'audio_drafts_test.dart' as fixture;

void main() {
  for (final failure in [false, true]) {
    testWidgets(
      'three choices, explicit confirmation and ${failure ? 'retry after error' : 'confirmed deletion'}',
      (tester) async {
        final repo = AudioDraftRepository();
        final rec = fixture.Recorder()
          ..state = {
            'id': 'A',
            'key': 'key-A',
            'phase': 'review',
            'session': {'transcript_id': 'source-A', 'boundary_warnings': []},
          };
        var deletes = 0;
        Future<http.Response> backend(http.Request r) async {
          if (r.method == 'DELETE') {
            deletes++;
            expect(r.url.queryParameters, {'confirm': 'true'});
            if (failure && deletes == 1) {
              return http.Response(
                jsonEncode({
                  'error': {
                    'code': 'audio_cleanup_failed',
                    'message': 'Не удалось очистить файлы',
                  },
                }),
                409,
                headers: {'content-type': 'application/json; charset=utf-8'},
              );
            }
            return http.Response('', 204);
          }
          expect(r.method, 'GET');
          return fixture.response({
            'status': 'ready_for_review',
            'transcript_id': 'source-A',
            'parameters': {'title': 'A', 'folder_ids': []},
            'boundary_warnings': [],
          });
        }

        final api = ApiClient(
          Uri.parse('http://example/api/v1/'),
          client: MockClient(backend),
        );
        final c = AudioReviewController(
          api,
          fixture.MemoryStore(),
          rec,
          drafts: repo,
          audioApiFactory: () =>
              AudioApi(api.baseUri, client: MockClient(backend)),
        );
        await c.saveDraft(fixture.entry('A').recovery.draft);
        await tester.pumpWidget(
          YourMettingsApp(audioReview: c, recorder: rec, drafts: repo),
        );
        await tester.tap(find.text('Продолжить встречу'));
        await tester.pumpAndSettle();
        // App bar/system back uses the same three-choice dialog.
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.text('Продолжить редактирование'), findsOneWidget);
        expect(find.text('Сохранить черновик и выйти'), findsOneWidget);
        expect(find.text('Удалить встречу'), findsOneWidget);
        await tester.tap(find.text('Продолжить редактирование'));
        await tester.pumpAndSettle();
        expect(find.byType(TranscriptPage), findsOneWidget);
        expect(deletes, 0);
        Future<void> chooseDelete() async {
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Удалить встречу'));
          await tester.pumpAndSettle();
          expect(find.text('Удалить встречу?'), findsOneWidget);
        }

        await chooseDelete();
        expect(deletes, 0);
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        expect(deletes, 0);
        expect(c.draft.text, 'Текст A');
        await chooseDelete();
        await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
        await tester.pumpAndSettle();
        if (failure) {
          expect(find.byType(TranscriptPage), findsOneWidget);
          expect(c.error, contains('Не удалось очистить файлы'));
          expect(repo['A']!.recovery.draft.text, 'Текст A');
          await chooseDelete();
          await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
          await tester.pumpAndSettle();
        }
        expect(find.byType(TranscriptPage), findsNothing);
        expect(repo['A'], isNull);
        expect(find.text('Записать встречу'), findsOneWidget);
        expect(rec.phase, 'done');
        expect(deletes, failure ? 2 : 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        rec.dispose();
        repo.dispose();
        api.close();
      },
    );
  }
  testWidgets(
    'confirmed local cleanup failure is visible in drafts and retries without deleting again',
    (tester) async {
      final repo = AudioDraftRepository();
      final rec = fixture.Recorder()
        ..failRelease = true
        ..state = {
          'id': 'A',
          'key': 'key-A',
          'phase': 'review',
          'session': {'transcript_id': 'source-A', 'boundary_warnings': []},
        };
      var deletes = 0;
      Future<http.Response> backend(http.Request r) async {
        if (r.method == 'DELETE') {
          deletes++;
          return http.Response('', 204);
        }
        return fixture.response({'items': []});
      }

      final api = ApiClient(
        Uri.parse('http://example/api/v1/'),
        client: MockClient(backend),
      );
      final review = AudioReviewController(
        api,
        fixture.MemoryStore(),
        rec,
        drafts: repo,
        audioApiFactory: () =>
            AudioApi(api.baseUri, client: MockClient(backend)),
      );
      await review.saveDraft(fixture.entry('A').recovery.draft);
      expect(await review.deleteMeeting(), isFalse);
      expect(repo['A']!.serverDeleted, isTrue);
      expect(rec.handoffPending, isTrue);
      await tester.pumpWidget(
        YourMettingsApp(recorder: rec, audioReview: review, drafts: repo),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Пространство'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-drafts')));
      await tester.pumpAndSettle();
      expect(find.text('Завершить удаление'), findsOneWidget);
      rec.failRelease = false;
      await tester.tap(find.text('Завершить удаление'));
      await tester.pumpAndSettle();
      expect(repo['A'], isNull);
      expect(deletes, 1);
      expect(find.text('Сохранённых черновиков пока нет.'), findsOneWidget);
      expect(rec.active, isFalse);
      expect(rec.handoffPending, isFalse);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Новая встреча'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Записать встречу'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      review.dispose();
      rec.dispose();
      repo.dispose();
      api.close();
    },
  );
  testWidgets(
    'done journal with pending cleanup has a visible recovery action',
    (tester) async {
      final repo = AudioDraftRepository();
      final saved = fixture
          .entry('A')
          .copy(serverDeleted: true, deletePending: true, handoff: true);
      await repo.put(saved);
      final rec = fixture.Recorder()
        ..state = {'phase': 'done'}
        ..handoffPending = true;
      final api = ApiClient(Uri.parse('http://example/api/v1/'));
      final review = AudioReviewController(
        api,
        fixture.MemoryStore(),
        rec,
        drafts: repo,
      )..recovery = saved.recovery;
      await tester.pumpWidget(
        MaterialApp(
          home: RecorderPage(recorder: rec, review: review),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Завершить операцию'), findsOneWidget);
      await tester.ensureVisible(find.text('Завершить операцию'));
      await tester.tap(find.text('Завершить операцию'));
      await tester.pumpAndSettle();
      expect(repo['A'], isNull);
      expect(rec.handoffPending, isFalse);
      expect(find.text('Завершить операцию'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      review.dispose();
      rec.dispose();
      repo.dispose();
      api.close();
    },
  );
}

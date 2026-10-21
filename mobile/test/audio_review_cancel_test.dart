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
import 'package:your_mettings/features/recording/recorder_coordinator.dart';
import 'package:your_mettings/services/recovery_store.dart';
import 'package:your_mettings/services/audio_draft_store.dart';

class _Store implements RecoveryStore {
  RecoveryState value = RecoveryState();
  bool fail = false;
  @override
  Future<RecoveryState> load() async => value;
  @override
  Future<void> save(RecoveryState next) async {
    if (fail) throw StateError('disk full');
    value = RecoveryState.fromJson(next.toJson());
  }
}

class _Recorder extends RecorderCoordinator {
  @override
  Future<void> releaseReview(String expectedId) async {
    expect(state['id'], expectedId);
    state = {'phase': 'done'};
    notifyListeners();
  }
}

void main() {
  for (final failure in [false, true]) {
    testWidgets(
      'cancel review ${failure ? 'keeps input on disk error' : 'resumes same saved session without POST'}',
      (tester) async {
        final methods = <String>[];
        Future<http.Response> backend(http.Request r) async {
          methods.add(r.method);
          expect(r.method, 'GET');
          return http.Response(
            jsonEncode({
              'status': 'ready_for_review',
              'transcript_id': 'source',
              'parameters': {'title': 'Original', 'folder_ids': []},
            }),
            200,
          );
        }

        final api = ApiClient(
          Uri.parse('http://example/api/v1/'),
          client: MockClient(backend),
        );
        final drafts = AudioDraftRepository();
        final recorder = _Recorder()
          ..state = {
            'phase': 'review',
            'key': 'same-key',
            'id': 'same-session',
            'session': {'transcript_id': 'source', 'boundary_warnings': []},
          };
        final store = _Store();
        final review = AudioReviewController(
          api,
          store,
          recorder,
          drafts: drafts,
          audioApiFactory: () =>
              AudioApi(api.baseUri, client: MockClient(backend)),
        );
        await review.saveDraft(Draft(title: 'Review', text: 'Speech'));
        await tester.pumpWidget(
          YourMettingsApp(
            recorder: recorder,
            audioReview: review,
            drafts: drafts,
          ),
        );
        await tester.tap(find.text('Продолжить встречу'));
        await tester.pumpAndSettle();
        expect(find.byType(TranscriptPage), findsOneWidget);
        await tester.enterText(
          find.byType(TextFormField).at(1),
          'Edited speech',
        );
        store.fail = failure;
        await tester.ensureVisible(find.text('Отменить создание встречи'));
        await tester.tap(find.text('Отменить создание встречи'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Сохранить черновик и выйти'));
        await tester.pumpAndSettle();
        if (failure) {
          expect(find.byType(TranscriptPage), findsOneWidget);
          expect(review.storageError, isNotNull);
          expect(review.draft.text, 'Edited speech');
        } else {
          expect(find.byType(TranscriptPage), findsNothing);
          expect(store.value.draft.text, isEmpty);
          expect(drafts['same-session']!.recovery.draft.text, 'Edited speech');
          expect(find.text('Записать встречу'), findsOneWidget);
          await tester.tap(
            find.descendant(
              of: find.byType(NavigationBar),
              matching: find.text('Пространство'),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('draft-same-session')));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<TextFormField>(find.byType(TextFormField).at(1))
                .controller!
                .text,
            'Edited speech',
          );
        }
        expect(recorder.state['id'], failure ? 'same-session' : null);
        expect(recorder.phase, failure ? 'review' : 'done');
        expect(methods, everyElement('GET'));
        await tester.pumpWidget(const SizedBox());
        review.dispose();
        drafts.dispose();
        recorder.dispose();
        api.close();
      },
    );
  }
}

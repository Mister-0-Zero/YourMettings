import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/recording/audio_api.dart';
import 'package:your_mettings/features/recording/audio_engine.dart';
import 'package:your_mettings/features/recording/audio_review_controller.dart';
import 'package:your_mettings/features/recording/audio_transfer_status.dart';
import 'package:your_mettings/features/recording/recorder_coordinator.dart';
import 'package:your_mettings/features/recording/recorder_page.dart';
import 'package:your_mettings/models/api_models.dart';

import 'audio_drafts_test.dart' show MemoryStore;
import 'audio_upload_status_test.dart' show seed, reply;

class StatusRecorder extends RecorderCoordinator {
  void publish(Json value) {
    state = jsonDecode(jsonEncode(value)) as Json;
    notifyListeners();
  }
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'real engine updates recorder screen mid-queue and on a new failure, $brightness',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('ym-upload-ui-');
        final journal = seed(dir);
        final recorder = StatusRecorder();
        final api = ApiClient(Uri.parse('http://example/api/v1/'));
        final review = AudioReviewController(api, MemoryStore(), recorder);
        var attempt = 0;
        late Completer<void> pending, release;
        await tester.runAsync(() async {
          pending = Completer<void>();
          release = Completer<void>();
        });
        final engine = AudioEngine(
          journal,
          AudioApi(
            api.baseUri,
            client: MockClient((request) async {
              if (request.url.path.endsWith('/chunks')) {
                final n = int.parse(
                  request.url.queryParameters['sequence_number']!,
                );
                if (attempt == 0) throw http.ClientException('offline');
                if (attempt == 1 && n == 1) {
                  pending.complete();
                  await release.future;
                  throw http.ClientException('offline again');
                }
                return reply({
                  'accepted': true,
                  'safe_to_delete_local': true,
                  'chunk': {
                    'sequence_number': n,
                    'sha256': sha256.convert(request.bodyBytes).toString(),
                  },
                });
              }
              return reply({'status': 'transcribing'});
            }),
          ),
          changed: recorder.publish,
        );
        await tester.runAsync(() => engine.sync(force: true));
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: RecorderPage(recorder: recorder, review: review),
          ),
        );
        await tester.pump();
        expect(find.text('Ожидаем повторной отправки'), findsOneWidget);
        expect(find.text('Отправлено фрагментов: 0 из 2'), findsOneWidget);
        expect(find.text('Повторить отправку'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        attempt = 1;
        late Future<void> retry;
        await tester.runAsync(() async {
          retry = engine.sync(force: true);
          await pending.future.timeout(const Duration(seconds: 5));
        });
        await tester.pump();
        expect(find.text('Отправляем запись…'), findsOneWidget);
        expect(find.text('Отправлено фрагментов: 1 из 2'), findsOneWidget);
        expect(find.text('Ожидаем повторной отправки'), findsNothing);
        expect(
          find.textContaining('Отправка временно не удалась'),
          findsNothing,
        );
        expect(find.text('Повторить отправку'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          .5,
        );
        await tester.runAsync(() async {
          release.complete();
          await retry;
        });
        await tester.pump();
        expect(find.text('Ожидаем повторной отправки'), findsOneWidget);
        expect(find.text('Отправлено фрагментов: 1 из 2'), findsOneWidget);
        expect(find.text('Повторить отправку'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        attempt = 2;
        await tester.runAsync(() => engine.sync(force: true));
        await tester.pump();
        expect(find.text('Распознаём речь…'), findsOneWidget);
        expect(find.text('Отправлено фрагментов: 2 из 2'), findsOneWidget);
        expect(
          find.text(
            'Все фрагменты приняты сервером. Ожидаем готовый транскрипт.',
          ),
          findsOneWidget,
        );
        expect(find.text('Повторить отправку'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => engine.dispose());
        review.dispose();
        recorder.dispose();
        api.close();
        dir.deleteSync(recursive: true);
      },
    );
  }

  testWidgets(
    'restored stale error is hidden only during a real retry; narrow layout stays readable',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final snapshot = <String, dynamic>{
        'phase': 'sending',
        'sync_active': true,
        'sync_stage': 'uploading',
        'network_error': true,
        'upload_error': 'old error',
        'chunks': [
          {'acked': false},
          {'acked': false},
        ],
      };
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
            child: Scaffold(
              body: ListView(
                padding: const EdgeInsets.all(24),
                children: [AudioTransferStatus(snapshot: snapshot)],
              ),
            ),
          ),
        ),
      );
      expect(find.text('Повторяем отправку…'), findsOneWidget);
      expect(find.text('old error'), findsNothing);
      expect(find.text('Отправлено фрагментов: 0 из 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

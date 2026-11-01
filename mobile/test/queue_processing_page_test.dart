import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:your_mettings/features/meetings/summary_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:your_mettings/features/drafts/queue_processing_page.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/drafts/draft_record.dart';

import 'support/draft_test_fixture.dart';

void main() {
  for (final dark in [false, true]) {
    for (final legacyObject in [false, true]) {
      testWidgets(
        'Qwen error object survives cold reopen without TypeError; dark=$dark legacy=$legacyObject',
        (tester) async {
          final f = (await tester.runAsync(DraftTestFixture.create))!;
          await tester.runAsync(() => f.workspace.initialize());
          final draft = (await tester.runAsync(
            () => f.workspace.create(
              LocalDraftKind.text,
              input: LocalDraftInput(
                title: 'Test title',
                text: 'Kept input',
                folderIds: ['folder-1'],
              ),
            ),
          ))!;
          await tester.runAsync(
            () => f.workspace.withOwner(
              (repo, _) => repo.update(
                draft.localId,
                expectedRevision: draft.revision,
                change: (j) {
                  j['state'] = 'processing';
                  (j['checkpoints'] as Json)['queue'] = {
                    'stage': 'needs_action',
                    'error_code': legacyObject
                        ? {
                            'code': 'llm_timeout',
                            'message': 'Тестовая ошибка модели.',
                          }
                        : 'llm_timeout',
                    if (!legacyObject)
                      'error_message': 'Тестовая ошибка модели.',
                  };
                },
              ),
            ),
          );
          await tester.runAsync(f.workspace.reload);
          for (var reopen = 0; reopen < 2; reopen++) {
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(
                  brightness: dark ? Brightness.dark : Brightness.light,
                ),
                home: QueueProcessingPage(
                  workspace: f.workspace,
                  localId: draft.localId,
                ),
              ),
            );
            await tester.pump();
            expect(find.text('Тестовая ошибка модели.'), findsOneWidget);
            expect(
              find.text('Для продолжения нужно ваше решение'),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(f.workspace.reload);
          }
          expect(f.httpCalls, isEmpty);
          expect(f.vault.reads, 0);
          await tester.runAsync(f.close);
        },
      );
    }
  }
  for (final laterEdits in [false, true]) {
    testWidgets(
      'automatic result uses ordinary summary viewer; later edits require explicit opening=$laterEdits',
      (tester) async {
        final f = (await tester.runAsync(
          () => DraftTestFixture.create(
            response: (request) => http.Response(
              jsonEncode({
                'id': 'summary-1',
                'transcript_id': 'transcript-1',
                'title': 'Saved automatic meeting',
                'content': '# Ready\n\nSaved **summary**.',
                'folder_ids': ['folder-1'],
                'created_at': '2026-11-01T00:00:00Z',
                'updated_at': '2026-11-01T00:00:00Z',
                'version': 'v1',
                'navigation': [],
              }),
              200,
            ),
          ),
        ))!;
        await tester.runAsync(() => f.workspace.initialize());
        final draft = (await tester.runAsync(
          () => f.workspace.create(
            LocalDraftKind.text,
            input: LocalDraftInput(
              title: 'Unsent local title',
              text: 'Unsent local edit',
            ),
          ),
        ))!;
        if (laterEdits) {
          await tester.runAsync(
            () => f.workspace.withOwner(
              (repo, _) => repo.update(
                draft.localId,
                expectedRevision: draft.revision,
                change: (j) {
                  j['state'] = 'saved_with_changes';
                  (j['checkpoints'] as Json)['queue'] = {
                    'stage': 'saved_with_changes',
                  };
                },
              ),
            ),
          );
          await tester.runAsync(f.workspace.reload);
        } else {
          f.workspace.items = [];
        }
        f.workspace.completions = [
          {
            'local_id': draft.localId,
            'summary_id': 'summary-1',
            'title': 'Saved automatic meeting',
          },
        ];
        await tester.pumpWidget(
          MaterialApp(
            home: QueueProcessingPage(
              workspace: f.workspace,
              localId: draft.localId,
            ),
          ),
        );
        for (var n = 0; n < 20; n++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        if (laterEdits) {
          expect(find.byType(SummaryPageView), findsNothing);
          expect(
            find.text(
              'Summary сохранён; более поздние правки остались в черновике',
            ),
            findsOneWidget,
          );
          expect(
            (await tester.runAsync(
              () => f.workspace.reader.read(draft.localId),
            ))!.input.text,
            'Unsent local edit',
          );
        } else {
          expect(find.byType(SummaryPageView), findsOneWidget);
          expect(find.text('Сохранить выбранный вариант'), findsNothing);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(f.close);
      },
    );
  }
}

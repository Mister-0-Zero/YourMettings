import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:your_mettings/api/api_client.dart';
import 'package:your_mettings/features/meetings/meetings_page.dart';
import 'package:your_mettings/features/new_meeting/meeting_controller.dart';
import 'package:your_mettings/models/api_models.dart';
import 'package:your_mettings/services/recovery_store.dart';

void main() {
  for (final reject in [false, true]) {
    testWidgets(
      'folder confirmation cancel and ${reject ? '409 rollback' : '204 refresh'}',
      (tester) async {
        var deletes = 0;
        final api = ApiClient(
          Uri.parse('http://localhost/api/v1/'),
          client: MockClient((request) async {
            if (request.method == 'DELETE') {
              deletes++;
              expect(request.url.path, '/api/v1/folders/f1');
              expect(request.url.queryParameters, {
                'mode': 'with_contents',
                'confirm': 'true',
              });
              expect(request.body, isEmpty);
              return reject
                  ? http.Response.bytes(
                      utf8.encode(
                        jsonEncode({
                          'error': {
                            'code': 'folder_processing',
                            'message': 'busy',
                          },
                        }),
                      ),
                      409,
                    )
                  : http.Response('', 204);
            }
            expect(request.method, 'GET');
            return http.Response('{"items":[]}', 200);
          }),
        );
        final controller = MeetingController(api, MemoryStore());
        controller.folders = [
          Folder(
            id: 'f1',
            name: 'Own test',
            children: [Folder(id: 'f2', name: 'Child', parentId: 'f1')],
          ),
        ];
        addTearDown(() {
          controller.dispose();
          api.close();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: MeetingsPage(controller: controller)),
          ),
        );
        Future<void> confirmDialog() async {
          await tester.tap(find.byType(PopupMenuButton<String>).first);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Удалить папку'));
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.textContaining('вложенными папками'), findsOneWidget);
        }

        await confirmDialog();
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        expect(deletes, 0);
        expect(controller.folders, hasLength(1));
        await confirmDialog();
        await tester.tap(find.text('Удалить'));
        await tester.pumpAndSettle();
        expect(deletes, 1);
        expect(controller.folders, hasLength(reject ? 1 : 0));
        if (reject) {
          expect(find.textContaining('Дождитесь завершения'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  test('delete tree cancels ambiguous replay and preserves editable source/options', () async {
    final methods = <String>[];
    final api = ApiClient(
      Uri.parse('http://localhost/api/v1/'),
      client: MockClient((request) async {
        methods.add(request.method);
        return request.method == 'DELETE'
            ? http.Response('', 204)
            : http.Response('{"items":[]}', 200);
      }),
    );
    final store = MemoryStore();
    final controller = MeetingController(api, store);
    addTearDown(() {
      controller.dispose();
      api.close();
    });
    final draft = Draft(
      text: 'Own test',
      title: 'Test',
      folderIds: ['f2', 'outside'],
    );
    controller.recovery = RecoveryState(
      draft: draft,
      pending: PendingRequest('old-key', draft),
    );
    await controller.deleteFolder(
      Folder(
        id: 'f1',
        name: 'Root',
        children: [Folder(id: 'f2', name: 'Child', parentId: 'f1')],
      ),
    );
    await controller.check();
    expect(methods, ['DELETE', 'GET']);
    expect(store.state.pending, isNull);
    expect(controller.draft.text, 'Own test');
    expect(controller.draft.folderIds, ['outside']);
  });
}

class MemoryStore implements RecoveryStore {
  RecoveryState state = RecoveryState();
  @override
  Future<RecoveryState> load() async => state;
  @override
  Future<void> save(RecoveryState value) async {
    state = value;
  }
}

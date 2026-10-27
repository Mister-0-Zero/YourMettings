import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:your_mettings/features/settings/connection_page.dart';
import 'package:your_mettings/services/connection_settings.dart';

import 'demo_connection_test.dart'
    show MemoryKeyVault, canary, demoUser, response;

void main() {
  testWidgets(
    'key stays hidden, origin changes clear it, empty and invalid keys do not replace saved access',
    (tester) async {
      final vault = MemoryKeyVault()..values['http://127.0.0.1:8000'] = canary;
      var requests = 0;
      final settings = ConnectionSettings(
        vault: vault,
        probeClient: () => MockClient((r) async {
          requests++;
          if (r.headers['X-Demo-Key'] != canary) {
            return response({
              'error': {'code': 'demo_key_invalid', 'message': 'Invalid'},
            }, 401);
          }
          return response(
            r.url.path == '/health' ? {'status': 'ok'} : demoUser,
          );
        }),
      );
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        MaterialApp(home: ConnectionPage(controller: settings, initial: true)),
      );
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      TextField keyField() => tester.widget<TextField>(fields.at(1));
      expect(keyField().obscureText, isTrue);
      expect(keyField().autocorrect, isFalse);
      expect(keyField().enableSuggestions, isFalse);
      expect(keyField().enableIMEPersonalizedLearning, isFalse);
      expect(keyField().controller!.text, canary);
      await tester.ensureVisible(find.byTooltip('Показать ключ'));
      await tester.tap(find.byTooltip('Показать ключ'));
      await tester.pump();
      expect(keyField().obscureText, isFalse);
      await tester.enterText(fields.at(0), 'https://another.example/api/v1');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(keyField().controller!.text, isEmpty);
      expect(keyField().obscureText, isTrue);
      final check = find.text('Проверить подключение');
      await tester.ensureVisible(check);
      await tester.tap(check);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Введите демонстрационный ключ'),
        findsOneWidget,
      );
      expect(requests, 0);
      await tester.ensureVisible(fields.at(1));
      await tester.enterText(fields.at(1), 'Invalid-Test-Key');
      final save = find.text('Сохранить и применить');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Демонстрационный ключ неверен'),
        findsOneWidget,
      );
      expect(settings.active, isNull);
      expect(vault.values.keys, ['http://127.0.0.1:8000']);
      await tester.ensureVisible(fields.at(1));
      await tester.enterText(fields.at(1), canary);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(settings.active!.origin, 'https://another.example');
      expect(vault.values['https://another.example'], canary);
      expect(find.text('Подключение сохранено и применено.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

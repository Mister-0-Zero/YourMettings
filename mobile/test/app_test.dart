import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:your_mettings/app/your_mettings_app.dart';

void main() {
  testWidgets(
    'starts with new meeting and keeps unsupported actions disabled',
    (tester) async {
      await tester.pumpWidget(const YourMettingsApp());
      expect(find.text('Сохраните главное'), findsNothing);
      expect(find.text('Записать встречу'), findsOneWidget);
      expect(find.text('Загрузить транскрипт'), findsOneWidget);
      for (final title in [
        'Загрузить аудио',
        'Подключиться к видеоконференции',
      ]) {
        await tester.scrollUntilVisible(find.text(title), 150);
        final tile = tester.widget<ListTile>(
          find.ancestor(of: find.text(title), matching: find.byType(ListTile)),
        );
        expect(tile.enabled, isFalse);
        expect(tile.onTap, isNull);
      }
    },
  );

  testWidgets('all four sections can be opened and navigation returns home', (
    tester,
  ) async {
    await tester.pumpWidget(const YourMettingsApp());
    for (final entry in {
      'Встречи': 'Ваши встречи',
      'Инструменты':
          'Шаблоны и дополнительные инструменты будут доступны позже.',
      'Профиль': 'Тестовый профиль',
    }.entries) {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(entry.key),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
    }
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Новая встреча'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Сохраните главное'), findsNothing);
    expect(find.text('Записать встречу'), findsOneWidget);
  });

  testWidgets('transcript entry opens and closes on a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const YourMettingsApp());
    await tester.tap(find.text('Загрузить транскрипт'));
    await tester.pumpAndSettle();
    expect(find.text('Транскрипт встречи'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Сохраните главное'), findsNothing);
    expect(find.text('Записать встречу'), findsOneWidget);
  });
}

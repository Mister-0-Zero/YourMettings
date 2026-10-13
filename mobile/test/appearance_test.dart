import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:your_mettings/app/appearance.dart';
import 'package:your_mettings/app/your_mettings_app.dart';

void main() {
  test('appearance survives restart and sequential rapid changes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'yourmettings-appearance-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/appearance.json');
    final controller = AppearanceController(file: file);
    addTearDown(controller.dispose);
    await Future.wait([
      controller.update(mode: ThemeMode.dark),
      controller.update(color: AccentColor.green),
    ]);
    final restarted = AppearanceController(file: file);
    addTearDown(restarted.dispose);
    await restarted.load();
    expect(restarted.themeMode, ThemeMode.dark);
    expect(restarted.accent, AccentColor.green);
  });

  testWidgets(
    'navigation labels center at narrow/phone/tablet widths in both themes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.viewPadding = const FakeViewPadding(top: 28, bottom: 24);
      tester.platformDispatcher.textScaleFactorTestValue = 1.4;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final width in [320.0, 390.0, 800.0]) {
        for (final mode in [ThemeMode.light, ThemeMode.dark]) {
          tester.view.physicalSize = Size(width, 900);
          final appearance = AppearanceController()..themeMode = mode;
          await tester.pumpWidget(
            YourMettingsApp(
              key: ValueKey('$width-$mode'),
              appearance: appearance,
            ),
          );
          await tester.pumpAndSettle();
          final labels = find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('Новая встреча'),
          );
          expect(
            tester.renderObject<RenderParagraph>(labels).textAlign,
            TextAlign.center,
          );
          expect(tester.getCenter(labels).dx, closeTo(width / 8, 1));
          final appBar = tester.widget<AppBar>(find.byType(AppBar).first);
          expect(
            appBar.centerTitle ??
                Theme.of(tester.element(find.byType(AppBar).first))
                    .appBarTheme
                    .centerTitle,
            isTrue,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          appearance.dispose();
        }
      }
    },
  );

  testWidgets('profile changes theme and accent with one shared UI', (
    tester,
  ) async {
    final appearance = AppearanceController();
    addTearDown(appearance.dispose);
    await tester.pumpWidget(YourMettingsApp(appearance: appearance));
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Профиль'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Системная'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Тёмная').last);
    await tester.pumpAndSettle();
    expect(appearance.themeMode, ThemeMode.dark);
    expect(
      Theme.of(tester.element(find.text('Оформление'))).brightness,
      Brightness.dark,
    );
    await tester.tap(find.text('Синий'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Зелёный').last);
    await tester.pumpAndSettle();
    expect(appearance.accent, AccentColor.green);
    expect(tester.takeException(), isNull);
  });
}

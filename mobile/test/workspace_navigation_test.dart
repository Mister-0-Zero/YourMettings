import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:your_mettings/features/recording/workspace_page.dart';

void main() {
  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets(
        'square workspace blocks and section navigation dark=$dark scale=$scale',
        (tester) async {
          tester.view.physicalSize = const Size(360, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? ThemeData.dark() : ThemeData.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: const Scaffold(body: WorkspacePage()),
            ),
          );
          final tile = find.byKey(const ValueKey('workspace-drafts'));
          final size = tester.getSize(tile);
          expect(size.width, closeTo(size.height, .01));
          await tester.tap(tile);
          await tester.pumpAndSettle();
          expect(find.text('Сохранённых черновиков пока нет.'), findsOneWidget);
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('workspace-templates')),
          );
          await tester.tap(find.byKey(const ValueKey('workspace-templates')));
          await tester.pumpAndSettle();
          expect(
            find.text('Работа с шаблонами пока недоступна.'),
            findsOneWidget,
          );
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('workspace-sharing')),
          );
          await tester.tap(find.byKey(const ValueKey('workspace-sharing')));
          await tester.pumpAndSettle();
          expect(
            find.textContaining('обмен встречами пока недоступны'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

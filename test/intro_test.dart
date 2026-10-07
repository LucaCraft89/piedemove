// First run: three steps, skippable, shown once.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/ui/intro/intro_page.dart';
import 'package:piedemove/ui/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> pump(WidgetTester t) async {
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: darkTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                  onPressed: () => openIntro(context), child: const Text('open')),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  testWidgets('three steps, then "Inizia" marks it seen', (t) async {
    SharedPreferences.setMockInitialValues({});
    expect(await introSeen(), isFalse);
    await pump(t);
    expect(find.text('Viaggi gratis: cammina meno'), findsOneWidget);
    await t.tap(find.text('Avanti'));
    await t.pumpAndSettle();
    expect(find.text('Consenti la posizione'), findsOneWidget);
    await t.tap(find.text('Avanti'));
    await t.pumpAndSettle();
    expect(find.text('Imposta Casa'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.tap(find.text('Inizia'));
    await t.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
    expect(await introSeen(), isTrue);
  });

  testWidgets('"Salta" ends it at once', (t) async {
    SharedPreferences.setMockInitialValues({});
    await pump(t);
    await t.tap(find.text('Salta'));
    await t.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
    expect(await introSeen(), isTrue);
  });
}

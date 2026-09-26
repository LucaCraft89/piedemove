// Casa / Lavoro: a long press opens change / remove (the chip's tooltip used
// to take the long press, so it never did).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/places/photon.dart';
import 'package:piedemove/places/shortcuts.dart';
import 'package:piedemove/ui/home/home_page.dart';
import 'package:piedemove/ui/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('long press offers change and remove; remove clears it',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(shortcutPlacesProvider.notifier).set(Shortcut.home,
        const Place(name: 'Casa mia', address: '', lat: 45.07, lon: 7.68));
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: darkTheme(),
        home: const Scaffold(body: Center(child: ShortcutChip(Shortcut.home))),
      ),
    ));
    expect(find.text('Casa'), findsOneWidget);
    await t.longPress(find.text('Casa'));
    await t.pumpAndSettle();
    expect(find.text('Cambia Casa'), findsOneWidget);
    expect(find.text('Rimuovi Casa'), findsOneWidget);
    await t.tap(find.text('Rimuovi Casa'));
    await t.pumpAndSettle();
    expect(container.read(shortcutPlacesProvider)[Shortcut.home], isNull);
    expect(find.text('Casa +'), findsOneWidget);
  });
}

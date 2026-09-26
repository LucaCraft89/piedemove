// Casa / Lavoro are kept across restarts; a stop keeps being a stop.
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/places/photon.dart';
import 'package:piedemove/places/shortcuts.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('set, restart, read back; clear removes one only', () async {
    SharedPreferences.setMockInitialValues({});
    final a = ShortcutPlaces();
    a.set(Shortcut.home,
        const Place(name: 'Casa mia', address: 'Via Roma 1', lat: 45.07, lon: 7.68));
    a.set(Shortcut.work,
        const Place(name: 'POLITECNICO', address: 'Fermate 1 · 2', lat: 45.06,
            lon: 7.66, stop: true));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final b = ShortcutPlaces();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(b.state[Shortcut.home]!.name, 'Casa mia');
    expect(b.state[Shortcut.work]!.stop, isTrue);

    b.clear(Shortcut.home);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final c = ShortcutPlaces();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.state.containsKey(Shortcut.home), isFalse);
    expect(c.state[Shortcut.work], isNotNull);
  });
}

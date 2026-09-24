import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/ui/map/map_focus.dart';
import 'package:piedemove/ui/nav/entity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('focus survives sheet steps; only close and cancella clear it', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(focusProvider); // alive, so it listens
    final nav = c.read(entityNavProvider.notifier);

    nav.push(const LineRef(7));
    expect(c.read(focusProvider), const RouteFocus(7));

    nav.push(const StopRef(1)); // a stop sheet keeps the line focused
    expect(c.read(focusProvider), const RouteFocus(7));
    nav.pop();
    expect(c.read(focusProvider), const RouteFocus(7));

    c.read(focusProvider.notifier).close();
    expect(c.read(focusProvider), isNull);
    expect(c.read(entityNavProvider), isEmpty);

    nav.push(const LineRef(3));
    expect(c.read(focusProvider.notifier).needsConfirm, isFalse);
    c.read(focusProvider.notifier).cancella();
    expect(c.read(focusProvider), isNull);
  });
}

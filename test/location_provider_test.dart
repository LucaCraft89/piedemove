// The location provider closes cleanly with its scope (audit 2026-09: the
// controller used to be disposed twice, which threw on app shutdown).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/location/device_location.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('disposing the scope disposes the controller once', () async {
    final container = ProviderContainer();
    container.read(locationProvider);
    await Future<void>.delayed(Duration.zero);
    expect(container.dispose, returnsNormally);
  });
}

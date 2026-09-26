// Live trip settings survive a save and stay in range.
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/settings/settings.dart';

void main() {
  test('warn stops and sound round-trip; out of range is clamped', () {
    const s = PmSettings(alightWarnStops: 2, alightSound: true);
    final back = PmSettings.fromJson(s.toJson());
    expect(back.alightWarnStops, 2);
    expect(back.alightSound, isTrue);
    expect(PmSettings.fromJson(const {}).alightWarnStops, 1);
    expect(PmSettings.fromJson(const {'warnStops': 9}).alightWarnStops, 2);
    expect(const PmSettings().copyWith(alightWarnStops: 0).alightWarnStops, 1);
  });
}

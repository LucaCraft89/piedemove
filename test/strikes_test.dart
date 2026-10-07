// The strike banner: GTT strike alerts, the next one within two days.
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/realtime/gtfs_rt.dart';
import 'package:piedemove/realtime/strikes.dart';

RtAlert _alert(String id,
        {int? cause,
        String header = '',
        List<(DateTime?, DateTime?)> periods = const []}) =>
    RtAlert(
      id: id,
      header: header,
      description: '',
      cause: cause,
      effect: null,
      routeIds: const {},
      stopIds: const {},
      tripIds: const {},
      from: periods.firstOrNull?.$1,
      to: periods.firstOrNull?.$2,
      periods: periods,
    );

void main() {
  final now = DateTime(2026, 10, 7, 12); // a Wednesday

  test('a strike by cause or by its words', () {
    expect(isStrike(_alert('a', cause: rtCauseStrike)), isTrue);
    expect(isStrike(_alert('b', header: 'SCIOPERO nazionale di 24 ore')), isTrue);
    expect(isStrike(_alert('c', header: 'Deviazione linea 2')), isFalse);
  });

  test('the earliest strike within two days; ended or far ones ignored', () {
    final fri = DateTime(2026, 10, 9, 8, 30);
    final s = nextStrike([
      _alert('ended', cause: 4, periods: [(DateTime(2026, 10, 1), DateTime(2026, 10, 2))]),
      _alert('far', cause: 4, periods: [(DateTime(2026, 10, 20), null)]),
      _alert('fri', cause: 4, periods: [(fri, DateTime(2026, 10, 9, 23))]),
      _alert('detour', header: 'Deviazione'),
    ], now)!;
    expect(s.$1.id, 'fri');
    expect(strikeLabel(s.$2, now), 'Sciopero ven 09/10 dalle 08:30');
    expect(nextStrike([_alert('far', cause: 4, periods: [(DateTime(2026, 10, 20), null)])], now),
        isNull);
  });

  test('labels: in progress, today, tomorrow', () {
    expect(strikeLabel(now, now), 'Sciopero in corso');
    expect(strikeLabel(DateTime(2026, 10, 7, 18), now), 'Sciopero oggi dalle 18:00');
    expect(strikeLabel(DateTime(2026, 10, 8, 8, 30), now),
        'Sciopero domani dalle 08:30');
    final active = nextStrike([
      _alert('now', cause: 4, periods: [(DateTime(2026, 10, 7, 8), DateTime(2026, 10, 7, 20))]),
    ], now)!;
    expect(strikeLabel(active.$2, now), 'Sciopero in corso');
  });
}

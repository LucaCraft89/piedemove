/// Phase 9: the regional merge rules — snap covered stops, drop fully covered
/// routes, keep everything else as scheduled only.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/index_io.dart';
import 'package:piedemove/data/index_merge.dart';
import 'package:piedemove/data/transit_index.dart';

import 'support/synthetic.dart';

// ~0.0009 deg lat is ~100 m: inside the 150 m snap radius.
const _near = 0.0009;
const _far = 0.05; // ~5 km

TransitIndex _gtt() => syntheticIndex(
      stops: [
        ('a', 'TRAPANI', 45.0692, 7.6376),
        ('b', 'PESCHIERA', 45.0694, 7.6388),
      ],
      patterns: [
        ('2', RouteType.tram, ['a', 'b'], [
          [28800, 28900]
        ]),
      ],
    );

void main() {
  test('covered regional stops become their GTT stop', () {
    final regional = syntheticIndex(
      stops: [
        ('x', 'TRAPANI EXTRA', 45.0692 + _near, 7.6376),
        ('y', 'CHIERI', 45.0692 + _far, 7.6376),
      ],
      patterns: [
        ('268', RouteType.bus, ['x', 'y'], [
          [30000, 32000]
        ]),
      ],
    );

    final merged = mergeRegional(_gtt(), regional);

    // One new stop only: the covered one collapsed onto GTT stop 0.
    expect(merged.stopCount, 3);
    expect(merged.stopIds.last, 'R:y');
    expect(merged.routeCount, 2);
    expect(merged.isScheduledOnly(1), isTrue);
    expect(merged.isScheduledOnly(0), isFalse);

    // The regional pattern boards at the GTT stop: that is the transfer.
    final p = merged.patternCount - 1;
    expect(merged.patternStopAt(p, 0), 0);
    expect(merged.patternStopAt(p, 1), 2);

    // ... and the GTT stop now lists both patterns.
    expect(merged.routesAt(0).length, 2);

    // Times survive the copy.
    final trip = merged.patternTripAt(p, 0);
    expect(merged.depOf(trip, 0), 30000);
    expect(merged.arrOf(trip, 1), 32000);
    expect(merged.serviceRunsOn(merged.tripService[trip], 1), isTrue);
  });

  test('a regional route with no uncovered stop is dropped', () {
    final regional = syntheticIndex(
      stops: [
        ('x', 'TRAPANI EXTRA', 45.0692 + _near, 7.6376),
        ('y', 'PESCHIERA EXTRA', 45.0694, 7.6388 + _near),
      ],
      patterns: [
        ('999', RouteType.bus, ['x', 'y'], [
          [30000, 32000]
        ]),
      ],
    );

    final merged = mergeRegional(_gtt(), regional);
    expect(merged.routeCount, 1);
    expect(merged.stopCount, 2);
    expect(merged.patternCount, 1);
    expect(merged.tripCount, 1);
  });

  test('the merged index round-trips through index.bin', () {
    final regional = syntheticIndex(
      stops: [
        ('x', 'TRAPANI EXTRA', 45.0692 + _near, 7.6376),
        ('y', 'CHIERI', 45.0692 + _far, 7.6376),
      ],
      patterns: [
        ('268', RouteType.bus, ['x', 'y'], [
          [30000, 32000]
        ]),
      ],
      serviceStartDay: 19995, // a different window: it must be rebased
    );

    final merged = mergeRegional(_gtt(), regional);
    final back = decodeIndex(encodeIndex(merged));
    expect(back.routeFeed, merged.routeFeed);
    expect(back.stopIds, merged.stopIds);
    expect(back.serviceDayCount, merged.serviceDayCount);
    expect(back.serviceStartDay, 19995);

    // Both calendars still say "runs", each on its own days.
    final regionalTrip = back.tripCount - 1;
    expect(
      back.serviceRunsOn(back.tripService[regionalTrip], 1),
      isTrue,
    );
    expect(back.serviceRunsOn(back.tripService[0], 19995 - 19995 + 5), isTrue);
  });
}

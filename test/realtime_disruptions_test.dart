// Realtime audit fixes: cancellations, skipped stops, alert periods and
// stop_sequence numbers with gaps.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/index_io.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/realtime/gtfs_rt.dart';
import 'package:piedemove/realtime/link.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/routing/departures.dart';
import 'package:piedemove/routing/footpaths.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/routing/raptor.dart';

import 'support/synthetic.dart';

List<int> _varint(int value) {
  final out = <int>[];
  var v = value;
  do {
    var byte = v & 0x7f;
    v = v >>> 7;
    if (v != 0) byte |= 0x80;
    out.add(byte);
  } while (v != 0);
  return out;
}

List<int> _tag(int field, int wire) => _varint(field << 3 | wire);
List<int> _int(int field, int value) => [..._tag(field, 0), ..._varint(value)];
List<int> _bytes(int field, List<int> payload) =>
    [..._tag(field, 2), ..._varint(payload.length), ...payload];
List<int> _string(int field, String value) => _bytes(field, utf8.encode(value));

RtTripUpdate _update(String tripId,
        {bool canceled = false,
        Set<int> skipped = const {},
        Map<int, int> delays = const {},
        String? startDate}) =>
    RtTripUpdate(
      tripId: tripId,
      routeId: null,
      startDate: startDate,
      tripDelay: null,
      byStopId: const {},
      delayBySequence: delays,
      timeBySequence: const {},
      timestamp: null,
      canceled: canceled,
      skippedSequences: skipped,
    );

void main() {
  test('decodes a cancelled trip and a skipped stop', () {
    final feed = decodeFeed(Uint8List.fromList([
      ..._bytes(2, [
        ..._string(1, 'e1'),
        ..._bytes(3, [
          ..._bytes(1, [..._string(1, 'trip-1'), ..._int(4, 3)]), // CANCELED
        ]),
      ]),
      ..._bytes(2, [
        ..._string(1, 'e2'),
        ..._bytes(3, [
          ..._bytes(1, [..._string(1, 'trip-2')]),
          ..._bytes(2, [..._int(1, 3), ..._string(4, 'S3'), ..._int(5, 1)]),
          ..._bytes(2, [..._int(1, 4), ..._bytes(3, _int(1, 60))]),
        ]),
      ]),
    ]));
    final byId = {for (final u in feed.tripUpdates) u.tripId: u};
    expect(byId['trip-1']!.canceled, isTrue);
    expect(byId['trip-2']!.canceled, isFalse);
    expect(byId['trip-2']!.skippedSequences, {3});
    expect(byId['trip-2']!.skippedStopIds, {'S3'});
    expect(byId['trip-2']!.delayBySequence, {4: 60});
  });

  test('an alert is active in any of its periods, not just the first', () {
    int at(int h) => DateTime(2026, 9, 24, h).millisecondsSinceEpoch ~/ 1000;
    final feed = decodeFeed(Uint8List.fromList([
      ..._bytes(2, [
        ..._string(1, 'a1'),
        ..._bytes(5, [
          ..._bytes(1, [..._int(1, at(7)), ..._int(2, at(9))]),
          ..._bytes(1, [..._int(1, at(17)), ..._int(2, at(19))]),
        ]),
      ]),
    ]));
    final a = feed.alerts.single;
    expect(a.activeAt(DateTime(2026, 9, 24, 8)), isTrue);
    expect(a.activeAt(DateTime(2026, 9, 24, 12)), isFalse);
    expect(a.activeAt(DateTime(2026, 9, 24, 18)), isTrue);
  });

  group('stop_sequence with gaps', () {
    final ix = syntheticIndex(
      stops: [
        ('A', 'A', 45.0, 7.6),
        ('B', 'B', 45.01, 7.6),
        ('C', 'C', 45.02, 7.6),
      ],
      patterns: [
        ('2', RouteType.tram, ['A', 'B', 'C'], [
          [0, 60, 120],
        ]),
      ],
      stopSequences: {
        0: [10, 20, 30],
      },
    );

    test('a delay keyed by sequence lands on the right position', () {
      final rt = RealtimeState(
          tripUpdates: {ix.tripIds.first: _update(ix.tripIds.first, delays: {20: 90})});
      final delay = buildDelayLookup(ix, rt);
      expect(delay(0, 0), isNull);
      expect(delay(0, 1), 90);
    });

    test('a vehicle position follows the stored sequence', () {
      const v = RtVehicle(
        id: 'v', label: null, tripId: null, routeId: null,
        lat: 45.0, lon: 7.6, bearing: null,
        stopSequence: 30, stopId: null,
        status: VehicleStatus.inTransitTo, timestamp: null,
      );
      expect(vehiclePosition(ix, 0, v), 2);
    });

    test('sequences survive the binary round trip', () {
      final back = decodeIndex(encodeIndex(ix));
      expect(back.stopSequenceAt(0, 2), 30);
    });
  });

  group('cancelled and skipped runs', () {
    final ix = syntheticIndex(
      stops: [
        ('A', 'ALFA', 45.0000, 7.6000),
        ('C', 'CHARLIE', 45.0200, 7.6000),
      ],
      patterns: [
        ('1', 3, ['A', 'C'], [
          [8 * 3600, 8 * 3600 + 600],
          [8 * 3600 + 900, 8 * 3600 + 1500],
        ]),
      ],
    );
    final date = syntheticDate();
    final today = DateTime(date.year, date.month, date.day);
    final rt = RealtimeState(
        tripUpdates: {ix.tripIds[0]: _update(ix.tripIds[0], canceled: true)});
    final unavailable = buildUnavailableLookup(ix, rt, today);

    test('the lookup applies to the reported day only', () {
      expect(unavailable(0, 0), isTrue);
      expect(unavailable(1, 0), isFalse);
      final other = RealtimeState(tripUpdates: {
        ix.tripIds[0]: _update(ix.tripIds[0], canceled: true, startDate: '19991231'),
      });
      expect(buildUnavailableLookup(ix, other, today)(0, 0), isFalse);
    });

    test('a cancelled run is not listed as a departure', () {
      final next = nextDepartures(
          ix, 0, today.add(const Duration(hours: 7, minutes: 50)), 5,
          unavailable: unavailable);
      expect(next.map((d) => d.trip), [1]);
    });

    test('the planner rides the next run instead', () {
      final js = Planner(ix, Footpaths.build(ix)).plan(PlanRequest(
        originLat: 45.0,
        originLon: 7.6,
        destLat: 45.02,
        destLon: 7.6,
        when: today.add(const Duration(hours: 7, minutes: 50)),
        unavailable: unavailable,
      ));
      final ride = js.first.legs.firstWhere((l) => l.kind == LegKind.ride);
      expect(ride.departure, 8 * 3600 + 900);
      expect(ride.options.every((o) => o.trip != 0), isTrue);
    });

    test('a skipped alight stop is not ridden to', () {
      final skip = RealtimeState(tripUpdates: {
        ix.tripIds[0]: _update(ix.tripIds[0], skipped: {2}),
      });
      final js = Planner(ix, Footpaths.build(ix)).plan(PlanRequest(
        originLat: 45.0,
        originLon: 7.6,
        destLat: 45.02,
        destLon: 7.6,
        when: today.add(const Duration(hours: 7, minutes: 50)),
        unavailable: buildUnavailableLookup(ix, skip, today),
      ));
      final ride = js.first.legs.firstWhere((l) => l.kind == LegKind.ride);
      expect(ride.arrival, 8 * 3600 + 1500);
    });
  });
}

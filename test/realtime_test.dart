/// Realtime: the hand-rolled protobuf reader, the GTFS-RT mapping and the
/// carry-forward delay lookup. Feeds are encoded here on the wire format, so
/// the test fails if either side of the decoder drifts.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/realtime/gtfs_rt.dart';
import 'package:piedemove/realtime/store.dart';

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

List<int> _float(int field, double value) => [
      ..._tag(field, 5),
      ...(ByteData(4)..setFloat32(0, value, Endian.little))
          .buffer
          .asUint8List(),
    ];

List<int> _translated(int field, String text, String language) =>
    _bytes(field, _bytes(1, [..._string(1, text), ..._string(2, language)]));

void main() {
  test('decodes a vehicle position', () {
    final feed = decodeFeed(Uint8List.fromList([
      ..._bytes(1, _int(3, 1700000000)), // header.timestamp
      ..._bytes(2, [
        ..._string(1, 'e1'),
        ..._bytes(4, [
          ..._bytes(1, [..._string(1, 'trip-7'), ..._string(5, 'route-2')]),
          ..._bytes(2, [
            ..._float(1, 45.0692),
            ..._float(2, 7.6376),
            ..._float(3, 91.5),
          ]),
          ..._int(3, 4), // current_stop_sequence
          ..._string(7, 'stop-3'),
          ..._int(4, 1), // STOPPED_AT
          ..._int(5, 1700000123),
          ..._bytes(8, [..._string(1, 'v42'), ..._string(2, '4242')]),
        ]),
      ]),
    ]));

    expect(feed.vehicles, hasLength(1));
    final v = feed.vehicles.single;
    expect(v.id, 'v42');
    expect(v.label, '4242');
    expect(v.tripId, 'trip-7');
    expect(v.routeId, 'route-2');
    expect(v.lat, closeTo(45.0692, 1e-4));
    expect(v.lon, closeTo(7.6376, 1e-4));
    expect(v.bearing, closeTo(91.5, 1e-3));
    expect(v.stopSequence, 4);
    expect(v.stopId, 'stop-3');
    expect(v.status, VehicleStatus.stoppedAt);
    expect(feed.timestamp, DateTime.fromMillisecondsSinceEpoch(1700000000000));
  });

  test('decodes a trip update, negative delays included', () {
    final feed = decodeFeed(Uint8List.fromList([
      ..._bytes(2, [
        ..._string(1, 'e2'),
        ..._bytes(3, [
          ..._bytes(1, _string(1, 'trip-7')),
          ..._bytes(2, [
            ..._int(1, 2), // stop_sequence
            ..._string(4, 'B'),
            ..._bytes(3, _int(1, 120)), // departure.delay
          ]),
          ..._bytes(2, [
            ..._int(1, 3),
            ..._string(4, 'C'),
            ..._bytes(2, _int(1, -30)), // arrival.delay, no departure
          ]),
          ..._int(5, 60), // TripUpdate.delay
        ]),
      ]),
    ]));

    final u = feed.tripUpdates.single;
    expect(u.tripId, 'trip-7');
    expect(u.byStopId, {'B': 120, 'C': -30});
    expect(u.delayBySequence, {2: 120, 3: -30});
    expect(u.tripDelay, 60);
  });

  test('alert prefers the Italian translation and reads its entities', () {
    final feed = decodeFeed(Uint8List.fromList([
      ..._bytes(2, [
        ..._string(1, 'a1'),
        ..._bytes(5, [
          ..._bytes(1, [..._int(1, 1700000000), ..._int(2, 1700003600)]),
          ..._bytes(5, _string(2, 'route-2')),
          ..._bytes(5, _string(5, 'stop-3')),
          ..._int(6, 4), // STRIKE
          ..._int(7, 1), // NO_SERVICE
          ..._translated(10, 'Sciopero', 'it'),
          ..._bytes(11, [
            ..._bytes(1, [..._string(1, 'Strike'), ..._string(2, 'en')]),
            ..._bytes(1, [..._string(1, 'Servizio sospeso'), ..._string(2, 'it')]),
          ]),
        ]),
      ]),
    ]));

    final a = feed.alerts.single;
    expect(a.header, 'Sciopero');
    expect(a.description, 'Servizio sospeso');
    expect(a.cause, 4);
    expect(a.effect, 1);
    expect(a.routeIds, {'route-2'});
    expect(a.stopIds, {'stop-3'});
    expect(a.activeAt(DateTime.fromMillisecondsSinceEpoch(1700001000000)), isTrue);
    expect(a.activeAt(DateTime.fromMillisecondsSinceEpoch(1700009000000)), isFalse);
  });

  test('a stop_time_update delay carries forward to later stops', () {
    final ix = syntheticIndex(
      stops: [
        ('A', 'A', 45.0, 7.6),
        ('B', 'B', 45.01, 7.6),
        ('C', 'C', 45.02, 7.6),
        ('D', 'D', 45.03, 7.6),
      ],
      patterns: [
        ('2', RouteType.tram, ['A', 'B', 'C', 'D'], [
          [0, 60, 120, 180],
          [600, 660, 720, 780],
        ]),
      ],
    );
    final rt = RealtimeState(tripUpdates: {
      ix.tripIds.first: const RtTripUpdate(
        tripId: 't0-0',
        routeId: null,
        startDate: null,
        tripDelay: 15,
        byStopId: {},
        // GTT numbers stops from 1: position 1 is sequence 2.
        delayBySequence: {2: 120},
        timeBySequence: {},
        timestamp: null,
      ),
    });
    final delay = buildDelayLookup(ix, rt);

    expect(delay(0, 0), 15, reason: 'before the first update: TripUpdate.delay');
    expect(delay(0, 1), 120);
    expect(delay(0, 3), 120, reason: 'carried forward to every later stop');
    expect(delay(1, 0), isNull, reason: 'no trip id in the feed');
  });

  test('an absolute stop time becomes a delay against the schedule', () {
    final ix = syntheticIndex(
      stops: [('A', 'A', 45.0, 7.6), ('B', 'B', 45.01, 7.6)],
      patterns: [
        ('2', RouteType.tram, ['A', 'B'], [
          [8 * 3600, 8 * 3600 + 300],
        ]),
      ],
    );
    final day = DateTime(2026, 9, 19);
    final rt = RealtimeState(tripUpdates: {
      ix.tripIds.first: RtTripUpdate(
        tripId: ix.tripIds.first,
        routeId: null,
        startDate: '20260919',
        tripDelay: null,
        byStopId: const {},
        delayBySequence: const {},
        // B is due 08:05 and the feed says 08:07: two minutes late.
        timeBySequence: {
          2: day.add(const Duration(hours: 8, minutes: 7)).millisecondsSinceEpoch ~/
              1000,
        },
        timestamp: null,
      ),
    });

    expect(buildDelayLookup(ix, rt)(0, 1), 120);
  });

  test('a feed with no answer yet counts as stale', () {
    const state = RealtimeState();
    expect(state.staleFeeds(), RtFeedKind.values);
  });
}

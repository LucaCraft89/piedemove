/// Phase 6a: the progress engine on a routed walk leg: segment projection,
/// monotone progress, 60 m cutoff, split, strip text, reroute, and a replay
/// of a recorded (noisy) track.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/geo/walk_graph.dart';
import 'package:piedemove/geo/walk_router.dart';
import 'package:piedemove/location/live_trip.dart';
import 'package:piedemove/routing/journey.dart';

// ~1.1 km path with a dog-leg: north 500 m, east ~200 m, north 500 m.
const _lon = 7.6;
final _router = WalkRouter(WalkGraph.build(
  nodeLat: [4500000, 4501000],
  nodeLon: [760000, 760000],
  edges: [
    WalkEdgeSpec(0, 1, WalkFlags.make(WalkKind.path),
        geom: [4500450, 760000, 4500450, 760300, 4500550, 760300, 4500550, 760000]),
  ],
  osmTime: 1,
  bbox: [4499000, 759000, 4503000, 761000],
));

LiveTripState _start() {
  final route = _router.route(45.0, _lon, 45.01, _lon)!;
  final leg = LiveLeg(
    kind: LegKind.walk,
    lat: [for (final p in route.polyline) p[1]],
    lon: [for (final p in route.polyline) p[0]],
    cumulative: const [],
    stopVertex: [route.polyline.length - 1],
    stopNames: const ['Dest'],
    departure: 0,
    arrival: 900,
    maneuvers: route.maneuvers,
  );
  return _from(leg);
}

LiveTripState _from(LiveLeg raw) {
  // recompute cumulative through the public constructor path
  final cum = <double>[0];
  for (var i = 1; i < raw.lat.length; i++) {
    cum.add(cum[i - 1] + _m(raw.lat[i - 1], raw.lon[i - 1], raw.lat[i], raw.lon[i]));
  }
  final leg = LiveLeg(
      kind: raw.kind,
      lat: raw.lat,
      lon: raw.lon,
      cumulative: cum,
      stopVertex: raw.stopVertex,
      stopNames: raw.stopNames,
      departure: 0,
      arrival: 900,
      maneuvers: raw.maneuvers);
  return LiveTripState(
      route: LiveRoute([leg]),
      journey: Journey([], DateTime(2026, 9, 24)),
      metresToEnd: leg.metres);
}

double _m(double a, double b, double c, double d) =>
    ((c - a).abs() * 110540) + ((d - b).abs() * 78700);

LiveFix _fix(double lat, double lon, {double acc = 8}) => LiveFix(
    lat: lat, lon: lon, accuracy: acc, speed: 1.2, at: DateTime(2026, 9, 24, 9));

void main() {
  test('projection is forward-only and lands between vertices', () {
    var s = _start();
    final leg = s.leg;
    final mid = (leg.lat[0] + leg.lat[1]) / 2;
    s = advanceLive(s, _fix(mid, leg.lon[0]));
    expect(s.along, closeTo(leg.cumulative[1] / 2, 2));
    final a = s.along;
    s = advanceLive(s, _fix(leg.lat[0], leg.lon[0])); // behind the rider
    expect(s.along, a);
  });

  test('beyond 60 m keeps progress and says estimated', () {
    var s = _start();
    final leg = s.leg;
    s = advanceLive(s, _fix(leg.lat[1], leg.lon[1]));
    final a = s.along;
    s = advanceLive(s, _fix(leg.lat[1] + 0.005, leg.lon[1] + 0.01));
    expect(s.estimated, isTrue);
    expect(s.along, a);
  });

  test('split joins at the rider, strip text and next maneuver', () {
    var s = _start();
    final leg = s.leg;
    s = advanceLive(s, _fix((leg.lat[0] + leg.lat[1]) / 2, leg.lon[0]));
    final sp = splitLeg(leg, s.along);
    expect(sp.travelled.last, sp.ahead.first);
    expect(sp.ahead.last, [leg.lon.last, leg.lat.last]);
    expect(sp.travelled.first, [leg.lon.first, leg.lat.first]);
    expect(walkStripText(s), startsWith('Cammina ancora '));
    expect(walkStripText(s), endsWith('fino a Dest'));
    expect(nextManeuver(leg, s.vertex), isNotNull);
  });

  test('advances within 25 m of the walk end', () {
    var s = _start();
    final leg = s.leg;
    s = advanceLive(s, _fix(leg.lat.last, leg.lon.last));
    expect(s.finished, isTrue);
  });

  test('reroute swaps the leg with fresh progress', () {
    final s = _start();
    final r = rerouteWalkLeg(s, 45.0005, _lon + 0.001, _router,
        _router.route(45.0, _lon, 45.01, _lon)!);
    expect(r, isNotNull);
    expect(r!.along, 0);
    expect(r.leg.maneuvers, isNotEmpty);
  });

  test('replay: noisy recorded track never rewinds and ends the leg', () {
    var s = _start();
    final leg = s.leg;
    var prev = 0.0;
    for (var i = 0; i < leg.lat.length - 1; i++) {
      for (var k = 0; k < 10; k++) {
        final t = k / 10;
        // deterministic jitter of a few metres, with an occasional step back
        final jitter = ((i * 10 + k) % 3 - 1) * 0.00003;
        final back = (k == 5) ? -0.05 : 0.0;
        s = advanceLive(
            s,
            _fix(leg.lat[i] + (leg.lat[i + 1] - leg.lat[i]) * (t + back) + jitter,
                leg.lon[i] + (leg.lon[i + 1] - leg.lon[i]) * (t + back)));
        if (s.finished) break;
        expect(s.along, greaterThanOrEqualTo(prev));
        prev = s.along;
      }
    }
    s = s.finished ? s : advanceLive(s, _fix(leg.lat.last, leg.lon.last));
    expect(s.finished, isTrue);
  });
}

/// The router on real OSM data: a committed fixture graph of central Turin
/// (Porta Nuova -> Politecnico) and the stops inside it. Offline, no index.
///
/// Rebuild the fixture with
///     dart tool/build_walk.dart --bbox 45.05,7.63,45.078,7.69
///       --input (the cached tiles covering it) --asset ""
///       --out test/fixtures/walk_fixture.pmwg.gz
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/geo/distance.dart';
import 'package:piedemove/geo/walk_graph.dart';
import 'package:piedemove/geo/walk_router.dart';

/// Every stop of the fixture area must sit this close to a walkable edge.
const maxStopSnapMetres = 60.0;

void main() {
  final fixture = File('test/fixtures/walk_fixture.pmwg.gz');
  late WalkGraph graph;
  late WalkRouter router;
  late List<List<double>> stops;

  setUpAll(() {
    graph = WalkGraph.decode(Uint8List.fromList(gzip.decode(fixture.readAsBytesSync())));
    router = WalkRouter(graph);
    stops = [
      for (final s in jsonDecode(File('test/fixtures/walk_stops.json').readAsStringSync()) as List)
        [(s[0] as num).toDouble(), (s[1] as num).toDouble()]
    ];
  });

  test('the fixture is a valid v1 graph with a sane size', () {
    expect(graph.header.format, walkGraphFormat);
    expect(graph.nodeCount, greaterThan(5000));
    expect(graph.edgeCount, greaterThan(5000));
    expect(fixture.lengthSync(), lessThan(400 * 1024));
    // one big connected pedestrian network, not confetti
    final biggest = graph.componentEdges.reduce((a, b) => a > b ? a : b);
    expect(biggest, greaterThan(graph.edgeCount * 0.9));
    // all three crossing kinds and steps exist in a real city
    final kinds = <int>{};
    final crossTypes = <int>{};
    for (var e = 0; e < graph.edgeCount; e++) {
      kinds.add(WalkFlags.kind(graph.edgeFlags[e]));
      if (WalkFlags.kind(graph.edgeFlags[e]) == WalkKind.crossing) {
        crossTypes.add(WalkFlags.sub(graph.edgeFlags[e]));
      }
    }
    expect(kinds, containsAll([WalkKind.path, WalkKind.street, WalkKind.side, WalkKind.crossing]));
    expect(crossTypes, containsAll([WalkCrossing.signals, WalkCrossing.unmarked]));
  });

  test('every stop of the area snaps onto the network', () {
    var worst = 0.0;
    for (final s in stops) {
      final snap = router.snap(s[0], s[1], maxMetres: maxStopSnapMetres);
      expect(snap, isNotNull, reason: 'stop at ${s[0]},${s[1]} is off the graph');
      if (snap!.connector > worst) worst = snap.connector;
    }
    // ignore: avoid_print
    print('stops ${stops.length}, worst snap ${worst.toStringAsFixed(1)} m');
  });

  test('Porta Nuova -> Politecnico follows the streets, not a chord', () {
    const aLat = 45.0616, aLon = 7.6780; // Torino Porta Nuova
    const bLat = 45.0626, bLon = 7.6630; // Politecnico
    final sw = Stopwatch()..start();
    final route = router.route(aLat, aLon, bLat, bLon)!;
    sw.stop();
    final straight = haversineMetres(aLat, aLon, bLat, bLon);
    final ratio = route.metres / straight;
    // ignore: avoid_print
    print('straight ${straight.round()} m, walked ${route.metres.round()} m '
        '(x${ratio.toStringAsFixed(2)}), ${sw.elapsedMilliseconds} ms');
    expect(ratio, inInclusiveRange(1.03, 1.5));
    // the polyline is a walkable path: consecutive points close together
    for (var i = 1; i < route.polyline.length; i++) {
      final p = route.polyline[i - 1], q = route.polyline[i];
      expect(haversineMetres(p[1], p[0], q[1], q[0]), lessThan(400));
    }
    // a walk of 1.2 km in a city crosses streets
    expect(route.maneuvers.where((m) => m.type == ManeuverType.cross), isNotEmpty);
    expect(route.maneuvers.first.type, ManeuverType.start);
    expect(route.maneuvers.last.type, ManeuverType.arrive);
    var sum = 0.0;
    for (final m in route.maneuvers) {
      sum += m.metres;
    }
    expect(sum, closeTo(route.metres, 1));
    for (final m in route.maneuvers) {
      // ignore: avoid_print
      print('  $m');
    }
    // and back again is about as long (a symmetric metric)
    final back = router.route(bLat, bLon, aLat, aLon)!;
    expect(back.metres, closeTo(route.metres, route.metres * 0.05));
  });

  test('route times over many stop pairs stay interactive', () {
    final sw = Stopwatch()..start();
    var n = 0, failed = 0;
    for (var i = 0; i + 40 < stops.length && n < 40; i += 7) {
      final a = stops[i], b = stops[i + 40];
      if (haversineMetres(a[0], a[1], b[0], b[1]) > 1500) continue;
      n++;
      if (router.route(a[0], a[1], b[0], b[1]) == null) failed++;
    }
    expect(n, greaterThan(10));
    expect(failed, 0);
    // ignore: avoid_print
    print('$n routes, ${(sw.elapsedMilliseconds / n).toStringAsFixed(1)} ms each (VM)');
    expect(sw.elapsedMilliseconds / n, lessThan(300));
  });
}

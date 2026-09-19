/// Finds the trips where a footpath transfer between two *different* stops cuts
/// walking. Each sampled origin/destination pair is planned twice: once with
/// the real footpath table, once with transfers restricted to a stop itself.
/// Pairs where the footpath version saves >= 100 m are printed, worst first —
/// the top ones are worth pinning as tests (§15.1).
///
///     dart tool/discover_hops.dart [pairs] [seed]
library;

import 'dart:io';
import 'dart:math';

import 'package:piedemove/data/clustering.dart';
import 'package:piedemove/data/index_io.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/routing/footpaths.dart';
import 'package:piedemove/routing/raptor.dart';

Future<void> main(List<String> args) async {
  final pairs = args.isNotEmpty ? int.parse(args[0]) : 150;
  final rng = Random(args.length > 1 ? int.parse(args[1]) : 7);

  final ix = await readIndexFile('build/index.bin');
  if (ix == null) {
    stdout.writeln('no build/index.bin — run `dart tool/build_index.dart` first');
    return;
  }

  final withFootpaths = Planner(ix, Footpaths.build(ix));
  // Every stop its own cluster and a 1 m radius: no transfer between distinct
  // stops survives, which is the "walk from where the bus drops you" baseline.
  final lonely = StopClusters(
    List.generate(ix.stopCount, (i) => i),
    List.generate(ix.stopCount, (i) => [i]),
    ix.stopNames,
  );
  final without =
      Planner(ix, Footpaths.build(ix, radius: 1, clusters: lonely));

  var day = DateTime.now();
  while (day.weekday > DateTime.friday) {
    day = day.add(const Duration(days: 1));
  }
  final when = DateTime(day.year, day.month, day.day, 18);

  double? bestWalk(Planner p, int from, int to) {
    final journeys = p.plan(PlanRequest(
      originLat: ix.stopLat[from],
      originLon: ix.stopLon[from],
      destLat: ix.stopLat[to],
      destLon: ix.stopLon[to],
      when: when,
    ));
    if (journeys.isEmpty) return null;
    return sortBalanced(journeys).first.walkMetres;
  }

  final wins = <(double, String)>[];
  for (var i = 0; i < pairs; i++) {
    final from = rng.nextInt(ix.stopCount);
    final to = rng.nextInt(ix.stopCount);
    if (from == to) continue;
    final a = bestWalk(withFootpaths, from, to);
    final b = bestWalk(without, from, to);
    if (a == null || b == null) continue;
    final saved = b - a;
    if (saved < 100) continue;
    wins.add((
      saved,
      '${saved.round()} m: ${_label(ix, from)} -> ${_label(ix, to)} '
          '(${a.round()} m vs ${b.round()} m)',
    ));
  }

  wins.sort((x, y) => y.$1.compareTo(x.$1));
  stdout.writeln('${wins.length} footpath wins in $pairs pairs');
  for (final w in wins.take(20)) {
    stdout.writeln('  ${w.$2}');
  }
}

String _label(TransitIndex ix, int stop) =>
    '${ix.stopNames[stop]} (${ix.stopIds[stop]})';

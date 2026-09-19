/// Display-only stop clusters.
///
/// Two stops cluster when they share a cleaned name **and** sit within 150 m.
/// Never by name alone: "TRAPANI" is 7 stops in 4 places over 900 m and
/// "PESCHIERA" includes one in Moncalieri. Routing always uses single stops.
library;

import 'package:piedemove/geo/distance.dart';

import 'transit_index.dart';

const clusterRadiusMetres = 150.0;

class StopClusters {
  StopClusters(this.clusterOfStop, this.members, this.names);

  /// Cluster index per stop index.
  final List<int> clusterOfStop;
  final List<List<int>> members;
  final List<String> names;

  int get length => members.length;

  static StopClusters build(TransitIndex ix) {
    final byName = <String, List<int>>{};
    for (var s = 0; s < ix.stopCount; s++) {
      byName.putIfAbsent(ix.stopNames[s], () => []).add(s);
    }
    final clusterOf = List<int>.filled(ix.stopCount, -1);
    final members = <List<int>>[];
    final names = <String>[];
    for (final entry in byName.entries) {
      final stops = entry.value;
      for (final s in stops) {
        if (clusterOf[s] != -1) continue;
        // Single-link growth within the name group.
        final cluster = <int>[s];
        clusterOf[s] = members.length;
        for (var i = 0; i < cluster.length; i++) {
          final a = cluster[i];
          for (final b in stops) {
            if (clusterOf[b] != -1) continue;
            if (haversineMetres(ix.stopLat[a], ix.stopLon[a], ix.stopLat[b],
                    ix.stopLon[b]) <=
                clusterRadiusMetres) {
              clusterOf[b] = members.length;
              cluster.add(b);
            }
          }
        }
        members.add(cluster);
        names.add(entry.key);
      }
    }
    return StopClusters(clusterOf, members, names);
  }
}

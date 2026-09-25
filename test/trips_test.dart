import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/index_io.dart';
import 'package:piedemove/routing/footpaths.dart';
import 'package:piedemove/routing/raptor.dart';
import 'package:yaml/yaml.dart';

/// The user's own trips (`test/trips.yaml`) planned against the real index.
void main() {
  const indexPath = 'build/index.bin';
  final required = Platform.environment['PIEDEMOVE_REQUIRE_INDEX'] == '1';
  final skip = File(indexPath).existsSync() || required
      ? null
      : 'run `dart tool/build_index.dart` first';

  final spec = loadYaml(File('test/trips.yaml').readAsStringSync()) as YamlMap;
  for (final trip in (spec['trips'] as YamlList).cast<YamlMap>()) {
    test('${trip['name']}', () async {
      final ix = await readIndexFile(indexPath) ??
          (throw StateError('$indexPath missing, unreadable or an old format'));
      final planner = Planner(ix, Footpaths.build(ix));
      final parts = (trip['at'] as String).split(':');
      var day = DateTime.now();
      while (day.weekday > DateTime.friday) {
        day = day.add(const Duration(days: 1));
      }
      final journeys = planner.plan(PlanRequest(
        originLat: (trip['from'] as YamlList)[0] as double,
        originLon: (trip['from'] as YamlList)[1] as double,
        destLat: (trip['to'] as YamlList)[0] as double,
        destLon: (trip['to'] as YamlList)[1] as double,
        when: DateTime(day.year, day.month, day.day, int.parse(parts[0]),
            int.parse(parts[1])),
      ));
      expect(journeys, isNotEmpty);
      final best = sortBalanced(journeys).first;
      expect(best.walkMetres, lessThanOrEqualTo((trip['maxWalk'] as num) + 0.0));
      if (trip['maxRides'] != null) {
        expect(best.rides, lessThanOrEqualTo(trip['maxRides'] as int));
      }
    }, skip: skip);
  }
}

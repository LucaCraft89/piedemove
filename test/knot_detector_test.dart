import 'package:flutter_test/flutter_test.dart';

import '../tool/gap_detector.dart';
import '../tool/knot_detector.dart';

void main() {
  test('shipped ambient geometry has no spikes and no kink loops', () {
    final knots = findKnots(readGz('assets/ambient.json.gz'));
    expect(knots, isEmpty, reason: knots.take(10).join('\n'));
  });

  test('detector flags a spike and a kink loop', () {
    Map<String, dynamic> one(List<List<double>> c) => {
          'features': [
            {
              'properties': <String, dynamic>{},
              'geometry': {'coordinates': c},
            }
          ]
        };
    // ~9 m out, ~9 m back: a spike.
    expect(
        findKnots(one([
          [7.0, 45.0],
          [7.0001, 45.0],
          [7.0, 45.00001],
        ])),
        isNotEmpty);
    // A figure-eight kink.
    expect(
        findKnots(one([
          [7.0, 45.0],
          [7.0002, 45.0002],
          [7.0002, 45.0],
          [7.0, 45.0002],
        ])),
        isNotEmpty);
  });
}

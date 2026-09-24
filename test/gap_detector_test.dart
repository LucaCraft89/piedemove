import 'package:flutter_test/flutter_test.dart';

import '../tool/gap_detector.dart';

void main() {
  test('shipped patterns: dotted hops stay rare, stops advance along the path',
      () {
    final net = readNet('assets/lines.bin.gz');
    var hops = 0, dotted = 0;
    for (final p in net.patterns) {
      hops += p.hopApprox.length;
      dotted += p.approxHops;
      for (var i = 1; i < p.stopVertex.length; i++) {
        expect(p.stopVertex[i], greaterThanOrEqualTo(p.stopVertex[i - 1]),
            reason: 'pattern ${p.pattern} stop $i');
      }
    }
    expect(dotted / hops, lessThan(0.01),
        reason: '$dotted of $hops hops are dotted');
  });

  test('shipped ambient geometry draws every pattern hop, joints shared', () {
    final gaps = findGaps(readNet('assets/lines.bin.gz'),
        EmittedGeometry(readGz('assets/ambient.json.gz')));
    expect(gaps, isEmpty, reason: gaps.take(10).join('\n'));
  });

  test('detector flags a hop missing from the drawn geometry', () {
    final net = readNet('assets/lines.bin.gz');
    final all = readGz('assets/ambient.json.gz');
    final features = (all['features'] as List).skip(200).toList();
    final gaps = findGaps(net, EmittedGeometry({'features': features}));
    expect(gaps, isNotEmpty);
  });
}

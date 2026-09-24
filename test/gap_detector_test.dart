import 'package:flutter_test/flutter_test.dart';

import '../tool/gap_detector.dart';

void main() {
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

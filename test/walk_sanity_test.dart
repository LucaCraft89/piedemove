import 'package:flutter_test/flutter_test.dart';

import '../tool/walk_sanity.dart';

void main() {
  Map<String, dynamic> m(int nodes, {double share = 0.99, int size = 900000}) =>
      {'nodes': nodes, 'edges': nodes * 3 ~/ 2, 'mainComponentShare': share, 'size': size};

  test('passes normal, fails floors and swings', () {
    expect(check(m(82000), m(80000)), isEmpty);
    expect(check(m(82000), null), isEmpty);
    expect(check(m(20000), null), isNotEmpty);
    expect(check(m(82000, share: 0.5), null), isNotEmpty);
    expect(check(m(60000), m(82000)), isNotEmpty);
    expect(check(m(82000, share: 0.9), m(82000)), isNotEmpty);
    expect(check(m(82000), {'payloadSha256': 'x'}), isEmpty); // old manifest without stats
  });
}

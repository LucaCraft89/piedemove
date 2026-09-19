import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:piedemove/data/feeds.dart';

/// Feeds move and the aperTO-listed URLs are already dead. This asserts each
/// GTT endpoint still answers. Network test: off unless PIEDEMOVE_NETWORK=1,
/// so the normal suite runs offline.
void main() {
  final skip = Platform.environment['PIEDEMOVE_NETWORK'] == '1'
      ? null
      : 'set PIEDEMOVE_NETWORK=1 to hit the network';

  Feeds.all.forEach((name, url) {
    test('$name answers', () async {
      final response = await http
          .head(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      expect(response.statusCode, 200, reason: url);
    }, skip: skip);
  });
}

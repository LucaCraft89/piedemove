// "Segnala un problema": the trip log, and the issue link without positions.
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/location/trip_log.dart';
import 'package:piedemove/ui/settings/report_page.dart';

void main() {
  test('lines are timed and capped', () {
    final log = TripLog(clock: () => DateTime(2026, 10, 7, 8, 5, 3));
    log.add('start');
    expect(log.lines.single, '08:05:03 start');
    for (var i = 0; i < tripLogMaxLines + 10; i++) {
      log.add('fix $i');
    }
    expect(log.lines, hasLength(tripLogMaxLines));
    expect(log.lines.last, endsWith('fix ${tripLogMaxLines + 9}'));
  });

  test('positions are rounded in the log and dropped from the issue', () {
    final pos = logPos(45.0626123, 7.6624987);
    expect(pos, '45.0626,7.6625');
    final line = '08:05:03 fix $pos acc 8 m';
    expect(withoutPositions(line), '08:05:03 fix … acc 8 m');
    final uri = reportIssueUri('0.9.0-beta.15', line);
    final body = uri.queryParameters['body']!;
    expect(body, contains('0.9.0-beta.15'));
    expect(body, contains('fix … acc 8 m'));
    expect(body, isNot(contains('45.0626')));
    expect(uri.toString().length, lessThan(8000));
  });

  test('a long log is cut to its end for the link', () {
    final long = List.generate(2000, (i) => '08:00:00 leg $i').join('\n');
    final body = reportIssueUri(null, long).queryParameters['body']!;
    expect(body, contains('leg 1999'));
    expect(body, isNot(contains('leg 1\n')));
  });
}

// The alert list says how old it is while GTT's alert service is down.
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/ui/sheets/alert_sheet.dart';

void main() {
  final now = DateTime(2026, 10, 7, 12);

  test('fresh: no line', () {
    expect(
        alertsAsOfLabel(
            FeedHealth(lastSuccess: now.subtract(const Duration(minutes: 3))),
            now),
        isNull);
  });

  test('from the copy on the phone, or old: dated', () {
    expect(
        alertsAsOfLabel(
            FeedHealth(lastSuccess: DateTime(2026, 9, 28, 14, 5), cached: true),
            now),
        'Servizio avvisi GTT non raggiungibile · avvisi del 28/09 14:05');
    expect(
        alertsAsOfLabel(
            FeedHealth(lastSuccess: now.subtract(const Duration(hours: 1))),
            now),
        startsWith('Servizio avvisi GTT non raggiungibile · avvisi del'));
  });

  test('never answered: said plainly', () {
    expect(alertsAsOfLabel(null, now), 'Servizio avvisi GTT non raggiungibile');
  });
}

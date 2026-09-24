import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/ui/map/latest_runner.dart';

void main() {
  test('serial, coalesced, latest wins', () async {
    final r = LatestRunner();
    final log = <String>[];
    final gate = Completer<void>();
    r.request(() async {
      log.add('a start');
      await gate.future;
      log.add('a end');
    });
    r.request(() async => log.add('b'));
    r.request(() async => log.add('c'));
    await Future<void>.delayed(Duration.zero);
    expect(log, ['a start']);
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(log, ['a start', 'a end', 'c']);
  });
  test('a throwing job does not stop the queue', () async {
    final r = LatestRunner();
    var ran = false;
    r.request(() async => throw StateError('x'));
    r.request(() async => ran = true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(ran, true);
  });
}

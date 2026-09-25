// MapLibre only accepts `["zoom"]` as the input of one top-level `step` or
// `interpolate`; anything else is rejected at runtime and the property falls
// back to its default without an error the app can see (every ambient line
// drew 1 px wide and fully opaque at every zoom until this was caught in
// logcat). These pin the rule for the expressions built in Dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/ui/map/line_features.dart';
import 'package:piedemove/ui/map/map_style.dart';

bool _isZoom(Object? e) => e is List && e.length == 1 && e.first == 'zoom';

int _zooms(Object? e) {
  if (_isZoom(e)) return 1;
  if (e is! List) return 0;
  return e.fold(0, (n, x) => n + _zooms(x));
}

/// Null when [e] follows the rule, else why not.
String? zoomRuleViolation(Object e) {
  final total = _zooms(e);
  if (total == 0) return null;
  if (e is! List || e.isEmpty) return 'not an expression';
  final op = e.first;
  final input = op == 'interpolate' ? e[2] : (op == 'step' ? e[1] : null);
  if (!_isZoom(input)) return 'zoom is not the top-level step/interpolate input';
  if (total != 1) return 'zoom used $total times';
  return null;
}

void main() {
  test('the rule checker itself', () {
    expect(zoomRuleViolation(['step', ['zoom'], 0, 12, 1]), isNull);
    expect(zoomRuleViolation(['*', ['step', ['zoom'], 0, 12, 1], 2]), isNotNull);
    expect(
        zoomRuleViolation([
          'case',
          true,
          ['step', ['zoom'], 0, 12, 1],
          ['step', ['zoom'], 0, 14, 1],
        ]),
        isNotNull);
  });

  test('ambient width and tier opacity keep zoom at the top', () {
    for (final e in [
      ambientWidth(),
      ambientWidth(extra: ambientCasingExtra),
      ambientWidth(extra: pickedExtra),
      tierOpacity(),
      tierOpacity(factor: ambientCasingOpacity),
      tierOpacity(factor: approxLineOpacity),
      focusWidth(kindRidden),
      focusWidth(kindContext, extra: 2),
    ]) {
      expect(zoomRuleViolation(e), isNull, reason: '$e');
    }
  });

  test('tier opacity steps: tier 0 always, tier 1 from z12, tier 2 from z14',
      () {
    final e = tierOpacity(factor: 0.5);
    expect(e[3], tier1MinZoom);
    expect(e[5], tier2MinZoom);
    expect(e.last, 0.5);
  });
}

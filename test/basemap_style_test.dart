import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/settings/settings.dart';
import 'package:piedemove/ui/map/basemap_style.dart';

void main() {
  test('every variant is a valid style with attribution and unique layer ids', () {
    for (final k in MapStyleKind.values) {
      final j = jsonDecode(buildBasemapStyle(mapPalette(k, appDark: false)))
          as Map<String, dynamic>;
      final ids = [for (final l in j['layers']) l['id']];
      expect(ids.toSet().length, ids.length);
      final attr = j['sources']['openmaptiles']['attribution'] as String;
      expect(attr, allOf(contains('OpenFreeMap'), contains('OpenMapTiles'), contains('OpenStreetMap')));
    }
  });
  test('auto follows the app theme', () {
    expect(mapPalette(MapStyleKind.auto, appDark: true).dark, isTrue);
    expect(mapPalette(MapStyleKind.auto, appDark: false).dark, isFalse);
  });
}

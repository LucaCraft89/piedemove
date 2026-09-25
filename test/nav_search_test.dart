// Navigation stack and search fixes (audit 2026-09).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:piedemove/places/favourites.dart';
import 'package:piedemove/places/photon.dart';
import 'package:piedemove/places/saved.dart';
import 'package:piedemove/places/search_index.dart';
import 'package:piedemove/ui/nav/entity.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/synthetic.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pushing the entity already on top does not stack it twice', () {
    final nav = EntityNav();
    nav.push(const StopRef(3));
    nav.push(const StopRef(3));
    expect(nav.state, hasLength(1));
    nav.push(const LineRef(1));
    nav.push(const StopRef(3)); // not on top: a real step
    expect(nav.state, hasLength(3));
    nav.dispose();
  });

  test('a blank query matches no stop and no line', () {
    final ix = syntheticIndex(
      stops: [('A', 'ALFA', 45.0, 7.6), ('B', 'BRAVO', 45.01, 7.6)],
      patterns: [
        ('1', 3, ['A', 'B'], [
          [0, 60],
        ]),
      ],
    );
    expect(searchStops(ix, '   '), isEmpty);
    expect(searchRoutes(ix, ''), isEmpty);
    expect(searchRoutes(ix, '1'), [0]);
  });

  test('photon caches per query and rough position', () async {
    var calls = 0;
    final client = PhotonClient(
      client: MockClient((_) async {
        calls++;
        return http.Response(jsonEncode({'features': []}), 200);
      }),
    );
    await client.search('piazza castello', lat: 45.07, lon: 7.68);
    await client.search('piazza castello', lat: 45.0701, lon: 7.6801);
    expect(calls, 1, reason: 'same ~1 km cell: cached');
    await client.search('piazza castello', lat: 45.02, lon: 7.61);
    expect(calls, 2, reason: 'across town: asked again');
  });

  group('async loads keep what the user added meanwhile', () {
    const saved = Place(name: 'Casa', address: '', lat: 45.0, lon: 7.6);
    const early = Place(name: 'Lavoro', address: '', lat: 45.1, lon: 7.7);

    test('saved places', () async {
      SharedPreferences.setMockInitialValues({
        'pm.saved': jsonEncode([saved.toJson()]),
      });
      final list = PlaceList('pm.saved');
      list.add(early); // before the load lands
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(list.state.map((p) => p.name), ['Lavoro', 'Casa']);
      list.dispose();
    });

    test('favourites', () async {
      SharedPreferences.setMockInitialValues({
        'pm.favourites': ['stop:A'],
      });
      final fav = Favourites();
      final toggled = fav.toggle('line:4');
      await toggled;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fav.state, containsAll(['stop:A', 'line:4']));
      fav.dispose();
    });
  });
}

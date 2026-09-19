import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/places/photon.dart';
import 'package:piedemove/places/search_index.dart';

import 'support/synthetic.dart';

TransitIndex _index() => syntheticIndex(
      stops: const [
        ('s1', 'Fermata 872 - PORTA NUOVA', 45.0625, 7.6785),
        ('s2', 'Fermata 873 - CITTÀ STUDI', 45.0700, 7.6600),
        ('s3', 'Fermata 874 - CITTÀ GIARDINO', 45.0800, 7.6500),
      ],
      patterns: const [
        ('2', RouteType.tram, ['s1', 's2'], [[0, 120]]),
        ('33', RouteType.bus, ['s2', 's3'], [[0, 180]]),
      ],
    );

void main() {
  test('fold strips diacritics and case', () {
    expect(fold('Città Studî'), 'citta studi');
  });

  test('matching is token-prefix and diacritic-insensitive', () {
    expect(matchesQuery('CITTÀ STUDI', 'citta stu'), isTrue);
    expect(matchesQuery('CITTÀ STUDI', 'studi'), isTrue);
    expect(matchesQuery('CITTÀ STUDI', 'porta'), isFalse);
  });

  test('stops match by cleaned name, nearest first', () {
    final ix = _index();
    expect(searchStops(ix, 'studi'), [1]);
    // The stop code finds a pole on its own.
    expect(searchStops(ix, 's3'), [2]);
    // Two matches: the nearer pole leads.
    expect(searchStops(ix, 'citta', lat: 45.0800, lon: 7.6500), [2, 1]);
  });

  test('lines match by number, exact short name first', () {
    final ix = _index();
    expect(searchRoutes(ix, '3'), [1]);
    expect(searchRoutes(ix, '2').first, 0);
  });

  test('photon feature keeps the street address, never the district', () {
    final place = Place.fromFeature(const {
      'geometry': {'coordinates': [7.66, 45.06]},
      'properties': {
        'name': 'Politecnico',
        'street': 'Corso Duca degli Abruzzi',
        'housenumber': '24',
        'city': 'Torino',
        'district': 'Crocetta',
      },
    });
    expect(place!.name, 'Politecnico');
    expect(place.address, 'Corso Duca degli Abruzzi 24, Torino');
    expect(place.lat, 45.06);
  });

  test('a feature without a point is dropped', () {
    expect(Place.fromFeature(const {'properties': {}}), isNull);
  });
}

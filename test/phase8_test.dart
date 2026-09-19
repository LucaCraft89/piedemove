import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/places/favourites.dart';
import 'package:piedemove/ui/sheets/stop_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _entrances() => {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [7.6785, 45.0625],
          },
          'properties': {'name': 'Porta Nuova ovest'},
        },
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [7.6790, 45.0625],
          },
          'properties': {'name': ''},
        },
        // A kilometre away: out of range.
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [7.6900, 45.0700],
          },
          'properties': {'name': 'Altrove'},
        },
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('entrances within the radius come back nearest first, named', () {
    final near = entrancesNear(_entrances(), 45.0625, 7.6785);
    expect(near.length, 2);
    expect(near.first.$1, 'Porta Nuova ovest');
    expect(near.first.$2, lessThan(1));
    // An unnamed entrance still reads as one.
    expect(near[1].$1, 'Ingresso metro');
  });

  test('no entrance data is simply an empty list', () {
    expect(entrancesNear(null, 45.0625, 7.6785), isEmpty);
  });

  test('a favourite survives a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final favourites = Favourites();
    await favourites.toggle(stopFavourite('s1'));
    await favourites.toggle(lineFavourite('4'));
    expect(favourites.state, {'stop:s1', 'line:4'});

    await favourites.toggle(stopFavourite('s1'));
    expect(favourites.state, {'line:4'});

    final reloaded = Favourites();
    await Future<void>.delayed(Duration.zero);
    expect(reloaded.state, {'line:4'});
  });
}

// Place results carry what they are (street, address, pharmacy...) for the
// icon, and keep it when saved.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/places/photon.dart';
import 'package:piedemove/places/place_icon.dart';

Place _photon(Map<String, dynamic> props) => Place.fromFeature({
      'geometry': {
        'coordinates': [7.66, 45.06],
      },
      'properties': props,
    })!;

void main() {
  test('Photon type and OSM tag become the kind', () {
    expect(_photon({'type': 'street', 'name': 'Via Roma'}).kind, 'street');
    expect(
        _photon({'type': 'house', 'street': 'Via Roma', 'housenumber': '1'})
            .kind,
        'house');
    expect(
        _photon({
          'type': 'other',
          'name': 'Farmacia',
          'osm_key': 'amenity',
          'osm_value': 'pharmacy',
        }).kind,
        'amenity:pharmacy');
  });

  test('icons tell streets, addresses and places apart', () {
    Place p(String kind, {bool stop = false}) =>
        Place(name: 'x', address: '', lat: 0, lon: 0, kind: kind, stop: stop);
    expect(placeIcon(p('street')), Icons.add_road);
    expect(placeIcon(p('house')), Icons.home_outlined);
    expect(placeIcon(p('amenity:pharmacy')), Icons.local_pharmacy_outlined);
    expect(placeIcon(p('shop:supermarket')), Icons.shopping_bag_outlined);
    expect(placeIcon(p('leisure:park')), Icons.park_outlined);
    expect(placeIcon(p('')), Icons.place_outlined, reason: 'saved before kinds');
    expect(placeIcon(p('', stop: true)), Icons.signpost_outlined);
  });

  test('the kind survives saving', () {
    const place =
        Place(name: 'x', address: '', lat: 0, lon: 0, kind: 'amenity:cafe');
    expect(Place.fromJson(place.toJson()).kind, 'amenity:cafe');
    expect(
        Place.fromJson(const {'n': 'old', 'a': '', 'lat': 0, 'lon': 0}).kind,
        '');
  });
}

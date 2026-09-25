/// The icon for a place result, from its Photon [Place.kind], so a street, an
/// address, a pharmacy and a park do not all look like the same pin.
library;

import 'package:flutter/material.dart';

import 'photon.dart';

IconData placeIcon(Place place) {
  if (place.stop) return Icons.signpost_outlined;
  final kind = place.kind;
  if (kind == 'street') return Icons.add_road;
  if (kind == 'house') return Icons.home_outlined;
  final (key, value) = switch (kind.split(':')) {
    [final k, final v] => (k, v),
    _ => ('', ''),
  };
  switch (value) {
    case 'restaurant' || 'fast_food' || 'food_court':
      return Icons.restaurant;
    case 'cafe' || 'bar' || 'pub' || 'ice_cream':
      return Icons.local_cafe_outlined;
    case 'pharmacy':
      return Icons.local_pharmacy_outlined;
    case 'hospital' || 'clinic' || 'doctors':
      return Icons.local_hospital_outlined;
    case 'school' || 'university' || 'college' || 'kindergarten':
      return Icons.school_outlined;
    case 'library':
      return Icons.local_library_outlined;
    case 'bank' || 'atm':
      return Icons.account_balance_outlined;
    case 'post_office':
      return Icons.local_post_office_outlined;
    case 'cinema' || 'theatre':
      return Icons.theaters_outlined;
    case 'place_of_worship':
      return Icons.church_outlined;
    case 'parking':
      return Icons.local_parking;
    case 'museum' || 'gallery':
      return Icons.museum_outlined;
    case 'hotel' || 'hostel' || 'guest_house':
      return Icons.hotel_outlined;
    case 'park' || 'garden':
      return Icons.park_outlined;
    case 'station' || 'halt' || 'tram_stop' || 'bus_stop' || 'platform':
      return Icons.train_outlined;
  }
  return switch (key) {
    'shop' => Icons.shopping_bag_outlined,
    'tourism' || 'historic' => Icons.attractions_outlined,
    'leisure' => Icons.park_outlined,
    'railway' || 'public_transport' => Icons.train_outlined,
    'office' || 'building' => Icons.business_outlined,
    'place' || 'boundary' => Icons.location_city_outlined,
    'highway' => Icons.add_road,
    'amenity' => Icons.storefront_outlined,
    _ => Icons.place_outlined,
  };
}

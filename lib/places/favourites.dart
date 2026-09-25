/// Favourite stops and lines (§11.3), stored locally.
///
/// Keyed by the GTFS stop id and the route short name, not by index: the index
/// is rebuilt with every feed and its integers move. One set in
/// SharedPreferences; nothing leaves the phone.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _key = 'pm.favourites';

String stopFavourite(String stopId) => 'stop:$stopId';
String lineFavourite(String shortName) => 'line:$shortName';

class Favourites extends StateNotifier<Set<String>> {
  Favourites() : super(const {}) {
    _loaded = _load().catchError((Object _) {}); // a failed read never blocks saving
  }

  /// Writes wait for the first read, or a quick tap would overwrite the list.
  late final Future<void> _loaded;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    // A star tapped before the load finished is kept, not overwritten.
    state = {...(prefs.getStringList(_key) ?? const []), ...state};
  }

  Future<void> toggle(String key) async {
    state = state.contains(key) ? ({...state}..remove(key)) : {...state, key};
    await _loaded;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, state.toList());
  }
}

final favouritesProvider =
    StateNotifierProvider<Favourites, Set<String>>((_) => Favourites());

/// Recents and saved places, stored locally (§11.3).
///
/// One list of [Place]s each, in SharedPreferences as JSON. Nothing leaves the
/// phone.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'photon.dart';

const _recentsKey = 'pm.recents';
const _savedKey = 'pm.saved';
const maxRecents = 10;

class PlaceList extends StateNotifier<List<Place>> {
  PlaceList(this._key, {this.cap}) : super(const []) {
    _loaded = _load().catchError((Object _) {}); // a failed read never blocks saving
  }

  /// Writes wait for this: saving before the first read would overwrite the
  /// stored list with only what was added meanwhile.
  late final Future<void> _loaded;

  final String _key;
  final int? cap;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    if (!mounted) return;
    try {
      final loaded = [
        for (final j in jsonDecode(raw) as List)
          Place.fromJson(j as Map<String, dynamic>),
      ];
      // Places added before the load finished stay on top, not overwritten.
      state = [
        ...state,
        for (final p in loaded)
          if (!contains(p)) p,
      ].take(cap ?? 1 << 30).toList();
    } catch (_) {
      // Corrupt or an older shape: start clean rather than break the search.
    }
  }

  Future<void> _save() async {
    await _loaded;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode([for (final p in state) p.toJson()]));
  }

  /// Adds [place] at the top, deduplicated by coordinates.
  void add(Place place) {
    final rest = [for (final p in state) if (!_same(p, place)) p];
    state = [place, ...rest].take(cap ?? 1 << 30).toList();
    _save();
  }

  void remove(Place place) {
    state = [for (final p in state) if (!_same(p, place)) p];
    _save();
  }

  bool contains(Place place) => state.any((p) => _same(p, place));

  static bool _same(Place a, Place b) =>
      (a.lat - b.lat).abs() < 1e-6 && (a.lon - b.lon).abs() < 1e-6;
}

final recentPlacesProvider =
    StateNotifierProvider<PlaceList, List<Place>>((_) => PlaceList(_recentsKey, cap: maxRecents));

final savedPlacesProvider =
    StateNotifierProvider<PlaceList, List<Place>>((_) => PlaceList(_savedKey));

/// The place pinned on the map, if any. Set by the search page.
final selectedPlaceProvider = StateProvider<Place?>((_) => null);

final photonClientProvider = Provider<PhotonClient>((_) => PhotonClient());

/// "Casa" and "Lavoro": two places one tap away on the home screen.
///
/// Stored in SharedPreferences as JSON, like saved places; nothing leaves the
/// phone. A stop picked in search keeps `stop: true`, so the planner still
/// uses every pole of it.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'photon.dart';

const _key = 'pm.shortcuts';

enum Shortcut { home, work }

String shortcutLabel(Shortcut s) => switch (s) {
      Shortcut.home => 'Casa',
      Shortcut.work => 'Lavoro',
    };

class ShortcutPlaces extends StateNotifier<Map<Shortcut, Place>> {
  ShortcutPlaces() : super(const {}) {
    _loaded = _load().catchError((Object _) {});
  }

  late final Future<void> _loaded;

  Future<void> _load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null || !mounted) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      state = {
        for (final s in Shortcut.values)
          if (j[s.name] is Map<String, dynamic>)
            s: Place.fromJson(j[s.name] as Map<String, dynamic>),
        // Set before the load finished: the user's choice wins.
        ...state,
      };
    } catch (_) {}
  }

  Future<void> _save() async {
    await _loaded;
    await (await SharedPreferences.getInstance()).setString(
        _key, jsonEncode({for (final e in state.entries) e.key.name: e.value.toJson()}));
  }

  void set(Shortcut s, Place place) {
    state = {...state, s: place};
    _save();
  }

  void clear(Shortcut s) {
    state = {...state}..remove(s);
    _save();
  }
}

final shortcutPlacesProvider =
    StateNotifierProvider<ShortcutPlaces, Map<Shortcut, Place>>(
        (_) => ShortcutPlaces());

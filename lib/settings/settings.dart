/// Settings (§11.7): the planning knobs, the modes, the theme.
///
/// One immutable record in SharedPreferences as JSON. Corrupt data resets to
/// the defaults rather than breaking the planner. Language is not here yet:
/// every string is Italian in source, so the English switch needs l10n first.
library;

import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/routing/footpaths.dart' show defaultWalkSpeed;

const _key = 'pm.settings';

/// The four walk speeds offered; custom is any other value.
const walkSpeedSlow = 0.9;
const walkSpeedNormal = defaultWalkSpeed;
const walkSpeedFast = 1.6;

@immutable
class PmSettings {
  const PmSettings({
    this.maxExtraMinutes = 20,
    this.walkCapMetres = 800,
    this.walkSpeed = defaultWalkSpeed,
    this.minTransferSeconds = 60,
    this.modes = allModes,
    this.themeMode = ThemeMode.system,
  });

  static const allModes = <int>{
    RouteType.tram,
    RouteType.metro,
    RouteType.bus,
    RouteType.funicular,
  };

  /// A journey arriving later than the fastest + this is dropped (§7.3).
  final int maxExtraMinutes;
  final double walkCapMetres;
  final double walkSpeed;
  final int minTransferSeconds;

  /// GTFS `route_type`s to plan with. Empty is not allowed: the UI keeps at
  /// least one on.
  final Set<int> modes;
  final ThemeMode themeMode;

  Set<int> get excludedModes => allModes.difference(modes);

  PmSettings copyWith({
    int? maxExtraMinutes,
    double? walkCapMetres,
    double? walkSpeed,
    int? minTransferSeconds,
    Set<int>? modes,
    ThemeMode? themeMode,
  }) =>
      PmSettings(
        maxExtraMinutes: maxExtraMinutes ?? this.maxExtraMinutes,
        walkCapMetres: walkCapMetres ?? this.walkCapMetres,
        walkSpeed: walkSpeed ?? this.walkSpeed,
        minTransferSeconds: minTransferSeconds ?? this.minTransferSeconds,
        modes: modes == null || modes.isEmpty ? this.modes : modes,
        themeMode: themeMode ?? this.themeMode,
      );

  Map<String, dynamic> toJson() => {
        'extra': maxExtraMinutes,
        'cap': walkCapMetres,
        'speed': walkSpeed,
        'transfer': minTransferSeconds,
        'modes': modes.toList()..sort(),
        'theme': themeMode.name,
      };

  static PmSettings fromJson(Map<String, dynamic> j) {
    final modes = <int>{
      for (final m in (j['modes'] as List? ?? const [])) (m as num).toInt(),
    };
    return PmSettings(
      maxExtraMinutes: (j['extra'] as num?)?.toInt() ?? 20,
      walkCapMetres: (j['cap'] as num?)?.toDouble() ?? 800,
      walkSpeed: (j['speed'] as num?)?.toDouble() ?? defaultWalkSpeed,
      minTransferSeconds: (j['transfer'] as num?)?.toInt() ?? 60,
      modes: modes.isEmpty ? allModes : modes,
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == j['theme'],
        orElse: () => ThemeMode.system,
      ),
    );
  }
}

class SettingsController extends StateNotifier<PmSettings> {
  SettingsController() : super(const PmSettings()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      state = PmSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // Older or corrupt shape: the defaults are always a working setup.
      state = const PmSettings();
    }
  }

  Future<void> update(PmSettings next) async {
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(next.toJson()));
  }

  void edit(PmSettings Function(PmSettings) change) => update(change(state));

  void toggleMode(int routeType, bool on) => edit((s) {
        final next = {...s.modes};
        on ? next.add(routeType) : next.remove(routeType);
        // Never plan with nothing: the last mode stays on.
        return next.isEmpty ? s : s.copyWith(modes: next);
      });
}

final settingsProvider =
    StateNotifierProvider<SettingsController, PmSettings>(
  (_) => SettingsController(),
);

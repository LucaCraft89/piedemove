/// Every finished live trip, kept on the phone: the walking you did against
/// walking the whole way, for the arrival screen and "I tuoi viaggi". Stored
/// in SharedPreferences as JSON; nothing leaves the phone.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'trip_summary.dart';

const _key = 'pm.tripHistory';

/// Trips kept (the oldest drop out).
const tripHistoryMax = 1000;

class TripRecord {
  const TripRecord({
    required this.at,
    required this.walkMetres,
    required this.rideMetres,
    required this.directWalkMetres,
    required this.seconds,
  });

  factory TripRecord.of(TripSummary s) => TripRecord(
        at: s.arrivedAt,
        walkMetres: s.walkMetres,
        rideMetres: s.rideMetres,
        directWalkMetres: s.directWalkMetres,
        seconds: s.duration.inSeconds,
      );

  factory TripRecord.fromJson(Map<String, dynamic> j) => TripRecord(
        at: DateTime.fromMillisecondsSinceEpoch(j['at'] as int),
        walkMetres: (j['w'] as num).toDouble(),
        rideMetres: (j['r'] as num).toDouble(),
        directWalkMetres: (j['d'] as num).toDouble(),
        seconds: j['s'] as int,
      );

  final DateTime at;
  final double walkMetres;
  final double rideMetres;
  final double directWalkMetres;
  final int seconds;

  /// Walking spared against walking the whole way (never negative).
  double get spared =>
      (directWalkMetres - walkMetres).clamp(0, double.infinity).toDouble();

  Map<String, dynamic> toJson() => {
        'at': at.millisecondsSinceEpoch,
        'w': walkMetres.round(),
        'r': rideMetres.round(),
        'd': directWalkMetres.round(),
        's': seconds,
      };
}

/// Totals over some trips.
class TripTotals {
  const TripTotals(this.trips, this.walk, this.ride, this.spared);

  final int trips;
  final double walk;
  final double ride;
  final double spared;

  static TripTotals of(Iterable<TripRecord> records) {
    var n = 0;
    var w = 0.0, r = 0.0, s = 0.0;
    for (final t in records) {
      n++;
      w += t.walkMetres;
      r += t.rideMetres;
      s += t.spared;
    }
    return TripTotals(n, w, r, s);
  }
}

/// This calendar month's trips, and all of them.
(TripTotals, TripTotals) monthAndAll(List<TripRecord> records, DateTime now) => (
      TripTotals.of(records.where(
          (t) => t.at.year == now.year && t.at.month == now.month)),
      TripTotals.of(records),
    );

class TripHistory extends StateNotifier<List<TripRecord>> {
  TripHistory() : super(const []) {
    _loaded = _load().catchError((Object _) {});
  }

  late final Future<void> _loaded;

  Future<void> _load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null || !mounted) return;
    try {
      final saved = [
        for (final j in jsonDecode(raw) as List<dynamic>)
          TripRecord.fromJson(j as Map<String, dynamic>),
      ];
      state = [...saved, ...state]; // added before the load: kept, last
    } catch (_) {}
  }

  Future<void> add(TripRecord r) async {
    var next = [...state, r];
    if (next.length > tripHistoryMax) {
      next = next.sublist(next.length - tripHistoryMax);
    }
    state = next;
    await _loaded;
    try {
      await (await SharedPreferences.getInstance())
          .setString(_key, jsonEncode([for (final t in state) t.toJson()]));
    } catch (_) {}
  }

  Future<void> clear() async {
    state = const [];
    try {
      await (await SharedPreferences.getInstance()).remove(_key);
    } catch (_) {}
  }
}

final tripHistoryProvider =
    StateNotifierProvider<TripHistory, List<TripRecord>>((ref) => TripHistory());

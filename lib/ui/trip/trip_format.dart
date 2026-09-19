/// Pure formatting for the result cards and the trip detail. Kept out of the
/// widgets so the tests can pin the wording.
library;

import 'package:piedemove/routing/journey.dart';

/// Seconds below which a connection gets a warning chip (§11.4).
const tightConnectionSeconds = 120;

String hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// `23 min`, `1 h 05`.
String durationLabel(int seconds) {
  final minutes = (seconds / 60).round();
  if (minutes < 60) return '$minutes min';
  return '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')}';
}

/// Walking distances are the footpath generator's estimate, not a measured
/// path, so they carry the "approximate" marker until §9.10 has walked the
/// real streets for that leg.
String metresLabel(double metres, {bool approximate = false}) {
  final value = metres < 950
      ? '${metres.round()} m'
      : '${(metres / 1000).toStringAsFixed(1)} km';
  return approximate ? '≈ $value' : value;
}

/// The live countdown on a card: `parte ora`, `parte tra 4 min`, `partito`.
String leavesInLabel(DateTime departure, DateTime now) {
  final seconds = departure.difference(now).inSeconds;
  if (seconds < -60) return 'partito';
  if (seconds < 60) return 'parte ora';
  return 'parte tra ${seconds ~/ 60} min';
}

/// Every line that can make this hop — the product's whole point.
List<String> legLines(Leg leg) =>
    [for (final o in leg.options) o.routeShortName];

/// A ride the traveller only just catches after getting off the previous one.
bool tightConnection(Journey journey, int legIndex) {
  final leg = journey.legs[legIndex];
  if (leg.kind != LegKind.ride || legIndex == 0) return false;
  if (leg.options.isEmpty) return false;
  final slack = leg.options.first.departure - leg.readyTime;
  return slack < tightConnectionSeconds;
}

/// The last stop of a ride the vehicle has already reached, as an index into
/// [scheduled] (seconds on the journey's clock), or null when it has not
/// started. [delaySeconds] comes from the trip update; on schedule data the
/// caller passes null and nothing is highlighted.
int? lastPassedIndex(List<int> scheduled, int delaySeconds, int nowSeconds) {
  int? out;
  for (var i = 0; i < scheduled.length; i++) {
    if (scheduled[i] + delaySeconds <= nowSeconds) {
      out = i;
    } else {
      break;
    }
  }
  return out;
}

/// Transfer count as the card says it: `diretto`, `1 cambio`, `2 cambi`.
String transfersLabel(int transfers) => switch (transfers) {
      0 => 'diretto',
      1 => '1 cambio',
      _ => '$transfers cambi',
    };

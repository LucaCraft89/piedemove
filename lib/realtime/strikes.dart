/// Strikes (§ alerts): GTT announces them as service alerts, usually one per
/// line, with the guaranteed bands ("fasce garantite") in the text. The home
/// screen shows one banner for the next one, in force now or within two days.
library;

import 'gtfs_rt.dart';

/// GTFS-RT `Cause.STRIKE`.
const rtCauseStrike = 4;

final _strikeWords = RegExp(r'sciopero|agitazione sindacale', caseSensitive: false);

bool isStrike(RtAlert a) =>
    a.cause == rtCauseStrike ||
    _strikeWords.hasMatch(a.header) ||
    _strikeWords.hasMatch(a.description);

/// When [a] is next in force from [now]: [now] itself if it already is, the
/// start of its next period otherwise, null if it is over.
DateTime? nextInForce(RtAlert a, DateTime now) {
  final periods = a.periods.isEmpty ? [(a.from, a.to)] : a.periods;
  DateTime? best;
  for (final (from, to) in periods) {
    if (to != null && !to.isAfter(now)) continue;
    final start = from == null || !from.isAfter(now) ? now : from;
    if (best == null || start.isBefore(best)) best = start;
  }
  return best;
}

/// The strike to tell the rider about: in force now or starting within
/// [ahead]; the earliest. Returns the alert and when it starts.
(RtAlert, DateTime)? nextStrike(Iterable<RtAlert> alerts, DateTime now,
    {Duration ahead = const Duration(hours: 48)}) {
  (RtAlert, DateTime)? best;
  for (final a in alerts) {
    if (!isStrike(a)) continue;
    final at = nextInForce(a, now);
    if (at == null || at.difference(now) > ahead) continue;
    if (best == null || at.isBefore(best.$2)) best = (a, at);
  }
  return best;
}

const _days = ['lun', 'mar', 'mer', 'gio', 'ven', 'sab', 'dom'];

/// `Sciopero in corso`, `Sciopero oggi dalle 18:00`, `Sciopero domani dalle
/// 08:30`, `Sciopero ven 10/10 dalle 08:30`.
String strikeLabel(DateTime start, DateTime now) {
  if (!start.isAfter(now)) return 'Sciopero in corso';
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(start.hour)}:${two(start.minute)}';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(start.year, start.month, start.day);
  final d = day.difference(today).inDays;
  final when = switch (d) {
    0 => 'oggi',
    1 => 'domani',
    _ => '${_days[start.weekday - 1]} ${two(start.day)}/${two(start.month)}',
  };
  return 'Sciopero $when dalle $time';
}

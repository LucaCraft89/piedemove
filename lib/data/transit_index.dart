/// The in-memory transit index: CSR-style typed arrays, no per-object graph.
///
/// A **pattern** is a unique (route, direction, stop sequence). Trips inside a
/// pattern are sorted by their departure at the first stop.
library;

import 'dart:typed_data';

final _fermataPrefix = RegExp(r'^Fermata \S+ - ');

/// `"Fermata 872 - TRAPANI"` -> `"TRAPANI"`.
String cleanStopName(String raw) => raw.replaceFirst(_fermataPrefix, '').trim();

/// GTFS `route_type` values present in the GTT feed.
class RouteType {
  static const tram = 0;
  static const metro = 1;
  static const bus = 3;
  static const funicular = 7;
}

class TransitIndex {
  TransitIndex({
    required this.feedVersion,
    required this.serviceStartDay,
    required this.serviceDayCount,
    required this.stopIds,
    required this.stopCodes,
    required this.stopNames,
    required this.stopLat,
    required this.stopLon,
    required this.routeIds,
    required this.routeShortNames,
    required this.routeLongNames,
    required this.routeTypes,
    required this.patternRoute,
    required this.patternDir,
    required this.patternStopOffset,
    required this.patternStop,
    required this.patternTripOffset,
    required this.patternTrip,
    required this.tripIds,
    required this.tripPattern,
    required this.tripService,
    required this.tripTimeOffset,
    required this.tripDep,
    required this.tripArr,
    required this.serviceDays,
    required this.stopPatternOffset,
    required this.stopPattern,
    required this.stopPatternPos,
  });

  final String feedVersion;

  /// Epoch day (days since 1970-01-01, local) of `serviceDays` column 0.
  final int serviceStartDay;
  final int serviceDayCount;

  final List<String> stopIds;
  final List<String> stopCodes;
  final List<String> stopNames;
  final Float64List stopLat;
  final Float64List stopLon;

  final List<String> routeIds;
  final List<String> routeShortNames;
  final List<String> routeLongNames;
  final Int8List routeTypes;

  final Int32List patternRoute;
  final Int8List patternDir;
  final Int32List patternStopOffset;
  final Int32List patternStop;
  final Int32List patternTripOffset;
  final Int32List patternTrip;

  final List<String> tripIds;
  final Int32List tripPattern;
  final Int32List tripService;
  final Int32List tripTimeOffset;
  final Int32List tripDep;
  final Int32List tripArr;

  /// `serviceDays[service * serviceDayCount + day] != 0` -> service runs.
  final Uint8List serviceDays;

  final Int32List stopPatternOffset;
  final Int32List stopPattern;
  final Int32List stopPatternPos;

  int get stopCount => stopIds.length;
  int get routeCount => routeIds.length;
  int get patternCount => patternRoute.length;
  int get tripCount => tripIds.length;
  int get serviceCount =>
      serviceDayCount == 0 ? 0 : serviceDays.length ~/ serviceDayCount;

  Map<String, int>? _stopByIdCache;
  Map<String, int> get stopIndexById => _stopByIdCache ??= {
        for (var i = 0; i < stopIds.length; i++) stopIds[i]: i,
      };

  Map<String, int>? _tripByIdCache;

  /// Realtime feeds identify a run by its GTFS `trip_id`.
  Map<String, int> get tripIndexById => _tripByIdCache ??= {
        for (var i = 0; i < tripIds.length; i++) tripIds[i]: i,
      };

  Map<String, int>? _routeByIdCache;
  Map<String, int> get routeIndexById => _routeByIdCache ??= {
        for (var i = 0; i < routeIds.length; i++) routeIds[i]: i,
      };

  /// Distinct routes serving [stop], in the order they first appear.
  List<int> routesAt(int stop) {
    final out = <int>[];
    for (var i = stopPatternOffset[stop]; i < stopPatternOffset[stop + 1]; i++) {
      final route = patternRoute[stopPattern[i]];
      if (!out.contains(route)) out.add(route);
    }
    return out;
  }

  int patternLength(int p) => patternStopOffset[p + 1] - patternStopOffset[p];

  int patternStopAt(int p, int pos) => patternStop[patternStopOffset[p] + pos];

  int patternTripCount(int p) => patternTripOffset[p + 1] - patternTripOffset[p];

  int patternTripAt(int p, int i) => patternTrip[patternTripOffset[p] + i];

  int depOf(int trip, int pos) => tripDep[tripTimeOffset[trip] + pos];

  int arrOf(int trip, int pos) => tripArr[tripTimeOffset[trip] + pos];

  String routeShortNameOfPattern(int p) => routeShortNames[patternRoute[p]];

  int routeTypeOfPattern(int p) => routeTypes[patternRoute[p]];

  bool serviceRunsOn(int service, int dayIndex) =>
      dayIndex >= 0 &&
      dayIndex < serviceDayCount &&
      serviceDays[service * serviceDayCount + dayIndex] != 0;

  /// Column of [date] in `serviceDays`; negative or >= [serviceDayCount] when
  /// the date falls outside the published calendar.
  int dayIndexOf(DateTime date) =>
      epochDay(date) - serviceStartDay;

  /// Calendar day of [d] read in its own zone, as days since 1970-01-01.
  static int epochDay(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 86400000;

  static DateTime dateOfEpochDay(int day) =>
      DateTime.fromMillisecondsSinceEpoch(day * 86400000, isUtc: true);
}

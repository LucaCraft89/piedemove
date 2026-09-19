/// GTFS -> [TransitIndex]. Streaming: one pass over each member, never the
/// whole feed in memory. Runs happily inside an isolate; progress is reported
/// through [onProgress] so a first-launch screen can show it.
library;

import 'dart:typed_data';

import 'csv.dart';
import 'gtfs_zip.dart';
import 'transit_index.dart';

typedef ProgressSink = void Function(String stage, double fraction);

/// Growable Int32 buffer: keeps the big stop_times arrays out of boxed lists.
class _IntBuf {
  Int32List _a = Int32List(1024);
  int _len = 0;

  int get length => _len;

  void add(int v) {
    if (_len == _a.length) {
      final bigger = Int32List(_a.length * 2)..setRange(0, _len, _a);
      _a = bigger;
    }
    _a[_len++] = v;
  }

  Int32List toList() => Int32List.sublistView(_a, 0, _len);
}

int parseGtfsTime(String s) {
  // "HH:MM:SS", hours may exceed 24 for trips running past midnight.
  var h = 0, m = 0, sec = 0, field = 0, cur = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 58) {
      if (field == 0) {
        h = cur;
      } else if (field == 1) {
        m = cur;
      }
      field++;
      cur = 0;
    } else if (c >= 48 && c <= 57) {
      cur = cur * 10 + (c - 48);
    }
  }
  if (field == 2) sec = cur;
  return h * 3600 + m * 60 + sec;
}

int _parseDate(String yyyymmdd) => TransitIndex.epochDay(DateTime.utc(
      int.parse(yyyymmdd.substring(0, 4)),
      int.parse(yyyymmdd.substring(4, 6)),
      int.parse(yyyymmdd.substring(6, 8)),
    ));

Future<TransitIndex> buildIndex(GtfsZip zip, {ProgressSink? onProgress}) async {
  void progress(String stage, double f) => onProgress?.call(stage, f);

  // ---- feed_info ------------------------------------------------------
  var feedVersion = '';
  {
    CsvHeader? h;
    await for (final line in zip.lines('feed_info.txt')) {
      if (line.isEmpty) continue;
      if (h == null) {
        h = CsvHeader(line);
        continue;
      }
      feedVersion = h.value(parseCsvLine(line), 'feed_version') ?? '';
      break;
    }
  }

  // ---- stops ----------------------------------------------------------
  progress('stops', 0.05);
  final stopIds = <String>[];
  final stopCodes = <String>[];
  final stopNames = <String>[];
  final lat = <double>[];
  final lon = <double>[];
  final stopIndex = <String, int>{};
  {
    CsvHeader? h;
    await for (final line in zip.lines('stops.txt')) {
      if (line.isEmpty) continue;
      if (h == null) {
        h = CsvHeader(line);
        continue;
      }
      final r = parseCsvLine(line);
      final type = h.value(r, 'location_type') ?? '0';
      if (type != '0') continue; // stations and entrances are not boardable
      final id = h.value(r, 'stop_id');
      final la = double.tryParse(h.value(r, 'stop_lat') ?? '');
      final lo = double.tryParse(h.value(r, 'stop_lon') ?? '');
      if (id == null || la == null || lo == null) continue;
      stopIndex[id] = stopIds.length;
      stopIds.add(id);
      stopCodes.add(h.value(r, 'stop_code') ?? '');
      stopNames.add(cleanStopName(h.value(r, 'stop_name') ?? id));
      lat.add(la);
      lon.add(lo);
    }
  }

  // ---- routes ---------------------------------------------------------
  progress('routes', 0.1);
  final routeIds = <String>[];
  final routeShort = <String>[];
  final routeLong = <String>[];
  final routeType = <int>[];
  final routeIndex = <String, int>{};
  {
    CsvHeader? h;
    await for (final line in zip.lines('routes.txt')) {
      if (line.isEmpty) continue;
      if (h == null) {
        h = CsvHeader(line);
        continue;
      }
      final r = parseCsvLine(line);
      final id = h.value(r, 'route_id');
      if (id == null) continue;
      routeIndex[id] = routeIds.length;
      routeIds.add(id);
      routeShort.add(h.value(r, 'route_short_name') ??
          h.value(r, 'route_long_name') ??
          id);
      routeLong.add(h.value(r, 'route_long_name') ?? '');
      routeType.add(int.tryParse(h.value(r, 'route_type') ?? '3') ?? 3);
    }
  }

  // ---- calendar + calendar_dates -> per-service day bitmap ------------
  progress('calendar', 0.15);
  final serviceIndex = <String, int>{};
  final weekly = <int, List<bool>>{}; // service -> 7 weekday flags
  final ranges = <int, (int, int)>{}; // service -> (startDay, endDay)
  final exceptions = <int, Map<int, bool>>{}; // service -> day -> added
  var minDay = 1 << 30, maxDay = -(1 << 30);

  int serviceOf(String id) =>
      serviceIndex.putIfAbsent(id, () => serviceIndex.length);

  {
    CsvHeader? h;
    await for (final line in zip.lines('calendar.txt')) {
      if (line.isEmpty) continue;
      if (h == null) {
        h = CsvHeader(line);
        continue;
      }
      final r = parseCsvLine(line);
      final id = h.value(r, 'service_id');
      final start = h.value(r, 'start_date');
      final end = h.value(r, 'end_date');
      if (id == null || start == null || end == null) continue;
      final s = serviceOf(id);
      weekly[s] = [
        for (final d in const [
          'monday',
          'tuesday',
          'wednesday',
          'thursday',
          'friday',
          'saturday',
          'sunday',
        ])
          (h.value(r, d) ?? '0') == '1',
      ];
      final sd = _parseDate(start), ed = _parseDate(end);
      ranges[s] = (sd, ed);
      if (sd < minDay) minDay = sd;
      if (ed > maxDay) maxDay = ed;
    }
  }
  {
    CsvHeader? h;
    await for (final line in zip.lines('calendar_dates.txt')) {
      if (line.isEmpty) continue;
      if (h == null) {
        h = CsvHeader(line);
        continue;
      }
      final r = parseCsvLine(line);
      final id = h.value(r, 'service_id');
      final date = h.value(r, 'date');
      if (id == null || date == null) continue;
      final s = serviceOf(id);
      final day = _parseDate(date);
      exceptions.putIfAbsent(s, () => {})[day] =
          (h.value(r, 'exception_type') ?? '1') == '1';
      if (day < minDay) minDay = day;
      if (day > maxDay) maxDay = day;
    }
  }
  if (minDay > maxDay) {
    minDay = TransitIndex.epochDay(DateTime.now());
    maxDay = minDay;
  }
  final dayCount = maxDay - minDay + 1;
  final serviceDays = Uint8List(serviceIndex.length * dayCount);
  for (final s in serviceIndex.values) {
    final range = ranges[s];
    if (range != null) {
      final w = weekly[s]!;
      for (var day = range.$1; day <= range.$2; day++) {
        // 1970-01-01 was a Thursday: weekday index 3 with Monday == 0.
        final weekday = (day + 3) % 7;
        if (w[weekday]) serviceDays[s * dayCount + (day - minDay)] = 1;
      }
    }
    exceptions[s]?.forEach((day, added) {
      if (day < minDay || day > maxDay) return;
      serviceDays[s * dayCount + (day - minDay)] = added ? 1 : 0;
    });
  }

  // ---- trips ----------------------------------------------------------
  progress('trips', 0.2);
  final tripIds = <String>[];
  final tripIndex = <String, int>{};
  final tripRoute = <int>[];
  final tripService = <int>[];
  final tripDir = <int>[];
  {
    CsvHeader? h;
    await for (final line in zip.lines('trips.txt')) {
      if (line.isEmpty) continue;
      if (h == null) {
        h = CsvHeader(line);
        continue;
      }
      final r = parseCsvLine(line);
      final id = h.value(r, 'trip_id');
      final route = routeIndex[h.value(r, 'route_id') ?? ''];
      final service = serviceIndex[h.value(r, 'service_id') ?? ''];
      if (id == null || route == null || service == null) continue;
      tripIndex[id] = tripIds.length;
      tripIds.add(id);
      tripRoute.add(route);
      tripService.add(service);
      tripDir.add(int.tryParse(h.value(r, 'direction_id') ?? '0') ?? 0);
    }
  }

  // ---- stop_times -> patterns ----------------------------------------
  // GTT publishes stop_times.txt ordered by stop, not by trip, so a trip's
  // rows are scattered over 83 MB. Two streaming passes with typed arrays keep
  // peak memory around 40 MB: pass one counts rows per trip, pass two fills a
  // CSR table that is then sorted per trip by stop_sequence.
  progress('stop times', 0.3);
  final rowCount = Int32List(tripIds.length + 1);
  Future<void> scan(
      void Function(int trip, int stop, int seq, int dep, int arr) row,
      double base) async {
    CsvHeader? h;
    var rows = 0;
    await for (final line in zip.lines('stop_times.txt')) {
      if (line.isEmpty) continue;
      if (h == null) {
        h = CsvHeader(line);
        continue;
      }
      if ((++rows & 0xFFFF) == 0) {
        progress('stop times', base + 0.25 * (rows / 1400000).clamp(0, 1));
      }
      final r = parseCsvLine(line);
      final trip = tripIndex[h.value(r, 'trip_id') ?? ''];
      final stop = stopIndex[h.value(r, 'stop_id') ?? ''];
      final seq = int.tryParse(h.value(r, 'stop_sequence') ?? '');
      if (trip == null || stop == null || seq == null) continue;
      final dep = h.value(r, 'departure_time');
      final arr = h.value(r, 'arrival_time');
      // GTT publishes every time; a row without one would break the sequence.
      if (dep == null && arr == null) continue;
      row(trip, stop, seq, parseGtfsTime(dep ?? arr!), parseGtfsTime(arr ?? dep!));
    }
  }

  await scan((trip, _, _, _, _) => rowCount[trip]++, 0.3);

  final rowOffset = Int32List(tripIds.length + 1);
  var rowTotal = 0;
  for (var t = 0; t < tripIds.length; t++) {
    rowOffset[t] = rowTotal;
    rowTotal += rowCount[t];
  }
  rowOffset[tripIds.length] = rowTotal;
  final rowCursor = Int32List.fromList(rowOffset.sublist(0, tripIds.length));
  final rowStop = Int32List(rowTotal);
  final rowSeq = Int32List(rowTotal);
  final rowDep = Int32List(rowTotal);
  final rowArr = Int32List(rowTotal);

  progress('stop times', 0.55);
  await scan((trip, stop, seq, dep, arr) {
    final at = rowCursor[trip]++;
    rowStop[at] = stop;
    rowSeq[at] = seq;
    rowDep[at] = dep;
    rowArr[at] = arr;
  }, 0.55);

  progress('patterns', 0.82);
  final patternKeys = <String, int>{};
  final patternRoute = <int>[];
  final patternDir = <int>[];
  final patternStopOffset = <int>[0];
  final patternStopFlat = <int>[];
  final patternTrips = <List<int>>[];

  final keptTripIds = <String>[];
  final keptPattern = <int>[];
  final keptService = <int>[];
  final timeOffset = <int>[];
  final depBuf = _IntBuf();
  final arrBuf = _IntBuf();

  final order = <int>[];
  for (var t = 0; t < tripIds.length; t++) {
    final from = rowOffset[t], to = rowOffset[t + 1];
    if (to - from < 2) continue;
    order
      ..clear()
      ..addAll([for (var i = from; i < to; i++) i]);
    order.sort((a, b) => rowSeq[a].compareTo(rowSeq[b]));

    final route = tripRoute[t];
    final key = StringBuffer('$route|${tripDir[t]}');
    for (final i in order) {
      key.write(',');
      key.write(rowStop[i]);
    }
    var p = patternKeys[key.toString()];
    if (p == null) {
      p = patternRoute.length;
      patternKeys[key.toString()] = p;
      patternRoute.add(route);
      patternDir.add(tripDir[t]);
      for (final i in order) {
        patternStopFlat.add(rowStop[i]);
      }
      patternStopOffset.add(patternStopFlat.length);
      patternTrips.add(<int>[]);
    }
    final newTrip = keptTripIds.length;
    keptTripIds.add(tripIds[t]);
    keptPattern.add(p);
    keptService.add(tripService[t]);
    timeOffset.add(depBuf.length);
    for (final i in order) {
      depBuf.add(rowDep[i]);
      arrBuf.add(rowArr[i]);
    }
    patternTrips[p].add(newTrip);
  }

  // ---- CSR: pattern -> trips (sorted by first departure) --------------
  progress('sorting', 0.92);
  final patternTripOffset = Int32List(patternRoute.length + 1);
  var total = 0;
  for (var p = 0; p < patternTrips.length; p++) {
    patternTripOffset[p] = total;
    total += patternTrips[p].length;
  }
  patternTripOffset[patternRoute.length] = total;
  final patternTripFlat = Int32List(total);
  final deps = depBuf.toList();
  for (var p = 0; p < patternTrips.length; p++) {
    final trips = patternTrips[p]
      ..sort((a, b) => deps[timeOffset[a]].compareTo(deps[timeOffset[b]]));
    patternTripFlat.setRange(
        patternTripOffset[p], patternTripOffset[p] + trips.length, trips);
  }

  // ---- CSR: stop -> patterns ------------------------------------------
  progress('postings', 0.96);
  final counts = Int32List(stopIds.length + 1);
  for (var p = 0; p < patternRoute.length; p++) {
    for (var i = patternStopOffset[p]; i < patternStopOffset[p + 1]; i++) {
      counts[patternStopFlat[i]]++;
    }
  }
  final stopPatternOffset = Int32List(stopIds.length + 1);
  var acc = 0;
  for (var s = 0; s < stopIds.length; s++) {
    stopPatternOffset[s] = acc;
    acc += counts[s];
  }
  stopPatternOffset[stopIds.length] = acc;
  final cursor = Int32List.fromList(stopPatternOffset.sublist(0, stopIds.length));
  final stopPattern = Int32List(acc);
  final stopPatternPos = Int32List(acc);
  for (var p = 0; p < patternRoute.length; p++) {
    final base = patternStopOffset[p];
    for (var i = base; i < patternStopOffset[p + 1]; i++) {
      final s = patternStopFlat[i];
      final at = cursor[s]++;
      stopPattern[at] = p;
      stopPatternPos[at] = i - base;
    }
  }

  progress('done', 1);
  return TransitIndex(
    feedVersion: feedVersion,
    serviceStartDay: minDay,
    serviceDayCount: dayCount,
    stopIds: stopIds,
    stopCodes: stopCodes,
    stopNames: stopNames,
    stopLat: Float64List.fromList(lat),
    stopLon: Float64List.fromList(lon),
    routeIds: routeIds,
    routeShortNames: routeShort,
    routeLongNames: routeLong,
    routeTypes: Int8List.fromList(routeType),
    patternRoute: Int32List.fromList(patternRoute),
    patternDir: Int8List.fromList(patternDir),
    patternStopOffset: Int32List.fromList(patternStopOffset),
    patternStop: Int32List.fromList(patternStopFlat),
    patternTripOffset: patternTripOffset,
    patternTrip: patternTripFlat,
    tripIds: keptTripIds,
    tripPattern: Int32List.fromList(keptPattern),
    tripService: Int32List.fromList(keptService),
    tripTimeOffset: Int32List.fromList(timeOffset),
    tripDep: deps,
    tripArr: arrBuf.toList(),
    serviceDays: serviceDays,
    stopPatternOffset: stopPatternOffset,
    stopPattern: stopPattern,
    stopPatternPos: stopPatternPos,
  );
}

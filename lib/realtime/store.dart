/// The realtime store: three polled feeds, one immutable state, feed health.
///
/// Every fetch is isolated — a dead feed updates its own health entry and
/// nothing else. The planner and the sheets keep working on schedule data with
/// all three down (CLAUDE.md, "Isolate failures").
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:piedemove/data/feeds.dart';
import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/routing/departures.dart';
import 'package:piedemove/routing/journey.dart' show serviceDayTime;

import 'gtfs_rt.dart';

enum RtFeedKind { vehicles, tripUpdates, alerts }

const _url = {
  RtFeedKind.vehicles: Feeds.gttVehiclePositions,
  RtFeedKind.tripUpdates: Feeds.gttTripUpdates,
  RtFeedKind.alerts: Feeds.gttAlerts,
};

const _interval = {
  RtFeedKind.vehicles: Duration(seconds: 20),
  RtFeedKind.tripUpdates: Duration(seconds: 30),
  RtFeedKind.alerts: Duration(minutes: 5),
};

const _maxBackoff = Duration(minutes: 5);

/// A realtime request that has not answered in this long is a failed poll.
const rtFetchTimeout = Duration(seconds: 15);
const rtAlertsFetchTimeout = Duration(seconds: 45);

/// Data older than this, with every poll since failing, is dropped rather than
/// shown as live: vehicles move, delays change.
const _maxAge = {
  RtFeedKind.vehicles: Duration(minutes: 3),
  RtFeedKind.tripUpdates: Duration(minutes: 10),
};

class FeedHealth {
  const FeedHealth({
    this.lastSuccess,
    this.lastError,
    this.status,
    this.bytes,
    this.cached = false,
  });

  /// The data came from the copy kept on the phone, not from this run.
  final bool cached;

  final DateTime? lastSuccess;
  final String? lastError;
  final int? status;
  final int? bytes;

  /// Stale once three intervals have passed without a good answer, or as
  /// soon as a first request failed. A first answer still on its way is not
  /// stale: at launch the chip said "non disponibili" for feeds that were
  /// simply loading (the 150 KB alerts feed takes a few seconds).
  bool staleAt(DateTime now, Duration interval) => lastSuccess == null
      ? lastError != null
      : now.difference(lastSuccess!) > interval * 3;
}

@immutable
class RealtimeState {
  const RealtimeState({
    this.vehicles = const {},
    this.tripUpdates = const {},
    this.alerts = const [],
    this.health = const {},
  });

  /// By vehicle id.
  final Map<String, RtVehicle> vehicles;

  /// By trip id.
  final Map<String, RtTripUpdate> tripUpdates;
  final List<RtAlert> alerts;
  final Map<RtFeedKind, FeedHealth> health;

  RealtimeState copyWith({
    Map<String, RtVehicle>? vehicles,
    Map<String, RtTripUpdate>? tripUpdates,
    List<RtAlert>? alerts,
    Map<RtFeedKind, FeedHealth>? health,
  }) =>
      RealtimeState(
        vehicles: vehicles ?? this.vehicles,
        tripUpdates: tripUpdates ?? this.tripUpdates,
        alerts: alerts ?? this.alerts,
        health: health ?? this.health,
      );

  /// The home chip for [staleFeeds]: which data is missing, in a rider's
  /// words, or null when all is live. GTT's alert feed alone answering 500
  /// read as "live data broken" while buses and delays were live (beta 11).
  String? staleLabel([DateTime? now]) => staleFeedsLabel(staleFeeds(now));

  /// Feeds that have gone quiet, for the home feed-health chip.
  List<RtFeedKind> staleFeeds([DateTime? now]) {
    final at = now ?? DateTime.now();
    return [
      for (final kind in RtFeedKind.values)
        if ((health[kind] ?? const FeedHealth()).staleAt(at, _interval[kind]!))
          kind,
    ];
  }

  List<RtAlert> alertsFor({String? routeId, String? stopId, String? tripId}) {
    final now = DateTime.now();
    return [
      for (final a in alerts)
        if (a.activeAt(now) &&
            ((routeId != null && a.routeIds.contains(routeId)) ||
                (stopId != null && a.stopIds.contains(stopId)) ||
                (tripId != null && a.tripIds.contains(tripId))))
          a,
    ];
  }
}

typedef FeedFetch = Future<Uint8List> Function(String url);

Future<Uint8List> _httpFetch(String url) async {
  // Without a timeout a stalled socket never reaches `finally`, and that feed
  // stops polling for the rest of the session.
  // The alerts feed is ~150 KB (the others 25-100 KB) and polled every 5 min:
  // 15 s was too short on a slow connection (CI emulator, Oct 2026).
  final limit = url == Feeds.gttAlerts ? rtAlertsFetchTimeout : rtFetchTimeout;
  final response = await http.get(Uri.parse(url)).timeout(limit);
  if (response.statusCode != 200) {
    throw http.ClientException('HTTP ${response.statusCode}', Uri.parse(url));
  }
  return response.bodyBytes;
}

/// The last good alerts feed, kept between runs. GTT's alert service can be
/// down for days (HTTP 500, October 2026) and alerts held only in memory
/// vanished on every start - suspended stops and detours with them. Each
/// alert carries its own active periods, so an old copy still drops what
/// has ended.
abstract class AlertCache {
  Future<(Uint8List, DateTime)?> load();
  Future<void> save(Uint8List bytes, DateTime at);
}

class FileAlertCache implements AlertCache {
  Future<File> _file(String name) async => File(
      '${(await getApplicationSupportDirectory()).path}/rt/$name');

  @override
  Future<(Uint8List, DateTime)?> load() async {
    try {
      final data = await _file('alerts.pb');
      final at = await _file('alerts.at');
      if (!await data.exists() || !await at.exists()) return null;
      final ms = int.tryParse((await at.readAsString()).trim());
      if (ms == null) return null;
      return (await data.readAsBytes(), DateTime.fromMillisecondsSinceEpoch(ms));
    } catch (e) {
      debugPrint('pm: alert cache unreadable: $e');
      return null;
    }
  }

  @override
  Future<void> save(Uint8List bytes, DateTime at) async {
    try {
      final data = await _file('alerts.pb');
      await data.parent.create(recursive: true);
      // Write then rename: a crash mid-write never leaves half a feed.
      final tmp = File('${data.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(data.path);
      await (await _file('alerts.at'))
          .writeAsString('${at.millisecondsSinceEpoch}', flush: true);
    } catch (e) {
      debugPrint('pm: alert cache not saved: $e');
    }
  }
}

class RealtimeController extends StateNotifier<RealtimeState>
    with WidgetsBindingObserver {
  RealtimeController({
    this.fetch = _httpFetch,
    this.alertCache,
    bool autoStart = true,
  }) : super(const RealtimeState()) {
    unawaited(restoreAlerts());
    if (!autoStart) return;
    WidgetsBinding.instance.addObserver(this);
    start();
  }

  final FeedFetch fetch;
  final AlertCache? alertCache;

  /// Loads the cached alerts, unless the feed has already answered.
  Future<void> restoreAlerts() async {
    final cached = await alertCache?.load();
    if (cached == null || !mounted) return;
    final (bytes, at) = cached;
    final last = state.health[RtFeedKind.alerts]?.lastSuccess;
    if (last != null && !last.isBefore(at)) return;
    try {
      final feed = decodeFeed(bytes);
      state = state.copyWith(alerts: feed.alerts, health: {
        ...state.health,
        RtFeedKind.alerts: FeedHealth(
            lastSuccess: at, status: 200, bytes: bytes.length, cached: true),
      });
    } catch (e) {
      debugPrint('pm: cached alerts undecodable: $e');
    }
  }
  final _timers = <RtFeedKind, Timer>{};
  final _backoff = <RtFeedKind, Duration>{};
  var _running = false;

  void start() {
    if (_running) return;
    _running = true;
    for (final kind in RtFeedKind.values) {
      unawaited(pollOnce(kind));
    }
  }

  void stop() {
    _running = false;
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Backgrounded: every feed pauses (battery, and the data is stale anyway).
    if (state == AppLifecycleState.resumed) {
      start();
    } else {
      stop();
    }
  }

  Future<void> pollOnce(RtFeedKind kind) async {
    try {
      final bytes = await fetch(_url[kind]!);
      final feed = decodeFeed(bytes);
      _backoff.remove(kind);
      if (!mounted) return;
      state = _apply(kind, feed, bytes.length);
      if (kind == RtFeedKind.alerts) {
        unawaited(alertCache?.save(bytes, DateTime.now()));
      }
    } catch (e) {
      if (!mounted) return;
      final previous = state.health[kind] ?? const FeedHealth();
      final maxAge = _maxAge[kind];
      final expired = maxAge != null &&
          previous.lastSuccess != null &&
          DateTime.now().difference(previous.lastSuccess!) > maxAge;
      if (expired) {
        state = switch (kind) {
          RtFeedKind.vehicles => state.copyWith(vehicles: const {}),
          RtFeedKind.tripUpdates => state.copyWith(tripUpdates: const {}),
          RtFeedKind.alerts => state,
        };
      }
      state = state.copyWith(health: {
        ...state.health,
        kind: FeedHealth(
          lastSuccess: previous.lastSuccess,
          lastError: '$e',
          status: previous.status,
          bytes: previous.bytes,
          cached: previous.cached,
        ),
      });
      final grown = (_backoff[kind] ?? _interval[kind]!) * 2;
      _backoff[kind] = grown > _maxBackoff ? _maxBackoff : grown;
    } finally {
      if (_running && mounted) {
        _timers[kind]?.cancel();
        _timers[kind] = Timer(
          _backoff[kind] ?? _interval[kind]!,
          () => pollOnce(kind),
        );
      }
    }
  }

  RealtimeState _apply(RtFeedKind kind, RtFeed feed, int bytes) {
    final health = {
      ...state.health,
      kind: FeedHealth(lastSuccess: DateTime.now(), status: 200, bytes: bytes),
    };
    return switch (kind) {
      RtFeedKind.vehicles => state.copyWith(
          vehicles: {for (final v in feed.vehicles) v.id: v},
          health: health,
        ),
      RtFeedKind.tripUpdates => state.copyWith(
          tripUpdates: {for (final u in feed.tripUpdates) u.tripId: u},
          health: health,
        ),
      RtFeedKind.alerts =>
        state.copyWith(alerts: feed.alerts, health: health),
    };
  }

  @override
  void dispose() {
    stop();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final realtimeProvider =
    StateNotifierProvider<RealtimeController, RealtimeState>(
  (ref) => RealtimeController(alertCache: FileAlertCache()),
);

/// Delays as an offset onto the static index. A `stop_time_update` carries
/// forward to later stops until the next one, so the lookup walks back from the
/// asked position to the most recent stop the feed mentioned.
///
/// GTT keys its updates by `stop_sequence`; the index keeps each pattern
/// position's own sequence ([TransitIndex.stopSequenceAt], gaps and all).
/// Entries that give an absolute `time` instead of a delay are turned into
/// one against the scheduled second of that stop.
DelayLookup buildDelayLookup(TransitIndex ix, RealtimeState rt) {
  return (trip, position) {
    final update = rt.tripUpdates[ix.tripIds[trip]];
    if (update == null) return null;
    final pattern = ix.tripPattern[trip];
    final startOfDay = _startOfDay(update.startDate);
    for (var p = position; p >= 0; p--) {
      final byStop = update.byStopId[ix.stopIds[ix.patternStopAt(pattern, p)]];
      if (byStop != null) return byStop;
      final seq = ix.stopSequenceAt(pattern, p);
      final delay = update.delayBySequence[seq];
      if (delay != null) return delay;
      final time = update.timeBySequence[seq];
      if (time != null && startOfDay != null) {
        final scheduled = serviceDayTime(startOfDay, ix.depOf(trip, p));
        return time - scheduled.millisecondsSinceEpoch ~/ 1000;
      }
    }
    return update.tripDelay;
  };
}

/// `YYYYMMDD` -> that service day's date.
DateTime? _startOfDay(String? yyyymmdd) {
  if (yyyymmdd == null || yyyymmdd.length != 8) return null;
  final year = int.tryParse(yyyymmdd.substring(0, 4));
  final month = int.tryParse(yyyymmdd.substring(4, 6));
  final day = int.tryParse(yyyymmdd.substring(6, 8));
  if (year == null || month == null || day == null) return null;
  return DateTime(year, month, day);
}

/// Runs the trip-update feed says are not coming, or will not stop at a
/// position, on the service day they report (today, when the feed omits it).
UnavailableLookup buildUnavailableLookup(
    TransitIndex ix, RealtimeState rt, DateTime today) {
  final day = '${today.year.toString().padLeft(4, '0')}'
      '${today.month.toString().padLeft(2, '0')}'
      '${today.day.toString().padLeft(2, '0')}';
  return (trip, position) {
    final u = rt.tripUpdates[ix.tripIds[trip]];
    if (u == null || (u.startDate != null && u.startDate != day)) return false;
    if (u.canceled) return true;
    final pattern = ix.tripPattern[trip];
    if (u.skippedSequences.contains(ix.stopSequenceAt(pattern, position))) {
      return true;
    }
    if (u.skippedStopIds.isEmpty) return false;
    final stop = ix.patternStopAt(pattern, position);
    return u.skippedStopIds.contains(ix.stopIds[stop]);
  };
}

/// Null until the index is ready or when nothing is cancelled or skipped.
final unavailableLookupProvider = Provider<UnavailableLookup?>((ref) {
  final ix = ref.watch(transitIndexProvider).valueOrNull;
  if (ix == null) return null;
  final rt = ref.watch(realtimeProvider);
  final any = rt.tripUpdates.values.any((u) =>
      u.canceled || u.skippedSequences.isNotEmpty || u.skippedStopIds.isNotEmpty);
  if (!any) return null;
  return buildUnavailableLookup(ix, rt, DateTime.now());
});

/// Null until the index is ready; callers fall back to scheduled times.
final delayLookupProvider = Provider<DelayLookup?>((ref) {
  final ix = ref.watch(transitIndexProvider).valueOrNull;
  if (ix == null) return null;
  final rt = ref.watch(realtimeProvider);
  return buildDelayLookup(ix, rt);
});

String? staleFeedsLabel(List<RtFeedKind> stale) {
  final v = stale.contains(RtFeedKind.vehicles);
  final d = stale.contains(RtFeedKind.tripUpdates);
  final a = stale.contains(RtFeedKind.alerts);
  if (v && d && a) return 'Dati in tempo reale non disponibili';
  final live = switch ((v, d)) {
    (true, true) => 'Posizioni e ritardi fermi',
    (true, false) => 'Posizioni dei mezzi ferme',
    (false, true) => 'Ritardi fermi: orari programmati',
    _ => null,
  };
  if (!a) return live;
  return live == null ? 'Avvisi GTT non disponibili' : '$live · niente avvisi';
}

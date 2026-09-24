/// The realtime store: three polled feeds, one immutable state, feed health.
///
/// Every fetch is isolated — a dead feed updates its own health entry and
/// nothing else. The planner and the sheets keep working on schedule data with
/// all three down (CLAUDE.md, "Isolate failures").
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

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

class FeedHealth {
  const FeedHealth({this.lastSuccess, this.lastError, this.status, this.bytes});

  final DateTime? lastSuccess;
  final String? lastError;
  final int? status;
  final int? bytes;

  /// Stale once three intervals have passed without a good answer.
  bool staleAt(DateTime now, Duration interval) =>
      lastSuccess == null ||
      now.difference(lastSuccess!) > interval * 3;
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
  final response = await http.get(Uri.parse(url));
  if (response.statusCode != 200) {
    throw http.ClientException('HTTP ${response.statusCode}', Uri.parse(url));
  }
  return response.bodyBytes;
}

class RealtimeController extends StateNotifier<RealtimeState>
    with WidgetsBindingObserver {
  RealtimeController({this.fetch = _httpFetch, bool autoStart = true})
      : super(const RealtimeState()) {
    if (!autoStart) return;
    WidgetsBinding.instance.addObserver(this);
    start();
  }

  final FeedFetch fetch;
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
    } catch (e) {
      if (!mounted) return;
      final previous = state.health[kind] ?? const FeedHealth();
      state = state.copyWith(health: {
        ...state.health,
        kind: FeedHealth(
          lastSuccess: previous.lastSuccess,
          lastError: '$e',
          status: previous.status,
          bytes: previous.bytes,
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
  (ref) => RealtimeController(),
);

/// Delays as an offset onto the static index. A `stop_time_update` carries
/// forward to later stops until the next one, so the lookup walks back from the
/// asked position to the most recent stop the feed mentioned.
///
/// GTT keys its updates by `stop_sequence`, 1-based and contiguous, so position
/// `p` is sequence `p + 1`; entries that give an absolute `time` instead of a
/// delay are turned into one against the scheduled second of that stop.
DelayLookup buildDelayLookup(TransitIndex ix, RealtimeState rt) {
  return (trip, position) {
    final update = rt.tripUpdates[ix.tripIds[trip]];
    if (update == null) return null;
    final pattern = ix.tripPattern[trip];
    final startOfDay = _startOfDay(update.startDate);
    for (var p = position; p >= 0; p--) {
      final byStop = update.byStopId[ix.stopIds[ix.patternStopAt(pattern, p)]];
      if (byStop != null) return byStop;
      final delay = update.delayBySequence[p + 1];
      if (delay != null) return delay;
      final time = update.timeBySequence[p + 1];
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

/// Null until the index is ready; callers fall back to scheduled times.
final delayLookupProvider = Provider<DelayLookup?>((ref) {
  final ix = ref.watch(transitIndexProvider).valueOrNull;
  if (ix == null) return null;
  final rt = ref.watch(realtimeProvider);
  return buildDelayLookup(ix, rt);
});

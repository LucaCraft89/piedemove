/// The trip query and its result (§11.4): from, to, when, and the two orderings.
///
/// Planning is an explicit action, not a watch: the alert filters and the live
/// feeds change every few seconds and the search must not rerun under the user.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/places/photon.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/routing/providers.dart';
import 'package:piedemove/routing/raptor.dart';
import 'package:piedemove/settings/settings.dart';

enum WhenMode { now, departAt, arriveBy }

enum TripTab { fastest, balanced }

@immutable
class TripQuery {
  const TripQuery({
    this.from,
    this.to,
    this.whenMode = WhenMode.now,
    this.when,
  });

  final Place? from;
  final Place? to;
  final WhenMode whenMode;

  /// The chosen time for [WhenMode.departAt] / [WhenMode.arriveBy].
  final DateTime? when;

  bool get ready => from != null && to != null;
  bool get arriveBy => whenMode == WhenMode.arriveBy;
  DateTime resolvedWhen() =>
      whenMode == WhenMode.now ? DateTime.now() : (when ?? DateTime.now());

  TripQuery copyWith({
    Place? from,
    Place? to,
    WhenMode? whenMode,
    DateTime? when,
    bool clearFrom = false,
    bool clearTo = false,
  }) =>
      TripQuery(
        from: clearFrom ? null : (from ?? this.from),
        to: clearTo ? null : (to ?? this.to),
        whenMode: whenMode ?? this.whenMode,
        when: when ?? this.when,
      );
}

@immutable
class TripResult {
  const TripResult({
    required this.fastest,
    required this.balanced,
    required this.computedAt,
    required this.query,
    this.failed = false,
  });

  final List<Journey> fastest;
  final List<Journey> balanced;
  final DateTime computedAt;
  final TripQuery query;

  /// The planner threw: the UI says so instead of showing "no journeys".
  final bool failed;

  bool get isEmpty => fastest.isEmpty;

  List<Journey> forTab(TripTab tab) =>
      tab == TripTab.fastest ? fastest : balanced;
}

@immutable
class TripState {
  const TripState({
    this.query = const TripQuery(),
    this.result,
    this.planning = false,
    this.tab = TripTab.balanced,
    this.selected,
    this.sheetHidden = false,
  });

  final TripQuery query;
  final TripResult? result;
  final bool planning;
  final TripTab tab;

  /// Index into the current tab's list when the detail page is open.
  final int? selected;

  /// The sheet was closed: home shows a reopen chip (§11.2).
  final bool sheetHidden;

  TripState copyWith({
    TripQuery? query,
    TripResult? result,
    bool? planning,
    TripTab? tab,
    int? selected,
    bool clearSelected = false,
    bool clearResult = false,
    bool? sheetHidden,
  }) =>
      TripState(
        query: query ?? this.query,
        result: clearResult ? null : (result ?? this.result),
        planning: planning ?? this.planning,
        tab: tab ?? this.tab,
        selected: clearSelected ? null : (selected ?? this.selected),
        sheetHidden: sheetHidden ?? this.sheetHidden,
      );
}

/// A [PlanRequest] for [query] under [settings]. Pure, so the tests can pin it.
PlanRequest planRequestFor({
  required TripQuery query,
  required PmSettings settings,
  required Set<int> suspendedStops,
  required Set<int> detouredRoutes,
}) {
  final from = query.from!;
  final to = query.to!;
  return PlanRequest(
    originLat: from.lat,
    originLon: from.lon,
    destLat: to.lat,
    destLon: to.lon,
    when: query.resolvedWhen(),
    arriveBy: query.arriveBy,
    walkCapMetres: settings.walkCapMetres,
    walkSpeed: settings.walkSpeed,
    minTransferSeconds: settings.minTransferSeconds,
    maxExtraMinutes: settings.maxExtraMinutes,
    suspendedStops: suspendedStops,
    detouredRoutes: detouredRoutes,
    excludedRouteTypes: settings.excludedModes,
  );
}

class TripPlanController extends StateNotifier<TripState> {
  TripPlanController(this._ref) : super(const TripState());

  final Ref _ref;

  void setFrom(Place? place) => state = state.copyWith(
        query: state.query.copyWith(from: place, clearFrom: place == null),
      );

  void setTo(Place? place) => state = state.copyWith(
        query: state.query.copyWith(to: place, clearTo: place == null),
      );

  void swap() => state = state.copyWith(
        query: TripQuery(
          from: state.query.to,
          to: state.query.from,
          whenMode: state.query.whenMode,
          when: state.query.when,
        ),
      );

  void setWhen(WhenMode mode, [DateTime? at]) => state = state.copyWith(
        query: state.query.copyWith(whenMode: mode, when: at),
      );

  void setTab(TripTab tab) =>
      state = state.copyWith(tab: tab, clearSelected: true);

  void select(int index) => state = state.copyWith(selected: index);

  void back() => state = state.copyWith(clearSelected: true);

  void hideSheet() => state = state.copyWith(sheetHidden: true);

  void reopenSheet() => state = state.copyWith(sheetHidden: false);

  void clear() => state = TripState(query: state.query);

  /// Plans, then keeps the result until the user clears or replans.
  Future<void> plan() async {
    final planner = _ref.read(plannerProvider);
    if (!state.query.ready || planner == null) return;
    final query = state.query;
    state = state.copyWith(
      planning: true,
      clearResult: true,
      clearSelected: true,
      sheetHidden: false,
    );
    // One frame so the spinner paints before the synchronous search.
    await Future<void>.delayed(Duration.zero);
    final request = planRequestFor(
      query: query,
      settings: _ref.read(settingsProvider),
      suspendedStops: _ref.read(suspendedStopsProvider),
      detouredRoutes: _ref.read(detouredRoutesProvider),
    );
    TripResult result;
    try {
      final journeys = planner.plan(request);
      result = TripResult(
        fastest: sortFastest(journeys),
        balanced: sortBalanced(journeys),
        computedAt: DateTime.now(),
        query: query,
      );
    } catch (e) {
      debugPrint('pm: planning failed: $e');
      result = TripResult(
        fastest: const [],
        balanced: const [],
        computedAt: DateTime.now(),
        query: query,
        failed: true,
      );
    }
    if (!mounted) return;
    state = state.copyWith(planning: false, result: result);
  }
}

final tripPlanProvider =
    StateNotifierProvider<TripPlanController, TripState>(
  TripPlanController.new,
);

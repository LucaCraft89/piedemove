/// The live trip strip (§12): one compact bar that says what to do next, the
/// manual board/alight button, and the one-tap "Ricalcola" banner.
///
/// It never recalculates by itself — off route only raises the banner.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/walk_router.dart';
import 'package:piedemove/location/live_trip.dart';
import 'package:piedemove/places/photon.dart';
import 'package:piedemove/realtime/store.dart' show delayLookupProvider;
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/trip/live_stats.dart';
import 'package:piedemove/ui/trip/trip_format.dart';
import 'package:piedemove/ui/trip/trip_plan.dart';

/// `Scendi a Peschiera tra 3 fermate`, `A piedi: Trapani tra 120 m`.
String liveLabel(LiveTripState s) {
  final leg = s.leg;
  final name = leg.endName;
  if (leg.kind == LegKind.ride) {
    if (s.stopsRemaining <= 0) {
      return 'Scendi ora${name.isEmpty ? '' : ' a $name'}';
    }
    if (s.stopsRemaining == 1) return 'Scendi a $name alla prossima fermata';
    return 'Scendi a $name tra ${s.stopsRemaining} fermate';
  }
  return walkStripText(s);
}

/// At the boarding stop, before boarding: `Aspetta il 10 per FALCHERA`, with
/// the other lines that make the same ride (`o 16, 42`). Null otherwise.
String? waitingLabel(LiveTripState s, TransitIndex? ix) {
  if (!s.reachedBoardStop || s.riding || s.isLastLeg) return null;
  final i = s.legIndex + 1;
  if (i >= s.journey.legs.length) return null;
  final ride = s.journey.legs[i];
  if (ride.kind != LegKind.ride || ride.options.isEmpty) return null;
  final first = ride.options.first;
  final others = <String>{
    for (final o in ride.options.skip(1)) o.routeShortName,
  }..remove(first.routeShortName);
  final head = ix == null
      ? ''
      : ' per ${cleanStopName(ix.stopNames[ix.patternStopAt(first.pattern, ix.patternLength(first.pattern) - 1)])}';
  return 'Aspetta il ${first.routeShortName}$head'
      '${others.isEmpty ? '' : ' (o ${others.join(', ')})'}';
}

/// Second strip line for a routed walk: the next turn, crossing or steps.
String? maneuverLabel(LiveTripState s) {
  final m = nextManeuver(s.leg, s.vertex);
  if (m == null || m.type == ManeuverType.arrive) return null;
  final what = switch (m.type) {
    ManeuverType.cross => 'Attraversa',
    ManeuverType.steps => 'Scale',
    ManeuverType.left || ManeuverType.sharpLeft => 'Svolta a sinistra',
    ManeuverType.slightLeft => 'Leggermente a sinistra',
    ManeuverType.right || ManeuverType.sharpRight => 'Svolta a destra',
    ManeuverType.slightRight => 'Leggermente a destra',
    _ => 'Prosegui',
  };
  final along = s.leg.cumulative[m.pointIndex.clamp(0, s.leg.lastVertex)];
  final n = (((along - s.along) / 10).round() * 10).clamp(0, 1 << 30);
  final st = m.street;
  return '$what${st == null || st.isEmpty ? '' : ' su $st'} tra $n m';
}

/// Asks before a running trip ends; true when the user confirms.
Future<bool> confirmEndTrip(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Terminare il viaggio?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Termina'),
          ),
        ],
      ),
    ) ==
    true;

class LiveStrip extends ConsumerWidget {
  const LiveStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(liveTripProvider);
    if (live == null) return const SizedBox.shrink();
    final controller = ref.read(liveTripProvider.notifier);
    final theme = Theme.of(context);
    final boarding =
        live.leg.kind == LegKind.walk &&
        !live.isLastLeg &&
        live.route.legs[live.legIndex + 1].kind == LegKind.ride;
    // At the stop: the walk is done, what matters is the bus (rider request).
    final waiting =
        waitingLabel(live, ref.watch(transitIndexProvider).valueOrNull);

    // Back during a ride would close the app mid-trip: ask, then end it.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await confirmEndTrip(context)) controller.stop();
      },
      child: Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        elevation: 8,
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(Gap.screen),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (live.offRoute)
                  _RecalculateBanner(
                    onRecalculate: () {
                      if (live.leg.kind == LegKind.walk &&
                          controller.recalculateWalk()) {
                        return;
                      }
                      // Replan from where the rider is now (no fix: same query).
                      final fix = controller.lastFix;
                      controller.stop();
                      final plan = ref.read(tripPlanProvider.notifier);
                      if (fix != null) {
                        plan.setFrom(
                          Place(
                            name: 'La mia posizione',
                            address: '',
                            lat: fix.lat,
                            lon: fix.lon,
                          ),
                        );
                        plan.setWhen(WhenMode.now);
                      }
                      plan.plan();
                    },
                  ),
                Row(
                  children: [
                    Icon(
                      waiting != null
                          ? Icons.hourglass_top
                          : live.leg.kind == LegKind.ride
                          ? Icons.directions_bus
                          : Icons.directions_walk,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: Gap.element),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            waiting ?? liveLabel(live),
                            style: theme.textTheme.titleMedium,
                          ),
                          if (waiting != null && live.leg.endName.isNotEmpty)
                            Text(
                              'alla fermata ${live.leg.endName}',
                              style: theme.textTheme.bodyMedium,
                            ),
                          if (waiting == null &&
                              live.leg.kind == LegKind.walk &&
                              maneuverLabel(live) != null)
                            Text(
                              maneuverLabel(live)!,
                              style: theme.textTheme.bodyMedium,
                            ),
                          if (live.estimated)
                            Text(
                              'posizione stimata',
                              style: theme.textTheme.bodySmall,
                            ),
                          _LiveStatsLines(live: live),
                        ],
                      ),
                    ),
                    if (live.leg.kind == LegKind.walk && waiting == null)
                      TextButton(
                        onPressed: controller.recalculateWalk,
                        child: const Text('Ricalcola'),
                      ),
                    IconButton(
                      tooltip: 'Termina il viaggio',
                      onPressed: controller.stop,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: Gap.element),
                Row(
                  children: [
                    Expanded(
                      // Always available: the sensors are a help, not a gate.
                      child: FilledButton.tonal(
                        onPressed: controller.manualAdvance,
                        child: Text(
                          live.leg.kind == LegKind.ride
                              ? 'Sono sceso'
                              : boarding
                              ? 'Sono salito'
                              : 'Sono arrivato',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}

class _RecalculateBanner extends StatelessWidget {
  const _RecalculateBanner({required this.onRecalculate});

  final VoidCallback onRecalculate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.element),
      padding: const EdgeInsets.all(Gap.element),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Sembri fuori percorso',
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ),
          TextButton(onPressed: onRecalculate, child: const Text('Ricalcola')),
        ],
      ),
    );
  }
}

/// When the next vehicle comes (or the ride reaches the stop), then the whole
/// trip: arrival, time left, distance left. Ticks on its own so a countdown
/// moves without a new fix (a phone in a pocket on a bus gets few).
class _LiveStatsLines extends ConsumerStatefulWidget {
  const _LiveStatsLines({required this.live});

  final LiveTripState live;

  @override
  ConsumerState<_LiveStatsLines> createState() => _LiveStatsLinesState();
}

class _LiveStatsLinesState extends ConsumerState<_LiveStatsLines> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
        const Duration(seconds: 15), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ix = ref.watch(transitIndexProvider).valueOrNull;
    if (ix == null) return const SizedBox.shrink();
    final delays = ref.watch(delayLookupProvider);
    final live = widget.live;
    final stats = liveStats(
      live,
      delayOf: (i, {atAlight = false}) =>
          legDelay(ix, delays, live.journey.legs[i], atAlight: atAlight),
    );
    final now = DateTime.now();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    String when(DateTime at, int? delay) => [
          'alle ${hhmm(at)}',
          untilLabel(at, now),
          delayLabel(delay) ?? 'programmato',
        ].join(' · ');

    final next = stats.nextDeparture == null
        ? null
        : '${stats.nextLine == null ? 'Il mezzo' : 'Il ${stats.nextLine}'} '
            'passa ${when(stats.nextDeparture!, stats.nextDelay)}';
    final alight = stats.alightAt == null
        ? null
        : 'Arrivo in fermata ${when(stats.alightAt!, stats.alightDelay)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (next ?? alight case final line?)
          Text(line, style: theme.textTheme.bodyMedium),
        Text(
          'Destinazione ${hhmm(stats.arrival)} · '
          '${untilLabel(stats.arrival, now)} · '
          '${metresLabel(stats.metresLeft)}'
          '${stats.arrivalDelayKnown ? '' : ' · orario programmato'}',
          style: muted,
        ),
      ],
    );
  }
}


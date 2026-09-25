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
import 'package:piedemove/realtime/store.dart'
    show delayLookupProvider, unavailableLookupProvider;
import 'package:piedemove/routing/departures.dart' show Departure;
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
String? waitingLabel(LiveTripState s, TransitIndex? ix, {Departure? coming}) {
  if (!s.reachedBoardStop || s.riding || s.isLastLeg) return null;
  final i = s.legIndex + 1;
  if (i >= s.journey.legs.length) return null;
  final ride = s.journey.legs[i];
  if (ride.kind != LegKind.ride || ride.options.isEmpty) return null;
  // The line actually coming next, when the live departures know it.
  final line = coming?.routeShortName ?? ride.options.first.routeShortName;
  final pattern = coming?.pattern ?? ride.options.first.pattern;
  final others = <String>{
    for (final o in ride.options) o.routeShortName,
  }..remove(line);
  final head = ix == null
      ? ''
      : ' per ${cleanStopName(ix.stopNames[ix.patternStopAt(pattern, ix.patternLength(pattern) - 1)])}';
  return 'Aspetta il $line$head'
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

class LiveStrip extends ConsumerStatefulWidget {
  const LiveStrip({super.key});

  @override
  ConsumerState<LiveStrip> createState() => _LiveStripState();
}

/// Read at a glance (rider report, beta 6): one big instruction, one detail
/// line, a big countdown tile, and three stat tiles. It ticks every 10 s so
/// countdowns move without a fix; delays arrive with every realtime poll.
class _LiveStripState extends ConsumerState<LiveStrip> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
        const Duration(seconds: 10), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = ref.watch(liveTripProvider);
    if (live == null) return const SizedBox.shrink();
    final ix = ref.watch(transitIndexProvider).valueOrNull;
    final controller = ref.read(liveTripProvider.notifier);
    final theme = Theme.of(context);
    final now = DateTime.now();
    final stats = ix == null
        ? null
        : liveStats(live, ix,
            now: now,
            delays: ref.watch(delayLookupProvider),
            unavailable: ref.watch(unavailableLookupProvider));
    final boarding =
        live.leg.kind == LegKind.walk &&
        !live.isLastLeg &&
        live.route.legs[live.legIndex + 1].kind == LegKind.ride;
    // At the stop: the walk is done, what matters is the bus.
    final waiting = waitingLabel(live, ix, coming: stats?.next);

    final (title, detail) = switch (live) {
      _ when waiting != null => (
          waiting,
          live.leg.endName.isEmpty ? null : 'alla fermata ${live.leg.endName}',
        ),
      _ when live.riding => (
          liveLabel(live),
          stats?.alightAt == null
              ? null
              : 'arrivo in fermata ${hhmm(stats!.alightAt!)}'
                  '${delayLabel(stats.alightDelay) == null ? '' : ' · ${delayLabel(stats.alightDelay)}'}',
        ),
      _ => (liveLabel(live), maneuverLabel(live)),
    };

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
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (live.offRoute)
                    _RecalculateBanner(
                      onRecalculate: () => _recalculate(live, controller),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: theme.textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            if (detail != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  detail,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant),
                                ),
                              ),
                            if (live.estimated)
                              Text('posizione stimata',
                                  style: theme.textTheme.bodySmall),
                          ],
                        ),
                      ),
                      const SizedBox(width: Gap.element),
                      _Hero(live: live, stats: stats, now: now),
                    ],
                  ),
                  if (stats != null) ...[
                    const SizedBox(height: Gap.element),
                    _StatTiles(stats: stats, now: now),
                  ],
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _recalculate(LiveTripState live, LiveTripController controller) {
    if (live.leg.kind == LegKind.walk && controller.recalculateWalk()) return;
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
  }
}

/// The one number that matters now, big: minutes to the bus, stops to the
/// alight stop, or metres of walking left - with its time underneath.
class _Hero extends StatelessWidget {
  const _Hero({required this.live, required this.stats, required this.now});

  final LiveTripState live;
  final LiveStats? stats;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final next = stats?.next;
    final String big, unit;
    String? caption, caption2;
    Color? captionColor;
    if (live.riding) {
      final n = live.stopsRemaining;
      big = n <= 0 ? 'ORA' : '$n';
      unit = n <= 0 ? 'scendi' : (n == 1 ? 'fermata' : 'fermate');
      if (stats?.alightAt != null) caption = hhmm(stats!.alightAt!);
    } else if (next != null) {
      final m = minutesUntil(next.time, now);
      big = m == 0 ? 'ORA' : '$m';
      unit = m == 0 ? 'in arrivo' : 'min';
      caption = '${next.routeShortName} · ${hhmm(next.time)}';
      final d = delayLabel(next.delaySeconds);
      caption2 = d ?? 'programmato';
      captionColor = next.delaySeconds == null
          ? theme.colorScheme.onSurfaceVariant
          : next.delaySeconds! >= 120
          ? theme.colorScheme.error
          : tokens.live;
      if (stats?.then != null) {
        caption2 = '$caption2 · poi ${hhmm(stats!.then!.time)}';
      }
    } else {
      final metres = ((live.metresToEnd / 10).round() * 10).clamp(0, 1 << 30);
      big = metres >= 1000 ? (metres / 1000).toStringAsFixed(1) : '$metres';
      unit = metres >= 1000 ? 'km' : 'm';
    }
    return Container(
      constraints: const BoxConstraints(minWidth: 96),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            big,
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: theme.colorScheme.onPrimaryContainer,
              height: 1.0,
            ),
          ),
          Text(unit,
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.onPrimaryContainer)),
          if (caption != null)
            Text(caption,
                style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700)),
          if (caption2 != null)
            Text(caption2,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: captionColor, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

/// Arrival, time left, distance left: three tiles, value first.
class _StatTiles extends StatelessWidget {
  const _StatTiles({required this.stats, required this.now});

  final LiveStats stats;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final left = stats.arrival.difference(now).inSeconds;
    return Row(
      children: [
        _Tile(
          icon: Icons.flag_outlined,
          value: hhmm(stats.arrival),
          label: stats.arrivalLive ? 'arrivo' : 'arrivo (orario)',
        ),
        const SizedBox(width: 8),
        _Tile(
          icon: Icons.timer_outlined,
          value: left <= 0 ? 'ora' : durationLabel(left),
          label: 'mancano',
        ),
        const SizedBox(width: 8),
        _Tile(
          icon: Icons.straighten,
          value: metresLabel(stats.metresLeft),
          label: 'da fare',
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.value, required this.label});

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
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

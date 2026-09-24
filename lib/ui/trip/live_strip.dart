/// The live trip strip (§12): one compact bar that says what to do next, the
/// manual board/alight button, and the one-tap "Ricalcola" banner.
///
/// It never recalculates by itself — off route only raises the banner.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/geo/walk_router.dart';
import 'package:piedemove/location/live_trip.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/trip/trip_plan.dart';

/// `Scendi a Peschiera tra 3 fermate`, `A piedi: Trapani tra 120 m`.
String liveLabel(LiveTripState s) {
  final leg = s.leg;
  final name = leg.endName;
  if (leg.kind == LegKind.ride) {
    if (s.stopsRemaining <= 0) return 'Scendi ora${name.isEmpty ? '' : ' a $name'}';
    if (s.stopsRemaining == 1) return 'Scendi a $name alla prossima fermata';
    return 'Scendi a $name tra ${s.stopsRemaining} fermate';
  }
  return walkStripText(s);
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

class LiveStrip extends ConsumerWidget {
  const LiveStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(liveTripProvider);
    if (live == null) return const SizedBox.shrink();
    final controller = ref.read(liveTripProvider.notifier);
    final theme = Theme.of(context);
    final boarding = live.leg.kind == LegKind.walk &&
        !live.isLastLeg &&
        live.route.legs[live.legIndex + 1].kind == LegKind.ride;

    return Align(
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
                      controller.stop();
                      ref.read(tripPlanProvider.notifier).plan();
                    },
                  ),
                Row(
                  children: [
                    Icon(
                      live.leg.kind == LegKind.ride
                          ? Icons.directions_bus
                          : Icons.directions_walk,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: Gap.element),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(liveLabel(live),
                              style: theme.textTheme.titleMedium),
                          if (live.leg.kind == LegKind.walk &&
                              maneuverLabel(live) != null)
                            Text(maneuverLabel(live)!,
                                style: theme.textTheme.bodyMedium),
                          if (live.estimated)
                            Text('posizione stimata',
                                style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                    if (live.leg.kind == LegKind.walk)
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

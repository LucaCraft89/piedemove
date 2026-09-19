/// Trip results (§11.4) and trip detail (§11.6) in one draggable sheet.
///
/// Arrival and duration lead each card; walking is a bold coloured chip beside
/// them; every serving line of a leg is on the badge row. The detail page is the
/// same sheet with a back arrow, so there is one navigation model, not two.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/routing/providers.dart';
import 'package:piedemove/ui/nav/entity.dart';
import 'package:piedemove/ui/sheets/alert_sheet.dart';
import 'package:piedemove/ui/sheets/sheet_parts.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/widgets/line_badge.dart';

import 'trip_format.dart';
import 'trip_plan.dart';

/// The countdowns are minute-grained; a 20 s tick keeps them honest.
const _tick = Duration(seconds: 20);

class TripSheet extends ConsumerStatefulWidget {
  const TripSheet({super.key});

  @override
  ConsumerState<TripSheet> createState() => _TripSheetState();
}

class _TripSheetState extends ConsumerState<TripSheet> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_tick, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final trip = ref.watch(tripPlanProvider);
    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.15,
      maxChildSize: 0.92,
      snap: true,
      snapSizes: const [0.15, 0.5, 0.92],
      builder: (context, controller) => Material(
        elevation: 8,
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: trip.selected == null
            ? _Results(controller: controller, now: DateTime.now())
            : _Detail(
                controller: controller,
                index: trip.selected!,
                now: DateTime.now(),
              ),
      ),
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({required this.controller, required this.now});

  final ScrollController controller;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trip = ref.watch(tripPlanProvider);
    final plan = ref.read(tripPlanProvider.notifier);
    final result = trip.result;
    final alerts = ref.watch(activeAlertsProvider);
    final journeys = result?.forTab(trip.tab) ?? const <Journey>[];

    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(Gap.screen, 0, Gap.screen, Gap.screen),
      children: [
        const Grabber(),
        Row(
          children: [
            Expanded(
              child: Text(
                trip.planning ? 'Cerco percorsi…' : 'Percorsi',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            IconButton(
              tooltip: 'Ricalcola',
              onPressed: trip.planning ? null : plan.plan,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: 'Chiudi i percorsi',
              onPressed: plan.hideSheet,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        if (alerts.isNotEmpty)
          _AlertBanner(count: alerts.length, onTap: () => showAlertList(context, ref)),
        SegmentedButton<TripTab>(
          segments: const [
            ButtonSegment(value: TripTab.fastest, label: Text('Più veloce')),
            ButtonSegment(value: TripTab.balanced, label: Text('Bilanciato')),
          ],
          selected: {trip.tab},
          onSelectionChanged: (s) => plan.setTab(s.first),
        ),
        const SizedBox(height: Gap.element),
        if (trip.planning)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: Gap.screen),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (result == null)
          const Text('Scegli partenza e arrivo, poi cerca.')
        else if (result.failed)
          const Text('Non è stato possibile calcolare il percorso.')
        else if (journeys.isEmpty)
          const Text('Nessun percorso con questi limiti. '
              'Prova ad alzare il cammino massimo o i minuti in più.')
        else
          for (final (i, j) in journeys.indexed)
            _JourneyCard(
              journey: j,
              now: now,
              onTap: () => plan.select(i),
            ),
      ],
    );
  }
}

class _AlertBanner extends StatelessWidget {
  const _AlertBanner({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.element),
      child: Material(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Gap.element),
            child: Row(
              children: [
                Icon(Icons.warning_amber, color: scheme.onErrorContainer),
                const SizedBox(width: Gap.element),
                Expanded(
                  child: Text(
                    count == 1
                        ? '1 avviso di servizio attivo'
                        : '$count avvisi di servizio attivi',
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
                Icon(Icons.chevron_right, color: scheme.onErrorContainer),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _JourneyCard extends ConsumerWidget {
  const _JourneyCard({
    required this.journey,
    required this.now,
    required this.onTap,
  });

  final Journey journey;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final departure = journey.timeOf(journey.departure);
    final arrival = journey.timeOf(journey.arrival);
    final walk = journey.walkMetres;
    final firstRide =
        journey.legs.where((l) => l.kind == LegKind.ride).firstOrNull;
    final delay = firstRide == null
        ? null
        : rideDelaySeconds(ref, firstRide, firstRide.options.firstOrNull);

    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.element),
      child: Card(
        color: theme.colorScheme.surfaceContainerHighest,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Gap.element),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '${hhmm(departure)} → ${hhmm(arrival)}',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(width: Gap.element),
                    Text(
                      durationLabel(journey.durationSeconds),
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    _WalkChip(metres: walk),
                  ],
                ),
                const SizedBox(height: 8),
                _LegChain(journey: journey),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      leavesInLabel(departure, now),
                      style: theme.textTheme.bodyMedium,
                    ),
                    Text('· ${transfersLabel(journey.transfers)}',
                        style: theme.textTheme.bodySmall),
                    if (delay != null && delay.abs() >= 60)
                      _MiniChip(
                        label: delay > 0
                            ? '+${delay ~/ 60} min'
                            : '${delay ~/ 60} min',
                        color: tokens.live,
                      ),
                    for (var i = 0; i < journey.legs.length; i++)
                      if (tightConnection(journey, i))
                        _MiniChip(
                          label: 'cambio stretto',
                          color: theme.colorScheme.error,
                        ),
                  ],
                ),
                if (journey.detoured) const _DetourBanner(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Walking metres are the cost: bold, coloured by tier, never grey.
class _WalkChip extends StatelessWidget {
  const _WalkChip({required this.metres});

  final double metres;

  @override
  Widget build(BuildContext context) {
    final color = context.tokens.walk.ofMetres(metres);
    return Semantics(
      label: 'A piedi ${metres.round()} metri',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.directions_walk, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              metresLabel(metres),
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      );
}

class _DetourBanner extends StatelessWidget {
  const _DetourBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(Icons.alt_route, size: 16, color: scheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text('Linea deviata',
                style: TextStyle(color: scheme.error)),
          ),
        ],
      ),
    );
  }
}

/// Walk · badges · walk, in order, with every serving line on each ride.
class _LegChain extends StatelessWidget {
  const _LegChain({required this.journey});

  final Journey journey;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final leg in journey.legs) {
      if (leg.kind == LegKind.walk) {
        if (leg.walkMetres < 1) continue;
        final color = context.tokens.walk.ofMetres(leg.walkMetres);
        children.add(Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.directions_walk, size: 16, color: color),
            Text(metresLabel(leg.walkMetres),
                style: TextStyle(color: color, fontWeight: FontWeight.w700)),
          ],
        ));
      } else {
        children.add(Wrap(
          spacing: 4,
          children: [
            for (final o in leg.options.take(6))
              LineBadge(shortName: o.routeShortName, routeType: o.routeType),
          ],
        ));
      }
    }
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}

/// Trip detail (§11.6): walk, ride, transfer, ride, walk — everything tappable.
class _Detail extends ConsumerWidget {
  const _Detail({
    required this.controller,
    required this.index,
    required this.now,
  });

  final ScrollController controller;
  final int index;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trip = ref.watch(tripPlanProvider);
    final plan = ref.read(tripPlanProvider.notifier);
    final ix = ref.watch(transitIndexProvider).valueOrNull;
    final journeys = trip.result?.forTab(trip.tab) ?? const <Journey>[];
    if (ix == null || index >= journeys.length) {
      return const SizedBox.shrink();
    }
    final journey = journeys[index];
    final theme = Theme.of(context);

    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(Gap.screen, 0, Gap.screen, Gap.screen),
      children: [
        const Grabber(),
        Row(
          children: [
            IconButton(
              tooltip: 'Indietro',
              onPressed: plan.back,
              icon: const Icon(Icons.arrow_back),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${hhmm(journey.timeOf(journey.departure))} → '
                    '${hhmm(journey.timeOf(journey.arrival))}',
                    style: theme.textTheme.titleLarge,
                  ),
                  Text(
                    '${durationLabel(journey.durationSeconds)} · '
                    '${transfersLabel(journey.transfers)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            _WalkChip(metres: journey.walkMetres),
          ],
        ),
        const SizedBox(height: Gap.element),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: plan.plan,
                icon: const Icon(Icons.refresh),
                label: const Text('Ricalcola'),
              ),
            ),
            const SizedBox(width: Gap.element),
            Expanded(
              // Live trip is phase 7: it needs a real ride to verify.
              child: FilledButton.icon(
                onPressed: null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Avvia'),
              ),
            ),
          ],
        ),
        if (journey.detoured) const _DetourBanner(),
        for (final (i, leg) in journey.legs.indexed)
          if (leg.kind == LegKind.walk)
            _WalkStep(journey: journey, leg: leg, ix: ix)
          else
            _RideStep(
              journey: journey,
              leg: leg,
              ix: ix,
              tight: tightConnection(journey, i),
              now: now,
            ),
      ],
    );
  }
}

class _WalkStep extends ConsumerWidget {
  const _WalkStep({required this.journey, required this.leg, required this.ix});

  final Journey journey;
  final Leg leg;
  final TransitIndex ix;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (leg.walkMetres < 1) return const SizedBox.shrink();
    final color = context.tokens.walk.ofMetres(leg.walkMetres);
    final transfer = leg.fromStop >= 0 && leg.toStop >= 0;
    final target = leg.toStop >= 0 ? leg.toStop : leg.fromStop;
    final name = target >= 0 ? cleanStopName(ix.stopNames[target]) : null;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minTileHeight: Gap.row,
      leading: Icon(Icons.directions_walk, color: color),
      title: Text(
        '${transfer ? 'Cambio' : 'A piedi'} '
        '${metresLabel(leg.walkMetres)} · '
        '${durationLabel(leg.arrival - leg.departure)}',
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
      subtitle: name == null
          ? null
          : Text(leg.toStop >= 0 ? 'fino a $name' : 'da $name'),
      onTap: target < 0
          ? null
          : () => openEntity(context, ref, StopRef(target)),
    );
  }
}

class _RideStep extends ConsumerStatefulWidget {
  const _RideStep({
    required this.journey,
    required this.leg,
    required this.ix,
    required this.tight,
    required this.now,
  });

  final Journey journey;
  final Leg leg;
  final TransitIndex ix;
  final bool tight;
  final DateTime now;

  @override
  ConsumerState<_RideStep> createState() => _RideStepState();
}

class _RideStepState extends ConsumerState<_RideStep> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final ix = widget.ix;
    final leg = widget.leg;
    final journey = widget.journey;
    final theme = Theme.of(context);
    final chosen = leg.options.firstOrNull;
    final headsign = chosen == null
        ? ''
        : cleanStopName(ix.stopNames[ix.patternStopAt(
            chosen.pattern, ix.patternLength(chosen.pattern) - 1)]);
    final stops = chosen == null
        ? const <(int, int)>[]
        : intermediateStops(ix, chosen, leg.fromStop, leg.toStop);
    final delay = rideDelaySeconds(ref, leg, chosen);
    // Where the vehicle is right now, from the trip update: GTT sends no trip
    // id on a vehicle, so the position comes from the delay, not the feed.
    final midnight = DateTime(
        journey.date.year, journey.date.month, journey.date.day);
    final scheduled = [
      leg.departure,
      for (final (_, seconds) in stops) seconds,
      leg.arrival,
    ];
    final passed = delay == null
        ? null
        : lastPassedIndex(
            scheduled, delay, widget.now.difference(midnight).inSeconds);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: Gap.element),
        Row(
          children: [
            Wrap(
              spacing: 4,
              children: [
                for (final o in leg.options.take(6))
                  InkWell(
                    onTap: () => openEntity(
                      context,
                      ref,
                      LineRef(ix.patternRoute[o.pattern],
                          direction: ix.patternDir[o.pattern]),
                    ),
                    child: LineBadge(
                      shortName: o.routeShortName,
                      routeType: o.routeType,
                    ),
                  ),
              ],
            ),
            const SizedBox(width: Gap.element),
            Expanded(
              child: Text(headsign,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('${hhmm(journey.timeOf(leg.departure))} → '
                '${hhmm(journey.timeOf(leg.arrival))}'),
            if (delay != null)
              _MiniChip(
                label: delay.abs() < 60
                    ? 'in orario'
                    : (delay > 0 ? '+${delay ~/ 60} min' : '${delay ~/ 60} min'),
                color: context.tokens.live,
              )
            else
              Text('Programmato', style: theme.textTheme.bodySmall),
            if (widget.tight)
              _MiniChip(
                label: 'cambio stretto',
                color: theme.colorScheme.error,
              ),
          ],
        ),
        if (leg.fromStop >= 0)
          _StopLine(
            stop: leg.fromStop,
            label: 'Sali a ${cleanStopName(ix.stopNames[leg.fromStop])}',
            live: passed == 0,
          ),
        if (stops.isNotEmpty)
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18),
                  const SizedBox(width: 4),
                  Text('${stops.length} fermate',
                      style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ),
        if (_open)
          for (final (i, (stop, seconds)) in stops.indexed)
            _StopLine(
              stop: stop,
              label: '${hhmm(journey.timeOf(seconds))}  '
                  '${cleanStopName(ix.stopNames[stop])}',
              dense: true,
              live: passed == i + 1,
            ),
        if (leg.toStop >= 0)
          _StopLine(
            stop: leg.toStop,
            label: 'Scendi a ${cleanStopName(ix.stopNames[leg.toStop])}',
            live: passed == scheduled.length - 1,
          ),
        if (leg.options.length > 1) ...[
          const SheetSection('Altre linee per questa tratta'),
          for (final o in leg.options.skip(1).take(6))
            Row(
              children: [
                LineBadge(shortName: o.routeShortName, routeType: o.routeType),
                const SizedBox(width: Gap.element),
                Text(hhmm(journey.timeOf(o.departure))),
                if (o.detoured) ...[
                  const SizedBox(width: Gap.element),
                  const Expanded(child: _DetourBanner()),
                ],
              ],
            ),
        ],
      ],
    );
  }
}

class _StopLine extends ConsumerWidget {
  const _StopLine({
    required this.stop,
    required this.label,
    this.dense = false,
    this.live = false,
  });

  final int stop;
  final String label;
  final bool dense;

  /// The stop the live vehicle has just reached: marked by an icon as well as
  /// a colour, never by colour alone.
  final bool live;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final base = dense
        ? Theme.of(context).textTheme.bodySmall
        : Theme.of(context).textTheme.bodyMedium;
    return InkWell(
      onTap: () => openEntity(context, ref, StopRef(stop)),
      child: Container(
        constraints: BoxConstraints(minHeight: dense ? 32 : Gap.tapTarget),
        alignment: Alignment.centerLeft,
        padding: EdgeInsets.only(left: dense && !live ? Gap.screen : 0),
        child: Row(
          children: [
            if (live) ...[
              Semantics(
                label: 'Il mezzo è qui',
                child: Icon(Icons.trip_origin,
                    size: 14, color: context.tokens.live),
              ),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text(
                label,
                style: live
                    ? base?.copyWith(
                        color: context.tokens.live,
                        fontWeight: FontWeight.w700,
                      )
                    : base,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Stops strictly between the board and alight stops of [option], each with
/// its scheduled arrival second on the journey's clock. Empty when the pair is
/// not on the pattern.
List<(int stop, int seconds)> intermediateStops(
  TransitIndex ix,
  RideOption option,
  int fromStop,
  int toStop,
) {
  final pattern = option.pattern;
  var from = -1;
  var to = -1;
  for (var pos = 0; pos < ix.patternLength(pattern); pos++) {
    final stop = ix.patternStopAt(pattern, pos);
    if (from < 0 && stop == fromStop) from = pos;
    if (from >= 0 && stop == toStop && pos > from) {
      to = pos;
      break;
    }
  }
  if (from < 0 || to < 0) return const [];
  // Times past 24:00 and previous-day trips are already folded into the leg, so
  // the offset comes from the option itself, never from the raw trip times.
  final offset = option.departure - ix.depOf(option.trip, from);
  return [
    for (var pos = from + 1; pos < to; pos++)
      (ix.patternStopAt(pattern, pos), ix.arrOf(option.trip, pos) + offset),
  ];
}

/// Realtime delay of [option] at the board stop, or null on schedule data.
int? rideDelaySeconds(WidgetRef ref, Leg leg, RideOption? option) {
  if (option == null) return null;
  final ix = ref.read(transitIndexProvider).valueOrNull;
  final delays = ref.watch(delayLookupProvider);
  if (ix == null || delays == null) return null;
  for (var pos = 0; pos < ix.patternLength(option.pattern); pos++) {
    if (ix.patternStopAt(option.pattern, pos) == leg.fromStop) {
      return delays(option.trip, pos);
    }
  }
  return null;
}

/// Stop sheet (§11.5): next arrivals, line filter, lines serving it, alerts.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/routing/departures.dart';
import 'package:piedemove/ui/nav/entity.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/widgets/departure_row.dart';
import 'package:piedemove/ui/widgets/line_badge.dart';

import 'sheet_parts.dart';

class StopBody extends ConsumerStatefulWidget {
  const StopBody({super.key, required this.stop, required this.controller});

  final int stop;
  final ScrollController controller;

  @override
  ConsumerState<StopBody> createState() => _StopBodyState();
}

class _StopBodyState extends ConsumerState<StopBody> {
  String? _filter;

  @override
  Widget build(BuildContext context) {
    final ix = ref.watch(transitIndexProvider).valueOrNull;
    if (ix == null) return const SizedBox.shrink();
    final stop = widget.stop;
    final now = DateTime.now();
    final departures = nextDepartures(
      ix,
      stop,
      now,
      20,
      delays: ref.watch(delayLookupProvider),
    );
    final alerts = ref
        .watch(realtimeProvider)
        .alertsFor(stopId: ix.stopIds[stop]);

    final routes = ix.routesAt(stop);
    final shown = _filter == null
        ? departures
        : [for (final d in departures) if (d.routeShortName == _filter) d];

    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.all(Gap.screen),
      children: [
        const Grabber(),
        SheetHeader(
          title: cleanStopName(ix.stopNames[stop]),
          subtitle: 'Fermata ${ix.stopCodes[stop]}',
        ),
        AlertTiles(alerts: alerts),
        if (routes.length > 1)
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final route in routes)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      selected: _filter == ix.routeShortNames[route],
                      label: Text(ix.routeShortNames[route]),
                      onSelected: (on) => setState(
                        () => _filter = on ? ix.routeShortNames[route] : null,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const SheetSection('Prossimi passaggi'),
        if (shown.isEmpty)
          const Text('Nessuna corsa nelle prossime ore.')
        else
          for (final d in shown)
            InkWell(
              onTap: () => openEntity(
                context,
                ref,
                LineRef(ix.patternRoute[d.pattern],
                    direction: ix.patternDir[d.pattern]),
              ),
              child: DepartureRow(departure: d, now: now),
            ),
        const SheetSection('Linee'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final route in routes)
              InkWell(
                onTap: () => openEntity(context, ref, LineRef(route)),
                child: LineBadge(
                  shortName: ix.routeShortNames[route],
                  routeType: ix.routeTypes[route],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Stop sheet (§11.5): next arrivals, line filter, lines serving it, alerts.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/distance.dart';
import 'package:piedemove/geo/line_providers.dart';
import 'package:piedemove/places/favourites.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/routing/departures.dart';
import 'package:piedemove/ui/nav/entity.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/widgets/departure_row.dart';
import 'package:piedemove/ui/widgets/line_badge.dart';

import 'sheet_parts.dart';

/// Entrances of [entrances] within [radius] of a point, nearest first (§10.5).
List<(String name, double metres)> entrancesNear(
  Map<String, dynamic>? entrances,
  double lat,
  double lon, {
  double radius = 150,
}) {
  final out = <(String, double)>[];
  for (final f in (entrances?['features'] as List? ?? const [])) {
    final feature = f as Map<String, dynamic>;
    final c = (feature['geometry'] as Map)['coordinates'] as List;
    final d = haversineMetres(
        lat, lon, (c[1] as num).toDouble(), (c[0] as num).toDouble());
    if (d > radius) continue;
    final name =
        ((feature['properties'] as Map?)?['name'] ?? '').toString();
    out.add((name.isEmpty ? 'Ingresso metro' : name, d));
  }
  out.sort((a, b) => a.$2.compareTo(b.$2));
  return out;
}

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
      unavailable: ref.watch(unavailableLookupProvider),
    );
    final alerts = ref
        .watch(realtimeProvider)
        .alertsFor(stopId: ix.stopIds[stop]);

    final routes = ix.routesAt(stop);
    final isMetro =
        routes.any((r) => ix.routeTypes[r] == RouteType.metro);
    final entrances = isMetro
        ? entrancesNear(
            ref.watch(metroEntrancesProvider).valueOrNull,
            ix.stopLat[stop],
            ix.stopLon[stop],
          )
        : const <(String, double)>[];
    final shown = _filter == null
        ? departures
        : [for (final d in departures) if (d.routeShortName == _filter) d];
    // The same stop's other poles (usually the other direction, across the
    // street): search lists a stop once, so they are one tap from here.
    final clusters = ref.watch(stopClustersProvider);
    final siblings = clusters == null
        ? const <int>[]
        : [
            for (final m in clusters.members[clusters.clusterOfStop[stop]])
              if (m != stop &&
                  ix.stopPatternOffset[m] != ix.stopPatternOffset[m + 1])
                m,
          ];

    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.all(Gap.screen),
      children: [
        const Grabber(),
        SheetHeader(
          title: cleanStopName(ix.stopNames[stop]),
          subtitle: 'Fermata ${ix.stopCodes[stop]}',
          trailing: FavouriteButton(stopFavourite(ix.stopIds[stop])),
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
        if (siblings.isNotEmpty) ...[
          const SheetSection('Stessa fermata, altri pali'),
          for (final m in siblings)
            ListTile(
              contentPadding: EdgeInsets.zero,
              minTileHeight: Gap.row,
              leading: const Icon(Icons.signpost_outlined),
              title: Text('Fermata ${ix.stopCodes[m]}'),
              subtitle: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final r in ix.routesAt(m).take(8))
                    LineBadge(
                      shortName: ix.routeShortNames[r],
                      routeType: ix.routeTypes[r],
                    ),
                ],
              ),
              onTap: () => openEntity(context, ref, StopRef(m)),
            ),
        ],
        if (entrances.isNotEmpty) ...[
          const SheetSection('Ingressi della metro'),
          for (final (name, metres) in entrances)
            ListTile(
              contentPadding: EdgeInsets.zero,
              minTileHeight: Gap.row,
              leading: Icon(Icons.subdirectory_arrow_right,
                  color: context.tokens.modes.metro),
              title: Text(name),
              trailing: Text('${metres.round()} m'),
            ),
        ],
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
        RawData(
          'stop_id ${ix.stopIds[stop]}\n'
          'stop_code ${ix.stopCodes[stop]}\n'
          'stop_name ${ix.stopNames[stop]}\n'
          'lat ${ix.stopLat[stop]}\nlon ${ix.stopLon[stop]}\n'
          'index $stop\n'
          'routes ${[for (final r in routes) ix.routeShortNames[r]].join(', ')}',
        ),
      ],
    );
  }
}

/// Line sheet (§11.5): itinerary with a direction toggle, service span and
/// frequency, live vehicles on the line, alerts.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/realtime/gtfs_rt.dart';
import 'package:piedemove/realtime/link.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/ui/nav/entity.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/widgets/line_badge.dart';

import 'sheet_parts.dart';

/// The longest pattern of [route] in [direction] — the one that reads as "the"
/// itinerary; short workings are subsets of it.
int? representativePattern(TransitIndex ix, int route, int direction) {
  int? best;
  var bestLength = -1;
  for (var p = 0; p < ix.patternCount; p++) {
    if (ix.patternRoute[p] != route || ix.patternDir[p] != direction) continue;
    final length = ix.patternLength(p);
    if (length > bestLength) {
      bestLength = length;
      best = p;
    }
  }
  return best;
}

/// First departures today of every pattern of the route in that direction,
/// sorted. The representative pattern alone is not enough: short workings are
/// separate patterns and often carry most of the service.
List<int> _todayDepartures(
  TransitIndex ix,
  int route,
  int direction,
  DateTime day,
) {
  final dayIndex = ix.dayIndexOf(day);
  final out = <int>[];
  for (var p = 0; p < ix.patternCount; p++) {
    if (ix.patternRoute[p] != route || ix.patternDir[p] != direction) continue;
    for (var t = 0; t < ix.patternTripCount(p); t++) {
      final trip = ix.patternTripAt(p, t);
      if (!ix.serviceRunsOn(ix.tripService[trip], dayIndex)) continue;
      out.add(ix.depOf(trip, 0));
    }
  }
  out.sort();
  return out;
}

String _hhmm(int seconds) {
  final s = seconds % 86400;
  return '${(s ~/ 3600).toString().padLeft(2, '0')}:'
      '${(s % 3600 ~/ 60).toString().padLeft(2, '0')}';
}

/// Median gap, in minutes; null with fewer than two runs.
int? _headwayMinutes(List<int> departures) {
  if (departures.length < 2) return null;
  final gaps = [
    for (var i = 1; i < departures.length; i++)
      departures[i] - departures[i - 1],
  ]..sort();
  return gaps[gaps.length ~/ 2] ~/ 60;
}

class LineBody extends ConsumerWidget {
  const LineBody({
    super.key,
    required this.route,
    required this.direction,
    required this.controller,
  });

  final int route;
  final int direction;
  final ScrollController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ix = ref.watch(transitIndexProvider).valueOrNull;
    if (ix == null) return const SizedBox.shrink();
    final rt = ref.watch(realtimeProvider);
    final pattern = representativePattern(ix, route, direction) ??
        representativePattern(ix, route, 1 - direction);
    final alerts = rt.alertsFor(routeId: ix.routeIds[route]);
    final vehicles = vehiclesOnRoute(ix, rt, route);
    final departures = _todayDepartures(ix, route, direction, DateTime.now());
    final headway = _headwayMinutes(departures);

    return ListView(
      controller: controller,
      padding: const EdgeInsets.all(Gap.screen),
      children: [
        const Grabber(),
        SheetHeader(
          title: ix.routeLongNames[route].isEmpty
              ? 'Linea ${ix.routeShortNames[route]}'
              : ix.routeLongNames[route],
          subtitle: pattern == null
              ? null
              : 'Capolinea: ${cleanStopName(ix.stopNames[ix.patternStopAt(pattern, ix.patternLength(pattern) - 1)])}',
          leading: LineBadge(
            shortName: ix.routeShortNames[route],
            routeType: ix.routeTypes[route],
          ),
        ),
        AlertTiles(alerts: alerts),
        const SizedBox(height: Gap.element),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('Andata')),
            ButtonSegment(value: 1, label: Text('Ritorno')),
          ],
          selected: {direction},
          onSelectionChanged: (s) {
            // A direction change is a replacement, not a new level.
            ref.read(entityNavProvider.notifier)
              ..pop()
              ..push(LineRef(route, direction: s.first));
          },
        ),
        if (departures.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.element),
            child: Text(
              'Oggi ${_hhmm(departures.first)}–${_hhmm(departures.last)}'
              '${headway == null ? '' : ' · ogni ~$headway min'}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        if (vehicles.isNotEmpty) ...[
          const SheetSection('Veicoli in linea'),
          for (final v in vehicles)
            ListTile(
              contentPadding: EdgeInsets.zero,
              minTileHeight: Gap.row,
              leading: Icon(modeIcon(ix.routeTypes[route]),
                  color: context.tokens.live),
              title: Text(v.label ?? v.id),
              subtitle: Text(statusLabel(v.status)),
              onTap: () => openEntity(context, ref, VehicleRef(v.id)),
            ),
        ],
        const SheetSection('Percorso'),
        if (pattern == null)
          const Text('Percorso non disponibile.')
        else
          for (var p = 0; p < ix.patternLength(pattern); p++)
            StopStep(
              name: cleanStopName(ix.stopNames[ix.patternStopAt(pattern, p)]),
              first: p == 0,
              last: p == ix.patternLength(pattern) - 1,
              onTap: () => openEntity(
                context,
                ref,
                StopRef(ix.patternStopAt(pattern, p)),
              ),
            ),
      ],
    );
  }
}

String statusLabel(VehicleStatus status) => switch (status) {
      VehicleStatus.incomingAt => 'In arrivo alla fermata',
      VehicleStatus.stoppedAt => 'Alla fermata',
      VehicleStatus.inTransitTo => 'In viaggio',
    };

/// Also drawn by the vehicle sheet, with the vehicle's position as [marker].
class StopStep extends StatelessWidget {
  const StopStep({
    super.key,
    required this.name,
    required this.first,
    required this.last,
    required this.onTap,
    this.marker,
  });

  final String name;
  final bool first;
  final bool last;
  final VoidCallback onTap;
  final Widget? marker;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Gap.row),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Icon(
                first
                    ? Icons.trip_origin
                    : (last ? Icons.place : Icons.circle),
                size: first || last ? 14 : 8,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: Gap.element),
            Expanded(
              child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            ?marker,
          ],
        ),
      ),
    );
  }
}

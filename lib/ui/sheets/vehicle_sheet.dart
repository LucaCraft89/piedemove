/// Vehicle sheet (§11.5): line number only (never "Vettura"), direction,
/// status, next stop, delay, and the itinerary with the vehicle's position.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/realtime/link.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/ui/nav/entity.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/widgets/line_badge.dart';

import 'line_sheet.dart' show StopStep, statusLabel;
import 'sheet_parts.dart';

class VehicleBody extends ConsumerWidget {
  const VehicleBody({
    super.key,
    required this.vehicleId,
    required this.controller,
  });

  final String vehicleId;
  final ScrollController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ix = ref.watch(transitIndexProvider).valueOrNull;
    final rt = ref.watch(realtimeProvider);
    final vehicle = rt.vehicles[vehicleId];
    if (ix == null) return const SizedBox.shrink();
    if (vehicle == null) {
      return ListView(
        controller: controller,
        padding: const EdgeInsets.all(Gap.screen),
        children: const [
          Grabber(),
          SheetHeader(title: 'Veicolo non più in linea'),
        ],
      );
    }

    final trip = tripIndexOf(ix, vehicle);
    final route = routeIndexOf(ix, vehicle);
    final pattern = trip == null ? null : ix.tripPattern[trip];
    final position =
        pattern == null ? null : vehiclePosition(ix, pattern, vehicle);
    final delay = trip == null || position == null
        ? null
        : ref.watch(delayLookupProvider)?.call(trip, position);
    final headsign = pattern == null
        ? null
        : cleanStopName(
            ix.stopNames[ix.patternStopAt(pattern, ix.patternLength(pattern) - 1)],
          );

    return ListView(
      controller: controller,
      padding: const EdgeInsets.all(Gap.screen),
      children: [
        const Grabber(),
        SheetHeader(
          // GTT names the route but not the run, so the headsign is often
          // unknown; the line number always carries the identity.
          title: headsign ??
              (route == null
                  ? (vehicle.label ?? vehicle.id)
                  : 'Linea ${ix.routeShortNames[route]}'),
          subtitle: '${statusLabel(vehicle.status)}'
              '${vehicle.label == null ? '' : ' · vettura ${vehicle.label}'}',
          leading: route == null
              ? null
              : LineBadge(
                  shortName: ix.routeShortNames[route],
                  routeType: ix.routeTypes[route],
                ),
        ),
        Row(
          children: [
            _LiveChip(stale: vehicle.timestamp == null),
            const SizedBox(width: Gap.element),
            if (delay != null)
              Text(
                delay >= 60
                    ? '${delay ~/ 60} min di ritardo'
                    : (delay <= -60 ? '${-delay ~/ 60} min in anticipo' : 'In orario'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
          ],
        ),
        if (pattern != null && position != null)
          ListTile(
            contentPadding: EdgeInsets.zero,
            minTileHeight: Gap.row,
            leading: const Icon(Icons.place),
            title: Text(cleanStopName(
                ix.stopNames[ix.patternStopAt(pattern, position)])),
            subtitle: const Text('Prossima fermata'),
            onTap: () => openEntity(
              context,
              ref,
              StopRef(ix.patternStopAt(pattern, position)),
            ),
          ),
        if (route != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => openEntity(
                context,
                ref,
                LineRef(route,
                    direction: pattern == null ? 0 : ix.patternDir[pattern]),
              ),
              icon: const Icon(Icons.timeline),
              label: Text('Linea ${ix.routeShortNames[route]}'),
            ),
          ),
        const SheetSection('Percorso'),
        if (pattern == null)
          const Text('Il feed non indica la corsa in servizio.')
        else
          for (var p = 0; p < ix.patternLength(pattern); p++)
            StopStep(
              name: cleanStopName(ix.stopNames[ix.patternStopAt(pattern, p)]),
              first: p == 0,
              last: p == ix.patternLength(pattern) - 1,
              marker: p == position
                  ? Icon(modeIcon(route == null ? RouteType.bus : ix.routeTypes[route]),
                      color: context.tokens.live)
                  : null,
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

class _LiveChip extends StatelessWidget {
  const _LiveChip({required this.stale});

  final bool stale;

  @override
  Widget build(BuildContext context) {
    final live = context.tokens.live;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: stale ? scheme.surfaceContainerHighest : live.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle,
              size: 8, color: stale ? scheme.onSurfaceVariant : live),
          const SizedBox(width: 6),
          Text(
            stale ? 'Programmato' : 'LIVE',
            style: TextStyle(
              color: stale ? scheme.onSurfaceVariant : live,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

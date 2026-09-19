/// Home sheet: next arrivals at the stops around you, soonest first.
///
/// Favourites join this list in phase 8.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/distance.dart';
import 'package:piedemove/location/device_location.dart';
import 'package:piedemove/routing/departures.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/widgets/departure_row.dart';

const nearbyRadiusMetres = 400.0;
const _departuresPerStop = 3;

/// Stops within [nearbyRadiusMetres], nearest first.
List<(int stop, double metres)> stopsNear(
  TransitIndex ix,
  double lat,
  double lon, {
  double radius = nearbyRadiusMetres,
}) {
  final out = <(int, double)>[];
  for (var s = 0; s < ix.stopCount; s++) {
    if (ix.stopPatternOffset[s] == ix.stopPatternOffset[s + 1]) continue;
    final d = haversineMetres(lat, lon, ix.stopLat[s], ix.stopLon[s]);
    if (d <= radius) out.add((s, d));
  }
  out.sort((a, b) => a.$2.compareTo(b.$2));
  return out;
}

class NearbySheet extends ConsumerWidget {
  const NearbySheet({super.key, required this.onStopTap});

  final void Function(int stop) onStopTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DraggableScrollableSheet(
      initialChildSize: 0.15,
      minChildSize: 0.15,
      snap: true,
      snapSizes: const [0.15, 0.5, 0.92],
      maxChildSize: 0.92,
      builder: (context, scrollController) => Material(
        elevation: 8,
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: _NearbyList(controller: scrollController, onStopTap: onStopTap),
      ),
    );
  }
}

class _NearbyList extends ConsumerWidget {
  const _NearbyList({required this.controller, required this.onStopTap});

  final ScrollController controller;
  final void Function(int stop) onStopTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(transitIndexProvider);
    final position = ref.watch(myPositionProvider);
    final now = DateTime.now();

    final children = <Widget>[const _Grabber()];
    final ix = index.valueOrNull;
    if (index.isLoading) {
      children.add(const _Note('Preparo gli orari GTT…'));
    } else if (index.hasError) {
      children.add(const _Note('Orari non disponibili.'));
    } else if (position == null) {
      children.add(const _Note('Posizione sconosciuta: tocca il mirino.'));
    } else if (ix != null) {
      final near = stopsNear(ix, position.latitude, position.longitude);
      if (near.isEmpty) {
        children.add(const _Note('Nessuna fermata entro 400 m.'));
      }
      for (final (stop, metres) in near.take(12)) {
        final departures = nextDepartures(ix, stop, now, _departuresPerStop);
        if (departures.isEmpty) continue;
        children.add(_StopBlock(
          name: cleanStopName(ix.stopNames[stop]),
          metres: metres,
          departures: departures,
          now: now,
          onTap: () => onStopTap(stop),
        ));
      }
    }

    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(
          Gap.screen, 0, Gap.screen, Gap.screen),
      children: children,
    );
  }
}

class _StopBlock extends StatelessWidget {
  const _StopBlock({
    required this.name,
    required this.metres,
    required this.departures,
    required this.now,
    required this.onTap,
  });

  final String name;
  final double metres;
  final List<Departure> departures;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final walk = context.tokens.walk.ofMetres(metres);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.element / 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                Text('${metres.round()} m',
                    style: TextStyle(color: walk, fontWeight: FontWeight.w700)),
              ],
            ),
            for (final d in departures) DepartureRow(departure: d, now: now),
          ],
        ),
      ),
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 36,
          height: 4,
          margin: const EdgeInsets.symmetric(vertical: Gap.element),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.outlineVariant,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.element),
        child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
      );
}

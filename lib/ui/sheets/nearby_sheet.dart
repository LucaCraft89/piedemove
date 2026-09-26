/// Home sheet: next arrivals at the stops around you, soonest first.
///
/// Favourite stops sit above the nearby ones (§11.3).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/distance.dart';
import 'package:piedemove/location/device_location.dart';
import 'package:piedemove/places/favourites.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/routing/departures.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/widgets/departure_row.dart';
import 'package:piedemove/ui/widgets/line_badge.dart';

const nearbyRadiusMetres = 400.0;
const _boardPerStop = 2;
const _boardHeight = 78.0;
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
        // The list must end above the system navigation bar, not under it.
        child: SafeArea(
          top: false,
          child: _NearbyList(controller: scrollController, onStopTap: onStopTap),
        ),
      ),
    );
  }
}

class _NearbyList extends ConsumerStatefulWidget {
  const _NearbyList({required this.controller, required this.onStopTap});

  final ScrollController controller;
  final void Function(int stop) onStopTap;

  @override
  ConsumerState<_NearbyList> createState() => _NearbyListState();
}

class _NearbyListState extends ConsumerState<_NearbyList> {
  /// Minutes count down between realtime polls too.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
        const Duration(seconds: 30), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final onStopTap = widget.onStopTap;
    final index = ref.watch(transitIndexProvider);
    final position = ref.watch(myPositionProvider);
    final now = DateTime.now();

    final children = <Widget>[const _Grabber()];
    final ix = index.valueOrNull;
    if (ix != null) {
      final favourites = [
        for (final key in ref.watch(favouritesProvider))
          if (key.startsWith('stop:'))
            ix.stopIndexById[key.substring(5)],
      ].whereType<int>().toList();
      if (favourites.isNotEmpty) {
        // The live board: one card per favourite, visible even at peek.
        children.add(SizedBox(
          height: _boardHeight,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final stop in favourites)
                _BoardCard(
                  name: cleanStopName(ix.stopNames[stop]),
                  departures: nextDepartures(
                    ix,
                    stop,
                    now,
                    _boardPerStop,
                    delays: ref.watch(delayLookupProvider),
                    unavailable: ref.watch(unavailableLookupProvider),
                  ),
                  now: now,
                  onTap: () => onStopTap(stop),
                ),
            ],
          ),
        ));
      }
    }
    if (index.isLoading) {
      children.add(const _Note('Preparo gli orari GTT…'));
    } else if (index.hasError) {
      children.add(const _Note('Orari non disponibili.'));
    } else if (position == null) {
      children.add(const _Note('Posizione sconosciuta: tocca il mirino.'));
    } else if (ix != null) {
      final near = stopsNear(ix, position.latitude, position.longitude);
      // Only labelled when favourites are above it: alone, the list is obvious.
      if (children.length > 1) children.add(const _Note('Vicino a te'));
      if (near.isEmpty) {
        children.add(const _Note('Nessuna fermata entro 400 m.'));
      }
      for (final (stop, metres) in near.take(12)) {
        final departures = nextDepartures(
          ix,
          stop,
          now,
          _departuresPerStop,
          delays: ref.watch(delayLookupProvider),
          unavailable: ref.watch(unavailableLookupProvider),
        );
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

  /// Null when the phone has no position yet: a favourite still lists.
  final double? metres;
  final List<Departure> departures;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final metres = this.metres;
    final walk =
        metres == null ? null : context.tokens.walk.ofMetres(metres);
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
                if (metres != null)
                  Text('${metres.round()} m',
                      style:
                          TextStyle(color: walk, fontWeight: FontWeight.w700)),
              ],
            ),
            for (final d in departures) DepartureRow(departure: d, now: now),
          ],
        ),
      ),
    );
  }
}

/// A favourite stop at a glance: its name, then the next two vehicles as
/// badge + big minutes (live ones in the live colour).
class _BoardCard extends StatelessWidget {
  const _BoardCard({
    required this.name,
    required this.departures,
    required this.now,
    required this.onTap,
  });

  final String name;
  final List<Departure> departures;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8, bottom: 6),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            width: 196,
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.star, size: 14, color: theme.colorScheme.primary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (departures.isEmpty)
                  Text('Nessuna corsa a breve',
                      style: theme.textTheme.bodySmall)
                else
                  // Both vehicles on one line: the card fits the sheet at peek;
                  // long line names shrink rather than overflow.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (i, d) in departures.indexed) ...[
                        if (i > 0) const SizedBox(width: 10),
                        LineBadge(
                            shortName: d.routeShortName,
                            routeType: d.routeType),
                        const SizedBox(width: 4),
                        Text(
                          _minutes(d.time, now),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: d.live ? context.tokens.live : null,
                          ),
                        ),
                      ],
                    ],
                  ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _minutes(DateTime at, DateTime now) {
  final m = at.difference(now).inSeconds ~/ 60;
  return m <= 0 ? 'ora' : "$m'";
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

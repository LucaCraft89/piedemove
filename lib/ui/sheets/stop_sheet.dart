/// Minimal stop sheet: name and next arrivals.
///
/// Phase 3 replaces this with the one `openEntity(EntityRef)` system; the call
/// site stays [showStopSheet] so only this file changes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/routing/departures.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/widgets/departure_row.dart';

void showStopSheet(BuildContext context, int stop) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.15,
      maxChildSize: 0.92,
      snap: true,
      snapSizes: const [0.15, 0.5, 0.92],
      expand: false,
      builder: (context, controller) => Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: _StopBody(stop: stop, controller: controller),
      ),
    ),
  );
}

class _StopBody extends ConsumerWidget {
  const _StopBody({required this.stop, required this.controller});

  final int stop;
  final ScrollController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ix = ref.watch(transitIndexProvider).valueOrNull;
    if (ix == null) return const SizedBox.shrink();
    final now = DateTime.now();
    final departures = nextDepartures(ix, stop, now, 20);
    return ListView(
      controller: controller,
      padding: const EdgeInsets.all(Gap.screen),
      children: [
        Text(cleanStopName(ix.stopNames[stop]),
            style: Theme.of(context).textTheme.headlineSmall),
        Text(ix.stopCodes[stop],
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: Gap.element),
        if (departures.isEmpty)
          const Text('Nessuna corsa nelle prossime ore.')
        else
          for (final d in departures) DepartureRow(departure: d, now: now),
      ],
    );
  }
}

/// "I tuoi viaggi": the walking the app spared, this month and in all, from
/// the finished live trips kept on the phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/location/trip_history.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/trip/live_strip.dart' show StatTile;

Future<void> openStats(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => const StatsPage()));

/// `3,2 km` / `850 m`, approximate.
String kmLabel(double metres) => metres >= 1000
    ? '≈ ${(metres / 1000).toStringAsFixed(1).replaceAll('.', ',')} km'
    : '≈ ${(metres / 10).round() * 10} m';

class StatsPage extends ConsumerWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(tripHistoryProvider);
    final (month, all) = monthAndAll(records, DateTime.now());
    final theme = Theme.of(context);

    Widget block(String title, TripTotals t) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.screen),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Row(children: [
                StatTile(
                    icon: Icons.route,
                    value: '${t.trips}',
                    label: t.trips == 1 ? 'viaggio' : 'viaggi'),
                const SizedBox(width: 8),
                StatTile(
                    icon: Icons.directions_walk,
                    value: kmLabel(t.walk),
                    label: 'a piedi'),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                StatTile(
                    icon: Icons.directions_bus,
                    value: kmLabel(t.ride),
                    label: 'sui mezzi'),
                const SizedBox(width: 8),
                StatTile(
                    icon: Icons.savings_outlined,
                    value: kmLabel(t.spared),
                    label: 'a piedi risparmiati'),
              ]),
            ],
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('I tuoi viaggi')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(Gap.screen),
          children: [
            if (records.isEmpty)
              const Text('Nessun viaggio ancora: i viaggi live portati a '
                  'termine compaiono qui.')
            else ...[
              block('Questo mese', month),
              block('In tutto', all),
              Text(
                '"Risparmiati": la strada a piedi in meno rispetto a fare '
                'tutto il tragitto a piedi (linea d\'aria × 1,35). Le distanze '
                'sono approssimate e restano sul telefono.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Gap.element),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Cancella lo storico'),
                  onPressed: () => ref.read(tripHistoryProvider.notifier).clear(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

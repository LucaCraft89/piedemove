/// Alert sheet (§11.5): full text, cause, effect, affected lines and stops,
/// active period.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/ui/nav/entity.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/widgets/line_badge.dart';

import 'sheet_parts.dart';

/// `Alert.Cause` (GTFS-realtime).
String? causeLabel(int? cause) => switch (cause) {
      3 => 'Guasto tecnico',
      4 => 'Sciopero',
      5 => 'Manifestazione',
      6 => 'Incidente',
      7 => 'Festività',
      8 => 'Maltempo',
      9 => 'Manutenzione',
      10 => 'Lavori',
      11 => 'Intervento delle forze dell\'ordine',
      12 => 'Emergenza sanitaria',
      _ => null,
    };

/// `Alert.Effect`.
String? effectLabel(int? effect) => switch (effect) {
      1 => 'Servizio sospeso',
      2 => 'Servizio ridotto',
      3 => 'Ritardi significativi',
      4 => 'Deviazione',
      5 => 'Servizio aggiuntivo',
      6 => 'Servizio modificato',
      9 => 'Fermata spostata',
      _ => null,
    };

String _day(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} '
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class AlertBody extends ConsumerWidget {
  const AlertBody({
    super.key,
    required this.alertId,
    required this.controller,
  });

  final String alertId;
  final ScrollController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ix = ref.watch(transitIndexProvider).valueOrNull;
    final alert = ref
        .watch(realtimeProvider)
        .alerts
        .where((a) => a.id == alertId)
        .firstOrNull;
    if (alert == null) {
      return ListView(
        controller: controller,
        padding: const EdgeInsets.all(Gap.screen),
        children: const [Grabber(), SheetHeader(title: 'Avviso non più attivo')],
      );
    }

    final tags = [
      if (causeLabel(alert.cause) != null) causeLabel(alert.cause)!,
      if (effectLabel(alert.effect) != null) effectLabel(alert.effect)!,
    ];
    final routes = ix == null
        ? const <int>[]
        : [
            for (final id in alert.routeIds)
              if (ix.routeIndexById[id] != null) ix.routeIndexById[id]!,
          ];
    final stops = ix == null
        ? const <int>[]
        : [
            for (final id in alert.stopIds)
              if (ix.stopIndexById[id] != null) ix.stopIndexById[id]!,
          ];

    return ListView(
      controller: controller,
      padding: const EdgeInsets.all(Gap.screen),
      children: [
        const Grabber(),
        SheetHeader(
          title: alert.header.isEmpty ? 'Avviso di servizio' : alert.header,
          subtitle: alert.from == null && alert.to == null
              ? null
              : '${alert.from == null ? '' : _day(alert.from!)}'
                  '${alert.to == null ? '' : ' – ${_day(alert.to!)}'}',
          leading: Icon(Icons.warning_amber,
              color: Theme.of(context).colorScheme.error),
        ),
        if (tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.element),
            child: Wrap(
              spacing: 8,
              children: [for (final t in tags) Chip(label: Text(t))],
            ),
          ),
        if (alert.description.isNotEmpty) ...[
          const SizedBox(height: Gap.element),
          Text(alert.description,
              style: Theme.of(context).textTheme.bodyMedium),
        ],
        if (routes.isNotEmpty) ...[
          const SheetSection('Linee interessate'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final route in routes)
                InkWell(
                  onTap: () => openEntity(context, ref, LineRef(route)),
                  child: LineBadge(
                    shortName: ix!.routeShortNames[route],
                    routeType: ix.routeTypes[route],
                  ),
                ),
            ],
          ),
        ],
        if (stops.isNotEmpty) ...[
          const SheetSection('Fermate interessate'),
          for (final stop in stops)
            ListTile(
              contentPadding: EdgeInsets.zero,
              minTileHeight: Gap.row,
              leading: const Icon(Icons.place),
              title: Text(cleanStopName(ix!.stopNames[stop])),
              onTap: () => openEntity(context, ref, StopRef(stop)),
            ),
        ],
        RawData(
          'id ${alert.id}\n'
          'cause ${alert.cause} effect ${alert.effect}\n'
          'route_ids ${alert.routeIds.join(', ')}\n'
          'stop_ids ${alert.stopIds.join(', ')}\n'
          'trip_ids ${alert.tripIds.join(', ')}\n'
          'from ${alert.from} to ${alert.to}\n'
          'header ${alert.header}\n'
          'description ${alert.description}',
        ),
      ],
    );
  }
}

/// The alert list behind the home "Avvisi" pill.
void showAlertList(BuildContext context, WidgetRef ref) {
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
        child: Consumer(
          builder: (context, ref, _) {
            final now = DateTime.now();
            final alerts = [
              for (final a in ref.watch(realtimeProvider).alerts)
                if (a.activeAt(now)) a,
            ];
            return ListView(
              controller: controller,
              padding: const EdgeInsets.all(Gap.screen),
              children: [
                const Grabber(),
                SheetHeader(
                  title: 'Avvisi',
                  onClose: () => Navigator.of(context).pop(),
                ),
                if (alerts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: Gap.element),
                    child: Text('Nessun avviso attivo.'),
                  )
                else
                  AlertTiles(alerts: alerts),
              ],
            );
          },
        ),
      ),
    ),
  );
}

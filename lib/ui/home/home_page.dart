/// Home (§11.2): full-screen map, search bar, pill row, my-position button in
/// the corner, and the nearby-arrivals sheet.
///
/// Phase 5 wires the planner in: the card takes a from and a to, the trip sheet
/// replaces the nearby list while a result is up, and closing it leaves a
/// reopen chip. Linee stays for phase 6.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'package:piedemove/data/index_source.dart';
import 'package:piedemove/data/providers.dart';
import 'package:piedemove/location/device_location.dart';
import 'package:piedemove/location/live_trip.dart';
import 'package:piedemove/places/photon.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/ui/map/map_focus.dart';
import 'package:piedemove/ui/map/map_view.dart';
import 'package:piedemove/ui/nav/entity.dart';
import 'package:piedemove/ui/sheets/alert_sheet.dart';
import 'package:piedemove/ui/search/search_page.dart';
import 'package:piedemove/ui/settings/settings_page.dart';
import 'package:piedemove/ui/sheets/nearby_sheet.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/trip/live_strip.dart';
import 'package:piedemove/ui/trip/trip_plan.dart';
import 'package:piedemove/ui/trip/trip_sheet.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool _centred = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => ref.read(locationProvider.notifier).start());
  }

  Future<void> _recentre() async {
    final position = ref.read(myPositionProvider);
    if (position == null) return;
    await ref.read(mapControllerProvider)?.animateCamera(
          CameraUpdate.newLatLngZoom(
              LatLng(position.latitude, position.longitude), 15.5),
        );
  }

  /// Button: centre on the dot, or fix permission/services if that is why not.
  Future<void> _onLocate() async {
    if (ref.read(locationProvider).status != LocStatus.ok) {
      await ref.read(locationProvider.notifier).activate();
    }
    await _recentre();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(mapStatusProvider);
    final loc = ref.watch(locationProvider.select((l) => l.status));
    // Centre once on the first fix of the session; the button does it after.
    ref.listen(myPositionProvider, (_, p) {
      if (p != null && !_centred) {
        _centred = true;
        _recentre();
      }
    });
    final indexState = ref.watch(transitIndexProvider);
    final stage = ref.watch(indexStageProvider);
    final stale = ref.watch(realtimeProvider).staleFeeds();
    final trip = ref.watch(tripPlanProvider);
    final live = ref.watch(liveTripProvider);
    final showTrip =
        !trip.sheetHidden && (trip.planning || trip.result != null);

    return Scaffold(
      body: Stack(
        children: [
          MapView(
            onStopTap: (stop) => openEntity(context, ref, StopRef(stop)),
            onVehicleTap: (id) => openEntity(context, ref, VehicleRef(id)),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(Gap.screen),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _PlannerCard(),
                  const SizedBox(height: Gap.element),
                  const _PillRow(),
                  if (indexState.isLoading)
                    _Chip(_stageLabel(stage), progress: true),
                  if (indexState.hasError)
                    const _Chip('Orari non disponibili'),
                  if (status != null) _Chip(status),
                  if (loc == LocStatus.denied ||
                      loc == LocStatus.deniedForever ||
                      loc == LocStatus.servicesOff)
                    _Chip('Attiva posizione',
                        onTap: ref.read(locationProvider.notifier).activate),
                  if (ref.watch(focusProvider) != null) const _CancellaPill(),
                  if (trip.sheetHidden && trip.result != null)
                    _ReopenChip(
                      onReopen: ref.read(tripPlanProvider.notifier).reopenSheet,
                      onClear: ref.watch(focusProvider) != null
                          ? null
                          : ref.read(tripPlanProvider.notifier).clear,
                    ),
                  if (stale.length == RtFeedKind.values.length)
                    const _Chip('Dati in tempo reale non disponibili')
                  else if (stale.isNotEmpty)
                    const _Chip('Alcuni dati in tempo reale sono fermi'),
                ],
              ),
            ),
          ),
          Positioned(
            right: Gap.screen,
            bottom: MediaQuery.of(context).size.height * 0.15 + Gap.screen,
            child: FloatingActionButton.small(
              heroTag: 'pm-locate',
              tooltip: 'La mia posizione',
              onPressed: _onLocate,
              child: const Icon(Icons.my_location),
            ),
          ),
          // A running trip owns the bottom of the screen (§12).
          if (ref.watch(entityNavProvider).isNotEmpty)
            const EntitySheet()
          else if (live != null)
            const LiveStrip()
          else if (showTrip)
            const TripSheet()
          else
            NearbySheet(
              onStopTap: (stop) => openEntity(context, ref, StopRef(stop)),
            ),
        ],
      ),
    );
  }
}

String _stageLabel(IndexStage stage) => switch (stage) {
      IndexStage.downloading => 'Scarico gli orari GTT…',
      IndexStage.building => 'Preparo gli orari…',
      _ => 'Carico gli orari…',
    };

/// From, to, swap and when (§11.4). The planner runs on Cerca, not on every
/// keystroke: a search is a decision, and it costs a full RAPTOR pass.
class _PlannerCard extends ConsumerWidget {
  const _PlannerCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final plan = ref.read(tripPlanProvider.notifier);
    final query = ref.watch(tripPlanProvider).query;
    final me = ref.watch(myPositionProvider);

    Place? myPlace() => me == null
        ? null
        : Place(
            name: 'La mia posizione',
            address: '',
            lat: me.latitude,
            lon: me.longitude,
          );

    Future<void> pick(bool origin) async {
      final place = await openSearch(context, pick: true);
      if (place == null) return;
      origin ? plan.setFrom(place) : plan.setTo(place);
    }

    void search() {
      if (query.from == null) plan.setFrom(myPlace());
      plan.plan();
    }

    final canSearch = query.to != null && (query.from != null || me != null);

    return Material(
      elevation: 3,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: Gap.element, vertical: 8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      _EndpointRow(
                        icon: Icons.trip_origin,
                        hint: me == null
                            ? 'Da dove parti?'
                            : 'La mia posizione',
                        place: query.from,
                        onTap: () => pick(true),
                        onClear: query.from == null
                            ? null
                            : () => plan.setFrom(null),
                      ),
                      Divider(height: 1, color: scheme.outlineVariant),
                      _EndpointRow(
                        icon: Icons.place,
                        hint: 'Dove vai?',
                        place: query.to,
                        onTap: () => pick(false),
                        onClear:
                            query.to == null ? null : () => plan.setTo(null),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Inverti partenza e arrivo',
                  onPressed: query.from == null && query.to == null
                      ? null
                      : plan.swap,
                  icon: const Icon(Icons.swap_vert),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(child: _WhenRow(query: query)),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: canSearch ? search : null,
                  icon: const Icon(Icons.directions, size: 18),
                  label: const Text('Cerca'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EndpointRow extends StatelessWidget {
  const _EndpointRow({
    required this.icon,
    required this.hint,
    required this.place,
    required this.onTap,
    required this.onClear,
  });

  final IconData icon;
  final String hint;
  final Place? place;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: Gap.row,
        child: Row(
          children: [
            Icon(icon, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: Gap.element),
            Expanded(
              child: Text(
                place?.name ?? hint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color:
                      place == null ? scheme.onSurfaceVariant : scheme.onSurface,
                ),
              ),
            ),
            if (onClear != null)
              IconButton(
                tooltip: 'Cancella',
                visualDensity: VisualDensity.compact,
                onPressed: onClear,
                icon: const Icon(Icons.close, size: 18),
              ),
          ],
        ),
      ),
    );
  }
}

/// Ora · Parti alle · Arriva entro. Picking a time switches the mode with it.
class _WhenRow extends ConsumerWidget {
  const _WhenRow({required this.query});

  final TripQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.read(tripPlanProvider.notifier);

    Future<void> pickTime(WhenMode mode) async {
      final base = query.when ?? DateTime.now();
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(base),
      );
      if (time == null) return;
      final now = DateTime.now();
      plan.setWhen(
        mode,
        DateTime(now.year, now.month, now.day, time.hour, time.minute),
      );
    }

    final label = query.whenMode == WhenMode.now || query.when == null
        ? null
        : '${query.when!.hour.toString().padLeft(2, '0')}:'
            '${query.when!.minute.toString().padLeft(2, '0')}';

    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          ChoiceChip(
            label: const Text('Ora'),
            selected: query.whenMode == WhenMode.now,
            onSelected: (_) => plan.setWhen(WhenMode.now),
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            label: Text(query.whenMode == WhenMode.departAt && label != null
                ? 'Parti $label'
                : 'Parti alle'),
            selected: query.whenMode == WhenMode.departAt,
            onSelected: (_) => pickTime(WhenMode.departAt),
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            // Short labels: the three chips plus Cerca must fit one row
            // without the last one being cut mid-word.
            label: Text(query.whenMode == WhenMode.arriveBy && label != null
                ? 'Arriva $label'
                : 'Arriva'),
            selected: query.whenMode == WhenMode.arriveBy,
            onSelected: (_) => pickTime(WhenMode.arriveBy),
          ),
        ],
      ),
    );
  }
}

/// Drops whatever the map is focused on. A live trip asks first.
class _CancellaPill extends ConsumerWidget {
  const _CancellaPill();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
        padding: const EdgeInsets.only(top: Gap.element),
        child: ActionChip(
          avatar: const Icon(Icons.close, size: 16),
          label: const Text('Cancella'),
          onPressed: () async {
            final focus = ref.read(focusProvider.notifier);
            if (focus.needsConfirm) {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Terminare il viaggio?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Annulla'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Termina'),
                    ),
                  ],
                ),
              );
              if (ok != true) return;
            }
            focus.cancella();
          },
        ),
      );
}

/// The trip sheet was closed: reopen it, or clear the trip (§11.2).
class _ReopenChip extends StatelessWidget {
  const _ReopenChip({required this.onReopen, required this.onClear});

  final VoidCallback onReopen;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Gap.element),
        child: Row(
          children: [
            ActionChip(
              avatar: const Icon(Icons.directions, size: 16),
              label: const Text('Mostra i percorsi'),
              onPressed: onReopen,
            ),
            if (onClear != null) ...[
              const SizedBox(width: 8),
              ActionChip(
                avatar: const Icon(Icons.close, size: 16),
                label: const Text('Cancella'),
                onPressed: onClear,
              ),
            ],
          ],
        ),
      );
}

/// Veicoli, Avvisi, Filtri and Impostazioni are live; Linee waits for phase 6.
class _PillRow extends ConsumerWidget {
  const _PillRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vehiclesOn = ref.watch(vehiclesVisibleProvider);
    final alerts = ref.watch(realtimeProvider).alerts.length;
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          ActionChip(
            avatar: const Icon(Icons.search, size: 16),
            label: const Text('Cerca'),
            onPressed: () => openSearch(context),
          ),
          const SizedBox(width: 8),
          FilterChip(
            avatar: const Icon(Icons.directions_bus, size: 16),
            label: const Text('Veicoli'),
            selected: vehiclesOn,
            onSelected: (on) =>
                ref.read(vehiclesVisibleProvider.notifier).state = on,
          ),
          const SizedBox(width: 8),
          ActionChip(
            avatar: const Icon(Icons.warning_amber, size: 16),
            label: Text(alerts == 0 ? 'Avvisi' : 'Avvisi ($alerts)'),
            onPressed: () => showAlertList(context, ref),
          ),
          const SizedBox(width: 8),
          ActionChip(
            avatar: const Icon(Icons.tune, size: 16),
            label: const Text('Filtri'),
            onPressed: () => showFilters(context),
          ),
          const SizedBox(width: 8),
          // Linee arrives with the line network in phase 6.
          const ActionChip(
            avatar: Icon(Icons.timeline, size: 16),
            label: Text('Linee'),
            onPressed: null,
          ),
          const SizedBox(width: 8),
          ActionChip(
            avatar: const Icon(Icons.settings, size: 16),
            label: const Text('Impostazioni'),
            onPressed: () => openSettings(context),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, {this.progress = false, this.onTap});

  final String text;
  final VoidCallback? onTap;
  final bool progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.element),
      child: Material(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: Gap.element, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (progress) ...[
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
              ],
              Text(text,
                  style: TextStyle(color: scheme.onSecondaryContainer)),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

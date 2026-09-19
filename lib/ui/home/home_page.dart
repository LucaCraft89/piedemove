/// Home (§11.2): full-screen map, search bar, pill row, my-position button in
/// the corner, and the nearby-arrivals sheet.
///
/// The pills are wired in later phases; they are here so the shell is the one
/// the rest of the app grows into.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'package:piedemove/data/index_source.dart';
import 'package:piedemove/data/providers.dart';
import 'package:piedemove/location/device_location.dart';
import 'package:piedemove/ui/map/map_view.dart';
import 'package:piedemove/ui/sheets/nearby_sheet.dart';
import 'package:piedemove/ui/sheets/stop_sheet.dart';
import 'package:piedemove/ui/theme/tokens.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _locate(move: true));
  }

  Future<void> _locate({bool move = false}) async {
    final position = await locateMe();
    if (position == null || !mounted) return;
    ref.read(myPositionProvider.notifier).state = position;
    if (!move) return;
    await ref.read(mapControllerProvider)?.animateCamera(
          CameraUpdate.newLatLngZoom(
            LatLng(position.latitude, position.longitude),
            15.5,
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(mapStatusProvider);
    final indexState = ref.watch(transitIndexProvider);
    final stage = ref.watch(indexStageProvider);

    return Scaffold(
      body: Stack(
        children: [
          MapView(onStopTap: (stop) => showStopSheet(context, stop)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(Gap.screen),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SearchBar(),
                  const SizedBox(height: Gap.element),
                  const _PillRow(),
                  if (indexState.isLoading)
                    _Chip(_stageLabel(stage), progress: true),
                  if (indexState.hasError)
                    const _Chip('Orari non disponibili'),
                  if (status != null) _Chip(status),
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
              onPressed: () => _locate(move: true),
              child: const Icon(Icons.my_location),
            ),
          ),
          NearbySheet(onStopTap: (stop) => showStopSheet(context, stop)),
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

class _SearchBar extends StatelessWidget {
  const _SearchBar();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 3,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        // Search arrives in phase 4.
        onTap: null,
        child: SizedBox(
          height: Gap.row,
          child: Row(
            children: [
              const SizedBox(width: Gap.element),
              Icon(Icons.search, color: scheme.onSurfaceVariant),
              const SizedBox(width: Gap.element),
              Expanded(
                child: Text('Dove vai?',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
              IconButton(
                tooltip: 'Inverti partenza e arrivo',
                onPressed: null,
                icon: const Icon(Icons.swap_vert),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PillRow extends StatelessWidget {
  const _PillRow();

  static const _pills = [
    ('Veicoli', Icons.directions_bus),
    ('Avvisi', Icons.warning_amber),
    ('Filtri', Icons.tune),
    ('Linee', Icons.timeline),
    ('Impostazioni', Icons.settings),
  ];

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 36,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _pills.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final (label, icon) = _pills[i];
            return ActionChip(
              avatar: Icon(icon, size: 16),
              label: Text(label),
              onPressed: null,
            );
          },
        ),
      );
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, {this.progress = false});

  final String text;
  final bool progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.element),
      child: Material(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
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
    );
  }
}

/// Search (§11.3): one box, sectioned results — places, stops, lines, vehicles.
///
/// Places come from Photon (debounced, stale requests dropped); stops, lines
/// and vehicles are local, so the box keeps working with every feed down.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' show Position;
import 'package:maplibre_gl/maplibre_gl.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/distance.dart';
import 'package:piedemove/location/device_location.dart';
import 'package:piedemove/places/photon.dart';
import 'package:piedemove/places/saved.dart';
import 'package:piedemove/places/search_index.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/ui/map/map_view.dart';
import 'package:piedemove/ui/nav/entity.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/widgets/line_badge.dart';

const searchDebounce = Duration(milliseconds: 300);
const minPlaceQuery = 3;

/// Opens the search page. With [pick] the page is a place chooser for the
/// planner: it answers the chosen place instead of pinning it, and hides the
/// line and vehicle sections, which are not somewhere you can travel to.
Future<Place?> openSearch(BuildContext context, {bool pick = false}) =>
    Navigator.of(context).push<Place>(
      MaterialPageRoute<Place>(builder: (_) => SearchPage(pick: pick)),
    );

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, this.pick = false});

  final bool pick;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _text = TextEditingController();
  Timer? _debounce;

  /// Bumped on every keystroke; a reply with an older ticket is dropped.
  int _ticket = 0;
  String _query = '';
  List<Place> _places = const [];
  bool _placesFailed = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    setState(() => _query = value.trim());
    _debounce?.cancel();
    if (_query.length < minPlaceQuery) {
      setState(() {
        _places = const [];
        _placesFailed = false;
      });
      return;
    }
    _debounce = Timer(searchDebounce, _fetchPlaces);
  }

  Future<void> _fetchPlaces() async {
    final ticket = ++_ticket;
    final query = _query;
    final me = ref.read(myPositionProvider);
    try {
      final places = await ref.read(photonClientProvider).search(
            query,
            lat: me?.latitude,
            lon: me?.longitude,
          );
      if (!mounted || ticket != _ticket) return;
      setState(() {
        _places = _byDistance(places, me?.latitude, me?.longitude);
        _placesFailed = false;
      });
    } catch (e) {
      debugPrint('pm: photon failed: $e');
      if (!mounted || ticket != _ticket) return;
      setState(() {
        _places = const [];
        _placesFailed = true;
      });
    }
  }

  void _pick(Place place) {
    ref.read(recentPlacesProvider.notifier).add(place);
    if (widget.pick) {
      Navigator.of(context).pop(place);
      return;
    }
    ref.read(selectedPlaceProvider.notifier).state = place;
    ref.read(mapControllerProvider)?.animateCamera(
          CameraUpdate.newLatLngZoom(LatLng(place.lat, place.lon), 16),
        );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ix = ref.watch(transitIndexProvider).valueOrNull;
    final me = ref.watch(myPositionProvider);
    final stops = ix == null || _query.isEmpty
        ? const <int>[]
        : searchStops(ix, _query, lat: me?.latitude, lon: me?.longitude);
    final routes =
        ix == null || _query.isEmpty ? const <int>[] : searchRoutes(ix, _query);
    final vehicles = _query.isEmpty
        ? const []
        : searchVehicles(ref.watch(realtimeProvider).vehicles.values, _query);
    final saved = ref.watch(savedPlacesProvider);
    final recents = ref.watch(recentPlacesProvider);
    final empty = _query.isEmpty;
    // A bare line number means the line, not the poles numbered like it.
    final linesFirst = !widget.pick && looksLikeLineNumber(_query);
    final stopTiles = [
      if (stops.isNotEmpty) const _Section('Fermate'),
      for (final s in stops) _stopTile(ix!, s, me),
    ];

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _text,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: widget.pick
                ? 'Cerca luogo o fermata'
                : 'Cerca luogo, fermata, linea o veicolo',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
        ),
        actions: [
          if (_query.isNotEmpty)
            IconButton(
              tooltip: 'Cancella',
              icon: const Icon(Icons.close),
              onPressed: () {
                _text.clear();
                _onChanged('');
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Gap.screen),
        children: [
          if (empty) ...[
            if (me != null)
              ListTile(
                leading: const Icon(Icons.my_location),
                title: const Text('La mia posizione'),
                onTap: () => _pick(Place(
                  name: 'La mia posizione',
                  address: '',
                  lat: me.latitude,
                  lon: me.longitude,
                )),
              ),
            if (saved.isNotEmpty) const _Section('Salvati'),
            for (final p in saved) _placeTile(p),
            if (recents.isNotEmpty) const _Section('Recenti'),
            for (final p in recents) _placeTile(p),
          ] else ...[
            if (_placesFailed)
              const ListTile(
                leading: Icon(Icons.cloud_off),
                title: Text('Ricerca luoghi non disponibile'),
                subtitle: Text('Fermate, linee e veicoli funzionano comunque.'),
              ),
            if (_places.isNotEmpty) const _Section('Luoghi'),
            for (final p in _places) _placeTile(p),
            if (!linesFirst) ...stopTiles,
            if (routes.isNotEmpty && !widget.pick) const _Section('Linee'),
            if (!widget.pick)
              for (final r in routes)
              ListTile(
                leading: LineBadge(
                  shortName: ix!.routeShortNames[r],
                  routeType: ix.routeTypes[r],
                ),
                title: Text(ix.routeLongNames[r].isEmpty
                    ? 'Linea ${ix.routeShortNames[r]}'
                    : ix.routeLongNames[r]),
                onTap: () {
                  Navigator.of(context).pop();
                  openEntity(context, ref, LineRef(r));
                },
              ),
            if (linesFirst) ...stopTiles,
            if (vehicles.isNotEmpty && !widget.pick) const _Section('Veicoli'),
            if (!widget.pick)
              for (final v in vehicles)
              ListTile(
                leading: const Icon(Icons.directions_bus),
                title: Text(v.label ?? v.id),
                subtitle: Text('Mezzo ${v.id}'),
                onTap: () {
                  Navigator.of(context).pop();
                  openEntity(context, ref, VehicleRef(v.id));
                },
              ),
            if (_places.isEmpty &&
                stops.isEmpty &&
                routes.isEmpty &&
                vehicles.isEmpty &&
                !_placesFailed)
              const ListTile(title: Text('Nessun risultato.')),
          ],
        ],
      ),
    );
  }

  Widget _placeTile(Place p) {
    final isSaved = ref.read(savedPlacesProvider.notifier).contains(p);
    return ListTile(
      leading: const Icon(Icons.place_outlined),
      title: Text(p.name),
      subtitle: p.address.isEmpty ? null : Text(p.address),
      trailing: IconButton(
        tooltip: isSaved ? 'Rimuovi dai salvati' : 'Salva',
        icon: Icon(isSaved ? Icons.star : Icons.star_border),
        onPressed: () => isSaved
            ? ref.read(savedPlacesProvider.notifier).remove(p)
            : ref.read(savedPlacesProvider.notifier).add(p),
      ),
      onTap: () => _pick(p),
    );
  }

  Widget _stopTile(TransitIndex ix, int stop, Position? me) {
    final metres = me == null
        ? null
        : haversineMetres(me.latitude, me.longitude, ix.stopLat[stop],
            ix.stopLon[stop]);
    final routes = ix.routesAt(stop);
    return ListTile(
      leading: const Icon(Icons.signpost_outlined),
      title: Text(cleanStopName(ix.stopNames[stop])),
      subtitle: Row(
        children: [
          // GTFS gives no street address for a GTT pole: the code is the
          // on-street identifier, so it stands in for one.
          Text('Fermata ${ix.stopCodes[stop]}'
              '${metres == null ? '' : ' · ${metres.round()} m'}  '),
          Expanded(
            child: Wrap(
              spacing: 4,
              children: [
                for (final r in routes.take(6))
                  LineBadge(
                    shortName: ix.routeShortNames[r],
                    routeType: ix.routeTypes[r],
                  ),
              ],
            ),
          ),
        ],
      ),
      isThreeLine: routes.length > 3,
      onTap: () {
        if (widget.pick) {
          _pick(Place(
            name: cleanStopName(ix.stopNames[stop]),
            address: 'Fermata ${ix.stopCodes[stop]}',
            lat: ix.stopLat[stop],
            lon: ix.stopLon[stop],
          ));
          return;
        }
        Navigator.of(context).pop();
        openEntity(context, ref, StopRef(stop));
      },
    );
  }
}

List<Place> _byDistance(List<Place> places, double? lat, double? lon) {
  if (lat == null || lon == null) return places;
  final out = [...places];
  out.sort((a, b) => haversineMetres(lat, lon, a.lat, a.lon)
      .compareTo(haversineMetres(lat, lon, b.lat, b.lon)));
  return out;
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.screen, Gap.element, Gap.screen, 4),
        child: Text(
          title,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      );
}

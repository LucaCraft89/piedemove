/// "Linee": every line in the index, grouped by mode, with a filter box.
///
/// A browse companion to the search box (which also finds a line by number):
/// here nothing needs to be typed to find one. Tapping a line opens the one
/// entity sheet and focuses it on the map, exactly like any other tap site.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/places/search_index.dart';
import 'package:piedemove/ui/nav/entity.dart';
import 'package:piedemove/ui/sheets/line_picker.dart' show compareRouteNames;
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/widgets/line_badge.dart';

Future<void> openLinesBrowser(BuildContext context) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const LinesBrowser()),
    );

/// One section of the browser: a heading and its routes, in display order.
typedef LineGroup = ({String title, List<int> routes});

/// Groups the routes that have at least one pattern (a route no trip uses is
/// noise) by mode, GTT first and the scheduled-only regional feed last, each
/// sorted like line badges ("2" before "10"). A non-empty [query] keeps only
/// the routes [searchRoutes] matches by number or name.
List<LineGroup> groupLines(TransitIndex ix, String query) {
  final served = <int>{for (final r in ix.patternRoute) r};
  final keep = query.trim().isEmpty
      ? served
      : searchRoutes(ix, query, limit: ix.routeCount).toSet();
  final byTitle = <String, List<int>>{};
  for (final r in served) {
    if (!keep.contains(r)) continue;
    byTitle.putIfAbsent(_groupTitle(ix, r), () => []).add(r);
  }
  return [
    for (final title in _groupOrder)
      if (byTitle[title] case final routes?)
        (
          title: title,
          routes: routes
            ..sort((a, b) {
              final byName = compareRouteNames(
                  ix.routeShortNames[a], ix.routeShortNames[b]);
              return byName != 0 ? byName : a.compareTo(b);
            }),
        ),
  ];
}

const _groupOrder = ['Metro', 'Tram', 'Bus', 'Funicolare', 'Altre', 'Regionali'];

String _groupTitle(TransitIndex ix, int route) {
  if (ix.isScheduledOnly(route)) return 'Regionali';
  return switch (ix.routeTypes[route]) {
    RouteType.metro => 'Metro',
    RouteType.tram => 'Tram',
    RouteType.bus => 'Bus',
    RouteType.funicular => 'Funicolare',
    _ => 'Altre',
  };
}

class LinesBrowser extends ConsumerStatefulWidget {
  const LinesBrowser({super.key});

  @override
  ConsumerState<LinesBrowser> createState() => _LinesBrowserState();
}

class _LinesBrowserState extends ConsumerState<LinesBrowser> {
  final _text = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ix = ref.watch(transitIndexProvider).valueOrNull;
    final groups = ix == null ? const <LineGroup>[] : groupLines(ix, _query);
    // Flattened so a long list builds lazily: a heading, then its rows.
    final items = <Object>[
      for (final g in groups) ...[g.title, ...g.routes],
    ];

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _text,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Filtra linee per numero o nome',
            border: InputBorder.none,
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
        actions: [
          if (_query.isNotEmpty)
            IconButton(
              tooltip: 'Cancella',
              icon: const Icon(Icons.close),
              onPressed: () {
                _text.clear();
                setState(() => _query = '');
              },
            ),
        ],
      ),
      body: ix == null
          ? const Center(child: Text('Orari non ancora disponibili'))
          : items.isEmpty
              ? const Center(child: Text('Nessuna linea trovata'))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) => switch (items[i]) {
                    final String title => _Heading(title),
                    final int route => _LineTile(ix: ix, route: route),
                    _ => const SizedBox.shrink(),
                  },
                ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Semantics(
        header: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              Gap.screen, Gap.element, Gap.screen, 4),
          child: Text(
            title,
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
        ),
      );
}

class _LineTile extends ConsumerWidget {
  const _LineTile({required this.ix, required this.route});

  final TransitIndex ix;
  final int route;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final short = ix.routeShortNames[route];
    final long = ix.routeLongNames[route];
    return ListTile(
      leading: LineBadge(shortName: short, routeType: ix.routeTypes[route]),
      title: Text(long.isEmpty || long == short ? 'Linea $short' : long),
      subtitle: ix.isScheduledOnly(route)
          ? const Text('Solo orario, senza dati in tempo reale')
          : null,
      onTap: () => openEntity(context, ref, LineRef(route)),
    );
  }
}

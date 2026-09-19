/// Segment picker (§9.8): a tapped stretch of road used by several lines.
///
/// While it is open the candidate segments draw thicker on the map; tapping a
/// badge opens that line in the one entity sheet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:piedemove/data/providers.dart';
import 'package:piedemove/ui/map/map_view.dart';
import 'package:piedemove/ui/nav/entity.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/widgets/line_badge.dart';

import 'sheet_parts.dart';

/// Line numbers first, alphabetically inside equal numbers: "2" before "10".
int compareRouteNames(String a, String b) {
  final na = int.tryParse(a), nb = int.tryParse(b);
  if (na != null && nb != null) return na.compareTo(nb);
  if (na != null) return -1;
  if (nb != null) return 1;
  return a.compareTo(b);
}

void showLinePicker(
  BuildContext context,
  WidgetRef ref,
  List<(String, int)> routes, {
  List<int> featureIds = const [],
}) {
  ref.read(linePickerProvider.notifier).state = featureIds;
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => _LinePicker(routes: routes),
  ).whenComplete(
    () => ref.read(linePickerProvider.notifier).state = const [],
  );
}

class _LinePicker extends ConsumerWidget {
  const _LinePicker({required this.routes});

  final List<(String, int)> routes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ix = ref.watch(transitIndexProvider).valueOrNull;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(Gap.screen),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Grabber(),
              Text('Linee qui', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Gap.element),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (name, route) in routes)
                    InkWell(
                      onTap: () {
                        Navigator.of(context).pop();
                        openEntity(context, ref, LineRef(route));
                      },
                      child: LineBadge(
                        shortName: name,
                        routeType: ix?.routeTypes[route] ?? 3,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One departure: line badge, headsign, "N min", LIVE or Programmato.
library;

import 'package:flutter/material.dart';

import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/routing/departures.dart';
import 'package:piedemove/ui/theme/tokens.dart';

import 'line_badge.dart';

class DepartureRow extends StatelessWidget {
  const DepartureRow({super.key, required this.departure, this.now});

  final Departure departure;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final at = departure.time;
    final minutes =
        at.difference(now ?? DateTime.now()).inSeconds ~/ 60;
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Gap.row),
      child: Row(
        children: [
          LineBadge(
            shortName: departure.routeShortName,
            routeType: departure.routeType,
          ),
          const SizedBox(width: Gap.element),
          Expanded(
            child: Text(
              cleanStopName(departure.headsign),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: Gap.element),
          Text(
            minutes <= 0 ? 'ora' : '$minutes min',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: departure.live ? context.tokens.live : null,
            ),
          ),
        ],
      ),
    );
  }
}

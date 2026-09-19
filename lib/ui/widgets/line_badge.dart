/// The line badge: coloured pill, mode icon, line number only.
/// Never colour alone — the number and the icon carry the same information.
library;

import 'package:flutter/material.dart';

import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/ui/theme/tokens.dart';

IconData modeIcon(int routeType) => switch (routeType) {
      RouteType.tram => Icons.tram,
      RouteType.metro => Icons.subway,
      RouteType.funicular => Icons.cable,
      _ => Icons.directions_bus,
    };

class LineBadge extends StatelessWidget {
  const LineBadge({
    super.key,
    required this.shortName,
    required this.routeType,
  });

  final String shortName;
  final int routeType;

  @override
  Widget build(BuildContext context) {
    final color = context.tokens.modes.ofRouteType(routeType);
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
            ? Colors.white
            : Colors.black;
    return Semantics(
      label: 'Linea $shortName',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(modeIcon(routeType), size: 14, color: onColor),
            const SizedBox(width: 4),
            Text(
              shortName,
              style: TextStyle(
                color: onColor,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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

/// Every line that makes one ride, as one badge: a segment per mode (colour,
/// icon, then its numbers "4 · 10 · 16"), in the order the options come.
/// A single line is a plain [LineBadge].
class LineGroupBadge extends StatelessWidget {
  const LineGroupBadge({super.key, required this.lines, this.maxNames = 6});

  /// (short name, route type), best option first; repeats are dropped.
  final List<(String, int)> lines;

  /// Past this many numbers the rest become "+N".
  final int maxNames;

  @override
  Widget build(BuildContext context) {
    final groups = lineGroups(lines);
    if (groups.length == 1 && groups.single.$2.length == 1) {
      return LineBadge(
          shortName: groups.single.$2.single, routeType: groups.single.$1);
    }
    final all = [for (final (_, names) in groups) ...names];
    var left = maxNames;
    final segments = <Widget>[];
    for (final (type, names) in groups) {
      if (left <= 0) break;
      final shown = names.take(left).toList();
      left -= shown.length;
      final color = context.tokens.modes.ofRouteType(type);
      final onColor =
          ThemeData.estimateBrightnessForColor(color) == Brightness.dark
              ? Colors.white
              : Colors.black;
      final more = left <= 0 && all.length > maxNames
          ? '  +${all.length - maxNames}'
          : '';
      segments.add(Container(
        color: color,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(modeIcon(type), size: 14, color: onColor),
            const SizedBox(width: 4),
            // Not Flexible: the badge often sits in an unbounded Row; the
            // name cap keeps it short instead.
            Text(
              '${shown.join(' · ')}$more',
              style: TextStyle(
                color: onColor,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ));
    }
    return Semantics(
      label: 'Linee ${all.join(', ')}',
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Row(mainAxisSize: MainAxisSize.min, children: segments),
      ),
    );
  }
}

/// [lines] grouped by route type in order of first appearance, names
/// deduplicated within a type.
List<(int, List<String>)> lineGroups(List<(String, int)> lines) {
  final byType = <int, List<String>>{};
  for (final (name, type) in lines) {
    final names = byType.putIfAbsent(type, () => []);
    if (!names.contains(name)) names.add(name);
  }
  return [for (final e in byType.entries) (e.key, e.value)];
}

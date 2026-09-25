// One badge for every line that makes a ride, and the pie-split stop bubbles.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/ui/map/cluster_pies.dart';
import 'package:piedemove/ui/theme/app_theme.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/widgets/line_badge.dart';

Future<void> _pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(
      theme: darkTheme(),
      home: Scaffold(body: Center(child: child)),
    ));

void main() {
  test('lines group by mode in order of first appearance, repeats dropped',
      () {
    final groups = lineGroups(const [
      ('4', RouteType.tram),
      ('10', RouteType.bus),
      ('4', RouteType.tram), // another pattern of the same line
      ('16', RouteType.bus),
    ]);
    expect(groups.map((g) => g.$1), [RouteType.tram, RouteType.bus]);
    expect(groups.map((g) => g.$2), [
      ['4'],
      ['10', '16'],
    ]);
  });

  testWidgets('several lines make one badge with every number',
      (tester) async {
    await _pump(
        tester,
        const LineGroupBadge(lines: [
          ('10', RouteType.bus),
          ('16', RouteType.bus),
          ('10', RouteType.bus),
        ]));
    expect(find.text('10 · 16'), findsOneWidget);
    expect(find.byIcon(Icons.directions_bus), findsOneWidget);
    expect(find.byType(LineBadge), findsNothing);
    expect(find.bySemanticsLabel('Linee 10, 16'), findsOneWidget);
  });

  testWidgets('mixed modes: one segment per mode, one badge',
      (tester) async {
    await _pump(
        tester,
        const LineGroupBadge(lines: [
          ('4', RouteType.tram),
          ('10', RouteType.bus),
        ]));
    expect(find.text('4'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
    expect(find.byIcon(Icons.tram), findsOneWidget);
    expect(find.byIcon(Icons.directions_bus), findsOneWidget);
  });

  testWidgets('a single line stays a plain badge', (tester) async {
    await _pump(tester,
        const LineGroupBadge(lines: [('13', RouteType.tram)]));
    expect(find.byType(LineBadge), findsOneWidget);
  });

  testWidgets('past the cap the rest are counted, not dropped',
      (tester) async {
    await _pump(
        tester,
        LineGroupBadge(
          maxNames: 3,
          lines: [for (final n in ['1', '2', '3', '4', '5']) (n, RouteType.bus)],
        ));
    expect(find.text('1 · 2 · 3  +2'), findsOneWidget);
  });

  test('a pie has one slice per mode, metro first', () {
    const m = ModeColors.dark;
    expect(clusterPieColors(m, 1, 1, 1, 1),
        [m.metro, m.funicular, m.tram, m.bus]);
    expect(clusterPieColors(m, 1, 0, 0, 0), [m.bus]);
    expect(clusterPieColors(m, 1, 1, 0, 0), [m.tram, m.bus]);
    expect(clusterPieName(1, 1, 0, 0), 'pm-pie-1100');
  });

  test('pie image: stroke ring outside, equal slices inside', () async {
    const m = ModeColors.dark;
    const stroke = Color(0xFFFFFFFF);
    final png = await renderClusterPie([m.tram, m.bus], stroke, 1);
    final codec = await ui.instantiateImageCodec(png);
    final image = (await codec.getNextFrame()).image;
    const size = clusterPieRadius * 2;
    expect(image.width, size);
    final bytes = (await image.toByteData())!;
    Color at(double x, double y) {
      final i = (y.round() * image.width + x.round()) * 4;
      return Color.fromARGB(bytes.getUint8(i + 3), bytes.getUint8(i),
          bytes.getUint8(i + 1), bytes.getUint8(i + 2));
    }

    const c = size / 2;
    // Right half is the first slice (from twelve o'clock, clockwise).
    expect(at(c + 10, c).toARGB32(), m.tram.toARGB32());
    expect(at(c - 10, c).toARGB32(), m.bus.toARGB32());
    expect(at(c, 1).toARGB32(), stroke.toARGB32());
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/ui/theme/app_theme.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/widgets/line_badge.dart';
import 'package:piedemove/data/transit_index.dart';

void main() {
  testWidgets('line badge carries number and icon, not colour alone',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: darkTheme(),
      home: const Scaffold(
        body: LineBadge(shortName: '13', routeType: RouteType.tram),
      ),
    ));
    expect(find.text('13'), findsOneWidget);
    expect(find.byIcon(Icons.tram), findsOneWidget);
  });

  test('walk tiers never collapse to one colour', () {
    const walk = WalkColors.dark;
    expect(walk.ofMetres(100), walk.short);
    expect(walk.ofMetres(400), walk.medium);
    expect(walk.ofMetres(900), walk.long);
  });

  test('mixed stops take the most distinctive mode', () {
    expect(
      ModeColors.dark.ofModes({RouteType.bus, RouteType.metro}),
      ModeColors.dark.metro,
    );
    expect(ModeColors.dark.ofModes({RouteType.bus}), ModeColors.dark.bus);
  });
}

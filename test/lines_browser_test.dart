// The "Linee" browser: grouping, order, filter, and the page itself.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/ui/sheets/lines_browser.dart';
import 'package:piedemove/ui/theme/app_theme.dart';

import 'support/synthetic.dart';

TransitIndex _index() => syntheticIndex(
      stops: [('A', 'ALFA', 45.0, 7.6), ('B', 'BRAVO', 45.01, 7.6)],
      patterns: [
        for (final (name, type) in const [
          ('10', RouteType.bus),
          ('2', RouteType.bus),
          ('4', RouteType.tram),
          ('M1', RouteType.metro),
          ('2', RouteType.bus), // regional twin of GTT 2, below
        ])
          (name, type, ['A', 'B'], [
            [0, 60],
          ]),
      ],
      regionalPatterns: {4},
    );

void main() {
  test('groups by mode, regional last, numbers in badge order', () {
    final groups = groupLines(_index(), '');
    expect(groups.map((g) => g.title), ['Metro', 'Tram', 'Bus', 'Regionali']);
    final ix = _index();
    final bus = groups.firstWhere((g) => g.title == 'Bus');
    expect(bus.routes.map((r) => ix.routeShortNames[r]), ['2', '10']);
  });

  test('the filter keeps only matching lines', () {
    final ix = _index();
    final groups = groupLines(ix, '4');
    expect(groups.map((g) => g.title), ['Tram']);
    expect(groupLines(ix, 'zzz'), isEmpty);
  });

  testWidgets('lists the lines and filters as you type', (tester) async {
    final ix = _index();
    await tester.pumpWidget(ProviderScope(
      overrides: [transitIndexProvider.overrideWith((_) async => ix)],
      child: MaterialApp(theme: darkTheme(), home: const LinesBrowser()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Metro'), findsOneWidget);
    expect(find.text('Regionali'), findsOneWidget);
    expect(find.text('Linea M1'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'M1');
    await tester.pumpAndSettle();
    expect(find.text('Linea M1'), findsOneWidget);
    expect(find.text('Tram'), findsNothing);

    await tester.enterText(find.byType(TextField), 'nessuna');
    await tester.pumpAndSettle();
    expect(find.text('Nessuna linea trovata'), findsOneWidget);
  });
}

// Favourite stops as a live board at the top of the home sheet: a card each,
// next two vehicles with big minutes, fitting a phone-width screen.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/data/providers.dart';
import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/location/device_location.dart';
import 'package:piedemove/places/favourites.dart';
import 'package:piedemove/realtime/store.dart';
import 'package:piedemove/ui/sheets/nearby_sheet.dart';
import 'package:piedemove/ui/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/synthetic.dart';

class _Favs extends Favourites {
  _Favs(Set<String> s) {
    state = s;
  }
}

void main() {
  testWidgets('a card per favourite with its next vehicles', (t) async {
    SharedPreferences.setMockInitialValues({});
    final now = DateTime.now();
    // To the second, and every time half a minute off a minute boundary: the
    // board reads the clock again a moment later, and with whole minutes a
    // test started at hh:mm:59.9 saw 2' and 12' (CI, beta 16 run).
    final secs = now.hour * 3600 + now.minute * 60 + now.second;
    final ix = syntheticIndex(
      stops: [
        ('A', 'PORTA NUOVA', 45.06, 7.678),
        ('B', 'POLITECNICO', 45.062, 7.662),
        ('C', 'FAR', 45.09, 7.70),
      ],
      patterns: [
        ('10', RouteType.bus, ['A', 'C'], [
          [secs + 270, secs + 900],
          [secs + 870, secs + 1500],
        ]),
        ('4', RouteType.tram, ['B', 'C'], [
          [secs + 390, secs + 1000],
        ]),
      ],
      serviceStartDay: TransitIndex.epochDay(now) - 1,
    );
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(
      overrides: [
        transitIndexProvider.overrideWith((ref) async => ix),
        myPositionProvider.overrideWith((ref) => null),
        delayLookupProvider.overrideWith((ref) => null),
        unavailableLookupProvider.overrideWith((ref) => null),
        favouritesProvider.overrideWith(
            (ref) => _Favs({stopFavourite('A'), stopFavourite('B')})),
      ],
      child: MaterialApp(
        theme: darkTheme(),
        home: Scaffold(body: NearbySheet(onStopTap: (_) {})),
      ),
    ));
    await t.pump();
    await t.pump();
    expect(find.text('PORTA NUOVA'), findsOneWidget);
    expect(find.text('POLITECNICO'), findsOneWidget);
    // Minutes round down: 4.5 min is 4', whatever ms pass before the build.
    expect(find.text("4'"), findsOneWidget, reason: 'line 10 in 4 min');
    expect(find.text("14'"), findsOneWidget, reason: 'and the one after');
    expect(find.text("6'"), findsOneWidget, reason: 'tram 4 at POLITECNICO');
    expect(t.takeException(), isNull);
  });
}

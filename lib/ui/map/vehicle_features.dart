/// Live vehicles as GeoJSON, plus the mode sprites the icon layer needs.
///
/// One sprite per mode, drawn at startup from the Material icon onto a canvas:
/// black disc, ring in the mode colour, white glyph (§10.1).
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/geo/lines_io.dart';
import 'package:piedemove/geo/road_graph.dart' show bearingBetween;
import 'package:piedemove/realtime/gtfs_rt.dart';
import 'package:piedemove/realtime/link.dart';
import 'package:piedemove/routing/journey.dart';
import 'package:piedemove/ui/map/map_focus.dart';
import 'package:piedemove/ui/theme/tokens.dart';
import 'package:piedemove/ui/widgets/line_badge.dart';

const vehicleModes = {
  'tram': RouteType.tram,
  'metro': RouteType.metro,
  'funicular': RouteType.funicular,
  'bus': RouteType.bus,
};

String _modeKey(int routeType) => switch (routeType) {
      RouteType.tram => 'tram',
      RouteType.metro => 'metro',
      RouteType.funicular => 'funicular',
      _ => 'bus',
    };

/// Route indices whose vehicles stay visible under [focus]; null = no focus,
/// show all. A journey keeps the routes its ride legs draw (first option).
Set<int>? focusRoutes(TransitIndex ix, MapFocus? focus) => switch (focus) {
      null => null,
      RouteFocus(:final route) => {route},
      JourneyFocus(:final journey) => {
          for (final l in journey.legs)
            if (l.kind == LegKind.ride && l.options.isNotEmpty)
              ix.patternRoute[l.options.first.pattern],
        },
    };

/// Vehicles allowed by [routes] (null = all); unknown-route ones drop when set.
Iterable<RtVehicle> vehiclesForRoutes(
  TransitIndex? ix,
  Iterable<RtVehicle> vehicles,
  Set<int>? routes,
) =>
    routes == null || ix == null
        ? vehicles
        : vehicles.where((v) => routes.contains(routeIndexOf(ix, v)));

/// A vehicle this far from a ridden pattern is on another branch or at the
/// depot: not the one the rider waits for.
const vehicleOffPatternMetres = 300.0;

/// Headings closer than this to the pattern's own direction there count as
/// "going the rider's way".
const vehicleSameWayDegrees = 90.0;

/// Journey focus: only vehicles that can be the rider's - on a ridden line
/// **and heading the ridden way**. GTT's vehicle feed names the line only (no
/// run, no direction), so the direction comes from the vehicle's bearing
/// against the pattern where it is; a vehicle with no bearing stays (unknown
/// is not wrong). Other focus kinds use [vehiclesForRoutes].
Iterable<RtVehicle> vehiclesForJourney(
  TransitIndex ix,
  LineNetwork? net,
  Iterable<RtVehicle> vehicles,
  Journey journey,
) {
  final patterns = [
    for (final l in journey.legs)
      if (l.kind == LegKind.ride && l.options.isNotEmpty) l.options.first.pattern,
  ];
  return vehicles.where((v) {
    final route = routeIndexOf(ix, v);
    if (route == null) return false;
    final trip = tripIndexOf(ix, v);
    for (final p in patterns) {
      if (ix.patternRoute[p] != route) continue;
      if (trip != null) {
        if (ix.patternDir[ix.tripPattern[trip]] == ix.patternDir[p]) return true;
        continue;
      }
      if (headingMatchesPattern(ix, net, p, v.lat, v.lon, v.bearing)) {
        return true;
      }
    }
    return false;
  });
}

/// True when a vehicle at ([lat], [lon]) heading [bearing] runs along
/// [pattern] in its direction: the nearest piece of the pattern (snapped
/// geometry, else stop to stop) is within [vehicleOffPatternMetres] and its
/// heading within [vehicleSameWayDegrees]. A null bearing is not evidence
/// against, so it passes when near.
bool headingMatchesPattern(TransitIndex ix, LineNetwork? net, int pattern,
    double lat, double lon, double? bearing) {
  final geom = net?[pattern];
  final pts = <(double, double)>[
    if (geom != null && geom.vertexCount > 1)
      for (var i = 0; i < geom.vertexCount; i++)
        (geom.vertexLat[i] / 1e6, geom.vertexLon[i] / 1e6)
    else
      for (var i = 0; i < ix.patternLength(pattern); i++)
        (ix.stopLat[ix.patternStopAt(pattern, i)],
            ix.stopLon[ix.patternStopAt(pattern, i)]),
  ];
  var best = double.infinity;
  var bestSeg = -1;
  for (var i = 0; i + 1 < pts.length; i++) {
    final d = _metresToSegment(lat, lon, pts[i], pts[i + 1]);
    if (d < best) {
      best = d;
      bestSeg = i;
    }
  }
  if (bestSeg < 0 || best > vehicleOffPatternMetres) return false;
  if (bearing == null) return true;
  final (a, b) = (pts[bestSeg], pts[bestSeg + 1]);
  final along = bearingBetween(a.$1, a.$2, b.$1, b.$2);
  final diff = ((bearing - along) % 360 + 360) % 360;
  return math.min(diff, 360 - diff) < vehicleSameWayDegrees;
}

/// Metres from a point to a segment, on a local flat projection (fine at the
/// few-hundred-metre scale this is used at).
double _metresToSegment(
    double lat, double lon, (double, double) a, (double, double) b) {
  const mPerDegLat = 111320.0;
  final mPerDegLon = mPerDegLat * math.cos(lat * math.pi / 180);
  final ax = (a.$2 - lon) * mPerDegLon, ay = (a.$1 - lat) * mPerDegLat;
  final bx = (b.$2 - lon) * mPerDegLon, by = (b.$1 - lat) * mPerDegLat;
  final dx = bx - ax, dy = by - ay;
  final len2 = dx * dx + dy * dy;
  final t = len2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0);
  final px = ax + t * dx, py = ay + t * dy;
  return math.sqrt(px * px + py * py);
}

/// Feature ids are list positions: the plugin hands back an id string on tap,
/// and a vehicle id is not a number. [order] receives the matching ids.
Map<String, dynamic> vehicleFeatureCollection(
  TransitIndex? ix,
  Iterable<RtVehicle> vehicles,
  List<String> order,
) {
  order.clear();
  final features = <Map<String, dynamic>>[];
  for (final v in vehicles) {
    final route = ix == null ? null : routeIndexOf(ix, v);
    features.add({
      'type': 'Feature',
      'id': order.length,
      'geometry': {
        'type': 'Point',
        'coordinates': [v.lon, v.lat],
      },
      'properties': {
        'mode': _modeKey(
            route == null || ix == null ? RouteType.bus : ix.routeTypes[route]),
        'line': route == null || ix == null ? '' : ix.routeShortNames[route],
        'bearing': v.bearing ?? 0,
      },
    });
    order.add(v.id);
  }
  return {'type': 'FeatureCollection', 'features': features};
}

/// Registers `pm-veh-<mode>` images on the style.
Future<void> addVehicleIcons(
  MapLibreMapController controller,
  ModeColors modes,
) async {
  for (final entry in vehicleModes.entries) {
    await controller.addImage(
      'pm-veh-${entry.key}',
      await renderVehicleIcon(
        modeIcon(entry.value),
        modes.ofRouteType(entry.value),
      ),
    );
  }
}

@visibleForTesting
Future<Uint8List> renderVehicleIcon(IconData icon, Color ring) async {
  const size = 48;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const center = Offset(size / 2, size / 2);
  canvas.drawCircle(center, 19, Paint()..color = const Color(0xFF111111));
  canvas.drawCircle(
    center,
    19,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..color = ring,
  );
  final glyph = TextPainter(
    textDirection: TextDirection.ltr,
    text: TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontSize: 24,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
        color: Colors.white,
      ),
    ),
  )..layout();
  glyph.paint(canvas, center - Offset(glyph.width / 2, glyph.height / 2));
  final image = await recorder.endRecording().toImage(size, size);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

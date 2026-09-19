/// Live vehicles as GeoJSON, plus the mode sprites the icon layer needs.
///
/// One sprite per mode, drawn at startup from the Material icon onto a canvas:
/// black disc, ring in the mode colour, white glyph (§10.1).
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'package:piedemove/data/transit_index.dart';
import 'package:piedemove/realtime/gtfs_rt.dart';
import 'package:piedemove/realtime/link.dart';
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

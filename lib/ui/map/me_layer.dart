/// Own position dot: one GeoJSON source, three layers (accuracy circle, heading
/// wedge, dot with white ring). Re-added on every style load, kept on top.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:piedemove/location/device_location.dart';

import 'map_style.dart';

const meSource = 'pm-me';
const meLayers = ['pm-me-accuracy', 'pm-me-wedge', 'pm-me-dot'];
const _wedgeImage = 'pm-me-wedge';

/// Metres per dp-pixel at zoom 22 on a 512 tile grid, at [lat].
double _radiusPx22(double metres, double lat) =>
    metres / (78271.517 * math.cos(lat * math.pi / 180) / (1 << 22));

/// The dot for fix [p]; [at] draws it at another point (a glide step toward
/// [p]) with [p]'s accuracy and heading.
Map<String, dynamic> meFeatures(Position? p, {(double, double)? at}) => {
      'type': 'FeatureCollection',
      'features': p == null
          ? []
          : [
              {
                'type': 'Feature',
                'geometry': {
                  'type': 'Point',
                  'coordinates': [at?.$2 ?? p.longitude, at?.$1 ?? p.latitude],
                },
                'properties': {
                  'r22': _radiusPx22(p.accuracy.clamp(0, 2000), p.latitude),
                  // -1 = no heading: the wedge layer filters it out.
                  'heading': usableHeading(p) ?? -1,
                },
              }
            ],
    };

Future<void> _addWedgeImage(MapLibreMapController c) async {
  const s = 88.0;
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  const mid = Offset(s / 2, s / 2);
  final path = Path()
    ..moveTo(mid.dx, mid.dy)
    ..lineTo(mid.dx - 16, 4)
    ..quadraticBezierTo(mid.dx, -2, mid.dx + 16, 4)
    ..close();
  canvas.drawPath(path, Paint()..color = const Color(0xB31A73E8));
  final img = await rec.endRecording().toImage(s.toInt(), s.toInt());
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  await c.addImage(_wedgeImage, bytes!.buffer.asUint8List());
}

/// Adds source + layers at the top of the stack. Throws on failure: the
/// caller owns the try/catch and the status chip.
Future<void> addMeLayers(MapLibreMapController c, Position? p) async {
  // A half-failed earlier attempt may have left pieces behind.
  for (final l in meLayers) {
    try {
      await c.removeLayer(l);
    } catch (_) {}
  }
  try {
    await c.removeSource(meSource);
  } catch (_) {}
  await c.addSource(meSource, GeojsonSourceProperties(data: meFeatures(p)));
  await _addWedgeImage(c);
  await _addLayers(c);
}

Future<void> _addLayers(MapLibreMapController c) async {
  await c.addCircleLayer(
    meSource,
    'pm-me-accuracy',
    const CircleLayerProperties(
      circleColor: meColor,
      circleOpacity: meAccuracyOpacity,
      circleStrokeColor: meColor,
      circleStrokeOpacity: meAccuracyStrokeOpacity,
      circleStrokeWidth: 1.0,
      circleRadius: [
        'interpolate',
        ['exponential', 2],
        ['zoom'],
        0, ['/', ['get', 'r22'], 4194304],
        22, ['get', 'r22'],
      ],
    ),
    enableInteraction: false,
  );
  await c.addSymbolLayer(
    meSource,
    'pm-me-wedge',
    const SymbolLayerProperties(
      iconImage: _wedgeImage,
      iconRotate: ['get', 'heading'],
      iconRotationAlignment: 'map',
      iconAllowOverlap: true,
      iconIgnorePlacement: true,
      iconSize: meWedgeSize / 88.0,
    ),
    filter: ['>=', ['get', 'heading'], 0],
    enableInteraction: false,
  );
  await c.addCircleLayer(
    meSource,
    'pm-me-dot',
    const CircleLayerProperties(
      circleColor: meColor,
      circleRadius: meDotDiameter / 2,
      circleStrokeColor: '#FFFFFF',
      circleStrokeWidth: meRingWidth,
    ),
    enableInteraction: false,
  );
}

/// Layers only, in stack order: called after any layer group lands above it.
Future<void> raiseMeLayers(MapLibreMapController c) async {
  for (final l in meLayers) {
    await c.removeLayer(l);
  }
  await _addLayers(c);
}

/// Glide between fixes: this many steps over [meGlide], so the dot moves
/// instead of jumping once a second (rider report: "updates too slow").
const meGlideSteps = 6;
const meGlide = Duration(milliseconds: 600);

/// Past this the dot jumps: a glide across town would lie about where it was.
const meGlideMaxMetres = 300.0;

/// The glide's points from ([aLat], [aLon]) to ([bLat], [bLon]), end included.
List<(double, double)> meGlidePoints(
        double aLat, double aLon, double bLat, double bLon) =>
    [
      for (var i = 1; i <= meGlideSteps; i++)
        (
          aLat + (bLat - aLat) * i / meGlideSteps,
          aLon + (bLon - aLon) * i / meGlideSteps,
        ),
    ];


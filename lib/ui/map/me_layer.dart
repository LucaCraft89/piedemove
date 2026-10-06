/// Own position dot: one GeoJSON source, three layers (accuracy circle, heading
/// beam, dot with white ring). Re-added on every style load, kept on top.
/// The beam is a fading cone like Google Maps': the compass when standing or
/// walking, the GPS course in a vehicle; its opening is the sensor's error.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:piedemove/location/compass.dart';

import 'map_style.dart';

const meSource = 'pm-me';
const meLayers = ['pm-me-accuracy', 'pm-me-wedge', 'pm-me-dot'];

/// Beam openings drawn (degrees); a heading uses the narrowest that covers
/// its spread.
const meBeamSpreads = [30, 45, 60, 80, 100];
String _beamImage(int spread) => 'pm-me-beam-$spread';

/// The image for a beam [spread] degrees wide.
String meBeamImageFor(double spread) => _beamImage(meBeamSpreads.firstWhere(
    (b) => b >= spread - 0.5,
    orElse: () => meBeamSpreads.last));

/// Metres per dp-pixel at zoom 22 on a 512 tile grid, at [lat].
double _radiusPx22(double metres, double lat) =>
    metres / (78271.517 * math.cos(lat * math.pi / 180) / (1 << 22));

/// The dot for fix [p]; [at] draws it at another point (a glide step toward
/// [p]) with [p]'s accuracy. [heading] is the beam (see [meHeading]); without
/// it the GPS course is used when moving.
Map<String, dynamic> meFeatures(Position? p,
        {(double, double)? at, MeHeading? heading}) =>
    _meFeatures(p, at, heading ?? meHeading(p, null));

Map<String, dynamic> _meFeatures(
        Position? p, (double, double)? at, MeHeading? heading) =>
    {
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
                  // -1 = no heading: the beam layer filters it out.
                  'heading': heading?.degrees ?? -1,
                  'beam': meBeamImageFor(heading?.spread ?? meBeamMin),
                },
              }
            ],
    };

const _beamCanvas = 192.0, _beamRadius = 90.0;

/// A cone opening [spread] degrees up from the centre (north once rotated),
/// strong at the dot and fading out, like Google Maps' beam.
Future<void> _addBeamImage(MapLibreMapController c, int spread) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  const mid = Offset(_beamCanvas / 2, _beamCanvas / 2);
  final half = spread / 2 * math.pi / 180;
  final rect = Rect.fromCircle(center: mid, radius: _beamRadius);
  final path = Path()
    ..moveTo(mid.dx, mid.dy)
    ..arcTo(rect, -math.pi / 2 - half, 2 * half, false)
    ..close();
  canvas.drawPath(
    path,
    Paint()
      ..shader = ui.Gradient.radial(mid, _beamRadius, const [
        Color(0xCC1A73E8),
        Color(0x661A73E8),
        Color(0x001A73E8),
      ], const [
        0.0,
        0.55,
        1.0,
      ]),
  );
  final size = _beamCanvas.toInt();
  final img = await rec.endRecording().toImage(size, size);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  await c.addImage(_beamImage(spread), bytes!.buffer.asUint8List());
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
  for (final spread in meBeamSpreads) {
    await _addBeamImage(c, spread);
  }
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
      iconImage: ['get', 'beam'],
      iconRotate: ['get', 'heading'],
      iconRotationAlignment: 'map',
      iconAllowOverlap: true,
      iconIgnorePlacement: true,
      iconSize: meBeamSize / _beamCanvas,
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


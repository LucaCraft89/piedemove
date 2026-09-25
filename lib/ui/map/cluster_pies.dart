/// Stop bubbles below z15, split into equal slices: one per mode inside.
///
/// A style image per mode combination (15 of them), picked per bubble from the
/// `b`/`t`/`m`/`f` flags the source aggregates with `max`. Drawn over the
/// single-colour circle, which stays as the fallback if the images fail.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'package:piedemove/ui/theme/tokens.dart';

/// Outer radius (dp) of a pie at icon size 1: the largest bubble, 24 dp,
/// plus its 2 dp stroke.
const clusterPieRadius = 26.0;
const clusterPieStroke = 2.0;

/// Flag order in an image name: bus, tram, metro, funicular.
const _flags = ['b', 't', 'm', 'f'];

String clusterPieName(int b, int t, int m, int f) => 'pm-pie-$b$t$m$f';

/// `pm-pie-<b><t><m><f>` for the bubble under evaluation.
List<Object> clusterPieImage() => [
      'concat',
      'pm-pie-',
      for (final f in _flags) ['to-string', ['get', f]],
    ];

/// The slice colours for a flag combination, in drawing order (clockwise
/// from twelve o'clock): metro, funicular, tram, bus - the same precedence a
/// single-colour bubble used, so the first slice keeps the old colour.
List<Color> clusterPieColors(ModeColors modes, int b, int t, int m, int f) => [
      if (m == 1) modes.metro,
      if (f == 1) modes.funicular,
      if (t == 1) modes.tram,
      if (b == 1) modes.bus,
    ];

/// Adds all 15 images. [pixelRatio] is the device's: Android registers a
/// decoded bitmap at the screen density, so drawing at dp x ratio gives a
/// pie of [clusterPieRadius] dp at icon size 1.
Future<void> addClusterPies(
  MapLibreMapController controller,
  ModeColors modes,
  Color stroke,
  double pixelRatio,
) async {
  for (var bits = 1; bits < 16; bits++) {
    final b = bits & 1, t = bits >> 1 & 1, m = bits >> 2 & 1, f = bits >> 3 & 1;
    await controller.addImage(
      clusterPieName(b, t, m, f),
      await renderClusterPie(
          clusterPieColors(modes, b, t, m, f), stroke, pixelRatio),
    );
  }
}

@visibleForTesting
Future<Uint8List> renderClusterPie(
    List<Color> slices, Color stroke, double pixelRatio) async {
  final size = (clusterPieRadius * 2 * pixelRatio).ceil();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final center = Offset(size / 2, size / 2);
  canvas.drawCircle(center, size / 2, Paint()..color = stroke);
  final inner = Rect.fromCircle(
      center: center,
      radius: (clusterPieRadius - clusterPieStroke) * pixelRatio);
  final sweep = 2 * math.pi / slices.length;
  for (final (i, color) in slices.indexed) {
    canvas.drawArc(inner, -math.pi / 2 + i * sweep, sweep, true,
        Paint()
          ..color = color
          ..isAntiAlias = true);
  }
  final image = await recorder.endRecording().toImage(size, size);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

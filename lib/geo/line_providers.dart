/// Line assets on the phone (§9.4, §9.7, §9.9).
///
/// All three are gzipped assets built on the desktop and keyed to a feed. A
/// missing, stale or corrupt asset costs the map its lines and nothing else:
/// every provider answers null and routing never reads them.
library;

import 'dart:convert';
import 'dart:io';


import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import 'lines_io.dart';

Map<String, dynamic> _gunzipJson(Uint8List gz) =>
    jsonDecode(utf8.decode(gzip.decode(gz), allowMalformed: true))
        as Map<String, dynamic>;

Future<Map<String, dynamic>?> _loadJson(String asset) async {
  try {
    final gz = (await rootBundle.load(asset)).buffer.asUint8List();
    return compute(_gunzipJson, gz);
  } catch (e) {
    debugPrint('pm: $asset unavailable: $e');
    return null;
  }
}

/// The pre-merged ambient network as a GeoJSON FeatureCollection.
final ambientLinesProvider = FutureProvider<Map<String, dynamic>?>(
  (_) => _loadJson('assets/ambient.json.gz'),
);

/// Dashed stop-to-road connectors.
final stopConnectorsProvider = FutureProvider<Map<String, dynamic>?>(
  (_) => _loadJson('assets/connectors.json.gz'),
);

LineNetwork? _decode(Uint8List gz) =>
    decodeLines(Uint8List.fromList(gzip.decode(gz)));

/// Snapped pattern geometry, loaded only when focus mode needs it. Null when
/// the asset is for another feed: stale geometry is worse than none.
final lineNetworkProvider = FutureProvider<LineNetwork?>((ref) async {
  final ix = await ref.watch(transitIndexProvider.future);
  try {
    final gz = (await rootBundle.load('assets/lines.bin.gz'))
        .buffer
        .asUint8List();
    final net = await compute(_decode, gz);
    if (net == null || net.feedVersion != ix.feedVersion) {
      debugPrint('pm: lines.bin.gz is for another feed (${net?.feedVersion})');
      return null;
    }
    return net;
  } catch (e) {
    debugPrint('pm: lines.bin.gz unavailable: $e');
    return null;
  }
});

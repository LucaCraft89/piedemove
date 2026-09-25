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
import 'lines_rebase.dart';

Map<String, dynamic> _gunzipJson(Uint8List gz) =>
    jsonDecode(utf8.decode(gzip.decode(gz), allowMalformed: true))
        as Map<String, dynamic>;

Future<Map<String, dynamic>?> _loadJson(String asset) async {
  try {
    final data = await rootBundle.load(asset);
    // The ByteData can be a view into a larger buffer: honour its window.
    final gz = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    // Awaited inside the try, so a gzip or JSON error lands in the catch.
    return await compute(_gunzipJson, gz);
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

/// Metro entrances (§10.5), built on the desktop by `tool/fetch_entrances.dart`.
final metroEntrancesProvider = FutureProvider<Map<String, dynamic>?>(
  (_) => _loadJson('assets/entrances.json.gz'),
);

LineNetwork? _decode(Uint8List gz) =>
    decodeLines(Uint8List.fromList(gzip.decode(gz)));

/// Snapped pattern geometry for the index on the phone, loaded only when
/// focus mode needs it. Geometry from another GTT export is matched pattern
/// by pattern ([rebaseLines]); whatever has none is drawn through its stops,
/// dotted and marked approximate - never nothing, never silently wrong.
final lineNetworkProvider = FutureProvider<LineNetwork?>((ref) async {
  final ix = await ref.watch(transitIndexProvider.future);
  LineNetwork? source;
  try {
    final data = await rootBundle.load('assets/lines.bin.gz');
    final gz = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    source = await compute(_decode, gz);
  } catch (e) {
    debugPrint('pm: lines.bin.gz unavailable: $e');
  }
  final r = rebaseLines(source, ix);
  debugPrint('pm: lines ${source?.feedVersion} on index ${ix.feedVersion}: '
      '${r.matched} patterns matched, ${r.synthetic} drawn through stops');
  return r.net;
});

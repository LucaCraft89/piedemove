/// Line assets on the phone (§9.4, §9.7, §9.9).
///
/// Lines, ambient network and connectors come from the newest downloaded set
/// (`lines_update.dart`, rebuilt by CI when GTT publishes) and otherwise from
/// the shipped assets. A missing, stale or corrupt file costs the map its
/// lines and nothing else: routing never reads them.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../data/providers.dart';
import 'lines_io.dart';
import 'lines_rebase.dart';
import 'lines_update.dart';

/// `<support>/lines`, or null where there is no such folder (tests).
Future<Directory?> linesDir() async {
  try {
    return Directory('${(await getApplicationSupportDirectory()).path}/lines');
  } catch (_) {
    return null;
  }
}

/// Bytes of line file [name]: the downloaded set's copy when one is
/// installed, else the shipped asset.
Future<Uint8List> _lineFileBytes(String name) async {
  final root = await linesDir();
  final set = root == null ? null : currentLinesSet(root);
  if (set != null) {
    try {
      return await File('${set.dir.path}/$name').readAsBytes();
    } catch (e) {
      debugPrint('pm: downloaded $name unreadable, using the shipped one: $e');
    }
  }
  return _assetBytes('assets/$name');
}

Future<Uint8List> _assetBytes(String asset) async {
  final data = await rootBundle.load(asset);
  // The ByteData can be a view into a larger buffer: honour its window.
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Map<String, dynamic> _gunzipJson(Uint8List gz) =>
    jsonDecode(utf8.decode(gzip.decode(gz), allowMalformed: true))
        as Map<String, dynamic>;

Future<Map<String, dynamic>?> _loadJson(
    Future<Uint8List> Function() bytes, String name) async {
  try {
    // Awaited inside the try, so a gzip or JSON error lands in the catch.
    return await compute(_gunzipJson, await bytes());
  } catch (e) {
    debugPrint('pm: $name unavailable: $e');
    return null;
  }
}

/// The pre-merged ambient network as a GeoJSON FeatureCollection. Loaded at
/// start, so it also runs the (daily, foreground) lines update check; a new
/// set reloads the network, the connectors and the focus geometry.
final ambientLinesProvider =
    FutureProvider<Map<String, dynamic>?>((ref) async {
  final ambient = await _loadJson(
      () => _lineFileBytes('ambient.json.gz'), 'ambient.json.gz');
  final root = await linesDir();
  final lifecycle = WidgetsBinding.instance.lifecycleState;
  if (root != null &&
      (lifecycle == null || lifecycle == AppLifecycleState.resumed)) {
    unawaited(LinesUpdater(root: root).checkAndUpdate().then((r) {
      debugPrint('pm: lines update $r');
      if (r == LinesUpdateResult.updated) {
        ref.invalidate(lineNetworkProvider);
        ref.invalidate(stopConnectorsProvider);
        ref.invalidateSelf();
      }
    }));
  }
  return ambient;
});

/// Dashed stop-to-road connectors.
final stopConnectorsProvider = FutureProvider<Map<String, dynamic>?>(
  (_) => _loadJson(
      () => _lineFileBytes('connectors.json.gz'), 'connectors.json.gz'),
);

/// Metro entrances (§10.5), built on the desktop by `tool/fetch_entrances.dart`.
final metroEntrancesProvider = FutureProvider<Map<String, dynamic>?>(
  (_) => _loadJson(
      () => _assetBytes('assets/entrances.json.gz'), 'entrances.json.gz'),
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
    source = await compute(_decode, await _lineFileBytes('lines.bin.gz'));
  } catch (e) {
    debugPrint('pm: lines.bin.gz unavailable: $e');
  }
  final r = rebaseLines(source, ix);
  debugPrint('pm: lines ${source?.feedVersion} on index ${ix.feedVersion}: '
      '${r.matched} patterns matched, ${r.synthetic} drawn through stops');
  return r.net;
});

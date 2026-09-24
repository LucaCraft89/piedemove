/// Riverpod wiring for the walking graph: which file is used, and the daily
/// silent update check.
///
/// Order: downloaded graph on disk (valid, format-compatible) -> shipped
/// asset -> null (legs stay straight dotted "≈"). Parse and grid building run
/// in an isolate; nothing here waits on the network.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'walk_graph_update.dart';
import 'walk_router.dart';

/// The graph shipped inside the APK.
const walkGraphAsset = 'assets/walk_graph.pmwg.gz';

/// The router in use, with where it came from (for the debug log / About).
class WalkSource {
  const WalkSource(this.router, this.origin);
  final WalkRouter router;
  final String origin; // 'downloaded' | 'asset'
}

Future<Directory?> walkDir() async {
  try {
    return Directory('${(await getApplicationSupportDirectory()).path}/walk');
  } catch (_) {
    return null;
  }
}

// Top level on purpose: a closure made inside the async provider captures the
// async frame (a Future), which cannot cross the isolate boundary.
WalkSource? _loadSource(File? file, Uint8List? bytes) {
  final l = loadWalkLayers(downloaded: file, shipped: bytes);
  return l == null ? null : WalkSource(WalkRouter(l.$1), l.$2);
}

// Not async, so the closure captures only its two arguments.
Future<WalkSource?> _loadInIsolate(File? file, Uint8List? bytes) =>
    Isolate.run(() => _loadSource(file, bytes));

final walkRouterProvider = FutureProvider<WalkSource?>((ref) async {
  final clock = Stopwatch()..start();
  final dir = await walkDir();
  Uint8List? shipped;
  try {
    final data = await rootBundle.load(walkGraphAsset);
    shipped = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (e) {
    debugPrint('pm: walk graph asset failed: $e');
  }
  final file = dir == null ? null : File('${dir.path}/$walkDownloadedName');
  final bytes = shipped == null ? null : Uint8List.fromList(shipped);
  final source = await _loadInIsolate(file, bytes);
  debugPrint('pm: walk graph ${source?.origin ?? 'none'}: parse+grid '
      '${clock.elapsedMilliseconds} ms, ${source?.router.graph.edgeCount} edges');

  final lifecycle = WidgetsBinding.instance.lifecycleState;
  if (dir != null &&
      (lifecycle == null || lifecycle == AppLifecycleState.resumed)) {
    final current = source?.router.graph.header.osmTime ?? 0;
    unawaited(WalkGraphUpdater(dir: dir, currentOsmTime: () => current)
        .checkAndUpdate()
        .then((r) {
      if (r == WalkUpdateResult.updated) ref.invalidateSelf();
    }));
  }
  return source;
});

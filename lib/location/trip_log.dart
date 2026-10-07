/// What the live trip decided and why, for "Segnala un problema": every leg
/// change, cue, prompt and a fix every few seconds. Kept in memory during
/// a trip and saved as the last trip when it ends; nothing leaves the phone
/// unless the rider copies or posts it.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Lines kept per trip (a long ride with a fix every 10 s fits).
const tripLogMaxLines = 1500;

class TripLog {
  TripLog({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final _lines = <String>[];

  List<String> get lines => List.unmodifiable(_lines);

  void add(String message) {
    final t = _clock();
    String two(int n) => n.toString().padLeft(2, '0');
    _lines.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)} $message');
    if (_lines.length > tripLogMaxLines) {
      _lines.removeRange(0, _lines.length - tripLogMaxLines);
    }
  }

  void clear() => _lines.clear();

  String dump() => _lines.join('\n');

  static Future<File> _file() async => File(
      '${(await getApplicationSupportDirectory()).path}/logs/last_trip.txt');

  /// Saves this trip as the last one (best effort).
  Future<void> save() async {
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(dump(), flush: true);
    } catch (e) {
      debugPrint('pm: trip log not saved: $e');
    }
  }

  /// The last saved trip, or null.
  static Future<String?> loadLast() async {
    try {
      final f = await _file();
      return await f.exists() ? await f.readAsString() : null;
    } catch (_) {
      return null;
    }
  }
}

/// A position for the log, rounded to ~11 m.
String logPos(double lat, double lon) =>
    '${lat.toStringAsFixed(4)},${lon.toStringAsFixed(4)}';

/// The log without positions, for a public issue: coordinates become `…`.
String withoutPositions(String log) =>
    log.replaceAll(RegExp(r'-?\d{1,3}\.\d{3,},-?\d{1,3}\.\d{3,}'), '…');

final tripLogProvider = Provider<TripLog>((ref) => TripLog());

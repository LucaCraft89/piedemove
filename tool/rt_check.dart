/// Decodes the three live GTT realtime feeds and prints what came back.
/// `dart tool/rt_check.dart` — a sanity check on the hand-rolled decoder
/// against real payloads, since `protoc` is not installed.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:piedemove/data/feeds.dart';
import 'package:piedemove/realtime/gtfs_rt.dart';

Future<void> main() async {
  final client = HttpClient();
  for (final entry in {
    'vehicles': Feeds.gttVehiclePositions,
    'trip updates': Feeds.gttTripUpdates,
    'alerts': Feeds.gttAlerts,
  }.entries) {
    try {
      final response = await (await client.getUrl(Uri.parse(entry.value))).close();
      final bytes = await response.fold<List<int>>([], (a, b) => a..addAll(b));
      final feed = decodeFeed(Uint8List.fromList(bytes));
      stdout.writeln('${entry.key}: HTTP ${response.statusCode}, '
          '${bytes.length} B, ts ${feed.timestamp}, '
          '${feed.vehicles.length} vehicles, '
          '${feed.tripUpdates.length} trip updates, '
          '${feed.alerts.length} alerts');
      final v = feed.vehicles.firstOrNull;
      if (v != null) {
        stdout.writeln('  e.g. ${v.id} trip ${v.tripId} '
            '@ ${v.lat.toStringAsFixed(5)},${v.lon.toStringAsFixed(5)} '
            'seq ${v.stopSequence} ${v.status.name}');
      }
      final u = feed.tripUpdates.firstOrNull;
      if (u != null) {
        final delays = feed.tripUpdates.fold(0, (n, u) => n + u.delayBySequence.length);
        final times = feed.tripUpdates.fold(0, (n, u) => n + u.timeBySequence.length);
        stdout.writeln('  e.g. trip ${u.tripId} date ${u.startDate} '
            'seq ${u.delayBySequence.keys.followedBy(u.timeBySequence.keys).take(3).toList()}');
        stdout.writeln('  $delays delay entries, $times absolute-time entries');
      }
      final a = feed.alerts.firstOrNull;
      if (a != null) {
        stdout.writeln('  e.g. "${a.header}" cause ${a.cause} effect ${a.effect} '
            'routes ${a.routeIds.length} stops ${a.stopIds.length}');
      }
    } catch (e) {
      stdout.writeln('${entry.key}: FAILED $e');
    }
  }
  client.close();
}

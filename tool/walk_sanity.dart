/// CI gate for a freshly built walk graph.
///
///     dart tool/walk_sanity.dart <new_manifest> [<previous_manifest>]
///
/// Exit 0 = publishable, 1 = fail the run. Checks absolute floors (Turin has
/// far more than these) and, when the previous manifest carries stats, swings.
/// Prints `changed=true|false` (payload hash differs) as the last line.
library;

import 'dart:convert';
import 'dart:io';

const minNodes = 50000;
const minMainShare = 0.9;
const maxSwing = 0.15; // +-15 % nodes/edges vs the previous release
const maxSizeSwing = 0.3;

Map<String, dynamic> _load(String p) =>
    jsonDecode(File(p).readAsStringSync()) as Map<String, dynamic>;

/// Returns the failures; empty means publishable. [old] may be null or lack stats.
List<String> check(Map<String, dynamic> n, Map<String, dynamic>? old) {
  final bad = <String>[];
  final nodes = n['nodes'] as int, edges = n['edges'] as int;
  final share = (n['mainComponentShare'] as num).toDouble();
  if (nodes < minNodes) bad.add('nodes $nodes < $minNodes');
  if (share < minMainShare) bad.add('main component share $share < $minMainShare');
  void swing(String k, num now, double lim) {
    final o = old?[k];
    if (o is num && o > 0 && (now - o).abs() / o > lim) {
      bad.add('$k swung $o -> $now (> ${lim * 100}%)');
    }
  }

  swing('nodes', nodes, maxSwing);
  swing('edges', edges, maxSwing);
  swing('size', n['size'] as int, maxSizeSwing);
  final o = old?['mainComponentShare'];
  if (o is num && share < o - 0.03) bad.add('connectivity dropped $o -> $share');
  return bad;
}

void main(List<String> a) {
  final n = _load(a[0]);
  final old = a.length > 1 && File(a[1]).existsSync() ? _load(a[1]) : null;
  final bad = check(n, old);
  for (final b in bad) {
    stderr.writeln('SANITY FAIL: $b');
  }
  if (bad.isNotEmpty) exit(1);
  stdout.writeln('changed=${old == null || old['payloadSha256'] != n['payloadSha256']}');
}

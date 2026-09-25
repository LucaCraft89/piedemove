// The lines updater against a fake release: nothing touches the network.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:piedemove/geo/lines_io.dart';
import 'package:piedemove/geo/lines_update.dart';
import 'package:piedemove/geo/pattern_snap.dart';

Uint8List _linesGz(String feed) {
  final g = SnappedPattern(
    pattern: 0,
    vertexLat: Int32List.fromList([45000000, 45010000]),
    vertexLon: Int32List.fromList([7600000, 7600000]),
    vertexWay: Int64List(2),
    vertexDir: Uint8List(2),
    stopVertex: Int32List.fromList([0, 1]),
    stopLat: Int32List.fromList([45000000, 45010000]),
    stopLon: Int32List.fromList([7600000, 7600000]),
    hopApprox: Uint8List(1),
  );
  return Uint8List.fromList(gzip.encode(
      encodeLines(LineNetwork(feed, [g], signatures: ['1|3|A,B']))));
}

Uint8List _json(Object o) => Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(o))));

class _Release {
  _Release(String feed, {int format = linesFormatVersion, this.corrupt = false})
      : etag = '"$feed-$format"' {
    files = {
      'lines.bin.gz': _linesGz(feed),
      'ambient.json.gz': _json({'type': 'FeatureCollection', 'features': []}),
      'connectors.json.gz': _json({'type': 'FeatureCollection', 'features': []}),
    };
    manifest = {
      'format': format,
      'feedVersion': feed,
      'files': {
        for (final e in files.entries)
          e.key: {'size': e.value.length, 'sha256': sha256.convert(e.value).toString()},
      },
    };
  }

  late Map<String, Uint8List> files;
  late Map<String, dynamic> manifest;
  final bool corrupt;
  /// Changes with the content, as a real server's does.
  final String etag;
  final requests = <http.BaseRequest>[];

  MockClient get client => MockClient.streaming((req, _) async {
        requests.add(req);
        final name = req.url.pathSegments.last;
        if (name == 'manifest.json') {
          if (req.headers['If-None-Match'] == etag) {
            return http.StreamedResponse(const Stream.empty(), 304);
          }
          return http.StreamedResponse(
              Stream.value(utf8.encode(jsonEncode(manifest))), 200,
              headers: {'etag': etag});
        }
        var body = files[name]!;
        if (corrupt && name == 'connectors.json.gz') {
          body = Uint8List.fromList(body)..[body.length - 1] ^= 0xff;
        }
        return http.StreamedResponse(Stream.value(body), 200);
      });

  int get fileRequests =>
      requests.where((r) => r.url.pathSegments.last != 'manifest.json').length;
}

void main() {
  late Directory root;
  var clock = DateTime.utc(2026, 9, 25, 12);
  setUp(() {
    root = Directory.systemTemp.createTempSync('lines_update');
    clock = DateTime.utc(2026, 9, 25, 12);
  });
  tearDown(() => root.deleteSync(recursive: true));

  LinesUpdater updater(_Release r) => LinesUpdater(
        root: root,
        manifestUrl: 'https://example.test/rel/manifest.json',
        client: r.client,
        now: () => clock,
      );

  test('a new set is downloaded, verified and switched to', () async {
    final r = _Release('20260925');
    expect(await updater(r).checkAndUpdate(), LinesUpdateResult.updated);
    final set = currentLinesSet(root)!;
    expect(set.feedVersion, '20260925');
    final net = decodeLines(Uint8List.fromList(
        gzip.decode(File('${set.dir.path}/lines.bin.gz').readAsBytesSync())));
    expect(net!.feedVersion, '20260925');
  });

  test('the same feed again is not downloaded', () async {
    final r = _Release('20260925');
    await updater(r).checkAndUpdate();
    clock = clock.add(const Duration(days: 2));
    expect(await updater(r).checkAndUpdate(), LinesUpdateResult.current);
    expect(r.fileRequests, 3);
  });

  test('a newer feed replaces the set; the old one is pruned', () async {
    await updater(_Release('20260925')).checkAndUpdate();
    final first = currentLinesSet(root)!.dir;
    clock = clock.add(const Duration(days: 2));
    expect(await updater(_Release('20260930')).checkAndUpdate(),
        LinesUpdateResult.updated);
    expect(currentLinesSet(root)!.feedVersion, '20260930');
    expect(first.existsSync(), isFalse);
  });

  test('one bad file: nothing switches, the set in use stays', () async {
    await updater(_Release('20260925')).checkAndUpdate();
    clock = clock.add(const Duration(days: 2));
    expect(await updater(_Release('20260930', corrupt: true)).checkAndUpdate(),
        LinesUpdateResult.failed);
    expect(currentLinesSet(root)!.feedVersion, '20260925');
    expect(root.listSync().whereType<Directory>(), hasLength(1));
  });

  test('another format is ignored and leaves no ETag behind', () async {
    final r = _Release('20260925', format: linesFormatVersion + 1);
    expect(await updater(r).checkAndUpdate(), LinesUpdateResult.incompatible);
    expect(r.fileRequests, 0);
    expect(currentLinesSet(root), isNull);
  });

  test('at most one check a day', () async {
    final r = _Release('20260925');
    await updater(r).checkAndUpdate();
    expect(await updater(r).checkAndUpdate(), LinesUpdateResult.tooSoon);
  });

  test('offline is a quiet failure and not counted as a check', () async {
    final u = LinesUpdater(
      root: root,
      manifestUrl: 'https://example.test/rel/manifest.json',
      client: MockClient((_) async => throw const SocketException('offline')),
      now: () => clock,
    );
    expect(await u.checkAndUpdate(), LinesUpdateResult.failed);
    expect(await u.checkAndUpdate(), LinesUpdateResult.failed);
  });
}

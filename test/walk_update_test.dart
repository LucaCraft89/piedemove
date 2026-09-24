/// The graph updater against a fake HTTP server: nothing here touches the
/// network.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:piedemove/geo/walk_graph.dart';
import 'package:piedemove/geo/walk_graph_update.dart';

Uint8List _graphGz(int osmTime) {
  final g = WalkGraph.build(
    nodeLat: [4500000, 4500100],
    nodeLon: [760000, 760000],
    edges: [WalkEdgeSpec(0, 1, WalkFlags.make(WalkKind.path), name: 'Via Prova')],
    osmTime: osmTime,
    bbox: [4499000, 759000, 4501000, 761000],
  );
  return Uint8List.fromList(gzip.encode(g.encode()));
}

// 2026-09-01 (shipped) and 2026-09-20 (update)
const _shipped = 1788220800, _newer = 1789862400;

Map<String, dynamic> _manifest(Uint8List gz,
        {int format = walkGraphFormat, String? sha, int date = _newer, int? size}) =>
    {
      'format': format,
      'version': '20260920',
      'date': DateTime.fromMillisecondsSinceEpoch(date * 1000, isUtc: true).toIso8601String(),
      'bbox': [44.99, 7.56, 45.14, 7.79],
      'size': size ?? gz.length,
      'sha256': sha ?? sha256.convert(gz).toString(),
      'url': 'walk_graph.pmwg.gz',
    };

class _Server {
  _Server(this.manifest, this.graph, {this.breakGraphAfter});
  Map<String, dynamic> manifest;
  Uint8List graph;
  final etag = '"v1"';
  int? breakGraphAfter;
  final requests = <http.BaseRequest>[];

  MockClient get client => MockClient.streaming((req, _) async {
        requests.add(req);
        if (req.url.path.endsWith('manifest.json')) {
          if (req.headers['If-None-Match'] == etag) {
            return http.StreamedResponse(const Stream.empty(), 304);
          }
          final body = utf8.encode(jsonEncode(manifest));
          return http.StreamedResponse(Stream.value(body), 200, headers: {'etag': etag});
        }
        if (breakGraphAfter != null) {
          final n = breakGraphAfter!;
          Stream<List<int>> broken() async* {
            yield graph.sublist(0, n);
            throw const SocketException('connection reset');
          }

          return http.StreamedResponse(broken(), 200);
        }
        return http.StreamedResponse(Stream.value(graph), 200);
      });

  int get graphRequests => requests.where((r) => !r.url.path.endsWith('manifest.json')).length;
}

void main() {
  layerTests();
  late Directory dir;
  var clock = DateTime.utc(2026, 9, 24, 12);
  setUp(() {
    dir = Directory.systemTemp.createTempSync('walk_update');
    clock = DateTime.utc(2026, 9, 24, 12);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  WalkGraphUpdater updater(_Server s, {int shipped = _shipped}) => WalkGraphUpdater(
        dir: dir,
        currentOsmTime: () => shipped,
        manifestUrl: 'https://example.test/rel/manifest.json',
        client: s.client,
        now: () => clock,
      );

  test('a newer graph is downloaded, verified and swapped in', () async {
    final gz = _graphGz(_newer);
    final s = _Server(_manifest(gz), gz);
    final u = updater(s);
    expect(await u.checkAndUpdate(), WalkUpdateResult.updated);
    final g = readWalkGraphFile(u.graphFile)!;
    expect(g.header.osmTime, _newer);
    expect(File('${u.graphFile.path}.tmp').existsSync(), isFalse);
  });

  test('a bad hash is rejected and nothing is written', () async {
    final gz = _graphGz(_newer);
    final s = _Server(_manifest(gz, sha: 'a' * 64), gz);
    final u = updater(s);
    expect(await u.checkAndUpdate(), WalkUpdateResult.failed);
    expect(u.graphFile.existsSync(), isFalse);
    expect(File('${u.graphFile.path}.tmp').existsSync(), isFalse);
  });

  test('a corrupt payload with a matching file hash is still rejected', () async {
    final gz = _graphGz(_newer);
    final raw = Uint8List.fromList(gzip.decode(gz))..[walkHeaderBytes + 3] ^= 0x55;
    final bad = Uint8List.fromList(gzip.encode(raw));
    final s = _Server(_manifest(bad), bad);
    expect(await updater(s).checkAndUpdate(), WalkUpdateResult.failed);
    expect(File('${dir.path}/$walkDownloadedName').existsSync(), isFalse);
  });

  test('an incompatible newer format is ignored without downloading', () async {
    final gz = _graphGz(_newer);
    final s = _Server(_manifest(gz, format: walkGraphFormat + 1), gz);
    expect(await updater(s).checkAndUpdate(), WalkUpdateResult.incompatible);
    expect(s.graphRequests, 0);
  });

  test('an older or equal graph is not downloaded', () async {
    final gz = _graphGz(_shipped);
    final s = _Server(_manifest(gz, date: _shipped), gz);
    expect(await updater(s).checkAndUpdate(), WalkUpdateResult.current);
    expect(s.graphRequests, 0);
  });

  test('offline: the shipped graph stays, and the next attempt is not delayed', () async {
    final s = _Server({}, Uint8List(0));
    final u = WalkGraphUpdater(
      dir: dir,
      currentOsmTime: () => _shipped,
      manifestUrl: 'https://example.test/rel/manifest.json',
      client: MockClient((_) async => throw const SocketException('offline')),
      now: () => clock,
    );
    expect(await u.checkAndUpdate(), WalkUpdateResult.failed);
    expect(await u.checkAndUpdate(), WalkUpdateResult.failed); // not "too soon"
    expect(u.graphFile.existsSync(), isFalse);
    expect(s.requests, isEmpty);
  });

  test('a missing manifest (404) is silent and counts as a check', () async {
    final u = WalkGraphUpdater(
      dir: dir,
      currentOsmTime: () => _shipped,
      manifestUrl: 'https://example.test/rel/manifest.json',
      client: MockClient((_) async => http.Response('not found', 404)),
      now: () => clock,
    );
    expect(await u.checkAndUpdate(), WalkUpdateResult.failed);
    expect(await u.checkAndUpdate(), WalkUpdateResult.tooSoon);
  });

  test('an interrupted download leaves the old file intact', () async {
    final oldGz = _graphGz(_shipped + 100);
    File('${dir.path}/$walkDownloadedName').writeAsBytesSync(oldGz);
    final gz = _graphGz(_newer);
    final s = _Server(_manifest(gz), gz, breakGraphAfter: gz.length ~/ 2);
    final u = updater(s, shipped: _shipped + 100);
    expect(await u.checkAndUpdate(), WalkUpdateResult.failed);
    expect(u.graphFile.readAsBytesSync(), oldGz);
    expect(File('${u.graphFile.path}.tmp').existsSync(), isFalse);
    // the manifest etag was not stored: the next check retries the download
    clock = clock.add(const Duration(days: 2));
    s.breakGraphAfter = null;
    expect(await u.checkAndUpdate(), WalkUpdateResult.updated);
    expect(readWalkGraphFile(u.graphFile)!.header.osmTime, _newer);
  });

  test('at most one check a day, then a conditional request', () async {
    final gz = _graphGz(_shipped);
    final s = _Server(_manifest(gz, date: _shipped), gz);
    final u = updater(s);
    expect(await u.checkAndUpdate(), WalkUpdateResult.current);
    expect(await u.checkAndUpdate(), WalkUpdateResult.tooSoon);
    expect(s.requests, hasLength(1));
    clock = clock.add(const Duration(hours: 25));
    expect(await u.checkAndUpdate(), WalkUpdateResult.current);
    expect(s.requests.last.headers['If-None-Match'], '"v1"');
    expect(s.requests, hasLength(2));
  });
}

void layerTests() {
  group('loader layering', () {
    final bytes = File('test/fixtures/walk_fixture.pmwg.gz').readAsBytesSync();
    late Directory d;
    setUp(() => d = Directory.systemTemp.createTempSync('walk_layers'));
    tearDown(() => d.deleteSync(recursive: true));

    test('valid downloaded beats shipped', () {
      final f = File('${d.path}/x')..writeAsBytesSync(bytes);
      expect(loadWalkLayers(downloaded: f, shipped: bytes)!.$2, 'downloaded');
    });
    test('corrupt or missing downloaded falls back to shipped', () {
      final f = File('${d.path}/x')..writeAsBytesSync([1, 2, 3, 4]);
      expect(loadWalkLayers(downloaded: f, shipped: bytes)!.$2, 'asset');
      expect(loadWalkLayers(downloaded: File('${d.path}/none'), shipped: bytes)!.$2, 'asset');
    });
    test('nothing valid gives null', () {
      expect(loadWalkLayers(shipped: Uint8List.fromList([9, 9])), isNull);
      expect(loadWalkLayers(), isNull);
    });
  });
}

// Torn index files and streamed downloads (audit 2026-09).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:piedemove/data/download.dart';
import 'package:piedemove/data/index_io.dart';

import 'support/synthetic.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('pm_io'));
  tearDown(() => dir.deleteSync(recursive: true));

  final ix = syntheticIndex(
    stops: [('A', 'ALFA', 45.0, 7.6), ('B', 'BRAVO', 45.01, 7.6)],
    patterns: [
      ('1', 3, ['A', 'B'], [
        [8 * 3600, 8 * 3600 + 600],
      ]),
    ],
  );

  test('the index is written atomically and reads back', () async {
    final path = '${dir.path}/index.bin';
    await writeIndexFile(ix, path);
    expect(File('$path.tmp').existsSync(), isFalse);
    final back = await readIndexFile(path);
    expect(back!.stopIds, ix.stopIds);
  });

  test('a truncated index reads as missing and is removed', () async {
    final path = '${dir.path}/index.bin';
    await writeIndexFile(ix, path);
    final f = File(path);
    final bytes = f.readAsBytesSync();
    f.writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
    expect(await readIndexFile(path), isNull);
    expect(f.existsSync(), isFalse);
  });

  group('downloadToFile', () {
    test('streams the body to the file', () async {
      final path = '${dir.path}/feed.zip';
      final client = MockClient.streaming((_, __) async => http.StreamedResponse(
          Stream.fromIterable([
            [1, 2, 3],
            [4, 5],
          ]),
          200));
      await downloadToFile('https://example.test/f.zip', path,
          timeout: const Duration(seconds: 5), client: client);
      expect(File(path).readAsBytesSync(), [1, 2, 3, 4, 5]);
      expect(File('$path.part').existsSync(), isFalse);
    });

    test('a non-200 answer throws and writes nothing', () async {
      final path = '${dir.path}/feed.zip';
      final client = MockClient((_) async => http.Response('gone', 404));
      await expectLater(
          downloadToFile('https://example.test/f.zip', path,
              timeout: const Duration(seconds: 5), client: client),
          throwsA(isA<HttpException>()));
      expect(File(path).existsSync(), isFalse);
    });

    test('a broken stream leaves no partial file under either name', () async {
      final path = '${dir.path}/feed.zip';
      File(path).writeAsBytesSync([9, 9]); // previous good copy stays
      Stream<List<int>> broken() async* {
        yield [1, 2];
        throw const SocketException('reset');
      }

      final client = MockClient.streaming(
          (_, __) async => http.StreamedResponse(broken(), 200));
      await expectLater(
          downloadToFile('https://example.test/f.zip', path,
              timeout: const Duration(seconds: 5), client: client),
          throwsA(isA<SocketException>()));
      expect(File(path).readAsBytesSync(), [9, 9]);
      expect(File('$path.part').existsSync(), isFalse);
    });

    test('a stalled stream times out', () async {
      final path = '${dir.path}/feed.zip';
      final never = StreamController<List<int>>();
      final client = MockClient.streaming(
          (_, __) async => http.StreamedResponse(never.stream, 200));
      await expectLater(
          downloadToFile('https://example.test/f.zip', path,
              timeout: const Duration(milliseconds: 50), client: client),
          throwsA(isA<TimeoutException>()));
      expect(File('$path.part').existsSync(), isFalse);
      await never.close();
    });
  });
}

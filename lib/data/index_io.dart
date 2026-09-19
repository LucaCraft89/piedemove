/// Binary persistence for [TransitIndex].
///
/// Format is versioned; a file written by an older build is rejected and the
/// index rebuilt. Typed arrays are stored 8-byte aligned so they can be read
/// back as views without copying.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'transit_index.dart';

const indexFormatVersion = 1;
const _magic = 0x504D5631; // "PMV1"

class IndexFormatException implements Exception {
  IndexFormatException(this.message);
  final String message;
  @override
  String toString() => 'IndexFormatException: $message';
}

class _Writer {
  final _out = BytesBuilder(copy: false);
  int get length => _out.length;

  void _align() {
    final pad = (8 - (length % 8)) % 8;
    if (pad > 0) _out.add(Uint8List(pad));
  }

  void int32(int v) => _out.add(Uint8List(4)..buffer.asByteData().setInt32(0, v, Endian.little));

  void bytes(Uint8List b) {
    int32(b.length);
    _align();
    _out.add(b);
  }

  void i8(Int8List a) => bytes(Uint8List.view(a.buffer, a.offsetInBytes, a.length));

  void u8(Uint8List a) => bytes(a);

  void i32(Int32List a) {
    int32(a.length);
    _align();
    _out.add(Uint8List.view(a.buffer, a.offsetInBytes, a.length * 4));
  }

  void f64(Float64List a) {
    int32(a.length);
    _align();
    _out.add(Uint8List.view(a.buffer, a.offsetInBytes, a.length * 8));
  }

  void strings(List<String> v) {
    final blob = utf8.encode(v.join('\u0000'));
    int32(v.length);
    bytes(blob);
  }

  Uint8List take() => _out.takeBytes();
}

class _Reader {
  _Reader(this.data) : _view = ByteData.view(data.buffer, data.offsetInBytes, data.length);
  final Uint8List data;
  final ByteData _view;
  int _at = 0;

  void _align() => _at += (8 - (_at % 8)) % 8;

  int int32() {
    final v = _view.getInt32(_at, Endian.little);
    _at += 4;
    return v;
  }

  Uint8List bytes() {
    final n = int32();
    _align();
    final v = Uint8List.view(data.buffer, data.offsetInBytes + _at, n);
    _at += n;
    return v;
  }

  Int8List i8() {
    final b = bytes();
    return Int8List.view(b.buffer, b.offsetInBytes, b.length);
  }

  Uint8List u8() => bytes();

  Int32List i32() {
    final n = int32();
    _align();
    final v = Int32List.view(data.buffer, data.offsetInBytes + _at, n);
    _at += n * 4;
    return v;
  }

  Float64List f64() {
    final n = int32();
    _align();
    final v = Float64List.view(data.buffer, data.offsetInBytes + _at, n);
    _at += n * 8;
    return v;
  }

  List<String> strings() {
    final n = int32();
    final blob = utf8.decode(bytes());
    if (n == 0) return const [];
    return blob.split('\u0000');
  }
}

Uint8List encodeIndex(TransitIndex ix) {
  final w = _Writer()
    ..int32(_magic)
    ..int32(indexFormatVersion);
  w.strings([ix.feedVersion]);
  w
    ..int32(ix.serviceStartDay)
    ..int32(ix.serviceDayCount);
  w.strings(ix.stopIds);
  w.strings(ix.stopCodes);
  w.strings(ix.stopNames);
  w.f64(ix.stopLat);
  w.f64(ix.stopLon);
  w.strings(ix.routeIds);
  w.strings(ix.routeShortNames);
  w.strings(ix.routeLongNames);
  w.i8(ix.routeTypes);
  w.i32(ix.patternRoute);
  w.i8(ix.patternDir);
  w.i32(ix.patternStopOffset);
  w.i32(ix.patternStop);
  w.i32(ix.patternTripOffset);
  w.i32(ix.patternTrip);
  w.strings(ix.tripIds);
  w.i32(ix.tripPattern);
  w.i32(ix.tripService);
  w.i32(ix.tripTimeOffset);
  w.i32(ix.tripDep);
  w.i32(ix.tripArr);
  w.u8(ix.serviceDays);
  w.i32(ix.stopPatternOffset);
  w.i32(ix.stopPattern);
  w.i32(ix.stopPatternPos);
  return w.take();
}

TransitIndex decodeIndex(Uint8List data) {
  final r = _Reader(data);
  if (r.int32() != _magic) throw IndexFormatException('not an index file');
  final version = r.int32();
  if (version != indexFormatVersion) {
    throw IndexFormatException('version $version, expected $indexFormatVersion');
  }
  final feedVersion = r.strings().first;
  return TransitIndex(
    feedVersion: feedVersion,
    serviceStartDay: r.int32(),
    serviceDayCount: r.int32(),
    stopIds: r.strings(),
    stopCodes: r.strings(),
    stopNames: r.strings(),
    stopLat: r.f64(),
    stopLon: r.f64(),
    routeIds: r.strings(),
    routeShortNames: r.strings(),
    routeLongNames: r.strings(),
    routeTypes: r.i8(),
    patternRoute: r.i32(),
    patternDir: r.i8(),
    patternStopOffset: r.i32(),
    patternStop: r.i32(),
    patternTripOffset: r.i32(),
    patternTrip: r.i32(),
    tripIds: r.strings(),
    tripPattern: r.i32(),
    tripService: r.i32(),
    tripTimeOffset: r.i32(),
    tripDep: r.i32(),
    tripArr: r.i32(),
    serviceDays: r.u8(),
    stopPatternOffset: r.i32(),
    stopPattern: r.i32(),
    stopPatternPos: r.i32(),
  );
}

Future<void> writeIndexFile(TransitIndex ix, String path) async {
  await File(path).writeAsBytes(encodeIndex(ix), flush: true);
}

/// Returns null when the file is missing or written by another format version,
/// so the caller can rebuild instead of crashing.
Future<TransitIndex?> readIndexFile(String path) async {
  final f = File(path);
  if (!f.existsSync()) return null;
  try {
    return decodeIndex(await f.readAsBytes());
  } on IndexFormatException {
    return null;
  }
}

/// A 60-line protobuf wire reader.
///
/// `protoc` is not installed on this machine and GTFS-realtime needs ~20 fields
/// out of the whole schema, so nothing is generated: the wire format is read
/// directly and the few fields we use are pulled out by number.
library;

import 'dart:convert';
import 'dart:typed_data';

/// One decoded message: field number -> values, in wire order.
///
/// Values are `int` (varint / fixed64), `double` (fixed32, i.e. float) or
/// `Uint8List` (length-delimited: string, bytes or a nested message).
class Pb {
  Pb(this.fields);

  final Map<int, List<Object>> fields;

  static Pb decode(Uint8List b, [int start = 0, int? end]) {
    final stop = end ?? b.length;
    final data = ByteData.sublistView(b);
    final fields = <int, List<Object>>{};
    var i = start;

    int varint() {
      var result = 0, shift = 0;
      while (i < stop) {
        final byte = b[i++];
        if (shift < 64) result |= (byte & 0x7f) << shift;
        shift += 7;
        if (byte & 0x80 == 0) break;
      }
      return result;
    }

    while (i < stop) {
      final key = varint();
      final field = key >> 3;
      Object? value;
      switch (key & 7) {
        case 0:
          value = varint();
        case 1:
          value = data.getUint64(i, Endian.little);
          i += 8;
        case 2:
          final len = varint();
          value = Uint8List.sublistView(b, i, i + len);
          i += len;
        case 5:
          value = data.getFloat32(i, Endian.little);
          i += 4;
        default:
          return Pb(fields); // group or unknown: give up on the rest
      }
      (fields[field] ??= []).add(value);
    }
    return Pb(fields);
  }

  Object? _one(int n) {
    final v = fields[n];
    return v == null || v.isEmpty ? null : v.first;
  }

  int? int_(int n) => _one(n) as int?;

  double? float(int n) {
    final v = _one(n);
    return v is double ? v : (v as int?)?.toDouble();
  }

  String? str(int n) {
    final v = _one(n);
    return v is Uint8List ? utf8.decode(v, allowMalformed: true) : null;
  }

  Pb? msg(int n) {
    final v = _one(n);
    return v is Uint8List ? Pb.decode(v) : null;
  }

  List<Pb> all(int n) => [
        for (final v in fields[n] ?? const []) if (v is Uint8List) Pb.decode(v),
      ];
}

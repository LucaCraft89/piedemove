/// Minimal RFC4180 CSV reader for GTFS text files. Row-at-a-time, no buffering
/// of the whole file: the caller feeds it lines from a stream.
library;

List<String> parseCsvLine(String line) {
  final out = <String>[];
  final buf = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        buf.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == ',') {
      out.add(buf.toString());
      buf.clear();
    } else if (c != '\r') {
      buf.write(c);
    }
  }
  out.add(buf.toString());
  return out;
}

/// Column index lookup for a GTFS header row, tolerant of a UTF-8 BOM.
class CsvHeader {
  CsvHeader(String headerLine) {
    final cols = parseCsvLine(headerLine);
    for (var i = 0; i < cols.length; i++) {
      var name = cols[i].trim();
      if (i == 0 && name.startsWith('﻿')) name = name.substring(1);
      _index[name] = i;
    }
  }

  final _index = <String, int>{};

  /// -1 when the optional column is absent.
  int operator [](String column) => _index[column] ?? -1;

  String? value(List<String> row, String column) {
    final i = this[column];
    if (i < 0 || i >= row.length) return null;
    final v = row[i];
    return v.isEmpty ? null : v;
  }
}

/// Streams a URL to a file without holding the body in memory (the regional
/// zip is over 200 MB), via `<path>.part` and a rename, so a killed download
/// never leaves a truncated file under the real name.
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Downloads [url] to [path]. Throws on a non-200 answer, a wait longer than
/// [headerTimeout] for the response to start (the regional server assembles
/// its zip first, well over a minute), a gap longer than [timeout] between
/// two body chunks, or an I/O error; the partial file is removed either way.
Future<void> downloadToFile(
  String url,
  String path, {
  required Duration timeout,
  Duration? headerTimeout,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  final part = File('$path.part');
  IOSink? sink;
  try {
    final response =
        await c.send(http.Request('GET', Uri.parse(url)))
            .timeout(headerTimeout ?? timeout);
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }
    part.parent.createSync(recursive: true);
    sink = part.openWrite();
    // A gap between chunks longer than [timeout] fails the stream; a slow but
    // steady transfer may take as long as it needs.
    await sink.addStream(response.stream.timeout(timeout));
    await sink.flush();
    await sink.close();
    sink = null;
    await part.rename(path);
  } finally {
    if (sink != null) {
      try {
        await sink.close();
      } catch (_) {}
    }
    if (part.existsSync()) part.deleteSync();
    if (client == null) c.close();
  }
}

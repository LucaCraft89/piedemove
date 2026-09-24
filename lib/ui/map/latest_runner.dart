/// Runs async jobs one at a time; while one is in flight only the newest
/// request is kept, so the last requested state always wins and none is
/// dropped or run interleaved with another.
class LatestRunner {
  Future<void> Function()? _pending;
  bool _running = false;

  void request(Future<void> Function() job) {
    _pending = job;
    if (!_running) _drain();
  }

  Future<void> _drain() async {
    _running = true;
    try {
      while (_pending != null) {
        final job = _pending!;
        _pending = null;
        try {
          await job();
        } catch (_) {} // each job isolates its own failures
      }
    } finally {
      _running = false;
    }
  }
}

/// Live trip vibrations (§12), strong enough to feel in a pocket on a bus.
///
/// `HapticFeedback.vibrate` is a UI tap: a few tens of milliseconds, weak,
/// and muted whenever the phone's touch feedback is off - riders barely felt
/// "scendi" (beta 5 report). The native channel in `MainActivity` plays a
/// full-amplitude waveform with alarm usage instead; the tap stays as the
/// fallback where the channel is missing (tests, other platforms).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:piedemove/location/live_trip.dart' show LiveCue;

const _channel = MethodChannel('piedemove/vibrate');

/// Off/on timings in ms (starting with a pause) and amplitudes 0-255.
typedef VibrationPattern = ({List<int> timings, List<int> amplitudes});

/// One stop left: two firm pulses. Get off now: three long ones, the last
/// longest - unmistakable, about 3.5 s in all.
VibrationPattern cuePattern(LiveCue cue) => switch (cue) {
      LiveCue.oneStopLeft => (
          timings: const [0, 500, 250, 500],
          amplitudes: const [0, 255, 0, 255],
        ),
      LiveCue.alightNow => (
          timings: const [0, 900, 300, 900, 300, 1200],
          amplitudes: const [0, 255, 0, 255, 0, 255],
        ),
    };

/// Never throws.
Future<void> vibrateCue(LiveCue cue) async {
  final p = cuePattern(cue);
  try {
    final ok = await _channel.invokeMethod<bool>(
        'pattern', {'timings': p.timings, 'amplitudes': p.amplitudes});
    if (ok == true) return;
  } catch (e) {
    debugPrint('pm: vibration channel: $e');
  }
  try {
    await HapticFeedback.vibrate();
  } catch (_) {}
}

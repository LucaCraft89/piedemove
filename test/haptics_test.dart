// "Scendi" must be felt: a strong native waveform, the UI tap only as fallback.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piedemove/location/haptics.dart';
import 'package:piedemove/location/live_trip.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('piedemove/vibrate');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('patterns: full strength, get-off the longest', () {
    for (final cue in LiveCue.values) {
      final p = cuePattern(cue);
      expect(p.timings.length, p.amplitudes.length);
      expect(p.amplitudes.where((a) => a > 0), everyElement(255));
    }
    int total(LiveCue c) => cuePattern(c).timings.fold(0, (a, b) => a + b);
    expect(total(LiveCue.alightNow), greaterThan(3000));
    expect(total(LiveCue.alightNow), greaterThan(total(LiveCue.oneStopLeft)));
  });

  test('the native waveform is asked for; no tap when it plays', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    final taps = <MethodCall>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      taps.add(call);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await vibrateCue(LiveCue.alightNow);
    expect(calls.single.method, 'pattern');
    expect((calls.single.arguments as Map)['timings'],
        cuePattern(LiveCue.alightNow).timings);
    expect(taps.where((c) => c.method == 'HapticFeedback.vibrate'), isEmpty);
  });

  test('without the channel it still taps, and never throws', () async {
    final taps = <MethodCall>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      taps.add(call);
      return null;
    });
    addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await vibrateCue(LiveCue.oneStopLeft);
    expect(taps.where((c) => c.method == 'HapticFeedback.vibrate'), hasLength(1));
  });

  test('"get off" with sound on also asks for the notification sound',
      () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await vibrateCue(LiveCue.alightNow, sound: true);
    expect(calls, ['sound', 'pattern']);
    calls.clear();
    await vibrateCue(LiveCue.oneStopLeft, sound: true);
    expect(calls, ['pattern'], reason: 'the early warning stays silent');
  });
}

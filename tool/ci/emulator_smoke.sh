#!/usr/bin/env bash
# Runs inside reactivecircus/android-emulator-runner (see .github/workflows/ci.yml):
# install, seed the prebuilt index, run the on-device smoke tour, capture one
# screenshot per `PM_STEP`, and fail on a crash in logcat.
set -uo pipefail

PKG=com.piedemove.piedemove
OUT=build/ci
mkdir -p "$OUT/shots"

adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done'
adb logcat -c

# Install first so the app's data dir exists, then seed the index the check
# job built (the app would otherwise download ~250 MB and build it on device).
adb install -r build/app/outputs/flutter-apk/app-debug.apk
# Answer the location prompt up front (it would cover every screenshot) and
# put the emulator's GPS in Turin (Politecnico) instead of California.
adb shell pm grant "$PKG" android.permission.ACCESS_FINE_LOCATION || true
adb shell pm grant "$PKG" android.permission.ACCESS_COARSE_LOCATION || true
adb emu geo fix 7.6624 45.0626 || true
if [ -f build/index.bin ]; then
  adb push build/index.bin /data/local/tmp/index.bin
  adb shell chmod 644 /data/local/tmp/index.bin
  # One string: adb shell re-splits its arguments on the device.
  adb shell "run-as $PKG sh -c 'mkdir -p files && cp /data/local/tmp/index.bin files/index.bin'" \
    && echo "seeded index.bin" || echo "could not seed index.bin: the app will build it"
fi

flutter test integration_test/app_smoke_test.dart -d emulator-5554 -r expanded \
  > "$OUT/itest.log" 2>&1 &
PID=$!
while kill -0 "$PID" 2>/dev/null; do
  for step in $(grep -o 'PM_STEP [A-Za-z0-9_-]*' "$OUT/itest.log" | awk '{print $2}'); do
    shot="$OUT/shots/$step.png"
    [ -f "$shot" ] || { adb exec-out screencap -p > "$shot"; echo "captured $step"; }
  done
  sleep 1
done
wait "$PID"
status=$?

adb logcat -d > "$OUT/logcat.txt"
tail -n 60 "$OUT/itest.log"
if grep -E "FATAL EXCEPTION|ANR in $PKG" "$OUT/logcat.txt"; then
  echo "::error::the app crashed or stopped responding on the emulator"
  status=1
fi
exit "$status"

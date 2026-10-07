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

# The slow CI emulator's own launcher stops responding while the app runs,
# and its "isn't responding" dialog covered every screenshot. Background
# ANR dialogs are off, and system dialogs are closed before each capture.
# (Not hide_error_dialogs: with it Android kills a foreground app that
# stalls for a moment instead of letting it recover. Our own ANRs still fail
# the run: logcat is checked below.)
adb shell settings put secure anr_show_background 0 || true

flutter test integration_test/app_smoke_test.dart -d emulator-5554 -r expanded \
  > "$OUT/itest.log" 2>&1 &
PID=$!
while kill -0 "$PID" 2>/dev/null; do
  for step in $(grep -o 'PM_STEP [A-Za-z0-9_-]*' "$OUT/itest.log" | awk '{print $2}'); do
    shot="$OUT/shots/$step.png"
    [ -f "$shot" ] || {
      adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null 2>&1 || true
      sleep 0.5
      adb exec-out screencap -p > "$shot"; echo "captured $step"; }
  done
  sleep 1
done
wait "$PID"
status=$?

# After the tour (installing APKs compiles them, and that load made the app
# stall at launch): the release APK must install as shipped - it is the one
# users get.
REL=build/app/outputs/flutter-apk/app-release.apk
if [ -f "$REL" ]; then
  if adb install -r "$REL" > "$OUT/release-install.txt" 2>&1 &&
     adb shell pm list packages | grep -q "package:$PKG"; then
    echo "release APK installs"
    adb uninstall "$PKG" >/dev/null 2>&1 || true
  else
    cat "$OUT/release-install.txt"
    echo "::error::the release APK does not install on the emulator"
    status=1
  fi
fi

# The newest published release, as users download it: logged, never fatal
# (the network or GitHub may be down; this checks what is already out).
pub=$(curl -fsSL https://api.github.com/repos/LucaCraft89/piedemove/releases \
  | python3 -c "import json,sys; r=[a['browser_download_url'] for x in json.load(sys.stdin) for a in x['assets'] if a['name'].endswith('.apk') and not a['name'].endswith('-arm64.apk')]; print(r[0] if r else '')" 2>/dev/null)
if [ -n "$pub" ] && curl -fsSL -o /tmp/published.apk "$pub"; then
  if adb install -r /tmp/published.apk > "$OUT/published-install.txt" 2>&1; then
    echo "PM_PUBLISHED installs: $pub"
  else
    echo "PM_PUBLISHED does NOT install: $pub: $(tail -1 "$OUT/published-install.txt")"
  fi
  adb uninstall "$PKG" >/dev/null 2>&1 || true
fi

adb logcat -d > "$OUT/logcat.txt"
tail -n 60 "$OUT/itest.log"
if grep -E "FATAL EXCEPTION|ANR in $PKG" "$OUT/logcat.txt"; then
  echo "::error::the app crashed or stopped responding on the emulator"
  status=1
fi
exit "$status"

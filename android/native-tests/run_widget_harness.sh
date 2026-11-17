#!/bin/bash
set -euo pipefail

shiri_serial="${1:-emulator-5580}"
case "$shiri_serial" in emulator-*) ;; *) echo 'Refusing to run this test on a physical device.' >&2; exit 2;; esac
shiri_repo="$(cd "$(dirname "$0")/../.." && pwd)"
shiri_adb="${SHIRI_ADB:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb}"
shiri_build="${SHIRI_ANDROID_BUILD_DIR:-/private/tmp/shiri-android-native-build}"
shiri_test_apk="$shiri_build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
shiri_output="${2:-$shiri_repo/build-deliverables}"

cleanup() {
  "$shiri_adb" -s "$shiri_serial" shell appwidget revokebind --package com.shiri.anniversary --user 0 >/dev/null 2>&1 || true
  "$shiri_adb" -s "$shiri_serial" uninstall com.shiri.anniversary.test >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$shiri_adb" -s "$shiri_serial" install -t -r "$shiri_test_apk"
"$shiri_adb" -s "$shiri_serial" shell appwidget grantbind --package com.shiri.anniversary --user 0
shiri_result="$("$shiri_adb" -s "$shiri_serial" shell am instrument -w com.shiri.anniversary.test/com.shiri.anniversary.WidgetRenderHarness)"
printf '%s\n' "$shiri_result"
case "$shiri_result" in *'PASS: actual AppWidgetHostView'*) ;; *) exit 1;; esac
mkdir -p "$shiri_output"
dot_clean "$shiri_repo"
for shiri_size in compact compact-wide small medium; do
  "$shiri_adb" -s "$shiri_serial" exec-out run-as com.shiri.anniversary cat "cache/widget-$shiri_size.png" > "$shiri_output/android-widget-$shiri_size.png"
  dot_clean "$shiri_repo"
done
printf 'Widget renders saved to %s\n' "$shiri_output"

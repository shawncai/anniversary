# Android native delivery checklist

- [x] Android 8 / API 26 minimum; Flutter template AGP 8.7.3 and Kotlin 2.1.0 retained.
- [x] Existing NDK 26.3.11579264 pinned; no third-party Android runtime dependencies added.
- [x] App-private originals and thumbnails; operating-system cloud backup and device migration disabled.
- [x] System photo/document pickers, full/selected-photo permissions, capture-date scan pagination.
- [x] Native P-256, HKDF-SHA256 and AES-256-GCM; one-use ephemeral handles.
- [x] BLE GATT server/central discovery with permission errors and lifecycle cleanup; sender port 0 scans without advertising.
- [x] Pending native P-256 handles cleared when discovery stops or activity leaves foreground.
- [x] Real resizable RemoteViews home widget, independent event configuration, deep links.
- [x] Local-calendar date calculations, midnight refresh, timezone/date/boot/package updates.
- [x] No sample or remote photos; widget uses only app-private user cover or plain white background.
- [x] Kotlin/resource compilation and complete universal debug APK (`assembleDebug`, 2026-11-13).
- [x] APK v2 debug signature verified; minSdk26 / targetSdk35; armv7, arm64 and x86_64 included.
- [x] Final APK inspected: no test fixtures, demo/design assets, or bundled photo images.
- [x] Native AES-GCM known-answer/tamper checks, ECDH/HKDF agreement, one-use handles.
- [x] Native widget dates: reference counts, day zero, anniversary today, future dates, leap day, DST and year boundary.
- [x] Android 35 emulator: actual AppWidgetHostView small/medium render, independent event selection and resize passed.
- [x] Android 35 emulator: platform AES-GCM known-answer/tamper rejection and P-256/HKDF agreement passed.
- [x] Fixed RemoteViews bitmap budget overflow using the smaller physical/current display pixel budget and sRGB ARGB8888 covers.
- [x] Temporary test host IDs, bind permission and test APK cleaned up; user test library preserved.
- [x] Final-widget removal cancels midnight alarm even when delayed update broadcasts arrive; emulator alarm cancellation verified.
- [ ] Full Flutter UI integration (coordinated by root agent).
- [ ] Physical iOS ↔ Android BLE discovery and encrypted transfer verification.

## Local build environment

The repository and the default Gradle cache are on exFAT. macOS creates AppleDouble sidecars there, which Gradle/AAPT can mistake for class files or resource directories. Build with internal-disk intermediate paths; source files remain in the repository:

```sh
export JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home'
export GRADLE_USER_HOME=/private/tmp/shiri-gradle-native
export SHIRI_ANDROID_BUILD_DIR=/private/tmp/shiri-android-native-build
./gradlew :app:assembleDebug --no-daemon --console=plain
```

`SHIRI_ANDROID_BUILD_DIR` is optional on normal APFS/Linux/Windows filesystems. The standard output remains `../build` when unset. The local temporary Gradle home reuses the existing `modules-2` dependency and `wrapper` caches through symlinks; it does not erase or change the user's cache layout.

For a final production release, supply a real signing configuration through the release environment. The release build intentionally does not reuse the debug signing key.

The [standalone native crypto harness](./native-tests/CryptoCheck.java) runs against the compiled [ShiriCrypto](./app/src/main/kotlin/com/shiri/anniversary/ShiriCrypto.kt) class and Kotlin stdlib without JUnit or extra dependencies.

## Native widget render harness (test APK only)

The [instrumentation harness](./app/src/androidTest/java/com/shiri/anniversary/WidgetRenderHarness.java) binds the actual provider to a temporary AppWidgetHost, validates event selection and renders small/medium RemoteViews. It also runs AES-GCM known-answer/tamper checks and P-256/HKDF on Android's native providers. It requires already imported test user data. It contains no fixed photos and adds no component to the production APK.

Build the test APK with the same internal-disk environment above:

```sh
./gradlew -I native-tests/widget_test.init.gradle :app:assembleDebugAndroidTest --no-daemon --console=plain -Pkotlin.compiler.execution.strategy=in-process
```

Run only on the task's emulator, after the production debug APK and test data are present:

```sh
adb -s emulator-5580 install -t -r /private/tmp/shiri-android-native-build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb -s emulator-5580 shell appwidget grantbind --package com.shiri.anniversary --user 0
adb -s emulator-5580 shell am instrument -w com.shiri.anniversary.test/com.shiri.anniversary.WidgetRenderHarness
adb -s emulator-5580 shell appwidget revokebind --package com.shiri.anniversary --user 0
```

The harness deletes only its allocated widget ID and stops its host in a `finally` block. Always revoke its temporary bind permission after execution, including failure. Rendered PNGs are written into the target app's cache as `widget-small.png` and `widget-medium.png`. The independent test APK can be uninstalled after inspection; do not clear the app's imported data.

The widget PNGs are native `AppWidgetHostView` renders, not launcher-screen captures. The test used host-injected user-library fixtures; those photos are absent from the delivered production APK.

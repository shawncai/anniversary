# Shiri native bridge v1

Flutter 3.32.6 (installed SDK), Dart 3.8. iOS 16+, Android 26+. Bundle/application ID `com.shiri.anniversary`; widget App Group `group.com.shiri.anniversary`.

Method channel: `com.shiri.anniversary/platform`. All native work must return errors through FlutterError / result.error and complete each result once. User cancellation returns null. Heavy photo/file/crypto work runs off the main thread.

## Methods

- `paths` → `{documents: absolutePath, temporary: absolutePath}`. Documents directory is app-private and explicitly excluded from OS cloud backup. No storage permission needed.
- `photoPermission` → `full | limited | denied | restricted | notDetermined`.
- `requestPhotoPermission` → same status. Native full/limited authorization request only when asked from UI.
- `pickPhotos` → list of imported PhotoInput objects below, or null on cancel. Multiple system-picker selection; copy originals and create JPEG thumbnails locally. Original HEIC bytes remain intact; Flutter renders JPEG thumbnail.
- `scanPhotos` args `{startYear:int,month:int,day:int,windowDays:int,offset:int,limit:int}` → `{items:[PhotoInput],nextOffset:int|null,unavailable:int}`. Enumerate authorized still-image metadata, reject dates before the first anniversary date before copying, and match month/day within tolerance including year boundaries. Copy only matching local originals; do not silently download cloud-only assets. `offset` counts matching assets, limit capped100; the app uses batches of20 for cancellation and staging size. Android prefers valid MediaStore DATE_TAKEN, then EXIF original date, then creation/modification fallback; the same resolved timestamp is returned to Dart. iOS uses PhotoKit creationDate. Original files use generated names in documents/imports. Dart validates the range again and commits confirmed associations directly, with SHA256 deduplication and cleanup of every staged input.
- `importFile` → absolutePath copied to temporary, or null. Native document picker for `.shiri` (application/octet-stream accepted).
- `exportFile` args `{path:absolutePath,name:string}` → bool saved (false on cancel). Native export/document-create flow; do not overwrite without platform confirmation.
- `updateWidgets` args `{json:string,coverPath:string|null}` → null. JSON WidgetSnapshot below. Copy cover to shared widget container only when path exists; snapshot atomic; reload all widgets. Android per-widget selected IDs should survive snapshot updates. iOS uses App Group.
- `requestPinWidget` → bool (Android launcher pin request; iOS false, instructions shown by Flutter).
- `initialLink` → `shiri://anniversary/<id>` or null. Native also invokes Flutter `onDeepLink` with URI string for warm launches.
- `openSettings` → null.
- `deviceName` → user-facing device model/name string. Used only on local pairing screen.
- `startDiscovery` args `{name:string,host:string,port:int}` → bool supported/started. Start BLE only while transfer UI visible. port=0 means sender central scan only; port1..65535 means receiver scan plus advertising a readable endpoint. service UUID `9b5971e4-3790-4bd0-b670-ef6e28d22a01`, readable characteristic `9b5971e4-3790-4bd0-b670-ef6e28d22a02` holds UTF8 JSON `{name,host,port}`. Native invokes Flutter `onNearbyDevice` with same map. BLE advertises UUID, central connects+reads characteristic. No photo data or secrets in advertisement. Report unsupported/permission denial rather than pretending success.
- `stopDiscovery` → null. Stop advertising/scanning, close GATT/peripheral connections. Also stop on activity/application lifecycle exit.

## PhotoInput

`{sourceId:string,originalPath:absolutePath,thumbnailPath:absolutePath,capturedAt:ISO8601,originalName:string,mimeType:string}`. Source IDs stable per library asset where available. CapturedAt uses photo creation/date-taken (fallback creation/modification date only if absent). Data layer labels user-editable date. Filename never used as a trusted filesystem path.

## WidgetSnapshot

`{version:1,selectedEventId:string|null,events:[{id:string,title:string,startDate:"YYYY-MM-DD",coverPath:string|null,lightText:bool}],updatedAt:ISO8601}`.

Native copies supplied coverPath to its widget-shared `cover.jpg`; selected event may use it. Small/medium home widgets show title, days until next anniversary, elapsed days, next date and cover if present. iOS also supports accessoryRectangular. Native date calculations use local calendar day differences, not milliseconds. Start date day=0; anniversary today countdown=0; Feb29 maps to Feb28 in non-leap years. Future dates count toward first date, never negative elapsed.

Widget tap deep-links to its event. iOS timelines provide daily midnight entries for at least14 days; Android updates on DATE_CHANGED/TIME_SET/TIMEZONE_CHANGED, app state changes and provider interval. OS timing is not an exact-second promise.

## Native crypto for local encrypted transfers

- `cryptoKeyPair` → `{handle:string,publicKey:Uint8List}`. Ephemeral P-256 agreement pair in memory; publicKey is ANSI X9.63 uncompressed65-byte point (04||X||Y).
- `cryptoDerive` args `{handle,peerPublicKey:Uint8List,salt:Uint8List}` → Uint8List32. ECDH P256 + HKDF-SHA256 with passed salt and UTF8 info `shiri-transfer-v1`. Destroy key-pair handle after derive. Standard native CryptoKit / javax.crypto, no custom curve implementation.
- `cryptoSeal` args `{key:Uint8List32,nonce:Uint8List12,plaintext:Uint8List,aad:Uint8List}` → ciphertext||tag16 (no nonce prefix). AES256-GCM.
- `cryptoOpen` args `{key,nonce,ciphertext,aad}` → plaintext; authentication failure throws. Never log key/data.

Protocol is implemented in Dart. Per-transfer session salt32 and random nonces; mutual six-digit SAS confirmation derived from shared key protects handshake from MITM. No file is accepted until both peers confirm same SAS. All archive chunks are AES-GCM authenticated with sequence+session AAD; data never sent in plaintext. The address and public handshake metadata are the only unencrypted LAN data. Sessions expire and server stops on exit.

## Agent ownership

- Core agent: `lib/core/**`, core tests. Domain/repository/archive/transfer; no UI or native files.
- iOS agent: `ios/**`, optional `scripts/configure_ios_widgets.rb`. No Android or Dart edits.
- Android agent: `android/**`. No iOS or Dart edits.
- Root: app UI, `lib/platform/**`, assets, app bootstrap, package/config docs and integration.

After every generated file/folder run `dot_clean ./` at repo root. Do not install or upgrade dependencies without review. Crypto3.0.6 from verified dart.dev publisher is the only proposed third-party runtime package; used for SHA256/HMAC, pinned. Flutter SDK/toolchain dependencies are separately locked. No npm/yarn; Node not needed.

## Calendar reminders (2026-11-16)

- `syncReminder` takes the anniversary JSON plus `requestPermissions:bool`, returning a human-readable status. Permissions are requested only after an explicit editor save; background restore/resume reconciliation uses `false`. No third-party SDK or network call is involved.
- Android uses READ_CALENDAR/WRITE_CALENDAR and a dedicated `ACCOUNT_TYPE_LOCAL` calendar (`拾日 · 本机`). Upserts match calendar ID, app package and stable anniversary deep link. Annual events use RRULE plus DURATION; one-time events clear both and use DTEND. A zero-minute alert belongs to the app. Repeated saves and reinstall recovery replace that alert, not the event. Calendar provider operations are transactional and selections parameterized.
- iOS uses EventKit full event access (iOS17+) / event access (iOS16). Only a local source is eligible; no default iCloud/Exchange/Google calendar is selected. Events are matched by device-local identifier plus app deep link, with a date-bounded recovery lookup. Annual EKRecurrenceRule / single event plus EKAlarm provide system Calendar alerts. If no local source exists or permission is denied, the returned status explicitly says only in-app reminders are available. Calendar delivery depends on system Calendar notification settings.
- February29 recurs on the last day of February; date-only math and widget recurrence use the same rule. Past one-time events remain historical calendar entries and do not generate a late alert. The default reminder is09:00 local; the editor permits another time.
- `takeDayReminders {ids,date}` returns IDs not yet shown that day and records them in device-only preferences. App startup, resume and minute changes check enabled due events; a single dialog lists all due anniversaries. These acknowledgement keys and native calendar record IDs never enter exported backups.
- Widget event snapshots now include optional `repeatYearly` (defaulttrue for old snapshots). A completed one-time date displays elapsed days instead of another annual countdown. Widget photos refresh to the current cover when the app syncs; OS widgets do not promise second-by-second slideshow playback.

Native references: [Android Calendar Provider](https://developer.android.com/identity/providers/calendar-provider), [Apple EventKit access](https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoevents(completion:)), [EKAlarm](https://developer.apple.com/documentation/eventkit/ekalarm).

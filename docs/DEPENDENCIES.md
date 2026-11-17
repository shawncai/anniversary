# Dependency review

2026-11-13. Runtime review before installation:

- Flutter 3.32.6 / Dart 3.8.1: existing installed stable SDK, commit 077b4a4ce1. Tool invocation filled its missing matching Dart cache; no SDK upgrade was performed.
- flutter, flutter_localizations, flutter_test, integration_test: official Flutter SDK packages, SDK-locked. Localization is required for native Chinese date-picker strings; test packages do not ship in release.
- crypto 3.0.6: pinned exact version already cached locally; verified dart.dev publisher, BSD-3-Clause; pure Dart SHA-256 and HMAC for file identity, archive integrity and transfer SAS. It performs no network, storage, permission request or dynamic code execution. Native CryptoKit/javax.crypto performs P-256/HKDF/AES-GCM encryption.
- Android Gradle Plugin, Gradle, Kotlin and AndroidX entries are Flutter-generated build dependencies; native agent keeps reviewed template versions, no automatic updates. See Gradle configuration and lock/checksum notes.
- iOS uses system Photos, PhotosUI, UniformTypeIdentifiers, CoreBluetooth, CryptoKit, EventKit, WidgetKit, AppIntents and Foundation. No third-party native runtime SDK.

Sources:
- https://pub.dev/packages/crypto/versions/3.0.6
- https://pub.dev/packages/crypto/versions/3.0.6/license
- https://docs.flutter.dev/platform-integration/platform-channels

No analytics, advertising, remote font, cloud, login, npm or yarn package is introduced. Version changes require a new review. pubspec.lock is committed as part of the deliverable. This is a bounded source/purpose review, not a claim of exhaustive vulnerability scanning.

Development-only validation components installed from official vendors: Android SDK system-images;android-35;default;arm64-v8a revision2, and Apple iOS26.0.1 Simulator runtime23A8464 arm64. These are test environments, not application dependencies or SDK upgrades.

2026-11-16 typography review: Adobe Source Han Sans 2.005R, immutable revision `6c709ca72d3d7c46ab42ebecc1a26e7d69595a37`, official CN regional subset OTF in Light/Regular/Medium/Bold. Unmodified assets, each with30,926 Unicode mappings, not an app-string-only subset. SIL Open Font License1.1 permits bundling; copyright/reserved names and full license are retained. Downloaded Git blob hashes were checked against the official tagged tree; sizes and SHA256 are recorded in `assets/font_manifest.json`. Flutter embeds four weights; native widgets reuse the three weights they use. No runtime download, tracking or new package dependency. Asset licensing is included in the app at `assets/licenses/source_han_sans_OFL.txt`.

Official source: https://github.com/adobe-fonts/source-han-sans/tree/2.005R

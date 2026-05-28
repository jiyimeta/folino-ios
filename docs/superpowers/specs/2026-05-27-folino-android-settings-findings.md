# Folino Android Settings Spike — Findings

Date: 2026-05-27 (completed 2026-05-28)
Branch: `worktree-android-settings-spike`
Spike spec: `docs/superpowers/specs/2026-05-27-folino-android-settings-spike-design.md`
Spike plan: `docs/superpowers/plans/2026-05-27-folino-android-settings-spike.md`

---

## 1. Summary

The spike validated that Folino's Settings screen can run on Android by sharing Foundation-only Swift
logic cross-compiled via the Swift 6.3 Android SDK, exposed to Kotlin through swift-java JNI bindings, with
data ferried across the JNI boundary via swift-wirelet binary codecs. A working screen ran on a physical
Pixel 8a (Android 16, arm64-v8a): DataStore-backed toggle/layout preferences persist correctly, and the
version-history section shows real Swift-decoded content — 8 versions from 1.5.1 to 1.2.0 with
locale-resolved English descriptions, proving Swift executed `VersionHistoryEntry.init(from:)` with `Locale.current`
on-device. The `*Logic` / `*` (UI) product split proposed in the 2026-05-21 spec works in practice: the
`SettingsLogic` product (protocol + ViewModel + wire types + JSON loader) compiled unchanged for Android;
only the UI layer required a full Compose reimplementation. Two minimal `#if canImport` guards were needed in
Domain at spike time; both have since been superseded by cleaner architectural fixes (see §1.1).

Screenshots:

- `/tmp/folino-settings-p3.png` — P3: DataStore toggles + placeholder version history header
- `/tmp/folino-settings-p4.png` — P4: real Swift-decoded version history (8 entries, English descriptions)
- `/tmp/folino-settings-final.png` — post-Fix state: Settings screen with Material icons + Licenses row
- `/tmp/folino-licenses.png` — post-Fix state: AboutLibraries Licenses screen (populated dependency list)

### 1.1 Follow-up fixes applied after initial spike

Five follow-up commits moved items from "needs separate handling / known issue" to "applied":

- **`0f75ba4`** Use Double for ReaderPreferences.staffSize; drop Domain's CoreGraphics dependency
- **`bf40189`** Move DomainError's LocalizedError conformance from Domain to App
- **`2828fec`** Add Material icons to Compose Settings rows (matching iOS SF Symbols)
- **`f53ad4d`** Add AboutLibraries-powered Licenses screen reachable from Settings
- **`1ed8204`** Narrow Material3 @OptIn from MainActivity class to LicensesRoute composable

---

## 2. Environment setup

### Toolchain

| Item | Value |
| --- | --- |
| Swift toolchain ID | `org.swift.632202605101a` |
| Swift toolchain banner | `Apple Swift version 6.3.2 (swift-6.3.2-RELEASE)` |
| Host triple | `arm64-apple-macosx26.0` |
| Android Swift SDK name | `swift-6.3.2-RELEASE_android` |
| SDK installed via | `swift sdk list` — already present at session start |

Verified with `TOOLCHAINS=org.swift.632202605101a swift --version`. The banner shows `swift-6.3.2-RELEASE`
(not `swiftlang-6.3.2`), confirming the open-source toolchain is active. **Apple's Xcode Swift rejects the
SDK's Foundation swiftmodule** — the open-source toolchain must be used for all cross-compile steps.

The spike-time `#if canImport(CoreGraphics)` and `#if canImport(Darwin)` guards in Domain (commit `25215e2`)
have been superseded by `0f75ba4` and `bf40189` respectively. Domain no longer contains any `#if canImport`
guards — it is Android-clean unconditionally.

### NDK

| Item | Value |
| --- | --- |
| NDK version | `28.2.13676358` |
| NDK path | `~/Library/Android/sdk/ndk/28.2.13676358` |
| Sysroot setup | `setup-android-sdk.sh` — must be run once per machine (or after NDK upgrade) |

Script: `~/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle/swift-android/scripts/setup-android-sdk.sh`.
It rewrites a sysroot symlink inside the artifactbundle; without it, cross-compilation fails with
`'semaphore.h' file not found`. The script is idempotent.

### Cross-compile smoke test (Phase 0)

Target: `aarch64-unknown-linux-android28`, product `SheetMusicCore` from `swift-sheet-music`, release mode.

```sh
TOOLCHAINS=org.swift.632202605101a SWIFT_SHEET_MUSIC_ANDROID=1 \
  swift build --package-path <ssm> --product SheetMusicCore \
  --swift-sdk aarch64-unknown-linux-android28 -c release
```

Result: **BUILD SUCCESSFUL** — `Build of product 'SheetMusicCore' complete! (538.47s)`.
First build ~9 minutes on Apple M-series; subsequent incremental builds are much faster.
Notable: swift-java's `JExtractSwiftPlugin` runs automatically as a build-tool plugin; `libSheetMusicAndroidJNI.so`
was the final artifact.

### swiftkit-core Maven local publish

Source: `swift-sheet-music/.build/checkouts/swift-java` (the swift-java revision pinned in SSM's
`Package.resolved`).

```sh
<swift-java-checkout>/gradlew -p <swift-java-checkout> :SwiftKitCore:publishToMavenLocal
```

Result: **BUILD SUCCESSFUL in 42s**. Artifact path: `~/.m2/repository/org/swift/swiftkit/swiftkit-core/1.0-SNAPSHOT/`.

**swiftkit-core is not on Maven Central** — `publishToMavenLocal` is a required setup step on every fresh
machine or CI runner. The `gradlew` wrapper in the SSM SwiftPM checkout is self-contained.

### JDK versions

| JDK | Version | Role |
| --- | --- | --- |
| Host `java` (PATH) | OpenJDK 18.0.1.1 (AdoptOpenJDK) | Default JAVA_HOME |
| Gradle-selected for Folino Android builds | Azul Zulu 17.0.17 | Explicit override via `org.gradle.java.home` |

`org.gradle.java.home` in `Android/gradle.properties` currently hardcodes the Zulu-17 path
(`/Library/Java/JavaVirtualMachines/zulu-17.jdk/Contents/Home`). This is machine-specific and must be moved
to a per-developer override (e.g. `~/.gradle/gradle.properties`) before the project is shared or added to CI.

### GitHub Packages credentials

`~/.gradle/gradle.properties` contains `gpr.user` and `gpr.key`. Required to resolve
`io.github.jiyimeta:wirelet-*` from the wirelet GitHub Packages Maven repo.

### Setup friction summary

| Step | Notes |
| --- | --- |
| NDK sysroot re-link | One-time per machine or NDK upgrade; idempotent |
| swiftkit-core mavenLocal publish | One-time per machine/CI runner |
| Zulu-17 JDK installed | AGP minimum; host OpenJDK 18 not usable for Android Gradle |
| gpr.user/gpr.key in `~/.gradle/gradle.properties` | Required for wirelet dependency resolution |
| First cross-compile ~9 min | Subsequent builds are incremental and much faster |

---

## 3. What was shared cleanly (できること)

### 3.1 SettingsLogic product (Phase 1, commit d1e4ff5 + fix 76881aa)

The `SettingsLogic` SwiftPM product was extracted from the iOS `Settings` product by a behavior-preserving
split. It contains:

| Symbol | Type | Compiled on Android? |
| --- | --- | --- |
| `VersionHistoryLoader` | `protocol` (Foundation-only) | Yes |
| `VersionHistoryViewModel` | `@Observable @MainActor class` | Yes (`libswiftObservation.so` ships in the SDK) |
| `VersionHistoryWire` / `VersionHistoryWireList` | `@WireFormat` structs | Yes |
| `JSONVersionHistoryLoader` | `struct` (pure Foundation + Codable) | Yes |
| `versionHistoryWirePayload` | `func` | Yes |

The Yams-backed `DefaultVersionHistoryLoader` and all SwiftUI views stayed in the iOS-only `Settings` product.
iOS test suites were unaffected: SettingsLogicTests 3/3 green, SettingsTests 9/9 green.

**Gotcha (76881aa):** `App/VersionHistoryPresenter.swift` and
`Tests/FolinoTests/VersionHistoryPresenterTests.swift` both needed an explicit `import SettingsLogic`.
Swift does not re-export a dependency's symbols through `import Settings`. The test import was missed
initially and caused a clean-build compile error (`cannot find type 'VersionHistoryLoader'`).

### 3.2 Domain platform compatibility (spike commit 25215e2; superseded by 0f75ba4 + bf40189)

At spike time, two minimal `#if canImport` guards were added in Domain (commit `25215e2`). Both have since
been replaced by cleaner fixes:

**`staffSize` / CoreGraphics (`0f75ba4`):** All six `CGFloat` occurrences in
`Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift` (`staffSize` property, init param, Codable
decode, `minStaffSize`, `maxStaffSize` constants) were changed to `Double`. Five downstream Reader files
(`LayoutSettingsModel`, `ReaderPreferencesStore`, `ReaderViewModel`, `ReaderRootScreen`,
`VisualInspectorScreen`) had explicit `CGFloat` annotations updated. SwiftUI views further downstream use
SE-0307 implicit conversion (`Double` → `CGFloat`) — deliberate scope limit. The `#if canImport(CoreGraphics)`
import guard was removed. iOS behavior is identical (`CGFloat == Double` on 64-bit Apple; JSON wire format
unchanged). Domain now has zero `CGFloat` or CoreGraphics references.

**`DomainError` / Darwin (`bf40189`):** `DomainError` is now a pure
`enum DomainError: Error, Sendable, Equatable { … }` with no `LocalizedError` conformance and no
`String(localized:)` call. A new `App/DomainError+LocalizedError.swift` provides `@retroactive LocalizedError`
conformance with the same switch, keeping the bundle reference in App. All seven `domain.error.*` localized
string keys (× 5 locales) moved from `Packages/Domain/Sources/Domain/Resources/Localizable.xcstrings` to
`App/Resources/Localizable.xcstrings` (byte-identical translations). Domain's `Resources/` directory was
deleted; `Packages/Domain/Package.swift` no longer declares `resources:` for the Domain target. Because
Features cannot import App, `LibraryViewModel.describe()` and `ReaderViewModel.describe()` received
per-feature fallback strings (`library.error.fallback.*` / `reader.error.fallback.*` — 4 keys each, verbatim
copies of the originals) for cases they format themselves. Screens that surface errors via
`(error as? LocalizedError)?.errorDescription` work through App's extension at runtime.

### 3.3 Wire type roundtrip

`swift-wirelet 0.1.0-alpha.2` supports `[String]` fields AND nested `[@WireFormat]` arrays — no shape
workarounds were needed. The roundtrip test (`VersionHistoryWireListRoundtripTests`) passes.

### 3.4 @Observable on Android

`@Observable` and `import Observation` compiled correctly on Android without modification. The SDK ships
`libswiftObservation.so`. (Note: reactive observation across JNI was not exercised in this spike — see §6.)

---

## 4. What had to be reimplemented natively in Compose (できないこと — UI layer)

There is no shared UI path between iOS and Android. Every UI element was reimplemented in Jetpack Compose.

| Settings element | iOS (SwiftUI) | Android (Compose) | Notes |
| --- | --- | --- | --- |
| Reader toggle rows (4 items) | `Toggle` in `Form` | `Switch` + `Row` in `LazyColumn` | Defaults match exactly |
| Layout mode picker | Segmented `Picker` (V/H/P) | `SingleChoiceSegmentedButtonRow` | Same 3 options |
| "Reader" section header | `Section` header | `Text(titleSmall)` | Plain text |
| Version history list | `VersionHistoryScreen` SwiftUI view | `items(versionHistory.size)` in LazyColumn | Correct data |
| Soundfont picker row | `SoundfontPresetRow` | Not implemented (out of scope) | |
| Feedback mail | `FeedbackMailView` (`MFMailComposeViewController`) | Not implemented (out of scope) | No Android equivalent |
| License list | `LicenseListView` (iOS build-tool plugin) | `LibrariesContainer` via AboutLibraries 11.2.3 (`f53ad4d`) | Navigated from Settings "About" section |

### 4.1 Material icons for Settings rows (commit 2828fec)

`androidx.compose.material:material-icons-extended` (BOM-pinned) was added. `ToggleRow` now takes a
leading `imageVector` parameter; all callers updated with `contentDescription` set per icon.

| Settings row | SF Symbol (iOS) | Material Icon (Android) | Notes |
| --- | --- | --- | --- |
| Metronome | `metronome` | `Icons.Filled.MusicNote` | |
| Picture-in-Picture | `pip` | `Icons.Filled.PictureInPicture` | |
| Collapse rests | `arrow.up.and.down.text.horizontal` | `Icons.Filled.UnfoldLess` | |
| Keep screen awake | `sun.max` | `Icons.Filled.ScreenLockPortrait` | Semantically imperfect; see §7 |
| Layout mode | `square.split.2x1` | `Icons.Filled.ViewArray` | |
| Version History header | (section header) | `Icons.Filled.History` | 8 dp padding (vs 12 dp in ToggleRow; see §7) |

### 4.2 Licenses screen (commit f53ad4d + 1ed8204)

- Root `Android/build.gradle.kts`: `id("com.mikepenz.aboutlibraries.plugin") version "11.2.3" apply false`.
- App applies the plugin + runtime deps `aboutlibraries-core:11.2.3`, `aboutlibraries-compose-m3:11.2.3`,
  and `androidx.navigation:navigation-compose:2.8.0`.
- New `LicensesScreen.kt` wraps `LibrariesContainer` (M3).
- `MainActivity.kt` hosts a `NavHost` with `settings` and `licenses` routes; the licenses route renders a
  `Scaffold` + `TopAppBar("Licenses")` with a back arrow, extracted into a `private @Composable fun
  LicensesRoute(onBack: () -> Unit)` (commit `1ed8204` narrowed `@OptIn(ExperimentalMaterial3Api::class)`
  from class-level to this function).
- `SettingsScreen.kt` has a new "About" section with a clickable "Licenses" row
  (`Icons.Filled.Description`) that calls `onOpenLicenses`.
- Runtime-verified on Pixel 6 Pro API 36 emulator: the Licenses screen renders a populated dependency list
  (AboutLibraries 11.2.3, Activity 1.9.2, AppCompat 1.6.1, …) with Apache 2.0 badges.
  Screenshots: `/tmp/folino-settings-final.png` and `/tmp/folino-licenses.png`.

---

## 5. What needs separate handling (別途対応が必要なこと)

| Item | Reason | Required work |
| --- | --- | --- |
| Settings persistence (DataStore vs AppStorage) | `@AppStorage` / SwiftData don't exist on Android | Kotlin DataStore (done in spike); key contract not shared (see §6.5) |
| Localization / `.xcstrings` | `String(localized:)` and `.xcstrings` have no Android path | Decide: share strings file + a script-based emitter, or maintain per-platform string resources |
| Soundfont provider | `MuseScoreGeneralProvider` + download state machine; iOS-specific asset delivery | Full reimplementation needed on Android |
| Crash reporting | Firebase Crashlytics iOS SDK | Firebase Crashlytics Android SDK (separate setup) |
| Feedback mail | `MFMailComposeViewController` — iOS only | Android Intent-based mail; no shared code possible |
| SF Symbols → Material Icons | Apple-only asset; mapping now implemented for Settings rows (`2828fec`) | Apply same mapping discipline to future screens; no shared asset |
| Main-thread JNI decode | `MainActivity.onCreate` decodes on main thread (acceptable for spike) | Move to ViewModel + coroutine before production |
| JNI error handling | `VersionHistoryBridge.decode` has no error handling; malformed payload crashes | Wrap in `runCatching` for production |
| Yams-backed loader (iOS only) | `DefaultVersionHistoryLoader` uses Yams; stays in iOS `Settings` product | Android uses `JSONVersionHistoryLoader`; no change needed |

**Items resolved since initial spike:** Domain CoreGraphics guards → fixed by `0f75ba4`. DomainError
Android fallback → fixed by `bf40189`. License list has no Android path → resolved by AboutLibraries in
`f53ad4d`. SF Symbol substitution for Settings rows → implemented in `2828fec` (mapping table above).

---

## 6. Architecture findings and unresolved decisions for productization

### 6.1 The `*Logic` / `*` split is validated

The `SettingsLogic` / `Settings` product split from the 2026-05-21 spec worked correctly in practice.
Settings was a good first target because its shareable logic (`VersionHistoryViewModel` + the JSON loader)
is stateless. The same split will be needed for every Feature intended for Android.

### 6.2 `@Observable` reactive stores not exercised across JNI

This spike used a one-shot JNI call (load-on-startup, not reactive). The 2026-05-21 spec flagged reactive
observation across JNI as the main risk. A Reader or Editor pilot would need to validate that
`@Observable`-backed ViewModels can drive Compose state correctly via a JNI event loop — this remains
unvalidated.

### 6.3 Domain's Android-clean rule is now codified

The two `#if canImport` guards added at spike time (commit `25215e2`) were a minimal fix. The follow-up
commits `0f75ba4` and `bf40189` replaced them with the correct architectural approach: Domain stays a pure
value-type / protocol layer with no platform-specific imports; localization belongs in the UI tier (App or
Feature). This rule is now enforced by the absence of any `#if canImport`, `CGFloat`, CoreGraphics, or
`String(localized:)` call in Domain. Future Domain-compat audits should flag any regression to these
patterns.

The per-feature fallback string approach (`library.error.fallback.*` / `reader.error.fallback.*`) is a
direct consequence of the Feature-can't-import-App rule: Features format their own error messages without
reaching into App's `DomainError+LocalizedError` extension.

### 6.4 Localization strategy is unresolved

Domain no longer carries localized strings (resolved by `bf40189`). The remaining question is how
`.xcstrings` content for non-Domain strings should reach Android. Options include:

- A script that exports `.xcstrings` to Android `strings.xml` format at build time.
- Duplicating user-visible strings per platform (maintenance burden, but keeps platforms decoupled).
- Routing all localization through Swift (pass locale as input, return pre-localized strings over JNI).

This decision should be made before any Feature with significant user-visible copy is ported.

### 6.5 DataStore key contract is not shared

`SettingsPrefs` uses plain string keys (`"reader.metronome.enabled"`, etc.) that are visually aligned with
iOS `ReaderGlobalSettingsKey` / `PrivacySettingsKey` typed constants, but there is no compile-time
contract ensuring they match. If a key is renamed on iOS, the Android side silently diverges. A shared
key definition (even as a documentation table) is needed before production.

### 6.6 swift-java + wirelet vs. `@_cdecl` plan

The 2026-05-21 spec proposed using `@_cdecl` for the JNI boundary. The spike superseded that with
swift-java jextract + wirelet. The swap held up: swift-java's static initializer (`SwiftLibraries.loadLibraryWithFallbacks`)
handled `.so` load order correctly with no manual `System.loadLibrary` calls and no logcat errors.
wirelet `0.1.0-alpha.2` generated correct `VersionHistoryWireListCodec` + model classes for the
`kotlin.android` source set with a manual `dependsOn` wiring (the plugin v1 only auto-wires `kotlin.jvm`).

### 6.7 In-tree `Android/` vs. standalone repo

The spike placed the Android Gradle project under `Android/` in the iOS repo (mirroring swift-sheet-music's
layout). This is a convenience for cross-compile path resolution (`packageRoot.resolve("Packages/...")`)
but creates a monorepo-style coupling. A standalone `folino-android` repo would require publishing Swift
products as a prebuilt artifact first. Decision deferred.

### 6.8 swift-java version

The spike pins `swiftlang/swift-java` at exact `0.3.0` (gated behind `FOLINO_ANDROID=1`). This is
intentionally stricter than swift-sheet-music, which fetches swift-java unconditionally — the iOS manifest
never references the swift-java dependency.

---

## 7. Cleanup / known issues before leaving spike status

| Issue | Location | Fix |
| --- | --- | --- |
| Hardcoded Zulu-17 JDK path | `Android/gradle.properties` | Move to per-developer `~/.gradle/gradle.properties` or use Gradle toolchain API |
| NDK host path hardcoded `darwin-x86_64` | `Scripts/android-build-libs.sh` (inherited from SSM) | Detect `uname -m`; use `darwin-aarch64` on Apple Silicon NDK if present |
| Main-thread JNI + asset decode | `MainActivity.onCreate` | Move to ViewModel + `viewModelScope.launch` |
| No error handling in `VersionHistoryBridge` | `Android/FolinoSettingsAndroid/src/main/kotlin/.../VersionHistory.kt` | Wrap in `runCatching`; return empty list on decode failure |
| Stale "Phase 3" comments | `Android/FolinoSettingsAndroid/build.gradle.kts` | Clean up inline TODO comments |
| `logLevel: "debug"` in swift-java config | `Packages/Features/Settings/Sources/FolinoSettingsJNI/swift-java.config` | Set to `"info"` or remove before production |
| `items(list.size)` idiom | `SettingsScreen.kt` | Replace with idiomatic `items(list)` (LazyColumn extension) |
| DataStore key contract not shared | `SettingsPrefs.kt` | Document or enforce parity with iOS typed constants |
| Version-history loader test has no description assertions | `SettingsLogicTests` | `VersionHistoryEntry.localeUserInfoKey` is internal to Domain — either expose for tests or add integration coverage |
| `defaultLocalization: "en"` residual in Domain | `Packages/Domain/Package.swift` | `bf40189` removed the `resources:` declaration but `defaultLocalization` remains; inert (no target uses it) but worth deleting |
| Icon padding inconsistency | `SettingsScreen.kt` | Version History section header icon uses 8 dp padding; `ToggleRow` icons use 12 dp — minor visual inconsistency |
| No `@Preview` for "About" section | `SettingsScreen.kt` | `onOpenLicenses` callback is optional; the "About" section renders only when non-nil, so a no-callback preview omits it; add a dedicated preview with a stub callback |
| `Icons.Filled.ScreenLockPortrait` for "Keep screen awake" | `SettingsScreen.kt` | Icon implies lock-engaged; `BrightnessMedium` / `LightMode` would communicate "screen on" more directly; judgment call kept, review before production |

---

## 8. Reproduce from a clean checkout

Prerequisites: Xcode 26+, open-source Swift toolchain `org.swift.632202605101a` installed, Android Studio,
NDK 28.2.13676358, Azul Zulu 17 JDK, `gpr.user` / `gpr.key` in `~/.gradle/gradle.properties`.

```sh
# 1. Clone and enter the worktree branch
git clone <repo> folino && cd folino
git checkout worktree-android-settings-spike   # or use the worktree directly

# 2. One-time NDK sysroot re-link
~/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle/swift-android/scripts/setup-android-sdk.sh

# 3. Publish swiftkit-core to mavenLocal
# Locate the swift-java checkout via the swift-sheet-music dependency:
SWIFT_JAVA_PATH=$(find .build/checkouts -name 'swift-java' -maxdepth 2 -type d | head -1)
"$SWIFT_JAVA_PATH/gradlew" -p "$SWIFT_JAVA_PATH" :SwiftKitCore:publishToMavenLocal

# 4. Cross-compile FolinoSettingsJNI and stage .so + Java bindings
bash Scripts/android-build-libs.sh

# 5. Build and run on a connected device (or emulator)
cd Android
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.keynumber.folino/.MainActivity
```

Step 4 takes ~9 minutes on first run (subsequent builds are incremental). Both arm64-v8a and x86_64 ABIs
are built by default; restrict with `FOLINO_ANDROID_ABIS=arm64-v8a bash Scripts/android-build-libs.sh`
for faster local iteration.

The AboutLibraries license list is generated at `assembleDebug` time by the Gradle plugin — no extra step
is needed. The Licenses screen is reachable from the Settings "About" section immediately after install.

---

## Appendix: commit log

| SHA | Description |
| --- | --- |
| `f1a6aea` | Add findings scaffold with P0 toolchain notes |
| `d1e4ff5` | Split SettingsLogic (version-history protocol + VM) out of Settings |
| `76881aa` | Add missing SettingsLogic import to App version-history tests |
| `083cee0` | Add Android Gradle scaffold (settings module + Compose app shell) |
| `45e3fe4` | Compose Settings screen with DataStore-backed toggles |
| `5d33064` | Add VersionHistoryWire @WireFormat types with roundtrip test |
| `cbbd96d` | Add JSON version-history loader + wire payload helper for Android |
| `25215e2` | Add Android-only FolinoSettingsJNI target (gated by FOLINO_ANDROID) |
| `6d0e8fc` | Add android-build-libs.sh to cross-compile + stage FolinoSettingsJNI |
| `46ca664` | Wire wirelet Kotlin codegen + JNI façade into FolinoSettingsAndroid |
| `2decafd` | Render Swift-decoded version history in Compose via wirelet |
| `0f75ba4` | Use Double for ReaderPreferences.staffSize; drop Domain's CoreGraphics dependency |
| `bf40189` | Move DomainError's LocalizedError conformance from Domain to App |
| `2828fec` | Add Material icons to Compose Settings rows (matching iOS SF Symbols) |
| `f53ad4d` | Add AboutLibraries-powered Licenses screen reachable from Settings |
| `1ed8204` | Narrow Material3 @OptIn from MainActivity class to LicensesRoute composable |

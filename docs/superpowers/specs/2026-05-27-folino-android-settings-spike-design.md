# Folino Android Settings Spike

Date: 2026-05-27

## Goal

Validate Folino's Android-sharing approach end-to-end on the **Settings
feature**, producing a running Jetpack Compose Settings screen on an
emulator (Pixel 6 Pro API 36, the device `swift-sheet-music`'s Android
example is verified on) and a findings document enumerating what is
sharable, what must be reimplemented in Compose, and what needs separate
handling.

The mechanism mirrors `swift-sheet-music`'s current Android delivery
stack: Foundation-only Swift cross-compiled via the Swift 6.3 Android SDK,
exposed to Kotlin through **swift-java (jextract)** JNI bindings, with
data payloads serialized via **swift-wirelet** `@WireFormat` codecs, and a
Kotlin/Compose UI on top.

This is a spike. The terminal deliverable is a working screen plus the
findings document — not a shipped Android product.

## Relationship to the 2026-05-21 architecture spec

`docs/superpowers/specs/2026-05-21-android-share-architecture-design.md`
established Folino's first Android-sharing plan (a Library pilot, never
executed). This spike **supersedes two of its decisions** and **adopts one
of its patterns**:

- **Supersedes — JNI mechanism.** The 2026-05-21 spec chose hand-written
  `@_cdecl` C wrappers and explicitly rejected `swift-java` as "too young."
  Since then `swift-sheet-music` shipped a working Android port on
  `swift-java` + `swift-wirelet` (both as of 2026-05-27). This spike uses
  **swift-java (jextract)** for JNI entry points and **wirelet** for data
  payloads, validating the newer stack on Folino.
- **Supersedes — data bridging.** Raw handle/pointer + C-string passing is
  replaced by wirelet `@WireFormat` codecs for the data payload.
- **Adopts — the `*Logic` / `*` (UI) split.** Per that spec's future
  direction ("apply the same split to Settings next"), this spike splits
  the Settings feature package into a Foundation-only `SettingsLogic`
  product and a thinned iOS-UI `Settings` product. The Android side drives
  `SettingsLogic`.

The 2026-05-21 spec planned the Library pilot *before* Settings. Because
that pilot was never executed, **this Settings spike becomes Folino's first
real validation of the Swift Android toolchain** — toolchain, `@Observable`,
and `@MainActor`-on-Android risks land here first. The version-history
slice (below) is chosen partly because it is a stateless one-shot load,
sidestepping the unproven `@Observable`-on-Android reactive path.

## Non-goals

- Porting Domain protocol implementations (SQLite, CloudKit, file I/O,
  Firebase) to Android.
- Touching Reader / Editor / ImportExport / Library feature packages.
- Adding `.android` to `swift-sheet-music`'s `platforms` declaration. The
  Settings slice does not depend on swift-sheet-music's Apple-only targets.
- A standalone `folino-android` repository. The Android scaffold lives
  inside the iOS repo's worktree for the duration of the spike.
- An Android-side Picture-in-Picture / metronome / soundfont engine. The
  Settings toggles that gate those features are mirrored as preferences
  only; the features themselves are out of scope.

## Settings screen content (sharability breakdown)

`SettingsSheet.swift` (`Packages/Features/Settings/Sources/Settings/Screens/`)
is a SwiftUI `Form`. Per-element analysis:

| Element | Implementation | Android disposition |
| --- | --- | --- |
| Reader toggles ×4 (metronome / PiP / collapse rests / keep-awake) | `@AppStorage` Bool | Compose + DataStore. No Swift. |
| Layout-mode picker | `ReaderLayoutMode` enum (raw String) + `@AppStorage` | Compose segmented control + DataStore. Enum is sharable but trivial. |
| Soundfont preset row | `MuseScoreGeneralProvider` (download state machine) | **OUT** — platform-heavy. |
| Privacy: crash reporting | `CrashReporter` → Firebase | **OUT** — platform-specific. |
| About: version history | `VersionHistoryLoader` (Yams parse) + `VersionHistoryViewModel` (diff) over `VersionHistoryEntry` (Domain) | **Shared slice** — runs Swift logic on Android via JNI + wirelet, renders in Compose. |
| About: licenses | `LicenseList` | **OUT** — iOS build-tool plugin. |
| About: feedback mail | `MFMailComposeViewController` | **OUT** — iOS-only. |

`swift-sheet-music` is not a dependency of Settings. Its role here is
(a) a reference template for the `Android/` Gradle layout, swift-java JNI
bridge, and wirelet plugin wiring, and (b) confirmation that the Android
toolchain + GitHub Packages auth path works.

## Architecture

### iOS-side package split (behavior-preserving)

`Packages/Features/Settings/` gains a second SPM product, mirroring the
2026-05-21 spec's LibraryLogic pattern:

```
Packages/Features/Settings/
  Package.swift                     MODIFIED: exposes SettingsLogic + Settings
  Sources/
    SettingsLogic/                  NEW — Foundation + Observation only
      VersionHistoryLoader.swift    MOVED from Settings
      VersionHistoryViewModel.swift MOVED from Settings
      (depends on: Domain; builds for iOS + Android)
    Settings/                       THINNED — iOS SwiftUI
      Screens/SettingsSheet.swift   unchanged (now imports SettingsLogic)
      Screens/SoundfontPresetRow.swift
      VersionHistory/VersionHistoryScreen.swift   imports SettingsLogic
      Views/FeedbackMailView.swift
  Tests/
    SettingsLogicTests/             NEW — Swift Testing, Foundation only
      (version-history loader + VM tests migrated here)
    SettingsTests/                  iOS UI / sheet tests remain
```

`VersionHistoryEntry` already lives in `Domain` (Foundation-only,
`Decodable`); it does not move. iOS Settings behavior must be identical at
the end of the split — no copy or feature change.

**Yams caveat.** `VersionHistoryLoader` depends on Yams (a C-libyaml
wrapper). A `SettingsLogic` target that must cross-compile cannot assume
Yams builds for Android. The split keeps the `VersionHistoryLoader`
*protocol* in `SettingsLogic` and the Yams-backed `DefaultVersionHistoryLoader`
behind a seam so the Android JNI bridge can supply its own decode path if
Yams does not cross-compile. Whether Yams cross-compiles is an explicit
findings item (see Risks).

### Android-side layout (in the worktree, repo root)

Mirrors `swift-sheet-music`'s `Android/` + `Examples/Android/` structure:

```
Android/                                  NEW Gradle project
  settings.gradle.kts, build.gradle.kts, gradle.properties, gradlew
  FolinoSettingsAndroid/                  .aar module (JNI bridge + wirelet codecs)
    build.gradle.kts                      android-library + wirelet plugin + swiftkit-core dep
    src/main/
      kotlin/com/keynumber/folino/settings/
        SettingsJNI.kt                    native fn declarations
        VersionHistoryHandle.kt           decodes wire payload via generated codec
      java-generated/                     swift-java jextract output (gitignored)
      jniLibs/<abi>/libFolinoSettingsJNI.so + Swift runtime (gitignored, staged by script)
  app/                                    Compose demo app
    src/main/kotlin/com/keynumber/folino/
      MainActivity.kt
      ui/settings/
        SettingsScreen.kt                 Compose Form-equivalent
        SettingsPrefs.kt                  DataStore-backed toggle/picker state
        VersionHistoryList.kt             renders shared entries
Scripts/
  android-build-libs.sh                   per-ABI cross-compile → stage .so (ported from sheet-music)

Packages/Features/Settings/Sources/
  FolinoSettingsJNI/                      NEW — Android-only Swift JNI target
    JNISymbols.swift                      public bridge fns (swift-java entry points)
    swift-java.config                     jextract config
    Metadata/VersionHistoryWire.swift     @WireFormat schema
```

`FolinoSettingsJNI` is gated behind an env flag (e.g. `FOLINO_ANDROID=1`)
in `Package.swift`, exactly as `swift-sheet-music` gates `SheetMusicAndroidJNI`
behind `SWIFT_SHEET_MUSIC_ANDROID=1`, so the iOS build never sees it.

### Data flow (version-history slice)

```
SettingsLogic (Swift):  VersionHistoryLoader → [VersionHistoryEntry]
        │  driven by
FolinoSettingsJNI (Swift, Android-only):
        │  @WireFormat VersionHistoryWire { version: String; descriptions: [String] }
        │  public func nativeLoadVersionHistory(yamlBytes: Data) -> Data   // encoded [VersionHistoryWire]
        │  swift-java jextract → Java bindings (src/main/java-generated/)
        │  Scripts/android-build-libs.sh: cross-compile aarch64 + x86_64 → libFolinoSettingsJNI.so
        │       + Swift runtime .so → Android/FolinoSettingsAndroid/src/main/jniLibs/<abi>/
        ▼
FolinoSettingsAndroid (Kotlin):
        │  wirelet Gradle plugin reads the @WireFormat schema → VersionHistoryWireCodec.kt
        │  SettingsJNI.nativeLoadVersionHistory(bytes) → ByteArray, decode via codec
        ▼
app (Compose):  VersionHistoryList renders the decoded entries
```

The `VersionHistory.yml` asset is read by Kotlin from Android assets and
the bytes passed into Swift, sidestepping SwiftPM-resource-bundle-on-Android
questions. The Swift side parses (Yams if it cross-compiles; otherwise a
seam-supplied decode) and re-encodes the result as a wirelet payload.

## Phasing

Ordered so a working screen is reached before the deepest integration. If
P4 stalls, P3 still delivers a running screen and P1–P4 yield rich findings.

- **P0 — Toolchain bootstrap.** Pin `TOOLCHAINS=org.swift.632202605101a`;
  confirm `swift-6.3.2-RELEASE_android` SDK; run the NDK sysroot setup
  script; locally publish `swiftkit-core` (swift-java); confirm `gpr.user`/
  `gpr.key` resolve wirelet + sheet-music artifacts from GitHub Packages.
- **P1 — SettingsLogic extraction (iOS).** Behavior-preserving refactor:
  move version-history loader + VM into `SettingsLogic`; migrate their
  tests to `SettingsLogicTests`; keep iOS Settings green
  (`xcodebuild test` on iOS Simulator, per `project_package_test_command`).
- **P2 — Android scaffold.** `Android/` Gradle project + `FolinoSettingsAndroid`
  module + `app` + `Scripts/android-build-libs.sh`, ported from sheet-music.
- **P3 — Compose Settings UI (working screen).** Toggles + layout picker
  bound to DataStore; version-history shown from static placeholder data.
  **Milestone: screen runs on the emulator.**
- **P4 — wirelet version-history bridge.** `FolinoSettingsJNI` target +
  `@WireFormat` schema + swift-java config; cross-compile; wirelet codegen;
  Compose renders Swift-driven version-history entries. Surfaces JNI,
  codegen, packaging, and the Yams cross-compile question hands-on.
- **P5 — Findings document.**

## Explicitly out (recorded as "needs separate handling")

Documented in findings, not implemented: soundfont provider / download
state machine; crash reporting (Firebase); license list (`LicenseList`
build-tool plugin); feedback mail (`MFMailComposeViewController`);
SF Symbols → Compose icon substitution; `@AppStorage` ↔ DataStore
persistence divergence.

## Findings document structure

Written at `docs/superpowers/specs/2026-05-27-folino-android-settings-findings.md`:

1. **Environment setup friction** — toolchain pinning, NDK sysroot,
   swift-java local publish, GitHub Packages auth, Java version (host has
   18; Gradle/AGP want 17 — note the JDK actually used).
2. **Shared cleanly** — which Swift compiled and ran on Android unchanged
   (`VersionHistoryEntry`, the loader/VM if Yams cooperates).
3. **Reimplemented in Compose** — UI that had no shared path (`Form`,
   toggles, picker, navigation, alerts).
4. **Needs separate handling** — Yams/libyaml cross-compile result;
   Firebase; MailCompose; LicenseList; SF Symbols; `@AppStorage` ↔ DataStore.
5. **Unresolved architecture decisions for productization** — where shared
   Settings code ultimately belongs; whether `SettingsLogic` should host
   reactive `@Observable` stores once `@Observable`-on-Android is proven;
   how to share localization; the standalone-repo vs in-tree question.

## Risks & fallbacks

| Risk | Detection | Response |
| --- | --- | --- |
| Yams (libyaml C dep) does not cross-compile to Android | `swift build` for the Android triple fails on the Yams module | Keep `DefaultVersionHistoryLoader` iOS-side; in `FolinoSettingsJNI` decode via a pure-Swift path (e.g. ship the data as JSON the wire fn parses with `JSONDecoder`). Record as a findings item; no spec revision. |
| swift-java `swiftkit-core` local-publish / jextract setup is a blocker | `Scripts/android-build-libs.sh` or Gradle codegen fails | Fall back to `@_cdecl` for the entry points (wirelet payload unchanged), per the 2026-05-21 mechanism. Record the comparison in findings. |
| Swift Android toolchain cannot produce a usable `.so` | Cross-compile/link failure | Stop at P3 (working Compose screen, no Swift). Findings document the toolchain blocker. |
| iOS Settings regression during the split | `SettingsTests` / manual smoke | Keep P1 a behavior-preserving refactor in its own commit; no feature/copy change. |
| `@MainActor`/`@Observable` misbehave on Android | Crash/no-op during P4 | The version-history slice is stateless one-shot; if reactive paths are needed they are deferred to a future spec (matches 2026-05-21 fallback). |

## Success criteria

- iOS Settings behaves identically to today after the `SettingsLogic` split
  (tests green).
- The Compose Settings screen runs on the Pixel 6 Pro API 36 emulator with
  working toggles + layout picker (DataStore-backed).
- Version-history entries produced by Swift `SettingsLogic` are rendered in
  Compose via the swift-java + wirelet path (or the documented fallback if a
  layer is blocked).
- The findings document enumerates sharable / reimplemented / separate-handling
  items with concrete evidence from the spike.

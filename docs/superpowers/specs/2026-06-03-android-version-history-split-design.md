# Split iOS / Android Version History

**Date:** 2026-06-03
**Status:** Approved — ready for implementation plan
**Branch:** `version-history-split`

## Problem

iOS and Android currently show the same version-history ("What's New") content. The
data physically lives in two files already — iOS reads `App/Resources/VersionHistory.yml`
(YAML, via Yams) and Android reads `Android/app/src/main/assets/VersionHistory.json`
(JSON, hand-copied once in commit `cbbd96d`) — but the Android JSON is a stale copy of
iOS history (it stops at 1.5.1 while iOS is at 1.6.0).

The two platforms ship **different features on different timelines**. Their release notes
must diverge: each platform's "What's New" should list what actually shipped on that
platform, in that platform's own version numbering. So Android's version history needs to
become its own independent source of truth, not a copy of iOS.

## Goal

- Android version history is authored and maintained independently of iOS.
- Both platforms author in the **same format (YAML)** and parse through the **same shared
  Swift loader**, so the schema and locale-selection logic stay single-sourced (parity
  rule: share logic, never reimplement an iOS code path on Android).
- Leave room for a future `android-release` tool that mirrors the iOS `ios-release` flow.

Non-goals:

- No new Android UX. Android shows the full list inside Settings; it has no cold-launch
  "What's New" sheet or per-version baseline logic (unlike iOS `VersionHistoryPresenter`).
  This change is data-source separation only.
- iOS content and behavior are untouched.

## Why C-Swift (not build-time JSON generation)

The original JSON path was chosen to keep libyaml (Yams' C dependency, `CYaml`) out of the
Android Swift build. A cross-compile spike on this branch **disproved that constraint**:
adding Yams to `SettingsLogic` and cross-building `FolinoSettingsJNI` for
`x86_64-unknown-linux-android28` succeeded — `CYaml`'s C sources (`api/emitter/parser/
reader/scanner/writer.c`) compiled and `libFolinoSettingsJNI.so` (6.7 MB) linked, exit 0.

With libyaml proven to cross-compile, the cleanest design is to parse YAML on the Swift
side for **both** platforms and keep the existing wire bridge:

- One shared `VersionHistoryLoader` (Yams-backed). Schema + locale selection live only in
  Swift (`Domain.VersionHistoryEntry`).
- The wire format already carries **post-localization** `[String]` (locale selection runs
  in `VersionHistoryEntry.init(from:)` before crossing JNI), so Kotlin needs no schema and
  no parsing logic. Parsing on the Swift side keeps it that way.
- No build-time generation step, no generated artifact, no `yq` dependency.

A Kotlin-side YAML parser was rejected: it would re-implement the multi-locale schema,
locale selection, and version parsing in Kotlin (the wire only carries resolved strings),
duplicating logic the parity rule requires us to share.

## Data flow (after change)

```
iOS:      App/Resources/VersionHistory.yml
            → DefaultVersionHistoryLoader (reads bundle Data)
            → YAMLVersionHistoryLoader(data:) [Yams] → [VersionHistoryEntry] → UI

Android:  assets/VersionHistory.yml (Kotlin reads bytes)
            → VersionHistoryBridge.load → JNI → Swift nativeLoadVersionHistory(ymlBytes)
            → versionHistoryWirePayload(ymlData:) → YAMLVersionHistoryLoader [Yams]
            → locale selection (Swift) → VersionHistoryWireList ([String]) → JNI
            → Kotlin wire decode → VersionHistoryItem → Compose
```

Only the **input format** to the Swift bridge changes (JSON bytes → YAML bytes). The wire
envelope, the Kotlin decode, and the Compose UI are unchanged.

## Changes

### 1. Files — separate source of truth

- iOS: `App/Resources/VersionHistory.yml` — unchanged.
- Android: replace `Android/app/src/main/assets/VersionHistory.json` with
  `Android/app/src/main/assets/VersionHistory.yml`, seeded by converting the current JSON
  content (1.5.1 and earlier) to the iOS YAML schema. From here it diverges: future Android
  entries use Android's own version numbers and feature list.
- `git rm` the old `VersionHistory.json`.

### 2. Loader unification (Swift)

- Promote the spike's data-based `YAMLVersionHistoryLoader` into `SettingsLogic` (reachable
  by both the iOS app and the Android JNI target). It parses YAML `Data` into
  `[VersionHistoryEntry]`, skipping malformed entries (same resilience as today's loaders).
- Refactor `DefaultVersionHistoryLoader` (in `Settings`) to read the bundle resource as
  `Data` and delegate to `YAMLVersionHistoryLoader(data:)`, so there is exactly one YAML
  parse path.
- Delete `JSONVersionHistoryLoader` and its tests.
- Move the `Yams` dependency from the `Settings` target to `SettingsLogic` in
  `Packages/Features/Settings/Package.swift` (done in the spike). `Settings` keeps Yams
  transitively.

### 3. Android bridge

- `FolinoSettingsJNI.nativeLoadVersionHistory`: input is now YAML bytes; internally call a
  `versionHistoryWirePayload(ymlData:)` helper backed by `YAMLVersionHistoryLoader`. Wire
  output type unchanged.
- Kotlin: `SettingsJNI` / `VersionHistoryBridge` parameter naming reflects YAML;
  `MainActivity` reads `assets.open("VersionHistory.yml")`.
- Rebuild the JNI `.so` for both ABIs via `Scripts/android-build-libs.sh` (now bundles
  `CYaml`). Verify the arm64-v8a build too (spike only covered x86_64).

### 4. Release config

Extend `.release.yml` with an `android:` section so a future `android-release` tool reads
the Android source the same way `ios-release` reads `history_yml`. iOS keys unchanged:

```yaml
app_name: Folino
history_yml: App/Resources/VersionHistory.yml        # iOS
extra_locales: [ko, zh-Hans, zh-Hant]
android:
  history_yml: Android/app/src/main/assets/VersionHistory.yml
```

Confirm `ios-release` tolerates the unknown `android:` key before relying on it.

### 5. Tests

- `SettingsLogic`: `YAMLVersionHistoryLoader` decode tests (replacing the JSON loader
  tests) — well-formed YAML, malformed-entry skipping, empty/garbage input → `[]`.
- Validation test: the Android `VersionHistory.yml` asset decodes to ≥ 1
  `VersionHistoryEntry`. This is the schema gate for the hand-authored Android file.
- iOS `DefaultVersionHistoryLoader` tests remain green after the delegation refactor.

## Risks / open items

- **arm64-v8a build**: the spike only cross-built x86_64. The implementation must confirm
  arm64-v8a (real device ABI) links too. Same toolchain and C sources, so expected to pass.
- **`.so` size**: adds the six libyaml `.o` files to the JNI library — negligible.
- **`ios-release` extra-key tolerance**: verify it ignores `android:` rather than erroring.
- **Native `.so` drift**: per prior incident, the primary worktree's staged `.so` can go
  stale relative to a rebuilt one. After merging, regenerate Library/Settings `.so`s so the
  installed app doesn't hit `UnsatisfiedLinkError`.

## Verification

- `swift test` (or the project's xcodebuild-on-simulator equivalent) green for `SettingsLogic`
  and `Settings`.
- `Scripts/android-build-libs.sh` produces `.so` for arm64-v8a + x86_64 with no errors.
- Android app installs and the Settings → version-history list renders the Android YAML
  content on a device.

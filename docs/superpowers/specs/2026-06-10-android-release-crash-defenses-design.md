# Android Release-Crash Defenses (Deterministic Safety Net)

**Date:** 2026-06-10
**Status:** Design (awaiting review)
**Platform:** Android

## Problem

Two crash classes recently slipped past `compileDebugKotlin` (which passed) and only
surfaced at runtime on a specific action, exactly the kind of failure that could ship
in a release:

1. **Missing / stale JNI `.so` → `UnsatisfiedLinkError`.** Native libs load lazily via
   each generated class's static initializer. `libFolinoLibraryJNI.so` /
   `libFolinoSettingsJNI.so` load at app launch, but **`libFolinoSoundfontJNI.so` and
   `libFolinoReaderJNI.so` only load when a score is opened** (their classes are first
   used by `ReaderPlaybackService`). So a missing Reader/Soundfont `.so` passes a launch
   check and crashes only on score-open.
2. **Room schema-hash mismatch on app update** (a same-version schema change) →
   `IllegalStateException` thrown from a DB query, then **silently swallowed** at the
   JNI boundary so import "does nothing." (Out of scope here — see below — but its
   *silent* nature motivates component D.)

The goal: **deterministic, script/test-based gates** (not dependent on a human noticing)
that catch these before a release. There is currently **no Android CI and no Android
release pipeline** (`.release.yml`'s Android section is reserved for a future tool), so
the gates are standalone scripts + gradle tasks + a new instrumented-test suite that the
developer (or Claude) runs before a release build.

## Goals

- A pre-build/pre-release check that fails deterministically if any expected native lib
  is absent from the built APK — **without a device**.
- An on-device smoke that fails deterministically if a native lib is missing/broken or
  the basic import path throws — covering the exact runtime paths compile-checks miss.
- Fail-fast at launch: a missing/broken `.so` should crash at startup (visible to any
  launch check), not deep in a flow — **provided the startup-latency cost is acceptable**.
- Silent failures become loud (observable via Crashlytics + user-visible error).

## Non-Goals (explicitly deferred or excluded)

- **Room version-bump / schema-export guard / migrations.** Deferred to *after the first
  release* (pre-release installs are reset via reinstall / `pm clear`, so the schema-hash
  crash does not affect real users yet). The current canonical-`v1` +
  `fallbackToDestructiveMigration` convention stays untouched.
- **New CI (GitHub Actions / Android fastlane).** Not built here; the gates are scripts
  the release flow can later call. Wiring into a future `android-release` tool is out of scope.
- iOS is unaffected (all changes are Android-only, except possibly the shared import error
  surfacing in D — see D's constraint).

## Expected native-lib set (source of truth for component A)

Per ABI `{arm64-v8a, x86_64}`, the APK must contain these Folino JNI libs:

| Lib | Owning module | Loads at |
| --- | --- | --- |
| `libFolinoLibraryJNI.so` | FolinoLibraryAndroid | launch (library list) |
| `libFolinoSettingsJNI.so` | FolinoSettingsAndroid | launch (version history) |
| `libFolinoReaderJNI.so` | FolinoReaderAndroid | **score open** |
| `libFolinoSoundfontJNI.so` | FolinoSoundfontAndroid | **score open** |

Plus their shared runtime dependency `libSwiftJava.so` (Reader/Settings stage it) and the
Swift runtime stubs (`libswiftCore.so`, etc.). Component A asserts at minimum the four
`libFolino*JNI.so` per ABI (these are the ones that actually go missing in a fresh
worktree); `libSwiftJava.so` is asserted too. Swift-runtime stubs are not individually
enumerated (they are staged as a group; their absence would already fail the four).

## Components

### A. `Scripts/android-release-check.sh` — native-lib completeness (device-free, deterministic)

A bash script (Claude/dev-invokable; later callable from a release flow) that:
1. Builds the debug APK (or accepts a path to an already-built APK / app bundle).
2. Lists the packaged native libs (`unzip -l <apk> 'lib/*'` — no device, no `aapt`
   dependency) and asserts that for **every** ABI in the app's `abiFilters`
   (`arm64-v8a`, `x86_64`) **every** expected `libFolino*JNI.so` + `libSwiftJava.so` is
   present. Missing → print which lib/ABI and exit non-zero.
3. Prints a clear PASS / FAIL summary.

The expected-lib list lives in the script as an explicit array (single source of truth);
a comment points back to this spec's table. This catches the exact failure
(`libFolinoSoundfontJNI.so` not packaged) *before running anything*.

Alternative considered: a gradle verification task wired before `assembleRelease`. Deferred
— with no release pipeline yet, a standalone script is simpler and Claude-callable; a thin
gradle task can wrap the script later.

### B. Instrumented smoke suite — new `app/src/androidTest/`

Stand up the missing androidTest infrastructure (source set, `androidTestImplementation`
androidx.test deps, `testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"`),
with two deterministic tests run via `./gradlew :app:connectedDebugAndroidTest` on the
Claude-started emulator (`ANDROID_SERIAL=emulator-5554`):

1. **`NativeLibraryLoadTest`** — force class-init of each of the four generated JNI entry
   classes (`LibraryAndroidStoreViewModel`, `MuseScoreGeneralAndroidStoreViewModel`,
   `FolinoReaderJNI`, `FolinoSettingsJNI`) so each `System.loadLibrary` runs. Assert no
   `UnsatisfiedLinkError`/`ExceptionInInitializerError`. This alone catches every
   missing/broken `.so` regardless of which flow would have triggered it.
2. **`ImportSmokeTest`** — bundle a small fixture `.mscz` as an androidTest asset
   (`app/src/androidTest/assets/`, sourced from `FolinoScreenshot/Resources/Now_is_the_time.mscz`),
   copy it to a temp path, construct `LibraryAndroidStoreViewModel.create(context)` (JNI is
   available on-device), call `importScore(tempPath)`, and assert the score is persisted
   (e.g. the store's score count increments / `loadAll` returns it) with no exception.

These exercise the native-load + import paths that the soundfont/Room crashes lived on.
No UI navigation / gesture driving (kept out per the "lightweight, deterministic" decision).

### C. `FolinoApplication : Application` — eager native-load at startup (perf-gated)

There is no `Application` subclass today. Add `FolinoApplication` (registered via
`android:name` in `AndroidManifest.xml`) whose `onCreate` eagerly loads all four JNI libs
(by referencing each generated entry class, or `System.loadLibrary` for each), so a
missing/broken `.so` throws **at launch** instead of on score-open. Wrap each load so a
failure is also logged to Crashlytics (it should never fail in a good build; the log makes
a bad build observable).

**Perf gate (deterministic decision, not a guess):** measure cold-start `TotalTime` via
`adb shell am start -W -n com.keynumber.folino/.MainActivity` (median of N≥5 runs, force-stop
between) **with and without** `FolinoApplication`. The heavy shared Swift runtime already
loads at launch (LibraryJNI), so only the Reader + Soundfont `.so` `dlopen` + `JNI_OnLoad`
are added. **Decision rule:** keep eager-load if the median delta is **≤ 150 ms**. There is
no cheaper partial variant — Library/Settings already load at launch, so eager-loading only
the two currently-lazy libs (Reader + Soundfont) *is* the full added cost. So if the delta
exceeds the threshold, **drop C entirely and rely on A + B** for detection. Either way,
record the measured with/without numbers + the decision in the implementation notes so the
choice is reproducible.

### D. Make import / JNI failures observable (no silent swallow)

The Room exception during import was printed to `System.err` but **swallowed** so the user
saw nothing. Locate the swallow point (the Swift `try?` / generated-adapter catch on the
`importScore` → `LibraryAndroidStore` path) and change a swallowed import failure to:
(1) log a **Crashlytics non-fatal** record, and (2) surface a **user-visible error**
(Snackbar/toast on the Library screen) instead of a silent no-op.

**Constraint:** if the swallow lives in shared (cross-platform) Swift code, the change must
not alter iOS behavior — prefer surfacing via the Android JNI/Compose boundary (where the
import call returns to Kotlin), or gate the Crashlytics call behind the Android platform.
The exact swallow location is identified during implementation (investigation step).

## Testing

- **A:** run the script against a known-good APK (PASS) and against an APK with a lib
  removed (FAIL, names the missing lib) — a self-test in the script's PR description / a
  dry-run. Deterministic, no device.
- **B:** the two instrumented tests ARE the test; verify they go RED when a `.so` is removed
  / a bad fixture is used, GREEN on a good build.
- **C:** the perf measurement is the gate; the eager-load itself is exercised by every
  launch (and by B's environment).
- **D:** a manual check (force the import error, confirm Crashlytics non-fatal + visible
  error) — hard to make fully deterministic; covered by code review + a one-off repro.

## Sequencing

Independent components; suggested order: **A** (fastest win, device-free) → **C**
(eager-load + perf measurement) → **B** (androidTest infra + two tests) → **D**
(observability). Each lands and is verified on the emulator independently.

## Risks / Open Questions

1. **B's androidTest infra is new** — first instrumented test in the repo; needs runner +
   deps + emulator. The generated VM `create()` requires JNI (fine on-device).
2. **Fixture import side effects** — `ImportSmokeTest` writes to the app's real Room DB on
   the emulator; isolate by clearing app data before the test or using a distinct fixture,
   so it doesn't accumulate across runs.
3. **C perf** — if the delta exceeds threshold, C is dropped (A + B still cover detection);
   the decision is data-driven and recorded.
4. **D swallow location** — must be pinpointed; if it's shared Swift, respect the iOS-parity
   constraint.

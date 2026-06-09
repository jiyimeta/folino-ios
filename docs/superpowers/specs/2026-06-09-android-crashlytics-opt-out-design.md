# Android Crashlytics + Settings opt-out — Design

**Date:** 2026-06-09
**Status:** Approved (pending user spec review)

## Goal

Bring Firebase Crashlytics to the Android app at behavior parity with iOS,
including a user-facing opt-out toggle in Settings. Today the Android app has
no Firebase integration at all; iOS already ships Crashlytics with a "Send
crash reports" toggle (opt-in by default).

## iOS reference (the behavior to match)

The Android implementation mirrors the iOS *logic and semantics*, while its
*UI placement and copy* follow Android idioms.

- **Init:** `App/AppBootstrap.start()` reads the persisted preference at launch
  and calls `FirebaseCrashReporter.configure(collectionEnabled:)`, which runs
  `FirebaseApp.configure()` then `setCrashlyticsCollectionEnabled(_:)`.
- **Persistence:** UserDefaults key `privacyCrashReportingEnabled` (Bool).
  **Default is `true`** — absence on first launch is treated as enabled
  (opt-in by default; the toggle is an opt-*out*).
- **Toggle:** Settings → Privacy section. On change it immediately calls
  `crashReporter.setCollectionEnabled(newValue)`.
- **Copy (English):**
  - title: "Send crash reports"
  - footer: "Helps fix bugs by sharing anonymous crash diagnostics. Never
    linked to you."
- **Architecture:** `CrashReporter` protocol (UtilityCore) ← `FirebaseCrashReporter`
  adapter (Infrastructure) ← wired in `App/`. Firebase SDK import is confined
  to one Infrastructure target.

## Parity decision

Crash reporting is inherently platform-native — it can only be implemented in
Kotlin against the Android Firebase SDK. The only shared *logic* is the
"enabled by default" semantics, which is a single boolean default that the
Android side mirrors directly. No `swift-wirelet` bridge and no shared Swift
target are warranted (per the iOS/Android parity rule: lift only logic that
would otherwise be duplicated; this would not be).

## Scope

**In scope**
- Firebase Crashlytics integration in the Android app (JVM **and** NDK).
- A DataStore-backed opt-out preference, default enabled.
- A "Privacy" section in the Android Settings screen with the crash-reporting
  toggle.
- Applying the preference to Crashlytics at startup and on toggle change.

**Out of scope** (mirrors iOS, which also ships Crashlytics-only)
- Firebase Analytics.
- Forwarding score-parse diagnostics to crash telemetry (the iOS
  `ScoreDiagnosticReporter` equivalent). May be added later.
- Localized (`values-ja` etc.) copy — the Android app is currently
  English-only; new strings are English, consistent with existing Settings copy.

## Decisions (from brainstorming)

1. **Firebase app registration:** Claude registers the Android app
   (`com.keynumber.folino`) in the existing `folino-app` Firebase project via
   the firebase MCP, fetches `google-services.json`, and commits it to
   `Android/app/google-services.json`. (The iOS `App/GoogleService-Info.plist`
   is already tracked in git, so committing the Android config matches the
   project convention.)
2. **Architecture:** Native Kotlin, minimal. A small `CrashReporting` helper
   object centralizes the Firebase calls so `MainActivity` does not hardcode
   the SDK and so tests/builds without Firebase stay simple. No Kotlin
   interface abstraction beyond that (YAGNI — there is only one consumer).
3. **Catch range:** JVM **+ NDK** (`firebase-crashlytics` and
   `firebase-crashlytics-ndk`), so crashes in the bundled native `.so`
   (Swift runtime, Oboe/FluidSynth audio) are captured, not just JVM crashes.

## Design

### 1. Gradle wiring

- **`Android/build.gradle.kts`** (root): declare, `apply false`:
  - `com.google.gms.google-services` (4.4.2)
  - `com.google.firebase.crashlytics` (3.0.2)
- **`Android/app/build.gradle.kts`**:
  - apply both plugins
  - add `platform("com.google.firebase:firebase-bom:<latest stable>")`
    (pin the current latest stable BoM at implementation time, e.g. 33.x) and
    `firebase-crashlytics` + `firebase-crashlytics-ndk`
  - enable native symbol upload per build type:
    `firebaseCrashlytics { nativeSymbolUploadEnabled = true }`
- **`Android/app/google-services.json`**: fetched via MCP, committed.

**Known caveat to verify during implementation:** the app's native `.so` are
prebuilt (copied from the Swift cross-compile / vendored audio libs), so
Crashlytics may only have stripped binaries. Native symbol upload may need the
unstripped `.so` (or accept that some native frames are unsymbolicated). This is
a build-config detail to confirm when the NDK path is wired; it does not change
the opt-out behavior, which is the user-facing deliverable.

### 2. Opt-out preference

In `SettingsPrefs.kt` / `SettingsKeys`:

```kotlin
// Whether Crashlytics crash-data collection is enabled. Opt-out semantics:
// absent (first launch) is treated as true, mirroring iOS
// `privacyCrashReportingEnabled`.
val crashReportingEnabled = booleanPreferencesKey("privacy.crashReporting.enabled")
```

```kotlin
val crashReporting: Flow<Boolean> =
    context.dataStore.data.map { it[SettingsKeys.crashReportingEnabled] ?: true }

suspend fun setCrashReporting(v: Boolean) =
    context.dataStore.edit { it[SettingsKeys.crashReportingEnabled] = v }
```

### 3. CrashReporting helper

A small object (in `:app`, e.g. `com.keynumber.folino.diagnostics.CrashReporting`)
wrapping the Firebase calls:

```kotlin
object CrashReporting {
    fun setCollectionEnabled(enabled: Boolean) {
        FirebaseCrashlytics.getInstance().isCrashlyticsCollectionEnabled = enabled
    }
}
```

Crashlytics auto-initializes via its ContentProvider; the helper only toggles
collection. The collection flag is persisted by Crashlytics itself, but we
re-apply from DataStore on every launch so DataStore remains the source of
truth (matching iOS, which re-applies from UserDefaults at bootstrap).

### 4. Startup application

In `MainActivity.onCreate`, before `setContent` (same synchronous-read pattern
already used for VersionHistory):

```kotlin
val crashEnabled = runBlocking { prefs.crashReporting.first() }
CrashReporting.setCollectionEnabled(crashEnabled)
```

### 5. Settings UI

In `SettingsScreen.kt`, add a **Privacy** section (Android idiom: section header
+ a switch row with supporting text below it). Place it after the Reader
settings, before Version History / About.

- Collect the pref:
  `val crashReporting by prefs.crashReporting.collectAsState(initial = true)`
- A toggle row with title + supporting text (a new `ToggleRow` variant that
  accepts an optional `subtitle`, styled like the existing A4 description line).
- `onChange`: persist via `prefs.setCrashReporting(v)` and immediately call
  `CrashReporting.setCollectionEnabled(v)`.
- New string resources in `res/values/strings.xml`:
  - `settings_privacy_title` = "Privacy"
  - `settings_privacy_crash_title` = "Send crash reports"
  - `settings_privacy_crash_description` =
    "Helps fix bugs by sharing anonymous crash diagnostics. Never linked to you."
- Icon: `Icons.Filled.BugReport`.

## Data flow

```
First launch:        DataStore (absent) → default true → CrashReporting.setCollectionEnabled(true)
User turns off:      Switch → prefs.setCrashReporting(false) → CrashReporting.setCollectionEnabled(false)
Subsequent launch:   DataStore (false) → CrashReporting.setCollectionEnabled(false)
```

## Testing / verification

- Build the Android app (cross-compiled libs already staged in the primary
  checkout; follow the worktree build conventions if working in a worktree).
- `installDebug` + launch on Pixel and confirm the Privacy toggle renders,
  persists across relaunch, and the app starts cleanly with Firebase present.
- A forced test crash (debug-only) to confirm an event reaches the Crashlytics
  dashboard, and that toggling off suppresses collection.
- iOS unaffected (no shared code touched).

## Risks

- **Native symbol upload** for prebuilt `.so` (see caveat above) — may yield
  unsymbolicated native frames; does not block the opt-out feature.
- **`google-services.json` in git** — consistent with the committed iOS plist;
  the file contains client config (API key restricted by app id), not secrets.

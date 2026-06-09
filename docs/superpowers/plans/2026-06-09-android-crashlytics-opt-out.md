# Android Crashlytics + Settings opt-out Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Firebase Crashlytics (JVM + NDK) to the Folino Android app with a "Send crash reports" opt-out toggle in Settings, at behavior parity with iOS (opt-in by default, re-applied at launch).

**Architecture:** Native Kotlin. Crashlytics calls are confined to a small `CrashReporting` helper object in `:app`. A DataStore boolean preference (default `true`) is the source of truth and is re-applied to Crashlytics on every launch and on toggle change. A new "Privacy" section in the Settings Compose screen drives the toggle. No `swift-wirelet` bridge — crash reporting is inherently Android-native and the only shared logic is the opt-in default, which is mirrored directly.

**Tech Stack:** Kotlin, Jetpack Compose (Material3), AndroidX DataStore Preferences, Firebase BoM / `firebase-crashlytics` / `firebase-crashlytics-ndk`, Gradle plugins `com.google.gms.google-services` + `com.google.firebase.crashlytics`, firebase MCP for app registration.

**Verification note:** This is Firebase + Compose glue with no DataStore/Compose test harness in the Android module (only `junit:junit` is on the classpath; no Robolectric). Following established practice for this Android port, the verification gate is a clean Gradle build plus a Pixel `installDebug` + launch, not unit tests. Steps below reflect that.

**Reference spec:** `docs/superpowers/specs/2026-06-09-android-crashlytics-opt-out-design.md`

---

## File Structure

- **Create** `Android/app/google-services.json` — Firebase Android client config (committed, like the iOS plist).
- **Create** `Android/app/src/main/kotlin/com/keynumber/folino/diagnostics/CrashReporting.kt` — helper wrapping Crashlytics collection toggle.
- **Modify** `Android/build.gradle.kts` — declare the two Gradle plugins `apply false`.
- **Modify** `Android/app/build.gradle.kts` — apply plugins, add Firebase BoM + crashlytics + crashlytics-ndk, enable native symbol upload.
- **Modify** `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt` — add the `crashReportingEnabled` key, flow, and setter.
- **Modify** `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsScreen.kt` — add a Privacy section + a `ToggleRow` subtitle variant.
- **Modify** `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` — apply the pref to Crashlytics at startup; wire the toggle's side effect.
- **Modify** `Android/app/src/main/res/values/strings.xml` — Privacy section + crash-reporting copy.

---

## Task 1: Register the Android app in Firebase and fetch `google-services.json`

This task uses the firebase MCP (the user approved Claude doing the registration). No code/TDD.

**Files:**
- Create: `Android/app/google-services.json`

- [ ] **Step 1: Confirm the active Firebase project**

Call `mcp__firebase__firebase_list_projects` and confirm `folino-app` is present (the iOS app already lives there: `projects/folino-app/iosApps/...`, namespace `com.KeyNumber.Folino`).

- [ ] **Step 2: Create the Android app**

Call `mcp__firebase__firebase_create_app` with platform `android`, project `folino-app`, package name `com.keynumber.folino`, display name `folino`. (Load the tool schema first via ToolSearch `select:mcp__firebase__firebase_create_app`.)

- [ ] **Step 3: Fetch the SDK config (`google-services.json`)**

Call `mcp__firebase__firebase_get_sdk_config` for the new Android app (platform `android`). (Load via ToolSearch `select:mcp__firebase__firebase_get_sdk_config`.) Write the returned JSON verbatim to `Android/app/google-services.json`.

- [ ] **Step 4: Sanity-check the file**

Run: `grep -o '"package_name": "[^"]*"' Android/app/google-services.json`
Expected: contains `com.keynumber.folino`. Also confirm `"project_id": "folino-app"` is present.

- [ ] **Step 5: Commit**

```bash
git add Android/app/google-services.json
git commit -m "chore(android): add Firebase google-services.json"
```

---

## Task 2: Gradle wiring for Firebase Crashlytics (JVM + NDK)

**Files:**
- Modify: `Android/build.gradle.kts`
- Modify: `Android/app/build.gradle.kts`

- [ ] **Step 1: Declare the Gradle plugins at the root, `apply false`**

In `Android/build.gradle.kts`, add the two plugins to the existing `plugins { ... }` block. Pin the latest stable at implementation time; these are known-good defaults:

```kotlin
plugins {
    id("com.android.library") version "8.5.0" apply false
    id("com.android.application") version "8.5.0" apply false
    id("org.jetbrains.kotlin.android") version "2.0.20" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.20" apply false
    id("com.mikepenz.aboutlibraries.plugin") version "11.2.3" apply false
    id("com.google.gms.google-services") version "4.4.2" apply false
    id("com.google.firebase.crashlytics") version "3.0.2" apply false
}
```

- [ ] **Step 2: Apply the plugins in `:app`**

In `Android/app/build.gradle.kts`, add both to the `plugins { ... }` block (order: google-services then crashlytics, after the existing plugins):

```kotlin
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.mikepenz.aboutlibraries.plugin")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}
```

- [ ] **Step 3: Enable native symbol upload per build type**

In `Android/app/build.gradle.kts`, inside `android { ... }`, extend the existing `buildTypes { release { ... } }` and add a `debug` entry so Crashlytics is exercised in debug too. Add a `firebaseCrashlytics` block to each:

```kotlin
buildTypes {
    debug {
        configure<com.google.firebase.crashlytics.buildtools.gradle.CrashlyticsExtension> {
            // Upload native symbols for the bundled .so (Swift runtime, Oboe/FluidSynth)
            // so native crashes are symbolicated. Some prebuilt libs may only be stripped;
            // see the spec caveat — unsymbolicated frames are acceptable, this does not fail the build.
            nativeSymbolUploadEnabled = true
        }
    }
    release {
        isMinifyEnabled = false
        proguardFiles(
            getDefaultProguardFile("proguard-android-optimize.txt"),
            "proguard-rules.pro"
        )
        configure<com.google.firebase.crashlytics.buildtools.gradle.CrashlyticsExtension> {
            nativeSymbolUploadEnabled = true
        }
    }
}
```

- [ ] **Step 4: Add the Firebase dependencies**

In `Android/app/build.gradle.kts`, in the `dependencies { ... }` block, add the Firebase BoM and Crashlytics artifacts (BoM manages versions). Pin the current latest stable BoM at implementation time; `33.7.0` is a known-good default:

```kotlin
implementation(platform("com.google.firebase:firebase-bom:33.7.0"))
implementation("com.google.firebase:firebase-crashlytics")
implementation("com.google.firebase:firebase-crashlytics-ndk")
```

- [ ] **Step 5: Build to confirm Gradle resolves the plugins/deps**

Run (from `Android/`): `./gradlew :app:assembleDebug`
(See the worktree build conventions if working in a worktree — the cross-compiled Swift `.so` must already be staged; if `assembleDebug` fails on missing native libs rather than Firebase, that is a pre-existing staging step, not this task.)
Expected: BUILD SUCCESSFUL. The google-services plugin reads `Android/app/google-services.json` (added in Task 1) at configure time; a missing file fails with "File google-services.json is missing."

- [ ] **Step 6: Commit**

```bash
git add Android/build.gradle.kts Android/app/build.gradle.kts
git commit -m "build(android): integrate Firebase Crashlytics (JVM + NDK)"
```

---

## Task 3: Add the opt-out preference to DataStore

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt`

- [ ] **Step 1: Add the preference key**

In `SettingsPrefs.kt`, inside `object SettingsKeys`, add (after `a4ReferenceHz`):

```kotlin
/**
 * Whether Crashlytics crash-data collection is enabled. Opt-out semantics:
 * absent (first launch) is treated as `true`, mirroring iOS
 * `privacyCrashReportingEnabled`. The toggle is an opt-*out*.
 */
val crashReportingEnabled = booleanPreferencesKey("privacy.crashReporting.enabled")
```

- [ ] **Step 2: Add the flow and setter**

In `class SettingsPrefs`, add the flow alongside the others (after `a4ReferenceHz`):

```kotlin
val crashReporting: Flow<Boolean> =
    context.dataStore.data.map { it[SettingsKeys.crashReportingEnabled] ?: true }
```

and the setter alongside the others (after `setA4ReferenceHz`):

```kotlin
suspend fun setCrashReporting(v: Boolean) =
    context.dataStore.edit { it[SettingsKeys.crashReportingEnabled] = v }
```

- [ ] **Step 3: Compile-check**

Run (from `Android/`): `./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt
git commit -m "feat(android/settings): add crash-reporting opt-out preference (default on)"
```

---

## Task 4: Add the CrashReporting helper

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/diagnostics/CrashReporting.kt`

- [ ] **Step 1: Write the helper**

```kotlin
package com.keynumber.folino.diagnostics

import com.google.firebase.crashlytics.FirebaseCrashlytics

/**
 * Thin wrapper over Firebase Crashlytics so the rest of the app does not import the SDK directly.
 *
 * Crashlytics auto-initializes via its ContentProvider; this only toggles data collection.
 * DataStore (`SettingsPrefs.crashReporting`) is the source of truth — we re-apply it on every
 * launch, mirroring iOS which re-applies the UserDefaults flag at bootstrap.
 */
object CrashReporting {
    fun setCollectionEnabled(enabled: Boolean) {
        FirebaseCrashlytics.getInstance().isCrashlyticsCollectionEnabled = enabled
    }
}
```

- [ ] **Step 2: Compile-check**

Run (from `Android/`): `./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL (resolves `com.google.firebase.crashlytics.FirebaseCrashlytics` from Task 2's dependency).

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/diagnostics/CrashReporting.kt
git commit -m "feat(android/diagnostics): add CrashReporting helper"
```

---

## Task 5: Apply the preference to Crashlytics at startup

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`

- [ ] **Step 1: Add imports**

In `MainActivity.kt`, add to the import block:

```kotlin
import com.keynumber.folino.diagnostics.CrashReporting
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
```

- [ ] **Step 2: Read the pref and apply it before `setContent`**

In `onCreate`, immediately after `val prefs = SettingsPrefs(applicationContext)` (currently line 77), insert:

```kotlin
// Re-apply the persisted crash-reporting opt-out before any UI. Synchronous read mirrors the
// VersionHistory spike pattern below; DataStore is the source of truth (iOS re-applies the
// UserDefaults flag at bootstrap the same way). Default true = opt-in.
val crashEnabled = runBlocking { prefs.crashReporting.first() }
CrashReporting.setCollectionEnabled(crashEnabled)
```

- [ ] **Step 3: Compile-check**

Run (from `Android/`): `./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(android): apply crash-reporting opt-out at launch"
```

---

## Task 6: Add the Privacy section to Settings UI

**Files:**
- Modify: `Android/app/src/main/res/values/strings.xml`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsScreen.kt`

- [ ] **Step 1: Add string resources**

In `Android/app/src/main/res/values/strings.xml`, add before `</resources>`:

```xml
    <string name="settings_privacy_title">Privacy</string>
    <string name="settings_privacy_crash_title">Send crash reports</string>
    <string name="settings_privacy_crash_description">Helps fix bugs by sharing anonymous crash diagnostics. Never linked to you.</string>
```

- [ ] **Step 2: Add a subtitle-capable ToggleRow variant**

In `SettingsScreen.kt`, replace the existing `ToggleRow` (currently lines 166-180) with a version that supports an optional subtitle, keeping the no-subtitle call sites working via the default:

```kotlin
@Composable
private fun ToggleRow(
    icon: ImageVector,
    title: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
    subtitle: String? = null,
) {
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = title,
            modifier = Modifier.padding(end = 12.dp),
        )
        Column(Modifier.weight(1f)) {
            Text(title)
            if (subtitle != null) {
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Switch(checked = checked, onCheckedChange = onChange)
    }
}
```

- [ ] **Step 3: Add the BugReport icon import**

In `SettingsScreen.kt`, add to the `androidx.compose.material.icons.filled.*` import group:

```kotlin
import androidx.compose.material.icons.filled.BugReport
```

- [ ] **Step 4: Collect the pref in the composable**

In `SettingsScreen` (the `@Composable fun SettingsScreen`), add alongside the other `collectAsState` calls (after the `a4Hz` line, currently line 38):

```kotlin
val crashReporting by prefs.crashReporting.collectAsState(initial = true)
```

- [ ] **Step 5: Render the Privacy section**

In `SettingsScreen.kt`, in the `LazyColumn`, insert the Privacy section after the A4 slider `item { A4SliderRow(...) }` block (currently ends at line 114) and before the Version History `if (versionHistory.isNotEmpty())` block. The toggle persists the pref and immediately applies it to Crashlytics:

```kotlin
item {
    Spacer(Modifier.height(16.dp))
    Text(stringResource(R.string.settings_privacy_title), style = MaterialTheme.typography.titleSmall)
}
item {
    ToggleRow(
        icon = Icons.Filled.BugReport,
        title = stringResource(R.string.settings_privacy_crash_title),
        subtitle = stringResource(R.string.settings_privacy_crash_description),
        checked = crashReporting,
        onChange = { v ->
            scope.launch { prefs.setCrashReporting(v) }
            com.keynumber.folino.diagnostics.CrashReporting.setCollectionEnabled(v)
        },
    )
}
```

- [ ] **Step 6: Build**

Run (from `Android/`): `./gradlew :app:assembleDebug`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 7: Commit**

```bash
git add Android/app/src/main/res/values/strings.xml Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsScreen.kt
git commit -m "feat(android/settings): add Privacy section with crash-reporting toggle"
```

---

## Task 7: Device verification (Pixel)

No code. Confirm the feature end-to-end on a physical Pixel (per the Android port's established install+launch verification).

- [ ] **Step 1: Install the debug build**

Run (from `Android/`): `./gradlew :app:installDebug`
Expected: INSTALLED.

- [ ] **Step 2: Launch and reach Settings**

Run: `adb shell am start -n com.keynumber.folino/.MainActivity`
Then open the drawer → Settings. Confirm a **Privacy** section appears with a **Send crash reports** switch (ON by default) and the description line below it.

- [ ] **Step 2b: (optional) Verify no startup regression**

Confirm the app launches cleanly with Firebase present (no crash on the `runBlocking` pref read or Crashlytics init). Watch logcat: `adb logcat -d | grep -iE "crashlytics|firebase" | head`.

- [ ] **Step 3: Verify persistence**

Toggle **Send crash reports** OFF, kill and relaunch the app, reopen Settings — the switch must still be OFF (DataStore persisted) and `CrashReporting.setCollectionEnabled(false)` is re-applied at launch (Task 5).

- [ ] **Step 4: (optional) Verify an event reaches the dashboard**

With the toggle ON, trigger a debug-only forced crash (e.g. temporarily add a button that throws, or `adb shell` an uncaught exception path), relaunch so Crashlytics uploads, and confirm the event appears via `mcp__firebase__crashlytics_list_events` / the Firebase console. Remove any temporary crash trigger afterward. Then toggle OFF and confirm new crashes are not collected.

- [ ] **Step 5: Report results to the user**

Summarize what was verified on device. iOS is unaffected (no shared code touched).

---

## Self-Review

- **Spec coverage:** Firebase registration (Task 1) ✓; Gradle JVM+NDK wiring + native symbol upload (Task 2) ✓; opt-out pref default-true (Task 3) ✓; CrashReporting helper (Task 4) ✓; startup re-apply (Task 5) ✓; Privacy section + copy + immediate apply (Task 6) ✓; device verification (Task 7) ✓. Out-of-scope items (Analytics, diagnostic forwarding, localization) intentionally excluded per spec.
- **Type consistency:** `prefs.crashReporting` (Flow) / `prefs.setCrashReporting` / `SettingsKeys.crashReportingEnabled` / `CrashReporting.setCollectionEnabled` used identically across Tasks 3–6.
- **Placeholders:** BoM/plugin versions are pinned with "verify latest" guidance, not left as TBD. Native-symbol caveat is explicit and explicitly non-blocking.

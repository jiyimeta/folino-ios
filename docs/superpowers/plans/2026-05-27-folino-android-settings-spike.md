# Folino Android Settings Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a running Jetpack Compose Settings screen for Folino on an Android emulator, driven by shared Swift logic via swift-java JNI + swift-wirelet codecs, and produce a findings document on what is sharable vs. needs separate handling.

**Architecture:** Split `Packages/Features/Settings` into a Foundation-only `SettingsLogic` product (version-history loader protocol + view model) and a thinned iOS `Settings` product. Add an in-worktree `Android/` Gradle project (a `.aar` JNI module + a Compose app) mirroring `swift-sheet-music`'s Android delivery. The version-history slice flows Swift → `@WireFormat` → swift-java JNI → wirelet Kotlin codec → Compose.

**Tech Stack:** Swift 6.3.2 (open-source toolchain `org.swift.632202605101a`), Swift Android SDK `swift-6.3.2-RELEASE_android`, swift-java (jextract, JNI mode), swift-wirelet `0.1.0-alpha.2` (Maven + Gradle plugin), Kotlin, Jetpack Compose, Gradle 8 / AGP, Android NDK, JNI, DataStore, Swift Testing.

**Reference implementation:** `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music` (paths below as `SSM/…`). Its `Android/`, `Examples/Android/`, `Sources/SheetMusicAndroidJNI/`, `Scripts/android-build-libs.sh`, and `CLAUDE.md` are the templates this plan ports from.

**Reference spec:** `docs/superpowers/specs/2026-05-27-folino-android-settings-spike-design.md`

**Worktree:** Already on `worktree-android-settings-spike` (branched from local `main`). All paths below are relative to the worktree root unless absolute.

---

## File Structure

```
Packages/Features/Settings/
  Package.swift                                      MODIFIED (SettingsLogic product/target; Android block)
  Sources/
    SettingsLogic/                                   NEW — Foundation + Observation + Domain
      VersionHistoryLoader.swift                     MOVED from Settings (protocol only)
      VersionHistoryViewModel.swift                  MOVED from Settings
    Settings/                                         THINNED (iOS SwiftUI)
      Screens/SettingsSheet.swift                    MODIFIED (import SettingsLogic)
      VersionHistory/DefaultVersionHistoryLoader.swift  NEW (Yams impl, split out, stays iOS)
      VersionHistory/VersionHistoryScreen.swift      MODIFIED (import SettingsLogic)
    FolinoSettingsJNI/                                NEW — Android-only (gated by FOLINO_ANDROID=1)
      JNISymbols.swift                                public bridge fns (swift-java entry points)
      swift-java.config                               jextract config
      Metadata/VersionHistoryWire.swift               @WireFormat schema
  Tests/
    SettingsLogicTests/                               NEW (Swift Testing)
      VersionHistoryViewModelTests.swift              MOVED from SettingsTests
      VersionHistoryWireTests.swift                   NEW (wirelet roundtrip)
    SettingsTests/                                    KEPT
      VersionHistory/DefaultVersionHistoryLoaderTests.swift  KEPT (Yams impl)

Android/                                              NEW Gradle project (worktree root)
  settings.gradle.kts, build.gradle.kts, gradle.properties, gradle/wrapper/, gradlew
  FolinoSettingsAndroid/
    build.gradle.kts                                  android-library + wirelet plugin + swiftkit-core
    proguard-consumer.pro
    src/main/AndroidManifest.xml
    src/main/kotlin/com/keynumber/folino/settings/SettingsJNI.kt
    src/main/kotlin/com/keynumber/folino/settings/VersionHistory.kt   (handle/decoder)
    src/main/java-generated/                          swift-java output (gitignored)
    src/main/jniLibs/<abi>/                           staged .so (gitignored)
  app/
    build.gradle.kts, proguard-rules.pro
    src/main/AndroidManifest.xml
    src/main/kotlin/com/keynumber/folino/MainActivity.kt
    src/main/kotlin/com/keynumber/folino/ui/settings/SettingsScreen.kt
    src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt
    src/main/kotlin/com/keynumber/folino/ui/settings/VersionHistoryList.kt
    src/main/assets/VersionHistory.json               JSON copy of the version-history data

Scripts/
  android-build-libs.sh                               NEW (ported from SSM)

docs/superpowers/specs/
  2026-05-27-folino-android-settings-findings.md       NEW (P5 deliverable)

.gitignore                                            MODIFIED (java-generated/, jniLibs/, Android build dirs)
```

---

## Phase 0 — Toolchain bootstrap

These are verification/setup tasks, not TDD. Each ends by confirming an observable signal. No commits except Task 0.5.

### Task 0.1: Confirm Swift toolchain + Android SDK

- [ ] **Step 1: Pin the open-source toolchain and verify**

Run:
```bash
export TOOLCHAINS=org.swift.632202605101a
swift --version
```
Expected: banner contains `swift-6.3.2-RELEASE` (NOT `swiftlang-6.3.2`). The Apple Xcode-shipped fork rejects the SDK's prebuilt Foundation swiftmodule.

- [ ] **Step 2: Confirm the Android SDK is installed**

Run: `swift sdk list`
Expected: output includes `swift-6.3.2-RELEASE_android`.

### Task 0.2: Stage the NDK sysroot symlinks (one-time)

- [ ] **Step 1: Locate the NDK and run the SDK setup script**

Run:
```bash
NDK_DIR="$(ls -d "$HOME/Library/Android/sdk/ndk/"*/ | sort -V | tail -1 | sed 's:/$::')"
ANDROID_NDK_HOME="$NDK_DIR" \
  "$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle/swift-android/scripts/setup-android-sdk.sh"
```
Expected: completes without error. (If skipped, cross-compile later fails with `'semaphore.h' file not found` / `could not build C module 'SwiftOverlayShims'`.)

- [ ] **Step 2: Smoke-test cross-compile of an existing Android-ready package**

Verify the toolchain end-to-end against the reference package before touching Folino:
```bash
cd /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music
SWIFT_SHEET_MUSIC_ANDROID=1 swift build --package-path . --product SheetMusicCore \
  --swift-sdk aarch64-unknown-linux-android28 -c release
```
Expected: build succeeds. This isolates "toolchain broken" from "Folino code broken" before P4. Return to the worktree afterward.

### Task 0.3: Locally publish swift-java's swiftkit-core

swift-java's `swiftkit-core` is not on Maven Central; the Android module gets it via `mavenLocal()`.

- [ ] **Step 1: Resolve the worktree's SwiftPM deps so checkouts exist**

This requires Package.swift to already reference swift-java (added in Task 4.3). For P0, instead publish from the reference package's checkout, which is identical:
```bash
cd /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music
swift package resolve
cd .build/checkouts/swift-java && ./gradlew :SwiftKitCore:publishToMavenLocal
```
Expected: `BUILD SUCCESSFUL`; `~/.m2/repository/org/swift/swiftkit/swiftkit-core/1.0-SNAPSHOT/` is populated.

### Task 0.4: Confirm GitHub Packages auth resolves wirelet

- [ ] **Step 1: Verify gpr credentials are present**

Run: `grep -E 'gpr\.(user|key)' "$HOME/.gradle/gradle.properties"`
Expected: both `gpr.user` and `gpr.key` lines present (a classic PAT with `read:packages`). If absent, stop and ask the user to add them — Gradle cannot resolve `io.github.jiyimeta:wirelet-runtime` without them.

### Task 0.5: Record toolchain facts in the findings scaffold

- [ ] **Step 1: Create the findings doc with a filled-in environment section**

Create `docs/superpowers/specs/2026-05-27-folino-android-settings-findings.md` with a `## 1. Environment setup` section recording: exact toolchain id, SDK name, NDK version used, the `setup-android-sdk.sh` outcome, swiftkit-core publish outcome, host JDK version (`java -version`) vs. the JDK Gradle actually used, and any friction. Other sections are headers only for now.

- [ ] **Step 2: Commit**
```bash
git add docs/superpowers/specs/2026-05-27-folino-android-settings-findings.md
git commit -m "Add findings scaffold with P0 toolchain notes"
```

---

## Phase 1 — SettingsLogic extraction (iOS, behavior-preserving)

TDD-applicable refactor. iOS Settings behavior must be identical at the end. `SettingsLogic` is Foundation + Observation + Domain only (NO Yams, NO DeviceKit, NO Utility) so it cross-compiles. The Yams-backed `DefaultVersionHistoryLoader` is split out and stays in the iOS `Settings` target.

### Task 1.1: Add the SettingsLogic product and target

**Files:**
- Modify: `Packages/Features/Settings/Package.swift`

- [ ] **Step 1: Add the product and target**

In `products`, add before the `Settings` library:
```swift
.library(name: "SettingsLogic", targets: ["SettingsLogic"]),
```
In `targets`, add before the `Settings` target:
```swift
.target(
    name: "SettingsLogic",
    dependencies: ["Domain"],
    plugins: swiftLintPlugins,
),
```
Add `"SettingsLogic"` to the `Settings` target's `dependencies` array (first element). Add the test target after `SettingsTests`:
```swift
.testTarget(name: "SettingsLogicTests", dependencies: ["SettingsLogic", "Domain"]),
```

- [ ] **Step 2: Verify the manifest parses**

Run: `swift package --package-path Packages/Features/Settings dump-package > /dev/null`
Expected: no error (it will warn about empty `SettingsLogic` sources dir until Task 1.2 — create the dir: `mkdir -p Packages/Features/Settings/Sources/SettingsLogic Packages/Features/Settings/Tests/SettingsLogicTests`).

### Task 1.2: Move the view model into SettingsLogic

**Files:**
- Create: `Packages/Features/Settings/Sources/SettingsLogic/VersionHistoryViewModel.swift`
- Delete: `Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryViewModel.swift`

- [ ] **Step 1: Move the file unchanged**

Move `VersionHistoryViewModel.swift` to `Sources/SettingsLogic/`. Its content is unchanged (imports `Domain` + `Observation`; both available in SettingsLogic). Make the type's stored properties `public` where the iOS Screen reads them: `recentChanges`, `pastChanges`, `isHistorySplit`, `isPastChangesShown`, and `showMoreButtonDidTap()` must be `public` now that `VersionHistoryScreen` is in a different module:
```swift
import Domain
import Observation

@Observable
@MainActor
public final class VersionHistoryViewModel {
    public let isHistorySplit: Bool
    public let recentChanges: [VersionHistoryEntry]
    public let pastChanges: [VersionHistoryEntry]
    public var isPastChangesShown = false

    public init(entries: [VersionHistoryEntry], baseline: AppVersion, isHistorySplit: Bool) {
        self.isHistorySplit = isHistorySplit
        recentChanges = entries.filter { $0.version > baseline }
        pastChanges = entries.filter { $0.version <= baseline }
    }

    public func showMoreButtonDidTap() {
        isPastChangesShown = true
    }
}
```

### Task 1.3: Move the loader protocol to SettingsLogic, split the Yams impl into Settings

**Files:**
- Create: `Packages/Features/Settings/Sources/SettingsLogic/VersionHistoryLoader.swift` (protocol only)
- Create: `Packages/Features/Settings/Sources/Settings/VersionHistory/DefaultVersionHistoryLoader.swift` (Yams impl)
- Delete: `Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryLoader.swift`

- [ ] **Step 1: SettingsLogic gets the protocol only (no Yams)**

`Sources/SettingsLogic/VersionHistoryLoader.swift`:
```swift
import Domain

public protocol VersionHistoryLoader: Sendable {
    func load() throws -> [VersionHistoryEntry]
}
```

- [ ] **Step 2: Settings keeps the Yams-backed default impl**

`Sources/Settings/VersionHistory/DefaultVersionHistoryLoader.swift` — same body as the old `DefaultVersionHistoryLoader`, now importing `SettingsLogic` for the protocol:
```swift
import Domain
import Foundation
import SettingsLogic
import Yams

public struct DefaultVersionHistoryLoader: VersionHistoryLoader {
    public enum LoadError: Error {
        case resourceNotFound(name: String)
        case unparseableRoot
    }

    private let bundle: Bundle
    private let resourceName: String

    public init(bundle: Bundle = .main, resourceName: String = "VersionHistory") {
        self.bundle = bundle
        self.resourceName = resourceName
    }

    public func load() throws -> [VersionHistoryEntry] {
        guard let url = bundle.url(forResource: resourceName, withExtension: "yml") else {
            throw LoadError.resourceNotFound(name: resourceName)
        }
        let yaml = try String(contentsOf: url, encoding: .utf8)
        guard let root = try Yams.compose(yaml: yaml) else {
            throw LoadError.unparseableRoot
        }
        guard case let .sequence(sequence) = root else {
            throw LoadError.unparseableRoot
        }
        let decoder = YAMLDecoder()
        return sequence.compactMap { try? decoder.decode(VersionHistoryEntry.self, from: $0) }
    }
}
```

- [ ] **Step 3: Update the two iOS files that consume these types**

In `Sources/Settings/Screens/SettingsSheet.swift` add `import SettingsLogic` (after `import Domain`). `DefaultVersionHistoryLoader` is in-module (Settings) so no other change. In `Sources/Settings/VersionHistory/VersionHistoryScreen.swift` add `import SettingsLogic`.

### Task 1.4: Migrate the view-model test; keep the loader test in SettingsTests

**Files:**
- Create: `Packages/Features/Settings/Tests/SettingsLogicTests/VersionHistoryViewModelTests.swift` (moved)
- Delete: `Packages/Features/Settings/Tests/SettingsTests/VersionHistory/VersionHistoryViewModelTests.swift`

- [ ] **Step 1: Move the VM test verbatim**

Move `VersionHistoryViewModelTests.swift` into `SettingsLogicTests/`. Change its import from `@testable import Settings` to `@testable import SettingsLogic` (keep `import Domain`). `DefaultVersionHistoryLoaderTests.swift` stays in `SettingsTests` (it tests the Yams impl, which stayed in Settings).

- [ ] **Step 2: Run the package tests on the iOS Simulator**

Per `memory/project_package_test_command` (`swift test` is broken by the SwiftLint plugin's macOS requirement):
```bash
xcodebuild test -scheme Settings-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation
```
Expected: build succeeds; `SettingsLogicTests` + `SettingsTests` all pass.

- [ ] **Step 3: Build the full app to confirm no regression in the composition root**
```bash
xcodegen generate
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build
```
Expected: build succeeds. (`Local.xcconfig` is symlinked in this worktree.)

- [ ] **Step 4: Commit**
```bash
git add Packages/Features/Settings
git commit -m "Split SettingsLogic (version-history protocol + VM) out of Settings"
```

---

## Phase 2 — Android scaffold (port from swift-sheet-music)

Stand up the Gradle project structure. No Swift cross-compile yet; the app builds against an empty JNI module so we can confirm the Gradle/Compose toolchain independently.

### Task 2.1: Create the Android/ Gradle project skeleton

**Files (copy from `SSM/Android/` then edit):**
- Create: `Android/gradlew`, `Android/gradlew.bat`, `Android/gradle/wrapper/*`
- Create: `Android/settings.gradle.kts`, `Android/build.gradle.kts`, `Android/gradle.properties`

- [ ] **Step 1: Copy the wrapper and root build files**
```bash
mkdir -p Android
cp -R /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Android/gradle Android/
cp /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Android/gradlew Android/
cp /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Android/gradlew.bat Android/
cp /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Android/build.gradle.kts Android/
cp /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Android/gradle.properties Android/
chmod +x Android/gradlew
```

- [ ] **Step 2: Write `Android/settings.gradle.kts`**

Mirror `SSM/Android/settings.gradle.kts` (the `Android/` project, not `Examples/Android/`) but rename the project and module. Include the `WireletGitHubPackages` `pluginManagement` + `dependencyResolutionManagement` repos and `mavenLocal()` exactly as in `SSM/Examples/Android/settings.gradle.kts` (shown in the reference spec), then:
```kotlin
rootProject.name = "FolinoAndroid"
include(":FolinoSettingsAndroid")
include(":app")
```
No `includeBuild` is needed (app and module are in the same Gradle project here, unlike SSM's split). The `app` module depends on `:FolinoSettingsAndroid` directly via `project(":FolinoSettingsAndroid")`.

### Task 2.2: Create the FolinoSettingsAndroid module

**Files:**
- Create: `Android/FolinoSettingsAndroid/build.gradle.kts`
- Create: `Android/FolinoSettingsAndroid/proguard-consumer.pro` (empty file is fine)
- Create: `Android/FolinoSettingsAndroid/src/main/AndroidManifest.xml`

- [ ] **Step 1: Write `build.gradle.kts`**

Port from `SSM/Android/SheetMusicAndroid/build.gradle.kts`. Keep the `plugins`, `android` (compileSdk 35, minSdk 28, abiFilters arm64-v8a + x86_64, JVM 17, jniLibs + java-generated srcDirs), and the `dependencies` block (`swiftkit-core:1.0-SNAPSHOT`, `wirelet-runtime:0.1.0-alpha.2`). Drop `maven-publish` and the entire `afterEvaluate { publishing { … } }` block (the spike does not publish). Change:
```kotlin
android { namespace = "com.keynumber.folino.settings" }
```
The `wirelet { … }` block is added in Task 4.5 (no schema exists until P4). For now omit it and omit the `generateWireletCodecsMain` wiring.

- [ ] **Step 2: Minimal manifest**

`src/main/AndroidManifest.xml`:
```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" />
```

### Task 2.3: Create the Compose app module shell

**Files:**
- Create: `Android/app/build.gradle.kts`, `Android/app/proguard-rules.pro`
- Create: `Android/app/src/main/AndroidManifest.xml`
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`

- [ ] **Step 1: Write `app/build.gradle.kts`**

Port from `SSM/Examples/Android/app/build.gradle.kts`. Keep the Compose plugin + BOM + material3 + activity-compose deps and the `packaging { jniLibs { pickFirsts += setOf("**/libc++_shared.so") } }` block. Change `namespace`/`applicationId` to `com.keynumber.folino`. Drop the media3/media deps (no audio in this spike). Replace the two `io.github.jiyimeta:sheet-music-*` deps with:
```kotlin
implementation(project(":FolinoSettingsAndroid"))
implementation("androidx.datastore:datastore-preferences:1.1.1")
```
Omit the `wirelet { … }` block and the `id("io.github.jiyimeta.wirelet")` plugin line for now (added in Task 4.5 — the app references generated codecs only after P4).

- [ ] **Step 2: Manifest with a single launcher Activity**

`app/src/main/AndroidManifest.xml`:
```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:label="folino" android:theme="@style/Theme.Material3.DayNight.NoActionBar">
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
```

- [ ] **Step 3: MainActivity hosting an empty Composable**
```kotlin
package com.keynumber.folino

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme { Surface { Text("folino settings — scaffold") } }
        }
    }
}
```

- [ ] **Step 4: Update .gitignore**

Append to the worktree-root `.gitignore`:
```
# Android spike
Android/.gradle/
Android/build/
Android/**/build/
Android/.kotlin/
Android/local.properties
Android/**/src/main/jniLibs/
Android/**/src/main/java-generated/
```

- [ ] **Step 5: Build the APK (no Swift yet) to validate Gradle/Compose/AGP**
```bash
Android/gradlew -p Android :app:assembleDebug
```
Expected: `BUILD SUCCESSFUL`. This proves the Gradle/AGP/Compose/wirelet-repo/JDK setup independently of any Swift cross-compile. If AGP rejects JDK 18, point `Android/gradle.properties` at the Android-Studio-bundled JDK 17/21 via `org.gradle.java.home=…` and record it in findings §1.

- [ ] **Step 6: Commit**
```bash
git add Android .gitignore
git commit -m "Add Android Gradle scaffold (settings module + Compose app shell)"
```

---

## Phase 3 — Compose Settings UI (working-screen milestone)

Build the real Settings UI bound to DataStore. Version-history shows static placeholder data here; the Swift-driven path replaces it in P4. **The milestone is: the screen runs on the emulator.**

### Task 3.1: DataStore-backed preferences

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt`

- [ ] **Step 1: Write the prefs holder**

Mirrors the iOS `@AppStorage` keys (`ReaderGlobalSettingsKey.*`, `PrivacySettingsKey.*`). Keys are plain strings here; reconciling them with the iOS key constants is a findings item.
```kotlin
package com.keynumber.folino.ui.settings

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

val Context.dataStore by preferencesDataStore(name = "folino_settings")

object SettingsKeys {
    val metronomeEnabled = booleanPreferencesKey("reader.metronome.enabled")
    val pipEnabled = booleanPreferencesKey("reader.pictureInPicture.enabled")
    val collapseRests = booleanPreferencesKey("reader.collapseMultiMeasureRests")
    val keepAwake = booleanPreferencesKey("reader.keepScreenAwake.enabled")
    val layoutMode = stringPreferencesKey("reader.layoutMode") // "vertical" | "horizontal" | "page"
}

class SettingsPrefs(private val context: Context) {
    val metronome: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.metronomeEnabled] ?: false }
    val pip: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.pipEnabled] ?: false }
    val collapseRests: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.collapseRests] ?: false }
    val keepAwake: Flow<Boolean> = context.dataStore.data.map { it[SettingsKeys.keepAwake] ?: true }
    val layoutMode: Flow<String> = context.dataStore.data.map { it[SettingsKeys.layoutMode] ?: "page" }

    suspend fun setMetronome(v: Boolean) = context.dataStore.edit { it[SettingsKeys.metronomeEnabled] = v }
    suspend fun setPip(v: Boolean) = context.dataStore.edit { it[SettingsKeys.pipEnabled] = v }
    suspend fun setCollapseRests(v: Boolean) = context.dataStore.edit { it[SettingsKeys.collapseRests] = v }
    suspend fun setKeepAwake(v: Boolean) = context.dataStore.edit { it[SettingsKeys.keepAwake] = v }
    suspend fun setLayoutMode(v: String) = context.dataStore.edit { it[SettingsKeys.layoutMode] = v }
}
```

### Task 3.2: Settings Compose screen

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsScreen.kt`

- [ ] **Step 1: Write the screen (toggles + layout picker)**

A `LazyColumn` reproducing the iOS `Form` sections. SF Symbols are replaced with Material icons (a findings item).
```kotlin
package com.keynumber.folino.ui.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

@Composable
fun SettingsScreen(prefs: SettingsPrefs, versionHistory: List<VersionHistoryItem>) {
    val scope = rememberCoroutineScope()
    val metronome by prefs.metronome.collectAsState(initial = false)
    val pip by prefs.pip.collectAsState(initial = false)
    val collapse by prefs.collapseRests.collectAsState(initial = false)
    val keepAwake by prefs.keepAwake.collectAsState(initial = true)
    val layout by prefs.layoutMode.collectAsState(initial = "page")

    LazyColumn(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Text("Reader", style = MaterialTheme.typography.titleSmall) }
        item { ToggleRow("Metronome", metronome) { v -> scope.launch { prefs.setMetronome(v) } } }
        item { ToggleRow("Picture in Picture", pip) { v -> scope.launch { prefs.setPip(v) } } }
        item { ToggleRow("Collapse multi-measure rests", collapse) { v -> scope.launch { prefs.setCollapseRests(v) } } }
        item { ToggleRow("Keep screen awake", keepAwake) { v -> scope.launch { prefs.setKeepAwake(v) } } }
        item {
            Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Text("Layout", Modifier.weight(1f))
                SingleChoiceSegmentedButtonRow {
                    listOf("vertical", "horizontal", "page").forEachIndexed { i, mode ->
                        SegmentedButton(
                            selected = layout == mode,
                            onClick = { scope.launch { prefs.setLayoutMode(mode) } },
                            shape = SegmentedButtonDefaults.itemShape(i, 3),
                        ) { Text(mode.take(1).uppercase()) }
                    }
                }
            }
        }
        item { Spacer(Modifier.height(16.dp)); Text("Version History", style = MaterialTheme.typography.titleSmall) }
        items(versionHistory.size) { idx ->
            val v = versionHistory[idx]
            Column { Text(v.version, style = MaterialTheme.typography.titleMedium)
                v.descriptions.forEach { Text("• $it", style = MaterialTheme.typography.bodyMedium) } }
        }
    }
}

@Composable
private fun ToggleRow(title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

data class VersionHistoryItem(val version: String, val descriptions: List<String>)
```

### Task 3.3: Static version-history placeholder + wire into MainActivity

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/VersionHistoryList.kt`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`

- [ ] **Step 1: Placeholder data source (replaced in P4)**
```kotlin
package com.keynumber.folino.ui.settings

object VersionHistorySource {
    // P3 placeholder. P4 replaces this with Swift-decoded entries.
    fun placeholder(): List<VersionHistoryItem> = listOf(
        VersionHistoryItem("1.5.1", listOf("Placeholder — replaced by Swift in P4")),
    )
}
```

- [ ] **Step 2: MainActivity renders SettingsScreen**
```kotlin
package com.keynumber.folino

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import com.keynumber.folino.ui.settings.SettingsPrefs
import com.keynumber.folino.ui.settings.SettingsScreen
import com.keynumber.folino.ui.settings.VersionHistorySource

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = SettingsPrefs(applicationContext)
        setContent {
            MaterialTheme { Surface { SettingsScreen(prefs, VersionHistorySource.placeholder()) } }
        }
    }
}
```

### Task 3.4: Run on the emulator (MILESTONE)

- [ ] **Step 1: Boot the emulator**
```bash
"$ANDROID_HOME/emulator/emulator" -avd Pixel_6_Pro_API_36 -no-snapshot -no-boot-anim &
adb wait-for-device
```
Expected: device shows `device` in `adb devices`.

- [ ] **Step 2: Install and launch**
```bash
Android/gradlew -p Android :app:installDebug
adb shell am start -n com.keynumber.folino/.MainActivity
```
Expected: app launches.

- [ ] **Step 3: Capture a screenshot**
```bash
adb exec-out screencap -p > /tmp/folino-settings-p3.png
```
`Read` the PNG. Expected: Reader toggles, layout segmented control, and the placeholder version-history row are visible and toggles flip on tap. **This is the working-screen milestone.**

- [ ] **Step 4: Commit**
```bash
git add Android
git commit -m "Compose Settings screen with DataStore-backed toggles (runs on emulator)"
```

---

## Phase 4 — wirelet version-history bridge

Replace the placeholder with version-history entries produced by Swift `SettingsLogic`, crossing JNI via swift-java and decoded in Kotlin via a wirelet codec.

### Task 4.1: @WireFormat wire type + Swift roundtrip test (TDD)

**Files:**
- Create: `Packages/Features/Settings/Sources/FolinoSettingsJNI/Metadata/VersionHistoryWire.swift`
- Create: `Packages/Features/Settings/Tests/SettingsLogicTests/VersionHistoryWireTests.swift`

> Note: the wire type is referenced by tests compiled for the host (macOS/iOS), so it must be available outside the Android-only target during testing. Place the `@WireFormat` type in a small target that the test target can import. Simplest: put it in `SettingsLogic` (add `import Wirelet` and the swift-wirelet dep to SettingsLogic), and have `FolinoSettingsJNI` re-use it. Add the swift-wirelet package dep to `Package.swift` unconditionally (it is pure Swift + a macro; it builds for Apple platforms fine). Adjust the file path to `Sources/SettingsLogic/VersionHistoryWire.swift` accordingly.

- [ ] **Step 1: Write the failing roundtrip test**

`Tests/SettingsLogicTests/VersionHistoryWireTests.swift`:
```swift
import Testing
@testable import SettingsLogic

@Suite struct VersionHistoryWireTests {
    @Test func roundTripsListPayload() throws {
        let entries = [
            VersionHistoryWire(version: "1.5.1", descriptions: ["a", "b"]),
            VersionHistoryWire(version: "1.5.0", descriptions: ["c"]),
        ]
        let bytes = VersionHistoryWireList(entries: entries).encodeToData()
        let decoded = try VersionHistoryWireList(decoding: bytes)
        #expect(decoded.entries == entries)
    }
}
```

- [ ] **Step 2: Run it — expect a compile failure (types undefined)**

Run: `xcodebuild test -scheme Settings-Package -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:SettingsLogicTests/VersionHistoryWireTests`
Expected: FAIL — `cannot find 'VersionHistoryWire'`.

- [ ] **Step 3: Add the wire types**

`Sources/SettingsLogic/VersionHistoryWire.swift`:
```swift
import Wirelet

@WireFormat
public struct VersionHistoryWire: Equatable {
    public var version: String
    public var descriptions: [String]

    public init(version: String, descriptions: [String]) {
        self.version = version
        self.descriptions = descriptions
    }
}

@WireFormat
public struct VersionHistoryWireList: Equatable {
    public var entries: [VersionHistoryWire]

    public init(entries: [VersionHistoryWire]) { self.entries = entries }
}
```
Add to `Package.swift`: the package dep `.package(url: "https://github.com/jiyimeta/swift-wirelet.git", revision: "31be47c84fddf2834b3cccc05ff955dcd1f2668e")` and `.product(name: "Wirelet", package: "swift-wirelet")` to the `SettingsLogic` target deps. (`@WireFormat` supports `String` and `[T]` fields per the wire-format spec.)

- [ ] **Step 4: Run the test — expect PASS**

Same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add Packages/Features/Settings
git commit -m "Add VersionHistoryWire @WireFormat types with roundtrip test"
```

### Task 4.2: SettingsLogic gains an Android-safe loader from JSON

The Yams loader stays iOS-side. For Android, decode the same `VersionHistoryEntry` from JSON (pure Foundation), then map to wire types.

**Files:**
- Create: `Packages/Features/Settings/Sources/SettingsLogic/JSONVersionHistoryLoader.swift`
- Create: `Android/app/src/main/assets/VersionHistory.json`

- [ ] **Step 1: Add a JSON-backed loader (Foundation only)**
```swift
import Domain
import Foundation

public struct JSONVersionHistoryLoader: VersionHistoryLoader {
    private let data: Data
    public init(data: Data) { self.data = data }

    public func load() throws -> [VersionHistoryEntry] {
        try JSONDecoder().decode([VersionHistoryEntry].self, from: data)
    }
}

public func versionHistoryWirePayload(jsonData: Data) -> Data {
    let entries = (try? JSONVersionHistoryLoader(data: jsonData).load()) ?? []
    let wire = entries.map { VersionHistoryWire(version: $0.version.description, descriptions: $0.descriptions) }
    return VersionHistoryWireList(entries: wire).encodeToData()
}
```
> `VersionHistoryEntry.init(from:)` already keys on `version` (String) + `descriptions` (`[{en,ja,zh-Hans,zh-Hant,ko}]`) and selects by locale. The JSON asset must use that shape. Confirm `AppVersion` has a `description` (or add a `String` accessor) for the wire `version` field.

- [ ] **Step 2: Create the JSON asset**

Convert the iOS `VersionHistory.yml` (find it under `App/` or `Packages/Features/Settings/Sources/Settings/Resources/`) to JSON with the same keys, into `Android/app/src/main/assets/VersionHistory.json`. Keep at least two version entries with multi-locale descriptions so the decode is exercised.

- [ ] **Step 3: Commit**
```bash
git add Packages/Features/Settings Android/app/src/main/assets
git commit -m "Add JSON version-history loader + wire payload helper for Android"
```

### Task 4.3: FolinoSettingsJNI Android-only target + swift-java config

**Files:**
- Create: `Packages/Features/Settings/Sources/FolinoSettingsJNI/JNISymbols.swift`
- Create: `Packages/Features/Settings/Sources/FolinoSettingsJNI/swift-java.config`
- Modify: `Packages/Features/Settings/Package.swift`

- [ ] **Step 1: JNI entry point**
```swift
import Foundation
import SettingsLogic

/// swift-java entry point for Kotlin `SettingsJNI.nativeLoadVersionHistory`.
/// Takes the JSON asset bytes, returns the wirelet-encoded entry list.
public func nativeLoadVersionHistory(jsonBytes: Data) -> Data {
    versionHistoryWirePayload(jsonData: jsonBytes)
}
```

- [ ] **Step 2: swift-java config**

`swift-java.config`:
```json
{
  "javaPackage": "com.keynumber.folino.settings.swiftjava",
  "mode": "jni",
  "logLevel": "debug"
}
```

- [ ] **Step 3: Gate the target in Package.swift behind FOLINO_ANDROID**

Mirror `SSM/Package.swift`'s `isAndroid` block. At the top:
```swift
let isAndroid = ProcessInfo.processInfo.environment["FOLINO_ANDROID"] == "1"
```
Add the swift-java package dep (copy the exact URL/revision and the `JExtractSwiftPlugin` usage from `SSM/Package.swift`). Conditionally append the `FolinoSettingsJNI` target (dependencies `["SettingsLogic", .product(name: "Wirelet", package: "swift-wirelet")]`, with the swift-java jextract plugin) and a matching `.library(name: "FolinoSettingsJNI", targets: ["FolinoSettingsJNI"])` product, only when `isAndroid`. Keep `FolinoSettingsJNI` out of the default (iOS) build so `xcodebuild` never sees it.

- [ ] **Step 4: Verify iOS build is unaffected**
```bash
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build
```
Expected: succeeds (FolinoSettingsJNI excluded).

- [ ] **Step 5: Verify the JNI product cross-compiles**
```bash
export TOOLCHAINS=org.swift.632202605101a
FOLINO_ANDROID=1 swift build --product FolinoSettingsJNI --swift-sdk aarch64-unknown-linux-android28 -c release
```
Expected: `libFolinoSettingsJNI.so` under `.build/aarch64-unknown-linux-android28/release/`. **If this fails on a dependency (e.g. Wirelet's macro or a transitive C dep), record it in findings §4 and apply the Risks-table fallback before proceeding.**

- [ ] **Step 6: Commit**
```bash
git add Packages/Features/Settings
git commit -m "Add Android-only FolinoSettingsJNI target (gated by FOLINO_ANDROID)"
```

### Task 4.4: Port the cross-compile staging script

**Files:**
- Create: `Scripts/android-build-libs.sh`

- [ ] **Step 1: Copy and adapt the SSM script**

Copy `SSM/Scripts/android-build-libs.sh`. Change: `SWIFT_SHEET_MUSIC_ANDROID=1` → `FOLINO_ANDROID=1`; `--product SheetMusicAndroidJNI` → `--product FolinoSettingsJNI`; `libSheetMusicAndroidJNI.so` → `libFolinoSettingsJNI.so`; `JNI_DIR` → `Android/FolinoSettingsAndroid/src/main/jniLibs`; the generated-java source path's `SheetMusicAndroidJNI` segment → `FolinoSettingsJNI`; the java-generated dest → `Android/FolinoSettingsAndroid/src/main/java-generated`. Keep the per-ABI loop, `libSwiftJava.so` staging, runtime-stub copy (with the test-lib exclusions), and `libc++_shared.so` from the NDK.

- [ ] **Step 2: Run it**
```bash
chmod +x Scripts/android-build-libs.sh
Scripts/android-build-libs.sh
```
Expected: `libFolinoSettingsJNI.so` + `libSwiftJava.so` + Swift runtime `.so` + `libc++_shared.so` staged under `Android/FolinoSettingsAndroid/src/main/jniLibs/{arm64-v8a,x86_64}/`, and Java bindings under `…/java-generated/`.

- [ ] **Step 3: Commit (script only; staged .so/java are gitignored)**
```bash
git add Scripts/android-build-libs.sh
git commit -m "Add android-build-libs.sh to cross-compile + stage FolinoSettingsJNI"
```

### Task 4.5: Wire wirelet codegen into the Android module

**Files:**
- Modify: `Android/FolinoSettingsAndroid/build.gradle.kts`
- Modify: `Android/app/build.gradle.kts` (re-add wirelet plugin if codecs are consumed app-side)

- [ ] **Step 1: Add the wirelet plugin + block to FolinoSettingsAndroid**

Add `id("io.github.jiyimeta.wirelet") version "0.1.0-alpha.2"` to its `plugins`. Add the `wirelet { … }` block from `SSM/Android/SheetMusicAndroid/build.gradle.kts`, changing `swiftPackagePath` to point at this repo's wirelet checkout and:
```kotlin
val packageRoot: File = rootProject.projectDir.resolve("..").canonicalFile  // worktree root
wirelet {
    swiftPackagePath.set(File(packageRoot, "Packages/Features/Settings/.build/checkouts/swift-wirelet")
        .takeIf { it.exists() } ?: File(packageRoot, ".build/checkouts/swift-wirelet"))
    sources {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Packages/Features/Settings/Sources/SettingsLogic"))
            codecPackage.set("com.keynumber.folino.settings")
            modelPackage.set("com.keynumber.folino.settings")
            emitModels.set(true)
        }
    }
}
```
Then add the manual `generateWireletCodecsMain` source-set + `dependsOn` wiring block exactly as in the reference (the plugin v1 only auto-wires kotlin.jvm, not kotlin.android).

> The schema path must contain the `@WireFormat` declarations (`VersionHistoryWire.swift`). Ensure `swift package resolve` has been run inside `Packages/Features/Settings` so `.build/checkouts/swift-wirelet` exists for the emitter to read.

- [ ] **Step 2: Build the module to generate + compile codecs**
```bash
Android/gradlew -p Android :FolinoSettingsAndroid:assembleDebug
```
Expected: `BUILD SUCCESSFUL`; generated `VersionHistoryWireCodec.kt` / `VersionHistoryWireListCodec.kt` (+ model classes) compile.

- [ ] **Step 3: Commit**
```bash
git add Android/FolinoSettingsAndroid/build.gradle.kts Android/app/build.gradle.kts
git commit -m "Wire wirelet Kotlin codegen into FolinoSettingsAndroid"
```

### Task 4.6: Kotlin JNI façade + decode

**Files:**
- Create: `Android/FolinoSettingsAndroid/src/main/kotlin/com/keynumber/folino/settings/SettingsJNI.kt`
- Create: `Android/FolinoSettingsAndroid/src/main/kotlin/com/keynumber/folino/settings/VersionHistory.kt`

- [ ] **Step 1: Façade over the generated swift-java entry point**

Mirror `SSM/Android/SheetMusicAndroid/.../SheetMusicJNI.kt`. The generated class name follows the target (`FolinoSettingsJNI`) under the `…swiftjava` package:
```kotlin
package com.keynumber.folino.settings

import org.swift.swiftkit.core.SwiftMemoryManagement
import com.keynumber.folino.settings.swiftjava.Data as SwiftData
import com.keynumber.folino.settings.swiftjava.FolinoSettingsJNI as SwiftJavaJNI

object SettingsJNI {
    fun nativeLoadVersionHistory(jsonBytes: ByteArray): ByteArray {
        val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
        return SwiftJavaJNI.nativeLoadVersionHistory(SwiftData.fromByteArray(jsonBytes, arena), arena).toByteArray()
    }
}
```
> Confirm the exact generated method signature (arena arg position, `SwiftData` factory) against the staged `src/main/java-generated/` files; adjust to match what jextract emitted.

- [ ] **Step 2: Public API: bytes → decoded entries via the wirelet codec**
```kotlin
package com.keynumber.folino.settings

// VersionHistoryWireListCodec + VersionHistoryWire are wirelet-generated (emitModels=true).
object VersionHistoryBridge {
    fun load(jsonBytes: ByteArray): List<VersionHistoryWire> =
        VersionHistoryWireListCodec.decode(SettingsJNI.nativeLoadVersionHistory(jsonBytes)).entries
}
```

- [ ] **Step 3: Commit**
```bash
git add Android/FolinoSettingsAndroid/src/main/kotlin
git commit -m "Add Kotlin JNI façade + wirelet decode for version history"
```

### Task 4.7: Feed Swift-decoded entries into Compose; run

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/VersionHistoryList.kt`

- [ ] **Step 1: Replace the placeholder source with the JNI bridge**

In `MainActivity`, read the asset and call the bridge (off the main thread, then map to `VersionHistoryItem`):
```kotlin
val json = assets.open("VersionHistory.json").readBytes()
val items = com.keynumber.folino.settings.VersionHistoryBridge.load(json)
    .map { com.keynumber.folino.ui.settings.VersionHistoryItem(it.version, it.descriptions) }
```
Pass `items` into `SettingsScreen`. (For the spike a synchronous load in `onCreate` before `setContent` is acceptable; note threading as a finding.)

- [ ] **Step 2: Rebuild and run**
```bash
Scripts/android-build-libs.sh            # if Swift changed since last stage
Android/gradlew -p Android :app:installDebug
adb shell am start -n com.keynumber.folino/.MainActivity
adb exec-out screencap -p > /tmp/folino-settings-p4.png
```
`Read` the PNG. Expected: the Version History section now shows the entries decoded by Swift from the JSON asset (real versions + descriptions), not the placeholder.

- [ ] **Step 3: Commit**
```bash
git add Android/app/src/main/kotlin
git commit -m "Render Swift-decoded version history in Compose via wirelet"
```

---

## Phase 5 — Findings document

### Task 5.1: Complete the findings document

**Files:**
- Modify: `docs/superpowers/specs/2026-05-27-folino-android-settings-findings.md`

- [ ] **Step 1: Fill in every section with concrete evidence**

Using the spec's findings structure, write up each section from what actually happened, citing commands, errors, and the two screenshots (`/tmp/folino-settings-p3.png`, `/tmp/folino-settings-p4.png`):
1. **Environment setup** — (from Task 0.5) plus anything new.
2. **Shared cleanly** — `VersionHistoryEntry` (Domain `Decodable`), `VersionHistoryViewModel`, the wire types; confirm they compiled and ran on Android.
3. **Reimplemented in Compose** — `Form`/sections, toggles, segmented picker, version-history list; SF Symbols → Material icons.
4. **Needs separate handling** — Yams/libyaml (stayed iOS-side; JSON used on Android — state whether Yams was even attempted); Firebase crash reporting; `MFMailComposeViewController`; `LicenseList`; `@AppStorage` ↔ DataStore key/semantics divergence; the asset-format question (yml vs json); main-thread load.
5. **Unresolved architecture decisions** — where shared Settings code belongs long-term; `@Observable`-on-Android (untested here — the slice was stateless); localization sharing; in-tree vs `folino-android` repo; whether to keep swift-java or revisit `@_cdecl`.

Each claim must cite a concrete signal (a command that passed/failed, a screenshot, a build error). No vague statements.

- [ ] **Step 2: Open in QuickMD for the user**
```bash
quick-md docs/superpowers/specs/2026-05-27-folino-android-settings-findings.md
```

- [ ] **Step 3: Commit**
```bash
git add docs/superpowers/specs/2026-05-27-folino-android-settings-findings.md
git commit -m "Write Folino Android Settings spike findings"
```

---

## Self-review notes (for the executor)

- **Spec coverage:** P1 = SettingsLogic split; P2 = Android scaffold; P3 = Compose UI + DataStore (working screen); P4 = swift-java + wirelet version-history bridge; P5 = findings. The five spec findings sections map 1:1 to Task 5.1 substeps. OUT items (soundfont/Firebase/LicenseList/mail/SF-Symbols) are recorded, not built.
- **Type consistency:** Swift `VersionHistoryWire(version:descriptions:)` / `VersionHistoryWireList(entries:)` are used identically in Tasks 4.1/4.2/4.3; Kotlin `VersionHistoryWire.version/.descriptions` + `VersionHistoryWireListCodec.decode(...).entries` match the `emitModels=true` output naming. `nativeLoadVersionHistory(jsonBytes:)` Swift signature matches the Kotlin `SettingsJNI` call.
- **Known soft spots to verify at runtime (not placeholders — flagged unknowns):** exact jextract-generated method signature (Task 4.6 Step 1 says verify against staged output); whether `AppVersion` exposes a `String` for the wire `version` field (Task 4.2 note); whether the wirelet `[T]`-of-`@WireFormat` nesting is supported by `0.1.0-alpha.2` (Task 4.1 — if not, flatten to a length-prefixed list in the bridge and record it). Each has an inline instruction or a Risks-table fallback in the spec.

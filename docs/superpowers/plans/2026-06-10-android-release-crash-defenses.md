# Android Release-Crash Defenses Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add deterministic, script/test-based gates that catch the two release-risk crash classes (missing native `.so` → `UnsatisfiedLinkError`; silently-swallowed import failures) before a release.

**Architecture:** Four independent components — (A) a device-free bash script asserting every expected `libFolino*JNI.so` is packaged in the APK; (B) a new `androidTest` suite that force-loads all four JNI libs and imports a fixture score; (C) a new `Application` subclass that eager-loads all four libs at launch (kept only if the measured cold-start cost is small); (D) Kotlin-side surfacing of import failures (Crashlytics non-fatal + user-visible error) so silent failures become loud.

**Tech Stack:** Bash, Android Gradle (Kotlin DSL), androidx.test (instrumented), Jetpack Compose, Firebase Crashlytics. Emulator verification via `ANDROID_SERIAL=emulator-5554`.

---

## Reference Material

- Spec: `docs/superpowers/specs/2026-06-10-android-release-crash-defenses-design.md`
- Native-lib load sites (each generated class's static init): `LibraryAndroidStoreViewModel` (loads `FolinoLibraryJNI`), `MuseScoreGeneralAndroidStoreViewModel` (`FolinoSoundfontJNI`), `FolinoReaderJNI`/`FolinoSettingsJNI` java-generated (`SwiftLibraries.loadLibraryWithFallbacks`).
- Generated Library VM API: `com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel` — `val scores: StateFlow<List<ScoreRowWire>>`, `fun importScore(path: String)`. Built via `LibraryVMFactory(context.applicationContext)` (see `MainActivity.kt:693-701`).
- Room store: `com.keynumber.folino.library.RoomLibraryStore` — process-wide singleton DB; `loadAll(): List<ScoreRecordWire>` (each has `deletedAt`). Constructible as `RoomLibraryStore(context)`.
- Import swallow points: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift:89` `importScore` (parse `try?` at :91; the dedup `store.loadAll()` Room exception is eaten by the wirelet JNI proxy — NOT catchable in Swift, but IS catchable when Kotlin calls `loadAll()` directly).
- App module: `Android/app/build.gradle.kts`, `Android/app/src/main/AndroidManifest.xml` (no `Application` subclass today; `abiFilters = [arm64-v8a, x86_64]`).
- Fixture score: `FolinoScreenshot/Resources/Now_is_the_time.mscz` (valid .mscz, reuse as test asset).
- Crashlytics wrapper: `com.keynumber.folino.diagnostics.CrashReporting` (app module; used in `SettingsScreen.kt`).
- Build scripts: `Scripts/android-build-{library,reader,soundfont}-libs.sh`, `Scripts/android-build-libs.sh`.

## Build-order / environment notes (from prior Android work)

- Fresh worktree: per-module `.so` are gitignored and NOT carried across worktrees — build ALL of `libFolino{Library,Reader,Settings,Soundfont}JNI.so` (the missing Soundfont/Reader `.so` is exactly defense (A)/(C)'s target). `java-generated` bindings may also need copying from the primary checkout + `swift package resolve`.
- Gradle invocation pattern: `PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH Android/gradlew -p Android <task> --no-daemon`.
- Emulator only (`ANDROID_SERIAL=emulator-5554`); never disconnect the physical Pixel.

## Worktree Setup (do first, at execution time)

- [ ] Create an isolated worktree from local `main` (EnterWorktree, `worktree.baseRef: head` is configured → branches from local HEAD). Symlink the gitignored config:
```bash
ln -s /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Config/Local.xcconfig <worktree>/Config/Local.xcconfig
```
- [ ] Build all four JNI `.so` into the worktree (needed for B/C verification + the app to run):
```bash
<worktree>/Scripts/android-build-library-libs.sh
<worktree>/Scripts/android-build-reader-libs.sh
<worktree>/Scripts/android-build-soundfont-libs.sh
# (Settings JNI: Scripts/android-build-libs.sh — run if libFolinoSettingsJNI.so is absent)
```
Run `swift package resolve` for the relevant package first if a build complains about unresolved deps. Copy any missing `java-generated` dir from the primary checkout.

---

## Task 1 (Component A): Native-lib completeness check script

**Files:**
- Create: `Scripts/android-release-check.sh`

- [ ] **Step 1: Write the script.** It asserts every expected Folino JNI lib (+ `libSwiftJava.so`) is packaged for every ABI. Takes an optional APK path; builds `:app:assembleDebug` if none given.

```bash
#!/usr/bin/env bash
# Deterministic pre-release gate: verify every expected native lib is packaged in
# the APK, for every ABI. Catches a missing/un-staged libFolino*JNI.so BEFORE the
# app is ever run (the failure otherwise only surfaces at runtime on score-open).
#
# Usage:
#   Scripts/android-release-check.sh [path/to/app.apk]
# With no arg, builds Android/app :app:assembleDebug and checks the resulting APK.
# Exits non-zero (and prints which lib/ABI is missing) if anything is absent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

# Source of truth — see docs/superpowers/specs/2026-06-10-android-release-crash-defenses-design.md
ABIS=("arm64-v8a" "x86_64")
EXPECTED_LIBS=(
    "libFolinoLibraryJNI.so"
    "libFolinoReaderJNI.so"
    "libFolinoSettingsJNI.so"
    "libFolinoSoundfontJNI.so"
    "libSwiftJava.so"
)

APK="${1:-}"
if [[ -z "$APK" ]]; then
    echo "==> No APK given; building :app:assembleDebug"
    PATH="/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH" \
        "$ROOT/Android/gradlew" -p "$ROOT/Android" :app:assembleDebug --no-daemon
    APK="$ROOT/Android/app/build/outputs/apk/debug/app-debug.apk"
fi

if [[ ! -f "$APK" ]]; then
    echo "error: APK not found: $APK" >&2
    exit 2
fi
echo "==> Checking native libs in: $APK"

# One listing of all packaged lib/ entries.
LIBS_IN_APK="$(unzip -Z1 "$APK" 'lib/*' 2>/dev/null || true)"

missing=0
for abi in "${ABIS[@]}"; do
    for lib in "${EXPECTED_LIBS[@]}"; do
        if ! grep -qx "lib/$abi/$lib" <<<"$LIBS_IN_APK"; then
            echo "MISSING: lib/$abi/$lib"
            missing=1
        fi
    done
done

if [[ "$missing" -ne 0 ]]; then
    echo "FAIL: one or more expected native libs are not packaged."
    exit 1
fi
echo "PASS: all expected native libs present for ${ABIS[*]}."
```

- [ ] **Step 2: Make it executable and run it (PASS case).**

Run:
```bash
chmod +x /Users/.../<worktree>/Scripts/android-release-check.sh
/Users/.../<worktree>/Scripts/android-release-check.sh
```
Expected: ends with `PASS: all expected native libs present for arm64-v8a x86_64.` (after building the APK). This requires all four `.so` staged (see Worktree Setup).

- [ ] **Step 3: Verify it FAILS deterministically when a lib is missing.** Temporarily point it at an APK known to lack a lib, OR temporarily remove one expected lib name's staged `.so` and rebuild — simplest: temporarily add a bogus expected lib and confirm non-zero exit + `MISSING:` line, then revert. Confirm exit code:
```bash
/Users/.../<worktree>/Scripts/android-release-check.sh ; echo "exit=$?"
```
Expected for the negative test: `MISSING: lib/<abi>/<lib>` printed, `FAIL`, `exit=1`. Revert any temporary edit afterward.

- [ ] **Step 4: Commit.**
```bash
git -C <worktree> add Scripts/android-release-check.sh
git -C <worktree> commit -m "build(android): release-check script asserting native-lib completeness"
```

---

## Task 2 (Component C): Eager native-load Application + perf measurement

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/FolinoApplication.kt`
- Modify: `Android/app/src/main/AndroidManifest.xml` (add `android:name`)

- [ ] **Step 1: Create the Application subclass** that force-loads all four JNI libs at launch by initializing each generated entry class. A load failure is logged to Crashlytics (never expected in a good build; makes a bad build observable) and rethrown so a broken build fails fast at launch.

```kotlin
package com.keynumber.folino

import android.app.Application
import com.keynumber.folino.diagnostics.CrashReporting

/**
 * Eager-loads every Folino JNI native library at process start. Without this, only
 * libFolinoLibraryJNI/libFolinoSettingsJNI load at launch (their classes are used on
 * the start screen); libFolinoReaderJNI/libFolinoSoundfontJNI load lazily on score-open.
 * A missing/broken .so would then crash deep in a flow instead of at launch. Forcing all
 * four to load here makes such a packaging failure fail FAST (visible to any launch check).
 *
 * Each entry class's static initializer runs the corresponding System.loadLibrary; we
 * trigger them via Class.forName(initialize = true).
 */
class FolinoApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        loadNativeEntryClasses()
    }

    private fun loadNativeEntryClasses() {
        val cl = javaClass.classLoader!!
        for (fqcn in NATIVE_ENTRY_CLASSES) {
            try {
                Class.forName(fqcn, /* initialize = */ true, cl)
            } catch (t: Throwable) {
                // A failure here means a native lib is missing/broken in this build.
                CrashReporting.log("Failed to eager-load native entry class: $fqcn")
                throw t // fail fast at launch rather than later on score-open
            }
        }
    }

    private companion object {
        val NATIVE_ENTRY_CLASSES = listOf(
            "com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel",
            "com.keynumber.folino.settings.swiftjava.FolinoSettingsJNI",
            "com.keynumber.folino.reader.swiftjava.FolinoReaderJNI",
            "com.keynumber.folino.soundfont.generated.MuseScoreGeneralAndroidStoreViewModel",
        )
    }
}
```
NOTE: confirm `CrashReporting` exposes a `log(String)` (or `recordException`) method; if the API differs, match it (read `com/keynumber/folino/diagnostics/CrashReporting.kt`). If no suitable method exists, drop the `CrashReporting.log` line and keep the `throw` (fail-fast is the essential behavior).

- [ ] **Step 2: Register it in the manifest.** Add `android:name=".FolinoApplication"` to the `<application>` element in `Android/app/src/main/AndroidManifest.xml`:
```xml
    <application
        android:name=".FolinoApplication"
        android:label="folino"
        android:icon="@mipmap/ic_launcher"
        android:roundIcon="@mipmap/ic_launcher_round"
        android:theme="@style/AppTheme">
```

- [ ] **Step 3: Build, install, launch — confirm clean startup.**
```bash
export ANDROID_SERIAL=emulator-5554
PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH <worktree>/Android/gradlew -p <worktree>/Android :app:installDebug --no-daemon
adb -s emulator-5554 shell am start -n com.keynumber.folino/.MainActivity
sleep 5; adb -s emulator-5554 shell pidof com.keynumber.folino
adb -s emulator-5554 logcat -d -t 200 | rg -i "UnsatisfiedLink|FATAL|AndroidRuntime" | head
```
Expected: pid present, no crash. (If a `.so` is genuinely missing, this now crashes at launch — that is the intended fail-fast.)

- [ ] **Step 4: Measure the cold-start cost (the perf gate).** Median of 5 runs, force-stopping between, WITH the Application (current) — then temporarily revert the manifest `android:name` (only) and re-measure WITHOUT.
```bash
# helper: run 5x and print TotalTime values
for i in 1 2 3 4 5; do
  adb -s emulator-5554 shell am force-stop com.keynumber.folino
  adb -s emulator-5554 shell am start -W -n com.keynumber.folino/.MainActivity | rg "TotalTime"
done
```
Record the median TotalTime WITH vs WITHOUT. **Decision rule:** keep the Application if `median(with) - median(without) <= 150 ms`. If it exceeds 150 ms, REMOVE `FolinoApplication` + the manifest change (rely on A + B for detection). Write the measured numbers + decision into the commit message.

- [ ] **Step 5: Commit (the kept outcome).**
```bash
git -C <worktree> add Android/app/src/main/kotlin/com/keynumber/folino/FolinoApplication.kt Android/app/src/main/AndroidManifest.xml
git -C <worktree> commit -m "feat(android): eager-load all JNI libs at launch (fail-fast)

Cold-start delta: with=<X>ms without=<Y>ms (median of 5), within 150ms budget."
```
(If the decision was to drop C, instead commit nothing for this task and note the measured delta in the final report.)

---

## Task 3 (Component B-1): androidTest infra + native-load smoke

**Files:**
- Modify: `Android/app/build.gradle.kts` (androidTest deps + runner)
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/NativeLibraryLoadTest.kt`

- [ ] **Step 1: Add the instrumented-test infrastructure** to `Android/app/build.gradle.kts`. In `defaultConfig` add the runner; in `dependencies` add androidx.test:
```kotlin
    defaultConfig {
        applicationId = "com.keynumber.folino"
        minSdk = 28
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
```
```kotlin
    // (in dependencies { ... })
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:core-ktx:1.6.1")
```

- [ ] **Step 2: Write the native-load smoke** — force class-init of each native entry class; any missing/broken `.so` throws here.
```kotlin
package com.keynumber.folino

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Deterministic guard: every Folino JNI native library must load. Each entry class's
 * static initializer runs its System.loadLibrary; a missing/un-staged .so throws
 * ExceptionInInitializerError / UnsatisfiedLinkError here — catching the exact failure
 * (e.g. libFolinoSoundfontJNI.so absent) that otherwise only surfaces on score-open.
 */
@RunWith(AndroidJUnit4::class)
class NativeLibraryLoadTest {
    private val entryClasses = listOf(
        "com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel",
        "com.keynumber.folino.settings.swiftjava.FolinoSettingsJNI",
        "com.keynumber.folino.reader.swiftjava.FolinoReaderJNI",
        "com.keynumber.folino.soundfont.generated.MuseScoreGeneralAndroidStoreViewModel",
    )

    @Test
    fun allFolinoNativeLibrariesLoad() {
        val cl = javaClass.classLoader!!
        for (fqcn in entryClasses) {
            // initialize = true forces the static initializer (System.loadLibrary) to run.
            Class.forName(fqcn, true, cl)
        }
    }
}
```

- [ ] **Step 3: Run it on the emulator.**
```bash
export ANDROID_SERIAL=emulator-5554
PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH <worktree>/Android/gradlew -p <worktree>/Android :app:connectedDebugAndroidTest --no-daemon 2>&1 | tail -25
```
Expected: BUILD SUCCESSFUL, `NativeLibraryLoadTest > allFolinoNativeLibrariesLoad` PASSED.

- [ ] **Step 4: Verify it goes RED on a missing lib.** Temporarily delete one staged `.so` (e.g. `Android/FolinoSoundfontAndroid/src/main/jniLibs/x86_64/libFolinoSoundfontJNI.so`) and re-run — expect the test to FAIL with `UnsatisfiedLinkError`. Restore the `.so` afterward (re-run its build script or `git`-clean the deletion — it is gitignored, so re-run `Scripts/android-build-soundfont-libs.sh` to restore).

- [ ] **Step 5: Commit.**
```bash
git -C <worktree> add Android/app/build.gradle.kts Android/app/src/androidTest/kotlin/com/keynumber/folino/NativeLibraryLoadTest.kt
git -C <worktree> commit -m "test(android): instrumented native-library load smoke + androidTest infra"
```

---

## Task 4 (Component B-2): Import smoke test + fixture

**Files:**
- Create: `Android/app/src/androidTest/assets/smoke.mscz` (copied from `FolinoScreenshot/Resources/Now_is_the_time.mscz`)
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/ImportSmokeTest.kt`

- [ ] **Step 1: Add the fixture asset.**
```bash
mkdir -p <worktree>/Android/app/src/androidTest/assets
cp <worktree>/FolinoScreenshot/Resources/Now_is_the_time.mscz <worktree>/Android/app/src/androidTest/assets/smoke.mscz
```

- [ ] **Step 2: Write the import smoke.** It copies the fixture to a temp path, imports it through the real generated VM, and asserts the score is persisted in the shared Room DB — exercising the native import path + Room write that the silent-failure bug lived on. It clears app DB state first so the assertion is deterministic across runs.
```kotlin
package com.keynumber.folino

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.keynumber.folino.library.LibraryVMFactory
import com.keynumber.folino.library.RoomLibraryStore
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Deterministic smoke for the import path: import a bundled fixture .mscz through the
 * real generated LibraryAndroidStoreViewModel and assert it persists into the shared
 * Room DB. Exercises nativeImportScore + the Room write — the exact path the silent
 * import failure lived on. Uses RoomLibraryStore.loadAll() (synchronous, shared DB) for
 * the assertion to avoid StateFlow timing.
 */
@RunWith(AndroidJUnit4::class)
class ImportSmokeTest {
    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val store = RoomLibraryStore(context)

    @Before
    fun clearScores() {
        // Start from a known state: permanently remove any existing rows so the
        // count delta is unambiguous. (Pre-release DB; safe to wipe on the emulator.)
        store.loadAll().forEach { store.deleteRecord(it.id) }
    }

    @Test
    fun importsFixtureScore() {
        // Copy the bundled fixture to a real file path (importScore takes a path).
        val tmp = File.createTempFile("smoke", ".mscz", context.cacheDir)
        context.assets.open("smoke.mscz").use { input ->
            tmp.outputStream().use { input.copyTo(it) }
        }

        val before = store.loadAll().count { it.deletedAt <= 0.0 }

        val vm = LibraryVMFactory(context.applicationContext)
            .create(LibraryAndroidStoreViewModelClass(), buildVm = true) // see NOTE
        vm.importScore(tmp.absolutePath)

        val after = store.loadAll().count { it.deletedAt <= 0.0 }
        assertTrue("import should add exactly one active score (before=$before after=$after)", after == before + 1)
    }
}
```
NOTE on VM construction: `LibraryVMFactory(context.applicationContext)` is an `androidx.lifecycle.ViewModelProvider.Factory` (see `MainActivity.kt:693`). In a non-ViewModelStoreOwner test, construct the VM via the SAME factory call the app uses — the implementer should read `LibraryVMFactory.create(...)` and call it exactly as the app does (the placeholder `LibraryAndroidStoreViewModelClass()` above is illustrative). If the factory needs a `modelClass`, pass `LibraryAndroidStoreViewModel::class.java`. The essential behavior: obtain a real `LibraryAndroidStoreViewModel` and call `importScore(path)`. Keep the assertion (count delta via `store.loadAll()`) exactly as written.

- [ ] **Step 3: Run it on the emulator.**
```bash
export ANDROID_SERIAL=emulator-5554
PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH <worktree>/Android/gradlew -p <worktree>/Android :app:connectedDebugAndroidTest --no-daemon 2>&1 | tail -25
```
Expected: BUILD SUCCESSFUL, `ImportSmokeTest > importsFixtureScore` PASSED (and `NativeLibraryLoadTest` still PASSED).

- [ ] **Step 4: Commit.**
```bash
git -C <worktree> add Android/app/src/androidTest/assets/smoke.mscz Android/app/src/androidTest/kotlin/com/keynumber/folino/ImportSmokeTest.kt
git -C <worktree> commit -m "test(android): instrumented import smoke (fixture .mscz round-trips into Room)"
```

---

## Task 5 (Component D): Surface import failures (no silent swallow)

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt` (import call site, ~lines 23-56)

**Why here:** the original silent failure was a Room exception thrown while the Swift `importScore` called Kotlin `loadAll()` for dedup — eaten by the wirelet JNI proxy (un-catchable in Swift). But when **Kotlin** calls `loadAll()` directly, the same failure is a normal, catchable Kotlin exception. So we wrap the import at the Kotlin call site with a catchable pre/post check that surfaces both hard exceptions AND silent no-ops.

- [ ] **Step 1: Read the current import call site** (`LibraryScreen.kt:23-56`) — the SAF `OpenDocument` result handler that copies to `cacheDir` and calls `viewModel.importScore(cacheFile.absolutePath)` (~line 41). Note how the screen shows transient messages (is there an existing Snackbar host / `SnackbarHostState`? a Toast?). Use the existing user-notification mechanism on this screen; if none exists, add a `Toast` (simplest, no host plumbing).

- [ ] **Step 2: Wrap the import in a catchable verify-and-surface block.** Replace the bare `viewModel.importScore(path)` call with:
```kotlin
// Surface import failures that were previously silent: a broken DB throws here (Kotlin
// context, catchable — unlike inside the Swift→Kotlin JNI proxy), and a no-op import
// (parse failure etc.) is caught by the count delta. Either way the user is told and a
// Crashlytics non-fatal is logged instead of the import silently doing nothing.
val store = RoomLibraryStore(context)
try {
    val before = store.loadAll().count { it.deletedAt <= 0.0 }
    viewModel.importScore(cacheFile.absolutePath)
    val after = store.loadAll().count { it.deletedAt <= 0.0 }
    if (after <= before) {
        CrashReporting.log("Import produced no new score: ${cacheFile.name}")
        Toast.makeText(context, context.getString(R.string.import_failed), Toast.LENGTH_LONG).show()
    }
} catch (t: Throwable) {
    CrashReporting.recordException(t)
    Toast.makeText(context, context.getString(R.string.import_failed), Toast.LENGTH_LONG).show()
}
```
Adjust `CrashReporting.log` / `CrashReporting.recordException` to the actual `CrashReporting` API (read `diagnostics/CrashReporting.kt`; if only one of log/recordException exists, use it for both). `RoomLibraryStore` is already a dependency of the app module (it backs the library). `importScore` is synchronous (Room runs with `allowMainThreadQueries`), so the post-`importScore` `loadAll()` reflects the result immediately.

- [ ] **Step 3: Add the string resource.** Append to every Reader/app `strings.xml` the app module ships (the app module is English-only → only `Android/app/src/main/res/values/strings.xml`):
```xml
    <string name="import_failed">Couldn\'t import this file.</string>
```

- [ ] **Step 4: Build + install + manually confirm the happy path still works + the error path surfaces.**
```bash
export ANDROID_SERIAL=emulator-5554
PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH <worktree>/Android/gradlew -p <worktree>/Android :app:installDebug --no-daemon
adb -s emulator-5554 shell am start -n com.keynumber.folino/.MainActivity
```
Happy path: import a valid file via "+" → score appears, no toast. Error path (to confirm surfacing): the deterministic check is that an import which adds no score shows the toast + logs — hard to force without breaking the DB; verify by code review that both branches call the toast + CrashReporting. (The instrumented `ImportSmokeTest` covers the happy path deterministically.)

- [ ] **Step 5: Commit.**
```bash
git -C <worktree> add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt Android/app/src/main/res/values/strings.xml
git -C <worktree> commit -m "feat(android-library): surface import failures (Crashlytics + user-visible) instead of silent no-op"
```

---

## Final Verification

- [ ] `Scripts/android-release-check.sh` → PASS on the built APK.
- [ ] `:app:connectedDebugAndroidTest` → both `NativeLibraryLoadTest` and `ImportSmokeTest` GREEN on the emulator.
- [ ] App launches cleanly with `FolinoApplication` (if C was kept); cold-start delta recorded.
- [ ] Manual: "+" import of a valid file adds a score (no error toast).
- [ ] Update / create the memory note for this work; the release-check script + smoke are the new pre-release gates.

## Self-Review Notes (for the implementer)

- **VM construction in `ImportSmokeTest` (Task 4 Step 2):** the `LibraryVMFactory.create(...)` call is the one fuzzy spot — read the factory + call it exactly as `MainActivity` does. The assertion (count delta via `RoomLibraryStore.loadAll()`) is the load-bearing part and must stay verbatim.
- **`CrashReporting` API (Tasks 2 & 5):** confirm method names; adapt the calls. Fail-fast `throw` (Task 2) and the toast (Task 5) are the essential behaviors and must remain even if the Crashlytics call is adjusted/dropped.
- **C is conditional:** if the measured cold-start delta exceeds 150 ms, Task 2 is dropped (not committed) and that's recorded — A + B still provide deterministic detection.

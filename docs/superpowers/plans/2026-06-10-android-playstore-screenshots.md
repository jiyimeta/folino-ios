# Android Play Store Screenshot Harness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate localized, device-framed Google Play screenshots for the Folino Android app with one Gradle command, reaching 4 specific in-app states deterministically.

**Architecture:** Mirror VocalTuner's *scene → marketing frame → fastlane supply* structure, but run capture as an **instrumented test on an emulator** (not host-JVM Robolectric) because the Reader renders sheet music via native JNI `.so` libraries. Each scene composes real production composables into a fixed-pixel marketing frame and is captured at the node level, so one AVD yields both phone and tablet outputs. Reader scenes reuse the VM-computed `DrawProgram` (no re-implementation of native layout); `hiddenStaves` in `LayoutOptions` drives staff visibility; a static `ScoreCursor` built via `nearestCursorForTap` drives the cursor overlay.

**Tech Stack:** Kotlin, Jetbrains Compose (BOM 2024.09.02), Roborazzi 1.32.0 (instrumented/connected mode), AndroidX Test (AndroidJUnit4), `io.github.jiyimeta:sheet-music-*` libraries, Room, fastlane supply.

---

## Critical context (read before starting)

- **Module:** the app module is `Android/app`, namespace `com.keynumber.folino`, applicationId `com.keynumber.folino`, `minSdk 28`, `compileSdk 35`, `ndk.abiFilters = [arm64-v8a, x86_64]`. Compose BOM `2024.09.02`. Depends on `:FolinoReaderAndroid`, `:FolinoLibraryAndroid`, `:FolinoSettingsAndroid` and the three `io.github.jiyimeta:sheet-music-*` SNAPSHOT artifacts.
- **Native libs must be staged before any androidTest build.** `FolinoReaderAndroid/src/main/jniLibs` (Reader JNI + Swift runtime) and `FolinoLibraryAndroid/src/main/jniLibs` (`libFolinoLibraryJNI.so`) plus generated Kotlin under `java-generated` are produced by `Scripts/android-build-reader-libs.sh` / `Scripts/android-build-library-libs.sh` and the Wirelet codegen. If a fresh checkout, these must exist or the test APK will crash at `System.loadLibrary`. Confirm presence first; if missing, run the staging scripts (see memory: Android build toolchain).
- **Why instrumented, not Robolectric:** Robolectric runs on the host JVM and cannot load Android arm/x86 `.so`. VocalTuner used `@RunWith(RobolectricTestRunner)` + `RuntimeEnvironment.setQualifiers`. We must use `@RunWith(AndroidJUnit4)` in `src/androidTest` and **cannot** switch screen qualifiers at runtime. Device differentiation is achieved purely by the marketing frame's fixed output pixel size + `innerDesignWidth`, captured as a sized node.
- **An emulator/AVD must be booted** for capture tasks. A device with a display at least as large as the largest frame canvas avoids clipping; if the default AVD is smaller, render canvases that fit (Play Console accepts a range of sizes/aspect — exact 1600px is not mandatory) or use a large-resolution AVD.
- **Verification reality:** there is no "assert the PNG looks right" unit test. Each capture task's verification = the Gradle/test run completes without crashing AND the expected PNG files exist, are non-empty, and have the expected pixel dimensions; then a human (or the orchestrator via `Read` on the PNG) visually confirms the state. Treat "build + run + files exist + visual spot-check" as the done bar.

## Key production API surface (verified, quote when coding)

- `ReaderScreen(scoreId, title, layoutMode, displayOptions: LayoutOptions, onDisplayOptionsChange, onBack, onEditInfo, pageTapHintDismissed, onDismissPageTapHint, globalA4ReferenceHz, pipEnabled, showSeekBar, onShowSeekBarChange, onShare, readerVm, audioVm)` — `FolinoReaderAndroid/.../ReaderScreen.kt:95`.
- Reader rendering core `ReadyScore(state: ReaderState.Ready, scoreHandle: Long?, fontProvider, audioVm, layoutOptions)` — `ReaderScreen.kt:302`. Renders `state.program.pages.first()` via `ScorePage(page, fontProvider, pxPerMM, modifier)` and overlays `PlaybackCursorOverlay(scoreHandle, cursorFlow = audioVm.currentCursor, pxPerMM, scale, panOffset, modifier)`.
- `ReaderViewModel`: `load(scoreId)`, `state: StateFlow<ReaderState>` (Ready holds `.program`), `scoreHandle: StateFlow<Long?>`, `parts: StateFlow<List<PartDescriptor>>`, `openingQuarterBpm`, `setLayoutOptions(LayoutOptions)`. Score file path = `filesDir/Scores/<scoreId>.mscz`. `ReaderViewModel.kt:32`.
- `LayoutOptions(mode, staffSize, honorLayoutBreaks, collapseMultiMeasureRests, showInvisibleElements, hiddenStaves: Set<StaffAddress>, clefOverrides: Map<StaffAddress,String>)`, `LayoutOptions.DEFAULT` (mode=PAGE, staffSize=28.0), `LayoutOptions.encode(): ByteArray`. `StaffAddress(partIndex, staffIndexInPart)`. `PartDescriptor(name, staves: List<StaffDescriptor>)`, `StaffDescriptor(address, defaultClefRawType)`. `LayoutOptions.kt`.
- `DisplayInspectorSheet(options: LayoutOptions, parts: List<PartDescriptor>, sheetState: SheetState, onDismiss, onChange, showSeekBar, onShowSeekBarChange)` — `DisplayInspectorSheet.kt:105`.
- `nearestCursorForTap(tap: Offset, contentOffsetPx: Offset, pxPerMM: Float, scale: Float, scoreHandle: Long, layoutOptionsBytes: ByteArray): ScoreCursor?` — `TapToCursor.kt:33`. Pure JNI, no engine.
- `ScoreCursor` (sealed) from `io.github.jiyimeta.sheetmusic.audio.model`; `ScoreCursorCodec.encode(cursor)`, `SheetMusicJNI.nativeCursorFrame(handle, bytes)`, `DecodedFrameCodec.decode(bytes)` give a cursor's `{x,y,width,height}` in mm.
- `ScoreHandle.load(bytes: ByteArray): ScoreHandle?` with `.raw: Long`. `bundledFontProvider(context): FontProvider`. `SheetMusicJNI.nativeInstallSMuFLMetrics(BravuraMetricsBuilder.buildTable(assets))` must run before layout/rendering (ReaderViewModel.load does this).
- `LibraryScreen(viewModel: LibraryAndroidStoreViewModel, onOpenScore, onOpenDrawer, onEditInfoForScore)` — `LibraryScreen.kt:14`. `LibraryAndroidStoreViewModel.create(store: LibraryStore, pdfRenderer, audioExporter)`; `scores: StateFlow<List<ScoreRowWire>>`. `System.loadLibrary("FolinoLibraryJNI")` in its companion init.
- `ScoreRowWire(id, title, subtitle, composer, isFavorite)`.
- `RoomLibraryStore` over `folino-library.db` (`filesDir`); `ScoreRecordEntity(id, title, subtitle, composer, arranger?, lyricist?, copyright?, localFileName, contentHash, deletedAt, lastOpenedAt, isFavorite)`; `upsert(ScoreRecordWire)`, `copyImportedFile(fromPath, localFileName)`; scores dir = `filesDir/Scores`.
- `FolinoTheme(darkTheme, content)` — `Theme.kt:57`.

---

## File structure

```
Android/app/src/androidTest/
├── assets/Now_is_the_time.mscz                                  # committed mock score
└── kotlin/com/keynumber/folino/screenshot/
    ├── ScreenshotTest.kt           # @RunWith(AndroidJUnit4); captureAll() device×locale×scene
    ├── ScreenshotConfig.kt         # Device{PHONE,TABLET}, ScreenshotLocale{EN,JA}
    ├── CaptureHarness.kt           # captureNode(...) wrapper around Roborazzi/captureToImage at fixed px
    ├── frame/
    │   ├── ScreenshotLayout.kt     # phone()/tablet() presets (ported)
    │   └── ScreenshotFrame.kt      # frame + title/subtitle + gradient (ported)
    ├── fixtures/
    │   ├── MarketingStrings.kt     # (scene,locale)->{title,subtitle} placeholder copy
    │   ├── MockScores.kt           # 3 mock rows + fixed UUIDs + asset staging
    │   └── ReaderSceneHost.kt      # load score -> program/parts -> ReaderSceneContent + cursor helper
    └── scenes/
        ├── Scene.kt                # Scene(id, order, content); Scenes.all
        ├── LibraryScene.kt         # #3 -> order 30 (built first as walking skeleton)
        ├── ReaderCursorScene.kt    # #1 -> order 10
        ├── DisplayHiddenScene.kt   # #2 -> order 20
        └── PipScene.kt             # #4 -> order 60
Android/fastlane/
├── Appfile
├── Fastfile
└── README.md
Android/app/build.gradle.kts        # + roborazzi plugin, androidTest deps, collectScreenshots task
```

**Scene ordering (reserves slots for deferred repeat scenes):** Reader+cursor=`10`, Display-hidden=`20`, Library=`30`, (reserved `40` whole-piece repeat, `50` AB repeat), PiP=`60`. Output filenames use the 2-digit order. This lets the two deferred scenes slot in at 40/50 later without renumbering.

---

## Task 0: Branch + emulator/native-lib readiness check

**Files:** none (environment).

- [ ] **Step 1: Confirm on the feature branch**

Run: `git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS branch --show-current`
Expected: `android-playstore-screenshots`

- [ ] **Step 2: Confirm native libs are staged**

Run: `ls Android/FolinoReaderAndroid/src/main/jniLibs/arm64-v8a Android/FolinoLibraryAndroid/src/main/jniLibs/arm64-v8a`
Expected: `.so` files present (incl. Reader JNI + `libFolinoLibraryJNI.so`). If empty/missing, run `Scripts/android-build-reader-libs.sh` and `Scripts/android-build-library-libs.sh` (see memory `project_android_build_toolchain`) before proceeding. Also confirm `FolinoLibraryAndroid/src/main/java-generated` (Wirelet codegen) exists; if not, run the gradle codegen task then the lib script (codegen → .so order matters).

- [ ] **Step 3: Confirm an emulator is booted**

Run: `adb devices`
Expected: at least one `emulator-XXXX  device`. If none, the orchestrator should ask the user to boot an AVD (prefer a large-display AVD, e.g. a tablet profile, to avoid frame clipping). Do not fabricate capture results without a device.

- [ ] **Step 4: Baseline app build sanity**

Run: `cd Android && ./gradlew :app:assembleDebug -q`
Expected: BUILD SUCCESSFUL. (Confirms the toolchain + native libs link before adding test code.)

---

## Task 1: Marketing frame primitives (ported, no app dependency)

**Files:**
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/frame/ScreenshotLayout.kt`
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/frame/ScreenshotFrame.kt`

- [ ] **Step 1: Port `ScreenshotLayout`**

Copy VocalTuner's `ScreenshotLayout.kt` verbatim, changing only `package com.keynumber.folino.screenshot.frame`. Keep `phone()`/`tablet()` presets exactly (titleTopFraction, frameAspectRatio, innerDesignWidth=393.dp/800.dp, dark gradient, etc.). Drop `AnnotationPink` only if unused (keep it — Annotation primitive is optional but harmless).

```kotlin
package com.keynumber.folino.screenshot.frame
// ... identical body to VocalTuner ScreenshotLayout.kt (data class + phone()/tablet()) ...
```

- [ ] **Step 2: Port `ScreenshotFrame`**

Copy VocalTuner's `ScreenshotFrame.kt` verbatim, changing only the package to `com.keynumber.folino.screenshot.frame`. This is the density-scaling frame (title band, subtitle band, rounded device frame, `CompositionLocalProvider(LocalDensity provides innerDensity)`). No logic change.

- [ ] **Step 3: Compile-check (deferred to Task 2's gradle wiring)**

The frame files reference only Compose APIs already on the app's classpath, but androidTest deps + the Roborazzi plugin land in Task 2. No standalone run here.

- [ ] **Step 4: Commit**

```bash
git add Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/frame/
git commit -m "feat(android-screenshots): port marketing frame primitives from VocalTuner"
```

---

## Task 2: Gradle wiring (Roborazzi plugin, androidTest deps, collectScreenshots task)

**Files:**
- Modify: `Android/app/build.gradle.kts`

- [ ] **Step 1: Add the Roborazzi plugin**

In the `plugins { }` block add:

```kotlin
id("io.github.takahirom.roborazzi") version "1.32.0"
```

- [ ] **Step 2: Add androidTest dependencies**

In `dependencies { }` add (instrumented variants — NOT `testImplementation`):

```kotlin
androidTestImplementation("androidx.test.ext:junit:1.2.1")
androidTestImplementation("androidx.test:runner:1.6.2")
androidTestImplementation("androidx.test:rules:1.6.1")
androidTestImplementation(composeBom)
androidTestImplementation("androidx.compose.ui:ui-test-junit4")
androidTestImplementation("io.github.takahirom.roborazzi:roborazzi:1.32.0")
androidTestImplementation("io.github.takahirom.roborazzi:roborazzi-compose:1.32.0")
androidTestImplementation("io.github.takahirom.roborazzi:roborazzi-android:1.32.0")
debugImplementation("androidx.compose.ui:ui-test-manifest")
```

Add the instrumentation runner to `defaultConfig`:

```kotlin
testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
```

- [ ] **Step 3: Register `collectScreenshots`**

After the `android { }` block, add (adapted from VocalTuner; depends on the instrumented capture task — for connected Roborazzi the device writes PNGs under the app's external files dir, which we pull, then sort):

```kotlin
// Copy captured PNGs into the fastlane supply tree.
//   <buildDir>/outputs/roborazzi/<deviceAlias>/<playLocale>/<NN>.png
//   -> Android/fastlane/metadata/android/<playLocale>/images/<phoneScreenshots|tenInchScreenshots>/<NN>.png
tasks.register("collectScreenshots") {
    description = "Pull device screenshots and copy into fastlane/metadata/android/<locale>/images/*"
    group = "screenshot"
    dependsOn("connectedDebugAndroidTest")
    doLast {
        val src = layout.buildDirectory.dir("outputs/roborazzi").get().asFile
        val deviceToImageDir = mapOf("phone" to "phoneScreenshots", "tablet" to "tenInchScreenshots")
        val fastlaneRoot = rootProject.file("fastlane/metadata/android")
        deviceToImageDir.forEach { (deviceAlias, imageDir) ->
            val deviceDir = src.resolve(deviceAlias)
            if (!deviceDir.exists()) return@forEach
            deviceDir.listFiles()?.filter { it.isDirectory }?.forEach { localeDir ->
                val target = fastlaneRoot.resolve("${localeDir.name}/images/$imageDir")
                target.mkdirs()
                localeDir.listFiles()?.filter { it.extension == "png" }?.forEach { png ->
                    png.copyTo(target.resolve(png.name), overwrite = true)
                }
            }
        }
        println("Screenshots collected into $fastlaneRoot")
    }
}
```

> NOTE on output location: Roborazzi connected capture writes PNGs to the device, and the Roborazzi gradle integration pulls them into `build/outputs/roborazzi`. Confirm the exact pulled path on the first real run (Task 4 Step 4) and adjust `src`/the in-test `filePath` so they agree. If the pull path differs, set the in-test path via `RoborazziRule`/`roborazzi.outputDir` accordingly.

- [ ] **Step 4: Sync/build sanity**

Run: `cd Android && ./gradlew :app:help -q`
Expected: configuration succeeds (plugin resolves). If the plugin id/version fails to resolve, confirm `pluginManagement` repositories in `settings.gradle.kts` include Maven Central / Gradle Plugin Portal.

- [ ] **Step 5: Commit**

```bash
git add Android/app/build.gradle.kts
git commit -m "build(android-screenshots): add roborazzi + androidTest deps + collectScreenshots task"
```

---

## Task 3: Scene model + config + capture harness

**Files:**
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/Scene.kt`
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/ScreenshotConfig.kt`
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/CaptureHarness.kt`

- [ ] **Step 1: `Scene` model**

```kotlin
package com.keynumber.folino.screenshot.scenes

import androidx.compose.runtime.Composable
import com.keynumber.folino.screenshot.frame.ScreenshotLayout

// One marketing scene. `order` drives the output filename. `content` renders the framed
// scene for the given device layout and language tag.
class Scene(
    val id: String,
    val order: Int,
    val content: @Composable (layout: ScreenshotLayout, tag: String) -> Unit,
)

object Scenes {
    // Populated as scenes are added (Tasks 5-8). Orders reserve 40/50 for deferred repeat scenes.
    val all: List<Scene> = listOf(
        // Scene("ReaderCursor", 10) { l, t -> ReaderCursorScene(l, t) },   // Task 6
        // Scene("DisplayHidden", 20) { l, t -> DisplayHiddenScene(l, t) }, // Task 7
        // Scene("Library", 30) { l, t -> LibraryScene(l, t) },            // Task 5
        // Scene("Pip", 60) { l, t -> PipScene(l, t) },                    // Task 8
    )
}
```

- [ ] **Step 2: `ScreenshotConfig` (phone/tablet, en/ja — no Robolectric qualifiers)**

```kotlin
package com.keynumber.folino.screenshot

import com.keynumber.folino.screenshot.frame.ScreenshotLayout

// Device classes. On a real device we cannot change screen qualifiers, so the device identity is
// entirely the marketing-frame output size (widthPx×heightPx) + the layout preset's innerDesignWidth.
enum class Device(
    val alias: String,
    val widthPx: Int,
    val heightPx: Int,
    val playDir: String,
    val layout: () -> ScreenshotLayout,
) {
    PHONE("phone", 1080, 1920, "phoneScreenshots", { ScreenshotLayout.phone() }),
    TABLET("tablet", 1280, 1920, "tenInchScreenshots", { ScreenshotLayout.tablet() }),
}

// Locales we ship screenshots for. `tag` is passed to MarketingStrings; `playLocale` is the dir name.
enum class ScreenshotLocale(val tag: String, val playLocale: String) {
    EN("en", "en-US"),
    JA("ja", "ja-JP"),
}
```

> NOTE: TABLET heightPx/widthPx (1280×1920) chosen to fit common AVD displays while keeping a 2:3-ish tablet aspect; raise toward 1600×2560 if the booted AVD is large enough. Play Console accepts 320–3840 px per side.

- [ ] **Step 3: `CaptureHarness` — capture a composable at a fixed pixel size**

```kotlin
package com.keynumber.folino.screenshot

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.captureRoboImage

// Renders `content` inside a Box sized to exactly (widthPx × heightPx) device pixels by forcing a
// density of 1.0 for the wrapper (so 1.dp == 1px at this level; the frame's own inner density
// override still scales the app subtree). Captures the root node to `filePath`.
fun ComposeContentTestRule.captureFixedSize(
    widthPx: Int,
    heightPx: Int,
    filePath: String,
    content: @Composable () -> Unit,
) {
    setContent {
        CompositionLocalProvider(LocalDensity provides Density(density = 1f, fontScale = 1f)) {
            Box(modifier = Modifier.size(widthPx.dp, heightPx.dp)) { content() }
        }
    }
    onRoot().captureRoboImage(filePath = filePath)
}
```

> NOTE: `CompositionLocalProvider` import is `androidx.compose.runtime.CompositionLocalProvider`. The density=1f trick maps `widthPx.dp` to `widthPx` device-independent units that, at this provided density, equal pixels — making the captured bitmap exactly widthPx×heightPx independent of the AVD's real density. Confirm the captured PNG dimensions on first run; if Roborazzi captures at the device's real density instead, switch to Roborazzi's size option (`RoborazziComposeOptions.sizeDp`) or capture via `captureToImage()` on the sized node.

- [ ] **Step 4: Compile-check**

Run: `cd Android && ./gradlew :app:compileDebugAndroidTestKotlin -q`
Expected: BUILD SUCCESSFUL (no scenes referenced yet; `Scenes.all` empty).

- [ ] **Step 5: Commit**

```bash
git add Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/Scene.kt \
        Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/ScreenshotConfig.kt \
        Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/CaptureHarness.kt
git commit -m "feat(android-screenshots): scene model, device/locale config, fixed-size capture harness"
```

---

## Task 4: Marketing strings + ScreenshotTest skeleton + first empty run

**Files:**
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/fixtures/MarketingStrings.kt`
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/ScreenshotTest.kt`

- [ ] **Step 1: `MarketingStrings` with placeholder copy (en/ja) per scene**

```kotlin
package com.keynumber.folino.screenshot.fixtures

// Placeholder marketing copy per scene, keyed by language tag. TODO(copy): replace with final
// store copy before release — these are intentionally provisional ("仮").
data class SceneCopy(val title: String, val subtitle: String?)

object MarketingStrings {
    // sceneId -> tag -> copy
    private val table: Map<String, Map<String, SceneCopy>> = mapOf(
        "ReaderCursor" to mapOf(
            "en" to SceneCopy("Read your scores", "Follow along as the music plays"),
            "ja" to SceneCopy("楽譜を表示", "再生に合わせて自動で追従"),
        ),
        "DisplayHidden" to mapOf(
            "en" to SceneCopy("Show only the parts you want", "Hide any staff with a tap"),
            "ja" to SceneCopy("見たいパートだけ表示", "不要な段はタップで非表示"),
        ),
        "Library" to mapOf(
            "en" to SceneCopy("Your whole library", "All your scores in one place"),
            "ja" to SceneCopy("あなたの楽譜棚", "すべての楽譜をひとつに"),
        ),
        "Pip" to mapOf(
            "en" to SceneCopy("Keep playing anywhere", "Picture-in-picture playback"),
            "ja" to SceneCopy("ながら再生", "ピクチャinピクチャで再生"),
        ),
    )

    fun forScene(sceneId: String, tag: String): SceneCopy =
        table[sceneId]?.get(tag) ?: table[sceneId]?.get("en") ?: SceneCopy(sceneId, null)
}
```

- [ ] **Step 2: `ScreenshotTest` (instrumented, AndroidJUnit4)**

```kotlin
package com.keynumber.folino.screenshot

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.keynumber.folino.screenshot.scenes.Scenes
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

// Captures every Device × Locale × Scene combination on the connected device.
// Output (in-test path): outputs/roborazzi/<device.alias>/<locale.playLocale>/<NN>.png
@RunWith(AndroidJUnit4::class)
class ScreenshotTest {

    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun captureAll() {
        for (device in Device.entries) {
            for (locale in ScreenshotLocale.entries) {
                for (scene in Scenes.all) {
                    val order = scene.order.toString().padStart(2, '0')
                    val path = "outputs/roborazzi/${device.alias}/${locale.playLocale}/$order.png"
                    composeRule.captureFixedSize(device.widthPx, device.heightPx, path) {
                        scene.content(device.layout(), locale.tag)
                    }
                }
            }
        }
    }
}
```

> NOTE: a single `createComposeRule` may not allow multiple `setContent` calls across iterations. If the second `setContent` throws, restructure to one capture per `@Test` (parameterized) or recreate the content via the rule's activity per iteration. Resolve this on the first run (Step 4). With `Scenes.all` empty, the loop is a no-op and the test passes trivially — proving the harness wiring before any scene exists.

- [ ] **Step 3: Compile-check**

Run: `cd Android && ./gradlew :app:compileDebugAndroidTestKotlin -q`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: First on-device run (empty scene list)**

Run: `cd Android && ./gradlew :app:connectedDebugAndroidTest -q`
Expected: test `captureAll` runs and PASSES (no captures yet). This proves the instrumented harness + Roborazzi connected setup work on the emulator before adding real scenes. If it fails on Roborazzi setup, fix here (output dir config, manifest, runner) while there's no scene complexity.

- [ ] **Step 5: Commit**

```bash
git add Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/fixtures/MarketingStrings.kt \
        Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/ScreenshotTest.kt
git commit -m "feat(android-screenshots): marketing strings + instrumented ScreenshotTest skeleton"
```

---

## Task 5: Walking skeleton — Library scene (#3, order 30)

This is the lowest-native-risk scene (no sheet rendering): seed Room, render real `LibraryScreen`. It proves the full pipeline end to end (seed → real composable → frame → capture → collect → fastlane tree).

**Files:**
- Create: `Android/app/src/androidTest/assets/Now_is_the_time.mscz`
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/fixtures/MockScores.kt`
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/LibraryScene.kt`
- Modify: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/Scene.kt`

- [ ] **Step 1: Stage the mock score asset**

```bash
cp ~/Desktop/Now_is_the_time.mscz Android/app/src/androidTest/assets/Now_is_the_time.mscz
```

- [ ] **Step 2: `MockScores` — fixed ids + the three rows + filesDir/Room seeding**

```kotlin
package com.keynumber.folino.screenshot.fixtures

import android.content.Context
import java.io.File

// Three deterministic mock library rows derived from the bundled Now_is_the_time.mscz.
// Fixed UUIDs keep capture output stable across runs. The mscz asset is copied into
// filesDir/Scores/<id>.mscz for each; metadata is seeded directly into folino-library.db.
object MockScores {
    data class Mock(val id: String, val title: String, val composer: String)

    val all = listOf(
        Mock("00000000-0000-0000-0000-0000000000a1", "Now is the time", "Trad."),
        Mock("00000000-0000-0000-0000-0000000000a2", "アタタメマスカ", ""),          // composer cleared
        Mock("00000000-0000-0000-0000-0000000000a3", "Looks_Good_To_Me", "K. Ito"),
    )

    // Copies the test asset into filesDir/Scores/<id>.mscz for every mock row.
    fun stageScoreFiles(context: Context) {
        val scoresDir = File(context.filesDir, "Scores").apply { mkdirs() }
        context.assets.open("Now_is_the_time.mscz").use { input ->
            val bytes = input.readBytes()
            all.forEach { mock ->
                File(scoresDir, "${mock.id}.mscz").writeBytes(bytes)
            }
        }
    }
}
```

- [ ] **Step 3: `LibraryScene` — seed Room + render real `LibraryScreen` in the frame**

Construct a `RoomLibraryStore` against the app context, upsert the three rows (as `ScoreRecordWire`), stage files, build a `LibraryAndroidStoreViewModel` via `.create(store, pdfRenderer, audioExporter)`, and render `LibraryScreen` inside `ScreenshotFrame`. The pdfRenderer/audioExporter adapters: pass the app's real implementations if cheaply constructible, otherwise minimal no-op fakes implementing those Domain protocols (they are not exercised by a static Library list capture).

```kotlin
package com.keynumber.folino.screenshot.scenes

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import com.keynumber.folino.screenshot.fixtures.MockScores
import com.keynumber.folino.screenshot.frame.ScreenshotFrame
import com.keynumber.folino.screenshot.frame.ScreenshotLayout
import com.keynumber.folino.ui.library.LibraryScreen
import com.keynumber.folino.ui.theme.FolinoTheme
// + imports for RoomLibraryStore, ScoreRecordWire, LibraryAndroidStoreViewModel, fakes

@Composable
fun LibraryScene(layout: ScreenshotLayout, tag: String) {
    val copy = MarketingStrings.forScene("Library", tag)
    val context = LocalContext.current
    val viewModel = remember {
        MockScores.stageScoreFiles(context)
        val store = RoomLibraryStore(context)            // confirm constructor (context)
        MockScores.all.forEach { m ->
            store.upsert(
                ScoreRecordWire(
                    id = m.id, title = m.title, subtitle = "", composer = m.composer,
                    arranger = null, lyricist = null, copyright = null,
                    localFileName = "${m.id}.mscz", contentHash = "",
                    deletedAt = 0.0, lastOpenedAt = 0.0, isFavorite = false,
                ),
            )
        }
        LibraryAndroidStoreViewModel.create(store, NoopPdfRenderer, NoopAudioExporter)
    }
    ScreenshotFrame(title = copy.title, subtitle = copy.subtitle, layout = layout) {
        FolinoTheme {
            LibraryScreen(
                viewModel = viewModel,
                onOpenScore = {},
                onOpenDrawer = {},
                onEditInfoForScore = {},
            )
        }
    }
}
```

> Confirm on device: `RoomLibraryStore` constructor signature, the exact `ScoreRecordWire` field set, and the `ScorePdfRenderer`/`ScoreAudioFileExporter` interfaces to stub (`NoopPdfRenderer`/`NoopAudioExporter`). If `LibraryScreen` shows a top app bar/drawer affordance, that's acceptable (it reads as the real Library top). If the wire row also needs `deletedAt` as a sentinel for "not deleted", use the same value the app uses for live rows (check `RoomLibraryStore` upsert/query).

- [ ] **Step 4: Register the scene**

In `Scene.kt`, add to `Scenes.all`:

```kotlin
Scene("Library", 30) { l, t -> LibraryScene(l, t) },
```

- [ ] **Step 5: Run + verify the PNGs**

Run: `cd Android && ./gradlew :app:connectedDebugAndroidTest -q`
Expected: PASS. Then pull/inspect: 4 PNGs (phone/tablet × en/ja) named `30.png`.
Run: `cd Android && ./gradlew :app:collectScreenshots -q`
Expected: PNGs copied to `Android/fastlane/metadata/android/{en-US,ja-JP}/images/{phoneScreenshots,tenInchScreenshots}/30.png`.
Visually confirm (Read the PNG): three rows; `アタタメマスカ` shows **no composer**; framed with title/subtitle.

- [ ] **Step 6: Commit**

```bash
git add Android/app/src/androidTest/assets/Now_is_the_time.mscz \
        Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/fixtures/MockScores.kt \
        Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/LibraryScene.kt \
        Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/Scene.kt
git commit -m "feat(android-screenshots): Library scene (walking skeleton) end to end"
```

---

## Task 6: Reader scene host + Reader+cursor scene (#1, order 10)

**Files:**
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/fixtures/ReaderSceneHost.kt`
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/ReaderCursorScene.kt`
- Modify: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/Scene.kt`

- [ ] **Step 1: `ReaderSceneHost` — load a score to a renderable program + static cursor**

Responsibilities: install SMuFL metrics, `ScoreHandle.load` the bundled asset, compute the `DrawProgram` for given `LayoutOptions`, expose `page`, `scoreHandle.raw`, `parts`, and a helper to build a static `ScoreCursor` at the first measure's middle. Reuse `ReaderViewModel` where possible (it already does install + load + parts + program); create one, call `load(scoreId)` after staging the file, `setLayoutOptions(options)`, and collect `state` until `ReaderState.Ready` to get `.program`. Render via a copy of `ReadyScore` (call it `ReaderSceneContent`) that takes an injected `cursorFlow: StateFlow<ScoreCursor?>` instead of `audioVm.currentCursor`, and a fixed `scale = 1f` with scroll pinned to top (no gestures needed in a static frame).

```kotlin
// Sketch — confirm exact ReaderState.Ready shape + program type on device.
@Composable
fun ReaderSceneContent(
    page: <DrawProgram.Page>,
    scoreHandleRaw: Long,
    fontProvider: FontProvider,
    cursorFlow: StateFlow<ScoreCursor?>,
) {
    // identical layout math to ReadyScore (fitPxPerMM from viewport, vPad), but:
    //  - no pointerInput gesture blocks
    //  - PlaybackCursorOverlay(cursorFlow = cursorFlow, ...)
}
```

Cursor construction helper (pure JNI, no engine):

```kotlin
// After the page is laid out at a known viewport width, a tap at the first measure's mid-point maps
// to a cursor via nearestCursorForTap. For a deterministic point, use a fraction of the first
// system's first measure. Confirm on device; fall back to a JNI "first cursor" if available.
fun firstMeasureMidCursor(
    scoreHandleRaw: Long,
    layoutOptions: LayoutOptions,
    pxPerMM: Float,
    viewportWidthPx: Int,
): ScoreCursor? = nearestCursorForTap(
    tap = Offset(viewportWidthPx * 0.12f, /* first-system y */ 80f),
    contentOffsetPx = Offset.Zero,
    pxPerMM = pxPerMM,
    scale = 1f,
    scoreHandle = scoreHandleRaw,
    layoutOptionsBytes = layoutOptions.encode(),
)
```

> The tap coordinates are heuristic. On the first run, Read the PNG and nudge the fraction until the cursor sits ~mid first measure. If `nearestCursorForTap` returns null at the guessed point, sweep x in [0.05..0.25] / adjust y to the first staff line. Keep the helper here so only one place needs tuning.

- [ ] **Step 2: `ReaderCursorScene`**

```kotlin
@Composable
fun ReaderCursorScene(layout: ScreenshotLayout, tag: String) {
    val copy = MarketingStrings.forScene("ReaderCursor", tag)
    ScreenshotFrame(title = copy.title, subtitle = copy.subtitle, layout = layout) {
        FolinoTheme {
            ReaderSceneHost(layoutOptions = LayoutOptions.DEFAULT, withCursorAtFirstMeasure = true)
        }
    }
}
```

`ReaderSceneHost` internally loads the score, builds the cursor (when `withCursorAtFirstMeasure`), and renders `ReaderSceneContent`.

- [ ] **Step 3: Register the scene** (`Scene.kt`): `Scene("ReaderCursor", 10) { l, t -> ReaderCursorScene(l, t) },`

- [ ] **Step 4: Run + verify**

Run: `cd Android && ./gradlew :app:connectedDebugAndroidTest -q`
Expected: PASS; `10.png` set produced. Read a PNG: score renders (all staves), cursor visible ~middle of measure 1, framed with title/subtitle.

- [ ] **Step 5: Commit**

```bash
git add Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/fixtures/ReaderSceneHost.kt \
        Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/ReaderCursorScene.kt \
        Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/Scene.kt
git commit -m "feat(android-screenshots): Reader scene host + Reader+cursor scene"
```

---

## Task 7: Display inspector + hidden staves scene (#2, order 20)

**Files:**
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/DisplayHiddenScene.kt`
- Modify: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/Scene.kt`

- [ ] **Step 1: Build hidden-staves options from the score's real parts**

Reuse `ReaderSceneHost`'s loaded `parts` to find the addresses of the 2nd/3rd/4th staves (flatten `parts.flatMap { it.staves }`, take indices 1,2,3 of the flattened list, use their `.address`). Build `LayoutOptions.DEFAULT.copy(hiddenStaves = those addresses)`.

```kotlin
val staves = parts.flatMap { it.staves }
val hidden = listOf(1, 2, 3).mapNotNull { staves.getOrNull(it)?.address }.toSet()
val options = LayoutOptions.DEFAULT.copy(hiddenStaves = hidden)
```

- [ ] **Step 2: Compose Reader (with hidden staves) + DisplayInspectorSheet open on top**

```kotlin
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DisplayHiddenScene(layout: ScreenshotLayout, tag: String) {
    val copy = MarketingStrings.forScene("DisplayHidden", tag)
    ScreenshotFrame(title = copy.title, subtitle = copy.subtitle, layout = layout) {
        FolinoTheme {
            val host = rememberReaderSceneState(LayoutOptions.DEFAULT) // loads score + parts + program
            val hidden = remember(host.parts) {
                val staves = host.parts.flatMap { it.staves }
                listOf(1, 2, 3).mapNotNull { staves.getOrNull(it)?.address }.toSet()
            }
            val options = LayoutOptions.DEFAULT.copy(hiddenStaves = hidden)
            Box {
                ReaderSceneContentFor(host, options)   // background: score with 2/3/4 hidden
                val sheetState = rememberStandardBottomSheetState(initialValue = SheetValue.Expanded)
                DisplayInspectorSheet(
                    options = options,
                    parts = host.parts,
                    sheetState = sheetState,
                    onDismiss = {},
                    onChange = {},
                )
            }
        }
    }
}
```

> Resolve on device: `DisplayInspectorSheet` uses `ModalBottomSheet`; capturing it expanded should show the Parts rows with staves 2/3/4 as `VisibilityOff`. If the modal renders with a dimmed scrim that hides the score too much, either accept the scrim (it reads as a real inspector) or extract the sheet's inner content into a public `@Composable DisplayInspectorContent(...)` and render that in a `Surface` aligned to the bottom. Prefer the real sheet first; only extract if the static capture looks wrong. If extraction is needed, that's a minimal, justified production seam — add it in `DisplayInspectorSheet.kt` and reuse it from the sheet itself (DRY).

- [ ] **Step 3: Register** (`Scene.kt`): `Scene("DisplayHidden", 20) { l, t -> DisplayHiddenScene(l, t) },`

- [ ] **Step 4: Run + verify**

Run: `cd Android && ./gradlew :app:connectedDebugAndroidTest -q`
Expected: PASS; `20.png` set. Read a PNG: inspector open at the bottom; Parts list shows staves 2/3/4 toggled off; the score behind shows those staves removed.

- [ ] **Step 5: Commit**

```bash
git add Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/DisplayHiddenScene.kt \
        Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/Scene.kt
# include DisplayInspectorSheet.kt only if a content seam was extracted
git commit -m "feat(android-screenshots): display inspector + hidden-staves scene"
```

---

## Task 8: PiP-style scene (#4, order 60)

**Files:**
- Create: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/PipScene.kt`
- Modify: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/Scene.kt`

- [ ] **Step 1: Faux launcher background**

A bespoke Compose home screen: a wallpaper-ish vertical gradient, a 4×N grid of rounded app-icon placeholders with short labels, and a faux status bar row (time + a couple of icons). No system PiP — this is a still image. Keep it generic (no real branding) so it reads as "a phone home screen".

- [ ] **Step 2: Floating PiP card with only staves 2/3/4 visible**

Compute `hiddenStaves` as the COMPLEMENT of staves 2/3/4: hide staff index 0 and indices 4+ of the flattened staves list, keep 1/2/3 visible.

```kotlin
val staves = host.parts.flatMap { it.staves }
val visibleIdx = setOf(1, 2, 3)
val hidden = staves.indices.filter { it !in visibleIdx }.mapNotNull { staves.getOrNull(it)?.address }.toSet()
val options = LayoutOptions.DEFAULT.copy(hiddenStaves = hidden)
```

Render `ReaderSceneContentFor(host, options)` inside a rounded, shadowed `Surface` sized to a PiP-like aspect ratio (e.g. 16:9 or the Reader's natural A4-width/system-height), positioned bottom-end over the launcher, with a small translucent transport-control row (play/pause + skip icons) to read as PiP.

```kotlin
@Composable
fun PipScene(layout: ScreenshotLayout, tag: String) {
    val copy = MarketingStrings.forScene("Pip", tag)
    ScreenshotFrame(title = copy.title, subtitle = copy.subtitle, layout = layout) {
        Box {
            FauxHomeScreen()
            val host = rememberReaderSceneState(LayoutOptions.DEFAULT)
            // ... compute options (only 2/3/4 visible) ...
            PipCard(modifier = Modifier.align(Alignment.BottomEnd)) {
                FolinoTheme { ReaderSceneContentFor(host, options) }
            }
        }
    }
}
```

- [ ] **Step 3: Register** (`Scene.kt`): `Scene("Pip", 60) { l, t -> PipScene(l, t) },`

- [ ] **Step 4: Run + verify**

Run: `cd Android && ./gradlew :app:connectedDebugAndroidTest -q`
Expected: PASS; `60.png` set. Read a PNG: faux home screen with a floating PiP card showing only staves 2/3/4, transport controls visible, framed.

- [ ] **Step 5: Commit**

```bash
git add Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/PipScene.kt \
        Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/scenes/Scene.kt
git commit -m "feat(android-screenshots): PiP-style faux-home scene"
```

---

## Task 9: Fastlane supply config + README + full pipeline run

**Files:**
- Create: `Android/fastlane/Appfile`
- Create: `Android/fastlane/Fastfile`
- Create: `Android/fastlane/README.md`

- [ ] **Step 1: `Appfile`** (env-driven, no secrets committed)

```ruby
package_name(ENV.fetch("PLAY_PACKAGE_NAME", "com.keynumber.folino"))
json_key_file(ENV.fetch("PLAY_JSON_KEY_PATH", ""))
```

- [ ] **Step 2: `Fastfile`** — `upload_screenshots` lane (images only)

Adapt VocalTuner's Fastfile: keep the `upload_screenshots` lane (and `download_metadata`/`upload_metadata` if useful). Default `applicationId` `com.keynumber.folino`.

```ruby
default_platform(:android)
platform :android do
  desc "Upload only the Play Store screenshots (no binary, no metadata, no changelog)"
  lane :upload_screenshots do
    upload_to_play_store(
      track: ENV.fetch("PLAY_TRACK", "internal"),
      skip_upload_apk: true, skip_upload_aab: true,
      skip_upload_metadata: true, skip_upload_changelogs: true,
      skip_upload_images: false, skip_upload_screenshots: false,
      validate_only: ENV["PLAY_VALIDATE_ONLY"] == "1",
    )
  end
end
```

- [ ] **Step 3: `README.md`** — document the run

Document: prerequisites (booted AVD, staged native libs), `./gradlew :app:collectScreenshots`, output location, the deferred repeat scenes (orders 40/50), and the manual upload (`PLAY_PACKAGE_NAME=… PLAY_JSON_KEY_PATH=… PLAY_VALIDATE_ONLY=1 bundle exec fastlane android upload_screenshots`).

- [ ] **Step 4: Full pipeline run**

Run: `cd Android && ./gradlew :app:collectScreenshots -q`
Expected: all 16 PNGs (4 scenes × 2 locales × 2 devices) land under `Android/fastlane/metadata/android/{en-US,ja-JP}/images/{phoneScreenshots,tenInchScreenshots}/{10,20,30,60}.png`.

- [ ] **Step 5: Commit**

```bash
git add Android/fastlane/
git commit -m "build(android-screenshots): fastlane supply config + README"
```

> NOTE: `.gitignore` the generated PNGs under `fastlane/metadata/android/**/images/` if the team prefers not to commit binaries; otherwise commit them as the canonical store assets. Decide with the user; default to gitignoring the generated images and committing only config.

---

## Self-review

**Spec coverage:**
- Scene #1 Reader+cursor → Task 6. ✓
- Scene #2 display inspector + hidden staves → Task 7. ✓
- Scene #3 Library + mock dups (アタタメマスカ composer blank, Looks_Good_To_Me) → Task 5. ✓
- Scene #4 PiP-style, only staves 2/3/4 visible → Task 8. ✓
- Marketing frame + placeholder title/subtitle → Tasks 1,4. ✓
- ja+en × phone+tablet (16 PNGs) → Tasks 3,4,9. ✓
- fastlane output tree → Tasks 2,9. ✓
- Deferred repeat scenes reserved at orders 40/50 → Task 3 (Scenes) + README. ✓
- Mock from ~/Desktop/Now_is_the_time.mscz, committed → Task 5. ✓

**Placeholder scan:** Remaining `<DrawProgram.Page>` / `rememberReaderSceneState` / `ReaderSceneContentFor` are named seams whose concrete types are confirmed against the library on first device build (the program type is internal to the sheet-music lib and only reachable via `ReaderState.Ready`); they are flagged as "confirm on device", not silent TODOs. All deterministic code (frame, gradle, config, library scene, fastlane) is concrete.

**Type consistency:** `LayoutOptions`, `StaffAddress`, `ScoreRowWire`, `ScoreRecordWire`, `Scene`, `Device`, `ScreenshotLocale`, `MarketingStrings.forScene` are used consistently across tasks. Scene orders (10/20/30/60) match between Scene registration and verification steps.

**Risk register (resolve during execution, not blockers to planning):**
1. Roborazzi connected-mode output path + fixed-size node capture (Task 3/4 NOTE) — proven by the empty run before any scene.
2. Multiple `setContent` per `createComposeRule` (Task 4 NOTE) — restructure to per-test if needed.
3. `nearestCursorForTap` coordinate tuning (Task 6) — Read PNG + nudge.
4. `ModalBottomSheet` static capture vs. content-seam extraction (Task 7).
5. AVD display size vs. tablet canvas (Task 3 NOTE) — shrink canvas or use a large AVD.
```

# Android Reader Picture-in-Picture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the Android Reader shrink into a system Picture-in-Picture window that keeps showing the score with the playback cursor following along, plus play/pause and ±10s controls — matching the iOS PiP feature.

**Architecture:** Android PiP is *activity-based* (the Activity shrinks into a floating window), not iOS's custom CVPixelBuffer/`AVSampleBufferDisplayLayer` rendering. We add a process-scoped coordinator (`ReaderPipController`) that `ReaderScreen` (FolinoReaderAndroid) and `MainActivity` (app) share. When PiP mode turns on, `ReaderScreen` swaps to a minimal `ReaderPipContent` that reuses the existing `HorizontalScore` composable (score + `PlaybackCursorOverlay` + JNI auto-scroll). Playback already survives via the foreground `ReaderPlaybackService` (`MediaSessionService`). No new native (`.so`) symbols.

**Tech Stack:** Kotlin, Jetpack Compose (Material3), Android `PictureInPictureParams` / `RemoteAction` / `BroadcastReceiver`, DataStore (existing `SettingsPrefs.pip`), JUnit4 (new, for one pure function).

---

## Background facts (verified in the codebase)

- **Reader entry point:** `ReaderScreen(...)` is invoked at `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt:296`, inside the `reader/{id}/{title}` route of `LibraryNavGraph`'s nested `NavHost`. `MainActivity` is a single `ComponentActivity` (`MainActivity.kt:74`).
- **PiP setting already persisted:** `SettingsPrefs.pip: Flow<Boolean>` (`reader.pictureInPicture.enabled`, default `false`) and `setPip(Boolean)` already exist (`Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt:17,46,59`). The Settings UI toggle row also already exists (`SettingsScreen.kt`, "Picture in Picture"). **No settings work needed.**
- **Playback API (verified):** via `audioVm.engine: StateFlow<AndroidPlaybackEngine?>`. `engine.play()`, `engine.pause()`, `engine.seek(toTimeSeconds: Double)` are used in `ReaderScreen.kt`'s `TransportBar`. Observables on `ReaderAudioViewModel`: `state: StateFlow<PlaybackState>`, `currentTimeSeconds`, `totalTimeSeconds`, `currentCursor` (`ReaderAudioViewModel.kt:58-72`). **A `skip(...)` method is NOT confirmed on the engine — implement ±10s as `seek(current ± 10, clamped to [0,total])`.**
- **Horizontal rendering to reuse:** `HorizontalScore(state, scoreHandle, fontProvider, audioVm, layoutOptions)` (`ReaderScreen.kt:441`) renders `ScorePage` + `PlaybackCursorOverlay` + auto-scroll. It reads `state.program.pages.first()`.
- **Layout compute:** `ReaderViewModel` computes one `DrawProgram` from the current `layoutOptions` via `SheetMusicJNI.nativeComputeLayout(handle, PAGE_WIDTH_MM, PAGE_HEIGHT_MM, opts.encode())` (`ReaderViewModel.kt:86`). Layout *mode* is carried inside the options blob (`LayoutOptions.encode()`, `VERTICAL/HORIZONTAL/PAGE -> 0/1/2`, `LayoutOptions.kt:36-40`). `ReaderState.Ready(val program: DrawProgram)` is a public data class (`ReaderState.kt:8`).
- **Audio survives PiP:** playback is owned by `ReaderPlaybackService` (foreground `MediaSessionService`), bound by `ReaderAudioViewModel` — independent of the composable/Activity lifecycle.
- **No JVM unit tests exist yet.** `FolinoReaderAndroid/build.gradle.kts` has no `testImplementation`.
- **App build/run commands:**
  - Build+install: `Android/gradlew -p Android :app:installDebug`
  - Launch: `adb shell am start -n com.keynumber.folino/.MainActivity`
  - Reader-module unit tests: `Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest`

> **Worktree note:** This is pure Kotlin (no `.so` regeneration). If implementing in a fresh worktree, copy `Android/FolinoReaderAndroid/src/main/jniLibs/` and `Android/FolinoReaderAndroid/src/main/java-generated/` (and the equivalents for other modules) from the primary checkout so Gradle can link, per project convention. No `Scripts/android-build-*.sh` run is required because no native source changed.

## File structure

| File | Module | Create/Modify | Responsibility |
| --- | --- | --- | --- |
| `reader/PipAspect.kt` | FolinoReaderAndroid | Create | Pure `pipAspectClamped(staffCount): Double` — iOS heuristic clamped to Android's `[1.0, 2.39]`. |
| `reader/PipAspectTest.kt` (`src/test/...`) | FolinoReaderAndroid | Create | JUnit test for `pipAspectClamped`. |
| `FolinoReaderAndroid/build.gradle.kts` | FolinoReaderAndroid | Modify | Add `testImplementation("junit:junit:4.13.2")`. |
| `reader/ReaderPipController.kt` | FolinoReaderAndroid | Create | Process-scoped coordinator: `isInPipMode`, `eligible`, `isPlaying`, `staffCount` StateFlows + `onTogglePlayPause`/`onSkip` callbacks + `PipHost` interface + `Context.findActivity()`. |
| `reader/ReaderViewModel.kt` | FolinoReaderAndroid | Modify | Add `suspend fun horizontalProgram(): DrawProgram?`. |
| `reader/ReaderPipContent.kt` | FolinoReaderAndroid | Create | Minimal PiP composable: compute horizontal program, render `HorizontalScore` with no chrome. |
| `reader/ReaderScreen.kt` | FolinoReaderAndroid | Modify | `internal` `HorizontalScore`; add `pipEnabled` param; publish controller state + transport hooks; switch to `ReaderPipContent` in PiP; toolbar PiP button. |
| `MainActivity.kt` | app | Modify | Pass `pipEnabled`; implement `PipHost`; PiP lifecycle (`onUserLeaveHint`, `onPictureInPictureModeChanged`); keep params current; register receiver. |
| `ReaderPipIntegration.kt` | app | Create | `ReaderPipActions` constants, `buildPipParams(...)`, `PipActionReceiver`. |
| `app/src/main/AndroidManifest.xml` | app | Modify | `supportsPictureInPicture` + `configChanges` on `MainActivity`. |

---

### Task 1: PiP aspect-ratio pure function (TDD)

**Files:**
- Modify: `Android/FolinoReaderAndroid/build.gradle.kts:32-57` (add test dep)
- Create: `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/PipAspectTest.kt`
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PipAspect.kt`

- [ ] **Step 1: Add the JUnit test dependency**

In `Android/FolinoReaderAndroid/build.gradle.kts`, add to the `dependencies { ... }` block (after line 56):

```kotlin
    testImplementation("junit:junit:4.13.2")
```

- [ ] **Step 2: Write the failing test**

Create `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/PipAspectTest.kt`:

```kotlin
package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Test

class PipAspectTest {
    @Test fun singleStaffClampsToAndroidMax() {
        // iOS heuristic 6.0/1 = 6.0, clamped to Android's 2.39 max.
        assertEquals(2.39, pipAspectClamped(1), 1e-9)
    }

    @Test fun twoStavesClampToAndroidMax() {
        // 6.0/2 = 3.0 -> clamped to 2.39.
        assertEquals(2.39, pipAspectClamped(2), 1e-9)
    }

    @Test fun threeStavesStaysBelowMax() {
        // 6.0/3 = 2.0, within range.
        assertEquals(2.0, pipAspectClamped(3), 1e-9)
    }

    @Test fun sixStavesIsSquare() {
        // 6.0/6 = 1.0 (the iOS lower clamp).
        assertEquals(1.0, pipAspectClamped(6), 1e-9)
    }

    @Test fun manyStavesClampToOne() {
        // 6.0/12 = 0.5 -> clamped up to 1.0.
        assertEquals(1.0, pipAspectClamped(12), 1e-9)
    }

    @Test fun zeroOrNegativeTreatedAsOneStaff() {
        assertEquals(2.39, pipAspectClamped(0), 1e-9)
        assertEquals(2.39, pipAspectClamped(-5), 1e-9)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails (unresolved reference)**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --tests "com.keynumber.folino.reader.PipAspectTest"`
Expected: FAIL — compilation error `unresolved reference: pipAspectClamped`.

- [ ] **Step 4: Implement the function**

Create `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PipAspect.kt`:

```kotlin
package com.keynumber.folino.reader

/**
 * Android PiP windows accept an aspect ratio (width / height) within roughly `[1/2.39, 2.39]`;
 * values outside throw from `PictureInPictureParams.setAspectRatio`.
 */
const val PIP_MAX_ASPECT = 2.39

/**
 * PiP window aspect ratio (width / height) from the score's staff count, mirroring the iOS
 * heuristic (`6.0 / staffCount`, clamped to `1.0…6.0`) and then clamped into Android's allowed
 * range. Wide single-system scores sit at the max; busier scores get a squarer window.
 */
fun pipAspectClamped(staffCount: Int): Double {
    val staves = staffCount.coerceAtLeast(1)
    val ios = (6.0 / staves).coerceIn(1.0, 6.0)
    return ios.coerceIn(1.0 / PIP_MAX_ASPECT, PIP_MAX_ASPECT)
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --tests "com.keynumber.folino.reader.PipAspectTest"`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add Android/FolinoReaderAndroid/build.gradle.kts \
        Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/PipAspectTest.kt \
        Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PipAspect.kt
git commit -m "feat(android-pip): pip aspect-ratio heuristic + unit test"
```

---

### Task 2: ReaderPipController coordinator + PipHost

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderPipController.kt`

- [ ] **Step 1: Create the coordinator**

Create `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderPipController.kt`:

```kotlin
package com.keynumber.folino.reader

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Process-scoped bridge between the Reader screen (FolinoReaderAndroid) and the Activity (app),
 * which can't see each other's view models directly. The Reader publishes PiP *eligibility*,
 * playback state, staff count, and transport callbacks while it is on screen; `MainActivity`
 * reads them to build `PictureInPictureParams` and to route in-window RemoteAction taps.
 *
 * Android PiP keeps the Activity alive, so a process singleton is the right scope. Callbacks and
 * flags are cleared via [reset] when the Reader leaves composition to avoid stale transport hooks.
 */
object ReaderPipController {
    private val _isInPipMode = MutableStateFlow(false)
    /** True while the system shows the Activity in a PiP window. Set by `MainActivity`. */
    val isInPipMode: StateFlow<Boolean> = _isInPipMode.asStateFlow()
    fun setInPipMode(value: Boolean) { _isInPipMode.value = value }

    private val _eligible = MutableStateFlow(false)
    /** True when the Reader is on screen, PiP is enabled, and playback is playing. */
    val eligible: StateFlow<Boolean> = _eligible.asStateFlow()
    fun setEligible(value: Boolean) { _eligible.value = value }

    private val _isPlaying = MutableStateFlow(false)
    /** Drives the in-window play/pause glyph. */
    val isPlaying: StateFlow<Boolean> = _isPlaying.asStateFlow()
    fun setPlaying(value: Boolean) { _isPlaying.value = value }

    private val _staffCount = MutableStateFlow(2)
    /** Total staff count of the open score; drives the PiP window aspect ratio. */
    val staffCount: StateFlow<Int> = _staffCount.asStateFlow()
    fun setStaffCount(value: Int) { _staffCount.value = value }

    /** Toggle play/pause on the live engine. Registered by the Reader; invoked by the receiver. */
    @Volatile var onTogglePlayPause: (() -> Unit)? = null

    /** Seek by a signed delta in seconds (±10s), clamped by the Reader. */
    @Volatile var onSkip: ((Double) -> Unit)? = null

    /** Clear transport hooks + eligibility when the Reader leaves the screen. */
    fun reset() {
        onTogglePlayPause = null
        onSkip = null
        _eligible.value = false
        _isPlaying.value = false
    }
}

/** Implemented by the host Activity so the Reader's toolbar button can enter PiP immediately. */
interface PipHost {
    fun enterPipNow()
}

/** Walk the context wrappers to the hosting Activity (for the toolbar PiP button). */
fun Context.findActivity(): Activity? {
    var ctx: Context? = this
    while (ctx is ContextWrapper) {
        if (ctx is Activity) return ctx
        ctx = ctx.baseContext
    }
    return null
}
```

- [ ] **Step 2: Compile-check the module**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderPipController.kt
git commit -m "feat(android-pip): ReaderPipController coordinator + PipHost"
```

---

### Task 3: Horizontal program for the PiP surface

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt:172-180` (add a method next to `pagedProgram`)

- [ ] **Step 1: Add `horizontalProgram()`**

In `ReaderViewModel.kt`, immediately after the `pagedProgram(...)` function (after line 180), add:

```kotlin
    /**
     * One-shot horizontal (single-system) layout program for the Picture-in-Picture surface,
     * independent of the user's current layout mode. Same native call as the recompute loop,
     * with the mode forced to HORIZONTAL in the options blob.
     */
    suspend fun horizontalProgram(): DrawProgram? {
        val h = handle?.raw ?: return null
        val opts = layoutOptions.value.copy(mode = ReaderLayoutMode.HORIZONTAL)
        val bytes = withContext(Dispatchers.Default) {
            SheetMusicJNI.nativeComputeLayout(h, PAGE_WIDTH_MM, PAGE_HEIGHT_MM, opts.encode())
        }
        if (bytes.isEmpty()) return null
        return try {
            DrawProgramReader.decode(bytes)
        } catch (e: Exception) {
            null
        }
    }
```

(`DrawProgram`, `DrawProgramReader`, `Dispatchers`, `withContext`, `SheetMusicJNI`, `PAGE_WIDTH_MM`, `PAGE_HEIGHT_MM` are all already imported/defined in this file.)

- [ ] **Step 2: Compile-check**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt
git commit -m "feat(android-pip): ReaderViewModel.horizontalProgram for PiP surface"
```

---

### Task 4: ReaderPipContent composable

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt:441` (change `private` → `internal` on `HorizontalScore`)
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderPipContent.kt`

- [ ] **Step 1: Make `HorizontalScore` reusable**

In `ReaderScreen.kt`, change the declaration at line 441 from:

```kotlin
@Composable
private fun HorizontalScore(
```

to:

```kotlin
@Composable
internal fun HorizontalScore(
```

- [ ] **Step 2: Create the PiP content composable**

Create `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderPipContent.kt`:

```kotlin
package com.keynumber.folino.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawProgram
import io.github.jiyimeta.sheetmusic.compose.render.bundledFontProvider

/**
 * Minimal Picture-in-Picture surface: the score forced to horizontal single-system layout, with
 * the playback cursor following along — no toolbar, transport, inspector, or gestures. Reuses
 * [HorizontalScore] (ScorePage + PlaybackCursorOverlay + JNI auto-scroll) on a dedicated horizontal
 * program so it stays horizontal even when the user's normal layout mode is page/vertical.
 */
@Composable
internal fun ReaderPipContent(
    readerVm: ReaderViewModel,
    audioVm: ReaderAudioViewModel,
) {
    val context = LocalContext.current
    val fontProvider = remember(context) { bundledFontProvider(context) }
    val scoreHandle by readerVm.scoreHandle.collectAsStateWithLifecycle()
    val layoutOptions by readerVm.layoutOptions.collectAsStateWithLifecycle()

    var program by remember { mutableStateOf<DrawProgram?>(null) }
    // Recompute the horizontal program whenever the score or display options change.
    LaunchedEffect(scoreHandle, layoutOptions) {
        program = readerVm.horizontalProgram()
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.White),
        contentAlignment = Alignment.Center,
    ) {
        val p = program
        if (p != null && p.pages.isNotEmpty()) {
            HorizontalScore(
                state = ReaderState.Ready(p),
                scoreHandle = scoreHandle,
                fontProvider = fontProvider,
                audioVm = audioVm,
                layoutOptions = layoutOptions.copy(mode = ReaderLayoutMode.HORIZONTAL),
            )
        }
    }
}
```

- [ ] **Step 3: Compile-check**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt \
        Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderPipContent.kt
git commit -m "feat(android-pip): ReaderPipContent minimal horizontal PiP surface"
```

---

### Task 5: Wire ReaderScreen (pipEnabled, controller publish, PiP switch, toolbar button)

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` (params, body, imports)

- [ ] **Step 1: Add imports**

In `ReaderScreen.kt`, add these imports alongside the existing ones (near the top of the file):

```kotlin
import androidx.compose.material.icons.filled.PictureInPicture
import androidx.compose.runtime.DisposableEffect
```

- [ ] **Step 2: Add the `pipEnabled` parameter**

In the `ReaderScreen(...)` signature (lines 72-86), add a parameter after `globalA4ReferenceHz` (before `readerVm`):

```kotlin
    globalA4ReferenceHz: Double = 440.0,
    /** When true, PiP is enabled in Settings: show the toolbar PiP button and allow auto-enter. */
    pipEnabled: Boolean = false,
    readerVm: ReaderViewModel = viewModel(),
    audioVm: ReaderAudioViewModel = viewModel(),
```

- [ ] **Step 3: Publish controller state + transport hooks**

In the `ReaderScreen` body, right after the existing `LaunchedEffect(displayOptions) { ... }` (line 107), add:

```kotlin
    val pipActive by ReaderPipController.isInPipMode.collectAsStateWithLifecycle()
    val playbackState by audioVm.state.collectAsStateWithLifecycle()
    val parts by readerVm.parts.collectAsStateWithLifecycle()

    // Publish PiP eligibility + window inputs while the Reader is on screen.
    LaunchedEffect(state, pipEnabled, playbackState, parts) {
        ReaderPipController.setStaffCount(parts.sumOf { it.staves.size })
        ReaderPipController.setPlaying(playbackState == PlaybackState.PLAYING)
        ReaderPipController.setEligible(
            state is ReaderState.Ready && pipEnabled && playbackState == PlaybackState.PLAYING,
        )
    }

    // Register transport hooks the in-window RemoteActions call; clear them on exit. ±10s is
    // implemented via seek (the engine has no verified skip()): clamp to [0, total].
    DisposableEffect(Unit) {
        ReaderPipController.onTogglePlayPause = {
            val e = audioVm.engine.value
            if (audioVm.state.value == PlaybackState.PLAYING) e?.pause() else e?.play()
        }
        ReaderPipController.onSkip = { delta ->
            audioVm.engine.value?.let { e ->
                val target = (audioVm.currentTimeSeconds.value + delta)
                    .coerceIn(0.0, audioVm.totalTimeSeconds.value)
                e.seek(target)
            }
        }
        onDispose { ReaderPipController.reset() }
    }
```

(`PlaybackState` is already imported at `ReaderScreen.kt:59`.)

- [ ] **Step 4: Switch the UI to the PiP surface when in PiP**

Wrap the existing `Scaffold( ... ) { ... }` (lines 115-160) and the two trailing `if (showInspector)` / `if (showDisplayInspector)` blocks (lines 161-179) in an `if (pipActive) { ... } else { ... }`. Concretely, replace the line:

```kotlin
    Scaffold(
```

with:

```kotlin
    if (pipActive) {
        ReaderPipContent(readerVm = readerVm, audioVm = audioVm)
        return
    }

    Scaffold(
```

> Note: `return` here exits the `@Composable fun ReaderScreen` early — this is a top-level composable function (not a lambda), so an early `return` is valid and leaves the normal UI (Scaffold + sheets) un-composed while in PiP.

- [ ] **Step 5: Add the toolbar PiP button**

In the `TopAppBar` `actions = { ... }` block (lines 124-131), add the PiP button before the existing display-inspector `IconButton`:

```kotlin
                actions = {
                    if (pipEnabled) {
                        val pipCtx = LocalContext.current
                        IconButton(onClick = { (pipCtx.findActivity() as? PipHost)?.enterPipNow() }) {
                            Icon(
                                Icons.Filled.PictureInPicture,
                                contentDescription = "Picture in Picture",
                            )
                        }
                    }
                    IconButton(onClick = { showDisplayInspector = true }) {
                        Icon(
                            Icons.AutoMirrored.Filled.ViewList,
                            contentDescription = stringResource(R.string.reader_display_settings),
                        )
                    }
                },
```

(`LocalContext` is already imported at `ReaderScreen.kt:50`.)

- [ ] **Step 6: Compile-check**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 7: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git commit -m "feat(android-pip): wire ReaderScreen — pip switch, transport hooks, toolbar button"
```

---

### Task 6: Pass `pipEnabled` from the Reader route

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt:283-316` (reader route)

- [ ] **Step 1: Read the pref and pass it**

In `MainActivity.kt`, inside the `reader/{id}/{title}` composable, add a pref read next to the others (after line 291, the `globalA4Hz` line):

```kotlin
                val pipEnabled by prefs.pip.collectAsState(initial = false)
```

Then in the `ReaderScreen(...)` call (lines 296-316), add the argument after `globalA4ReferenceHz`:

```kotlin
                    globalA4ReferenceHz = globalA4Hz,
                    pipEnabled = pipEnabled,
                    onBack = { nav.popBackStackIfResumed() },
```

(`collectAsState` is already imported at `MainActivity.kt:32`.)

- [ ] **Step 2: Compile-check**

Run: `Android/gradlew -p Android :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(android-pip): pass pipEnabled pref into ReaderScreen"
```

---

### Task 7: Manifest — declare PiP support

**Files:**
- Modify: `Android/app/src/main/AndroidManifest.xml:8`

- [ ] **Step 1: Add PiP attributes to MainActivity**

In `Android/app/src/main/AndroidManifest.xml`, change the activity opening tag from:

```xml
        <activity android:name=".MainActivity" android:exported="true">
```

to:

```xml
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:supportsPictureInPicture="true"
            android:resizeableActivity="true"
            android:configChanges="screenSize|smallestScreenSize|screenLayout|orientation">
```

> `configChanges` prevents the Activity (and its Compose/nav state) from being recreated when the window resizes into/out of PiP.

- [ ] **Step 2: Build the app to confirm the manifest is valid**

Run: `Android/gradlew -p Android :app:assembleDebug`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/AndroidManifest.xml
git commit -m "feat(android-pip): declare PiP support on MainActivity"
```

---

### Task 8: PiP params, RemoteActions, receiver, and Activity lifecycle

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ReaderPipIntegration.kt`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` (class header, onCreate, lifecycle overrides, imports)

- [ ] **Step 1: Create the PiP integration file**

Create `Android/app/src/main/kotlin/com/keynumber/folino/ReaderPipIntegration.kt`:

```kotlin
package com.keynumber.folino

import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Rational
import com.keynumber.folino.reader.ReaderPipController
import com.keynumber.folino.reader.pipAspectClamped
import kotlin.math.roundToInt

/** Broadcast contract for the in-window PiP controls. */
object ReaderPipActions {
    const val ACTION = "com.keynumber.folino.PIP_ACTION"
    const val EXTRA_CONTROL = "control"
    const val CONTROL_TOGGLE = "toggle"
    const val CONTROL_BACK = "back"        // -10s
    const val CONTROL_FORWARD = "forward"  // +10s
}

/**
 * Build PiP params: aspect ratio from staff count, the three RemoteActions (−10s, play/pause,
 * +10s), and — on Android 12+ — auto-enter when eligible. The play/pause glyph reflects [isPlaying].
 */
fun buildPipParams(
    activity: Activity,
    staffCount: Int,
    isPlaying: Boolean,
    autoEnter: Boolean,
): PictureInPictureParams {
    val aspect = pipAspectClamped(staffCount)
    val builder = PictureInPictureParams.Builder()
        .setAspectRatio(Rational((aspect * 100).roundToInt(), 100))
        .setActions(
            listOf(
                remoteAction(
                    activity, android.R.drawable.ic_media_rew, "Back 10s",
                    ReaderPipActions.CONTROL_BACK, requestCode = 1,
                ),
                remoteAction(
                    activity,
                    if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                    if (isPlaying) "Pause" else "Play",
                    ReaderPipActions.CONTROL_TOGGLE, requestCode = 2,
                ),
                remoteAction(
                    activity, android.R.drawable.ic_media_ff, "Forward 10s",
                    ReaderPipActions.CONTROL_FORWARD, requestCode = 3,
                ),
            ),
        )
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        builder.setAutoEnterEnabled(autoEnter)
        builder.setSeamlessResizeEnabled(false)
    }
    return builder.build()
}

private fun remoteAction(
    activity: Activity,
    iconRes: Int,
    title: String,
    control: String,
    requestCode: Int,
): RemoteAction {
    val intent = Intent(ReaderPipActions.ACTION)
        .setPackage(activity.packageName)
        .putExtra(ReaderPipActions.EXTRA_CONTROL, control)
    val pi = PendingIntent.getBroadcast(
        activity, requestCode, intent,
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
    return RemoteAction(Icon.createWithResource(activity, iconRes), title, title, pi)
}

/** Routes in-window control taps to the Reader's transport hooks via [ReaderPipController]. */
class PipActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.getStringExtra(ReaderPipActions.EXTRA_CONTROL)) {
            ReaderPipActions.CONTROL_TOGGLE -> ReaderPipController.onTogglePlayPause?.invoke()
            ReaderPipActions.CONTROL_BACK -> ReaderPipController.onSkip?.invoke(-10.0)
            ReaderPipActions.CONTROL_FORWARD -> ReaderPipController.onSkip?.invoke(10.0)
        }
    }
}
```

- [ ] **Step 2: Add imports to MainActivity**

In `MainActivity.kt`, add these imports:

```kotlin
import android.content.IntentFilter
import android.content.res.Configuration
import android.os.Build
import androidx.core.content.ContextCompat
import androidx.compose.runtime.LaunchedEffect
import com.keynumber.folino.reader.PipHost
import com.keynumber.folino.reader.ReaderPipController
```

- [ ] **Step 3: Make MainActivity a PipHost and add the receiver field**

Change the class header (line 74) from:

```kotlin
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = SettingsPrefs(applicationContext)
```

to:

```kotlin
class MainActivity : ComponentActivity(), PipHost {

    private val pipReceiver = PipActionReceiver()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = SettingsPrefs(applicationContext)
        val activity = this@MainActivity

        ContextCompat.registerReceiver(
            this,
            pipReceiver,
            IntentFilter(ReaderPipActions.ACTION),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
```

- [ ] **Step 4: Keep PiP params current inside setContent**

In `MainActivity.kt`, inside `setContent { MaterialTheme { Surface { ... } } }`, add this at the very top of the `Surface {` body (before `val rootNav = ...`, line 99):

```kotlin
                    // Keep PiP params current: auto-enter flag (API 31+) and play/pause glyph.
                    val pipEligible by ReaderPipController.eligible.collectAsState()
                    val pipPlaying by ReaderPipController.isPlaying.collectAsState()
                    val pipStaff by ReaderPipController.staffCount.collectAsState()
                    LaunchedEffect(pipEligible, pipPlaying, pipStaff) {
                        runCatching {
                            activity.setPictureInPictureParams(
                                buildPipParams(activity, pipStaff, pipPlaying, autoEnter = pipEligible),
                            )
                        }
                    }
```

(`collectAsState` and `getValue` are already imported at `MainActivity.kt:32-33`.)

- [ ] **Step 5: Add the PiP lifecycle overrides + onDestroy**

In `MainActivity.kt`, replace the closing of the class. Change the end of the class from:

```kotlin
        }
    }
}
```

(the `onCreate` close `}`, then class close `}` at lines 114-115) to:

```kotlin
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // API 31+ auto-enters via setAutoEnterEnabled; older versions enter here when eligible.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && ReaderPipController.eligible.value) {
            runCatching {
                enterPictureInPictureMode(
                    buildPipParams(
                        this,
                        ReaderPipController.staffCount.value,
                        ReaderPipController.isPlaying.value,
                        autoEnter = false,
                    ),
                )
            }
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        ReaderPipController.setInPipMode(isInPictureInPictureMode)
    }

    override fun enterPipNow() {
        runCatching {
            enterPictureInPictureMode(
                buildPipParams(
                    this,
                    ReaderPipController.staffCount.value,
                    ReaderPipController.isPlaying.value,
                    autoEnter = false,
                ),
            )
        }
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(pipReceiver) }
        super.onDestroy()
    }
}
```

- [ ] **Step 6: Build the app**

Run: `Android/gradlew -p Android :app:assembleDebug`
Expected: BUILD SUCCESSFUL.

> If the build fails on `ContextCompat` (unresolved): add `implementation("androidx.core:core-ktx:1.13.1")` to `Android/app/build.gradle.kts` dependencies and rebuild. (It is normally already present transitively.)

- [ ] **Step 7: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ReaderPipIntegration.kt \
        Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(android-pip): PiP params, RemoteActions receiver, Activity lifecycle"
```

---

### Task 9: Build, install, and verify on device

**Files:** none (verification only)

- [ ] **Step 1: Ensure native libs are staged (worktree only)**

If working in a fresh worktree, copy the prebuilt native + generated bindings from the primary checkout so Gradle can link (no native rebuild needed — nothing native changed):

Run (adjust `<PRIMARY>` to the primary checkout path):
```bash
rsync -a <PRIMARY>/Android/FolinoReaderAndroid/src/main/jniLibs/ Android/FolinoReaderAndroid/src/main/jniLibs/
rsync -a <PRIMARY>/Android/FolinoReaderAndroid/src/main/java-generated/ Android/FolinoReaderAndroid/src/main/java-generated/
```
(Skip this step entirely when implementing in the primary checkout.)

- [ ] **Step 2: Build + install on the connected Pixel**

Run: `Android/gradlew -p Android :app:installDebug`
Expected: BUILD SUCCESSFUL, APK installed.

- [ ] **Step 3: Launch**

Run: `adb shell am start -n com.keynumber.folino/.MainActivity`
Expected: app launches to the Library.

- [ ] **Step 4: Manual verification checklist (Claude drives install/launch; user confirms gestures)**

Enable PiP in Settings (gear → "Picture in Picture" ON), then open a score and:

1. **Manual button:** press Play, tap the toolbar PiP button → the Reader shrinks to a floating window showing the horizontal score with the cursor following playback. Audio continues.
2. **Auto-enter (Android 12+):** with playback running, press Home → the app auto-enters PiP.
3. **In-window controls:** the window shows −10s / play-pause / +10s. Tapping play/pause toggles audio and flips the glyph; ±10s jumps the playback position (clamped at start/end).
4. **Restore:** tap the window to expand → returns to the full Reader, normal UI intact (no recreate/flicker — `configChanges` working).
5. **Close:** dismiss the PiP window (×) → audio keeps playing via the foreground service (notification present).
6. **Gate off:** turn the Settings toggle OFF → toolbar PiP button disappears and Home press no longer auto-enters PiP.
7. **Layout independence:** set Settings layout to Page or Vertical; PiP still shows the horizontal single-system layout.

- [ ] **Step 5: Final commit (if any verification fixes were needed)**

```bash
git add -A
git commit -m "fix(android-pip): device-verification adjustments"
```

---

## Self-review

- **Spec coverage:** Activity-based PiP (Task 7,8) ✓; minimal horizontal content reusing existing composables (Task 3,4) ✓; auto-enter + manual button trigger (Task 5,8) ✓; play/pause + ±10s RemoteActions (Task 8, with ±10s via seek since no verified `skip`) ✓; aspect clamp to Android range (Task 1, applied Task 8) ✓; foreground-service audio survival (relied upon, no work) ✓; `pipEnabled` gate via existing DataStore key (Task 5,6) ✓; Settings toggle already exists (no task, by design) ✓; unit test for the one pure function (Task 1) ✓; manual Pixel verification (Task 9) ✓.
- **Out of scope honored:** no frame pump / pixel buffers / MediaCodec; no in-window scrub bar; OS-managed teardown.
- **Type consistency:** `ReaderPipController` API (`setInPipMode/setEligible/setPlaying/setStaffCount/onTogglePlayPause/onSkip/reset`) used identically across Tasks 2/5/8. `buildPipParams(activity, staffCount, isPlaying, autoEnter)` signature consistent across Task 8 call sites. `pipAspectClamped(Int): Double` consistent (Task 1 → Task 8). `HorizontalScore` made `internal` (Task 4) before reuse (Task 4). `ReaderState.Ready(program)` matches the verified data class.
- **±10s correctness:** uses only verified engine APIs (`seek(Double)`, `currentTimeSeconds`, `totalTimeSeconds`), avoiding the unconfirmed `skip`.
```

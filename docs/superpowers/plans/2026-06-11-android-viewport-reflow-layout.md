# Android Viewport-Reflow Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Android Reader lay out sheet music at a fixed pixel-per-mm density against the real viewport width (iOS-style reflow), so a wider tablet shows MORE music at the SAME staff size instead of zooming a fixed A4 page up ~1.4×.

**Architecture:** Today every render surface computes `fitPxPerMM = viewport_px / pageWidthMM` where the native layout is always produced at a fixed `PAGE_WIDTH_MM = 210`. That couples staff size to device width (the bug). We replace this with a single fixed density `LAYOUT_DP_PER_MM` (dp per layout-mm): render at `pxPerMM = LAYOUT_DP_PER_MM × density` (≈ 1:1, pinch-zoom on top), and feed the native layout a viewport-derived width `viewport_px / pxPerMM` mm so the engine reflows more measures into wider viewports. iOS already works this way (`VerticalScoreContainer` lays out at the real point width); this brings Android to parity. PiP is intentionally left unchanged (a small fixed window where fit-to-fixed-width is correct).

**Tech Stack:** Kotlin, Jetpack Compose, `swift-sheet-music` JNI (`SheetMusicJNI.nativeComputeLayout`), JUnit4 unit tests, Robolectric instrumented screenshot harness.

---

## Background facts (verified in code)

- `SheetMusicJNI.nativeComputeLayout(handle, widthMm, heightMm, optionsBlob)` reflows the score to the passed `widthMm` (proven: `ReaderViewModel.pagedProgram` already passes arbitrary width/height). The fixed `PAGE_WIDTH_MM = 210` is a choice inherited from the ssm Android example app (`ReaderViewModel.kt:24-25` comment "matches the example's single-page layout"), NOT an Android constraint.
- Three full-screen render surfaces, each with its own `fitPxPerMM`:
  - VERTICAL — `ReadyScore`, `ReaderScreen.kt:466-470` → `viewport.width / page.widthMM`. Consumes the VM recompute-loop `_state` (which is laid out at fixed 210mm → MUST change the layout width too, not just the render).
  - HORIZONTAL — `HorizontalScore`, `ReaderScreen.kt:1196-1200` → `viewport.width / A4_WIDTH_MM`. Natural single-system width; layout width arg is irrelevant, only the render scale changes.
  - PAGE — `PagedScore`, `PagedScore.kt:79-81, 90` → `viewport.width / PAGE_WIDTH_MM`, then `pagedProgram(PAGE_WIDTH_MM, viewportHeightMm)`. Its own layout call (NOT the recompute loop).
- Cursor / tap / AB overlay math is density-agnostic: everything multiplies/divides by `pxPerMM × scale` (`TapToCursor.kt:42-43`, overlay calls). Changing how `pxPerMM` is derived needs no math changes there.
- PiP: `ReaderScreen.kt:260` `pipAspectForSystemHeight(page.heightMM, A4_WIDTH_MM)` and `ReaderPipContent`/`PipScene` use `cardWidthPx / A4_WIDTH_MM`. This is a small floating window — fit-to-fixed-width is the correct behavior there. **Leave PiP unchanged.** `A4_WIDTH_MM` (`ReaderScreen.kt:1166`) therefore stays defined.
- Screenshot harness (`ReaderSceneHost.kt:194`) replicates the VERTICAL render path and drives the SAME `ReaderViewModel`; it uses `SCREENSHOT_STAFF_SIZE = 18.0` (`ReaderSceneHost.kt:48`) for all scenes, phone and tablet. After this change the tablet no longer inflates, so the prior handoff's "tablet-specific staffSize" idea is obsolete.

## Density anchor

`LAYOUT_DP_PER_MM = 393.0 / 210.0 ≈ 1.8714`. Rationale: a ~393dp-wide phone (Pixel 7, the harness phone) lays out exactly 210mm — so phones render byte-identically to today, while a ~800dp tablet lays out ~427mm (≈2× the music) at the same staff dp-size. This is a tunable constant; the final value is confirmed by the phone/tablet screenshot pass in Task 7.

## File map

- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderLayoutDensity.kt` — the density constant + pure helpers.
- Create: `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderLayoutDensityTest.kt` — unit tests.
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt` — thread layout width into the recompute loop.
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` — VERTICAL (`ReadyScore`) and HORIZONTAL (`HorizontalScore`) render scale + width push.
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PagedScore.kt` — PAGE render scale + viewport-derived layout width.
- Modify: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/fixtures/ReaderSceneHost.kt` and the score scenes — harness fixed density; retune.
- Modify: `~/Desktop/android-screenshot-tablet-staffsize-handoff.md` and Claude memory — record resolution.

---

### Task 1: Fixed-density layout math (pure functions, TDD)

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderLayoutDensity.kt`
- Test: `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderLayoutDensityTest.kt`

- [ ] **Step 1: Write the failing test**

```kotlin
package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Test

class ReaderLayoutDensityTest {
    // A ~393dp phone lays out ~210mm regardless of pixel density (device-independent).
    @Test fun phoneWidthMmIs210AtDensity1() {
        assertEquals(210.0, layoutWidthMm(widthPx = 393, densityPxPerDp = 1.0f), 0.5)
    }

    @Test fun phoneWidthMmIs210AtDensity2() {
        assertEquals(210.0, layoutWidthMm(widthPx = 786, densityPxPerDp = 2.0f), 0.5)
    }

    // A ~800dp tablet lays out ~427mm — roughly twice the music at the same staff size.
    @Test fun tabletWidthMmIsRoughlyDouble() {
        assertEquals(427.5, layoutWidthMm(widthPx = 1600, densityPxPerDp = 2.0f), 1.0)
    }

    // pxPerMm and widthMm are exact inverses: widthPx round-trips.
    @Test fun pxPerMmInvertsWidthMm() {
        val px = 1080
        val d = 2.625f
        val mm = layoutWidthMm(px, d)
        assertEquals(px.toDouble(), mm * fixedPxPerMm(d), 0.5)
    }

    @Test fun nonPositiveInputClampsToMin() {
        assertEquals(80.0, layoutWidthMm(0, 2.0f), 1e-9)
        assertEquals(80.0, layoutWidthMm(100, 0f), 1e-9)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./Android/gradlew -p ./Android :FolinoReaderAndroid:testDebugUnitTest --tests "com.keynumber.folino.reader.ReaderLayoutDensityTest"`
Expected: FAIL — `Unresolved reference: layoutWidthMm` / `fixedPxPerMm`.

- [ ] **Step 3: Write minimal implementation**

```kotlin
package com.keynumber.folino.reader

/**
 * Fixed layout density: logical dp per layout-millimetre.
 *
 * Anchored so a ~393dp-wide phone lays out ~210mm of score width — phones render as before,
 * while wider tablets reflow MORE music at the SAME staff size (matching iOS, which lays out at
 * the real viewport width instead of zooming a fixed A4 page). Tunable; confirmed by the
 * phone/tablet screenshot pass.
 */
const val LAYOUT_DP_PER_MM: Double = 393.0 / 210.0 // ≈ 1.8714

/** Smallest layout width we ever ask the engine for, so a zero/garbage viewport never degenerates. */
private const val MIN_LAYOUT_WIDTH_MM: Double = 80.0

/** Render scale (pixels per layout-mm) at the given Compose density (`Density.density` = px per dp). */
fun fixedPxPerMm(densityPxPerDp: Float): Float = (LAYOUT_DP_PER_MM * densityPxPerDp).toFloat()

/**
 * Layout width (mm) to feed the engine for a viewport [widthPx] at [densityPxPerDp].
 * Inverse of [fixedPxPerMm]: `widthMm = widthPx / pxPerMm = widthDp / LAYOUT_DP_PER_MM`.
 */
fun layoutWidthMm(widthPx: Int, densityPxPerDp: Float): Double {
    if (widthPx <= 0 || densityPxPerDp <= 0f) return MIN_LAYOUT_WIDTH_MM
    return maxOf(widthPx / fixedPxPerMm(densityPxPerDp).toDouble(), MIN_LAYOUT_WIDTH_MM)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./Android/gradlew -p ./Android :FolinoReaderAndroid:testDebugUnitTest --tests "com.keynumber.folino.reader.ReaderLayoutDensityTest"`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderLayoutDensity.kt Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderLayoutDensityTest.kt
git commit -m "feat(reader-android): fixed-density layout math for viewport reflow"
```

---

### Task 2: Thread layout width into the ReaderViewModel recompute loop

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt:24-26, 54-55, 79-102, 172-180`

The recompute loop currently lays out VERTICAL/HORIZONTAL `_state` at fixed `PAGE_WIDTH_MM`. Add a `_layoutWidthMm` input fed from the render surface so VERTICAL reflows to the viewport. HORIZONTAL ignores width (natural layout) — harmless. PAGE uses its own `pagedProgram` (Task 4).

- [ ] **Step 1: Re-comment the page constants and keep height-only A4**

Replace `ReaderViewModel.kt:24-26`:

```kotlin
// A4 page height in millimetres, used as the layout canvas height. The layout WIDTH is no longer
// fixed: it comes from the viewport via [setLayoutWidthMm] so the engine reflows to the real screen
// width (iOS parity). PAGE_WIDTH_MM is only the pre-viewport seed default.
private const val PAGE_WIDTH_MM = 210.0
private const val PAGE_HEIGHT_MM = 297.0
```

- [ ] **Step 2: Add the layout-width input flow**

After `ReaderViewModel.kt:55` (`val layoutOptions: StateFlow<LayoutOptions> = _layoutOptions.asStateFlow()`), add:

```kotlin
    // Viewport-derived layout width (mm) for the wrapping (VERTICAL) layout. Seeded to A4 width until
    // the render surface reports its viewport; pushed via [setLayoutWidthMm]. Drives the recompute.
    private val _layoutWidthMm = MutableStateFlow(PAGE_WIDTH_MM)
    val layoutWidthMm: StateFlow<Double> = _layoutWidthMm.asStateFlow()
```

And add a setter next to `setLayoutOptions` (after `ReaderViewModel.kt:66`):

```kotlin
    /** Push the viewport-derived layout width (mm) in from the render surface; drives a recompute. */
    fun setLayoutWidthMm(mm: Double) {
        if (mm > 0.0) _layoutWidthMm.value = mm
    }
```

- [ ] **Step 3: Fold the width into the recompute loop**

Replace the `combine(...).mapLatest { ... }` head in `startRecomputeLoop` (`ReaderViewModel.kt:81-86`) so it combines three flows and passes the width to native:

```kotlin
            combine(_scoreHandle, _layoutOptions, _layoutWidthMm) { h, opts, widthMm ->
                Triple(h, opts, widthMm)
            }
                .mapLatest { (h, opts, widthMm) ->
                    if (h == null) return@mapLatest
                    delay(RECOMPUTE_DEBOUNCE_MS)
                    val programBytes = withContext(Dispatchers.Default) {
                        SheetMusicJNI.nativeComputeLayout(h, widthMm, PAGE_HEIGHT_MM, opts.encode())
                    }
```

(Leave the rest of the block — empty-bytes guard, decode, `_state.value = ReaderState.Ready(program)` — unchanged.)

- [ ] **Step 4: Leave `pagedProgram` and `horizontalProgram` as-is for now**

`pagedProgram` (`:172-180`) is re-pointed by Task 4's call site. `horizontalProgram` (`:187-199`, PiP only) keeps `PAGE_WIDTH_MM` — PiP is unchanged. No edits this step.

- [ ] **Step 5: Compile the module**

Run: `./Android/gradlew -p ./Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 6: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt
git commit -m "feat(reader-android): feed viewport-derived layout width into recompute loop"
```

---

### Task 3: VERTICAL render (`ReadyScore`) — fixed density + width push

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt:331-340` (call site), `:446-470` (`ReadyScore`)

- [ ] **Step 1: Add a width-report callback to `ReadyScore`**

Replace the `ReadyScore` signature (`ReaderScreen.kt:446-453`):

```kotlin
@Composable
private fun ReadyScore(
    state: ReaderState.Ready,
    scoreHandle: Long?,
    fontProvider: io.github.jiyimeta.sheetmusic.compose.render.FontProvider,
    audioVm: ReaderAudioViewModel,
    layoutOptions: LayoutOptions,
    bottomContentPad: Dp = 0.dp,
    onLayoutWidthMm: (Double) -> Unit = {},
) {
```

- [ ] **Step 2: Switch the render scale to fixed density and report the width**

Replace `ReaderScreen.kt:464-470` (the `fit-width` comment + `fitPxPerMM` block):

```kotlin
    // Fixed-density render: pxPerMM is the same on every device, so the staff is the same on-screen
    // size on phone and tablet. The engine reflows to the viewport width (reported below) so a wider
    // screen shows MORE music, not bigger notes. Pinch `scale` multiplies on top. (iOS parity.)
    val fitPxPerMM = if (viewportSize.width > 0) fixedPxPerMm(density.density) else 0f

    // Report the viewport-derived layout width up to the VM, which reflows the score to it.
    LaunchedEffect(viewportSize.width, density.density) {
        if (viewportSize.width > 0) onLayoutWidthMm(layoutWidthMm(viewportSize.width, density.density))
    }
```

(`density` is already `LocalDensity.current` at `ReaderScreen.kt:461`. `contentWidthPx`/`contentHeightPx` at `:471-472` are unchanged — they consume `fitPxPerMM`.)

- [ ] **Step 3: Wire the callback at the call site**

In the `ReaderLayoutMode.VERTICAL -> ReadyScore(...)` call (`ReaderScreen.kt:331-340`), add the argument after `bottomContentPad = ...`:

```kotlin
                        bottomContentPad = if (!showSeekBar) fabClusterReservedHeight else 0.dp,
                        onLayoutWidthMm = readerVm::setLayoutWidthMm,
```

- [ ] **Step 4: Compile the module**

Run: `./Android/gradlew -p ./Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git commit -m "feat(reader-android): vertical render at fixed density, reflow to viewport"
```

---

### Task 4: PAGE render (`PagedScore`) — fixed density + viewport-derived width

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PagedScore.kt:79-91`

- [ ] **Step 1: Confirm `density` is in scope**

Read `PagedScore.kt` around the `viewportSize` declaration (~`:70-90`). If there is no `val density = LocalDensity.current`, add one next to it (the file already imports `androidx.compose.ui.platform.LocalDensity` for its dp math; if not, add the import).

- [ ] **Step 2: Switch fit + derive both viewport dimensions in mm**

Replace `PagedScore.kt:79-81`:

```kotlin
    val fitPxPerMM = if (viewportSize.width > 0) fixedPxPerMm(density.density) else 0f
    val viewportWidthMm: Double =
        if (fitPxPerMM > 0f) (viewportSize.width / fitPxPerMM).toDouble() else PAGE_WIDTH_MM
    val viewportHeightMm: Double =
        if (fitPxPerMM > 0f) (viewportSize.height / fitPxPerMM).toDouble() else 0.0
```

- [ ] **Step 3: Lay out each page at the viewport width (not fixed A4)**

In the `LaunchedEffect(...)` that builds pages (`PagedScore.kt:88-91`), change the key list and the `pagedProgram` call to use `viewportWidthMm`:

```kotlin
    LaunchedEffect(scoreHandle, viewportWidthMm, viewportHeightMm, layoutOptions) {
        if (scoreHandle != null && viewportHeightMm > 0.0) {
            val pages = readerVm.pagedProgram(viewportWidthMm, viewportHeightMm)?.pages ?: emptyList()
            val breaks = readerVm.pageBreaks(viewportHeightMm)
```

(`pageBreaks` paginates by height only — unchanged. The per-page `contentWidthPx`/`pageTopPx` math at `:155-158` consumes `fitPxPerMM` and is unchanged.)

- [ ] **Step 4: Compile the module**

Run: `./Android/gradlew -p ./Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PagedScore.kt
git commit -m "feat(reader-android): page mode reflows to viewport at fixed density"
```

---

### Task 5: HORIZONTAL full-screen render — fixed density (PiP untouched)

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt:1196-1200`

- [ ] **Step 1: Confirm `density` is in scope in `HorizontalScore`**

Read `ReaderScreen.kt` around the `HorizontalScore` `viewportSize` declaration (~`:1186-1200`). If there is no `val density = LocalDensity.current`, add one next to `var scale by remember { ... }`.

- [ ] **Step 2: Switch the horizontal fit to fixed density**

Replace `ReaderScreen.kt:1196-1200`:

```kotlin
    // Fixed-density render (same pxPerMM as vertical) so the single-system row is the same on-screen
    // size on phone and tablet. The row is natural-width (no wrap) → horizontal scroll; the layout
    // width arg passed to the engine is irrelevant in horizontal mode.
    val fitPxPerMM = if (viewportSize.width > 0) fixedPxPerMm(density.density) else 0f
```

(Do NOT touch `A4_WIDTH_MM` at `:1166` or its PiP use at `:260` — PiP is intentionally fit-to-fixed-width.)

- [ ] **Step 3: Compile the module**

Run: `./Android/gradlew -p ./Android :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Run the full module unit tests (regression)**

Run: `./Android/gradlew -p ./Android :FolinoReaderAndroid:testDebugUnitTest`
Expected: PASS (existing `PipAspectTest`, `ReaderRepeatControllerTest`, new `ReaderLayoutDensityTest`).

- [ ] **Step 5: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git commit -m "feat(reader-android): horizontal render at fixed density"
```

---

### Task 6: Build the app + manual device smoke (phone & tablet)

**Files:** none (verification task).

- [ ] **Step 1: Assemble the app**

Run: `./Android/gradlew -p ./Android :app:assembleDebug`
Expected: BUILD SUCCESSFUL. (Fresh worktree: first generate JNI bindings / native libs per `project_android_build_toolchain` — `Scripts/android-build-libs.sh` or the documented bootstrap — before assembling.)

- [ ] **Step 2: Install + launch on the tablet emulator and a phone form factor**

Per the user's standing rule (`feedback_android_install_launch`), install and launch — do NOT just build:

```
ANDROID_SERIAL=emulator-5554 ./Android/gradlew -p ./Android :app:installDebug
adb -s emulator-5554 shell am start -n com.keynumber.folino/.MainActivity
```

Open a multi-staff score in each layout mode (vertical / horizontal / page) on both a phone-sized and a tablet-sized emulator window. Confirm by eye: the staff is the SAME apparent size on phone and tablet, and the tablet shows MORE measures per system / more systems, not a zoomed-up page. Hand the device to the user for the final read.

- [ ] **Step 3: No code change — no commit.** Record observations for Task 7 tuning.

---

### Task 7: Screenshot harness — adopt fixed density, drop tablet-staffSize idea, retune

**Files:**
- Modify: `Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/fixtures/ReaderSceneHost.kt:194-198`
- Modify (if needed): `.../scenes/AbRepeatScene.kt:154-158`
- Verify-only: `.../scenes/PipScene.kt` (PiP — unchanged), `ReaderCursorScene`, `DisplayHiddenScene`, `LoopAllScene`

The harness drives the production `ReaderViewModel`, so it inherits the reflow once it (a) reports its viewport width to the VM and (b) renders at the fixed density.

- [ ] **Step 1: Report the harness viewport width to the VM**

In `ReaderSceneHost.kt`, where the host computes `fitPxPerMM` and has the VM + `viewportSize` + `density` in scope (~`:190-198`), push the width once known:

```kotlin
    LaunchedEffect(viewportSize.width, density.density) {
        if (viewportSize.width > 0) readerVm.setLayoutWidthMm(layoutWidthMm(viewportSize.width, density.density))
    }
```

(Use the same VM instance the scene already collects `state` from. If the host exposes the VM under a different name, adapt.)

- [ ] **Step 2: Switch the harness fit to fixed density**

Replace `ReaderSceneHost.kt:194-198`:

```kotlin
            val fitPxPerMM = if (viewportSize.width > 0) fixedPxPerMm(density.density) else 0f
```

- [ ] **Step 3: Mirror the same change in AbRepeatScene's local fit**

Replace `AbRepeatScene.kt:154-158`'s `fitPxPerMM` so it uses the fixed density (the band/scroll formula below it is unchanged — it already works at any `fitPxPerMM`):

```kotlin
    val fitPxPerMM = if (a != null && b != null && viewportSize.width > 0) {
        fixedPxPerMm(density.density)
    } else {
        0f
    }
```

(If `density` isn't already in scope in this scene, add `val density = LocalDensity.current`.)

- [ ] **Step 4: Re-render all score scenes on BOTH form factors**

Run (in the active screenshot worktree, with its `-PssmVersion` per the handoff; flaky native "Process crashed" → re-run once):

```
ANDROID_SERIAL=emulator-5554 ./Android/gradlew -p ./Android \
  -PssmVersion=0.0.0-<branch>-SNAPSHOT :app:collectScreenshots
```

`Read` the resulting PNGs for phone (`phoneScreenshots`) and tablet (`tenInchScreenshots`) at `Android/fastlane/metadata/android/<locale>/images/.../NN.png`: 10 Reader+cursor, 20 display(staff-hidden), 30 loop inspector, 40 AB m5-7, 60 PiP.

- [ ] **Step 5: Retune `SCREENSHOT_STAFF_SIZE` once, device-agnostically**

`SCREENSHOT_STAFF_SIZE` (`ReaderSceneHost.kt:48`) is now a single value that renders consistently on both devices (no tablet branch — the prior handoff idea is obsolete). If 18.0 reads too large/small in the marketing frame after reflow, adjust the one constant and re-run Step 4. Confirm AB (40) keeps all three looped measures + both flags in frame and PiP (60) crop still frames the kept staves.

- [ ] **Step 6: Commit**

```bash
git add Android/app/src/androidTest/kotlin/com/keynumber/folino/screenshot/
git commit -m "feat(android-screenshots): fixed-density reflow; drop tablet staffSize divergence"
```

---

### Task 8: Record the resolution in docs + memory

**Files:**
- Modify: `~/Desktop/android-screenshot-tablet-staffsize-handoff.md` (NOT committed — it's on the Desktop)
- Modify: Claude memory `project_android_playstore_screenshots.md`; add a reference memory for the layout model

- [ ] **Step 1: Mark the handoff resolved**

Prepend a short "RESOLVED" note to `~/Desktop/android-screenshot-tablet-staffsize-handoff.md`: the tablet inflation was the fixed-A4-page + fit-to-width model; fixed it by switching all full-screen modes to fixed-density viewport reflow (iOS parity, `LAYOUT_DP_PER_MM`); the per-device staffSize branch is no longer needed.

- [ ] **Step 2: Update memory**

Update `project_android_playstore_screenshots.md` to note the reflow change, and add a `reference_android_layout_fixed_density.md` memory (with a `MEMORY.md` index line) capturing: the fixed-density model, `LAYOUT_DP_PER_MM` anchor rationale, that PiP intentionally stays fit-to-fixed-width, and that VERTICAL needs both the render scale AND the VM layout width changed (HORIZONTAL/PAGE notes too). Link `[[feedback_ios_android_parity]]`.

- [ ] **Step 3: Commit the in-repo doc**

```bash
git add docs/superpowers/plans/2026-06-11-android-viewport-reflow-layout.md
git commit -m "docs: plan for Android viewport-reflow layout"
```

---

## Self-review notes

- **Spec coverage:** All three full-screen modes (VERTICAL Task 3, PAGE Task 4, HORIZONTAL Task 5) switch to fixed density; the VERTICAL layout-width coupling is handled in Task 2; harness in Task 7; PiP explicitly out of scope and unchanged.
- **Type consistency:** `fixedPxPerMm(Float): Float` and `layoutWidthMm(Int, Float): Double` and `setLayoutWidthMm(Double)` are used identically across Tasks 1–7. The new `ReadyScore` param is `onLayoutWidthMm: (Double) -> Unit`.
- **No regressions to cursor/tap/AB/overlay math:** all consume `fitPxPerMM × scale`; only the derivation of `fitPxPerMM` changes.
- **Open tuning item:** `LAYOUT_DP_PER_MM` and `SCREENSHOT_STAFF_SIZE` final values are confirmed visually in Tasks 6–7, not assumed.

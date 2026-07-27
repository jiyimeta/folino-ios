# Android Reader Free-Form Scroll and Pinch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Android reader browser-like viewport control — diagonal panning with no axis lock, a pinch whose centroid stays fixed, and momentum after a pan — across all three display modes.

**Architecture:** Replace the Compose scroll containers (`Modifier.verticalScroll` / `Modifier.horizontalScroll`) on the vertical and horizontal reader surfaces with a single `ReaderViewportState` (scale + two-dimensional offset) driven by one gesture loop, and rebase the page surface's existing hand-rolled pan onto the same state. Panning becomes a `graphicsLayer` translation on the content box instead of a scroll container's placement; clamping is computed from the content extent at the *current* frame's scale rather than from a scroll state's stale `maxValue`, which is what makes the pinch anchor hold.

**Tech Stack:** Kotlin, Jetpack Compose (foundation gestures, `graphicsLayer`, `splineBasedDecay`), JUnit 4 for unit tests, Gradle.

## Global Constraints

- **No new dependencies.** Everything used here is already on the Compose foundation / animation classpath.
- **Scale range stays `1f..8f`.** No zooming out below fit; no rubber-band overscroll; no double-tap zoom. These were explicitly scoped out.
- **`scale` / `rasterScale` split is preserved on the vertical surface.** The bands stay recorded at `rasterScale` and a layer transform covers the difference during a gesture — this is what keeps a pinch off the score's re-record path. The horizontal and page surfaces re-record per frame today and keep doing so.
- **The clip and the pan `graphicsLayer` must live on the same node.** Splitting them across two boxes loses the content's own RenderNode, and every wet-ink frame then re-records the whole score.
- **Comment reflow budget is 120 columns** (SwiftLint's `line_length.warning`), matching the repo's comment style rule.
- **Whole-file staging only.** No `git add -p` / hunk-level staging.
- **No Bash compounds.** No `cd X && cmd` — use `Android/gradlew -p Android …` from the repo root.
- **Verification device is the physical Pixel.** Do not start an emulator; if no device is attached, ask the user to connect one. Android changes end with `:app:installDebug` plus an `adb` launch.
- **Work in a git worktree** created via `superpowers:using-git-worktrees`, based on local `main`. Subagents must use the absolute worktree path and `git -C <worktree>` for every git call.

## File Structure

| File | Responsibility |
| --- | --- |
| `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewport.kt` | **New.** Pure viewport math (clamping, focal correction, scale coercion), the `ReaderViewportState` holder, and the shared gesture modifier. Everything the three surfaces have in common. |
| `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderViewportMathTest.kt` | **New.** Unit tests for the pure functions. |
| `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderViewportStateTest.kt` | **New.** Unit tests for the state holder, including the anchor regression. |
| `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` | **Modify.** `ReadyScore` (vertical) and `HorizontalScore` adopt the viewport; `focalAdjustedOffset` moves out. |
| `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PagedScore.kt` | **Modify.** `panOffset` gives way to the shared state; gains momentum. |

---

### Task 1: Pure viewport math

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewport.kt`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt:1479-1496` (delete `focalAdjustedOffset`, which moves to the new file)
- Test: `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderViewportMathTest.kt`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `internal enum class ViewportUnderfill { START, CENTER }`
  - `internal fun axisContentPx(unitContentPx: Float, fixedPadPx: Float, scale: Float): Float`
  - `internal fun clampAxisOffset(offset: Float, contentPx: Float, viewportPx: Float, underfill: ViewportUnderfill): Float`
  - `internal fun focalAdjustedOffset(currentScroll: Float, centroid: Float, ratio: Float, pad: Float = 0f): Float`
  - `internal fun coerceReaderScale(scale: Float): Float`
  - `internal const val MIN_READER_SCALE = 1f`, `internal const val MAX_READER_SCALE = 8f`

Everything is same-package (`com.keynumber.folino.reader`), so `ReaderScreen.kt` and `PagedScore.kt` need no import for these.

- [ ] **Step 1: Write the failing tests**

Create `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderViewportMathTest.kt`:

```kotlin
package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Unit tests for the pure viewport math shared by the three reader surfaces.
 *
 * The focal tests assert the property that matters rather than the formula: the document point sitting
 * under the pinch centroid must land on the same screen pixel after the zoom step. Screen position of a
 * document point `d` (document px at scale 1) is `pad + scale * d - offset`, where `pad` is fixed padding
 * that does not scale with zoom.
 */
class ReaderViewportMathTest {

    private fun screenX(documentPx: Float, scale: Float, offset: Float, pad: Float = 0f): Float =
        pad + scale * documentPx - offset

    @Test fun axisContentPx_scalesContentButNotThePad() {
        assertEquals(2400f, axisContentPx(unitContentPx = 1000f, fixedPadPx = 400f, scale = 2f), 0.001f)
    }

    @Test fun clamp_contentLargerThanViewport_staysInRange() {
        assertEquals(0f, clampAxisOffset(-50f, 2000f, 800f, ViewportUnderfill.START), 0.001f)
        assertEquals(700f, clampAxisOffset(700f, 2000f, 800f, ViewportUnderfill.START), 0.001f)
        assertEquals(1200f, clampAxisOffset(5000f, 2000f, 800f, ViewportUnderfill.START), 0.001f)
    }

    @Test fun clamp_contentSmallerThanViewport_startPinsToZero() {
        assertEquals(0f, clampAxisOffset(300f, 500f, 800f, ViewportUnderfill.START), 0.001f)
    }

    @Test fun clamp_contentSmallerThanViewport_centerReturnsHalfTheGapNegated() {
        // Content 500 px inside an 800 px viewport: a 150 px lead-in on each side. Offset is a scroll
        // position, so the lead-in is a NEGATIVE offset (translation = -offset pushes content forward).
        assertEquals(-150f, clampAxisOffset(300f, 500f, 800f, ViewportUnderfill.CENTER), 0.001f)
    }

    @Test fun focal_holdsTheCentroid_withoutPad() {
        val scale0 = 2f
        val offset0 = 340f
        val centroid = 260f
        val ratio = 1.25f
        val documentPx = (offset0 + centroid) / scale0
        val offset1 = focalAdjustedOffset(offset0, centroid, ratio)
        assertEquals(centroid, screenX(documentPx, scale0 * ratio, offset1), 0.01f)
    }

    @Test fun focal_holdsTheCentroid_withLeadingPad() {
        val pad = 48f
        val scale0 = 1.5f
        val offset0 = 200f
        val centroid = 410f
        val ratio = 0.8f
        val documentPx = (offset0 + centroid - pad) / scale0
        val offset1 = focalAdjustedOffset(offset0, centroid, ratio, pad)
        assertEquals(centroid, screenX(documentPx, scale0 * ratio, offset1, pad), 0.01f)
    }

    @Test fun coerceReaderScale_clampsToOneThroughEight() {
        assertEquals(1f, coerceReaderScale(0.25f), 0.001f)
        assertEquals(3.5f, coerceReaderScale(3.5f), 0.001f)
        assertEquals(8f, coerceReaderScale(12f), 0.001f)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --tests "*ReaderViewportMathTest*" --no-daemon`

Expected: FAIL — compilation error, `axisContentPx` / `clampAxisOffset` / `ViewportUnderfill` / `coerceReaderScale` unresolved.

- [ ] **Step 3: Create the pure-math file**

Create `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewport.kt`:

```kotlin
package com.keynumber.folino.reader

/** Lower bound of the reader's pinch zoom: fit. Zooming out past fit is deliberately not offered. */
internal const val MIN_READER_SCALE = 1f

/** Upper bound of the reader's pinch zoom. */
internal const val MAX_READER_SCALE = 8f

/**
 * Where content sits along one axis when it is SMALLER than the viewport — the case where there is no
 * scrolling to do and the offset is decided rather than chosen.
 *
 * [START] pins it to the leading edge (the vertical surface's top-anchored page). [CENTER] centers it
 * (the horizontal surface's single system, which floats in the middle of a taller viewport).
 */
internal enum class ViewportUnderfill { START, CENTER }

/**
 * Content extent along one axis at [scale], in px.
 *
 * [unitContentPx] is the part that scales with zoom (the page itself at scale 1); [fixedPadPx] is
 * padding that does NOT scale — the vertical surface's breathing room above and below the page, plus its
 * extra bottom pad that lets the last system clear the floating play button.
 */
internal fun axisContentPx(unitContentPx: Float, fixedPadPx: Float, scale: Float): Float =
    unitContentPx * scale + fixedPadPx

/**
 * Clamp a scroll offset along one axis.
 *
 * Positive offset means scrolled forward (down / right), matching `ScrollState.value`. When the content
 * is larger than the viewport the offset rides in `[0, contentPx - viewportPx]`. When it is smaller
 * there is nothing to scroll and [underfill] decides: [ViewportUnderfill.START] pins to zero;
 * [ViewportUnderfill.CENTER] returns a negative offset of half the gap, which the layer's
 * `translation = -offset` turns into a positive lead-in.
 */
internal fun clampAxisOffset(
    offset: Float,
    contentPx: Float,
    viewportPx: Float,
    underfill: ViewportUnderfill,
): Float = if (contentPx <= viewportPx) {
    when (underfill) {
        ViewportUnderfill.START -> 0f
        ViewportUnderfill.CENTER -> (contentPx - viewportPx) / 2f
    }
} else {
    offset.coerceIn(0f, contentPx - viewportPx)
}

/**
 * New scroll offset (px) that keeps the content point under the pinch centroid fixed across a zoom step
 * of ratio `r = newScale / oldScale`. Only the page content scales by `r`; a constant leading [pad] (the
 * fixed padding before the page, which does NOT scale with zoom) is held out of the scaling.
 *
 * In scroll space the content point under the centroid is at `scroll + centroid`; the scaling page part
 * is `scroll + centroid - pad`, so after scaling by `r` the new offset is
 * `pad + r * (scroll - pad + centroid) - centroid`. With `pad = 0` this reduces to the simple
 * `r * (scroll + centroid) - centroid`.
 *
 * The result is NOT clamped here. Clamping is the caller's job and has to happen against the content
 * extent at the NEW scale — clamping against the old extent is what used to drag the anchor to the
 * top-left, since a scroll container's `maxValue` still described the previous frame's layout.
 */
internal fun focalAdjustedOffset(
    currentScroll: Float,
    centroid: Float,
    ratio: Float,
    pad: Float = 0f,
): Float = pad + ratio * (currentScroll - pad + centroid) - centroid

/** Clamp a proposed zoom into the reader's supported range. */
internal fun coerceReaderScale(scale: Float): Float = scale.coerceIn(MIN_READER_SCALE, MAX_READER_SCALE)
```

- [ ] **Step 4: Delete the old copy of `focalAdjustedOffset`**

In `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt`, delete lines 1479-1496 in full — the KDoc block starting `/**` with `New scroll offset (px) that keeps the content point…` and the `private fun focalAdjustedOffset(…)` declaration that follows it. Its replacement lives in `ReaderViewport.kt` and is `internal`, so the two call sites in `ReaderScreen.kt` (lines ~1270-1271 and ~2220-2221) keep compiling unchanged.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --tests "*ReaderViewportMathTest*" --no-daemon`

Expected: PASS, 7 tests.

- [ ] **Step 6: Verify the module still compiles**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin --no-daemon`

Expected: BUILD SUCCESSFUL.

- [ ] **Step 7: Commit**

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewport.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderViewportMathTest.kt
git -C <worktree> commit -m "feat(reader-android): pure viewport math for clamping and focal zoom"
```

---

### Task 2: `ReaderViewportState` and the shared gesture modifier

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewport.kt` (append)
- Test: `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderViewportStateTest.kt`

**Interfaces:**
- Consumes: everything Task 1 produced.
- Produces:
  - `internal data class ViewportGeometry(viewportWidthPx, viewportHeightPx, unitContentWidthPx, unitContentHeightPx, fixedPadXPx, fixedPadYPx, leadingPadYPx)` — all `Float`, all defaulting to `0f`.
  - `internal class ReaderViewportState(deferRaster: Boolean, underfillX: ViewportUnderfill, underfillY: ViewportUnderfill)` with:
    - read-only state `scale: Float`, `rasterScale: Float`, `offsetX: Float`, `offsetY: Float`
    - `var geometry: ViewportGeometry`
    - `fun applyPan(pan: Offset)`, `fun applyZoom(zoomFactor: Float, centroid: Offset)`
    - `fun snapOffsetX(value: Float)`, `fun snapOffsetY(value: Float)`
    - `suspend fun animateOffsetXTo(target: Float)`, `suspend fun animateOffsetYTo(target: Float)`
    - `fun settleRaster()`, `fun reset()`
    - `fun cancelFling()`, `fun startFling(scope: CoroutineScope, density: Density, velocity: Velocity)`
  - `@Composable internal fun rememberReaderViewportState(deferRaster: Boolean, underfillX: ViewportUnderfill, underfillY: ViewportUnderfill): ReaderViewportState`
  - `internal fun Modifier.readerViewportGestures(state: ReaderViewportState, scope: CoroutineScope, key: Any?, enabled: Boolean, allowSingleFingerPan: () -> Boolean, allowFling: Boolean, onManualViewportChange: () -> Unit): Modifier`

- [ ] **Step 1: Write the failing tests**

Create `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderViewportStateTest.kt`:

```kotlin
package com.keynumber.folino.reader

import androidx.compose.ui.geometry.Offset
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Unit tests for [ReaderViewportState] — the snapshot-state holder the three reader surfaces share.
 *
 * The zoom tests are the regression for the bug this replaced: the old surfaces wrote the focal
 * correction back through `ScrollState.scrollTo`, which clamped against a `maxValue` describing the
 * PREVIOUS frame's layout. Zooming in pinned the offset to a stale upper bound and the anchor slid to
 * the top-left. Clamping against the extent at the new scale is what fixes it.
 */
class ReaderViewportStateTest {

    /** A 1000x800 viewport over content that is 1000x4000 px at scale 1, with no padding. */
    private fun state(
        deferRaster: Boolean = false,
        underfillY: ViewportUnderfill = ViewportUnderfill.START,
    ) = ReaderViewportState(deferRaster, ViewportUnderfill.START, underfillY).apply {
        geometry = ViewportGeometry(
            viewportWidthPx = 1000f,
            viewportHeightPx = 800f,
            unitContentWidthPx = 1000f,
            unitContentHeightPx = 4000f,
        )
    }

    @Test fun applyPan_movesOppositeTheFinger() {
        val s = state()
        s.setOffsetY(500f)
        s.applyPan(Offset(0f, -120f)) // finger travels up ⇒ content scrolls down
        assertEquals(620f, s.offsetY, 0.01f)
    }

    @Test fun applyPan_clampsAtTheTop() {
        val s = state()
        s.setOffsetY(40f)
        s.applyPan(Offset(0f, 400f))
        assertEquals(0f, s.offsetY, 0.01f)
    }

    @Test fun applyPan_doesNotMoveHorizontallyAtFitWidth() {
        val s = state()
        s.applyPan(Offset(-300f, 0f))
        assertEquals(0f, s.offsetX, 0.01f)
    }

    @Test fun applyZoom_holdsTheCentroid() {
        val s = state()
        s.setOffsetY(600f)
        val centroid = Offset(500f, 300f)
        val documentY = (s.offsetY + centroid.y) / s.scale
        s.applyZoom(zoomFactor = 2f, centroid = centroid)
        assertEquals(2f, s.scale, 0.001f)
        assertEquals(centroid.y, s.scale * documentY - s.offsetY, 0.05f)
    }

    @Test fun applyZoom_doesNotCollapseToTheTopLeft() {
        // The regression: zooming in near the bottom of a long score must not snap the viewport home.
        val s = state()
        s.setOffsetY(3000f)
        s.applyZoom(zoomFactor = 1.5f, centroid = Offset(500f, 400f))
        assert(s.offsetY > 3000f) { "expected the offset to grow with the zoom, was ${s.offsetY}" }
    }

    @Test fun applyZoom_clampsIntoTheNewExtent() {
        // Zoom in, ride to the very bottom, then zoom back out: the offset has to come back inside the
        // shrunken extent rather than sitting past its new end.
        val s = state()
        s.applyZoom(zoomFactor = 4f, centroid = Offset(500f, 400f))
        s.setOffsetY(Float.MAX_VALUE) // clamps to the maximum at scale 4: 16000 - 800
        assertEquals(15200f, s.offsetY, 0.01f)
        s.applyZoom(zoomFactor = 0.5f, centroid = Offset(500f, 400f))
        assertEquals(2f, s.scale, 0.001f)
        assertEquals(7200f, s.offsetY, 0.01f) // the maximum at scale 2: 8000 - 800
    }

    @Test fun underfillCenter_centersShortContent() {
        val s = ReaderViewportState(false, ViewportUnderfill.START, ViewportUnderfill.CENTER).apply {
            geometry = ViewportGeometry(
                viewportWidthPx = 1000f,
                viewportHeightPx = 800f,
                unitContentWidthPx = 3000f,
                unitContentHeightPx = 400f,
            )
        }
        s.setOffsetY(0f)
        assertEquals(-200f, s.offsetY, 0.01f)
    }

    @Test fun deferRaster_holdsTheRasterScaleUntilSettled() {
        val s = state(deferRaster = true)
        s.applyZoom(zoomFactor = 2f, centroid = Offset(500f, 400f))
        assertEquals(2f, s.scale, 0.001f)
        assertEquals(1f, s.rasterScale, 0.001f)
        s.settleRaster()
        assertEquals(2f, s.rasterScale, 0.001f)
    }

    @Test fun withoutDeferRaster_theRasterScaleTracksTheScale() {
        val s = state(deferRaster = false)
        s.applyZoom(zoomFactor = 2f, centroid = Offset(500f, 400f))
        assertEquals(2f, s.rasterScale, 0.001f)
    }

    @Test fun reset_returnsToFitAndOrigin() {
        val s = state()
        s.setOffsetY(900f)
        s.applyZoom(zoomFactor = 3f, centroid = Offset(500f, 400f))
        s.reset()
        assertEquals(1f, s.scale, 0.001f)
        assertEquals(1f, s.rasterScale, 0.001f)
        assertEquals(0f, s.offsetX, 0.001f)
        assertEquals(0f, s.offsetY, 0.001f)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --tests "*ReaderViewportStateTest*" --no-daemon`

Expected: FAIL — compilation error, `ReaderViewportState` and `ViewportGeometry` unresolved.

- [ ] **Step 3: Append the state holder and gesture modifier**

Append to `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewport.kt`, and add these imports at the top of the file:

```kotlin
import androidx.compose.animation.core.AnimationState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDecay
import androidx.compose.animation.core.animateTo
import androidx.compose.animation.core.spring
import androidx.compose.animation.splineBasedDecay
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerEvent
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Velocity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlin.math.abs
```

Body:

```kotlin
/**
 * Everything a [ReaderViewportState] needs from its surface's layout, in px, republished on every
 * composition that changes it.
 *
 * The scaling and non-scaling parts are kept apart because clamping has to be evaluated at a scale the
 * layout has not run at yet — mid-pinch, the extent for the frame being computed does not exist in any
 * measured node. [unitContentWidthPx] / [unitContentHeightPx] are the content at scale 1;
 * [fixedPadXPx] / [fixedPadYPx] are padding that never scales; [leadingPadYPx] is the part of the fixed
 * vertical padding that sits BEFORE the content, which the focal correction has to hold out of the
 * scaling.
 */
internal data class ViewportGeometry(
    val viewportWidthPx: Float = 0f,
    val viewportHeightPx: Float = 0f,
    val unitContentWidthPx: Float = 0f,
    val unitContentHeightPx: Float = 0f,
    val fixedPadXPx: Float = 0f,
    val fixedPadYPx: Float = 0f,
    val leadingPadYPx: Float = 0f,
)

/**
 * The reader's viewport: a zoom plus a two-dimensional offset, replacing the pair of Compose scroll
 * containers the vertical and horizontal surfaces used to nest.
 *
 * Offsets follow `ScrollState.value`: positive means scrolled forward (down / right). The surface turns
 * that into a layer transform with `translation = -offset`, so every consumer downstream — tap-to-cursor,
 * the auto-follow keep-in-view calls over JNI, the ink overlays — reads the same sign it always did.
 *
 * @param deferRaster true when the surface records its score at [rasterScale] and lets a layer transform
 *   cover the difference during a gesture (the vertical surface, whose score is one page as tall as the
 *   whole document). False when the surface re-records per frame, which is affordable for a single row or
 *   a single page; [rasterScale] then simply tracks [scale].
 */
internal class ReaderViewportState(
    private val deferRaster: Boolean,
    private val underfillX: ViewportUnderfill,
    private val underfillY: ViewportUnderfill,
) {
    var scale by mutableFloatStateOf(1f)
        private set

    /** The scale the score's draw commands were last recorded at. See [deferRaster]. */
    var rasterScale by mutableFloatStateOf(1f)
        private set

    var offsetX by mutableFloatStateOf(0f)
        private set

    var offsetY by mutableFloatStateOf(0f)
        private set

    var geometry by mutableStateOf(ViewportGeometry())

    private var flingJob: Job? = null

    private fun clampX(value: Float, atScale: Float = scale): Float = clampAxisOffset(
        value,
        axisContentPx(geometry.unitContentWidthPx, geometry.fixedPadXPx, atScale),
        geometry.viewportWidthPx,
        underfillX,
    )

    private fun clampY(value: Float, atScale: Float = scale): Float = clampAxisOffset(
        value,
        axisContentPx(geometry.unitContentHeightPx, geometry.fixedPadYPx, atScale),
        geometry.viewportHeightPx,
        underfillY,
    )

    // Named `snap…`, not `setOffset…`: `offsetX` / `offsetY` are `private set` properties, so Kotlin already
    // synthesises `setOffsetX(Float)` / `setOffsetY(Float)` on the JVM and an explicit function of that name
    // is a platform declaration clash. `snap` also reads as the no-animation counterpart to `animateOffsetXTo`.
    fun snapOffsetX(value: Float) { offsetX = clampX(value) }

    fun snapOffsetY(value: Float) { offsetY = clampY(value) }

    /** Pan by a finger delta. The content follows the finger, so the offset moves the other way. */
    fun applyPan(pan: Offset) {
        offsetX = clampX(offsetX - pan.x)
        offsetY = clampY(offsetY - pan.y)
    }

    /**
     * Zoom by [zoomFactor] about [centroid] (viewport px), holding the content point under the centroid
     * fixed. Clamped against the extent at the NEW scale — see [focalAdjustedOffset].
     */
    fun applyZoom(zoomFactor: Float, centroid: Offset) {
        if (centroid.x.isNaN() || centroid.y.isNaN()) return
        val newScale = coerceReaderScale(scale * zoomFactor)
        val ratio = newScale / scale
        if (ratio == 1f) return
        val focalX = focalAdjustedOffset(offsetX, centroid.x, ratio)
        val focalY = focalAdjustedOffset(offsetY, centroid.y, ratio, geometry.leadingPadYPx)
        scale = newScale
        if (!deferRaster) rasterScale = newScale
        offsetX = clampX(focalX, newScale)
        offsetY = clampY(focalY, newScale)
    }

    /** Re-record the score at the scale it is now shown at. No-op when the scale did not move. */
    fun settleRaster() { if (rasterScale != scale) rasterScale = scale }

    fun reset() {
        cancelFling()
        scale = 1f
        rasterScale = 1f
        offsetX = clampX(0f, 1f)
        offsetY = clampY(0f, 1f)
    }

    suspend fun animateOffsetXTo(target: Float) {
        AnimationState(initialValue = offsetX).animateTo(clampX(target), AUTO_FOLLOW_SPEC) {
            offsetX = clampX(value)
        }
    }

    suspend fun animateOffsetYTo(target: Float) {
        AnimationState(initialValue = offsetY).animateTo(clampY(target), AUTO_FOLLOW_SPEC) {
            offsetY = clampY(value)
        }
    }

    fun cancelFling() {
        flingJob?.cancel()
        flingJob = null
    }

    /**
     * Coast on after the fingers lift. [velocity] is the pointer's, so each axis is negated into offset
     * space. Each axis stops on its own the moment it reaches an edge — there is no rubber-band, so a
     * fling into the end of the score simply stops there.
     */
    fun startFling(scope: CoroutineScope, density: Density, velocity: Velocity) {
        cancelFling()
        if (abs(velocity.x) < 1f && abs(velocity.y) < 1f) return
        flingJob = scope.launch {
            val decay = splineBasedDecay<Float>(density)
            coroutineScope {
                launch {
                    AnimationState(initialValue = offsetX, initialVelocity = -velocity.x)
                        .animateDecay(decay) {
                            val clamped = clampX(value)
                            offsetX = clamped
                            if (clamped != value) cancelAnimation()
                        }
                }
                launch {
                    AnimationState(initialValue = offsetY, initialVelocity = -velocity.y)
                        .animateDecay(decay) {
                            val clamped = clampY(value)
                            offsetY = clamped
                            if (clamped != value) cancelAnimation()
                        }
                }
            }
        }
    }

    private companion object {
        /**
         * Spec for the auto-follow re-pin, standing in for what `ScrollState.animateScrollTo` used to
         * provide. This is the knob to turn if the playback re-pin reads as too eager or too sluggish.
         */
        val AUTO_FOLLOW_SPEC = spring<Float>(stiffness = Spring.StiffnessMediumLow, visibilityThreshold = 0.5f)
    }
}

@Composable
internal fun rememberReaderViewportState(
    deferRaster: Boolean,
    underfillX: ViewportUnderfill,
    underfillY: ViewportUnderfill,
): ReaderViewportState = remember(deferRaster, underfillX, underfillY) {
    ReaderViewportState(deferRaster, underfillX, underfillY)
}

/**
 * The reader's one gesture loop: free two-dimensional panning, a pinch that pans at the same time, and
 * momentum when the fingers lift.
 *
 * This deliberately replaces `Modifier.verticalScroll` + `Modifier.horizontalScroll`. Those are two
 * independent `scrollable` modifiers, and whichever one's drag detector wins the pointer slop owns the
 * gesture for its duration — which is why a diagonal drag used to resolve onto an axis and stay there.
 *
 * Movement is observed on the Initial pass and consumed, so a pan cancels the sibling
 * `detectTapGestures` that would otherwise seek. Single-finger panning waits for touch slop first: a tap
 * that wobbles a pixel has to stay a tap, or seeking becomes unreliable.
 *
 * @param key extra `pointerInput` restart key, on top of [state] and the flags below. Anything that
 *   changes the gesture's meaning and is stable across a gesture belongs here.
 * @param allowSingleFingerPan a LAMBDA, evaluated per event rather than captured. The page surface's
 *   answer depends on the live zoom (`scale > 1f`, so `HorizontalPager` keeps its swipe at fit), and a
 *   value read into the `pointerInput` key list would restart the handler mid-pinch and abort the
 *   gesture the instant the zoom crossed 1. False while annotating on every surface — a single finger
 *   is a stroke there.
 * @param allowFling false while annotating — coasting away from where the reader is writing loses their
 *   place. Safe as a plain value: it only changes when the pen is armed or put away.
 * @param onManualViewportChange fired once per gesture, on two-finger contact or on the first real
 *   single-finger movement. Suspends the playback auto-follow. Firing on pointer MOVEMENT rather than on
 *   a scroll-in-progress flag is load-bearing: a programmatic auto-follow re-pin emits no pointer input,
 *   so this can never mistake the auto-scroll's own animation for a gesture and latch suspension on.
 */
internal fun Modifier.readerViewportGestures(
    state: ReaderViewportState,
    scope: CoroutineScope,
    key: Any?,
    enabled: Boolean,
    allowSingleFingerPan: () -> Boolean,
    allowFling: Boolean,
    onManualViewportChange: () -> Unit,
): Modifier = pointerInput(state, key, enabled, allowFling) {
    if (!enabled) return@pointerInput
    val slop = viewConfiguration.touchSlop
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = false)
        state.cancelFling()
        val tracker = VelocityTracker()
        var notifiedManual = false
        var panned = false
        var pastSlop = false
        var travelled = 0f
        var event: PointerEvent
        do {
            event = awaitPointerEvent(PointerEventPass.Initial)
            val pressed = event.changes.count { it.pressed }
            if (pressed >= 2) {
                if (!notifiedManual) {
                    onManualViewportChange()
                    notifiedManual = true
                }
                val centroid = event.calculateCentroid(useCurrent = true)
                if (!centroid.x.isNaN() && !centroid.y.isNaN()) {
                    val zoom = event.calculateZoom()
                    if (zoom != 1f) state.applyZoom(zoom, centroid)
                    val pan = event.calculatePan()
                    if (pan != Offset.Zero) {
                        state.applyPan(pan)
                        panned = true
                    }
                }
                event.changes.forEach { if (it.positionChanged()) it.consume() }
                // A pinch does not seed the fling: the two-finger centroid is a poor velocity signal and
                // coasting out of a zoom feels like a slip rather than a throw.
                tracker.resetTracking()
                pastSlop = true
            } else if (pressed == 1 && allowSingleFingerPan()) {
                val change = event.changes.first { it.pressed }
                val pan = event.calculatePan()
                if (!pastSlop) {
                    travelled += pan.getDistance()
                    if (travelled >= slop) pastSlop = true
                }
                if (pastSlop && pan != Offset.Zero) {
                    if (!notifiedManual) {
                        onManualViewportChange()
                        notifiedManual = true
                    }
                    state.applyPan(pan)
                    panned = true
                    tracker.addPosition(change.uptimeMillis, change.position)
                    change.consume()
                }
            }
        } while (event.changes.any { it.pressed })
        if (allowFling && panned) {
            state.startFling(scope, this@pointerInput, tracker.calculateVelocity())
        }
        state.settleRaster()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --tests "*ReaderViewportStateTest*" --no-daemon`

Expected: PASS, 10 tests.

- [ ] **Step 5: Verify the module compiles**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin --no-daemon`

Expected: BUILD SUCCESSFUL. Nothing consumes the new state yet — the three surfaces still use their scroll containers.

- [ ] **Step 6: Commit**

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewport.kt Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderViewportStateTest.kt
git -C <worktree> commit -m "feat(reader-android): viewport state and one gesture loop for pan, pinch, and fling"
```

---

### Task 3: Adopt the viewport on the vertical surface

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt:1067-1477` (`ReadyScore`)

**Interfaces:**
- Consumes: `rememberReaderViewportState`, `ReaderViewportState`, `ViewportGeometry`, `ViewportUnderfill`, `Modifier.readerViewportGestures` from Task 2.
- Produces: nothing new for later tasks. Tasks 4 and 5 repeat the same substitution on their own surfaces.

**Context:** this surface renders the whole document as one tall page inside a scroll container, with `vPadPx` of unscaled breathing room above and below and `bottomPadPx` more below that. Two `pointerInput` blocks sit on the outer Box — one detecting a pinch, one detecting a manual drag for the auto-follow suspension — and both go away, replaced by `readerViewportGestures`.

- [ ] **Step 1: Replace the state declarations**

In `ReadyScore`, replace lines 1086-1107 — the `viewportSize`, `scaleState`/`scale`, `rasterScaleState`/`rasterScale`, `isDrawing`, `vScroll`, `hScroll`, `density`, `scope` declarations — with:

```kotlin
    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    // `deferRaster = true`: this surface's score is ONE page as tall as the whole document, so following
    // the live scale would re-record every draw command in it on each frame of a pinch. The bands stay
    // recorded at `rasterScale`, a layer transform covers the difference while the fingers are down, and
    // the one real re-raster happens when they lift.
    val viewport = rememberReaderViewportState(
        deferRaster = true,
        underfillX = ViewportUnderfill.START,
        underfillY = ViewportUnderfill.START,
    )
    val scale = viewport.scale
    val rasterScale = viewport.rasterScale
    // Drives AnnotationDryOverlay's reflow-recompute gate (skip recompute mid-stroke). MVP leaves this
    // always false and relies on the dry overlay's own recompute-on-`drawings`-change instead.
    val isDrawing = false

    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
```

- [ ] **Step 2: Point the camera-retire watch at the new state**

Replace the body of the `LaunchedEffect(Unit)` at lines 1124-1126 with:

```kotlin
    LaunchedEffect(Unit) {
        snapshotFlow { viewport.scale }.drop(1).collect { annotation?.inkHandoff?.releaseAll() }
    }
```

- [ ] **Step 3: Publish the geometry**

After the `bottomPadPx` declaration (line ~1139), insert:

```kotlin
    // Republished whenever the layout inputs move. The pads are the non-scaling part: `vPadPx` above and
    // below the page plus `bottomPadPx` of extra run-out under it, and `leadingPadYPx` is the top one,
    // which the focal correction holds out of the scaling.
    //
    // In a SideEffect, not inline: this writes snapshot state, and the only readers are the gesture loop
    // and the auto-follow effect, both of which run after the composition commits.
    SideEffect {
        viewport.geometry = ViewportGeometry(
            viewportWidthPx = viewportSize.width.toFloat(),
            viewportHeightPx = viewportSize.height.toFloat(),
            unitContentWidthPx = page.widthMM.toFloat() * fitPxPerMM,
            unitContentHeightPx = page.heightMM.toFloat() * fitPxPerMM,
            fixedPadYPx = vPadPx * 2 + bottomPadPx,
            leadingPadYPx = vPadPx,
        )
    }
```

Add `import androidx.compose.runtime.SideEffect` to the file's imports if absent.

- [ ] **Step 4: Move the auto-follow effect onto the viewport**

In the `LaunchedEffect` at lines 1146-1218, make these substitutions and leave everything else — including all four JNI calls — untouched:

- `vScroll.value.toDouble()` → `viewport.offsetY.toDouble()` (both occurrences, lines ~1182 and ~1192)
- `if (abs(newY - vScroll.value) >= 0.5f) { vScroll.animateScrollTo(newY.toInt().coerceAtLeast(0)) }` →
  ```kotlin
                if (abs(newY - viewport.offsetY) >= 0.5f) {
                    viewport.animateOffsetYTo(newY)
                }
  ```
- `hScroll.value.toDouble()` → `viewport.offsetX.toDouble()` (line ~1207)
- `if (abs(newX - hScroll.value) >= 0.5f) { hScroll.animateScrollTo(newX.toInt().coerceAtLeast(0)) }` →
  ```kotlin
                    if (abs(newX - viewport.offsetX) >= 0.5f) {
                        viewport.animateOffsetXTo(newX)
                    }
  ```

The `coerceAtLeast(0)` guards go away because `animateOffsetYTo` / `animateOffsetXTo` clamp internally.

- [ ] **Step 5: Replace the three pointer-input blocks with one**

Replace lines 1220-1318 — the outer `Box(Modifier…)` argument list, from `.pointerInput(scoreHandle, …)` through the closing of the suspension detector — with:

```kotlin
    Box(
        Modifier
            .fillMaxSize()
            .onSizeChanged { viewportSize = it }
            // Tap-to-seek + audition. Lives in its own pointerInput so it coexists with the viewport
            // gestures below: `detectTapGestures` only fires on a tap, while the viewport loop consumes
            // moves past touch slop — neither steals the other's events. The tap point is in this outer
            // (viewport) px space; fold the offsets and the fixed vertical padding into the content offset
            // so the helper's divide yields document-mm. Disabled while annotating: a single-finger tap
            // there is the wet overlay's to consume, not a seek.
            .pointerInput(scoreHandle, fitPxPerMM, layoutOptions, annotationMode) {
                if (annotationMode) return@pointerInput
                val handle = scoreHandle ?: return@pointerInput
                if (fitPxPerMM <= 0f) return@pointerInput
                val optionsBytes = layoutOptions.encode()
                detectTapGestures { offset ->
                    val cursor = nearestCursorForTap(
                        tap = offset,
                        contentOffsetPx = Offset(-viewport.offsetX, vPadPx - viewport.offsetY),
                        pxPerMM = fitPxPerMM,
                        scale = viewport.scale,
                        scoreHandle = handle,
                        layoutOptionsBytes = optionsBytes,
                    ) ?: return@detectTapGestures
                    audioVm.handleTap(cursor)
                }
            }
            // Pan, pinch, and fling. While annotating only two-finger gestures are taken — a single finger
            // is a stroke — and momentum is off so the score does not coast away from where the reader is
            // writing.
            .readerViewportGestures(
                state = viewport,
                scope = scope,
                key = fitPxPerMM,
                enabled = fitPxPerMM > 0f,
                allowSingleFingerPan = { !annotationMode },
                allowFling = !annotationMode,
                onManualViewportChange = audioVm::suspendPlaybackFollowForManualViewportChange,
            ),
        contentAlignment = Alignment.TopStart,
    ) {
```

- [ ] **Step 6: Replace the scroll container with the pan layer**

Replace lines 1320-1342 — the `scrollEnabled` / `scrollModifier` block and the `Box(scrollModifier) {` that follows — with:

```kotlin
        // Panning is a layer translation now, not a scroll container's placement. The clip and the
        // `graphicsLayer` MUST stay on this one node: the layer is what gives the content its own
        // RenderNode, and without it every wet-ink frame invalidates to the root and re-records the whole
        // score's display list, which is what made drawing crawl on long scores.
        //
        // Read inside the layer block, not captured outside it, so a pan or a pinch updates this one
        // transform during the LAYER phase instead of recomposing the score.
        Box(
            Modifier
                .clipToBounds()
                .graphicsLayer {
                    translationX = -viewport.offsetX
                    translationY = -viewport.offsetY
                },
        ) {
```

Add `import androidx.compose.ui.draw.clipToBounds` to the file's imports if it is not already present.

- [ ] **Step 7: Point the score surface and the ink wet window at the viewport**

Inside that Box, the content `Box(Modifier.size(…))` at lines 1343-1349 keeps its current sizing — the overlays stacked on it are `fillMaxSize` siblings and must keep matching the drawn content at the live scale.

In `scoreSurfaceModifier` (lines 1359-1369), replace the layer block's two state reads:

```kotlin
                        .graphicsLayer {
                            val zoom = viewport.scale / viewport.rasterScale
                            scaleX = zoom
                            scaleY = zoom
                            transformOrigin = TransformOrigin(0f, 0f)
                        }
```

and change its `remember` key list from `remember(vPadPx, density)` to `remember(vPadPx, density, viewport)`.

In the annotation block (lines 1439-1472), replace the wet-window declaration at line 1449 and the `wetModifier` offset:

```kotlin
                        // The wet window is pinned to the visible band by offsetting it by the viewport
                        // offset, and `worldToScreen` folds that same offset in (plus the vPad the
                        // siblings get from their padding) so document coordinates land exactly where the
                        // dry layer paints them.
                        //
                        // Unlike before, this offset CAN move mid-annotation: a two-finger pan is allowed
                        // while the pen is out. That is sound because the two are mutually exclusive in
                        // time — the wet layer cancels its stroke when a second finger lands — and the
                        // recomposition it costs per pan frame is the same cost a pinch already paid here.
                        val wetWindowTopPx = viewport.offsetY.roundToInt()
```

and leave `wetWindowHeightPx`, the `AnnotationLayers` call, the `wetWorldToScreen` matrix, and the `wetModifier` as they are — they already read `wetWindowTopPx` and `scale`. Add `import kotlin.math.roundToInt` if absent.

- [ ] **Step 8: Verify the module compiles**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin --no-daemon`

Expected: BUILD SUCCESSFUL. If `rememberScrollState`, `verticalScroll`, or `horizontalScroll` are now unused in the file, leave the imports in place — `HorizontalScore` still uses them until Task 4.

- [ ] **Step 9: Run the whole module's unit tests**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --no-daemon`

Expected: PASS, no regressions.

- [ ] **Step 10: Install and verify on the device**

```bash
adb devices
```

Expected: the physical Pixel is listed. If no device is attached, stop and ask the user to connect one — do not start an emulator.

```bash
Android/gradlew -p Android :app:installDebug --no-daemon
adb shell am start -n com.keynumber.folino/.MainActivity
```

Open a score in vertical mode and check:

- A diagonal drag tracks the finger — no snap onto an axis.
- A pinch holds its centroid at the middle of the screen, near an edge, and near a corner.
- Lifting one finger of a pinch does not jump the viewport. (An asymmetric finger lift is exactly what caused the iOS pinch-release jump; verify explicitly.)
- A flick coasts and decays, and stops cleanly at the top and bottom of the score.
- A single tap still seeks.
- During playback, a pinch or a drag suspends auto-follow; pressing play again resumes it.
- With the pen armed: a single finger draws, two fingers pan and zoom, and there is no coast on release.
- **On the longest score available**, panning stays as smooth as it was before this change, and drawing
  ink on it does not crawl. This is the band-culling and RenderNode check: panning moved from a scroll
  container's placement to a layer translation, and both properties depended on that container.

Also check logcat for crashes: `adb logcat -d -s AndroidRuntime`.

- [ ] **Step 11: Commit**

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git -C <worktree> commit -m "feat(reader-android): free-form pan, pinch, and fling on the vertical surface"
```

---

### Task 4: Adopt the viewport on the horizontal surface

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt:2048-2377` (`HorizontalScore`)

**Interfaces:**
- Consumes: the same Task 2 API as Task 3.
- Produces: nothing new.

**Context:** this surface lays the score out as one natural-width row. It scrolls horizontally always and vertically only when a zoomed row grows taller than the viewport; when it is shorter, it is centered. That conditional is what `ViewportUnderfill.CENTER` replaces. This surface re-records per frame (`ScorePage(pxPerMM = fitPxPerMM * scale)`) and keeps doing so, so it uses `deferRaster = false`. It is also the PiP rendition's surface — `pipFit` changes only `fitPxPerMM`, and nothing here alters that.

- [ ] **Step 1: Replace the state declarations**

Replace lines 2067-2073 with:

```kotlin
    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    // `deferRaster = false`: a single row is cheap enough to re-record per frame, which this surface
    // already does. `underfillY = CENTER` is the short-row case — a row shorter than the viewport floats
    // in the middle of it rather than sitting at the top, which is what the old `needsVScroll` branch and
    // its centering Box did between them.
    val viewport = rememberReaderViewportState(
        deferRaster = false,
        underfillX = ViewportUnderfill.START,
        underfillY = ViewportUnderfill.CENTER,
    )
    val scale = viewport.scale

    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
```

- [ ] **Step 2: Publish the geometry**

After the `needsVScroll` declaration (line ~2092), insert:

```kotlin
    SideEffect {
        viewport.geometry = ViewportGeometry(
            viewportWidthPx = viewportSize.width.toFloat(),
            viewportHeightPx = viewportSize.height.toFloat(),
            unitContentWidthPx = page.widthMM.toFloat() * fitPxPerMM,
            unitContentHeightPx = page.heightMM.toFloat() * fitPxPerMM,
        )
    }
```

- [ ] **Step 3: Move the auto-follow effect onto the viewport**

In the `LaunchedEffect` at lines 2097-2168, substitute:

- `hScroll.value.toDouble()` → `viewport.offsetX.toDouble()` (lines ~2135 and ~2140)
- `if (abs(newX - hScroll.value) >= 0.5f) { hScroll.animateScrollTo(newX.toInt().coerceAtLeast(0)) }` →
  ```kotlin
                    if (abs(newX - viewport.offsetX) >= 0.5f) {
                        viewport.animateOffsetXTo(newX)
                    }
  ```
- `vScroll.value.toDouble()` → `viewport.offsetY.toDouble()` (line ~2156)
- `if (abs(newY - vScroll.value) >= 0.5f) { vScroll.animateScrollTo(newY.toInt().coerceAtLeast(0)) }` →
  ```kotlin
                        if (abs(newY - viewport.offsetY) >= 0.5f) {
                            viewport.animateOffsetYTo(newY)
                        }
  ```

Leave the `if (needsVScroll)` gate around the vertical branch and both JNI calls untouched.

- [ ] **Step 4: Replace the three pointer-input blocks with one**

Replace lines 2170-2251 — from `Box(` through `contentAlignment = Alignment.Center,` — with:

```kotlin
    Box(
        Modifier
            .fillMaxSize()
            .onSizeChanged { viewportSize = it }
            // Tap-to-seek + audition. Separate pointerInput from the viewport loop (see ReadyScore).
            // The row's position is now one offset pair, so both axes fold into the content offset
            // unconditionally — the short-row centering that used to need its own branch arrives as a
            // negative offsetY from `ViewportUnderfill.CENTER`.
            .pointerInput(scoreHandle, fitPxPerMM, layoutOptions, annotationMode) {
                // While annotating, a tap is the start of a stroke — never a seek.
                if (annotationMode) return@pointerInput
                val handle = scoreHandle ?: return@pointerInput
                if (fitPxPerMM <= 0f) return@pointerInput
                val optionsBytes = layoutOptions.encode()
                detectTapGestures { offset ->
                    val cursor = nearestCursorForTap(
                        tap = offset,
                        contentOffsetPx = Offset(-viewport.offsetX, -viewport.offsetY),
                        pxPerMM = fitPxPerMM,
                        scale = viewport.scale,
                        scoreHandle = handle,
                        layoutOptionsBytes = optionsBytes,
                    ) ?: return@detectTapGestures
                    audioVm.handleTap(cursor)
                }
            }
            .readerViewportGestures(
                state = viewport,
                scope = scope,
                key = fitPxPerMM,
                enabled = fitPxPerMM > 0f,
                allowSingleFingerPan = { !annotationMode },
                allowFling = !annotationMode,
                onManualViewportChange = audioVm::suspendPlaybackFollowForManualViewportChange,
            ),
        contentAlignment = Alignment.TopStart,
    ) {
```

- [ ] **Step 5: Replace the scroll container and its centering box**

Replace lines 2252-2286 — from the `scrollEnabled` comment through the inner `Box(Modifier.size(width = …, height = contentHeightPx …)) {` — with:

```kotlin
        // Panning is a layer translation; the clip and the layer stay on one node so the content keeps
        // its own RenderNode (see the vertical surface for why that matters to ink).
        Box(
            Modifier
                .clipToBounds()
                .graphicsLayer {
                    translationX = -viewport.offsetX
                    translationY = -viewport.offsetY
                },
        ) {
            // Exactly the scaled row. The outer viewport-height box that used to center a short row is
            // gone: centering is now the clamp's `ViewportUnderfill.CENTER` result.
            Box(
                Modifier.size(
                    width = with(density) { contentWidthPx.toDp() },
                    height = with(density) { contentHeightPx.toDp() },
                ),
            ) {
```

This removes one level of nesting, so delete the matching extra closing brace at the end of the composable — the block that used to close the outer centering Box (line ~2374).

- [ ] **Step 6: Point the ink wet window at the viewport**

Replace the wet-window declarations at lines 2343-2347 with:

```kotlin
                            // WIDTH is the clamped axis here: the horizontal layout is one natural-width
                            // row — far past the 65536 px front-buffer limit on a long piece — while its
                            // height is a single system. So the wet window tracks the horizontal offset,
                            // and vertical only matters when the zoomed row is tall enough to scroll.
                            //
                            // A two-finger pan can move these mid-annotation now; see the vertical
                            // surface's note on why that is sound.
                            val wetWindowLeftPx = viewport.offsetX.roundToInt()
                            val wetWindowTopPx = if (needsVScroll) viewport.offsetY.roundToInt() else 0
                            val wetWindowWidthPx = viewportSize.width.coerceAtLeast(0)
                            val wetWindowHeightPx =
                                if (needsVScroll) viewportSize.height.coerceAtLeast(0) else contentHeightPx.toInt()
```

The `AnnotationLayers` call below it needs no change — its matrix and modifier already read these two values.

- [ ] **Step 7: Verify the module compiles**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin --no-daemon`

Expected: BUILD SUCCESSFUL. `rememberScrollState`, `verticalScroll`, and `horizontalScroll` are now unused in `ReaderScreen.kt` — delete those three imports (lines 13, 25, 26) and rerun until clean.

- [ ] **Step 8: Run the module's unit tests**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --no-daemon`

Expected: PASS.

- [ ] **Step 9: Install and verify on the device**

```bash
Android/gradlew -p Android :app:installDebug --no-daemon
adb shell am start -n com.keynumber.folino/.MainActivity
```

Switch the reader to horizontal layout (Settings → Layout, or the display inspector) and check:

- At fit, the row is vertically centered and a drag pans it horizontally with no vertical drift.
- Zoomed until the row is taller than the screen, a diagonal drag moves both axes at once.
- A pinch holds its centroid.
- A flick coasts and stops at the start and end of the row.
- Playback follows the cursor measure-by-measure, and a gesture suspends that follow.
- A single tap still seeks; the pen still draws and two fingers still pan.
- Enter picture-in-picture and confirm the PiP rendition still fits and follows.

- [ ] **Step 10: Commit**

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git -C <worktree> commit -m "feat(reader-android): free-form pan, pinch, and fling on the horizontal surface"
```

---

### Task 5: Rebase the page surface onto the shared viewport

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PagedScore.kt:85-443`

**Interfaces:**
- Consumes: the same Task 2 API.
- Produces: nothing new.

**Context:** this surface already pans freely and anchors its zoom at the centroid, so the behavioral delta is momentum. The structural delta is that its inline clamp and focal math — the second copy of what Task 1 extracted — go away, and its `panOffset` (a content translation, ≤ 0) flips to the shared scroll-offset sign. A page is viewport-sized at fit, so the geometry is just the viewport, and it does not vary per page.

`HorizontalPager` keeps `userScrollEnabled = scale == 1f && !annotationMode`: a zoomed page does not turn on a drag. That is what `allowSingleFingerPan = scale > 1f && !annotationMode` preserves — at fit, the viewport loop takes nothing and the pager gets its swipe.

- [ ] **Step 1: Replace the state declarations**

Replace lines 90-91 with:

```kotlin
    // `deferRaster = false`: a page is about a screenful, so re-recording it per pinch frame is fine —
    // which is what this surface already did. Underfill is START on both axes: a page is viewport-sized
    // at fit, so the underfill case only arises transiently and the top-left is where it belongs.
    val viewport = rememberReaderViewportState(
        deferRaster = false,
        underfillX = ViewportUnderfill.START,
        underfillY = ViewportUnderfill.START,
    )
    val scale = viewport.scale
    // Content translation, derived from the viewport's scroll-space offset. Every consumer below — the
    // cursor, loop, and A–B overlays, the annotation layers, the nav overlay — takes a translation, so
    // convert once here rather than negating at each site.
    val panOffset = Offset(-viewport.offsetX, -viewport.offsetY)
```

- [ ] **Step 2: Publish the geometry and switch the page-turn reset**

After the `fitPxPerMM` declaration (line ~96), insert:

```kotlin
    // A page is laid out to the viewport, so the content at scale 1 IS the viewport. No fixed padding,
    // and no per-page variation — this belongs above the pager, not inside a page.
    SideEffect {
        viewport.geometry = ViewportGeometry(
            viewportWidthPx = viewportSize.width.toFloat(),
            viewportHeightPx = viewportSize.height.toFloat(),
            unitContentWidthPx = viewportSize.width.toFloat(),
            unitContentHeightPx = viewportSize.height.toFloat(),
        )
    }
```

Add `import androidx.compose.runtime.SideEffect` to the file's imports.

Replace line 131 with:

```kotlin
    // Reset zoom + pan on page turn (iOS parity: each page enters at fit-width). Also stops a fling that
    // was still coasting when the page changed under it.
    LaunchedEffect(pagerState.currentPage) { viewport.reset() }
```

- [ ] **Step 3: Replace the pinch/pan pointer input**

Replace lines 249-314 — the whole `// Pinch-zoom + pan gesture lives INSIDE the pager page …` comment and the `.pointerInput(fitPxPerMM, pageIndex, annotationMode) { … }` block that follows, up to and including its closing `},` — with:

```kotlin
                    // Pan, pinch, and fling live INSIDE the pager page (not as a sibling overlay), so
                    // `HorizontalPager` still receives single-finger horizontal swipes at fit:
                    // `allowSingleFingerPan` is false there, so nothing is consumed and the swipe reaches
                    // the pager. Zoomed, the drag pans the page instead and does not turn it.
                    .readerViewportGestures(
                        state = viewport,
                        scope = scope,
                        key = fitPxPerMM,
                        enabled = fitPxPerMM > 0f,
                        // A lambda, not a value: this answer flips the instant a pinch crosses fit, and a
                        // value in the `pointerInput` key list would restart the handler mid-gesture.
                        allowSingleFingerPan = { viewport.scale > 1f && !annotationMode },
                        allowFling = !annotationMode,
                        onManualViewportChange = audioVm::suspendPlaybackFollowForManualViewportChange,
                    ),
```

- [ ] **Step 4: Update the remaining `panOffset` readers**

These now read the local `panOffset` derived in Step 1, so most sites are unchanged. Verify each still compiles and reads correctly:

- The tap `contentOffsetPx = Offset(panOffset.x, panOffset.y - pageTopPx)` (line ~240) — unchanged.
- The content Box's `graphicsLayer { translationX = panOffset.x; translationY = panOffset.y }` (line ~324) — unchanged.
- `PlaybackCursorOverlay`, `LoopHighlightOverlay`, `AbBoundaryMarkersOverlay`, and the annotation `pageOffset` (lines ~345, ~357, ~368, ~381) — unchanged.
- `PageTapOverlay`'s `graphicsLayer` (lines ~434-440) — unchanged.

Remove `import androidx.compose.runtime.mutableFloatStateOf` and the now-unused gesture imports at lines 5-9 (`awaitEachGesture`, `awaitFirstDown`, `calculateCentroid`, `calculatePan`, `calculateZoom`) and `import androidx.compose.ui.input.pointer.positionChanged` (line 34) if the compiler reports them unused.

- [ ] **Step 5: Verify the module compiles**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:compileDebugKotlin --no-daemon`

Expected: BUILD SUCCESSFUL.

- [ ] **Step 6: Run the module's unit tests**

Run: `Android/gradlew -p Android :FolinoReaderAndroid:testDebugUnitTest --no-daemon`

Expected: PASS.

- [ ] **Step 7: Install and verify on the device**

```bash
Android/gradlew -p Android :app:installDebug --no-daemon
adb shell am start -n com.keynumber.folino/.MainActivity
```

Switch the reader to page layout and check:

- At fit, a horizontal swipe turns the page and a vertical drag does nothing.
- Zoomed, a diagonal drag pans in both axes and does NOT turn the page.
- A pinch holds its centroid; a flick while zoomed coasts and stops at the page edge.
- Turning the page resets to fit at the top-left, and a fling in flight when the page turns does not carry over.
- The edge tap zones still navigate, and they scale and pan with the page.
- A center tap still seeks; the pen still draws and two fingers still pan.

- [ ] **Step 8: Commit**

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PagedScore.kt
git -C <worktree> commit -m "feat(reader-android): put the page surface on the shared viewport and give it momentum"
```

---

### Task 6: Final sweep

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt`, `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PagedScore.kt` (dead code and comments only)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Remove dead code**

Search both files for leftovers and delete what no longer has a reader:

```bash
rg -n 'ScrollState|verticalScroll|horizontalScroll|rememberScrollState|scaleState|rasterScaleState|isZoomed|needsVScroll|scrollEnabled' Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/
```

`isZoomed` (vertical) and `needsVScroll` (horizontal) are still live — both still gate an auto-follow branch and, for `needsVScroll`, the ink wet-window height. Everything else on that list should be gone.

- [ ] **Step 2: Reflow the comments you touched**

Comment paragraphs go up to 120 columns. Check the blocks edited in Tasks 3-5 and rewrap any that were left narrower or wider.

- [ ] **Step 3: Run the full Android unit-test suite**

Run: `Android/gradlew -p Android testDebugUnitTest --no-daemon`

Expected: PASS across all modules.

- [ ] **Step 4: Build and install once more**

```bash
Android/gradlew -p Android :app:installDebug --no-daemon
adb shell am start -n com.keynumber.folino/.MainActivity
```

- [ ] **Step 5: Cross-mode verification pass**

With one score open, switch between vertical, horizontal, and page without leaving the reader, and confirm each mode enters at fit with the viewport at its home position and that gestures behave as verified in Tasks 3-5. Then check logcat is clean:

```bash
adb logcat -d -s AndroidRuntime
```

Expected: no `FATAL EXCEPTION`.

- [ ] **Step 6: Report to the user**

Summarize what shipped, and flag the one deliberate regression for their judgment: the edge glow that came with Compose's scroll containers is gone, and with rubber-band out of scope, reaching an edge is now a hard stop. Ask whether that reads acceptably in the hand before deciding whether to add rubber-band.

- [ ] **Step 7: Commit**

```bash
git -C <worktree> add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PagedScore.kt
git -C <worktree> commit -m "chore(reader-android): drop the scroll-container leftovers"
```

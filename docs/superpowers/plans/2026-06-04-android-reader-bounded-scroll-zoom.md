# Android Reader — Bounded Scroll + Pinch Zoom Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Android Reader Chrome-mobile scroll semantics — at fit-width no horizontal scroll, when zoomed horizontal scroll bounded to content edges, vertical always bounded to content edges, with native Android stretch overscroll and focal-point-follow pinch zoom.

**Architecture:** Mirror iOS `ScoreScrollHost`: a native Compose scroll container (Folino side) owns scroll bounds + stretch overscroll + fling; pinch zoom is a content-size + content-`pxPerMM` change (re-rasterized, sharp). The shared swift-sheet-music renderer gains a gesture-free `ScorePage` composable so it no longer fights the scroll container. Playback auto-scroll drives the scroll state via the existing shared keep-in-view JNI call.

**Tech Stack:** Kotlin, Jetbrains Compose (foundation `verticalScroll`/`horizontalScroll`, `pointerInput`/`awaitEachGesture`), swift-sheet-music Android Compose lib (mavenLocal `0.0.0-SNAPSHOT`), FolinoReaderJNI (shared Domain scroll-follow via swift-java).

**Spec:** `docs/superpowers/specs/2026-06-03-android-reader-bounded-scroll-zoom-design.md`

**Verification note:** The Folino Android modules have no JUnit/unit-test harness; established practice (and the gesture/scroll nature of this change) is **on-device verification on the Pixel 8a** (install + launch). This plan follows that pattern rather than introducing a test framework for a trivial pure formula. The shared keep-in-view math is already unit-covered on the Swift side.

---

## File Structure

| File | Repo | Responsibility | Change |
| --- | --- | --- | --- |
| `Android/SheetMusicComposeAndroid/.../compose/render/ScoreCanvas.kt` | swift-sheet-music | Page renderer | **Add** public gesture-free `ScorePage`; leave `ScoreCanvas` untouched |
| `Android/FolinoReaderAndroid/.../reader/ReaderScreen.kt` | Folino | Reader screen + scroll/zoom host | **Rewrite** `ReadyScore`; replace `ScoreTransform`/`keepInViewOffsetY` panOffset coupling with scroll-state host |
| `Android/FolinoReaderAndroid/build.gradle.kts` | Folino | Dependency pin | No change (consumes `0.0.0-SNAPSHOT`; re-publish overwrites it) |

Helpers introduced in `ReaderScreen.kt` (pure, file-private):
- `focalAdjustedOffset(currentScroll, centroid, ratio)` — keep the content point under the pinch centroid fixed.
- `contentExtentToScrollOffset(...)` mapping for keep-in-view (reuses the shared JNI call).

---

## Phase A — swift-sheet-music: add `ScorePage` renderer

Working dir: `~/Developer/Personal/swift-packages/swift-sheet-music`

### Task A1: Add the gesture-free `ScorePage` composable

**Files:**
- Modify: `Android/SheetMusicComposeAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/compose/render/ScoreCanvas.kt`

- [ ] **Step 1: Add `ScorePage` above `drawPage`**

Insert this composable into `ScoreCanvas.kt` (after the existing `ScoreCanvas` function, before `private fun DrawScope.drawPage`). It reuses the existing private `drawPage` and installs **no** `pointerInput` and **no** `withTransform` translate — the caller's scroll container translates, and zoom is baked into `pxPerMM`.

```kotlin
/**
 * Gesture-free renderer for a single [EncodablePage]. Unlike [ScoreCanvas],
 * this installs no pan/zoom pointer input and applies no translate — the
 * caller is expected to host it inside a native scroll container (which owns
 * scroll bounds, fling, and overscroll) and to bake zoom into [pxPerMM]
 * (`fitPxPerMM * scale`). Drawing at the zoomed [pxPerMM] re-rasterizes glyphs
 * at the target resolution, so the score stays sharp at every zoom level.
 *
 * @param page          the page to draw (document coordinates in mm)
 * @param fontProvider  supplies the SMuFL + text typefaces
 * @param pxPerMM       pixels per document-millimetre, already including zoom
 * @param modifier      should size the canvas to the zoomed content extent
 */
@Composable
fun ScorePage(
    page: EncodablePage,
    fontProvider: FontProvider,
    pxPerMM: Float,
    modifier: Modifier = Modifier,
) {
    val smufl = fontProvider.smuflTypeface()
    val text = fontProvider.textTypeface()
    Canvas(modifier = modifier) {
        drawPage(page, pxPerMM, smufl, text)
    }
}
```

- [ ] **Step 2: Verify the module compiles**

Run (from `~/Developer/Personal/swift-packages/swift-sheet-music/Android`):
```
./gradlew :SheetMusicComposeAndroid:compileReleaseKotlin
```
Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 3: Commit (in swift-sheet-music)**

```
git -C ~/Developer/Personal/swift-packages/swift-sheet-music add Android/SheetMusicComposeAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/compose/render/ScoreCanvas.kt
git -C ~/Developer/Personal/swift-packages/swift-sheet-music commit -m "feat(compose): add gesture-free ScorePage renderer for host-owned scroll"
```

### Task A2: Publish the Compose lib to mavenLocal

**Files:** none (publish only)

- [ ] **Step 1: Publish `0.0.0-SNAPSHOT` to mavenLocal**

Run (from `~/Developer/Personal/swift-packages/swift-sheet-music/Android`):
```
./gradlew -Pversion=0.0.0-SNAPSHOT :SheetMusicComposeAndroid:publishReleasePublicationToMavenLocal
```
Expected: `BUILD SUCCESSFUL`; artifact refreshed under
`~/.m2/repository/io/github/jiyimeta/sheet-music-compose-android/0.0.0-SNAPSHOT/`.

- [ ] **Step 2: Confirm `ScorePage` is in the published AAR's classes**

Run:
```
unzip -l ~/.m2/repository/io/github/jiyimeta/sheet-music-compose-android/0.0.0-SNAPSHOT/sheet-music-compose-android-0.0.0-SNAPSHOT.aar | grep -i ScoreCanvas
```
Expected: lists `ScoreCanvasKt.class` (where the top-level `ScorePage` lands). If the AAR is a thin wrapper, instead confirm via the Folino reader build picking it up in Phase D.

---

## Phase B — Folino: scroll/zoom host in `ReadyScore`

Working dir: `~/Developer/Personal/ios-apps/Folino-iOS`. All edits in
`Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt`.

### Task B1: Replace `ReadyScore` body with the scroll/zoom host

**Files:**
- Modify: `Android/FolinoReaderAndroid/.../reader/ReaderScreen.kt` (the `ReadyScore` composable, ~lines 97-159, and imports)

- [ ] **Step 1: Update imports**

Remove the now-unused `ScoreTransform` import and add scroll/gesture imports. Replace the existing render imports block. New imports to ensure present:

```kotlin
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.unit.IntSize
import io.github.jiyimeta.sheetmusic.compose.render.ScorePage
```

Remove:
```kotlin
import io.github.jiyimeta.sheetmusic.compose.render.ScoreTransform
```
(Keep `bundledFontProvider` and `FontProvider` usage as-is.)

- [ ] **Step 2: Rewrite the `ReadyScore` composable**

Replace the whole `ReadyScore` function (the existing `var transform … Box { ScoreCanvas(...) … PlaybackCursorOverlay(...) }`) with the scroll-host version below. This single rewrite covers: native vertical scroll (always) + horizontal scroll (only when zoomed), pinch zoom floored at fit-width (`scale ≥ 1`) with focal-point follow, the relocated cursor overlay, and the rewired auto-scroll. Subsequent tasks only verify slices of it on-device.

```kotlin
@Composable
private fun ReadyScore(
    state: ReaderState.Ready,
    scoreHandle: Long?,
    fontProvider: io.github.jiyimeta.sheetmusic.compose.render.FontProvider,
    audioVm: ReaderAudioViewModel,
) {
    val page = state.program.pages.first()

    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    var scale by remember { mutableFloatStateOf(1f) }

    val vScroll = rememberScrollState()
    val hScroll = rememberScrollState()
    val density = LocalDensity.current

    // fit-width: at scale 1 the page width exactly fills the viewport, so the
    // horizontal extent is zero (no horizontal scroll) — matching iOS zoom 1.0.
    val fitPxPerMM = if (page.widthMM > 0 && viewportSize.width > 0) {
        (viewportSize.width / page.widthMM).toFloat()
    } else {
        0f
    }
    val contentWidthPx = (page.widthMM.toFloat() * fitPxPerMM * scale)
    val contentHeightPx = (page.heightMM.toFloat() * fitPxPerMM * scale)
    val isZoomed = contentWidthPx > viewportSize.width + 0.5f

    // Vertical breathing room so the first/last system isn't flush. Tunable.
    val vPadPx = with(density) { 16.dp.toPx() }
    val padPx = with(density) { 24.dp.toPx() }

    // Auto-scroll: keep the playback cursor in view via the shared Domain
    // keep-in-view math (JNI). Vertical always; horizontal only when zoomed.
    LaunchedEffect(scoreHandle, fitPxPerMM, scale) {
        val handle = scoreHandle ?: return@LaunchedEffect
        if (fitPxPerMM <= 0f) return@LaunchedEffect
        audioVm.currentCursor.collectLatest { cursor ->
            if (cursor == null) return@collectLatest
            val bytes = SheetMusicJNI.nativeCursorFrame(handle, ScoreCursorCodec.encode(cursor))
            if (bytes.isEmpty()) return@collectLatest
            val frame = DecodedFrameCodec.decode(bytes)

            val yMin = (frame.y * fitPxPerMM * scale)
            val yMax = ((frame.y + frame.height) * fitPxPerMM * scale) + vPadPx * 2
            val newY = FolinoReaderJNI.nativeScrollOffsetKeepingInView(
                vScroll.value.toDouble(),
                yMin,
                yMax,
                viewportSize.height.toDouble(),
                padPx.toDouble(),
            ).toFloat()
            if (abs(newY - vScroll.value) >= 0.5f) {
                vScroll.animateScrollTo(newY.toInt().coerceAtLeast(0))
            }

            if (isZoomed) {
                val xMin = (frame.x * fitPxPerMM * scale)
                val xMax = ((frame.x + frame.width) * fitPxPerMM * scale)
                val newX = FolinoReaderJNI.nativeScrollOffsetKeepingInView(
                    hScroll.value.toDouble(),
                    xMin,
                    xMax,
                    viewportSize.width.toDouble(),
                    padPx.toDouble(),
                ).toFloat()
                if (abs(newX - hScroll.value) >= 0.5f) {
                    hScroll.animateScrollTo(newX.toInt().coerceAtLeast(0))
                }
            }
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .onSizeChanged { viewportSize = it }
            // Pinch zoom: only two-finger gestures are consumed here; single-finger
            // drags fall through to the scroll modifiers (native fling + overscroll).
            .pointerInput(fitPxPerMM) {
                if (fitPxPerMM <= 0f) return@pointerInput
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    do {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        val pressed = event.changes.count { it.pressed }
                        if (pressed >= 2) {
                            val zoom = event.calculateZoom()
                            if (zoom != 1f) {
                                val centroid = event.calculateCentroid(useCurrent = true)
                                val newScale = (scale * zoom).coerceIn(1f, 8f)
                                val ratio = newScale / scale
                                if (ratio != 1f && centroid.isSpecified) {
                                    val newX = focalAdjustedOffset(hScroll.value.toFloat(), centroid.x, ratio)
                                    val newY = focalAdjustedOffset(vScroll.value.toFloat(), centroid.y, ratio)
                                    scale = newScale
                                    // Apply after recomposition resizes the content; scroll state
                                    // clamps to [0, maxValue] (X collapses to 0 when scale → 1).
                                    launch { hScroll.scrollTo(newX.toInt().coerceAtLeast(0)) }
                                    launch { vScroll.scrollTo(newY.toInt().coerceAtLeast(0)) }
                                }
                                event.changes.forEach { if (it.positionChanged()) it.consume() }
                            }
                        }
                    } while (event.changes.any { it.pressed })
                }
            },
        contentAlignment = Alignment.TopStart,
    ) {
        // Scroll modifiers: vertical always; horizontal only when zoomed so that
        // at fit-width there is zero horizontal interaction (no horizontal stretch).
        val scrollModifier = if (isZoomed) {
            Modifier.verticalScroll(vScroll).horizontalScroll(hScroll)
        } else {
            Modifier.verticalScroll(vScroll)
        }

        Box(scrollModifier) {
            Box(
                Modifier.size(
                    width = with(density) { contentWidthPx.toDp() },
                    height = with(density) { (contentHeightPx + vPadPx * 2).toDp() },
                ),
            ) {
                ScorePage(
                    page = page,
                    fontProvider = fontProvider,
                    pxPerMM = fitPxPerMM * scale,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = with(density) { vPadPx.toDp() }),
                )
                scoreHandle?.let { handle ->
                    PlaybackCursorOverlay(
                        scoreHandle = handle,
                        cursorFlow = audioVm.currentCursor,
                        pxPerMM = fitPxPerMM,
                        scale = scale,
                        panOffset = Offset.Zero,
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(vertical = with(density) { vPadPx.toDp() }),
                    )
                }
            }
        }
    }
}
```

- [ ] **Step 3: Add the `focalAdjustedOffset` helper and delete `keepInViewOffsetY`**

Remove the now-unused `keepInViewOffsetY` function (old lines ~161-195). Add this pure helper near it:

```kotlin
/**
 * New scroll offset (px) that keeps the content point under the pinch centroid
 * fixed across a zoom step of ratio `r = newScale / oldScale`. In scroll space a
 * content pixel at `scroll + centroid` must remain under `centroid` after the
 * content scales by `r`: `newScroll = r * (scroll + centroid) - centroid`. The
 * scroll state clamps the result to `[0, maxValue]`, so no clamp is needed here.
 */
private fun focalAdjustedOffset(currentScroll: Float, centroid: Float, ratio: Float): Float =
    ratio * (currentScroll + centroid) - centroid
```

- [ ] **Step 4: Sanity-check `focalAdjustedOffset` by hand**

No JUnit harness in this module — reason through it:
- `ratio = 1` → `1*(s+c) - c = s` (no change). ✓
- Zoom in 2× about origin (`c=0`) → `2*s` (offset doubles, content under top-left stays). ✓
- Zoom in about a point `c` with `s=0` → `r*c - c = (r-1)*c` (scrolls so the point under `c` stays put). ✓

- [ ] **Step 5: Commit (do not auto-push)**

```
git -C ~/Developer/Personal/ios-apps/Folino-iOS add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git -C ~/Developer/Personal/ios-apps/Folino-iOS commit -m "feat(reader-android): native scroll host with bounded pan + focal pinch zoom"
```

---

## Phase C — Build & on-device verification (Pixel 8a)

Working dir: `~/Developer/Personal/ios-apps/Folino-iOS`. Per project rule, an
Android change is not done until install + launch on device succeed.

### Task C1: Stage native libs (only if stale) and build the app

**Files:** none (build only)

- [ ] **Step 1: Stage Reader JNI libs if missing/stale**

Only needed if `Android/FolinoReaderAndroid/src/main/jniLibs` is empty or the
JNI changed (it didn't here). If a clean worktree or missing `.so`, run:
```
Scripts/android-build-reader-libs.sh
```
Expected: `.so` + `java-generated` staged. (Skip if already present from prior builds.)

- [ ] **Step 2: Assemble the debug app**

Run (from `Android/`):
```
./gradlew :app:assembleDebug
```
Expected: `BUILD SUCCESSFUL`. If `ScorePage` is unresolved, re-run Phase A Task A2 (mavenLocal publish) — Gradle resolved a stale snapshot.

- [ ] **Step 3: Install + launch on the Pixel 8a**

Run (from `Android/`):
```
./gradlew :app:installDebug
```
Then:
```
adb shell am start -n com.keynumber.folino/.MainActivity
```
Expected: app launches; navigate into a score to reach the Reader.

### Task C2: Verify the scroll/zoom behavior on device

**Files:** none (manual observation; hand back to the user for gestures per the
iOS/Android no-auto-gesture preference — describe what to check)

- [ ] **Step 1: Fit-width (not zoomed)**
  - Vertical drag scrolls the score, bounded top/bottom, with Android stretch
    overscroll at the ends.
  - Horizontal drag does **nothing** — no horizontal pan, no horizontal stretch.

- [ ] **Step 2: Pinch to zoom in**
  - Cannot zoom out below fit-width (`scale` floors at 1.0; content snaps back
    to the no-horizontal-scroll state).
  - The content point under the fingers stays put while zooming (focal follow).
  - After zooming in, horizontal drag scrolls, bounded to left/right edges with
    stretch overscroll; vertical still bounded.

- [ ] **Step 3: Gesture arbitration (the key risk)**
  - Single-finger pan never triggers zoom.
  - Two-finger pinch never gets hijacked into a scroll/fling.
  - If single-finger pan feels "stolen" by the pinch detector, the fix is the
    `pressed >= 2` gate / consuming only on `positionChanged` (already in B1) —
    re-check `PointerEventPass.Initial` vs `Main` if drags are being eaten.

- [ ] **Step 4: Playback auto-scroll**
  - Start playback; the cursor stays in view (vertical always; horizontal once
    zoomed), and manual pan is preserved while the cursor remains visible.

- [ ] **Step 5: Report results to the user**
  - Summarize what passed; if a gesture issue remains, capture it and iterate on
    B1 Step 2 before claiming completion (verification-before-completion).

---

## Self-Review (already run by the author)

- **Spec coverage:** fit-width-no-horizontal (B1 scrollModifier conditional);
  zoomed-horizontal-bounded (horizontalScroll when `isZoomed`); vertical-bounded
  (verticalScroll always); stretch overscroll (native scroll modifiers);
  min-zoom 1.0 (`coerceIn(1f, 8f)`); focal follow (`focalAdjustedOffset`);
  shared keep-in-view (JNI, both axes); pure `ScorePage` renderer (Phase A);
  Android-only / no iOS change (Phase A additive). All covered.
- **Placeholders:** none — full code in each code step.
- **Type consistency:** `fitPxPerMM`, `scale`, `contentWidthPx`,
  `contentHeightPx`, `isZoomed`, `focalAdjustedOffset`, `ScorePage(page,
  fontProvider, pxPerMM, modifier)`, `PlaybackCursorOverlay(... panOffset =
  Offset.Zero, pxPerMM = fitPxPerMM, scale = scale ...)` consistent across tasks.

## Risks / open points for the executor

- **Gesture arbitration** is the one behavior that can't be proven without the
  device. If `awaitPointerEvent(PointerEventPass.Initial)` consumes single-finger
  drags, try gating consumption strictly on `pressed >= 2` (already done) and, if
  still wrong, move the pinch reads to `PointerEventPass.Main` or detect the
  second pointer before consuming any movement.
- **`calculateCentroid(useCurrent = true)`** returns `Offset.Unspecified` when no
  pointers are pressed — guarded by `centroid.isSpecified`.
- **Content padding** (`vPadPx = 16.dp`) is a tunable; adjust after seeing the
  first/last system spacing on device.

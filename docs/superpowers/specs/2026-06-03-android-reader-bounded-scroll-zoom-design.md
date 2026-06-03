# Android Reader — Bounded Scroll + Pinch Zoom (Chrome-mobile semantics)

**Date:** 2026-06-03
**Status:** Approved design, pending implementation plan
**Scope:** `Android/FolinoReaderAndroid` (Folino) + an additive renderer in `swift-sheet-music`

## Problem

The Android Reader renders the score in vertical mode but currently allows
**unbounded scrolling in every direction**. `ScoreCanvas`
(swift-sheet-music's shared Compose renderer) handles pan/zoom with
`detectTransformGestures`, clamps only `scale` to `[0.25, 8]`, and adds raw
`pan` to `panOffset` with **no bounds clamp**. The user can fling the page
off-screen in any direction.

Desired behavior mirrors viewing a mobile website in Chrome:

- **Not zoomed (fit-width):** no horizontal scrolling at all.
- **Zoomed in:** horizontal scrolling is enabled, bounded to the content's
  left/right edges.
- **Vertical:** always scrollable, bounded to the content's top/bottom edges.
- **Edges:** native Android overscroll feedback when you hit a bound.

## Parity baseline (iOS)

iOS `VerticalScoreContainer` + `ScoreScrollHost` already implement exactly this
behavior, and the implementation should mirror its **architecture**, not just
its visible result:

- The score content is `scaleEffect`-ed **inside** a native `UIScrollView`
  (`maximumZoomScale` pinned at 1). The scroll view owns scroll bounds, fling,
  and overscroll natively; zoom is just a content-size + content-scale change.
  The SwiftUI `Canvas` re-rasterizes under `scaleEffect` so the score stays
  sharp at every zoom level (no bitmap upscale).
- **"zoom 1.0 = fit width."** `fit = min(1.0, viewport.width / doc.size.width)`.
  Pinching below 1.0 rubber-bands back to 1.0 (`targetZoom = combined < 1.05 ?
  1.0 : combined`) — you cannot shrink below fit-width.
- Horizontal scroll exists **only when zoomed** (`alwaysBounceHorizontal =
  false`); vertical always scrolls (`alwaysBounceVertical = true`).
- Pinch commit keeps the content point under the user's fingers fixed
  (focal-point follow), via `newOffset = startLocation*(ratio-1) +
  currentOffset - pinch.offsetX`.
- Auto-scroll (keep playback cursor in view) feeds the shared Domain function
  `scrollOffsetKeepingInView` (called from Android via JNI as
  `FolinoReaderJNI.nativeScrollOffsetKeepingInView`) — one implementation, no
  divergent Kotlin port.

Android's existing `fitPxPerMM = viewportWidthPx / page.widthMM` already makes
**Android `scale == 1` identical to iOS `zoom 1.0` (fit-width)**, so the unit
baselines line up with no conversion.

## Decisions (confirmed with user)

| Decision | Choice |
| --- | --- |
| Placement of bounded scroll/zoom | Match iOS: native scroll **host on the Folino side**; renderer stays shared. |
| Overscroll style | **Android default stretch** overscroll (idiomatic Android; free from native scroll). |
| Minimum zoom | **fit-width floor (`scale = 1.0`)** — cannot zoom out below fit. |
| Pinch focal point | **Follow the pinch centroid** (iOS-parity), via scroll-offset adjustment on each zoom step. |

These follow the project's two cross-platform rules: **logic/behavior matches
iOS and is shared** (the keep-in-view math is already shared via JNI; the
renderer is shared), while **UI/UX placement prefers Android idioms** (native
Compose scroll + stretch overscroll instead of an iOS-style rubber-band port).

## Architecture

Three pieces. The only shared-library change is **additive** (a new public
composable); existing `ScoreCanvas` is untouched so the swift-sheet-music
Examples app keeps working.

### 1. `swift-sheet-music`: add a pure renderer `ScorePage`

`ScoreCanvas` couples gesture handling (`detectTransformGestures`) with drawing.
A native scroll container needs a renderer that **does not** install its own
pan/zoom pointer input (it would fight the scroll modifiers).

Add a public, gesture-free composable to
`SheetMusicComposeAndroid/.../compose/render/ScoreCanvas.kt` (same file or a
sibling):

```kotlin
@Composable
fun ScorePage(
    page: EncodablePage,
    fontProvider: FontProvider,
    pxPerMM: Float,        // caller passes fitPxPerMM * scale
    modifier: Modifier = Modifier,
) {
    val smufl = fontProvider.smuflTypeface()
    val text = fontProvider.textTypeface()
    Canvas(modifier = modifier) {
        drawPage(page, pxPerMM, smufl, text)   // reuse existing private drawPage
    }
}
```

- No `pointerInput`, no `withTransform` translate (the scroll container
  translates; zoom is baked into `pxPerMM`).
- Drawing at `pxPerMM = fitPxPerMM * scale` re-rasterizes glyphs at the zoomed
  resolution → sharp at every zoom (iOS-parity on sharpness).
- `ScoreCanvas` remains for the Examples app, optionally refactored later to
  delegate to `ScorePage` (not required for this change).

This is a cross-repo change to swift-sheet-music (dev clone at
`~/Developer/Personal/swift-packages/swift-sheet-music`); Folino re-pins the
package after the renderer lands.

### 2. Folino `ReadyScore`: the scroll/zoom host (iOS `ScoreScrollHost` analog)

Rewrite `ReadyScore` in
`Android/FolinoReaderAndroid/.../reader/ReaderScreen.kt`:

**State & derived sizes**
- `var scale by remember { mutableFloatStateOf(1f) }` — clamped `[1f, 8f]`.
- `viewportWidthPx`, `viewportHeightPx` from `onSizeChanged` on the outer Box.
- `fitPxPerMM = viewportWidthPx / page.widthMM`.
- `contentWidthPx  = viewportWidthPx * scale` (== `page.widthMM * fitPxPerMM *
  scale`).
- `contentHeightPx = page.heightMM * fitPxPerMM * scale`.
- Vertical content padding (top + bottom) so the first/last system isn't flush;
  a single tunable constant (start at `16.dp` top and bottom; the Scaffold
  `TopAppBar` already insets the score below the chrome).

**Scroll container**
- `val vScroll = rememberScrollState()`, `val hScroll = rememberScrollState()`.
- Outer Box fills the viewport and records its size.
- Inner content Box is sized to `(contentWidthPx, contentHeightPx)` (converted
  to dp) and carries the score + cursor overlay.
- Apply `Modifier.verticalScroll(vScroll)` **always**.
- Apply `Modifier.horizontalScroll(hScroll)` **only when `contentWidthPx >
  viewportWidthPx`** (i.e. `scale > 1`). At `scale == 1` the horizontal scroll
  modifier is omitted entirely, so there is zero horizontal interaction and no
  horizontal stretch overscroll — matching "not zoomed → no left/right scroll."

**Pinch zoom (focal-point follow, coexisting with native scroll)**
- A `Modifier.pointerInput` that **only consumes two-or-more-finger gestures**;
  single-finger drags fall through to the scroll modifiers (native fling +
  stretch overscroll).
- Per pinch event:
  - `zoom = event.calculateZoom()`, `centroid = event.calculateCentroid()`
    (viewport coords).
  - `newScale = (scale * zoom).coerceIn(1f, 8f)`; `r = newScale / scale`.
  - Focal-point invariant (keep the content point under `centroid` fixed):
    - `newX = r * (hScroll.value + centroid.x) - centroid.x`
    - `newY = r * (vScroll.value + centroid.y) - centroid.y`
  - Set `scale = newScale`; after the content box resizes, `hScroll.scrollTo`
    / `vScroll.scrollTo` to the clamped new offsets (the scroll state clamps to
    `[0, maxValue]` automatically; when scale returns to 1, `hScroll.maxValue`
    becomes 0 and any horizontal offset collapses to 0).

**Gesture-arbitration note (primary implementation risk):** native scroll
modifiers consume drags on the Main pass; a naive `detectTransformGestures`
would also eat single-finger pans and starve the scroll. The pinch detector
must gate on pointer count (only act with ≥2 pointers down) and observe early
enough (Initial pass) to win two-finger gestures while leaving one-finger
gestures for scroll. This needs an on-device verification step (see Testing).

### 3. Cursor overlay & auto-scroll

**Overlay placement** — move `PlaybackCursorOverlay` **inside** the scrolled
content Box, called with `panOffset = Offset.Zero`, `pxPerMM = fitPxPerMM`,
`scale = scale`. It draws the cursor rect at `f.x * fitPxPerMM * scale` in the
content Box's coordinate space, so it scrolls and zooms with the score
automatically — no manual offset feeding.

**Auto-scroll (keep-in-view)** — replace the current `transform.panOffset.y`
mutation with scroll-state animation:
- On each playback cursor frame, decode `DecodedFrame` (existing path).
- Map the frame rect to content px: `min/max = frame.{y,x} * fitPxPerMM *
  scale` (and `+ height/width`).
- Call the shared `FolinoReaderJNI.nativeScrollOffsetKeepingInView(...)` for
  **both axes** (current Android code does Y only; iOS does both — this brings
  Android to parity), with the current `vScroll.value` / `hScroll.value` as the
  `current` offset.
- `vScroll.animateScrollTo(newY)`; for X, only when horizontal scrolling is
  active (`scale > 1`), `hScroll.animateScrollTo(newX)`.
- Preserve the existing "only move when the cursor leaves the viewport"
  behavior — the shared function already returns the current offset unchanged
  when the target is fully visible; skip the animate call when the delta is
  below ~0.5 px (as today).

## Data flow

```
single-finger drag ─▶ verticalScroll / horizontalScroll (native)
                       └─ bounds clamp + fling + stretch overscroll

two-finger pinch ───▶ pointerInput (≥2 pointers)
                       ├─ scale = (scale*zoom).coerceIn(1, 8)
                       └─ scrollTo(focal-adjusted, clamped)   // focal follow

playback cursor ────▶ DecodedFrame ─▶ nativeScrollOffsetKeepingInView (shared)
                       └─ animateScrollTo (Y always, X when zoomed)
```

## Testing / verification

- **On-device (Pixel 8a, install + launch — per project rule for Android
  changes):**
  - Not zoomed: vertical scroll bounded top/bottom with stretch overscroll;
    **no** horizontal movement or horizontal stretch.
  - Zoomed in: horizontal scroll appears, bounded to left/right edges with
    stretch overscroll; vertical still bounded.
  - Pinch out cannot go below fit-width (`scale` floors at 1.0); content snaps
    back to no-horizontal-scroll state.
  - Pinch focal point: the spot under the fingers stays put while zooming.
  - Playback auto-scroll keeps the cursor in view (vertical always; horizontal
    when zoomed) without fighting manual pan.
  - **Gesture arbitration:** single-finger pan never zooms; two-finger pinch
    never gets hijacked into a scroll. This is the explicit risk to confirm.
- **Build:** `Scripts/android-build-libs.sh` (regenerate Swift `.so` /
  bindings if the swift-sheet-music re-pin changes them) then
  `installDebug` + `adb shell am start`. Watch for native drift in the Library
  `.so` (known issue) if the worktree's libs go stale.
- No new unit tests are strictly required (gesture + scroll are UI behavior);
  the shared keep-in-view math is already covered. If a pure helper is
  extracted for the focal-point offset formula, add a small Swift Testing /
  Kotlin unit test for it.

## Out of scope / non-goals

- No changes to spec / product behavior, module boundaries, or Domain
  protocols.
- No horizontal *paged* mode, no multi-page handling (vertical mode renders a
  single tall page: `state.program.pages.first()`).
- No iOS changes (iOS already has this behavior).
- `ScoreCanvas` behavior for the Examples app is unchanged.

## Affected files

- `~/Developer/Personal/swift-packages/swift-sheet-music/Android/SheetMusicComposeAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/compose/render/ScoreCanvas.kt`
  — add `ScorePage`.
- `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt`
  — rewrite `ReadyScore` (scroll host + pinch); update keep-in-view to drive
  scroll state for both axes; remove the unbounded `transform`/`ScoreTransform`
  usage and `keepInViewOffsetY`'s panOffset coupling (keep the shared JNI call).
- swift-sheet-music Compose-lib dependency pin for the Android consumer:
  `ScorePage` ships in the Kotlin `SheetMusicComposeAndroid` artifact
  (`io.github.jiyimeta.sheetmusic.compose`), consumed by `FolinoReaderAndroid`
  via Gradle/Maven — bump that dependency version (publish to `mavenLocal`
  during dev, mirroring the existing wirelet / sheet-music Android pin flow) to
  the revision that adds `ScorePage`. (No iOS `Package.swift` / `project.yml`
  change is needed — this renderer addition is Android-only.)

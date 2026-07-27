# Android Reader — free-form scroll and pinch

Status: design approved 2026-07-27. Android only.

## Problem

The Android reader's viewport does not behave the way a browser's does.

- **Panning is forced onto an axis.** A diagonal drag resolves to purely vertical or purely
  horizontal movement and stays locked there for the rest of the gesture.
- **A pinch drifts toward the top-left** instead of holding the content point under the fingers.

Both symptoms come from the same place: the vertical and horizontal surfaces delegate viewport
control to Compose scroll containers.

- `Modifier.verticalScroll` and `Modifier.horizontalScroll` are two independent `scrollable`
  modifiers. Whichever one's drag detector wins the pointer slop owns the gesture for its duration,
  so a two-axis drag is impossible by construction.
- The focal correction itself is right — `focalAdjustedOffset` in `ReaderScreen.kt` solves for the
  offset that holds the centroid fixed — but its result is written back through
  `ScrollState.scrollTo`, which clamps to `[0, maxValue]`. That `maxValue` reflects the *previous*
  frame's layout of the content box, whose size is derived from `scale`. Zooming in pins the offset
  to a stale upper bound every frame; zooming out drops it to 0. Either way the anchor slides to the
  top-left.

The page surface (`PagedScore.kt`) already uses a free two-dimensional `panOffset` with a
centroid-anchored zoom and does not have these symptoms. It is missing momentum, and it carries its
own copy of the clamp and focal math.

## Scope

All three reader surfaces: `ReadyScore` (vertical) and `HorizontalScore` in `ReaderScreen.kt`, and
`PagedScore`.

**In scope:** free diagonal panning, a pinch whose centroid stays fixed, and momentum (fling) after
a pan.

**Explicitly out of scope**, decided during design:

- Rubber-band overscroll at the edges.
- Zooming out below fit (`scale` keeps its `1f..8f` range).
- Double-tap to toggle zoom — it would put a wait on the single tap, which is a seek.

## Design

### `ReaderViewport.kt`

A new file under `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/`. No new
module and no new layer boundary.

```kotlin
class ReaderViewportState {
    var scale: Float          // where the fingers are now
    var rasterScale: Float    // the scale the bands were last recorded at
    var offsetX: Float        // scroll offset, positive = scrolled right
    var offsetY: Float        // scroll offset, positive = scrolled down
    var viewportSize: IntSize
    var unitContentSize: Size // content extent in px at scale 1.0, padding included
}
```

`scale` / `rasterScale` keep the existing split, which is what keeps a pinch off the score's
re-record path: the bands stay recorded at `rasterScale`, a layer transform covers the difference
while the fingers are down, and one re-raster happens when they lift.

**The offset sign follows `ScrollState.value`, not `PagedScore`'s `panOffset`.** Positive means
scrolled down/right. Every consumer downstream — the tap-to-cursor offset, the auto-follow JNI
calls — already reads offsets in that convention, so they change their source, not their formulas.
`PagedScore`'s negative-going `panOffset` is the one that flips sign, and it loses its inline clamp
in exchange.

### Fixing the anchor

`focalAdjustedOffset(currentScroll, centroid, ratio, pad)` is kept verbatim, including its `pad`
parameter for the fixed vertical padding that does not scale with zoom. What changes is where its
result is clamped: against the content extent computed from the *new* `scale` in the same frame,
rather than against a `ScrollState.maxValue` left over from the previous layout. That removes the
one-frame lag, and the anchor holds.

### Fixing the axis lock

Nothing to solve directly. The lock is a property of `scrollable`, and the scroll containers are
gone.

### One gesture loop

A single `awaitEachGesture` replaces the two `pointerInput` blocks each surface currently stacks
(one to detect a pinch, one to detect a manual drag for the auto-follow suspension).

| Input | Behavior |
| --- | --- |
| One finger | Free pan, clamped to the content extent. No rubber-band. |
| Two fingers | Pinch and pan applied together (`calculateZoom` + `calculatePan`). |
| Fingers lift | Fling from the tracked velocity via `splineBasedDecay`, stopping per axis at its edge. |
| New touch | Cancels an in-flight fling. |
| Fingers lift with `scale != rasterScale` | Re-record the bands at the new scale (unchanged). |

While annotating, only two-finger gestures are taken: pinch and pan both apply, fling does not. A
single finger still falls through to the wet overlay as a stroke.

Tap-to-seek keeps its own `pointerInput` with `detectTapGestures`, as today. The pan loop consumes
only pointers that actually moved, so a down-and-up reaches the tap detector. With double-tap zoom
out of scope, no wait is introduced on the seek.

Auto-follow suspension (`suspendPlaybackFollowForManualViewportChange`) folds into this loop: fire
on two-finger contact, or on the first real movement of a single finger. Same semantics as the two
detectors it replaces — in particular it must still fire on pointer *movement* rather than on
`ScrollableState.isScrollInProgress`, because a programmatic auto-follow scroll flips that flag with
no pointer event and would latch the suspension on permanently.

### Applying it to the three surfaces

**`ReadyScore` (vertical).** The scroll modifiers give way to the viewport modifier. The `isZoomed`
branch that adds and removes `horizontalScroll` disappears — at fit width the clamp leaves no
horizontal room on its own.

One trap here, flagged by the existing code's own comment: annotation currently disables scrolling
with `enabled = false` rather than dropping the modifier, because dropping it also drops the
`placeRelativeWithLayer` that gives the scrolled content its own RenderNode, and without that layer
every wet-ink frame re-records the whole score. The viewport's `graphicsLayer` supplies that
RenderNode in the new design, so the property survives — on the condition that the clip and the
`graphicsLayer` stay on the same node rather than being split across two boxes.

Band culling also survives. `BandedScorePage`'s documentation states that a host wrapping it in its
own `graphicsLayer` is the intended way to zoom, and that band layers nest inside it rather than
collapsing into it.

**`HorizontalScore`.** The same substitution. The `needsVScroll` conditional is absorbed by the
clamp, and its tap math stops branching on it: with a two-dimensional offset, both axes fold in
unconditionally.

**`PagedScore`.** `HorizontalPager` stays, and so does
`userScrollEnabled = scale == 1f && !annotationMode` — a zoomed page does not turn on a drag, by
decision. The reset on page turn (`scale = 1f`, offset zeroed) stays. The delta is that its inline
pan, clamp, and focal math are replaced by the shared state, and it gains momentum.

### Downstream call sites

Each of these changes where it reads the offset, not how it computes with it.

- The auto-follow `LaunchedEffect` on all three surfaces: `vScroll.value` becomes
  `viewport.offsetY`, `animateScrollTo` becomes the viewport's animate. The keep-in-view and
  pin-system-to-top JNI calls are untouched.
- `nearestCursorForTap`'s `contentOffsetPx`.
- The ink `wetWorldToScreen` matrix and the dry overlay's placement.

## Deliberate trade-offs

**Edges become a hard stop.** Compose's scroll containers bring an edge glow that goes away with
them, and rubber-band was scoped out, so reaching an edge now simply stops. This is the one respect
in which the result is less browser-like than what it replaces. Adding rubber-band later is
self-contained within `ReaderViewportState`, so shipping the hard stop first and judging it by feel
is the cheaper order.

**The transform math stays in Kotlin.** The repo's parity rule says logic should match iOS and be
shared rather than duplicated. Clamping and focal correction are presentation-layer viewport math
with no counterpart to share: iOS's reader rides SwiftUI's `ScrollView` and magnification gesture.
The obligation this design does honor is the anti-duplication half — the two existing copies of the
same calculation collapse into one.

## Verification

Pure unit tests in `FolinoReaderAndroid/src/test`, no Robolectric: offset clamping, focal correction
(extending the existing coverage), the fling's resting point, and its per-axis stop at an edge.

Gesture feel does not survive a unit test. The rest is manual on the real Pixel, after
`installDebug` and launch:

- A diagonal drag tracks the finger, with no snap to an axis.
- A pinch holds its centroid — checked at the middle, near an edge, and near a corner.
- A fling decays smoothly and stops at the edge without a visible jolt.
- A pinch during playback suspends auto-follow, and play/seek clears it.
- A single tap still seeks.
- Two-finger pinch and pan work while annotating; a single finger still draws.
- Page mode turns on a swipe at fit and does not turn while zoomed.

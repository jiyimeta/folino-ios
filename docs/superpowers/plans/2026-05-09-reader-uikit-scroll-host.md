# Reader: UIScrollView-backed pan/pinch host

**Status:** in progress
**Worktree:** `.claude/worktrees/reader-uikit-pan-pinch` (branch `worktree-reader-uikit-pan-pinch`)

## Motivation

The current Reader uses a SwiftUI `ScrollView` plus `MagnifyGesture`. Two interaction shortcomings vs. Files / Preview:

1. Pinch only begins when **two fingers land simultaneously**. Drop a second finger after a one-finger drag and pinch never starts.
2. While pinching you cannot pan, and while panning you cannot pinch.

These are inherent to SwiftUI's gesture stack — `MagnifyGesture` and `DragGesture` don't share the smooth multi-finger transition `UIScrollView` gives for free.

We want to keep the **resolution behavior** the current implementation has (pinching never blurs the score). That sharpness comes from SwiftUI's `Canvas` re-rasterizing under `scaleEffect` — *not* from anything `UIScrollView` does. `UIScrollView`'s built-in pinch zoom uses a `CALayer` transform on the `viewForZooming`, which **does** bitmap-upscale during the gesture (PDFKit pattern: blur during pinch, snap sharp on release).

## Design

**Keep the SwiftUI dual-`scaleEffect` Canvas pipeline. Disable `UIScrollView`'s built-in zoom. Use `UIScrollView` only for pan + gesture coordination.**

### Component split

- **`ScoreScrollHost<Content: View>`** — new `UIViewRepresentable` in `Packages/Features/Reader/Sources/Reader/Screens/`. Owns a `UIScrollView` configured with `maximumZoomScale = 1` (zoom disabled). Hosts SwiftUI `Content` via `UIHostingController` inside `contentLayoutGuide` with Auto Layout edge constraints, so the host's `intrinsicContentSize` (= the SwiftUI `.frame(framedWidth, framedHeight)`) drives `contentSize`.

- **`VerticalScoreContainer`** — keeps every piece of zoom logic it has today (`viewportZoom`, `liveMagnification`, `liveMagAnchor`, `pendingPinchScroll`, `effectiveZoom`, `autoScroll`, `zoomedSurface`, all the `PinchSession` math). Three things change:
  - The outer `ScrollView` becomes `ScoreScrollHost`.
  - `MagnifyGesture` deletes; pinch state arrives via host callbacks.
  - `ScrollPosition` deletes; programmatic scroll goes via a `pendingScroll: CGPoint?` binding the host consumes.

### `ScoreScrollHost` API

```swift
struct ScoreScrollHost<Content: View>: UIViewRepresentable {
    @Binding var contentOffset: CGPoint
    @Binding var contentInsetTop: CGFloat
    @Binding var pendingScroll: ScrollCommand?      // .immediate(p) | .animated(p)
    let onPinchBegan: (UnitPoint, CGPoint) -> Void  // (anchor, locationInContent)
    let onPinchChanged: (CGFloat) -> Void           // magnification
    let onPinchEnded: (CGFloat, CGPoint, CGPoint) -> Void  // (mag, startLocation, currentOffset)
    let content: () -> Content
}
```

Internals:
- `UIScrollView` subclass with `minimumZoomScale = maximumZoomScale = 1`, `delaysContentTouches = false` (keep tap-to-seek and double-tap crisp), `alwaysBounceVertical = true`.
- A custom `UIPinchGestureRecognizer` added to the scroll view, with a `UIGestureRecognizerDelegate` that returns `true` from `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)` so it fires alongside the built-in pan. **This is the whole reason for the migration:** `UIScrollView`'s pan supports 1-finger pan with smooth promotion when a second finger arrives, and the simultaneous-recognition delegate means our pinch can join the gesture in flight.
- `UIScrollViewDelegate.scrollViewDidScroll` reports `contentOffset` to the binding.
- On every layout pass, push `adjustedContentInset.top` to the inset binding.
- In `updateUIView`, if `pendingScroll` is non-nil: apply `setContentOffset(_:animated:)` and clear the binding (via `DispatchQueue.main.async` to avoid mutating during view update).

### Pinch math (changes vs. current code)

Current code uses `session.initialScrollOffset` (offset captured at pinch start). With UIScrollView pan-during-pinch, we'd "lose" any pan that happened during the gesture. Fix: at `.ended`, use `scrollView.contentOffset` (current offset) instead of the stored initial offset. Derivation:

```
After commit, content scales by ratio from .topLeading.
Content point under fingers at release = startLocation (host coords; host is unaffected by inner scaleEffect).
Want: same content point lands at same screen position post-commit.
  pre-commit screen pos  = startLocation - currentOffset
  post-commit screen pos = startLocation * ratio - newOffset
  ⇒ newOffset = startLocation * (ratio - 1) + currentOffset
```

When pan-during-pinch is zero, this collapses to the existing formula.

`PinchSession.initialScrollOffset` field is no longer needed (just `baseZoom`).

### What stays unchanged

- `effectiveZoom` (user zoom × fit-to-width).
- The `.scaleEffect(liveMagnification, anchor: liveMagAnchor).scaleEffect(zoom, anchor: .topLeading).frame(framedWidth, framedHeight)` stack.
- The `pendingPinchScroll` queue + `.onChange(of: viewModel.viewportZoom)` dispatch — still needed because the SwiftUI re-layout that resizes `intrinsicContentSize` (and therefore `contentSize`) is async; we apply the scroll one tick after the zoom commit.
- Rubber-band branch (`isBounceBack`) — unchanged.
- `tapSeekGesture` (SpatialTap on `coordinateSpace("scoreSurface")`) and `doubleTapGesture` — both stay as SwiftUI gestures inside the hosted content. They coexist with the UIScrollView pan because pan only steals the touch once movement exceeds slop.
- `autoScroll` — same math, except it pushes via `pendingScroll = .animated(target)` instead of `scrollPosition.scrollTo`.

### What gets simpler

- `contentInsetTop` no longer needs hand math. UIScrollView's `adjustedContentInset.top` is exactly the value, and `setContentOffset(point, animated:)` operates in `contentOffset` units directly (no `+ topInset` correction needed). Delete the `+ contentInsetTop` term in the pinch commit math.
- `.defaultScrollAnchor(.topLeading)` workaround for content-grow center-anchoring issue: not needed in UIKit; `UIScrollView` is top-leading natively.

## Implementation steps

1. Write `ScoreScrollHost.swift` (new file). Include `ScrollCommand` enum.
2. Modify `VerticalScoreContainer`:
   - Drop `scrollPosition`, swap to `@State pendingScroll: ScrollCommand?`.
   - Replace `scrollContent(viewport:)` body's `ScrollView { … }` with `ScoreScrollHost(…) { zoomedSurface(viewport:) }`.
   - Move pinch-end commit logic into a `commitPinch(magnification:startLocation:currentOffset:)` method invoked from the host's `onPinchEnded`.
   - Remove `magnifyGesture` and `.simultaneousGesture(magnifyGesture)`.
   - Remove `+ contentInsetTop` from the commit formula.
   - Move `.simultaneousGesture(doubleTapGesture)` from outside the scroll view onto the inner `scoreSurface` (it must live on a SwiftUI view, and the outer view is now UIKit).
3. Build for iPhone 16 sim with `-skipPackagePluginValidation`. Fix any compile issues.
4. Install + launch in simulator. Hand control to the user for tactile verification (per CLAUDE.md: don't drive the gestures from a subagent).

## Verification (user does this)

- One-finger drag pans both axes.
- During a one-finger pan, drop a second finger → pinch begins mid-gesture, scaling around the centroid.
- During a two-finger pinch, lift one finger → pan continues from the remaining finger.
- Pinch and pan simultaneously (centroid drift) — both happen.
- **Score stays sharp throughout the pinch** (the resolution test — if anything blurs during pinch, the SwiftUI `scaleEffect` pipeline got lost and we've regressed).
- Release commits zoom; pinch start anchor stays under the same screen point at release.
- Pinch below 1.0 from baseline 1.0 rubber-bands back smoothly.
- Tap-to-seek still works (single tap on a note → cursor jumps).
- Double-tap toggles zoom.
- Auto-scroll (during playback) still brings the cursor back into view.

## Out of scope

- Replacing the SwiftUI Canvas with a UIView-based renderer. The whole point of this design is that the resolution sharpness comes from `Canvas` + `scaleEffect` — keep it.
- Editor-side gestures. Editor uses its own surface; it can adopt the same host later if useful.
- Removing the `pendingPinchScroll` indirection. Doable in UIKit (synchronous `contentSize`) but would require duplicating the framed-size formula on the UIKit side; the SwiftUI-driven layout is the single source of truth.

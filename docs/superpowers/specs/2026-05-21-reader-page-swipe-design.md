# Reader page-mode swipe navigation — design

## Goal

Add horizontal swipe page navigation to Reader's page mode. The swipe must visually drag the
adjacent page in alongside the user's finger (not snap on release), and only engage at zoom
≈ 100 %. Existing edge tap zones and tap-seek stay as they are.

## Non-goals

- No swipe in vertical / horizontal scroll modes — those modes already pan through a real scroll
  view, and there is no concept of "adjacent page" there.
- No two-finger or velocity-only swipe; commit is governed by position threshold OR predicted
  fling end position, but the gesture is single-finger drag.
- No rework of `commitPageTurn`'s freeze-first-page-offset semantics for jump-to-edge taps.

## Scope

Touches `PagedScoreContainer` and `PagedZoomedSurface` in
`Packages/Features/Reader/Sources/Reader/Screens/PagedScoreContainer.swift`, plus `PageState` in
the same directory. Tests cover the pure commit-decision function.

## Gating

Drag-following is gated on **all** of:

- `abs(viewModel.viewportZoom - 1.0) < 0.001`. Pinch-snap already lands exactly on `1.0` for the
  existing zoom-out path; the epsilon is a forward-looking guard against drift, not a real
  tolerance window.
- `pinchSession == nil`. A pinch in progress always wins.
- `pages.count > 1`. No swipe on single-page documents.
- The drag start point falls inside the central 76 % column. The leading / trailing 12 % edge
  columns remain pure tap zones (the existing `PageTapZone` `DragGesture(minimumDistance: 0)`
  drives press feedback there).

If any gate fails when the drag begins, the drag is ignored — it does not start tracking,
does not move pages, and `dragTranslationX` stays at 0.

## Gesture composition

A new `DragGesture(minimumDistance: 8)` is attached to the page-band content (alongside the
existing `SpatialTapGesture` for tap-seek). SwiftUI's distance-based disambiguation handles the
two:

- Lift before exceeding 8 pt → tap-seek fires as today.
- Cross 8 pt → drag wins, tap-seek is cancelled.

A per-sample dominance check rejects drag samples whose vertical component dominates
(`abs(dx) > abs(dy) * 1.5` evaluated on every `onChanged`). Page mode has no vertical scroll
today, but the check costs nothing and prevents future regressions if a vertical-scroll
surface is layered in.

## Drag-following render model

The current `PagedZoomedSurface` invariant is "page offset is a pure function of `pageIndex`":

- `idx < currentIdx` → offset `-viewport.width`
- `idx >= currentIdx` → offset `0`, with `zIndex = -Double(idx)` keeping lower indices on top.

To make the next page visible during a left-drag, the rule changes to a three-way baseline:

- `idx < currentIdx` → `-viewport.width`
- `idx == currentIdx` → `0`
- `idx > currentIdx` → `+viewport.width`

`zIndex` is unchanged (current still covers next). The existing commit-turn animation still works:
moving from `cur` → `cur + 1`, the old current becomes `idx < newCurrent` and animates from `0`
to `-viewport.width`; the old next becomes `idx == newCurrent` and animates from `+viewport.width`
to `0`. This is equivalent to the existing "current slides left, next was already at 0" behaviour
visually — the only delta is that previously-resident next was at 0 underneath; now it's at
`+viewport.width` and slides in. Acceptable because next is also in the pre-rendered window so
the build cost is already paid.

A new state on `PageState`:

```swift
var dragTranslationX: CGFloat = 0
var isDragging: Bool = false
```

Every page's offset becomes `baseOffset + dragTranslationX`, except pages held by
`freezeFirstPageOffset` which retain their existing freeze rule. `dragTranslationX = 0` reproduces
the resting layout exactly.

Result during drag:

- `dragTranslationX = +30` (right drag) → current page sits at `+30`, previous page sits at
  `-viewport.width + 30` (so 30 pt of it pokes in from the leading edge).
- `dragTranslationX = -30` (left drag) → current page sits at `-30`, next page sits at
  `+viewport.width - 30` (so 30 pt pokes in from the trailing edge).

## Rubber banding at edges

When dragging past first page (right drag at `pageIndex == 0`) or past last page (left drag at
`pageIndex == pages.count - 1`), `dragTranslationX` is damped against the raw translation:

```swift
let raw = translation.x
let resistive = sign(raw) * viewport.width * (1 - 1 / (1 + abs(raw) / viewport.width))
```

The asymptote at half the viewport width is the visual hint that there is no page beyond. Commit
is impossible on the damped side — even a 95 % rubber-banded drag returns to 0 on release.

## Commit / cancel decision

On `onEnded`, build a pure `DragOutcome` decision from drag translation, predicted end translation
(SwiftUI provides `predictedEndTranslation` on `DragGesture.Value`), viewport width, and
edge flags:

```swift
enum PageSwipeOutcome {
    case commitPrevious   // animate to pageIndex - 1
    case commitNext       // animate to pageIndex + 1
    case cancel           // animate back to dragTranslationX = 0
}

static func outcome(
    translationX: CGFloat,
    predictedEndX: CGFloat,
    viewportWidth: CGFloat,
    isAtFirstPage: Bool,
    isAtLastPage: Bool,
) -> PageSwipeOutcome
```

Decision rules:

1. If `translationX > 0` and `isAtFirstPage` → `.cancel` (rubber band, no commit possible).
2. If `translationX < 0` and `isAtLastPage` → `.cancel`.
3. Compute `progress = translationX / viewportWidth` and
   `predictedProgress = predictedEndX / viewportWidth`.
4. If `abs(progress) > 0.3` **or** `abs(predictedProgress) > 0.3`, commit in the sign direction
   (`+` → previous, `-` → next). Otherwise cancel.

The pure function is testable in isolation. The view layer only translates SwiftUI gesture
values into its arguments and dispatches to the right side-effect.

## Commit animation continuity

A drag that commits hands the residual motion off to the existing `pageTransitionAnimation`:

```swift
withAnimation(Self.pageTransitionAnimation) {
    pageState.pageIndex = newIdx
    pageState.dragTranslationX = 0
}
```

Because every page's offset is `baseOffset(idx, newIdx) + dragTranslationX`, mutating both inside
one transaction interpolates each page from "old baseline + drag amount" to "new baseline + 0".
For a left-commit (next) at `dragTranslationX = -120, viewport.width = 400`:

- The (new current = old next) page was visually at `+400 + (-120) = +280`; ends at
  `0 + 0 = 0`. ✓
- The (new previous = old current) page was visually at `0 + (-120) = -120`; ends at
  `-400 + 0 = -400`. ✓

No bespoke per-residual-distance timing — the existing `easeInOut(duration: 0.22)` is reused. A
fast fling that releases at 90 % progress visually traverses only the remaining 10 % under that
curve, which lands closer to instant than to lagging.

`pendingScroll = .immediate(.zero)` is still called after commit, matching the existing
`commitPageTurn` semantics so the scroll host re-anchors to origin.

Cancel uses a separate, snappier animation so the page returns to rest without feeling sticky:

```swift
withAnimation(.smooth(duration: 0.18)) {
    pageState.dragTranslationX = 0
}
```

## Playback-cursor follow conflict

`followCursor(_:)` calls `commitPageTurn` whenever the playback cursor lands on a new page. During
an active drag this would yank the band out from under the finger. While `pageState.isDragging`
is true, `followCursor` no-ops; on drag end (whether commit or cancel) it re-runs once against
the current `playbackCursor` so the page catches up if playback advanced through pages during
the gesture.

## Clipping & pinch interaction

The existing `.frame(width: viewport.width, height: viewport.height).clipped()` on the page-band
ZStack continues to clip neighbours — the visible reveal is bounded to the band by construction.

Pinch above 1.0 disables the swipe gate. The `pinch.magnification` / `committedZoom` /
`viewportZoom` machinery is untouched; this design only adds a parallel translation that lives
between resting layout and the existing scroll host.

## Testing

A new Swift Testing suite `PageSwipeOutcomeTests` exercises
`PagedScoreContainer.outcome(translationX:predictedEndX:viewportWidth:isAtFirstPage:isAtLastPage:)`:

- `commitNext` at threshold + 1 pt past 30 %, no fling.
- `commitNext` from a fling whose `predictedEndX` crosses 30 % even though `translationX` is
  below 30 %.
- `cancel` below both thresholds.
- `cancel` despite over-threshold translation when `isAtLastPage` and direction is left.
- `cancel` despite over-threshold translation when `isAtFirstPage` and direction is right.
- Symmetric set for `commitPrevious`.

The view body and the gesture wiring are not directly unit-testable. Manual verification is the
preview / simulator gesture — out of scope for this design's test list, covered during
implementation.

## Files touched

- `Packages/Features/Reader/Sources/Reader/Screens/PagedScoreContainer.swift` — gesture, gate,
  drag-following offsets, commit/cancel handling, `outcome` static function.
- `Packages/Features/Reader/Sources/Reader/Screens/PageState.swift` — `dragTranslationX`,
  `isDragging`.
- `Packages/Features/Reader/Tests/ReaderTests/PageSwipeOutcomeTests.swift` — new test file.

No localized strings, no settings keys, no `xcstrings` work, no architectural changes.

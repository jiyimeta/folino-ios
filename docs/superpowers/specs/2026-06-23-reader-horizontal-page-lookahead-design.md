# Reader horizontal + page lookahead follow (iOS + Android) — design

**Status:** Draft for review
**Date:** 2026-06-23
**Feature package:** `Packages/Features/Reader` (iOS) + `Android/FolinoReaderAndroid` (Android)
**Touches:** `Reader` (iOS `HorizontalScoreContainer`, `PagedScoreContainer`, `ReaderRootScreen`, `ReaderPlaybackSession`); Android (`HorizontalScore`, `PagedScore`, `ReaderAudioViewModel`)

## Goal

Extend the shipped **vertical** lookahead auto-scroll to the Reader's remaining two layout
modes, on **both iOS and Android**, so playback anticipates the cursor in every mode:

- **Horizontal:** same 2-stage trigger as vertical (real cursor + a 2-beat lookahead cursor),
  but the *action* is to **left-align the playing cursor's measure** (horizontal mode is
  measure-anchored, not system-anchored).
- **Page:** a **1-beat** lookahead, triggered by the **lookahead (virtual) cursor only**, that
  **activates the page containing the virtual cursor** — turning the page ~1 beat before the
  playhead reaches it.

## Key insight that shaped the design

The vertical work already built everything needed; this feature is almost entirely **reuse**:

- `Domain.scrollOffsetPinningSystemTop(current:systemMin:systemMax:lookaheadMax:viewport:topInset:)`
  is **axis-agnostic 1-D math**: "pin the target's leading edge (minus `topInset`), but only
  when the target OR the lookahead has left the viewport." Vertical uses it for the system's
  Y-span; **horizontal reuses it verbatim for the measure's X-span** (passing measure-minX as
  `systemMin`, the lookahead measure's maxX as `lookaheadMax`, `pad` as `topInset`).
- `Score.cursor(advancedByBeats:from:)` (ssm, already bridged to Android as
  `nativeCursorAdvancedByBeats`) computes any-lead lookahead cursor. The **2-beat anchor**
  (`scrollAnchorCursor`) already exists; page only needs a **1-beat** variant.
- Measure/page geometry already exists: iOS `HorizontalScoreContainer.measureRect(for:in:)` and
  `PagedScoreContainer.followCursor(_:)` (cursor→page); Android `nativeMeasureFrame` and
  `PagedScore`'s `breaksMm` cursor→page band search.

**Therefore this feature adds NO new shared/Domain/ssm/JNI code.** The only new logic is a
1-beat lookahead cursor (`pageAnchorCursor`) and per-mode container/composable wiring. The
Android side needs **no new JNI bridge and no `.so` rebuild for new symbols** — it reuses
`nativeScrollOffsetPinningSystemTop`, `nativeCursorAdvancedByBeats`, `nativeMeasureFrame`,
`nativeCursorFrame`, `nativeHorizontalMeasureScrollOffset`.

## Non-goals

- **No new Domain / ssm / JNI function.** Horizontal reuses `scrollOffsetPinningSystemTop`
  as-is (its vertical-flavored param names are documented as axis-agnostic at the call site;
  not renamed, to avoid churn on a just-shipped function + the Android bridge/`.so`).
- **No change to the highlight / playing cursor.** It stays on the real position in all modes.
- **No change to vertical mode** (already shipped).
- **No change to horizontal-mode Y follow** (the gentle keep-in-view when zoomed taller than
  the viewport stays; only the **X** axis gets the lookahead).
- **Android PiP** is out of scope — it is not yet implemented (design `2026-06-09-android-reader-pip-design.md`); it will inherit the lookahead via the shared `HorizontalScore` + JNI path when built. (iOS PiP IS now included — see Component 8, added per user request after the initial spec, since PiP's scroll is measure-left-align like horizontal.)

## Decisions (from brainstorming)

| Question | Decision |
| --- | --- |
| Horizontal lead | **2 beats** — reuse the existing `scrollAnchorCursor`. |
| Horizontal action | **Left-align the playing cursor's measure**, via `scrollOffsetPinningSystemTop` on the X axis (measure span + lookahead measure's right edge). |
| Horizontal trigger | **2-stage**: real measure OR lookahead measure not fully visible (horizontally). |
| Page lead | **1 beat** — new `pageAnchorCursor`. |
| Page trigger | **Lookahead (virtual) cursor only.** Single trigger; no real-cursor stage. |
| Page action | **Activate the page containing the virtual cursor** (the existing page-turn fed the lookahead cursor). |
| Page highlight consequence | **Accepted:** the playhead may sit on the previous (off-screen) page for up to ~1 beat during the anticipatory turn. The 1-beat lead is chosen to keep this brief. |
| Paused / scrubbing / manual seek | Both modes fall back to today's reactive behavior on the **real** cursor (anchor is `nil`). |
| New shared/JNI code | **None.** Reuse existing Domain + JNI functions; only add a 1-beat anchor + wiring. |

## Components

### 1. iOS — `ReaderPlaybackSession.pageAnchorCursor` (1-beat)

Add a sibling of `scrollAnchorCursor`, with a 1-beat lead:

```swift
/// Lookahead anchor for PAGE mode: the `.beat` cursor `pageLookaheadBeats` beats ahead of the
/// live position, so the page turns before the playhead reaches the next page. Non-nil ONLY
/// during continuous playback; page mode falls back to `displayCursor` when nil. Never drives
/// the highlight.
var pageAnchorCursor: ScoreCursor? {
    guard isPlaying, scrubCursor == nil,
          let raw = rawPlaybackCursor, let score = scoreProvider()
    else { return nil }
    return score.cursor(advancedByBeats: Self.pageLookaheadBeats, from: raw)
}

/// Lead distance for `pageAnchorCursor`, in quarter-note beats. Shorter than the scroll lead so
/// the playhead is only briefly on the prior page during an anticipatory page turn.
static let pageLookaheadBeats: Double = 1
```

(`scrollAnchorCursor` / `scrollLookaheadBeats = 2` are unchanged and reused by horizontal.)

### 2. iOS — `HorizontalScoreContainer` lookahead left-align

- Add a `scrollAnchorCursor: ScoreCursor?` parameter (2-beat lookahead).
- Change `autoScroll(cursor:)` → `autoScroll(realCursor:lookaheadCursor:)`; trigger via
  `.onChange(of: [playbackCursor, scrollAnchorCursor])`.
- **X axis:** when `lookaheadCursor` is non-nil and both `measureRect(for: realCursor)` and
  `measureRect(for: lookaheadCursor)` resolve, compute:
  ```swift
  let realMin = (realMeasure.minX + scorePadding) * zoom
  let realMax = (realMeasure.maxX + scorePadding) * zoom
  let lookMax = (lookaheadMeasure.maxX + scorePadding) * zoom
  // Axis-agnostic reuse: "system" params carry the playing measure's X-span; pin its leading edge.
  newX = CGFloat(scrollOffsetPinningSystemTop(
      current: Double(curX), systemMin: Double(realMin), systemMax: Double(realMax),
      lookaheadMax: Double(lookMax), viewport: Double(viewport.width), topInset: Double(pad),
  ))
  ```
  When `lookaheadCursor` is `nil` (paused / scrub), keep the existing
  `horizontalMeasureScrollOffset` on the real measure.
- **Y axis:** unchanged (the existing gentle keep-in-view for when content is taller than the
  viewport).

### 3. iOS — `PagedScoreContainer` virtual-cursor page follow

- Add a `pageAnchorCursor: ScoreCursor?` parameter (1-beat lookahead).
- Change the trigger to `.onChange(of: [playbackCursor, pageAnchorCursor])` and call
  `followCursor(pageAnchorCursor ?? playbackCursor)`. `followCursor(_:)` is unchanged — it maps
  the cursor → measure → system → page range and `commitPageTurn`s. Feeding it the 1-beat
  lookahead during playback turns to the virtual cursor's page; feeding the real cursor when
  paused preserves manual-seek behavior.

### 4. iOS — `ReaderRootScreen` wiring

Pass `scrollAnchorCursor: viewModel.playbackSession.scrollAnchorCursor` to
`HorizontalScoreContainer`, and `pageAnchorCursor: viewModel.playbackSession.pageAnchorCursor`
to `PagedScoreContainer`. (Vertical already gets `scrollAnchorCursor`.)

### 5. Android — `ReaderAudioViewModel.pageAnchorCursor` StateFlow (1-beat)

Add a sibling of `scrollAnchorCursor` with a 1-beat lead, via the same JNI bridge:

```kotlin
val pageAnchorCursor: StateFlow<ScoreCursor?> =
    _engine.flatMapLatest { engine ->
        if (engine == null) flowOf(null)
        else combine(engine.state, engine.currentCursor) { state, cursor ->
            val handle = scoreHandle
            if (state != PlaybackState.PLAYING || cursor == null || handle == null) null
            else ScoreCursorCodec.decode(
                SheetMusicJNI.nativeCursorAdvancedByBeats(handle, ScoreCursorCodec.encode(cursor), PAGE_LOOKAHEAD_BEATS),
            )
        }
    }.stateIn(viewModelScope, SharingStarted.Eagerly, null)

// companion object:
const val PAGE_LOOKAHEAD_BEATS = 1.0
```

### 6. Android — `HorizontalScore` lookahead left-align

In `HorizontalScore`'s auto-scroll `LaunchedEffect`, combine the real cursor with
`audioVm.scrollAnchorCursor` (2-beat). When the anchor is non-null, fetch the lookahead
measure via `nativeMeasureFrame(anchor)` and call `nativeScrollOffsetPinningSystemTop` on the X
axis (real measure span + lookahead measure right edge, `topInset = padPx`); when null, keep
the existing `nativeHorizontalMeasureScrollOffset` on the real measure. The vertical-when-zoomed
block stays unchanged.

### 7. Android — `PagedScore` virtual-cursor page follow

In `PagedScore.kt`'s page-turn `LaunchedEffect`, source the cursor from
`audioVm.pageAnchorCursor` combined with `audioVm.currentCursor` and use
`anchor ?? real` for the `nativeCursorFrame` → `breaksMm` band search →
`pagerState.animateScrollToPage(target)`. During playback this turns to the virtual cursor's
page; paused falls back to the real cursor.

### 8. iOS — PiP frame renderer lookahead (added per user request)

PiP's score scroll (`ScorePiPFrameRenderer.advanceScroll`) is already measure-left-align (the
same model as horizontal), driven per-frame by a `CADisplayLink` smooth lerp toward a target
offset, following the REAL cursor only. Graft the 2-beat lookahead the same way as horizontal —
the **rendered cursor stays on the real position** (PiP blits the real cursor rect):

- `ReaderViewModel.wirePiPSession()`: add `pipSession.scrollAnchorCursorProvider = { [weak self] in self?.playbackSession.scrollAnchorCursor }`.
- `ReaderPiPSession`: add `var scrollAnchorCursorProvider: () -> ScoreCursor? = { nil }`; in `notifyCursorChanged()` also push `coordinatorBacking?.updateScrollAnchorCursor(scrollAnchorCursorProvider())`.
- `ScorePiPCoordinator`: add a `scrollAnchorCursor` state + `updateScrollAnchorCursor(_:)`; in `pumpTick` call `renderFrame(playbackCursor: currentCursor, lookaheadCursor: scrollAnchorCursor)`.
- `ScorePiPFrameRenderer`: `renderFrame(playbackCursor:lookaheadCursor:)` keeps the rendered cursor on `playbackCursor`; `advanceScroll(realCursor:lookaheadCursor:)` sets, when the lookahead is present, `targetScrollOffsetDocX = scrollOffsetPinningSystemTop(current: scrollOffsetDocX, systemMin: realMeasure.minX, systemMax: realMeasure.maxX, lookaheadMax: lookaheadMeasure.maxX, viewport: viewportWidthDoc, topInset: padDoc)` (else the existing real-measure target). The per-frame lerp then animates toward the anticipated target. `import Domain`.

This is the horizontal 2-stage trigger applied to PiP: it left-aligns the playing measure ~2
beats before that measure would overflow the small PiP viewport. **Android PiP** is unimplemented
(see Non-goals) and will inherit the same behavior when built.

## Data flow (per mode, during playback)

```
Horizontal:  real + 2-beat anchor → measureRect/nativeMeasureFrame (both) →
             scrollOffsetPinningSystemTop(X: real measure span, lookahead measure maxX) →
             left-align playing measure (fires when real OR lookahead measure off-screen)
Page:        1-beat anchor → cursor→page (existing followCursor / breaksMm search) →
             commitPageTurn / animateScrollToPage to the VIRTUAL cursor's page
PiP (iOS):   real + 2-beat anchor → measureDocRect (both) → scrollOffsetPinningSystemTop →
             per-frame lerp toward the left-aligned playing measure (rendered cursor stays real)
```

Highlight stays on the real `displayCursor` in both modes.

## Testing

- **iOS / Android — no new unit-testable pure function** (reuse of already-tested
  `scrollOffsetPinningSystemTop` + `cursor(advancedByBeats:)`). The `pageAnchorCursor` mirrors
  the tested `scrollAnchorCursor` with a different constant; an optional Reader test can assert
  it equals `score.cursor(advancedByBeats: 1, from: rawPlaybackCursor)` while playing and `nil`
  when paused (Swift Testing, fake controller — mirrors the existing scrollAnchorCursor tests).
- **iOS build:** Reader package builds; previews/horizontal/paged construction updated.
- **Android build:** `:FolinoReaderAndroid:compileDebugKotlin`.
- **Manual / on-device (both platforms):**
  - **Horizontal:** during playback the playing measure left-aligns ~2 beats before it would
    scroll off the right; paused/scrub unchanged; Y (zoomed) unchanged.
  - **Page:** the page turns ~1 beat before the playhead reaches the next page; the highlight
    briefly trails on the prior page (expected); paused/manual seek turns on the real cursor;
    swipe-to-turn unaffected.
  - **PiP (iOS):** the small PiP score left-aligns the playing measure ~2 beats early (the
    rendered cursor stays on the real position); paused holds; the per-frame motion stays smooth.
  - Vertical unchanged.

## Risks / open notes

- **Page playhead briefly off-screen.** By design (virtual-cursor page active), the highlighted
  playhead can sit on the prior, off-screen page for up to ~1 beat during the anticipatory turn.
  The 1-beat lead keeps it brief; tune `pageLookaheadBeats` / `PAGE_LOOKAHEAD_BEATS` if it feels
  too long or too short.
- **Axis-agnostic reuse naming.** `scrollOffsetPinningSystemTop` keeps its vertical-flavored
  name; the horizontal call sites carry a comment mapping "system"→measure X-span. If this reads
  poorly in review, a follow-up can rename it generically (ripples to vertical + the JNI bridge).
- **Horizontal lead vs measure width.** A 2-beat lookahead measure may be the same measure as
  the real cursor's (then the trigger is just the real measure leaving) or the next measure
  (anticipation). Both are handled by the single `scrollOffsetPinningSystemTop` call.

## Parity

Same design and shared logic on both platforms (the pin math + lookahead cursor are bridged
Swift; only the Compose/SwiftUI wiring differs). No new shared code, so parity is automatic.

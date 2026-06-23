# Reader vertical-mode lookahead auto-scroll — design

**Status:** Implemented
**Date:** 2026-06-22
**Feature package:** `Packages/Features/Reader`
**Touches:** `swift-sheet-music` (`SheetMusicCore`), `Reader`, `Domain`

> **Revision (2026-06-23):** The scroll *position* was refined during implementation per user
> feedback. The original sketch was "anchor-only minimal keep-in-view" (reuse
> `scrollOffsetKeepingInView` on the lookahead cursor). The shipped behavior instead **pins the
> playing cursor's system to the top of the viewport** (cleared below the top overlay), via a new
> `Domain.scrollOffsetPinningSystemTop`, re-scrolling only when the lookahead *or* the playing
> system leaves the viewport. The 2-beat lookahead still drives the trigger timing. The sections
> below reflect the shipped behavior; superseded "anchor-only" wording is annotated where it remains.

## Goal

In the Reader's **vertical** mode, the score auto-scrolls to keep the playback cursor on
screen. Today the scroll fires reactively: it only moves once the *currently playing* cursor
has crossed the viewport edge. The user wants the scroll to fire **earlier** — roughly
**2 beats ahead** of the playing cursor — so the next region is revealed before the playhead
reaches it and the reader always has lead time.

Crucially, the **highlighted / playing cursor must not move**. Only the *scroll trigger*
looks ahead. The cursor the user sees pulsing on the staff stays at the real playback
position; the viewport just scrolls to where playback *will be* 2 beats from now.

## Key insight that shaped the design

"Where will the cursor be 2 beats from now" is **pure notation math** — it depends only on
the score's measures, `division`, and the current tick, not on the audio engine, tempo, or
any live state. `SheetMusicCore` already hosts exactly this family of helpers as `Score`
extensions:

- `Score.seconds(at:)` / `Score.cursor(atSeconds:)` / `notatedDurationSeconds`
  (`Score+NotatedTime.swift`) — the seek bar's time↔cursor map.
- `Score.cursorSteppingMeasure(from:direction:)` (`Score+MeasureStep.swift`) — measure-grain
  cursor stepping.
- `Score.translateCursorForHiddenStaves(_:hiddenStaves:)` (`Score+FilteredTapCursor.swift`).

These are already bridged to Android via `SheetMusicAndroidJNI` (`CursorBridge.swift`,
`MeasureStepBridge.swift`), which is the project's established parity pattern for
cursor/notation logic: **implement once in `SheetMusicCore`, expose to Android through a JNI
bridge.**

So the lookahead is a single new pure `Score` extension —
`cursor(advancedByBeats:from:)` — sitting next to `cursor(atSeconds:)`. The Reader feeds it
the live cursor and uses the result *only* to drive auto-scroll.

**This supersedes the brainstorming sketch.** During brainstorming we discussed a lookahead
query on `PlaybackEngine.PlaybackTimeline` plus a new `PlaybackController` (Domain protocol)
method. Both are unnecessary and were dropped:

- **No `PlaybackController` / Domain protocol change** — avoids a public-protocol ripple
  across Features (and its sign-off). The lookahead needs only the `Score`, which the Reader
  already holds.
- **No `PlaybackEngine` / `PlaybackTimeline` change** — the audio engine's timeline is an
  *expanded* schedule (and only exists during playback). Computing from the notated `Score`
  is simpler, always available, and is what scroll-follow actually wants (2 notated beats
  ahead).

## Non-goals

- **No change to highlight / playing-cursor behavior.** The on-staff cursor stays at the real
  position. Only the scroll anchor looks ahead.
- **Horizontal and Page modes are untouched.** Horizontal uses measure-anchored scrolling and
  Page uses pagination — different logic, out of scope here.
- **No PiP change.** The Picture-in-Picture renderer has its own per-frame scroll smoothing.
- **No new Settings UI.** The lead amount is a single source-of-truth constant (default 2
  beats), tunable in code; exposing it as a user setting is a possible later step, not now.
- **No Android UI work in this task.** The shared `SheetMusicCore` function is placed so
  Android's reader can adopt the same lookahead later via a JNI bridge + Compose scroll; that
  is a separate follow-up (see Parity).
- **No `PlaybackController` / `PlaybackEngine` / `PlaybackTimeline` change.**

## Decisions (from brainstorming)

| Question | Decision |
| --- | --- |
| Predictive vs. reactive | **Predictive** — drive auto-scroll off a *future* cursor, not a geometric margin bias. |
| Lead unit | **Beats** (musically anchored, scales the wall-clock lead with tempo). Quarter-note beats: a beat = `division` ticks. |
| Lead amount (default) | **2 beats.** Single constant, code-tunable. |
| Where the lookahead lives | **`SheetMusicCore` `Score` extension** (pure notation), next to the seek map. Shared with Android, JNI-bridgeable. |
| Highlight vs. scroll cursor | **Separated.** Highlight = live `displayCursor`; scroll anchor = lookahead cursor. |
| Scroll position | **Pin the playing cursor's system to the viewport top** (just below the top overlay), via new `Domain.scrollOffsetPinningSystemTop`. Between scrolls the cursor drifts down through the visible area. *(Supersedes the original "reuse `scrollOffsetKeepingInView` unchanged" sketch.)* |
| Scroll trigger | Re-scroll when the **lookahead system OR the playing system** leaves the viewport. The 2-beat lookahead gives the lead in short systems; in tall systems the subsequent re-pin is driven by the playing system reaching the bottom. |
| Paused / scrubbing / manual seek | Falls back to the gentle `scrollOffsetKeepingInView` (no pin-to-top), so a tap-to-seek doesn't jump the view to the top. |
| When lookahead is active | **Only during continuous playback.** Paused / stopped / scrubbing → anchor is `nil` → auto-scroll falls back to `displayCursor` (today's behavior). |
| Scope | **Vertical mode only.** |

## Components

### 1. `SheetMusicCore` — `Score.cursor(advancedByBeats:from:)`

New pure `Score` extension (new file `Score+NotatedLookahead.swift`, or appended to
`Score+NotatedTime.swift`). Mirrors the existing helpers' primitives
(`effectiveMeasureDurations()`, `division`, `tickInMeasure(of:)`):

```swift
extension Score {
    /// The `.beat` cursor `beats` quarter-note beats after `cursor`, walking measures and
    /// clamping to the score's final notated tick. A beat is `division` ticks. Returns
    /// `cursor` unchanged when `beats <= 0` or the score has no measures. Pure notation
    /// math — no tempo, no audio-engine state — so it is deterministic and is the same
    /// lookahead Android can call through a JNI bridge.
    public func cursor(advancedByBeats beats: Double, from cursor: ScoreCursor) -> ScoreCursor {
        let lengths = effectiveMeasureDurations().map { $0.ticks(division: division) }
        guard !lengths.isEmpty, beats > 0 else { return cursor }
        var measure = min(max(cursor.measureIndex, 0), lengths.count - 1)
        var tick = min(max(tickInMeasure(of: cursor), 0), lengths[measure])
        var remaining = Int((beats * Double(division)).rounded())
        while remaining > 0 {
            let ticksLeftInMeasure = lengths[measure] - tick
            if remaining <= ticksLeftInMeasure {
                return .beat(measureIndex: measure, tickInMeasure: tick + remaining)
            }
            remaining -= ticksLeftInMeasure
            if measure == lengths.count - 1 {
                return .beat(measureIndex: measure, tickInMeasure: lengths[measure])
            }
            measure += 1
            tick = 0
        }
        return .beat(measureIndex: measure, tickInMeasure: tick)
    }
}
```

- Returns a **`.beat`** cursor, which is **staff-agnostic** — so no hidden-staves translation
  is needed downstream (a `.beat` address means the same column in the full-score and the
  filtered layout).
- Reads `tickInMeasure(of:)` on the *input* cursor, which may be `.item` (engine note onset)
  or `.beat`. The caller passes the **full-score-addressed** cursor (see below) so an `.item`
  resolves against the right staff.
- Tempo-independent in tick space: 2 beats is always `2 * division` ticks. Tempo only affects
  how much wall-clock those 2 beats take — which is exactly the desired "more lead time at
  slow tempo" behavior.

### 2. `Reader` — `ReaderPlaybackSession.scrollAnchorCursor`

Add a computed property to `ReaderPlaybackSession`:

```swift
/// Lookahead anchor for vertical-mode auto-scroll: the `.beat` cursor `scrollLookaheadBeats`
/// beats after the live position, so the score scrolls before the playing cursor reaches the
/// viewport edge. Non-nil ONLY during continuous playback (not paused / stopped / scrubbing);
/// callers fall back to `displayCursor` when nil, preserving today's reactive behavior.
var scrollAnchorCursor: ScoreCursor? {
    guard isPlaying, scrubCursor == nil,
          let raw = rawPlaybackCursor, let score = scoreProvider()
    else { return nil }
    return score.cursor(advancedByBeats: Self.scrollLookaheadBeats, from: raw)
}

static let scrollLookaheadBeats: Double = 2
```

- Uses **`rawPlaybackCursor`** (the engine's original full-score address), not the filtered
  `playbackCursor`, exactly as `playbackFraction` does — so `tickInMeasure(of:)` resolves
  against the correct staff and never walks a wrong/empty staff. The `.beat` result is
  staff-agnostic, so no `translateCursorForHiddenStaves` step is required.
- Observation: it reads the observable stored props `isPlaying`, `scrubCursor`,
  `rawPlaybackCursor`. When any changes, a SwiftUI view reading `scrollAnchorCursor`
  re-evaluates — so the container's auto-scroll `onChange` fires as the anchor advances.
- `scrubCursor == nil` guard: during a seek-bar drag the score follows the thumb with no
  lookahead (`displayCursor` already tracks the provisional position).

### 3. `Reader` — `VerticalScoreContainer` consumes the anchor for scroll only

`VerticalScoreContainer` currently takes one `playbackCursor: ScoreCursor?` and uses it for
**both** the highlight (passed to `VerticalZoomedSurface` → `ScoreView(playbackCursor:)`) and
the scroll (`.onChange(of: playbackCursor) { autoScroll(cursor: …) }`). Separate them:

- Add a parameter `scrollAnchorCursor: ScoreCursor?` (the lookahead).
- **Highlight unchanged:** keep passing `playbackCursor` to `VerticalZoomedSurface`. The
  on-staff cursor still renders at the live/display position. `VerticalZoomedSurface` does not
  change.
- **Scroll = pin the playing system to the top.** `autoScroll(realCursor:lookaheadCursor:viewport:)`
  takes both cursors and fires on `.onChange(of: [playbackCursor, scrollAnchorCursor])`. During
  playback (lookahead non-nil) the **Y** offset is computed by `Domain.scrollOffsetPinningSystemTop`
  from the playing cursor's system span and the lookahead system's bottom — pinning the playing
  system's top to a **screen-space** clearance below the floating top overlay
  (`safeAreaTop + ReaderTopOverlay.height + 8`, not zoom-scaled, since `contentOffset` shares the
  scaled-content point space). The **X** offset still keeps the playing column in view via
  `scrollOffsetKeepingInView` (only relevant when zoomed). When the lookahead is `nil` (paused /
  scrubbing / manual seek), both axes fall back to `scrollOffsetKeepingInView` so a tap-to-seek
  doesn't jump the view to the top. `cursorFrame(for:in:)` (whose Y span is the cursor's whole
  system) and the `ScoreScrollHost` command path are unchanged.

### 5. `Domain` — `scrollOffsetPinningSystemTop` (pure pin-to-top + trigger)

New pure function next to `scrollOffsetKeepingInView` (`ScrollFollow.swift`), shared/testable for
iOS-Android parity:

```swift
public func scrollOffsetPinningSystemTop(
    current: Double,
    systemMin: Double, systemMax: Double,   // playing cursor's system span (scaled content coords)
    lookaheadMax: Double,                    // lookahead cursor's system bottom
    viewport: Double,
    topInset: Double,                        // screen-space clearance below the top overlay
) -> Double {
    let viewTop = current, viewBottom = current + viewport
    let systemFullyVisible = systemMin >= viewTop && systemMax <= viewBottom
    let lookaheadVisible = lookaheadMax <= viewBottom
    if systemFullyVisible, lookaheadVisible { return current }   // drift: no scroll
    return max(0, systemMin - topInset)                          // pin the system top below the overlay
}
```

This yields both behaviors the user described: in **short** systems the lookahead reaching the
bottom snaps the playing system to the top, then the cursor drifts through several fully-visible
systems with no further scroll; in **tall** systems (≈1 fits below the pinned one) the next snap
waits until the playing system itself leaves the viewport bottom. Clamped at 0; the
`ScoreScrollHost` clamps the trailing extent.

### 4. `Reader` — wire the anchor through `ReaderRootScreen`

`ReaderRootScreen` already passes `playbackSession.displayCursor` to the score containers. For
the **vertical** container only, also pass
`scrollAnchorCursor: viewModel.playbackSession.scrollAnchorCursor`. `HorizontalScoreContainer`
and `PagedScoreContainer` call sites are unchanged.

## Data flow

```
engine cursor tick → ReaderPlaybackSession.rawPlaybackCursor (full-score addr)
                       │
                       ├─ applyCursorTranslation → playbackCursor (filtered)  ─→ displayCursor ─→ HIGHLIGHT (unchanged)
                       │
                       └─ scrollAnchorCursor (computed, only while playing):
                             score.cursor(advancedByBeats: 2, from: rawPlaybackCursor)   // .beat, staff-agnostic
                                │
ReaderRootScreen → VerticalScoreContainer(playbackCursor: displayCursor,
                                          scrollAnchorCursor: scrollAnchorCursor)
                                │
                       .onChange(of: [displayCursor, scrollAnchorCursor])
                       → autoScroll(realCursor: displayCursor, lookaheadCursor: scrollAnchorCursor)
                                │  Y (playing): scrollOffsetPinningSystemTop(playing-system span, lookahead bottom, overlay clearance)
                                │  X (playing): scrollOffsetKeepingInView(playing column)   ·   paused/scrub: keep-in-view both axes
                                │
                       cursorFrame(for:in:) [Y span = whole system] → setContentOffset(animated:)
```

Net effect: the scroll fires ~2 beats before the playing cursor reaches the viewport edge (the
lookahead trigger) and pins the playing cursor's system to the top of the viewport (clear of the
top overlay), while the highlight stays on the real position.

## Testing

- **`SheetMusicCore` unit tests (Swift Testing)** for `cursor(advancedByBeats:from:)`:
  - advance staying within the current measure;
  - advance crossing exactly one measure boundary;
  - multi-measure advance (lead longer than the current measure's remainder);
  - clamp at end-of-score (advance past the last tick → final tick of the last measure);
  - `beats <= 0` → returns the input cursor unchanged;
  - empty score → `.beat(0, 0)` / input unchanged;
  - input is `.item` vs `.beat` → same resulting `.beat` position;
  - mixed measure lengths (e.g. a 3/4 measure between 4/4 measures) tick accounting.
- **`Reader` tests (Swift Testing, fake `PlaybackController`)** for `scrollAnchorCursor`:
  - `nil` when paused / stopped;
  - `nil` while scrubbing (`scrubCursor != nil`);
  - while playing, equals `score.cursor(advancedByBeats: 2, from: rawPlaybackCursor)`;
  - advancing `rawPlaybackCursor` advances the anchor by the same lead;
  - highlight path (`displayCursor`) is unaffected by the anchor.
- **`Domain` tests (Swift Testing)** for `scrollOffsetPinningSystemTop`: no-move when the system
  and lookahead are visible; lookahead-below pins the visible system to the top; system-below and
  system-above pin it; clamp at 0; system taller than the viewport pins its top; stays put once
  pinned and the lookahead is back in view.
- **Manual / preview (vertical mode, on device):** during playback the playing cursor's system
  pins to the top of the viewport (clear of the top overlay) ~2 beats before it would reach the
  bottom edge; in short systems the cursor then drifts through several visible systems before the
  next pin; in tall systems the next pin waits until the playing system reaches the bottom; the
  highlighted cursor never jumps ahead; pausing freezes scrolling; seek-bar scrub / tap-to-seek
  use the gentle keep-in-view (no jump to top); Horizontal / Page / PiP behave exactly as before.

## Risks / open notes

- **Lead feel is subjective.** 2 beats is the starting default in `scrollLookaheadBeats`. If
  on-device it reads as too much / too little, change the one constant. Switching the *unit*
  to wall-clock seconds later is a one-line swap that reuses the existing seconds map
  (`score.cursor(atSeconds: score.seconds(at: raw) + leadSeconds)`); the call sites don't
  change.
- **Quarter-note beats vs. metric beats.** The lead is in quarter-note beats (`division`
  ticks), consistent with `effectiveQuarterBpm`. In compound meters (6/8 etc.) a metric beat
  is a dotted quarter, so "2 beats" is 2 quarters, not 2 dotted-quarters. Acceptable for v1;
  refining to metric beats is a later tweak inside the same function.
- **Pin clearance / overlay.** The pinned system top sits at `safeAreaTop +
  ReaderTopOverlay.height + 8` screen points so it clears the floating Back / inspector overlay at
  any zoom. The `+ 8` gap is tunable; raise it (~12) if the overlay's glass shadow should be
  cleared too.
- **Tall systems (system > viewport).** Pinning the system top still leaves its bottom off-screen
  (unavoidable). No re-scroll loop: once the top is in place, the pin computes the same offset.
- **Manual-scroll preservation.** While playing, the pin re-scrolls only when the playing or
  lookahead system leaves the viewport, so a manual scroll that keeps both visible is preserved
  until the next genuine trigger. Paused / scrubbing keeps the original `scrollOffsetKeepingInView`
  (fully-visible target untouched).

## Parity follow-up (out of scope here)

The shared logic lives in `SheetMusicCore`, so Android can reach the *same*
`cursor(advancedByBeats:from:)` by adding a bridge in `SheetMusicAndroidJNI` (alongside
`CursorBridge` / `MeasureStepBridge`) and applying the anchor to its Compose vertical-scroll
follow. That is a separate Android task; this spec covers the shared function and the iOS
vertical Reader only.

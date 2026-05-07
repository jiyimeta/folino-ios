# Reader A–B Repeat — Native Loop Rewire

Date: 2026-05-07
Status: Drafting (awaiting user spec review)

## Goal

Replace the host-side cursor-watching A–B repeat machinery with calls into
`PlaybackEngine.setLoop` / `clearLoop` (added in
`swift-sheet-music@795f0c5`). The new engine APIs configure
`AVMusicTrack.loopRange` + `isLoopingEnabled` for sample-accurate native
looping, removing the source of audio glitches and the suppression logic the
host needed to avoid them.

User-visible behavior is unchanged: the inspector's repeat-mode cycle button,
the A/B pill, the loop-region overlay, and persistence in
`PlaybackPreferences` all continue to work the same way. What changes is the
audio path underneath.

## Non-goals

- Reworking the inspector UI, the A/B pill, the loop-region overlay, or the
  persistence schema. `ABRepeatRange` (`ChordPath`-based) stays the storage
  format.
- Beat-precision A/B endpoints. The Reader still snaps A to the head of a
  measure and B to the last chord of a measure.
- Touching `swift-sheet-music`. The new engine API is already in place; this
  spec consumes it.

## Background — what's broken today

The current A–B loop wraps the cursor by **observing the engine's cursor
stream** in two places:

1. `LivePlaybackController` — sees a cursor past B, calls `engine.seek(to: A)`.
2. `ReaderViewModel` — same logic, also calls back into the controller.

Each call into `engine.seek(to:)` while playing forces a stop / write / start
cycle on the running `AVAudioSequencer`. The sequencer emits a few stale "past
B" cursors before the seek lands, which would re-trigger the wrap, so we added:

- `LivePlaybackController.isSeekingLoopStart` — flag, suppresses re-fire while
  the seek is in flight.
- `LivePlaybackController.dispatchCursor(_:) -> CursorDispatch` — drops the
  stale cursor.
- `ReaderViewModel.isHandlingLoopWrap` + `shouldIgnoreObservedCursor` — same
  flag pattern at a different layer.
- `ReaderViewModel.evaluateLoopWrap`, `seekToLoopStart`, `preSeekIfNeeded` —
  the host-side wrap logic itself.

Even with all of that, the audio path is fragile (audible "tick" on wrap,
sequencer occasionally desyncs from the cursor) because we're driving the wrap
from outside the engine.

## What the new engine API gives us

`PlaybackEngine.setLoop(from: ScoreCursor, to: ScoreCursor)` writes
`AVMusicTrack.loopRange` + `isLoopingEnabled` on every track. The sequencer
wraps **at the boundary, sample-accurately**, with no audible glitch. The
engine's own cursor poll already folds the sequencer's monotonic beat counter
back into `[startTick, endTick)`, so the cursor stream observers see the
wrapped position naturally.

`engine.play(...) / seek(...) / skip(...)` all snap out-of-range positions
to the loop start automatically.

`clearLoop()` disables looping and restores each track's original length.

Both `setLoop` and `clearLoop` pause playback before mutating
`AVMusicTrack.lengthInBeats` (live track-length mutation on a running
sequencer isn't supported). The host is expected to resume via `play(...)`.

## Design

### 1. `LivePlaybackController.setLoopRange` becomes a thin adapter

```swift
public func setLoopRange(_ range: ABRepeatRange?) {
    let wasPlaying = engine.state == .playing
    if let range, let score = loadedScore,
       let (start, end) = loopCursors(for: range, in: score)
    {
        applyLoop(start: start, end: end, in: score)
    } else {
        engine.clearLoop()
    }
    if wasPlaying, let score = loadedScore {
        engine.play(in: score)
    }
}
```

`loopCursors(for:in:)` resolves the `ABRepeatRange` (`ChordPath` measure
indices) to a pair of `ScoreCursor`s:

- `start = .beat(measureIndex: range.start.measureIndex, tickInMeasure: 0)`
- `end = .beat(measureIndex: range.end.measureIndex + 1, tickInMeasure: 0)`
  — half-open at the next measure's downbeat, so the end measure plays
  through before the wrap.
- **Last-measure case** (`range.end.measureIndex + 1 ≥ totalMeasures`):
  `.beat(...)` past the score won't resolve to a frame. Fall back to
  `engine.setLoop(from: start, throughEndOf: lastID)` where `lastID` is the
  `ScoreItemID` of the final chord in the end measure.

`applyLoop` picks `setLoop(from:to:)` vs `setLoop(from:throughEndOf:)` based on
that fallback.

A small free function — `lastScoreItemID(inMeasure: Int, of: Score)` — walks
`score.parts.first.staves.first.measures[m].voices.first.elements`, finds the
last `.chord`, and lifts a representative `ScoreItemID.note(...)` from its
notes (or `.rest(...)` if it's a rest). Single staff, single voice — same
shape `RepeatLoop.snapMeasureEnd` already uses, but returning an item ID
rather than a `ChordPath`.

### 2. `setCursor` reverts to a plain `engine.seek`

The engine snaps any out-of-range tick into the loop on its own. We no longer
need:

- The "past loop end → seek to start" branch in `setLoopRange`.
- The `isSeekingLoopStart` flag and the `CursorDispatch` enum dispatcher.
- The `loopRange` field on the controller.
- The `cursorIsPastLoopEnd` / `measureIndex(of:)` helpers.

The Combine sink on `engine.$currentCursor` simplifies to forwarding the
value directly to `cursorHandler`.

### 3. `ReaderViewModel` stops watching the cursor for wrap

Delete:

- `evaluateLoopWrap(for:)`
- `seekToLoopStart(_:)`
- `preSeekIfNeeded(controller:score:)`
- `shouldIgnoreObservedCursor(_:)`
- `isHandlingLoopWrap`
- The `if shouldIgnoreObservedCursor(value) { return }` early-out in
  `startObservingCursor`'s handler — it becomes a one-liner that just
  assigns `playbackCursor`.
- The pre-seek call in `togglePlayback` — the engine snaps into the loop on
  its own when `play(...)` is called past the loop end.

Keep:

- All the marker / range mutators (`setRepeatA`, `setRepeatB`, `clearRepeatA`,
  `clearRepeatB`, `advanceRepeatMode`).
- `forwardLoopRangeToController` — same name, same call site, just the
  controller does something useful with the range now.
- `activeLoopRange(in:)` — picks the right range based on `repeatMode`.

### 4. Test cleanup (aggressive)

Delete the wrap-mechanism tests in `ReaderViewModelRepeatTests`:

- `cursorPastEndDuringPlaybackSeeksToStartOfA`
- `stalePastEndCursorDoesNotOverwriteLoopStartWhileWrapIsPending`
- `cursorWithinLoopDoesNotTriggerSeek`
- `cursorWrapDoesNotFireWhilePaused`
- `nilCursorDuringLoopAllPlaybackWrapsToStart`
- `togglePlaybackPreSeeksToAWhenCursorAlreadyPastB`
- `rapidPastEndCursorEmissionsTriggerOnlyOneSeek`
- `wrapReArmsAfterCursorReturnsInsideLoop`

Keep — and verify still pass:

- `repeatModeDefaultsToOff`
- `advanceRepeatModeCyclesAndPersists`
- `setRepeatASnapsToCursorMeasureHead`
- `setRepeatBSnapsToCursorMeasureEnd`
- `setRepeatAReplacesPreviousAValue`
- `clearRepeatARemovesStartButKeepsEnd`
- `clearRepeatBRemovesEndButKeepsStart`
- `advanceRepeatModeForwardsLoopRange`
- `setRepeatAOnlyDoesNotForwardLoopRangeYet`
- `bothMarkersSetForwardsTheNormalizedRange`
- `persistedAbRepeatIsSeededIntoControllerOnPlaybackPrep`

These all stay valuable — they exercise the persistence + range-forwarding
contract, not the wrap mechanism.

`FakePlaybackController.recordedSetCursorCalls` stays (other suites use it),
but no repeat tests mention it after this pass.

### 5. Domain protocol stays

`PlaybackController.setLoopRange(_ range: ABRepeatRange?)` keeps its current
signature. Only `LivePlaybackController`'s implementation changes; the Domain
abstraction level (persistence-typed `ABRepeatRange`) is correct.

### 6. Auto-resume on setLoop / clearLoop

`PlaybackEngine.setLoop` / `clearLoop` pause playback internally. Folino's UX
(unlike the desktop example) treats marker toggles as transparent — the user
expects audio to keep playing if it was playing. The controller snapshots
`engine.state == .playing` before each call, then resumes via
`engine.play(in: loadedScore)` afterwards. Idempotent across the
`setLoopRange(nil)` clear path too.

## Files touched

- `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift` —
  `setLoopRange` rewrite, simplifications listed in §1–2.
- `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` —
  deletions listed in §3.
- `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift`
  — deletions listed in §4.
- The `loopCursors(for:in:)` and `lastScoreItemID(inMeasure:of:)` helpers
  live inside `LivePlaybackController.swift` (private methods). They're
  purely about the engine-side cursor mapping; `RepeatLoop.swift` stays
  reserved for the Reader feature's score-side helpers (`snapMeasureHead`,
  `snapMeasureEnd`, `scoreFullRange`, `normalize`).

## Verification

- `swift test` in `Packages/Features/Reader` (kept tests pass after deletions).
- `swift test` in `Packages/Infrastructure` (controller unit tests still
  green; if there are no controller tests for `setLoopRange` yet — there
  aren't — leave coverage to the manual verification step; the cursor mapping
  is a small free function we could unit-test if it grows).
- Manual: open a multi-measure score in the simulator, set A and B at
  different measure pairs (including the very last measure), press play,
  confirm the audio wraps cleanly with no audible click and the cursor
  remains in `[A, B]`. Confirm setting A or B mid-playback continues
  audio without a perceptible pause.
- Manual: with `repeatMode == .loopAll`, confirm the score loops at its end
  with the cursor wrapping to measure 0.

## Risks

- **Last-measure mapping**: the `ScoreItemID` lookup helper could miss edge
  cases (empty measure, measure with only rests). Mitigation: walk `.chord`
  AND `.rest` elements when looking for the "last item"; if neither exists,
  fall back to `setLoop(from:to:)` with a beat cursor at the start of the
  end measure (degraded but non-crashing).
- **Track-length restore on `clearLoop`**: the engine restores
  `originalTrackLengths` snapshotted at the time of `setLoop`. If the host
  changes the score (re-`prepare`) between `setLoop` and `clearLoop`, the
  cached lengths point at released tracks. The engine handles this in
  `prepare(score:)` by calling `clearLoop()` itself first, so the host
  doesn't need to coordinate.
- **Auto-resume races**: if the engine is mid-`pause` from a different code
  path when we snapshot `state`, we might resume something the user just
  paused. In practice the engine's `state` is published synchronously on
  the MainActor, and our code paths into it are also MainActor — the
  snapshot + resume happen in the same actor work item, so no interleave.

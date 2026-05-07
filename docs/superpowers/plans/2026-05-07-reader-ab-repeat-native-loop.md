# Reader A–B Repeat — Native Loop Rewire — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the host-side cursor-watching A–B loop wrap with `PlaybackEngine.setLoop` / `clearLoop` (native `AVMusicTrack.loopRange` looping). User-visible behavior unchanged; audio glitches and the suppression flags they required go away.

**Architecture:** `LivePlaybackController.setLoopRange` resolves the persistence-typed `ABRepeatRange` (`ChordPath` measure indices) to engine-typed `ScoreCursor` endpoints and forwards them to `PlaybackEngine.setLoop(from:to:)` (or `setLoop(from:throughEndOf:)` for the last-measure case where there's no measure `N+1` downbeat to half-open at). Controller snapshots playback state and resumes via `engine.play(in:)` after — `setLoop`/`clearLoop` pause internally. `ReaderViewModel` and `LivePlaybackController` lose all the cursor-stream watching machinery that previously implemented wraps from the host side.

**Tech Stack:** Swift 6.3, Swift Testing, `swift-sheet-music@f18847d` (the revision pinned across all three packages on this branch).

**Spec:** `docs/superpowers/specs/2026-05-07-reader-ab-repeat-native-loop-design.md`

---

## File Structure

**Modified:**

- `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift` — `setLoopRange` rewrite, `setCursor` revert, cursor-sink simplification, deletion of `dispatchCursor` / `loopRange` field / `isSeekingLoopStart` / `seekToLoopStart` / `cursorIsPastLoopEnd` / `measureIndex(of:)` / `CursorDispatch` enum. Adds private `loopBounds(for:in:)` and `lastScoreItemID(inMeasure:of:)` helpers (file-local to the controller).
- `Packages/Infrastructure/Tests/InfrastructureTests/Audio/LivePlaybackControllerTests.swift` — adds unit tests for the cursor mapping helpers (private symbols accessed via `@testable import Audio`).
- `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` — drops `evaluateLoopWrap` / `seekToLoopStart` / `preSeekIfNeeded` / `shouldIgnoreObservedCursor` / `isHandlingLoopWrap`; the cursor-observe handler simplifies to a one-liner; `togglePlayback` drops the `preSeekIfNeeded(...)` call.
- `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift` — deletes 8 wrap-mechanism tests (listed in §4 of the spec).

**Untouched (verify still pass):**

- `Packages/Features/Reader/Sources/Reader/RepeatLoop.swift` — score-side `ChordPath` helpers stay as-is.
- `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift` — fake's `setLoopRange` continues to record calls; no API change.
- `Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift` — protocol signature unchanged.

---

## Task 1: Add cursor-mapping helpers to `LivePlaybackController` (TDD)

**Files:**
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Audio/LivePlaybackControllerTests.swift`

The helpers are pure: `(ABRepeatRange, Score) → LoopBounds?`. `LoopBounds` carries enough info for the caller to pick `engine.setLoop(from:to:)` vs `engine.setLoop(from:throughEndOf:)`. Tested in isolation; the engine itself is not exercised here.

`PlaybackTimeline` registers cursor anchors as `.note(NoteID)` for sounding chords and `.rest(RestID)` for empty chords (rests). The `lastScoreItemID(inMeasure:of:)` helper mirrors that — for the last `.chord` element in the measure, it returns `.note(NoteID(noteIndexInChord: 0))` if `chord.notes.nonEmpty`, otherwise `.rest(RestID(...))`. Walks `score.parts.first.staves.first.measures[m].voices.first.elements`, the same shape `RepeatLoop.snapMeasureEnd` uses.

- [ ] **Step 1: Add the failing test for `loopBounds(for:in:)` on a non-last-measure range**

Add to `LivePlaybackControllerTests.swift`. Drop these alongside the existing fixtures section.

```swift
// MARK: - Loop bounds

@Test func loopBoundsUsesBeatRangeWhenEndIsNotLastMeasure() {
    let score = makeMeasureScore(measureCount: 4)
    let range = ABRepeatRange(
        start: ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 0),
        end: ChordPath(systemIndex: 0, measureIndex: 2, voiceIndex: 0, chordIndex: 0)
    )

    let bounds = LivePlaybackController.loopBounds(for: range, in: score)

    guard case let .beatRange(start, end) = bounds else {
        Issue.record("expected .beatRange, got \(String(describing: bounds))")
        return
    }
    #expect(start == .beat(measureIndex: 1, tickInMeasure: 0))
    #expect(end == .beat(measureIndex: 3, tickInMeasure: 0))
}
```

Then add this fixture builder to the file (next to the existing `makeScore(parts:)`):

```swift
/// Builds a single-part, single-staff score with `measureCount` measures,
/// each containing a single quarter-note chord on voice 0. Just enough
/// shape for the loop-bounds helpers to walk; no actual notes (rests are
/// the unified empty-chord representation, which is what the cursor
/// timeline keys via `.rest(RestID)`).
private func makeMeasureScore(measureCount: Int) -> Score {
    let measures = (0 ..< measureCount).map { _ in
        Measure(voices: [Voice(elements: [.rest(duration: .quarter)])])
    }
    let staff = Staff(measures: measures)
    let part = Part(
        id: "P0",
        instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
        staves: [staff]
    )
    return Score(division: 480, parts: [part])
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter loopBoundsUsesBeatRangeWhenEndIsNotLastMeasure` from `Packages/Infrastructure/`.
Expected: FAIL — `LivePlaybackController.loopBounds` is not defined.

- [ ] **Step 3: Add `LoopBounds` enum and `loopBounds(for:in:)` to `LivePlaybackController.swift`**

Add inside `LivePlaybackController` (replace the `private enum CursorDispatch { ... }` block — that one's going away in Task 2 anyway, but for now leave it untouched and add this alongside):

```swift
/// Half-open loop interval resolved against the loaded score. The
/// caller maps each case to the matching `PlaybackEngine.setLoop`
/// overload — `.beatRange` to `setLoop(from:to:)`,
/// `.throughEndOf` to `setLoop(from:throughEndOf:)`. Latter is used
/// when the loop covers the last measure of the score and there's
/// no measure-`N+1` downbeat to half-open at.
enum LoopBounds: Equatable {
    case beatRange(start: ScoreCursor, end: ScoreCursor)
    case throughEndOf(start: ScoreCursor, last: ScoreItemID)
}

/// Map a persistence-typed `ABRepeatRange` to engine-typed cursor
/// bounds. Returns `nil` when the score has no measures or the
/// range can't be resolved (e.g. last-measure case but the end
/// measure has no chord/rest elements to anchor `throughEndOf` on).
static func loopBounds(
    for range: ABRepeatRange, in score: Score
) -> LoopBounds? {
    let measureCount = score.parts.first?.staves.first?.measures.count ?? 0
    guard measureCount > 0,
          range.start.measureIndex >= 0,
          range.end.measureIndex < measureCount,
          range.start.measureIndex <= range.end.measureIndex
    else { return nil }
    let start = ScoreCursor.beat(
        measureIndex: range.start.measureIndex, tickInMeasure: 0
    )
    let endNext = range.end.measureIndex + 1
    if endNext < measureCount {
        let end = ScoreCursor.beat(
            measureIndex: endNext, tickInMeasure: 0
        )
        return .beatRange(start: start, end: end)
    }
    guard let last = lastScoreItemID(
        inMeasure: range.end.measureIndex, of: score
    ) else { return nil }
    return .throughEndOf(start: start, last: last)
}

/// Last `.chord` element in the given measure (voice 0 of staff 0
/// — same spine the rest of the cursor mapping uses). Returns a
/// `.note(NoteID)` for chords with notes, `.rest(RestID)` for
/// rests (empty chords). `nil` when the measure has no `.chord`
/// elements at all (a measure of clef / time-sig / key-sig only).
static func lastScoreItemID(
    inMeasure measureIndex: Int, of score: Score
) -> ScoreItemID? {
    guard let part = score.parts.first,
          let staff = part.staves.first,
          staff.measures.indices.contains(measureIndex) else { return nil }
    guard let voice = staff.measures[measureIndex].voices.first else {
        return nil
    }
    let elements = voice.elements
    let staffAddress = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    var lastID: ScoreItemID?
    for (idx, element) in elements.enumerated() {
        guard case let .chord(chord) = element else { continue }
        if chord.notes.isEmpty {
            lastID = .rest(RestID(
                staff: staffAddress,
                measureIndex: measureIndex,
                voiceIndex: 0,
                elementIndex: idx
            ))
        } else {
            lastID = .note(NoteID(
                staff: staffAddress,
                measureIndex: measureIndex,
                voiceIndex: 0,
                elementIndex: idx,
                noteIndexInChord: 0
            ))
        }
    }
    return lastID
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter loopBoundsUsesBeatRangeWhenEndIsNotLastMeasure` from `Packages/Infrastructure/`.
Expected: PASS.

- [ ] **Step 5: Add the failing test for the last-measure (`throughEndOf`) case**

Add to `LivePlaybackControllerTests.swift`:

```swift
@Test func loopBoundsUsesThroughEndOfWhenEndIsLastMeasure() {
    let score = makeMeasureScore(measureCount: 3)
    let range = ABRepeatRange(
        start: ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 0),
        end: ChordPath(systemIndex: 0, measureIndex: 2, voiceIndex: 0, chordIndex: 0)
    )

    let bounds = LivePlaybackController.loopBounds(for: range, in: score)

    guard case let .throughEndOf(start, last) = bounds else {
        Issue.record("expected .throughEndOf, got \(String(describing: bounds))")
        return
    }
    #expect(start == .beat(measureIndex: 1, tickInMeasure: 0))
    // The last element in measure 2 is a quarter-note rest at element index 0.
    if case let .rest(restID) = last {
        #expect(restID.measureIndex == 2)
        #expect(restID.voiceIndex == 0)
        #expect(restID.elementIndex == 0)
    } else {
        Issue.record("expected .rest, got \(last)")
    }
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `swift test --filter loopBoundsUsesThroughEndOfWhenEndIsLastMeasure` from `Packages/Infrastructure/`.
Expected: PASS — implementation already covers this branch.

- [ ] **Step 7: Add the failing test for `lastScoreItemID` returning `.note` on a sounding chord**

Add to `LivePlaybackControllerTests.swift`:

```swift
@Test func lastScoreItemIDReturnsNoteIDForChordWithNotes() {
    // MIDI 60 = middle C, TPC 14 = "C natural" in MuseScore's tonal pitch
    // class numbering. Concrete values don't matter — we only need a
    // `Chord` whose `notes` is non-empty so `lastScoreItemID` returns
    // `.note(...)` rather than `.rest(...)`.
    let chord = Chord(
        duration: .quarter,
        notes: [Note(pitch: 60, tpc: 14)]
    )
    let measure = Measure(voices: [
        Voice(elements: [.rest(duration: .quarter), .chord(chord)])
    ])
    let staff = Staff(measures: [measure])
    let part = Part(
        id: "P0",
        instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
        staves: [staff]
    )
    let score = Score(division: 480, parts: [part])

    let id = LivePlaybackController.lastScoreItemID(inMeasure: 0, of: score)

    if case let .note(noteID) = id {
        #expect(noteID.measureIndex == 0)
        #expect(noteID.elementIndex == 1) // second element in the voice
        #expect(noteID.noteIndexInChord == 0)
    } else {
        Issue.record("expected .note, got \(String(describing: id))")
    }
}
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `swift test --filter lastScoreItemIDReturnsNoteIDForChordWithNotes` from `Packages/Infrastructure/`.
Expected: PASS.

- [ ] **Step 9: Add the failing test for the no-elements (`nil`) case**

Add to `LivePlaybackControllerTests.swift`:

```swift
@Test func lastScoreItemIDReturnsNilForMeasureWithNoChordElements() {
    let measure = Measure(voices: [Voice(elements: [])])
    let staff = Staff(measures: [measure])
    let part = Part(
        id: "P0",
        instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
        staves: [staff]
    )
    let score = Score(division: 480, parts: [part])

    let id = LivePlaybackController.lastScoreItemID(inMeasure: 0, of: score)
    #expect(id == nil)
}
```

- [ ] **Step 10: Run the test to verify it passes**

Run: `swift test --filter lastScoreItemIDReturnsNilForMeasureWithNoChordElements` from `Packages/Infrastructure/`.
Expected: PASS.

- [ ] **Step 11: Run the full Infrastructure suite to verify nothing else broke**

Run: `swift test` from `Packages/Infrastructure/`.
Expected: all tests pass.

- [ ] **Step 12: Commit**

```bash
git add Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/Audio/LivePlaybackControllerTests.swift
git commit -m "feat(audio): add loopBounds + lastScoreItemID helpers"
```

---

## Task 2: Wire helpers into `setLoopRange` and drop wrap from controller

**Files:**
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift`

This task replaces the controller's `setLoopRange` and `setCursor` bodies, drops the `dispatchCursor` /`CursorDispatch`/ `loopRange`/ `isSeekingLoopStart`/ `seekToLoopStart`/ `cursorIsPastLoopEnd`/ `measureIndex(of:)` machinery, and simplifies the Combine sink on `engine.$currentCursor`.

The new `setLoopRange` uses `loopBounds(for:in:)` from Task 1 and forwards to `engine.setLoop(from:to:)` or `setLoop(from:throughEndOf:)`. It snapshots `engine.state == .playing` before the call (the engine pauses on `setLoop`/`clearLoop`) and resumes via `engine.play(in:)` afterwards so mid-playback marker toggles stay seamless.

- [ ] **Step 1: Replace the Combine sink to forward cursors directly**

In `LivePlaybackController.swift`, find the existing `engine.$currentCursor.sink` block:

```swift
engine.$currentCursor
    .sink { [weak self] value in
        guard let self else { return }
        // Combine emits the engine's `@Published currentCursor` on
        // willSet, synchronously on the MainActor where the timer
        // task ran. Forward to the registered handler in the same
        // work item so each cursor change reaches SwiftUI without
        // an intervening Task hop. Routing through `AsyncStream` +
        // `for-await` instead let the consumer drain a buffered
        // burst in one work item, collapsing the intermediate
        // cursor positions before SwiftUI got a render slot
        // between them — visible as the cursor "skipping" past
        // chord onsets that the example app shows.
        switch self.dispatchCursor(value) {
        case let .forward(cursor):
            self.cursorHandler?(cursor)
        case .suppress:
            break
        }
    }
    .store(in: &cancellables)
```

Replace with:

```swift
engine.$currentCursor
    .sink { [weak self] value in
        // Combine emits the engine's `@Published currentCursor` on
        // willSet, synchronously on the MainActor where the timer
        // task ran. Forward to the registered handler in the same
        // work item so each cursor change reaches SwiftUI without
        // an intervening Task hop. Routing through `AsyncStream` +
        // `for-await` instead let the consumer drain a buffered
        // burst in one work item, collapsing the intermediate
        // cursor positions before SwiftUI got a render slot
        // between them — visible as the cursor "skipping" past
        // chord onsets that the example app shows.
        self?.cursorHandler?(value)
    }
    .store(in: &cancellables)
```

- [ ] **Step 2: Replace the `setLoopRange` body**

Find:

```swift
public func setLoopRange(_ range: ABRepeatRange?) {
    loopRange = range
    guard let range, let cursor = engine.currentCursor else { return }
    if cursorIsPastLoopEnd(cursor, range: range) {
        seekToLoopStart(range)
    }
}
```

Replace with:

```swift
public func setLoopRange(_ range: ABRepeatRange?) {
    let wasPlaying = engine.state == .playing
    if let range, let score = loadedScore,
       let bounds = Self.loopBounds(for: range, in: score)
    {
        switch bounds {
        case let .beatRange(start, end):
            engine.setLoop(from: start, to: end)
        case let .throughEndOf(start, last):
            engine.setLoop(from: start, throughEndOf: last)
        }
    } else {
        engine.clearLoop()
    }
    if wasPlaying, let score = loadedScore {
        engine.play(in: score)
    }
}
```

- [ ] **Step 3: Revert `setCursor` to a plain `engine.seek`**

Find:

```swift
public func setCursor(to cursor: ScoreCursor) {
    // `PlaybackEngine.seek(to:)` does the stop/write/start cycle that
    // keeps the running sequencer and audible transport aligned.
    engine.seek(to: cursor)
}
```

(This body is already fine after the recent commit — no change needed; just leave it. The engine's `seek(...)` snaps any tick into the active loop on its own.)

- [ ] **Step 4: Delete the dead helpers and stored fields**

Find the `private enum CursorDispatch { ... }` block:

```swift
private enum CursorDispatch {
    case forward(ScoreCursor?)
    case suppress
}
```

Delete it.

Find:

```swift
private var loopRange: ABRepeatRange?
private var isSeekingLoopStart = false
```

Delete both.

Find the four private wrap-helper methods at the bottom of the type and delete each:

```swift
private func dispatchCursor(_ cursor: ScoreCursor?) -> CursorDispatch {
    /* … */
}

private func seekToLoopStart(_ range: ABRepeatRange) {
    /* … */
}

private func cursorIsPastLoopEnd(_ cursor: ScoreCursor, range: ABRepeatRange) -> Bool {
    /* … */
}

private func measureIndex(of cursor: ScoreCursor) -> Int {
    /* … */
}
```

The `LoopBounds` enum + `loopBounds(for:in:)` + `lastScoreItemID(inMeasure:of:)` from Task 1 stay.

- [ ] **Step 5: Build the package to verify it compiles**

Run: `swift build` from `Packages/Infrastructure/`.
Expected: builds cleanly; no unused-import or missing-symbol warnings related to the deletions.

- [ ] **Step 6: Run the full Infrastructure test suite**

Run: `swift test` from `Packages/Infrastructure/`.
Expected: all tests pass — the existing tests don't touch the deleted symbols, and the Task 1 tests stay green.

- [ ] **Step 7: Commit**

```bash
git add Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift
git commit -m "refactor(audio): forward A-B loop to engine native API"
```

---

## Task 3: Drop wrap from `ReaderViewModel`; delete obsolete tests

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Modify: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift`

The view model no longer needs to detect "cursor past B" — the engine's native loop handles wrap and emits already-wrapped cursors. Drop `evaluateLoopWrap`, `seekToLoopStart`, `preSeekIfNeeded`, `shouldIgnoreObservedCursor`, the `isHandlingLoopWrap` flag, the early-out in the cursor handler, and the `preSeekIfNeeded` call site in `togglePlayback`. The 8 tests that exercise this mechanism go too — they assert against `recordedSetCursorCalls` increments produced by the now-deleted host-side seeks.

- [ ] **Step 1: Simplify `startObservingCursor` to a one-liner handler**

In `ReaderViewModel.swift`, find:

```swift
public func startObservingCursor() {
    guard let controller = playbackController else { return }
    controller.observeCursor { [weak self] value in
        guard let self else { return }
        if shouldIgnoreObservedCursor(value) { return }
        playbackCursor = value
        evaluateLoopWrap(for: value)
    }
}
```

Replace with:

```swift
public func startObservingCursor() {
    guard let controller = playbackController else { return }
    controller.observeCursor { [weak self] value in
        self?.playbackCursor = value
    }
}
```

- [ ] **Step 2: Drop the wrap-state field and its doc comment**

Find:

```swift
/// True between issuing a wrap-to-A seek and observing the engine
/// emit a cursor back inside the loop. Suppresses the wrap from
/// re-firing on the engine's stale past-B cursor emissions, which
/// would otherwise queue dozens of `setCursor` calls per second.
@ObservationIgnored
private var isHandlingLoopWrap: Bool = false
```

Delete the whole block (comment + property).

- [ ] **Step 3: Drop `preSeekIfNeeded` from `togglePlayback`**

Find inside `togglePlayback`:

```swift
} else {
    do {
        await preSeekIfNeeded(controller: controller, score: score)
        try await controller.play()
        isPlaying = true
    } catch {
        isPlaying = false
    }
}
```

Replace with:

```swift
} else {
    do {
        try await controller.play()
        isPlaying = true
    } catch {
        isPlaying = false
    }
}
```

- [ ] **Step 4: Delete the four private wrap methods**

In the same file, find and delete each of these methods in the `extension ReaderViewModel { }` block at the bottom:

```swift
private func shouldIgnoreObservedCursor(_ cursor: ScoreCursor?) -> Bool {
    /* … */
}

private func evaluateLoopWrap(for cursor: ScoreCursor?) {
    /* … */
}

private func preSeekIfNeeded(controller: any PlaybackController, score: Score) async {
    /* … */
}

private func seekToLoopStart(_ range: ABRepeatRange) {
    /* … */
}
```

Keep `activeLoopRange(in:)` and `forwardLoopRangeToController()` — both still used.

- [ ] **Step 5: Build the package to verify it compiles**

Run: `swift build` from `Packages/Features/Reader/`.
Expected: builds cleanly. No warnings about unused private symbols.

- [ ] **Step 6: Delete the 8 wrap-mechanism tests**

In `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift`, delete each of these whole `@Test` blocks:

- `cursorPastEndDuringPlaybackSeeksToStartOfA`
- `stalePastEndCursorDoesNotOverwriteLoopStartWhileWrapIsPending`
- `cursorWithinLoopDoesNotTriggerSeek`
- `cursorWrapDoesNotFireWhilePaused`
- `nilCursorDuringLoopAllPlaybackWrapsToStart`
- `togglePlaybackPreSeeksToAWhenCursorAlreadyPastB`
- `rapidPastEndCursorEmissionsTriggerOnlyOneSeek`
- `wrapReArmsAfterCursorReturnsInsideLoop`

Leave the other 11 `@Test` blocks intact — they exercise persistence + range-forwarding contracts that still apply.

- [ ] **Step 7: Run the Reader test suite**

Run: `swift test` from `Packages/Features/Reader/`.
Expected: all kept tests pass; the deleted tests no longer appear.

- [ ] **Step 8: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift
git commit -m "refactor(reader): drop host-side A-B wrap; engine handles it"
```

---

## Task 4: Cross-package verification

**Files:** none modified — verification only.

- [ ] **Step 1: Run Reader package tests**

Run: `swift test` from `Packages/Features/Reader/`.
Expected: PASS.

- [ ] **Step 2: Run Infrastructure package tests**

Run: `swift test` from `Packages/Infrastructure/`.
Expected: PASS.

- [ ] **Step 3: Run Domain package tests**

Run: `swift test` from `Packages/Domain/`.
Expected: PASS — Domain wasn't touched, but the protocol shape interaction with Infrastructure changed; running the suite confirms no implicit ABI regression.

- [ ] **Step 4: Build the full app**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build` from the worktree root.
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: No commit unless test fixes were needed**

This task is verification-only. If anything failed, drop into a fix-up commit on the offending package.

---

## Task 5: Manual simulator verification

**Files:** none — manual testing.

This task confirms the user-visible behavior that automated tests can't easily cover (sample-accurate audio looping, seamless mid-playback marker toggles).

- [ ] **Step 1: Build and run the app on the simulator**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build` then `xcrun simctl install` + `xcrun simctl launch` per CLAUDE.md's "When the simulator is needed" workflow. Hand control to the user for the actual gesture-driven verification — programmatic taps via `simctl` aren't reliable for the gestures involved.

- [ ] **Step 2: User checks the four scenarios**

Tell the user to verify each:

1. **Mid-score loop**: open a score with 6+ measures, set A on m=2 / B on m=4, press play. Audio should loop m=2..m=4 cleanly, with no audible click at the wrap, and the cursor should stay inside [m=2, m=4].
2. **Last-measure loop**: set A on m=N-2 / B on m=N-1 (the very last measure). Audio should loop the last two measures, including the full ringing of the final note before wrapping.
3. **Mid-play marker toggle**: while playing within a wider region, tap A on a closer measure. Audio should keep playing without an audible pause; the loop should re-base immediately.
4. **`.loopAll` mode**: cycle to `.loopAll`, play to the end. The score should wrap to m=0 cleanly.

- [ ] **Step 3: If any scenario regresses**

Diagnose the regression — most likely candidates are (a) the last-measure `throughEndOf` mapping landing on the wrong tick because `voice 0` of `staff 0` has a non-chord last element, or (b) `engine.play(in:)` being called when `loadedScore` is nil. Both are addressable by tightening the helper's branch coverage. No second-guessing the engine's native loop — it's been validated in the example app.

---

## Self-Review

**1. Spec coverage:**
- §1 (controller adapter) → Task 2.
- §2 (`setCursor` revert) → Task 2 Step 3.
- §3 (drop wrap from VM) → Task 3.
- §4 (test cleanup) → Task 3 Step 6.
- §5 (Domain protocol unchanged) → no task; verified by build.
- §6 (auto-resume) → Task 2 Step 2 (the `if wasPlaying { engine.play(in:) }` path).
- §6.5 helper location → Task 1 Step 3 places them inside `LivePlaybackController.swift`.

All sections covered.

**2. Placeholder scan:** none — every step has either exact file edits or runnable commands. No "TBD"/"TODO"/"appropriate"/"similar to"-style language.

**3. Type / signature consistency:**
- `LoopBounds` cases (`.beatRange`, `.throughEndOf`) are referenced consistently by name across Task 1 (definition + tests) and Task 2 (switch).
- `loopBounds(for:in:)` is called as `Self.loopBounds(...)` from inside the type and `LivePlaybackController.loopBounds(...)` from tests — both valid for an internal static method.
- `lastScoreItemID(inMeasure:of:)` matches between Task 1 implementation and the Task 1 unit test invocation.
- The deleted method names match what's actually in the current source (verified against the diff in the spec doc).

No inconsistencies.

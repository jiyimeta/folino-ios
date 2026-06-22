# Reader vertical-mode lookahead auto-scroll — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the Reader's vertical mode, fire the playback auto-scroll ~2 beats *ahead* of the playing cursor so the next region is revealed before the playhead reaches it, while the on-staff highlighted cursor stays at the real position.

**Architecture:** Add one pure notation helper to `swift-sheet-music` (`SheetMusicCore`): `Score.cursor(advancedByBeats:from:)`, sitting next to the existing seek map (`cursor(atSeconds:)`). `ReaderPlaybackSession` exposes a computed `scrollAnchorCursor` (the live cursor advanced 2 beats, non-nil only while playing). `VerticalScoreContainer` keeps highlighting `playbackCursor` but drives auto-scroll off `scrollAnchorCursor ?? playbackCursor`. No `PlaybackController` / `PlaybackEngine` / Domain-protocol change.

**Tech Stack:** Swift 6.3, iOS 26+, SwiftUI + UIKit (`UIScrollView`) Reader, Swift Testing, SwiftPM packages, `swift-sheet-music` consumed via a pinned git `revision:`.

**Spec:** `docs/superpowers/specs/2026-06-22-reader-vertical-lookahead-autoscroll-design.md`

## Global Constraints

- **Swift 6.3, iOS 26+.** Universal app, bundle id `com.KeyNumber.Folino`.
- **Lead unit = quarter-note beats; default = 2 beats.** A beat is `division` ticks. Single source-of-truth constant `ReaderPlaybackSession.scrollLookaheadBeats`.
- **Highlight cursor must never move.** Only the scroll anchor looks ahead.
- **Vertical mode only.** Horizontal / Page / PiP untouched.
- **No `PlaybackController` (Domain protocol) / `PlaybackEngine` / `PlaybackTimeline` change.**
- **Access modifiers:** keep types/members `internal` unless they cross a module boundary. The new ssm `Score` method is `public` (crosses into Folino); the Folino `scrollAnchorCursor` / constant are `internal` (`var` / `static let`, no modifier).
- **Comment reflow at 120 cols.** American spelling except Apple-API terms (`cancelled`).
- **Package tests run via `xcodebuild test` on an iPhone 17 Pro Max simulator** (not `swift test` — the SwiftLint plugin breaks the SwiftPM CLI). `-skipPackagePluginValidation` on the CLI.
- **ssm pin is a git `revision:`** repeated in 5 files: `project.yml` + `Packages/{Domain,Infrastructure,Features/Library,Features/Reader}/Package.swift`. Current value: `b6e2b8c254dcbd459b2fe4e54b900a410a9eea20`.
- **Two repos.** ssm logic lives at `~/Developer/Personal/swift-packages/swift-sheet-music`; Folino at `~/Developer/Personal/ios-apps/Folino-iOS`. Work in worktrees (see Setup).

---

## Setup — worktrees (do once, at execution start)

Use the `superpowers:using-git-worktrees` skill / project worktree conventions to create:

- **ssm worktree** off the ssm clone's `origin/main` — e.g. `~/Developer/Personal/swift-packages/.worktrees/lookahead-beats`. All Task 1 edits happen here.
- **Folino worktree** off Folino's **local `main`** — e.g. under the Folino worktrees dir. All Folino edits (Tasks 2-6) happen here. Symlink `Config/Local.xcconfig` from the primary checkout (gitignored; carries the Team ID) before any `xcodegen generate` / build.

Subagents executing tasks must use the **absolute worktree path** and `git -C <worktree>` for every git command — never the primary checkout.

> **Two-repo TDD note:** The ssm function's authoritative tests live in Folino's `ReaderTests` (the established pattern — see `ScoreSeekTimeTests.swift`), which can only compile once Folino is re-pinned to a pushed ssm revision. So Task 1 implements + compile-checks the ssm function; Task 3 runs its tests immediately after re-pin (before any wiring) so a bug is caught in isolation. The Folino-only logic (Task 4) is full red-green TDD.

---

## Task 1: ssm — `Score.cursor(advancedByBeats:from:)`

**Files:**
- Create: `~/.../swift-sheet-music/Sources/SheetMusicCore/Score/Score+NotatedLookahead.swift` (in the **ssm worktree**)

**Interfaces:**
- Consumes: existing `Score` internals `effectiveMeasureDurations()`, `division`, `tickInMeasure(of:)`, `ScoreCursor.measureIndex`, `Fraction.ticks(division:)` (all in `SheetMusicCore`, same module).
- Produces: `public func cursor(advancedByBeats beats: Double, from cursor: ScoreCursor) -> ScoreCursor` on `Score`. Returns a `.beat(measureIndex:tickInMeasure:)` cursor (staff-agnostic). Consumed by `ReaderPlaybackSession` (Task 4) and tested by `ScoreLookaheadTests` (Task 3).

- [ ] **Step 1: Write the function**

Create `Score+NotatedLookahead.swift` in the ssm worktree:

```swift
extension Score {
    /// The `.beat` cursor `beats` quarter-note beats after `cursor`, walking measures and clamping to the
    /// score's final notated tick. A beat is `division` ticks. Returns `cursor` unchanged when `beats <= 0` or
    /// the score has no measures. Pure notation math — no tempo, no audio-engine state — so it is deterministic
    /// and is the same lookahead Android can call through a JNI bridge.
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

- [ ] **Step 2: Compile-check the target**

Run (from the ssm worktree root):

```
swift build --target SheetMusicCore
```

Expected: builds with no errors. (Individual ssm targets build via `swift build`; the full test suite does not — it pulls Android JNI deps. That's why the tests live in Folino — Task 3.)

- [ ] **Step 3: Hand-trace the algorithm against the Task 3 cases**

Confirm by hand (division 480, 4/4 = 1920 ticks): `from .beat(0,0) +2 → .beat(0,960)`; `from .beat(0,1440) +2 → .beat(1,480)`; `from .beat(0,0) +6 (2 measures) → .beat(1,960)`; `from .beat(1,1440) +4 (last measure) → .beat(1,1920)`; `+0 → input`. If any disagrees, fix the function before committing.

- [ ] **Step 4: Commit (ssm worktree, no push yet)**

```bash
git -C <ssm-worktree> add Sources/SheetMusicCore/Score/Score+NotatedLookahead.swift
git -C <ssm-worktree> commit -m "feat(core): add Score.cursor(advancedByBeats:from:) notation lookahead"
```

---

## Task 2: Push ssm and re-pin Folino

**Files:**
- Modify (Folino worktree): `project.yml`, `Packages/Domain/Package.swift`, `Packages/Infrastructure/Package.swift`, `Packages/Features/Library/Package.swift`, `Packages/Features/Reader/Package.swift`

**Interfaces:**
- Consumes: the ssm commit from Task 1.
- Produces: a Folino checkout pinned to a pushed ssm revision that contains `cursor(advancedByBeats:from:)`.

- [ ] **Step 1: STOP — get user approval to push ssm**

Pushing is an external side effect on the user's `swift-sheet-music` repo. Ask: *"Task 1 の `Score.cursor(advancedByBeats:from:)` を ssm に push して良いですか？（pure notation 関数・engine/render 変更なし）"* Do not push until the user confirms.

- [ ] **Step 2: Push ssm and capture the new revision**

```bash
git -C <ssm-worktree> push origin HEAD
git -C <ssm-worktree> rev-parse HEAD
```

Record the full 40-char SHA from `rev-parse` as `<NEW_SSM_SHA>`.

- [ ] **Step 3: Re-pin all 5 files**

Replace `b6e2b8c254dcbd459b2fe4e54b900a410a9eea20` with `<NEW_SSM_SHA>` in each (in the **Folino worktree**):
- `project.yml` (the `swift-sheet-music:` `revision:` line)
- `Packages/Domain/Package.swift`
- `Packages/Infrastructure/Package.swift`
- `Packages/Features/Library/Package.swift`
- `Packages/Features/Reader/Package.swift`

Verify none remain:

```
rg -l "b6e2b8c254dcbd459b2fe4e54b900a410a9eea20" <folino-worktree>
```

Expected: no output.

- [ ] **Step 4: Regenerate the project and resolve packages**

```
xcodegen generate
```

Run from the Folino worktree root. Then resolve the Reader package's dependencies (from `Packages/Features/Reader`):

```
xcodebuild -resolvePackageDependencies -scheme Reader-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

Expected: resolves `swift-sheet-music` at `<NEW_SSM_SHA>` with no error.

- [ ] **Step 5: Commit the re-pin**

```bash
git -C <folino-worktree> add project.yml Packages/Domain/Package.swift Packages/Infrastructure/Package.swift Packages/Features/Library/Package.swift Packages/Features/Reader/Package.swift
git -C <folino-worktree> commit -m "build(deps): re-pin swift-sheet-music for notation lookahead"
```

---

## Task 3: Folino — validate the ssm lookahead via ReaderTests

**Files:**
- Create: `Packages/Features/Reader/Tests/ReaderTests/ScoreLookaheadTests.swift`

**Interfaces:**
- Consumes: `Score.cursor(advancedByBeats:from:)` (now pinned), and `Score` construction (`Score(division:parts:systemMeasures:metaTags:)`, `Part`, `Staff`, `Measure`, `Instrument`, `InstrumentChannel`, `Fraction`) as used in `ScoreSeekTimeTests.swift`.
- Produces: regression coverage for the lookahead function. No production code.

- [ ] **Step 1: Write the tests**

Create `ScoreLookaheadTests.swift` (mirrors `ScoreSeekTimeTests.swift`'s Score builder; tempo is irrelevant to a tick-based advance, so it's omitted):

```swift
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

struct ScoreLookaheadTests {
    /// `count` default (4/4, 1920-tick) measures at division 480.
    private static func score(measures count: Int) -> Score {
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: (0 ..< count).map { _ in Measure(voices: []) })],
        )
        let systemMeasures = (0 ..< count).map { _ in SystemMeasure() }
        return Score(division: 480, parts: [part], systemMeasures: systemMeasures, metaTags: [:])
    }

    @Test func `advances within a measure — two beats is 960 ticks`() {
        let s = Self.score(measures: 1)
        #expect(s.cursor(advancedByBeats: 2, from: .beat(measureIndex: 0, tickInMeasure: 0))
            == .beat(measureIndex: 0, tickInMeasure: 960))
    }

    @Test func `crosses one measure boundary`() {
        let s = Self.score(measures: 2)
        #expect(s.cursor(advancedByBeats: 2, from: .beat(measureIndex: 0, tickInMeasure: 1440))
            == .beat(measureIndex: 1, tickInMeasure: 480))
    }

    @Test func `advances across a full measure`() {
        let s = Self.score(measures: 2)
        #expect(s.cursor(advancedByBeats: 6, from: .beat(measureIndex: 0, tickInMeasure: 0))
            == .beat(measureIndex: 1, tickInMeasure: 960))
    }

    @Test func `clamps to the final tick at end of score`() {
        let s = Self.score(measures: 2)
        #expect(s.cursor(advancedByBeats: 4, from: .beat(measureIndex: 1, tickInMeasure: 1440))
            == .beat(measureIndex: 1, tickInMeasure: 1920))
    }

    @Test func `non-positive beats returns the input cursor`() {
        let s = Self.score(measures: 2)
        #expect(s.cursor(advancedByBeats: 0, from: .beat(measureIndex: 0, tickInMeasure: 480))
            == .beat(measureIndex: 0, tickInMeasure: 480))
        #expect(s.cursor(advancedByBeats: -3, from: .beat(measureIndex: 0, tickInMeasure: 480))
            == .beat(measureIndex: 0, tickInMeasure: 480))
    }

    @Test func `empty score returns the input cursor`() {
        let s = Score(division: 480, parts: [], systemMeasures: [], metaTags: [:])
        #expect(s.cursor(advancedByBeats: 2, from: .beat(measureIndex: 0, tickInMeasure: 0))
            == .beat(measureIndex: 0, tickInMeasure: 0))
    }

    @Test func `accounts for a short pickup measure`() {
        // Measure 0 is a 1/4 pickup (480 ticks); measure 1 is full 4/4 (1920 ticks).
        let pickup = Fraction(numerator: 1, denominator: 4)
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: [Measure(voices: [], actualLength: pickup), Measure(voices: [])])],
        )
        let s = Score(division: 480, parts: [part],
                      systemMeasures: [SystemMeasure(), SystemMeasure()], metaTags: [:])
        // 2 beats = 960 ticks: 480 consumes the pickup, 480 spills into measure 1.
        #expect(s.cursor(advancedByBeats: 2, from: .beat(measureIndex: 0, tickInMeasure: 0))
            == .beat(measureIndex: 1, tickInMeasure: 480))
    }
}
```

- [ ] **Step 2: Run the tests**

From `Packages/Features/Reader`:

```
xcodebuild test -scheme Reader-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/ScoreLookaheadTests
```

Expected: PASS (7 tests). If any fail, the bug is in the Task 1 function — fix it in the ssm worktree, re-push, re-pin (Task 2), and re-run before continuing.

- [ ] **Step 3: Commit**

```bash
git -C <folino-worktree> add Packages/Features/Reader/Tests/ReaderTests/ScoreLookaheadTests.swift
git -C <folino-worktree> commit -m "test(reader): cover Score.cursor(advancedByBeats:from:)"
```

---

## Task 4: Folino — `ReaderPlaybackSession.scrollAnchorCursor`

**Files:**
- Create: `Packages/Features/Reader/Tests/ReaderTests/ReaderPlaybackSessionScrollAnchorTests.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift`

**Interfaces:**
- Consumes: `Score.cursor(advancedByBeats:from:)`; `FakePlaybackController` (`emitIsPlaying`, `emitCursor`); `ReaderPlaybackSession(controller:museScoreGeneralProvider:)`, `scoreProvider`, `startObservingCursor()`, `beginScrub()`.
- Produces: `var scrollAnchorCursor: ScoreCursor?` and `static let scrollLookaheadBeats: Double` on `ReaderPlaybackSession`.

- [ ] **Step 1: Write the failing tests**

Create `ReaderPlaybackSessionScrollAnchorTests.swift`:

```swift
import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
struct ReaderPlaybackSessionScrollAnchorTests {
    private static func twoMeasureScore() -> Score {
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: [Measure(voices: []), Measure(voices: [])])],
        )
        return Score(division: 480, parts: [part],
                     systemMeasures: [SystemMeasure(), SystemMeasure()], metaTags: [:])
    }

    private static func playingSession(
        _ controller: FakePlaybackController, at cursor: ScoreCursor,
    ) -> ReaderPlaybackSession {
        let score = twoMeasureScore()
        let session = ReaderPlaybackSession(controller: controller, museScoreGeneralProvider: nil)
        session.scoreProvider = { score }
        session.startObservingCursor()
        controller.emitIsPlaying(true)
        controller.emitCursor(cursor)
        return session
    }

    @Test func `anchor leads the live cursor by two beats while playing`() {
        let controller = FakePlaybackController()
        let session = Self.playingSession(controller, at: .beat(measureIndex: 0, tickInMeasure: 0))
        // 2 beats = 960 ticks into a 1920-tick 4/4 measure.
        #expect(session.scrollAnchorCursor == .beat(measureIndex: 0, tickInMeasure: 960))
    }

    @Test func `anchor is nil when not playing`() {
        let controller = FakePlaybackController()
        let session = Self.playingSession(controller, at: .beat(measureIndex: 0, tickInMeasure: 0))
        controller.emitIsPlaying(false)
        #expect(session.scrollAnchorCursor == nil)
    }

    @Test func `anchor is nil while scrubbing`() {
        let controller = FakePlaybackController()
        let session = Self.playingSession(controller, at: .beat(measureIndex: 0, tickInMeasure: 0))
        session.beginScrub()
        #expect(session.scrollAnchorCursor == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

From `Packages/Features/Reader`:

```
xcodebuild test -scheme Reader-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/ReaderPlaybackSessionScrollAnchorTests
```

Expected: FAIL to compile — `value of type 'ReaderPlaybackSession' has no member 'scrollAnchorCursor'`.

- [ ] **Step 3: Implement `scrollAnchorCursor`**

In `ReaderPlaybackSession.swift`, add right after the `displayCursor` computed property (the block ending at line 24):

```swift
    /// Lookahead anchor for vertical-mode auto-scroll: the `.beat` cursor `scrollLookaheadBeats` beats after
    /// the live position, so the score scrolls before the playing cursor reaches the viewport edge. Non-nil
    /// ONLY during continuous playback (not paused / stopped / scrubbing); callers fall back to `displayCursor`
    /// when nil, preserving the reactive scroll behavior. Never drives the on-staff highlight.
    ///
    /// Computed from `rawPlaybackCursor` (the engine's full-score address) so an `.item` cursor resolves its
    /// tick against the right staff — exactly as `playbackFraction` does. The `.beat` result is staff-agnostic,
    /// so no hidden-staves translation is needed.
    var scrollAnchorCursor: ScoreCursor? {
        guard isPlaying, scrubCursor == nil,
              let raw = rawPlaybackCursor, let score = scoreProvider()
        else { return nil }
        return score.cursor(advancedByBeats: Self.scrollLookaheadBeats, from: raw)
    }

    /// Lead distance for `scrollAnchorCursor`, in quarter-note beats. Code-tunable single source of truth.
    static let scrollLookaheadBeats: Double = 2
```

- [ ] **Step 4: Run to verify pass**

Same command as Step 2. Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git -C <folino-worktree> add Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift Packages/Features/Reader/Tests/ReaderTests/ReaderPlaybackSessionScrollAnchorTests.swift
git -C <folino-worktree> commit -m "feat(reader): add lookahead scrollAnchorCursor to playback session"
```

---

## Task 5: Folino — drive vertical auto-scroll off the anchor

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalScoreContainer.swift` (add param ~line 33; change `onChange` at lines 189-191)
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift` (the `VerticalScoreContainer(` call, after line 194)
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalScoreContainerPreviews.swift` (the `VerticalScoreContainer(` construction)

**Interfaces:**
- Consumes: `ReaderPlaybackSession.scrollAnchorCursor`.
- Produces: `VerticalScoreContainer` gains a `let scrollAnchorCursor: ScoreCursor?` parameter; highlight still uses `playbackCursor`, auto-scroll uses `scrollAnchorCursor ?? playbackCursor`.

This task is UI wiring; it is verified by a clean build (no new unit test — the behavior is covered by Task 4's session logic and Task 6's manual check). `HorizontalScoreContainer` / `PagedScoreContainer` are NOT changed.

- [ ] **Step 1: Add the parameter to `VerticalScoreContainer`**

In `VerticalScoreContainer.swift`, immediately after `let playbackCursor: ScoreCursor?` (line 33):

```swift
    let playbackCursor: ScoreCursor?
    /// Lookahead anchor used for auto-scroll ONLY — a cursor a couple of beats ahead of `playbackCursor` during
    /// playback, so the viewport scrolls before the playing cursor reaches the edge. `nil` when not playing /
    /// scrubbing, in which case auto-scroll falls back to `playbackCursor`. Never passed to the highlight.
    let scrollAnchorCursor: ScoreCursor?
```

- [ ] **Step 2: Drive `autoScroll` off the anchor**

Replace the `onChange` block at lines 189-191:

```swift
        .onChange(of: playbackCursor) { _, newCursor in
            autoScroll(cursor: newCursor, viewport: viewport)
        }
```

with:

```swift
        .onChange(of: scrollAnchorCursor ?? playbackCursor) { _, newTarget in
            autoScroll(cursor: newTarget, viewport: viewport)
        }
```

(The highlight path — `playbackCursor` passed to `VerticalZoomedSurface` at line 181 — is left unchanged.)

- [ ] **Step 3: Pass the anchor from `ReaderRootScreen`**

In `ReaderRootScreen.swift`, inside the `VerticalScoreContainer(` call (line 188), immediately after `playbackCursor: viewModel.playbackSession.displayCursor,` (line 194), add:

```swift
                        scrollAnchorCursor: viewModel.playbackSession.scrollAnchorCursor,
```

Leave the `HorizontalScoreContainer` (line 200) and `PagedScoreContainer` (line 211) calls unchanged.

- [ ] **Step 4: Fix the preview construction**

In `VerticalScoreContainerPreviews.swift`, the `VerticalScoreContainer(` construction now needs the new parameter. Next to its `playbackCursor:` argument, add:

```swift
                scrollAnchorCursor: nil,
```

- [ ] **Step 5: Build the Reader package**

From `Packages/Features/Reader`:

```
xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Expected: BUILD SUCCEEDED, with `VerticalScoreContainer.swift` showing as `Compiling` (confirming the edited file recompiled). Fix any missing-argument errors at other `VerticalScoreContainer(` sites surfaced by the compiler.

- [ ] **Step 6: Commit**

```bash
git -C <folino-worktree> add Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalScoreContainer.swift Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalScoreContainerPreviews.swift
git -C <folino-worktree> commit -m "feat(reader): scroll vertical viewport to the lookahead anchor"
```

---

## Task 6: Integration build + manual verification handoff

**Files:** none (verification only).

- [ ] **Step 1: Build the app**

From the Folino worktree root:

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 2: Run the full Reader test target (regression)**

From `Packages/Features/Reader`:

```
xcodebuild test -scheme Reader-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Expected: PASS, including `ScoreLookaheadTests` and `ReaderPlaybackSessionScrollAnchorTests`, with no regression in the existing scrub / cursor suites.

- [ ] **Step 3: Hand off manual verification to the user**

Per project policy, do not drive the simulator for gesture/playback checks. Tell the user to clean-build on device/simulator and confirm, in **vertical** mode:
- During playback the score scrolls ~2 beats **before** the playing cursor reaches the bottom edge (lead time visible).
- The highlighted/pulsing cursor stays on the actually-playing note — it never jumps ahead.
- Pausing freezes scrolling at the current position; resuming re-leads.
- Seek-bar scrub follows the thumb with no lookahead.
- **Horizontal / Page / PiP** behave exactly as before.

If the lead feels off, change `ReaderPlaybackSession.scrollLookaheadBeats` (the single constant) and rebuild.

---

## Self-Review

- **Spec coverage:** ssm `cursor(advancedByBeats:from:)` (Task 1) ✓; tests for it (Task 3) ✓; `scrollAnchorCursor` non-nil only while playing, raw-cursor-based, `.beat` result (Task 4) ✓; highlight/scroll separation + anchor-only geometry reuse (Task 5) ✓; vertical-only scope (Task 5 leaves H/Page/PiP) ✓; no `PlaybackController`/`PlaybackEngine` change (none in any task) ✓; lead constant tunable (Task 4 `scrollLookaheadBeats`) ✓; parity via shared `SheetMusicCore` function (Task 1) ✓; Android JNI bridge explicitly out of scope (not in any task) ✓.
- **Placeholder scan:** none — every code/test block is complete and every command has expected output.
- **Type consistency:** `cursor(advancedByBeats:from:)` signature identical across Tasks 1, 3, 4; `scrollAnchorCursor` / `scrollLookaheadBeats` identical across Tasks 4, 5; `VerticalScoreContainer.scrollAnchorCursor` param matches the `ReaderRootScreen` / preview call sites.
- **Note:** `.item`-input coverage for `cursor(advancedByBeats:from:)` is exercised indirectly (the session feeds `rawPlaybackCursor`, which may be `.item`, through `tickInMeasure(of:)` — already proven by the seek map's `.item` usage). The unit tests in Task 3 use `.beat` inputs to avoid constructing notes/`ScoreItemID`s.

# Reader time-based seek bar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a full-width, time-based seek bar to the Reader's bottom playback control, with a Settings toggle to hide it; dragging shows a provisional cursor the score follows, and audio jumps on release.

**Architecture:** A Reader-local `Score` time↔cursor map (tempo-weighted, notated timeline) drives a plain SwiftUI `Slider`. `ReaderPlaybackSession` gains scrub state (`scrubCursor` / `displayCursor`); the score containers render `displayCursor`. On release the scrub commits via the existing `PlaybackController.setCursor(to:)` — **no Domain protocol change**. The bottom overlay becomes a full-width glass card when enabled; horizontal/page viewports reserve space above the control in both states.

**Tech Stack:** Swift 6.3, SwiftUI (iOS 26+), Swift Testing, swift-sheet-music (`SheetMusicCore`), `@AppStorage` settings.

**Reference spec:** `docs/superpowers/specs/2026-06-01-reader-seek-bar-design.md`

**Worktree:** `.claude/worktrees/reader-seek-bar` on branch `reader-seek-bar` (carries the pre-existing tempo-readout WIP, which this builds on — `Score+EffectiveTempo.swift` provides `effectiveQuarterBpm(at:)`).

---

## Verified API surface (do not re-derive)

From `SheetMusicCore` (swift-sheet-music):
- `Score.division: Int` (PPQ, ticks per quarter note).
- `Score.effectiveMeasureDurations() -> [Fraction]` — per-measure length in whole notes, indexed by measure.
- `Fraction.ticks(division: Int) -> Int` — `numerator * 4 * division / denominator`.
- `ScoreCursor` is `enum { case item(ScoreItemID); case beat(measureIndex: Int, tickInMeasure: Int) }`, `Hashable`. `cursor.measureIndex: Int` exists for both cases.
- Model inits for fixtures: `Score(division:parts:systemMeasures:metaTags:)`, `Part(id:trackName:instrument:staves:)`, `Staff(measures:)`, `Measure(voices:)`, `Instrument(id:channels:)`, `InstrumentChannel(program:)`, `SystemMeasure(elements:)`, `PositionedSystemElement(position:element:originalStaff:)`, `MeasurePosition.start`, `SystemElement.tempo(Tempo)`, `Tempo(beatsPerSecond:)` (2.0 bps = 120 quarter-BPM).

Reader-local (already in the package):
- `Score.effectiveQuarterBpm(at: ScoreCursor?) -> Double` — quarter-note BPM governing the position; falls back to 120 when no marking governs (`Score+EffectiveTempo.swift`).
- `Score.tickInMeasure(of: ScoreCursor) -> Int`, `Score.beatTicks(atMeasure:) -> Int?` (`Score+ResolveTickInMeasure.swift`).

`PlaybackController` (Domain) — used as-is, unchanged: `func setCursor(to: ScoreCursor) async`.

Test fakes (`Packages/Features/Reader/Tests/ReaderTests/Fakes/`):
- `FakePlaybackController` — records `recordedSetCursorCalls: [ScoreCursor]`, drives streams via `emitCursor(_:)`.
- `FakeScoreLibraryRepository`, `FakeScoreFileGateway`.

`ReaderPlaybackSession` internals (relevant): `private(set) var playbackCursor: ScoreCursor?`, `private var rawPlaybackCursor`, `let controller: (any PlaybackController)?`, `var scoreProvider: () -> Score?`, `var onCursorChanged: () -> Void`, `private func seek(toMeasureStart:)` (the pattern endScrub mirrors).

---

## File structure

| File | Responsibility | Action |
| --- | --- | --- |
| `Packages/Features/Reader/Sources/Reader/Score+SeekTime.swift` | Tempo-weighted time↔cursor map over the notated timeline | Create |
| `Packages/Features/Reader/Tests/ReaderTests/ScoreSeekTimeTests.swift` | Unit tests for the time map | Create |
| `Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift` | Add `scrubCursor` / `displayCursor` + begin/update/end scrub | Modify |
| `Packages/Features/Reader/Tests/ReaderTests/ReaderPlaybackSessionScrubTests.swift` | Unit tests for scrub state | Create |
| `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift` | Add `showSeekBarEnabled` settings key | Modify |
| `Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift` | Seek-bar toggle in the reader section | Modify |
| `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings` | `settings.reader.showSeekBar` | Modify |
| `Packages/Features/Reader/Sources/Reader/Screens/ReaderToolbar.swift` | `ReaderBottomOverlay`: collapsed vs expanded card + seek bar + height constants | Modify |
| `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings` | `reader.toolbar.seekBar` accessibility label | Modify |
| `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift` | Pass `showSeekBar` + `displayCursor`; bottom safe-area inset for horizontal/page | Modify |

Build/test command for the Reader package (per project memory — `swift test` is broken by the SwiftLint plugin's macOS requirement):

```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation
```

Run from `.claude/worktrees/reader-seek-bar/Packages/Features/Reader`. To filter one suite append `-only-testing:ReaderTests/<SuiteName>`.

---

## Task 1: Tempo-weighted time↔cursor map

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Score+SeekTime.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ScoreSeekTimeTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `ScoreSeekTimeTests.swift`:

```swift
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@Suite struct ScoreSeekTimeTests {
    /// `count` 4/4 measures, division 480. Optional per-measure quarter-BPM via tempo markings
    /// in `systemMeasures` (beatsPerSecond = bpm/60).
    private static func score(measures count: Int, tempos: [Int: Double] = [:]) -> Score {
        let staffMeasures = (0 ..< count).map { _ in Measure(voices: []) }
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: staffMeasures)],
        )
        let systemMeasures = (0 ..< count).map { i -> SystemMeasure in
            guard let bpm = tempos[i] else { return SystemMeasure() }
            return SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: bpm / 60))),
            ])
        }
        return Score(division: 480, parts: [part], systemMeasures: systemMeasures, metaTags: [:])
    }

    @Test func `constant 120 BPM — two 4_4 measures total four seconds`() {
        let s = Self.score(measures: 2, tempos: [0: 120])
        #expect(abs(s.notatedDurationSeconds - 4.0) < 0.0001)
    }

    @Test func `no tempo marking falls back to 120 BPM`() {
        let s = Self.score(measures: 2)
        #expect(abs(s.notatedDurationSeconds - 4.0) < 0.0001)
    }

    @Test func `seconds at measure start is cumulative`() {
        let s = Self.score(measures: 2, tempos: [0: 120])
        #expect(abs(s.seconds(at: .beat(measureIndex: 1, tickInMeasure: 0)) - 2.0) < 0.0001)
    }

    @Test func `seconds interpolates within a measure`() {
        let s = Self.score(measures: 2, tempos: [0: 120])
        // 4/4 at division 480 → 1920 ticks/measure; 480 ticks = 1 quarter = 0.25 of the bar = 0.5s.
        #expect(abs(s.seconds(at: .beat(measureIndex: 0, tickInMeasure: 480)) - 0.5) < 0.0001)
    }

    @Test func `tempo change lengthens the slower measure`() {
        // Measure 0 @120 (2s), measure 1 @60 (4s) → total 6s; measure 1 starts at 2s.
        let s = Self.score(measures: 2, tempos: [0: 120, 1: 60])
        #expect(abs(s.notatedDurationSeconds - 6.0) < 0.0001)
        #expect(abs(s.seconds(at: .beat(measureIndex: 1, tickInMeasure: 0)) - 2.0) < 0.0001)
        #expect(abs(s.seconds(at: .beat(measureIndex: 1, tickInMeasure: 960)) - 4.0) < 0.0001)
    }

    @Test func `cursor at seconds maps to measure and tick`() {
        let s = Self.score(measures: 2, tempos: [0: 120])
        #expect(s.cursor(atSeconds: 2.0) == .beat(measureIndex: 1, tickInMeasure: 0))
        #expect(s.cursor(atSeconds: 3.0) == .beat(measureIndex: 1, tickInMeasure: 960))
    }

    @Test func `cursor at seconds clamps to range`() {
        let s = Self.score(measures: 2, tempos: [0: 120])
        #expect(s.cursor(atSeconds: -5) == .beat(measureIndex: 0, tickInMeasure: 0))
        #expect(s.cursor(atSeconds: 99) == .beat(measureIndex: 1, tickInMeasure: 1920))
    }

    @Test func `round trips through seconds and back`() {
        let s = Self.score(measures: 3, tempos: [0: 90, 2: 140])
        let cursor = ScoreCursor.beat(measureIndex: 1, tickInMeasure: 720)
        let back = s.cursor(atSeconds: s.seconds(at: cursor))
        #expect(back == cursor)
    }

    @Test func `empty score is safe`() {
        let s = Score(division: 480, parts: [], systemMeasures: [], metaTags: [:])
        #expect(s.notatedDurationSeconds == 0)
        #expect(s.cursor(atSeconds: 1) == .beat(measureIndex: 0, tickInMeasure: 0))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:ReaderTests/ScoreSeekTimeTests`
Expected: FAIL — `notatedDurationSeconds` / `seconds(at:)` / `cursor(atSeconds:)` are unresolved.

- [ ] **Step 3: Write the implementation**

Create `Score+SeekTime.swift`:

```swift
import SheetMusicCore

/// Tempo-weighted time map over the score's NOTATED timeline (each measure counted once — no repeat
/// expansion). "Time-based" means the seek bar's fraction is proportional to elapsed duration, so a
/// slow section occupies proportionally more of the bar than a fast one with the same measure count.
///
/// Tempo is integrated at measure granularity: each measure uses the quarter-BPM governing its
/// downbeat (`effectiveQuarterBpm(at:)`, which falls back to 120 when nothing governs). The global
/// playback tempo multiplier scales all measures uniformly, so the normalized fractions these
/// functions feed the slider are invariant to it — it is intentionally ignored here.
extension Score {
    /// Per-measure tick length, indexed by measure number.
    private func measureTickLengths() -> [Int] {
        effectiveMeasureDurations().map { $0.ticks(division: division) }
    }

    /// Seconds a measure of `ticks` length occupies at the quarter-BPM governing its downbeat.
    /// secondsPerTick = (60 / quarterBPM) / division.
    private func measureSeconds(measureIndex: Int, ticks: Int) -> Double {
        let bpm = max(1, effectiveQuarterBpm(at: .beat(measureIndex: measureIndex, tickInMeasure: 0)))
        let secondsPerTick = (60.0 / bpm) / Double(max(1, division))
        return Double(ticks) * secondsPerTick
    }

    /// Total notated duration in seconds.
    var notatedDurationSeconds: Double {
        measureTickLengths().enumerated().reduce(0.0) { acc, pair in
            acc + measureSeconds(measureIndex: pair.offset, ticks: pair.element)
        }
    }

    /// Cumulative seconds from the score's start to `cursor`.
    func seconds(at cursor: ScoreCursor) -> Double {
        let lengths = measureTickLengths()
        guard !lengths.isEmpty else { return 0 }
        let measure = min(max(cursor.measureIndex, 0), lengths.count - 1)
        var seconds = 0.0
        for i in 0 ..< measure {
            seconds += measureSeconds(measureIndex: i, ticks: lengths[i])
        }
        let measureTicks = lengths[measure]
        guard measureTicks > 0 else { return seconds }
        let tick = min(max(tickInMeasure(of: cursor), 0), measureTicks)
        seconds += Double(tick) / Double(measureTicks) * measureSeconds(measureIndex: measure, ticks: measureTicks)
        return seconds
    }

    /// Inverse of `seconds(at:)`: the `.beat` cursor at `seconds` from the start, clamped to
    /// `0 ... notatedDurationSeconds`.
    func cursor(atSeconds seconds: Double) -> ScoreCursor {
        let lengths = measureTickLengths()
        guard !lengths.isEmpty else { return .beat(measureIndex: 0, tickInMeasure: 0) }
        let target = max(0, seconds)
        var elapsed = 0.0
        for (i, ticks) in lengths.enumerated() {
            let measureDuration = measureSeconds(measureIndex: i, ticks: ticks)
            let isLast = i == lengths.count - 1
            if target < elapsed + measureDuration || isLast {
                let into = measureDuration > 0 ? (target - elapsed) / measureDuration : 0
                let clamped = min(max(into, 0), 1)
                let tick = min(Int((clamped * Double(ticks)).rounded()), ticks)
                return .beat(measureIndex: i, tickInMeasure: tick)
            }
            elapsed += measureDuration
        }
        return .beat(measureIndex: lengths.count - 1, tickInMeasure: lengths.last ?? 0)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:ReaderTests/ScoreSeekTimeTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Score+SeekTime.swift Packages/Features/Reader/Tests/ReaderTests/ScoreSeekTimeTests.swift
git commit -m "feat(reader): tempo-weighted time-cursor map for seek bar"
```

---

## Task 2: Scrub state on `ReaderPlaybackSession`

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderPlaybackSessionScrubTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `ReaderPlaybackSessionScrubTests.swift`:

```swift
import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
@Suite struct ReaderPlaybackSessionScrubTests {
    private static func twoMeasureScore() -> Score {
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: [Measure(voices: []), Measure(voices: [])])],
        )
        let systemMeasures = [
            SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 2.0))),
            ]),
            SystemMeasure(),
        ]
        return Score(division: 480, parts: [part], systemMeasures: systemMeasures, metaTags: [:])
    }

    private static func session(
        controller: FakePlaybackController? = FakePlaybackController(),
    ) -> ReaderPlaybackSession {
        let score = twoMeasureScore()
        let session = ReaderPlaybackSession(controller: controller, museScoreGeneralProvider: nil)
        session.scoreProvider = { score }
        return session
    }

    @Test func `display cursor falls back to playback cursor when not scrubbing`() {
        let session = Self.session()
        session.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))
        #expect(session.scrubCursor == nil)
        #expect(session.displayCursor == .beat(measureIndex: 1, tickInMeasure: 0))
    }

    @Test func `begin scrub seeds the provisional cursor from the real cursor`() {
        let session = Self.session()
        session.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))
        session.beginScrub()
        #expect(session.scrubCursor == .beat(measureIndex: 1, tickInMeasure: 0))
    }

    @Test func `update scrub moves the provisional cursor without touching the real one`() {
        let session = Self.session()
        session.setManualCursor(.beat(measureIndex: 0, tickInMeasure: 0))
        session.beginScrub()
        session.updateScrub(toFraction: 0.5) // half of a 4s timeline = 2s = measure 1 start
        #expect(session.scrubCursor == .beat(measureIndex: 1, tickInMeasure: 0))
        #expect(session.displayCursor == .beat(measureIndex: 1, tickInMeasure: 0))
        #expect(session.playbackCursor == .beat(measureIndex: 0, tickInMeasure: 0))
    }

    @Test func `end scrub commits to the controller and clears scrub state`() async {
        let controller = FakePlaybackController()
        let session = Self.session(controller: controller)
        session.beginScrub()
        session.updateScrub(toFraction: 0.5)
        session.endScrub()
        #expect(session.scrubCursor == nil)
        #expect(session.playbackCursor == .beat(measureIndex: 1, tickInMeasure: 0))
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(controller.recordedSetCursorCalls == [.beat(measureIndex: 1, tickInMeasure: 0)])
    }

    @Test func `end scrub without a controller still updates the local cursor`() {
        let session = Self.session(controller: nil)
        session.beginScrub()
        session.updateScrub(toFraction: 1.0)
        session.endScrub()
        #expect(session.scrubCursor == nil)
        #expect(session.playbackCursor == .beat(measureIndex: 1, tickInMeasure: 1920))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:ReaderTests/ReaderPlaybackSessionScrubTests`
Expected: FAIL — `scrubCursor` / `displayCursor` / `beginScrub` / `updateScrub` / `endScrub` are unresolved.

- [ ] **Step 3: Write the implementation**

In `ReaderPlaybackSession.swift`, add a stored property next to `playbackCursor` (line 13):

```swift
    private(set) var playbackCursor: ScoreCursor?

    /// Provisional cursor shown while the user drags the seek bar. Non-nil only mid-scrub. The score
    /// views render `displayCursor`, so they follow this instead of the live `playbackCursor`; audio
    /// and the real cursor stay put until `endScrub()`.
    private(set) var scrubCursor: ScoreCursor?

    /// What the on-screen score should highlight and auto-scroll to: the provisional scrub position
    /// when dragging, otherwise the live playback cursor.
    var displayCursor: ScoreCursor? { scrubCursor ?? playbackCursor }
```

Add the three scrub methods after `setManualCursor(_:)` (after line 248), mirroring `seek(toMeasureStart:)`'s commit pattern:

```swift
    /// Begin an interactive seek-bar drag. Seeds the provisional cursor at the current real position so
    /// the score doesn't jump before the first drag delta arrives.
    func beginScrub() {
        scrubCursor = playbackCursor ?? .beat(measureIndex: 0, tickInMeasure: 0)
    }

    /// Move the provisional cursor to `fraction` (0...1) of the notated timeline. Views following
    /// `displayCursor` re-scroll / page; audio and the real cursor are untouched.
    func updateScrub(toFraction fraction: Double) {
        guard let score = scoreProvider() else { return }
        let clamped = min(max(fraction, 0), 1)
        scrubCursor = score.cursor(atSeconds: clamped * score.notatedDurationSeconds)
        onCursorChanged()
    }

    /// Commit the drag: jump audio + the real cursor to the provisional position via the engine's
    /// existing `setCursor(to:)`, then clear scrub state so `displayCursor` falls back to the live
    /// cursor. A `.beat` cursor is staff-agnostic, so no hidden-staves translation is needed.
    func endScrub() {
        guard let target = scrubCursor else { return }
        rawPlaybackCursor = target
        playbackCursor = target
        scrubCursor = nil
        onCursorChanged()
        guard let controller else { return }
        Task { await controller.setCursor(to: target) }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:ReaderTests/ReaderPlaybackSessionScrubTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift Packages/Features/Reader/Tests/ReaderTests/ReaderPlaybackSessionScrubTests.swift
git commit -m "feat(reader): scrub state and display cursor on playback session"
```

---

## Task 3: Render `displayCursor` in the score containers

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift:152,162,172`

The three containers take a `playbackCursor:` argument. Switch the argument source from `playbackCursor` to `displayCursor` so they follow the provisional cursor while scrubbing. The parameter name inside each container stays `playbackCursor` — only the call sites change.

- [ ] **Step 1: Edit the three call sites**

In `ReaderRootScreen.content`, in each of the `.vertical`, `.horizontal`, `.page` branches, change:

```swift
                    playbackCursor: viewModel.playbackSession.playbackCursor,
```

to:

```swift
                    playbackCursor: viewModel.playbackSession.displayCursor,
```

(There are exactly three occurrences — one per layout branch.)

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the full Reader test suite (no regressions)**

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: PASS — `displayCursor == playbackCursor` when not scrubbing, so existing cursor tests are unaffected.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift
git commit -m "feat(reader): score containers follow scrub display cursor"
```

---

## Task 4: Settings key + toggle + localization

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift`
- Modify: `Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift`
- Modify: `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add the settings key**

In `ReaderLayoutMode.swift`, inside `enum ReaderGlobalSettingsKey`, after `pageTapHintDismissed` (line 44):

```swift
    /// Bool. When true, the Reader's bottom transport control shows a full-width time-based seek bar.
    /// Defaults to `true` at the `@AppStorage` site. When false, only the compact transport pill shows.
    public static let showSeekBarEnabled = "readerShowSeekBarEnabled"
```

- [ ] **Step 2: Add the toggle to the Settings reader section**

In `SettingsSheet.swift`, add an `@AppStorage` after `keepScreenAwake` (line 37):

```swift
    @AppStorage(ReaderGlobalSettingsKey.showSeekBarEnabled)
    private var showSeekBar = true
```

In `readerSection`, add this `Toggle` immediately after the `keepScreenAwakeToggle` line (line 119):

```swift
            seekBarToggle
```

And add the computed view next to `keepScreenAwakeToggle` (after line 177):

```swift
    private var seekBarToggle: some View {
        Toggle(isOn: $showSeekBar) {
            Label {
                Text("settings.reader.showSeekBar", bundle: .module)
            } icon: {
                Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
            }
        }
    }
```

- [ ] **Step 3: Add the localized string**

Add this entry to the `"strings"` object in the Settings `Localizable.xcstrings` (insert in key order near other `settings.reader.*` keys):

```json
    "settings.reader.showSeekBar" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Seek bar" } },
        "ja" : { "stringUnit" : { "state" : "translated", "value" : "シークバー" } },
        "ko" : { "stringUnit" : { "state" : "translated", "value" : "탐색 막대" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "进度条" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "進度列" } }
      }
    },
```

- [ ] **Step 4: Build Settings + Domain**

Run: `xcodebuild build -scheme Settings -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings
git commit -m "feat(settings): add reader seek-bar visibility toggle"
```

---

## Task 5: Bottom overlay — collapsed vs expanded card with seek bar

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderToolbar.swift` (`ReaderBottomOverlay`)
- Modify: `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings`

This is the main UI task. `ReaderBottomOverlay` gains a `showSeekBar: Bool` and two static content-height constants used by Task 6 for the viewport inset. OFF keeps today's layout verbatim; ON renders a full-width glass card (seek bar on top, transport row below) whose background bleeds through the bottom safe area but not the horizontal safe areas.

- [ ] **Step 1: Add the accessibility string**

Add to the Reader `Localizable.xcstrings` `"strings"` object (near other `reader.toolbar.*` keys):

```json
    "reader.toolbar.seekBar" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Playback position" } },
        "ja" : { "stringUnit" : { "state" : "translated", "value" : "再生位置" } },
        "ko" : { "stringUnit" : { "state" : "translated", "value" : "재생 위치" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "播放位置" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "播放位置" } }
      }
    },
```

- [ ] **Step 2: Restructure `ReaderBottomOverlay`**

Replace the `ReaderBottomOverlay` struct (lines 111–221) so it branches on `showSeekBar`. Keep the existing `transportButton`, `endpointButton`, and the transport/endpoint button bodies; extract the reusable pieces. Full replacement:

```swift
struct ReaderBottomOverlay: View {
    @Bindable var viewModel: ReaderViewModel
    /// When true, render the full-width seek-bar card; when false, today's compact transport pill.
    let showSeekBar: Bool

    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0

    /// Content height (above the bottom safe area) of the compact control — transport pill (44) plus
    /// the surrounding `.padding()` (16 top + 16 bottom). Used by `ReaderRootScreen` to inset the
    /// horizontal / page viewport so the score never renders under the control.
    static let collapsedContentHeight: CGFloat = 76
    /// Content height of the expanded card — seek row (~28) + spacing (8) + transport row (44) plus
    /// top padding (12) and inter-row padding. Excludes the safe-area bleed region.
    static let expandedContentHeight: CGFloat = 100

    /// Resolves the loaded score, if any, for the seek bar's time math.
    private var loadedScore: Score? {
        if case let .loaded(score) = viewModel.loadState { return score }
        return nil
    }

    var body: some View {
        if showSeekBar, let score = loadedScore {
            expandedLayout(score: score)
        } else {
            collapsedLayout
        }
    }

    // MARK: Collapsed (today's layout — unchanged)

    private var collapsedLayout: some View {
        HStack(spacing: 12) {
            resetZoomButton
            Spacer()
            endpointButtons
            if case .loaded = viewModel.loadState {
                transportPill
            }
        }
        .padding()
    }

    // MARK: Expanded (full-width seek card)

    private func expandedLayout(score: Score) -> some View {
        VStack(spacing: 8) {
            // reset-zoom floats above the card, leading — contextual, so it does not affect the inset.
            if viewModel.viewportZoom > 1.0 {
                HStack { resetZoomButton; Spacer() }
                    .padding(.horizontal)
            }
            seekCard(score: score)
        }
    }

    private func seekCard(score: Score) -> some View {
        VStack(spacing: 8) {
            seekBar(score: score)
            HStack(spacing: 0) {
                transportButtonsContent
                Spacer(minLength: 0)
                endpointButtons
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        // Keep the controls above the home indicator; the glass behind reaches the screen edge.
        .padding(.bottom, 8)
        .background(alignment: .top) {
            // Rounded-top glass that bleeds through the bottom safe area to the screen edge, but not
            // into the left/right safe areas (`.ignoresSafeArea(edges: .bottom)` only).
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
                .ignoresSafeArea(edges: .bottom)
        }
        .padding(.horizontal, 12) // outer margin from screen edges
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
    }

    private func seekBar(score: Score) -> some View {
        let total = score.notatedDurationSeconds
        let fraction = Binding<Double>(
            get: {
                if isScrubbing { return scrubFraction }
                guard total > 0, let cursor = viewModel.playbackSession.playbackCursor else { return 0 }
                return min(max(score.seconds(at: cursor) / total, 0), 1)
            },
            set: { newValue in
                scrubFraction = newValue
                viewModel.playbackSession.updateScrub(toFraction: newValue)
            },
        )
        return Slider(value: fraction, in: 0 ... 1) { editing in
            isScrubbing = editing
            if editing {
                viewModel.playbackSession.beginScrub()
            } else {
                viewModel.playbackSession.endScrub()
            }
        }
        .tint(.accentColor)
        .accessibilityLabel(Text("reader.toolbar.seekBar", bundle: .module))
    }

    // MARK: Shared pieces

    @ViewBuilder private var resetZoomButton: some View {
        if viewModel.viewportZoom > 1.0 {
            Button {
                viewModel.resetZoom()
            } label: {
                Label {
                    Text("reader.toolbar.resetZoom", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    @ViewBuilder private var endpointButtons: some View {
        if viewModel.repeatModel.mode == .abLoop {
            endpointButton(
                label: "A",
                isSet: viewModel.repeatModel.pendingRepeatA != nil,
                onSet: { Task { await viewModel.repeatModel.setA() } },
            )
            endpointButton(
                label: "B",
                isSet: viewModel.repeatModel.pendingRepeatB != nil,
                onSet: { Task { await viewModel.repeatModel.setB() } },
            )
        }
    }

    /// Transport buttons as a standalone interactive glass pill (collapsed layout).
    private var transportPill: some View {
        HStack(spacing: 0) { transportButtonsContent }
            .glassEffect(.regular.interactive())
            .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
    }

    /// Bare transport buttons (jump-to-start / step back / play-pause / step forward). Reused by the
    /// collapsed pill and the expanded card.
    @ViewBuilder private var transportButtonsContent: some View {
        transportButton(
            image: Image("arrow.uturn.backward.to.line", bundle: .module),
            label: Text("reader.toolbar.jumpToStart", bundle: .module),
        ) {
            viewModel.playbackSession.seekToStart()
        }
        transportButton(
            image: Image(systemName: "chevron.left.2"),
            label: Text("reader.toolbar.stepBackward", bundle: .module),
        ) {
            viewModel.playbackSession.stepMeasureBackward()
        }
        transportButton(
            image: Image(systemName: viewModel.playbackSession.isPlaying ? "pause.fill" : "play.fill"),
            label: Text(
                viewModel.playbackSession.isPlaying ? "reader.toolbar.pause" : "reader.toolbar.play",
                bundle: .module,
            ),
        ) {
            Task { await viewModel.playbackSession.togglePlayback() }
        }
        transportButton(
            image: Image(systemName: "chevron.right.2"),
            label: Text("reader.toolbar.stepForward", bundle: .module),
        ) {
            viewModel.playbackSession.stepMeasureForward()
        }
    }

    private func transportButton(
        image: Image,
        label: Text,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            image
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .tint(.primary)
        .accessibilityLabel(label)
    }

    private func endpointButton(
        label: String,
        isSet: Bool,
        onSet: @escaping () -> Void,
    ) -> some View {
        Button(action: onSet) {
            Text(verbatim: label)
                .tint(.primary)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .glassEffect(.regular.tint(isSet ? .clear : .accentColor).interactive())
    }
}
```

Note: `Score` is already in scope via `import SheetMusicCore` at the top of `ReaderToolbar.swift`.

- [ ] **Step 3: Add a preview for the expanded card**

Append a preview inside the existing `#if DEBUG` block at the bottom of `ReaderToolbar.swift` (after the existing `#Preview`):

```swift
#Preview("Bottom overlay · seek bar") {
    let score = Score(
        division: 480,
        parts: [Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: [Measure(voices: []), Measure(voices: []), Measure(voices: [])])],
        )],
        systemMeasures: [
            SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 2.0))),
            ]),
            SystemMeasure(), SystemMeasure(),
        ],
        metaTags: [:],
    )
    let vm = ReaderViewModel(
        scoreItem: PreviewFakeRepository.sampleItem,
        repository: PreviewFakeRepository(),
        gateway: PreviewFakeGateway(score: score),
        scoresDirectory: URL(filePath: "/tmp"),
    )
    return VStack {
        Spacer()
        ReaderBottomOverlay(viewModel: vm, showSeekBar: true)
    }
    .task { await vm.load() }
}
```

- [ ] **Step 4: Render the preview and verify the layout**

Render `Bottom overlay · seek bar` via `mcp__xcode__RenderPreview` and `Read` the PNG. Verify against the spec:
- Full-width card with a horizontal margin from the screen edges.
- Seek bar (label-free) on top; transport row below; A/B only when AB-loop is active.
- Glass reaches the screen bottom edge (bleeds through the safe area), top corners rounded.

Iterate on `seekCard` paddings / `cornerRadius` against the snapshot until it matches. If `expandedContentHeight` no longer matches the rendered card height, update the constant (Task 6 reads it).

- [ ] **Step 5: Build the Reader package**

Run: `xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED. (`ReaderRootScreen` will not compile yet because it constructs `ReaderBottomOverlay` without `showSeekBar` — fixed in Task 6. If building the whole package fails only on that call site, proceed to Task 6; otherwise fix preview/card errors first.)

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/ReaderToolbar.swift Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings
git commit -m "feat(reader): full-width seek-bar card in bottom overlay"
```

---

## Task 6: Wire `showSeekBar` + bottom viewport inset in `ReaderRootScreen`

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`

- [ ] **Step 1: Add the `@AppStorage`**

After `keepScreenAwake` (line 30):

```swift
    @AppStorage(ReaderGlobalSettingsKey.showSeekBarEnabled)
    private var showSeekBar = true
```

- [ ] **Step 2: Pass `showSeekBar` to the bottom overlay**

Change the `ReaderBottomOverlay(viewModel: viewModel)` line (line 82) to:

```swift
                ReaderBottomOverlay(viewModel: viewModel, showSeekBar: showSeekBar)
```

- [ ] **Step 3: Inset the score viewport above the control in horizontal / page modes**

Add a computed inset and apply it to `content` next to the existing top inset (line 69). Replace:

```swift
            content
                .safeAreaPadding(.top, ReaderTopOverlay.height)
```

with:

```swift
            content
                .safeAreaPadding(.top, ReaderTopOverlay.height)
                .safeAreaPadding(.bottom, bottomControlInset)
```

And add this computed property to the struct (e.g. after the `layoutMode` computed property, line 36):

```swift
    /// Space the bottom control reserves above the score, applied only in horizontal / page modes —
    /// vertical mode lets the score scroll under the floating control. The control overlays the
    /// score's bottom edge whether or not the seek bar is shown, so both states inset; the expanded
    /// card is taller than the compact pill.
    private var bottomControlInset: CGFloat {
        switch layoutMode {
        case .vertical:
            0
        case .horizontal, .page:
            showSeekBar
                ? ReaderBottomOverlay.expandedContentHeight
                : ReaderBottomOverlay.collapsedContentHeight
        }
    }
```

- [ ] **Step 4: Build the Reader package**

Run: `xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Run the full Reader test suite**

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift
git commit -m "feat(reader): limit horizontal/page viewport above the bottom control"
```

---

## Task 7: Full app build + manual verification handoff

**Files:** none (verification only)

- [ ] **Step 1: Regenerate the project and build the app**

The app project must build with the new code. Run from the worktree root:

```bash
xcodegen generate
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 2: Run the app test suite**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation test
```

Expected: PASS.

- [ ] **Step 3: Hand off for manual verification**

Do not auto-launch the simulator (project convention). Summarize for the user to verify by hand:
- Seek bar appears by default; full-width card with margins; glass reaches the bottom edge but not the left/right safe areas.
- Dragging shows the provisional cursor and the score auto-scrolls / pages to it (horizontal + page); audio and the real cursor jump only on release.
- Settings → Reader → "Seek bar" toggles the bar; OFF reverts to the compact pill.
- Horizontal + page: the score never renders under the control in either state. Vertical: unchanged (score scrolls under the control).

---

## Self-review notes

- **Spec coverage:** §1 settings → Task 4; §2 time map → Task 1; §3 scrub state → Task 2; §4 containers → Task 3; §5 card/slider → Task 5; §6 viewport inset → Task 6. All covered.
- **Type consistency:** `notatedDurationSeconds`, `seconds(at:)`, `cursor(atSeconds:)` (Task 1) are used verbatim in Tasks 2 and 5. `scrubCursor` / `displayCursor` / `beginScrub` / `updateScrub(toFraction:)` / `endScrub` (Task 2) are used verbatim in Tasks 3 and 5. `showSeekBar` and `ReaderBottomOverlay.{collapsed,expanded}ContentHeight` (Task 5) are used in Task 6. `ReaderGlobalSettingsKey.showSeekBarEnabled` (Task 4) is read in Tasks 4 and 6.
- **Risks:** (1) `expandedContentHeight` is a static estimate — Task 5 step 4 reconciles it with the rendered card. (2) ko / zh-Hans / zh-Hant translations for the two new strings are best-effort; flag for native review. (3) Scores with repeats make the live thumb revisit earlier positions when a section repeats — accepted for v1 (notated timeline).
```
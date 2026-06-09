# Android Reader Rehearsal Marks & Measure Skip — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add iOS-parity rehearsal-mark bubbles and previous/next-measure skip buttons to the Android Reader's seek-bar transport, with the underlying score logic shared via swift-sheet-music (not reimplemented in Kotlin).

**Architecture:** Lift the Reader's tempo/tick/seek-time/rehearsal-mark Swift extensions out of the Folino `Reader` feature into swift-sheet-music's `SheetMusicCore` (Foundation-only, Android-reachable). Add two JNI bridges (`nativeRehearsalMarks`, `nativeStepMeasureCursor`) over those shared functions. Refactor iOS Reader to call the lifted API (no behavior change). Build the Android UI in Jetpack Compose (pills above the seek bar + `‹`/`›` measure buttons), wired through the existing `AndroidPlaybackEngine.seek(to: ScoreCursor)`.

**Tech Stack:** Swift 6.3, swift-sheet-music (SPM + JNI via swift-java/jextract), Wirelet wire codecs, Folino SPM packages, Jetpack Compose / Material3, Kotlin DataStore, Pixel device.

**Spec:** `docs/superpowers/specs/2026-06-09-android-reader-rehearsal-marks-measure-skip-design.md`

**Cross-repo gotchas (from project memory — read before starting):**
- swift-sheet-music dev clone: `~/Developer/Personal/swift-packages/swift-sheet-music`. Work in a **worktree off `origin/main`** (ssm local main lags; `git fetch` first). Folino work also uses a worktree off **local main**.
- ssm example app needs `Examples/Apple/.../Sounds/MuseScore_General.sf2` (~205MB, gitignored) — symlink from the primary clone.
- ssm engine changes: verify in the **macOS** example app (`SheetMusicExampleMac`), **report → get approval → push** before re-pinning Folino.
- Bumping ssm in Folino = update **both** the consuming `Package.swift` `from:`/revision **and** `project.yml` `packages:` to the same pin.
- Android: regenerate wirelet/jextract codegen **before** the `.so` build (`Scripts/android-build-libs.sh`); fresh worktrees also need `swift package resolve`. Android changes are verified by **install + launch** on device by the implementer.

---

## File Structure

**swift-sheet-music (`SheetMusicCore`) — new/changed:**
- Create `Sources/SheetMusicCore/Score/Score+EffectiveTempo.swift` — `governingTempo(at:)`, `effectiveQuarterBpm(at:)` (lifted).
- Create `Sources/SheetMusicCore/Score/Score+TickInMeasure.swift` — `resolveTickInMeasure(for:)`, `tickInMeasure(of:)`, `beatTicks(atMeasure:)` (lifted).
- Create `Sources/SheetMusicCore/Score/Score+NotatedTime.swift` — `notatedDurationSeconds`, `seconds(at:)`, `cursor(atSeconds:)` (lifted).
- Create `Sources/SheetMusicCore/Score/Score+RehearsalMarks.swift` — `RehearsalMarkEntry` struct + `Score.rehearsalMarks()`.
- Create `Sources/SheetMusicCore/Score/Score+MeasureStep.swift` — `MeasureStepDirection` enum + `Score.cursorSteppingMeasure(from:direction:)`.
- Modify `Sources/SheetMusicCore/Score/Score+OpeningTempo.swift` — redefine `openingQuarterBpm` as `effectiveQuarterBpm(at: nil)` (DRY) and remove the duplicated mirror logic.

**swift-sheet-music (`SheetMusicAndroidJNI`) — new/changed:**
- Create `Sources/SheetMusicAndroidJNI/Audio/RehearsalMarkCodec.swift` — list wire codec (template: `Audio/MetronomeBeatCodec.swift`).
- Create `Sources/SheetMusicAndroidJNI/RehearsalMarksBridge.swift` — `nativeRehearsalMarks(scoreHandle:)`.
- Create `Sources/SheetMusicAndroidJNI/MeasureStepBridge.swift` — `nativeStepMeasureCursor(scoreHandle:fromCursorBytes:direction:)`.

**swift-sheet-music (Kotlin facade):**
- Modify `Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/SheetMusicJNI.kt` — `nativeRehearsalMarks`, `nativeStepMeasureCursor` + a `RehearsalMarkEntry` Kotlin decode.

**swift-sheet-music tests:**
- Create `Tests/SheetMusicTests/RehearsalMarksTests.swift`, `Tests/SheetMusicTests/MeasureStepTests.swift`.
- Create `Tests/SheetMusicTests/AndroidJNI/RehearsalMarksBridgeTests.swift`, `Tests/SheetMusicTests/AndroidJNI/MeasureStepBridgeTests.swift`.

**Folino iOS (`Reader` feature) — delete + rewire:**
- Delete `Packages/Features/Reader/Sources/Reader/Score+EffectiveTempo.swift`, `Score+ResolveTickInMeasure.swift`, `Score+SeekTime.swift`.
- Rewrite `Packages/Features/Reader/Sources/Reader/Score+RehearsalMarks.swift` — map shared `RehearsalMarkEntry` → `ReaderRehearsalMark`.
- Modify `Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift` — `stepMeasure{Forward,Backward}` call `cursorSteppingMeasure`.
- Re-pin ssm in the relevant `Package.swift` files + `project.yml`.

**Folino Android:**
- Modify `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt` — `rehearsalMarks` StateFlow + step methods + `RehearsalMark` data class.
- Modify `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` — `RehearsalMarkBubbleRow` + transport row `‹`/`›` buttons.

---

## PHASE A — swift-sheet-music: shared logic + JNI

### Task A1: Create the ssm worktree

**Files:** none (environment setup)

- [ ] **Step 1: Fetch and create the worktree off origin/main**

```bash
git -C ~/Developer/Personal/swift-packages/swift-sheet-music fetch origin
git -C ~/Developer/Personal/swift-packages/swift-sheet-music worktree add -b reader-rehearsal-measure-step /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music-rehearsal origin/main
```

- [ ] **Step 2: Symlink the example soundfont from the primary clone**

```bash
ln -s ~/Developer/Personal/swift-packages/swift-sheet-music/Examples/Apple/SheetMusicExample/Sounds/MuseScore_General.sf2 /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music-rehearsal/Examples/Apple/SheetMusicExample/Sounds/MuseScore_General.sf2
```

- [ ] **Step 3: Verify the host build works**

Run: `swift build --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music-rehearsal --target SheetMusicCore`
Expected: `Build complete!`

> All subsequent Phase A paths are under `…/swift-sheet-music-rehearsal/`.

### Task A2: Lift tempo helpers into SheetMusicCore

**Files:**
- Create: `Sources/SheetMusicCore/Score/Score+EffectiveTempo.swift`
- Modify: `Sources/SheetMusicCore/Score/Score+OpeningTempo.swift`

- [ ] **Step 1: Create `Score+EffectiveTempo.swift` with the lifted logic**

```swift
extension Score {
    /// The tempo marking governing `cursor` — the most recent `SystemElement.tempo` at or before the cursor's measure
    /// and in-measure tick — or `nil` when none precedes the position (or the score carries none). A `nil` cursor is
    /// treated as the very start of the score, so it yields the opening marking.
    public func governingTempo(at cursor: ScoreCursor?) -> Tempo? {
        guard !systemMeasures.isEmpty else { return nil }
        let cursorMeasure = cursor?.measureIndex ?? 0
        let cursorTick = cursor.map { tickInMeasure(of: $0) } ?? 0
        let lastMeasure = min(cursorMeasure, systemMeasures.count - 1)

        var governing: Tempo?
        for measureIndex in 0 ... lastMeasure {
            let isCursorMeasure = measureIndex == cursorMeasure
            for positioned in systemMeasures[measureIndex].elements {
                guard case let .tempo(tempo) = positioned.element else { continue }
                // In the cursor's own measure, a marking only takes effect once the cursor reaches its tick.
                if isCursorMeasure, positioned.position.ticks(division: division) > cursorTick { continue }
                governing = tempo
            }
        }
        return governing
    }

    /// Quarter-note BPM in force at `cursor` — falls back to MuseScore's 120 BPM default when no marking governs the
    /// position. A `nil` cursor yields the opening tempo.
    public func effectiveQuarterBpm(at cursor: ScoreCursor?) -> Double {
        (governingTempo(at: cursor)?.beatsPerSecond ?? 2.0) * 60
    }
}
```

- [ ] **Step 2: Redefine `openingQuarterBpm` in terms of the lifted helper (DRY)**

In `Score+OpeningTempo.swift`, replace the mirrored derivation body so the property becomes:

```swift
extension Score {
    /// Quarter-note BPM at the score's opening. Equivalent to `effectiveQuarterBpm(at: nil)`.
    public var openingQuarterBpm: Double { effectiveQuarterBpm(at: nil) }
}
```

(Keep any other declarations in that file intact; only collapse the duplicated opening-tempo derivation.)

- [ ] **Step 3: Build to verify (will fail — `tickInMeasure` not yet defined)**

Run: `swift build --package-path . --target SheetMusicCore`
Expected: FAIL referencing `tickInMeasure` — resolved by Task A3.

### Task A3: Lift tick-in-measure helpers into SheetMusicCore

**Files:**
- Create: `Sources/SheetMusicCore/Score/Score+TickInMeasure.swift`

- [ ] **Step 1: Create the file with lifted logic (made `public`)**

```swift
extension Score {
    /// In-measure tick offset of the voice element identified by `itemID`. Returns `nil` when the path doesn't resolve.
    public func resolveTickInMeasure(for itemID: ScoreItemID) -> Int? {
        guard let staff = self[itemID.staff] else { return nil }
        guard staff.measures.indices.contains(itemID.measureIndex) else { return nil }
        let voices = staff.measures[itemID.measureIndex].voices
        guard voices.indices.contains(itemID.voiceIndex) else { return nil }
        let elements = voices[itemID.voiceIndex].elements
        guard itemID.elementIndex >= 0, itemID.elementIndex <= elements.count else { return nil }

        let measureDuration = staff.measures.effectiveMeasureDurations()[itemID.measureIndex]
        var tick = 0
        for i in 0 ..< itemID.elementIndex {
            if case let .chord(chord) = elements[i] {
                tick += chord.duration.resolved(in: measureDuration).ticks(division: division)
            }
        }
        return tick
    }

    /// In-measure tick offset of a cursor regardless of its `.item` vs `.beat` flavour.
    public func tickInMeasure(of cursor: ScoreCursor) -> Int {
        switch cursor {
        case let .beat(_, tick): tick
        case let .item(id): resolveTickInMeasure(for: id) ?? 0
        }
    }

    /// Tick length of one notated beat (the prevailing time-signature denominator unit) in `measureIndex`. Carries the
    /// time signature forward from earlier measures, defaulting to 4/4. `nil` when the index is out of range.
    public func beatTicks(atMeasure measureIndex: Int) -> Int? {
        guard let measures = parts.first?.staves.first?.measures,
              measures.indices.contains(measureIndex)
        else { return nil }
        var denominator = 4
        for i in 0 ... measureIndex {
            for case let .timeSignature(ts) in measures[i].voices.flatMap(\.elements) {
                denominator = ts.denominator
                break
            }
        }
        return 4 * division / denominator
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build --package-path . --target SheetMusicCore`
Expected: `Build complete!` (Task A2 now resolves).

- [ ] **Step 3: Commit**

```bash
git -C . add Sources/SheetMusicCore/Score/Score+EffectiveTempo.swift Sources/SheetMusicCore/Score/Score+TickInMeasure.swift Sources/SheetMusicCore/Score/Score+OpeningTempo.swift
git -C . commit -m "feat(core): lift effective-tempo and tick-in-measure helpers into SheetMusicCore"
```

### Task A4: Lift notated-time map into SheetMusicCore

**Files:**
- Create: `Sources/SheetMusicCore/Score/Score+NotatedTime.swift`

- [ ] **Step 1: Create the file (lifted, `public` where consumed cross-module)**

```swift
extension Score {
    /// Per-measure tick length, indexed by measure number.
    private func measureTickLengths() -> [Int] {
        effectiveMeasureDurations().map { $0.ticks(division: division) }
    }

    /// Seconds a measure of `ticks` length occupies at the quarter-BPM governing its downbeat.
    private func measureSeconds(measureIndex: Int, ticks: Int) -> Double {
        let bpm = max(1, effectiveQuarterBpm(at: .beat(measureIndex: measureIndex, tickInMeasure: 0)))
        let secondsPerTick = (60.0 / bpm) / Double(max(1, division))
        return Double(ticks) * secondsPerTick
    }

    /// Total notated duration in seconds (each measure counted once — no repeat expansion).
    public var notatedDurationSeconds: Double {
        measureTickLengths().enumerated().reduce(0.0) { acc, pair in
            acc + measureSeconds(measureIndex: pair.offset, ticks: pair.element)
        }
    }

    /// Cumulative seconds from the score's start to `cursor`.
    public func seconds(at cursor: ScoreCursor) -> Double {
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

    /// Inverse of `seconds(at:)`: the `.beat` cursor at `seconds` from the start, clamped to `0 ... notatedDurationSeconds`.
    public func cursor(atSeconds seconds: Double) -> ScoreCursor {
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

- [ ] **Step 2: Build**

Run: `swift build --package-path . --target SheetMusicCore`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git -C . add Sources/SheetMusicCore/Score/Score+NotatedTime.swift
git -C . commit -m "feat(core): lift notated-time map (seconds/cursor) into SheetMusicCore"
```

### Task A5: RehearsalMarkEntry + Score.rehearsalMarks() (TDD)

**Files:**
- Create: `Sources/SheetMusicCore/Score/Score+RehearsalMarks.swift`
- Test: `Tests/SheetMusicTests/RehearsalMarksTests.swift`

- [ ] **Step 1: Write the failing test**

Use an existing MSCX/score fixture loader from the test target (mirror how `RehearsalMarkTests.swift` / `EffectiveMeasureDurationsTests.swift` load a `Score`). Pick a fixture known to carry at least two rehearsal marks.

```swift
import Testing
@testable import SheetMusicCore

@Suite struct RehearsalMarksTests {
    @Test func marksAreOrderedWithFractionsInUnitRange() throws {
        let score = try TestScores.withRehearsalMarks()   // existing fixture helper
        let marks = score.rehearsalMarks()
        #expect(marks.count >= 2)
        #expect(marks.allSatisfy { $0.fraction >= 0 && $0.fraction <= 1 })
        // Ordered by position on the timeline.
        #expect(marks.map(\.fraction) == marks.map(\.fraction).sorted())
        // Each cursor is a .beat at the mark's measure.
        #expect(marks.allSatisfy { if case .beat = $0.cursor { true } else { false } })
    }

    @Test func emptyWhenNoMarks() throws {
        let score = try TestScores.simpleNoMarks()
        #expect(score.rehearsalMarks().isEmpty)
    }
}
```

> If no `TestScores` helper exists, add fixture loading inline using the same MSCX-loading call the neighboring tests use; reuse a fixture under `Tests/SheetMusicTests/Fixtures/`.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path . --filter RehearsalMarksTests`
Expected: FAIL — `rehearsalMarks` not defined.

- [ ] **Step 3: Implement `Score+RehearsalMarks.swift`**

```swift
/// A rehearsal mark resolved onto the notated timeline: its text, the fraction (0...1) of the timeline it sits at,
/// and the cursor to seek to when tapped.
public struct RehearsalMarkEntry: Equatable, Sendable {
    public let text: String
    public let fraction: Double
    public let cursor: ScoreCursor
    public init(text: String, fraction: Double, cursor: ScoreCursor) {
        self.text = text
        self.fraction = fraction
        self.cursor = cursor
    }
}

extension Score {
    /// Rehearsal marks across the score, each placed by its tempo-weighted time fraction. Empty when the score has no
    /// marks or zero notated duration. Ordered by position.
    public func rehearsalMarks() -> [RehearsalMarkEntry] {
        let total = notatedDurationSeconds
        guard total > 0 else { return [] }
        var marks: [RehearsalMarkEntry] = []
        for (measureIndex, systemMeasure) in systemMeasures.enumerated() {
            for positioned in systemMeasure.elements {
                guard case let .rehearsalMark(mark) = positioned.element else { continue }
                let tick = positioned.position.ticks(division: division)
                let cursor = ScoreCursor.beat(measureIndex: measureIndex, tickInMeasure: tick)
                let fraction = min(max(seconds(at: cursor) / total, 0), 1)
                marks.append(RehearsalMarkEntry(text: mark.text, fraction: fraction, cursor: cursor))
            }
        }
        return marks
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path . --filter RehearsalMarksTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C . add Sources/SheetMusicCore/Score/Score+RehearsalMarks.swift Tests/SheetMusicTests/RehearsalMarksTests.swift
git -C . commit -m "feat(core): Score.rehearsalMarks() with tempo-weighted fractions"
```

### Task A6: MeasureStepDirection + cursorSteppingMeasure (TDD)

**Files:**
- Create: `Sources/SheetMusicCore/Score/Score+MeasureStep.swift`
- Test: `Tests/SheetMusicTests/MeasureStepTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import SheetMusicCore

@Suite struct MeasureStepTests {
    @Test func forwardAdvancesOneMeasureAndClampsAtEnd() throws {
        let score = try TestScores.multiMeasure()   // >= 3 measures
        let last = score.effectiveMeasureDurations().count - 1
        let from = ScoreCursor.beat(measureIndex: 0, tickInMeasure: 0)
        #expect(score.cursorSteppingMeasure(from: from, direction: .forward) == .beat(measureIndex: 1, tickInMeasure: 0))
        let atEnd = ScoreCursor.beat(measureIndex: last, tickInMeasure: 0)
        #expect(score.cursorSteppingMeasure(from: atEnd, direction: .forward) == .beat(measureIndex: last, tickInMeasure: 0))
    }

    @Test func backwardRestartsCurrentMeasureWhenPastFirstBeat() throws {
        let score = try TestScores.multiMeasure()
        let beat = score.beatTicks(atMeasure: 2)!
        // Past the first beat → restart measure 2.
        let mid = ScoreCursor.beat(measureIndex: 2, tickInMeasure: beat)
        #expect(score.cursorSteppingMeasure(from: mid, direction: .backward) == .beat(measureIndex: 2, tickInMeasure: 0))
    }

    @Test func backwardGoesToPreviousMeasureWithinFirstBeat() throws {
        let score = try TestScores.multiMeasure()
        let within = ScoreCursor.beat(measureIndex: 2, tickInMeasure: 0)
        #expect(score.cursorSteppingMeasure(from: within, direction: .backward) == .beat(measureIndex: 1, tickInMeasure: 0))
        let atStart = ScoreCursor.beat(measureIndex: 0, tickInMeasure: 0)
        #expect(score.cursorSteppingMeasure(from: atStart, direction: .backward) == .beat(measureIndex: 0, tickInMeasure: 0))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path . --filter MeasureStepTests`
Expected: FAIL — `cursorSteppingMeasure` not defined.

- [ ] **Step 3: Implement `Score+MeasureStep.swift`**

```swift
public enum MeasureStepDirection: Sendable { case backward, forward }

extension Score {
    /// The `.beat` cursor for stepping one measure from `cursor`. Forward advances to the next measure's downbeat,
    /// clamped to the last measure. Backward uses the media-player idiom: if the cursor is still within the first beat
    /// of its measure, go to the previous measure's downbeat; otherwise restart the current measure. Clamped to 0.
    public func cursorSteppingMeasure(from cursor: ScoreCursor, direction: MeasureStepDirection) -> ScoreCursor {
        let count = effectiveMeasureDurations().count
        guard count > 0 else { return .beat(measureIndex: 0, tickInMeasure: 0) }
        let current = min(max(cursor.measureIndex, 0), count - 1)
        switch direction {
        case .forward:
            return .beat(measureIndex: min(current + 1, count - 1), tickInMeasure: 0)
        case .backward:
            let beat = beatTicks(atMeasure: current) ?? Int.max
            let target = tickInMeasure(of: cursor) < beat ? current - 1 : current
            return .beat(measureIndex: max(target, 0), tickInMeasure: 0)
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path . --filter MeasureStepTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C . add Sources/SheetMusicCore/Score/Score+MeasureStep.swift Tests/SheetMusicTests/MeasureStepTests.swift
git -C . commit -m "feat(core): Score.cursorSteppingMeasure measure-step navigation"
```

### Task A7: Resolve the fraction-basis question

**Files:** none (decision recorded in code comments + this task's outcome)

- [ ] **Step 1: Determine the Android seek-bar time basis**

Inspect `AndroidPlaybackEngine.totalTimeSeconds` (in `Sources/SheetMusicAudioCore` / the engine source). Confirm whether it equals `Score.notatedDurationSeconds` (notated, no repeat expansion).

- [ ] **Step 2: Decide the wire payload**

- If **equal**: the JNI returns `fraction` directly (Task A8 as written).
- If **not equal**: change `RehearsalMarkEntry`'s wire to carry `seconds` (= `score.seconds(at: cursor)`) instead of `fraction`, and on the Kotlin side divide by `audioVm.totalTimeSeconds` at render time. Update Task A8 codec + Task C2 decode accordingly.

Record the decision as a comment in `RehearsalMarkCodec.swift`. **Default assumption: equal (fraction).** Proceed with fraction unless Step 1 proves otherwise.

### Task A8: JNI bridge — nativeRehearsalMarks (TDD round-trip)

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/Audio/RehearsalMarkCodec.swift`
- Create: `Sources/SheetMusicAndroidJNI/RehearsalMarksBridge.swift`
- Test: `Tests/SheetMusicTests/AndroidJNI/RehearsalMarksBridgeTests.swift`

- [ ] **Step 1: Write the failing codec round-trip test**

```swift
import Testing
import Foundation
@testable import SheetMusicAndroidJNI
@testable import SheetMusicCore

@Suite struct RehearsalMarksBridgeTests {
    @Test func encodeDecodeRoundTrip() throws {
        let entries = [
            RehearsalMarkEntry(text: "A", fraction: 0.0, cursor: .beat(measureIndex: 0, tickInMeasure: 0)),
            RehearsalMarkEntry(text: "サビ", fraction: 0.5, cursor: .beat(measureIndex: 8, tickInMeasure: 240)),
        ]
        let data = RehearsalMarkCodec.encode(entries)
        let decoded = try RehearsalMarkCodec.decode(data)
        #expect(decoded == entries)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path . --filter RehearsalMarksBridgeTests`
Expected: FAIL — `RehearsalMarkCodec` not defined.

- [ ] **Step 3: Implement the codec**

Follow the list-codec pattern in `Sources/SheetMusicAndroidJNI/Audio/MetronomeBeatCodec.swift`. Wire layout: `i32 count`, then per entry: `i32 textByteCount` + UTF-8 bytes + `f64 fraction` + the `ScoreCursorCodec.encode(cursor)` bytes prefixed by `i32 cursorByteCount`. Provide `static func encode(_:) -> Data` and `static func decode(_:) throws -> [RehearsalMarkEntry]` using the same `@WireFormat`/byte-cursor helpers the template uses.

- [ ] **Step 4: Implement the JNI entry point**

In `RehearsalMarksBridge.swift`, mirror `NearestCursorBridge.swift`:

```swift
import Foundation
import SheetMusicCore

public func nativeRehearsalMarks(scoreHandle: Int64) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    return RehearsalMarkCodec.encode(score.rehearsalMarks())
}
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --package-path . --filter RehearsalMarksBridgeTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git -C . add Sources/SheetMusicAndroidJNI/Audio/RehearsalMarkCodec.swift Sources/SheetMusicAndroidJNI/RehearsalMarksBridge.swift Tests/SheetMusicTests/AndroidJNI/RehearsalMarksBridgeTests.swift
git -C . commit -m "feat(jni): nativeRehearsalMarks bridge + wire codec"
```

### Task A9: JNI bridge — nativeStepMeasureCursor (TDD round-trip)

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/MeasureStepBridge.swift`
- Test: `Tests/SheetMusicTests/AndroidJNI/MeasureStepBridgeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import SheetMusicAndroidJNI
@testable import SheetMusicCore

@Suite struct MeasureStepBridgeTests {
    @Test func forwardCursorRoundTripsThroughWire() throws {
        let score = try TestScores.multiMeasure()
        let handle = scoreTable.insert(score)
        defer { scoreTable.release(handle) }
        let from = try ScoreCursorCodec.encode(.beat(measureIndex: 0, tickInMeasure: 0))
        let out = nativeStepMeasureCursor(scoreHandle: handle, fromCursorBytes: from, direction: 1)
        #expect(try ScoreCursorCodec.decode(out) == .beat(measureIndex: 1, tickInMeasure: 0))
    }
}
```

> `direction` wire convention: `0 = backward`, `1 = forward`.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path . --filter MeasureStepBridgeTests`
Expected: FAIL — `nativeStepMeasureCursor` not defined.

- [ ] **Step 3: Implement the JNI entry point**

```swift
import Foundation
import SheetMusicCore

public func nativeStepMeasureCursor(scoreHandle: Int64, fromCursorBytes: Data, direction: Int32) -> Data {
    guard let score = scoreTable.value(for: scoreHandle),
          let from = try? ScoreCursorCodec.decode(fromCursorBytes)
    else { return fromCursorBytes }
    let dir: MeasureStepDirection = direction == 0 ? .backward : .forward
    let target = score.cursorSteppingMeasure(from: from, direction: dir)
    return ScoreCursorCodec.encode(target)
}
```

> If `ScoreCursorCodec.encode` is `throws`, wrap with `(try? …) ?? fromCursorBytes`.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path . --filter MeasureStepBridgeTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C . add Sources/SheetMusicAndroidJNI/MeasureStepBridge.swift Tests/SheetMusicTests/AndroidJNI/MeasureStepBridgeTests.swift
git -C . commit -m "feat(jni): nativeStepMeasureCursor bridge"
```

### Task A10: Kotlin JNI facade declarations

**Files:**
- Modify: `Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/SheetMusicJNI.kt`

- [ ] **Step 1: Add the facade methods + decode helper**

Following the existing `nativeNearestCursor` wrapper style, add:

```kotlin
fun nativeRehearsalMarks(scoreHandle: Long): ByteArray =
    SheetMusicAndroidJNI.nativeRehearsalMarks(scoreHandle)

fun nativeStepMeasureCursor(scoreHandle: Long, fromCursorBytes: ByteArray, direction: Int): ByteArray =
    SheetMusicAndroidJNI.nativeStepMeasureCursor(scoreHandle, fromCursorBytes, direction)
```

Add a Kotlin `RehearsalMarkEntry` data class and a `RehearsalMarkCodec.decode(bytes): List<RehearsalMarkEntry>` mirroring the Swift wire layout (i32 count; per entry i32 textLen + UTF-8 + f64 fraction + i32 cursorLen + cursor bytes via `ScoreCursorCodec.decode`). Place it next to `ScoreCursorCodec` in the same Kotlin package.

```kotlin
data class RehearsalMarkEntry(val text: String, val fraction: Double, val cursor: ScoreCursor)
```

- [ ] **Step 2: Build the host package (Swift side) to ensure JNI symbols compile**

Run: `swift build --package-path . --target SheetMusicAndroidJNI`
Expected: `Build complete!` (Note: full `.so`/Kotlin build happens in Folino Phase C; here verify Swift compiles.)

- [ ] **Step 3: Commit**

```bash
git -C . add Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/SheetMusicJNI.kt
git -C . commit -m "feat(jni-kotlin): rehearsal-marks + measure-step facade + RehearsalMark codec"
```

### Task A11: macOS example-app verification + push gate

**Files:**
- Modify: `Examples/Apple/SheetMusicExample/macOS/ContentSidebar.swift` (temporary verification UI)

- [ ] **Step 1: Add a temporary inspector listing rehearsal marks + step buttons**

In `ContentSidebar.swift`, add a debug section that calls `score.rehearsalMarks()` (lists text + fraction) and two buttons invoking `score.cursorSteppingMeasure(from: currentCursor, direction:)` then seeking the example's playback bridge. Keep it clearly marked as temporary.

- [ ] **Step 2: Build the macOS example**

Run: `xcodebuild -project Examples/Apple/SheetMusicExample.xcodeproj -scheme SheetMusicExampleMac -destination 'platform=macOS' -skipPackagePluginValidation build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Launch and verify by ear/eye**

```bash
open ~/Library/Developer/Xcode/DerivedData/SheetMusicExample-*/Build/Products/Debug/SheetMusicExampleMac.app
```
Verify: rehearsal-mark list matches the score; tapping step buttons jumps exactly one measure with correct rewind-vs-restart.

- [ ] **Step 4: Revert the temporary UI**

```bash
git -C . checkout Examples/Apple/SheetMusicExample/macOS/ContentSidebar.swift
```

- [ ] **Step 5: STOP — report to the user and get approval before pushing**

Per project policy, ssm engine changes are reported and approved before push. Summarize what was verified, then on approval:

```bash
git -C . push origin reader-rehearsal-measure-step
```

> Capture the pushed commit SHA — Phase B re-pins to it.

---

## PHASE B — Folino iOS: re-pin + refactor to shared API

### Task B1: Create a Folino worktree and re-pin ssm

**Files:**
- Modify: `Package.swift` of every Folino package that pins ssm, and `project.yml`.

- [ ] **Step 1: Create the Folino worktree (off local main)**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS worktree add -b reader-rehearsal-measure-step /Users/kiichi/Developer/Personal/ios-apps/Folino-rehearsal main
```

- [ ] **Step 2: Symlink Local.xcconfig into the worktree**

```bash
ln -s /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Config/Local.xcconfig /Users/kiichi/Developer/Personal/ios-apps/Folino-rehearsal/Config/Local.xcconfig
```

- [ ] **Step 3: Find every ssm pin and bump to the pushed SHA**

Run: `grep -rn "swift-sheet-music" /Users/kiichi/Developer/Personal/ios-apps/Folino-rehearsal/Packages --include=Package.swift`
Run: `grep -n "swift-sheet-music" /Users/kiichi/Developer/Personal/ios-apps/Folino-rehearsal/project.yml`

Update each `.package(url:…, revision: "<old>")` and the `project.yml` `packages:` entry to the Phase A11 SHA. (Match the existing pin style — revision vs from.)

- [ ] **Step 4: Resolve + regenerate the project**

```bash
xcodegen generate --spec /Users/kiichi/Developer/Personal/ios-apps/Folino-rehearsal/project.yml --project /Users/kiichi/Developer/Personal/ios-apps/Folino-rehearsal
```

- [ ] **Step 5: Commit the re-pin**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-rehearsal add -A
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-rehearsal commit -m "build: re-pin swift-sheet-music (shared rehearsal/measure-step API)"
```

> All Phase B/C paths below are under the `Folino-rehearsal` worktree.

### Task B2: Delete lifted Reader files, rewire rehearsal marks

**Files:**
- Delete: `Packages/Features/Reader/Sources/Reader/Score+EffectiveTempo.swift`, `Score+ResolveTickInMeasure.swift`, `Score+SeekTime.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Score+RehearsalMarks.swift`

- [ ] **Step 1: Delete the now-shared extension files**

```bash
git -C . rm Packages/Features/Reader/Sources/Reader/Score+EffectiveTempo.swift Packages/Features/Reader/Sources/Reader/Score+ResolveTickInMeasure.swift Packages/Features/Reader/Sources/Reader/Score+SeekTime.swift
```

- [ ] **Step 2: Rewrite `Score+RehearsalMarks.swift` to map the shared entry**

```swift
import SheetMusicCore

/// A rehearsal mark resolved to a position on the seek bar, for SwiftUI consumption.
struct ReaderRehearsalMark: Identifiable {
    let id: String
    let text: String
    let fraction: Double
    let cursor: ScoreCursor
}

extension Score {
    /// Reader view-model wrapper over the shared `rehearsalMarks()` from SheetMusicCore.
    func readerRehearsalMarks() -> [ReaderRehearsalMark] {
        rehearsalMarks().enumerated().map { index, entry in
            ReaderRehearsalMark(
                id: "\(index)-\(entry.text)",
                text: entry.text,
                fraction: entry.fraction,
                cursor: entry.cursor,
            )
        }
    }
}
```

- [ ] **Step 3: Update call sites of the old `rehearsalMarks()`**

Run: `grep -rn "\.rehearsalMarks()" Packages/Features/Reader/Sources`
Rename each Reader call that expected `[ReaderRehearsalMark]` to `readerRehearsalMarks()`. (The shared `rehearsalMarks()` now returns `[RehearsalMarkEntry]`.)

- [ ] **Step 4: Build the Reader package**

Run: `cd Packages/Features/Reader && xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: `BUILD SUCCEEDED`, with `Compiling` lines for the changed files (per project memory — `-scheme Folino` may false-skip).

- [ ] **Step 5: Commit**

```bash
git -C . add -A
git -C . commit -m "refactor(reader): consume shared SheetMusicCore tempo/time/rehearsal API"
```

### Task B3: Route measure-step through the shared function

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift`

- [ ] **Step 1: Replace the inline step logic with the shared call**

In `stepMeasureForward()` / `stepMeasureBackward()`, compute the target via the shared API and keep the existing `seek(toMeasureStart:)` plumbing:

```swift
func stepMeasureForward() {
    let from = rawPlaybackCursor ?? .beat(measureIndex: 0, tickInMeasure: 0)
    let target = score.cursorSteppingMeasure(from: from, direction: .forward)
    seek(toMeasureStart: target.measureIndex)
}

func stepMeasureBackward() {
    let from = rawPlaybackCursor ?? .beat(measureIndex: 0, tickInMeasure: 0)
    let target = score.cursorSteppingMeasure(from: from, direction: .backward)
    seek(toMeasureStart: target.measureIndex)
}
```

> Confirm `seek(toMeasureStart:)` still exists and is the intended sink; if the surrounding code already clamps, the shared function's clamping is harmless (idempotent).

- [ ] **Step 2: Build + run Reader tests**

Run: `cd Packages/Features/Reader && xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: tests PASS; step behavior unchanged.

- [ ] **Step 3: Build the full app to confirm no cross-package breakage**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git -C . add Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift
git -C . commit -m "refactor(reader): measure step via shared cursorSteppingMeasure"
```

---

## PHASE C — Folino Android: ViewModel + Compose UI

> Prereq: the Folino Android build must use the re-pinned ssm. Per project memory, fresh worktrees need `swift package resolve` then `Scripts/android-build-libs.sh` (wirelet/jextract codegen → `.so`) **before** gradle. To avoid a full cross-compile, copy `jniLibs/` + `java-generated/` from the primary checkout only if the ssm pin matches; otherwise regenerate.

### Task C1: Rebuild Android native libs against the new ssm

**Files:** none (generated artifacts)

- [ ] **Step 1: Resolve + regenerate codegen + .so**

```bash
swift package resolve --package-path /Users/kiichi/Developer/Personal/ios-apps/Folino-rehearsal/Packages/Features/Reader
/Users/kiichi/Developer/Personal/ios-apps/Folino-rehearsal/Scripts/android-build-libs.sh
```

- [ ] **Step 2: Confirm the new JNI symbols are present**

Run: `grep -rn "nativeRehearsalMarks\|nativeStepMeasureCursor" /Users/kiichi/Developer/Personal/ios-apps/Folino-rehearsal/Android`
Expected: the generated Kotlin facade exposes both methods.

### Task C2: ViewModel — rehearsal marks + step methods

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt`

- [ ] **Step 1: Add the rehearsal-marks StateFlow and step methods**

```kotlin
private val _rehearsalMarks = MutableStateFlow<List<RehearsalMarkEntry>>(emptyList())
val rehearsalMarks: StateFlow<List<RehearsalMarkEntry>> = _rehearsalMarks.asStateFlow()

/// Call once the score handle is known (where the score/layout is set up).
fun loadRehearsalMarks(scoreHandle: Long) {
    _rehearsalMarks.value = RehearsalMarkCodec.decode(SheetMusicJNI.nativeRehearsalMarks(scoreHandle))
}

fun stepMeasureBackward(scoreHandle: Long) = stepMeasure(scoreHandle, direction = 0)
fun stepMeasureForward(scoreHandle: Long) = stepMeasure(scoreHandle, direction = 1)

private fun stepMeasure(scoreHandle: Long, direction: Int) {
    val current = engine.value?.currentCursor?.value
    val fromBytes = ScoreCursorCodec.encode(current ?: ScoreCursor.Beat(0, 0))
    val targetBytes = SheetMusicJNI.nativeStepMeasureCursor(scoreHandle, fromBytes, direction)
    val target = ScoreCursorCodec.decode(targetBytes)
    engine.value?.seek(target)
}
```

> Match the actual `ScoreCursor` Kotlin type and `engine.seek(to:)` signature found in `ReaderAudioViewModel.kt`/the engine. Thread the `scoreHandle` from wherever the Reader already holds it (the same handle used for `nativeNearestCursor`); if the VM already stores it, drop the parameter and use the field.

- [ ] **Step 2: Call `loadRehearsalMarks` when the score handle is set**

Wire the load at the same point the Reader obtains its score handle (near layout setup / where `nativeNearestCursor` gets its handle).

### Task C3: RehearsalMarkBubbleRow composable

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt`

- [ ] **Step 1: Add the composable**

```kotlin
@Composable
private fun RehearsalMarkBubbleRow(
    marks: List<RehearsalMarkEntry>,
    currentFraction: Float,
    onSeek: (ScoreCursor) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (marks.isEmpty()) return
    val currentIndex = marks.indexOfLast { it.fraction.toFloat() <= currentFraction }
    BoxWithConstraints(modifier.fillMaxWidth().height(28.dp)) {
        val width = maxWidth
        marks.forEachIndexed { index, mark ->
            val isCurrent = index == currentIndex
            // Position the pill's center at the mark fraction, clamped so it stays on-screen.
            RehearsalMarkPill(
                text = mark.text,
                isCurrent = isCurrent,
                modifier = Modifier
                    .zIndex(if (isCurrent) 1f else 0f)
                    .align(Alignment.CenterStart)
                    .offset(x = (width * mark.fraction.toFloat()))
                    .clickable { onSeek(mark.cursor) },
            )
        }
    }
}

@Composable
private fun RehearsalMarkPill(text: String, isCurrent: Boolean, modifier: Modifier = Modifier) {
    val bg = if (isCurrent) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surface
    val fg = if (isCurrent) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurfaceVariant
    Surface(
        color = bg,
        contentColor = fg,
        shape = RoundedCornerShape(50),
        border = if (isCurrent) null else BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        modifier = modifier,
    ) {
        Text(
            text = text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier.widthIn(max = 96.dp).padding(horizontal = 8.dp, vertical = 2.dp),
        )
    }
}
```

> Refine the horizontal offset so the pill is *centered* on its fraction (subtract half the pill width via `onGloballyPositioned` or a measured offset) and clamped to `[0, width - pillWidth]`. Align the row's left/right padding to whatever inset `ReaderSeekBar` uses so pills sit over their timeline points.

- [ ] **Step 2: Place the row directly above `ReaderSeekBar` inside `TransportBar`**

```kotlin
val marks by audioVm.rehearsalMarks.collectAsState()
val currentFraction = if (total > 0) (current / total).toFloat() else 0f
RehearsalMarkBubbleRow(
    marks = marks,
    currentFraction = currentFraction,
    onSeek = { cursor -> audioVm.engine.value?.seek(cursor) },
)
ReaderSeekBar(/* existing */)
```

### Task C4: Transport row measure-skip buttons

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt`

- [ ] **Step 1: Add `‹` / `›` buttons flanking play/pause**

In the transport `Row`, between the existing jump-to-start and play, add a previous-measure button; after play, add a next-measure button. Guard both on `isPrepared`.

```kotlin
SmallButton(
    onClick = { audioVm.stepMeasureBackward(scoreHandle) },
    enabled = isPrepared,
) { Icon(Icons.Filled.NavigateBefore, contentDescription = "Previous measure") }

// … existing play/pause CircleButton …

SmallButton(
    onClick = { audioVm.stepMeasureForward(scoreHandle) },
    enabled = isPrepared,
) { Icon(Icons.Filled.NavigateNext, contentDescription = "Next measure") }
```

> Use the same `SmallButton`/icon-button style already used for jump-to-start so sizing matches. Thread `scoreHandle` from the same source as Task C2. Resulting row order: `[|◀ jump-start] [‹ prev-meas] [▶/⏸ play] [› next-meas]`.

- [ ] **Step 2: Add the content descriptions to string resources (Android app module is English-only for these)**

Use literal `contentDescription` strings as above (accessibility labels; not user-facing copy). No localized resource needed.

### Task C5: Build, install, verify on device

**Files:** none

- [ ] **Step 1: Build the Android app**

```bash
/Users/kiichi/Developer/Personal/ios-apps/Folino-rehearsal/Android/gradlew -p /Users/kiichi/Developer/Personal/ios-apps/Folino-rehearsal/Android :app:installDebug
```
Expected: `BUILD SUCCESSFUL` and install on the connected Pixel.

- [ ] **Step 2: Launch**

```bash
adb shell monkey -p com.KeyNumber.Folino -c android.intent.category.LAUNCHER 1
```

- [ ] **Step 3: Manual verification (implementer drives)**

Open a score with rehearsal marks + the seek bar shown. Verify:
- Pills appear above the seek bar at the right positions; current pill highlights and advances during playback.
- Tapping a pill seeks to that mark.
- `‹` restarts the current measure unless within its first beat (then previous); `›` advances one measure; both clamp at ends; buttons dim when not prepared.
- Seek-bar-hidden (FAB) mode shows neither (unchanged).

- [ ] **Step 4: Commit the Android UI**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-rehearsal add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-rehearsal commit -m "feat(android-reader): rehearsal-mark pills + measure-skip buttons"
```

---

## PHASE D — Finish

### Task D1: Report and decide integration

- [ ] **Step 1: Summarize** what shipped (ssm pushed SHA, Folino branch, verification evidence) and **stop for the user** to decide merge/push per the project's finishing-a-development-branch flow. Do not push Folino `main` or merge without explicit approval.

---

## Self-Review notes

- **Spec coverage:** rehearsal bubbles (A5/A8/C2/C3), measure skip (A6/A9/C2/C4), shared-logic lift (A2–A6), iOS refactor-to-shared (B2/B3), seek-bar-ON-only placement (C3/C4 inside `TransportBar`), fraction-basis risk (A7), testing (A5/A6/A8/A9 + Reader tests B2/B3 + device C5), `‹`/`›` icons (C4). Drag-snap and FAB-mode are explicitly out of scope (spec).
- **Open variability flagged, not placeheld:** exact ssm wire-helper API names and the Kotlin `ScoreCursor`/`engine.seek` signatures are resolved by reading the cited template files (`MetronomeBeatCodec.swift`, `ScoreCursorCodec.swift`, `NearestCursorBridge.swift`, `ReaderAudioViewModel.kt`) during implementation — the layout and call shape are fully specified; only local identifier spellings are confirmed in-repo.
- **Type consistency:** `RehearsalMarkEntry` (text/fraction/cursor) used consistently Swift↔Kotlin; `MeasureStepDirection`/`direction` int convention (0 back / 1 forward) consistent across A6/A9/C2; `cursorSteppingMeasure(from:direction:)` signature stable across A6/A9/B3.

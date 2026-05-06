# Reader A–B Repeat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a three-mode repeat feature (off / loop-all / A–B) to the Reader, with measure-snapped A/B endpoints, per-score persistence, and a cursor-driven loop wrap.

**Architecture:** State + behavior live in `ReaderViewModel`. A cursor observer added inside the VM detects when the playback cursor crosses the loop end and seeks back to the loop start. Mode + A/B markers persist via `ReaderPreferences` (existing repository path). The audio engine's loop primitive is not used (it's a stub today); the VM-layer wrap is sufficient for practice cadence.

**Tech Stack:** Swift 6.3, SwiftUI, Swift Testing, `swift-sheet-music` (Score model + `PlaybackEngine`), CloudKit-backed `ScoreLibraryRepository`.

**Spec:** `docs/superpowers/specs/2026-05-07-reader-ab-repeat-design.md`

**Scope deviation surfaced upfront:** the spec includes a translucent
accent-color band on the score visualizing the loop region. v1 ships the
loop range as a "m.12 → m.16" text indicator on the A/B pill instead. The
score-overlay band requires an upstream measure-rect API in
`swift-sheet-music` that doesn't exist today, and adding that is a separate
concern from the loop feature itself. Confirm the deferral before starting
implementation.

---

## File Structure

### New files

| Path | Responsibility |
| --- | --- |
| `Packages/Domain/Sources/Domain/Models/RepeatMode.swift` | The 3-mode enum. |
| `Packages/Features/Reader/Sources/Reader/RepeatLoop.swift` | VM-internal loop helpers: cursor → measureIndex, snap to measure head/end, score-wide range, effective range. Pure functions, easy to unit-test. |
| `Packages/Features/Reader/Sources/Reader/RepeatModeButton.swift` | The 3-state cycle button view used in `InspectorView`. |
| `Packages/Features/Reader/Sources/Reader/ABPill.swift` | The bottom-right A/B liquid-glass pill view. |
| `Packages/Domain/Tests/DomainTests/Models/RepeatModeTests.swift` | Round-trip Codable tests. |
| `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesRepeatTests.swift` | Tests for the new fields' defaults, init, decoding legacy JSON. |
| `Packages/Features/Reader/Tests/ReaderTests/RepeatLoopHelpersTests.swift` | Tests for the pure helpers in `RepeatLoop.swift`. |
| `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift` | Behavior tests for the new VM surface. |

### Modified files

| Path | Change |
| --- | --- |
| `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift` | Add `repeatMode: RepeatMode` (default `.off`) and `abRepeat: ABRepeatRange?` (default `nil`). Preserve `Codable` back-compat. |
| `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` | Add accessors + mutators (`advanceRepeatMode`, `setRepeatA`, `setRepeatB`, `clearRepeatA`, `clearRepeatB`). Wire the cursor observer to evaluate loop wraps. Pass `abRepeat` into `initialPlaybackPreferences`. Pre-seek to A on `togglePlayback` when cursor > B. |
| `Packages/Features/Reader/Sources/Reader/InspectorView.swift` | Insert `RepeatModeButton` next to the tempo / metronome controls. |
| `Packages/Features/Reader/Sources/Reader/ReaderToolbar.swift` (`ReaderBottomOverlay`) | Host the `ABPill` to the right of the existing reset-zoom pill, gated on `repeatMode == .abLoop`. |
| `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift` | Record `setLoopRange` calls so tests can verify the forwarding. |

---

## Conventions

- All new tests use **Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`).
- Run the Reader test suite after each task: `cd Packages/Features/Reader && swift test`.
- Run the Domain test suite after Domain-side tasks: `cd Packages/Domain && swift test`.
- Each task ends with a commit. Use whole-file staging (project rule).
- Pre-commit hook runs SwiftFormat / SwiftLint — let the hook fix and re-stage if it complains.

---

## Task 1: Add `RepeatMode` enum to Domain

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/RepeatMode.swift`
- Test: `Packages/Domain/Tests/DomainTests/Models/RepeatModeTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Packages/Domain/Tests/DomainTests/Models/RepeatModeTests.swift
import Domain
import Foundation
import Testing

@Suite
struct RepeatModeTests {
    @Test func cycleAdvancesOffToAllToAbAndBackToOff() {
        #expect(RepeatMode.off.next == .loopAll)
        #expect(RepeatMode.loopAll.next == .abLoop)
        #expect(RepeatMode.abLoop.next == .off)
    }

    @Test func roundTripsThroughJSON() throws {
        for mode in [RepeatMode.off, .loopAll, .abLoop] {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(RepeatMode.self, from: data)
            #expect(decoded == mode)
        }
    }
}
```

- [ ] **Step 2: Run tests; verify they fail**

```bash
cd Packages/Domain && swift test --filter RepeatModeTests
```

Expected: FAIL — `RepeatMode` not defined.

- [ ] **Step 3: Write the enum**

```swift
// Packages/Domain/Sources/Domain/Models/RepeatMode.swift
import Foundation

/// Three-state cycle for the Reader's repeat / loop feature.
/// `.off` plays through, `.loopAll` loops the whole score, `.abLoop`
/// loops the user-selected A–B section (measures).
public enum RepeatMode: String, Hashable, Sendable, Codable, CaseIterable {
    case off
    case loopAll
    case abLoop

    /// Cycle order shown on the Inspector's mode button.
    public var next: RepeatMode {
        switch self {
        case .off: .loopAll
        case .loopAll: .abLoop
        case .abLoop: .off
        }
    }
}
```

- [ ] **Step 4: Run tests; verify they pass**

```bash
cd Packages/Domain && swift test --filter RepeatModeTests
```

Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/RepeatMode.swift \
        Packages/Domain/Tests/DomainTests/Models/RepeatModeTests.swift
git commit -m "feat(domain): add RepeatMode enum for Reader loop"
```

---

## Task 2: Extend `ReaderPreferences` with repeat fields

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift`
- Test: `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesRepeatTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesRepeatTests.swift
import Domain
import Foundation
import SheetMusicCore
import Testing

@Suite
struct ReaderPreferencesRepeatTests {
    private static func sampleScoreItemID() -> ScoreItemID { ScoreItemID() }

    @Test func defaultsRepeatModeOffAndAbRepeatNil() {
        let prefs = ReaderPreferences(
            scoreItemID: Self.sampleScoreItemID(),
            staffSize: 14,
            hiddenStaves: []
        )
        #expect(prefs.repeatMode == .off)
        #expect(prefs.abRepeat == nil)
    }

    @Test func legacyJSONWithoutRepeatFieldsDecodesWithDefaults() throws {
        let id = ReaderPreferencesID()
        let scoreID = Self.sampleScoreItemID()
        // Hand-crafted JSON without the new fields, mirroring records
        // saved before the migration.
        let json = """
        {
            "id": "\(id.rawValue)",
            "scoreItemID": "\(scoreID.rawValue)",
            "staffSize": 14,
            "hiddenStaves": [],
            "staffProgramOverrides": {}
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: json)

        #expect(decoded.repeatMode == .off)
        #expect(decoded.abRepeat == nil)
    }

    @Test func roundTripsThroughJSONWithRepeatFieldsSet() throws {
        let chord = ChordPath(systemIndex: 0, measureIndex: 4, voiceIndex: 0, chordIndex: 0)
        let endChord = ChordPath(systemIndex: 0, measureIndex: 8, voiceIndex: 0, chordIndex: 3)
        let prefs = ReaderPreferences(
            scoreItemID: Self.sampleScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            repeatMode: .abLoop,
            abRepeat: ABRepeatRange(start: chord, end: endChord)
        )

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)

        #expect(decoded.repeatMode == .abLoop)
        #expect(decoded.abRepeat?.start == chord)
        #expect(decoded.abRepeat?.end == endChord)
    }
}
```

- [ ] **Step 2: Run tests; verify they fail**

```bash
cd Packages/Domain && swift test --filter ReaderPreferencesRepeatTests
```

Expected: FAIL — `repeatMode` / `abRepeat` not present, init signature mismatch.

- [ ] **Step 3: Extend `ReaderPreferences`**

Replace the existing `init` and add the two stored properties. The full new file:

```swift
// Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift
import CoreGraphics
import Foundation
import SheetMusicCore

public struct ReaderPreferences: Hashable, Sendable, Codable, Identifiable {
    public static let minStaffSize: CGFloat = 8
    public static let maxStaffSize: CGFloat = 28
    public static let minTempoMultiplier: Double = 0.5
    public static let maxTempoMultiplier: Double = 2.0

    public let id: ReaderPreferencesID
    public let scoreItemID: ScoreItemID
    public var staffSize: CGFloat
    public var hiddenStaves: Set<StaffAddress>
    public var staffProgramOverrides: [StaffAddress: Int]
    public var tempoMultiplier: Double?
    public var repeatMode: RepeatMode
    public var abRepeat: ABRepeatRange?

    public init(
        id: ReaderPreferencesID = ReaderPreferencesID(),
        scoreItemID: ScoreItemID,
        staffSize: CGFloat,
        hiddenStaves: Set<StaffAddress>,
        staffProgramOverrides: [StaffAddress: Int] = [:],
        tempoMultiplier: Double? = nil,
        repeatMode: RepeatMode = .off,
        abRepeat: ABRepeatRange? = nil
    ) {
        self.id = id
        self.scoreItemID = scoreItemID
        self.staffSize = min(max(staffSize, Self.minStaffSize), Self.maxStaffSize)
        self.hiddenStaves = hiddenStaves
        self.staffProgramOverrides = staffProgramOverrides.mapValues { min(max($0, 0), 127) }
        self.tempoMultiplier = tempoMultiplier.map {
            min(max($0, Self.minTempoMultiplier), Self.maxTempoMultiplier)
        }
        self.repeatMode = repeatMode
        self.abRepeat = abRepeat
    }

    private enum CodingKeys: String, CodingKey {
        case id, scoreItemID, staffSize, hiddenStaves, staffProgramOverrides
        case tempoMultiplier, repeatMode, abRepeat
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(ReaderPreferencesID.self, forKey: .id)
        let scoreItemID = try c.decode(ScoreItemID.self, forKey: .scoreItemID)
        let staffSize = try c.decode(CGFloat.self, forKey: .staffSize)
        let hiddenStaves = try c.decode(Set<StaffAddress>.self, forKey: .hiddenStaves)
        let overrides = try c.decodeIfPresent(
            [StaffAddress: Int].self, forKey: .staffProgramOverrides
        ) ?? [:]
        let tempo = try c.decodeIfPresent(Double.self, forKey: .tempoMultiplier)
        let mode = try c.decodeIfPresent(RepeatMode.self, forKey: .repeatMode) ?? .off
        let ab = try c.decodeIfPresent(ABRepeatRange.self, forKey: .abRepeat)
        self.init(
            id: id, scoreItemID: scoreItemID, staffSize: staffSize,
            hiddenStaves: hiddenStaves, staffProgramOverrides: overrides,
            tempoMultiplier: tempo, repeatMode: mode, abRepeat: ab
        )
    }
}
```

(Keep the existing `static let` / `id` / `scoreItemID` ordering — only the
`init`, the two new fields, and the explicit `Decodable` are added.)

- [ ] **Step 4: Run tests; verify they pass**

```bash
cd Packages/Domain && swift test --filter ReaderPreferencesRepeatTests
```

Expected: PASS (3 tests). Run the full Domain suite too — the `ReaderPreferences` change must not break adjacent tests:

```bash
cd Packages/Domain && swift test
```

Expected: All Domain tests green.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift \
        Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesRepeatTests.swift
git commit -m "feat(domain): add repeatMode and abRepeat to ReaderPreferences"
```

---

## Task 3: Record `setLoopRange` calls on `FakePlaybackController`

The fake currently has an empty `setLoopRange` body. Tests for the VM's
loop forwarding need a recorder.

**Files:**
- Modify: `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift`

- [ ] **Step 1: Modify the fake**

Add a recorder property and append in `setLoopRange`:

```swift
// Inside the @MainActor final class FakePlaybackController body,
// alongside the other private(set) recorders:
private(set) var loopRangeCalls: [ABRepeatRange?] = []

// Replace the existing stub:
func setLoopRange(_ range: ABRepeatRange?) {
    loopRangeCalls.append(range)
}
```

(Keep the rest of the file untouched.)

- [ ] **Step 2: Verify the existing Reader tests still pass**

```bash
cd Packages/Features/Reader && swift test
```

Expected: PASS (test count unchanged from before this task).

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift
git commit -m "test(reader): record setLoopRange calls on fake controller"
```

---

## Task 4: Snap-and-cursor helpers (`RepeatLoop.swift`)

Pure functions used by the VM mutators and the loop wrap. Each helper is
unit-tested against a hand-built `Score` fixture so the VM's tests can
focus on behavior rather than fixture wrangling.

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/RepeatLoop.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/RepeatLoopHelpersTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Packages/Features/Reader/Tests/ReaderTests/RepeatLoopHelpersTests.swift
import Domain
@testable import Reader
import SheetMusicCore
import Testing

@Suite
struct RepeatLoopHelpersTests {
    /// One quarter-note rest element. Rests work for these tests since
    /// the snap helpers treat any `.chord(_)` element (including
    /// empty-notes rests) as a chord position.
    private static func element() -> VoiceElement {
        .rest(duration: .quarter)
    }

    /// 3-measure score, voice 0 has 2 elements, 3 elements, 1 element.
    private static func makeScore() -> Score {
        let m0 = Measure(voices: [Voice(elements: [element(), element()])])
        let m1 = Measure(voices: [Voice(elements: [element(), element(), element()])])
        let m2 = Measure(voices: [Voice(elements: [element()])])
        let staff = Staff(measures: [m0, m1, m2])
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [staff]
        )
        return Score(division: 480, parts: [part])
    }

    @Test func measureIndexOfBeatCursorReturnsItsField() {
        let cursor = ScoreCursor.beat(measureIndex: 4, tickInMeasure: 240)
        #expect(measureIndex(of: cursor) == 4)
    }

    @Test func measureIndexOfItemCursorReadsItDirectlyFromTheID() {
        let staffAddress = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let restID = RestID(
            staff: staffAddress, measureIndex: 7, voiceIndex: 0, elementIndex: 0
        )
        let cursor = ScoreCursor.item(.rest(restID))
        #expect(measureIndex(of: cursor) == 7)
    }

    @Test func snapMeasureHeadProducesFirstChordInMeasure() {
        let score = Self.makeScore()
        let head = snapMeasureHead(measureIndex: 1, in: score)
        #expect(head.measureIndex == 1)
        #expect(head.voiceIndex == 0)
        #expect(head.chordIndex == 0)
    }

    @Test func snapMeasureEndProducesLastChordInMeasure() {
        let score = Self.makeScore()
        let end = snapMeasureEnd(measureIndex: 1, in: score)
        #expect(end?.measureIndex == 1)
        #expect(end?.voiceIndex == 0)
        // m1 has 3 elements -> last index is 2.
        #expect(end?.chordIndex == 2)
    }

    @Test func snapMeasureEndIsNilForEmptyMeasure() {
        let emptyMeasure = Measure(voices: [Voice(elements: [])])
        let staff = Staff(measures: [emptyMeasure])
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [staff]
        )
        let score = Score(division: 480, parts: [part])
        #expect(snapMeasureEnd(measureIndex: 0, in: score) == nil)
    }

    @Test func scoreFullRangeSpansFirstChordOfMeasure0ToLastChordOfFinalMeasure() {
        let score = Self.makeScore()
        let range = scoreFullRange(in: score)
        #expect(range?.start.measureIndex == 0)
        #expect(range?.end.measureIndex == 2)
        // m0 starts at element 0; m2 has 1 element -> last index is 0.
        #expect(range?.start.chordIndex == 0)
        #expect(range?.end.chordIndex == 0)
    }

    @Test func normalizeSwapsRangeWhenStartIsAfterEnd() {
        let early = ChordPath(systemIndex: 0, measureIndex: 2, voiceIndex: 0, chordIndex: 0)
        let late = ChordPath(systemIndex: 0, measureIndex: 5, voiceIndex: 0, chordIndex: 1)
        let inverted = ABRepeatRange(start: late, end: early)
        let normalized = normalize(inverted)
        #expect(normalized.start == early)
        #expect(normalized.end == late)
    }
}
```

- [ ] **Step 2: Run tests; verify they fail**

```bash
cd Packages/Features/Reader && swift test --filter RepeatLoopHelpersTests
```

Expected: FAIL — symbols not defined.

- [ ] **Step 3: Implement the helpers**

```swift
// Packages/Features/Reader/Sources/Reader/RepeatLoop.swift
import Domain
import SheetMusicCore

/// Returns the measure index the cursor points at. Both
/// `ScoreCursor.beat` and `ScoreCursor.item` carry it directly:
/// `.beat` has it as a stored field, `.item(ScoreItemID)` exposes
/// it via `ScoreItemID.measureIndex`.
func measureIndex(of cursor: ScoreCursor) -> Int {
    switch cursor {
    case let .beat(measureIndex, _): measureIndex
    case let .item(id): id.measureIndex
    }
}

/// First-chord ChordPath for the given measure (`voiceIndex = 0,
/// chordIndex = 0`). The `systemIndex` is set to 0 — it's a layout-side
/// concept the engine doesn't consume here.
func snapMeasureHead(measureIndex: Int, in _: Score) -> ChordPath {
    ChordPath(systemIndex: 0, measureIndex: measureIndex, voiceIndex: 0, chordIndex: 0)
}

/// Last-chord ChordPath for the given measure. Walks voice 0 of the
/// first staff to find the maximum chord index. Returns `nil` when the
/// measure has no chords (e.g. all-rest measure, empty fixture).
func snapMeasureEnd(measureIndex: Int, in score: Score) -> ChordPath? {
    guard let part = score.parts.first,
          let staff = part.staves.first,
          staff.measures.indices.contains(measureIndex) else { return nil }
    let voice = staff.measures[measureIndex].voices.first
    guard let elements = voice?.elements else { return nil }
    var lastChordIdx: Int?
    for (idx, element) in elements.enumerated() {
        if case .chord = element { lastChordIdx = idx }
    }
    guard let chordIndex = lastChordIdx else { return nil }
    return ChordPath(
        systemIndex: 0, measureIndex: measureIndex,
        voiceIndex: 0, chordIndex: chordIndex
    )
}

/// Loop range covering the whole score, used for `.loopAll`. `nil` when
/// the score has no measures.
func scoreFullRange(in score: Score) -> ABRepeatRange? {
    guard let part = score.parts.first,
          let staff = part.staves.first,
          !staff.measures.isEmpty else { return nil }
    let lastMeasure = staff.measures.count - 1
    let start = snapMeasureHead(measureIndex: 0, in: score)
    guard let end = snapMeasureEnd(measureIndex: lastMeasure, in: score) else { return nil }
    return ABRepeatRange(start: start, end: end)
}

/// Auto-swap so `start <= end` by `(measureIndex, chordIndex)`.
func normalize(_ range: ABRepeatRange) -> ABRepeatRange {
    let s = range.start
    let e = range.end
    let key: (ChordPath) -> (Int, Int) = { ($0.measureIndex, $0.chordIndex) }
    if key(s) <= key(e) { return range }
    return ABRepeatRange(start: e, end: s)
}
```

- [ ] **Step 4: Run tests; verify they pass**

```bash
cd Packages/Features/Reader && swift test --filter RepeatLoopHelpersTests
```

Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/RepeatLoop.swift \
        Packages/Features/Reader/Tests/ReaderTests/RepeatLoopHelpersTests.swift
git commit -m "feat(reader): add measure-snap and cursor helpers for repeat loop"
```

---

## Task 5: VM repeatMode + advanceRepeatMode

Wire the persisted field through the view model. This task does **not** yet
forward `setLoopRange` to the controller — that comes in Task 7.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift` (new file, will grow over Tasks 5–9)

- [ ] **Step 1: Write the failing tests**

```swift
// Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift
import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

@Suite @MainActor
struct ReaderViewModelRepeatTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }

    private static func makeVM(
        controller: FakePlaybackController = FakePlaybackController(),
        repo: FakeScoreLibraryRepository = FakeScoreLibraryRepository()
    ) -> (ReaderViewModel, FakePlaybackController, FakeScoreLibraryRepository) {
        let item = Self.makeItem()
        repo.scoreItems = [item]
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            playbackController: controller
        )
        return (vm, controller, repo)
    }

    @Test func repeatModeDefaultsToOff() async {
        let (vm, _, _) = Self.makeVM()
        await vm.load()
        #expect(vm.repeatMode == .off)
    }

    @Test func advanceRepeatModeCyclesAndPersists() async {
        let (vm, _, repo) = Self.makeVM()
        await vm.load()

        await vm.advanceRepeatMode()
        #expect(vm.repeatMode == .loopAll)
        #expect(repo.savedReaderPreferences.last?.repeatMode == .loopAll)

        await vm.advanceRepeatMode()
        #expect(vm.repeatMode == .abLoop)
        #expect(repo.savedReaderPreferences.last?.repeatMode == .abLoop)

        await vm.advanceRepeatMode()
        #expect(vm.repeatMode == .off)
        #expect(repo.savedReaderPreferences.last?.repeatMode == .off)
    }
}
```

- [ ] **Step 2: Run tests; verify they fail**

```bash
cd Packages/Features/Reader && swift test --filter ReaderViewModelRepeatTests
```

Expected: FAIL — `vm.repeatMode` / `vm.advanceRepeatMode()` not defined.

- [ ] **Step 3: Extend `mutatePreferences` to preserve the new fields**

In `ReaderViewModel.swift` find `private func mutatePreferences(...)` and update the re-seat to forward `repeatMode` / `abRepeat`:

```swift
private func mutatePreferences(_ apply: (inout ReaderPreferences) -> Void) async {
    var copy = preferences
    apply(&copy)
    let normalized = ReaderPreferences(
        id: copy.id,
        scoreItemID: copy.scoreItemID,
        staffSize: copy.staffSize,
        hiddenStaves: copy.hiddenStaves,
        staffProgramOverrides: copy.staffProgramOverrides,
        tempoMultiplier: copy.tempoMultiplier,
        repeatMode: copy.repeatMode,
        abRepeat: copy.abRepeat
    )
    preferences = normalized
    try? await repository.saveReaderPreferences(normalized)
}
```

- [ ] **Step 4: Add the public surface to the VM**

In `ReaderViewModel.swift`, add a section near the tempo accessors (e.g. just after `setMetronomeEnabled(_:)`):

```swift
// MARK: - Repeat / loop

public var repeatMode: RepeatMode { preferences.repeatMode }
public var abRepeat: ABRepeatRange? { preferences.abRepeat }

public func advanceRepeatMode() async {
    let next = preferences.repeatMode.next
    await mutatePreferences { $0.repeatMode = next }
}
```

- [ ] **Step 5: Run tests; verify they pass**

```bash
cd Packages/Features/Reader && swift test --filter ReaderViewModelRepeatTests
```

Expected: PASS (2 tests). Also run the full Reader suite:

```bash
cd Packages/Features/Reader && swift test
```

Expected: All Reader tests green.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift
git commit -m "feat(reader): add repeatMode + advanceRepeatMode on view model"
```

---

## Task 6: VM setRepeatA / setRepeatB / clearRepeatA / clearRepeatB

The mutators that move A or B to the cursor's measure boundaries.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift`

- [ ] **Step 1: Append failing tests to the existing suite**

Append inside `ReaderViewModelRepeatTests`:

```swift
@Test func setRepeatASnapsToCursorMeasureHead() async {
    let (vm, _, repo) = Self.makeVM()
    await vm.load()
    vm.setManualCursor(.beat(measureIndex: 4, tickInMeasure: 0))

    await vm.setRepeatA()

    #expect(vm.abRepeat?.start.measureIndex == 4)
    #expect(vm.abRepeat?.start.chordIndex == 0)
    #expect(vm.abRepeat?.end == nil) // B unset
    #expect(repo.savedReaderPreferences.last?.abRepeat?.start.measureIndex == 4)
}

@Test func setRepeatBSnapsToCursorMeasureEnd() async {
    let (vm, _, _) = Self.makeVM()
    await vm.load()
    vm.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))

    await vm.setRepeatB()

    // FakeScoreFileGateway loads a 3-measure score (see fixture); m1
    // has at least one chord, so the snapped end ChordPath has
    // measureIndex == 1.
    #expect(vm.abRepeat?.end.measureIndex == 1)
}

@Test func setRepeatAReplacesPreviousAValue() async {
    let (vm, _, _) = Self.makeVM()
    await vm.load()

    vm.setManualCursor(.beat(measureIndex: 2, tickInMeasure: 0))
    await vm.setRepeatA()
    vm.setManualCursor(.beat(measureIndex: 5, tickInMeasure: 0))
    await vm.setRepeatA()

    #expect(vm.abRepeat?.start.measureIndex == 5)
}

@Test func clearRepeatARemovesStartButKeepsEnd() async {
    let (vm, _, _) = Self.makeVM()
    await vm.load()
    vm.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))
    await vm.setRepeatA()
    await vm.setRepeatB()
    #expect(vm.abRepeat != nil)

    await vm.clearRepeatA()

    // Once start is cleared and end remains, the persisted record drops
    // the range entirely (loop is incomplete) but keeps the B marker
    // for re-display via a separate `pendingB` accessor.
    #expect(vm.abRepeat == nil)
    #expect(vm.pendingRepeatB?.measureIndex == 1)
}

@Test func clearRepeatBRemovesEndButKeepsStart() async {
    let (vm, _, _) = Self.makeVM()
    await vm.load()
    vm.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))
    await vm.setRepeatA()
    await vm.setRepeatB()

    await vm.clearRepeatB()

    #expect(vm.abRepeat == nil)
    #expect(vm.pendingRepeatA?.measureIndex == 1)
}
```

**Why two pending fields:** `ABRepeatRange` requires both endpoints. To
honor "set A only without B" (or vice-versa) we keep two transient
endpoints; the persisted `abRepeat` is non-nil only when both are set.

- [ ] **Step 2: Run tests; verify they fail**

```bash
cd Packages/Features/Reader && swift test --filter ReaderViewModelRepeatTests
```

Expected: FAIL — symbols missing.

- [ ] **Step 3: Add storage + mutators to `ReaderViewModel`**

Replace the `// MARK: - Repeat / loop` section added in Task 5 with:

```swift
// MARK: - Repeat / loop

@ObservationIgnored
private var pendingA: ChordPath?
@ObservationIgnored
private var pendingB: ChordPath?

public var repeatMode: RepeatMode { preferences.repeatMode }
public var abRepeat: ABRepeatRange? { preferences.abRepeat }
public var pendingRepeatA: ChordPath? { pendingA ?? preferences.abRepeat?.start }
public var pendingRepeatB: ChordPath? { pendingB ?? preferences.abRepeat?.end }

public func advanceRepeatMode() async {
    let next = preferences.repeatMode.next
    await mutatePreferences { $0.repeatMode = next }
}

public func setRepeatA() async {
    guard case let .loaded(score) = loadState,
          let cursor = playbackCursor else { return }
    let measure = measureIndex(of: cursor)
    let head = snapMeasureHead(measureIndex: measure, in: score)
    pendingA = head
    await commitPendingRepeat()
}

public func setRepeatB() async {
    guard case let .loaded(score) = loadState,
          let cursor = playbackCursor else { return }
    let measure = measureIndex(of: cursor)
    guard let end = snapMeasureEnd(measureIndex: measure, in: score) else { return }
    pendingB = end
    await commitPendingRepeat()
}

public func clearRepeatA() async {
    pendingA = nil
    if let existing = preferences.abRepeat {
        pendingB = existing.end
    }
    await mutatePreferences { $0.abRepeat = nil }
}

public func clearRepeatB() async {
    pendingB = nil
    if let existing = preferences.abRepeat {
        pendingA = existing.start
    }
    await mutatePreferences { $0.abRepeat = nil }
}

private func commitPendingRepeat() async {
    let candidateStart = pendingA ?? preferences.abRepeat?.start
    let candidateEnd = pendingB ?? preferences.abRepeat?.end
    guard let start = candidateStart, let end = candidateEnd else {
        // Only one set so far — leave the persisted range nil.
        await mutatePreferences { $0.abRepeat = nil }
        return
    }
    let normalized = normalize(ABRepeatRange(start: start, end: end))
    pendingA = normalized.start
    pendingB = normalized.end
    await mutatePreferences { $0.abRepeat = normalized }
}
```

- [ ] **Step 4: Run tests; verify they pass**

```bash
cd Packages/Features/Reader && swift test --filter ReaderViewModelRepeatTests
```

Expected: PASS (7 tests in suite total). Also run the full Reader suite:

```bash
cd Packages/Features/Reader && swift test
```

Expected: All Reader tests green.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift
git commit -m "feat(reader): add A/B set + clear mutators on view model"
```

---

## Task 7: Forward `setLoopRange` to the controller

Whenever `repeatMode` or the markers change, the VM forwards an
`ABRepeatRange?` to the controller. The mapping (per spec):

| Mode | Forwarded value |
| --- | --- |
| `.off` | `nil` |
| `.loopAll` | `scoreFullRange(in: score)` |
| `.abLoop`, both markers set | the persisted (normalized) range |
| `.abLoop`, ≤1 marker set | `nil` |

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift`

- [ ] **Step 1: Append failing tests**

```swift
@Test func advanceRepeatModeForwardsLoopRange() async {
    let (vm, controller, _) = Self.makeVM()
    await vm.load()

    await vm.advanceRepeatMode() // .off -> .loopAll
    #expect(controller.loopRangeCalls.last??.start.measureIndex == 0)

    await vm.advanceRepeatMode() // .loopAll -> .abLoop with no markers
    #expect(controller.loopRangeCalls.last == .some(nil))

    await vm.advanceRepeatMode() // .abLoop -> .off
    #expect(controller.loopRangeCalls.last == .some(nil))
}

@Test func setRepeatAOnlyDoesNotForwardLoopRangeYet() async {
    let (vm, controller, _) = Self.makeVM()
    await vm.load()
    await vm.advanceRepeatMode() // .loopAll
    await vm.advanceRepeatMode() // .abLoop
    let countBefore = controller.loopRangeCalls.count
    vm.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))

    await vm.setRepeatA()

    // One additional call recorded, value is `nil` (B still unset).
    #expect(controller.loopRangeCalls.count == countBefore + 1)
    #expect(controller.loopRangeCalls.last == .some(nil))
}

@Test func bothMarkersSetForwardsTheNormalizedRange() async {
    let (vm, controller, _) = Self.makeVM()
    await vm.load()
    await vm.advanceRepeatMode() // .loopAll
    await vm.advanceRepeatMode() // .abLoop
    vm.setManualCursor(.beat(measureIndex: 2, tickInMeasure: 0))
    await vm.setRepeatA()
    vm.setManualCursor(.beat(measureIndex: 0, tickInMeasure: 0))

    await vm.setRepeatB()

    // Auto-swap: B at m0 + A at m2 -> normalized start=m0, end=m2.
    let last = controller.loopRangeCalls.last??
    #expect(last?.start.measureIndex == 0)
    #expect(last?.end.measureIndex == 2)
}
```

(`controller.loopRangeCalls.last??` peels both Optionals — outer is "no
calls recorded yet," inner is "called with `nil`." When both unwrap, you
get an `ABRepeatRange`.)

- [ ] **Step 2: Run tests; verify they fail**

```bash
cd Packages/Features/Reader && swift test --filter ReaderViewModelRepeatTests
```

Expected: FAIL — controller never receives the ranges.

- [ ] **Step 3: Add the forwarding logic**

In `ReaderViewModel.swift`, add a private helper just below
`commitPendingRepeat`:

```swift
private func forwardLoopRangeToController() async {
    guard let controller = playbackController,
          case let .loaded(score) = loadState else { return }
    let range: ABRepeatRange? = {
        switch preferences.repeatMode {
        case .off:
            return nil
        case .loopAll:
            return scoreFullRange(in: score)
        case .abLoop:
            return preferences.abRepeat
        }
    }()
    await controller.setLoopRange(range)
}
```

Then call it from each of the four mutators *and* from `advanceRepeatMode`
right after the persisted state is updated:

```swift
public func advanceRepeatMode() async {
    let next = preferences.repeatMode.next
    await mutatePreferences { $0.repeatMode = next }
    await forwardLoopRangeToController()
}

public func setRepeatA() async {
    guard case let .loaded(score) = loadState,
          let cursor = playbackCursor else { return }
    let measure = measureIndex(of: cursor)
    let head = snapMeasureHead(measureIndex: measure, in: score)
    pendingA = head
    await commitPendingRepeat()
    await forwardLoopRangeToController()
}

public func setRepeatB() async {
    guard case let .loaded(score) = loadState,
          let cursor = playbackCursor else { return }
    let measure = measureIndex(of: cursor)
    guard let end = snapMeasureEnd(measureIndex: measure, in: score) else { return }
    pendingB = end
    await commitPendingRepeat()
    await forwardLoopRangeToController()
}

public func clearRepeatA() async {
    pendingA = nil
    if let existing = preferences.abRepeat {
        pendingB = existing.end
    }
    await mutatePreferences { $0.abRepeat = nil }
    await forwardLoopRangeToController()
}

public func clearRepeatB() async {
    pendingB = nil
    if let existing = preferences.abRepeat {
        pendingA = existing.start
    }
    await mutatePreferences { $0.abRepeat = nil }
    await forwardLoopRangeToController()
}
```

- [ ] **Step 4: Run tests; verify they pass**

```bash
cd Packages/Features/Reader && swift test --filter ReaderViewModelRepeatTests
```

Expected: PASS (10 tests in suite total).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift
git commit -m "feat(reader): forward effective loop range to playback controller"
```

---

## Task 8: Cursor-driven loop wrap

When the cursor crosses past the loop end *during playback*, seek to the
loop start. Manual cursor moves while paused are exempt — the gate is
`isPlaying`.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift`

- [ ] **Step 1: Append failing tests**

```swift
@Test func cursorPastEndDuringPlaybackSeeksToStartOfA() async throws {
    let (vm, controller, _) = Self.makeVM()
    await vm.load()
    await vm.advanceRepeatMode() // .loopAll
    await vm.advanceRepeatMode() // .abLoop
    vm.setManualCursor(.beat(measureIndex: 0, tickInMeasure: 0))
    await vm.setRepeatA()
    vm.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))
    await vm.setRepeatB()
    vm.startObservingCursor()

    // Begin playback so the wrap gate (`isPlaying`) opens.
    await vm.togglePlayback()
    let setCursorCountBefore = controller.recordedSetCursorCalls.count

    // Engine emits a cursor in m=2 — past the loop end of m=1.
    controller.emitCursor(.beat(measureIndex: 2, tickInMeasure: 0))
    await Task.yield()

    let lastSeek = controller.recordedSetCursorCalls.last
    #expect(controller.recordedSetCursorCalls.count == setCursorCountBefore + 1)
    if case let .beat(measureIndex, tick) = lastSeek {
        #expect(measureIndex == 0)
        #expect(tick == 0)
    } else {
        Issue.record("expected a .beat cursor seek")
    }
}

@Test func cursorWithinLoopDoesNotTriggerSeek() async {
    let (vm, controller, _) = Self.makeVM()
    await vm.load()
    await vm.advanceRepeatMode()
    await vm.advanceRepeatMode()
    vm.setManualCursor(.beat(measureIndex: 0, tickInMeasure: 0))
    await vm.setRepeatA()
    vm.setManualCursor(.beat(measureIndex: 2, tickInMeasure: 0))
    await vm.setRepeatB()
    vm.startObservingCursor()
    await vm.togglePlayback()
    let setCursorCountBefore = controller.recordedSetCursorCalls.count

    controller.emitCursor(.beat(measureIndex: 1, tickInMeasure: 240))
    await Task.yield()

    #expect(controller.recordedSetCursorCalls.count == setCursorCountBefore)
}

@Test func cursorWrapDoesNotFireWhilePaused() async {
    let (vm, controller, _) = Self.makeVM()
    await vm.load()
    await vm.advanceRepeatMode()
    await vm.advanceRepeatMode()
    vm.setManualCursor(.beat(measureIndex: 0, tickInMeasure: 0))
    await vm.setRepeatA()
    vm.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))
    await vm.setRepeatB()
    vm.startObservingCursor()
    // Note: NOT calling togglePlayback — isPlaying stays false.
    let before = controller.recordedSetCursorCalls.count

    controller.emitCursor(.beat(measureIndex: 2, tickInMeasure: 0))
    await Task.yield()

    #expect(controller.recordedSetCursorCalls.count == before)
}

@Test func nilCursorDuringLoopAllPlaybackWrapsToStart() async {
    let (vm, controller, _) = Self.makeVM()
    await vm.load()
    await vm.advanceRepeatMode() // .loopAll
    vm.startObservingCursor()
    await vm.togglePlayback()
    let before = controller.recordedSetCursorCalls.count

    // Engine signals end of score by nilling the cursor.
    controller.emitCursor(nil)
    await Task.yield()

    #expect(controller.recordedSetCursorCalls.count == before + 1)
    if case let .beat(measureIndex, _) = controller.recordedSetCursorCalls.last {
        #expect(measureIndex == 0)
    } else {
        Issue.record("expected a .beat cursor seek to measure 0")
    }
}
```

- [ ] **Step 2: Run tests; verify they fail**

```bash
cd Packages/Features/Reader && swift test --filter ReaderViewModelRepeatTests
```

Expected: FAIL — wrap logic not yet present.

- [ ] **Step 3: Wire the wrap into `startObservingCursor`**

Find the existing `startObservingCursor()` in `ReaderViewModel.swift` and replace its body:

```swift
public func startObservingCursor() {
    guard let controller = playbackController else { return }
    controller.observeCursor { [weak self] value in
        guard let self else { return }
        self.playbackCursor = value
        self.evaluateLoopWrap(for: value)
    }
}
```

Then add the evaluator below `forwardLoopRangeToController()`:

```swift
private func evaluateLoopWrap(for cursor: ScoreCursor?) {
    guard isPlaying,
          case let .loaded(score) = loadState else { return }

    let active: ABRepeatRange?
    switch preferences.repeatMode {
    case .off:
        active = nil
    case .loopAll:
        active = scoreFullRange(in: score)
    case .abLoop:
        active = preferences.abRepeat
    }
    guard let range = active else { return }

    // Treat a nil cursor while we believe ourselves to be playing as a
    // natural-end signal: wrap to the loop start.
    if cursor == nil {
        seekToLoopStart(range)
        return
    }
    if let cursor, measureIndex(of: cursor) > range.end.measureIndex {
        seekToLoopStart(range)
    }
}

private func seekToLoopStart(_ range: ABRepeatRange) {
    let startCursor = ScoreCursor.beat(
        measureIndex: range.start.measureIndex, tickInMeasure: 0
    )
    setManualCursor(startCursor)
}
```

- [ ] **Step 4: Run tests; verify they pass**

```bash
cd Packages/Features/Reader && swift test --filter ReaderViewModelRepeatTests
```

Expected: PASS (14 tests in suite total).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift
git commit -m "feat(reader): seek back to loop start when cursor exits range"
```

---

## Task 9: Pre-seek to A when cursor > B at play press

Per the spec: when the user presses play with the cursor already past the
loop end, the engine should jump to A immediately rather than playing
through to the score end.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift`

- [ ] **Step 1: Append failing test**

```swift
@Test func togglePlaybackPreSeeksToAWhenCursorAlreadyPastB() async {
    let (vm, controller, _) = Self.makeVM()
    await vm.load()
    await vm.advanceRepeatMode()
    await vm.advanceRepeatMode()
    vm.setManualCursor(.beat(measureIndex: 0, tickInMeasure: 0))
    await vm.setRepeatA()
    vm.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))
    await vm.setRepeatB()

    // Move cursor past B before pressing play.
    vm.setManualCursor(.beat(measureIndex: 5, tickInMeasure: 0))
    let preSeekCount = controller.recordedSetCursorCalls.count

    await vm.togglePlayback()

    let last = controller.recordedSetCursorCalls.last
    #expect(controller.recordedSetCursorCalls.count >= preSeekCount + 1)
    if case let .beat(measureIndex, _) = last {
        #expect(measureIndex == 0) // start of A
    } else {
        Issue.record("expected pre-seek to A's measure")
    }
    #expect(controller.playCount == 1)
}
```

- [ ] **Step 2: Run tests; verify they fail**

```bash
cd Packages/Features/Reader && swift test --filter ReaderViewModelRepeatTests
```

Expected: FAIL — pre-seek not present.

- [ ] **Step 3: Add the pre-seek to `togglePlayback`**

Find the play branch of `togglePlayback()` in `ReaderViewModel.swift`. Right before `try await controller.play()`, insert:

```swift
preSeekIfNeeded(controller: controller, score: score)
```

Then add the helper near `evaluateLoopWrap`:

```swift
private func preSeekIfNeeded(controller: any PlaybackController, score: Score) {
    let active: ABRepeatRange?
    switch preferences.repeatMode {
    case .off: active = nil
    case .loopAll: active = scoreFullRange(in: score)
    case .abLoop: active = preferences.abRepeat
    }
    guard let range = active,
          let cursor = playbackCursor,
          measureIndex(of: cursor) > range.end.measureIndex else { return }
    let target = ScoreCursor.beat(
        measureIndex: range.start.measureIndex, tickInMeasure: 0
    )
    Task { await controller.setCursor(to: target) }
    playbackCursor = target
}
```

(The `Task` hop matches the existing `setManualCursor` pattern — the
controller's `setCursor` is `async`, but we want play() to fire
immediately afterward so the engine seeks then starts.)

- [ ] **Step 4: Run tests; verify they pass**

```bash
cd Packages/Features/Reader && swift test --filter ReaderViewModelRepeatTests
```

Expected: PASS (15 tests in suite total).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift
git commit -m "feat(reader): pre-seek to loop start when cursor past loop end on play"
```

---

## Task 10: Seed `abRepeat` into the engine on initial load

`initialPlaybackPreferences(for:)` currently passes `abRepeat: nil`. With
markers persisted, we should pass the saved range so the engine sees the
loop on the very first frame after load.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift`

- [ ] **Step 1: Append failing test**

```swift
@Test func persistedAbRepeatIsSeededIntoControllerOnPlaybackPrep() async {
    let item = Self.makeItem()
    let repo = FakeScoreLibraryRepository()
    repo.scoreItems = [item]
    let chord = ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 0)
    let endChord = ChordPath(systemIndex: 0, measureIndex: 2, voiceIndex: 0, chordIndex: 0)
    let stored = ReaderPreferences(
        scoreItemID: item.id,
        staffSize: 14,
        hiddenStaves: [],
        repeatMode: .abLoop,
        abRepeat: ABRepeatRange(start: chord, end: endChord)
    )
    repo.storedReaderPreferences[item.id] = stored
    let controller = FakePlaybackController()
    let vm = ReaderViewModel(
        scoreItem: item,
        repository: repo,
        gateway: FakeScoreFileGateway(),
        scoresDirectory: URL(filePath: "/tmp"),
        playbackController: controller
    )

    await vm.load()
    await vm.prepareForPlayback()

    #expect(controller.lastLoadedPreferences?.abRepeat?.start == chord)
    #expect(controller.lastLoadedPreferences?.abRepeat?.end == endChord)
}
```

- [ ] **Step 2: Run tests; verify they fail**

```bash
cd Packages/Features/Reader && swift test --filter ReaderViewModelRepeatTests
```

Expected: FAIL — `abRepeat` is still `nil`.

- [ ] **Step 3: Update `initialPlaybackPreferences`**

In `ReaderViewModel.swift`, change the `PlaybackPreferences` init at the end of `initialPlaybackPreferences(for:)`:

```swift
return PlaybackPreferences(
    scoreItemID: scoreItem.id,
    perStaff: states,
    tempoMultiplier: preferences.tempoMultiplier ?? 1.0,
    abRepeat: preferences.abRepeat
)
```

- [ ] **Step 4: Run tests; verify they pass**

```bash
cd Packages/Features/Reader && swift test --filter ReaderViewModelRepeatTests
```

Expected: PASS (16 tests in suite total).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelRepeatTests.swift
git commit -m "feat(reader): seed persisted abRepeat into engine on load"
```

---

## Task 11: `RepeatModeButton` view + Inspector slot

The 3-state cycle button. SF Symbols composition is finalized inline; the
contract is "three readable states."

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/RepeatModeButton.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/InspectorView.swift`

- [ ] **Step 1: Create the button view**

```swift
// Packages/Features/Reader/Sources/Reader/RepeatModeButton.swift
import Domain
import SwiftUI

struct RepeatModeButton: View {
    let mode: RepeatMode
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .padding(.horizontal, 4)
                .symbolVariant(mode == .off ? .none : .fill)
                .accessibilityLabel(label)
        }
        .accessibilityValue(value)
    }

    private var symbol: String {
        switch mode {
        case .off, .loopAll: return "repeat"
        case .abLoop: return "repeat.1" // overlaid via .badge below if needed
        }
    }

    private var tint: Color {
        mode == .off ? .secondary : .accentColor
    }

    private var label: String {
        String(localized: "Repeat")
    }

    private var value: String {
        switch mode {
        case .off: return String(localized: "Off")
        case .loopAll: return String(localized: "Loop all")
        case .abLoop: return String(localized: "A–B section")
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        RepeatModeButton(mode: .off) {}
        RepeatModeButton(mode: .loopAll) {}
        RepeatModeButton(mode: .abLoop) {}
    }
    .padding()
}
```

(The `repeat.1` choice is a stand-in. Refine the icon at preview time —
acceptable to use a custom overlay with a small "A·B" badge. The
contract is three visually distinct states.)

- [ ] **Step 2: Add the button to `InspectorView`**

Open `InspectorView.swift`, find `tempoControls` (the `HStack` containing
the metronome / percent label / slider), and append the `RepeatModeButton`
to the trailing edge of that HStack:

```swift
@ViewBuilder
private var tempoControls: some View {
    HStack(spacing: 8) {
        Button { /* metronome toggle … existing */ } label: { /* … */ }
        Button { /* percent reset … existing */ } label: { /* … */ }
        Slider(/* … existing */)

        RepeatModeButton(mode: viewModel.repeatMode) {
            await viewModel.advanceRepeatMode()
        }
    }
}
```

(Leave the existing widgets untouched — only append the new button.)

- [ ] **Step 3: Build and preview**

Build the Reader package and confirm the button compiles:

```bash
cd Packages/Features/Reader && swift build
```

Expected: build succeeds. Open `RepeatModeButton.swift` in Xcode and
confirm the three-state preview renders.

- [ ] **Step 4: Verify test suite still green**

```bash
cd Packages/Features/Reader && swift test
```

Expected: All Reader tests green.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/RepeatModeButton.swift \
        Packages/Features/Reader/Sources/Reader/InspectorView.swift
git commit -m "feat(reader): add repeat mode cycle button to inspector"
```

---

## Task 12: `ABPill` view + bottom-overlay slot

Bottom-right liquid-glass pill, gated on `repeatMode == .abLoop`. Tap to
set / overwrite, long-press to clear. Subtitle shows `m. N` when set.

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/ABPill.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderToolbar.swift` (the `ReaderBottomOverlay` struct lives there)

- [ ] **Step 1: Create the pill**

```swift
// Packages/Features/Reader/Sources/Reader/ABPill.swift
import Domain
import SwiftUI

struct ABPill: View {
    @Bindable var viewModel: ReaderViewModel

    var body: some View {
        HStack(spacing: 0) {
            endpointButton(
                label: "A",
                measureIndex: viewModel.pendingRepeatA?.measureIndex,
                onSet: { Task { await viewModel.setRepeatA() } },
                onClear: { Task { await viewModel.clearRepeatA() } }
            )
            Divider().frame(height: 24)
            endpointButton(
                label: "B",
                measureIndex: viewModel.pendingRepeatB?.measureIndex,
                onSet: { Task { await viewModel.setRepeatB() } },
                onClear: { Task { await viewModel.clearRepeatB() } }
            )
        }
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("A–B repeat markers")
    }

    @ViewBuilder
    private func endpointButton(
        label: String,
        measureIndex: Int?,
        onSet: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) -> some View {
        Button(action: onSet) {
            VStack(spacing: 0) {
                Text(label)
                    .font(.callout.bold())
                    .foregroundStyle(measureIndex == nil ? Color.secondary : Color.accentColor)
                Text(measureIndex.map { "m. \($0 + 1)" } ?? " ")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 44)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityValue(
            measureIndex.map { "Set to measure \($0 + 1)" } ?? "Not set"
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in onClear() }
        )
    }
}
```

(Measure numbers are 1-based in the UI — index 0 displays as "m. 1".
Liquid glass uses `ultraThinMaterial` for now; swap to a richer iOS 26
material if available at preview time.)

- [ ] **Step 2: Wire into `ReaderBottomOverlay`**

Open `ReaderToolbar.swift` and replace the `ReaderBottomOverlay` body:

```swift
struct ReaderBottomOverlay: View {
    @Bindable var viewModel: ReaderViewModel

    var body: some View {
        HStack {
            if viewModel.viewportZoom > 1.0 {
                Button {
                    viewModel.resetZoom()
                } label: {
                    Label("Reset zoom", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            Spacer()
            if viewModel.repeatMode == .abLoop {
                ABPill(viewModel: viewModel)
            }
        }
        .padding()
    }
}
```

- [ ] **Step 3: Build**

```bash
cd Packages/Features/Reader && swift build
```

Expected: build succeeds.

- [ ] **Step 4: Verify the suite is still green**

```bash
cd Packages/Features/Reader && swift test
```

Expected: All Reader tests green.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ABPill.swift \
        Packages/Features/Reader/Sources/Reader/ReaderToolbar.swift
git commit -m "feat(reader): add A/B pill overlay for section repeat"
```

---

## Task 13: Manual verification

Build the app and exercise the feature end-to-end. Previews handle the
chrome; the simulator handles cursor wrapping during real playback.

- [ ] **Step 1: Build the app**

```bash
xcodegen generate
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build
```

Expected: build succeeds.

- [ ] **Step 2: Install and launch on simulator**

Use the existing project workflow (open Xcode, run on iPhone 16
Simulator, or via `xcrun simctl install` + `launch`).

- [ ] **Step 3: Walk through the smoke checks**

Open a multi-measure score. For each step verify by eye:

1. Open Inspector. The repeat cycle button is in the Playback section near tempo / metronome. It starts in `.off` state (secondary tint).
2. Tap the cycle button — accent tint, "Loop all" announced. The A/B pill is **not** yet visible.
3. Tap once more — accent tint with the A·B treatment. The A/B pill appears bottom-right.
4. Place the cursor in measure 4 (tap a chord there). Tap `A`. Pill subtitle shows `m. 4`.
5. Place the cursor in measure 8. Tap `B`. Pill subtitle shows `m. 8`.
6. Press play. Verify the cursor reaches measure 8 then jumps back to measure 4 and continues looping.
7. While playing, tap `A` while the cursor is in measure 6. The pill updates to `m. 6`; loop now plays measures 6–8.
8. Long-press `A`. Pill shows blank under `A`; loop becomes inactive (cursor plays through).
9. Cycle the mode back to `.off` via the inspector. Pill disappears. Markers persist (cycle back to `.abLoop` and confirm the previously-set A is still present).
10. Close and reopen the score. Confirm `repeatMode` and the A marker survived.

- [ ] **Step 4: If any check fails**

File a bug, tighten the failing test, and reopen the relevant task. Do
not declare done.

- [ ] **Step 5: Commit any tweaks**

```bash
git status
# If anything changed during verification, stage whole files and commit.
```

---

## Out of scope for v1 (follow-up work)

- **Score-overlay loop band** (the translucent accent band over measures).
  Requires either an upstream `swift-sheet-music` API exposing measure
  rects, or a SwiftUI overlay built on a published `LayoutDocument`
  surface. Track as a separate plan.
- **Engine-level loop primitive** in `swift-sheet-music`. The VM-layer
  wrap is precise enough for practice (sub-measure latency dominated by
  the engine's `play(from:in:)` start-up), but a dedicated loop primitive
  would be lower-jitter.
- **First-run discoverability callout** for the cycle button on iPhone
  compact. Revisit with telemetry.

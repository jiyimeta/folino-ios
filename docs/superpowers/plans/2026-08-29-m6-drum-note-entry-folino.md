# M6 drum note entry — Folino half (§5.4 + §5.1–5.6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a percussion staff editable from the note-input pad — a column caret shared by pitched and drum
staves, and a configurable drum key layout that writes each instrument into its own voice.

**Architecture:** Everything that decides anything lives in `EditorCore`, which Android links too (spec §8): the
column stepper, `GMDrumset`-backed `DrumPadKey` / `DrumPadLayout`, the voice presets, and the write resolution of
§5.5. Only the SwiftUI pad is iOS-only, and it gets a `PARITY(android):` marker. The caret keeps its rendered
type (`ScoreItemID`) — spec §5.4 says the caret is *drawn at the write destination*, so what changes is where
stepping may land and which voice a write goes to, not what the host renders.

**Tech Stack:** Swift 6.3, SwiftUI, Swift Testing, `EditorCore` (Foundation + Domain + `SheetMusicCore`),
swift-sheet-music's `GMDrumset` / `CreateVoice` / `SplitRest` / `SetNoteHead` (landed 2026-08-29, this branch).

**Spec:** `docs/superpowers/specs/2026-08-12-drum-note-entry-design.md` (§5.1–5.6, §8, §10). The ssm half is
`docs/superpowers/plans/2026-08-29-m6-drum-note-entry-ssm.md`, already implemented.

## Global Constraints

- **Worktree pair.** Folino `.claude/worktrees/scratch-creation-spec` (branch `worktree-scratch-creation-spec`),
  path-pinned to ssm `~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music` (branch
  `feature/scratch-creation-m1`). The pin's six files stay UNCOMMITTED, and the two `ScoreUI` dependency lines in
  `Packages/Features/Editor/Package.swift` / `Packages/Features/Library/Package.swift` ride with them.
- **Deployment floor iOS 18.0.** No raw iOS-26 API — go through `Packages/Utility/Sources/UtilityUI/GlassEffectCompat.swift`.
- **Internal feature names never appear in user-facing copy**, and the app is lowercase `folino` to users.
- **Everything that decides goes in `EditorCore`.** A decision written as an `EditorViewModel` method is a decision
  Android has to write a second time — the failure mode spec §8 exists to prevent.
- **New tests are Swift Testing.** `import Testing`, `@Suite`, `@Test`, `#expect`.
- **Gates:**
  `env -C Packages/Features/Editor xcodebuild test -scheme Editor-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`
  and the app's own
  `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation test`.
- **Comment style:** reflow `//` and `///` at 120 columns. **`public` is a decision** — no modifier until
  something outside the module needs it.
- **SwiftLint budgets are real here:** `EditorViewModel.swift` sits at 384/400 lines and `EditorSessionCore.swift`
  at 349/400. Add new surface in new files, not to those two.

---

## Scope

**In:** spec §5.4 (column caret), §5.2/§5.3/§5.5/§5.6 (the drum key model, the pad, the write resolution, layout
editing), §5.1 (entering drum mode), and the parity marker §8 requires.

**Out:** accents / ghost notes / flams, moving ← / → into the pad, creating a drum part from scratch, and the
Compose pad — all four are out by the spec's own §3, and the last one is the deferred half the parity marker
records.

---

## File structure

**Created**

| Path | Responsibility |
| --- | --- |
| `Packages/Features/Editor/Sources/EditorCore/ColumnNavigation.swift` | The column: every onset at a tick across a staff's voices, and the step to the next/previous one |
| `Packages/Features/Editor/Sources/EditorCore/DrumPadLayout.swift` | `DrumPadKey`, `DrumPadLayout`, the two voice presets, and the preset a score's own bars imply |
| `Packages/Features/Editor/Sources/EditorCore/EditorSessionCore+Drums.swift` | Is this staff a drum staff, which keys are lit in the caret's column, and what a key press resolves to |
| `Packages/Features/Editor/Sources/Editor/Views/EditorDrumPadRows.swift` | The two instrument rows and one key's face |
| `Packages/Features/Editor/Sources/Editor/Views/EditorDrumLayoutSheet.swift` | Editing the layout: reorder, re-instrument, voice badge, row count, presets |
| `Packages/Features/Editor/Sources/Editor/DrumPadLayoutStore.swift` | `UserDefaults` persistence, read once into local state — never through `@AppStorage` |
| `Packages/Features/Editor/Tests/EditorCoreTests/ColumnNavigationTests.swift` | Column stepping across voices, and armed-duration stepping through an empty bar |
| `Packages/Features/Editor/Tests/EditorCoreTests/DrumPadLayoutTests.swift` | Defaults, presets, the preset a score implies |
| `Packages/Features/Editor/Tests/EditorCoreTests/DrumInputTests.swift` | All four branches of §5.5 step 4, plus voice creation, drumset repair and one-tap-one-undo |

**Modified**

| Path | Change |
| --- | --- |
| `EditorCore/EditorSessionCore.swift` | `drumPadLayout` state |
| `EditorCore/EditorSessionCore+Navigation.swift` | ← / → step the column |
| `EditorCore/EditorSessionCore+Input.swift` | Pitched writes go to `activeVoice` |
| `Editor/EditorViewModel+Ops.swift` | Forwarders for the drum ops |
| `Editor/Views/EditorPadView.swift` | Swap the lower rows when the caret's staff is a drum staff |
| `Editor/Resources/Localizable.xcstrings` | Drum key names and the layout sheet's copy, 5 languages |
| `docs/engineering/ios-android-parity.md` | Regenerated from the new marker |

---

## Task 1: the column — every onset at a tick, across a staff's voices

Spec §5.4. A column is `(staff, measureIndex, tick)`. This task builds the pure functions that answer "what is at
this column?" and "where is the next one?", with no session state involved, so they can be tested alone and reused
by both the stepper and the drum write.

**Files:**
- Create: `Packages/Features/Editor/Sources/EditorCore/ColumnNavigation.swift`
- Create: `Packages/Features/Editor/Tests/EditorCoreTests/ColumnNavigationTests.swift`

**Interfaces:**
- Consumes: `SheetMusicCore.Score`, `VoiceElementID`, `NoteDuration`, `DurationChangeAlgorithm.tickOffset(in:ofElementAt:division:)`.
- Produces:
  - `public struct ScoreColumn: Sendable, Equatable` — `staff: StaffAddress`, `measureIndex: Int`, `tick: Int`.
  - `public enum ColumnNavigation` with
    `public static func column(of slot: VoiceElementID, in score: Score) -> ScoreColumn?`,
    `public static func slot(inVoice voiceIndex: Int, at column: ScoreColumn, in score: Score) -> (slot: VoiceElementID, tickWithinSlot: Int)?`,
    `public static func next(after column: ScoreColumn, in score: Score, steppingBy armed: NoteDuration?) -> ScoreColumn?`,
    `public static func previous(before column: ScoreColumn, in score: Score) -> ScoreColumn?`.

- [ ] **Step 1: Write the failing test**

Create `Packages/Features/Editor/Tests/EditorCoreTests/ColumnNavigationTests.swift`:

```swift
@testable import EditorCore
import SheetMusicCore
import Testing

@Suite("ColumnNavigation")
struct ColumnNavigationTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    /// One 4/4 bar on one staff: voice 0 is four quarters, voice 1 is a half then two quarters — so the two voices
    /// share onsets at ticks 0 and 960 and disagree at 480 and 1440.
    private static func twoVoiceBar() -> Score {
        let voice0 = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .quarter), .rest(duration: .quarter),
            .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        let voice1 = Voice(elements: [
            .rest(duration: .half), .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        let staffValue = Staff(measures: [Measure(voices: [voice0, voice1])])
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staffValue])
        return Score(division: 480, parts: [part])
    }

    private static func slot(voice: Int, element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: voice, elementIndex: element)
    }

    @Test("a slot reports the column it sits in")
    func columnOfSlot() {
        let score = Self.twoVoiceBar()
        #expect(ColumnNavigation.column(of: Self.slot(voice: 0, element: 3), in: score)
            == ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 960))
        // Voice 1's half rest opens the bar, so its second element starts at the half-way tick too.
        #expect(ColumnNavigation.column(of: Self.slot(voice: 1, element: 1), in: score)
            == ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 960))
    }

    @Test("a column resolves to the slot each voice has covering it")
    func slotInVoice() {
        let score = Self.twoVoiceBar()
        let column = ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 480)
        // Voice 0 has an onset exactly there; voice 1 is halfway through its opening half rest.
        #expect(ColumnNavigation.slot(inVoice: 0, at: column, in: score)?.slot == Self.slot(voice: 0, element: 2))
        #expect(ColumnNavigation.slot(inVoice: 0, at: column, in: score)?.tickWithinSlot == 0)
        #expect(ColumnNavigation.slot(inVoice: 1, at: column, in: score)?.slot == Self.slot(voice: 1, element: 0))
        #expect(ColumnNavigation.slot(inVoice: 1, at: column, in: score)?.tickWithinSlot == 480)
    }

    @Test("a voice the measure does not have resolves to nothing")
    func slotInMissingVoice() {
        let score = Self.twoVoiceBar()
        let column = ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 0)
        #expect(ColumnNavigation.slot(inVoice: 2, at: column, in: score) == nil)
    }

    @Test("→ stops at the next onset in ANY voice")
    func nextCrossesVoices() {
        let score = Self.twoVoiceBar()
        var column = ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 0)
        var visited: [Int] = []
        while let next = ColumnNavigation.next(after: column, in: score, steppingBy: nil), next.measureIndex == 0 {
            visited.append(next.tick)
            column = next
        }
        // Voice 0's onsets are 0/480/960/1440 and voice 1's are 0/960/1440 — the union, in order.
        #expect(visited == [480, 960, 1440])
    }

    @Test("← walks the same union backwards")
    func previousCrossesVoices() {
        let score = Self.twoVoiceBar()
        let column = ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 960)
        #expect(ColumnNavigation.previous(before: column, in: score)?.tick == 480)
    }

    @Test("→ continues into the next measure")
    func nextCrossesTheBarline() {
        var score = Self.twoVoiceBar()
        score.parts[0].staves[0].measures.append(Measure(voices: [
            Voice(elements: [.rest(duration: .whole)]),
        ]))
        let last = ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 1440)
        let next = ColumnNavigation.next(after: last, in: score, steppingBy: nil)
        #expect(next == ScoreColumn(staff: Self.staff, measureIndex: 1, tick: 0))
    }

    /// The rule that makes an empty bar enterable: a measure rest has ONE onset, at tick 0, so without this → would
    /// jump the whole bar and there would be no way to reach beat 2 of an empty measure at all.
    @Test("with nothing ahead in the bar, → steps by the armed duration")
    func nextFallsBackToTheArmedDuration() {
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .measure),
        ])
        let staffValue = Staff(measures: [Measure(voices: [voice])])
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staffValue])
        let score = Score(division: 480, parts: [part])

        let start = ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 0)
        #expect(ColumnNavigation.next(after: start, in: score, steppingBy: .quarter)?.tick == 480)
        // And it stops at the barline rather than stepping past the bar's own length.
        let last = ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 1440)
        #expect(ColumnNavigation.next(after: last, in: score, steppingBy: .quarter) == nil)
    }

    @Test("the end of the staff has nowhere to go")
    func nextAtTheEnd() {
        let score = Self.twoVoiceBar()
        let last = ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 1440)
        #expect(ColumnNavigation.next(after: last, in: score, steppingBy: nil) == nil)
        let first = ScoreColumn(staff: Self.staff, measureIndex: 0, tick: 0)
        #expect(ColumnNavigation.previous(before: first, in: score) == nil)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `env -C Packages/Features/Editor xcodebuild test -scheme Editor-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:EditorCoreTests/ColumnNavigationTests`
Expected: FAIL to build — "cannot find 'ColumnNavigation' in scope".

- [ ] **Step 3: Write `ColumnNavigation.swift`**

```swift
import Foundation
import SheetMusicCore

/// A vertical slice through one staff at one moment: which bar, and how far into it. The caret's real position
/// once it stops belonging to a voice (spec §5.4).
///
/// Ticks, not element indices, because that is the only address the voices of a bar agree on: voice 1's "beat 3"
/// and voice 2's are the same tick and almost never the same element index.
public struct ScoreColumn: Sendable, Equatable {
    public var staff: StaffAddress
    public var measureIndex: Int
    public var tick: Int

    public init(staff: StaffAddress, measureIndex: Int, tick: Int) {
        self.staff = staff
        self.measureIndex = measureIndex
        self.tick = tick
    }
}

/// Reading a staff as columns: where a slot sits, what covers a column in a given voice, and how to step.
///
/// Pure functions over a `Score` — no session state — so both the ← / → keys and the drum write resolution can ask
/// the same questions, and Android gets the same answers by linking the same target.
public enum ColumnNavigation {
    /// The column `slot` begins at, or `nil` when the address names nothing.
    public static func column(of slot: VoiceElementID, in score: Score) -> ScoreColumn? {
        guard let voice = voice(at: slot, in: score), voice.elements.indices.contains(slot.elementIndex) else {
            return nil
        }
        return ScoreColumn(
            staff: slot.staff,
            measureIndex: slot.measureIndex,
            tick: DurationChangeAlgorithm.tickOffset(
                in: voice, ofElementAt: slot.elementIndex, division: score.division,
            ),
        )
    }

    /// The slot in `voiceIndex` that COVERS `column`, and how far into that slot the column falls.
    ///
    /// A non-zero `tickWithinSlot` is the "landed mid-rest" case: the caller splits the rest there before writing.
    /// `nil` when the measure has no such voice — which is what tells a drum key to create one.
    public static func slot(
        inVoice voiceIndex: Int, at column: ScoreColumn, in score: Score,
    ) -> (slot: VoiceElementID, tickWithinSlot: Int)? {
        let address = VoiceElementID(
            staff: column.staff, measureIndex: column.measureIndex, voiceIndex: voiceIndex, elementIndex: 0,
        )
        guard let voice = voice(at: address, in: score) else { return nil }
        let measureTicks = measureTicks(column.measureIndex, on: column.staff, in: score)
        var tick = 0
        for (index, element) in voice.elements.enumerated() {
            guard case let .chord(chord) = element else { continue }
            let length = chord.duration.resolved(in: measureTicks.duration).ticks(division: score.division)
            if column.tick < tick + length {
                return (
                    VoiceElementID(
                        staff: column.staff, measureIndex: column.measureIndex,
                        voiceIndex: voiceIndex, elementIndex: index,
                    ),
                    column.tick - tick
                )
            }
            tick += length
        }
        return nil
    }

    /// The next column at or after `column`, walking into the following bar when this one is spent.
    ///
    /// `steppingBy` is the fallback when no voice has an onset ahead in this bar — an empty measure holds a single
    /// measure rest, whose only onset is tick 0, so without it → would jump the whole bar and beat 2 of an empty bar
    /// would be unreachable. The fallback never steps past the barline; the bar's end is the following bar's tick 0.
    public static func next(
        after column: ScoreColumn, in score: Score, steppingBy armed: NoteDuration?,
    ) -> ScoreColumn? {
        let onsets = onsetTicks(in: column.measureIndex, on: column.staff, in: score)
        if let ahead = onsets.first(where: { $0 > column.tick }) {
            return ScoreColumn(staff: column.staff, measureIndex: column.measureIndex, tick: ahead)
        }
        let measure = measureTicks(column.measureIndex, on: column.staff, in: score)
        if let armed {
            let stepped = column.tick + armed.ticks(division: score.division)
            if stepped < measure.ticks {
                return ScoreColumn(staff: column.staff, measureIndex: column.measureIndex, tick: stepped)
            }
        }
        let nextMeasure = column.measureIndex + 1
        guard measures(on: column.staff, in: score)?.indices.contains(nextMeasure) == true else { return nil }
        return ScoreColumn(staff: column.staff, measureIndex: nextMeasure, tick: 0)
    }

    /// The previous column, walking back into the preceding bar's LAST onset when this one opens the bar.
    ///
    /// No armed-duration fallback, deliberately: ← retreats along what is actually written, and an empty bar
    /// reached from its right-hand edge is walked back through by the onsets → laid down on the way in.
    public static func previous(before column: ScoreColumn, in score: Score) -> ScoreColumn? {
        let onsets = onsetTicks(in: column.measureIndex, on: column.staff, in: score)
        if let behind = onsets.last(where: { $0 < column.tick }) {
            return ScoreColumn(staff: column.staff, measureIndex: column.measureIndex, tick: behind)
        }
        let previousMeasure = column.measureIndex - 1
        guard previousMeasure >= 0,
              measures(on: column.staff, in: score)?.indices.contains(previousMeasure) == true
        else { return nil }
        let previousOnsets = onsetTicks(in: previousMeasure, on: column.staff, in: score)
        return ScoreColumn(
            staff: column.staff, measureIndex: previousMeasure, tick: previousOnsets.last ?? 0,
        )
    }

    /// Every tick at which ANY voice of the bar starts a chord or rest, ascending and deduplicated. The union is
    /// the whole point: a column stops wherever either hand does.
    static func onsetTicks(in measureIndex: Int, on staff: StaffAddress, in score: Score) -> [Int] {
        guard let measures = measures(on: staff, in: score), measures.indices.contains(measureIndex) else {
            return []
        }
        let measureDuration = measureTicks(measureIndex, on: staff, in: score).duration
        var ticks: Set<Int> = []
        for voice in measures[measureIndex].voices {
            var tick = 0
            for element in voice.elements {
                guard case let .chord(chord) = element else { continue }
                ticks.insert(tick)
                tick += chord.duration.resolved(in: measureDuration).ticks(division: score.division)
            }
        }
        return ticks.sorted()
    }

    private static func measures(on staff: StaffAddress, in score: Score) -> [Measure]? {
        guard score.parts.indices.contains(staff.partIndex),
              score.parts[staff.partIndex].staves.indices.contains(staff.staffIndexInPart)
        else { return nil }
        return score.parts[staff.partIndex].staves[staff.staffIndexInPart].measures
    }

    private static func voice(at slot: VoiceElementID, in score: Score) -> Voice? {
        guard let measures = measures(on: slot.staff, in: score),
              measures.indices.contains(slot.measureIndex),
              measures[slot.measureIndex].voices.indices.contains(slot.voiceIndex)
        else { return nil }
        return measures[slot.measureIndex].voices[slot.voiceIndex]
    }

    private static func measureTicks(
        _ measureIndex: Int, on staff: StaffAddress, in score: Score,
    ) -> (duration: Fraction, ticks: Int) {
        let duration = score.effectiveMeasureDuration(at: staff, measureIndex: measureIndex)
        return (duration, duration.ticks(division: score.division))
    }
}
```

`Fraction.ticks(division:)` may not exist under that name — check how `SplitRest` in ssm resolves a measure
duration to ticks (`rest.duration.resolved(in:).ticks(division:)`) and mirror whatever the `Fraction` API actually
offers; if there is no direct conversion, resolve `.measure` against the duration and ask the resulting
`NoteDuration`. Do not invent an arithmetic of your own.

- [ ] **Step 4: Run the tests to verify they pass**

Run the `-only-testing:EditorCoreTests/ColumnNavigationTests` command from Step 2.
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Editor/Sources/EditorCore/ColumnNavigation.swift Packages/Features/Editor/Tests/EditorCoreTests/ColumnNavigationTests.swift
git commit -m "feat(editor): a staff reads as columns, so a caret can stop between voices"
```

---

## Task 2: ← / → step the column, and pitched writes go to `activeVoice`

Spec §5.4's behavior change, with its own gate. On a single-voice staff — most scores — nothing observable moves,
which is exactly what the existing suites assert; on a multi-voice staff the new behavior is the point.

**Files:**
- Modify: `Packages/Features/Editor/Sources/EditorCore/EditorSessionCore+Navigation.swift`
- Modify: `Packages/Features/Editor/Sources/EditorCore/EditorSessionCore+Input.swift`
- Create: `Packages/Features/Editor/Tests/EditorCoreTests/ColumnCaretTests.swift`

**Interfaces:**
- Consumes: `ColumnNavigation`, `ScoreColumn` from Task 1.
- Produces: `EditorSessionCore.caretColumn: ScoreColumn?` (public, read-only) — the column the caret is in, and
  the authority on where the next write lands.

**Why the column has to be stored rather than derived.** `caretItem` names a SLOT, and a slot cannot express "beat
2 of an empty bar": that bar holds one measure rest whose only slot begins at tick 0. Deriving the column from
`caretItem` would round every mid-slot position back to its slot's start and silently undo the armed-duration step.
So `place(selection:caret:)` keeps `caretColumn` in step with `caretItem` for every ordinary placement (tap, ← / →
onto an onset, re-derivation), and the column stepper sets it directly when it lands between onsets. The RENDERED
caret stays `caretItem` — the covering slot — exactly as spec §5.4 says: drawn at the write destination.

- [ ] **Step 1: Write the failing test**

Create `Packages/Features/Editor/Tests/EditorCoreTests/ColumnCaretTests.swift` asserting, over
`EditorCoreFixtures` (see `Tests/EditorCoreTests/Support/EditorCoreFixtures.swift` for what it already builds):

1. On a single-voice staff, `selectNextElement()` lands on exactly the slot it landed on before — pin the
   expected `ScoreItemID` literally, so the test fails if the column path changes it.
2. On a two-voice staff, stepping from voice 0's beat 1 stops at voice 1's beat 2 onset when voice 0 has none
   there.
3. Stepping through an empty bar with a quarter armed visits four columns.
4. With `activeVoice = 1`, writing a note puts it in voice 1 even though the caret was placed from voice 0.

Write the assertions out in full — no "similar to above" — and derive each expected value from the fixture's own
shape rather than from a run.

- [ ] **Step 2: Run it to verify it fails**

Run: the Editor-Package test command with `-only-testing:EditorCoreTests/ColumnCaretTests`.
Expected: FAIL — the second and fourth assertions, which are the two behaviors this task adds.

- [ ] **Step 3: Step the column**

Replace `EditorSessionCore+Navigation.swift`'s `step(_:)` with a column walk: read the caret's column
(`ColumnNavigation.column(of:in:)` on `Self.slot(of: caretItem) ?? Self.slot(of: selectedItem)`), ask
`ColumnNavigation.next` / `.previous` (passing `armedInputDuration` as `steppingBy` for `next`), then place both
markers on the slot the destination column resolves to **in the voice the caret is already in when that voice has
one, and otherwise in the lowest-numbered voice that does** — the caret is drawn at the write destination, and on
a single-voice staff that is the only voice there is.

Keep the doc comment's two existing contracts and add the column one: navigation applies no command, and at either
end the markers HOLD rather than clearing.

- [ ] **Step 4: Pitched writes go to `activeVoice`, splitting the rest they land inside**

In `EditorSessionCore+Input.swift`, resolve the target slot for a note write through
`ColumnNavigation.slot(inVoice: activeVoice, at: caretColumn, in: score)` instead of using the caret's own slot
directly. Three rules:

- when `activeVoice` is the caret's own voice — the single-voice case and the default — the resolved slot IS the
  caret's slot, so nothing about today's behavior may change;
- when the measure has no such voice, the write is refused (voice creation belongs to the drum key, which knows
  which voice its instrument wants; a letter key does not grow a staff a second voice behind the user's back);
- **when the column falls INSIDE a rest (`tickWithinSlot != 0`), split it first** — `.splitRest` and the write in
  ONE `.composite`, so it is one undo step. This is what makes the armed-duration step of Step 3 mean anything: →
  into the middle of an empty bar and then a letter must write THERE, not back at beat 1.

  The composite's second member has to name the slot the split will create, and it is planned against the
  PRE-split score — so compute the index rather than re-reading: the tail's first element is
  `coveringSlot.elementIndex + DurationChangeAlgorithm.alignedDurations(forTicks: tickWithinSlot, rtickStart:
  columnTick - tickWithinSlot, division: score.division).count`. That is ssm's own public decomposition, the very
  one `SplitRest` uses, so the two cannot disagree.

**This deviates from the plan as first written**, which refused a mid-rest write and deferred splitting to the
drum path. Refusing it makes the empty-bar step of §5.4 unreachable on a pitched staff, which is the case the spec
names as the reason the fallback exists at all.

- [ ] **Step 5: Run the whole EditorCore + Editor suite**

Run the Editor-Package test command with no `-only-testing`.
Expected: PASS. **`EditorViewModelInputTests` and the navigation tests passing unchanged is this task's gate** —
if one of them needs editing to go green, stop and report which, because that is a behavior change the spec did
not ask for.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Editor/Sources/EditorCore Packages/Features/Editor/Tests/EditorCoreTests
git commit -m "feat(editor): the caret is a column, and a write picks its own voice"
```

---

## Task 3: the drum key model

Spec §5.2. Pure data plus the two presets — no session, no UI.

**Files:**
- Create: `Packages/Features/Editor/Sources/EditorCore/DrumPadLayout.swift`
- Create: `Packages/Features/Editor/Tests/EditorCoreTests/DrumPadLayoutTests.swift`

**Interfaces:**
- Consumes: `SheetMusicCore.GMDrumset`, `DrumsetEntry`, `Instrument`.
- Produces:
  - `public struct DrumPadKey: Sendable, Equatable, Identifiable` — `pitch: Int`, `name: String`,
    `headType: String?`, `line: Int`, `voiceIndex: Int`; `id` is `pitch`.
  - `public struct DrumPadLayout: Sendable, Equatable, Codable` — `keys: [DrumPadKey]`, `rowCount: Int`
    (clamped 1...3), `public static let `default`: DrumPadLayout` (15 keys), and
    `public func resolved(against instrument: Instrument) -> DrumPadLayout` — a score's own `drumset` overrides the
    GM line/head for the pitches it defines.
  - `public enum DrumVoicePreset: String, Sendable, CaseIterable` — `.singleVoice`, `.handsAndFeet`; with
    `public func applied(to layout: DrumPadLayout) -> DrumPadLayout` and
    `public static func implied(by score: Score, staff: StaffAddress) -> DrumVoicePreset`.

The default fifteen, in order — a realistic kit, and every pitch is one `GMDrumset` names:

`42 closed hi-hat, 46 open hi-hat, 51 ride, 49 crash, 38 snare, 37 side stick, 50 high tom, 48 hi-mid tom,
47 low-mid tom, 45 low tom, 43 high floor tom, 41 low floor tom, 36 bass drum, 44 pedal hi-hat, 56 cowbell`

Hands-and-feet puts 36, 41 and 44 in voice 1 — `GMDrumset`'s own split, which is MuseScore's. Single-voice puts
every key in voice 0.

`implied(by:staff:)` answers `.handsAndFeet` when ANY measure of that staff has more than one voice, `.singleVoice`
otherwise.

Write the tests first, run them red, then the type. Cover: the default's count and order; `resolved` taking a
non-standard ride line from a score's `drumset` while keeping the GM name; each preset's voice assignment; both
answers from `implied`; and `rowCount` clamping at 0 and at 4.

- [ ] **Commit**

```bash
git add Packages/Features/Editor/Sources/EditorCore/DrumPadLayout.swift Packages/Features/Editor/Tests/EditorCoreTests/DrumPadLayoutTests.swift
git commit -m "feat(editor): a drum key is data, and two presets say which hand plays it"
```

---

## Task 4: is this a drum staff, and which keys are lit

Spec §5.1 and the lit rule in §5.3. Both are questions about the score at the caret, so both are the core's.

**Files:**
- Create: `Packages/Features/Editor/Sources/EditorCore/EditorSessionCore+Drums.swift`
- Modify: `Packages/Features/Editor/Sources/EditorCore/EditorSessionCore.swift` (the `drumPadLayout` property only)
- Create: `Packages/Features/Editor/Tests/EditorCoreTests/DrumInputTests.swift` (started here, finished in Task 5)

**Interfaces:**
- Consumes: Tasks 1 and 3.
- Produces on `EditorSessionCore`:
  - `public var drumPadLayout = DrumPadLayout.default` (stored; the host seeds it from `UserDefaults`),
  - `public var isDrumStaffActive: Bool` — the caret's staff has `Instrument.useDrumset`,
  - `public var litDrumPitches: Set<Int>` — the pitches sounding in the caret's column, in any voice,
  - `public var resolvedDrumPadLayout: DrumPadLayout` — `drumPadLayout.resolved(against:)` the caret staff's
    instrument.

Tests: a pitched staff is never "drum active"; a drum staff with the caret on it is; the lit set is empty on an
empty bar, holds both hands' pitches when two voices sound at the same tick, and does NOT include a pitch that
sounds at a different tick in the same bar.

- [ ] **Commit**

```bash
git add Packages/Features/Editor/Sources/EditorCore Packages/Features/Editor/Tests/EditorCoreTests
git commit -m "feat(editor): the core knows a drum staff, and what sounds in the caret's column"
```

---

## Task 5: what a drum key press does

Spec §5.5 — the heart of the feature, and the one piece that MUST be in the core. One press is one
`CompositeEditCommand`, so one tap is one undo step.

**Files:**
- Modify: `Packages/Features/Editor/Sources/EditorCore/EditorSessionCore+Drums.swift`
- Modify: `Packages/Features/Editor/Tests/EditorCoreTests/DrumInputTests.swift`

**Interfaces:**
- Consumes: `ColumnNavigation`, `DrumPadKey`, and ssm's `.createVoice` / `.splitRest` / `.setNoteHead` /
  `.inputNote` / `.addNoteToChord` / `.removeNoteFromChord` intents.
- Produces: `public func pressDrumKey(_ key: DrumPadKey)` on `EditorSessionCore`.

The sequence, exactly as spec §5.5 states it:

1. Resolve the target voice from the key (`key.voiceIndex`).
2. If the measure has no such voice, prepend `.createVoice` — which plans to nothing when it is already there, so
   it can be issued unconditionally.
3. If the score's drumset has no entry for this pitch, add one from `GMDrumset`. **Do not skip this**: without a
   `drumLineMap` entry the layout falls back to the pitched diatonic formula and the note is drawn on a completely
   wrong line, visible only for instruments the imported chart never used. There is no edit intent for the
   instrument, so this is a direct mutation of `session.score`'s `Instrument.drumset` — do it BEFORE the composite
   and note in the doc comment that it is deliberately outside the undo step, because an entry that describes how
   a drum is engraved is not something an undo should take away.
4. Resolve the slot covering the caret's column in that voice, then:
   - **a chord that already contains this pitch** → `.removeNoteFromChord` (which collapses the chord to a rest
     when it was the only note);
   - **a chord without this pitch** → `.addNoteToChord` + `.setNoteHead`;
   - **a rest at the column's own tick** → `.inputNote` (armed duration) + `.setNoteHead`;
   - **a rest the column falls INSIDE** → `.splitRest` at `tickWithinSlot` first, then the rest case against the
     slot the split created.

The caret does NOT advance. Selection lands on the note just toggled on, so the callout still covers duration and
ties for it.

Tests — every branch above, plus: writing into a measure whose target voice does not exist; writing a pitch absent
from the score's drumset and asserting the entry was added and the note landed on the GM line; and one tap being
one undo step (apply, `undo()`, `#expect(session.score == before)`).

- [ ] **Commit**

```bash
git add Packages/Features/Editor/Sources/EditorCore Packages/Features/Editor/Tests/EditorCoreTests
git commit -m "feat(editor): a drum key toggles its own instrument in its own voice"
```

---

## Task 6: the pad's lower rows

Spec §5.3. Row 1 is untouched. The two instrument rows replace C–B when the caret's staff is a drum staff; the
rest key keeps its pitched meaning and stays at the end of the last row.

**Files:**
- Create: `Packages/Features/Editor/Sources/Editor/Views/EditorDrumPadRows.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/Views/EditorPadView.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Ops.swift` (a `pressDrumKey` forwarder)
- Modify: `Packages/Features/Editor/Sources/Editor/Resources/Localizable.xcstrings`

A key's face is its notehead glyph over a short name, and it wears a voice badge when `voiceIndex != 0`. A key is
**lit when its pitch is in `litDrumPitches`** — that is what makes the pad readable while correcting an imported
chart, and the property that lets the keys be toggles at all.

Long-pressing a key opens a `Menu` with `primaryAction:`, matching the tuplet and dot keys: fill this measure with
this instrument at the armed duration (and un-fill when it is already filled), swap the key's instrument, and move
it between voices.

`ViewThatFits` collapses the rows on a wide iPad exactly as it does today — do not add a second layout path.

Add `#Preview`s for the three-row pad at compact and regular width and for the lit state, and render them with
`mcp__xcode__RenderPreview` before moving on. Spec §10's view gate is those previews.

- [ ] **Commit** — `feat(editor): the pad's lower rows become a drum kit on a percussion staff`

---

## Task 7: editing the layout, and persisting it

Spec §5.6.

**Files:**
- Create: `Packages/Features/Editor/Sources/Editor/Views/EditorDrumLayoutSheet.swift`
- Create: `Packages/Features/Editor/Sources/Editor/DrumPadLayoutStore.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift` (the sheet flag only — the file is at
  384/400 lines, so put anything longer in its own file)

Reached from the `…` key's menu. Keys drag to reorder, tapping a key opens the instrument picker, tapping its
voice badge flips 1 ↔ 2, a stepper sets the row count 1...3, and the two presets sit in the same place.

`DrumPadLayout` persists as JSON in `UserDefaults`. **It must NOT be read through `@AppStorage` into layout
directly** — that routes through `UserDefaults` and lands outside `withAnimation`, which previously turned one pad
animation into a two-stage bounce. Drive the view from local state; persist separately.

The layout is **global, not per-score**: the user asked for a fixed core they can learn, and a layout that
reshuffles itself per file defeats that. The PRESET, though, is pre-selected per score from what the file actually
does — `DrumVoicePreset.implied(by:staff:)` from Task 3, applied when a session opens on a drum staff.

- [ ] **Commit** — `feat(editor): the drum layout is editable, and remembered`

---

## Task 8: the parity marker, and the gates

**Files:**
- Modify: `Packages/Features/Editor/Sources/Editor/Views/EditorDrumPadRows.swift` (the marker)
- Modify: `docs/engineering/ios-android-parity.md` (regenerated)

Add at the top of the SwiftUI pad rows:

```swift
// PARITY(android): drum note entry pad — Android needs a Compose pad over the same EditorCore ops
// (pressDrumKey, DrumPadLayout, the column caret). Only this view is iOS-only; every decision behind it is in
// EditorCore and already links into FolinoEditorJNI, so implementing the Compose half moves no logic.
```

Then `python3 Scripts/parity-report.py` and commit the regenerated ledger with it — the `parity-ledger` pre-commit
hook fails if it drifted.

- [ ] Run `env -C Packages/Features/Editor xcodebuild test -scheme Editor-Package …` — green.
- [ ] Run the app's own `xcodebuild … test` — green.
- [ ] Build for the device and hand the user the device pass from spec §10: correcting a real imported drum chart,
      which is the primary use case and the only way to judge whether three rows are worth their height.

- [ ] **Commit** — `docs: record the Compose drum pad as a deliberate one-platform gap`

---

## Final verification

- [ ] Both test gates green.
- [ ] `EditorViewModelInputTests` and the navigation suites passed **unedited** through Task 2 — the column caret's
      own gate.
- [ ] `grep -rn "func pressDrumKey" Packages/Features/Editor/Sources/Editor/` finds only a forwarder: every
      decision is in `EditorCore`, which is what makes the Android half a UI job rather than a port.
- [ ] The parity ledger names the Compose pad.
- [ ] Report to the user: what the device pass should look for, and that M6 completing puts the release bar
      (M1–M4 + M6) in reach of an ssm 2.2.0 tag.

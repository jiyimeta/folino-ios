# M4: Rehearsal Mark Editing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create, rename and delete a rehearsal mark on the target bar from the Editor's measure menu, so a score written from scratch can carry the marks the Reader's seek bar already navigates by.

**Architecture:** A rehearsal mark is already a `SystemElement.rehearsalMark` held by `Score.systemMeasures[measureIndex]` — the model, the MSCX round-trip, the layout, the fingerprint and folino's seek bar all exist. M4 adds only the two missing halves: an ssm `SetRehearsalMark` / `RemoveRehearsalMark` command pair (with the same pre-image capture-and-restore inverse M3's signature commands use, but capturing the system lane rather than the staves' signature prefixes) reached through wire intents 23/24, and a folino Editor sheet reached from the measure menu next to the two signature rows.

**Tech Stack:** Swift 6.3, Swift Testing (`@Suite`/`@Test`/`#expect`), swift-sheet-music (ssm) local path pin, SwiftUI Feature packages (Editor / Domain).

**Spec:** `docs/superpowers/specs/2026-08-26-scratch-score-creation-and-pro-design.md` — the umbrella spec, §1 item 6 and §3 item 5 and the M4 row in §4. M4's design was settled in chat rather than in its own spec (the umbrella spec itself designates M4 as "directly with an implementation plan"); the decisions that settled it are in **Decided semantics** below and are not to be re-litigated in a task.

## Global Constraints

- Two worktrees, two repos: **folino** = `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/scratch-creation-spec` (branch `worktree-scratch-creation-spec`); **ssm** = `/Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music` (branch `feature/scratch-creation-m1`). Commit each change in its own repo. Never merge ssm to main; no ssm release (umbrella policy — everything releases as 2.1.0 after M6).
- folino consumes ssm via local path pin; the 6 pin files (`Packages/Domain/Package.swift`, `Packages/Features/{Editor,Library,Reader}/Package.swift`, `Packages/Infrastructure/Package.swift`, `project.yml`) are already modified in the working tree — leave them modified, do **NOT** commit them.
- ssm tests: `xcrun swift test --filter <SuiteName>` from the ssm worktree root (plain `swift test` may pick the wrong toolchain). **`--filter` matches TYPE names only** — a directory name (`EditingTests`) or a `@Suite` display string (`"Rehearsal mark commands"`) silently runs zero tests and still reports success. Always pass the `struct` name, and sanity-check the reported test count against what you expected to run.
- folino package tests: `xcodebuild test -scheme <Pkg> -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` **from the package directory**. The two packages this plan touches expose their schemes as plain `Editor` and `Domain` (verified with `xcodebuild -list`, no `-Package` suffix). Plain `swift test` does NOT work in the folino repo.
- folino app build: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build` (this plan does not change `project.yml`).
- `EditIntent` case order is the wire format: **append, never renumber**. M4's cases are wire indices **23 and 24** exactly as listed in Tasks 2 and 3. The highest index in use today is 22 (`removeTimeSignature`).
- MuseScore (`~/Developer/musescore/MuseScore`) is a **behavioral reference only — GPL, no code ported or translated**.
- **ssm core code must compile for wasm, which has no `CharacterSet`.** `FoundationEssentials` — what the wasm build links — does not carry it, so `trimmingCharacters(in: .whitespacesAndNewlines)` builds on Apple and fails the wasm gate. In **ssm only**, use that repo's own `trimmingWhitespaceAndNewlines()` (pinned equivalent by `TrimmingHelpersTests`' scalar sweep). This bit M4: Tasks 1-3 shipped the `CharacterSet` form and only the wasm gate in Task 4 caught it. **Folino is the opposite case** — an Apple-only app target with no wasm build and no access to the ssm helper, so `CharacterSet` is correct there and must stay.
- No access modifier unless needed; `public` only for cross-module use. New tests use Swift Testing. Whole-file staging only (`git add <file>`, never `-p`).
- User-facing copy: app name lowercase `folino`; never expose internal feature names (`Editor`, `Reader`, …) in user-readable strings; Editor xcstrings fill all five locales (en, ja, ko, zh-Hans, zh-Hant).
- Comment paragraphs reflow at 120 columns.

### Decided semantics (do not re-litigate in tasks)

1. **One mark per bar, at the bar's start.** `SetRehearsalMark` writes at `MeasurePosition.start` and replaces the mark the bar already carries; the score model permits several marks in a bar, but this command's unit is "the mark on this bar". Removal drops every rehearsal mark in the bar.
2. **Text only.** The command writes `RehearsalMark.text` and nothing else. Frame, color, offsets and font overrides are preserved untouched on the replace path — a rename must not reset how an imported mark is drawn. This is why `ScoreFingerprintHasher` needs no change: it already hashes `text` and deliberately excludes the display trivia (see its doc at `ScoreFingerprintHasher.swift:331-338`).
3. **Empty text is refused, not silently ignored.** `SetRehearsalMark.apply` throws `.emptyRehearsalMarkText` when the text is empty after trimming whitespace. The sheet disables Apply in exactly that case, so it is unreachable from the UI — the refusal is what a directly-built command answers, the same role `.invalidTimeSignatureValue` plays for `SetTimeSignature`.
4. **Restating the same text plans to nothing.** The planner returns `nil` (session reports `.nothingToApply`) when the bar already carries that exact text, and when a removal is asked of a bar carrying no mark — the rule `.setKeySignature` and `.movePart` already follow.
5. **No renumbering, ever.** Inserting a mark between A and B does not renumber B. MuseScore does not either, and a mark is a name the composer chose, not an ordinal.
6. **The system lane is padded to full length on write.** A score that never held a system element has an empty `Score.systemMeasures`; writing a mark grows it to one entry per measure so it stays the parallel lane `InsertMeasure` / `DeleteMeasure` / `SetTimeSignature+Splice` all test for (`systemMeasures.count == measureCount`). Growing it only as far as the target index would leave the lane non-parallel and those commands would then stop maintaining it.
7. **The inverse captures the whole lane.** `Score.systemMeasures` is one small struct per measure, usually with an empty element array; capturing all of it makes the inverse obviously correct — it restores the padding as well as the mark — where a per-measure capture would have to re-derive whether it had padded.
8. **No confirmation dialog on removal, and no refusal alert in the sheet.** Deleting a mark is one undoable byte change with no re-barring behind it (unlike a signature removal, which is why that one confirms). And no refusal the sheet can reach exists: `.targetNotFound` needs an out-of-range bar the selection cannot produce, and `.emptyRehearsalMarkText` is gated by the disabled Apply button. Writing copy for unreachable states is what `EditorSignatureSheet`'s refusal doc argues against.
9. **The suggested name is the next letter.** Opening the sheet on a bar with no mark seeds the field with the letter for `index = (number of bars strictly before the target that carry a rehearsal mark)`, spelled A…Z then AA, AB, … Bars, not marks: one bar carries one mark as far as this surface is concerned, which is the premise ssm's own commands are written on, so counting bars is the version that stays consistent with it. Opening it on a bar that has one seeds the field with that mark's text (a rename). The field is a free-form `TextField` throughout — numbers, CJK, anything.

---

### Task 1: ssm — `SetRehearsalMark` / `RemoveRehearsalMark` commands

**Repo:** ssm

**Files:**
- Create: `Sources/SheetMusicCore/Editing/SetRehearsalMark.swift`
- Modify: `Sources/SheetMusicCore/Editing/EditRefusal.swift` (append one `Reason` case and its two switch arms)
- Test: `Tests/SheetMusicTests/EditingTests/RehearsalMarkCommandTests.swift` (create)

**Interfaces:**
- Produces: `public struct SetRehearsalMark: EditCommand` with `public init(measureIndex: Int, text: String)` and internal `init(restoringLane: [SystemMeasure], at: Int)`; `public struct RemoveRehearsalMark: EditCommand` with `public init(measureIndex: Int)`. Both return a `SetRehearsalMark(restoringLane:at:)` as their inverse.
- Produces: internal `enum RehearsalMarkLane` with `static func mark(in score: Score, measureIndex: Int) -> RehearsalMark?` — Task 2's planners call it.
- Produces: `EditRefusal.Reason.emptyRehearsalMarkText`, code `"edit.emptyRehearsalMarkText"`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/EditingTests/RehearsalMarkCommandTests.swift`:

```swift
import Testing
@testable import SheetMusicCore

/// The two rehearsal-mark commands: what they write into `Score.systemMeasures`, what they preserve on a rename,
/// and that each one's returned inverse restores the lane byte-for-byte — padding included.
@Suite("Rehearsal mark commands")
struct RehearsalMarkCommandTests {
    /// Four bars of quarter rests on one staff, with an EMPTY system lane — the shape `Score.blank` produces and
    /// the one the padding rule exists for.
    private static func blankScore() -> Score {
        let staff = Staff(measures: (0 ..< 4).map { _ in
            Measure(voices: [Voice(elements: Array(repeating: .rest(duration: .quarter), count: 4))])
        })
        return Score(division: 480, parts: [
            Part(id: "1", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
    }

    private static func markText(in score: Score, measureIndex: Int) -> String? {
        RehearsalMarkLane.mark(in: score, measureIndex: measureIndex)?.text
    }

    @Test("writing a mark into an empty lane pads it to one entry per measure")
    func writePadsLane() throws {
        var score = Self.blankScore()
        #expect(score.systemMeasures.isEmpty)
        try SetRehearsalMark(measureIndex: 2, text: "A").apply(to: &score)
        #expect(score.systemMeasures.count == 4)
        #expect(Self.markText(in: score, measureIndex: 2) == "A")
        #expect(Self.markText(in: score, measureIndex: 0) == nil)
    }

    @Test("the mark sits at the head of the bar")
    func writtenAtStart() throws {
        var score = Self.blankScore()
        try SetRehearsalMark(measureIndex: 1, text: "B").apply(to: &score)
        let positioned = try #require(score.systemMeasures[1].elements.first)
        #expect(positioned.position == .start)
        #expect(positioned.originalStaff == nil)
    }

    @Test("renaming preserves the mark's frame, color and offsets")
    func renamePreservesStyling() throws {
        var score = Self.blankScore()
        score.systemMeasures = Array(repeating: SystemMeasure(), count: 4)
        var styled = RehearsalMark(text: "A", offsetX: 1.5, offsetY: -2, frame: .circle)
        styled.visible = false
        score.systemMeasures[1].elements = [
            PositionedSystemElement(position: .start, element: .rehearsalMark(styled)),
        ]
        try SetRehearsalMark(measureIndex: 1, text: "Coda").apply(to: &score)
        let mark = try #require(RehearsalMarkLane.mark(in: score, measureIndex: 1))
        #expect(mark.text == "Coda")
        #expect(mark.frame == .circle)
        #expect(mark.offsetX == 1.5)
        #expect(mark.offsetY == -2)
        #expect(mark.visible == false)
    }

    @Test("the inverse restores the lane exactly, padding included")
    func inverseRestoresLane() throws {
        var score = Self.blankScore()
        let before = score.systemMeasures
        let inverse = try SetRehearsalMark(measureIndex: 2, text: "A").apply(to: &score)
        try inverse.apply(to: &score)
        #expect(score.systemMeasures == before)
    }

    @Test("removing drops the mark, and its inverse puts it back")
    func removeAndUndo() throws {
        var score = Self.blankScore()
        try SetRehearsalMark(measureIndex: 2, text: "A").apply(to: &score)
        let seeded = score.systemMeasures
        let inverse = try RemoveRehearsalMark(measureIndex: 2).apply(to: &score)
        #expect(Self.markText(in: score, measureIndex: 2) == nil)
        try inverse.apply(to: &score)
        #expect(score.systemMeasures == seeded)
    }

    @Test("empty and whitespace-only text is refused")
    func emptyTextRefused() {
        var score = Self.blankScore()
        #expect(throws: SheetMusicError.self) {
            try SetRehearsalMark(measureIndex: 0, text: "   ").apply(to: &score)
        }
        #expect(score.systemMeasures.isEmpty)
    }

    @Test("text is trimmed before it is written")
    func textIsTrimmed() throws {
        var score = Self.blankScore()
        try SetRehearsalMark(measureIndex: 0, text: "  A  ").apply(to: &score)
        #expect(Self.markText(in: score, measureIndex: 0) == "A")
    }

    @Test("an out-of-range bar is refused by both commands")
    func outOfRangeRefused() {
        var score = Self.blankScore()
        #expect(throws: SheetMusicError.self) {
            try SetRehearsalMark(measureIndex: 4, text: "A").apply(to: &score)
        }
        #expect(throws: SheetMusicError.self) {
            try RemoveRehearsalMark(measureIndex: -1).apply(to: &score)
        }
    }

    @Test("removing where there is no mark is refused")
    func removeWithoutMarkRefused() {
        var score = Self.blankScore()
        #expect(throws: SheetMusicError.self) {
            try RemoveRehearsalMark(measureIndex: 1).apply(to: &score)
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run from the ssm worktree root: `xcrun swift test --filter RehearsalMarkCommandTests`
Expected: FAIL — `cannot find 'SetRehearsalMark' in scope`, `cannot find 'RehearsalMarkLane' in scope`.

- [ ] **Step 3: Append the refusal reason**

In `Sources/SheetMusicCore/Editing/EditRefusal.swift`, add the case to `EditRefusal.Reason` immediately after `case invalidTimeSignatureValue(numerator:denominator:)` and before `case unexpected(description:)`:

```swift
        /// A rehearsal mark whose text is empty (or whitespace only) is not a mark — it would engrave as a bare
        /// frame with nothing in it. `SetRehearsalMark` refuses rather than write one. A host's sheet disables its
        /// confirm button on an empty field, so this is what a command built directly answers, the same role
        /// `.invalidTimeSignatureValue` plays for `SetTimeSignature`.
        case emptyRehearsalMarkText
```

Add the matching arm to the `code` switch (next to `edit.invalidTimeSignatureValue`):

```swift
        case .emptyRehearsalMarkText:
            "edit.emptyRehearsalMarkText"
```

and to `developerDescription`'s switch, matching the surrounding style:

```swift
        case .emptyRehearsalMarkText:
            "Rehearsal mark text is empty."
```

(Read the two switches first and follow the exact formatting each already uses — they are `switch reason` expressions returning a string.)

- [ ] **Step 4: Write the commands**

Create `Sources/SheetMusicCore/Editing/SetRehearsalMark.swift`:

```swift
import SheetMusicFoundation

/// The system lane's rehearsal-mark reads and writes, shared by both commands and by `ScoreEditSession`'s planners.
///
/// A rehearsal mark is a SYSTEM element (`Score.systemMeasures`), not a voice element, so none of the
/// `MeasureStructure` machinery the note- and signature-level commands lean on applies here: there is no leading
/// run to splice into and no tuplet index to shift. What replaces it is this lane.
enum RehearsalMarkLane {
    /// The rehearsal mark on `measureIndex`, or `nil` when that bar carries none — the first one, on the deliberate
    /// premise that one bar carries one mark (see the plan's decided semantics).
    static func mark(in score: Score, measureIndex: Int) -> RehearsalMark? {
        guard score.systemMeasures.indices.contains(measureIndex) else { return nil }
        return mark(in: score.systemMeasures, measureIndex: measureIndex)
    }

    /// The same read against a captured lane, for the inverse's `text`.
    static func mark(in lane: [SystemMeasure], measureIndex: Int) -> RehearsalMark? {
        guard lane.indices.contains(measureIndex) else { return nil }
        for positioned in lane[measureIndex].elements {
            if case let .rehearsalMark(mark) = positioned.element { return mark }
        }
        return nil
    }

    /// Grows the lane to one entry per measure, so it stays the PARALLEL lane `InsertMeasure`, `DeleteMeasure` and
    /// `SetTimeSignature`'s splice all test for (`systemMeasures.count == measureCount`) before they will maintain
    /// it. Growing only as far as the bar being written would leave the lane short, and those commands would then
    /// silently stop keeping it aligned with the measures.
    static func pad(_ score: inout Score) {
        let count = MeasureStructure.measureCount(of: score)
        guard score.systemMeasures.count < count else { return }
        score.systemMeasures.append(
            contentsOf: Array(repeating: SystemMeasure(), count: count - score.systemMeasures.count),
        )
    }

    /// Replaces the mark `measure` already carries, or inserts one at the bar's start when it carries none.
    ///
    /// The replace path mutates the existing mark IN PLACE rather than substituting a fresh `RehearsalMark`, for
    /// the reason `SetKeySignature.write` gives about a key: this states which text, not how it is drawn, so an
    /// imported mark's frame, color, offsets and font overrides survive a rename.
    ///
    /// The insert lands before the first element positioned later than the bar's start, because
    /// `SystemMeasure.elements` is stored in document order.
    static func write(_ text: String, into measure: inout SystemMeasure) {
        if let index = measure.elements.firstIndex(where: {
            if case .rehearsalMark = $0.element { true } else { false }
        }) {
            guard case var .rehearsalMark(mark) = measure.elements[index].element else { return }
            mark.text = text
            measure.elements[index].element = .rehearsalMark(mark)
            return
        }
        let insertion = measure.elements.firstIndex { $0.position > .start } ?? measure.elements.count
        measure.elements.insert(
            PositionedSystemElement(position: .start, element: .rehearsalMark(RehearsalMark(text: text))),
            at: insertion,
        )
    }

    /// Drops every rehearsal mark from `measure`, reporting whether it found one. Every mark rather than the first:
    /// the bar's mark is what this pair addresses, and leaving a second one behind would make the removal look like
    /// it had not happened.
    static func removeMarks(from measure: inout SystemMeasure) -> Bool {
        let before = measure.elements.count
        measure.elements.removeAll {
            if case .rehearsalMark = $0.element { true } else { false }
        }
        return measure.elements.count < before
    }
}

/// Writes `text` as the rehearsal mark at the head of `measureIndex` — replacing the mark that bar already carries,
/// or creating one where it carried none.
///
/// ## The inverse
///
/// A mark write is not reversible by arithmetic: the bar may have carried no mark at all, and the write may have
/// PADDED an empty system lane out to the score's measure count on its way in. So the inverse carries the pre-image
/// — the whole `systemMeasures` lane as it stood — restored verbatim by `init(restoringLane:at:)`, the idiom
/// `SetKeySignature(restoringPrefixes:at:)`, `InsertMeasure(restoredContents:)` and `AddPart(restoring:at:)` use.
///
/// The lane rather than the one bar, even though only one bar changes: `Score.systemMeasures` is one small struct
/// per measure — usually with an empty element array — and a whole-lane capture restores the padding as part of the
/// same value, where a per-bar capture would have to re-derive whether it had padded at all.
public struct SetRehearsalMark: EditCommand {
    public let measureIndex: Int
    /// The text to write, trimmed by `apply`. On the restore path this is the text the captured lane puts back —
    /// `apply` ignores it there and splices the pre-image instead.
    public let text: String
    /// Set only when this command is the inverse of a `SetRehearsalMark` / `RemoveRehearsalMark`: the score's whole
    /// system lane as it stood before that edit.
    let restoredLane: [SystemMeasure]?

    public init(measureIndex: Int, text: String) {
        self.measureIndex = measureIndex
        self.text = text
        restoredLane = nil
    }

    init(restoringLane lane: [SystemMeasure], at measureIndex: Int) {
        self.measureIndex = measureIndex
        restoredLane = lane
        text = RehearsalMarkLane.mark(in: lane, measureIndex: measureIndex)?.text ?? ""
    }

    /// A rehearsal mark belongs to the system rather than to a staff, so there is no voice element to name. Part 0 /
    /// staff 0 / voice 0 / element 0 of the bar is what the other bar-addressing commands report
    /// (`SetKeySignature`, `RemoveTimeSignature`), and the session only reads `measureIndex` off it.
    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        // One place states the range, for the same reason `SetKeySignature` does: the answer is the same whether
        // the command is reached through an intent or built directly.
        guard measureIndex >= 0, measureIndex < MeasureStructure.measureCount(of: score), !score.parts.isEmpty
        else { throw Self.refused(.targetNotFound(affectedLocation)) }

        let previous = score.systemMeasures
        if let restoredLane {
            score.systemMeasures = restoredLane
        } else {
            let trimmed = text.trimmingWhitespaceAndNewlines()
            guard !trimmed.isEmpty else { throw Self.refused(.emptyRehearsalMarkText) }
            RehearsalMarkLane.pad(&score)
            RehearsalMarkLane.write(trimmed, into: &score.systemMeasures[measureIndex])
        }
        return SetRehearsalMark(restoringLane: previous, at: measureIndex)
    }
}

/// Removes the rehearsal mark at `measureIndex`.
///
/// Refused with `.targetNotFound` when the bar carries none. That case is the PLANNER's to resolve to nothing
/// (`ScoreEditSession+RehearsalMarkPlanning` returns `nil`, which the session reports as `.nothingToApply`); the
/// throw here is what the same command answers when it is built directly, so the range and the emptiness are both
/// stated in one place — exactly the split `RemoveKeySignature` uses.
///
/// Unlike the signature removals there is no measure-0 exception: bar 1's rehearsal mark is a mark like any other,
/// not the score declaring something the engraver needs.
public struct RemoveRehearsalMark: EditCommand {
    public let measureIndex: Int

    public init(measureIndex: Int) {
        self.measureIndex = measureIndex
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard measureIndex >= 0, measureIndex < MeasureStructure.measureCount(of: score), !score.parts.isEmpty,
              score.systemMeasures.indices.contains(measureIndex)
        else { throw Self.refused(.targetNotFound(affectedLocation)) }

        let previous = score.systemMeasures
        guard RehearsalMarkLane.removeMarks(from: &score.systemMeasures[measureIndex]) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        return SetRehearsalMark(restoringLane: previous, at: measureIndex)
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `xcrun swift test --filter RehearsalMarkCommandTests`
Expected: PASS, 9 tests.

(`TextFrameType` is declared in `Sources/SheetMusicCore/Score/TextStyle.swift` and its cases are `.rectangle`, `.circle`, `.none` — `.circle` in `renamePreservesStyling` is correct as written.)

- [ ] **Step 6: Run the surrounding suites for regressions**

Run: `xcrun swift test --filter EditRefusalTests` then `xcrun swift test --filter EditingTests`
Expected: PASS. `EditRefusalTests` holds no exhaustive `switch` over `Reason`, so appending a case should not touch it — if it nevertheless fails, read it before changing anything, because a break there means the new case collided with an existing expectation rather than merely widening the enum.

- [ ] **Step 7: Commit (ssm)**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music add Sources/SheetMusicCore/Editing/SetRehearsalMark.swift Sources/SheetMusicCore/Editing/EditRefusal.swift Tests/SheetMusicTests/EditingTests/RehearsalMarkCommandTests.swift
git -C /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music commit -m "feat: rehearsal mark set/remove edit commands"
```

---

### Task 2: ssm — `EditIntent` cases 23/24 and their planners

**Repo:** ssm

**Files:**
- Modify: `Sources/SheetMusicCore/Editing/EditIntent.swift` (append two cases at the end of the enum)
- Modify: `Sources/SheetMusicCore/Editing/ScoreEditSession+Planning.swift` (two names on the grouped structural `case`, two `if case` arms in `structuralCommand`, one doc-comment count)
- Create: `Sources/SheetMusicCore/Editing/ScoreEditSession+RehearsalMarkPlanning.swift`
- Test: `Tests/SheetMusicTests/EditingTests/RehearsalMarkIntentTests.swift` (create)

**Interfaces:**
- Consumes: Task 1's `SetRehearsalMark(measureIndex:text:)`, `RemoveRehearsalMark(measureIndex:)`, `RehearsalMarkLane.mark(in:measureIndex:)`.
- Produces: `EditIntent.setRehearsalMark(measureIndex: Int, text: String)` (wire index 23) and `EditIntent.removeRehearsalMark(measureIndex: Int)` (wire index 24) — Task 3 encodes these and Task 5's folino view model constructs them.
- Produces: `ScoreEditSession.setRehearsalMarkCommand(at:text:in:)` and `.removeRehearsalMarkCommand(at:in:)`, both `static`, both internal, both returning `(any EditCommand)?`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/EditingTests/RehearsalMarkIntentTests.swift`:

```swift
import Testing
@testable import SheetMusicCore

/// The two rehearsal-mark intents as a session plans and applies them: what lands, what resolves to nothing, and
/// that undo/redo round-trips the lane.
@Suite("Rehearsal mark intents")
struct RehearsalMarkIntentTests {
    private static func blankScore() -> Score {
        let staff = Staff(measures: (0 ..< 4).map { _ in
            Measure(voices: [Voice(elements: Array(repeating: .rest(duration: .quarter), count: 4))])
        })
        return Score(division: 480, parts: [
            Part(id: "1", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
    }

    private static func markText(in score: Score, measureIndex: Int) -> String? {
        RehearsalMarkLane.mark(in: score, measureIndex: measureIndex)?.text
    }

    @Test("setting a mark lands and undo takes it back out")
    func setAndUndo() {
        let session = ScoreEditSession(score: Self.blankScore())
        #expect(session.apply(.setRehearsalMark(measureIndex: 1, text: "A")))
        #expect(Self.markText(in: session.score, measureIndex: 1) == "A")
        #expect(session.undo())
        #expect(session.score.systemMeasures.isEmpty)
        #expect(session.redo())
        #expect(Self.markText(in: session.score, measureIndex: 1) == "A")
    }

    @Test("renaming replaces the text in place")
    func rename() {
        let session = ScoreEditSession(score: Self.blankScore())
        #expect(session.apply(.setRehearsalMark(measureIndex: 1, text: "A")))
        #expect(session.apply(.setRehearsalMark(measureIndex: 1, text: "Bridge")))
        #expect(Self.markText(in: session.score, measureIndex: 1) == "Bridge")
        #expect(session.score.systemMeasures[1].elements.count == 1)
    }

    @Test("restating the same text is nothing to apply, not a refusal")
    func restatingIsNoOp() {
        let session = ScoreEditSession(score: Self.blankScore())
        #expect(session.apply(.setRehearsalMark(measureIndex: 1, text: "A")))
        #expect(!session.apply(.setRehearsalMark(measureIndex: 1, text: "A")))
        #expect(session.lastRefusal?.reason == .nothingToApply)
    }

    @Test("removing where there is no mark is nothing to apply")
    func removingNothingIsNoOp() {
        let session = ScoreEditSession(score: Self.blankScore())
        #expect(!session.apply(.removeRehearsalMark(measureIndex: 2)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
    }

    @Test("removing a mark lands and undo puts it back")
    func removeAndUndo() {
        let session = ScoreEditSession(score: Self.blankScore())
        #expect(session.apply(.setRehearsalMark(measureIndex: 2, text: "C")))
        #expect(session.apply(.removeRehearsalMark(measureIndex: 2)))
        #expect(Self.markText(in: session.score, measureIndex: 2) == nil)
        #expect(session.undo())
        #expect(Self.markText(in: session.score, measureIndex: 2) == "C")
    }

    @Test("empty text reaches the command and is refused")
    func emptyTextRefused() {
        let session = ScoreEditSession(score: Self.blankScore())
        #expect(!session.apply(.setRehearsalMark(measureIndex: 0, text: "  ")))
        #expect(session.lastRefusal?.reason == .emptyRehearsalMarkText)
    }

    @Test("a mark changes the score's fingerprint")
    func fingerprintMoves() {
        let session = ScoreEditSession(score: Self.blankScore())
        let before = session.score.stableFingerprint
        #expect(session.apply(.setRehearsalMark(measureIndex: 1, text: "A")))
        #expect(session.score.stableFingerprint != before)
        #expect(session.undo())
        #expect(session.score.stableFingerprint == before)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcrun swift test --filter RehearsalMarkIntentTests`
Expected: FAIL — `type 'EditIntent' has no member 'setRehearsalMark'`.

- [ ] **Step 3: Append the two intent cases**

At the very END of the `EditIntent` enum in `Sources/SheetMusicCore/Editing/EditIntent.swift`, after `case removeTimeSignature(measureIndex: Int)`:

```swift
    /// Write `text` as the rehearsal mark at the head of `measureIndex` — replacing the mark that bar already
    /// carries, or creating one where it carried none. The text is trimmed of surrounding whitespace before it is
    /// written, and only the text changes: a renamed mark keeps the frame, color and offsets it was drawn with.
    ///
    /// Resolves to nothing to apply when that bar already carries this exact text — the same rule
    /// `.setKeySignature` and `.movePart` apply to an edit that would restore the score to itself. Text that is
    /// empty after trimming reaches `SetRehearsalMark.apply` and is refused there as `.emptyRehearsalMarkText`;
    /// an out-of-range `measureIndex` is refused there as `.targetNotFound`, so one place states each rule.
    case setRehearsalMark(measureIndex: Int, text: String)

    /// Remove the rehearsal mark at `measureIndex`. Plans to nothing when that bar carries none. No measure-0
    /// exception, unlike the signature removals: bar 1's mark is a mark like any other.
    case removeRehearsalMark(measureIndex: Int)
```

- [ ] **Step 4: Write the planners**

Create `Sources/SheetMusicCore/Editing/ScoreEditSession+RehearsalMarkPlanning.swift`:

```swift
import SheetMusicFoundation

/// `ScoreEditSession`'s planning half for the rehearsal-mark intents.
///
/// Its own file rather than another block in `ScoreEditSession+SignaturePlanning.swift`, and for the reason that
/// file gives for existing at all: `+Planning.swift` is at 345 of SwiftLint's 400 lines, and a rehearsal mark is a
/// SYSTEM element rather than something a bar declares, so it shares no reasoning with the signature planners next
/// door beyond addressing a bar.
///
/// `structuralCommand(for:in:)` dispatches to these, so they are internal rather than private; nothing outside this
/// module calls them.
extension ScoreEditSession {
    /// `.setRehearsalMark`: write the text, unless the bar already carries exactly it.
    ///
    /// `nil` in that case — the score already says this, and planning it anyway would push an undo entry that
    /// restores the score to itself, the dead ⌘Z `.setKeySignature` and `.movePart` both refuse. The comparison is
    /// made against the TRIMMED text, which is what the command would go on to write, so a re-submitted field with
    /// a stray trailing space is recognised as the no-op it is.
    ///
    /// Empty text is deliberately NOT caught here: `SetRehearsalMark.apply` states that rule, so a host gets the
    /// same `.emptyRehearsalMarkText` whether the command was reached through this intent or built directly.
    static func setRehearsalMarkCommand(
        at measureIndex: Int, text: String, in score: Score,
    ) -> (any EditCommand)? {
        let trimmed = text.trimmingWhitespaceAndNewlines()
        guard RehearsalMarkLane.mark(in: score, measureIndex: measureIndex)?.text != trimmed else { return nil }
        return SetRehearsalMark(measureIndex: measureIndex, text: trimmed)
    }

    /// `.removeRehearsalMark`: the removal, or `nil` when the bar carries no mark to remove — nothing to apply
    /// rather than a refusal, the same split `removeKeySignatureCommand` makes.
    static func removeRehearsalMarkCommand(at measureIndex: Int, in score: Score) -> (any EditCommand)? {
        guard RehearsalMarkLane.mark(in: score, measureIndex: measureIndex) != nil else { return nil }
        return RemoveRehearsalMark(measureIndex: measureIndex)
    }
}
```

- [ ] **Step 5: Dispatch them from the session's planner**

In `Sources/SheetMusicCore/Editing/ScoreEditSession+Planning.swift`, extend the grouped structural case (currently `case .insertMeasure, .deleteMeasure, .addPart, .removePart, .movePart, .setKeySignature, .removeKeySignature:`) to:

```swift
        case .insertMeasure, .deleteMeasure, .addPart, .removePart, .movePart,
             .setKeySignature, .removeKeySignature, .setRehearsalMark, .removeRehearsalMark:
```

Then in `structuralCommand(for:in:)`, add these two arms immediately before the closing `return nil`:

```swift
        if case let .setRehearsalMark(measureIndex, text) = intent {
            return setRehearsalMarkCommand(at: measureIndex, text: text, in: score)
        }
        if case let .removeRehearsalMark(measureIndex) = intent {
            return removeRehearsalMarkCommand(at: measureIndex, in: score)
        }
```

and update that function's doc comment, which currently opens "The seven intents that change the score's shape: the measure columns, the parts, and what a bar declares." — make it:

```swift
    /// The nine intents that change the score's shape: the measure columns, the parts, what a bar declares, and the
    /// rehearsal mark it carries.
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcrun swift test --filter RehearsalMarkIntentTests`
Expected: PASS, 7 tests.

Then run: `xcrun swift test --filter RehearsalMarkCommandTests`
Expected: PASS (Task 1's suite still green).

- [ ] **Step 7: Commit (ssm)**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music add Sources/SheetMusicCore/Editing/EditIntent.swift Sources/SheetMusicCore/Editing/ScoreEditSession+Planning.swift Sources/SheetMusicCore/Editing/ScoreEditSession+RehearsalMarkPlanning.swift Tests/SheetMusicTests/EditingTests/RehearsalMarkIntentTests.swift
git -C /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music commit -m "feat: rehearsal mark edit intents and their planners"
```

---

### Task 3: ssm — wire indices 23/24

**Repo:** ssm

**Files:**
- Modify: `Sources/SheetMusicEditWire/Intent/EditIntentCodec.swift` (index table, two `EditIntentWire` cases, the encode switch, the decode switch, two payload structs, two doc-comment layout blocks)
- Test: `Tests/SheetMusicTests/AndroidJNI/EditIntentCodecTests.swift` (modify — append two tests)

**Interfaces:**
- Consumes: Task 2's `EditIntent.setRehearsalMark(measureIndex:text:)` / `.removeRehearsalMark(measureIndex:)`.
- Produces: `EditIntentWire.setRehearsalMark(SetRehearsalMarkIntentWire)` at discriminator **23** and `.removeRehearsalMark(RemoveRehearsalMarkIntentWire)` at **24**; `SetRehearsalMarkIntentWire(measureIndex: Int, text: String)` with `decoded() -> (measureIndex: Int, text: String)`; `RemoveRehearsalMarkIntentWire(measureIndex: Int)` with `decoded() -> Int`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/AndroidJNI/EditIntentCodecTests.swift`, inside the existing suite and matching the surrounding tests' style (read the neighbours at lines 159-211 first — they pin the discriminator byte and round-trip the value):

```swift
    @Test("setRehearsalMark pins discriminator 23 and round-trips its text")
    func setRehearsalMarkRoundTrips() throws {
        let intent = EditIntent.setRehearsalMark(measureIndex: 3, text: "1サビ")
        let bytes = EditIntentCodec.encode(intent)
        #expect(bytes[1] == 23)
        #expect(try EditIntentCodec.decode(bytes) == intent)
    }

    @Test("removeRehearsalMark pins discriminator 24")
    func removeRehearsalMarkRoundTrips() throws {
        let intent = EditIntent.removeRehearsalMark(measureIndex: 0)
        let bytes = EditIntentCodec.encode(intent)
        #expect(bytes[1] == 24)
        #expect(try EditIntentCodec.decode(bytes) == intent)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcrun swift test --filter EditIntentCodecTests`
Expected: FAIL — `type 'EditIntentWire' has no member 'setRehearsalMark'` (or, if the enum builds, a mismatch on the discriminator byte).

- [ ] **Step 3: Extend the index table and the wire enum**

In the file header's index table, after `/// 22 = removeTimeSignature(RemoveTimeSignatureIntentWire)`:

```swift
/// 23 = setRehearsalMark(SetRehearsalMarkIntentWire)
/// 24 = removeRehearsalMark(RemoveRehearsalMarkIntentWire)
```

and extend the sentence below it that reads "…and 19…22 for M3 signature changes; 0…4 predate them all…" to "…19…22 for M3 signature changes and 23…24 for M4 rehearsal marks; 0…4 predate them all…".

Add the payload layout blocks after `RemoveTimeSignatureIntentWire`'s:

```swift
/// `SetRehearsalMarkIntentWire` (`setRehearsalMark`'s payload):
/// ```
/// tag 1: measureIndex  i32, zig-zag varint
/// tag 2: text          string — UTF-8, trimmed engine-side, never empty after trimming
/// ```
///
/// `RemoveRehearsalMarkIntentWire` (`removeRehearsalMark`'s payload). Byte-identical to
/// `RemoveTimeSignatureIntentWire` and deliberately its own struct, for the reason that one is separate from
/// `RemoveKeySignatureIntentWire`: the removals address different things and are free to diverge.
/// ```
/// tag 1: measureIndex  i32, zig-zag varint
/// ```
```

At the end of `enum EditIntentWire`'s case list, after `case removeTimeSignature(RemoveTimeSignatureIntentWire)`:

```swift
    /// Appended for M4 rehearsal marks — index 23. Never renumber anything above it.
    case setRehearsalMark(SetRehearsalMarkIntentWire)
    /// Appended for M4 rehearsal marks — index 24.
    case removeRehearsalMark(RemoveRehearsalMarkIntentWire)
```

- [ ] **Step 4: Extend both switches**

In `init(from intent: EditIntent)`, after the `.removeTimeSignature` arm:

```swift
        case let .setRehearsalMark(measureIndex, text):
            self = .setRehearsalMark(SetRehearsalMarkIntentWire(measureIndex: measureIndex, text: text))
        case let .removeRehearsalMark(measureIndex):
            self = .removeRehearsalMark(RemoveRehearsalMarkIntentWire(measureIndex: measureIndex))
```

In `decoded(depth:)`, after its `.removeTimeSignature` arm (read the neighbours — the signature arms follow the shape `case let .removeTimeSignature(wire): return .removeTimeSignature(measureIndex: wire.decoded())`):

```swift
        case let .setRehearsalMark(wire):
            let decoded = wire.decoded()
            return .setRehearsalMark(measureIndex: decoded.measureIndex, text: decoded.text)
        case let .removeRehearsalMark(wire):
            return .removeRehearsalMark(measureIndex: wire.decoded())
```

- [ ] **Step 5: Add the payload structs**

At the end of the file, after `RemoveTimeSignatureIntentWire`:

```swift
/// `setRehearsalMark`'s payload — which bar carries the mark, and what it reads.
///
/// `text` is the only string an edit intent has ever carried besides `PartPlanWire`'s names, and it is free-form on
/// purpose: a mark is "A", "1サビ", "Coda" — whatever the composer wrote. The engine trims it and refuses an empty
/// result, so no length or character rule is stated here.
@WireFormat
public struct SetRehearsalMarkIntentWire {
    public var measureIndex: Int32
    public var text: String

    public init(measureIndex: Int, text: String) {
        self.measureIndex = Int32(measureIndex)
        self.text = text
    }

    public func decoded() -> (measureIndex: Int, text: String) {
        (measureIndex: Int(measureIndex), text: text)
    }
}

/// `removeRehearsalMark`'s payload. Byte-identical to `RemoveTimeSignatureIntentWire` and deliberately its own
/// struct, for the reason that one is separate from `RemoveKeySignatureIntentWire`: the removals address different
/// things and are free to diverge.
@WireFormat
public struct RemoveRehearsalMarkIntentWire {
    public var measureIndex: Int32

    public init(measureIndex: Int) {
        self.measureIndex = Int32(measureIndex)
    }

    public func decoded() -> Int {
        Int(measureIndex)
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcrun swift test --filter EditIntentCodecTests`
Expected: PASS, including the two new tests.

- [ ] **Step 7: Commit (ssm)**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music add Sources/SheetMusicEditWire/Intent/EditIntentCodec.swift Tests/SheetMusicTests/AndroidJNI/EditIntentCodecTests.swift
git -C /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music commit -m "feat: wire encoding for the rehearsal mark intents"
```

---

### Task 4: ssm — replay script steps, golden re-record, docs, gates

**Repo:** ssm

**Files:**
- Modify: `Tests/SheetMusicTests/EditingTests/EditReplayScript.swift` (two steps appended to `standard(staff:)`)
- Modify: `Android/SheetMusicAndroid/src/androidTest/kotlin/io/github/jiyimeta/sheetmusic/EditSessionReplayTest.kt:33` (`EXPECTED_STEP_COUNT` 18 → 20)
- Modify (re-recorded, not hand-edited): `Android/SheetMusicAndroid/src/androidTest/assets/editReplay/*`, `Web/sheet-music-web/test/fixtures/*`
- Modify: `docs/edit-commands.md:113` (tick the `SetRehearsalMark` checkbox)

**Interfaces:**
- Consumes: Task 2's intents and Task 3's wire encoding. Produces no new API — this task is the acceptance gate that the wire bytes and fingerprints M4 introduces are pinned for the Android and web replays.

- [ ] **Step 1: Append the two replay steps**

In `EditReplayScript.standard(staff:)`, after `let step12b = …` and before the `return [` array:

```swift
        // Step 13a: name measure 1 "A". A rehearsal mark is the first SYSTEM-lane edit in this script — every step
        // above it moves voice elements — so it is also the first one whose wire bytes carry a string, and the
        // first whose fingerprint moves through `ScoreFingerprintHasher`'s system lane rather than a staff's.
        // The fixture's system lane is empty, so this step also exercises the padding path.
        let step13a = EditReplayStep.intent(.setRehearsalMark(measureIndex: 1, text: "A"))
        // Step 13b: take it away again. Paired with 13a deliberately, for the reason 11a/11b are paired:
        // `RemoveRehearsalMark` has its own inverse and its own wire bytes, and a script that only ever set a mark
        // would encode neither. The score's VALUE does not return to 12b's — 13a padded the empty system lane out
        // to one entry per measure and the removal takes the mark back out WITHOUT un-padding — but its
        // FINGERPRINT does, because `ScoreFingerprint.combineSystemLane` hashes the lane by its occupants and
        // never by its length, deliberately, so that the in-memory and MSCX spellings of the same score agree.
        // Empty padding is invisible to it.
        let step13b = EditReplayStep.intent(.removeRehearsalMark(measureIndex: 1))
```

and extend the returned array to end `…, step12a, step12b, step13a, step13b,`.

- [ ] **Step 2: Move the Kotlin step count**

In `Android/SheetMusicAndroid/src/androidTest/kotlin/io/github/jiyimeta/sheetmusic/EditSessionReplayTest.kt`, line 33:

```kotlin
        private const val EXPECTED_STEP_COUNT = 20
```

Also update `EditReplayGoldenTests.swift`'s doc comment, which says "`EditReplayScript.standard`'s eighteen steps" and "asserting the same nineteen fingerprints" — make them "twenty steps" and "twenty-one fingerprints".

- [ ] **Step 3: Run the golden tests to verify they fail**

Run: `xcrun swift test --filter EditReplayGoldenTests` and `xcrun swift test --filter EditReplayWebGoldenTests`
Expected: FAIL — the committed assets carry 18 steps / 19 fingerprints and the live script now produces 20 / 21.

- [ ] **Step 4: Re-record the goldens**

```bash
SM_EDIT_REPLAY_RECORD=1 xcrun swift test --filter EditReplayGoldenTests
```

then

```bash
SM_EDIT_REPLAY_RECORD=1 xcrun swift test --filter EditReplayWebGoldenTests
```

- [ ] **Step 5: Verify the recorded assets**

Re-run BOTH suites WITHOUT the environment variable:

```bash
xcrun swift test --filter EditReplayGoldenTests
xcrun swift test --filter EditReplayWebGoldenTests
xcrun swift test --filter EditReplayDeterminismTests
```

Expected: PASS. Then review what was recorded:

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music diff --stat Android/SheetMusicAndroid/src/androidTest/assets/editReplay Web/sheet-music-web/test/fixtures
```

Expected: only the replay assets changed — the first 19 fingerprints must be **unchanged** (M4 appends steps rather than altering existing ones). If any earlier fingerprint moved, stop: something in Tasks 1–3 changed existing behavior, and that is a bug to fix rather than a golden to re-record.

- [ ] **Step 6: Tick the docs checkbox**

In `docs/edit-commands.md`, line 113, change

```
- [ ] **SetRehearsalMark** *(sugar)* — A / B / C boxed labels.
```

to

```
- [x] **SetRehearsalMark** — set / rename / remove the mark on one bar (`RemoveRehearsalMark` is its sibling).
```

and, if the "suggested order" list around line 190 still groups `SetRehearsalMark` with the unimplemented text marks, drop it from that grouping.

- [ ] **Step 7: Run the gates**

```bash
xcrun swift test
Scripts/preflight.sh --apple
Scripts/preflight.sh --android
Scripts/wasm-build-web.sh
npm --prefix Web/sheet-music-web test
```

Expected: all green; the npm suite's count grows only if the fixtures added cases. `Scripts/preflight.sh --android` needs the release toolchain first on `PATH` — if it fails on toolchain grounds see the repo memory `project_android_build_toolchain`. `Scripts/preflight.sh --wasm` is **parked** for this feature branch (a Swift Testing / wasm toolchain threshold crash, recorded in the M3 pre-tag decision list); the npm run above is its standing substitute — say so in the commit body rather than silently skipping it.

- [ ] **Step 8: Commit (ssm)**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music add Tests/SheetMusicTests/EditingTests/EditReplayScript.swift Tests/SheetMusicTests/AndroidJNI/EditReplayGoldenTests.swift Android/SheetMusicAndroid/src/androidTest/kotlin/io/github/jiyimeta/sheetmusic/EditSessionReplayTest.kt Android/SheetMusicAndroid/src/androidTest/assets/editReplay Web/sheet-music-web/test/fixtures docs/edit-commands.md
git -C /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music commit -m "test: replay goldens cover the rehearsal mark intents"
```

---

### Task 5: folino — the Editor view model's rehearsal-mark surface

**Repo:** folino

**Files:**
- Create: `Packages/Features/Editor/Sources/Editor/EditorViewModel+RehearsalMarks.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift` (one presentation flag, one callback)
- Modify: `Packages/Domain/Sources/Domain/Analytics/AnalyticsEvent+Factories.swift` (one factory, next to `scoreSignatureChanged`)
- Test: `Packages/Features/Editor/Tests/EditorTests/EditorRehearsalMarkTests.swift` (create)
- Test: `Packages/Domain/Tests/DomainTests/AnalyticsEventFactoryTests.swift` (modify — one test)

**Interfaces:**
- Consumes: Task 2's `EditIntent.setRehearsalMark(measureIndex:text:)` / `.removeRehearsalMark(measureIndex:)`, and the existing `EditorViewModel.targetMeasureIndex`, `apply(_:)`, `session?.lastRefusal`, `targetDisplayedMeasureNumber`.
- Produces: `EditorViewModel.isRehearsalMarkSheetPresented: Bool`, `.onRehearsalMarkEdited: ((String) -> Void)?`, and (in the new file) `.targetRehearsalMarkText: String?`, `.suggestedRehearsalMarkText: String`, `@discardableResult func setRehearsalMark(text: String) -> Bool`, `@discardableResult func removeRehearsalMark() -> Bool` — Task 6's sheet calls all of these.
- Produces: `AnalyticsEvent.scoreRehearsalMarkEdited(action: String)` → event name `score_rehearsal_mark_edited`, parameter `action` ∈ `"set"` / `"remove"`.

- [ ] **Step 1: Write the failing tests**

Create `Packages/Features/Editor/Tests/EditorTests/EditorRehearsalMarkTests.swift`:

```swift
import Domain
@testable import Editor
import Foundation
import SheetMusicCore
import Testing

/// The rehearsal-mark surface: what the sheet reads to open on, the letter it suggests, and the two writes —
/// including the quiet no-op ssm reports as `.nothingToApply`, which must not look like a failure to the caller.
@MainActor
@Suite("Editor rehearsal marks")
struct EditorRehearsalMarkTests {
    private func makeViewModel() -> EditorViewModel {
        EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: URL(filePath: "/tmp"),
            gateway: FakeScoreFileGateway(),
            repository: FakeScoreLibraryRepository(),
            originalStore: FakeScoreOriginalStore(),
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
        )
    }

    /// A session on `threeMeasuresOfQuarterRests` with a rest picked in `measure` — the selection is what supplies
    /// `targetMeasureIndex`.
    private func session(targeting measure: Int) -> EditorViewModel {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.threeMeasuresOfQuarterRests())
        vm.select(.rest(RestID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measure, voiceIndex: 0, elementIndex: 0,
        )))
        return vm
    }

    @Test func `a bar with no mark reads nil and suggests A`() {
        let vm = session(targeting: 0)
        #expect(vm.targetRehearsalMarkText == nil)
        #expect(vm.suggestedRehearsalMarkText == "A")
    }

    @Test func `setting a mark lands and the bar then reads it back`() {
        let vm = session(targeting: 1)
        #expect(vm.setRehearsalMark(text: "A"))
        #expect(vm.targetRehearsalMarkText == "A")
    }

    @Test func `the suggestion counts the marks in earlier bars`() {
        let vm = session(targeting: 0)
        #expect(vm.setRehearsalMark(text: "A"))
        vm.select(.rest(RestID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 2, voiceIndex: 0, elementIndex: 0,
        )))
        #expect(vm.suggestedRehearsalMarkText == "B")
    }

    @Test func `a bar that already has a mark suggests its own text`() {
        let vm = session(targeting: 1)
        #expect(vm.setRehearsalMark(text: "Bridge"))
        #expect(vm.suggestedRehearsalMarkText == "Bridge")
    }

    @Test func `removing drops the mark`() {
        let vm = session(targeting: 1)
        #expect(vm.setRehearsalMark(text: "A"))
        #expect(vm.removeRehearsalMark())
        #expect(vm.targetRehearsalMarkText == nil)
    }

    @Test func `restating the same text reports false without a refusal`() {
        let vm = session(targeting: 1)
        #expect(vm.setRehearsalMark(text: "A"))
        #expect(!vm.setRehearsalMark(text: "A"))
        #expect(vm.session?.lastRefusal?.reason == .nothingToApply)
    }

    @Test func `both writes report through the analytics hook`() {
        let vm = session(targeting: 1)
        var reported: [String] = []
        vm.onRehearsalMarkEdited = { reported.append($0) }
        #expect(vm.setRehearsalMark(text: "A"))
        #expect(vm.removeRehearsalMark())
        #expect(reported == ["set", "remove"])
    }

    /// No session at all — `targetMeasureIndex` is `selectedItem?.measureIndex ?? caretItem?.measureIndex`, and
    /// both are nil before one begins. There is no `clearSelection()` to reach for; this is the shape that makes
    /// "no target" certain rather than dependent on where a fresh session parks its caret.
    @Test func `without a target both writes are a no-op`() {
        let vm = makeViewModel()
        #expect(vm.targetMeasureIndex == nil)
        #expect(!vm.setRehearsalMark(text: "A"))
        #expect(!vm.removeRehearsalMark())
    }

    @Test(arguments: [(0, "A"), (1, "B"), (25, "Z"), (26, "AA"), (27, "AB")])
    func `letters run A to Z then AA`(index: Int, expected: String) {
        #expect(EditorViewModel.rehearsalMarkLetter(at: index) == expected)
    }
}
```

`EditorFixtures.threeMeasuresOfQuarterRests()` and `EditorFixtures.sampleItem()` both exist at `Packages/Features/Editor/Tests/EditorTests/Support/EditorFixtures.swift:162` and `:235`; the fake stores are the same ones `EditorSignatureIntentTests` constructs.

- [ ] **Step 2: Run the tests to verify they fail**

From `Packages/Features/Editor`: `xcodebuild test -scheme Editor -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:EditorTests/EditorRehearsalMarkTests`
Expected: FAIL — `value of type 'EditorViewModel' has no member 'targetRehearsalMarkText'`.

- [ ] **Step 3: Add the analytics factory**

In `Packages/Domain/Sources/Domain/Analytics/AnalyticsEvent+Factories.swift`, immediately after `scoreSignatureChanged`:

```swift
    /// A rehearsal mark written, renamed or removed in the editor. `action` is `"set"` or `"remove"` — a rename is
    /// a `"set"`, because from the score's point of view it is the same write.
    public static func scoreRehearsalMarkEdited(action: String) -> AnalyticsEvent {
        AnalyticsEvent(name: "score_rehearsal_mark_edited", parameters: [
            "action": .string(action),
        ])
    }
```

And in `Packages/Domain/Tests/DomainTests/AnalyticsEventFactoryTests.swift`, next to the `scoreSignatureChanged` test and following its exact style:

```swift
    @Test(arguments: ["set", "remove"])
    func `rehearsal mark edited carries its action`(action: String) {
        let event = AnalyticsEvent.scoreRehearsalMarkEdited(action: action)
        #expect(event.name == "score_rehearsal_mark_edited")
        #expect(event.parameters["action"] == .string(action))
    }
```

- [ ] **Step 4: Add the presentation flag and the hook**

In `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift`, immediately after `isTimeSignatureSheetPresented`:

```swift
    /// Drives the rehearsal-mark sheet. On the view model for the same reason the signature flags are: the row that
    /// raises it folds into the overflow `Menu`, and a `@State` flag owned by a control that can disappear takes the
    /// open sheet with it. No refusal to clear on open, unlike those two — the sheet has no reachable refusal (see
    /// `EditorViewModel+RehearsalMarks.swift`).
    public var isRehearsalMarkSheetPresented = false
```

and after `onSignatureChanged`:

```swift
    /// Fired after a rehearsal-mark edit lands, as `"set"` or `"remove"`. A closure rather than an analytics client,
    /// for the reason `onPartsEdited` gives: the Editor logs nothing itself.
    public var onRehearsalMarkEdited: ((String) -> Void)?
```

- [ ] **Step 5: Write the view model extension**

Create `Packages/Features/Editor/Sources/Editor/EditorViewModel+RehearsalMarks.swift`:

```swift
import Domain
import Foundation
import SheetMusicCore

/// Rehearsal-mark editing as the sheet drives it. Both writes route through the shared `apply(_:)` choke point, so
/// both are undoable and both re-publish the score to the reading surface for free.
///
/// Both address `targetMeasureIndex` — the selection's bar, else the caret's — and are a no-op without one, exactly
/// as the measure and signature ops next door are.
///
/// **No refusal surface, deliberately.** ssm can refuse these two with `.targetNotFound` (an out-of-range bar, which
/// a selection cannot produce) or `.emptyRehearsalMarkText` (which the sheet's disabled Apply button prevents), so
/// there is no reachable refusal for a `lastRehearsalMarkRefusal` to carry. A `false` here means the score already
/// said this — the `.nothingToApply` the session reports for restating a mark's own text, or for removing one from a
/// bar that carries none — and the sheet simply closes on it.
extension EditorViewModel {
    // MARK: - What the sheet opens showing

    /// The rehearsal mark on the target bar, or `nil` when it carries none (and without a target).
    ///
    /// Walks `Score.systemMeasures` directly: a rehearsal mark is a system element rather than a voice element, and
    /// ssm's own `RehearsalMarkLane` is internal to the engine — mirrored here the way `keySignatureReferenceStaff`
    /// mirrors `KeySignatureStaves`.
    public var targetRehearsalMarkText: String? {
        guard let score, let targetMeasureIndex else { return nil }
        return Self.rehearsalMarkText(in: score, measureIndex: targetMeasureIndex)
    }

    /// What the sheet's field opens holding: the target bar's own mark when it has one (the sheet is renaming), and
    /// otherwise the next letter — the letter for however many marks sit in bars BEFORE this one, so a mark added
    /// between A and B is suggested "B" while B itself keeps its name.
    ///
    /// A suggestion, not a rule: the field is free-form, and nothing renumbers anything afterwards.
    public var suggestedRehearsalMarkText: String {
        if let existing = targetRehearsalMarkText { return existing }
        guard let score, let targetMeasureIndex else { return Self.rehearsalMarkLetter(at: 0) }
        let earlier = (0 ..< min(targetMeasureIndex, score.systemMeasures.count)).count {
            Self.rehearsalMarkText(in: score, measureIndex: $0) != nil
        }
        return Self.rehearsalMarkLetter(at: earlier)
    }

    /// A, B, … Z, AA, AB, … — spreadsheet-column lettering, which is what a score does once it runs past Z.
    static func rehearsalMarkLetter(at index: Int) -> String {
        guard index >= 0 else { return "A" }
        var remaining = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + remaining % 26))) + letters
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return letters
    }

    // MARK: - Applying

    /// Writes `text` as the target bar's rehearsal mark, replacing the one it carries or creating one where it
    /// carried none. `false` when there is no target, or when the bar already reads exactly this.
    @discardableResult
    public func setRehearsalMark(text: String) -> Bool {
        guard let targetMeasureIndex else { return false }
        return applyRehearsalMark(
            .setRehearsalMark(measureIndex: targetMeasureIndex, text: text), action: "set",
        )
    }

    /// Drops the target bar's rehearsal mark. `false` when there is no target, or when the bar carries none.
    @discardableResult
    public func removeRehearsalMark() -> Bool {
        guard let targetMeasureIndex else { return false }
        return applyRehearsalMark(.removeRehearsalMark(measureIndex: targetMeasureIndex), action: "remove")
    }

    private func applyRehearsalMark(_ intent: EditIntent, action: String) -> Bool {
        guard apply(intent) else { return false }
        onRehearsalMarkEdited?(action)
        return true
    }

    // MARK: - Reading the score

    /// The first rehearsal mark's text at `measureIndex`, or `nil`. First rather than all: one bar carries one mark
    /// as far as this surface is concerned, which is the same premise ssm's own commands are written on.
    private static func rehearsalMarkText(in score: Score, measureIndex: Int) -> String? {
        guard score.systemMeasures.indices.contains(measureIndex) else { return nil }
        for positioned in score.systemMeasures[measureIndex].elements {
            if case let .rehearsalMark(mark) = positioned.element { return mark.text }
        }
        return nil
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

From `Packages/Features/Editor`: `xcodebuild test -scheme Editor -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:EditorTests/EditorRehearsalMarkTests`
Expected: PASS.

From `Packages/Domain`: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/AnalyticsEventFactoryTests`
Expected: PASS.

- [ ] **Step 7: Commit (folino)**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/scratch-creation-spec add Packages/Features/Editor/Sources/Editor/EditorViewModel+RehearsalMarks.swift Packages/Features/Editor/Sources/Editor/EditorViewModel.swift Packages/Features/Editor/Tests/EditorTests/EditorRehearsalMarkTests.swift Packages/Domain/Sources/Domain/Analytics/AnalyticsEvent+Factories.swift Packages/Domain/Tests/DomainTests/AnalyticsEventFactoryTests.swift
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/scratch-creation-spec commit -m "feat: rehearsal-mark surface on the editor view model"
```

(Do **not** stage `Packages/*/Package.swift` or `project.yml` — they carry the local ssm pin.)

---

### Task 6: folino — the measure-menu row, the sheet, and the strings

**Repo:** folino

**Files:**
- Create: `Packages/Features/Editor/Sources/Editor/Views/EditorRehearsalMarkSheet.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/Screens/EditorTopBarView+Signatures.swift` (one menu row, one `.sheet`)
- Modify: `Packages/Features/Editor/Sources/Editor/Resources/Localizable.xcstrings` (six keys × five locales)
- Modify: `App/EditableReaderScreen.swift` (one analytics wire, next to `onSignatureChanged`)

**Interfaces:**
- Consumes: Task 5's `isRehearsalMarkSheetPresented`, `targetRehearsalMarkText`, `suggestedRehearsalMarkText`, `setRehearsalMark(text:)`, `removeRehearsalMark()`, `onRehearsalMarkEdited`, and the existing `targetMeasureIndex` / `targetDisplayedMeasureNumber`.
- Produces: no API — this is the UI leaf.

- [ ] **Step 1: Add the six strings**

Add these keys to `Packages/Features/Editor/Sources/Editor/Resources/Localizable.xcstrings`, each with `comment` and all five locales `"state": "translated"`, matching the file's existing entry shape exactly (`{"comment": …, "localizations": {"<lang>": {"stringUnit": {"state": "translated", "value": …}}}}`; the file is `version 1.0`, `sourceLanguage en`, and its keys are sorted):

| key | comment | en | ja | ko | zh-Hans | zh-Hant |
| --- | --- | --- | --- | --- | --- | --- |
| `editor.measure.rehearsalMark` | Measure-menu row that opens the rehearsal-mark sheet for the target bar. | `Rehearsal Mark…` | `リハーサルマーク…` | `리허설 마크…` | `排练标记…` | `排練標記…` |
| `editor.rehearsalMark.title` | Title of the sheet that sets the rehearsal mark on one bar. | `Rehearsal Mark` | `リハーサルマーク` | `리허설 마크` | `排练标记` | `排練標記` |
| `editor.rehearsalMark.header %lld` | Section header of the rehearsal-mark sheet. %lld is the bar's displayed measure number. | `Measure %lld` | `%lld小節目` | `%lld번째 마디` | `第%lld小节` | `第%lld小節` |
| `editor.rehearsalMark.header.unnumbered` | Same section header for a bar the score draws no number for (a pickup). | `This Measure` | `この小節` | `이 마디` | `本小节` | `本小節` |
| `editor.rehearsalMark.footer` | Footer explaining where the mark is drawn. | `Drawn at the start of the measure, above the top staff.` | `小節の先頭、最上段の上に表示されます。` | `마디 시작 부분, 맨 위 보표 위에 표시됩니다.` | `显示在小节开头、最上方谱表的上方。` | `顯示在小節開頭、最上方譜表的上方。` |
| `editor.rehearsalMark.remove` | Destructive row that deletes the target bar's rehearsal mark. | `Delete Mark` | `マークを削除` | `마크 삭제` | `删除标记` | `刪除標記` |
| `editor.rehearsalMark.apply` | Confirmation button that writes the typed rehearsal mark. | `Apply` | `適用` | `적용` | `应用` | `套用` |

The last row's wording matches `editor.signature.apply` on purpose, but it gets its own key so the two sheets' copy can diverge later without one silently changing the other.

Verify the file still parses after editing. **Not `plutil -lint`** — it cannot lint JSON on this machine (it fails
identically on pristine `HEAD` and on `{"a":1}`), so a "failure" from it says nothing. Use `python3`, which parses the
file AND can assert the things a broken hand-edit actually produces:

```bash
python3 -m json.tool Packages/Features/Editor/Sources/Editor/Resources/Localizable.xcstrings > /dev/null
python3 -c '
import json
p = "Packages/Features/Editor/Sources/Editor/Resources/Localizable.xcstrings"
d = json.load(open(p))
strings = d["strings"]
assert list(strings) == sorted(strings), "keys are not sorted"
for key in [k for k in strings if k.startswith("editor.rehearsalMark.")]:
    entry = strings[key]
    assert entry.get("comment"), f"{key}: no comment"
    locs = entry["localizations"]
    assert set(locs) == {"en", "ja", "ko", "zh-Hans", "zh-Hant"}, f"{key}: locales {sorted(locs)}"
    for locale, value in locs.items():
        assert value["stringUnit"]["state"] == "translated", f"{key}/{locale}: not translated"
print("ok")
'
```

Strictly stronger than a parse check: it also catches the five-locale gap, a missing comment, a `state` left at
`new`, and keys inserted out of order.

- [ ] **Step 2: Write the sheet**

Create `Packages/Features/Editor/Sources/Editor/Views/EditorRehearsalMarkSheet.swift`:

```swift
import SheetMusicCore
import SwiftUI
import UtilityUI

// PARITY(android): M4 rehearsal mark editing — Android needs the sheet UI; ssm logic is shared

/// Names the target bar. A free-form field seeded with the bar's own mark (a rename) or the next letter, plus the
/// destructive row that takes an existing mark back out.
///
/// Its own view rather than a use of `EditorSignatureSheet`'s scaffold: that one is built around a picker, a
/// "applies until the next change" span, a removal confirmation and a refusal alert, and a rehearsal mark has none
/// of those — it is a point, not a span; its removal is one undoable byte; and no refusal is reachable from here
/// (see `EditorViewModel+RehearsalMarks.swift`).
@MainActor
struct EditorRehearsalMarkSheet: View {
    let viewModel: EditorViewModel
    /// The typed text, seeded once from the target bar. `@State` rather than a computed binding on the view model:
    /// typing must not write the score — Apply is what writes it.
    @State private var text: String

    @Environment(\.dismiss) private var dismiss

    init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
        _text = State(initialValue: viewModel.suggestedRehearsalMarkText)
    }

    /// Whitespace alone is not a mark, and the engine refuses it. Gating Apply here is what keeps that refusal
    /// unreachable from the UI.
    ///
    /// `CharacterSet` is fine here, unlike in ssm: this is an Apple-only app target, not a module that also has
    /// to build for wasm against `FoundationEssentials`. The ssm-side helper is not in scope from folino anyway.
    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // No `textInputAutocapitalization` override: `.characters` would suit "A" / "B" and wreck
                    // "Bridge" and "1サビ", which this field has to take just as readily. The seeded letter is
                    // already uppercase, so the default costs nothing.
                    TextField(text: $text) {
                        Text("editor.rehearsalMark.title", bundle: .module)
                    }
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(apply)
                } header: {
                    header
                } footer: {
                    Text("editor.rehearsalMark.footer", bundle: .module)
                }
                if viewModel.targetRehearsalMarkText != nil {
                    Section {
                        Button(role: .destructive) {
                            viewModel.removeRehearsalMark()
                            dismiss()
                        } label: {
                            Text("editor.rehearsalMark.remove", bundle: .module)
                        }
                    }
                }
            }
            .navigationTitle(Text("editor.rehearsalMark.title", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
    }

    /// The bar being named. An unnumbered bar (a pickup) is named "this measure": the score draws no number there,
    /// so there is none to quote — the same rule `EditorSignatureSheet`'s header follows.
    private var header: Text {
        if let number = viewModel.targetDisplayedMeasureNumber {
            Text("editor.rehearsalMark.header \(number)", bundle: .module)
        } else {
            Text("editor.rehearsalMark.header.unnumbered", bundle: .module)
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: { L10n.Common.cancel }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(action: apply) {
                Text("editor.rehearsalMark.apply", bundle: .module)
            }
            .disabled(trimmed.isEmpty)
        }
    }

    /// Writes the field and closes. The write's `false` is deliberately discarded — unlike the signature sheet
    /// there is nothing to keep this sheet up FOR, since a `false` here only ever means the bar already reads
    /// exactly this, which is the state the user asked for.
    ///
    /// The empty guard is for `onSubmit`, which fires on the keyboard's Done regardless of what Apply's own
    /// `disabled` says.
    private func apply() {
        guard !trimmed.isEmpty else { return }
        viewModel.setRehearsalMark(text: trimmed)
        dismiss()
    }
}

#if DEBUG
#Preview("Rehearsal mark — new") {
    EditorRehearsalMarkSheetPreviews.sheet(withExistingMark: false)
}

#Preview("Rehearsal mark — rename") {
    EditorRehearsalMarkSheetPreviews.sheet(withExistingMark: true)
}

/// The fixture behind both previews: three bars of quarter rests with bar 1 selected, optionally already carrying a
/// mark so the destructive Section is one flag away.
///
/// The score is built inline rather than shared, because the Editor package has no common preview fixture —
/// `EditorSignatureSheetPreviews.score()` next door builds its own for the same reason, and `EditorFixtures` is in
/// the test target and unreachable from here.
@MainActor
enum EditorRehearsalMarkSheetPreviews {
    private static func score() -> Score {
        let staff = Staff(measures: (0 ..< 3).map { _ in
            Measure(voices: [Voice(elements: Array(repeating: .rest(duration: .quarter), count: 4))])
        })
        return Score(division: 480, parts: [
            Part(id: "1", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
    }

    static func sheet(withExistingMark: Bool) -> some View {
        let viewModel = PreviewEditorFactory.makeViewModel()
        viewModel.beginSession(score: score())
        viewModel.select(.rest(RestID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 1, voiceIndex: 0, elementIndex: 0,
        )))
        if withExistingMark {
            viewModel.setRehearsalMark(text: "B")
        }
        return EditorRehearsalMarkSheet(viewModel: viewModel)
    }
}
#endif
```

`PreviewEditorFactory.makeViewModel()` is declared in `Views/EditorPadView.swift` with a single defaulted `armedDuration:` parameter, so the no-argument call above is correct.

- [ ] **Step 3: Add the menu row and the presentation**

In `Packages/Features/Editor/Sources/Editor/Screens/EditorTopBarView+Signatures.swift`, append to `signatureMenuRows` after the time-signature `Button`:

```swift
        Button {
            viewModel.isRehearsalMarkSheetPresented = true
        } label: {
            Label {
                Text("editor.measure.rehearsalMark", bundle: .module)
            } icon: {
                Image(systemName: "a.square")
            }
        }
        .disabled(viewModel.targetMeasureIndex == nil)
```

and to `signatureSheets(on:)`:

```swift
            .sheet(isPresented: $viewModel.isRehearsalMarkSheetPresented) {
                EditorRehearsalMarkSheet(viewModel: viewModel)
            }
```

Then widen that file's two doc comments, which currently say "Both signature rows" and "Presents both sheets": make them "The signature rows and the rehearsal-mark row" / "Presents all three sheets", keeping the reasoning sentences (the measure menu is where "what is true of THIS bar" lives; a presentation attached to a control that can disappear takes the open sheet with it) intact. Rename nothing — the file name and the two member names stay as they are; a third bar-scoped row is not a reason to churn the call sites in `EditorTopBarView.swift`.

- [ ] **Step 4: Wire the analytics**

In `App/EditableReaderScreen.swift`, immediately after the `vm.onSignatureChanged = …` block:

```swift
        // Same seam, same reason, for the rehearsal-mark sheet.
        vm.onRehearsalMarkEdited = { [analytics] action in
            analytics.log(.scoreRehearsalMarkEdited(action: action))
        }
```

- [ ] **Step 5: Render the two previews**

Use `mcp__xcode__RenderPreview` on `EditorRehearsalMarkSheet.swift` (per the global iOS workflow: previews before the simulator) and `Read` the resulting PNGs. Confirm: the header names the bar, the field is seeded ("A" for a new mark, "B" for the rename fixture), the footer reads at width without clipping, and the Delete row appears only in the rename preview.

- [ ] **Step 6: Build and test**

```bash
xcodegen generate
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```

From `Packages/Features/Editor`:

```bash
xcodebuild test -scheme Editor -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Expected: build succeeds and the whole Editor suite passes (not just the new one — the menu rows are covered by existing snapshot/behavior tests in some layouts).

- [ ] **Step 7: Confirm the reading surface refreshes (no code expected)**

`ReaderViewModel.adoptEditedScore(_:)` — the path that takes an edited score back from the editing session — already calls `recomputeSeekTimeline()` on the line after `recomputeVisibleScore()`, and `recomputeSeekTimeline` rebuilds `ReaderSeekTimeline(score:)`, which is what reads `Score.rehearsalMarks()`. So the mark bar picks up an added or renamed mark with no wiring of its own.

Nothing to write here; this step exists because a rehearsal mark is the first edit that changes what the mark bar itself displays rather than only the notes, and "it just works" is worth confirming by eye once (smoke item 5 below is the runtime check). Report that it was confirmed rather than leaving the step silently ticked.

- [ ] **Step 8: Commit (folino)**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/scratch-creation-spec add Packages/Features/Editor/Sources/Editor/Views/EditorRehearsalMarkSheet.swift Packages/Features/Editor/Sources/Editor/Screens/EditorTopBarView+Signatures.swift Packages/Features/Editor/Sources/Editor/Resources/Localizable.xcstrings App/EditableReaderScreen.swift
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/scratch-creation-spec commit -m "feat: rehearsal mark editing from the measure menu"
```

---

## Final verification

- [ ] **ssm full gates** — from the ssm worktree root: `xcrun swift test`; `Scripts/preflight.sh --apple`; `Scripts/preflight.sh --android`; `Scripts/wasm-build-web.sh` then `npm --prefix Web/sheet-music-web test`. (`--wasm` stays parked, see Task 4 Step 7.)
- [ ] **folino full build + Editor, Domain and Reader package suites** green.
- [ ] **`git status` in folino** shows only the six pin files modified and nothing else uncommitted.
- [ ] **Device smoke script** — hand to the user, on a score created from scratch and on an imported one:
  1. Select a bar mid-score → measure menu → Rehearsal Mark… → the field is seeded "A" → Apply. The boxed A draws above the top staff at the bar's start.
  2. Reopen the sheet on that bar → the field reads "A" and a Delete Mark row is present. Rename it to a CJK string ("1サビ") → Apply → the mark redraws with the new text.
  3. Add marks on two later bars → they suggest "B" then "C"; the earlier marks are NOT renumbered.
  4. Undo three times → each mark disappears in reverse order; redo restores them.
  5. Leave the edit session, reopen the score in the reading surface → the rehearsal-mark bubbles above the seek bar carry the new marks and tapping one seeks to its bar.
  6. Save, close the app, reopen → the marks survive the mscz round-trip.
  7. On a bar with a mark: Delete Mark → it is gone with no confirmation dialog, and one undo brings it back.
  8. On the pickup bar of a score created with an anacrusis: the sheet header reads "This Measure" rather than a number.
- [ ] **Update `MEMORY.md` / `project_scratch_creation_and_pro.md`** — tick M4, record the ssm and folino head SHAs, and carry forward anything the smoke test surfaces as still-open.

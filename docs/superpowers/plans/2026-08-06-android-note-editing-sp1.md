# SP1 — Planners, Selection, Geometry (swift-sheet-music) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every piece of note-editing logic and geometry that both platforms must share out of Folino and out of `SheetMusicUI` into platform-neutral swift-sheet-music targets, complete the intent vocabulary, and expose selection hit-testing, the caret rect and a re-tinted draw program over JNI — so SP2/SP3 have one implementation to call from both sides.

**Architecture:** Three moves and one extraction. (1) The seven planners move from Folino's `Editor` package into `SheetMusicCore/Editing/Planners/`, and `ScoreEditSession.apply` becomes the choke point that runs them — cross-bar interception, full-measure-rest collapse, and the `MeasureAccidentals` renotation bundle — so an intent plans into identical commands in both images. (2) `Selection/` moves from `SheetMusicUI` into `SheetMusicLayout`, with only `CGColor` resolution left Apple-side, and Folino's hit-test policy and caret-rect geometry move down with it as `LayoutDocument` methods. (3) The wire codecs move into a new Android-gated `SheetMusicEditWire` product that ssm's JNI target and (in SP3) Folino's `FolinoEditorJNI` both link, so one frozen schema has exactly one declaration.

**Tech Stack:** Swift 6.3, swift-sheet-music (`SheetMusicCore`, `SheetMusicLayout`, `SheetMusicUI`, `SheetMusicAndroidJNI`, new `SheetMusicEditWire`), swift-wirelet `@WireFormat*` macros, swift-java jextract, Kotlin/Gradle (`Android/SheetMusicAndroid`), Swift Testing, AndroidJUnit4.

## Global Constraints

- **All work happens in the ssm worktree** `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing` (branch `android-note-editing`). Never in the primary ssm checkout at `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music`. Use absolute paths or `git -C <worktree>`; a subagent that runs a bare `git commit` lands it in the wrong checkout.
- **No Folino source changes in SP1.** The planners are *copied into* ssm here; Folino keeps its own copies until SP2 deletes them and re-pins. The only Folino file this plan writes is this plan document itself.
- Host builds and tests use `xcrun swift …` (the plain `swift` shim can resolve to an uninstalled toolchain). Android cross-compilation uses the release toolchain the repo's own scripts prepend: `/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin`.
- Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`) for new Swift tests. `--filter` matches the **type** name, not the `@Suite` display name.
- **The wire discriminator order is append-only.** `EditIntentWire`'s existing cases 0–4 (`inputNote`, `setRestDuration`, `setChordDuration`, `delete`, `composite`) keep their indices; new intents append at 5 and up. Same rule for `DrawCommand` and every `@WireFormatChoice` this plan touches.
- No randomness, no clock reads in the replay tests. A determinism test that is itself nondeterministic proves nothing.
- Comment paragraphs reflow at 120 columns. American spelling except where an Apple/framework API name dictates otherwise (`cancelled`).
- **iOS behavior must not change.** Every type this plan relocates keeps its public name and semantics; `SheetMusicUI` re-exports what moved so no Apple-side call site has to be rewritten. The Apple-side test suites are the gate.
- ssm `main` is at **1.9.0**. SP1 releases **1.10.0** (Task 13). SP0's memory note said "1.9.0" — that version was taken by the measure-number work that landed on main meanwhile.

## Read before starting

`docs/superpowers/plans/2026-08-06-android-note-editing-sp0.md` § "Findings — SP0 as executed". Four assumptions in the design spec were wrong, and three of the findings are direct inputs to tasks here:

- **The wire is protobuf-style TLV with LEB128 varints and zig-zag signed ints**, not fixed-width little-endian. `EditIntentCodec.swift`'s doc comment is the only accurate description in the repo; three older codec files still carry stale fixed-width comments. Task 5 moves two of those three files — correct their comments as you move them.
- **`CrossBarInputPlanner` must intercept before the composite is built** (Task 2). `SetRestDuration` refuses for four reasons besides tuplets, and each refusal takes the note write down with it. The user ruled: keep iOS parity, and verify the interception here.
- **`EditReplayDeterminismTests`'s fixture is one measure, one voice, one staff, no rests, no tuplets, no `.locationShift`.** Do not cite it as proof of anything broader until Task 12 replaces it.

## File structure

| File | Responsibility |
| --- | --- |
| `Sources/SheetMusicCore/Editing/Planners/{MeasureAccidentals,CrossBarInputPlanner,FullMeasureRestCollapse,NoteInputPlanner,TiePlanner,IntervalPlanner,StaffStepPitch}.swift` (create) | The seven planners, moved from Folino verbatim, made `public`. |
| `Sources/SheetMusicCore/Editing/ScoreEditSession.swift` (modify) | Plans an intent through the planners; bundles accidental repairs; handles the new intents. |
| `Sources/SheetMusicCore/Editing/EditIntent.swift` (modify) | The remaining seven intent cases. |
| `Sources/SheetMusicCore/Score/ScoreFingerprint.swift` (modify) | Walk the fields the new intents can reach. |
| `Sources/SheetMusicEditWire/…` (create) | New Android-gated target: `EditIntentCodec`, `PathIDCodecs`, `StaffAddressCodec`, `ScoreItemIDCodec`, `ClefAnchorCodec`, `EditGeometryCodec`. |
| `Sources/SheetMusicLayout/Selection/{ScoreSelection,ScoreHitTarget,ScoreHitTester,ScoreHitTester+Marquee,SelectionExpansion}.swift` (create) | Selection model + hit-test ladder, moved out of `SheetMusicUI`. |
| `Sources/SheetMusicLayout/Selection/LayoutDocument+Editing.swift` (create) | `editingHitTest(at:activeVoice:)` and `editingCaretRect(for:in:)` — Folino's policies, moved down. |
| `Sources/SheetMusicUI/Selection/SelectionRenderState.swift` (modify) | Keeps only `CGColor` resolution; delegates ID expansion to `SelectionExpansion`. |
| `Sources/SheetMusicAndroidJNI/LayoutBridge+Selection.swift` (create) | Re-encode a cached layout with selected IDs tinted. |
| `Sources/SheetMusicAndroidJNI/Editing/EditGeometryBridge.swift` (create) | `nativeEditingHitTest`, `nativeEditingCaretFrame`, `nativeEncodeDrawProgram`. |
| `Tests/SheetMusicTests/EditingTests/Planners/…` (create) | Direct unit tests for the moved planners. |
| `Tests/SheetMusicTests/EditingTests/EditingFixtures.swift` (create) | Programmatic `Score` fixtures, moved from Folino's `EditorFixtures`. |
| `Android/SheetMusicAndroid/src/main/kotlin/.../SheetMusicJNI.kt` (modify) | Kotlin facade for the three new entry points. |

---

### Task 1: Move the seven planners into `SheetMusicCore`

The seven are pure `Score` → plan functions. They currently sit in
`Packages/Features/Editor/Sources/Editor/` in Folino and are the reason an
Android host would otherwise have to reimplement editing logic. Four of them
declare `import Domain`, which is unused — Folino's `Domain` re-exports
`SheetMusicCore`, so dropping that line is the whole port.

Folino's own tests for these are split: `NoteInputPlannerTests`,
`TiePlannerTests`, `IntervalPlannerTests`, `StaffStepPitchTests` call the
planners directly and port over; `MeasureAccidentalsTests` and
`CrossBarInputTests` drive `EditorViewModel` and stay in Folino, where SP2 keeps
them passing against the relocated types. This task therefore ports the four
direct suites and writes direct coverage for the other two.

**Files:**
- Create: `Sources/SheetMusicCore/Editing/Planners/MeasureAccidentals.swift`
- Create: `Sources/SheetMusicCore/Editing/Planners/CrossBarInputPlanner.swift`
- Create: `Sources/SheetMusicCore/Editing/Planners/FullMeasureRestCollapse.swift`
- Create: `Sources/SheetMusicCore/Editing/Planners/NoteInputPlanner.swift`
- Create: `Sources/SheetMusicCore/Editing/Planners/TiePlanner.swift`
- Create: `Sources/SheetMusicCore/Editing/Planners/IntervalPlanner.swift`
- Create: `Sources/SheetMusicCore/Editing/Planners/StaffStepPitch.swift`
- Create: `Tests/SheetMusicTests/EditingTests/EditingFixtures.swift`
- Create: `Tests/SheetMusicTests/EditingTests/Planners/NoteInputPlannerTests.swift`
- Create: `Tests/SheetMusicTests/EditingTests/Planners/TiePlannerTests.swift`
- Create: `Tests/SheetMusicTests/EditingTests/Planners/IntervalPlannerTests.swift`
- Create: `Tests/SheetMusicTests/EditingTests/Planners/StaffStepPitchTests.swift`
- Create: `Tests/SheetMusicTests/EditingTests/Planners/MeasureAccidentalsPlannerTests.swift`
- Create: `Tests/SheetMusicTests/EditingTests/Planners/CrossBarInputPlannerTests.swift`

**Interfaces:**
- Consumes: `NoteInputKeyMap` (already in `SheetMusicCore/Editing/`), `Score`, `Note`, `NoteDuration`, `VoiceElementID`, `RestID`, `NoteID`, `EditCommand`, `ReplaceVoiceElements`.
- Produces, all `public`:
  - `MeasureAccidentals.plannedPitch(...)` and `MeasureAccidentals.renotationCommands(in:changedFrom:) -> [any EditCommand]`
  - `CrossBarInputPlanner.Content` (`.note(pitch:tpc:)` / `.rest` — copy the real cases), `CrossBarInputPlanner.Plan`, `CrossBarInputPlanner.plan(_:duration:at:in:) -> Plan?`, `CrossBarInputPlanner.fitsInMeasure(_:at:in:) -> Bool`
  - `FullMeasureRestCollapse.Plan`, `FullMeasureRestCollapse.plan(deleting:in:) -> Plan?`
  - `NoteInputPlanner.pitch(forLetter:nearestTo:) -> (pitch: Int, tpc: Int)?`
  - `TiePlanner.tieTarget(for:in:) -> NoteID?`
  - `IntervalPlanner.diatonicThirdAbove(_:keySig:)`, `IntervalPlanner.octaveAbove(_:)`
  - `StaffStepPitch.diatonicShift(from:bySteps:keySig:)`, `StaffStepPitch.inKeyTpc(naturalTpc:keySig:)`
  - `EditingFixtures` (test-only): `fourQuarterRests()`, `twoMeasuresOfQuarterRests()`, `twoMeasuresOfQuarterRests(key:)`, `threeMeasuresOfQuarterRests()`, `chordAtIndex1()`, `twoNoteChordAtIndex1()`, `twoConsecutiveC4Chords()`, `c4ThenD4Chords()`, `c4AcrossBarline()`, `restID(measure:element:)`, `noteID(measure:element:noteIndex:)`, `staff0`

- [ ] **Step 1: Copy the seven files**

Source directory:
`/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Packages/Features/Editor/Sources/Editor/`

Copy each of the seven into
`Sources/SheetMusicCore/Editing/Planners/` **verbatim**, then make exactly these
edits and no others:

1. Delete the `import Domain` line where present (`CrossBarInputPlanner`,
   `TiePlanner`, `FullMeasureRestCollapse`).
2. Delete the `import SheetMusicCore` line — they are now inside that module.
3. Add `public` to the top-level `enum` and to every `static func`, nested
   `enum`/`struct`, and their stored properties and initializers that a caller
   outside `SheetMusicCore` needs. `MeasureAccidentals` also has internal
   helpers — leave those internal.

Do not "improve" anything while moving. A behavior change hidden in a move is
the one thing SP2's Folino tests cannot distinguish from a port bug.

- [ ] **Step 2: Compile the target**

Run: `xcrun swift build --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --target SheetMusicCore`
Expected: BUILD SUCCEEDED. Fix only missing-`public` errors and the two import
lines; anything else means the copy diverged.

- [ ] **Step 3: Port the fixture builder**

Create `Tests/SheetMusicTests/EditingTests/EditingFixtures.swift` from Folino's
`Packages/Features/Editor/Tests/EditorTests/Support/EditorFixtures.swift`,
keeping every `Score`-returning member and dropping `sampleItem()` (that returns
Folino's `ScoreItem`, which does not exist here). Header:

```swift
import Foundation
@testable import SheetMusicCore

/// Programmatic score fixtures for the editing tests. Moved from Folino's `EditorFixtures` so both sides build the
/// same shapes — a fixture that drifts between the two repos would make an SP2 regression look like a port bug.
enum EditingFixtures {
    static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    // …the rest verbatim from EditorFixtures, minus sampleItem()
}
```

- [ ] **Step 4: Port the four direct test suites**

Copy `NoteInputPlannerTests.swift`, `TiePlannerTests.swift`,
`IntervalPlannerTests.swift`, `StaffStepPitchTests.swift` into
`Tests/SheetMusicTests/EditingTests/Planners/`. Edits: replace
`import Domain` + `@testable import Editor` with `@testable import SheetMusicCore`,
rename `EditorFixtures` → `EditingFixtures`, and drop `@MainActor` from any suite
that carries it (nothing here needs the main actor now that `ScoreEditor` does
not).

- [ ] **Step 5: Write direct tests for the two planners whose Folino tests stay behind**

`MeasureAccidentalsPlannerTests` — three tests, calling the planner directly
rather than through a view model:

```swift
import Foundation
@testable import SheetMusicCore
import Testing

@Suite("MeasureAccidentals (direct)")
struct MeasureAccidentalsPlannerTests {
    /// D major: F and C are sharp, so the letter F must plan the ALTERED pitch, and the glyph must stay nil —
    /// the key signature already says it.
    @Test func `a letter key plans the pitch the key signature spells`() throws {
        let score = EditingFixtures.twoMeasuresOfQuarterRests(key: 2)
        let slot = EditingFixtures.restID(element: 2)
        let planned = try #require(MeasureAccidentals.plannedPitch(
            forLetter: "f", at: VoiceElementID(slot), in: score, referencePitch: nil,
        ))
        #expect(planned.pitch % 12 == 6) // F#
        #expect(planned.accidental == nil)
    }

    /// A bar whose first C is flipped to natural leaves the SECOND C reading natural to the eye while it still
    /// sounds sharp. The renotation pass is what repairs that.
    @Test func `renotation repairs a later note in the same bar`() throws {
        var previous = EditingFixtures.twoMeasuresOfQuarterRests(key: 2)
        // Two C#5 quarters in bar 0 (elements 2 and 3), then flatten the first to C natural.
        let first = VoiceElementID(EditingFixtures.restID(element: 2))
        let second = VoiceElementID(EditingFixtures.restID(element: 3))
        previous[first] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 73, tpc: 21)]))
        previous[second] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 73, tpc: 21)]))
        var current = previous
        current[first] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 72, tpc: 14)]))
        let repairs = MeasureAccidentals.renotationCommands(in: current, changedFrom: previous)
        #expect(!repairs.isEmpty)
    }

    @Test func `an unchanged bar needs no repairs`() {
        let score = EditingFixtures.twoMeasuresOfQuarterRests(key: 2)
        #expect(MeasureAccidentals.renotationCommands(in: score, changedFrom: score).isEmpty)
    }
}
```

If `plannedPitch`'s real parameter labels differ from the sketch above, use the
real ones — read the moved file, do not guess.

`CrossBarInputPlannerTests` — two tests:

```swift
import Foundation
@testable import SheetMusicCore
import Testing

@Suite("CrossBarInputPlanner (direct)")
struct CrossBarInputPlannerTests {
    /// A half note armed at the last quarter of a 4/4 bar does not fit — the planner must answer with a plan
    /// rather than nil, because the alternative (letting SetRestDuration refuse) takes the note write down too.
    @Test func `a duration that overruns the barline produces a plan`() {
        let score = EditingFixtures.twoMeasuresOfQuarterRests()
        let last = VoiceElementID(EditingFixtures.restID(element: 4))
        #expect(!CrossBarInputPlanner.fitsInMeasure(.half, at: last, in: score))
        #expect(CrossBarInputPlanner.plan(.rest, duration: .half, at: last, in: score) != nil)
    }

    @Test func `a duration that fits needs no plan`() {
        let score = EditingFixtures.twoMeasuresOfQuarterRests()
        let first = VoiceElementID(EditingFixtures.restID(element: 2))
        #expect(CrossBarInputPlanner.fitsInMeasure(.quarter, at: first, in: score))
        #expect(CrossBarInputPlanner.plan(.rest, duration: .quarter, at: first, in: score) == nil)
    }
}
```

- [ ] **Step 6: Run the new suites**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter NoteInputPlannerTests
```

Repeat for `TiePlannerTests`, `IntervalPlannerTests`, `StaffStepPitchTests`,
`MeasureAccidentalsPlannerTests`, `CrossBarInputPlannerTests`.
Expected: all pass, 0 failures.

- [ ] **Step 7: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing add Sources/SheetMusicCore/Editing/Planners Tests/SheetMusicTests/EditingTests
```
```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -m "feat(editing): move the seven note-input planners into SheetMusicCore"
```

---

### Task 2: `ScoreEditSession` plans through the planners

Today `apply` maps an intent straight onto one command. That is why SP0's own
findings say "this branch alone cannot drive real editing": no accidental
repairs, no cross-bar interception, no full-measure-rest collapse. This task
makes `apply` the choke point the spec's §5.1 describes, which is what lets the
two images plan identically from scalars.

Three behaviors, in this order:

1. **Cross-bar interception** — before building the `SetRestDuration` +
   `InputNote` composite for `.inputNote(…, duration:)`, ask
   `CrossBarInputPlanner`. When it answers with a plan, use the plan's commands
   instead. This is the finding the user ruled on: `SetRestDuration` refuses for
   four reasons besides tuplets and each refusal takes the note write with it;
   iOS only escapes the common case because the cross-bar planner runs first.
2. **Full-measure-rest collapse** — `.delete` asks `FullMeasureRestCollapse`
   first, and uses its plan when a delete would empty the bar.
3. **Accidental renotation** — every successfully planned command is wrapped by
   the equivalent of Folino's `renotatingAccidentals`: apply to a throwaway copy,
   ask `MeasureAccidentals.renotationCommands(in:changedFrom:)`, and bundle any
   repairs into one `CompositeEditCommand` so they share the edit's undo step.

**Files:**
- Modify: `Sources/SheetMusicCore/Editing/ScoreEditSession.swift`
- Test: `Tests/SheetMusicTests/EditingTests/ScoreEditSessionTests.swift` (extend)
- Re-record: `Android/SheetMusicAndroid/src/androidTest/assets/editReplay/`

**Interfaces:**
- Consumes: Task 1's planners.
- Produces: unchanged public surface — `apply(_:) -> Bool`, `undo()`, `redo()`, `score`, `lastAffectedLocation`, `lastRefusalReason`. Only the commands it builds change.

- [ ] **Step 1: Write the failing tests**

Append to `ScoreEditSessionTests.swift`:

```swift
    /// A half note armed on the last quarter of a 4/4 bar. Without the cross-bar interception the composite's
    /// SetRestDuration is refused and takes the note write down with it, so nothing appears at all.
    @Test func `an overrunning duration still writes the note`() throws {
        let session = ScoreEditSession(score: EditingFixtures.twoMeasuresOfQuarterRests())
        let target = EditingFixtures.restID(element: 4)
        #expect(session.apply(.inputNote(at: target, pitch: 60, tpc: 14, duration: .half)))
        let written = try #require(session.score[VoiceElementID(target)])
        guard case let .chord(chord) = written else { Issue.record("expected a chord"); return }
        #expect(!chord.notes.isEmpty)
    }

    /// Flipping a bar's first C# to C natural leaves the bar's second C# reading natural. The repairs ride the same
    /// undo step, so ONE undo puts both back.
    @Test func `accidental repairs ride the same undo step`() throws {
        var score = EditingFixtures.twoMeasuresOfQuarterRests(key: 2)
        let first = VoiceElementID(EditingFixtures.restID(element: 2))
        let second = VoiceElementID(EditingFixtures.restID(element: 3))
        score[first] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 73, tpc: 21)]))
        score[second] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 73, tpc: 21)]))
        let session = ScoreEditSession(score: score)
        let before = session.score.stableFingerprint
        #expect(session.apply(.setNotePitch(
            at: EditingFixtures.noteID(element: 2), pitch: 72, tpc: 14, accidental: .natural,
        )))
        #expect(session.score.stableFingerprint != before)
        #expect(session.undo())
        #expect(session.score.stableFingerprint == before)
    }

    /// Deleting the only element of a bar leaves ONE measure rest, not an empty bar.
    @Test func `a delete that empties a bar collapses to a measure rest`() throws {
        var score = EditingFixtures.twoMeasuresOfQuarterRests()
        let slot = VoiceElementID(EditingFixtures.restID(measure: 1, element: 0))
        score[slot] = .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)]))
        score.parts[0].staves[0].measures[1].voices[0].elements.removeSubrange(1...)
        let session = ScoreEditSession(score: score)
        #expect(session.apply(.delete(at: slot)))
        let elements = session.score.parts[0].staves[0].measures[1].voices[0].elements
        #expect(elements.count == 1)
        guard case let .chord(rest) = elements[0] else { Issue.record("expected a rest"); return }
        #expect(rest.notes.isEmpty)
        #expect(rest.duration == .measure)
    }
```

The second test uses `.setNotePitch`, which Task 3 adds. Write it now and expect
it not to compile until Task 3 — or, if executing strictly task-by-task, stage
that one test in Task 3 instead and note it here. The other two must fail
against the current `apply`.

- [ ] **Step 2: Run them to see them fail**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter ScoreEditSessionTests
```
Expected: the overrunning-duration test FAILS ("expected a chord" or an empty
notes array), the collapse test FAILS.

- [ ] **Step 3: Rewrite the planning path**

In `ScoreEditSession`, replace the body of `apply` and `command(for:in:depth:)`:

```swift
    @discardableResult
    public func apply(_ intent: EditIntent) -> Bool {
        let planned: (any EditCommand)?
        do {
            planned = try Self.command(for: intent, in: editor.score, depth: 0)
        } catch {
            lastRefusalReason = Self.reason(for: error)
            return false
        }
        guard let planned else {
            lastRefusalReason = "intent resolved to nothing to apply"
            return false
        }
        do {
            try editor.apply(Self.renotatingAccidentals(planned, from: editor.score))
        } catch {
            lastRefusalReason = Self.reason(for: error)
            return false
        }
        lastRefusalReason = nil
        return true
    }

    /// `command` with the accidental-glyph repairs its own edit makes necessary bundled onto it, as one undo step —
    /// or `command` untouched when it needs none (the common case) or when the engine would refuse it anyway.
    ///
    /// A stored glyph is only true relative to what precedes it in the bar, so any edit that changes a pitch, adds a
    /// note, or removes one can leave a LATER note in that bar saying the wrong thing. MuseScore re-runs its
    /// accidental state over the measure after every such edit; `MeasureAccidentals` is that pass, and this is where
    /// it hangs. Both images run it, from the same scalars, which is why the repairs never have to cross the wire.
    ///
    /// The repairs are planned against the POST-edit score, so the command is applied to a throwaway copy first.
    /// That copy is also what tells us a refused edit needs no repairs at all.
    private static func renotatingAccidentals(_ command: any EditCommand, from score: Score) -> any EditCommand {
        var preview = score
        guard (try? command.apply(to: &preview)) != nil else { return command }
        let repairs = MeasureAccidentals.renotationCommands(in: preview, changedFrom: score)
        guard !repairs.isEmpty else { return command }
        return CompositeEditCommand(commands: [command] + repairs, location: command.affectedLocation)
    }
```

And in `command(for:in:depth:)`, replace the `.inputNote` and `.delete` branches:

```swift
        case let .inputNote(location, pitch, tpc, duration):
            let write = InputNote(at: location, pitch: pitch, tpc: tpc)
            guard let duration else { return write }
            let slot = VoiceElementID(location)
            // A length change inside a tuplet is refused by the engine, and the refusal takes the note write down
            // with it — the second and later notes of a triplet simply never appear. Inside a tuplet the note is
            // written at whatever length the slot already has.
            guard !isInTuplet(slot, in: score) else { return write }
            // The armed length may overrun the barline. Ask the cross-bar planner FIRST: SetRestDuration refuses
            // for four reasons besides tuplets, and every one of those refusals would take the note write with it.
            // iOS only escapes the common case because this interception runs before the composite is built.
            if let plan = CrossBarInputPlanner.plan(
                .note(pitch: pitch, tpc: tpc), duration: duration, at: slot, in: score,
            ) {
                return CompositeEditCommand(commands: plan.commands, location: slot)
            }
            return CompositeEditCommand(
                commands: [SetRestDuration(at: slot, duration: duration), write],
                location: slot,
            )
```

```swift
        case let .delete(location):
            // A delete that empties its bar leaves ONE measure rest, not a hole — the same rule the write side
            // spells as `.measure` rather than `.whole`.
            if let plan = FullMeasureRestCollapse.plan(deleting: location, in: score) {
                return CompositeEditCommand(commands: plan.commands, location: location)
            }
            return DeleteVoiceElement(at: location)
```

Use the planners' real member names for `plan.commands` / `Content` — read the
moved files. If `Plan` exposes a single command rather than an array, pass it
directly rather than wrapping a one-element composite.

Also update `.setRestDuration` the same way if `CrossBarInputPlanner.plan(.rest, …)`
is what Folino's `EditorViewModel+Input.swift:102` does for the rest key — check
that call site and mirror it.

- [ ] **Step 4: Run the tests**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter ScoreEditSessionTests
```
Expected: PASS.

- [ ] **Step 5: Re-record the replay goldens**

`apply` now bundles repairs, so SP0's committed fingerprints are stale by
design. Re-record, then verify:

```
SM_EDIT_REPLAY_RECORD=1 xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter EditReplayGoldenTests
```
```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter EditReplayGoldenTests
```
Expected: the first run rewrites `editReplay/`, the second passes with no
override. Review the diff:
```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing diff --stat Android/SheetMusicAndroid/src/androidTest/assets/editReplay
```
A changed `goldens.txt` is expected. A changed `step-N.bin` is **not** — the wire
did not change in this task. If one changed, stop and find out why.

- [ ] **Step 6: Run the whole host suite**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing
```
Expected: 0 failures. `EditReplayDeterminismTests` will still pass — its fixture
has no accidentals to repair, which is exactly the narrowness Task 12 fixes.

- [ ] **Step 7: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -am "feat(editing): plan an intent through the planners, repairs and all"
```

---

### Task 3: The remaining intents

SP0 shipped four intents plus `composite`. The spec's §4.1 vocabulary needs
seven more. All of them exist as `EditCommand`s already — this is a mapping
task, plus validation.

**Watch `CreateTuplet`:** its `init` has `precondition(actualNotes > 1)` and
`precondition(normalNotes > 0)` — traps, not throws. A wire-decoded intent
carrying `0` would kill the process on a path the bridge advertises as returning
`false`. Validate in `command(for:)` before constructing, exactly as SP0's
`NoteDurationWire.decoded()` had to guard `Fraction`'s denominator.

**Files:**
- Modify: `Sources/SheetMusicCore/Editing/EditIntent.swift`
- Modify: `Sources/SheetMusicCore/Editing/ScoreEditSession.swift`
- Test: `Tests/SheetMusicTests/EditingTests/ScoreEditSessionTests.swift`

**Interfaces:**
- Consumes: `SetNotePitch`, `SetAccidental`, `AddNoteToChord`, `RemoveNoteFromChord`, `SetTie`, `CreateTuplet`, `RemoveTuplet` (all in `SheetMusicCore/Editing/`).
- Produces: seven new `EditIntent` cases, appended after `delete` and **before** `composite` is not allowed — append at the end, after `composite`, so the existing wire indices 0–4 hold.

- [ ] **Step 1: Extend the enum**

```swift
public enum EditIntent: Sendable, Equatable {
    /// Write a note into a rest slot. `duration` retimes the slot in the same undo step; `nil` keeps the slot's
    /// current length.
    case inputNote(at: RestID, pitch: Int, tpc: Int, duration: NoteDuration?)
    case setRestDuration(at: VoiceElementID, duration: NoteDuration)
    case setChordDuration(at: VoiceElementID, duration: NoteDuration)
    case delete(at: VoiceElementID)
    /// Several intents as one undo step.
    indirect case composite([EditIntent])
    // Appended in SP1. The five above are wire indices 0…4 and must keep them.
    case setNotePitch(at: NoteID, pitch: Int, tpc: Int, accidental: Accidental?)
    case setAccidental(at: NoteID, accidental: Accidental?)
    case addNoteToChord(at: VoiceElementID, pitch: Int, tpc: Int, accidental: Accidental?)
    case removeNoteFromChord(at: NoteID)
    case setTie(from: NoteID, to: NoteID, sourceTieForward: Int?, targetTieBack: Int?)
    case createTuplet(at: VoiceElementID, actualNotes: Int, normalNotes: Int)
    case removeTuplet(at: VoiceElementID)
}
```

Keep the existing doc comment, and extend its last paragraph: "The case order is
part of the wire format (`EditIntentWire`). Append; never renumber."

- [ ] **Step 2: Write the failing tests**

Append to `ScoreEditSessionTests.swift` one test per new case. Two of them
matter beyond coverage:

```swift
    /// A malformed tuplet ratio must be REFUSED, not trapped. CreateTuplet's init preconditions are traps, so a
    /// wire payload carrying 0 would kill the process on a path this API advertises as returning false.
    @Test func `a degenerate tuplet ratio is refused, not trapped`() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        #expect(!session.apply(.createTuplet(at: slot, actualNotes: 1, normalNotes: 2)))
        #expect(!session.apply(.createTuplet(at: slot, actualNotes: 3, normalNotes: 0)))
        #expect(session.lastRefusalReason != nil)
    }

    @Test func `a pitch change lands and undoes`() throws {
        let session = ScoreEditSession(score: EditingFixtures.chordAtIndex1())
        let note = EditingFixtures.noteID(element: 1)
        let before = session.score.stableFingerprint
        #expect(session.apply(.setNotePitch(at: note, pitch: 62, tpc: 16, accidental: nil)))
        #expect(try #require(session.score[note]).pitch == 62)
        #expect(session.undo())
        #expect(session.score.stableFingerprint == before)
    }
```

Plus one straightforward apply-then-assert test each for `.setAccidental`,
`.addNoteToChord` (chord note count grows), `.removeNoteFromChord` (shrinks),
`.setTie` (`tieForward` set on the source), `.removeTuplet` (voice's tuplet list
shrinks). Use `EditingFixtures.twoNoteChordAtIndex1()` and
`twoConsecutiveC4Chords()` for the chord and tie cases.

- [ ] **Step 3: Run them to see them fail**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter ScoreEditSessionTests
```
Expected: compile error — the cases do not exist yet — then, after Step 1 is in,
failures on the new tests.

- [ ] **Step 4: Map the cases**

Add to `command(for:in:depth:)`:

```swift
        case let .setNotePitch(location, pitch, tpc, accidental):
            return SetNotePitch(at: location, pitch: pitch, tpc: tpc, accidental: accidental)
        case let .setAccidental(location, accidental):
            return SetAccidental(at: location, accidental: accidental)
        case let .addNoteToChord(location, pitch, tpc, accidental):
            return AddNoteToChord(at: location, pitch: pitch, tpc: tpc, accidental: accidental)
        case let .removeNoteFromChord(location):
            return RemoveNoteFromChord(at: location)
        case let .setTie(source, target, sourceTieForward, targetTieBack):
            return SetTie(
                from: source, to: target,
                sourceTieForward: sourceTieForward, targetTieBack: targetTieBack,
            )
        case let .createTuplet(location, actualNotes, normalNotes):
            // `CreateTuplet.init` enforces these with preconditions — traps, not throws. A relayed intent is
            // attacker-shaped data as far as this function is concerned, so the check has to happen here.
            guard actualNotes > 1, normalNotes > 0 else {
                throw SheetMusicError.invalidEdit(
                    reason: "createTuplet: ratio \(actualNotes):\(normalNotes) is not a tuplet",
                )
            }
            return CreateTuplet(at: location, actualNotes: actualNotes, normalNotes: normalNotes)
        case let .removeTuplet(location):
            return RemoveTuplet(at: location)
```

- [ ] **Step 5: Run the tests**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter ScoreEditSessionTests
```
Expected: PASS, including Task 2's `accidental repairs ride the same undo step`
if it was deferred to here.

- [ ] **Step 6: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -am "feat(editing): complete the edit-intent vocabulary"
```

---

### Task 4: Wire cases for the new intents

Append seven discriminators to `EditIntentWire` (indices 5…11) and the payload
structs they need. `Accidental` is a `String`-raw-value enum: encode the raw
string and refuse an unknown one on decode, the same way `NoteDurationWire`
refuses an out-of-range `kind`. An unknown spelling that silently decoded as
`nil` would put a different glyph on the mirror than on the authoritative score.

**Files:**
- Modify: `Sources/SheetMusicAndroidJNI/Editing/EditIntentCodec.swift`
- Test: `Tests/SheetMusicTests/AndroidJNI/EditIntentCodecTests.swift`

**Interfaces:**
- Consumes: `EditIntent`'s new cases (Task 3), `NoteIDWire` / `VoiceElementIDWire` / `RestIDWire` from `Audio/PathIDCodecs.swift`.
- Produces: round-trippable wire encoding for all twelve intents; `EditIntentCodec.encode/decode` unchanged in signature.

- [ ] **Step 1: Write the failing round-trip tests**

Append to `EditIntentCodecTests.swift`:

```swift
    @Test func `every new intent round-trips`() throws {
        let staff = StaffAddress(partIndex: 1, staffIndexInPart: 1)
        let note = NoteID(staff: staff, measureIndex: 2, voiceIndex: 1, elementIndex: 3, noteIndexInChord: 1)
        let slot = VoiceElementID(staff: staff, measureIndex: 2, voiceIndex: 1, elementIndex: 3)
        let intents: [EditIntent] = [
            .setNotePitch(at: note, pitch: 61, tpc: 21, accidental: .sharp),
            .setAccidental(at: note, accidental: nil),
            .addNoteToChord(at: slot, pitch: 64, tpc: 18, accidental: .natural),
            .removeNoteFromChord(at: note),
            .setTie(from: note, to: note, sourceTieForward: 7, targetTieBack: nil),
            .createTuplet(at: slot, actualNotes: 3, normalNotes: 2),
            .removeTuplet(at: slot),
        ]
        for intent in intents {
            #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
        }
    }

    /// An accidental spelling this build does not know must fail the decode, not decode as "no accidental" —
    /// a silent nil would put a different glyph on the mirror than the authoritative score carries.
    @Test func `an unknown accidental spelling is refused`() throws {
        var bytes = EditIntentCodec.encode(.setAccidental(
            at: NoteID(staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                       measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0),
            accidental: .sharp,
        ))
        // Corrupt the accidental's raw-value bytes in place: flip the first byte of the UTF-8 payload.
        let index = try #require(bytes.indices.last.map { max(bytes.startIndex, $0 - 1) })
        bytes[index] ^= 0xFF
        #expect(throws: (any Error).self) { try EditIntentCodec.decode(bytes) }
    }
```

If the byte-flip does not reliably land inside the string payload, replace that
test with one that builds an `AccidentalWire(raw: "not-an-accidental")` directly
and asserts `decoded()` throws — the point is the refusal, not the corruption
technique.

- [ ] **Step 2: Run to see it fail**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter EditIntentCodecTests
```
Expected: compile failure (no such wire cases).

- [ ] **Step 3: Add the wire types**

```swift
/// `Accidental` as its raw-value string. Variable length, and deliberately not an index: `Accidental`'s cases are
/// declared in a source order this codec does not control, so an index would silently re-point the day someone
/// inserts a case. A spelling the reader does not know throws rather than decoding as "no accidental" — a silent
/// nil would put a different glyph on the mirror than the authoritative score carries.
@WireFormat
struct AccidentalWire {
    /// 0 = no accidental (`nil`), 1 = `raw` names one.
    var present: UInt8
    var raw: String

    init(from value: Accidental?) {
        if let value {
            present = 1
            raw = value.rawValue
        } else {
            present = 0
            raw = ""
        }
    }

    func decoded() throws -> Accidental? {
        guard present != 0 else { return nil }
        guard let accidental = Accidental(rawValue: raw) else {
            throw WireFormatError.unknownChoiceDiscriminator(0)
        }
        return accidental
    }
}

/// A signed tie index, or its absence. `Int?` has no wire form of its own here, and `-1` is not safe as a sentinel
/// because `SetTie` treats the value as opaque.
@WireFormat
struct OptionalIndexWire {
    var present: UInt8
    var value: Int32

    init(from value: Int?) {
        if let value {
            present = 1
            self.value = Int32(value)
        } else {
            present = 0
            self.value = 0
        }
    }

    func decoded() -> Int? {
        present != 0 ? Int(value) : nil
    }
}

@WireFormat
struct PitchWriteIntentWire {
    var location: NoteIDWire
    var pitch: Int32
    var tpc: Int32
    var accidental: AccidentalWire
}

@WireFormat
struct AddNoteIntentWire {
    var location: VoiceElementIDWire
    var pitch: Int32
    var tpc: Int32
    var accidental: AccidentalWire
}

@WireFormat
struct SetAccidentalIntentWire {
    var location: NoteIDWire
    var accidental: AccidentalWire
}

@WireFormat
struct SetTieIntentWire {
    var source: NoteIDWire
    var target: NoteIDWire
    var sourceTieForward: OptionalIndexWire
    var targetTieBack: OptionalIndexWire
}

@WireFormat
struct CreateTupletIntentWire {
    var location: VoiceElementIDWire
    var actualNotes: Int32
    var normalNotes: Int32
}
```

Give each an `init(from:)` mirroring the existing structs' style, and append the
cases to `EditIntentWire`:

```swift
    // Appended in SP1 — indices 5…11. Never renumber 0…4.
    case setNotePitch(PitchWriteIntentWire)
    case setAccidental(SetAccidentalIntentWire)
    case addNoteToChord(AddNoteIntentWire)
    case removeNoteFromChord(NoteIDWire)
    case setTie(SetTieIntentWire)
    case createTuplet(CreateTupletIntentWire)
    case removeTuplet(VoiceElementIDWire)
```

with the matching arms in `init(from intent:)` and `decoded(depth:)`.

- [ ] **Step 4: Extend the file's wire-layout doc comment**

The doc comment on `EditIntentCodec` is the only accurate description of this
format in the repo (SP0 finding). Extend the case-index table to 0…11 and add
field tables for the five new payload structs, in the same style. This is not
optional bookkeeping: SP3's Folino side reads this comment to know what it is
linking against.

- [ ] **Step 5: Run the tests**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter EditIntentCodecTests
```
Expected: PASS.

- [ ] **Step 6: Confirm the existing goldens did not move**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter EditReplayGoldenTests
```
Expected: PASS with no re-record. Appending cases must not change the bytes of
cases 0–4. If a `step-N.bin` mismatches, a case was renumbered — fix that, do
not re-record.

- [ ] **Step 7: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -am "feat(android): carry the remaining edit intents on the wire"
```

---

### Task 5: Extract `SheetMusicEditWire`, the shared Android-gated product

Spec §5.4, decided after SP0: ssm's `.so` decodes these bytes and Folino's `.so`
produces them, and two hand-maintained copies of a frozen schema in two repos
fail *silently* — reorder a case on one side and the other applies a different
intent, caught only whenever the fingerprint sampling next fires. One
declaration, both linkers.

Both sides are Android-only (iOS never encodes an intent — it calls the session
directly), so no iOS build is affected.

**Files:**
- Modify: `Package.swift`
- Move: `Sources/SheetMusicAndroidJNI/Editing/EditIntentCodec.swift` → `Sources/SheetMusicEditWire/EditIntentCodec.swift`
- Move: `Sources/SheetMusicAndroidJNI/Audio/PathIDCodecs.swift` → `Sources/SheetMusicEditWire/PathIDCodecs.swift`
- Move: `Sources/SheetMusicAndroidJNI/Audio/StaffAddressCodec.swift` → `Sources/SheetMusicEditWire/StaffAddressCodec.swift`
- Move: `Sources/SheetMusicAndroidJNI/Audio/ScoreItemIDCodec.swift` → `Sources/SheetMusicEditWire/ScoreItemIDCodec.swift`
- Move: `Sources/SheetMusicAndroidJNI/Audio/ClefAnchorCodec.swift` → `Sources/SheetMusicEditWire/ClefAnchorCodec.swift`
- Modify: every file in `Sources/SheetMusicAndroidJNI/` that used those types (add `import SheetMusicEditWire`)
- Modify: `Tests/SheetMusicTests/AndroidJNI/…` suites that `@testable import SheetMusicAndroidJNI` for these codecs

**Interfaces:**
- Consumes: `SheetMusicCore`, `Wirelet`.
- Produces: library product `SheetMusicEditWire` (Android-gated, static), exporting `EditIntentCodec`, `ScoreItemIDCodec`, `PathIDCodecs`, `StaffAddressCodec`, `ClefAnchorCodec`, and the `*Wire` structs behind them as `public`.

- [ ] **Step 1: Add the target and product**

In `Package.swift`, inside the `if isAndroid` block that already adds the
`SheetMusicAndroidJNI` product and the `CJNI` target:

```swift
    products += [
        .library(
            name: "SheetMusicEditWire",
            targets: ["SheetMusicEditWire"],
        ),
    ]
    targets += [
        .target(
            name: "SheetMusicEditWire",
            dependencies: [
                "SheetMusicCore",
                .product(name: "Wirelet", package: "swift-wirelet"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
        ),
    ]
```

`.v5` matches `SheetMusicAndroidJNI`, which is where these files come from — a
language-mode change would be an unrelated behavior variable in a move.

Add `"SheetMusicEditWire"` to `SheetMusicAndroidJNI`'s `dependencies`.

The product is deliberately **not** `type: .dynamic`: Folino's `FolinoEditorJNI`
and ssm's `SheetMusicAndroidJNI` are separate `.so`s and each links its own copy
of the wire code. That is fine — the wire is pure code with no shared state, and
what has to match between the two images is the *schema*, which is now one
source file rather than two.

- [ ] **Step 2: Move the five files**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing mv Sources/SheetMusicAndroidJNI/Editing/EditIntentCodec.swift Sources/SheetMusicEditWire/EditIntentCodec.swift
```

(create the directory first; repeat for the other four, which come from
`Sources/SheetMusicAndroidJNI/Audio/`.)

Then in each moved file, add `public` to every `struct`, its stored properties,
its `init(from:)` and its `decoded()`. They were same-target-internal before and
now cross a module boundary.

While moving `PathIDCodecs.swift`, `StaffAddressCodec.swift` and
`ScoreItemIDCodec.swift`, **fix their stale wire-layout doc comments** — they
claim fixed-width payloads (e.g. "`NoteIDWire` (24) → total 25 bytes") that the
macros have not emitted since the varint/TLV expansion. Replace the byte tables
with the tag-and-varint description `EditIntentCodec.swift` already uses, and
delete the cross-references that call those files "stale" now that they are not.

- [ ] **Step 3: Fix the importers**

```
rg -ln "EditIntentCodec|ScoreItemIDCodec|StaffAddressCodec|PathIDCodecs|ClefAnchorWire|VoiceElementIDWire|NoteIDWire|RestIDWire|TupletIDWire|StaffAddressWire" /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing/Sources /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing/Tests
```

Add `import SheetMusicEditWire` to each hit outside the new target. Test files
that reached the wire structs via `@testable import SheetMusicAndroidJNI` now
need `@testable import SheetMusicEditWire` as well — but prefer the public
surface where it suffices, since these types are public now.

- [ ] **Step 4: Add the new target to the test target's dependencies**

`SheetMusicTests` is assembled twice in `Package.swift` (Android and non-Android
shapes). Add `"SheetMusicEditWire"` to whichever list already carries
`"SheetMusicAndroidJNI"`.

- [ ] **Step 5: Build both shapes**

Host:
```
xcrun swift build --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing
```
Expected: BUILD SUCCEEDED — and note that on the host `isAndroid` is false, so
the new target is *not* built. That is the trap: a compile error here would only
appear on the cross-build. So also run:

```
SWIFT_SHEET_MUSIC_ANDROID=1 xcrun swift build --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --target SheetMusicEditWire
```

If that fails for host-toolchain reasons unrelated to the code, fall back to the
real cross-build in Task 13 and say so in the commit message.

Wait — the host test target references these codecs. Check whether
`SheetMusicTests`' Android-shaped assembly is the one used on the host: if the
host suite currently compiles `AndroidJNI/EditIntentCodecTests.swift`, the host
build DOES cover the new target, and the plain `swift build` above is enough.
Read `Package.swift`'s two `SheetMusicTests` blocks and record which is which in
the commit message.

- [ ] **Step 6: Run the full host suite**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing
```
Expected: 0 failures, and `EditReplayGoldenTests` passes **without** re-recording
— a pure move must not change one byte.

- [ ] **Step 7: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -am "refactor(android): one declaration of the edit wire, in its own product"
```

---

### Task 6: Extend `stableFingerprint` to what the new intents can reach

SP0's finding: the walk's exclusion list is enumerated in the file, and SP1's
new intents plus the `ReplaceVoiceElements`-carrying planners move whole
`VoiceElement` subtrees the walk cannot see. A field the walk is blind to is a
divergence it cannot report.

Scope it honestly: cover every `Chord` and `Note` field that a planner's
element copy carries, so that a planner disagreeing between images shows up as a
fingerprint mismatch rather than as a wrong glyph noticed by the user three
edits later.

**Files:**
- Modify: `Sources/SheetMusicCore/Score/ScoreFingerprint.swift`
- Test: `Tests/SheetMusicTests/EditingTests/ScoreFingerprintTests.swift`

**Interfaces:**
- Consumes: `Chord` (`arpeggio`, `lyrics`, `graceNotesBefore/After`, `articulations`, `tremolo`, `chordLines`, `stemVisible`, `beamVisible`), `Note` (`accidentalBracket`, `accidentalRole`, `glissando`, `headType`, `parentheses`, `isSmall`, `play`, `visible`).
- Produces: `Score.stableFingerprint` — same type, wider coverage. **This changes every fingerprint**, so Task 12 re-records.

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func `an articulation change moves the fingerprint`() {
        var score = EditingFixtures.chordAtIndex1()
        let before = score.stableFingerprint
        let slot = VoiceElementID(EditingFixtures.restID(element: 1))
        guard case var .chord(chord) = score[slot] else { Issue.record("expected a chord"); return }
        chord.articulations.append(ChordArticulation(subtype: "articStaccatoAbove"))
        score[slot] = .chord(chord)
        #expect(score.stableFingerprint != before)
    }

    @Test func `a notehead change moves the fingerprint`() throws {
        var score = EditingFixtures.chordAtIndex1()
        let before = score.stableFingerprint
        let note = EditingFixtures.noteID(element: 1)
        var value = try #require(score[note])
        value.headType = "cross"
        score[note] = value
        #expect(score.stableFingerprint != before)
    }
```

Use the real initializers for `ChordArticulation` and the real setter path for a
`Note` — read the models; the sketch above assumes a subscript setter that may
not exist, in which case mutate through the chord.

- [ ] **Step 2: Run to see them fail**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter ScoreFingerprintTests
```
Expected: both FAIL (fingerprints equal).

- [ ] **Step 3: Widen the walk**

Extend `combine(_ chord:)` and `combine(_ note:)` to feed each field listed in
the Interfaces block. For a field whose type is itself a struct/enum, feed a
discriminant plus the values that editing can change; for a `String?`, feed the
`-1` sentinel for `nil` exactly as `combine(_ accidental:)` already does. Grace
notes are `GraceChord` values — feed their count and recurse into each one's
chord content.

- [ ] **Step 4: Rewrite the doc comment's exclusion list**

The type's doc comment is a contract ("a difference it cannot see is a missed
detection, never a false alarm") and its value is entirely in the list being
accurate. Move every field you just covered out of the "not covered" list, and
leave the genuinely-still-excluded ones (`elementProperties`, every `Measure`
property, `Staff.defaultClefType`, `Score.systemMeasures`, and the walk's own
part/staff-grouping blindness) where they are, with the same "the next edit
command that touches one of these belongs here" warning.

- [ ] **Step 5: Run the tests**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter ScoreFingerprintTests
```
Expected: PASS.

- [ ] **Step 6: Re-record the replay goldens**

Every fingerprint moved. Same two-run procedure as Task 2 Step 5. This time
`goldens.txt` changes and `step-N.bin` must not.

- [ ] **Step 7: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -am "feat(editing): let the fingerprint see what a planner's element copy carries"
```

---

### Task 7: Move `Selection/` into `SheetMusicLayout`

Spec §5.2, and it is not optional: Folino's Editor imports `SheetMusicUI` solely
for these types, and that import is what stops the shared core from compiling
for Android at all.

`SheetMusicLayout` already builds for Android (the JNI target depends on it) and
already carries the conditional-CoreGraphics pattern these files need.
`SelectionRenderState` splits: the ID expansion is platform-neutral and moves;
`CGColor` resolution stays in `SheetMusicUI`.

**Files:**
- Move: `Sources/SheetMusicUI/Selection/ScoreSelection.swift` → `Sources/SheetMusicLayout/Selection/ScoreSelection.swift`
- Move: `Sources/SheetMusicUI/Selection/ScoreHitTarget.swift` → `Sources/SheetMusicLayout/Selection/ScoreHitTarget.swift`
- Move: `Sources/SheetMusicUI/Selection/ScoreHitTester.swift` → `Sources/SheetMusicLayout/Selection/ScoreHitTester.swift`
- Move: `Sources/SheetMusicUI/Selection/ScoreHitTester+Marquee.swift` → `Sources/SheetMusicLayout/Selection/ScoreHitTester+Marquee.swift`
- Create: `Sources/SheetMusicLayout/Selection/SelectionExpansion.swift`
- Modify: `Sources/SheetMusicUI/Selection/SelectionRenderState.swift`
- Move: `Tests/SheetMusicTests/ScoreHitTesterTests.swift`, `ScoreHitTesterClefTests.swift` → `Tests/SheetMusicTests/Layout/Selection/`

**Interfaces:**
- Consumes: `LayoutDocument`, `LayoutSystem`, `LayoutMeasure`, `LayoutElement`, `ScoreItemID`, `Score`.
- Produces (now in `SheetMusicLayout`): `ScoreSelection`, `ScoreHitTarget`, `ScoreHitTester(document:)` with `hitTest(at:)`, `itemIDs(in:)`, marquee API; `SelectionExpansion.expand(_:in:) -> Set<ScoreItemID>` and `SelectionExpansion.selectedIDs(for:in:) -> Set<ScoreItemID>`.
- `SheetMusicUI` keeps `SelectionRenderState` with `voiceColors`, `rangeBoxColor`, `color(for:voiceIndex:)`, `make(selection:voiceColors:score:)` — same signatures.

- [ ] **Step 1: Move the four files**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing mv Sources/SheetMusicUI/Selection/ScoreSelection.swift Sources/SheetMusicLayout/Selection/ScoreSelection.swift
```
(and the other three.)

In each moved file: delete `import SheetMusicLayout` (now the same module), and
wrap `import CoreGraphics` in `#if canImport(CoreGraphics)` / `#endif` — the
pattern `NearestCursor.swift` in this target already uses.

- [ ] **Step 2: Extract the ID expansion**

Create `Sources/SheetMusicLayout/Selection/SelectionExpansion.swift` holding
`SelectionRenderState.expand(_:in:)` verbatim (renamed to
`SelectionExpansion.expand`, made `public`) plus the `switch selection` that
turns a `ScoreSelection` into a `Set<ScoreItemID>`:

```swift
/// Turns a `ScoreSelection` into the set of item IDs a renderer should light up. Platform-neutral half of what used
/// to be `SelectionRenderState` — Android tints the same IDs through a draw-program re-encode, and a second
/// implementation of "which IDs does a tuplet selection cover" is exactly the divergence the parity rule forbids.
public enum SelectionExpansion {
    /// For non-tuplet IDs returns `[id]`; for a tuplet returns the tuplet ID itself plus every member chord/rest the
    /// bracket spans. Keeping the tuplet ID in the result lets a renderer tint the bracket / number, while the member
    /// IDs drive notehead / rest tinting through the same pipeline.
    public static func expand(_ id: ScoreItemID, in score: Score) -> Set<ScoreItemID> { … }

    /// Every ID `selection` covers, expanded. `.range` resolves through `score.items(inRangeFrom:to:)`.
    public static func selectedIDs(for selection: ScoreSelection, in score: Score) -> Set<ScoreItemID> { … }
}
```

- [ ] **Step 3: Reduce `SelectionRenderState` to its Apple half**

`SelectionRenderState.make(selection:voiceColors:score:)` keeps its signature and
its `drawRangeBox` decision (true only for `.range`), but gets its `selectedIDs`
from `SelectionExpansion.selectedIDs(for:in:)` instead of its own `switch`.
Delete the private `expand` from this file. Nothing else about the type changes.

- [ ] **Step 4: Re-export from `SheetMusicUI`**

Apple-side call sites (including Folino's, until SP2) import `SheetMusicUI` and
expect `ScoreSelection` / `ScoreHitTester` to be visible. Add, in a new
`Sources/SheetMusicUI/SelectionReexport.swift`:

```swift
/// The selection model and hit-test ladder moved down to `SheetMusicLayout` in 1.10.0 so an Android host can run
/// them too. Re-exported here so every Apple-side call site that imports `SheetMusicUI` for them keeps compiling —
/// this file exists for source compatibility and carries no logic of its own.
@_exported import struct SheetMusicLayout.ScoreHitTester
@_exported import enum SheetMusicLayout.ScoreHitTarget
@_exported import enum SheetMusicLayout.ScoreSelection
@_exported import enum SheetMusicLayout.SelectionExpansion
```

Match each declaration's real kind (`struct` / `enum` / `final class`) — a wrong
kind is a compile error that names the right fix.

- [ ] **Step 5: Move the tests and run the Apple suites**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing mv Tests/SheetMusicTests/ScoreHitTesterTests.swift Tests/SheetMusicTests/Layout/Selection/ScoreHitTesterTests.swift
```
(and the clef suite.) Fix their imports.

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing
```
Expected: 0 failures. `ScoreView`, `ScoreLayerBuilder` and the marquee suites are
the iOS-behavior-identical gate here.

- [ ] **Step 6: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -am "refactor(layout): move selection and hit-testing below the Apple line"
```

---

### Task 8: `LayoutDocument.editingHitTest(at:activeVoice:)`

Folino's `EditorViewModel+HitTest.swift` holds the *policy* on top of the
engine's ladder, and it is a policy the Android side needs identically: reduce
stem/flag/beam to their first notehead, drop `.clef`, prefer the active voice
within a 44-point slop box, rescue a near miss **only when the point is on a
staff band**, and otherwise answer nothing so a tap on paper deselects.

Only the parts that read the document move. Folino's `displayToSourceItem`
re-stamping (staff-filtered rendition → source addressing) stays in Folino — the
JNI bridge does its own re-addressing via the hidden-staff set, the way
`nativeNearestCursor` already models.

**Files:**
- Create: `Sources/SheetMusicLayout/Selection/LayoutDocument+Editing.swift`
- Test: `Tests/SheetMusicTests/Layout/Selection/LayoutDocumentEditingHitTestTests.swift`

**Interfaces:**
- Consumes: `ScoreHitTester`, `ScoreHitTarget`, `LayoutDocument.metrics.staffHeight`, `LayoutSystem.origin`, `LayoutSystem.staffOrigins`.
- Produces:
  - `public func editingHitTest(at point: CGPoint, activeVoice: Int) -> ScoreItemID?`
  - `public static let editingSlopHalfExtent: CGFloat` (22) — the JNI bridge and any future caller must not invent a second number.

- [ ] **Step 1: Write the failing tests**

Port `Packages/Features/Editor/Tests/EditorTests/EditorViewModelHitTestTests.swift`'s
cases that exercise the policy rather than the view model. At minimum:

- a tap on a notehead returns `.note` for that note
- a tap 10 points off a notehead, still within the staff band, rescues to it
- a tap in the page margin (well outside every staff band) returns `nil`
- a tap that hits voice 1's note while `activeVoice` is 0, with a voice-0 item
  inside the slop box, returns the voice-0 item
- a tap on a stem returns the stem's first notehead
- a tap on a clef returns `nil`

Build the document with the existing layout test support in
`Tests/SheetMusicTests/Layout/` (read what `ScoreHitTesterTests` uses — it
already lays out a real score, and `project_sheet_music_layout_install_in_tests`
records that layout tests need the SMuFL metrics installed first).

- [ ] **Step 2: Run to see them fail**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter LayoutDocumentEditingHitTestTests
```
Expected: compile failure — no such method.

- [ ] **Step 3: Implement**

Port `displayedItem(at:)`, `isOnStaff(_:in:)`, `slopRect(around:)` and
`selectableItem(from:)` from `EditorViewModel+HitTest.swift` verbatim into an
extension on `LayoutDocument`, keeping every comment — those comments record two
real bugs (the slop box reaching into page margins, and the gate being measured
with the same constant as the box it guards) and they must not be lost in the
move.

```swift
extension LayoutDocument {
    /// A tap in document coordinates resolved to the item it selects, or `nil` for "nothing" — which is what a tap
    /// on empty paper must mean, so the editing pad can be put away without leaving edit mode.
    ///
    /// Moved from Folino's `EditorViewModel+HitTest.swift` in 1.10.0 so iOS and Android run one policy. The caller
    /// still owns re-addressing: this answers in the RENDERED document's addressing, which may be a staff-filtered
    /// rendition of the score being edited.
    public func editingHitTest(at point: CGPoint, activeVoice: Int) -> ScoreItemID? { … }
}
```

- [ ] **Step 4: Run the tests**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter LayoutDocumentEditingHitTestTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -am "feat(layout): one editing hit-test policy for both platforms"
```

---

### Task 9: `LayoutDocument.editingCaretRect(for:in:)`

The caret and the selection callout's anchor are the same geometry: the engine's
cursor frame — whose Y spans the whole system — narrowed to the item's own staff
band, one `sp` clear above and below (a staff is 4 sp tall, so 6 sp total).
Folino computes it twice in `Reader/Views/EditingSelectionOverlay.swift`, once
with a 2-point minimum width for the caret and once with 1 for the anchor.

**Files:**
- Modify: `Sources/SheetMusicLayout/Selection/LayoutDocument+Editing.swift`
- Test: `Tests/SheetMusicTests/Layout/Selection/LayoutDocumentCaretRectTests.swift`

**Interfaces:**
- Consumes: `LayoutDocument.cursorFrame(for:in:)`, `LayoutSystem.flatIndex(for:)`, `LayoutDocument.metrics.sp`.
- Produces: `public func editingCaretRect(for item: ScoreItemID, in score: Score, minimumWidth: CGFloat = 2) -> CGRect?`

- [ ] **Step 1: Write the failing tests**

- the rect's top is one `sp` above the item's staff top, and its height is `6 * sp`
- its X range matches `cursorFrame(for: .item(item), in: score)`'s
- an item on a staff/measure the document does not contain returns `nil`
- `minimumWidth` floors a zero-width frame

- [ ] **Step 2: Run to see them fail**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter LayoutDocumentCaretRectTests
```

- [ ] **Step 3: Implement**

```swift
    /// The insertion caret's column: the engine's cursor frame for `item`, narrowed to `item`'s own staff band —
    /// one `sp` above the staff top to one `sp` below its bottom. Narrowed, unlike the playback head, because
    /// editing happens in one staff at a time.
    ///
    /// `nil` when the item doesn't resolve to a laid-out frame (a stale ID right after an edit reflows the
    /// document) or names a staff/measure this document doesn't contain.
    ///
    /// `minimumWidth` is the floor a zero-width frame is widened to: 2 for the caret, 1 for the selection anchor
    /// the callout is positioned from — the only difference between the two call sites in Folino's overlay.
    public func editingCaretRect(
        for item: ScoreItemID, in score: Score, minimumWidth: CGFloat = 2,
    ) -> CGRect? { … }
```

with a private `staffBand(for:measureIndex:)` ported from the overlay.

- [ ] **Step 4: Run the tests, then the whole suite**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing
```
Expected: 0 failures.

- [ ] **Step 5: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -am "feat(layout): the caret's column, narrowed to its own staff"
```

---

### Task 10: Tint a cached layout's draw program

Selecting a note must not re-engrave the score. The Android renderer consumes a
draw program; tinting is therefore a *re-encode* of the already-cached
`LayoutDocument` with `.setColor` bracketing the commands that belong to a
selected ID — never a relayout.

`DrawCommand.setColor(argb:)` already exists (discriminator 6), and
`LayoutChordNote` carries `noteID` while the rest case carries a `RestID`, which
is what makes per-element tinting possible without new layout data.

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/LayoutBridge+Selection.swift`
- Modify: `Sources/SheetMusicAndroidJNI/LayoutBridge.swift` (thread a selection through `buildCommands`)
- Create: `Sources/SheetMusicEditWire/EditGeometryCodec.swift` (the selection payload)
- Test: `Tests/SheetMusicTests/AndroidJNI/DrawProgramSelectionTests.swift`

**Interfaces:**
- Consumes: `LayoutDocumentCache.entry(for:)`, `SelectionExpansion`, `ScoreItemIDCodec`.
- Produces:
  - `@WireFormat struct SelectionTintWire { var argb: UInt32; var items: [ScoreItemIDWire] }` + `public enum SelectionTintCodec { encode/decode }`
  - `LayoutBridge.buildCommands(layout:tint:)` where `tint` is `(argb: UInt32, ids: Set<ScoreItemID>)?` — `nil` reproduces today's output byte-for-byte.

- [ ] **Step 1: Write the failing tests**

```swift
    /// With no selection the encoder must produce exactly what it produced before this feature existed —
    /// otherwise every unselected redraw pays for a feature it isn't using.
    @Test func `an empty tint changes nothing`() throws { … compare buildCommands(layout:tint:nil) to buildCommands(layout:) … }

    /// A selected notehead is bracketed by setColor(argb) … setColor(default), and an unselected one is not.
    @Test func `a selected note is tinted and its neighbor is not`() throws { … }

    /// Selecting a tuplet tints every member, because SelectionExpansion says so — the same rule the Apple
    /// renderer follows. A second implementation of that rule is what the parity rule forbids.
    @Test func `a tuplet selection tints its members`() throws { … }
```

- [ ] **Step 2: Run to see them fail**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter DrawProgramSelectionTests
```

- [ ] **Step 3: Implement the tint**

Add an optional tint parameter to `LayoutBridge.buildCommands` and, in
`encodeElement`, emit `.setColor(argb: tint.argb)` before an element whose ID is
in the set and `.setColor(argb: 0xFF00_0000)` after it. Do the ID matching in
`LayoutBridge+Selection.swift` so `LayoutBridge.swift` stays readable — it is
already `// swiftlint:disable file_length`.

Chord elements need per-note granularity: a chord where only one notehead is
selected tints that notehead alone, matching `ScoreLayerBuilder`'s behavior.
Read `ScoreLayerBuilder+Selection.swift` and the layer builder's element walk
and mirror their granularity decisions rather than inventing new ones.

- [ ] **Step 4: Run the tests**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter DrawProgramSelectionTests
```
Expected: PASS, and the `an empty tint changes nothing` test is the one that
proves no regression for the non-editing Reader.

- [ ] **Step 5: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -am "feat(android): recolor a cached layout's draw program for a selection"
```

---

### Task 11: The three remaining JNI entry points

Spec §5.3's last three rows. Each follows `nativeNearestCursor`'s established
shape: millimetres in (the unit the Kotlin overlay works in), `Data` out, empty
`Data` for every failure, no `@available` attribute (the jextract `@_cdecl`
wrapper is generated without one), and `LayoutOptionsWire` reused for the
hidden-staff set rather than a second hidden-staves format.

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/Editing/EditGeometryBridge.swift`
- Modify: `Sources/SheetMusicAndroidJNI/swift-java.config` if entry points must be listed there (check how SP0's seven were registered)
- Modify: `Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/SheetMusicJNI.kt`
- Test: `Tests/SheetMusicTests/AndroidJNI/EditGeometryBridgeTests.swift`

**Interfaces:**
- Consumes: Tasks 8, 9, 10; `LayoutDocumentCache`, `scoreTable`, `LayoutOptionsCodec`, `ScoreItemIDCodec`, `SelectionTintCodec`.
- Produces:
  - `public func nativeEditingHitTest(scoreHandle: Int64, xMm: Double, yMm: Double, activeVoice: Int32, optionsBytes: Data) -> Data`
  - `public func nativeEditingCaretFrame(scoreHandle: Int64, itemBytes: Data, minimumWidthMm: Double) -> Data`
  - `public func nativeEncodeDrawProgram(scoreHandle: Int64, selectionBytes: Data) -> Data`
  - `@WireFormat struct EditCaretFrameWire { var xMm, yMm, widthMm, heightMm: Double }` in `SheetMusicEditWire`

- [ ] **Step 1: Write the failing tests**

Host-side, driving the entry points the way `EditSessionBridgeTests` drives
SP0's: load a fixture with `nativeLoadScore`, call `nativeComputeLayout` to
populate the cache, then:

- `nativeEditingHitTest` at a known notehead's mm coordinates decodes to that
  note's `ScoreItemID`
- the same call with an unknown handle returns empty `Data`
- the same call before any `nativeComputeLayout` returns empty `Data` (nothing
  cached)
- `nativeEditingCaretFrame` for that item returns a rect whose height is `6 * sp`
  converted to mm
- `nativeEncodeDrawProgram` with an empty selection returns bytes equal to what
  `nativeComputeLayout` returned; with the note selected, it returns different
  bytes of the same page count

- [ ] **Step 2: Run to see them fail**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter EditGeometryBridgeTests
```

- [ ] **Step 3: Implement the three entry points**

Convert mm → pt with `72.0 / 25.4` on the way in and pt → mm with `25.4 / 72.0`
on the way out — the same constants every other bridge uses. Re-address the
hit-test result past hidden staves the way `nativeNearestCursor` does; read that
file and reuse its helper rather than writing a second one.

`nativeEncodeDrawProgram` must **not** call `LayoutBridge.computeWithDocument` —
it reads `LayoutDocumentCache.entry(for:)` and re-encodes. If the cache is empty
it returns empty `Data` and the Kotlin side is expected to compute a layout
first. Say so in the doc comment; a silent relayout here is the performance bug
this entry point exists to avoid.

- [ ] **Step 4: Add the Kotlin facade**

Mirror the three signatures in `SheetMusicJNI.kt` exactly as jextract generates
them (`Data` → `SwiftData`, `Int64` → `long`, `Double` → `double`). Task 13's
cross-build verifies the mapping; a mismatch surfaces as `UnsatisfiedLinkError`
on device, which is a far worse place to find it.

- [ ] **Step 5: Run the tests**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter EditGeometryBridgeTests
```
Expected: PASS.

- [ ] **Step 6: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -am "feat(android): expose editing hit-test, caret frame and selection tint over JNI"
```

---

### Task 12: A replay script worth citing

SP0's finding, verbatim: "Introduce a richer fixture before citing
`EditReplayDeterminismTests` as proof. One measure, one voice, one staff, no
rests, no tuplets, no `.locationShift` — the determinism claim is narrower than
it reads."

Two changes. The **fixture** becomes a programmatic score encoded to MSCX and
committed, so both the host and the device load identical bytes. The **script**
exercises what SP1 added: accidental repairs under a real key signature, a
cross-bar duration, a tuplet and a write inside it, a delete that collapses a
bar, and every new intent.

**Files:**
- Modify: `Tests/SheetMusicTests/EditingTests/EditReplayScript.swift`
- Modify: `Tests/SheetMusicTests/AndroidJNI/EditReplayGoldenTests.swift`
- Modify: `Tests/SheetMusicTests/EditingTests/EditReplayDeterminismTests.swift`
- Create: `Android/SheetMusicAndroid/src/androidTest/assets/editReplay/fixture.mscx` (recorded, not hand-written)
- Modify: `Android/SheetMusicAndroid/src/androidTest/kotlin/.../EditSessionReplayTest.kt` (fixture filename)

**Interfaces:**
- Consumes: `EditingFixtures`, `MSCXEncoder.encode(_:) throws -> Data`, `EditIntentCodec`, the session bridge.
- Produces: `EditReplayScript.standard(staff:)` covering all twelve intents; committed `editReplay/` assets regenerated.

- [ ] **Step 1: Build the fixture**

Add to `EditingFixtures`:

```swift
    /// The replay fixture: three 4/4 measures under D major (F# and C#), on one staff, seeded with a mix of quarter
    /// rests and two chords so the script can reach every shape SP1 added — accidental repairs need a key signature
    /// AND a second note in the bar; the cross-bar planner needs a bar boundary to overrun; the collapse path needs
    /// a bar it can empty.
    ///
    /// Programmatic rather than a hand-written .mscx: the shape is reviewable in one screen and cannot drift from a
    /// file nobody reads. The DEVICE loads the MSCX encoding of this, recorded by `EditReplayGoldenTests`, so both
    /// sides start from identical bytes rather than from this builder and a file that agree only by inspection.
    static func replayFixture() -> Score { … }
```

Build it from `twoMeasuresOfQuarterRests(key: 2)` plus a third measure and two
seeded chords, using the same `Voice`/`Measure`/`Staff`/`Part` construction the
other fixtures use.

- [ ] **Step 2: Record it as an asset**

Extend `EditReplayGoldenTests.record` to also write
`MSCXEncoder.encode(EditingFixtures.replayFixture())` to
`editReplay/fixture.mscx`, and change both `record` and `verify` to load the
fixture from that file rather than from `Bundle.module`'s `midi01.mscx`. Delete
the `midi01.mscx` asset copy and its drift assertion; replace it with the same
assertion against `fixture.mscx` and the freshly encoded bytes.

- [ ] **Step 3: Rewrite the ten steps**

`EditReplayGoldenTests.steps` becomes a longer array that reaches every intent.
Keep the existing discipline — the doc comment on that array explains why the
current steps only ever shorten the *last* slot, and the same index-stability
reasoning applies to any step added — and add, in an order that keeps earlier
indices valid:

1. `.inputNote` into a rest under D major, on a letter whose spelling the key
   alters (the repair path)
2. `.setNotePitch` on that note, flipping it to a natural (the repair path from
   the other side)
3. `.setAccidental` clearing it again
4. `.addNoteToChord` then `.removeNoteFromChord`
5. `.createTuplet` on a slot, then `.inputNote` inside it (the tuplet refusal
   that must NOT take the note write down)
6. `.setTie` between two same-pitch neighbors
7. `.inputNote` with a duration that overruns the barline (the cross-bar path)
8. `.delete` of the last surviving element of measure 2 (the collapse path)
9. `.removeTuplet`
10. undo/redo interleaved as today

Update the array's doc comment to say what each group proves. The comment is
what a reviewer reads to know the script is not just longer but *wider*.

- [ ] **Step 4: Point the determinism test at the same script**

`EditReplayDeterminismTests` should run `EditReplayScript.standard` over
`EditingFixtures.replayFixture()` and assert the two sessions agree at every
step, and additionally assert the fingerprints are not all equal (a script that
gets refused at every step would otherwise "prove" determinism trivially).

- [ ] **Step 5: Record and verify**

```
SM_EDIT_REPLAY_RECORD=1 xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter EditReplayGoldenTests
```
```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter EditReplayGoldenTests
```
Then review what landed:
```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing status --short Android/SheetMusicAndroid/src/androidTest/assets/editReplay
```
Expected: new `step-N.bin` files, a rewritten `goldens.txt`, a new
`fixture.mscx`, and `midi01.mscx` deleted.

- [ ] **Step 6: Update the Kotlin replay test**

`EditSessionReplayTest.kt` loads the fixture by name and loops over
`step-N.bin`. Change the filename, and update the hard-coded expected step
count if it carries one (SP0's last commit added an explicit device-side step
count assertion — find it and move it with the script).

- [ ] **Step 7: Run the full host suite**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing
```
Expected: 0 failures.

- [ ] **Step 8: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -am "test(android): replay every intent, over a fixture worth citing"
```

---

### Task 13: Cross-build, device pass, release 1.10.0

**Files:**
- Modify: `CHANGELOG.md`
- Modify: the version constant `SheetMusicEngine.version` reads (find it — SP0 added `SheetMusicEngine.version` / `versionStamp`, and a release bump must move it or the skew gate lies)

**Interfaces:**
- Consumes: everything above.
- Produces: tag `1.10.0` on `origin/main`, ready for Folino's SP2 re-pin.

- [ ] **Step 1: Cross-build both ABIs**

```
/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing/Scripts/android-build-libs.sh
```
Expected: SUCCESS for both ABIs. Read the script's header first — it prepends
the 6.3.3 release toolchain; the Xcode-bundled Swift cannot build these. Note
SP0's finding that SwiftPM still resolves the co-installed
`swift-6.3.2-RELEASE_android` SDK bundle: harmless, but if something
toolchain-shaped appears, that is the first thing to check.

- [ ] **Step 2: Confirm the new symbols and `JNI_OnLoad`**

```
nm -D --defined-only /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing/Android/SheetMusicAndroid/src/main/jniLibs/arm64-v8a/libSheetMusicAndroidJNI.so
```
Scan for `nativeEditingHitTest`, `nativeEditingCaretFrame`,
`nativeEncodeDrawProgram`, the seven SP0 entry points, and `JNI_OnLoad`.

- [ ] **Step 3: Run the device suite**

Follow SP0 Task 10's device procedure (the instrumented `EditSessionReplayTest`
against the re-recorded assets), on the physical Pixel — `reference_android_pixel_wireless_adb`
covers pairing if adb is not already connected.
Expected: every step's fingerprint matches `goldens.txt`, 0 failures.

- [ ] **Step 4: Write the CHANGELOG**

Move the `[Unreleased]` block to `## [1.10.0] - <today>` and add entries for:
the seven planners now living in `SheetMusicCore`; `ScoreEditSession.apply`
planning through them (**source-behavior change**: an intent now bundles
accidental repairs and may plan across a barline); the seven new intents and
their wire cases; the new `SheetMusicEditWire` product; `Selection/` moving from
`SheetMusicUI` to `SheetMusicLayout` (**source-breaking for anyone importing the
concrete module rather than `SheetMusicUI`** — say which types and that
`SheetMusicUI` re-exports them); `LayoutDocument.editingHitTest` /
`editingCaretRect`; the three new JNI entry points; and the widened
`stableFingerprint` (**every fingerprint value changes** — a host comparing
against a stored one from 1.9.0 must re-baseline).

- [ ] **Step 5: Bump the version**

```
rg -n "1\.9\.0" /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --glob '!CHANGELOG.md'
```
Update every hit that names the package version, including whatever
`SheetMusicEngine.version` returns. A stale version constant makes SP3's
version-skew gate compare two lies.

- [ ] **Step 6: Commit, push, wait for CI, then tag**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -am "chore(release): swift-sheet-music 1.10.0"
```

Merge to `main` and push **first**, wait for CI to go green, and only then tag —
pushing a tag in the same breath bypasses the status check
(`feedback_tag_after_ci_green`). Pushing and tagging both need explicit user
approval; stop and ask.

- [ ] **Step 7: Report**

Summarize for the user: what moved, what the device run showed, the tag, and the
one thing SP2 needs to know — Folino's `Editor` package still contains seven
files that are now duplicates, and deleting them is SP2's first task.

---

## Self-review

**Spec coverage.** The spec's §11 SP1 bullet names six things: move the seven
planners (Task 1); relocate `Selection/` to `SheetMusicLayout` (Task 7); add
`editingHitTest` (Task 8) and `editingCaretRect` (Task 9); add the remaining
intents (Tasks 3, 4); add the draw-program tint + `nativeEncodeDrawProgram`
(Tasks 10, 11); split the intent wire into the shared Android-gated product of
§5.4 (Task 5); refactor iOS onto the relocated types behavior-identically (Task
7 Steps 4–5); tag at the end (Task 13). All covered.

**Beyond the spec.** Task 2 (planning through the planners) is implied by §5.1's
description of `apply` but was not in SP0, and without it nothing else in SP1 is
reachable from a real edit. Task 6 (fingerprint) and Task 12 (fixture) are SP0
findings promoted to tasks. Task 12 also replaces the fixture asset, which SP0
did not anticipate.

**Known deviations.** (1) `MeasureAccidentalsTests` and `CrossBarInputTests`
stay in Folino because they drive `EditorViewModel`; Task 1 writes narrower
direct tests here, and SP2 keeps the wider ones passing. (2) Task 2's third test
uses `.setNotePitch`, which Task 3 adds — executing strictly task-by-task, stage
that one test in Task 3. (3) The goldens are re-recorded three times across the
branch (Tasks 2, 6, 12), which weakens the within-branch regression guard;
unavoidable when the behavior under test changes on purpose, and each
re-recording step says exactly which files may move and which may not.

**Not in SP1, deliberately.** `SelectionRederivation`, `ElementNavigator`,
`NoteNameFormatter` and `EditorFileFacts` stay in Folino (spec §5.1 — they read
the score for the UI rather than mutate it). The stale-layout race SP0 flagged
(`nativeComputeLayout` writing `LayoutDocumentCache` without the edit lock)
belongs to SP3 per SP0's findings, and Task 11 does not make it worse:
`nativeEncodeDrawProgram` only *reads* the cache.

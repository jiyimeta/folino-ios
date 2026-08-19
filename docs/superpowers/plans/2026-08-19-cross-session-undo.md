# Cross-Session Undo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Editor's undo history survive closing and reopening an edit session on the same score for the process lifetime — and, as the step that makes that cheap, route the iOS edit path through swift-sheet-music's `EditIntent` / `ScoreEditSession`, deleting Folino's duplicate copy of the edit planning.

**Architecture:** Step 1 (Tasks 1–5) replaces `EditorViewModel`'s hand-built `EditCommand`s with `EditIntent`s at a single choke point, `apply(_ intent:) -> Bool`. Because `ScoreEditSession` cannot apply raw commands and `ScoreEditor` cannot apply intents, one engine object cannot serve both entry points — so Tasks 1–3 migrate call sites against a **transitional, verbatim host-side copy of ssm's intent planning**, and Task 4 swaps the engine to `ScoreEditSession`, deletes that copy along with `applyCommand` and `renotatingAccidentals`, and proves no `EditCommand` construction remains. Step 2 (Tasks 6–8) adds a `@MainActor` Domain protocol `ScoreEditHistoryStore`, an App-layer LRU concrete that retains up to 3 deposited `ScoreEditSession`s keyed by `ScoreItemID` + `contentHash`, and the session-lifetime changes: adopt in `beginSession`, deposit in `endSession`, signed `sessionEditDepth`, count-driven unwind, and ✕ / revert ending all retained history for the score.

**Tech Stack:** Swift 6.3, SwiftUI + Observation, swift-sheet-music pinned `exact: "1.15.0"` (unchanged), Swift Testing, iOS 18 package floor.

**Spec:** `docs/superpowers/specs/2026-08-19-cross-session-undo-design.md`

## Global Constraints

- **Strict layered SPM modules.** The protocol goes in `Packages/Domain/Sources/Domain/Protocols/` beside `ScoreOriginalStore.swift`; the concrete goes in `App/` (it is process-lifetime composition state, not an Infrastructure adapter — every Infrastructure product adapts an external system and this type has none); the Editor sees the protocol through `import Domain`, which `@_exported import SheetMusicCore` makes sufficient to name `ScoreEditSession`. Utility and a Domain concrete are ruled out by the spec.
- **The LRU cap is 3 deposited sessions** — "Cap = 3 deposited sessions (the open session is checked out and not counted)". Memory pressure (`UIApplication.didReceiveMemoryWarningNotification`) empties the store; the checked-out session is unaffected.
- **Step 1 pass condition, two parts, both required:** (a) the existing Editor suites pass — suites that drive the *public ops* (`inputPitch`, `deleteSelection`, `writeRest`, `toggleTie`, …) must pass **unchanged**; the four files that seed edits through the internal seam (`EditorViewModelPersistenceTests`, `EditorViewModelRevertTests`, `EditorViewModelSessionTests`, `EditorViewModelPitchTests`) are mechanically retargeted from `vm.applyCommand(InputNote(…))` to `vm.apply(.inputNote(…))` with **assertions untouched**. (b) no `EditCommand` construction remains under `Packages/Features/Editor/Sources/` — `applyCommand` deleted, `renotatingAccidentals` deleted, no `CompositeEditCommand` anywhere. (a) alone is necessary, not sufficient.
- **No swift-sheet-music changes.** The pin stays `exact: "1.15.0"` in both `Package.swift` files and `project.yml`. If any task appears to need an ssm change, that is a **BLOCKED escalation to the user**, never a silent edit of the clone at `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music`.
- **Comment paragraphs reflow at 120 columns** (SwiftLint `line_length.warning: 120`). File budget is 400 lines (`file_length.warning`), function budget 60 (`function_body_length.warning`) — both fail the pre-commit hook, so respect them.
- **New tests use Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`), against the existing fakes in `EditorTests/Support/Fakes.swift`.
- **`public` is a decision, not a default.** New symbols get no access modifier unless another module references them. The one deliberate `public` in this plan is the Domain protocol (App and Editor both consume it). The `editor` property loses its `public` in Task 4 — nothing outside the Editor module reads it (verified by grep).
- **Baseline, measured:** the Editor package is green at base `2e8aeea0` with **155 tests in 17 suites passed**. That number is the Step 1 behavior-invariance gate.
- Run every `xcodebuild` in the foreground. Stage whole files only — never `git add -p` (the pre-commit hook rewrites staged Swift files). If a test run crashes or reports random unrelated failures, re-run with `-parallel-testing-enabled NO` appended before believing any failure — this environment's runner has crashed under parallel testing before.

## Controller rulings (these override the spec where they differ)

1. **✕ / discard does not deposit — it invalidates.** The spec accepted that redo survives a ✕-discard into the next session, naming an optional ssm addition (`ScoreEditSession.discardRedoHistory()`) as the alternative. Ruled: **no ssm change.** `discardSessionEdits()` calls `historyStore.invalidate(scoreItem.id)` and the session is torn down *without* deposit, so ✕ ends all retained history for that score — the same contract as an app kill. Rationale: `main` just shipped "✕ discards the session" (`15bcde6f`), and letting the next session redo the discarded edits contradicts that; the alternative costs an ssm release cycle on the critical path. Everything else about deposit (only when the flush left `isDirty == false` and the session has history) is unchanged for the normal ✓/close path.
2. **`unwindSessionEdits()` keeps the count-driven change and neither deposits nor invalidates itself.** The code shows the two "unwind" names share one implementation: `unwindSessionEdits()` (`EditorViewModel.swift:300`) is the score-rewind primitive, and its only production caller is `discardSessionEdits()` (`EditorViewModel+Discard.swift:78`; `EditorSessionEndModeTests` also calls it directly). The exact branching: `unwindSessionEdits()` becomes count-driven (undo `sessionEditDepth` times when positive, redo `-sessionEditDepth` when negative) and stays store-agnostic; the invalidate and the deposit suppression live one level up, in `discardSessionEdits()` only. `endSession()` owns the deposit; a ✕ suppresses it via the `didDiscardSession` flag, because the exit path after ✕ still runs `endSession()` (`EditorDiscardButton` → `onExit` → `ReaderEditingHost.requestExit()` → `onEndEditing` → `vm.endSession()`).
3. **No swift-sheet-music changes in this plan** (also a Global Constraint; repeated because the spec floats an optional ssm addition — it is not taken).

## Why Step 1 is four tasks, not one (deviation from the spec's "one mechanical step")

The spec's implementation order does the engine swap and all 25 call sites in one step. Ruled instead: split it so a reviewer can reject one slice while approving its neighbor. True coexistence of `applyCommand` and a session-backed `apply(_ intent:)` on one engine is impossible — `ScoreEditSession` exposes no raw-command apply, and two engine objects means two undo stacks — so the split works like this: Task 1 introduces `apply(_ intent:) -> Bool` backed by `TransitionalIntentPlanning`, a **verbatim host-side transcription of `ScoreEditSession`'s private planning** (ssm 1.15.0), routed through the existing `applyCommand`. Tasks 1–3 migrate call sites in three reviewable slices, each gated on the full Editor suite. Task 4 swaps the engine to `ScoreEditSession`, deletes the transcription + `applyCommand` + `renotatingAccidentals`, and greps the package clean — a small diff whose green gate *is* the proof that the transcription and ssm's original plan identically.

## Known transitional states

- **Tasks 1–3 deliberately duplicate ssm's planning** in `TransitionalIntentPlanning.swift`. Do not "fix" or "improve" it; fidelity is the point, and Task 4 deletes it.
- **Between Task 7 and Task 8, ✕ on a session with adopted history over-discards.** Task 7's unwind still walks `while canUndo`, which with retained history crosses the session boundary. Task 8's count-driven unwind fixes it, along with the depth clamp that lies below session start. Neither is a regression to chase at Task 7 — no gate test exercises adopted-history + ✕ until Task 8 adds them.

## File Structure

**Editor package — `Packages/Features/Editor/Sources/Editor/`**

| File | Responsibility |
| --- | --- |
| `EditorViewModel.swift` | Modify. Task 1: add `apply(_ intent:) -> Bool` + DEBUG `appliedIntents`. Task 4: hold `session: ScoreEditSession?` instead of `editor: ScoreEditor?`; delete `applyCommand` / `renotatingAccidentals`. Task 7: `historyStore` dependency, adopt in `beginSession`, deposit in `endSession`. Task 8: signed depth, count-driven `unwindSessionEdits`, `didDiscardSession`. |
| `TransitionalIntentPlanning.swift` | **Create Task 1, delete Task 4.** Verbatim copy of `ScoreEditSession`'s intent planning. |
| `EditorViewModel+Input.swift` | Modify Tasks 1–3. Letter input, ⌫, rest key, callout length keys migrate to intents; cross-bar branches, `restDuration(_:at:)`, `retimeCrossingBarline`, `writeCrossingBarline` deleted; `chainTail(from:in:)` caret compensation added. |
| `EditorViewModel+ChordTieTuplet.swift` | Modify Tasks 1, 3. Chord/tie/tuplet ops migrate; `tieAppendPlan()` becomes `tieAppendIntent()`; selection compensation after `appendTiedNote`. |
| `EditorViewModel+Pitch.swift` | Modify Tasks 1, 3. `setAccidental` (Task 1), `retune` collapses to one `.setNotePitch` intent (Task 3 — ssm walks the tie chain). |
| `EditorViewModel+Selection.swift` | Modify Task 4. `rederiveSelection` reads `session.lastAffectedLocation`. |
| `EditorViewModel+Discard.swift` | Modify Task 8. ✕ invalidates the store and suppresses the deposit. |
| `EditorViewModel+Revert.swift` | Modify Task 4 (`editor = nil` → `session = nil`), Task 8 (invalidate after the store swap succeeds). |
| `NoopScoreEditHistoryStore.swift` | Create Task 7. Does nothing, for previews — mirrors `NoopScoreOriginalStore`. |
| `Views/EditorPadView.swift` | Modify Task 7. `PreviewEditorFactory` passes the Noop store. |
| `Screens/EditorChromeView.swift` | Modify Task 8. Initial system-undo trampoline when an adopted session already `canUndo`. |

**Editor package — `Packages/Features/Editor/Tests/EditorTests/`**

| File | Responsibility |
| --- | --- |
| `EditorViewModelPersistenceTests.swift`, `EditorViewModelRevertTests.swift`, `EditorViewModelSessionTests.swift`, `EditorViewModelPitchTests.swift` | Modify Task 1. Seeding calls retargeted to intents, assertions untouched. Task 7 adds the `historyStore:` init argument. |
| Every other file constructing `EditorViewModel` (`EditorOriginalRoundTripTests`, `MeasureAccidentalsTests`, `EditorViewModelChordTests`, `EditorViewModelInputTests`, `EditorViewModelHitTestTests`, `EditorViewModelNavigationTests`, `CrossBarInputTests`, `EditorViewModelAuditionTests`, `EditorSessionEndModeTests`) | Modify Task 7. `historyStore: NoopScoreEditHistoryStore()` added to the constructor. |
| `Support/Fakes.swift` | Modify Task 7. `FakeScoreEditHistoryStore` (recording, checkout semantics) and `FakeScoreFileGateway.saveError`. |
| `EditorIntentConstructionTests.swift` | Create Task 5. Pins the intent each op constructs, the chord-upper-notehead ruling, the cross-bar caret landing, the `appendTiedNote` composite shapes. |
| `EditorCrossSessionUndoTests.swift` | Create Task 7, extend Task 8. Adopt/deposit/no-deposit rules; signed depth; ✕ and revert invalidation. |

**Domain — `Packages/Domain/Sources/Domain/Protocols/`**

| File | Responsibility |
| --- | --- |
| `ScoreEditHistoryStore.swift` | Create Task 6. The `@MainActor` protocol, verbatim from the spec. |

**App**

| File | Responsibility |
| --- | --- |
| `App/ProcessScoreEditHistoryStore.swift` | Create Task 6. The LRU concrete + memory-warning sweep. |
| `App/AppBootstrap.swift` | Modify Task 7. `let editHistoryStore = ProcessScoreEditHistoryStore()`. |
| `App/AppShellView.swift` | Modify Task 7. Threads the store through `ReadyShell` → `makeReader`. |
| `App/EditableReaderScreen.swift` | Modify Task 7. `historyStore` init parameter → `EditorViewModel`. |
| `FolinoScreenshot/Scenes/NoteEditingScene.swift` | Modify Task 7. Adds the new argument (a fresh `ProcessScoreEditHistoryStore()`). |
| `Tests/FolinoTests/ProcessScoreEditHistoryStoreTests.swift` | Create Task 6. LRU, checkout, hash guard, invalidate, memory sweep. |

**Docs**

| File | Responsibility |
| --- | --- |
| `docs/superpowers/specs/2026-08-19-cross-session-undo-design.md` | Modify Task 9. Reconcile the "redo survives ✕" paragraph with controller ruling 1, and anything else that drifted. |

## Test commands

Editor package suite (run from anywhere; `env -C` supplies the package directory because `cd` compounds are banned in this repo):

```sh
env -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo/Packages/Features/Editor \
  xcodebuild test -scheme Editor \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation
```

For a single suite append `-only-testing:EditorTests/<SuiteName>` (the test target, not the scheme).

App-level tests (`Tests/FolinoTests`) run against the app project:

```sh
xcodebuild -project /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo/Folino.xcodeproj \
  -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation test -only-testing:FolinoTests/<SuiteName>
```

---

## Task 1: The intent seam, the transitional planner, and the scalar call sites

**Files:**
- Create: `Packages/Features/Editor/Sources/Editor/TransitionalIntentPlanning.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift` (after `applyCommand`, ~line 355)
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Input.swift:41-59` (`deleteSelection`)
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+ChordTieTuplet.swift:18-21, 51-70, 168-178, 210-232`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Pitch.swift:53-58` (`setAccidental`)
- Modify: `Packages/Features/Editor/Tests/EditorTests/EditorViewModelPersistenceTests.swift` (7 seeding calls)
- Modify: `Packages/Features/Editor/Tests/EditorTests/EditorViewModelRevertTests.swift` (6 seeding calls)
- Modify: `Packages/Features/Editor/Tests/EditorTests/EditorViewModelSessionTests.swift` (6 seeding calls + 2 test names)
- Modify: `Packages/Features/Editor/Tests/EditorTests/EditorViewModelPitchTests.swift` (1 seeding call)

**Interfaces:**
- Consumes: `EditIntent` (SheetMusicCore, 14 cases — `.inputNote(at: RestID, pitch: Int, tpc: Int, duration: NoteDuration?)`, `.setRestDuration(at: VoiceElementID, duration: NoteDuration)`, `.setChordDuration(at:duration:)`, `.delete(at: VoiceElementID)`, `.composite([EditIntent])`, `.setNotePitch(at: NoteID, pitch: Int, tpc: Int, accidental: Accidental?)`, `.setAccidental(at: NoteID, accidental: Accidental?)`, `.addNoteToChord(at: VoiceElementID, pitch: Int, tpc: Int, accidental: Accidental?)`, `.removeNoteFromChord(at: NoteID)`, `.setTie(from: NoteID, to: NoteID, sourceTieForward: Int?, targetTieBack: Int?)`, `.createTuplet(at:actualNotes:normalNotes:)`, `.removeTuplet(at: VoiceElementID)`, `.writeNote(at: VoiceElementID, pitch: Int, tpc: Int, duration: NoteDuration?)`, `.writeRest(at: VoiceElementID, duration: NoteDuration)`). `EditIntent` is `Equatable` — tests compare intents by value.
- Produces: `EditorViewModel.apply(_ intent: EditIntent) -> Bool` (`@discardableResult`, internal — every later task's call sites route through this exact name and signature); `EditorViewModel.appliedIntents: [EditIntent]` (DEBUG-only, `private(set)`, read by Task 5's tests via `@testable`); `TransitionalIntentPlanning.command(for:in:depth:)` (deleted in Task 4).

- [ ] **Step 1: Retarget the four test files' seeding calls (the failing tests)**

These calls seed edits through the internal seam as a shorthand; they are the mechanical retarget the spec's pass condition names, and until `apply(_:)` exists they fail to compile — which is this task's red state. **Assertions stay untouched.**

In `EditorViewModelPersistenceTests.swift` (lines 94, 126, 155, 156, 157, 203, 236), `EditorViewModelRevertTests.swift` (lines 68, 90, 111, 146, 187, 231), and `EditorViewModelSessionTests.swift` (lines 28, 38, 56, 81), every

```swift
vm.applyCommand(InputNote(at: EditorFixtures.restID(element: N), pitch: P, tpc: T))
```

becomes

```swift
vm.apply(.inputNote(at: EditorFixtures.restID(element: N), pitch: P, tpc: T, duration: nil))
```

(with each site's own `N`/`P`/`T` values — e.g. line 156 becomes `.inputNote(at: EditorFixtures.restID(element: 2), pitch: 62, tpc: 16, duration: nil)`).

In `EditorViewModelSessionTests.swift:73` and `EditorViewModelPitchTests.swift:43`, the two `SetNotePitch` seeds:

```swift
vm.applyCommand(SetNotePitch(at: EditorFixtures.noteID(element: 1), pitch: 61, tpc: 21))
// becomes
vm.apply(.setNotePitch(at: EditorFixtures.noteID(element: 1), pitch: 61, tpc: 21, accidental: nil))
```

```swift
vm.applyCommand(SetNotePitch(at: noteID, pitch: 127, tpc: 19))
// becomes
vm.apply(.setNotePitch(at: noteID, pitch: 127, tpc: 19, accidental: nil))
```

(`SetNotePitch.init` defaults `accidental` to `nil`, so `accidental: nil` is byte-identical seeding. `.setNotePitch` walks the tie chain, but both seeds target untied notes — a chain of one — which ssm plans back to the identical bare `SetNotePitch`. Note `EditorViewModelSessionTests.swift:73` sits inside the test `invalid edit is swallowed and mutates nothing`, which targets a rest: the intent path refuses it just as the command path did — `TiePlanner.tieChain` of a rest is empty, planning returns `nil`, `apply` returns `false`, `generation` stays 0.)

Also rename the two test display names in `EditorViewModelSessionTests.swift` that say `applyCommand` — `beginSession arms the editor and applyCommand mutates + notifies` → `beginSession arms the editor and apply mutates + notifies`, and `appliedEditCount bumps only on applyCommand, never on undo or redo` → `appliedEditCount bumps only on apply, never on undo or redo` — and the `applyCommand` mentions in their comments. Names are not assertions.

- [ ] **Step 2: Run the Editor suite to verify it fails**

```sh
env -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo/Packages/Features/Editor \
  xcodebuild test -scheme Editor \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation
```

Expected: **FAIL to compile** — `value of type 'EditorViewModel' has no member 'apply'`.

- [ ] **Step 3: Create the transitional planner**

Create `Packages/Features/Editor/Sources/Editor/TransitionalIntentPlanning.swift`. This is a **verbatim transcription** of `ScoreEditSession.command(for:in:depth:)` and its private helpers from swift-sheet-music 1.15.0 (`Sources/SheetMusicCore/Editing/ScoreEditSession.swift`), with the doc comments condensed to pointers. Do not fix, reorder, or improve anything in it — fidelity to the ssm original is the entire point, and Task 4's green gate is what proves the copy exact.

```swift
import Domain
import Foundation
import SheetMusicCore

/// TRANSITIONAL — Task 4 of `docs/superpowers/plans/2026-08-19-cross-session-undo.md` deletes this file.
///
/// A verbatim host-side copy of `ScoreEditSession`'s intent planning (swift-sheet-music 1.15.0,
/// `ScoreEditSession.command(for:in:depth:)` and its private helpers), kept only so the Editor's call sites can
/// migrate to `EditIntent` one reviewable slice at a time while the view model still holds a `ScoreEditor` —
/// `ScoreEditSession` exposes no raw-command apply, so the two entry points cannot share one engine any other way.
/// Task 4 swaps the engine to `ScoreEditSession` (whose own copy of this planning takes over) and deletes this file.
/// Do not fix or improve anything here: fidelity to the ssm original is the point, and the gate suites prove it.
enum TransitionalIntentPlanning {
    /// Mirrors `ScoreEditSession.maxCompositeIntentDepth`.
    private static let maxCompositeIntentDepth = 8

    /// Mirrors `ScoreEditSession.command(for:in:depth:)`: plans an intent against `score`. `nil` when the intent has
    /// nothing to do; throws when a nested `.composite` exceeds the depth bound or names an impossible edit.
    static func command(for intent: EditIntent, in score: Score, depth: Int = 0) throws -> (any EditCommand)? {
        switch intent {
        case let .inputNote(location, pitch, tpc, duration):
            return inputNoteCommand(at: location, pitch: pitch, tpc: tpc, duration: duration, in: score)
        case let .setRestDuration(location, duration):
            // Cross-bar first, then the bar-filling `.measure` promotion — see ssm's comments.
            if let plan = CrossBarInputPlanner.plan(.rest, duration: duration, at: location, in: score) {
                return CompositeEditCommand(commands: plan.commands, location: plan.head)
            }
            return SetRestDuration(
                at: location, duration: RestDurationPromotion.promoted(duration, at: location, in: score),
            )
        case let .setChordDuration(location, duration):
            // Planned from the chord ALREADY in the slot so its other notes survive the barline. No `.measure`
            // promotion: that spelling is rest-only.
            if case let .chord(current)? = score[location], !current.notes.isEmpty,
               let plan = CrossBarInputPlanner.plan(.chord(current), duration: duration, at: location, in: score)
            {
                return CompositeEditCommand(commands: plan.commands, location: plan.head)
            }
            return SetChordDuration(at: location, duration: duration)
        case let .delete(location):
            // A delete that empties its bar leaves ONE measure rest; the collapsed rest's element index is threaded
            // into the composite's location so `lastAffectedLocation` names the rest, not element 0.
            if let plan = FullMeasureRestCollapse.plan(deleting: location, in: score) {
                return CompositeEditCommand(
                    commands: [plan.command],
                    location: VoiceElementID(
                        staff: location.staff,
                        measureIndex: location.measureIndex,
                        voiceIndex: location.voiceIndex,
                        elementIndex: plan.restElementIndex,
                    ),
                )
            }
            return DeleteVoiceElement(at: location)
        case let .composite(intents):
            guard depth < maxCompositeIntentDepth else {
                throw SheetMusicError.invalidEdit(
                    reason: "composite nesting exceeds depth limit (\(maxCompositeIntentDepth))",
                )
            }
            let commands = try intents.compactMap { try command(for: $0, in: score, depth: depth + 1) }
            guard let first = commands.first else { return nil }
            guard commands.count > 1 else { return first }
            return CompositeEditCommand(commands: commands, location: first.affectedLocation)
        case let .writeNote(location, pitch, tpc, duration):
            return try writeNoteCommand(at: location, pitch: pitch, tpc: tpc, duration: duration, in: score)
        case let .writeRest(location, duration):
            return writeRestCommand(at: location, duration: duration, in: score)
        case let .setNotePitch(location, pitch, tpc, accidental):
            return retuneCommand(at: location, pitch: pitch, tpc: tpc, accidental: accidental, in: score)
        case .setAccidental, .addNoteToChord, .removeNoteFromChord, .setTie, .createTuplet, .removeTuplet:
            return try directNoteEditCommand(for: intent)
        }
    }

    /// Mirrors `ScoreEditSession.inputNoteCommand`: write a note into a rest slot, re-timing it in the same undo
    /// step — bare inside a tuplet, a tied chain when the length outruns the bar.
    private static func inputNoteCommand(
        at location: RestID, pitch: Int, tpc: Int, duration: NoteDuration?, in score: Score,
    ) -> any EditCommand {
        let write = InputNote(at: location, pitch: pitch, tpc: tpc)
        guard let duration else { return write }
        let slot = VoiceElementID(location)
        guard !isInTuplet(slot, in: score) else { return write }
        if let plan = CrossBarInputPlanner.plan(
            .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: tpc)])),
            duration: duration, at: slot, in: score,
        ) {
            return CompositeEditCommand(commands: plan.commands, location: plan.head)
        }
        return CompositeEditCommand(
            commands: [SetRestDuration(at: slot, duration: duration), write],
            location: slot,
        )
    }

    /// Mirrors `ScoreEditSession.writeRestCommand`: make the slot a rest of `duration`, whatever is in it now.
    /// The delete inside is the PLAIN one — `.delete` keeps the full-measure collapse, this intent must not.
    private static func writeRestCommand(
        at location: VoiceElementID, duration: NoteDuration, in score: Score,
    ) -> (any EditCommand)? {
        guard case let .chord(current)? = score[location] else { return nil }
        if let plan = CrossBarInputPlanner.plan(.rest, duration: duration, at: location, in: score) {
            return CompositeEditCommand(commands: plan.commands, location: plan.head)
        }
        let retime = SetRestDuration(
            at: location, duration: RestDurationPromotion.promoted(duration, at: location, in: score),
        )
        guard !current.notes.isEmpty else { return retime }
        return CompositeEditCommand(
            commands: [DeleteVoiceElement(at: location), retime], location: location,
        )
    }

    /// Mirrors `ScoreEditSession.retuneCommand`: the pitch goes onto `location` AND every note it is tied to, as
    /// one command; the accidental glyph onto the chain's head alone. A chain of one comes back as a bare
    /// `SetNotePitch`.
    private static func retuneCommand(
        at location: NoteID, pitch: Int, tpc: Int, accidental: Accidental?, in score: Score,
    ) -> (any EditCommand)? {
        let chain = TiePlanner.tieChain(containing: location, in: score)
        guard !chain.isEmpty else { return nil }
        let commands: [any EditCommand] = chain.map { member in
            SetNotePitch(
                at: member, pitch: pitch, tpc: tpc,
                accidental: score[member]?.tieBack == nil ? accidental : nil,
            )
        }
        guard commands.count > 1 else { return commands[0] }
        return CompositeEditCommand(commands: commands, location: VoiceElementID(location))
    }

    /// Mirrors `ScoreEditSession.directNoteEditCommand`: the six intents that map straight onto an `EditCommand`.
    private static func directNoteEditCommand(for intent: EditIntent) throws -> (any EditCommand)? {
        if case let .setAccidental(location, accidental) = intent {
            return SetAccidental(at: location, accidental: accidental)
        }
        if case let .addNoteToChord(location, pitch, tpc, accidental) = intent {
            return AddNoteToChord(at: location, pitch: pitch, tpc: tpc, accidental: accidental)
        }
        if case let .removeNoteFromChord(location) = intent {
            return RemoveNoteFromChord(at: location)
        }
        if case let .setTie(source, target, sourceTieForward, targetTieBack) = intent {
            return SetTie(
                from: source, to: target,
                sourceTieForward: sourceTieForward, targetTieBack: targetTieBack,
            )
        }
        if case let .createTuplet(location, actualNotes, normalNotes) = intent {
            guard actualNotes > 1, normalNotes > 0 else {
                throw SheetMusicError.invalidEdit(
                    reason: "createTuplet: ratio \(actualNotes):\(normalNotes) is not a tuplet",
                )
            }
            return CreateTuplet(at: location, actualNotes: actualNotes, normalNotes: normalNotes)
        }
        if case let .removeTuplet(location) = intent {
            return RemoveTuplet(at: location)
        }
        return nil
    }

    /// Mirrors `ScoreEditSession.writeNoteCommand`: re-pitch the chord already in `location` (notehead 0), re-timing
    /// it in the same undo step; a barline-crossing length is spelled as a fresh single-note chain at the NEW pitch.
    /// Throws when the slot holds a rest — that is `.inputNote`'s case.
    private static func writeNoteCommand(
        at location: VoiceElementID, pitch: Int, tpc: Int, duration: NoteDuration?, in score: Score,
    ) throws -> any EditCommand {
        guard case let .chord(current)? = score[location], !current.notes.isEmpty else {
            throw SheetMusicError.invalidEdit(reason: "writeNote: no chord at \(location)")
        }
        let repitch = SetNotePitch(
            at: NoteID(
                staff: location.staff,
                measureIndex: location.measureIndex,
                voiceIndex: location.voiceIndex,
                elementIndex: location.elementIndex,
                noteIndexInChord: 0,
            ),
            pitch: pitch, tpc: tpc,
        )
        guard let duration, current.duration != duration, !isInTuplet(location, in: score) else {
            return repitch
        }
        if let plan = CrossBarInputPlanner.plan(
            .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: tpc)])),
            duration: duration, at: location, in: score,
        ) {
            return CompositeEditCommand(commands: plan.commands, location: plan.head)
        }
        return CompositeEditCommand(
            commands: [SetChordDuration(at: location, duration: duration), repitch],
            location: location,
        )
    }

    /// Mirrors `ScoreEditSession.isInTuplet`.
    private static func isInTuplet(_ slot: VoiceElementID, in score: Score) -> Bool {
        guard let staff = score[slot.staff],
              staff.measures.indices.contains(slot.measureIndex)
        else { return false }
        let voices = staff.measures[slot.measureIndex].voices
        guard voices.indices.contains(slot.voiceIndex) else { return false }
        return voices[slot.voiceIndex].tuplets.contains {
            slot.elementIndex >= $0.startIndex && slot.elementIndex <= $0.endIndex
        }
    }
}
```

- [ ] **Step 4: Add `apply(_ intent:)` and the DEBUG intent log to `EditorViewModel.swift`**

Directly below `applyCommand(_:)` (both must live in this file — `generation`, `appliedEditCount`, and `sessionEditDepth` have `private(set)` setters that do not span files):

```swift
    /// Central apply choke point for intent-driven edits — the seam every op is migrating to, and (from the engine
    /// swap on) the only one. Plans the intent exactly as `ScoreEditSession.apply(_:)` would, via the transitional
    /// copy of its planning, and routes the planned command through `applyCommand` so selection re-derivation,
    /// generation bump, `onScoreChanged`, and autosave can never be skipped. Returns `false` when the intent was
    /// refused; the engine's contract leaves the score untouched, so `generation` is unmoved and no side effect
    /// fires.
    @discardableResult
    func apply(_ intent: EditIntent) -> Bool {
        #if DEBUG
        appliedIntents.append(intent)
        #endif
        guard let editor else { return false }
        let planned: (any EditCommand)?
        do {
            planned = try TransitionalIntentPlanning.command(for: intent, in: editor.score)
        } catch {
            return false
        }
        guard let planned else { return false }
        let generationBeforeApply = generation
        applyCommand(planned)
        return generation != generationBeforeApply
    }
```

And with the other DEBUG helpers (beside `previewSeedSessionEdit`):

```swift
    #if DEBUG
    /// Every intent handed to `apply(_:)`, in order, refused ones included — the seam the intent-construction tests
    /// read. DEBUG-only: release builds carry neither the array nor its appends.
    @ObservationIgnored private(set) var appliedIntents: [EditIntent] = []
    #endif
```

`EditorViewModel.swift` is at 375 lines and this adds ~30; the 400-line budget holds but is tight until Task 4 removes ~45. If a later task crosses it, the pressure valve is moving the read-only derived properties (`hasEditTarget`, `isNoteSelected`, `hasSelectionCallout`) to a new extension file — they touch no private setters.

- [ ] **Step 5: Migrate the scalar 1:1 call sites**

These are the sites whose intent maps to a single scalar constructor — no planner involvement changes hands, so ssm's planning provably equals today's command.

`EditorViewModel+Input.swift`, `deleteSelection()` — the `.note` multi-note branch (line 45) and the `.tuplet` branch (line 52):

```swift
        case let .note(noteID):
            guard case let .chord(chord)? = score[VoiceElementID(noteID)] else { return }
            if chord.notes.count > 1 {
                apply(.removeNoteFromChord(at: noteID))
            } else {
                deleteElement(at: VoiceElementID(noteID), in: score)
            }
```

```swift
        case let .tuplet(tupletID):
            apply(.removeTuplet(at: VoiceElementID(
                staff: tupletID.staff,
                measureIndex: tupletID.measureIndex,
                voiceIndex: tupletID.voiceIndex,
                elementIndex: tupletID.startElementIndex,
            )))
```

`EditorViewModel+ChordTieTuplet.swift`:

```swift
    /// −音 → `.removeNoteFromChord` on the selected notehead (last note leaves a rest, engine-canonical).
    public func removeSelectedNoteFromChord() {
        guard case let .note(noteID)? = selectedItem else { return }
        apply(.removeNoteFromChord(at: noteID))
    }
```

`addNoteToChord(at:pitch:tpc:keySig:)` (line 51) — the refusal guard reads `apply`'s result instead of re-reading `generation`:

```swift
    private func addNoteToChord(at noteID: NoteID, pitch: Int, tpc: Int, keySig: Int) {
        let accidental = PitchSpelling.displayedAccidental(forTpc: tpc, in: keySig)
        let veID = VoiceElementID(noteID)
        guard apply(.addNoteToChord(at: veID, pitch: pitch, tpc: tpc, accidental: accidental)),
              let score, case let .chord(chord)? = score[veID] else { return }
        let addedNoteID = NoteID(
            staff: noteID.staff,
            measureIndex: noteID.measureIndex,
            voiceIndex: noteID.voiceIndex,
            elementIndex: noteID.elementIndex,
            noteIndexInChord: chord.notes.count - 1,
        )
        select(.note(addedNoteID))
        audition(addedNoteID)
    }
```

`toggleTie()` (lines 168–178):

```swift
    public func toggleTie() {
        guard case let .note(noteID)? = selectedItem, let score, let note = score[noteID],
              let targetID = TiePlanner.tieTarget(for: noteID, in: score)
        else { return }
        if note.tieForward != nil {
            apply(.setTie(from: noteID, to: targetID, sourceTieForward: nil, targetTieBack: nil))
        } else {
            apply(.setTie(from: noteID, to: targetID, sourceTieForward: 1, targetTieBack: 1))
        }
    }
```

`createTuplet(actualNotes:)` (line 221) and `removeTuplet()` (line 231) — the `actualNotes >= 2` guard, `armedTuplet` recording, and `normalNotes(forActualNotes:)` all stay host-side (key interpretation, per the spec):

```swift
        apply(.createTuplet(
            at: Self.tupletTarget(caretItem),
            actualNotes: actualNotes,
            normalNotes: Self.normalNotes(forActualNotes: actualNotes),
        ))
```

```swift
    public func removeTuplet() {
        guard let caretItem else { return }
        apply(.removeTuplet(at: Self.tupletTarget(caretItem)))
    }
```

`EditorViewModel+Pitch.swift`, `setAccidental(_:)` (line 57):

```swift
    public func setAccidental(_ accidental: Accidental?) {
        guard case let .note(noteID)? = selectedItem else { return }
        let generationBeforeSet = generation
        apply(.setAccidental(at: noteID, accidental: accidental))
        auditionSelectedNote(unlessStillAt: generationBeforeSet)
    }
```

Leave every other `applyCommand` call site untouched — Tasks 2 and 3 take them.

- [ ] **Step 6: Run the full Editor suite to verify it passes**

Same command as Step 2. Expected: **PASS — 155 tests, 17 suites** (the baseline; the retarget adds no tests).

- [ ] **Step 7: Commit**

```sh
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo add Packages/Features/Editor
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo commit -m "refactor(editor): route edits through EditIntent behind a transitional planner"
```

---

## Task 2: Cross-bar, rest, and collapse call sites

**Files:**
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Input.swift` — `writeRest(over:in:)` (:91-115), `restDuration(_:at:)` (:117-146, **delete**), `deleteElement(at:in:)` (:153-172), `applyToSelection(base:dots:)` (:220-238), `retimeCrossingBarline(...)` (:240-255, **delete**), `inputPitch(letter:onRest:in:)` (:279-308), `land(after:)` area (:357-380)

**Interfaces:**
- Consumes: `apply(_ intent: EditIntent) -> Bool` from Task 1.
- Produces: `chainTail(from head: VoiceElementID, in score: Score) -> VoiceElementID` (private to `EditorViewModel+Input.swift`; Task 3's `inputPitch(letter:onNote:in:)` in the same file reuses it). The read-only planner predicate `CrossBarInputPlanner.fitsInMeasure(_:at:in:)` is used to decide the caret landing — allowed by the spec ("predicates may keep calling the public planners read-only").

**What is deleted here, and why it's safe:** ssm's `.delete` runs `FullMeasureRestCollapse` and threads the collapsed rest's element index into `lastAffectedLocation`; `.writeRest` pairs the plain delete with the promoted re-time; `.setRestDuration` / `.setChordDuration` ask `CrossBarInputPlanner` before falling back; `RestDurationPromotion.promoted` is the same rule as the host's `restDuration(_:at:)`. Each deletion below hands planning to the identical ssm implementation — that identity is what the gate suites check.

**Behavioral watch item (do not "fix" the tests):** the explicit `select(.rest(plan.restElementIndex))` after a collapsing delete goes away; re-derivation lands the selection on the collapsed rest via the composite's location. The one visible difference is a caret that was parked in a *different measure* during a collapsing ⌫: today it is yanked onto the rest, after this task it stays put (re-derivation's usual split). No gate suite pins the old yank; if one fails here, STOP and escalate rather than editing the assertion — pass condition (a) requires public-op suites unchanged.

- [ ] **Step 1: Migrate `deleteElement`**

Replace the whole method (the `FullMeasureRestCollapse` plan, the generation guard, and the explicit `select` all move into ssm's `.delete`):

```swift
    /// `.delete`: a plain delete leaves a same-duration rest; a delete that empties its bar collapses the voice-
    /// measure to ONE measure rest (ssm's `FullMeasureRestCollapse`), reporting the collapsed rest as the affected
    /// location — so re-derivation lands the selection there without the explicit `select` this method used to do.
    private func deleteElement(at location: VoiceElementID, in _: Score) {
        apply(.delete(at: location))
    }
```

(Then simplify the two callers to drop the now-unused `score` argument if SwiftLint's `unused_parameter` complains — or keep the parameter as `in _: Score` exactly as written so the call sites don't churn. Keep it as written.)

- [ ] **Step 2: Migrate `writeRest(over:in:)` and delete `restDuration(_:at:)`**

The host keeps the *interpretation* guard — what the rest key means with nothing (or the same length) armed, and inside a tuplet — and hands the *planning* (cross-bar chain, `.measure` promotion, delete-and-retime composite) to `.writeRest`:

```swift
    /// Writes a rest of the armed length over the timed slot at `location`, whatever is currently in it.
    ///
    /// The guard is the key's INTERPRETATION and stays here: with nothing armed, the armed length already in the
    /// slot, or a tuplet member (whose lengths are the tuplet's to decide), the key falls back to a plain delete on
    /// a note and does nothing on a rest — exactly as before. Everything past the guard is planning, and
    /// `.writeRest` owns it now: the cross-barline run of rests, the `.measure` promotion for a bar-filling length,
    /// and the delete-plus-retime composite over a note (with the PLAIN delete — re-timing must not collapse the
    /// bar it empties, that would throw away the length the user just stated).
    private func writeRest(over location: VoiceElementID, in score: Score) {
        guard case let .chord(current)? = score[location] else { return }
        let isNote = !current.notes.isEmpty
        guard let armed = armedInputDuration, current.duration != armed, !isInsideTuplet(location) else {
            if isNote { deleteSelection() }
            return
        }
        apply(.writeRest(at: location, duration: armed))
    }
```

Delete `restDuration(_ duration:at:)` (lines 117–146) entirely — ssm's `RestDurationPromotion.promoted` is the same rule, and after this step nothing calls it.

- [ ] **Step 3: Migrate `applyToSelection` and delete `retimeCrossingBarline`**

```swift
    private func applyToSelection(base: NoteDuration, dots: Int) {
        guard let selectedItem, let slot = Self.slot(of: selectedItem) else { return }
        let duration = dots > 0 ? base.dotted(dots) : base
        switch selectedItem {
        case .note:
            // `.setChordDuration` spells a length the bar can't hold as a chain across the barline itself — from
            // the chord ALREADY in the slot, so its other notes survive — and the engine's refusal of a bad slot
            // is the same observable no-op the old early-return produced.
            apply(.setChordDuration(at: slot, duration: duration))
        case .rest:
            apply(.setRestDuration(at: slot, duration: duration))
        case .tuplet, .clef:
            return
        }
    }
```

Delete `retimeCrossingBarline(_:duration:at:in:)` (lines 240–255) — both of its callers just migrated. (The `score` property read and the `guard case .chord` in the old note branch are gone: ssm re-derives both from the intent's location.)

- [ ] **Step 4: Migrate `inputPitch(letter:onRest:in:)` with the caret-tail compensation**

The session reports only the chain's head (`lastAffectedLocation`); the caret must land past the chain's *tail*. Recompute the tail by walking `TiePlanner.tieChain(containing:)` from the head note — a fresh cross-bar write's chain is exactly the planner's chain (its head has no `tieBack`). Whether the write crossed the bar is decided *before* the apply with the read-only predicate, because an in-bar overwrite of an already-tied note must NOT walk that pre-existing chain (the caret belongs one slot on, as today):

```swift
    private func inputPitch(letter: Character, onRest restID: RestID, in score: Score) {
        let veID = VoiceElementID(restID)
        guard let rest = score[restID],
              let planned = MeasureAccidentals.plannedPitch(
                  forLetter: letter,
                  nearestTo: referencePitch(before: veID),
                  at: veID,
                  in: score,
              )
        else { return }
        // The armed length rides as the intent's `duration` — ssm re-times the slot, skips the re-time inside a
        // tuplet, and spells a length that outruns the bar as a tied chain. `nil` when there is nothing to re-time,
        // mirroring the old guard exactly: ssm's `.inputNote` does not skip a same-length re-time on its own, and a
        // no-op `SetRestDuration` must not ride along in the undo step.
        var duration: NoteDuration?
        if let armed = armedInputDuration, rest.duration != armed { duration = armed }
        // Decided BEFORE the apply, against the pre-edit score: after a chain write the caret belongs past the
        // chain's tail, but after an in-bar write it belongs one slot on even if the slot's note is (or becomes)
        // tied to something else — walking the chain unconditionally would overshoot there.
        let crossesBar = duration.map { !CrossBarInputPlanner.fitsInMeasure($0, at: veID, in: score) } ?? false
        let generationBeforeInput = generation
        guard apply(.inputNote(at: restID, pitch: planned.pitch, tpc: planned.tpc, duration: duration)) else {
            return
        }
        if crossesBar, let mutated = self.score {
            land(
                selection: veID,
                caretAfter: chainTail(from: veID, in: mutated),
                unlessStillAt: generationBeforeInput,
            )
        } else {
            land(after: veID, unlessStillAt: generationBeforeInput)
        }
    }
```

Add the tail walk beside `land(after:)`:

```swift
    /// The last slot of the tie chain a cross-barline write just produced at `head` — where the caret's "past what
    /// was written" starts. The chain a fresh write produces is exactly the planner's chain (its head has no
    /// `tieBack`), and `TiePlanner.tieChain` walks it whole; a chain of one hands back `head` itself.
    private func chainTail(from head: VoiceElementID, in score: Score) -> VoiceElementID {
        let headNote = NoteID(
            staff: head.staff,
            measureIndex: head.measureIndex,
            voiceIndex: head.voiceIndex,
            elementIndex: head.elementIndex,
            noteIndexInChord: 0,
        )
        guard let tail = TiePlanner.tieChain(containing: headNote, in: score).last else { return head }
        return VoiceElementID(tail)
    }
```

Do **not** touch `writeCrossingBarline` yet — `inputPitch(letter:onNote:in:)` still calls it until Task 3. The rest-slot call at line 354 is dead for this path now (the intent subsumed it); the shared helper is deleted in Task 3 when its last caller migrates.

Actually, check: `writeCrossingBarline` at `+Input.swift:340-355` is called from BOTH `inputPitch(letter:onRest:in:)` (which this step just rewrote — remove that call) and `inputPitch(letter:onNote:in:)` (Task 3). After this step it must have exactly one remaining caller (`onNote`). Verify with:

```sh
grep -n "writeCrossingBarline" /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo/Packages/Features/Editor/Sources/Editor/EditorViewModel+Input.swift
```

Expected: the declaration plus one call site (in `inputPitch(letter:onNote:in:)`).

- [ ] **Step 5: Run the full Editor suite**

```sh
env -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo/Packages/Features/Editor \
  xcodebuild test -scheme Editor \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation
```

Expected: **PASS — 155 tests.** `CrossBarInputTests` and `EditorViewModelInputTests` are the suites most sensitive to this slice; a failure there means the migration diverged — debug the call site, never the assertion.

- [ ] **Step 6: Commit**

```sh
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo add Packages/Features/Editor
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo commit -m "refactor(editor): drive cross-bar, rest, and collapse edits by intent"
```

---

## Task 3: Pitch, tie-append, and note-overwrite call sites

**Files:**
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Input.swift` — `inputPitch(letter:onNote:in:)` (:310-338), `writeCrossingBarline(...)` (:340-355, **delete**)
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+ChordTieTuplet.swift` — `appendTiedNote()` / `canAppendTiedNote` / `tieAppendPlan()` (:79-166)
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Pitch.swift` — `retune(_:in:pitch:tpc:accidental:)` (:33-52)

**Interfaces:**
- Consumes: `apply(_ intent:)` (Task 1), `chainTail(from:in:)` (Task 2, same file as `inputPitch`).
- Produces: `tieAppendIntent() -> EditIntent?` (private to `+ChordTieTuplet.swift`, replacing `tieAppendPlan()`).

**The one real behavioral fork, ruled here:** `.writeNote` re-pitches `noteIndexInChord: 0`; today's `inputPitch(letter:onNote:)` re-pitches the caret's own `NoteID`, which can name a non-zero notehead. Both outcomes: *(A)* adopt ssm's index-0 semantics — but the non-zero case is reachable by a real flow (＋音 adds a note, the ADDED note stays selected and carries the caret, and typing a letter to fix it would then re-pitch the chord's root instead of the note just added); *(B)* keep today's behavior with a narrow host-side branch. **Ruled: (B).** The branch constructs *intents* (`.setNotePitch`, `.composite`) — not `EditCommand`s — so pass condition (b) is untouched, and which notehead a letter means is input *interpretation*, which the spec keeps host-side. The barline-crossing case takes `.writeNote` even for a non-zero index, because today's code already collapses the chord to a single note of the new pitch there — no index survives that. One knowing divergence rides along: `.setNotePitch` walks the tie chain, so re-pitching a *tied* upper notehead now moves its tied partners too — today it silently broke the tie's pitch match (two pitches joined by a curve), which is the exact bug the chevrons' chain-walk fixed; this is accepted as an improvement, not compensated. Task 3 also leaves a `PARITY(android)` marker, since Android's `.writeNote` path keeps index-0 semantics.

- [ ] **Step 1: Migrate `inputPitch(letter:onNote:in:)` and delete `writeCrossingBarline`**

Replace the method:

```swift
    /// A letter key on a slot that already holds a note: re-pitch it, and re-time it to the armed length too —
    /// `.writeNote`'s own meaning. Writing over an existing note is still writing a note, and the length keys say
    /// what the next note will be, so a quarter armed over an existing half has to produce a quarter.
    ///
    /// One case stays host-side: a caret naming a chord's UPPER notehead (`noteIndexInChord != 0`) — reached by
    /// ＋音 adding a note (which selects the added note) and typing a letter to fix it. `.writeNote` re-pitches
    /// notehead 0; the user in that flow means the notehead the caret names, so the intent is built to say so
    /// (which notehead a letter means is interpretation, not planning). The barline case takes `.writeNote` for
    /// any index: the pre-intent code already collapsed the chord to a single note of the new pitch when the armed
    /// length crossed the bar, and that is exactly what `.writeNote` plans.
    // PARITY(android): letter input on a chord's upper notehead — Android's `.writeNote` path re-pitches
    // notehead 0; Android still needs the caret-notehead `.setNotePitch` branch iOS keeps here.
    private func inputPitch(letter: Character, onNote noteID: NoteID, in score: Score) {
        let veID = VoiceElementID(noteID)
        guard let note = score[noteID],
              let target = MeasureAccidentals.plannedPitch(
                  forLetter: letter, nearestTo: note.pitch, at: veID, in: score,
              )
        else { return }
        var duration: NoteDuration?
        if let armed = armedInputDuration, case let .chord(chord)? = score[veID], chord.duration != armed {
            duration = armed
        }
        let crossesBar = duration.map { !CrossBarInputPlanner.fitsInMeasure($0, at: veID, in: score) } ?? false
        let generationBeforeInput = generation
        let applied: Bool
        if noteID.noteIndexInChord == 0 || crossesBar {
            applied = apply(.writeNote(at: veID, pitch: target.pitch, tpc: target.tpc, duration: duration))
        } else {
            let repitch = EditIntent.setNotePitch(
                at: noteID, pitch: target.pitch, tpc: target.tpc, accidental: nil,
            )
            if let duration, !isInsideTuplet(veID) {
                applied = apply(.composite([.setChordDuration(at: veID, duration: duration), repitch]))
            } else {
                applied = apply(repitch)
            }
        }
        guard applied else { return }
        if crossesBar, let mutated = self.score {
            land(
                selection: veID,
                caretAfter: chainTail(from: veID, in: mutated),
                unlessStillAt: generationBeforeInput,
            )
        } else {
            land(after: veID, unlessStillAt: generationBeforeInput)
        }
    }
```

Delete `writeCrossingBarline(pitch:tpc:at:in:from:)` (its last caller is gone).

- [ ] **Step 2: Migrate `retune` — ssm walks the tie chain**

Replace the method (and drop its now-unused `in score:` parameter; update the three callers in `shiftPitch`, `shiftOctave` — they keep their own `score` reads for `keySig` / `note`):

```swift
    /// Writes a pitch onto `noteID` AND onto every note it is tied to, as one undo step — `.setNotePitch` owns the
    /// chain walk now (ssm's `retuneCommand`), including "the accidental glyph belongs to the chain's head alone".
    /// An untied note is a chain of one and plans back to the identical bare `SetNotePitch`.
    private func retune(_ noteID: NoteID, pitch: Int, tpc: Int, accidental: Accidental?) {
        let generationBeforeShift = generation
        apply(.setNotePitch(at: noteID, pitch: pitch, tpc: tpc, accidental: accidental))
        auditionSelectedNote(unlessStillAt: generationBeforeShift)
    }
```

Callers become:

```swift
        retune(noteID, pitch: shifted.pitch, tpc: shifted.tpc, accidental: shifted.accidental)
```

```swift
        retune(noteID, pitch: newPitch, tpc: note.tpc, accidental: note.accidental)
```

- [ ] **Step 3: Migrate `appendTiedNote` with the selection compensation**

Replace `appendTiedNote()`, `canAppendTiedNote`, and `tieAppendPlan()`:

```swift
    /// The pad's tie ＋ key: writes a note of the ARMED length in the slot after the selected one, at the same
    /// pitch, and ties the two together — one intent, one undo step.
    ///
    /// ssm's `.composite` reports its FIRST member's location (the appended note), where the old command pinned the
    /// location to the source note so re-derivation kept the selection there. Compensate with an explicit
    /// `select(.note(sourceID))` after a successful apply — the same post-apply explicit landing
    /// `addNoteToChord(at:pitch:tpc:keySig:)` already does. The source's own slot index is untouched by the append
    /// (`SetRestDuration` re-splices what FOLLOWS the slot; a cross-bar plan rewrites from the next slot on), so
    /// the captured id stays valid.
    public func appendTiedNote() {
        guard case let .note(sourceID)? = selectedItem else { return }
        guard let intent = tieAppendIntent() else { return }
        guard apply(intent) else { return }
        select(.note(sourceID))
    }

    /// Whether `appendTiedNote` has somewhere to write: a selected note, an armed length, and a rest in the next
    /// slot to overwrite. A note already sitting there would have to be pushed aside, which is not what a tie key
    /// should quietly do.
    public var canAppendTiedNote: Bool {
        tieAppendIntent() != nil
    }

    /// The composite `appendTiedNote` applies: write the pitch into the next slot at the armed length (ssm spells a
    /// length that outruns the bar as a tied chain), then tie the source note onto what was written. Sound because
    /// ssm plans composite members against the PRE-edit score and `.setTie` is built purely from scalars — and the
    /// chain's head lands at the very slot being written (`CrossBarInputPlanner.Plan.head`), so the tie target's
    /// `NoteID` is `next`'s slot whether the length fits the bar or spills across it.
    ///
    /// `nil` (the key dims) when the length has no plan AND no room: the chain would run off the end of the staff,
    /// and issuing the write anyway just hands the engine an edit it refuses — a lit key that does nothing.
    private func tieAppendIntent() -> EditIntent? {
        guard case let .note(noteID)? = selectedItem, let score, let note = score[noteID],
              let armed = armedInputDuration,
              let next = ElementNavigator.nextTimedElement(after: VoiceElementID(noteID), in: score),
              case let .chord(target)? = score[next], target.notes.isEmpty
        else { return nil }
        guard CrossBarInputPlanner.fitsInMeasure(armed, at: next, in: score)
            || CrossBarInputPlanner.plan(
                .chord(Chord(duration: armed, notes: [Note(pitch: note.pitch, tpc: note.tpc)])),
                duration: armed, at: next, in: score,
            ) != nil
        else { return nil }
        let restID = RestID(
            staff: next.staff,
            measureIndex: next.measureIndex,
            voiceIndex: next.voiceIndex,
            elementIndex: next.elementIndex,
        )
        let headID = NoteID(
            staff: next.staff,
            measureIndex: next.measureIndex,
            voiceIndex: next.voiceIndex,
            elementIndex: next.elementIndex,
            noteIndexInChord: 0,
        )
        return .composite([
            .inputNote(
                at: restID, pitch: note.pitch, tpc: note.tpc,
                duration: target.duration != armed ? armed : nil,
            ),
            .setTie(from: noteID, to: headID, sourceTieForward: 1, targetTieBack: 1),
        ])
    }
```

(The `CrossBarInputPlanner.plan` call here is *availability interpretation* — whether the key lights — and mirrors the `fitsInMeasure` fallback the old code had; it constructs no command. It stays.)

- [ ] **Step 4: Regenerate the parity ledger**

The new `PARITY(android)` marker must be reflected in `docs/engineering/ios-android-parity.md` or the `parity-ledger` pre-commit hook fails the commit:

```sh
/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo/Scripts/parity-report.py
```

(If the script needs different invocation, `head -40` it for usage; it regenerates the ledger in place.)

- [ ] **Step 5: Run the full Editor suite**

Same command as Task 2 Step 5. Expected: **PASS — 155 tests.** `EditorViewModelChordTests` and `EditorViewModelPitchTests` are the sensitive suites here.

- [ ] **Step 6: Commit**

```sh
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo add Packages/Features/Editor docs/engineering/ios-android-parity.md
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo commit -m "refactor(editor): drive pitch, tie-append, and note-overwrite edits by intent"
```

---

## Task 4: The engine swap — delete the duplicated planning

**Files:**
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift` (property, `beginSession`, `endSession`, `undo`, `redo`, `unwindSessionEdits`, `apply`, delete `applyCommand` + `renotatingAccidentals`)
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Selection.swift:23-25`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Revert.swift:97` area (`editor = nil`)
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Discard.swift:66` (`guard let editor`)
- Delete: `Packages/Features/Editor/Sources/Editor/TransitionalIntentPlanning.swift`

**Interfaces:**
- Consumes: `ScoreEditSession` (SheetMusicCore): `init(score:)`, `score`, `lastAffectedLocation`, `canUndo`, `canRedo`, `lastRefusalReason`, `apply(_ intent:) -> Bool` (`@discardableResult`), `undo() -> Bool`, `redo() -> Bool`. A plain `final class`, not `@MainActor`, not `Sendable` — "hold one per isolation domain", which retaining it on the main actor satisfies.
- Produces: `EditorViewModel.session: ScoreEditSession?` (internal `var` — the old `editor` was `public internal(set)` but nothing outside the module reads it, so the `public` is dropped: `public` is a decision). Tasks 7–8 mutate `session` from `beginSession`/`endSession`/`+Revert`.

- [ ] **Step 1: Swap the held engine**

In `EditorViewModel.swift`, replace the property (and update the type's doc comment, which opens "Owns the engine `ScoreEditor`…" — it now owns a `ScoreEditSession`):

```swift
    /// The engine session for one editing entry — `ScoreEditSession` plans each `EditIntent` into commands and owns
    /// both undo stacks. Internal: views read the derived `score` / `canUndo` / `canRedo`, never the session itself.
    var session: ScoreEditSession?
```

Update every reader in this file:

```swift
    public var score: Score? {
        _ = generation
        return session?.score
    }
```

```swift
    public var isSessionActive: Bool {
        session != nil
    }
```

```swift
    public var canUndo: Bool {
        session?.canUndo ?? false
    }

    public var canRedo: Bool {
        session?.canRedo ?? false
    }
```

```swift
    public func beginSession(score: Score) {
        session = ScoreEditSession(score: score)
        generation = 0
        appliedEditCount = 0
        sessionEditDepth = 0
        capturedOriginalThisSession = false
        Task { await reconcileCapturedOriginal() }
        selection = .none
        selectedItem = nil
        caretItem = nil
        armedDuration = nil
        armedDots = 0
        isAddToChordArmed = false
    }
```

```swift
    public func endSession() async {
        await flushPendingSave()
        session = nil
    }
```

```swift
    public func undo() {
        // `session.undo()` guards `canUndo` and reports an engine failure as `false`, preserving the old contract:
        // a swallowed failure must not fire a false generation bump / onSelectionChanged / onScoreChanged.
        guard let session, session.undo() else { return }
        sessionEditDepth = max(0, sessionEditDepth - 1)
        generation += 1
        rederiveSelection()
        onScoreChanged(session.score)
        isDirty = true
        scheduleAutosave()
    }
```

```swift
    public func redo() {
        guard let session, session.redo() else { return }
        sessionEditDepth += 1
        generation += 1
        rederiveSelection()
        onScoreChanged(session.score)
        isDirty = true
        scheduleAutosave()
    }
```

```swift
    func unwindSessionEdits() {
        guard let session else { return }
        while session.canUndo {
            guard session.undo() else { break }
        }
        sessionEditDepth = 0
        generation += 1
        rederiveSelection()
        onScoreChanged(session.score)
    }
```

(`unwindSessionEdits` stays `while canUndo` in this task — correct while history never crosses sessions. Task 8 makes it count-driven when adoption arrives.)

- [ ] **Step 2: Rewrite `apply`, delete `applyCommand` and `renotatingAccidentals`**

```swift
    /// Central apply choke point: every edit goes through here so selection re-derivation, generation bump,
    /// `onScoreChanged`, and autosave scheduling can never be skipped. Internal — ops extensions call it. Returns
    /// `false` when the session refused the intent; the engine's contract leaves the score untouched, so no side
    /// effect fires (`session.lastRefusalReason` carries the diagnostic when debugging a refusal). The session owns
    /// the planning — cross-bar chains, full-measure collapse, `.measure` promotion, tie-chain retuning — AND the
    /// accidental renotation pass that used to be `renotatingAccidentals` here.
    @discardableResult
    func apply(_ intent: EditIntent) -> Bool {
        #if DEBUG
        appliedIntents.append(intent)
        #endif
        guard let session, session.apply(intent) else { return false }
        generation += 1
        appliedEditCount += 1
        sessionEditDepth += 1
        rederiveSelection()
        onScoreChanged(session.score)
        isDirty = true
        scheduleAutosave()
        return true
    }
```

Delete `applyCommand(_ command:)` and `renotatingAccidentals(_:from:)` entirely, and delete `TransitionalIntentPlanning.swift`.

Also refresh the comments in this file that describe the old engine: the `score` property's paragraph ("`ScoreEditor` is a plain class…" — so is `ScoreEditSession`; keep the reasoning, swap the name), `appliedEditCount`'s and `sessionEditDepth`'s mentions of `applyCommand` (now `apply`), `canUndo`'s mention of `ScoreEditor.canUndo`, and `registerSystemUndo`'s "ScoreEditor's own stacks". Same for `EditorChromeView.swift`'s bridge comment if it names `ScoreEditor` (comment-only change).

- [ ] **Step 3: Update the three extension files**

`EditorViewModel+Selection.swift`:

```swift
    func rederiveSelection() {
        guard let session, let location = session.lastAffectedLocation else { return }
        let score = session.score
```

`EditorViewModel+Revert.swift` (teardown, keeping the comment's reasoning):

```swift
        // Drop the session last: `canUndo` reads through it, so the toolbar goes inert only once the score on disk
        // is actually the original.
        session = nil
```

`EditorViewModel+Discard.swift`:

```swift
    public func discardSessionEdits() async {
        guard session != nil else { return }
```

(Its doc comment's "the bottom of `ScoreEditor`'s undo stack" wording gets the same name swap.)

- [ ] **Step 4: Sweep the comments that describe the deleted mechanism**

Step 6's grep deliberately catches *comments* too — prose describing a deleted mechanism is stale documentation, and this package's doc comments are load-bearing. Rewrite in the vocabulary of intents (lower-camel case names like `.removeNoteFromChord` do not match the grep's `RemoveNoteFromChord(`-style patterns, and back-ticked names without a following `(` mostly don't either — but the sweep is about correctness, not evading the grep):

- `EditorViewModel+Audition.swift:21` — "`applyCommand` actually mutated the score" → "`apply` actually mutated the score"; its header's command-name list ("after `InputNote`, `SetNotePitch` …") becomes the intent list ("after `.inputNote`, `.setNotePitch`/`.writeNote`, `.setAccidental`, `.addNoteToChord`, and interval adds").
- `EditorViewModel+Input.swift` — the file-level and `inputPitch`/`deleteSelection` doc comments name `InputNote` / `SetNotePitch` / `SetRestDuration` / `RemoveNoteFromChord` / `DeleteVoiceElement` / `RemoveTuplet` / `FullMeasureRestCollapse` / `CompositeEditCommand`; swap each for the intent that replaced it, keeping the reasoning sentences.
- `EditorViewModel+ChordTieTuplet.swift` and `+Pitch.swift` — same treatment for the ops comments Tasks 1–3 didn't already rewrite.
- Anything the Step 6 grep still surfaces after this sweep is either a missed comment (rewrite it) or real leftover construction (a Task 1–3 miss — migrate it).

- [ ] **Step 5: Run the full Editor suite**

Same command. Expected: **PASS — 155 tests.** This green run is the proof that `TransitionalIntentPlanning` was a faithful copy: the same call sites now plan through ssm and nothing moved.

- [ ] **Step 6: Prove the duplication is gone — pass condition (b)**

```sh
grep -rn -e "EditCommand" -e "InputNote(" -e "DeleteVoiceElement(" -e "SetRestDuration(" \
  -e "SetChordDuration(" -e "SetNotePitch(" -e "SetAccidental(" -e "AddNoteToChord(" \
  -e "RemoveNoteFromChord(" -e "SetTie(" -e "CreateTuplet(" -e "RemoveTuplet(" \
  -e "FullMeasureRestCollapse" -e "RestDurationPromotion" -e "renotatingAccidentals" -e "applyCommand" \
  /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo/Packages/Features/Editor/Sources
```

Expected: **no output (exit code 1).** `CompositeEditCommand` is covered by the `EditCommand` pattern. The read-only predicates that legitimately remain (`CrossBarInputPlanner.plan`/`.fitsInMeasure` in `tieAppendIntent`, `TiePlanner.tieTarget`/`.tieChain`, `MeasureAccidentals.plannedPitch`, `ElementNavigator`, `isInsideTuplet`) are deliberately not in this pattern list — they are availability/interpretation, not edit construction. If the grep prints anything, the task is not done (see Step 4 for how to treat a hit).

- [ ] **Step 7: Commit**

```sh
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo add Packages/Features/Editor
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo commit -m "refactor(editor): hold ScoreEditSession and delete the duplicated planning"
```

---

## Task 5: Intent-construction tests

**Files:**
- Create: `Packages/Features/Editor/Tests/EditorTests/EditorIntentConstructionTests.swift`

**Interfaces:**
- Consumes: `apply(_ intent:)` and DEBUG `appliedIntents: [EditIntent]` (Task 1), the migrated ops (Tasks 1–3), `EditorFixtures`. `EditIntent: Equatable` makes whole-value assertions possible.

These tests are verification of already-landed behavior, so they are expected to pass on first run — a failure means a Task 1–3 slice diverged, and the fix goes in the call site, never the assertion. They pin the *shape* handed to `ScoreEditSession` (the test style the intent seam buys), the caret-tail compensation, the `appendTiedNote` composite shapes, and the chord-upper-notehead ruling.

- [ ] **Step 1: Write the suite**

```swift
import Domain
@testable import Editor
import Foundation
import SheetMusicUI
import Testing

/// Pins the `EditIntent` each op constructs — the test style the intent seam buys: an op's contract with the engine
/// is now a value, so "what did this key ask for" is a plain equality check. Behavior is covered by the pre-existing
/// op suites; these lock the shape handed to `ScoreEditSession`, the two host-side compensations (caret past a
/// cross-barline chain's tail; selection pinned to the source after a tie-append), and the chord-upper-notehead
/// ruling.
@MainActor
@Suite("Editor intent construction")
struct EditorIntentConstructionTests {
    private func makeViewModel() -> EditorViewModel {
        EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: URL(filePath: "/tmp"),
            gateway: FakeScoreFileGateway(),
            repository: FakeScoreLibraryRepository(),
            originalStore: FakeScoreOriginalStore(),
            playback: nil,
        )
    }

    // MARK: - Note input

    @Test func `letter input on a rest with no re-time records a bare inputNote`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1))) // arms .quarter — the slot's own length
        vm.inputPitch(letter: "c")
        #expect(vm.appliedIntents == [
            .inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil),
        ])
    }

    @Test func `letter input on a rest with a different armed length carries it as the intent's duration`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))
        vm.setDuration(.eighth)
        vm.inputPitch(letter: "d")
        #expect(vm.appliedIntents == [
            .inputNote(at: EditorFixtures.restID(element: 1), pitch: 62, tpc: 16, duration: .eighth),
        ])
    }

    @Test func `a cross-barline write lands the selection on the chain head and the caret past its tail`() throws {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoMeasuresOfQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 4))) // measure 0's LAST quarter slot
        vm.setDuration(.half)
        vm.inputPitch(letter: "c")
        // One quarter of room left in the bar: the half is spelled quarter + quarter tied across the barline —
        // by ssm, from this one scalar intent.
        #expect(vm.appliedIntents == [
            .inputNote(at: EditorFixtures.restID(element: 4), pitch: 60, tpc: 14, duration: .half),
        ])
        let head = try #require(vm.score?[EditorFixtures.noteID(element: 4)])
        #expect(head.tieForward == 1)
        let tail = try #require(vm.score?[EditorFixtures.noteID(measure: 1, element: 0)])
        #expect(tail.tieBack == 1)
        // Compensation 1: selection on the chain's head, caret past its TAIL — the session reports only the head.
        #expect(vm.selectedItem == .note(EditorFixtures.noteID(element: 4)))
        #expect(vm.caretItem == .rest(EditorFixtures.restID(measure: 1, element: 1)))
    }

    @Test func `letter input over a note records writeNote and still advances the caret`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1))) // arms .quarter — the chord's own length
        vm.inputPitch(letter: "d")
        #expect(vm.appliedIntents == [
            .writeNote(
                at: VoiceElementID(EditorFixtures.noteID(element: 1)), pitch: 62, tpc: 16, duration: nil,
            ),
        ])
        #expect(vm.score?[EditorFixtures.noteID(element: 1)]?.pitch == 62)
        #expect(vm.caretItem == .rest(EditorFixtures.restID(element: 2)))
    }

    /// The one real behavioral fork the spec flags, ruled in Task 3: `.writeNote` re-pitches notehead 0, but a
    /// caret naming a chord's UPPER notehead — the ＋音-then-fix flow — means THAT notehead, so the host builds a
    /// `.setNotePitch` for it instead.
    @Test func `letter input with the caret on a chord's upper notehead re-pitches that notehead, not the root`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoNoteChordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1, noteIndex: 1))) // the E4 above the C4 root
        vm.inputPitch(letter: "d")
        #expect(vm.appliedIntents == [
            .setNotePitch(
                at: EditorFixtures.noteID(element: 1, noteIndex: 1), pitch: 62, tpc: 16, accidental: nil,
            ),
        ])
        #expect(vm.score?[EditorFixtures.noteID(element: 1, noteIndex: 0)]?.pitch == 60) // the root stays
        #expect(vm.score?[EditorFixtures.noteID(element: 1, noteIndex: 1)]?.pitch == 62) // the E became D
    }

    // MARK: - Delete and the rest key

    @Test func `deleting the bar's only note records a plain delete and lands on the collapsed measure rest`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))
        vm.deleteSelection()
        #expect(vm.appliedIntents == [.delete(at: VoiceElementID(EditorFixtures.noteID(element: 1)))])
        // ssm collapsed the emptied bar to ONE measure rest and reported it as the affected location.
        #expect(vm.selectedItem == .rest(EditorFixtures.restID(element: 1)))
    }

    @Test func `deleting one note of a chord records removeNoteFromChord`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoNoteChordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1, noteIndex: 1)))
        vm.deleteSelection()
        #expect(vm.appliedIntents == [
            .removeNoteFromChord(at: EditorFixtures.noteID(element: 1, noteIndex: 1)),
        ])
    }

    @Test func `the rest key over a note with a different armed length records writeRest`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))
        vm.setDuration(.half)
        vm.writeRest()
        #expect(vm.appliedIntents == [
            .writeRest(at: VoiceElementID(EditorFixtures.noteID(element: 1)), duration: .half),
        ])
    }

    @Test func `the rest key with the note's own length armed falls back to delete`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1))) // arms .quarter, the note's own length
        vm.writeRest()
        #expect(vm.appliedIntents == [.delete(at: VoiceElementID(EditorFixtures.noteID(element: 1)))])
    }

    // MARK: - The callout's length keys

    @Test func `the callout's length key on a note records setChordDuration`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))
        vm.setSelectionDuration(.half)
        #expect(vm.appliedIntents == [
            .setChordDuration(at: VoiceElementID(EditorFixtures.noteID(element: 1)), duration: .half),
        ])
    }

    @Test func `the callout's length key on a rest records the raw length and ssm promotes the bar-filler`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))
        vm.setSelectionDuration(.whole)
        // The intent carries what the key said; the `.measure` spelling is ssm's promotion, applied engine-side.
        #expect(vm.appliedIntents == [
            .setRestDuration(at: VoiceElementID(EditorFixtures.restID(element: 1)), duration: .whole),
        ])
        guard case let .chord(rest)? = vm.score?[VoiceElementID(EditorFixtures.restID(element: 1))] else {
            Issue.record("expected a rest at element 1")
            return
        }
        #expect(rest.duration == .measure)
    }

    // MARK: - Ties

    @Test func `the tie toggle records setTie in both directions`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.twoConsecutiveC4Chords())
        vm.select(.note(EditorFixtures.noteID(element: 1)))
        vm.toggleTie()
        vm.toggleTie()
        #expect(vm.appliedIntents == [
            .setTie(
                from: EditorFixtures.noteID(element: 1), to: EditorFixtures.noteID(element: 2),
                sourceTieForward: 1, targetTieBack: 1,
            ),
            .setTie(
                from: EditorFixtures.noteID(element: 1), to: EditorFixtures.noteID(element: 2),
                sourceTieForward: nil, targetTieBack: nil,
            ),
        ])
    }

    @Test func `appendTiedNote records the inputNote + setTie composite and keeps the source selected`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1))) // arms .quarter — the next slot's own length too
        vm.appendTiedNote()
        #expect(vm.appliedIntents == [
            .composite([
                .inputNote(at: EditorFixtures.restID(element: 2), pitch: 60, tpc: 14, duration: nil),
                .setTie(
                    from: EditorFixtures.noteID(element: 1), to: EditorFixtures.noteID(element: 2),
                    sourceTieForward: 1, targetTieBack: 1,
                ),
            ]),
        ])
        // Compensation 2: ssm's composite reports its first member's location (the appended note); the selection
        // belongs on the SOURCE, re-landed explicitly.
        #expect(vm.selectedItem == .note(EditorFixtures.noteID(element: 1)))
    }

    @Test func `appendTiedNote across the barline ties onto the chain's head at the written slot`() throws {
        var score = EditorFixtures.twoMeasuresOfQuarterRests()
        score[VoiceElementID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 3)] =
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        let vm = makeViewModel()
        vm.beginSession(score: score)
        vm.select(.note(EditorFixtures.noteID(element: 3)))
        vm.setDuration(.half)
        vm.appendTiedNote()
        // One quarter of room after the source: the appended half is spelled quarter + quarter across the barline
        // by ssm, and the tie from the source lands on the chain's head — the very slot being written.
        #expect(vm.appliedIntents == [
            .composite([
                .inputNote(at: EditorFixtures.restID(element: 4), pitch: 60, tpc: 14, duration: .half),
                .setTie(
                    from: EditorFixtures.noteID(element: 3), to: EditorFixtures.noteID(element: 4),
                    sourceTieForward: 1, targetTieBack: 1,
                ),
            ]),
        ])
        let head = try #require(vm.score?[EditorFixtures.noteID(element: 4)])
        #expect(head.tieBack == 1) // tied from the source note
        #expect(head.tieForward == 1) // and onward into its own chain
        let chainTail = try #require(vm.score?[EditorFixtures.noteID(measure: 1, element: 0)])
        #expect(chainTail.tieBack == 1)
        #expect(vm.selectedItem == .note(EditorFixtures.noteID(element: 3)))
    }

    // MARK: - Pitch and accidentals

    @Test func `the chevrons record one setNotePitch and ssm walks the tie chain`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.tiedC4Chain(length: 3))
        vm.select(.note(EditorFixtures.noteID(element: 2))) // the chain's MIDDLE member
        vm.shiftPitch(bySemitones: 1)
        #expect(vm.appliedIntents == [
            .setNotePitch(
                at: EditorFixtures.noteID(element: 2),
                pitch: 61,
                tpc: PitchSpelling.shiftedTpc(from: 60, priorTpc: 14, to: 61, in: 0),
                accidental: .sharp,
            ),
        ])
        // The chain moved whole — that walk is ssm's now, from this one scalar intent.
        #expect(vm.score?[EditorFixtures.noteID(element: 1)]?.pitch == 61)
        #expect(vm.score?[EditorFixtures.noteID(element: 3)]?.pitch == 61)
        #expect(vm.score?[EditorFixtures.noteID(element: 4)]?.pitch == 60) // the untied neighbour stays
    }

    @Test func `the accidental key records setAccidental`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))
        vm.setAccidental(.sharp)
        #expect(vm.appliedIntents == [
            .setAccidental(at: EditorFixtures.noteID(element: 1), accidental: .sharp),
        ])
    }

    @Test func `the armed chord key records addNoteToChord`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.chordAtIndex1())
        vm.select(.note(EditorFixtures.noteID(element: 1)))
        vm.toggleAddToChord()
        vm.inputPitch(letter: "e")
        #expect(vm.appliedIntents == [
            .addNoteToChord(
                at: VoiceElementID(EditorFixtures.noteID(element: 1)), pitch: 64, tpc: 18, accidental: nil,
            ),
        ])
    }

    // MARK: - Tuplets

    @Test func `the tuplet key records createTuplet and removeTuplet at the caret's slot`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.select(.rest(EditorFixtures.restID(element: 1)))
        vm.createTuplet(actualNotes: 3)
        vm.removeTuplet()
        let slot = VoiceElementID(EditorFixtures.restID(element: 1))
        #expect(vm.appliedIntents == [
            .createTuplet(at: slot, actualNotes: 3, normalNotes: 2),
            .removeTuplet(at: slot),
        ])
    }
}
```

- [ ] **Step 2: Run the new suite**

```sh
env -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo/Packages/Features/Editor \
  xcodebuild test -scheme Editor \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation -only-testing:EditorTests/EditorIntentConstructionTests
```

Expected: **PASS — 18 tests.** (These verify landed behavior; a failure means a Task 1–3 call site diverged — fix the call site. Two assertions rest on planner facts worth knowing if one surprises you: `removeTuplet`'s slot comes from the caret's re-derived position after `createTuplet`, and the collapsed-measure-rest landing comes from ssm threading `restElementIndex` into the composite's location.)

- [ ] **Step 3: Run the full Editor suite**

Same command without `-only-testing`. Expected: **PASS — 173 tests** (155 baseline + 18).

- [ ] **Step 4: Commit**

```sh
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo add Packages/Features/Editor
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo commit -m "test(editor): pin the intent each op constructs"
```

---

## Task 6: `ScoreEditHistoryStore` — Domain protocol, App concrete, unit tests

**Files:**
- Create: `Packages/Domain/Sources/Domain/Protocols/ScoreEditHistoryStore.swift`
- Create: `App/ProcessScoreEditHistoryStore.swift`
- Create: `Tests/FolinoTests/ProcessScoreEditHistoryStoreTests.swift`

**Interfaces:**
- Consumes: `ScoreEditSession` (via Domain's `@_exported import SheetMusicCore`), `ScoreItemID` (Domain, `Hashable`), `UIApplication.didReceiveMemoryWarningNotification`.
- Produces — consumed by Tasks 7–8 exactly as written:

```swift
@MainActor
public protocol ScoreEditHistoryStore: AnyObject {
    func session(for id: ScoreItemID, contentHash: String) -> ScoreEditSession?
    func retain(_ session: ScoreEditSession, for id: ScoreItemID, contentHash: String)
    func invalidate(_ id: ScoreItemID)
}
```

and `ProcessScoreEditHistoryStore` (App-internal, `init(capacity: Int = 3, notificationCenter: NotificationCenter = .default)`).

- [ ] **Step 1: Write the Domain protocol**

Create `Packages/Domain/Sources/Domain/Protocols/ScoreEditHistoryStore.swift` (the shape is the spec's, verbatim; the doc comments carry the two non-obvious contracts — checkout and the hash guard):

```swift
import Foundation

/// Retains edit sessions across Editor entries, for the process lifetime. Memory-only by design: killing the app
/// drops every history, and so does memory pressure — there is no disk, no version history, no sync.
///
/// `@MainActor` with synchronous methods, not `Sendable`-async like `ScoreOriginalStore`: `ScoreEditSession` is
/// deliberately not `Sendable` ("hold one per isolation domain"), so the store must live on the actor that drives
/// sessions — the main actor, where `EditorViewModel` already is.
///
/// `session(for:contentHash:)` CHECKS THE ENTRY OUT — the returned session has one owner (the view model) until
/// `retain` deposits it again. That keeps LRU accounting trivial and makes an iPad split-view double-open of one
/// score safe: the second session finds nothing and starts fresh.
@MainActor
public protocol ScoreEditHistoryStore: AnyObject {
    /// Removes and returns the retained session for `id` — or nil (and drops any stale entry) when none is
    /// retained or `contentHash` differs from what it was deposited with.
    func session(for id: ScoreItemID, contentHash: String) -> ScoreEditSession?
    /// Deposits `session` as the most-recent entry, evicting least-recently-used entries over the cap.
    func retain(_ session: ScoreEditSession, for id: ScoreItemID, contentHash: String)
    /// Drops any retained session for `id`.
    func invalidate(_ id: ScoreItemID)
}
```

- [ ] **Step 2: Write the failing store tests**

Create `Tests/FolinoTests/ProcessScoreEditHistoryStoreTests.swift`:

```swift
import Domain
import Foundation
import Testing
import UIKit
@testable import folino

/// The process-lifetime session store: an LRU of three deposited sessions, checkout-on-read, hash-guarded, and
/// swept empty on a memory warning. Sessions are compared by identity — the store retains and returns the same
/// object, never a copy.
@MainActor
struct ProcessScoreEditHistoryStoreTests {
    private func makeSession() -> ScoreEditSession {
        ScoreEditSession(score: Score(division: 480, parts: []))
    }

    @Test func `a deposited session is checked out exactly once`() {
        let store = ProcessScoreEditHistoryStore()
        let id = ScoreItemID()
        let session = makeSession()
        store.retain(session, for: id, contentHash: "h")
        #expect(store.session(for: id, contentHash: "h") === session)
        // Checked out: a second concurrent asker (iPad split-view double-open) finds nothing.
        #expect(store.session(for: id, contentHash: "h") == nil)
    }

    @Test func `a contentHash mismatch drops the stale entry and returns nil`() {
        let store = ProcessScoreEditHistoryStore()
        let id = ScoreItemID()
        store.retain(makeSession(), for: id, contentHash: "deposited")
        #expect(store.session(for: id, contentHash: "different") == nil)
        // The stale entry is gone, not waiting to mislead a later asker with the old hash.
        #expect(store.session(for: id, contentHash: "deposited") == nil)
    }

    @Test func `a fourth deposit evicts the least-recently-used entry`() {
        let store = ProcessScoreEditHistoryStore()
        let ids = (0 ..< 4).map { _ in ScoreItemID() }
        let sessions = (0 ..< 4).map { _ in makeSession() }
        for index in 0 ..< 4 {
            store.retain(sessions[index], for: ids[index], contentHash: "h")
        }
        #expect(store.session(for: ids[0], contentHash: "h") == nil) // evicted
        #expect(store.session(for: ids[1], contentHash: "h") === sessions[1])
        #expect(store.session(for: ids[2], contentHash: "h") === sessions[2])
        #expect(store.session(for: ids[3], contentHash: "h") === sessions[3])
    }

    @Test func `re-depositing a score refreshes its recency and replaces its entry`() {
        let store = ProcessScoreEditHistoryStore()
        let ids = (0 ..< 4).map { _ in ScoreItemID() }
        let first = makeSession()
        let replacement = makeSession()
        store.retain(first, for: ids[0], contentHash: "h")
        store.retain(makeSession(), for: ids[1], contentHash: "h")
        store.retain(makeSession(), for: ids[2], contentHash: "h")
        // Re-deposit id 0: it becomes most-recent and holds ONE slot, not two.
        store.retain(replacement, for: ids[0], contentHash: "h2")
        store.retain(makeSession(), for: ids[3], contentHash: "h")
        // ids[1] was the least-recent at the fourth deposit — it went, id 0 stayed, under its new hash.
        #expect(store.session(for: ids[1], contentHash: "h") == nil)
        #expect(store.session(for: ids[0], contentHash: "h2") === replacement)
    }

    @Test func `invalidate empties the entry`() {
        let store = ProcessScoreEditHistoryStore()
        let id = ScoreItemID()
        store.retain(makeSession(), for: id, contentHash: "h")
        store.invalidate(id)
        #expect(store.session(for: id, contentHash: "h") == nil)
    }

    @Test func `a memory warning empties the store`() {
        let center = NotificationCenter()
        let store = ProcessScoreEditHistoryStore(notificationCenter: center)
        let id = ScoreItemID()
        store.retain(makeSession(), for: id, contentHash: "h")
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #expect(store.session(for: id, contentHash: "h") == nil)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

The new files are not in the generated project yet — regenerate first:

```sh
env -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo xcodegen generate
```

```sh
xcodebuild -project /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo/Folino.xcodeproj \
  -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation test -only-testing:FolinoTests/ProcessScoreEditHistoryStoreTests
```

Expected: **FAIL to compile** — `cannot find 'ProcessScoreEditHistoryStore' in scope`.

- [ ] **Step 4: Write the concrete**

Create `App/ProcessScoreEditHistoryStore.swift`:

```swift
import Domain
import Foundation
import UIKit

/// Retains each score's `ScoreEditSession` across Editor entries, for the process lifetime — the undo history a
/// session carries survives ✓-and-reopen. Memory-only by design; killing the app drops every history.
///
/// LRU-bounded at three deposited sessions because a retained session holds a full in-memory `Score` copy — the
/// spec budgets ~7 MB for the worst score we ship, so three slots is ≈ 21 MB worst case and typically well under
/// 1.5 MB. The open session is checked out (see the protocol) and never counts against the cap.
///
/// An `NSObject` subclass only for the selector-based notification observation below, which keeps the memory-
/// warning sweep synchronous and testable (posting on an injected center runs the handler inline).
@MainActor
final class ProcessScoreEditHistoryStore: NSObject, ScoreEditHistoryStore {
    private struct Entry {
        let id: ScoreItemID
        let contentHash: String
        let session: ScoreEditSession
    }

    /// Most-recently deposited last.
    private var entries: [Entry] = []
    private let capacity: Int

    init(capacity: Int = 3, notificationCenter: NotificationCenter = .default) {
        self.capacity = capacity
        super.init()
        // Memory pressure empties the store: the deposited sessions are a convenience cache, and "bounded until
        // jetsam disagrees" is not bounded. Same contract as a kill; the checked-out session is unaffected — the
        // store does not own it.
        notificationCenter.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
        )
    }

    func session(for id: ScoreItemID, contentHash: String) -> ScoreEditSession? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = entries.remove(at: index)
        // A hash mismatch means the file was rewritten out-of-band since the deposit (revert, re-import, version
        // restore, PDF re-read): the history no longer relates to the bytes on disk, so the stale entry is dropped
        // rather than left to mislead a later asker.
        guard entry.contentHash == contentHash else { return nil }
        return entry.session
    }

    func retain(_ session: ScoreEditSession, for id: ScoreItemID, contentHash: String) {
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, contentHash: contentHash, session: session))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func invalidate(_ id: ScoreItemID) {
        entries.removeAll { $0.id == id }
    }

    /// UIKit posts this on the main thread, so the `@MainActor` isolation holds dynamically.
    @objc private func handleMemoryWarning() {
        entries.removeAll()
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Same command as Step 3 (no regeneration needed this time — both files were added before the last `xcodegen generate`; if the concrete was created after it, regenerate again). Expected: **PASS — 6 tests.**

- [ ] **Step 6: Commit**

```sh
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo add Packages/Domain App/ProcessScoreEditHistoryStore.swift Tests/FolinoTests/ProcessScoreEditHistoryStoreTests.swift
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo commit -m "feat(app): process-lifetime ScoreEditHistoryStore with an LRU of three"
```

---

## Task 7: Session adoption and deposit

**Files:**
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift` (`init`, stored `historyStore`, `beginSession`, `endSession`, new `depositSessionIfWorthKeeping`)
- Create: `Packages/Features/Editor/Sources/Editor/NoopScoreEditHistoryStore.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/Views/EditorPadView.swift` (`PreviewEditorFactory.makeViewModel`, ~line 206)
- Modify: `Packages/Features/Editor/Tests/EditorTests/Support/Fakes.swift` (add `FakeScoreEditHistoryStore`; add `saveError` to `FakeScoreFileGateway`)
- Modify (constructor argument only): all 13 Editor test files listed in File Structure, plus `EditorIntentConstructionTests.swift` from Task 5
- Create: `Packages/Features/Editor/Tests/EditorTests/EditorCrossSessionUndoTests.swift`
- Modify: `App/AppBootstrap.swift` (~line 50, beside `pdfPlaybackParser`)
- Modify: `App/AppShellView.swift` (`ReadyShell` properties + init + call site; `makeReader`)
- Modify: `App/EditableReaderScreen.swift` (init parameter → `EditorViewModel`)
- Modify: `FolinoScreenshot/Scenes/NoteEditingScene.swift` (~line 105)

**Interfaces:**
- Consumes: `ScoreEditHistoryStore` + `ProcessScoreEditHistoryStore` (Task 6), `session: ScoreEditSession?` (Task 4), `ScoreItem.contentHash` (refreshed by `performSave()` to the on-disk digest, and by `refreshRow(_:)` across out-of-band writes — `EditableReaderScreen.wireOnce()` already re-seeds the row *before* `beginSession`, which is what makes the hash current at adoption time).
- Produces: `EditorViewModel.init(scoreItem:scoresDirectory:gateway:repository:originalStore:historyStore:playback:)` — the new `historyStore: any ScoreEditHistoryStore` parameter sits between `originalStore` and `playback` at every construction site; `FakeScoreEditHistoryStore` with `retained: [(id: ScoreItemID, contentHash: String, session: ScoreEditSession)]`, `sessionRequests: [(id: ScoreItemID, contentHash: String)]`, `invalidatedIDs: [ScoreItemID]` (Task 8's tests read all three); `FakeScoreFileGateway.saveError: Error?`.

- [ ] **Step 1: Write the fakes and the failing tests**

In `Support/Fakes.swift`, add to `FakeScoreFileGateway`:

```swift
    /// When set, `saveScore` throws this instead of writing — exercises the Editor's failed-final-save path.
    var saveError: Error?
```

and at the top of its `saveScore`:

```swift
    func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) throws {
        if let saveError { throw saveError }
        eventLog?.record("save")
        savedCalls.append((score, fileURL, format))
        // Write real bytes so callers that hash the saved file (Task 10's EditorFileFacts) see deterministic content.
        try Data("saved".utf8).write(to: fileURL)
    }
```

Then add the fake store at the end of the file:

```swift
/// In-memory `ScoreEditHistoryStore` with the concrete store's checkout-and-hash-guard semantics, recording every
/// call so tests can assert what the view model asked for. No LRU — the concrete owns that, in its own suite.
@MainActor
final class FakeScoreEditHistoryStore: ScoreEditHistoryStore {
    private(set) var retained: [(id: ScoreItemID, contentHash: String, session: ScoreEditSession)] = []
    private(set) var sessionRequests: [(id: ScoreItemID, contentHash: String)] = []
    private(set) var invalidatedIDs: [ScoreItemID] = []

    func session(for id: ScoreItemID, contentHash: String) -> ScoreEditSession? {
        sessionRequests.append((id, contentHash))
        guard let index = retained.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = retained.remove(at: index)
        guard entry.contentHash == contentHash else { return nil }
        return entry.session
    }

    func retain(_ session: ScoreEditSession, for id: ScoreItemID, contentHash: String) {
        retained.removeAll { $0.id == id }
        retained.append((id, contentHash, session))
    }

    func invalidate(_ id: ScoreItemID) {
        invalidatedIDs.append(id)
        retained.removeAll { $0.id == id }
    }
}
```

Create `EditorCrossSessionUndoTests.swift`:

```swift
import Domain
@testable import Editor
import Foundation
import SheetMusicUI
import Testing

/// The history's life across sessions: deposited at session end, adopted back at the next `beginSession` on the
/// same bytes, and never deposited dirty, empty, or under different bytes. The store here is the recording fake —
/// the concrete LRU lives in the App target with its own suite.
@MainActor
@Suite("EditorViewModel cross-session history")
struct EditorCrossSessionUndoTests {
    private func makeTempScoresDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "editor-history-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeViewModel(
        store: FakeScoreEditHistoryStore,
        gateway: FakeScoreFileGateway = FakeScoreFileGateway(),
        directory: URL,
    ) -> EditorViewModel {
        EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: directory,
            gateway: gateway,
            repository: FakeScoreLibraryRepository(),
            originalStore: FakeScoreOriginalStore(),
            historyStore: store,
            playback: nil,
        )
    }

    @Test func `endSession deposits a session with history and the next beginSession adopts it`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let vm = makeViewModel(store: store, directory: dir)
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))
        let editedScore = try #require(vm.score)
        await vm.endSession()

        #expect(store.retained.count == 1)
        #expect(store.retained.first?.id == vm.scoreItemID)
        // The deposit is keyed by the row's POST-flush contentHash — the digest of exactly the bytes the
        // session's score was saved as.
        #expect(store.retained.first?.contentHash == vm.scoreItem.contentHash)
        #expect(!vm.isSessionActive)

        vm.beginSession(score: editedScore)
        #expect(vm.canUndo) // the history crossed the session boundary
        vm.undo()
        #expect(vm.score == EditorFixtures.fourQuarterRests()) // the PREVIOUS session's edit, undone
    }

    @Test func `an untouched session is not deposited`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let vm = makeViewModel(store: store, directory: dir)
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        await vm.endSession()
        #expect(store.retained.isEmpty)
    }

    @Test func `a failed final save discards the session instead of depositing it`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let gateway = FakeScoreFileGateway()
        gateway.saveError = DomainError.persistenceFailed(reason: "test")
        let vm = makeViewModel(store: store, gateway: gateway, directory: dir)
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))
        await vm.endSession()
        // The flush left `isDirty == true`: depositing would retain a history whose bytes never reached the disk.
        // Discarding is exactly today's failed-final-save contract.
        #expect(store.retained.isEmpty)
    }

    @Test func `a deposit under different bytes is not adopted, and the stale entry is dropped`() {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let vm = makeViewModel(store: store, directory: dir)
        // A previous run deposited under bytes this row no longer has (reverted / re-imported / restored since).
        store.retain(
            ScoreEditSession(score: EditorFixtures.chordAtIndex1()),
            for: vm.scoreItemID,
            contentHash: "not-the-row's-digest",
        )
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        #expect(!vm.canUndo) // fresh session, no history
        #expect(store.retained.isEmpty) // the checkout's hash guard dropped the stale entry
        // And the view model asked with the ROW's hash — the guard the whole keying scheme rests on.
        #expect(store.sessionRequests.first?.contentHash == vm.scoreItem.contentHash)
    }
}
```

- [ ] **Step 2: Run the new suite to verify it fails**

```sh
env -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo/Packages/Features/Editor \
  xcodebuild test -scheme Editor \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation -only-testing:EditorTests/EditorCrossSessionUndoTests
```

Expected: **FAIL to compile** — `extra argument 'historyStore' in call` (the init doesn't take it yet).

- [ ] **Step 3: Add the dependency and the adopt/deposit logic**

`EditorViewModel.swift` — stored property beside `originalStore`, init parameter between `originalStore` and `playback`:

```swift
    @ObservationIgnored let historyStore: any ScoreEditHistoryStore
```

```swift
    public init(
        scoreItem: ScoreItem,
        scoresDirectory: URL,
        gateway: any ScoreFileGateway,
        repository: any ScoreLibraryRepository,
        originalStore: any ScoreOriginalStore,
        historyStore: any ScoreEditHistoryStore,
        playback: (any PlaybackController)?,
    ) {
        self.scoreItem = scoreItem
        self.scoresDirectory = scoresDirectory
        self.gateway = gateway
        self.repository = repository
        self.originalStore = originalStore
        self.historyStore = historyStore
        self.playback = playback
        hasCapturedOriginal = scoreItem.canRevertToOriginal
    }
```

`beginSession` — first line becomes the adoption ask (everything else it resets stays reset):

```swift
    public func beginSession(score: Score) {
        // A retained session is adopted as-is: the hash matched the very bytes `score` was parsed from, so its
        // `score` is value-equal to what the Reader just loaded. A miss — nothing retained, or the file rewritten
        // out-of-band since the deposit (revert, re-import, version restore, PDF re-read) — starts fresh.
        // `scoreItem.contentHash` is current here because the host re-seeds the row (`refreshRow`) before every
        // `beginSession` (`EditableReaderScreen.wireOnce()`).
        session = historyStore.session(for: scoreItem.id, contentHash: scoreItem.contentHash)
            ?? ScoreEditSession(score: score)
```

`endSession` and the deposit rule:

```swift
    /// Flushes any pending autosave, deposits the session for the next entry on this score, and drops it.
    public func endSession() async {
        await flushPendingSave()
        depositSessionIfWorthKeeping()
        session = nil
    }

    /// Deposits the session — only when the flush left nothing unsaved (a failed final save discards the session,
    /// exactly today's failure contract: a retained history must describe bytes that are actually on disk) and the
    /// session has any history at all (an untouched session has nothing worth a slot). `scoreItem.contentHash` is
    /// the digest of exactly the bytes `session.score` was last saved as, because `flushPendingSave()` ran first.
    private func depositSessionIfWorthKeeping() {
        guard let session, !isDirty, session.canUndo || session.canRedo else { return }
        historyStore.retain(session, for: scoreItem.id, contentHash: scoreItem.contentHash)
    }
```

- [ ] **Step 4: Update every construction site**

Mechanical: insert the `historyStore:` argument between `originalStore:` and `playback:` / `playbackController:`.

- `Packages/Features/Editor/Sources/Editor/NoopScoreEditHistoryStore.swift` (create; beside `NoopScoreOriginalStore.swift`):

```swift
import Domain
import Foundation

/// Does nothing, for previews. A preview session never outlives its view, so it has no history to keep.
@MainActor
final class NoopScoreEditHistoryStore: ScoreEditHistoryStore {
    func session(for _: ScoreItemID, contentHash _: String) -> ScoreEditSession? {
        nil
    }

    func retain(_: ScoreEditSession, for _: ScoreItemID, contentHash _: String) {}

    func invalidate(_: ScoreItemID) {}
}
```

- `EditorPadView.swift`, `PreviewEditorFactory.makeViewModel`: add `historyStore: NoopScoreEditHistoryStore(),`.
- The 13 Editor test files + `EditorIntentConstructionTests.swift`: add `historyStore: NoopScoreEditHistoryStore(),` to each `EditorViewModel(` construction (the new `EditorCrossSessionUndoTests` alone passes its `FakeScoreEditHistoryStore`).
- `App/AppBootstrap.swift`, beside `pdfPlaybackParser` (~line 50):

```swift
    /// Process-lifetime store retaining each score's `ScoreEditSession` across Editor entries (cross-session
    /// undo). A plain constant, like `pdfPlaybackParser`: no async setup, no failure mode, and it must exist
    /// before the first Reader screen is built.
    let editHistoryStore = ProcessScoreEditHistoryStore()
```

- `App/AppShellView.swift`: `ReadyShell` gains `let editHistoryStore: any ScoreEditHistoryStore` and the matching init parameter (thread it exactly as `originalStore` is threaded); the `ReadyShell(...)` call site in `AppShellView.body` passes `editHistoryStore: bootstrap.editHistoryStore,`; `makeReader` passes `historyStore: editHistoryStore,` into `EditableReaderScreen`.
- `App/EditableReaderScreen.swift`: init gains `historyStore: any ScoreEditHistoryStore,` after `originalStore:`, passed straight into the `EditorViewModel(` construction as `historyStore: historyStore,`.
- `FolinoScreenshot/Scenes/NoteEditingScene.swift` (~line 105): add `historyStore: ProcessScoreEditHistoryStore(),` after `originalStore: FixtureOriginalStore(),` (a fresh store per scene — the screenshot host never reopens a session, so Noop-like behavior with the real type, which this target compiles from App sources).

- [ ] **Step 5: Run everything**

Full Editor suite (same command as always). Expected: **PASS — 177 tests** (173 + the 4 new). Then both app targets:

```sh
xcodebuild -project /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo/Folino.xcodeproj \
  -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

```sh
xcodebuild -project /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo/Folino.xcodeproj \
  -scheme FolinoScreenshot -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

Expected: BUILD SUCCEEDED twice. (`FolinoScreenshot` compiles the same App sources against the Feature packages — it is the one place a missed construction site shows up.)

- [ ] **Step 6: Commit**

```sh
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo add Packages/Features/Editor App FolinoScreenshot
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo commit -m "feat(editor): adopt and deposit edit sessions across Editor entries"
```

---

## Task 8: Signed depth, count-driven unwind, ✕ and revert end retained history

**Files:**
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift` (`sessionEditDepth` docs, `sessionHasEdits`, `undo()`, `unwindSessionEdits()`, `didDiscardSession`, `beginSession`, `depositSessionIfWorthKeeping`)
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Discard.swift:65-90`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Revert.swift` (after the store swap succeeds)
- Modify: `Packages/Features/Editor/Sources/Editor/Screens/EditorChromeView.swift` (initial trampoline)
- Modify: `Packages/Features/Editor/Tests/EditorTests/EditorCrossSessionUndoTests.swift` (new tests)

**Interfaces:**
- Consumes: everything Task 7 produced; `FakeScoreEditHistoryStore.invalidatedIDs`; `FakeScoreOriginalStore` (for the revert test, as `EditorViewModelRevertTests` uses it).
- Produces: **signed `sessionEditDepth` semantics** — the signed net offset from session start: `+1` on apply and redo, `-1` on undo (no clamp), reset by `beginSession`; `sessionHasEdits == (sessionEditDepth != 0)`; `didDiscardSession: Bool` (internal, `@ObservationIgnored`) — set by `discardSessionEdits()`, read by the deposit guard, reset by `beginSession`.

- [ ] **Step 1: Write the failing tests**

Append to `EditorCrossSessionUndoTests.swift`:

```swift
    // MARK: - Signed depth and the count-driven unwind (Task 8)

    /// Seeds one committed session so the next `beginSession` adopts real history, and returns the session-open
    /// score of the SECOND session (= the first session's edited result).
    private func seedOneCommittedEdit(into vm: EditorViewModel) async throws -> Score {
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))
        let edited = try #require(vm.score)
        await vm.endSession()
        return edited
    }

    @Test func `undo below the session start drives the depth negative and counts as edits to discard`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let vm = makeViewModel(store: store, directory: dir)
        let edited = try await seedOneCommittedEdit(into: vm)

        vm.beginSession(score: edited)
        #expect(vm.sessionEditDepth == 0)
        #expect(vm.sessionHasEdits == false)

        vm.undo() // reaches BELOW this session's start, into the previous session's history

        #expect(vm.sessionEditDepth == -1)
        // A session that net-undid earlier work has changed the score: ✕ must ask before throwing that away, and
        // the session-end control must read "edited".
        #expect(vm.sessionHasEdits)
        #expect(vm.sessionEndMode == .commitEdited)
    }

    @Test func `discarding a net-negative session redoes back to the session-open score`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let vm = makeViewModel(store: store, directory: dir)
        let edited = try await seedOneCommittedEdit(into: vm)

        vm.beginSession(score: edited)
        vm.undo()
        #expect(vm.score == EditorFixtures.fourQuarterRests())

        await vm.discardSessionEdits()

        // The unwind went FORWARD (redo) to land on the session-open score — the previous session's edit intact.
        #expect(vm.score == edited)
        #expect(vm.sessionEditDepth == 0)
    }

    @Test func `discard unwinds only this session's edits and ends all retained history for the score`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        let vm = makeViewModel(store: store, directory: dir)
        let edited = try await seedOneCommittedEdit(into: vm)

        vm.beginSession(score: edited) // adopts — the store entry is checked out
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 2), pitch: 62, tpc: 16, duration: nil))

        await vm.discardSessionEdits()

        // Only THIS session's edit was unwound: the score is the session-open one, previous edit intact…
        #expect(vm.score == edited)
        // …and ✕ is final: the retained history is invalidated, and the exit's endSession must not deposit.
        #expect(store.invalidatedIDs == [vm.scoreItemID])
        await vm.endSession()
        #expect(store.retained.isEmpty)
        vm.beginSession(score: edited)
        #expect(!vm.canUndo) // the same contract as an app kill
    }

    @Test func `revertToOriginal invalidates the retained history`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FakeScoreEditHistoryStore()
        var item = EditorFixtures.sampleItem()
        item.originalFileName = "score.original.mscz"
        item.originalContentHash = "orig"
        item.originalProvenance = .importTime
        let vm = EditorViewModel(
            scoreItem: item,
            scoresDirectory: dir,
            gateway: FakeScoreFileGateway(),
            repository: FakeScoreLibraryRepository(),
            originalStore: FakeScoreOriginalStore(),
            historyStore: store,
            playback: nil,
        )
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))

        await vm.revertToOriginal()

        // The file no longer relates to any retained history — dropped eagerly, not left for the lazy hash miss.
        #expect(store.invalidatedIDs == [vm.scoreItemID])
        #expect(store.retained.isEmpty)
    }
```

- [ ] **Step 2: Run the suite to verify the new tests fail**

```sh
env -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo/Packages/Features/Editor \
  xcodebuild test -scheme Editor \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation -only-testing:EditorTests/EditorCrossSessionUndoTests
```

Expected: FAIL — `undo below the session start…` trips on `sessionEditDepth == -1` (the clamp holds it at 0); the discard tests fail on over-unwind / missing invalidation; the revert test fails on `invalidatedIDs` being empty.

- [ ] **Step 3: Implement the signed depth and count-driven unwind**

`EditorViewModel.swift`:

```swift
    /// The session's signed net offset from its starting score: incremented by `apply` and `redo()`, decremented
    /// by `undo()`, reset by `beginSession`. NEGATIVE when the session has undone below its own start — adopted
    /// history makes that reachable — which is still a change to the score this session made.
    ///
    /// Observed, and maintained here rather than read from the session, because the strip's session-end control
    /// switches on it: a mutation inside `ScoreEditSession` (a reference type from another module) notifies
    /// nothing, so a view bound to `canUndo` only refreshes when something else in the same body pass happens to
    /// change. This is what makes "the moment you change something, the control changes" true.
    public private(set) var sessionEditDepth = 0

    /// Whether this session has anything of its own to throw away — the difference between ✕ closing the session
    /// and ✕ asking first. Signed: a session that net-UNDID earlier sessions' work (negative depth) has changed
    /// the score too, and ✕ must offer to discard that as well.
    public var sessionHasEdits: Bool {
        sessionEditDepth != 0
    }
```

`undo()` — drop the clamp:

```swift
        guard let session, session.undo() else { return }
        sessionEditDepth -= 1
```

`unwindSessionEdits()`:

```swift
    /// Rewinds this session to the score it opened on, notifying the host a single time at the end.
    ///
    /// Count-driven, NOT `while canUndo`: with retained history the stack bottom no longer means "where this
    /// session started" — an adopted session can undo below its own start, and walking `canUndo` to exhaustion
    /// would silently discard PREVIOUS sessions' edits. `sessionEditDepth` is the signed net offset from session
    /// start, so undoing it (or redoing its negation) lands exactly on the session-open score from either
    /// direction. Store bookkeeping (invalidate, deposit suppression) lives in `discardSessionEdits()`, this
    /// method's only production caller; this owns the score alone.
    ///
    /// One notification rather than one per step: the host re-lays the score out on every `onScoreChanged`, so a
    /// long session would otherwise redraw the whole thing once per edit on the way back.
    func unwindSessionEdits() {
        guard let session else { return }
        while sessionEditDepth > 0, session.undo() {
            sessionEditDepth -= 1
        }
        while sessionEditDepth < 0, session.redo() {
            sessionEditDepth += 1
        }
        sessionEditDepth = 0
        generation += 1
        rederiveSelection()
        onScoreChanged(session.score)
    }
```

(`EditorSessionEndModeTests`' `undoing back to nothing hands the revert offer back` seeds `sessionEditDepth = 1` with no real edit via `previewSeedSessionEdit()`; the first loop's `session.undo()` returns `false` immediately and the trailing `sessionEditDepth = 0` keeps the test's contract — verified by the gate run below.)

The discard flag, beside the other `@ObservationIgnored` state:

```swift
    /// True once this session was ended by ✕ — `discardSessionEdits()` ran. Read by `endSession()`'s deposit guard,
    /// because the ✕ exit path still runs `endSession()` (`EditorDiscardButton` → `requestExit()` → `onEndEditing`):
    /// a discarded session's history — the redo of the discarded edits included — must not survive into the next
    /// session. Reset by `beginSession`.
    @ObservationIgnored var didDiscardSession = false
```

`beginSession` adds `didDiscardSession = false` to its resets. The deposit guard becomes:

```swift
    private func depositSessionIfWorthKeeping() {
        guard let session, !didDiscardSession, !isDirty, session.canUndo || session.canRedo else { return }
        historyStore.retain(session, for: scoreItem.id, contentHash: scoreItem.contentHash)
    }
```

- [ ] **Step 4: ✕ invalidates; revert invalidates**

`EditorViewModel+Discard.swift`, in `discardSessionEdits()` immediately after `unwindSessionEdits()`:

```swift
        unwindSessionEdits()

        // ✕ is final (controller ruling over the spec's redo-survives reading). The unwind above walked back via
        // undo, populating the session's redo stack — a deposited session would let the NEXT session redo exactly
        // what was just discarded, contradicting the "✕ discards the session" contract. So a ✕ ends ALL retained
        // history for this score: the deposit is suppressed and any retained entry dropped — the same contract as
        // an app kill. The file is correct either way; the flush below settles it.
        didDiscardSession = true
        historyStore.invalidate(scoreItem.id)
```

`EditorViewModel+Revert.swift`, immediately after the `reverted = try await originalStore.revertToOriginal(...)` success (before `scoreItem = reverted`):

```swift
        // The file no longer relates to any retained history for this score, and waiting for the lazy hash
        // mismatch would hold a dead multi-MB session in one of three slots. The live session is torn down below
        // without deposit, as today.
        historyStore.invalidate(scoreItem.id)
```

- [ ] **Step 5: Arm the system-undo bridge on adoption**

`EditorChromeView.swift`, on `chromeContent` beside the existing `.onChange(of: viewModel.appliedEditCount)`:

```swift
        // An adopted history is reachable from the strip's undo button the moment the session opens, but the
        // three-finger gesture goes through the system UndoManager, which only learns about edits when a
        // trampoline is registered — and that happens per NEWLY applied edit. Arm one initial trampoline when the
        // session already has history; `registerSystemUndo`'s symmetric re-registration handles everything after.
        .onAppear {
            if viewModel.canUndo {
                viewModel.registerSystemUndo(with: undoManager)
            }
        }
```

(No unit test reaches a SwiftUI environment `UndoManager`; Task 9's device checklist covers the gesture.)

- [ ] **Step 6: Run the full Editor suite**

Same command, full suite. Expected: **PASS — 181 tests** (177 + 4). `EditorSessionEndModeTests` and `EditorViewModelRevertTests` are the gates most likely to catch a slip here.

- [ ] **Step 7: Commit**

```sh
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo add Packages/Features/Editor
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo commit -m "feat(editor): signed session depth; discard and revert end retained history"
```

---

## Task 9: Full verification and spec reconciliation

**Files:**
- Modify: `docs/superpowers/specs/2026-08-19-cross-session-undo-design.md`

- [ ] **Step 1: Run every affected suite and build, in the foreground**

1. Full Editor suite (the usual command). Expected: **PASS — 181 tests.** Report the actual number.
2. App-level store suite:

```sh
xcodebuild -project /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo/Folino.xcodeproj \
  -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation test -only-testing:FolinoTests/ProcessScoreEditHistoryStoreTests
```

Expected: **PASS — 6 tests.**
3. `-scheme Folino … build` and `-scheme FolinoScreenshot … build` from the repo root (commands as in Task 7 Step 5). Expected: BUILD SUCCEEDED twice.

- [ ] **Step 2: Reconcile the spec**

The implementation deviates from the spec in three places; the spec must describe the code that exists (add to it, don't rewrite its history — a dated "Implementation notes" addendum section at the end is the right shape):

1. **"redo survives deposit, including after ✕" is no longer true.** Controller ruling: `discardSessionEdits()` invalidates the store entry and suppresses the deposit, so ✕ ends all retained history for the score — the same contract as an app kill; no ssm `discardRedoHistory()` was added.
2. **The caret-tail compensation is predicate-gated,** not unconditional: the chain walk runs only when the armed length did not fit the bar (decided pre-apply with `CrossBarInputPlanner.fitsInMeasure`), because an in-bar overwrite of an already-tied note must not walk that pre-existing chain.
3. **The `.writeNote` note-index fork was settled as a narrow host-side `.setNotePitch` branch** (the ＋音-then-fix flow makes the existing behavior matter), with a `PARITY(android)` marker; the barline case takes `.writeNote` for any index.

Also confirm the spec's "Step 1, mechanical" phase reads compatibly with the transitional-planner decomposition (a one-line note in the addendum suffices).

- [ ] **Step 3: Compile the device checklist into your report**

For a human on a physical device (no automated test reaches these):

1. **The headline flow:** open a score, edit a note, ✓ out, re-enter editing — the undo button is live and undoes the previous session's edit; redo brings it back; ✓ out and re-enter again — still there.
2. **✕ is final:** edit, ✕ (confirm the discard), re-enter — undo is dead; the discarded edit is gone from the score and cannot be redone.
3. **Undo below session start:** re-enter after a committed edit, undo past the session boundary, confirm the session-end control turns yellow (edited), then ✕ — the score returns to what it was when this session opened (the earlier edit back in place).
4. **Three-finger undo gesture** works immediately after re-entering a session with adopted history (before any new edit) — this is the Task 8 trampoline, unreachable by unit test.
5. **Revert to original** ends history: revert, re-enter — fresh session, no undo.
6. **A fourth score evicts the first:** edit-and-✓ four different scores, re-enter the first — no undo (LRU cap 3). Typical libraries make this quick with small scores.
7. **Memory warning** (simulator: Device ▸ Simulate Memory Warning): edit-and-✓ one score, trigger the warning, re-enter — no undo; an OPEN session survives the warning (its history intact while inside).
8. **iPad split-view double-open** of the same score: the second window's editor starts fresh; no crash, no shared stack.
9. **Editing feel unchanged:** a normal write/delete/tie/tuplet session behaves exactly as before Step 1 — this is a spot check on the whole migration.

- [ ] **Step 4: Commit**

```sh
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo add docs/superpowers/specs/2026-08-19-cross-session-undo-design.md
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/cross-session-undo commit -m "docs: reconcile the cross-session-undo spec with the implementation"
```

---

## Self-review notes

- **Spec coverage.** Step 1 scope + the 25-call-site table → Tasks 1–3 (Task 1: the 8 scalar sites + 4 test files; Task 2: `deleteElement`, `writeRest`, `applyToSelection`/`retimeCrossingBarline`, `inputPitch(onRest:)` + caret-tail compensation, deletion of `restDuration`; Task 3: `inputPitch(onNote:)` + `.writeNote` fork, `retune` chain, `appendTiedNote` composite + selection compensation, deletion of `writeCrossingBarline`). The deletions list → Tasks 2–4; `renotatingAccidentals` + `applyCommand` + pass condition (b) → Task 4 Step 6's grep. Pass condition (a) → every task's gate run against the measured 155 baseline. Step 1 risks: `.writeNote` index → Tasks 3/5; refusal shape → `apply(_:) -> Bool` (Task 1/4); composite `lastAffectedLocation` → Task 3's compensation, with `SelectionRederivationTests` in the gate. Step 2: protocol + placement → Task 6; keying/adopt/deposit (incl. failed-save and untouched-session rules, `refreshRow` currency) → Task 7; LRU cap 3 + checkout + memory sweep → Task 6; signed depth + count-driven unwind + revert invalidation + trampoline → Task 8; ✕ ruling → Task 8 (overriding the spec's redo-survives paragraph, reconciled in Task 9). Spec's test list → Tasks 5, 6, 7, 8. Implementation order → same sequence, with Step 1 split four ways (justified in the preamble).
- **Spec lines with no task, deliberately:** the memory-size estimation ("Bounding") is design rationale — the cap constant and the sweep are implemented, the arithmetic is not code; "Other file rewrites need no wiring" is a statement that no task is needed (the hash guard covers it, tested in Tasks 6/7); the rejected alternatives sections are narrative.
- **Placeholder scan:** no TBDs; every step carries the code or the exact command and expected result; the two "mechanical insert" steps (Task 7 Step 4) name the exact argument, position, and every file.
- **Type consistency:** `apply(_ intent: EditIntent) -> Bool` (Tasks 1, 4, and every call site); `appliedIntents` (Tasks 1, 5); `session: ScoreEditSession?` (Tasks 4, 7, 8); `chainTail(from:in:)` (Tasks 2, 3); `tieAppendIntent()` (Task 3); `ScoreEditHistoryStore.session(for:contentHash:)` / `retain(_:for:contentHash:)` / `invalidate(_:)` (Tasks 6, 7, 8 and both fakes); `historyStore` parameter position between `originalStore` and `playback` (Task 7, all sites); `didDiscardSession` (Task 8); `depositSessionIfWorthKeeping()` (Tasks 7, 8); `FakeScoreEditHistoryStore.retained` / `.sessionRequests` / `.invalidatedIDs` (Tasks 7, 8).
- **Deliberately not planned:** an Android-side implementation task (Android already drives `ScoreEditSession`; the one divergence gets a `PARITY(android)` marker in Task 3); any ssm change (ruling 3); persistence, version history, CloudKit (explicitly out of scope in the spec).

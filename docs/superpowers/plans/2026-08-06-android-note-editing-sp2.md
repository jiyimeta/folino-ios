# SP2 — Folino: extract `EditorCore` (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split Folino's `EditorViewModel` into a platform-neutral `EditorSessionCore` (Foundation + Domain only,
cross-compiles for Android) and a thin iOS `@Observable @MainActor` adapter, with every score mutation expressed as
a `SheetMusicCore.EditIntent` applied through `ScoreEditSession` — so SP3 can relay those intents to the mirror
session behind ssm's score handle without a second implementation of anything.

**Architecture:** Three moves in order. (1) Two gaps in ssm's intent vocabulary are closed first, while ssm 1.11.0 is
still untagged — `.setChordDuration` gains the cross-bar interception `.setRestDuration` already has, and a new
`.writeNote` intent covers the letter key landing on an occupied slot. (2) Folino's ops are converted, in place, from
building `EditCommand`s to naming `EditIntent`s, and the local copies of the seven planners are deleted because ssm
now owns them; the existing Editor suites gate every step. (3) Only once every op is intent-shaped and every
Apple-only dependency has a seam does the whole session move into a new `EditorCore` target, leaving `EditorViewModel`
as a mirror that re-syncs `@Observable` state after each call.

**Tech Stack:** Swift 6.3, SwiftPM, Swift Testing, swift-sheet-music 1.11.0 (`SheetMusicCore` / `SheetMusicLayout` /
`SheetMusicEditWire`), Domain (`@_exported import SheetMusicCore`).

## Global Constraints

- **iOS behavior must not change.** Every change here is a refactor whose observable output is identical. The
  `EditorTests` suites are the gate; a test that has to be *edited* to pass is a design failure, not a test failure —
  stop and report instead of rewriting the expectation. The only sanctioned edits are mechanical (a renamed symbol, a
  suite moving to a new test target).
- **ssm branch and worktree.** `swift-sheet-music` branch `android-note-editing`, worktree
  `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing`. It is
  at **1.11.0**, `origin/main` is merged in, and it is **unpushed and untagged** — which is the only reason Tasks 1–2
  are cheap. Always use `git -C <that path>`; never commit ssm work into the Folino tree.
- **Folino branch and worktree.** `worktree-android-note-editing`, worktree
  `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing`. Always use
  `git -C <that path>`.
- **The wire discriminator order is append-only.** `EditIntentWire`'s cases 0…11 keep their indices. `.writeNote`
  appends at **12**.
- **`EditorCore` is cross-compiled**, so it may import only `Foundation` and `Domain` (which re-exports
  `SheetMusicCore`). No `SwiftUI`, no `Observation`, no `CoreGraphics`, no `CryptoKit`, no `SheetMusicUI`, no
  `SheetMusicLayout`, no `@MainActor`, no SwiftLint build-tool plugin (it mirrors `ReaderAnnotationCore`, which the
  pre-commit hook lints on the host instead).
- **`EditorCore` holds `ScoreItemID`, not `ScoreSelection`.** Ruled 2026-08-11: keeping `ScoreSelection` out of the
  core is what keeps its dependency list at Domain alone. The iOS adapter derives `selection: ScoreSelection` from
  `selectedItem`.
- **Tests are Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`).
- **Comment paragraphs reflow at 120 columns.** American spelling except where an Apple/framework API name dictates
  otherwise (`cancelled`).
- **No partial staging** (`git add -p` is banned repo-wide — the pre-commit hook writes fixes back to disk and would
  mix them into the wrong commit). Stage whole files.
- **Access modifiers stay minimal.** `public` only where a module boundary genuinely needs it.

## Commands

| What | Command |
| --- | --- |
| ssm host tests | `xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter <SuiteName>` |
| ssm whole suite | same, without `--filter` |
| Folino Editor tests | from `Packages/Features/Editor/`: `xcodebuild test -scheme <SCHEME> -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` |
| One Folino suite | append `-only-testing:<SCHEME>/EditorTests/<SuiteName>` |
| Folino Reader tests | from `Packages/Features/Reader/`: `xcodebuild test -scheme Reader-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` |
| App build | `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build` |

**`<SCHEME>` changes in Task 5.** The Editor package has one product today, so its scheme is `Editor`. Task 5 adds a
second product (`EditorCore`), which makes the aggregate scheme `Editor-Package` — and the per-product `Editor`
scheme loses its test action. Every task from 5 on uses `Editor-Package`.

Pass markers: `✔ Suite <Name> passed` / `** TEST SUCCEEDED **`.

## File Structure

**ssm (Tasks 1–3):**

| File | Responsibility |
| --- | --- |
| `Sources/SheetMusicCore/Editing/EditIntent.swift` | + `.writeNote` case (12th, appended) |
| `Sources/SheetMusicCore/Editing/ScoreEditSession.swift` | + cross-bar branch in `.setChordDuration`; + `.writeNote` planning |
| `Sources/SheetMusicEditWire/EditIntentCodec.swift` | + `WriteNoteIntentWire`, discriminator 12 |
| `Tests/SheetMusicTests/EditingTests/ScoreEditSessionTests.swift` | planning tests for both |
| `Tests/SheetMusicTests/AndroidJNI/EditIntentCodecTests.swift` | round-trip for `.writeNote` |
| `CHANGELOG.md` | the two additions under `[1.11.0]` |

**Folino, new (`Packages/Features/Editor/Sources/EditorCore/`):**

| File | Responsibility |
| --- | --- |
| `EditorSessionCore.swift` | the session, selection/caret, arming, `apply(_:)`, rederivation, counters |
| `EditorSessionCore+Input.swift` | letter keys, rest key, delete, duration arming, the callout's length keys |
| `EditorSessionCore+Pitch.swift` | semitone / octave / accidental |
| `EditorSessionCore+ChordTieTuplet.swift` | chord building, ties, tuplets |
| `EditorSessionCore+Navigation.swift` | ← / → |
| `EditorSessionCore+Persistence.swift` | autosave debounce, save-destination policy, the file-facts seam |
| `SelectionRederivation.swift` | moved verbatim from `Editor` |
| `NoteSpelling.swift` | letter / alteration / octave from tpc + pitch — the shareable half of `NoteNameFormatter` |
| `PadGlyphs.swift` | SMuFL codepoint tables + the metronome-glyph composition rule |
| `EditorSeams.swift` | `NoteAuditioning`, `FileFactsProviding`, `ScoreFileWriting` protocols |

**Folino, changed (`Packages/Features/Editor/Sources/Editor/`):**

| File | Becomes |
| --- | --- |
| `EditorViewModel.swift` | `@Observable @MainActor` mirror over one `EditorSessionCore` |
| `EditorViewModel+*.swift` | one-line delegates, or deleted where the core absorbs the whole file |
| `EditorViewModel+HitTest.swift` | `LayoutDocument.editingHitTest` + `displayToSourceItem`, nothing else |
| `NoteNameFormatter.swift` | localization only; spelling comes from `NoteSpelling` |
| `Views/PadDurationGlyph.swift` | CoreText metrics only; codepoints come from `PadGlyphs` |
| `EditorFileFacts.swift` | the CryptoKit implementation of `FileFactsProviding` |
| **deleted** | `CrossBarInputPlanner`, `ElementNavigator`, `FullMeasureRestCollapse`, `IntervalPlanner`, `MeasureAccidentals`, `NoteInputPlanner`, `StaffStepPitch`, `TiePlanner` (all now in `SheetMusicCore`) |

**Folino, changed (elsewhere):**

| File | Change |
| --- | --- |
| `Packages/Features/Reader/Sources/Reader/Views/EditingSelectionOverlay.swift` | calls `LayoutDocument.editingCaretRect` instead of its own band math |
| `Packages/{Domain,Infrastructure,Features/Reader,Features/Library,Features/Editor}/Package.swift` | ssm pin `1.9.0` → `1.11.0` |
| `project.yml` | same pin |

---

# Part A — ssm: close the two gaps (Tasks 1–3)

These land on the ssm branch, in ssm's 1.11.0, before Folino consumes anything.

Both gaps were found on 2026-08-11 while planning SP2, by reading Folino's ops against
`ScoreEditSession.command(for:in:depth:)`. Neither is a regression in SP1 — SP1 built the vocabulary the *spec*
described, and the spec never enumerated these two paths.

### Task 1: `.setChordDuration` crosses the barline

**Why.** Folino's callout length keys re-time the selected element, and when the new length outruns the bar they
spell it as a tied chain (`EditorViewModel+Input.swift`'s `retimeCrossingBarline`, reached from `applyToSelection`).
`ScoreEditSession` gave `.setRestDuration` that interception but not `.setChordDuration`, which maps straight onto
`SetChordDuration` — and the engine refuses a single-slot lengthening that would cross a barline. Converting Folino's
ops to intents without this makes the callout's length keys go dead near a barline, which is exactly the failure
`CrossBarInputPlanner` was written to fix on the input side.

`CrossBarInputPlanner.plan` returns `nil` when the length fits its bar, so this is a pure addition: every case that
works today keeps taking the same path.

**Files:**
- Modify: `Sources/SheetMusicCore/Editing/ScoreEditSession.swift` (the `.setChordDuration` case, ~line 154)
- Test: `Tests/SheetMusicTests/EditingTests/ScoreEditSessionTests.swift`

**Interfaces:**
- Consumes: `CrossBarInputPlanner.plan(_:duration:at:in:)`, `CompositeEditCommand`
- Produces: no signature change — `.setChordDuration` behaves as before for lengths that fit.

- [ ] **Step 1: Read the neighbouring case first**

Read `Sources/SheetMusicCore/Editing/ScoreEditSession.swift`'s `.setRestDuration` case. This task makes
`.setChordDuration` its mirror image, minus the `.measure` promotion (a chord may not carry `.measure` — see
`InputNote`'s doc comment).

- [ ] **Step 2: Write the failing test**

Append to `Tests/SheetMusicTests/EditingTests/ScoreEditSessionTests.swift`:

```swift
    /// A half note asked for on the last quarter of a 4/4 bar. `SetChordDuration` alone is refused (the engine has
    /// "not enough room in the measure to lengthen"), so without the cross-bar interception the callout's length key
    /// is dead at every barline — the same hole `CrossBarInputPlanner` closed on the input side.
    @Test func `a chord re-timed past the barline is spelled as a tied chain`() throws {
        var score = EditingFixtures.twoMeasuresOfQuarterRests()
        let slot = VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 4)
        score[slot] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        let session = ScoreEditSession(score: score)

        #expect(session.apply(.setChordDuration(at: slot, duration: .half)))

        let head = try #require(session.score[slot])
        guard case let .chord(headChord) = head else { Issue.record("head is not a chord"); return }
        #expect(headChord.duration == .quarter)
        #expect(headChord.notes.first?.tieForward != nil)

        let tailSlot = VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 1, voiceIndex: 0, elementIndex: 0)
        guard case let .chord(tailChord)? = session.score[tailSlot] else {
            Issue.record("tail is not a chord"); return
        }
        #expect(tailChord.duration == .quarter)
        #expect(tailChord.notes.first?.pitch == 60)
        #expect(tailChord.notes.first?.tieBack != nil)
    }

    /// The far more common case: a length that fits its bar must still take the plain single-slot path, so this
    /// addition can't have changed what already worked.
    @Test func `a chord re-timed within its bar is untouched by the cross-bar path`() throws {
        var score = EditingFixtures.fourQuarterRests()
        let slot = VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        score[slot] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        let session = ScoreEditSession(score: score)

        #expect(session.apply(.setChordDuration(at: slot, duration: .half)))

        guard case let .chord(chord)? = session.score[slot] else { Issue.record("not a chord"); return }
        #expect(chord.duration == .half)
        #expect(chord.notes.first?.tieForward == nil)
    }
```

Check `EditingFixtures` for the exact helper names before writing — the SP1 plan lists
`fourQuarterRests()`, `twoMeasuresOfQuarterRests()`, `staff0`. If a helper is missing, add it there rather than
inlining a second fixture.

- [ ] **Step 3: Run the tests and watch the first one fail**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter ScoreEditSessionTests
```

Expected: `a chord re-timed past the barline is spelled as a tied chain` fails — `apply` returns `false`.

- [ ] **Step 4: Add the interception**

In `ScoreEditSession.command(for:in:depth:)`, replace the `.setChordDuration` case:

```swift
        case let .setChordDuration(location, duration):
            // The same cross-bar hole `.setRestDuration` has: a single-slot lengthening that would cross a barline
            // is refused outright by the engine, so the callout's length keys read as dead near one. Spell it as a
            // tied chain instead — the planner clones the chord into every piece, so a three-note chord arrives on
            // the far side as the same three notes. `plan` returns nil when the length fits its bar, which is what
            // keeps the ordinary path ordinary.
            //
            // No `.measure` promotion here, unlike the rest case: `.measure` is a rest-only duration (see
            // `InputNote`), and `MSCXEncoder` traps rather than emit one on a chord.
            if let plan = CrossBarInputPlanner.plan(
                .chord(Chord(duration: duration, notes: [])), duration: duration, at: location, in: score,
            ) {
                return CompositeEditCommand(commands: plan.commands, location: plan.head)
            }
            return SetChordDuration(at: location, duration: duration)
```

**Check `CrossBarInputPlanner.plan`'s `.chord` handling before committing to the empty-`notes` form above.** Read
`Sources/SheetMusicCore/Editing/Planners/CrossBarInputPlanner.swift`: its doc comment says the chord is *cloned into
every piece* and that "this also re-times what is already written: a three-note chord stretched over a barline has to
arrive on the far side as the same three notes". If the planner uses the passed chord's `notes` rather than reading
the slot's current chord, the call above must pass the **existing** chord instead:

```swift
        case let .setChordDuration(location, duration):
            guard case let .chord(current)? = score[location], !current.notes.isEmpty else {
                return SetChordDuration(at: location, duration: duration)
            }
            if let plan = CrossBarInputPlanner.plan(
                .chord(current), duration: duration, at: location, in: score,
            ) {
                return CompositeEditCommand(commands: plan.commands, location: plan.head)
            }
            return SetChordDuration(at: location, duration: duration)
```

Folino's own `retimeCrossingBarline` passes the existing chord (`applyToSelection`'s `.note` case reads
`case let .chord(chord)? = score[slot]` first), so the second form is the one that matches shipped iOS behavior.
Use it unless reading the planner proves the chord argument is ignored.

- [ ] **Step 5: Run the tests and watch both pass**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter ScoreEditSessionTests
```

Expected: PASS.

- [ ] **Step 6: Run the whole host suite**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing
```

Expected: green except the two known pre-existing failures recorded in SP1's ledger. If a *third* fails, stop and
report — the chain planner is reachable from the replay script, and a fingerprint drift here is a real finding.

- [ ] **Step 7: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing add Sources/SheetMusicCore/Editing/ScoreEditSession.swift Tests/SheetMusicTests/EditingTests/ScoreEditSessionTests.swift
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -m "fix(editing): let setChordDuration cross the barline, as setRestDuration already does"
```

---

### Task 2: `.writeNote` — the letter key on a slot that already holds a note

**Why.** `.inputNote` targets a `RestID` and plans `InputNote`, which refuses anything but a rest. Folino's letter key
also lands on notes (`EditorViewModel+Input.swift`'s `inputPitch(letter:onNote:)`), where it does two things at once:
re-times the slot to the armed length and re-pitches it — and when the armed length outruns the bar, it writes the
chain **with the new pitch** (`writeCrossingBarline`) rather than re-timing and then re-pitching.

That last case cannot be expressed as `.composite([.setChordDuration, .setNotePitch])` even after Task 1:
`CrossBarInputPlanner` clones the *existing* chord into every piece, so a following `.setNotePitch` would retune only
the chain's head and leave the tail tied to it at the old pitch. A tie between two different pitches is not a
notation this app should be able to produce.

So the vocabulary gains one case. It is deliberately *not* a widening of `.inputNote` — that case is wire index 0,
already pinned by the on-device replay goldens, and its `RestID` argument is what makes "write into an empty slot"
unambiguous.

**Files:**
- Modify: `Sources/SheetMusicCore/Editing/EditIntent.swift`
- Modify: `Sources/SheetMusicCore/Editing/ScoreEditSession.swift`
- Modify: `Sources/SheetMusicEditWire/EditIntentCodec.swift`
- Test: `Tests/SheetMusicTests/EditingTests/ScoreEditSessionTests.swift`
- Test: `Tests/SheetMusicTests/AndroidJNI/EditIntentCodecTests.swift`

**Interfaces:**
- Produces, for Task 6 and for SP3:
  `case writeNote(at: VoiceElementID, pitch: Int, tpc: Int, duration: NoteDuration?)` — wire discriminator **12**.

- [ ] **Step 1: Write the failing session tests**

Append to `Tests/SheetMusicTests/EditingTests/ScoreEditSessionTests.swift`:

```swift
    /// The letter key on a slot that already holds a note: re-pitch AND re-time, one undo step. Writing over a note
    /// is still writing a note, so the armed length has to apply — leaving it alone silently ignored half of what
    /// the pad was showing.
    @Test func `writeNote re-pitches and re-times an occupied slot in one step`() throws {
        var score = EditingFixtures.fourQuarterRests()
        let slot = VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        score[slot] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        let session = ScoreEditSession(score: score)

        #expect(session.apply(.writeNote(at: slot, pitch: 62, tpc: 16, duration: .eighth)))

        guard case let .chord(chord)? = session.score[slot] else { Issue.record("not a chord"); return }
        #expect(chord.duration == .eighth)
        #expect(chord.notes.first?.pitch == 62)
        #expect(chord.notes.count == 1)
    }

    /// The whole reason this case exists: the chain has to carry the NEW pitch. Re-timing first and re-pitching
    /// afterwards would leave the tail tied to the head at the old pitch.
    @Test func `writeNote past the barline writes the new pitch into every piece`() throws {
        var score = EditingFixtures.twoMeasuresOfQuarterRests()
        let slot = VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 4)
        score[slot] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        let session = ScoreEditSession(score: score)

        #expect(session.apply(.writeNote(at: slot, pitch: 62, tpc: 16, duration: .half)))

        guard case let .chord(head)? = session.score[slot] else { Issue.record("head is not a chord"); return }
        let tailSlot = VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 1, voiceIndex: 0, elementIndex: 0)
        guard case let .chord(tail)? = session.score[tailSlot] else { Issue.record("tail is not a chord"); return }
        #expect(head.notes.first?.pitch == 62)
        #expect(tail.notes.first?.pitch == 62)
        #expect(head.notes.first?.tieForward != nil)
        #expect(tail.notes.first?.tieBack != nil)
    }

    /// Inside a tuplet the member lengths are the tuplet's to decide: the engine refuses the length change, and a
    /// composite would take the pitch write down with it. Write the pitch at whatever length the slot already has —
    /// the same rule `.inputNote` follows.
    @Test func `writeNote inside a tuplet keeps the slot's own length`() throws {
        var score = EditingFixtures.fourQuarterRests()
        let slot = VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        score[slot] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        var session = ScoreEditSession(score: score)
        #expect(session.apply(.createTuplet(at: slot, actualNotes: 3, normalNotes: 2)))
        session = ScoreEditSession(score: session.score)
        guard case let .chord(before)? = session.score[slot] else { Issue.record("not a chord"); return }

        #expect(session.apply(.writeNote(at: slot, pitch: 62, tpc: 16, duration: .whole)))

        guard case let .chord(after)? = session.score[slot] else { Issue.record("not a chord"); return }
        #expect(after.duration == before.duration)
        #expect(after.notes.first?.pitch == 62)
    }

    /// A `nil` duration means "keep the slot's length" — what the pad sends before anything is armed.
    @Test func `writeNote with no duration only re-pitches`() throws {
        var score = EditingFixtures.fourQuarterRests()
        let slot = VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        score[slot] = .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)]))
        let session = ScoreEditSession(score: score)

        #expect(session.apply(.writeNote(at: slot, pitch: 62, tpc: 16, duration: nil)))

        guard case let .chord(chord)? = session.score[slot] else { Issue.record("not a chord"); return }
        #expect(chord.duration == .half)
        #expect(chord.notes.first?.pitch == 62)
    }

    /// A rest slot is `.inputNote`'s job, not this one. Refusing rather than quietly re-routing keeps the two cases
    /// telling the truth about what they mean, and keeps a relayed intent from doing something its name doesn't say.
    @Test func `writeNote refuses a slot holding a rest`() {
        let score = EditingFixtures.fourQuarterRests()
        let slot = VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        let session = ScoreEditSession(score: score)

        #expect(!session.apply(.writeNote(at: slot, pitch: 62, tpc: 16, duration: .quarter)))
        #expect(session.score == score)
    }
```

- [ ] **Step 2: Run them and watch every one fail to compile**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter ScoreEditSessionTests
```

Expected: build failure — `type 'EditIntent' has no member 'writeNote'`.

- [ ] **Step 3: Append the case**

In `Sources/SheetMusicCore/Editing/EditIntent.swift`, after `.removeTuplet`:

```swift
    /// Write a note into a slot that already holds a chord: re-pitch it, and re-time it to `duration` in the same
    /// undo step. `nil` keeps the slot's current length.
    ///
    /// Distinct from `.inputNote`, which targets a rest. The separation matters at the barline: when `duration`
    /// outruns the bar this spells the note as a tied chain carrying the NEW pitch, which re-timing and re-pitching
    /// as two intents cannot express — the chain clones the existing chord, so the second intent would retune only
    /// its head and leave the tail tied to it at the old pitch.
    case writeNote(at: VoiceElementID, pitch: Int, tpc: Int, duration: NoteDuration?)
```

- [ ] **Step 4: Plan it**

In `ScoreEditSession.command(for:in:depth:)`, add a case before the combined direct-note case:

```swift
        case let .writeNote(location, pitch, tpc, duration):
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
            // No length asked for, the slot is already that length, or the slot is inside a tuplet (where the engine
            // refuses the change and the refusal would take the pitch write down with it): re-pitch alone.
            guard let duration, current.duration != duration, !isInTuplet(location, in: score) else {
                return repitch
            }
            // The armed length may outrun the bar. The chain has to carry the NEW pitch, so it is planned from a
            // fresh chord rather than from `current` — that is what distinguishes this case from
            // `.setChordDuration` followed by `.setNotePitch`.
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
```

`isInTuplet(_:in:)` already exists as a `private static` helper at the bottom of the file.

**Watch the argument label.** `isInTuplet` is declared `isInTuplet(_ slot: VoiceElementID, in score: Score)`; use it
exactly as `.inputNote` does.

- [ ] **Step 5: Run the session tests**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter ScoreEditSessionTests
```

Expected: PASS. If the tuplet test fails because `createTuplet` moved the chord's slot, read what `CreateTuplet`
actually writes and adjust the fixture — not the assertion about length preservation.

- [ ] **Step 6: Write the failing wire round-trip test**

Add `.writeNote` to the intent table in `Tests/SheetMusicTests/AndroidJNI/EditIntentCodecTests.swift` (it round-trips
every case from one array — read the file and extend that array rather than adding a parallel test):

```swift
        .writeNote(at: slot, pitch: 62, tpc: 16, duration: .eighth),
        .writeNote(at: slot, pitch: 62, tpc: 16, duration: nil),
```

- [ ] **Step 7: Run it and watch it fail**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter EditIntentCodecTests
```

Expected: build failure or a decode mismatch — `EditIntentWire` has no case 12 yet.

- [ ] **Step 8: Add the wire projection**

In `Sources/SheetMusicEditWire/EditIntentCodec.swift`:

1. Extend the discriminator table comment at the top with `12 = writeNote(WriteNoteIntentWire)`.
2. Add the payload struct next to the existing `@WireFormat` payloads. Model it on the `inputNote` payload —
   **read that one first** and mirror its field order and its optional-`NoteDuration` encoding exactly; the only
   difference is that the location is a `VoiceElementID` rather than a `RestID`.
3. Append `case writeNote(WriteNoteIntentWire)` **last** in the choice enum, so it takes discriminator 12.
4. Extend `init(from:)` and `decoded` with the matching arms.

The append-only rule is what this step exists to honor: adding the case anywhere but last renumbers a shipped
discriminator, and the failure mode is a silent misdecode on the mirror session rather than a build error.

- [ ] **Step 9: Run the codec tests**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter EditIntentCodecTests
```

Expected: PASS.

- [ ] **Step 10: Pin the discriminator**

Find the test that pins each case's discriminator byte (SP1's plan calls the order "append-only"; there is a test
asserting the encoded first byte per case). Add `.writeNote` → `12`. If no such test exists, write one now:

```swift
    /// The wire discriminator order is frozen: a case that moves silently misdecodes on the far side of the relay,
    /// which no build error can catch. `.writeNote` was appended at 12 in 1.11.0.
    @Test func `writeNote encodes as discriminator 12`() throws {
        let bytes = EditIntentCodec.encoded(.writeNote(at: slot, pitch: 60, tpc: 14, duration: nil))
        #expect(bytes.first == 12)
    }
```

Match `EditIntentCodec`'s real encode entry point — read the file for its actual name before writing this.

- [ ] **Step 11: Run the whole host suite**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing
```

Expected: green except the two known pre-existing failures.

- [ ] **Step 12: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing add Sources/SheetMusicCore/Editing/EditIntent.swift Sources/SheetMusicCore/Editing/ScoreEditSession.swift Sources/SheetMusicEditWire/EditIntentCodec.swift Tests/SheetMusicTests/EditingTests/ScoreEditSessionTests.swift Tests/SheetMusicTests/AndroidJNI/EditIntentCodecTests.swift
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -m "feat(editing): writeNote — the letter key on a slot that already holds a note"
```

---

### Task 3: Release ssm 1.11.0

**Three separate stop-and-confirm gates, all ruled by the user on 2026-08-11:**

1. **Before writing the CHANGELOG entries (Step 1).** More fixes are still landing on ssm `main` — one had already
   merged when this plan was written, and the user said another was coming. The 1.11.0 section must not be treated as
   final until they say it is, because every one of those merges may owe it an entry.
2. **Before merging to `main` and pushing (Step 6).**
3. **Before pushing the tag (Step 8).**

**Re-merge `origin/main` before Step 2 and again before Step 6**, and re-run the host suite each time — the branch is
already 59 commits' worth of merge behind where it started, and the fixes arriving now touch the same tree.

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 0: Ask whether ssm `main` has settled**

Do not write a CHANGELOG entry or cut a version until the user confirms no further fixes are queued. If more are
coming, merge what has landed, re-run the suite, and wait.

- [ ] **Step 1: Document the two additions**

Under `## [1.11.0] - 2026-08-11`, in `### Added`:

```markdown
- `EditIntent.writeNote(at:pitch:tpc:duration:)` (wire discriminator 12) writes a note into a slot that already holds
  a chord — re-pitching and re-timing it as one undo step, and spelling the note as a tied chain carrying the new
  pitch when the length outruns the bar. `.inputNote` still owns the rest-slot case. The separation is not
  cosmetic: a chain is planned by cloning a chord, so re-timing and re-pitching as two intents would retune only the
  chain's head and leave its tail tied at the old pitch.
```

and in `### Changed`:

```markdown
- `EditIntent.setChordDuration` now spells a length that outruns its bar as a tied chain across the barline, the way
  `.setRestDuration` already did. Previously it mapped straight onto `SetChordDuration`, which the engine refuses for
  any single-slot lengthening that would cross a barline — so the intent was inexpressible exactly where a host most
  needs it. Behavior for a length that fits its bar is unchanged.
```

- [ ] **Step 2: Run the whole host suite one more time**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing
```

Expected: green except the two known pre-existing failures. Record the counts in the task report.

- [ ] **Step 3: Cross-build both Android ABIs**

```
Scripts/android-build-libs.sh
```

from the ssm worktree, with the release toolchain first on `PATH`:
`PATH="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH"`. Read the script's own name in
the worktree first — SP1's Task 13 used it and its report names the exact invocation.

Expected: both ABIs build; `nm -D --defined-only` on the produced `.so` still lists `JNI_OnLoad` and the
`Java_…` thunks.

- [ ] **Step 4: Re-run the on-device replay acceptance**

The passing acceptance recorded in SP1's ledger was taken **before** `origin/main` was merged in (59 commits,
including the spanner-skyline work that touches `SheetMusicLayout`). Re-run `EditSessionReplayTest` on the Pixel 8a
exactly as SP1's Task 13 report describes, and compare the fingerprints against `goldens.txt`.

**A fingerprint mismatch here is expected to be a real finding, not a stale golden.** Nothing in Tasks 1–2 changes
what an unedited score hashes to, and nothing in the merged main was supposed to change score content. If the
goldens move, stop and report rather than re-baselining.

- [ ] **Step 5: Ask the user before pushing**

Report: host counts, both ABIs, the device replay result. Then ask for the go-ahead to merge to `main` and push.

- [ ] **Step 6: Merge to main and push**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -am "chore(release): swift-sheet-music 1.11.0"
```

then merge the branch into `main` and push `main`. (Direct-to-`main` push warns that it bypasses the required status
check — that is expected; the tag in Step 8 is where the real gate lands.)

- [ ] **Step 7: Wait for CI green**

Watch the "Build & test (Apple)" check on the pushed `main`. **Do not tag before it is green** — pushing a tag
alongside the commit is what bypasses the status check.

- [ ] **Step 8: Ask, then tag**

With CI green, ask the user, then push the tag `1.11.0` (no `v` prefix — `v*` tags are the Android AAR publish
series and are not cut for a Swift release).

---

# Part B — Folino: intent-shaped ops (Tasks 4–8)

### Task 4: Re-pin to 1.11.0 and delete the planners ssm now owns

**Why.** SP1 moved seven planners plus `ElementNavigator` into `SheetMusicCore/Editing/Planners/`, `public`. Folino
still carries its own copies; two implementations of the same policy is exactly what the repo's parity rule forbids,
and `ScoreEditSession` plans against ssm's copies, so leaving Folino's would mean the two platforms could drift while
both compiling. `Domain` carries `@_exported import SheetMusicCore`, so the call sites need no import changes — the
names simply resolve to ssm's copies once the local files are gone.

**Files:**
- Modify: `Packages/Domain/Package.swift`, `Packages/Infrastructure/Package.swift`,
  `Packages/Features/Reader/Package.swift`, `Packages/Features/Library/Package.swift`,
  `Packages/Features/Editor/Package.swift` — ssm `exact: "1.9.0"` → `"1.11.0"`
- Modify: `project.yml` — `exactVersion: 1.9.0` → `1.11.0`
- Delete: `Packages/Features/Editor/Sources/Editor/{CrossBarInputPlanner,ElementNavigator,FullMeasureRestCollapse,IntervalPlanner,MeasureAccidentals,NoteInputPlanner,StaffStepPitch,TiePlanner}.swift`
- Delete: `Packages/Features/Editor/Tests/EditorTests/{ElementNavigatorTests,IntervalPlannerTests,NoteInputPlannerTests,StaffStepPitchTests,TiePlannerTests}.swift`
- Keep: `CrossBarInputTests.swift` and `MeasureAccidentalsTests.swift` — both are `EditorViewModel`-level behavior
  suites, not planner unit tests. They are the gate for the rest of this plan and must keep passing untouched.

- [ ] **Step 1: Confirm the pin list is complete**

```bash
grep -rn "swift-sheet-music" /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Packages/*/Package.swift /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Packages/Features/*/Package.swift /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/project.yml
```

Every `1.9.0` this prints must be changed. A partial pin fails to resolve with
`required using two different requirements`, which is a confusing error a long way from its cause.

- [ ] **Step 2: Bump every pin to 1.11.0**

- [ ] **Step 3: Regenerate the Xcode project from inside the worktree**

```bash
env -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing xcodegen generate
```

Run it from inside the worktree — passing `--spec` / `--project` from the primary checkout resolves package paths
against the wrong root.

- [ ] **Step 4: Delete the eight planner sources and five planner test files**

Use eight/five separate `rm` calls or one `git rm` per file — the repo's Bash discipline forbids
`find … -exec` and `xargs` for mutating operations.

- [ ] **Step 5: Build the Editor package and read what breaks**

```
xcodebuild -scheme Editor -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```

from `Packages/Features/Editor/`.

Expected: **green with no source edits.** Every deleted type resolves through `Domain`'s re-export of
`SheetMusicCore`. If something does not resolve, the likely causes, in order:

1. **`EditorInterval` was renamed.** SP1's final commit renamed it to `DiatonicInterval`. `EditorViewModel+ChordTieTuplet.swift`'s
   `addIntervalNote(_ interval: EditorInterval)` and every caller (`Views/EditorContextOps.swift`,
   `Views/EditorPadButtons.swift`, and the tests) need the new name. This is a mechanical rename, not a behavior
   change — do it here.
2. **A planner's members were made `public` with different labels.** Read ssm's copy and adapt the call site.
3. **A type Folino's copy had that ssm's does not.** Stop and report; that is a missed move in SP1, not something to
   patch around by resurrecting a local copy.

- [ ] **Step 6: Run the whole Editor suite**

```
xcodebuild test -scheme Editor -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

from `Packages/Features/Editor/`.

Expected: every remaining suite passes. `CrossBarInputTests` and `MeasureAccidentalsTests` passing here is the proof
that ssm's planners behave identically to the copies just deleted — that is the whole point of this task.

- [ ] **Step 7: Build the app**

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```

Expected: green. This catches a Reader or App call site that referenced a moved type.

- [ ] **Step 8: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing add -A
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing commit -m "refactor(editor): drop the planner copies swift-sheet-music 1.11.0 now owns"
```

---

### Task 5: The `EditorCore` target

**Why.** A new target with one moved file, before any logic depends on it — so the manifest, the scheme rename and
the test-target split are all proven while a failure is trivially attributable. `SelectionRederivation` is the right
first tenant: it is pure, it has its own suite, and every op the following tasks move calls it.

**Files:**
- Modify: `Packages/Features/Editor/Package.swift`
- Create: `Packages/Features/Editor/Sources/EditorCore/SelectionRederivation.swift` (moved, `public`)
- Delete: `Packages/Features/Editor/Sources/Editor/SelectionRederivation.swift`
- Create: `Packages/Features/Editor/Tests/EditorCoreTests/SelectionRederivationTests.swift` (moved)
- Delete: `Packages/Features/Editor/Tests/EditorTests/SelectionRederivationTests.swift`

**Interfaces:**
- Produces: target `EditorCore`, product `EditorCore`; `public enum SelectionRederivation` with
  `public static func item(at:in:preferringNoteIndex:) -> ScoreItemID?`

- [ ] **Step 1: Add the target and product**

In `Packages/Features/Editor/Package.swift`:

```swift
    products: [
        .library(name: "Editor", targets: ["Editor"]),
        // Platform-neutral editing session logic. Foundation + Domain only — no SwiftUI, no Observation, no
        // SheetMusicUI — so the Android `FolinoEditorJNI` bridge (SP3) can link it alongside the Apple `Editor` UI
        // target. Mirrors `ReaderAnnotationCore` in the Reader package.
        .library(name: "EditorCore", targets: ["EditorCore"]),
    ],
```

```swift
        // No SwiftLint build-tool plugin: this target is cross-compiled for Android like `FolinoReaderJNI`, and the
        // plugin needs a macOS host context the Android SDK build can't satisfy. The pre-commit hook lints it on the
        // host instead.
        .target(
            name: "EditorCore",
            dependencies: ["Domain"],
        ),
```

and add `"EditorCore"` to the `Editor` target's dependencies, plus a test target:

```swift
        .testTarget(
            name: "EditorCoreTests",
            dependencies: ["EditorCore"],
        ),
```

- [ ] **Step 2: Move `SelectionRederivation` and make it `public`**

The file moves verbatim except that `enum SelectionRederivation` becomes `public enum` and `static func item`
becomes `public static func item`. Its doc comment already explains why re-derivation exists — keep it whole.

`import Domain` stays; `import SheetMusicCore` can go (Domain re-exports it), but leaving it costs nothing. Prefer
dropping it, matching `ReaderAnnotationCore`'s style.

- [ ] **Step 3: Move its test file**

`Tests/EditorCoreTests/SelectionRederivationTests.swift` — change `@testable import Editor` to
`import EditorCore`. It tests only `public` API after Step 2, so `@testable` is not needed.

`EditorFixtures` lives in `Tests/EditorTests/Support/` and is not visible from the new test target. The moved suite
needs the two or three fixtures it uses. **Do not add a dependency from `EditorCoreTests` to `EditorTests`** —
duplicate just the fixtures the suite touches into `Tests/EditorCoreTests/Support/EditorCoreFixtures.swift`, and note
in a comment that `EditorTests/Support/EditorFixtures.swift` is the older, larger twin. Task 12 moves the rest of the
logic suites across and is where the two are reconciled.

- [ ] **Step 4: Build both targets**

```
xcodebuild -scheme Editor-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```

from `Packages/Features/Editor/`. Note the scheme name change — the package is multi-product from this task on.

- [ ] **Step 5: Run both test targets**

```
xcodebuild test -scheme Editor-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Expected: `EditorTests` and `EditorCoreTests` both pass.

- [ ] **Step 6: Prove the target cross-compiles for Android**

```
PATH="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH" swift build --package-path Packages/Features/Editor --swift-sdk aarch64-unknown-linux-android28 --target EditorCore -c release
```

from the worktree root.

Expected: green. **This is the check that gives the rest of the plan its meaning** — running it here, with one pure
file inside, establishes that the target, its dependency on Domain, and the toolchain all line up before any logic
moves in. If it fails now, the cause is the manifest or the toolchain; if it first fails in Task 12, the cause could
be any of eleven files.

If the Android SDK is not installed on this machine, record that in the task report and treat Task 13 as the first
place this runs — do not silently skip it.

- [ ] **Step 7: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing add -A
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing commit -m "feat(editor): add the cross-compiled EditorCore target, starting with SelectionRederivation"
```

---

### Task 6: The session becomes `ScoreEditSession`, and input speaks intents

**Why.** This is the change the whole plan exists for: `EditorViewModel` stops holding a `ScoreEditor` and building
`EditCommand`s, and starts holding a `ScoreEditSession` and naming `EditIntent`s. Everything the local code did
between the op and the engine — cross-bar interception, the `.measure` promotion, the full-measure-rest collapse, the
`MeasureAccidentals` bundle — is `ScoreEditSession.apply`'s job now, so the ops get considerably shorter.

The view model stays where it is for this task. Moving the code and changing what it says at the same time would make
a failure impossible to attribute.

**Files:**
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Input.swift`
- Test: `Packages/Features/Editor/Tests/EditorTests/EditorViewModelSessionTests.swift` (mechanical: `applyCommand` → `apply`)

**Interfaces:**
- Consumes: `ScoreEditSession`, `EditIntent` (including `.writeNote` from Task 2)
- Produces, for Tasks 7 and 12:
  - `EditorViewModel.session: ScoreEditSession?` replaces `editor: ScoreEditor?`
  - `@discardableResult func apply(_ intent: EditIntent) -> EditIntent?` replaces `applyCommand(_:)` — returns the
    intent when it landed, `nil` when the session refused it, so an Android relay knows what to forward

- [ ] **Step 1: Swap the session type and the choke point**

In `EditorViewModel.swift`:

```swift
    public private(set) var session: ScoreEditSession?

    public var score: Score? {
        _ = generation
        return session?.score
    }

    public var isSessionActive: Bool {
        session != nil
    }
```

`beginSession(score:)` builds a `ScoreEditSession(score:)`; `endSession()` clears it. `undo()` / `redo()` call
`session.undo()` / `session.redo()`, which return `Bool` instead of throwing:

```swift
    public func undo() {
        guard let session, session.undo() else { return }
        generation += 1
        rederiveSelection()
        onScoreChanged(session.score)
        isDirty = true
        scheduleAutosave()
    }
```

and the same shape for `redo()`. The `guard`'s second clause replaces the old `do { try … } catch { return }`, and
preserves the same contract: a refused undo must not fire a generation bump, `onSelectionChanged`, or
`onScoreChanged`.

Replace `applyCommand(_:)` with:

```swift
    /// Central apply choke point: every edit goes through here, so selection re-derivation, the generation bump,
    /// `onScoreChanged` and autosave scheduling can never be skipped.
    ///
    /// Returns the intent when it landed and `nil` when the session refused it. The return value is what an Android
    /// host relays to the mirror session behind ssm's score handle (SP3) — a refused intent must not be relayed, or
    /// the two copies diverge. On iOS nothing reads it, and a refusal stays silent: the engine leaves the score
    /// untouched by contract, and v1 shows no error.
    @discardableResult
    func apply(_ intent: EditIntent) -> EditIntent? {
        guard let session, session.apply(intent) else { return nil }
        generation += 1
        appliedEditCount += 1
        rederiveSelection()
        onScoreChanged(session.score)
        isDirty = true
        scheduleAutosave()
        return intent
    }
```

Delete `renotatingAccidentals(_:from:)` — `ScoreEditSession.apply` runs that pass itself, from the same
`MeasureAccidentals` this used to call.

Every other use of `editor` in the file (`canUndo`, `canRedo`, `rederiveSelection`'s `editor.lastAffectedLocation`)
becomes `session`.

- [ ] **Step 2: Update the session test suite mechanically**

`EditorViewModelSessionTests.swift` calls `vm.applyCommand(InputNote(at:pitch:tpc:))` in four tests. Those become:

```swift
        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))
```

and the `invalid edit is swallowed` test becomes:

```swift
        // Element 1 is a rest, not a note — the session must refuse; the VM must not bump generation.
        vm.apply(.setNotePitch(at: EditorFixtures.noteID(element: 1), pitch: 61, tpc: 21, accidental: nil))
```

This is the one suite this plan sanctions editing, and only because it addresses the choke point by name. Every
*behavior* assertion in it stays exactly as written.

- [ ] **Step 3: Run that suite and watch it fail**

```
xcodebuild test -scheme Editor-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Editor-Package/EditorTests/EditorViewModelSessionTests
```

Expected: build failure until Step 1 is complete, then PASS. Run it before touching `+Input.swift` — this proves the
choke point swap in isolation.

- [ ] **Step 4: Convert `inputPitch` to intents**

In `EditorViewModel+Input.swift`, the two private `inputPitch(letter:on…:)` helpers collapse. The rest form:

```swift
    private func inputPitch(letter: Character, onRest restID: RestID, in score: Score) {
        let veID = VoiceElementID(restID)
        guard let planned = MeasureAccidentals.plannedPitch(
            forLetter: letter, nearestTo: referencePitch(before: veID), at: veID, in: score,
        ) else { return }
        let generationBeforeInput = generation
        apply(.inputNote(
            at: restID, pitch: planned.pitch, tpc: planned.tpc, duration: armedInputDuration,
        ))
        land(after: veID, unlessStillAt: generationBeforeInput)
    }
```

and the note form:

```swift
    /// A letter key on a slot that already holds a note: re-pitch it, and re-time it to the armed length too.
    ///
    /// Both, not just the pitch. Writing over an existing note is still writing a note, and the length keys say what
    /// the next note will be — so a quarter armed over an existing half has to produce a quarter.
    private func inputPitch(letter: Character, onNote noteID: NoteID, in score: Score) {
        let veID = VoiceElementID(noteID)
        guard let note = score[noteID],
              let target = MeasureAccidentals.plannedPitch(
                  forLetter: letter, nearestTo: note.pitch, at: veID, in: score,
              )
        else { return }
        let generationBeforeInput = generation
        apply(.writeNote(
            at: veID, pitch: target.pitch, tpc: target.tpc, duration: armedInputDuration,
        ))
        land(after: veID, unlessStillAt: generationBeforeInput)
    }
```

**Delete `writeCrossingBarline(pitch:tpc:at:in:from:)` and `isInsideTuplet`'s use from these two paths** — the
session owns both decisions now.

**But the two-slot landing still matters.** `land(after:)` puts the caret on the element after `location`. When the
write crossed the barline, the caret has to clear the whole chain, not the head — that was `land(selection:caretAfter:)`
with the plan's `tail`. The session does not report the chain's tail. Handle it by walking from the affected
location the session *does* report:

```swift
    /// Where input leaves the two markers: the selection on the note just written, the caret on the next timed
    /// element in voice order — nil past the end of the staff.
    ///
    /// The walk starts from the slot the session says it affected, not from where the key was aimed. For a note
    /// written as a tied chain across the barline those differ: the write lands at `location` but occupies several
    /// slots, and the caret has to clear the whole chain rather than park inside it. `lastAffectedLocation` names
    /// the chain's head, so the caret advance walks forward until it leaves the tie.
    private func land(after location: VoiceElementID, unlessStillAt previousGeneration: Int) {
        guard generation != previousGeneration, let score else { return }
        let written = SelectionRederivation.item(at: location, in: score, preferringNoteIndex: nil)
        let next = ElementNavigator.nextTimedElement(after: tailOfTie(from: location, in: score), in: score)
            .flatMap { SelectionRederivation.item(at: $0, in: score, preferringNoteIndex: nil) }
        place(selection: written, caret: next)
        auditionSelectedNote(unlessStillAt: previousGeneration)
    }

    /// The last slot of a tied chain starting at `location`, or `location` itself when nothing is tied forward.
    private func tailOfTie(from location: VoiceElementID, in score: Score) -> VoiceElementID {
        var tail = location
        while case let .chord(chord)? = score[tail], chord.notes.first?.tieForward != nil,
              let next = ElementNavigator.nextTimedElement(after: tail, in: score)
        {
            tail = next
        }
        return tail
    }
```

`CrossBarInputTests`'s `the selection lands on the first piece and the caret clears the last one` is the test that
decides whether this is right. **If it fails, do not weaken it** — report instead, because the alternative fix is for
`ScoreEditSession` to report the chain's tail, which is an ssm change and a scope decision for the user.

- [ ] **Step 5: Convert the rest key and the callout's length keys**

`writeRest(over:in:)` collapses to one intent. The whole "delete the note, then re-time, unless a tuplet or nothing
armed" dance was iOS working around the engine; the session's `.setRestDuration` does the cross-bar plan and the
`.measure` promotion, and `.delete` does the full-measure collapse:

```swift
    /// Writes a rest of the armed length over the timed slot at `location`, whatever is currently in it.
    ///
    /// Over a note that is a delete (which leaves a rest of the NOTE's length) paired with the re-time, as one
    /// composite so it is a single undo step; over a rest the re-time alone. Falls back to the plain delete when
    /// there is no re-timing to do — nothing armed, or the armed length is what is already there — so that path
    /// keeps `FullMeasureRestCollapse`'s "an emptied bar reads as one measure rest". Inside a tuplet the member
    /// lengths are the tuplet's to decide and the engine refuses the re-time, so those slots delete plainly too.
    private func writeRest(over location: VoiceElementID, in score: Score) {
        guard case let .chord(current)? = score[location] else { return }
        let isNote = !current.notes.isEmpty
        guard let armed = armedInputDuration, current.duration != armed, !isInsideTuplet(location) else {
            if isNote { deleteSelection() }
            return
        }
        let retime = EditIntent.setRestDuration(at: location, duration: armed)
        apply(isNote ? .composite([.delete(at: location), retime]) : retime)
    }
```

**`restDuration(_:at:)` is now dead** — `RestDurationPromotion` inside `ScoreEditSession` applies the same rule. Delete
it, and check for other callers first (`applyToSelection` has one; Step 6 removes it).

`isInsideTuplet(_:)` stays for now: it also gates `isCaretInTuplet`, which is UI state rather than a planning
decision. Task 12 decides where it lives.

- [ ] **Step 6: Convert `applyToSelection`**

```swift
    private func applyToSelection(base: NoteDuration, dots: Int) {
        guard let selectedItem, let slot = Self.slot(of: selectedItem) else { return }
        let duration = dots > 0 ? base.dotted(dots) : base
        switch selectedItem {
        case .note: apply(.setChordDuration(at: slot, duration: duration))
        case .rest: apply(.setRestDuration(at: slot, duration: duration))
        case .tuplet, .clef: return
        }
    }
```

Delete `retimeCrossingBarline(_:duration:at:in:)`. Task 1 is what makes the `.note` line above correct at a barline —
if `CrossBarInputTests`'s `re-timing a note past the barline ties it instead of doing nothing` fails here, Task 1 did
not land or did not land correctly.

- [ ] **Step 7: Convert `deleteSelection` and `deleteElement`**

```swift
    private func deleteElement(at location: VoiceElementID, in score: Score) {
        let generationBeforeDelete = generation
        apply(.delete(at: location))
        guard generation != generationBeforeDelete else { return }
        // The session's `.delete` collapses a bar this emptied into one measure rest and reports the rest's own
        // slot as the affected location, so re-derivation has already put the selection there. Nothing to place.
    }
```

`FullMeasureRestCollapse.plan` is no longer called from Folino — the session calls it. Confirm the selection still
lands on the collapsed measure rest: `ScoreEditSession`'s `.delete` case threads `plan.restElementIndex` through
explicitly for exactly this reason. If `EditorViewModelInputTests` disagrees, read that case's doc comment before
changing anything.

If the explicit `select(...)` turns out to still be needed, keep it — but then say why in the comment, because the
session's doc comment claims it is not.

The three `applyCommand(...)` calls left in `deleteSelection` become:

```swift
        case let .note(noteID):
            guard case let .chord(chord)? = score[VoiceElementID(noteID)] else { return }
            if chord.notes.count > 1 {
                apply(.removeNoteFromChord(at: noteID))
            } else {
                deleteElement(at: VoiceElementID(noteID), in: score)
            }
```

and the `.tuplet` case becomes `apply(.removeTuplet(at: …))` with the same `VoiceElementID` construction.

- [ ] **Step 8: Run the input, cross-bar and accidental suites**

```
xcodebuild test -scheme Editor-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Editor-Package/EditorTests/EditorViewModelInputTests -only-testing:Editor-Package/EditorTests/CrossBarInputTests -only-testing:Editor-Package/EditorTests/MeasureAccidentalsTests
```

Expected: PASS, with no assertion edited.

- [ ] **Step 9: Run the whole package**

```
xcodebuild test -scheme Editor-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing add -A
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing commit -m "refactor(editor): drive input through ScoreEditSession intents"
```

---

### Task 7: Pitch, chords, ties and tuplets speak intents

**Why.** The remaining ops. These are the easy half — every one maps onto an intent that already existed before this
plan — but they are what makes `applyCommand` disappear entirely, and with it the last place Folino builds an
`EditCommand` of its own.

**Files:**
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Pitch.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+ChordTieTuplet.swift`

**Interfaces:**
- Consumes: `apply(_:) -> EditIntent?` from Task 6

- [ ] **Step 1: Pitch**

Each of the three ops in `+Pitch.swift` becomes one `apply(...)`:

```swift
        apply(.setNotePitch(at: noteID, pitch: shifted.pitch, tpc: shifted.tpc, accidental: shifted.accidental))
```

```swift
        apply(.setNotePitch(at: noteID, pitch: newPitch, tpc: note.tpc, accidental: note.accidental))
```

```swift
        apply(.setAccidental(at: noteID, accidental: accidental))
```

Everything else in that file — the guards, the `generationBefore…` captures, the `auditionSelectedNote` calls — is
unchanged.

- [ ] **Step 2: Chords**

`removeSelectedNoteFromChord` → `apply(.removeNoteFromChord(at: noteID))`.

`addNoteToChord(at:pitch:tpc:keySig:)` → `apply(.addNoteToChord(at: veID, pitch: pitch, tpc: tpc, accidental: accidental))`,
with its `generation != generationBeforeAdd` guard and its `select(.note(addedNoteID))` / `audition(addedNoteID)`
landing unchanged.

- [ ] **Step 3: Ties**

`toggleTie` → two `apply(.setTie(from:to:sourceTieForward:targetTieBack:))` calls, mirroring the two `applyCommand`
calls it has today.

`appendTiedNote` is the interesting one: `tieAppendPlan()` returns `[any EditCommand]` today, built from
`CrossBarInputPlanner` plus `SetRestDuration` / `InputNote` / `SetTie`. It becomes a plan of *intents*:

```swift
    /// The pad's tie ＋ key: writes a note of the ARMED length in the slot after the selected one, at the same pitch,
    /// and ties the two together — one composite, so one undo step.
    ///
    /// The chain across the barline is `.inputNote`'s job now (it asks the cross-bar planner itself), so this only
    /// has to name the slot, the pitch and the length, then tie onto whatever landed. `sourceTieForward: 1` /
    /// `targetTieBack: 1` are the tie's own numbering, unchanged.
    private func tieAppendPlan() -> (intents: [EditIntent], target: NoteID)? {
        guard case let .note(noteID)? = selectedItem, let score, let note = score[noteID],
              let armed = armedInputDuration,
              let next = ElementNavigator.nextTimedElement(after: VoiceElementID(noteID), in: score),
              case let .chord(target)? = score[next], target.notes.isEmpty
        else { return nil }
        // No room and no chain means the length being asked for has nowhere to go: issuing the write anyway hands
        // the session an intent it refuses, which reads as a lit key that does nothing. Report unavailable instead,
        // so `canAppendTiedNote` dims it.
        guard CrossBarInputPlanner.plan(
            .chord(Chord(duration: armed, notes: [Note(pitch: note.pitch, tpc: note.tpc)])),
            duration: armed, at: next, in: score,
        ) != nil || CrossBarInputPlanner.fitsInMeasure(armed, at: next, in: score) else { return nil }
        let head = NoteID(
            staff: next.staff,
            measureIndex: next.measureIndex,
            voiceIndex: next.voiceIndex,
            elementIndex: next.elementIndex,
            noteIndexInChord: 0,
        )
        let restID = RestID(
            staff: next.staff,
            measureIndex: next.measureIndex,
            voiceIndex: next.voiceIndex,
            elementIndex: next.elementIndex,
        )
        return (
            [
                .inputNote(at: restID, pitch: note.pitch, tpc: note.tpc, duration: armed),
                .setTie(from: noteID, to: head, sourceTieForward: 1, targetTieBack: 1),
            ],
            head
        )
    }

    public func appendTiedNote() {
        guard let plan = tieAppendPlan() else { return }
        apply(.composite(plan.intents))
    }

    public var canAppendTiedNote: Bool {
        tieAppendPlan() != nil
    }
```

**Two things to verify against the tests, not by reasoning:**

1. **The tie target's address.** Today's cross-bar branch ties onto `plan.head`, which is the chain's first slot —
   the same slot `next` names. The version above ties onto `next` in both cases, which should be identical. If
   `CrossBarInputTests`'s `the tie key carries its note across the barline too` disagrees, the chain's head is not
   where this assumes and the composite needs the head reported some other way. Report rather than guess.
2. **The availability guard.** Today's `guard CrossBarInputPlanner.fitsInMeasure(…) else { return nil }` sits only on
   the non-chain path; the version above keeps the same total by allowing either a plan or a fit.
   `the tie key stays dim when the chain has nowhere to land` is the test that decides it.

- [ ] **Step 4: Tuplets**

`createTuplet(actualNotes:)` → `apply(.createTuplet(at: Self.tupletTarget(caretItem), actualNotes: actualNotes, normalNotes: Self.normalNotes(forActualNotes: actualNotes)))`,
keeping the `actualNotes >= 2` guard and the "record `armedTuplet` before the caret check" ordering exactly as they
are, both of which the comments there explain.

`removeTuplet()` → `apply(.removeTuplet(at: Self.tupletTarget(caretItem)))`.

- [ ] **Step 5: Confirm `applyCommand` is gone**

```bash
grep -rn "applyCommand\|EditCommand\|CompositeEditCommand" /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Packages/Features/Editor/Sources/
```

Expected: no hits. Folino no longer names an `EditCommand` anywhere.

- [ ] **Step 6: Run the whole package**

```
xcodebuild test -scheme Editor-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Expected: PASS, with no assertion edited.

- [ ] **Step 7: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing add -A
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing commit -m "refactor(editor): drive pitch, chords, ties and tuplets through intents"
```

---

### Task 8: Hit-testing and the caret rect move onto `LayoutDocument`

**Why.** `EditorViewModel+HitTest.swift` is the file that makes the view model un-shareable: it imports
`SheetMusicUI`, an Apple-only SwiftUI target. SP1 moved the whole policy — the ladder, the 44-point slop box, the
active-voice preference, the on-staff gate — into `LayoutDocument.editingHitTest(at:activeVoice:)`. Folino's copy is
now a second implementation of a policy that has one owner.

The caret rect is the same story on the Reader's side: `EditingSelectionOverlay` computes the staff band itself, and
`LayoutDocument.editingCaretRect(for:in:minimumWidth:)` is that computation with the two call sites' only difference
(`minimumWidth` 2 for the caret, 1 for the callout anchor) as a parameter.

**Files:**
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+HitTest.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Views/EditingSelectionOverlay.swift`

- [ ] **Step 1: Reduce the hit-test file to its seam**

Everything from `displayedItem(at:)` down — `isOnStaff`, `slopHalfExtent`, `slopRect`, `selectableItem` — is deleted.
What remains:

```swift
import Foundation
import SheetMusicLayout

/// Maps a tap point (in the Reader's score-surface / `LayoutDocument` coordinate space) to a selection.
///
/// The policy itself — the hit-test ladder, the 44-point slop box, the active-voice preference and the on-staff gate
/// that makes a tap on empty paper mean "nothing" — lives in `LayoutDocument.editingHitTest(at:activeVoice:)` as of
/// swift-sheet-music 1.11.0, so iOS and Android run one implementation. What stays here is the part only this app
/// knows: which document is on screen, and how to re-address the answer.
extension EditorViewModel {
    public func handleTap(at point: CGPoint) {
        let item = resolvedItem(at: point)
        select(item)
        // Sound what was tapped, exactly as tapping the score does outside edit mode. Never over a running
        // transport: a one-shot preview on top of continuous playback.
        if case let .note(noteID)? = item, !isPlaybackActive {
            audition(noteID)
        }
    }

    // … selectItem(_:), deselect(), hoverItem(at:) unchanged …

    /// The hit is addressed against the RENDERED document, which may be a staff-filtered rendition of the score this
    /// view model edits — so the result is re-stamped into source addressing before it leaves
    /// (`displayToSourceItem`, identity when nothing is filtered).
    private func resolvedItem(at point: CGPoint) -> SheetMusicCore.ScoreItemID? {
        guard let document = documentProvider() else { return nil }
        return document.editingHitTest(at: point, activeVoice: activeVoice).flatMap(displayToSourceItem)
    }
}
```

Note the import list: `SheetMusicUI` is gone. `SheetMusicLayout` is what carries `LayoutDocument` and, since SP1, the
`Selection/` types.

- [ ] **Step 2: Run the hit-test suite**

```
xcodebuild test -scheme Editor-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Editor-Package/EditorTests/EditorViewModelHitTestTests
```

Expected: PASS. This suite is 210 lines of exactly the edge cases the deleted code existed for — the near-miss
rescue, the on-staff gate, the voice preference. It passing against ssm's copy is the proof the policies match.

If it fails, the difference is between two implementations that are supposed to be identical: diff the deleted code
against `Sources/SheetMusicLayout/Selection/LayoutDocument+Editing.swift` in the ssm worktree and report which one is
wrong. Do not adapt the test.

- [ ] **Step 3: Switch the Reader overlay to `editingCaretRect`**

Read `EditingSelectionOverlay.swift` and find the two places that build a rect from a cursor frame plus a staff band.
Replace each with:

```swift
        document.editingCaretRect(for: item, in: score, minimumWidth: 2)
```

for the caret, and `minimumWidth: 1` for the selection anchor the callout is positioned from. Delete the local
`staffBand`-shaped helper the two shared.

If the overlay's own version differs from ssm's in any way beyond `minimumWidth` — a different `sp` margin, a
different system lookup — stop and report. `LayoutDocument.editingCaretRect`'s doc comment claims it *is* Folino's
overlay's math; a real difference means SP1 moved it inexactly.

- [ ] **Step 4: Run the Reader suite**

```
xcodebuild test -scheme Reader-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

from `Packages/Features/Reader/`.

- [ ] **Step 5: Verify the caret by eye**

The caret and the callout anchor are geometry, and geometry is what a test suite is worst at. Render
`EditingSelectionOverlay`'s `#Preview` (or `EditorChromeView+Previews`) through the Xcode MCP `RenderPreview` and
read the PNG: the caret must be a thin bar spanning one staff's band, not the full system height and not a hairline.
If there is no preview covering it, add one — a preview for a geometry change is cheaper than a simulator run and
this plan will want it again in SP4.

- [ ] **Step 6: Build the app**

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```

- [ ] **Step 7: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing add -A
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing commit -m "refactor(editor): use the shared editing hit test and caret rect"
```

---

# Part C — Folino: cut the Apple-only seams (Tasks 9–11)

Three things in the view model cannot cross to Android as they stand. Each gets a seam **before** the move, so Task 12
is a move and nothing else.

### Task 9: The audition, hashing and file-write seams

**Why.** Three concrete Apple dependencies sit inside code that has to compile for Android:

| What | Why it can't cross | Seam |
| --- | --- | --- |
| `EditorFileFacts` | `import CryptoKit` — absent on Android | `FileFactsProviding` protocol; Kotlin supplies the digest on Android, as `LibraryAndroidStore` already does for import |
| Audition | `PlaybackController` is a 30-method Domain protocol over AVFoundation | `NoteAuditioning` — one method, the only one editing uses |
| Saving | `ScoreFileGateway.saveScore` is fine, but the `ScoreItem` row refresh is a repository call | `ScoreFileWriting`, so the core states the policy and the platform performs the write |

The narrow-protocol choice for audition is a deliberate deviation from spec §6.1, which says "`PlaybackController` is
already a Domain protocol, so Android supplies an implementation over its existing synth path". Making Android
implement thirty methods — audio session lifetime, cursor streams, per-staff mixing — to sound one note is not what
that sentence was reaching for. The *decision* to audition still stays in the core, which is what the spec cared about.

**Files:**
- Create: `Packages/Features/Editor/Sources/EditorCore/EditorSeams.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorFileFacts.swift`
- Create: `Packages/Features/Editor/Sources/Editor/EditorSeamAdapters.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift`,
  `EditorViewModel+Audition.swift`, `EditorViewModel+Persistence.swift`
- Modify: `Packages/Features/Editor/Tests/EditorTests/Support/FakePlaybackController.swift`

**Interfaces:**
- Produces, for Task 12:

```swift
public protocol NoteAuditioning: Sendable {
    func playPreview(noteID: NoteID, in score: Score, duration: TimeInterval) async
}

public protocol FileFactsProviding: Sendable {
    func hashAndSize(of url: URL) throws -> (contentHash: String, sizeBytes: Int64)
}

public protocol ScoreFileWriting: Sendable {
    func write(_ score: Score, to url: URL, format: ScoreFormat) async throws
    func refreshRow(_ item: ScoreItem) async throws
}
```

- [ ] **Step 1: Declare the three protocols**

`Sources/EditorCore/EditorSeams.swift`, with the code above plus doc comments explaining what each exists for. Each
comment should name the Android side of the seam, because that is the thing the reader of this file will not have in
front of them.

- [ ] **Step 2: Conform the iOS implementations**

`EditorFileFacts` becomes a `struct` conforming to `FileFactsProviding`, keeping the CryptoKit body exactly as it is
(it already matches the importer's hex-digest format, which is load-bearing — a different format would make every
saved score look like a new file to the library).

`EditorSeamAdapters.swift` carries two small wrappers:

```swift
/// Adapts the Reader's full playback controller down to the one method editing uses. The core auditions a note; it
/// has no business holding a handle to the audio session, the cursor stream or the per-staff mixer.
struct PlaybackAudition: NoteAuditioning {
    let controller: any PlaybackController

    func playPreview(noteID: NoteID, in score: Score, duration: TimeInterval) async {
        await controller.playPreview(noteID: noteID, in: score, duration: duration)
    }
}

/// Adapts the gateway + repository pair the App wires in. The core decides WHERE and IN WHAT FORMAT a score is
/// saved (`saveDestination`); this performs the write and refreshes the library row.
struct GatewayScoreWriter: ScoreFileWriting {
    let gateway: any ScoreFileGateway
    let repository: any ScoreLibraryRepository

    func write(_ score: Score, to url: URL, format: ScoreFormat) async throws {
        try await gateway.saveScore(score, fileURL: url, format: format)
    }

    func refreshRow(_ item: ScoreItem) async throws {
        try await repository.saveScoreItem(item)
    }
}
```

Check `ScoreFileGateway.saveScore` and `ScoreLibraryRepository.saveScoreItem` for `async` / `throws` — the existing
call sites in `EditorViewModel+Persistence.swift` use `try await` for both, so mirror whatever those actually are
rather than the shapes written above.

- [ ] **Step 3: Route the view model through them**

`EditorViewModel.init` keeps its current signature (the App composition root is not this task's business) and builds
the adapters internally:

```swift
        self.audition = playback.map(PlaybackAudition.init(controller:))
        self.fileFacts = EditorFileFacts()
        self.writer = GatewayScoreWriter(gateway: gateway, repository: repository)
```

`EditorViewModel+Audition.swift`'s `audition(_:)` calls `audition?.playPreview(…)`; `+Persistence.swift`'s
`performSave()` calls `writer.write(…)`, `fileFacts.hashAndSize(of:)` and `writer.refreshRow(…)`.

- [ ] **Step 4: Point the test fake at the narrow protocol**

`FakePlaybackController` conforms to the whole of `PlaybackController` today, which is why it is 141 lines. It can
stay as it is — `PlaybackAudition` wraps it — but `EditorViewModelAuditionTests` will read better against a small
fake. Add one to `Tests/EditorTests/Support/`:

```swift
/// Records what the editor asked to be sounded. Small on purpose: auditioning is one method, and a 141-line fake of
/// the whole transport told the reader nothing about which call the test was about.
final class FakeAudition: NoteAuditioning, @unchecked Sendable {
    private(set) var previews: [(noteID: NoteID, duration: TimeInterval)] = []

    func playPreview(noteID: NoteID, in score: Score, duration: TimeInterval) async {
        previews.append((noteID, duration))
    }
}
```

Keep `FakePlaybackController` — `EditorViewModel.init` still takes a `PlaybackController`, and other suites use it.
Whether the audition suite switches to `FakeAudition` depends on whether `EditorViewModel` grows a test-only
initializer; if it does not, leave the suite alone and land `FakeAudition` in Task 12 with the core's own tests.

- [ ] **Step 5: Run the whole package**

```
xcodebuild test -scheme Editor-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Expected: PASS. `EditorViewModelAuditionTests` and `EditorViewModelPersistenceTests` are the two that matter here.

- [ ] **Step 6: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing add -A
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing commit -m "refactor(editor): seam the audition, hashing and save dependencies"
```

---

### Task 10: `NoteSpelling` — the shareable half of `NoteNameFormatter`

**Why.** `NoteNameFormatter.readout(for:in:)` builds `"E♭4 · 4分音符 · m.12 · 声部 1"` with
`String(localized:bundle:.module)`. An xcstrings bundle does not ship inside a `.so`, so the string assembly cannot
cross — but the spelling math underneath it (letter from the line of fifths, alteration, scientific octave) is pure,
is the same math `StaffStepPitch` uses, and is exactly what Android needs to assemble the same readout from its own
string resources under the existing localization key scheme.

**Files:**
- Create: `Packages/Features/Editor/Sources/EditorCore/NoteSpelling.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/NoteNameFormatter.swift`
- Create: `Packages/Features/Editor/Tests/EditorCoreTests/NoteSpellingTests.swift`
- Modify: `Packages/Features/Editor/Tests/EditorTests/NoteNameFormatterTests.swift`

**Interfaces:**
- Produces:

```swift
public struct NoteSpelling: Sendable, Equatable {
    /// 0 = C … 6 = B.
    public let letterIndex: Int
    /// …−2 (𝄫), −1 (♭), 0 (♮), +1 (♯), +2 (𝄪)… — how far the tpc sits from its natural letter.
    public let alteration: Int
    /// Scientific octave: 4 contains middle C.
    public let octave: Int
}

public enum NoteSpeller {
    public static func spelling(pitch: Int, tpc: Int) -> NoteSpelling
    public static func name(pitch: Int, tpc: Int) -> String        // "E♭4"
    public static func duration(for item: ScoreItemID, in score: Score) -> NoteDuration?
}
```

- [ ] **Step 1: Write the failing test**

`Tests/EditorCoreTests/NoteSpellingTests.swift`:

```swift
import EditorCore
import Testing

@Suite("Note spelling")
struct NoteSpellingTests {
    @Test func `a natural spells without a glyph`() {
        #expect(NoteSpeller.name(pitch: 60, tpc: 14) == "C4")
    }

    @Test func `a flat spells with its glyph and its own letter's octave`() {
        #expect(NoteSpeller.name(pitch: 63, tpc: 10) == "E♭4")
    }

    /// The enharmonic pair the octave bucketing exists for: B♯3 and C♭4 must spell in the LETTER's octave, not the
    /// pitch's. Bucketing the pitch alone puts B♯3 in octave 4 and C♭4 in octave 5.
    @Test func `enharmonic spellings land in their letter's octave`() {
        #expect(NoteSpeller.name(pitch: 60, tpc: 19) == "B♯3")
        #expect(NoteSpeller.name(pitch: 59, tpc: 9) == "C♭4")
    }

    @Test func `a double sharp carries the double glyph`() {
        #expect(NoteSpeller.name(pitch: 62, tpc: 21) == "C𝄪4")
    }

    /// Structured parts, not just the assembled string: this is what Android reads to build the same readout from
    /// its own string resources.
    @Test func `spelling reports letter, alteration and octave separately`() {
        let spelling = NoteSpeller.spelling(pitch: 63, tpc: 10)
        #expect(spelling.letterIndex == 2)   // E
        #expect(spelling.alteration == -1)
        #expect(spelling.octave == 4)
    }
}
```

**Verify the tpc values against `NoteNameFormatterTests` before running** — that suite already pins several
pitch/tpc pairs, and copying its numbers is safer than deriving them here.

- [ ] **Step 2: Run it and watch it fail**

```
xcodebuild test -scheme Editor-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Editor-Package/EditorCoreTests/NoteSpellingTests
```

Expected: build failure — no `NoteSpeller`.

- [ ] **Step 3: Move the math**

`Sources/EditorCore/NoteSpelling.swift` takes `letterIndex(forTpc:)`, `alteration(forTpc:)`,
`accidentalGlyph(forAlteration:)`, `octave(pitch:letter:)`, `letterNames`, `naturalSemitoneByLetter` and
`duration(for:in:)` from `NoteNameFormatter` — bodies unchanged, doc comments moved with them. They are correct; this
task is not the place to improve them.

The accidental glyphs (`♯ ♭ 𝄪 𝄫`) come along: they are Unicode musical symbols, not localized text, and Android
renders the same characters.

- [ ] **Step 4: Reduce `NoteNameFormatter` to localization**

```swift
import Foundation
import SheetMusicCore

/// Assembles the selection readout shown in the iPad palette / iPhone callout menu (spec §5.8) — e.g.
/// `"E♭4 · 4分音符 · m.12 · 声部 1"`.
///
/// The spelling math moved to `EditorCore.NoteSpeller` so Android can run it; what stays here is the part that
/// cannot cross a `.so` boundary — `String(localized:bundle:.module)`, which needs an xcstrings bundle. Android
/// assembles the same segments from its own string resources under the same `editor.*` keys.
enum NoteNameFormatter {
    static func name(pitch: Int, tpc: Int) -> String {
        NoteSpeller.name(pitch: pitch, tpc: tpc)
    }

    static func readout(for item: SheetMusicCore.ScoreItemID, in score: Score) -> String {
        // … unchanged, calling NoteSpeller.name and NoteSpeller.duration …
    }

    static func localizedDurationName(_ duration: NoteDuration) -> String? {
        // … unchanged …
    }
}
```

`extension Bundle { static let editorModule }` at the bottom of the file stays where it is — it exists so tests can do
locale-independent lookups against the Editor module's bundle, and that bundle is still the Editor target's.

- [ ] **Step 5: Run both suites**

```
xcodebuild test -scheme Editor-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Editor-Package/EditorCoreTests/NoteSpellingTests -only-testing:Editor-Package/EditorTests/NoteNameFormatterTests
```

Expected: PASS, with `NoteNameFormatterTests` unedited.

- [ ] **Step 6: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing add -A
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing commit -m "refactor(editor): share the note-spelling math, keep the localization iOS-side"
```

---

### Task 11: `PadGlyphs` — the codepoint tables

**Why.** `PadDurationGlyph` is two things wedged together: a table of SMuFL codepoints plus the composition rule for a
dotted note (the metronome glyphs, because engraving glyphs carry only notehead advance), and a CoreText metrics pass
that trims a music font's enormous line box. Compose renders the same Bravura face from the same codepoints; it
cannot use `CTFontGetBoundingRectsForGlyphs`.

**Files:**
- Create: `Packages/Features/Editor/Sources/EditorCore/PadGlyphs.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/Views/PadDurationGlyph.swift`
- Modify: `Packages/Features/Editor/Tests/EditorTests/EditorPadGlyphTests.swift` (import only)

**Interfaces:**
- Produces: `public enum PadGlyphs` with `fontFamily`, `ordered`, `rests`, `rest(for:)`, `note(for:)`,
  `textNote(for:dots:)`, `augmentationDot`, `tie` — every member of `PadDurationGlyph` except `ctFont(size:)`,
  `swiftUIFont(size:)`, `LineTrim`, `lineTrim(…)` and `glyphBounds(of:in:)`.

- [ ] **Step 1: Move the tables**

Everything listed above moves verbatim, `public`, with its doc comments — and those comments are the point of the
file. The one about `textNote(for:dots:)` (why the metronome glyphs rather than the engraving ones) and the one about
`rests`' leger-line variants (why a bare whole rest and a bare half rest are indistinguishable on a key) are hard-won
and must survive the move intact.

`fontFamily` moves too: Compose needs the same family name, and the comment explaining that Bravura is registered
process-wide by `SheetMusicLayoutApple` stays with the Apple half.

- [ ] **Step 2: Make `PadDurationGlyph` forward**

`PadDurationGlyph` keeps only the CoreText half and re-exposes the tables so the ~20 view call sites do not churn:

```swift
enum PadDurationGlyph {
    /// The codepoint tables live in `EditorCore.PadGlyphs` so Compose can render the same glyphs from the same
    /// numbers. What stays here is the CoreText metrics pass, which no other platform can run.
    static let fontFamily = PadGlyphs.fontFamily
    static let ordered = PadGlyphs.ordered
    static let rests = PadGlyphs.rests
    static let augmentationDot = PadGlyphs.augmentationDot
    static let tie = PadGlyphs.tie

    static func rest(for duration: NoteDuration?) -> String { PadGlyphs.rest(for: duration) }
    static func note(for duration: NoteDuration?) -> String { PadGlyphs.note(for: duration) }
    static func textNote(for duration: NoteDuration?, dots: Int) -> String {
        PadGlyphs.textNote(for: duration, dots: dots)
    }

    // … ctFont, swiftUIFont, LineTrim, lineTrim, glyphBounds unchanged …
}
```

- [ ] **Step 3: Run the glyph suite**

```
xcodebuild test -scheme Editor-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Editor-Package/EditorTests/EditorPadGlyphTests
```

Expected: PASS. That suite asks the real Bravura font whether it has a glyph for every codepoint — it is what stops a
typo in a moved `\u{…}` from shipping as a .notdef box, which is exactly how the v1 glyphs failed.

- [ ] **Step 4: Render the pad and look at it**

Run `EditorChromeView+Previews`' pad preview through the Xcode MCP `RenderPreview` and read the PNG. Every duration
key, the rest key and the tie key must show their glyph. A moved codepoint table is the kind of change a test can pass
and an eye can fail.

- [ ] **Step 5: Run the whole package, then commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing add -A
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing commit -m "refactor(editor): share the pad's SMuFL codepoints, keep the CoreText metrics iOS-side"
```

---

# Part D — Folino: the move (Tasks 12–13)

### Task 12: `EditorSessionCore`, and `EditorViewModel` becomes a mirror

**Why.** Everything is now intent-shaped and seamed. This task is a move: the session, the selection and caret, the
arming state, the ops and the autosave policy go into `EditorCore`, and `EditorViewModel` becomes an `@Observable`
`@MainActor` mirror that re-syncs after each call and keeps the Apple-only concerns.

**The public API of `EditorViewModel` must not change.** `EditorChromeView`, `EditorPadView`, `EditorCalloutView`,
`EditorContextOps`, `SelectionCalloutLayer` and `App/EditableReaderScreen.swift` all drive it, and none of them is in
this plan's scope.

**Files:**
- Create: `Sources/EditorCore/EditorSessionCore.swift` + five extension files (see File Structure)
- Modify: `Sources/Editor/EditorViewModel.swift` and every `EditorViewModel+*.swift`
- Move: the logic suites from `Tests/EditorTests/` to `Tests/EditorCoreTests/`

**Interfaces:**
- Produces, for SP3:

```swift
public final class EditorSessionCore {
    public init(
        scoreItem: ScoreItem,
        scoresDirectory: URL,
        writer: any ScoreFileWriting,
        fileFacts: any FileFactsProviding,
        audition: (any NoteAuditioning)?,
    )

    public private(set) var session: ScoreEditSession?
    public var score: Score? { get }

    /// Bumped on every applied, undone or redone intent. The iOS adapter mirrors this into its `@Observable`
    /// `generation`; an Android bridge projects it through `@WireletObservable`.
    public private(set) var revision: Int
    /// Bumped ONLY by a successful `apply` — never by undo or redo.
    public private(set) var appliedIntentCount: Int
    /// Bumped by every `place(selection:caret:)` call, whether or not the values changed. The adapter needs the
    /// unconditional signal: `onSelectionChanged` fires on every placement today, and a mirror that only noticed
    /// *differences* would quietly drop the repeats.
    public private(set) var selectionRevision: Int

    public private(set) var selectedItem: ScoreItemID?
    public private(set) var caretItem: ScoreItemID?
    public internal(set) var armedDuration: NoteDuration?
    public internal(set) var armedDots: Int
    public internal(set) var isAddToChordArmed: Bool
    public internal(set) var armedTuplet: Int
    public var activeVoice: Int
    public var isPlaybackActive: Bool

    public func beginSession(score: Score)
    public func endSession() async
    @discardableResult public func apply(_ intent: EditIntent) -> EditIntent?
    public func undo() -> Bool
    public func redo() -> Bool
    // … the op vocabulary, each returning `EditIntent?` …
}
```

- [ ] **Step 1: Move the state and the lifecycle**

`EditorSessionCore.swift` takes, from `EditorViewModel.swift`: `session`, `score`, `selectedItem`, `caretItem`, the
arming properties, `activeVoice`, `isPlaybackActive` (with its `didSet` that drops the selection), `hasEditTarget`,
`isNoteSelected`, `hasSelectionCallout`, `armedInputDuration`, `beginSession`, `endSession`, `apply`, `undo`, `redo`,
`rederiveSelection`, `rederived`, `slot(of:)`, `previousNoteIndex(at:)`, `select`, `place(selection:caret:)`,
`armFromSelectionIfNeeded`.

`generation` and `appliedEditCount` become `revision` and `appliedIntentCount`. The three counters replace the
`@Observable` bumps: the core has no Observation, so the adapter reads them.

- [ ] **Step 2: Move the ops**

The five `EditorViewModel+*.swift` op files become `EditorSessionCore+*.swift`, `extension EditorSessionCore`,
bodies unchanged from Tasks 6–7 and 9–11. Each public op gains `@discardableResult` and an `EditIntent?` return:

```swift
    @discardableResult
    public func inputPitch(letter: Character) -> EditIntent? {
```

returning what `apply` returned. The value is dead on iOS and load-bearing on Android — SP3's Kotlin relay is one
function (local apply → `nativeApplyEditIntent` → fingerprint sample → relayout), and this return is its first step.

`EditorViewModel+HitTest.swift` does **not** move: it needs `LayoutDocument` and the `documentProvider` closure, both
Apple-side. It keeps calling `core.select(...)` and `core.audition(...)`.

- [ ] **Step 3: Write the mirror**

`EditorViewModel.swift` keeps every public property it has today and derives them:

```swift
@MainActor
@Observable
public final class EditorViewModel {
    @ObservationIgnored let core: EditorSessionCore

    public private(set) var generation = 0
    public private(set) var appliedEditCount = 0
    /// The adapter's copy of `core.selectionRevision`. Not `public`: nothing outside reads it, it exists only so
    /// `syncFromCore` can tell "the selection was placed again" from "the selection happens to be equal".
    private var selectionRevision = 0
    public private(set) var selection: ScoreSelection = .none
    public private(set) var selectedItem: SheetMusicCore.ScoreItemID?
    public private(set) var caretItem: SheetMusicCore.ScoreItemID?
    // … armedDuration, armedDots, isAddToChordArmed, armedTuplet, activeVoice, isPlaybackActive …

    /// Re-reads everything the core owns and fires the two seam callbacks when the core says something moved.
    ///
    /// A mirror rather than a set of computed properties: Observation tracks *stored* property access, and the core
    /// is a plain class it cannot see into. Computing `score` from `core.session` would register no dependency, and
    /// every view derived from it — the callout's length readout, `canTie`, `isCaretInTuplet` — would be computed
    /// once and never again.
    private func syncFromCore() {
        let scoreMoved = generation != core.revision
        let selectionMoved = selectionRevision != core.selectionRevision
        generation = core.revision
        appliedEditCount = core.appliedIntentCount
        selectionRevision = core.selectionRevision
        selectedItem = core.selectedItem
        caretItem = core.caretItem
        selection = core.selectedItem.map(ScoreSelection.single) ?? .none
        armedDuration = core.armedDuration
        armedDots = core.armedDots
        isAddToChordArmed = core.isAddToChordArmed
        armedTuplet = core.armedTuplet
        if scoreMoved, let score = core.score { onScoreChanged(score) }
        if selectionMoved { onSelectionChanged(selection, caretItem) }
    }
}
```

with every op as `public func inputPitch(letter: Character) { core.inputPitch(letter: letter); syncFromCore() }`.

**`onScoreChanged` and `onSelectionChanged` move to the adapter and fire from here**, not from the core. That keeps
the core free of `@MainActor` closures, and it keeps the App composition root's wiring (`EditableReaderScreen.swift`)
untouched — which is the constraint that matters, because that file is not in scope.

`registerSystemUndo(with:)`, `selectionAnchor`, `documentProvider`, `displayToSourceItem`, `padRevealRequests` /
`requestPadReveal()`, and `didSaveAsSiblingMSCZ`'s public surface all stay on the adapter.

- [ ] **Step 4: Verify the ordering the mirror depends on**

`onScoreChanged` fires *before* `onSelectionChanged` today? Read `EditorViewModel.apply` as it stands after Task 6:
`rederiveSelection()` (which fires `onSelectionChanged` via `place`) runs **before** `onScoreChanged(session.score)`.
The mirror above reverses that. Match the existing order — the Reader host sets `editedScore` and `selection` from
the two callbacks, and a selection that arrives before its score names an item the host cannot resolve yet.

Fix by firing selection first in `syncFromCore`, and note in a comment that the order is the shipped one and not an
accident.

- [ ] **Step 5: Split the test suites**

Move to `Tests/EditorCoreTests/`, changing `@testable import Editor` → `@testable import EditorCore` and
`EditorViewModel` → `EditorSessionCore`: `EditorViewModelInputTests`, `EditorViewModelPitchTests`,
`EditorViewModelChordTests`, `EditorViewModelNavigationTests`, `EditorViewModelSessionTests`,
`EditorViewModelPersistenceTests`, `EditorViewModelAuditionTests`, `CrossBarInputTests`, `MeasureAccidentalsTests`.
Rename each suite's display string from `"EditorViewModel …"` to `"EditorSessionCore …"`.

Stay in `Tests/EditorTests/`: `EditorViewModelHitTestTests` (needs `LayoutDocument`), `EditorPadGlyphTests`,
`NoteNameFormatterTests`, `EditorTests`.

`Support/EditorFixtures.swift` moves to `Tests/EditorCoreTests/Support/`, and `EditorCoreFixtures.swift` (added in
Task 5) folds into it. `EditorTests` needs `sampleItem()` and the ID helpers — duplicate just those into a small
`Tests/EditorTests/Support/EditorTestItems.swift` rather than making one test target depend on another.

`Support/LayoutTestSupport.swift` stays with `EditorTests` (it builds `LayoutDocument`s).
`Support/Fakes.swift` and `Support/FakePlaybackController.swift` move to `EditorCoreTests` if the core's initializer
takes the seam protocols — which it does — so replace them with `FakeAudition` (Task 9) plus small
`FakeScoreWriter` / `FakeFileFacts` conformers, and leave the two big fakes behind for whatever in `EditorTests`
still needs them. If nothing does, delete them.

**This is the step most likely to sprawl.** If a suite will not move without changing an assertion, leave it in
`EditorTests` driving the adapter and note it in the task report. A behavior test that keeps testing the same behavior
through the adapter is worth more than a tidy target split.

- [ ] **Step 6: Run everything**

```
xcodebuild test -scheme Editor-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

then the Reader package, then the app build.

Expected: PASS everywhere, with no behavior assertion edited.

- [ ] **Step 7: Confirm the core is clean**

```bash
grep -rn "import " /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Packages/Features/Editor/Sources/EditorCore/
```

Expected: only `Foundation` and `Domain`. Any other import is a seam that was missed.

```bash
grep -rn "@MainActor\|@Observable\|Task { @MainActor" /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing/Packages/Features/Editor/Sources/EditorCore/
```

Expected: no hits. `Task { @MainActor in … }` in particular never runs in a Swift-on-Android JNI process — no main
runloop is pumped — so one of those reaching the core would deadlock SP3 rather than fail to build.

- [ ] **Step 8: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing add -A
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing commit -m "refactor(editor): move the editing session into EditorCore, leaving an iOS mirror"
```

---

### Task 13: Prove it cross-compiles, and verify on device

**Why.** Everything above is gated by iOS tests. The point of the plan is a target that builds for Android, and the
only thing that proves that is building it for Android. And editing is gesture- and latency-sensitive: the final gate
is the user on a real device, as with annotation Phase 2.

- [ ] **Step 1: Cross-compile `EditorCore` for both ABIs**

```
PATH="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH" swift build --package-path Packages/Features/Editor --swift-sdk aarch64-unknown-linux-android28 --target EditorCore -c release
```

and the same for the second ABI the repo's `Scripts/android-build-*-libs.sh` scripts target — read one of them for
the exact SDK triples rather than guessing.

Expected: green for both.

Failures to expect, and what they mean:

- **`Foundation` shadowing `CGRect` / `CGPoint` / `CGFloat`.** On Android, Foundation ships its own, and it shadows a
  layout stub *silently* — no ambiguity error. `EditorCore` should contain no geometry at all after Task 8; if this
  fires, something geometric did not get seamed. (This cost SP1 a device round-trip in its Task 7.)
- **`CryptoKit` / `CoreText` / `Observation` not found.** A seam was missed; go back to Task 9 or 11.
- **A Domain type that is itself Apple-only.** Report it — Domain is supposed to cross already (`ReaderAnnotationCore`
  proves it), so this would be a real finding about Domain rather than about this plan.

- [ ] **Step 2: Run the whole Folino test sweep**

Editor package, Reader package, and the app scheme's tests. Record counts.

- [ ] **Step 3: Build and install on the physical Pixel**

Android has no `FolinoEditorJNI` yet — that is SP3 — so this step is not "test editing on Android". It is a
regression check that re-pinning ssm to 1.11.0 (Task 4) did not break what already ships. Follow the ordering in
CLAUDE.md: Gradle wirelet codegen first, then the `.so`s, then `assembleDebug`. Install **and launch** — the Android
rule is the inverse of the iOS one.

Verify: the Library opens, a score renders, playback runs, annotation still draws. A rendering or crash regression
here is a version-skew symptom and is worth stopping for.

- [ ] **Step 4: Hand the device to the user for the iOS pass**

Build and install the iOS app on the user's device (or simulator, if they prefer), and ask them to exercise editing:
enter edit mode, tap a note, arm a length, write a run of notes, write one that crosses a barline, delete, undo the
lot, redo, use the callout's length and dot keys, leave the session and reopen the file. Describe what to look for:
the caret leading the selection during a run, the tie appearing on a cross-bar write, the accidentals repairing
themselves later in the bar.

This plan changed no behavior, so the answer should be "identical to before". That is the claim being checked.

- [ ] **Step 5: Update the parity ledger if anything was deferred**

If any part of this plan left a deliberate one-platform gap, leave a `// PARITY(android): …` marker at the point of
divergence and run `Scripts/parity-report.py`. The `parity-ledger` pre-commit hook fails if
`docs/engineering/ios-android-parity.md` drifted, so this cannot be skipped silently.

- [ ] **Step 6: Merge `main` in one more time, re-run, and report**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-note-editing merge main --no-edit
```

Re-run the Editor and Reader suites after the merge. Then report — **do not merge this branch to `main` or push
without asking.**

---

## Notes for whoever executes this

**Read before starting:** SP0's Findings section
(`docs/superpowers/plans/2026-08-06-android-note-editing-sp0.md`), SP1's ledger
(`.superpowers/sdd/2026-08-06-android-note-editing-sp1/progress.md`), and §5.1, §6.1 and §11 of
`docs/superpowers/specs/2026-08-06-android-note-editing-design.md`.

**Three user rulings this plan is built on, which must not be reversed:**

- **2026-08-06** — `SetRestDuration`'s four non-tuplet refusal reasons taking a note write down with them: **status
  quo**. iOS behaves the same way, and `CrossBarInputPlanner`'s interception resolves the main symptom structurally.
- **2026-08-06** — the intent wire lives in one Android-gated ssm product (`SheetMusicEditWire`) that both repos link.
  Task 2 extends *that* declaration, not a Folino copy.
- **2026-08-11** — `EditorCore` holds `ScoreItemID`, not `ScoreSelection`, so its dependency list stays at Domain
  alone.

**Three things SP3 inherits and this plan deliberately does not fix:**

1. **The stale-layout race.** `nativeComputeLayout` writes to `LayoutDocumentCache` without taking the edit lock, and
   `nativeEditingHitTest`'s answer feeds an edit intent — so the failure mode is "a different element is edited",
   not "the cursor is off". Single-threaded Compose does not hit it today. SP0's Findings prescribe per-handle
   generations on the cache.
2. **`.tuplet` is still in filtered addressing** out of `engineCursorForFilteredTap`.
3. **`resetArgb` needs threading through eight `LayoutBridge` sites**, six of which predate this whole branch. The
   user ruled on 2026-08-09 that this lands in 1.11.0 — **check whether it did before assuming it is still open.**

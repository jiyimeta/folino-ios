# Cross-session undo — design

2026-08-19. Makes the Editor's undo history survive closing and reopening an
edit session on the same score, for as long as the app process lives — and, as
the step that makes that cheap and kills a standing duplication, routes the
iOS edit path through swift-sheet-music's `EditIntent` / `ScoreEditSession`,
the same choke point Android already drives.

## The problem

Ending an edit session destroys its undo history. `EditorViewModel.endSession()`
(`Packages/Features/Editor/Sources/Editor/EditorViewModel.swift:274`) flushes
the pending autosave and sets `editor = nil`; the `ScoreEditor` and both of its
command stacks go with it. Tap ✓, notice one bar later that the edit was wrong,
re-enter — and undo has nothing. The file has long been autosaved, so the only
way back is `revertToOriginal()`, which discards *every* session that ever ran,
not the one mistake.

The history is small, the process usually outlives the session by a long time,
and nothing about the session object requires it to die at ✓. This design keeps
it — in memory, for the process lifetime, bounded.

## What this covers, and what it does not

**In scope.**

- **Step 1** — the iOS Editor stops hand-building `EditCommand`s and drives
  `ScoreEditSession` with `EditIntent`s, deleting Folino's copy of the edit
  planning that ssm now owns.
- **Step 2** — a process-level store that retains a score's
  `ScoreEditSession` across sessions, keyed by score identity and content
  hash, LRU-bounded.

**Explicitly ephemeral.** Nothing is written to disk, no version history, no
CloudKit (`Packages/Infrastructure/Sources/CloudSync` is a one-line
placeholder; there is nothing to sync into). Killing the app drops all
histories, exactly as today.

### Rejected: persisting an edit log to disk

Every comparable editor — MuseScore, Word, Photoshop, Xcode, Procreate — drops
its undo stack when the document or the app closes. The apps that *do* keep
history (Google Docs, Figma, Dorico's Backup Projects) surface it as a separate
"version history" feature with named restore points and a preview, never as a
longer ⌘Z — because an unbounded ⌘Z across launches means undoing edits the
user no longer remembers making, blind. If folino ever wants that, it is a
separate feature built on snapshots plus a log (the revert-to-original spec's
sidecar is its natural base), not this one.

The 2026-08-16 revert spec's "Forward compatibility" section anticipated a
follow-up that would "persist the intent log". This design supersedes that
expectation: it keeps the intent *routing* (Step 1) and rejects the
*persistence*. The contracts that section fixed still hold — revert remains a
truncation of history, not an operation within it (see "Existing code that
must change").

### Rejected: `[EditIntent]` replay as the history representation

Holding the history as an intent list and replaying it on undo was considered
and rejected **as the representation** (the intents themselves stay, as Step
1's apply seam). Replay needs the score at log position 0 retained in memory —
the on-disk file is overwritten by autosave, so it cannot serve as the base.
The intent form therefore costs `base Score + [EditIntent]` against the raw
session's `current Score + inverse-command stack`: the delta is only the
inverse stack versus the intent array, and the intent form additionally pays a
replay stall on every undo. The inverse stack is far lighter than it sounds —
`InputNote`'s inverse is a single `ReplaceVoiceElement` carrying one `Chord`.
The one case where intents win is a score composed from scratch (empty base),
but splitting the mechanism by score provenance would divide the experience,
which this repo forbids (`feedback_no_experience_divergence`).

## What the investigation found

### The same planning exists twice

Folino's ops extensions and ssm's `ScoreEditSession` implement the same edit
planning — ssm's own comments say so ("mirrors Folino's
`EditorViewModel+Input.swift`", `ScoreEditSession.swift:123`). Both sides
independently: ask `CrossBarInputPlanner` before falling back to a single-slot
command, guard re-timing inside tuplets, promote a bar-filling rest to
`.measure` (`RestDurationPromotion` vs `restDuration(_:at:)`,
`EditorViewModel+Input.swift:119`), collapse a bar-emptying delete via
`FullMeasureRestCollapse` and thread the collapsed rest's element index into
the affected location, walk `TiePlanner.tieChain` to retune a whole tie chain,
and bundle `MeasureAccidentals.renotationCommands` onto every edit
(`EditorViewModel.swift:357` vs `ScoreEditSession.renotatingAccidentals`).
Every future planning fix has to land twice or the platforms drift.

### The ssm surface, verified at the pinned release

Folino pins swift-sheet-music `exact: "1.15.0"` (Editor `Package.swift`,
Domain `Package.swift`, `project.yml`). The `Sources/SheetMusicCore/Editing/`
tree is **identical between tag `1.15.0` and the clone's `main`** (no commits
in `1.15.0..HEAD` touch it), so everything below is available today with no
ssm release:

- **`EditIntent`** (`EditIntent.swift:12-63`) — 14 cases, scalar-only:
  `.inputNote`, `.setRestDuration`, `.setChordDuration`, `.delete`,
  `.composite`, `.setNotePitch`, `.setAccidental`, `.addNoteToChord`,
  `.removeNoteFromChord`, `.setTie`, `.createTuplet`, `.removeTuplet`,
  `.writeNote`, `.writeRest`.
- **`ScoreEditSession`** (`ScoreEditSession.swift`) — `init(score:)` (:14),
  `score` (:18), `lastAffectedLocation` (:23), `canUndo`/`canRedo` (:27/:31),
  `lastRefusalReason` (:39), `apply(_ intent:) -> Bool` (:48),
  `undo() -> Bool` (:98), `redo() -> Bool` (:104). A plain `final class`, not
  `@MainActor`, not `Sendable` — "hold one per isolation domain", which is
  exactly what retaining it on the main actor does. It is a value that can be
  handed around and re-entered; nothing in it assumes one continuous UI
  session.
- **`ScoreEditor`** (`ScoreEditor.swift`) — stays an internal detail of the
  session; Folino stops holding one directly.

**No ssm API addition is required** for either step. Two places where one
looked plausible resolve host-side; see "Two host-side compensations". One
optional addition is named under "Risks and open items" (redo of a discarded
session), with the exact signature, in case review rejects the default.

### Every `applyCommand` call site, and where it goes

`EditorViewModel.applyCommand(_:)` (`EditorViewModel.swift:338`) has **25 call
sites** (the prior estimate said ~22). All of them map onto intents:

| Call site | Today | Intent |
| --- | --- | --- |
| `+Input.swift:295,303` — `inputPitch(letter:onRest:)` | `[SetRestDuration, InputNote]` composite / bare `InputNote` | `.inputNote(at:pitch:tpc:duration:)` |
| `+Input.swift:354` — `writeCrossingBarline` (rest slot) | cross-bar chain composite | `.inputNote` (the `duration:` does it) |
| `+Input.swift:328,333` — `inputPitch(letter:onNote:)` | `[SetChordDuration, SetNotePitch]` / bare `SetNotePitch` | `.writeNote(at:pitch:tpc:duration:)` |
| `+Input.swift:354` — `writeCrossingBarline` (note slot) | cross-bar chain composite | `.writeNote` |
| `+Input.swift:103,108,112` — `writeRest(over:)` | rest chain / `[Delete, SetRestDuration]` / retime | `.writeRest(at:duration:)` |
| `+Input.swift:158,162` — `deleteElement` | `DeleteVoiceElement` / `FullMeasureRestCollapse` plan | `.delete(at:)` |
| `+Input.swift:231,253` — `applyToSelection` (note) | `SetChordDuration` / cross-bar composite | `.setChordDuration(at:duration:)` |
| `+Input.swift:234,253` — `applyToSelection` (rest) | `SetRestDuration` (promoted) / cross-bar composite | `.setRestDuration(at:duration:)` |
| `+Input.swift:45`, `+ChordTieTuplet.swift:20` | `RemoveNoteFromChord` | `.removeNoteFromChord(at:)` |
| `+Input.swift:52`, `+ChordTieTuplet.swift:231` | `RemoveTuplet` | `.removeTuplet(at:)` |
| `+ChordTieTuplet.swift:57` — `addNoteToChord` | `AddNoteToChord` | `.addNoteToChord(at:pitch:tpc:accidental:)` |
| `+ChordTieTuplet.swift:174,176` — `toggleTie` | `SetTie` | `.setTie(from:to:sourceTieForward:targetTieBack:)` |
| `+ChordTieTuplet.swift:221` — `createTuplet` | `CreateTuplet` | `.createTuplet(at:actualNotes:normalNotes:)` |
| `+ChordTieTuplet.swift:95` — `appendTiedNote` | chain-or-input + `SetTie` composite | `.composite([.inputNote, .setTie])` — see below |
| `+Pitch.swift:46,48` — `retune` (chevrons, tie chain) | `SetNotePitch` / chain composite | `.setNotePitch(at:pitch:tpc:accidental:)` (ssm walks the chain) |
| `+Pitch.swift:57` — `setAccidental` | `SetAccidental` | `.setAccidental(at:accidental:)` |

**No call site lacks an `EditIntent` case.** The one without a *single* case is
`appendTiedNote` (`+ChordTieTuplet.swift:95`): it becomes
`.composite([.inputNote(at: restID, pitch:, tpc:, duration: armed), .setTie(from: noteID, to: headNoteID, sourceTieForward: 1, targetTieBack: 1)])`.
That is sound because ssm plans composite members against the pre-edit score
and `.setTie` is constructed purely from scalars
(`ScoreEditSession.directNoteEditCommand`), applying only after the chain
exists — and the chain's head lands at the very slot being written
(`CrossBarInputPlanner.Plan.head`, `CrossBarInputPlanner.swift:212`), so the
tie target's `NoteID` is known before applying.

## Step 1 — one planner, not two

### Scope

`EditorViewModel` holds a `ScoreEditSession` instead of a `ScoreEditor`.
`applyCommand(_ command: any EditCommand)` becomes
`apply(_ intent: EditIntent) -> Bool` — same choke point, same side effects
(`generation`, `appliedEditCount`, `sessionEditDepth`, `rederiveSelection()`,
`onScoreChanged`, autosave), with the refusal branch reading the session's
`Bool` instead of catching `SheetMusicError.invalidEdit`. The 25 call sites
construct intents per the table. Deleted from Folino, because
`ScoreEditSession` owns them now:

- `renotatingAccidentals(_:from:)` (`EditorViewModel.swift:357`);
- the cross-bar branches: `writeCrossingBarline`, `retimeCrossingBarline`, and
  the chain-planning half of `writeRest(over:)`;
- `restDuration(_:at:)`'s promotion (ssm's `RestDurationPromotion`);
- the `FullMeasureRestCollapse` call in `deleteElement` — `.delete` plans the
  collapse and reports the collapsed rest as `lastAffectedLocation`, so the
  explicit `select(.rest(…))` after it goes too;
- the tie-chain walk in `+Pitch.swift`'s `retune` — `.setNotePitch` walks it.

**What stays host-side, deliberately.** Input *interpretation* and key
*availability* are the view model's job, not planning: which pitch a letter
means (`MeasureAccidentals.plannedPitch`), what the rest key means with
nothing armed (fall back to `.delete`), whether a key should light
(`canAppendTiedNote`, `canTie`, `isCaretInTuplet`). Those predicates may keep
calling the public planners read-only (`CrossBarInputPlanner.fitsInMeasure`,
`TiePlanner.tieTarget`, the local `isInsideTuplet`). The duplication being
killed is *edit construction* — after Step 1, no Folino code builds an
`EditCommand`.

### Two host-side compensations

Two behaviors currently ride on data the command-building code had in hand and
`ScoreEditSession` does not report:

1. **The caret after a cross-bar write.** `land(after:)` places the caret past
   the chain's *tail* (`plan.tail`). The session reports only the head
   (`lastAffectedLocation`). Recompute the tail after a successful apply by
   walking `TiePlanner.tieChain(containing:)` from the head note — the chain a
   fresh write produces is exactly the planner's chain (its head has no
   `tieBack`), and an unchained write is a chain of one, so a single code path
   covers both.
2. **Selection after `appendTiedNote`.** Today the composite's `location` is
   pinned to the *source* note so re-derivation keeps the selection there;
   ssm's `.composite` reports its first member's location (the appended
   note). Compensate with an explicit `select(.note(noteID))` after a
   successful apply — the same post-apply explicit landing
   `addNoteToChord(at:pitch:tpc:keySig:)` already does.

### Pass condition — two parts, both required

- **(a) Behavior invariance:** the existing Editor suites pass —
  `EditorViewModelInputTests`, `EditorViewModelPitchTests`,
  `EditorViewModelChordTests`, `CrossBarInputTests`,
  `EditorViewModelSessionTests`, `EditorViewModelAuditionTests`,
  `EditorViewModelNavigationTests`, `EditorViewModelHitTestTests`,
  `EditorViewModelPersistenceTests`, `EditorViewModelRevertTests`,
  `EditorSessionEndModeTests`, `EditorOriginalRoundTripTests`. Suites that
  drive the *public ops* (`inputPitch`, `deleteSelection`, `writeRest`,
  `toggleTie`, …) must pass **unchanged** — they are the proof. Four files
  additionally seed edits through the internal seam as
  `vm.applyCommand(InputNote(…))` (`EditorViewModelPersistenceTests.swift:94`
  et al., `EditorViewModelRevertTests.swift:68` et al.,
  `EditorViewModelSessionTests`, `EditorViewModelPitchTests`); those calls are
  mechanically retargeted to `vm.apply(.inputNote(…))` with **assertions
  untouched**.
- **(b) The duplication is gone:** no `EditCommand` construction remains under
  `Packages/Features/Editor/Sources/` — `applyCommand` deleted,
  `renotatingAccidentals` deleted, no `CompositeEditCommand` anywhere.
  (a) alone is necessary, not sufficient.

### Why Step 1 is in scope at all

The retained history (Step 2) no longer needs intents — it retains the session
object whole. Step 1 earns its place on its own: it deletes the double
implementation, it lets Android get identical behavior from the same choke
point keyed by intent, and it lets tests be written as "this intent sequence
was recorded". Landing it as its own step with its own pass condition keeps
the regression risk attributable; Step 2 then touches only session lifetime,
never edit semantics.

### Step 1 risks

- **`.writeNote` repitches `noteIndexInChord: 0`.** Folino's
  `inputPitch(letter:onNote:)` repitches the caret's own `NoteID`, which can
  name a non-zero notehead of a chord. Neither path walks the tie chain (only
  the chevrons do), so the only divergence is the note index. Add one test:
  letter input with the caret on a multi-note chord's upper note; if the
  existing behavior matters, the host keeps a narrow `.setNotePitch` branch
  for that case — a call-site decision, not a planning one.
- **Refusal surfaces change shape.** `apply` returning `false` replaces the
  caught `invalidEdit`; `lastRefusalReason` is available for debugging. The
  `generation`-unmoved contract every op relies on is preserved either way.
- **Composite `lastAffectedLocation`.** Covered by compensation 2; watch
  `SelectionRederivationTests` for any other site that assumed a pinned
  location.

## Step 2 — the history outlives the session

### The store

```swift
/// Retains edit sessions across Editor entries, for the process lifetime. Memory-only by design.
@MainActor
public protocol ScoreEditHistoryStore: AnyObject {
    /// Removes and returns the retained session for `id` — or nil (and drops any stale entry)
    /// when none is retained or `contentHash` differs from what it was deposited with.
    func session(for id: ScoreItemID, contentHash: String) -> ScoreEditSession?
    /// Deposits `session` as the most-recent entry, evicting least-recently-used entries over the cap.
    func retain(_ session: ScoreEditSession, for id: ScoreItemID, contentHash: String)
    /// Drops any retained session for `id`.
    func invalidate(_ id: ScoreItemID)
}
```

`@MainActor` with synchronous methods, not `Sendable`-async like
`ScoreOriginalStore`: `ScoreEditSession` is deliberately not `Sendable` ("hold
one per isolation domain"), so the store must live on the actor that drives
sessions — the main actor, where `EditorViewModel` already is. Domain has
precedent for main-actor protocols (`ScoreLibraryRepository.swift:9`,
`VocalTunerHandoff.swift:57`).

`session(for:contentHash:)` **checks the entry out** — the returned session
has one owner (the view model) until `retain` deposits it again. That keeps
LRU accounting trivial and makes the iPad split-view double-open of one score
safe: the second session finds nothing and starts fresh.

### Where it lives (resolved)

The feared constraint dissolves on inspection: **Domain already re-exports
`SheetMusicCore` wholesale** (`@_exported import SheetMusicCore`,
`Packages/Domain/Sources/Domain/DomainExports.swift:1`; sanctioned by
`docs/engineering/module-architecture.md:15` — "Re-exports `SheetMusicCore` so
Features see a single notation model"). `ScoreEditSession` is a
`SheetMusicCore` type, so a Domain protocol can name it and every Feature can
see it through `import Domain` today. No opaque handle or box type is needed.

- **Protocol** → `Packages/Domain/Sources/Domain/Protocols/ScoreEditHistoryStore.swift`,
  beside `ScoreOriginalStore`. Domain is the only layer both Features and the
  composition root already share, and naming an ssm type there is exactly what
  the re-export exists for (`ScoreShareService` already takes a `Score`).
- **Concrete** → `App/ProcessScoreEditHistoryStore.swift`, created once in
  `AppBootstrap` beside `LiveScoreOriginalStore` (`App/AppBootstrap.swift:102`)
  and threaded through `AppShellView` → `EditableReaderScreen` →
  `EditorViewModel.init`, the path every other Editor dependency takes
  (`App/AppShellView.swift:448`, `App/EditableReaderScreen.swift:47`). Unit
  tests live in `Tests/FolinoTests` (precedent:
  `ReviewPromptCoordinatorTests`). App is also where observing
  `UIApplication.didReceiveMemoryWarningNotification` is free — see
  "Bounding".
- **Ruled out.** *Utility*: it can depend on nothing else in this repo and
  must stay app-agnostic, so it cannot name `ScoreEditSession` at all.
  *Domain concrete*: Domain's charter is value types + protocols
  (`module-architecture.md:15`); a mutable LRU class is off-charter.
  *Infrastructure* is the honest runner-up — the `Live*`-adapter symmetry is
  attractive — but every Infrastructure product adapts an external system
  (GRDB, CloudKit, AVFoundation, file I/O) and this type has none; it is
  process-lifetime composition state, which is the App root's own charter.
  If review prefers adapter symmetry, moving the concrete to
  `Infrastructure/ScoreFiles` beside `LiveScoreOriginalStore` changes nothing
  else in this design.

The Editor gains a `NoopScoreEditHistoryStore` for previews, mirroring
`NoopScoreOriginalStore`.

### Keying, adoption, deposit

The key is `ScoreItemID`; the guard is `ScoreItem.contentHash`, which
`performSave()` refreshes to the on-disk digest on every successful save
(`EditorViewModel+Persistence.swift:76`), and which `refreshRow(_:)` /
`wireOnce()`'s re-seed keep current across out-of-band writes
(`App/EditableReaderScreen.swift:134` area).

- **`beginSession(score:)`** asks
  `store.session(for: scoreItem.id, contentHash: scoreItem.contentHash)`.
  A hit is adopted as-is — its `score` is value-equal to the one the Reader
  just loaded, because the hash matched the very bytes that score was parsed
  from. A miss (or hash mismatch — the score was reverted, re-imported,
  version-restored, PDF-re-read, or edited elsewhere since) creates a fresh
  `ScoreEditSession(score:)`. Everything else `beginSession` resets today
  stays reset (`sessionEditDepth = 0`, selection, arming,
  `capturedOriginalThisSession`).
- **`endSession()`** deposits instead of destroying: after `flushPendingSave()`
  — which is what makes `scoreItem.contentHash` the digest of exactly the
  bytes `session.score` was saved as — it calls
  `store.retain(session, for:contentHash:)` and drops its own reference.
  Deposit only when the flush left `isDirty == false` **and** the session has
  history (`canUndo || canRedo`); a failed final save discards the session,
  which is precisely today's failure contract, and an untouched session has
  nothing worth a slot.
- **`revertToOriginal()`** calls `store.invalidate(scoreItem.id)` after the
  store swap succeeds: the file no longer relates to any retained history, and
  waiting for the lazy hash mismatch would hold a dead multi-MB session in a
  slot. (Its own live session is torn down without deposit, as today —
  `EditorViewModel+Revert.swift:53`.)
- **Other file rewrites need no wiring.** PDF re-read and version-history
  restore change `contentHash` on the row; the mismatch drops the stale entry
  at the next `beginSession`. A score deleted from the Library simply ages out
  of the LRU; ids are UUIDs, so there is no reuse to guard.

### Bounding: the LRU cap is 3 retained sessions

Estimated, not measured — assumptions stated. The repo's largest fixture,
`Now_is_the_time.mscz` (108,597 bytes on disk; 1,534 measures across 24
staves; 7,618 chords + 2,296 rests; 7,664 notes; 3.7 MB as expanded `.mscx`),
as an in-memory `Score`:

- ~9,914 timed elements held inline in `VoiceElement` arrays at an assumed
  ~136 B stride (`Chord` has 10 stored fields, `Score/Chord.swift:5`) ≈ 1.35 MB;
- 7,664 notes at an assumed ~120 B stride (`Note` has 14 stored fields,
  `Score/Note.swift:4`) ≈ 0.92 MB, plus ~7.6 K `ChordNotes` array headers
  ≈ 0.37 MB;
- measures / voices / staves / strings scaffolding ≈ 0.5 MB;

≈ **3–4 MB per retained copy of this outlier score** (the 3.7 MB `.mscx` text
is a sanity anchor). The inverse stacks are noise next to that: a typical
inverse is one `ReplaceVoiceElement` carrying one `Chord` (≲ 0.5 KB), the
heavy ones (`ReplaceVoiceElements`, measure collapse) carry a voice-measure
(a few KB), so even a thousand-edit marathon stays ≈ 1 MB. Budget **~7 MB per
retained session** of the worst score we ship anywhere; a typical library item
(tens of KB on disk) retains at well under 0.5 MB.

Cap = 3 deposited sessions (the open session is checked out and not counted):
worst case ≈ **21 MB**, roughly 1–2 % of the foreground memory budget on the
smallest iOS 18-capable devices (~3 GB RAM class), and typically under 1.5 MB.
Three covers the concrete multi-piece flows (a rehearsal set, a lesson
flipping between a few pieces); each further slot buys "undo in the
fifth-most-recent score" at another outlier-copy of cost. An evicted score's
history is gone — the same contract as an app kill.

**Memory pressure empties the store.** The App-layer concrete observes
`UIApplication.didReceiveMemoryWarningNotification` and drops every deposited
entry (the checked-out session is unaffected — the store does not own it).
Same contract as a kill, and it is the difference between "bounded" and
"bounded until jetsam disagrees". This is an addition beyond the agreed
design's text, flagged under "Risks and open items".

### Existing code that must change

The stack bottom stops meaning "where this session started", which breaks
three session-scoped assumptions:

- **`sessionEditDepth` becomes signed.** With adopted history, `canUndo` (and
  the top bar's undo button, `EditorTopBarView.swift:220`) reaches below the
  session start, so `undo()`'s clamp
  (`sessionEditDepth = max(0, sessionEditDepth - 1)`,
  `EditorViewModel.swift:284`) would lie: undo two pre-session edits and the
  count is stuck at 0 while the score has moved. Drop the clamp; the depth is
  the signed net offset from session start. `sessionHasEdits`
  (`EditorViewModel.swift:50`) becomes `sessionEditDepth != 0` — a session
  that net-undid earlier work has changed the score and ✕ must offer to
  discard that too. Everything else about the counter is already right: reset
  in `beginSession`, `+1` on apply and redo, `-1` on undo.
- **`unwindSessionEdits()` / `discardSessionEdits()` become count-driven**
  (`EditorViewModel.swift:300`, `EditorViewModel+Discard.swift:65`). Today
  they unwind `while editor.canUndo` — with retained history that would
  silently discard *previous* sessions' edits. Instead: undo
  `sessionEditDepth` times when positive, **redo `-sessionEditDepth` times
  when negative** — both directions land exactly on the session-open score.
  The disk choreography around the unwind (cancel debounce, join in-flight
  save, flush) is untouched.
- **`revertToOriginal()` invalidates the store entry** (above).
  `capturedOriginalThisSession` semantics are unchanged.
- **The system-undo bridge arms on adoption.** `EditorChromeView` registers
  trampolines per newly applied edit (`EditorChromeView.swift:108`), so an
  adopted history is reachable from the top bar's buttons but not from the
  three-finger gesture until the first new edit. Register one initial
  trampoline at session start when the session already `canUndo`;
  `registerSystemUndo`'s symmetric re-registration handles the rest.

One consequence is accepted as designed rather than patched: **redo survives
deposit, including after ✕.** `unwindSessionEdits` walks back via `undo()`,
which populates the redo stack; the deposited session therefore lets the next
session redo what ✕ discarded. This is the consistent reading — *all* history
survives, and redo is the exact inverse of the discard, symmetric with undo
reaching back across sessions. The file is correct throughout (✕ rewrote it;
a redo re-dirties and autosaves). If review wants ✕ to be final, the fix is an
ssm addition — see "Risks and open items".

## Testing

Swift Testing, against the existing fakes (`EditorTests/Support/Fakes.swift`),
with a `FakeScoreEditHistoryStore` recording calls.

**Gate (must stay green):** the Step 1 suite list above, in particular
`EditorSessionEndModeTests` and `EditorViewModelRevertTests`.

**New, Step 1:** intent construction per op — for each of the 25 call sites,
the op records the expected intent (this is the test style the intent seam
buys); the letter-on-chord-upper-note case; `appendTiedNote`'s composite
including the cross-barline shape.

**New, Step 2:**

- close and reopen a session on the same item → undo still works, and undoes
  the previous session's edit;
- a changed `contentHash` between sessions → fresh session, no history;
- ✕ / discard unwinds only this session's edits, leaves an earlier session's
  edits intact and still undoable, and (signed depth) redoes back to session
  start after a net-negative session;
- LRU: a fourth deposit evicts the least-recent; `invalidate` empties the
  entry; checkout removes the entry (a second concurrent `session(for:)`
  returns nil);
- a failed final save does not deposit;
- `revertToOriginal` invalidates;
- `ProcessScoreEditHistoryStore` unit tests in `Tests/FolinoTests`, including
  the memory-warning sweep.

## Risks and open items

- **Additions beyond the agreed design, called out for review:** (1) the
  memory-pressure sweep; (2) the signed `sessionEditDepth` — the agreed text
  said the value is "usable as-is", which the investigation confirms *except*
  for the `max(0, …)` clamp at `EditorViewModel.swift:284` and the `> 0` read
  at `:50`, which must change for undo-below-session-start to be discardable;
  (3) "deposit only when clean and non-empty" as the failed-save rule.
  None contradicts an agreed decision; all three fill gaps the agreed text
  left open.
- **The agreed pass condition "existing test suites stay green unchanged"
  needs one nuance:** four test files construct `EditCommand`s directly as a
  seeding shorthand and get a mechanical retarget to intents (assertions
  untouched). Suites driving the public ops are the unchanged gate.
- **Call-site count:** 25, not the ~22 in the agreed text. Same set, better
  count; three were the shared cross-bar/retime helpers counted once.
- **Optional ssm addition, only if review rejects redo-after-discard:**
  `ScoreEditSession.discardRedoHistory()` (empties `ScoreEditor.redoStack`;
  ~5 lines). Nothing in Steps 1–2 needs it; naming it now because ssm changes
  ride their own release cadence and must be flagged early. The prior
  memory-note's assumption that route A "needs an ssm API addition" is
  otherwise **not confirmed** — everything required ships in the pinned
  1.15.0.
- **Memory figures are computed, not measured.** Struct strides were estimated
  from the field lists of `Note` and `Chord`; if the real numbers matter, a
  one-off `MemoryLayout` dump in the ssm dev clone settles them. The cap has
  an order-of-magnitude margin either way.
- **`.writeNote` note-index divergence** (Step 1 risks) — settled by the new
  test either as "index 0 is correct" or as a narrow host-side branch.

## Implementation order

1. **Step 1, mechanical:** swap `ScoreEditor` for `ScoreEditSession` in
   `EditorViewModel`, add `apply(_ intent:)`, migrate the 25 call sites and
   the four test files' seeding calls, delete the dead planning. Pass: gate
   suites green + no `EditCommand` construction left in the Editor package.
2. **Step 1, verification:** the new intent-construction tests and the
   chord-note-index test.
3. **Step 2, store:** Domain protocol, App concrete + unit tests, Noop for
   previews, wiring through `AppBootstrap` / `AppShellView` /
   `EditableReaderScreen`.
4. **Step 2, session lifetime:** adopt in `beginSession`, deposit in
   `endSession`, signed depth + count-driven unwind, revert invalidation, the
   bridge trampoline on adoption, and the Step 2 tests.

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
looked plausible resolve host-side; see "Two host-side compensations". A
third place — redo of a discarded session — is named under "Risks and open
items", with the exact signature it would have needed, for the case where
review rejected the default reading. Review did reject that default (see the
corrected "redo survives deposit" paragraph under "Existing code that must
change"), and the addition still was not needed: ✕ is implemented entirely
host-side, by suppressing the deposit rather than by trimming ssm's redo
stack.

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

**As shipped, the caret-landing claim above needs a narrower reading.**
Dropping the explicit `select(.rest(…))` does not mean the caret always stays
exactly where it was. `rederiveSelection()` compares the pre-mutation caret
and selection slots against `lastAffectedLocation` (the collapsed rest's slot,
always `elementIndex 0` of its voice-measure) and only takes the "keep this
marker, follow the other" branch when one of them already sat at that slot —
true precisely when the deleted note was the *leading timed element* of its
voice-measure. In every other case (deleting a later element that happens to
empty the bar) both branch checks fail, `rederiveSelection()` falls through to
`select(affected)`, and the caret lands on the collapsed rest exactly as the
old explicit `select(.rest(…))` did. The dropped call was redundant only for
the leading-element case.

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

   **As shipped, that single code path is gated, not unconditional.** Walking
   `TiePlanner.tieChain(containing:)` after every apply would overshoot for an
   in-bar overwrite of a note that is already tied to something else — the
   chain-walk landing belongs only to a write that itself crossed the bar. The
   host decides `crossesBar` **before** applying, against the pre-edit score
   (`CrossBarInputPlanner.fitsInMeasure(_:at:in:)`), and calls
   `chainTail(from:in:)` only when that predicate is true; an in-bar write
   takes the plain `land(after:)` path unconditionally, exactly as before this
   design (`EditorViewModel+Input.swift`'s `inputPitch(letter:onRest:)` and
   `inputPitch(letter:onNote:)`).
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

  **As shipped: it settled as the narrow host-side branch.** A caret on a
  chord's upper notehead (`noteIndexInChord != 0`), reached by adding a note
  and then typing a letter to fix it, takes `.setNotePitch` (composited with
  `.setChordDuration` when a length is armed, since `.setNotePitch` alone
  never re-times) instead of `.writeNote`, which would re-pitch notehead 0.
  The barline case is the one exception: any note index takes `.writeNote`
  there, because the pre-intent code already collapsed the chord to a single
  note before the write crossed the bar, which is exactly what `.writeNote`
  plans. The divergence carries a `PARITY(android)` marker
  (`EditorViewModel+Input.swift`) — Android's `.writeNote` path still
  re-pitches notehead 0 unconditionally.
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

**As shipped, this reads the other way: ✕ ends all retained history for the
score, redo included.** The agreed text below argued for the opposite —
letting the deposited session redo what ✕ just discarded, as the exact inverse
of undo reaching back across sessions — and was overridden by a controller
ruling once the two contracts sat side by side: `main` had already shipped "✕
discards the session" (commit `15bcde6f`) as the button's own promise, and a
redo that resurrects the discarded edit one session later breaks that promise
rather than honoring it symmetrically. `discardSessionEdits()` sets
`didDiscardSession = true` and calls `historyStore.invalidate(scoreItem.id)`;
`endSession()`'s `depositSessionIfWorthKeeping()` is guarded by
`!didDiscardSession`, so nothing is retained for the next session to redo from
— the same contract as an app kill. No ssm addition was needed for this; the
"Optional ssm addition" item below is now unnecessary in full, not merely
deferred.

*(Superseded reasoning, kept for context: one consequence was accepted as
designed rather than patched — **redo survives deposit, including after ✕.**
`unwindSessionEdits` walks back via `undo()`, which populates the redo stack;
the deposited session therefore lets the next session redo what ✕ discarded.
This was read as the consistent choice — *all* history survives, and redo is
the exact inverse of the discard, symmetric with undo reaching back across
sessions. The file was correct throughout either way (✕ rewrote it; a redo
re-dirties and autosaves). This is the reasoning the ruling above overrides.)*

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
- ✕ / discard unwinds only this session's edits — (signed depth) redoing
  forward to land on the session-open score when the undo reached below this
  session's start, so an earlier session's edit is intact in the score — and
  then ends **all** retained history for the score: `historyStore.invalidate`
  fires, the exit's `endSession()` does not deposit, and the next
  `beginSession()` on that score finds no undo at all;
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

  **As shipped: not needed, at all.** Review took the ✕-is-final reading (see
  the "redo survives deposit" correction above under "Existing code that must
  change"), which the host implements entirely on its own side by suppressing
  its own deposit — `discardRedoHistory()` was never added, and no other part
  of this design needed an ssm change either. Every required surface shipped
  in the pinned 1.15.0, exactly as the second sentence above already said.
- **Memory figures are computed, not measured.** Struct strides were estimated
  from the field lists of `Note` and `Chord`; if the real numbers matter, a
  one-off `MemoryLayout` dump in the ssm dev clone settles them. The cap has
  an order-of-magnitude margin either way.
- **`.writeNote` note-index divergence** (Step 1 risks) — settled by the new
  test either as "index 0 is correct" or as a narrow host-side branch.

## Manual verification on device

For a human on a physical device — no automated test reaches any of these. Do
them roughly in this order: later items build on state the earlier ones leave
behind (multiple retained sessions, etc.).

1. **Headline flow — undo reaching back into a previous session.**
   Open a score, edit one note, tap ✓ to end the session, immediately re-enter
   editing on the same score. **Expect:** the undo button in the top bar is
   live (not greyed out) on entry, before making any new edit; tapping it
   undoes the previous session's edit; tapping redo brings it back; tap ✓
   again and re-enter a third time — the edit (or its absence, depending
   where you left it) is still there and undo/redo still reach across that
   boundary too.
   **Failure looks like:** undo is dead (greyed out) immediately after
   re-entry — the deposit or the adopt didn't happen, i.e. `endSession()`
   didn't retain, or `beginSession()` didn't find the entry (most likely a
   `contentHash` mismatch that shouldn't be there, or the store never got
   wired through `AppBootstrap` → `AppShellView` → `EditableReaderScreen` →
   `EditorViewModel.init`).

2. **`contentHash` guard — an out-of-band change drops history.**
   End a session on a score with retained undo history (state from step 1).
   Outside the app, change the file (or, if that's not convenient in this
   build, use whatever path is easiest to force a re-import / version restore
   / PDF re-read on that same score — anything that rewrites the row's
   `contentHash`). Re-enter editing on that score. **Expect:** undo is dead —
   a fresh session, no history, and no crash or stale-content flash.
   **Failure looks like:** undo is live and undoing produces a score that
   doesn't match what's on screen (the adopted session's `score` no longer
   agrees with the bytes just loaded) — that's the hash guard silently not
   firing, and the two would visibly diverge as soon as you look.

3. **✕ is final — no undo, no redo, on re-entry.**
   Edit a note, tap ✕, confirm the discard. Re-enter editing on the same
   score. **Expect:** undo is dead AND redo is dead; the discarded edit is
   gone from the score (matches what it was before this session) and there is
   no way to bring it back via the top bar or the gesture.
   **Failure looks like:** either button is live, or undo/redo brings the
   discarded edit back — that's the pre-Task-9 spec behavior (redo survives
   deposit) resurfacing, i.e. `didDiscardSession` isn't being set or isn't
   gating the deposit, or `historyStore.invalidate` isn't being called.

4. **Undo below session start, then ✕ — the session-end control turns yellow
   and reverts correctly.**
   Re-enter a session after a committed edit exists (so there's something to
   undo into). Undo past the session's own start, into the earlier committed
   edit. **Expect:** the session-end control (✓/revert) turns yellow/edited,
   signaling this session has net-changed the score even though nothing new
   was typed. Then tap that control to discard. **Expect:** the score returns
   to exactly what it was when *this* session opened — the earlier edit is
   back in place (the net-negative depth correctly redoes back to session
   start rather than leaving the score at the undone-past-start position).
   **Failure looks like:** the control stays looking "clean" after undoing
   past session start (the signed-depth / `sessionHasEdits` check reads
   `== 0` instead of `!= 0`), or discarding leaves the score at the wrong
   point (the count-driven unwind redoes the wrong number of times, or in the
   wrong direction, for a negative `sessionEditDepth`).

5. **Three-finger-swipe system-undo gesture reaches an *adopted* session's
   history.**
   Re-enter a session that has adopted history from a previous session (state
   from step 1 or step 4, before making any new edit in this fresh session).
   Immediately perform the three-finger-swipe-left system-undo gesture (no
   tap on the on-screen undo button first). **Expect:** it undoes the earlier
   session's edit, exactly like tapping the top-bar undo button would.
   **Failure looks like:** the gesture does nothing on first try (feels
   unresponsive) but the top-bar undo button works fine — that's the Task 8
   trampoline not being armed at session start when the adopted session
   already `canUndo`; the gesture only starts working after the first *new*
   edit in this session re-registers it normally. This is the one behavior in
   this whole feature that no unit test can reach, so it's the highest-value
   item on this list.

6. **Revert to original ends history.**
   On a score with edits (retained or live), use revert-to-original. Re-enter
   editing on that score afterward. **Expect:** a fresh session, no undo
   available at all.
   **Failure looks like:** undo is live after revert and undoing produces
   something other than the original — `revertToOriginal()`'s call to
   `store.invalidate(scoreItem.id)` isn't firing, or isn't firing before the
   next `beginSession()` reads the store.

7. **A fourth score evicts the first (LRU cap 3).**
   Pick four different scores (small ones for speed). For each, in order:
   open, make one edit, tap ✓. After the fourth, re-enter editing on the
   *first* score. **Expect:** no undo — its retained session was evicted when
   the fourth was deposited.
   **Failure looks like:** undo is still live on the first score after a
   fourth deposit (cap isn't 3, or isn't being enforced), or — the opposite
   mistake — undo is *also* gone on the second or third score (over-eager
   eviction, or the checked-out/re-deposit bookkeeping is dropping entries it
   shouldn't).

8. **Memory warning sweeps deposited sessions, but not an open one.**
   Edit-and-✓ one score (so it has a deposited session). Trigger Device ▸
   Simulate Memory Warning (or the device-equivalent trigger the build under
   test supports). Re-enter editing on that score. **Expect:** no undo — the
   deposited entry was swept. Separately: open a *different* score for
   editing, make an edit (session live, not yet ended), trigger the memory
   warning while still inside that session, and confirm the open session is
   unaffected — undo is still live for edits made in that still-open session,
   and finishing it normally (✓) still deposits.
   **Failure looks like:** the open session's own undo history is wiped by
   the warning (the store reached into a session it doesn't own — it should
   only ever touch its own `entries` array, never a checked-out session), or
   conversely the deposited entry from the first score survives the warning
   (the `NSObject` notification observer isn't wired, or
   `handleMemoryWarning` isn't clearing `entries`).

9. **iPad split-view double-open of the same score.**
   On iPad, open the same score for editing in two separate split-view
   windows. **Expect:** no crash; the second window's editor starts a fresh
   session (since the store's `session(for:contentHash:)` checks the entry
   out — only one owner at a time); the two windows do not share one mutable
   stack, so edits in one don't silently appear or corrupt the other.
   **Failure looks like:** a crash on the second open, or the second window
   inexplicably shows edits made in the first (two `EditorViewModel`s holding
   the same `ScoreEditSession` instance).

10. **Editing feel unchanged — spot check on the whole Step 1 migration.**
    On any score, run a normal write/delete/tie/tuplet session: type a few
    notes, delete one (including at least one delete that empties a bar so
    the full-measure-rest collapse fires), tie two notes together, create and
    remove a tuplet, cross a barline with a long note. **Expect:** every one
    of these feels exactly as it did before this design (this is the whole
    point of Step 1's intent migration having a green gate) — correct
    pitches, correct caret advancement, correct tie chains, no stutter or
    visible glitch.
    **Failure looks like:** anything subtly off that unit tests wouldn't
    catch — e.g. caret landing one slot early/late after a cross-bar write
    (item 3's compensation misfiring), or a chord's upper notehead
    re-pitching the wrong note (item 5's `.writeNote`/`.setNotePitch` fork
    misrouting).

## Implementation order

1. **Step 1, mechanical:** swap `ScoreEditor` for `ScoreEditSession` in
   `EditorViewModel`, add `apply(_ intent:)`, migrate the 25 call sites and
   the four test files' seeding calls, delete the dead planning. Pass: gate
   suites green + no `EditCommand` construction left in the Editor package.

   **As shipped, this single step landed as four tasks**, not one commit:
   first, a transitional, verbatim host-side transcription of ssm's own
   planning behind the *same* `apply(_ intent:)` seam (so nothing downstream
   of it had to change twice), migrating the first slice of call sites onto
   it; then two further call-site slices migrating the rest; then the engine
   swap that deleted the transcription and handed planning to
   `ScoreEditSession` for real. The gate suite stayed green at that final
   engine-swap commit on the first run — the transitional transcription and
   ssm's actual planner produced identical behavior across all 181 tests,
   which is the practical proof that Folino's duplicated planning and ssm's
   had already converged before this design started.
2. **Step 1, verification:** the new intent-construction tests and the
   chord-note-index test.
3. **Step 2, store:** Domain protocol, App concrete + unit tests, Noop for
   previews, wiring through `AppBootstrap` / `AppShellView` /
   `EditableReaderScreen`.
4. **Step 2, session lifetime:** adopt in `beginSession`, deposit in
   `endSession`, signed depth + count-driven unwind, revert invalidation, the
   bridge trampoline on adoption, and the Step 2 tests.

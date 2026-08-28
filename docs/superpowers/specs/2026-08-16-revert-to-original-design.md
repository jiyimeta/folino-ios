# Revert to original — design

2026-08-16. Keeps the bytes a score arrived with, and gives the user a way back
to them after note editing, the way Photos keeps a photo's original behind an
edit.

## The problem

Note editing is destructive today. `EditorViewModel.performSave()`
(`Packages/Features/Editor/Sources/Editor/EditorViewModel+Persistence.swift`)
is the single write choke point, debounced two seconds after the last mutation,
and `saveDestination(for:scoresDirectory:)` sends the result to one of two
places:

- `.mscx` / `.mscz` sources are **overwritten in place**. The bytes the user
  imported are gone the moment the first autosave fires.
- MusicXML / MXL / MIDI sources are written as a sibling `<stem>.mscz` and
  `localFileName` switches to it. The source file survives on disk, but nothing
  references it any more, and `LiveScoreLibraryRepository.filesBackingRow`
  lists only `localFileName` and `sourcePDFFileName` — so permanently deleting
  the item leaks it. That orphan is an accident, not a feature.

The only way back is `ScoreEditor`'s undo stack, which lives in memory and is
dropped when the editing session ends. There is no cloud copy either:
`Packages/Infrastructure/Sources/CloudSync` is a placeholder.

One corner of the app already does better. A PDF-origin item keeps its original
PDF as a sidecar (`ScoreItem.sourcePDFFileName`), can display it instead of the
notation (`ReaderDisplaySource.originalPDF`), knows whether the notation has
drifted from what the conversion wrote
(`ScoreItem.isPDFDerivedScoreEdited`), and guards a destructive re-read behind
`PDFReparsePolicy`. This design generalises that shape to every format.

## What this covers, and what it does not

**In scope.** Preserving the import-time bytes of every score, and restoring
them on request.

**Deliberately out of scope.**

- A revision history. There is exactly one restore point per item: the
  original. Restoring to an arbitrary earlier state belongs to the follow-up
  spec.
- Reverting handwriting annotations, tags, favourites, playlists, or per-score
  preferences. The score file's contents are what revert replaces; everything a
  user accumulated around the score survives. Score info (title, composer, …)
  is the one exception, and only when the user asks for it explicitly — see
  "Entry points".
- Partial revert (a measure range, one staff). Whole score only.
- **A dedicated revert item on the Library's row menu itself.** That list gains
  no new entry. The score-info sheet — itself reachable from that same row
  menu, via the existing "楽曲情報" item — does carry revert; see "Entry
  points".

**A follow-up spec** will route iOS editing through swift-sheet-music's
`EditIntent` and persist the intent log, giving undo/redo that survives a
session. This design must not force that to be redesigned; the seams it needs
are called out under "Forward compatibility".

## Storage model

The original is kept **wholesale, as bytes, in a sidecar file**. Not a revision
table, not a log of inverse commands.

An inverse-command log was considered and rejected as the *guarantee*. Replay
depends on swift-sheet-music's planners, whose behaviour does change across
versions — accidental renotation changed recently — so the same log can produce
a different score after a dependency bump. "You reverted and did not get your
file back" is the one failure this feature cannot have. Bytes cannot drift.
(The log is still worth having, for history; see "Forward compatibility".)

### Files

The sidecar lives flat in the scores directory, beside the score:

```
<id>.mscz              the item's current bytes  (localFileName)
<id>.original.mscz     the bytes it was imported with
<id>.pdf               the original PDF, for PDF-origin items (unchanged)
```

`ScoreFormat.detect(filename:)` reads only the last extension, so
`<id>.original.mscz` detects as `.mscz` and needs no parser change. The
`localFileName == "<id>.<canonical-extension>"` convention is untouched,
because the sidecar never becomes `localFileName`. The only code that
enumerates the scores directory is the importer's staging sweep, and duplicate
detection is a hash query against the database, so neither notices a new file.

A subdirectory (`Originals/`) was considered and rejected: it introduces a
second path convention and prevents no failure the flat layout allows.

**For a MusicXML / MXL / MIDI source there is no copy.** The first save writes
a *new* path, so the source file is never overwritten — and cannot be, since
`LiveScoreFileGateway.saveScore` throws `unsupportedFormat` for those formats.
The existing `<id>.musicxml` is registered as the original where it already
sits. This also retires the orphan leak described above: once the file is named
by a column, `filesBackingRow` deletes it with the row.

The column therefore holds *a filename*, not a naming pattern — the same
contract `sourcePDFFileName` already has.

### Columns

Three new columns on `score_items`, added by migration v18 in its own
`Migrations+V18.swift` (`Migrations.swift` is at 286 lines against SwiftLint's
400-line cap; v16 and v17 set the precedent of one file per migration):

| Column | Meaning |
| --- | --- |
| `original_file_name` | The sidecar's filename, or `NULL` when nothing has been captured yet. |
| `original_content_hash` | SHA-256 of the sidecar's bytes, in the importer's hex-digest format. |
| `original_provenance` | What the sidecar's bytes actually are — see "Provenance". |

`original_content_hash` earns its place three times over: it verifies integrity
on restore, it answers "is this item revertible" (current hash differs from it)
without touching disk, and it extends duplicate detection.

`ScoreItem` gains the three matching properties, `ScoreItemRecord` the three
column mappings, and **`filesBackingRow` gains `original_file_name`** — without
that line, permanent delete and the 30-day prune leak the original.

## Capture

The original is captured **lazily, exactly once per item, immediately before
the first write that would overwrite it**, inside `performSave()`.

Capturing at import would pay storage for every score the user never edits.
Capturing at `beginSession` would fire for a session the user opens and leaves
without touching a note. The first write is the moment the bytes are actually
at risk, and — critically — it is the last moment they are still the import
bytes: score-info editing writes only the database row
(`LibraryViewModel.saveMetadata`), never the file.

### The sidecar's existence is the only marker

The condition for "already captured" is **the sidecar file being on disk**, not
a database flag, and not any per-session state.

Per-session state cannot work: `isDirty` and `autosaveTask` live on the view
model instance, so they say nothing about whether this item was overwritten in
some earlier session.

A database flag introduces a two-phase failure. With the order *copy → write
the score → update the row*, a kill between the write and the row update leaves
the flag clear, and the next first-write check would copy the **already-edited**
bytes over the real original and destroy it. Keying off the file removes the
phase entirely: whatever step a crash interrupts, the score file is still
pristine until the write lands, so a re-capture is always correct.

So the capture step is: if `<id>.original.<ext>` exists, do nothing; otherwise
copy the current score file to a scratch path and atomically rename it into
place, then proceed with the save. The database columns are written on the same
row update as the rest of the save, and are a cache of what the file already
says.

Copying is cheap: APFS makes `FileManager.copyItem` a clone, so the capture
costs no space until the two files diverge. Laziness is about not littering
sidecars beside scores nobody edits, not about copy cost.

### Editing and undoing back to the start does not restore the original

`EditorViewModel.undo()` sets `isDirty = true` and schedules a save, so a user
who makes an edit and undoes it still writes the file — re-encoded by
swift-sheet-music's writer, which is not byte-identical to what MuseScore
produced. The item is captured, and reports itself as edited, even though the
notation matches. This mirrors Photos, where entering and leaving the editor can
mark a photo edited, and it is stated here so it is not read later as a bug.

### Other writers of the score file

`performSave()` is not the only writer. Two PDF paths also write `<id>.mscz`:

- the conversion on first open (`ReaderViewModel+PDFConversion` →
  `PDFScoreConverter`), which creates the file rather than overwriting notation
  a user made;
- **re-reading the PDF** (`ReaderViewModel+PDFReread.swift`), which replaces the
  whole file. That one interacts with this design and is handled next.

The importer only ever writes new files, and the share service and the
VocalTuner hand-off are read-only.

## PDF-origin items

No special case is needed for capture. Between the conversion and the first note
edit, `contentHash == pdfDerivedContentHash` — that equality *is* the definition
of "not edited" in `ScoreItem.isPDFDerivedScoreEdited`. So the bytes the lazy
capture finds immediately before the first write are exactly the conversion's
output, which is the right thing to revert a PDF-origin score to.

**Re-reading the PDF invalidates the sidecar.** A re-read replaces the notation
with a fresh parse, so a sidecar captured against the previous parse is no
longer "the original" of anything the user can see. On a successful re-read the
sidecar is deleted and the three columns cleared, in the same row update that
`reReadPDF()` already performs; the next edit captures the new conversion's
output. Delete-and-recapture is preferred to updating the sidecar in place
because it has no failure mode of its own — the invariant is simply "the
sidecar, if present, is the baseline of the current parse".

**Two originals must never be called the same thing.** A PDF-origin item has the
original PDF and the score as folino first read it. The user's mental model is
that the PDF is the source, the notation is folino's reading of it, and their
edits sit on top; the labels mirror that hierarchy rather than offering
"original" twice:

- the editing toolbar offers only *revert my edits* — worded as returning to
  the state right after folino read the PDF;
- re-reading the PDF stays where it is, in the score-info sheet, under its own
  wording.

## Revert

Restoring writes the sidecar's bytes back over the item's file and brings the
row into agreement with them.

### What changes

- **`contentHash`, `sizeBytes`** — recomputed from the restored file (or taken
  from `original_content_hash`, which must match; a mismatch aborts the
  revert). **This check runs before any file is created, overwritten, moved,
  or deleted** — the sidecar (or the adopt-target, in the sibling case) is
  hashed and compared against `original_content_hash` first, and only once it
  agrees does the swap-in / sibling-delete happen. Checking after the
  destructive step would mean a corrupted sidecar is discovered only once the
  user's edit and the backup were both already gone — the exact failure this
  feature exists to prevent, restated as its own implementation bug.
- **`localFileName`, for a MusicXML / MXL / MIDI item** — restored to
  `<id>.musicxml` (etc.), and the sibling `<id>.mscz` is deleted. Restoring the
  actual source file is the only byte-exact answer; re-encoding it back through
  MuseScore's writer would not be. The row lands in exactly its post-import
  state.
- **`lengthBeats`, `defaultTempoBpm`, `primaryKey`, `instrumentationSummary`** —
  re-derived from a parse of the restored file, **always**, regardless of the
  score-info choice below. These describe the notation, so leaving them
  describing the edited version would be simply wrong. Unlike
  `ScoreItem+PDFConversion`'s `rebuilt`, this is a replacement rather than a
  `summary?.x ?? x` merge.
- **`title`, `subtitle`, `composer`, `arranger`, `lyricist`, `copyright`** —
  only when the user asks, and only from the score-info entry point. These are
  the fields `saveMetadata` writes, and the machinery to read them back out of a
  file already exists: `ScoreMetadataReading.readMetadata(for:)` plus
  `EditableScoreInfo(item:fileMetadata:)`, pointed at the sidecar.
- **The columns are cleared, and the sidecar is deleted where it is still a
  sidecar.** The item returns to its "never edited" state and the next edit
  captures again; keeping the sidecar would raise the question of what the
  original of an original is. In the sibling case there is nothing to delete —
  the original file has just become `localFileName` again, and it is the
  `.mscz` that goes.

### What does not change

- **Per-score preferences are not reset.** PDF re-read resets score-bound
  overrides because a better parse can renumber staves, invalidating an override
  that names a staff by index. Revert is the opposite motion: it restores the
  very staff numbering the overrides were authored against. The current editor
  is note entry only — it cannot add or remove staves or parts — so overrides
  authored *after* the edits are equally valid against the restored score. This
  reasoning depends on that limitation; if the follow-up spec brings structural
  editing, revisit it.
- **Handwriting annotations survive**, including musically-anchored ink.
  `MusicalAnchor` addresses a measure and a tick within it, so a stroke written
  against an edited passage can land somewhere else after the revert. The
  confirmation says so. Erasing a user's annotations to spare them an offset is
  the worse failure — the same call `reReadPDF` already makes.
- **PDF-origin fields are untouched.** Reverting to the conversion output
  restores `contentHash == pdfDerivedContentHash`, so
  `isPDFDerivedScoreEdited` becomes false on its own.

### Tearing down the edit session

Revert invoked from the editing toolbar must **not** go through
`EditorViewModel.endSession()`, which calls `flushPendingSave()` and would write
the very edits being discarded before discarding them. The revert path cancels
the pending autosave, clears `isDirty`, and drops the editor. The system
`UndoManager` trampoline needs no handling: it guards on `editor.canUndo` and
goes inert once the editor is gone.

Afterwards the reader reloads exactly as `reReadPDF` does — stop playback,
`await load()`.

### Atomicity

The in-place case follows the scratch-swap `reReadPDF` already uses: copy the
sidecar to a scratch path, `replaceItemAt` it over the score, update the row,
then delete the sidecar. A kill between the swap and the row update leaves the
file restored and the row's hash stale. That is the benign direction — the file
is what the reader opens, so the user sees their original and loses nothing; the
stale hash only mis-answers "is this edited" and duplicate detection, and heals
on the next save or revert. Doing the row first would produce the opposite,
worse state: a row claiming the original while the file still holds the edits.
Start-up reconciliation is not worth building for this.

The sibling case needs no swap at all — the original file has been sitting
untouched since import.

**As shipped, the order is the other way round: `LiveScoreOriginalStore`
deletes the `.mscz` inside `restoreFile` — before the caller (the Editor, the
Reader, or the Library) writes the row.** A crash between the delete and the
row write leaves the row still naming the deleted `.mscz` as
`localFileName`, pointing at nothing. This is the same direction of failure
the in-place case's "doing the row first" paragraph above calls worse — a row
claiming a state the file does not yet reflect — but here it is the shipped
behavior for the sibling case, not a hypothetical being rejected. It was
ruled acceptable to leave as shipped, for two reasons: the state is
recoverable rather than terminal (retrying the revert re-runs
`RevertPolicy.filePlan(for:)` against the still-unchanged row, resolves the
same `adoptExistingFile` plan, finds the adopt-target still on disk, and
succeeds — deleting an already-deleted `.mscz` is a no-op), and reordering
`LiveScoreOriginalStore.revertToOriginal` to return the restored facts
*before* deleting the sibling, so every caller writes the row first, is an
API-shape change this feature's final fix wave judged riskier than the
narrow, recoverable window it would close. A future change to
`LiveScoreOriginalStore` that touches this path should close the gap
properly rather than re-affirm it.

## Provenance

`original_provenance` records what the sidecar's bytes are, so the confirmation
dialog can be honest without being uniformly pessimistic:

| Value | Meaning |
| --- | --- |
| `importTime` | Captured by this feature, or recovered by the migration as genuinely untouched import bytes. |
| `conversionOutput` | The score exactly as the PDF conversion wrote it. |
| `legacyUnknown` | Captured from a pre-existing row that may already have been edited before this feature shipped. |

Note editing shipped on 2026-07-27, so few rows can be affected — but "few" is
not "none", and a dialog promising the import-time file must not lie. The
migration classifies pre-existing rows rather than stamping them all unknown:

- `localFileName` still `.musicxml` / `.mxl` / `.mid` → the editor has never
  saved this item (a save would have switched it to `.mscz`). The file is
  import-time; register it, `importTime`.
- `localFileName` is `<id>.mscz` and an orphan `<id>.musicxml` (or `.mxl` /
  `.mid`) sits in the scores directory → that orphan is the untouched import
  file. Register it, `importTime`. This doubles as the cleanup of the existing
  leak.
- PDF-origin with `contentHash == pdfDerivedContentHash` → unedited conversion
  output. No sidecar is written; the lazy capture will take it at the first
  edit, and it will be `conversionOutput`.
- `.mscx` / `.mscz` imports → genuinely unknowable. No sidecar, but the
  migration writes `original_provenance = legacyUnknown` on the row ahead of any
  capture, with `original_file_name` still `NULL`. That pre-stamp is how the
  capture, running possibly months later, knows this row predates the feature.

Only the last group ever sees the caveat, and only until they revert once.

Capture therefore resolves provenance as: keep a value the migration already
wrote; otherwise `conversionOutput` when `pdfOriginState == .converted`, and
`importTime` for everything else.

**Orphan recovery happens at capture time, not in the migration.** Migrations
run from `AppDatabase.init(databaseURL:)`, which receives only a `Database` —
it has no scores directory to scan. So the second bullet above (`.mscz` with an
orphan `.musicxml` / `.mxl` / `.mid` sibling) is not a migration-time scan at
all: it is folded into the same lookup the lazy capture already does. When
`performSave()`'s capture step runs, the caller offers any same-stem
non-MuseScore source file it finds on disk, and adopting one is treated as
authoritative evidence of `importTime`, exactly as if the migration had
pre-stamped it. The migration itself only ever pre-stamps the fourth group
(`legacyUnknown` on `.mscx` / `.mscz` imports); it performs no directory I/O.

## Duplicate detection

Importing a file whose score has since been edited currently slips past
duplicate detection, because the row's `contentHash` no longer matches the file.
`LiveScoreLibraryRepository` already solves this for PDFs by OR-ing
`source_pdf_content_hash` into the query; `original_content_hash` joins the same
condition. Re-importing a file you have already imported and edited is
recognised as a duplicate.

## Where the logic lives

Every decision is a pure function in Domain, so Android calls the same code when
its note editing grows a save choke point (SP4):

- whether a capture is needed, and what the sidecar should be named;
- the revert plan — which file goes where, which fields are replaced;
- `RevertPolicy`, shaped exactly like `PDFReparsePolicy`: whether the revert has
  to ask first, given musical annotations and provenance.

Infrastructure does the file I/O and the row write. The iOS UI carries a
`// PARITY(android):` marker.

Wiring note: revert does **not** live beside `reReadPDF` in the Reader. It
lives in Infrastructure (`LiveScoreOriginalStore`) behind the Domain protocol
`ScoreOriginalStore`, and both the Reader and the Library conform their own
view models to the relevant sheet-facing protocol against that same store.
The reason is the score-info sheet: it is presented from the Library as well
as the Reader, so putting the operation on `ReaderViewModel` would either
duplicate it or make the sheet behave differently depending on where it was
opened. The editing toolbar's entry point (which *does* live only in the
Reader-hosted Editor) reaches the same store through a closure seam the App
composition root connects — the same pattern the Editor's other host
callbacks already use, because Feature → Feature is forbidden.

## Entry points

**Editing toolbar** (`EditorChromeView+Toolbar.swift`, trailing overflow) —
"revert my edits". Hidden entirely when no sidecar exists, i.e. when the item
has never been edited. Goes through the confirmation dialog, which names what is
discarded (note edits only), warns that musically-anchored ink may shift, and
adds the provenance caveat for `legacyUnknown`.

**Score-info sheet** (`Packages/ScoreUI/Sources/ScoreUI/EditScoreInfoSheet.swift`)
— the same action, plus a choice of whether score info is restored from the
original file too. For a PDF-origin item this sits beside the existing "read the
PDF again", each with wording that says which of the two originals it means.
Because this sheet is presented from wherever `ScoreInfoEditing` is wired —
the Reader and the Library both — the entry point appears in both places
score info can be opened, including from the Library's row menu. The Library
*row menu's list view* still has no revert item of its own; that remains out
of scope, per "What this covers, and what it does not" above. And because the
Library does not load annotations, the sheet's confirmation cannot know
whether ink actually exists to be affected — its warning is worded as a
possibility ("handwriting anchored to the notation *may* move") rather than
measured, unlike the editing toolbar's confirmation, which is presented from
the Reader and therefore does know.

## Known limitations

**iPad split view.** The score-info sheet's entry point being reachable from
both the Library and the Reader (see "Entry points") creates one case this
design does not close: on iPad, the Library and the detail Reader can be
showing the same score at once in split view. Reverting from the Library's
score-info sheet writes the file and the row correctly, but the Reader
instance already has that score loaded in memory — its copy may still include
the edits the revert just discarded. If the user then starts editing from
that stale Reader, the Editor's own capture would take the *restored*
original as its new baseline and then immediately overwrite it on save with
the stale in-memory score, quietly re-creating the edits the user just
reverted. The Reader picks up the restored file correctly the next time it is
opened fresh; the hazard is confined to a Reader instance that was already
open across the revert.

Closing this properly needs a change-notification path from the repository to
an open Reader instance, which does not exist today and is a larger change
than this feature. It is recorded here as known, deliberately deferred
behavior rather than a bug to fix as part of this design.

## Testing

- **Byte equality.** Import → edit → revert leaves the file's SHA-256 equal to
  `original_content_hash` and to the imported file's own digest. Run for
  `.mscz`, `.mscx`, and MusicXML.
- **Capture idempotence and crash ordering.** A second save does not re-capture.
  Simulating a kill after the score write but before the row update, then saving
  again, leaves the sidecar holding the *import* bytes — this is the failure the
  file-as-marker rule exists to prevent, and it is what a database flag would
  get wrong.
- **Sibling round trip.** MusicXML → edit → revert restores `localFileName` to
  `.musicxml`, deletes the `.mscz`, and leaves the row equal to its post-import
  state.
- **PDF interaction.** A re-read clears the sidecar and columns; the next edit
  captures the new conversion output; reverting a PDF-origin item restores
  `contentHash == pdfDerivedContentHash`.
- **Deletion.** Permanent delete and the 30-day prune remove the sidecar
  (`filesBackingRow`).
- **Migration v18.** One row per provenance class, following `MigrationV16Tests`,
  including an orphan-`.musicxml` row that must be recovered as `importTime`.
- **Domain policies.** `RevertPolicy` and the revert plan as pure-function unit
  tests.

## Forward compatibility with the intent-log spec

Three decisions are made here so the follow-up does not force a redesign.

1. **The columns mean "revert baseline", not "backup".** When the intent log
   arrives, the sidecar is the log's replay base and `original_content_hash`
   verifies that base before a replay.
2. **Revert is a truncation of the log, not an operation within it.** Recording
   revert as an intent would leave replay carrying pre-revert intents that no
   longer compose with the base. Revert clears the log and returns to the
   baseline.
3. **Provenance is not derivable from the log.** The log only exists for items
   edited after it ships, so pre-existing rows still need
   `original_provenance`. The two must not be collapsed.

Because capture sits at `performSave()`, the log's writes will pass through the
same choke point. No further anticipation is needed.

## Implementation order

Three phases, each independently verifiable.

1. **Capture.** Columns, migration v18 with provenance classification and orphan
   recovery, the capture step in `performSave()`, `filesBackingRow`, duplicate
   detection. No user-visible change beyond the leak being fixed. Passes when
   the byte-equality and crash-ordering tests are green.
2. **Revert, from the editing toolbar.** The Domain plan and `RevertPolicy`, the
   Infrastructure write, the session teardown, the reader reload, the PDF
   re-read interaction, the confirmation dialog.
3. **The score-info entry point,** including the "restore score info too"
   choice. Separable because its pass condition is independent of the revert
   mechanism.

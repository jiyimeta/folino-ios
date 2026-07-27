# Note Editing — Design Spec

- **Date:** 2026-07-16
- **Status:** Draft for review (design approved in-session; architecture-realization decision open — see §9)
- **Scope:** iOS / iPadOS only for v1. Android deferred (but edit logic must be lift-able to shared Swift per the repo parity rule).
- **Branch:** `worktree-note-editing`

## 1. Summary

Add the ability to **edit the musical content** of a score the user is viewing: input / delete notes and rests, change a note's duration, change its pitch — plus chords, ties, tuplets, and accidentals. The interaction model is **"Caret & Pad" (select-then-act)**: tap a note or rest to place a caret on it, then act on the selection via a compact on-screen pad and a contextual callout. One responsive feature — **simpler presentation on iPhone, richer on iPad** — with identical capability on both.

The underlying engine (`swift-sheet-music`, already pinned at `be336454`) ships the entire editing command set, selection model, hit-testing, and MSCX/MSCZ serialization. **No upstream engine work is required for the core feature.** folino's work is: build the touch editing UI in the reserved `Editor` package, wire element-level hit-testing into the score surface, and fill in the already-declared `ScoreFileGateway.saveScore` stub.

## 2. Goals

- Full editing capability (not just light correction): notes, rests, durations, pitches, chords, ties, tuplets, accidentals — everything the engine's ready commands expose.
- **iPhone stays simple**; iPad may be visually richer. Same features on both — presentation differs, capability does not.
- Feel native to folino: iOS 26 **Liquid Glass** materials, SF Symbols, folino's Reader chrome conventions, lowercase `folino` in user-facing copy.
- Undoable, and safely persisted back to disk (`.mscx` / `.mscz`).

## 3. Non-goals (v1)

- **Adding / removing measures** and **manual beaming** — no ready engine command exists; deferred to a later phase requiring a small upstream `swift-sheet-music` addition (§10).
- **PDF scores** — not editable (they are PDFs, not a `Score` model); the edit affordance is hidden for them.
- **MusicXML write-back** — the engine decodes but does not encode MusicXML; an edited `.musicxml` is saved as a sibling `.mscz` copy (§8).
- **Android** — deferred. Edit-mutation logic should be written so it can later be lifted into shared Swift; no divergent reimplementation.
- **Marquee / range edits** as first-class multi-target commands — selection may render a range, but v1 commands act on a single target (optionally a delete-only range in a `CompositeEditCommand`, see §11).

## 4. Decisions already made (in-session)

| Decision | Choice |
| --- | --- |
| Editing depth | **Full** — chords, ties, tuplets, accidentals included |
| iPhone role | **Same features, simpler presentation** (one responsive feature) |
| Approach | **A — "Caret & Pad"** (in-place editing on the score, select-then-act) |
| Voices | **Voice picker in v1** (engine addresses voices already) |
| Audition | **On** — input / pitch change sounds the note through the current soundfont |
| Selection visual | **Reuse the Reader's existing note-highlight color** (do not introduce a new accent); render a **caret on the selected chord / rest** |
| Materials | **Liquid Glass / SF Symbols / iOS 26**, following folino's Reader chrome |

## 5. Interaction design — "Caret & Pad"

### 5.1 Entering / exiting edit mode

- Entry: an **"編集" (edit) affordance** in the Reader top chrome (icon-button in the inspector cluster). Entering edit mode:
  - pauses playback and hides the transport;
  - **repurposes tap-to-seek as tap-to-select** (resolves the primary gesture conflict);
  - dims any PencilKit annotation ink to ~40 % and makes it hit-test-transparent (annotation and note-editing are strictly mode-exclusive);
  - reveals the editing chrome (pad + callout on iPhone; pad + palette on iPad).
- Exit: **"完了"** returns to normal reading. Edits **autosave** (debounced) throughout; undo history is the safety net, so there is no discard dialog.

### 5.2 Selection & caret (refined per review)

- A single tap selects the nearest note / rest via `ScoreHitTester.itemID(at:)` (≈22 pt slop; tighter for Apple Pencil; Pencil hover pre-highlights the target).
- The selected element is drawn with **the same highlight color the Reader already uses for the current note** (the playback-cursor / selection tint) — reusing folino's existing visual language, not a bespoke accent. A **caret** (insertion indicator) sits on the selected chord / rest, making the "input here" point explicit.
- Tap empty staff = deselect. Long-press = loupe to disambiguate a notehead in a dense chord.
- **Rests are first-class tap targets**; in edit mode they get a subtle tint to advertise "tap to input here."
- Because engine IDs are **positional**, after each applied command the selection is **re-derived** from `ScoreEditor.lastAffectedLocation` (re-hit-test), which also drives keep-the-edited-note-visible scrolling.

### 5.3 The four core operations

| Operation | Touch interaction | Engine command |
| --- | --- | --- |
| **Input a note** | tap a rest (input slot) → tap a pitch key `C–B` | `InputNote(at: RestID, …)` via `NoteInputKeyMap`, octave nearest the previous note. If the armed duration ≠ the rest's duration → `CompositeEditCommand[SetRestDuration, InputNote]` as one undo step |
| **Delete** | select → `⌫` on the pad | `DeleteVoiceElement` (→ same-duration rest; measure length invariant). One notehead of a multi-note chord selected → `RemoveNoteFromChord` |
| **Change duration** | select → duration key | `SetChordDuration` / `SetRestDuration` (engine rebalances neighbors). The key also **arms** the entry duration for the next input |
| **Change pitch** | (a) drag the selected notehead vertically — ghost notehead snaps to staff steps with haptic ticks, release commits; (b) `▾▴` keys = ±semitone, long-press = ±octave | `SetNotePitch` (absolute, spelled from key signature, for drag; semitone for keys) |

The staff-drag pitch gesture is the one piece adopted from the runner-up gesture-first approach; it is the only op where direct manipulation is unambiguous and delightful.

### 5.4 Full-scope operations

Reached via a **floating callout** anchored beside the selected note (positioned with `LayoutDocument.cursorFrame(for:)` / `chordStemOrigin(at:)`) on iPhone, and a **persistent palette** on iPad:

- **Accidentals** ♭ ♮ ♯ (long-press → 𝄫 𝄪) → `SetAccidental`
- **Chords**: `＋音` arms add-to-chord (next pitch key / staff drag) → `AddNoteToChord`; `－音` → `RemoveNoteFromChord`; iPad adds `+3度 / +8度` interval shortcuts (client computes pitch/tpc from the key signature)
- **Tie** → `SetTie` (dimmed when there is no same-pitch successor)
- **Tuplet** → one-tap triplet `CreateTuplet(3,2)`; long-press grid for 5/6/7; becomes "remove" (`RemoveTuplet`) when the selection is inside a tuplet

### 5.5 Voices (v1)

A **voice picker** (segmented control) selects the target voice; edits apply to that voice. iPad surfaces it in the palette; iPhone in the context bar / callout `⋯`. Multi-voice scores still render all voices; only the active voice is edited.

### 5.6 Audition (v1)

On note input and pitch change, the resulting pitch sounds through the current soundfont for immediate aural feedback. Requires a lightweight play-single-note path from the audio adapter (Domain protocol); reuse the existing playback engine wiring.

### 5.7 Undo / redo

`ScoreEditor` provides the undo/redo stacks (`canUndo` / `canRedo`). Controls sit top-right in the edit chrome; system three-finger swipe gestures also route to `undo()` / `redo()`.

### 5.8 iPhone vs iPad presentation

- **iPhone (compact):** two-row bottom **pad** (durations / pitch + octave + delete) + the floating **callout** for contextual ops. The score keeps maximum vertical room. Context bar carries voice + audition indicators.
- **iPad (regular):** one-row bottom pad + a **persistent right-edge Edit palette** (the callout made permanent) showing a live **selection readout** ("E♭4 · 四分音符 · m.12 · 声部 1") and the `+3度 / +8度` shortcuts.
- One component set, arranged by size class (`committedSizeClass`) — identical capability.

### 5.9 Coexistence with PencilKit annotation

Strictly **mode-exclusive**. Edit mode dims annotation ink and blocks ink input; the two tools use visually distinct icons. Apple Pencil never draws ink while edit mode is active — no ambiguity between "annotate on top" and "edit the notes."

## 6. Visual & UI conventions

- **Liquid Glass (iOS 26):** the pad, callout, and iPad palette use system glass materials (`glassEffect` / `.regularMaterial`-class surfaces per current folino Reader chrome), floating over the score.
- **SF Symbols** for undo/redo/delete/speaker/chevron/voice etc.; note-value keys use crisp custom glyphs (accidentals use standard ♭ ♮ ♯ where they render well).
- **Follow the Reader chrome** (spacing, materials, button styling) so edit mode reads as the same app.
- **Copy:** user-facing strings are lowercase `folino` and natural Japanese ("編集" / "完了" / "声部"), localized via the established `module.feature.thing` key scheme; mockup labels are placeholders.
- **Selection color:** the Reader's existing highlight token (see §5.2), not a new accent.

## 7. Engine grounding (all present at the pinned revision)

- Commands: `InputNote`, `SetNotePitch`, `SetAccidental`, `SetChordDuration` / `SetRestDuration`, `DeleteVoiceElement`, `AddNoteToChord` / `RemoveNoteFromChord`, `SetTie`, `CreateTuplet` / `RemoveTuplet`, `CompositeEditCommand`; helper `NoteInputKeyMap`. Applied through `ScoreEditor` (undo/redo, `lastAffectedLocation`). All in `SheetMusicCore`, re-exported by Domain.
- Selection / hit-test: `ScoreSelection`, `ScoreItemID`, `ScoreHitTester` (`itemID(at:)`, `itemIDs(in:)`, `hitTest(at:)`), selection rendering via `ScoreView(… selection:)`. In `SheetMusicUI`.
- Persistence: `MSCXEncoder.encode(score, to:)`, `MSCZWriter.write(score:, to:)`, `SheetMusic.exportMSCX/exportMSCZ/exportMIDI`. In `SheetMusicMSCX` / `SheetMusic`.

## 8. Persistence

- Wire the already-declared `ScoreFileGateway.saveScore(_:fileURL:format:)` in `LiveScoreFileGateway` (Infrastructure) to call `SheetMusic.exportMSCX` / `exportMSCZ` (MSCX round-trips `==`-equal; MSCZ wraps it). This fills an existing stub — it is **not** a Domain protocol change.
- **Format policy:** `.mscx` / `.mscz` sources save in place. A `.musicxml` source (no encoder upstream) is saved as a sibling `.mscz` copy on first edit (naming: `<title>.mscz`; confirm naming — §11). PDF sources are non-editable.
- After a save, refresh the `ScoreItem` row (`contentHash`, `sizeBytes`, and any derived metadata) via `repository.saveScoreItem`, mirroring the metadata-edit path.
- **Autosave:** debounced write during editing; `lastAffectedLocation` keeps the edited note on screen.

## 9. Architecture & module integration (decision open — needs review)

Editing UI needs `SheetMusicUI` (render + hit-test), which sits **above** ScoreUI, so the editing surface **cannot** live in ScoreUI. It belongs in the reserved **`Editor`** Feature package, which — like Reader — takes the sanctioned `SheetMusicUI` carve-out. Domain re-exports the commands; Infrastructure owns serialization behind `ScoreFileGateway`. So far this is all within existing rules.

The open question is **how "edit in place" is realized without a Feature→Feature import** (Reader must not import Editor). Two options:

- **Option 1 — Reader overlay seam + App composition (recommended).** Reader exposes an injection seam (a `ViewBuilder` / closure) for an editing overlay and an "edit mode" flag; it already owns the score-rendering scaffolding (`ScoreScrollHost`, layout caching, containers) and already passes `selection` to `ScoreView`. The `Editor` package provides the `EditorViewModel` (owns `ScoreEditor`, applies commands, manages selection/voice/audition) and the chrome views (pad, callout, palette). **App** composes them: injects the Editor surface into Reader's seam and hands the editor the `LayoutDocument` + tap stream. No new package, no boundary change, no duplication of the score scaffolding.
  - Cost: Reader gains a modest injection API and must surface its `LayoutDocument` + tap coordinates to the seam.
- **Option 2 — new shared "ScoreCanvas" package below Features.** Lift the score-rendering scaffolding out of Reader into a new package that *is* allowed to import `SheetMusicUI`, consumed by both Reader and Editor; editing becomes a self-contained `EditorRootScreen`. Cleaner separation, but this is a **module-architecture change (new package / new boundary)** and a larger refactor of Reader.

**Recommendation: Option 1** (smaller, no boundary change). Because Option 2 is a module-architecture change, and even Option 1 adds a structural seam to Reader, this section is called out explicitly for sign-off during spec review.

Other integration points:

- **Entry points:** the Reader chrome "編集" button (edit the score you're viewing); optionally a Library `ScoreRowMenu` "編集" action later. App wires the composition (mirroring `makeReader`).
- **Screens/Views convention:** `Editor/Screens/` (navigable + presentation state) + `Editor/Views/` (pad, callout, palette, pickers) + `EditorViewModel`, mirroring Library/Reader.
- **Positional-ID drift:** re-derive selection after every `apply` from `lastAffectedLocation`.

## 10. Feasibility & phasing

**Buildable today (v1):** every interaction in §5 fires an existing command; hit-testing, selection rendering, callout geometry, undo, and `.mscx`/`.mscz` save are all shipped. Voice editing and audition are ready.

**Needs a small upstream `swift-sheet-music` addition (Phase 2):**
- Add / remove **measure** (no ready command; `systemMeasures` alignment invariant must be maintained) → v1 edits within the existing measure count and shows no "append measure" affordance.
- Manual **beaming** (no command).

**Possible tiny upstream conveniences (confirm or work around locally):**
- A render option to **tint rests** in edit mode (else overlay the tint in-app).
- A **staff-step → Y** geometry accessor for the ghost-notehead drag preview (if `LayoutDocument` doesn't already expose it).

Both are hours-scale, not blockers.

## 11. Open questions / decisions for review (proposed defaults)

1. **Architecture realization** (§9): Option 1 (Reader seam + App compose) vs Option 2 (new ScoreCanvas package). **Default: Option 1.**
2. **MusicXML save naming:** silently save edited `.musicxml` as `<title>.mscz` sibling, or prompt once? **Default: silent sibling `.mscz`, surfaced via a one-time note.**
3. **Transpose interaction:** edit in *written* pitch and **lock the Reader transpose stepper** during edit mode. **Default: lock + written-pitch editing.**
4. **Multi-select:** ship marquee-select for **delete only** (looped `DeleteVoiceElement` in a `CompositeEditCommand`), or defer all range ops? **Default: defer; single-target v1.**
5. **Auto-advance after input:** selection moves to the next element after a pitch-key input (on), but not after a drag (off). **Default: on-after-keys / off-after-drag.**
6. **Edit entry surface:** in-Reader button only for v1, or also a Library row action? **Default: in-Reader only for v1.**

## 12. Testing strategy

- **Editor unit tests (Swift Testing):** command-application logic and selection re-derivation against the engine's `Score` value tree — input, delete, duration change (with rest rebalancing), pitch change, chord build, tie, tuplet, undo/redo, positional-ID re-derivation after edits.
- **Persistence round-trip:** edit → `saveScore` (`.mscx`/`.mscz`) → reload → assert `==`-equal `Score` (semantic round-trip contract).
- **Hit-test wiring:** tap coordinate → expected `ScoreItemID` against a known `LayoutDocument`.
- **Feature tests** use fakes for audio/persistence per repo convention. UI-gesture feel (pitch drag) is verified manually on device.

## 13. Risks

- **Finger precision** for pitch-drag on dense/small iPhone staves — mitigated by ▾▴ keys as the primary path and drag as the delight path; verify on device.
- **Reader coupling** (Option 1 seam) — keep the injected API minimal and Domain-typed.
- **Positional-ID drift** — centralize re-derivation so no stale `ScoreItemID` is ever applied.
- **Autosave vs large scores** — debounce; serialize off-main.

## 14. Out of scope

Android; measure add/remove and beaming (Phase 2 / upstream); MusicXML write-back; lyrics/clef editing UI (engine supports them, but not surfaced in v1); marquee range ops beyond a possible delete.

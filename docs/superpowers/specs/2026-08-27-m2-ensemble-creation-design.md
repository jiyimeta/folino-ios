# M2: Ensemble Scratch Creation — Design

**Date:** 2026-08-27
**Status:** Approved design; implementation plan to follow
**Parent:** `2026-08-26-scratch-score-creation-and-pro-design.md` (umbrella), milestone M2
**Scope:** Instrument catalog, creation templates, multi-part wizard, transposing instruments, and part add/remove/reorder on existing scores.

## 1. Decisions that frame the design

- **Transposing display applies to imported scores too.** ssm today silently drops `<transposeChromatic>/<transposeDiatonic>` on import, so a B♭ trumpet part renders at concert pitch (sound is correct; the page disagrees with the printed part). M2 fixes the model, and imported scores gain written-pitch display along with scratch-created ones. Display-only change; playback is untouched. No concert/written view toggle in M2 (can be added later on top of this model).
- **Anacrusis (pickup measure) moves to M3.** M3 models irregular measures anyway (re-barring); the wizard field arrives there. M2's wizard does not offer it.
- **Part reorder is in scope**, alongside add/remove. The `StaffAddress` preference-migration machinery is shared across all three, so the marginal cost is one ssm command plus drag UI — and taking it now avoids reopening the migration later.
- **Part management UI lives in an Editor sheet**, with per-staff visibility toggles built into the same sheet (the Reader inspector's existing toggles remain as a second entry point to the same store).
- **Templates:** Solo piano, Voice + piano, SATB choir, String quartet — plus **"same instrumentation as an existing score"** (pick a library score; copy its part structure).

## 2. Transposition model: concert-pitch storage, written pitch derived at display time

The score continues to store **concert (sounding) pitch as the single source of truth** — `Note.pitch` is the MIDI sounding pitch and `Note.tpc` stays the single concert tpc, exactly as today. This matches the mscx format (`<pitch>` is sounding; `<tpc>` is concert tpc1) and keeps playback and every existing edit command untouched.

- **Model:** `Instrument` gains `transposeChromatic: Int` and `transposeDiatonic: Int` (default 0 = non-transposing). The mscx decoder/encoder round-trips the `<transposeChromatic>/<transposeDiatonic>` tags (currently dropped on import, never written on export). On export, `<tpc2>` (written tpc) is computed for transposing parts so MuseScore reads the file correctly. On import, `<tpc2>` is ignored (recomputed from the transposition when needed).
- **Display:** a new per-part written-pitch display transform joins the existing pipeline. Unlike the whole-score `Score.transposed(bySemitones:)`, no key-histogram heuristic is needed: the (diatonic, chromatic) pair determines the tpc shift exactly. Written key signatures are derived per part as `concertKey + fifthsDelta`. Parts with `useDrumset` and staves with `group == "percussion"` are skipped (same exclusion rule as the global transpose).
- **Pipeline order (folino Reader):** `clefOverrides → perPartWritten → transposed(global ±7) → filtered(hidingStaves:)`. The global Reader transpose is a sound-plus-notation shift, so it composes outside the written derivation. While editing, the global transpose stays forced to 0 (existing behavior) but the written transform stays live — it *is* the transposed-instrument input experience.
- **Note input:** `ScoreEditSession` keeps operating in concert space. Only the pad's note-name resolution (`InputNote`, `SetNotePitch`, step movement) becomes staff-aware: on a transposing staff the entered letter means written pitch and is inverted to concert before storage. Caret and selection work against the displayed document and are absorbed by the existing display→source mapping. Audition plays the sounding pitch.
- **Bug fix folded in:** `MSCXDecoder+KeySignature`'s fallback reads `<accidental>` as if it were the concert key; for a transposing part in older mscx that tag is the *written* key. With transposition now modeled, the fallback converts written → concert using the part's transposition.
- **Rejected alternative — MuseScore-style dual tpc1/tpc2 storage:** buys independently editable written enharmonics at the cost of a dual invariant rippling through every edit command. Derivation satisfies M2 (correct written display and input); a per-note tpc2 override can be layered on later without reversing this decision.

**Accepted costs:** the written transform runs per render (same class of cost as the proven `transposed` path). Derived written spelling may occasionally differ from a MuseScore user's manual respell; round-trip integrity is unaffected because concert pitch is the stored truth.

## 3. Instrument catalog and templates (folino Domain)

Following the `GMDrumKit` precedent — static data in **Domain**, so Android reads the same catalog over JNI — and keeping ssm catalog-agnostic.

**Catalog** (`ScoreInstrument.all`, ~24 entries, grouped by a notation-oriented family):

| Family | Instruments (* = transposing) |
| --- | --- |
| Voices | Soprano, Alto, Tenor* (−12, octave clef), Bass, Voice |
| Keyboards | Piano (grand staff), Electric piano, Organ |
| Strings | Violin, Viola, Cello, Contrabass* (−12) |
| Woodwinds | Flute, Oboe, Clarinet in B♭*, Alto sax in E♭*, Tenor sax in B♭*, Bassoon |
| Brass | Trumpet in B♭*, Horn in F*, Trombone, Tuba |
| Guitar & Bass | Guitar* (−12), Bass guitar* (−12) |
| Percussion | Drum kit (creatable in M2; note entry arrives with M6) |

Each entry carries: `id`, display name (xcstrings), family, staff plan (count + clefs, brace for grand staff), `transposeChromatic`/`transposeDiatonic`, GM program, and an amateur pitch-range hint (stored for future range warnings; no UI consumes it in M2). The data is clean-room, referencing MuseScore's `instruments.xml` **shape** only (GPL — no content or code ported).

**Templates** are Domain data too: a list of catalog IDs plus bracket grouping. Shipped set: Solo piano / Voice + piano / SATB choir / String quartet. "Same instrumentation as an existing score" is app-side (reads the chosen score's `Part` structure directly) and does not go through the catalog — instruments outside the catalog copy over as plain `Instrument` structs.

## 4. ssm: factory and part commands

**`Score.blank` v2** — `BlankScoreTemplate` becomes multi-part:

```swift
struct PartPlan {
    var instrumentID: String
    var longName: String?; var shortName: String?
    var staves: [StaffPlan]              // one per clef; piano = 2 + brace
    var transposeChromatic: Int; var transposeDiatonic: Int
    var gmProgram: Int                   // written into InstrumentChannel.program
    var isDrums: Bool                    // useDrumset + percussion staff group
}
struct BlankScoreTemplate { /* existing fields */; var parts: [PartPlan]; var bracketGroups: [Range<Int>] }
```

- Fixes M1's "piano is only correct because GM program 0 happens to be piano": `PartPlan` sets the program explicitly.
- Brackets: per-part brace for multi-staff parts (as in M1), plus template-specified `.normal` brackets spanning part ranges (SATB, string quartet). Brackets span the global flattened staff order, matching the model's convention.
- Measure 0 writes `concertKey` only; written key signatures are display-derived.

**Part commands** — three new `EditIntent` cases, undo built on the `InsertMeasure`/`DeleteMeasure` pattern:

- `.addPart(plan: PartPlan, at: Int)` — inserts a rest-filled staff column into every measure; re-stamps `systemMeasures` `originalStaff` and brackets.
- `.removePart(at: Int)` — inverse; undo captures the entire part (staves, associated spanners, brackets). Refused when it would remove the last part.
- `.movePart(from: Int, to: Int)` — reorder.
- All three re-number the `partIndex` in every embedded `StaffAddress` (`VoiceElementID` family, `PositionedSystemElement.originalStaff`). Bracket re-anchoring transplants the logic already proven in `filtered(hidingStaves:)` to the write path.
- **`ScoreEditSession` exposes a cumulative part-index mapping since load** (`[oldPartIndex: newPartIndex?]`, `nil` = removed), recomposed on every apply/undo/redo. This is the input to folino's preference migration (§6).

## 5. Wizard v2 (Library)

`NewScoreSheet` stays a single screen. The M1 three-preset picker is replaced by an **instrumentation section**:

1. Entry points: the four templates, "same instrumentation as an existing score" (opens a library score picker), and "choose instruments" (opens the catalog picker).
2. The chosen instrumentation expands into an **editable list in place** — row per instrument, swipe to delete, `+` to add from the catalog picker, drag to reorder. A template is an initial value, not a commitment.
3. Remaining fields (title, composer, concert key, time, tempo, measure count) are unchanged from M1. The key is the shared concert key; written keys are derived per part.

The catalog picker component is shared with the Editor's instruments sheet, so it lives in **ScoreUI**. The Domain seam is unchanged: `ScoreFileCreator` still takes a `Score`; only the form → `BlankScoreTemplate` mapping in Library grows.

## 6. Instruments sheet (Editor) and preference migration

**Instruments sheet**, opened from the Editor chrome, identical for scratch-created and imported scores (no experience divergence):

- Row = part: instrument name + staff summary. Drag to reorder, swipe/− to delete, `+` opens the shared catalog picker.
- **Per-staff visibility toggles are built into each row.** These write the Reader's per-score preference (`hiddenStaves`) — display state, immediate, outside undo — while the structural operations go through the edit session (undoable, saved). Editor cannot depend on Reader, so the App composition root wires the toggle through a callback seam (same pattern as `displayToSourceItem`). The Reader inspector's existing toggles remain; both edit the same store.
- Deleting a part is destructive (its notes go with it): confirmation dialog, with copy noting it can be undone. The last remaining part cannot be deleted.

**Preference migration** — the resolution of M2's biggest cross-codebase risk (`StaffAddress` is persisted per-score user data):

- On **save**, folino applies the session's cumulative part-index mapping once to the three per-score preference stores: `hiddenStaves` (`StaffAddress`), clef overrides (`StaffAddress`), and `MixerStripID` (`partIndex`, `instrumentOrdinal`). Rows for removed parts are dropped. Applying at save time (not per command) means mid-session undo/redo churn can never corrupt the stores. After a save consumes the mapping, the session's baseline resets, so a later save in the same session applies only the delta since the previous one.
- Reader's in-memory models (`LayoutSettingsModel`, mixer strips) re-derive through the existing `onScoreChanged` mirror.

## 7. Testing

**ssm:**
- `Score.blank` v2 round-trip: create → save → load → `==`, across templates and bracket groups.
- Part commands: exact undo inverses (including spanner and bracket restoration), ID re-stamping, mapping composition across apply/undo/redo sequences.
- Written-pitch display snapshots for B♭, E♭, F, and octave transpositions: note spelling and derived key signatures.
- `<transposeChromatic>/<transposeDiatonic>` and `<tpc2>` round-trip; regression test for the `KeySignature` `<accidental>` fallback fix.
- Written-input inversion: entering a letter on a transposing staff stores the correct concert pitch/tpc.

**folino:**
- Library: form → template v2 mapping, template expansion, clone-instrumentation from a real `Score` fixture (via fake `ScoreFileCreator`).
- Editor: instruments-sheet view model — add/remove/reorder emit the right `EditIntent`s; last-part deletion refused.
- Preference migration: pure-function unit tests applying mappings (delete, insert, reorder, compositions) to the three stores.
- Infrastructure: `LiveScoreFileCreator` multi-part save round-trip.

**On-device:** create an ensemble with a transposing part, enter notes on the B♭ staff (written input, sounding playback), and confirm an imported real trumpet score now displays at written pitch.

## 8. Analytics, Android parity, sequencing

**Analytics:** `.scoreCreated` gains template ID and part count. Part editing is one event, `.scorePartsEdited`, with an action parameter (add/remove/reorder). Minimal, per the events-first policy.

**Android parity:** the written transform, factory, part commands (ssm) and catalog/templates (Domain) land in shared code by construction. `PARITY(android)` markers at the three UI/wiring divergence points: wizard, instruments sheet, written-display pipeline wiring.

**ssm branch discipline:** work continues on `feature/scratch-creation-m1` in the `wt-scratch-creation` worktree; no ssm release until all milestones land (umbrella policy).

**Implementation order** (skeleton for the plan's task decomposition):

1. ssm: `Instrument` transposition + mscx round-trip + KeySignature fallback fix + per-part written display transform — an independent block that benefits imports immediately.
2. ssm: `BlankScoreTemplate` v2 (multi-part factory).
3. Domain catalog + templates; Library wizard v2.
4. ssm: part commands + cumulative mapping.
5. ScoreUI/Editor/App: instruments sheet + preference migration.
6. ssm: written-pitch input inversion on transposing staves.

## 9. Open questions

- **"Revert to original" on scratch-created scores** (deferred from M1): reverting returns to the blank score, and with M2 it also reverts part structure, widening the surprise. The remedy (reworded copy, or hiding the action for scratch-created scores) is decided together with the M5 paywall copy.
- **Range warnings**: the catalog stores amateur pitch-range hints, but no M2 UI consumes them. A future editor affordance (out-of-range tinting) can build on the data without a model change.

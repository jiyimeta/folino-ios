# M3 — Key/Time Signature Changes (Re-barring & Re-spelling) — Design

**Date:** 2026-08-27
**Status:** Approved design; implementation plan to follow
**Parent:** `2026-08-26-scratch-score-creation-and-pro-design.md` (umbrella), milestone M3
**Prerequisites:** M1 (score factory, measure commands), M2 (ensemble, transposing instruments) — both landed on ssm branch `feature/scratch-creation-m1`

M3 makes key and time signatures editable after creation and mid-piece. A time-signature change **re-bars** the affected region (re-partitions the tick stream into new-sized measures, splitting and tying notes at the new barlines); a key-signature change **re-spells** accidental glyphs across the affected region. This applies to any score folino can edit — scratch-created and imported alike.

**Reference implementation: MuseScore** (`~/Developer/musescore/MuseScore`) for behavior and edge cases only. GPL — no code may be ported or translated; all algorithms are clean-room in ssm.

## 1. Decisions

1. **Anacrusis (pickup measure) is in scope** — deferred here from M2. The creation wizard gains a pickup-length picker; `Score.blank` produces the irregular first measure. Post-creation pickup editing is *out* of scope (see §7).
2. **Tuplet conflicts refuse the whole operation.** A re-bar that would place a new barline inside a tuplet refuses with a structured `EditRefusal` naming the measure; the score is untouched. Matches MuseScore and every existing ssm planner (`CrossBarInputPlanner`, `PasteVoiceElements`, `SetChordDuration`).
3. **Engraving ships complete in M3**: cancellation naturals *and* end-of-system courtesy signatures (both greenfield in ssm today).
4. **Scope semantics are MuseScore's**: a change at measure *m* applies from *m* until the next existing change of the same kind (or end of score). A change at measure 0 is the "after the fact" global change. **Removing** an existing mid-piece change (reverting the region to the prevailing signature, with re-bar/re-spell) is also in scope; the initial (measure 0) signature can only be changed, never removed.
5. **Time signature entry is free-form**: numerator 1–63 × denominator 1/2/4/8/16/32, with presets as shortcuts. The wizard's time picker is unified onto the same control.

## 2. ssm model additions

- **`showCourtesy: Bool = true`** on `KeySignature` and `TimeSignature`, round-tripping MSCX `<showCourtesySig>` (currently dropped on decode). Gates the end-of-system courtesy synthesis (§6).
- **Cancellation naturals need no model change** — derived at layout time from the `activeKey` in force before the change point.
- **`Score.stableFingerprint` gains `actualLength`, `irregular`, and `systemMeasures`.** M3 is the first edit path to write these fields; the fingerprint's own doc comment mandates the extension. Android JNI and web replay goldens are regenerated.
- `Measure.actualLength` / `irregular` are unchanged as model; M3 is the first *producer* on an edit path (re-bar remainder handling, wizard pickup).

## 3. New intents and commands

`EditIntent` appends four cases (wire indices 19–22, append-only; all-scalar payloads, so no new bridge entry points — codec cases plus Kotlin/TS mirrors only):

```swift
case setKeySignature(measureIndex: Int, concertKey: Int)                     // 19
case removeKeySignature(measureIndex: Int)                                   // 20
case setTimeSignature(measureIndex: Int, numerator: Int, denominator: Int)   // 21
case removeTimeSignature(measureIndex: Int)                                  // 22
```

**Key side — composite of primitives.** `SetKeySignature` writes/replaces the concert `.keySignature` leading element on every non-percussion staff at measure *m* (canonical Clef→Key→Time prefix order via `MeasureStructure`; percussion skip per the `Score.blank`/`AddPart` convention). The planner bundles it with re-spelling of the whole affected span into one `CompositeEditCommand` (one undo step). Measure count never changes, so the composite shape is sufficient.

**Time side — dedicated column-level command.** `SetTimeSignature` performs the entire re-bar in a single `apply`: region re-partition across all staves, signature writes, spanner and `systemMeasures` reconciliation. Its inverse is a pre-image snapshot of every affected column (the `DeleteMeasure`/`AddPart` internal-initializer idiom), so undo restores the score byte-for-byte without inverting the re-bar analytically. Rationale: re-barring changes the measure *count*; composing it from `ReplaceVoiceElements` + `InsertMeasure`/`DeleteMeasure` would pass through states where content and measure count disagree and would fight index re-mapping across the composite. One function establishes all invariants at once.

**Remove commands** reuse the same machinery with the target signature = the prevailing one before *m*.

**Planner rules** (`ScoreEditSession+Planning`): setting a signature equal to the prevailing one, or removing where no explicit change exists, plans to `nil` → `.nothingToApply`. Range validation lives in the commands.

**New `EditRefusal.Reason` cases**: `.rebarWouldSplitTuplet(measureIndex:)`, `.rebarWouldBreakRepeat(measureIndex:)`, `.cannotRemoveInitialSignature`.

## 4. Re-bar algorithm (`RebarPlanner`, internal to SheetMusicCore)

Affected region = [*m*, next explicit time-signature change). For every (staff, voice):

1. **Flatten** the region's element lists into a tick-addressed stream: chords/rests with durations; untimed elements (mid-bar clefs, dynamics, `.locationShift`) remember their tick; grace notes ride their host chord; **each tuplet is one atomic unit**.
2. **Re-partition** at the new nominal duration. All arithmetic is `Fraction` — no rounding error.
   - **Note splitting**: a chord crossing a new barline is split via `DurationChangeAlgorithm.alignedDurations` + `makeChordChain` (the `CrossBarInputPlanner` parts, generalized from "insert forward from one slot" to "re-partition a region"): interior joints tied, outer ties preserved, head keeps articulations/lyrics, continuations are bare noteheads.
   - **No tie merging**: chains that were split by *old* barlines stay tied. Matches MuseScore; keeps the algorithm one-directional. Consequence, stated as intended behavior: A→B→A is not byte-identical (undo is).
   - **Tuplets**: an atomic unit that would cross a new barline refuses the whole operation (Decision 2).
   - **Irregular measures** (`actualLength != nil`, e.g. a pickup) are preserved atomically — content and `actualLength` untouched — and act as partition boundaries inside the region.
   - **Remainder**: the trailing partial bar is padded with aligned rests to a full final measure; an all-rest bar is promoted to a `.measure` rest.
3. **Structural markers re-home by tick**: repeat barlines, `startRepeat`, and special barlines move to the new barline at the same absolute tick; if that tick is no longer on a barline, refuse with `.rebarWouldBreakRepeat`. (Scratch-created scores don't author repeats yet, but M3 operates on imported scores too.)
4. **Parallel lanes**: each `systemMeasures` element (tempo, system text) re-homes to the new measure containing its old absolute tick. `Spanner.nextMeasuresOffset` is recomputed from ticks (the existing ±1-column helper does not cover this; new code).
5. The new `.timeSignature` is written into every staff at the region head; superseded signature elements inside the region are removed via `MeasureStructure.removeElements` (already tuplet-index-safe).

When the measure count changes, `parts[].staves[].measures` and `systemMeasures` stretch together inside the one command — the point of the dedicated-command shape.

## 5. Key re-spell details

- The stored value is the **concert key**; transposing parts' written keys remain fully derived (`writtenFifthsOffset` at encode/render time) — nothing new is stored per part.
- **Re-spell span = [*m*, next key change), all non-percussion staves**, via a new explicit-range API `MeasureAccidentals.renotationCommands(in:measureRange:)` wrapping the existing per-measure `renotate`. The session's automatic renotation pass only diffs changed measures and cannot reach past the change point, hence the explicit range.
- Existing skip rules are preserved (user-role accidentals, tied-back notes, pitch/tpc disagreement, non-standard glyphs) — deliberate user markings survive. Glyphs only; `pitch`/`tpc` never change.
- Extreme keys on transposing parts follow the established `respelledKey` ±12 clamp (M2 contract). The open M2 item on export-tpc2-vs-render asymmetry is independent of M3.

## 6. Engraving: naturals and courtesy signatures

**Cancellation naturals** render **only when the new key has zero accidentals** (e.g. D→C shows two naturals) — MuseScore's default and modern engraving practice (Behind Bars). This fully resolves the invisibility problem that motivated the decision (a change to C major otherwise draws nothing). Naturals on every reduction is a possible future style option, not M3.

- Implementation: `KeySignatureSteps` gains a naturals-step computation over the outgoing key's positions; `LayoutEngine+Placement` emits them when the prior `activeKey ≠ 0` and the new key = 0; `LayoutElement.keySignature` carries them; width scheduling (header and mid-bar `timedX`) includes their width.

**End-of-system courtesy** is pure layout synthesis (the model only contributes `showCourtesy`): when the next system's first measure begins with an explicit key/time change whose `showCourtesy == true`, the previous system's last measure gets trailing courtesy glyphs — the symmetric twin of the existing `synthesizeLeadingKeySig`. Key courtesy is per-staff (written key); time courtesy is uniform. The naturals rule applies to courtesy keys too. System breaking reserves courtesy width when the following measure opens with a signature change (same estimation style as the existing header width scheduling). Mid-piece changes that are *not* at a system boundary keep rendering inline at their tick (already works today).

## 7. Anacrusis (wizard + factory)

- `NewScoreForm` gains a pickup setting: none, or a length picked from divisor-aligned values shorter than the chosen time signature (e.g. 4/4 offers 1/8, 1/4, 3/8, 2/4, …). Enumerated choices, no free entry.
- `BlankScoreTemplate` / `Score.blank` set measure 0's `actualLength` and `irregular = true` (excluded from measure numbering via the existing `displayedMeasureNumber`); content is a `.measure` rest, which already resolves through `actualLength`.
- Post-creation pickup add/remove is out of scope; the re-bar preserves existing irregular measures, so nothing conflicts. A future `setPickup` intent can slot in without rework.

## 8. folino UI

**Entry point**: two rows appended to the Editor measure menu (below M1's three): "Key signature…" and "Time signature…" (`editor.measure.keySignature` / `.timeSignature`), disabled when `targetMeasureIndex == nil`. No new top-bar button (the documented width budget has ~19pt of slack); the rows ride the existing fold into the overflow `⋯`.

**Sheets** — one focused sheet per row, in the instruments-sheet idiom (presentation flag on the view model, `.sheet` attached at the strip root):

- Header shows the target measure number (`displayedMeasureNumber`) and the signature currently in force (`activeKey` / `effectiveMeasureDuration`).
- Key sheet: 15-key picker (verbatim `C / Am` labels, non-localized) + Apply.
- Time sheet: preset row (the current 7 plus 7/8, 9/8, 3/8) + free numerator/denominator steppers (1–63 × 1/2/4/8/16/32) + Apply.
- A destructive "Remove change at this measure" row appears only when an explicit mid-piece change of that kind exists at the target and it is not measure 0; confirmed via `confirmationDialog` (removal re-bars).
- One line of scope explanation ("applies from this measure to the next change"), localized in all five locales.

**Pickers lift into ScoreUI**: `KeySignaturePicker` / `TimeSignaturePicker`, the choice tables, and `keyLabel` move to `Packages/ScoreUI` under the `InstrumentCatalogPicker` contract (just the list — no chrome, no dismissal). `NewScoreSheet` rewires onto them, upgrading the wizard's time picker to free-form n/d (Decision 5) and adding the pickup row (§7).

**Refusal surfacing**: when `apply()` returns false, the sheet shows an alert localized from `lastRefusal` — the two re-bar reasons name the offending measure; a generic fallback covers the rest.

**Wiring**:

- Selection restoration relies on the default rederivation: after a re-bar the old item may not exist, and landing on `lastAffectedLocation` (the region head) is the right behavior.
- Undo is one step via the session; system three-finger undo works through the existing trampolines.
- Analytics: new Domain factory `scoreSignatureChanged(kind: key|time, action: set|remove)`, emitted through a new `onSignatureChanged` closure seam wired at the composition root (the `onPartsEdited` pattern — the Editor keeps no analytics client).
- xcstrings: Editor + ScoreUI, all five locales (en, ja, ko, zh-Hans, zh-Hant); key/time labels stay verbatim.
- `PARITY(android)` marker at the UI divergence point (the sheets); the ssm logic is shared, so no logic marker.

## 9. Testing

**ssm (the bulk):**

- Command suites `SetKeySignatureTests` / `SetTimeSignatureTests` in the established style: apply → assert intermediate state → apply inverse → `score == original` byte-for-byte. Time-side matrix: grow/shrink, same-denominator changes, measure count up/down, split+tie creation, remainder rest padding and `.measure` promotion, pickup preservation, mid-bar clef carry, spanner offsets, `systemMeasures` re-homing, all three refusals, set at measure 0 (global change), remove restoring the prevailing signature.
- **Round-trip corpus bed** (umbrella-spec requirement, green before any UI work): `Score.blank` → enter notes → signature change → MSCX encode → re-parse → full `Score` equality, across key/time × set/remove × pickup on/off.
- `EditReplayScript` gains steps for all four intents (its contract covers every case) → regenerate Android JNI and web goldens; wire codec goldens + Kotlin/TS mirrors.
- Fingerprint tests: `actualLength`, `irregular`, `systemMeasures` affect the hash.
- Layout: naturals step computation; courtesy synthesis (emitted / not emitted / suppressed by `showCourtesy == false`); `SM_LAYOUT_GOLDEN` re-baseline.
- Gates: `Scripts/preflight.sh --apple|--wasm|--android` all green (as M2).

**folino:**

- `EditorViewModel` intent-construction tests through the DEBUG `appliedIntents` seam (M1 style): menu enablement, sheet-to-intent mapping, no state pollution on refusal.
- Wizard: pickup selection → `BlankScoreTemplate` unit tests.
- Preview/device verification happens in the implementation plan: `#Preview` + `RenderPreview` for the signature sheets and the naturals/courtesy rendering.

## 10. Known adjacent gap (not touched in M3)

MIDI export writes only the first time signature (a deliberate pre-existing limitation in `MidiRenderer`). Exporting a score with mid-piece time changes to `.mid` misplaces barlines in a DAW; playback and metronome are tick-based and unaffected. Goes on the decision list for the ssm 2.1.0 tag.

## 11. Risks

- **Re-barring is the umbrella spec's named schedule risk.** Mitigations baked in: the corpus round-trip bed lands before UI; the dedicated-command-with-pre-image-inverse shape makes undo correctness testable byte-for-byte; tuplet/repeat conflicts refuse rather than approximate.
- **Fingerprint extension invalidates committed replay goldens** across Android and web — regeneration is a planned task, not an incident.
- **Courtesy width reservation** touches system breaking, the most layout-golden-sensitive area; the `SM_LAYOUT_GOLDEN` re-baseline is expected and reviewed, not waved through.

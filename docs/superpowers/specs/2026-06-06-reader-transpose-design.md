# Reader Transpose — Design

**Date:** 2026-06-06
**Status:** Approved design, pre-implementation
**Feature:** Semitone transposition in the Reader, affecting both engraving and playback.

## Goal

Let the user transpose the open score by a whole number of semitones in the
range **−7 … +7** (default 0). Transposition must affect **both** the displayed
notation (notes re-engraved at the transposed pitch, key signatures shifted) and
playback audio (sounding pitch shifted by the same interval). The two stay
consistent at all times.

The control is the only Reader knob that affects sound *and* appearance
inseparably (tempo affects only sound; clef/staff-size affect only appearance),
so its placement is the central UX question. Persistence is **per-score** — the
chosen transposition is remembered for each score, like tempo / clef overrides /
mixer state.

## Decisions (locked)

| Decision | Choice |
| --- | --- |
| Range | −7 … +7 semitones, default 0 |
| Persistence | Per-score, new `ReaderPreferences` field |
| Placement | **Mirrored in both inspectors** — single source of truth backs a row in each inspector's *General* section (same pattern as the seek-bar toggle, which mirrors between the Visual inspector and Settings) |
| Playback strategy | **Live engine transpose** — new `PlaybackController.setTranspose(semitones:)`; engine applies coarse tuning (semitone register) to non-drum channels. No score reload; instant during playback |
| Display strategy | New `Score.transposed(bySemitones:)` transform in swift-sheet-music, slotted into the existing display-transform pipeline |
| Drums / unpitched | Excluded from transposition on both display and playback |
| Key-signature handling | Proper transpose: key signatures shifted by N semitones, notes re-spelled against the new key (no accidental-soup) |
| Readout | Signed semitone integer (`+2`, `−3`, `0`) with a ♯♭ icon, `±` Stepper. Stepper double-tap resets to 0. (Resulting key-name readout deferred — see Out of Scope) |

## Why these choices

### Placement — mirror in both inspectors

The two inspectors are organized by intent:

- **Playback inspector** = "how it sounds": metronome, tempo, repeat, master
  volume, per-part program / per-staff volume·solo·mute.
- **Visual inspector** = "how it looks": layout direction, staff size, breaks,
  collapse multi-measure rests, show invisibles, seek-bar toggle, per-staff
  clef·visibility.

Transpose belongs to *both* categories. Putting it in only one hides it from
half the users who would look for it. The seek-bar toggle already establishes
the mirror pattern in this codebase (`showSeekBarEnabled` is editable from both
the Visual inspector and Settings), so a single `TransposeModel` driving a row
in each inspector's *General* section is consistent with existing conventions.

### Playback — live engine transpose, not score reload

The playback session (`ReaderPlaybackSession`) feeds the **original, untransformed**
score to `controller.load(...)` and reconciles the on-screen (display-transformed)
score via cursor translation. Two ways to make playback follow the transpose:

1. **Reload a transposed score** every time transpose changes. Simple (Folino-only,
   no engine change) but reloads the engine and forces a re-seek on every step;
   playback audibly stutters.
2. **Live engine transpose** (chosen). Add `setTranspose(semitones:)` to the
   `PlaybackController` protocol; the engine shifts sounding pitch by applying
   **coarse tuning** (the semitone register — distinct from the cents/fine
   register that A4 calibration uses, so the two compose) to every non-drum
   channel. No reload, instant, zero-artifact. This matches the existing live
   setters (`setTempoMultiplier`, `setMasterVolume`) and the proven A4-calibration
   tuning approach.

Because the engine keeps the original score and only shifts tuning, while the
display shows a transposed score, both rise by exactly N semitones and stay
consistent.

### Display — a new `Score.transposed(bySemitones:)` transform

The display pipeline in `ReaderRootScreen.content` already composes pure
`Score → Score` transforms from swift-sheet-music's `Score+DisplayTransforms.swift`:

```
score → applying(clefOverrides:) → filtered(hidingStaves:) → container
```

Transpose slots in as a sibling transform, applied **before** the hidden-staves
filter:

```
score → applying(clefOverrides:) → transposed(bySemitones:) → filtered(hidingStaves:)
```

`transposed(bySemitones:)` will:

1. Shift each `KeySignature` by N semitones (e.g. +2 turns C major / 0 sharps
   into D major / 2 sharps), and
2. Re-spell each `Note` against the **new** key signature using the existing
   `Note.shifted(bySemitones:in:)` (which already mirrors MuseScore's ↑/↓ arrow
   transpose semantics), then
3. Skip drum / unpitched-percussion staves entirely.

### Why transpose is orthogonal to the cursor/timing machinery

Transposition changes only pitch (`pitch`, `tpc`, `accidental`) and key
signatures. It does **not** change note count, note IDs, tick positions, or
measure structure. Therefore:

- Cursor translation, seek, scrub, and tap-to-seek are unaffected — every
  timing computation (`seconds(at:)`, `notatedDurationSeconds`,
  `effectiveMeasureDurations`) is identical between the original and transposed
  score, so the playback session can keep using the original score for all
  timing/cursor work.
- Tap-to-audition: a tap on the transposed display resolves to a `NoteID` that
  is identical in the original score (IDs are preserved by transpose). The
  engine auditions that note on the original score and the coarse tuning shifts
  it to the displayed pitch — so the heard pitch matches the seen pitch.

This clean separation is the reason the live-tuning approach is safe.

## Components

### swift-sheet-music (worktree — see Workflow)

- **`Score.transposed(bySemitones:)`** in `SheetMusicCore/Score/Score+DisplayTransforms.swift`
  (sibling of `filtered` / `applying(clefOverrides:)`). Shifts key signatures,
  re-spells notes, skips drum/unpitched staves. Pure `Score → Score`.
- **Engine `setTranspose`** support:
  - iOS (`SheetMusicAudioApple`): coarse tuning on non-drum channels via the
    AUMIDISynth coarse-tuning parameter (the semitone register; the A4-calibration
    fine/cents register is left untouched so they compose).
  - Android (FluidSynth): the matching RPN coarse-tuning path (same two-register
    split as calibration).
- **example app**: a transpose test UI (stepper ±7) wired to the engine + a
  rendered transposed score, so the user can verify both engraving and audio
  before anything is pushed.

### Domain (Folino)

- **`PlaybackController.setTranspose(semitones:) async`** added to the protocol
  (`Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift`).
- **`ReaderPreferences`** gains a `transposeSemitones: Int` field (default 0),
  persisted per-score alongside the existing fields.

### Infrastructure (Folino)

- The concrete `PlaybackController` adapter implements `setTranspose` by calling
  the ssm engine's coarse-tuning entry point.

### Reader feature (Folino)

- **`TransposeModel`** (`@MainActor @Observable`), modeled on `TempoModel` /
  `MasterVolumeModel`:
  - `semitones: Int` (clamped −7…+7), default 0.
  - `setValue` / step ± / reset-to-0.
  - `onChange` → `preferencesStore.mutate { prefs.transposeSemitones = … }`.
  - `controllerProvider` → calls `controller.setTranspose(semitones:)` on change.
  - Owned by `ReaderViewModel`; wired in an `wireTransposeModel()` and synced in
    `loadOrSeedPreferences()` (`transposeModel.sync(from: prefs)`).
- **`ReaderRootScreen.content`** applies `.transposed(bySemitones:)` in the
  display pipeline (after clef overrides, before hidden-staves filter), reading
  `viewModel.transposeModel.semitones`.
- **Transpose row** (♯♭ icon + signed readout + `±` Stepper, double-tap resets)
  added to the *General* section of both `PlaybackInspectorScreen` and
  `VisualInspectorScreen`, both bound to the same `TransposeModel`. Factor the
  row into one shared view to avoid divergence.
- **PiP**: `PiPLayoutSnapshot` gains `transposeSemitones`; `currentPiPLayoutSnapshot()`
  populates it; the PiP frame renderer applies the same `transposed(bySemitones:)`
  transform so the PiP overlay matches the main view.

### Android parity

- Both Android inspectors get the mirrored transpose row (content at iOS parity;
  placement follows Android idioms).
- The transpose **logic is shared** — `Score.transposed` lives in ssm (consumed
  by both platforms); the engine `setTranspose` is implemented per-platform
  (iOS coarse tuning / Android FluidSynth RPN) but exposed through the same
  conceptual API. No iOS logic is reimplemented as a divergent Android path.

## Data flow

```
User drags ± stepper (either inspector)
        │
        ▼
   TransposeModel.semitones = N        (clamped −7…+7)
        ├──────────────► onChange ──► preferencesStore.mutate(transposeSemitones = N)   [persist, per-score]
        │
        ├──────────────► controllerProvider().setTranspose(semitones: N)
        │                        └──► engine coarse-tuning on non-drum channels   [AUDIO]
        │
        └──(observation)─► ReaderRootScreen.content re-renders
                                 score.applying(clefOverrides:)
                                      .transposed(bySemitones: N)
                                      .filtered(hidingStaves:)              [DISPLAY]
                                 └──► PiP snapshot picks up N too
```

## Error handling / edge cases

- **Range clamp:** `TransposeModel` clamps to −7…+7; the Stepper enforces the
  same bounds. Out-of-range engine values are clamped by the adapter.
- **MIDI overflow:** `Note.shifted` already returns `nil` when a shifted pitch
  leaves MIDI 0…127. `Score.transposed` must define behavior for that note —
  proposed: keep the note at its un-shiftable extreme rather than dropping it
  (decide during ssm implementation; document in the ssm doc-comment). Audio via
  coarse tuning does not have this clamp issue at ±7 except at the extreme
  octaves of a range, which is acceptable.
- **Drum/unpitched staves:** skipped on both display and audio; coarse tuning is
  not applied to drum channels (it would select a different drum sound).
- **Transposing instruments / concert vs written pitch:** out of scope — the
  user-applied transpose is a uniform shift on top of whatever Folino already
  displays. Not changed by this feature.
- **No score loaded / no controller:** model still updates and persists; engine
  call is a no-op until a controller exists (existing pattern for the other
  models).

## Testing

- **ssm — `Score.transposed`** (Swift Testing): key-signature shift correctness
  (C→D at +2, etc.), note re-spelling matches `Note.shifted` semantics, drum
  staves untouched, note IDs / ticks preserved, MIDI-extreme behavior.
- **ssm — example app**: manual user verification of engraving + audio before push.
- **Folino — `TransposeModel`** (Swift Testing): clamping, persistence round-trip
  via a fake preferences store, `setTranspose` forwarded to a `FakePlaybackController`.
- **Folino — display pipeline**: `ReaderRootScreen` applies the transform in the
  right order; PiP snapshot carries the value.
- **Verification**: iOS via Xcode preview / build (no simulator launch per project
  convention); Android via installDebug + adb launch on Pixel.

## Workflow (per user instructions)

1. **Worktrees before implementation.** Folino work happens in the
   `worktree-transpose` worktree (already created from local main HEAD). The ssm
   work gets its **own worktree** cut when implementation reaches swift-sheet-music.
2. **ssm verification before push.** Before pushing any ssm change, add the
   transpose test UI to the ssm **example app** and hand it to the user for
   hands-on verification. Only after the user approves: push ssm → re-pin Folino
   (`Package.swift` + `project.yml` to the same revision).
3. **Auto-commit** applies (this is a spec/plan-driven new-feature implementation).

## Out of scope (YAGNI)

- Resulting key-name readout (e.g. "C → D") under the stepper — possible later
  enhancement; only meaningful when a score has a single unambiguous key.
- Transposing-instrument concert/written-pitch toggle.
- Per-part / per-staff independent transposition (this is a whole-score shift).
- Octave-only quick buttons or interval-name presets.

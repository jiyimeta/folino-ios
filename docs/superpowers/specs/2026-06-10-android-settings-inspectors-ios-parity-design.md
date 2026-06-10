# Android Settings & Reader Inspectors — Layout Polish + iOS Parity

**Date:** 2026-06-10
**Status:** Approved design (pending spec review)
**Platforms:** Android (Compose). iOS is the parity reference; no iOS changes.

## Problem

The Android Settings screen and the two Reader inspectors (display / playback) have
drifted from iOS in three ways:

1. **Layout inconsistency.** Single-line rows (text + a trailing control) render at
   varying heights because each row sets its own ad-hoc `padding`/`heightIn`. Section
   headers, leading-icon usage, control spacing, and dividers differ between the three
   screens. The result reads as uneven.
2. **Wording & ordering drift.** Row order, section grouping, which screen a feature
   lives on, and the user-facing labels diverge from iOS.
3. **Incomplete localization.** Many Android labels are hardcoded Kotlin string
   literals (`"Metronome"`, `"Volume"`, `"Tempo"`, `"Mixer"`, …) rather than
   `strings.xml` resources, so they are English-only while the rest of the app ships
   ja / ko / zh-rCN / zh-rTW.

## Goals

- Uniform, Material-idiomatic row heights and consistent section styling across the
  three screens.
- Full structural parity with iOS: same row order, same section grouping, same
  feature-to-screen placement, same wording.
- Every user-facing label sourced from `strings.xml`, localized in all five locales,
  mirroring the exact iOS wording (including the existing Japanese translations).

## Non-Goals

- **No control-idiom swap.** The segmented-vs-dropdown difference stays: Android keeps
  the dropdown menu pickers (display mode, playlist continuation) where iOS uses a
  segmented `Picker`. Other Android controls (sliders, steppers) stay unless matching
  iOS is a strict improvement that does not cost Android-ness (decided case-by-case).
- **No engine / playback-semantics changes.** The audio engine, mix model, and
  persistence keys are shared with iOS and stay as-is. Transpose remains persist-only
  on Android (no audio/notation transpose effect yet) — same as today.
- **No new global preferences.** `SettingsKeys.showInvisible` and
  `SettingsKeys.showSeekBar` already exist as global DataStore prefs; the new Settings
  rows surface those existing keys.

## Decisions (locked with the user)

1. **Cross-screen feature placement → full iOS parity.** Move/add features so each
   lives on the same screen(s) as iOS.
2. **Mixer → iOS "Parts" grouped structure.** Group channels by part; one program
   picker per part; per-staff volume/Solo/Mute below.
3. **Controls → keep Android's, except segmented/dropdown stays Android, and match iOS
   where it doesn't hurt Android-ness.**
4. **Version History → iOS-style separate-screen navigation** (not inline).
5. **Playlist continuation row in playback inspector → add** (wire `isInPlaylist`).
6. **Tempo row → iOS two-line design** (glyph marking + ± stepper / percent + slider).

---

## Part 1 — Shared layout system

### Placement

Define the shared row/section scaffold **once** as `public` composables in the
`FolinoReaderAndroid` library module (e.g. a new
`com/keynumber/folino/reader/ui/InspectorRows.kt`). The `app` module already depends on
`FolinoReaderAndroid`, so `SettingsScreen` can reuse them. This avoids triplicating the
scaffold. Placement note: these are pure presentational scaffolds (no Reader logic), so
hosting them in the Reader UI module is acceptable; the alternative (a new shared UI
module) is heavier than this task warrants.

### Building blocks

- **`InspectorRow` (single-line, uniform height).**
  `Modifier.fillMaxWidth().heightIn(min = 48.dp)`, `verticalAlignment = CenterVertically`,
  consistent horizontal content gap (`8.dp`). Slots: optional `leadingIcon`, `label`
  (weight 1f), trailing `control`. **All** single-line rows (Switch, dropdown trigger,
  ± stepper, value+chevron) use this, giving one uniform height. 48.dp = Material
  minimum touch target; the one-line list-item norm.
- **`SliderRow` (the documented exception).** Slider-bearing rows use their own
  consistent height built around the existing `sliderHeight = 24.dp`, not forced to the
  single-line height. Covers Settings A4, display Staff size, playback Volume/Tempo/A4,
  and mixer staff volume.
- **Two-line rows** (subtitle/footer present, e.g. PiP, Keep-awake, crash-reporting,
  SoundFont) keep their own taller height — never collapsed to single-line.
- **`InspectorSectionHeader` / `CollapsibleHeader`.** Unify typography (`titleSmall`),
  vertical padding, and icon treatment. Settings sections stay **non-collapsible** plain
  headers; both inspectors stay **collapsible** (matches iOS Form vs. CollapsibleSection).
  The existing duplicated `CollapsibleHeader` in both inspector files collapses into the
  shared one.

### Leading-icon policy (mirrors iOS)

- **Settings rows:** leading icon (iOS `Label`).
- **Display (visual) inspector rows:** **no** leading icon (iOS has none).
- **Playback inspector General rows:** leading icon (iOS has accent-tinted icons).

### Consistency pass

Single horizontal content padding, single control gap (`8.dp`), single divider inset
applied uniformly across all three screens.

---

## Part 2 — Settings screen (`SettingsScreen.kt`)

Target **Reader** section order (mirrors iOS `readerSection`):

| # | Row | Control | Change from today |
|---|-----|---------|-------------------|
| 1 | Metronome | Switch | — |
| 2 | Picture in Picture | Switch | **add footer subtitle** (iOS has one) |
| 3 | Collapse multi-measure rests | Switch | — |
| 4 | **Show hidden elements** | Switch | **NEW** — surface existing `showInvisible` pref |
| 5 | Keep screen awake | Switch | **rename to iOS wording + add footer subtitle** |
| 6 | **Show seek bar** | Switch | **NEW** — surface existing `showSeekBar` pref |
| 7 | Repeat | RepeatModePicker | — |
| 8 | Playlist | dropdown | — (dropdown kept) |
| 9 | **Default Calibration** (A4) | SliderRow | **restructure**: label "Default Calibration" + tuningfork icon, `A4 = NNNHz` as trailing readout, description caption, slider (iOS layout) |
| 10 | Display mode | dropdown | **rename "Layout" → "Display mode"; move below A4** (dropdown kept) |
| 11 | High quality audio | dynamic | **rename "High-Quality SoundFont" → iOS wording** |

- Add the **section footer** explaining repeat priority (iOS
  `settings.reader.continuation.footer`).
- **Privacy** section: already parity; localize any literals, confirm wording.
- **About** section: now contains **Version History (nav)**, Licenses (nav), Send
  Feedback — matching iOS `aboutSection` order. Version History becomes a navigation
  item (see Part 5).

The `SettingsScreen` composable gains `showInvisible` / `showSeekBar` collected state
(both already on `SettingsPrefs`) and a new `onOpenVersionHistory: (() -> Unit)?`
callback (mirroring `onOpenLicenses`).

---

## Part 3 — Display (visual) inspector (`DisplayInspectorSheet.kt`)

Target **General** section order (mirrors iOS `VisualInspectorScreen`):

1. Display mode (dropdown — kept)
2. Staff size (SliderRow)
3. **Transpose** — **NEW here** (iOS shows Transpose in *both* inspectors via the same
   model). Thread `transposeSemitones` + `onTransposeChange` into `DisplayInspectorSheet`
   and reuse the same `TransposeRow` design as the playback inspector. Persist-only
   (unchanged Android behavior).
4. Follow line and page breaks
5. Collapse multi-measure rests
6. Show hidden elements
7. Show seek bar

**Parts** section: keep current structure (already matches iOS) — no leading icons,
per-staff clef tile + visibility toggle.

---

## Part 4 — Playback inspector (`PlaybackInspectorSheet.kt`)

### General section — target order (mirrors iOS `PlaybackInspectorScreen`)

1. Metronome (leading icon)
2. **Tempo** — **two-line iOS design**: top line = beat-glyph marking + `= BPM`
   (tap-to-reset) + ± stepper; bottom line = `NN%` + whole-BPM slider. Uses the existing
   `openingQuarterBpm`. Beat glyph: use the governing-tempo beat glyph if the Android
   engine exposes it; otherwise fall back to the quarter-note glyph `♩` (note this
   fallback explicitly in code). Stepper commits whole BPM; slider stays in BPM space.
3. Repeat (leading icon)
4. **Playlist continuation** — **NEW**, shown only when `isInPlaylist`. Thread an
   `isInPlaylist` flag + continuation state through the Reader into the sheet; reuse the
   dropdown. Persist-only (continuous playback not yet built on Android — note in code).
5. Volume (master) (leading icon)
6. Transpose (leading icon) — existing `TransposeRow`.
7. Calibration (A4) — existing `A4ReferenceRow` (already mirrors iOS two-line design);
   localize literals only.

### Mixer → "Parts" restructure

Rename the section to iOS's **"Parts"** and regroup:

- **Group** `mixerChannels` by `partIndex`, derived from the existing
  `staffAddressByIndex` map (`StaffAddress.partIndex`). Pass the `parts:
  List<PartDescriptor>` (already available to the display inspector) into the playback
  inspector to supply **part display names** (instrument long name / track name).
- **Per part:** a header row = part name (`titleSmall`/headline) + **one** program
  picker. Selecting a program applies it to **all channels in that part** (iOS
  `ProgramPicker(partIndex:)` semantics). Drums parts show "Drums" instead of a picker.
- **Per staff (below the header):** volume `SliderRow` + Solo + Mute compact toggles.
  Remove the per-staff program picker (it moves to the part header).
- Solo/Mute stay session-only (not persisted), matching iOS and today.
- Keep the light per-row divider for visual grouping.

This is the highest-effort item: it changes how program changes fan out (per-part
instead of per-staff). Verify against a multi-staff part (e.g. Piano) on the emulator.

---

## Part 5 — Version History navigation

Mirror iOS: Version History is a navigation item inside the **About** section that
pushes a dedicated screen.

- Add `onOpenVersionHistory: (() -> Unit)?` to `SettingsScreen`; render it as an
  `InspectorRow` with a chevron (like Licenses) when non-null.
- Extract the existing inline version+bullet rendering into a `VersionHistoryScreen`
  composable.
- The Settings host (MainActivity / nav) wires the new destination the same way it wires
  Licenses. (Investigate the existing Settings/Licenses navigation wiring during
  planning and follow that pattern exactly.)

---

## Part 6 — Localization

Move every hardcoded literal to `strings.xml` and translate in all five locales,
mirroring iOS `.xcstrings` wording (reuse the existing Japanese values verbatim).

**Settings (`app` module `strings.xml`)** — new/renamed keys for: section header
"Reader", Metronome, Picture in Picture (+footer), Collapse multi-measure rests, Show
hidden elements, Keep screen awake (+footer, iOS wording), Show seek bar, Repeat,
Default Calibration (title + description already partly present), Display mode, High
quality audio, the Reader-section footer, Version History, About, Licenses, Send
Feedback, and the SoundFont dialog strings.

**Reader inspectors (`FolinoReaderAndroid` `strings.xml`)** — new keys for: "General",
"Volume", "Tempo", "Metronome", "Parts" (section), "No parts to mix.", "Drums", the A4
±/relative content-descriptions, transpose/repeat (mostly present). Reuse existing
`reader_*` keys where they already exist.

Each new key gets entries in `values/`, `values-ja/`, `values-ko/`, `values-zh-rCN/`,
`values-zh-rTW/`. Japanese values copied from the iOS `.xcstrings` (e.g. メトロノーム,
表示モード, 既定キャリブレーション, 音量, リピート, パート, …).

---

## Verification

- Build: `Scripts/android-build-libs.sh` if needed, then `installDebug` to the
  **emulator** (`emulator-5554`; never the physical Pixel). Launch and inspect all three
  screens per the iOS/Android-parity install+launch rule.
- Visually confirm: uniform single-line row heights; slider rows consistent; section
  headers consistent; row order matches iOS on each screen.
- Functional spot-checks: Show hidden / Show seek bar toggles drive the Reader; A4 row
  restructure still snaps to 432/440; Transpose appears in both inspectors and persists;
  Mixer "Parts" program picker applies per-part across a multi-staff part; Version
  History navigates to its own screen; Tempo two-line stepper/slider/reset behave.
- Locale check: switch the emulator to Japanese and confirm the mirrored wording.

## Risks / open items

- **Tempo beat glyph:** Android may not expose governing-tempo beat glyphs; fall back to
  `♩`. Confirm during implementation whether the shared engine surfaces a beat glyph.
- **Per-part program semantics:** applying one program to all staves in a part is a
  behavior nuance vs. today's per-staff program. This matches iOS; verify it does not
  regress drum parts or single-staff parts.
- **`isInPlaylist` plumbing:** the Reader entry point must know whether it was opened
  from a playlist. If that context is not currently threaded, add it; the continuation
  row is persist-only until continuous playback ships on Android.

## File inventory (expected touch set)

- `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ui/InspectorRows.kt` (new — shared scaffold)
- `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/DisplayInspectorSheet.kt`
- `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/PlaybackInspectorSheet.kt`
- `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt` (thread transpose into display inspector; `isInPlaylist`; parts into playback inspector)
- `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsScreen.kt`
- `Android/app/.../VersionHistoryScreen.kt` (new) + host nav wiring (MainActivity)
- `Android/app/src/main/res/values{,-ja,-ko,-zh-rCN,-zh-rTW}/strings.xml`
- `Android/FolinoReaderAndroid/src/main/res/values{,-ja,-ko,-zh-rCN,-zh-rTW}/strings.xml`

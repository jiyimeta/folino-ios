# Reader Staff Clef Override

Lets the user pick a default clef per staff inside the Reader inspector, persisted per score. Treble / Bass / C-clef variants — including `treble8vb` and `bass8va`, which the user reaches for often. While restructuring the inspector for per-staff visual settings, also moves the existing staff visibility (eye) toggle from the Playback tab to the new Visual tab so per-staff *display* controls live in one place.

## Goals

- Per-staff clef override picker in the Reader inspector's Visual tab.
- Override is purely a display preference: the score's authored opening clef is replaced for rendering, mid-score clef changes are preserved, MIDI playback is unchanged.
- Persisted per score on `ReaderPreferences`. New scores decode with no overrides.
- Move the per-staff visibility (eye) toggle from the Playback tab into the Visual tab's per-staff row.

## Non-Goals

- Overriding mid-score clef changes (only the staff's opening / default clef).
- Adding percussion to the picker (only meaningful for percussion staves; treat as a future ask).
- Pretty SMuFL glyph previews inside the menu rows (rawType label is enough for v1).
- A separate Editor-feature clef picker (Editor is out of scope).
- Touching MIDI rendering, transposition, or pitch data.

## Upstream Dependency

Bumped `swift-sheet-music` to revision `8f96b11096869fc3ebdf1bd84aae8f235d305fc6`, which introduces:

- `Staff.defaultClefType: String?` — first-class field; the layout engine synthesizes the opening clef from this when the first measure has no explicit `<Clef>` element.
- `SetStaffDefaultClef` `EditCommand` — sets / clears `defaultClefType`; returns the inverse for undo.
- `ClefAnchor` — `.staffDefault(StaffAddress)` vs. `.explicit(VoiceElementID)` to identify which clef instance an action targets.

These are additive on the upstream side; Folino built clean against the new revision without source changes.

## Data Model

### `Domain.ReaderPreferences`

Add:

```swift
public var staffClefOverrides: [StaffAddress: String]   // value = NotatedClef.rawType
```

- Same shape as the existing `staffProgramOverrides` and `staffVolumeOverrides`.
- Stored as the `NotatedClef.rawType` string (`"G"`, `"G8vb"`, `"F"`, `"F8va"`, `"alto"`, `"tenor"`, etc.) so `Domain` does not need to depend on `SheetMusicLayout`. The Reader feature converts to/from `NotatedClef` at the use site.
- Absent map entries fall back to the score's own opening clef.
- `Codable` migration: `decodeIfPresent(... ) ?? [:]` so existing persisted rows decode unchanged.
- Initializer drops entries whose rawType is unknown to `NotatedClef(rawType:)` (defensive — prevents a stale, unparseable string from leaking into the layout pipeline).

### Allowed clef rawTypes (v1 picker)

| Section | rawType | Display label |
| --- | --- | --- |
| Treble | `G` | G |
| Treble | `G8va` | G8va |
| Treble | `G8vb` | G8vb |
| Treble | `G15ma` | G15ma |
| Treble | `G15mb` | G15mb |
| Bass | `F` | F |
| Bass | `F8va` | F8va |
| Bass | `F8vb` | F8vb |
| C | `C3` (alto) | Alto |
| C | `C4` (tenor) | Tenor |

Percussion (`PERC`) is excluded from the picker for v1.

### Persistence — `ReaderPreferencesRecord`

Adds one nullable JSON column `staffClefOverridesJSON: String?`. Encoded shape mirrors `staffProgramOverridesJSON` / `staffVolumeOverridesJSON`. SQLite migration step adds the column with default `NULL`; existing rows read as no overrides.

## Score Transformation

New file `Packages/Features/Reader/Sources/Reader/Score+ApplyingClefOverrides.swift`:

```swift
extension Score {
    func applying(clefOverrides: [StaffAddress: String]) -> Score
}
```

Behavior, per `(staff, rawType)`:

- If the staff's measure 0 / voice 0 / element 0 already holds an **explicit** `<Clef>` voice element → rewrite that element's `concertClefType` (and `transposingClefType`) to `rawType`.
- Otherwise → set `Staff.defaultClefType = rawType` on that staff.

This mirrors how the upstream layout engine resolves the staff's opening clef ("explicit measure-0 clef wins, else `defaultClefType`"), so we update whichever path is authoritative for that staff.

Mid-score clef changes (explicit clef voice elements at element index ≥ 1, or in measures ≥ 1) are **not** touched.

The transformation is a pure function over a value-typed `Score`. Calling sites apply it in `ReaderRootScreen` **before** the existing `score.filtered(hidingStaves:)` step, so the override map's `StaffAddress` keys still index against the un-filtered score (`filtered` reindexes surviving staves and would invalidate the keys otherwise). The filter then drops hidden staves from the already-overridden score.

We do not go through the `EditCommand` / undo machinery — `ReaderPreferences` is the system of record for the override, and undo is not meaningful here (the user toggles via the inspector, the inspector itself is the undo target).

## ViewModel API

`ReaderViewModel` gains:

```swift
func effectiveClef(for: StaffAddress) -> String          // override ?? authored opening clef
func hasClefOverride(for: StaffAddress) -> Bool
func setClefOverride(_ rawType: String, for: StaffAddress) async
func clearClefOverride(for: StaffAddress) async
```

- `effectiveClef(for:)` reads `staffClefOverrides[address]` first; falls back to the score's authored opening clef (the explicit measure-0 clef rawType, else `Staff.defaultClefType`, else `"G"`).
- Setters update `preferences.staffClefOverrides`, persist via the existing repository call (same pattern as `setPartProgram` / `setVolume`), and bump any state SwiftUI observes for re-rendering the score.
- `clearClefOverride(for:)` removes the entry — same shape as `clearPartProgramOverride(forPartIndex:)`.

The transformed `Score` flows through the existing render path; no new state plumbing.

## Inspector UX

### Compact (iPhone) — segmented Picker stays as is

Two tabs: **Playback** / **Visual**. The Visual tab is restructured.

### Regular (iPad) — `List` with two `Section`s

Same two sections; the Visual section gets the same restructuring.

### Visual tab — new structure

```
Section: General
  · layoutRow
  · staffSizeRow
  · breakPolicyRow

Section: <Part 1 instrument name>
  ┌──────────────────────────────────────────────────────┐
  │  staff 1                       [Clef ▾]   [Eye]      │
  │  staff 2                       [Clef ▾]   [Eye]      │
  └──────────────────────────────────────────────────────┘

Section: <Part 2 instrument name>
  ┌──────────────────────────────────────────────────────┐
  │  staff 1                       [Clef ▾]   [Eye]      │
  └──────────────────────────────────────────────────────┘
```

- The Part section header reuses the playback tab's `Text(part.instrument.longName ?? part.trackName ?? "-")` style. No program picker on the Visual tab — that stays on the Playback tab where it lives now.
- Each staff row has no left-aligned label. The two controls right-align via `Spacer()`, matching the playback row's visual rhythm.
- `[Clef ▾]` is a `Menu`. Label = effective rawType string (`G`, `G8vb`, `F`, `Alto`, etc.). When override is active, the label text uses `Color.accentColor`; default uses `.primary`.
- `[Eye]` is the existing `EyeIcon` button — same widget, just relocated.

Menu contents:

```
[Reset to score default]                ← only when an override is active
─────
Treble
  G            G8va            G8vb
  G15ma        G15mb
─────
Bass
  F            F8va            F8vb
─────
C
  Alto         Tenor
```

(SwiftUI `Menu` lays items vertically; the table above is just to show grouping.)

`Section { … } header: { Text("Treble") }` per family, mirroring how `programPicker(partIndex:)` already does GM family sections.

### Playback tab — small subtraction

Remove the `visibilityButton(address:)` call from the per-staff row. The row now ends at the M (mute) button.

## Localization

`Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings` adds:

| Key | Default (en) |
| --- | --- |
| `reader.preferences.clef` | Clef |
| `reader.preferences.clef.section.treble` | Treble |
| `reader.preferences.clef.section.bass` | Bass |
| `reader.preferences.clef.section.cClefs` | C |
| `reader.preferences.clef.resetDefault` | Use score's clef |

The clef rawType strings themselves (`G`, `G8vb`, `F`, `F8va`, `Alto`, `Tenor`, …) are notation conventions and stay un-localized.

## Edge Cases

- **Staff has no opening clef event AND no `defaultClefType`.** Layout falls back to `"G"`. Setting `defaultClefType` via the override fixes this case implicitly.
- **Score has an explicit measure-0 clef on staff X but the override matches it.** Rewrite is a no-op write; harmless.
- **Override rawType becomes invalid** (e.g., user data restored from a future version with a clef we no longer support). `NotatedClef(rawType:)` defaults to `.treble` for unknown types; the picker clears the override on next mutation. Initializer's defensive drop covers persisted-data load.
- **Hidden staff with an override.** Override is applied first, then `filtered(hidingStaves:)` drops the staff. The persisted override entry is preserved across show/hide and re-activates the moment the user shows the staff again.
- **Mid-score clef change preceded by an override.** Override changes the opening clef; the mid-score change still applies at its measure. Note positions before the change use the new opening clef, after the change use the authored mid-piece clef. This is the expected and useful behavior.

## Testing

### `Domain` (`ReaderPreferencesTests`)

- Encode → decode round-trip preserves `staffClefOverrides`.
- Decode of legacy JSON without the key yields `[:]`.
- Initializer drops entries whose rawType is unknown to `NotatedClef`.

### `Infrastructure` (`ReaderPreferencesRecordTests`)

- Round-trip via the GRDB record: save → load preserves the map.
- SQLite migration adds the column without dropping data on an existing fixture row.

### `Reader` (`Score+ApplyingClefOverridesTests`)

- No-op when `clefOverrides` is empty (returned `Score` is `==` input).
- Override rewrites an explicit measure-0 clef when present, leaving later clef events untouched.
- Override sets `Staff.defaultClefType` when no explicit measure-0 clef is present.
- Mid-score clef change at measure 3 is preserved across the transform.
- Override targeted at a non-existent staff is a no-op (no crash).

### `Reader` (`ReaderViewModelTests`)

- `setClefOverride` updates `preferences.staffClefOverrides` and persists via the fake repository.
- `clearClefOverride` removes the entry.
- `effectiveClef(for:)` returns the override when set, else the authored opening clef rawType.

UI snapshot / preview verification stays manual — render the inspector via `mcp__xcode__RenderPreview` against `InspectorScreen`'s `#Preview`, confirming Treble / Bass / C sections appear and the Visual tab shows per-staff rows.

## Migration

- `ReaderPreferencesRecord`: SQLite `ALTER TABLE … ADD COLUMN staffClefOverridesJSON TEXT` (nullable). No backfill needed.
- `ReaderPreferences.Codable`: `decodeIfPresent ?? [:]` for the new key.
- No file-format / external-API migrations.

## Out-of-Scope Follow-Ups

- Percussion clef in the picker (only meaningful when the staff is percussion).
- Mid-score clef-change override (would need cursor / measure-pick UI).
- SMuFL Bravura glyph previews inside the menu rows.
- Editor-feature clef picker (Editor's own design, not Reader).

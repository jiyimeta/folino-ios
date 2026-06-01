# Library Metadata Editing — Design

Replace the Library's single-field rename alert with a metadata **edit
sheet** that lets users edit the human-readable metadata of a score
(title, subtitle, composer, arranger, lyricist, copyright) and view a
small set of read-only facts (source format, date added).

Today only the title is editable, via a `TextField` alert
(`LibraryRootRenameScoreAlert`). This work generalizes that into a
proper `Form`-based sheet and adds three new editable fields plus a
read-only info section.

## Goals

- The `…` row menu's "Rename" action is replaced by **"Edit info"**,
  which presents a modal edit sheet. The rename alert is removed; the
  sheet handles the title too.
- **Editable fields (free text):** title, subtitle, composer,
  arranger, lyricist, copyright.
- **Read-only fields:** source format (e.g. "MuseScore 4",
  "MuseScore 3", "MusicXML", "MIDI") and date added.
- Validation: title is the only required field (must be non-empty
  after trimming); Save is disabled while it is empty. All other
  fields are optional and may be cleared.
- Edits persist to the app's own database only — **the original score
  file is never rewritten** (consistent with how title/composer/subtitle
  already work).
- Existing library items (imported before this change) get their new
  fields pre-filled from the on-disk file the first time their sheet is
  opened — no bulk migration.

## Non-goals

- Editing `key` (primaryKey) or `tempo` (defaultTempoBpm). Deferred;
  not shown in this sheet at all.
- Writing metadata back into the score file (MSCX/MusicXML metaTags).
  Edits stay app-local.
- Showing the score's *original* composition/creation date. The score
  files do not carry one that `swift-sheet-music` extracts; the
  read-only "date added" is `ScoreItem.addedAt` (when it entered the
  folino library), labeled accordingly.
- Editing `instrumentationSummary` (a derived value), file size, length,
  content hash, or other system fields.
- A full standalone "score detail" screen. This is a focused edit sheet;
  a detail screen can come later if needed.
- Backfill migration that re-parses every file at update time. Pre-fill
  is lazy/on-open instead.

## Metadata availability (verified against swift-sheet-music)

- `arranger` / `copyright` / `lyricist` are exposed via `Score.metaTags`
  for both MSCX (MuseScore) and MusicXML. MIDI generally carries none of
  these. The app currently reads only `metaTags["composer"]` and discards
  the rest.
- The source format / MuseScore version is **not** stored anywhere; it is
  recovered by parsing the file into `Score.source`
  (`.museScore(.v2|.v3|.v4)`, `.musicXML`, `.midi`, `.pdf`, `.unknown`).
  The existing share path (`LiveScoreShareService`) already re-parses on
  demand to read `Score.source`; this design reuses that same on-demand
  parse for the sheet.

## Data model

Three new optional fields on `ScoreItem` (Domain):

```swift
public var arranger: String?
public var copyright: String?
public var lyricist: String?
```

`ScoreItemRecord` (Infrastructure/Persistence) mirrors them, and a new
**GRDB migration v10** adds the columns:

```sql
ALTER TABLE score_items ADD COLUMN arranger  TEXT;
ALTER TABLE score_items ADD COLUMN copyright TEXT;
ALTER TABLE score_items ADD COLUMN lyricist  TEXT;
```

These follow the same "snapshot from the file at import" model already
used for `composer` / `subtitle`: `LiveScoreFileImporter.commitImport`
populates them from `metaTags` when a new score is imported.

### NULL vs empty-string semantics

The three new columns (and, for the purposes of the sheet, the existing
`composer` / `subtitle`) distinguish two states:

- **NULL** — never set by the user. On sheet open, the field is
  **pre-filled** from the freshly parsed file `metaTags` (see below).
- **`""` (empty string)** — the user explicitly cleared the field. It
  stays empty; pre-fill does not re-populate it.

Rule: **on first Save, all editable fields are written as explicit
values** (an empty editor field is persisted as `""`, not NULL). After a
score has been saved through the sheet once, every editable column is
non-NULL, so pre-fill no longer applies to it. NULL therefore only ever
means "never edited through the sheet", which is exactly the set of
items that benefit from pre-fill (legacy items, and brand-new imports
whose file had no value).

## On-demand parse: source + pre-fill

When the sheet opens, it performs a single parse of the item's on-disk
file (the same `gateway.loadScore`-style call the share path uses) to
obtain:

1. `Score.source` → rendered as the read-only **source** label.
2. `metaTags` (composer, arranger, lyricist, copyright) → used to
   **pre-fill** any editable field whose stored column is NULL.

This means legacy items (imported before v10, NULL columns) display
their file metadata the first time the sheet opens, without a bulk
migration. Once saved, the values are persisted and the parse is no
longer needed for pre-fill (it is still done for the source label).

Source label strings (localized):

| `Score.source`        | Label          |
| --------------------- | -------------- |
| `.museScore(.v4)`     | MuseScore 4    |
| `.museScore(.v3)`     | MuseScore 3    |
| `.museScore(.v2)`     | MuseScore 2    |
| `.musicXML`           | MusicXML       |
| `.midi`               | MIDI           |
| `.pdf`                | PDF            |
| `.unknown`            | Unknown        |

If the parse fails, the source label falls back to a format derived from
the file extension (`ScoreFormat.detect`), and pre-fill is skipped (the
stored columns are shown as-is).

## Architecture

Strict layered. New code lands in Domain, Infrastructure, and
Features/Library.

```
Domain                       Infrastructure                 Features/Library
──────                       ──────────────                 ────────────────
ScoreItem (+3 fields)        ScoreItemRecord (+3 cols)
ScoreMetadataReading  ◀───── LiveScoreMetadataReader ──┐    EditScoreInfoSheet (Views/)
  (source + metaTags)          (wraps ScoreFileGateway)  │   EditScoreInfo wiring (Screens/)
ScoreLibraryRepository                                   │
  .saveScoreItem (reuse)                  App ── injects ─┴──▶ LibraryViewModel.saveMetadata
                                                                          │
                                                                          └─ scoreRowMenu "Edit info"
```

### Domain

A small new protocol lets the Library read source + raw metaTags for an
existing item without depending on Infrastructure or `swift-sheet-music`:

```swift
public struct ScoreFileMetadata: Sendable {
    public let source: ScoreSourceKind   // Domain-side enum mirroring ScoreSource
    public let composer: String?
    public let arranger: String?
    public let lyricist: String?
    public let copyright: String?
}

public protocol ScoreMetadataReading: Sendable {
    func readMetadata(for item: ScoreItem) async throws -> ScoreFileMetadata
}
```

`ScoreSourceKind` is a Foundation-only Domain enum (`.museScore(major:)`,
`.musicXML`, `.midi`, `.pdf`, `.unknown`) so Features never import
`swift-sheet-music`. (Exact shape finalized in the plan; it only needs
enough to render the source label.)

This protocol is consumed by a single Feature (Library), so the API
surface is intentionally minimal.

### Infrastructure

`LiveScoreMetadataReader: ScoreMetadataReading` wraps the existing
`ScoreFileGateway`, calls the same `loadScore` path the share service
uses, and maps `Score.source` + `metaTags` into `ScoreFileMetadata`.

`LiveScoreFileImporter.commitImport` is extended to populate the three
new `ScoreItem` fields from `metaTags` for new imports.

### Features/Library

- `LibraryViewModel`:
  - Remove `rename(_:to:)`.
  - Add `saveMetadata(_ item: ScoreItem, fields: EditableScoreInfo) async`
    that applies the edited fields to the item (title trimmed; empties
    persisted as `""`) and calls the existing `save` → `saveScoreItem`.
  - Add the `ScoreMetadataReading` dependency for source + pre-fill.
- `Views/`: `EditScoreInfoSheet` — a `Form` with two sections:
  - **Section 1 (editable):** Title, Subtitle, Composer, Arranger,
    Lyricist, Copyright. Copyright is a multi-line `TextField`
    (`axis: .vertical`) since MusicXML rights can contain newlines.
  - **Section 2 (info, read-only):** Source, Date added.
  - Toolbar: Cancel / Save. Save disabled while trimmed title is empty.
- `Screens/`: wiring that loads the item + on-open metadata, presents the
  sheet, and calls `viewModel.saveMetadata`. The `…` menu's rename action
  becomes "Edit info" and opens this sheet.

Follows the Library feature's existing `Screens/` + `Views/` split.

## Data flow

```
User taps "…" → "Edit info"
   ↓
Screen presents EditScoreInfoSheet, kicks off readMetadata(for: item)
   ↓
LiveScoreMetadataReader.loadScore → Score.source + metaTags
   ↓
Sheet initial values:
   editable field = stored column if non-NULL, else metaTags value (pre-fill)
   source label   = Score.source
   date added     = item.addedAt
   ↓
User edits, taps Save
   ↓
LibraryViewModel.saveMetadata: apply fields (title trimmed; empties → "")
   ↓
ScoreLibraryRepository.saveScoreItem → GRDB write (app DB only)
   ↓
@Observable snapshot updates the list row
```

## Error handling

- **Parse failure on open:** source label falls back to extension-derived
  format; pre-fill skipped; stored columns shown as-is. The sheet remains
  fully usable (editing/saving does not require the parse to succeed).
- **Empty title on Save:** Save button disabled; cannot be submitted.
- **Persistence failure:** surfaced the same way the existing
  rename/save path surfaces `DomainError.persistenceFailed` (no new error
  UI introduced).

## Localization

- Keys follow the `module.feature.thing` scheme. Field labels and the
  sheet title live in the Library namespace; any genuinely shared term
  reuses `UtilityUI` `L10n.Common`.
- "Date added" — Japanese **「追加日時」**; other languages adjusted to
  each language's idiom while keeping a comparable display width.
- Source labels (MuseScore 4 / 3 / 2, MusicXML, MIDI, PDF, Unknown) are
  localized; brand names like "MuseScore" stay as-is.

## Testing

- **Domain:** `ScoreItem` round-trips the three new fields
  (Codable / equality).
- **Infrastructure:**
  - GRDB v10 migration adds the columns and existing rows read back NULL.
  - `LiveScoreFileImporter` populates arranger/copyright/lyricist from a
    fixture file's metaTags on import.
  - `LiveScoreMetadataReader` maps a fixture's `Score.source` + metaTags
    into `ScoreFileMetadata`.
- **Features/Library:** against a fake `ScoreMetadataReading` +
  `ScoreLibraryRepository`:
  - NULL column → pre-filled from fake metadata; non-NULL column →
    stored value wins (no pre-fill).
  - Cleared field saved as `""`, and a subsequent open does not re-fill
    it.
  - Empty trimmed title blocks save; valid edit calls `saveScoreItem`
    with the expected item.
  - Parse failure → editing still works, source falls back.

## Risks / open points

- `ScoreSourceKind` shape: must mirror enough of `swift-sheet-music`'s
  `ScoreSource` to render the label without leaking the dependency into
  Features. Finalized in the plan.
- Per-open parse cost: acceptable because the sheet is opened
  deliberately (same trade-off the share menu already accepts), but it
  should run off the main actor and not block sheet presentation — show
  the sheet immediately, fill source/pre-fill when the parse returns.

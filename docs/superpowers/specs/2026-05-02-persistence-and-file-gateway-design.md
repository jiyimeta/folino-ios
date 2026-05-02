# Persistence and File Gateway — Design

**Status:** Ready for plan
**Date:** 2026-05-02
**Plan #:** 3

## Goal

Land Folino's local library persistence and the bridge to `swift-sheet-music`'s format I/O. After this work the app can:

- Persist score items, tags, and playlists in a local SQLite database via GRDB.
- Detect, parse, and round-trip score files (.mscx / .mscz / .musicxml / .mxl / .mid) through the `ScoreFileGateway`.
- Import a file from a source URL with SHA-256 duplicate detection and a two-stage commit API.
- Drive Library / Reader UI from observable repository state (no manual re-fetch wiring).

It does **not** include: Annotations persistence, Soundfont cache, Playback preferences persistence, CloudKit sync, or any Feature-layer UI. Those land in their own plans.

## Architectural decisions

### D1. Tag / playlist relations are normalized

`ScoreItem.tagIDs: Set<TagID>` and `Playlist.items: [ScoreItemID]` are persisted in junction tables (`score_item_tags`, `playlist_items`), not JSON columns.

**Why:** Folino's expected query patterns (filter library by tag, list playlists containing an item) are reverse lookups that benefit from indexes on the join column. Foreign-key cascades guarantee referential integrity. CloudKit's record-shape becomes "one record per row", which is the natural granularity for partial sync.

### D2. PDF is rejected at the import boundary in v1

`ScoreFormat.pdf` is removed from the enum entirely (along with its `canonicalExtension` and `detect(filename:)` arms). `ScoreFormat.detect(filename: "x.pdf")` returns `nil`; the importer maps `nil` to `DomainError.unsupportedFormat`. PDF support — both the enum case and any reader path — is deferred to a later plan that introduces OCR (v2+); reintroducing the case is a few-line change and is more cohesive when added together with the feature that uses it.

### D3. Duplicates allowed; user-confirmed via two-stage import API

`ScoreFileImporter` exposes `prepareImport` → `commitImport`. `prepareImport` reads the file once, computes SHA-256, asks the repository for matches, and returns an `ImportPlan` carrying the duplicates list. The Feature layer renders a dialog when duplicates exist; the user picks `.importAsNew` or `.openExisting(id)`; `commitImport` applies that choice. Hash collisions never silently merge — duplicates persist as distinct `ScoreItem`s when the user opts in. The hash column is non-unique.

### D4. `ScoreLibraryRepository` is observable single-layer

The protocol becomes `@MainActor + AnyObject + Observable`. Concrete impl (`LiveScoreLibraryRepository`) is `@Observable @MainActor final class`, holds `[ScoreItem]` / `[Tag]` / `[Playlist]` as observed properties, and refreshes them via GRDB `ValueObservation`. UI consumers read the properties directly — no `AsyncSequence`, no manual refetch wiring. We do not introduce a separate Store layer; if filter/derived-state logic accumulates later, a Store can be added on top without changing the protocol.

### D5. `ScoreItem.format` is removed

The Plan #2 `ScoreItem` had a `format: ScoreFormat` field that duplicated state with `localFileName`'s extension. Plan #3 deletes it. The convention "`localFileName == <id>.<canonical-extension>`" is enforced at import; consumers derive format via `ScoreFormat.detect(filename: item.localFileName)`. Single source of truth on disk.

### D6. `ScoreFileGateway` adds `loadFileMetadata`

A new entry point that returns `ScoreFileSummary` only — no `Score`. Used by import (which only needs metadata) without forcing the importer to parse the full notation tree. `loadScore` is reserved for Reader / Editor use.

### D7. `AnnotationStore` impl is deferred

Plan #2 defined the protocol; this plan does not implement it. AnnotationStore lands together with the Annotations feature (later plan) so the persistence schema and the consumer feature evolve as one unit.

## Module layout

```
Packages/Infrastructure/Sources/Persistence/
  Database/
    AppDatabase.swift              # DatabasePool construction + migrator wiring
    Migrations.swift               # v1 schema migration
  Records/
    ScoreItemRecord.swift          # GRDB struct (FetchableRecord + PersistableRecord)
    TagRecord.swift
    PlaylistRecord.swift
    ScoreItemTagRecord.swift       # junction
    PlaylistItemRecord.swift       # junction
  LiveScoreLibraryRepository.swift # @Observable @MainActor final class
  LiveScoreFileImporter.swift      # importer (hash + copy + repository)

Packages/Infrastructure/Sources/ScoreFiles/
  LiveScoreFileGateway.swift       # ScoreFileGateway implementation
  ScoreFileSummary+Score.swift     # Score → ScoreFileSummary extraction helpers
```

`Persistence` and `ScoreFiles` are independent SPM products inside the `Infrastructure` package. The importer composes a `ScoreFileGateway` (Domain protocol) and a `ScoreLibraryRepository` (Domain protocol) — Persistence does not import the ScoreFiles target. Wiring happens in App.

## Domain protocol changes

These changes overwrite Plan #2 protocol definitions. Plan #2 has no adopters yet, so the changes are non-breaking at the consumer level.

### `ScoreLibraryRepository`

```swift
@MainActor
public protocol ScoreLibraryRepository: AnyObject, Observable {
    var scoreItems: [ScoreItem] { get }
    var tags: [Tag] { get }
    var playlists: [Playlist] { get }

    /// Initial load. Idempotent — safe to call again to force a re-sync.
    func refresh() async throws

    func saveScoreItem(_ item: ScoreItem) async throws
    func deleteScoreItem(id: ScoreItemID) async throws

    func saveTag(_ tag: Tag) async throws
    func deleteTag(id: TagID) async throws

    func savePlaylist(_ playlist: Playlist) async throws
    func deletePlaylist(id: PlaylistID) async throws

    /// Used by the importer for duplicate detection.
    func scoreItems(matchingContentHash contentHash: String) async throws -> [ScoreItem]
}
```

Removed: `allScoreItems()`, `scoreItem(id:)`, `allTags()`, `allPlaylists()`. Single-item lookup by ID is done by the consumer against the observed array (`scoreItems.first { $0.id == id }`).

### `ScoreFileGateway`

```swift
public protocol ScoreFileGateway: Sendable {
    func detectFormat(fileName: String) -> ScoreFormat?

    /// Throws `DomainError.unsupportedFormat` for unknown extensions (PDF included
    /// — `.pdf` is not a `ScoreFormat` case in v1).
    func loadFileMetadata(fileURL: URL) async throws -> ScoreFileSummary

    /// Throws `DomainError.unsupportedFormat` for unknown extensions.
    func loadScore(fileURL: URL) async throws -> (score: Score, summary: ScoreFileSummary)

    /// v1 supports `.mscx` / `.mscz` writes. Other formats throw `.unsupportedFormat`.
    func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) async throws
}
```

### `ScoreFileImporter` (new)

```swift
public struct ImportPlan: Hashable, Sendable {
    public let sourceURL: URL
    public let format: ScoreFormat
    public let summary: ScoreFileSummary
    public let contentHash: String
    public let sizeBytes: Int64
    public let duplicates: [ScoreItem]
}

public enum ImportDecision: Hashable, Sendable {
    case importAsNew
    case openExisting(ScoreItemID)
}

public protocol ScoreFileImporter: Sendable {
    func prepareImport(sourceURL: URL) async throws -> ImportPlan
    func commitImport(_ plan: ImportPlan, decision: ImportDecision) async throws -> ScoreItem
}
```

### `ScoreItem`

`format: ScoreFormat` is removed. `localFileName` remains; consumers call `ScoreFormat.detect(filename: item.localFileName)` when format is needed.

### `ScoreFormat`

The `.pdf` case is removed (along with its `canonicalExtension` and `detect(filename:)` arms). The enum's v1 cases are: `.mscx`, `.mscz`, `.musicXML`, `.mxl`, `.midi`. `ScoreFormat.detect(filename:)` returns `nil` for `.pdf` and every other unknown extension. Plan #2 tests that exercised `.pdf` are updated.

## Database schema (v1 migration)

```sql
CREATE TABLE score_items (
  id                       TEXT    PRIMARY KEY,
  title                    TEXT    NOT NULL,
  composer                 TEXT,
  instrumentation_summary  TEXT,
  local_file_name          TEXT    NOT NULL,
  content_hash             TEXT    NOT NULL,
  size_bytes               INTEGER NOT NULL,
  length_beats             INTEGER NOT NULL,
  default_tempo_bpm        INTEGER NOT NULL,
  primary_key              TEXT,
  added_at                 REAL    NOT NULL,
  last_opened_at           REAL,
  is_favorite              INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX idx_score_items_content_hash ON score_items(content_hash);
CREATE INDEX idx_score_items_last_opened_at ON score_items(last_opened_at DESC);

CREATE TABLE tags (
  id          TEXT    PRIMARY KEY,
  name        TEXT    NOT NULL,
  color_hex   TEXT,
  sort_order  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE playlists (
  id          TEXT    PRIMARY KEY,
  name        TEXT    NOT NULL,
  sort_order  INTEGER NOT NULL DEFAULT 0,
  created_at  REAL    NOT NULL
);

CREATE TABLE score_item_tags (
  score_item_id  TEXT NOT NULL REFERENCES score_items(id) ON DELETE CASCADE,
  tag_id         TEXT NOT NULL REFERENCES tags(id)        ON DELETE CASCADE,
  PRIMARY KEY (score_item_id, tag_id)
);
CREATE INDEX idx_score_item_tags_tag_id ON score_item_tags(tag_id);

CREATE TABLE playlist_items (
  playlist_id    TEXT    NOT NULL REFERENCES playlists(id)   ON DELETE CASCADE,
  score_item_id  TEXT    NOT NULL REFERENCES score_items(id) ON DELETE CASCADE,
  position       INTEGER NOT NULL,
  PRIMARY KEY (playlist_id, score_item_id)
);
CREATE INDEX idx_playlist_items_playlist_id_position ON playlist_items(playlist_id, position);
```

### Schema notes

- IDs are stored as `TEXT` (UUID strings). GRDB does not have a native UUID column; string is the conventional representation and round-trips cleanly via `ScoreItemID.rawValue`.
- Timestamps are `REAL` (Unix epoch seconds, `Date.timeIntervalSince1970`). Timezone-less, comparable.
- Booleans are `INTEGER 0/1`.
- `primary_key` is the musical key (e.g. "C", "Em"); the schema column name uses `primary_key` because `key` is a reserved word in some SQL dialects (kept for portability).
- No `format` column on `score_items` — derived from `local_file_name` extension.
- No `PlaybackPreferences` / `SoundfontPatch` tables — those land in a later plan together with the Audio / Soundfonts modules.

### Domain ↔ DB translation

`ScoreItem` is a pure Domain value type. Persistence defines a parallel `ScoreItemRecord: FetchableRecord, PersistableRecord` (one-row mirror) and translates with `init(domain:)` / `func toDomain(tagIDs:) -> ScoreItem`. Tag IDs come from a separate `score_item_tags` query. Playlist items come from a `playlist_items` query ordered by `position`. Domain stays free of GRDB.

## Data flows

### Import

1. Feature/ImportExport receives a source URL (Files.app, share sheet, drag-drop).
2. `importer.prepareImport(sourceURL:)`:
   - Hash the file with CryptoKit `SHA256` while reading it (single pass).
   - Detect format from filename. `nil` → throw `unsupportedFormat` (PDFs and other unknown extensions all map to `nil`).
   - Call `gateway.loadFileMetadata(fileURL: sourceURL)` for summary.
   - Call `repository.scoreItems(matchingContentHash:)` for duplicates.
   - Return `ImportPlan`.
3. Feature decides:
   - `plan.duplicates.isEmpty` → auto `decision = .importAsNew`.
   - Otherwise show dialog → user picks `.importAsNew` / `.openExisting(id)` / cancels.
4. `importer.commitImport(plan, decision:)`:
   - `.openExisting(id)` → return existing item; no FS / DB writes.
   - `.importAsNew`:
     - Generate `ScoreItemID()`.
     - `localFileName = "\(id.rawValue).\(plan.format.canonicalExtension)"`.
     - Copy `plan.sourceURL` → `AppPaths.scoresDirectory.appending(path: localFileName)`.
     - Build `ScoreItem` from `plan.summary` + computed values.
     - Call `repository.saveScoreItem(_)`.
     - On any failure after the copy, delete the copied file (`defer` cleanup).
5. `repository.scoreItems` updates via ValueObservation; SwiftUI re-renders.

### Read (Reader open)

1. Feature/Reader receives a `ScoreItem` from the observed `repository.scoreItems`.
2. Resolve URL = `AppPaths.scoresDirectory.appending(path: item.localFileName)`.
3. `gateway.loadScore(fileURL:)` → `(Score, ScoreFileSummary)`.
4. Reader hands `Score` to `SheetMusicUI` (built in a later plan).
5. `repository.saveScoreItem(item.with(lastOpenedAt: now))` updates the row; ValueObservation re-emits.

Plan #3 ships steps 2–3 and the `lastOpenedAt` write path. The Reader UI itself is out of scope.

### Mutate (tag / favorite / rename)

1. Feature builds a modified `ScoreItem` value (struct copy with field changed).
2. `repository.saveScoreItem(updatedItem)`.
3. `LiveScoreLibraryRepository`:
   - GRDB write on the writer queue (background).
   - `ValueObservation` re-fires on next snapshot.
   - Callback hops to main; `@Observable scoreItems` is reassigned.
4. SwiftUI re-renders.

### ValueObservation lifecycle

`LiveScoreLibraryRepository` holds a single `Task` that consumes `observation.values(in: database)` and writes into the `@Observable` properties. The task is started lazily on the first `refresh()` call and cancelled in `deinit`. Multiple `refresh()` calls after the first are no-ops (the observation is already live).

## Error handling

| Layer | Failure | Surfaced as |
|---|---|---|
| ScoreFiles | parse failure | `DomainError.fileCorrupt` |
| ScoreFiles | unknown extension / PDF | `DomainError.unsupportedFormat` |
| Persistence | GRDB write / read | `DomainError.persistenceFailed(underlying:)` |
| Importer | hash / copy / FS | `DomainError.fileSystemFailed(underlying:)` |
| Importer | unsupported source | `DomainError.unsupportedFormat` (re-thrown) |

The existing `DomainError` cases (Plan #2) cover everything; no new cases added.

## Testing strategy

### Domain

- `ScoreItem` tests updated for the removed `format` field.
- `ImportPlan` / `ImportDecision` Sendable + Hashable conformance verified.

### Persistence

GRDB tests use `DatabaseQueue.makeShared` against an in-memory database (`":memory:"`). Each `@Suite` creates a fresh queue.

- Migration v1: applies cleanly, expected tables / indexes / FKs exist. Calling `migrator.migrate(database)` a second time does not raise and leaves the schema unchanged (GRDB's DatabaseMigrator tracks applied migrations internally).
- `LiveScoreLibraryRepository`:
  - Empty `scoreItems` after `refresh()` on empty DB.
  - Round-trip a `ScoreItem` (save → observed array reflects it → fields equal).
  - Tag relations: save item with `tagIDs`, observed `scoreItems[0].tagIDs` equals input.
  - FK cascade: delete a `Tag` → relation rows gone, `ScoreItem.tagIDs` no longer contains it.
  - Playlist position: insert items with positions [2, 0, 1], observed `playlist.items` is in [0,1,2] order.
  - `scoreItems(matchingContentHash:)` returns all matches (multiple duplicates allowed).
  - Concurrent writes via `withTaskGroup` succeed (DatabasePool serializes writes).
- `LiveScoreFileImporter` (real DB + tmpdir + Fake `ScoreFileGateway`):
  - Fresh import: `prepareImport.duplicates.isEmpty`, `commitImport(.importAsNew)` produces one row + one file.
  - Duplicate detection: re-import same bytes → `prepareImport.duplicates.count == 1`.
  - `.openExisting(id)`: no new file, no new row.
  - localFileName follows `<id>.<canonicalExtension>` exactly.
  - Save failure rollback: stub repository to throw; copied file is removed by `defer`.
  - `.pdf` source URL → `prepareImport` throws `unsupportedFormat` (via `nil` from `detect`).
  - Extension-less file → `prepareImport` throws `unsupportedFormat`.

### ScoreFiles

Fixtures in `Packages/Infrastructure/Tests/InfrastructureTests/Resources/`: minimal valid `.mscx`, `.mscz`, `.musicxml`, `.mxl`, `.mid`. A few KB each.

- `loadFileMetadata`: returns a `ScoreFileSummary` with non-empty `instrumentationSummary` and positive `lengthBeats` for each fixture.
- `loadScore`: returns a non-empty `Score` (`parts.isEmpty == false`) for each.
- `.pdf` URL → `loadFileMetadata` and `loadScore` throw `unsupportedFormat` (the gateway uses `ScoreFormat.detect` which returns `nil` for `.pdf`).
- Corrupt MSCX → throws `fileCorrupt`.
- `saveScore(_, fileURL:, format: .mscz)` round-trip: write a Score, read it back, parts/staves match.

Engine-level correctness (notation parsing fidelity) is the responsibility of swift-sheet-music's own tests, not Folino's.

### App

Plan #3 adds `LiveScoreLibraryRepository` / `LiveScoreFileGateway` / `LiveScoreFileImporter` instantiation in `AppBootstrap`. Confirm `xcodebuild` BUILD SUCCEEDED + `xcrun simctl install` + launch produces a running app. No Feature UI changes yet.

### Test scaffolding

- Swift Testing (`@Suite`, `@Test`, `#expect`) per project convention.
- `Packages/Infrastructure/.swiftlint.yml` shim (mirroring the Plan #2 errata for Domain).
- Tmpdir helpers in a small `TestSupport` directory inside `Tests/InfrastructureTests/`.

## Out of scope

- Annotations persistence (Plan #4 candidate, with Annotations feature).
- Playback preferences / Soundfont patch persistence (Plan with Audio + Soundfonts modules).
- CloudKit sync (separate plan; will reuse the Repository surface).
- Library / Reader / Editor UI.
- File deletion UI (the repository supports `deleteScoreItem` but the actual file removal from `AppPaths.scoresDirectory` happens at delete time inside the repository — covered in Plan #3).
- Multi-DB-version migration testing (only v1 exists yet; the migrator is in place for future versions).

## Risk register

- **GRDB ValueObservation + @Observable interplay** — first time we wire a ValueObservation `AsyncSequence` into an Observable class. Mitigation: explicit Persistence test that writes from one Task and asserts the observed property updates within a short timeout on the main actor.
- **CryptoKit hashing on large files** — large MSCZ archives could be slow to hash on main. Mitigation: `prepareImport` is async and the hashing is wrapped in a `Task.detached` block so it runs off main.
- **Sandbox file URL access** — share-sheet URLs require `startAccessingSecurityScopedResource()`. Mitigation: the importer wraps the source URL in a scoped-access block before reading; tests cover both scoped and unscoped URLs.
- **Plan #2 `ScoreItem.format` adopters** — Plan #2 tests reference `format`. Mitigation: Plan #3 explicitly migrates these tests as part of the Domain change task.

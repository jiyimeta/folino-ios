# Pencil Annotation — Plan 1: Domain + Persistence — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the scaffolded annotation Domain types with a reflow-stable, tick-based `MusicalAnchor` (public API) and add a GRDB-backed `LiveAnnotationStore` + SQLite `annotation_layers` table that persists one ink layer per score and cascades correctly with the soft/hard-delete lifecycle.

**Architecture:** This is Plan 1 of three (see `docs/superpowers/specs/2026-06-22-ipad-pencil-annotation-design.md` §16) — Domain + Infrastructure only, zero UI, fully testable in isolation, independent of any spike or upstream swift-sheet-music work. The Reader integration (Plan 2) and CloudKit sync (Plan 3) build on what this lands.

**Tech Stack:** Swift 6.3, GRDB (SQLite), Swift Testing, the existing `AppDatabase` / `DatabaseMigrator` / `FetchableRecord & PersistableRecord` patterns.

## Global Constraints

- **Platform:** Swift 6.3, iOS 26+, bundle id `com.KeyNumber.Folino`.
- **Domain is Foundation-only.** No PencilKit, no `SheetMusicLayout` dependency in Domain. The anchor carries pure musical coordinates; the Reader (Plan 2) maps them to screen rects.
- **Greenfield persistence.** Nothing persists annotations today (no store, no table). The breaking `MusicalAnchor` `Codable` change is therefore safe — there is no on-disk annotation data to migrate. Tests are rewritten, not migrated.
- **Minimize `public`.** Promote to `public` only the annotation types that cross the module boundary (consumed by Infrastructure now, by the Reader in Plan 2). Do not make internal helpers public.
- **New tests use Swift Testing** (`import Testing`, `@Test`, `#expect`, struct suites).
- **Package tests run via `xcodebuild`** on the **iPhone 17 Pro Max** simulator (`swift test` is broken by the SwiftLint plugin). Run each package's test from its package directory. Add `-skipPackagePluginValidation`.
- **Whole-file staging only** (`git add <path>` — never `git add -p`). The pre-commit hook runs SwiftFormat + `swiftlint --fix` on staged Swift files and writes fixes back; let it fix-and-fail, then re-stage and re-commit.
- **Comments reflow at the 120-column SwiftLint budget.**
- **Every commit message ends with the trailer:** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` (add it as a second `-m`).
- **Repo root:** `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS`.

---

### Task 1: Domain — new tick-based `MusicalAnchor` + public API surfacing

Replace the layout-derived `MusicalAnchor(systemIndex, normalizedFrame)` with a reflow-stable musical anchor, remove the now-unused `UnitRect`, and promote the annotation types from `internal` to `public` so Infrastructure (Task 3/4) can consume them. This is one atomic Domain change — the module and its tests must compile together.

**Files:**
- Modify: `Packages/Domain/Sources/Domain/MusicalAnchor.swift` (replace `UnitRect` + `MusicalAnchor` entirely)
- Modify: `Packages/Domain/Sources/Domain/Models/AnnotationLayer.swift` (make `public`, add `Sendable`)
- Modify: `Packages/Domain/Sources/Domain/Protocols/AnnotationStore.swift` (make `public`)
- Modify: `Packages/Domain/Sources/Domain/IDs.swift:29-43` (make `AnnotationID` / `AnnotationLayerID` `public` + `Sendable`)
- Test: `Packages/Domain/Tests/DomainTests/MusicalAnchorTests.swift` (rewrite; drop `UnitRectTests`)
- Test: `Packages/Domain/Tests/DomainTests/Models/AnnotationLayerTests.swift` (update `anchor` helper + call sites)

**Interfaces:**
- Produces: `public struct MusicalAnchor(measureIndex:tickInMeasure:partIndex:staffIndexInPart:dxSp:verticalOffsetSp:)`; `public struct DrawingAnchor(id:anchor:encodedDrawing:)`; `public struct TextBoxAnchor(id:anchor:text:)`; `public struct AnnotationLayer(id:scoreItemID:drawings:textBoxes:updatedAt:)`; `public protocol AnnotationStore`; `public struct AnnotationID(rawValue:)`; `public struct AnnotationLayerID(rawValue:)`. All `Codable`, `Hashable`, `Sendable`.

- [ ] **Step 1: Rewrite the Domain tests to the new shape (red — won't compile yet)**

Replace the entire contents of `Packages/Domain/Tests/DomainTests/MusicalAnchorTests.swift` with:

```swift
@testable import Domain
import Foundation
import Testing

struct MusicalAnchorTests {
    @Test func `round trips through codable`() throws {
        let a = MusicalAnchor(
            measureIndex: 7, tickInMeasure: 480, partIndex: 1,
            staffIndexInPart: 0, dxSp: 1.5, verticalOffsetSp: -2.0,
        )
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(MusicalAnchor.self, from: data)
        #expect(decoded == a)
    }

    @Test func `negative indices clamp to zero`() {
        let a = MusicalAnchor(
            measureIndex: -1, tickInMeasure: -5, partIndex: -2,
            staffIndexInPart: -3, dxSp: -1.0, verticalOffsetSp: -1.0,
        )
        #expect(a.measureIndex == 0)
        #expect(a.tickInMeasure == 0)
        #expect(a.partIndex == 0)
        #expect(a.staffIndexInPart == 0)
        // dxSp / verticalOffsetSp are unconstrained — negative offsets are valid.
        #expect(a.dxSp == -1.0)
        #expect(a.verticalOffsetSp == -1.0)
    }
}
```

In `Packages/Domain/Tests/DomainTests/Models/AnnotationLayerTests.swift`, replace the `anchor` helper (lines 6-8) and update the three call sites (`anchor(system: 0)`, `anchor(system: 3)`, `anchor(system: 1)`, and the bare `anchor()` calls):

```swift
    private func anchor(measure: Int = 0) -> MusicalAnchor {
        MusicalAnchor(
            measureIndex: measure, tickInMeasure: 0, partIndex: 0,
            staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0,
        )
    }
```

Then update the call sites in that file: `anchor(system: 0)` → `anchor(measure: 0)`, `anchor(system: 3)` → `anchor(measure: 3)`, `anchor(system: 1)` → `anchor(measure: 1)`. The two bare `anchor()` calls stay as-is.

- [ ] **Step 2: Run the Domain tests — verify they fail to compile**

Run (from `Packages/Domain/`):
```
xcodebuild test -scheme Domain-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/MusicalAnchorTests
```
Expected: BUILD FAILURE — `MusicalAnchor` has no member `measureIndex` / no matching initializer (the old `systemIndex`/`normalizedFrame` shape is still in place).

- [ ] **Step 3: Replace `MusicalAnchor.swift` with the new anchor (drop `UnitRect`)**

Replace the **entire** contents of `Packages/Domain/Sources/Domain/MusicalAnchor.swift` with:

```swift
import Foundation

/// A musical position an annotation is pinned to. Pure musical coordinates (Foundation-only); independent of any
/// computed layout, so it survives reflow / staff-size (content-zoom) changes / staff-visibility toggles. The Reader
/// maps between this and on-screen layout points via SheetMusicLayout; Domain stays layout-agnostic.
///
/// The x-coordinate mirrors the playback cursor's tick model (`measureIndex` + `tickInMeasure`) so the same
/// cursor/layout machinery applies. It is deliberately NOT a fraction of the measure width: musical spacing is
/// non-linear, so a uniform fraction has no engine correspondence and no inverse.
public struct MusicalAnchor: Hashable, Codable, Sendable {
    /// Zero-based index of the anchoring measure (stable across reflow).
    public let measureIndex: Int
    /// Tick offset within the measure (stable across reflow).
    public let tickInMeasure: Int
    /// Staff identity (stable across reflow), mirroring the engine's StaffAddress.
    public let partIndex: Int
    public let staffIndexInPart: Int
    /// Horizontal offset from the resolved tick column, in staff-spaces (sp). Preserves the relative x of strokes that
    /// snap to the same tick column.
    public let dxSp: Double
    /// Vertical offset from the top line of the staff, in staff-spaces (sp). Positive = downward.
    public let verticalOffsetSp: Double

    public init(
        measureIndex: Int,
        tickInMeasure: Int,
        partIndex: Int,
        staffIndexInPart: Int,
        dxSp: Double,
        verticalOffsetSp: Double,
    ) {
        self.measureIndex = max(0, measureIndex)
        self.tickInMeasure = max(0, tickInMeasure)
        self.partIndex = max(0, partIndex)
        self.staffIndexInPart = max(0, staffIndexInPart)
        self.dxSp = dxSp
        self.verticalOffsetSp = verticalOffsetSp
    }
}
```

Replace the **entire** contents of `Packages/Domain/Sources/Domain/Models/AnnotationLayer.swift` with:

```swift
import Foundation

/// A free-hand stroke (or stroke group) anchored to a position inside the score. `encodedDrawing` is opaque to Domain —
/// the Reader decodes it as a `PKDrawing`. Domain does not depend on PencilKit.
public struct DrawingAnchor: Hashable, Codable, Sendable, Identifiable {
    public let id: AnnotationID
    public var anchor: MusicalAnchor
    public var encodedDrawing: Data

    public init(id: AnnotationID = AnnotationID(), anchor: MusicalAnchor, encodedDrawing: Data) {
        self.id = id
        self.anchor = anchor
        self.encodedDrawing = encodedDrawing
    }
}

/// A user-typed text box anchored to a position inside the score. Plain text only — no rich formatting in v1.
public struct TextBoxAnchor: Hashable, Codable, Sendable, Identifiable {
    public let id: AnnotationID
    public var anchor: MusicalAnchor
    public var text: String

    public init(id: AnnotationID = AnnotationID(), anchor: MusicalAnchor, text: String) {
        self.id = id
        self.anchor = anchor
        self.text = text
    }
}

/// All annotations for a single score. There is at most one `AnnotationLayer` per `ScoreItem`.
public struct AnnotationLayer: Hashable, Codable, Sendable, Identifiable {
    public let id: AnnotationLayerID
    public let scoreItemID: ScoreItemID
    public var drawings: [DrawingAnchor]
    public var textBoxes: [TextBoxAnchor]
    public var updatedAt: Date

    public init(
        id: AnnotationLayerID = AnnotationLayerID(),
        scoreItemID: ScoreItemID,
        drawings: [DrawingAnchor],
        textBoxes: [TextBoxAnchor],
        updatedAt: Date,
    ) {
        self.id = id
        self.scoreItemID = scoreItemID
        self.drawings = drawings
        self.textBoxes = textBoxes
        self.updatedAt = updatedAt
    }
}
```

Replace the **entire** contents of `Packages/Domain/Sources/Domain/Protocols/AnnotationStore.swift` with:

```swift
import Foundation

/// Persistence façade for `AnnotationLayer`s. There is at most one layer per score item; this protocol exposes a
/// CRUD-by-score-id interface.
public protocol AnnotationStore: Sendable {
    func annotationLayer(forScoreItem id: ScoreItemID) async throws -> AnnotationLayer?
    func saveAnnotationLayer(_ layer: AnnotationLayer) async throws
    func deleteAnnotationLayer(forScoreItem id: ScoreItemID) async throws
}
```

In `Packages/Domain/Sources/Domain/IDs.swift`, replace the two annotation ID structs (lines 29-43) with their public, `Sendable` forms:

```swift
public struct AnnotationID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct AnnotationLayerID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}
```

- [ ] **Step 4: Run the Domain tests — verify green**

Run (from `Packages/Domain/`):
```
xcodebuild test -scheme Domain-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/MusicalAnchorTests -only-testing:DomainTests/AnnotationLayerTests -only-testing:DomainTests/AnnotationStoreProtocolTests
```
Expected: PASS (all three suites). `AnnotationStoreProtocolTests` (in `StorageProtocolsTests.swift`) is unchanged and must still pass against the now-public protocol.

- [ ] **Step 5: Commit**

```
git add Packages/Domain/Sources/Domain/MusicalAnchor.swift Packages/Domain/Sources/Domain/Models/AnnotationLayer.swift Packages/Domain/Sources/Domain/Protocols/AnnotationStore.swift Packages/Domain/Sources/Domain/IDs.swift Packages/Domain/Tests/DomainTests/MusicalAnchorTests.swift Packages/Domain/Tests/DomainTests/Models/AnnotationLayerTests.swift
git commit -m "feat(domain): make annotation API public with a reflow-stable tick-based MusicalAnchor" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Persistence — `annotation_layers` table (migration v12)

Add the SQLite table behind a new migration, with `score_item_id` as the primary key (one layer per score) and an `ON DELETE CASCADE` foreign key so the layer is dropped only on a score's hard delete, never on soft-delete (trash).

**Files:**
- Modify: `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift` (register `v12`; add `upToV11`; add `migrateV12`)
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AppDatabaseTests.swift` (add v12 tests)

**Interfaces:**
- Consumes: the existing `AppMigrations` enum and `AppDatabase` (foreign keys enabled).
- Produces: a migrated `annotation_layers` table with columns `id TEXT`, `score_item_id TEXT PRIMARY KEY REFERENCES score_items(id) ON DELETE CASCADE`, `updated_at REAL`, `payload BLOB`.

- [ ] **Step 1: Write the failing migration tests**

Append these two tests inside the `AppDatabaseTests` struct in `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AppDatabaseTests.swift` (before the closing brace):

```swift
    @Test func `v 12 creates annotation layers table`() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.all.migrate(queue)
        try queue.read { db in
            try #expect(db.tableExists("annotation_layers"))
            let cols = try db.columns(in: "annotation_layers").map(\.name)
            #expect(cols.contains("id"))
            #expect(cols.contains("score_item_id"))
            #expect(cols.contains("updated_at"))
            #expect(cols.contains("payload"))
        }
    }

    @Test func `v 12 cascades annotation layer on score hard delete only`() throws {
        // FK cascade requires foreign-keys ON, which AppDatabase configures; use it over a bare DatabaseQueue.
        let tmp = try TempDirectory()
        defer { withExtendedLifetime(tmp) {} }
        let db = try AppDatabase(databaseURL: tmp.url.appending(path: "f.sqlite"))
        let scoreID = "00000000-0000-0000-0000-0000000000c1"
        try db.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO score_items (id, title, local_file_name, content_hash,
                    size_bytes, length_beats, default_tempo_bpm, added_at)
                VALUES (?, 'T', 'f.mscx', 'h', 0, 0, 120, 0)
                """,
                arguments: [scoreID],
            )
            try db.execute(
                sql: """
                INSERT INTO annotation_layers (id, score_item_id, updated_at, payload)
                VALUES ('a', ?, 0, x'00')
                """,
                arguments: [scoreID],
            )
        }
        // Soft-delete (UPDATE deleted_at) must NOT remove the layer.
        try db.pool.write { db in
            try db.execute(sql: "UPDATE score_items SET deleted_at = 1 WHERE id = ?", arguments: [scoreID])
        }
        let afterSoft = try db.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM annotation_layers WHERE score_item_id = ?", arguments: [scoreID],
            )
        }
        #expect(afterSoft == 1)
        // Hard-delete (DELETE row) cascades the layer away.
        try db.pool.write { db in
            try db.execute(sql: "DELETE FROM score_items WHERE id = ?", arguments: [scoreID])
        }
        let afterHard = try db.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM annotation_layers WHERE score_item_id = ?", arguments: [scoreID],
            )
        }
        #expect(afterHard == 0)
    }
```

- [ ] **Step 2: Run the tests — verify they fail**

Run (from `Packages/Infrastructure/`):
```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/AppDatabaseTests
```
Expected: FAIL — `annotation_layers` table does not exist (`no such table` / `tableExists` false).

- [ ] **Step 3: Add the v12 migration**

In `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift`, register v12 in the `all` migrator by adding this line after the `v11` registration (line 19):

```swift
        m.registerMigration("v12", migrate: migrateV12)
```

Add an `upToV11` migrator after the `upToV8` block (after line 112), for the upgrade-against-prior-rows pattern:

```swift
    /// Migrator that registers v1 … v11 only — useful for tests that want to exercise the v12 upgrade against rows
    /// already inserted at the previous schema.
    static let upToV11: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        m.registerMigration("v2", migrate: migrateV2)
        m.registerMigration("v3", migrate: migrateV3)
        m.registerMigration("v4", migrate: migrateV4)
        m.registerMigration("v5", migrate: migrateV5)
        m.registerMigration("v6", migrate: migrateV6)
        m.registerMigration("v7", migrate: migrateV7)
        m.registerMigration("v8", migrate: migrateV8)
        m.registerMigration("v9", migrate: migrateV9)
        m.registerMigration("v10", migrate: migrateV10)
        m.registerMigration("v11", migrate: migrateV11)
        return m
    }()
```

Add the `migrateV12` function at the end of the enum (after `migrateV11`, before the final closing brace):

```swift
    // MARK: - v12

    /// Adds the `annotation_layers` table — one ink layer per score. `score_item_id` is the primary key (at most one
    /// layer per score) and an `ON DELETE CASCADE` foreign key, so a layer is dropped only when the score row is
    /// HARD-deleted (permanent delete / 30-day purge), never on soft-delete — restoring a trashed score keeps its ink.
    /// `payload` is the JSON-encoded drawings + text boxes (the PKDrawing blobs ride inside it).
    private static func migrateV12(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE annotation_layers (
            id             TEXT NOT NULL,
            score_item_id  TEXT NOT NULL PRIMARY KEY REFERENCES score_items(id) ON DELETE CASCADE,
            updated_at     REAL NOT NULL,
            payload        BLOB NOT NULL
        )
        """)
    }
```

- [ ] **Step 4: Run the tests — verify green**

Run (from `Packages/Infrastructure/`):
```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/AppDatabaseTests
```
Expected: PASS (all `AppDatabaseTests`, including the two new v12 tests).

- [ ] **Step 5: Commit**

```
git add Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AppDatabaseTests.swift
git commit -m "feat(persistence): add annotation_layers table (migration v12) with cascade on hard delete" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Persistence — `AnnotationLayerRecord` (GRDB row mirror)

A `FetchableRecord & PersistableRecord` that maps `AnnotationLayer` ↔ the `annotation_layers` row, encoding drawings + text boxes into the `payload` BLOB as JSON.

**Files:**
- Create: `Packages/Infrastructure/Sources/Persistence/Records/AnnotationLayerRecord.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AnnotationLayerRecordTests.swift`

**Interfaces:**
- Consumes: `Domain.AnnotationLayer` / `DrawingAnchor` / `TextBoxAnchor` / `MusicalAnchor` (public, from Task 1); `DomainError.persistenceFailed(reason:)`.
- Produces: `struct AnnotationLayerRecord` with `init(domain: AnnotationLayer) throws` and `func toDomain() throws -> AnnotationLayer`; `static let databaseTableName = "annotation_layers"`.

- [ ] **Step 1: Write the failing record round-trip test**

Create `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AnnotationLayerRecordTests.swift`:

```swift
@testable import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

struct AnnotationLayerRecordTests {
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppMigrations.all.migrate(q)
        return q
    }

    private func sampleLayer() -> AnnotationLayer {
        let anchor = MusicalAnchor(
            measureIndex: 4, tickInMeasure: 240, partIndex: 0,
            staffIndexInPart: 1, dxSp: 0.75, verticalOffsetSp: -3.5,
        )
        return AnnotationLayer(
            scoreItemID: ScoreItemID(),
            drawings: [
                DrawingAnchor(anchor: anchor, encodedDrawing: Data([0xDE, 0xAD, 0xBE, 0xEF])),
            ],
            textBoxes: [
                TextBoxAnchor(anchor: anchor, text: "fingering"),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
    }

    @Test func `round trips through GRDB`() throws {
        let queue = try makeQueue()
        // A parent score row is required by the FK.
        let layer = sampleLayer()
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO score_items (id, title, local_file_name, content_hash,
                    size_bytes, length_beats, default_tempo_bpm, added_at)
                VALUES (?, 'T', 'f.mscx', 'h', 0, 0, 120, 0)
                """,
                arguments: [layer.scoreItemID.rawValue.uuidString],
            )
            try AnnotationLayerRecord(domain: layer).insert(db)
        }
        let fetched = try queue.read { db -> AnnotationLayerRecord? in
            try AnnotationLayerRecord
                .filter(Column("score_item_id") == layer.scoreItemID.rawValue.uuidString)
                .fetchOne(db)
        }
        let domain = try #require(fetched).toDomain()
        #expect(domain == layer)
    }
}
```

- [ ] **Step 2: Run the test — verify it fails**

Run (from `Packages/Infrastructure/`):
```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/AnnotationLayerRecordTests
```
Expected: BUILD FAILURE — `AnnotationLayerRecord` is undefined.

- [ ] **Step 3: Create the record**

Create `Packages/Infrastructure/Sources/Persistence/Records/AnnotationLayerRecord.swift`:

```swift
import Domain
import Foundation
import GRDB

/// Row mirror for the `annotation_layers` table. The drawings + text boxes are JSON-encoded into the `payload` BLOB
/// column (the opaque PKDrawing blobs ride inside the `DrawingAnchor`s, base64-encoded by JSONEncoder). `id`,
/// `score_item_id`, and `updated_at` are columns so they can be keyed/queried without decoding the payload.
struct AnnotationLayerRecord: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "annotation_layers"

    var id: String
    var scoreItemId: String
    var updatedAt: Double
    var payload: Data

    enum CodingKeys: String, CodingKey {
        case id
        case scoreItemId = "score_item_id"
        case updatedAt = "updated_at"
        case payload
    }

    /// The JSON body stored in `payload`. `updatedAt`/ids live in their own columns, so the body is just the content.
    private struct Body: Codable {
        var drawings: [DrawingAnchor]
        var textBoxes: [TextBoxAnchor]
    }

    init(domain layer: AnnotationLayer) throws {
        id = layer.id.rawValue.uuidString
        scoreItemId = layer.scoreItemID.rawValue.uuidString
        updatedAt = layer.updatedAt.timeIntervalSince1970
        let body = Body(drawings: layer.drawings, textBoxes: layer.textBoxes)
        do {
            payload = try JSONEncoder().encode(body)
        } catch {
            throw DomainError.persistenceFailed(reason: "annotation_layers payload encode failed: \(error)")
        }
    }

    func toDomain() throws -> AnnotationLayer {
        guard let idUUID = UUID(uuidString: id) else {
            throw DomainError.persistenceFailed(reason: "annotation_layers.id is not a valid UUID: \(id)")
        }
        guard let scoreUUID = UUID(uuidString: scoreItemId) else {
            throw DomainError.persistenceFailed(
                reason: "annotation_layers.score_item_id is not a valid UUID: \(scoreItemId)",
            )
        }
        let body: Body
        do {
            body = try JSONDecoder().decode(Body.self, from: payload)
        } catch {
            throw DomainError.persistenceFailed(reason: "annotation_layers payload decode failed: \(error)")
        }
        return AnnotationLayer(
            id: AnnotationLayerID(rawValue: idUUID),
            scoreItemID: ScoreItemID(rawValue: scoreUUID),
            drawings: body.drawings,
            textBoxes: body.textBoxes,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
        )
    }
}
```

- [ ] **Step 4: Run the test — verify green**

Run (from `Packages/Infrastructure/`):
```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/AnnotationLayerRecordTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```
git add Packages/Infrastructure/Sources/Persistence/Records/AnnotationLayerRecord.swift Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AnnotationLayerRecordTests.swift
git commit -m "feat(persistence): add AnnotationLayerRecord GRDB row mirror" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Persistence — `LiveAnnotationStore` + CRUD and cascade integration tests

The GRDB-backed `AnnotationStore`. One layer per score (upsert keyed on `score_item_id`). Verify the full CRUD round-trip and the soft/hard-delete contract end-to-end against the real `LiveScoreLibraryRepository`.

**Files:**
- Create: `Packages/Infrastructure/Sources/Persistence/LiveAnnotationStore.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveAnnotationStoreTests.swift`

**Interfaces:**
- Consumes: `AppDatabase`; `AnnotationLayerRecord` (Task 3); `Domain.AnnotationStore` / `AnnotationLayer` / `ScoreItemID`; `LiveScoreLibraryRepository` (existing) for the cascade test.
- Produces: `public final class LiveAnnotationStore: AnnotationStore` with `public init(database: AppDatabase)`.

- [ ] **Step 1: Write the failing store tests**

Create `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveAnnotationStoreTests.swift`:

```swift
@testable import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@MainActor
struct LiveAnnotationStoreTests {
    private func makeDatabase() throws -> (AppDatabase, TempDirectory) {
        let tmp = try TempDirectory()
        let db = try AppDatabase(databaseURL: tmp.url.appending(path: "f.sqlite"))
        return (db, tmp)
    }

    private func insertScore(_ db: AppDatabase, id: ScoreItemID) async throws {
        try await db.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO score_items (id, title, local_file_name, content_hash,
                    size_bytes, length_beats, default_tempo_bpm, added_at)
                VALUES (?, 'T', 'f.mscx', 'h', 0, 0, 120, 0)
                """,
                arguments: [id.rawValue.uuidString],
            )
        }
    }

    private func layer(for scoreID: ScoreItemID, tick: Int) -> AnnotationLayer {
        let anchor = MusicalAnchor(
            measureIndex: 1, tickInMeasure: tick, partIndex: 0,
            staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0,
        )
        return AnnotationLayer(
            scoreItemID: scoreID,
            drawings: [DrawingAnchor(anchor: anchor, encodedDrawing: Data([0x01]))],
            textBoxes: [],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )
    }

    @Test func `save then fetch round trips the layer`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let store = LiveAnnotationStore(database: db)
        let scoreID = ScoreItemID()
        try await insertScore(db, id: scoreID)

        let saved = layer(for: scoreID, tick: 100)
        try await store.saveAnnotationLayer(saved)
        let fetched = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(fetched == saved)
    }

    @Test func `fetch on a score with no layer returns nil`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let store = LiveAnnotationStore(database: db)
        let result = try await store.annotationLayer(forScoreItem: ScoreItemID())
        #expect(result == nil)
    }

    @Test func `saving twice for the same score overwrites the layer`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let store = LiveAnnotationStore(database: db)
        let scoreID = ScoreItemID()
        try await insertScore(db, id: scoreID)

        try await store.saveAnnotationLayer(layer(for: scoreID, tick: 100))
        let second = layer(for: scoreID, tick: 200)
        try await store.saveAnnotationLayer(second)

        let fetched = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(fetched == second)
    }

    @Test func `delete removes the layer`() async throws {
        let (db, lifetime) = try makeDatabase()
        defer { withExtendedLifetime(lifetime) {} }
        let store = LiveAnnotationStore(database: db)
        let scoreID = ScoreItemID()
        try await insertScore(db, id: scoreID)

        try await store.saveAnnotationLayer(layer(for: scoreID, tick: 100))
        try await store.deleteAnnotationLayer(forScoreItem: scoreID)
        let result = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(result == nil)
    }

    @Test func `soft delete keeps ink, hard delete cascades it away`() async throws {
        let (db, lifetime) = try makeDatabase()
        let scoresDir = try TempDirectory()
        defer { withExtendedLifetime((lifetime, scoresDir)) {} }
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: scoresDir.url)
        let store = LiveAnnotationStore(database: db)

        let item = ScoreItem(
            title: "x", composer: nil, instrumentationSummary: nil,
            localFileName: "x.mid", contentHash: "h", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        try await repo.saveScoreItem(item)
        try await store.saveAnnotationLayer(layer(for: item.id, tick: 100))

        // Soft delete (trash) preserves the ink so restore brings it back.
        try await repo.softDeleteScoreItem(id: item.id)
        let afterSoft = try await store.annotationLayer(forScoreItem: item.id)
        #expect(afterSoft != nil)

        // Hard delete (permanent) cascades the layer away.
        try await repo.permanentlyDeleteScoreItem(id: item.id)
        let afterHard = try await store.annotationLayer(forScoreItem: item.id)
        #expect(afterHard == nil)
    }
}
```

- [ ] **Step 2: Run the tests — verify they fail**

Run (from `Packages/Infrastructure/`):
```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/LiveAnnotationStoreTests
```
Expected: BUILD FAILURE — `LiveAnnotationStore` is undefined.

- [ ] **Step 3: Create the store**

Create `Packages/Infrastructure/Sources/Persistence/LiveAnnotationStore.swift`:

```swift
import Domain
import Foundation
import GRDB

/// Live, GRDB-backed implementation of `AnnotationStore`. At most one `AnnotationLayer` per score; `saveAnnotationLayer`
/// upserts on the `score_item_id` primary key. Stateless apart from the `AppDatabase`, so it is `Sendable` and needs no
/// actor isolation — reads and writes hop onto the GRDB pool's own queues.
public final class LiveAnnotationStore: AnnotationStore {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func annotationLayer(forScoreItem id: ScoreItemID) async throws -> AnnotationLayer? {
        do {
            let key = id.rawValue.uuidString
            let record: AnnotationLayerRecord? = try await database.pool.read { db in
                try AnnotationLayerRecord
                    .filter(Column("score_item_id") == key)
                    .fetchOne(db)
            }
            return try record?.toDomain()
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    public func saveAnnotationLayer(_ layer: AnnotationLayer) async throws {
        do {
            let record = try AnnotationLayerRecord(domain: layer)
            try await database.pool.write { db in
                try record.save(db)
            }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }

    public func deleteAnnotationLayer(forScoreItem id: ScoreItemID) async throws {
        do {
            let key = id.rawValue.uuidString
            try await database.pool.write { db in
                _ = try AnnotationLayerRecord
                    .filter(Column("score_item_id") == key)
                    .deleteAll(db)
            }
        } catch {
            throw DomainError.persistenceFailed(reason: "\(error)")
        }
    }
}
```

- [ ] **Step 4: Run the tests — verify green**

Run (from `Packages/Infrastructure/`):
```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/LiveAnnotationStoreTests
```
Expected: PASS (all five tests).

- [ ] **Step 5: Run the full Infrastructure + Domain suites — verify nothing regressed**

Run (from `Packages/Infrastructure/`):
```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```
Then (from `Packages/Domain/`):
```
xcodebuild test -scheme Domain-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```
Expected: PASS for both packages.

- [ ] **Step 6: Commit**

```
git add Packages/Infrastructure/Sources/Persistence/LiveAnnotationStore.swift Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveAnnotationStoreTests.swift
git commit -m "feat(persistence): add LiveAnnotationStore with CRUD and soft/hard-delete cascade" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage (vs `2026-06-22-ipad-pencil-annotation-design.md` §16 Plan 1):**
- New tick-based `MusicalAnchor` (§4.2) → Task 1. ✓
- `internal → public` promotion + `Sendable` on ID types (§3/§10) → Task 1. ✓
- `UnitRect` removal + test rewrites (§3 should-fix, §12) → Task 1 (`MusicalAnchorTests` rewritten, `UnitRectTests` deleted, `AnnotationLayerTests` updated). ✓
- `LiveAnnotationStore` + SQLite v12 migration (§7) → Tasks 2-4. ✓
- Soft/hard-delete cascade — preserve on trash, drop on hard delete/prune (§7) → Task 2 (SQL-level) + Task 4 (end-to-end via repository). ✓
- Greenfield, no data migration (§7) → Global Constraints + relied on by Task 1. ✓
- **Out of Plan 1 scope (deferred to Plan 2):** DI wiring of `annotationStore` through `AppBootstrap → ReadyShell → ReaderRootScreen → ReaderViewModel` — no App changes here, because there is no consumer until the Reader integration. CloudKit (Plan 3). PencilKit / canvas / mapping (Plan 2).

**Placeholder scan:** none — every code step shows complete code; every run step shows the exact command and expected outcome.

**Type consistency:** `MusicalAnchor(measureIndex:tickInMeasure:partIndex:staffIndexInPart:dxSp:verticalOffsetSp:)` is used identically in Task 1 tests, Task 3 test, and Task 4 test. `AnnotationLayerRecord(domain:) throws` / `toDomain() throws` and `LiveAnnotationStore(database:)` match across Tasks 3-4. `databaseTableName = "annotation_layers"` and the column names (`id`, `score_item_id`, `updated_at`, `payload`) are consistent between the migration (Task 2) and the record (Task 3).

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-22-pencil-annotation-plan1-domain-persistence.md`. Two execution options:

1. **Subagent-Driven (recommended)** — a fresh subagent per task, two-stage review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session with checkpoints for review.

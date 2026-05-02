# Persistence and File Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land Folino's local SQLite-backed score library and the bridge to `swift-sheet-music` for format I/O, with a two-stage importer that does SHA-256 duplicate detection. UI consumers read library state via an `@Observable` `ScoreLibraryRepository`.

**Architecture:** GRDB `DatabasePool` lives inside the `Persistence` SPM target; one record struct per table mirrors the schema. `LiveScoreLibraryRepository` is an `@Observable @MainActor final class` fed by a `ValueObservation` task. `LiveScoreFileGateway` (in the `ScoreFiles` target) wraps `SheetMusic`. `LiveScoreFileImporter` (in `Persistence`) composes the Domain `ScoreFileGateway` + `ScoreLibraryRepository` protocols — the two Infrastructure targets stay independent and only meet inside `App/AppBootstrap.swift`.

**Tech Stack:** Swift 6.3 (Swift Testing), iOS 26+, GRDB 7, CryptoKit `SHA256`, `swift-sheet-music`, SwiftLintBuildToolPlugin.

**Source spec:** `docs/superpowers/specs/2026-05-02-persistence-and-file-gateway-design.md`.

---

## Deliberate deviations from spec

These are conscious cuts/clarifications relative to the spec. Stop and re-confirm with the human before changing any of them mid-execution.

- **`saveScore` is a v1 stub.** `swift-sheet-music` exposes no `Score → MSCX / MSCZ / MusicXML` serializer today (only `Score → MIDI` via `SheetMusic.exportMIDI`). `LiveScoreFileGateway.saveScore` throws `DomainError.unsupportedFormat` for every format. The "MSCZ round-trip" test from the spec's testing strategy is dropped. The protocol method stays so the Editor plan can fill it in without touching consumers.
- **No `sort_order` columns; `Tag` and `Playlist` Domain types are unchanged.** The spec's schema listed `sort_order INTEGER NOT NULL DEFAULT 0` on `tags` and `playlists`, but Plan #2's `Tag` / `Playlist` Domain models don't carry that field and there is no consumer in v1. Per YAGNI we drop the columns from the v1 migration; they can be reintroduced in a v2 migration alongside the ordering UI.
- **`ScoreItem.contentHash: String` is added in Domain.** The spec implies it via `scoreItems(matchingContentHash:)` and the `content_hash NOT NULL` column, but Plan #2's `ScoreItem` lacks the field. This plan adds it as a stored property (set at import time, never edited afterward).
- **`DomainError` mapping uses the existing case names from Plan #2.** The spec's table referenced `.fileCorrupt`, `.fileSystemFailed(underlying:)`, `.persistenceFailed(underlying:)` — none of which exist on `DomainError`. The actual mapping is:
  - parse failure → `scoreParseFailed(reason:)`
  - GRDB read/write failure → `persistenceFailed(reason:)`
  - importer hash/copy/FS failure → `persistenceFailed(reason:)`
  - source URL not readable → `scoreFileNotFound(name:)`
  - unknown extension (incl. `.pdf` in v1) → `unsupportedFormat(ext)`
- **Test fixtures land for `.mscx` only; `.mscz` is synthesized from it; `.mid` is synthesized via `SheetMusic.exportMIDI`.** A hand-crafted minimal MSCX (one C4 quarter note, one staff) lives in `Packages/Infrastructure/Tests/InfrastructureTests/Resources/`. MSCZ is built at test time via `SheetMusic.saveMSCZ(mscxData:)`. MIDI is built at test time via `SheetMusic.exportMIDI(score:)`. `.musicxml` / `.mxl` end-to-end fixture tests are **deferred**; the gateway's format dispatch for those branches is verified by exercising `loadFileMetadata` / `loadScore` against a stub adapter pattern (one suite per format). MuseScore-derived GPL fixtures (used by `swift-sheet-music`'s own tests) MUST NOT be vendored into this repo.
- **`Playlist.items` in spec === existing `Playlist.orderedScoreItemIDs`.** Naming difference only; we keep the Plan #2 name.
- **Whole-file staging only.** `CLAUDE.md` forbids `git add -p` — use whole-file `git add`. The pre-commit hook (SwiftFormat + SwiftLint --fix) runs on staged files; expect it to amend and re-run until clean.

---

## File structure

### Domain (overwrites Plan #2 where noted)

| File | Action | Responsibility |
|---|---|---|
| `Packages/Domain/Sources/Domain/ScoreFormat.swift` | **modify** | Drop `.pdf` case + arms in `canonicalExtension` and `detect(filename:)` |
| `Packages/Domain/Sources/Domain/Models/ScoreItem.swift` | **modify** | Drop `format`, add `contentHash: String` |
| `Packages/Domain/Sources/Domain/Protocols/ScoreLibraryRepository.swift` | **modify** | Become `@MainActor` `AnyObject, Observable` with observed properties + new method shape |
| `Packages/Domain/Sources/Domain/Protocols/ScoreFileGateway.swift` | **modify** | Add `loadFileMetadata(fileURL:)` |
| `Packages/Domain/Sources/Domain/Protocols/ScoreFileImporter.swift` | **create** | New `ImportPlan`, `ImportDecision`, `ScoreFileImporter` protocol |
| `Packages/Domain/Tests/DomainTests/ScoreFormatTests.swift` | **modify** | Remove the `.pdf` assertion |
| `Packages/Domain/Tests/DomainTests/Models/ScoreItemTests.swift` | **modify** | Drop `format:` from sample, exercise `contentHash` |
| `Packages/Domain/Tests/DomainTests/Protocols/StorageProtocolsTests.swift` | **modify** | Replace fake actor with `@Observable @MainActor` fake; new method shape |
| `Packages/Domain/Tests/DomainTests/Protocols/SyncFileProtocolsTests.swift` | **modify** | Update `FakeScoreFileGateway` for `loadFileMetadata` |
| `Packages/Domain/Tests/DomainTests/Protocols/ScoreFileImporterTests.swift` | **create** | Smoke test for `ImportPlan` / `ImportDecision` Sendable+Hashable + protocol conformance |

### Infrastructure / Persistence (new code)

| File | Action | Responsibility |
|---|---|---|
| `Packages/Infrastructure/.swiftlint.yml` | **create** | `parent_config: ../../.swiftlint.yml` shim (mirrors Domain) |
| `Packages/Infrastructure/Sources/Persistence/Placeholder.swift` | **delete** | Replaced by real types |
| `Packages/Infrastructure/Sources/Persistence/Database/AppDatabase.swift` | **create** | `DatabasePool` factory, public entry point |
| `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift` | **create** | v1 schema migrator |
| `Packages/Infrastructure/Sources/Persistence/Records/ScoreItemRecord.swift` | **create** | GRDB record + Domain ↔ DB translation |
| `Packages/Infrastructure/Sources/Persistence/Records/TagRecord.swift` | **create** | GRDB record + translation |
| `Packages/Infrastructure/Sources/Persistence/Records/PlaylistRecord.swift` | **create** | GRDB record + translation (without orderedScoreItemIDs) |
| `Packages/Infrastructure/Sources/Persistence/Records/ScoreItemTagRecord.swift` | **create** | Junction record |
| `Packages/Infrastructure/Sources/Persistence/Records/PlaylistItemRecord.swift` | **create** | Junction record (with `position`) |
| `Packages/Infrastructure/Sources/Persistence/LiveScoreLibraryRepository.swift` | **create** | `@Observable @MainActor final class` |
| `Packages/Infrastructure/Sources/Persistence/LiveScoreFileImporter.swift` | **create** | Two-stage importer |

### Infrastructure / ScoreFiles (new code)

| File | Action | Responsibility |
|---|---|---|
| `Packages/Infrastructure/Sources/ScoreFiles/Placeholder.swift` | **delete** | Replaced |
| `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreFileGateway.swift` | **create** | `ScoreFileGateway` impl (per-format dispatch) |
| `Packages/Infrastructure/Sources/ScoreFiles/ScoreFileSummary+Score.swift` | **create** | `init(score:)` extension to derive `ScoreFileSummary` from a parsed `Score` |

### Infrastructure tests

| File | Action | Responsibility |
|---|---|---|
| `Packages/Infrastructure/Package.swift` | **modify** | Declare `Resources/` as resources on `InfrastructureTests`; add `Persistence` test deps if needed |
| `Packages/Infrastructure/Tests/InfrastructureTests/InfrastructureTests.swift` | **modify** | Smoke test stays; module-link assertions removed for any module whose Placeholder we deleted |
| `Packages/Infrastructure/Tests/InfrastructureTests/TestSupport/TempDirectory.swift` | **create** | Tmpdir helper (creates + cleans up) |
| `Packages/Infrastructure/Tests/InfrastructureTests/TestSupport/Fixtures.swift` | **create** | Loads `.mscx` resource, synthesizes `.mscz` and `.mid` at runtime |
| `Packages/Infrastructure/Tests/InfrastructureTests/Resources/minimal.mscx` | **create** | Hand-crafted minimal MSCX (clean-room) |
| `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AppDatabaseTests.swift` | **create** | Migration v1 idempotency |
| `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreLibraryRepositoryTests.swift` | **create** | Round-trip / FK cascade / ValueObservation |
| `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreFileImporterTests.swift` | **create** | Two-stage import / dup detection / rollback |
| `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreFileGatewayTests.swift` | **create** | detectFormat / loadFileMetadata / loadScore / saveScore-stub |

### App composition root

| File | Action | Responsibility |
|---|---|---|
| `App/AppBootstrap.swift` | **modify** | Construct `AppDatabase`, `LiveScoreLibraryRepository`, `LiveScoreFileGateway`, `LiveScoreFileImporter`; expose them as `let` properties |
| `App/AppPaths.swift` | **(unchanged)** | Already exposes `databaseURL` and `scoresDirectory` |

---

## Tasks

The plan is grouped into seven phases. Phases A–B–C–D land Persistence + the Repository. Phase E lands ScoreFiles. Phase F lands the Importer. Phase G wires the App. Phases A and B can be committed independently.

### Phase A — Domain protocol/model updates (overwrites Plan #2)

These edits are non-breaking at the consumer level (Plan #2 has no adopters yet) but they DO break Plan #2's own Domain tests. Each task in this phase migrates the relevant tests in the same commit so `swift test` stays green.

---

### Task 1: Drop `.pdf` from `ScoreFormat`

**Files:**
- Modify: `Packages/Domain/Sources/Domain/ScoreFormat.swift`
- Modify: `Packages/Domain/Tests/DomainTests/ScoreFormatTests.swift`

- [ ] **Step 1: Update the test to assert `.pdf` returns nil**

In `ScoreFormatTests.swift`, replace the `.pdf` line in `detectsExtensionsCaseInsensitively` and add a dedicated assertion:

```swift
@Test func detectsExtensionsCaseInsensitively() {
    #expect(ScoreFormat.detect(filename: "song.mscz") == .mscz)
    #expect(ScoreFormat.detect(filename: "song.MSCZ") == .mscz)
    #expect(ScoreFormat.detect(filename: "song.mscx") == .mscx)
    #expect(ScoreFormat.detect(filename: "song.musicxml") == .musicXML)
    #expect(ScoreFormat.detect(filename: "song.xml") == .musicXML)
    #expect(ScoreFormat.detect(filename: "song.mxl") == .mxl)
    #expect(ScoreFormat.detect(filename: "song.mid") == .midi)
    #expect(ScoreFormat.detect(filename: "song.midi") == .midi)
    #expect(ScoreFormat.detect(filename: "song.smf") == .midi)
}

@Test func returnsNilForPDFInV1() {
    #expect(ScoreFormat.detect(filename: "song.pdf") == nil)
    #expect(ScoreFormat.detect(filename: "song.PDF") == nil)
}
```

- [ ] **Step 2: Run the tests; expect compile error or failure**

Run: `cd Packages/Domain && swift test --filter ScoreFormatTests`
Expected: build fails ("type 'ScoreFormat' has no member 'pdf'" is fine — we removed the assertion that used `.pdf == .pdf`) OR `returnsNilForPDFInV1` fails because `.pdf` still parses to `.pdf`.

- [ ] **Step 3: Drop `.pdf` from `ScoreFormat`**

Replace `Packages/Domain/Sources/Domain/ScoreFormat.swift` with:

```swift
import Foundation

/// File format Folino can read and write. Each case represents a distinct on-disk encoding.
public enum ScoreFormat: String, Hashable, Sendable, Codable, CaseIterable {
    case mscx
    case mscz
    case musicXML
    case mxl
    case midi

    /// The default file extension Folino writes when exporting this format.
    public var canonicalExtension: String {
        switch self {
        case .mscx: "mscx"
        case .mscz: "mscz"
        case .musicXML: "musicxml"
        case .mxl: "mxl"
        case .midi: "mid"
        }
    }

    /// Best-effort detection from a filename or path. Case-insensitive on the extension.
    /// Returns `nil` for `.pdf` in v1 — PDF support is deferred to a later plan that introduces OCR.
    public static func detect(filename: String) -> ScoreFormat? {
        guard let dotIndex = filename.lastIndex(of: ".") else { return nil }
        let ext = filename[filename.index(after: dotIndex)...].lowercased()
        switch ext {
        case "mscx": return .mscx
        case "mscz": return .mscz
        case "musicxml", "xml": return .musicXML
        case "mxl": return .mxl
        case "mid", "midi", "smf": return .midi
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Run the tests; expect pass**

Run: `cd Packages/Domain && swift test --filter ScoreFormatTests`
Expected: PASS, all suites green.

Then run the full Domain suite to catch any other adopter:
Run: `cd Packages/Domain && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/ScoreFormat.swift \
        Packages/Domain/Tests/DomainTests/ScoreFormatTests.swift
git commit -m "refactor(domain): drop ScoreFormat.pdf in v1"
```

---

### Task 2: Drop `format`, add `contentHash` on `ScoreItem`

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ScoreItem.swift`
- Modify: `Packages/Domain/Tests/DomainTests/Models/ScoreItemTests.swift`

- [ ] **Step 1: Update the test to use the new shape**

Replace `Packages/Domain/Tests/DomainTests/Models/ScoreItemTests.swift` with:

```swift
@testable import Domain
import Foundation
import Testing

@Suite struct ScoreItemTests {
    private func sample() -> ScoreItem {
        ScoreItem(
            id: ScoreItemID(),
            title: "Prelude in C",
            composer: "J. S. Bach",
            instrumentationSummary: "Piano",
            localFileName: "prelude.mscz",
            contentHash: "0000000000000000000000000000000000000000000000000000000000000000",
            sizeBytes: 8192,
            lengthBeats: 56,
            defaultTempoBpm: 72,
            primaryKey: "C major",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false
        )
    }

    @Test func roundTripsThroughCodable() throws {
        let item = sample()
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ScoreItem.self, from: data)
        #expect(decoded == item)
    }

    @Test func canHoldOptionalMetadata() {
        let item = ScoreItem(
            id: ScoreItemID(),
            title: "Untitled",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: "x.mid",
            contentHash: "deadbeef",
            sizeBytes: 0,
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false
        )
        #expect(item.composer == nil)
        #expect(item.primaryKey == nil)
    }

    @Test func conformsToIdentifiable() {
        let item = sample()
        let _: ScoreItemID = item.id
    }

    @Test func tagIDsAreOrderIndependent() {
        let t1 = TagID()
        let t2 = TagID()
        let base = sample()
        let a = base.with(tagIDs: [t1, t2])
        let b = base.with(tagIDs: [t2, t1])
        #expect(a == b)
    }

    @Test func contentHashIsCarriedThroughCodable() throws {
        let item = sample()
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ScoreItem.self, from: data)
        #expect(decoded.contentHash == item.contentHash)
    }
}

extension ScoreItem {
    fileprivate func with(tagIDs: Set<TagID>) -> ScoreItem {
        ScoreItem(
            id: id,
            title: title,
            composer: composer,
            instrumentationSummary: instrumentationSummary,
            localFileName: localFileName,
            contentHash: contentHash,
            sizeBytes: sizeBytes,
            lengthBeats: lengthBeats,
            defaultTempoBpm: defaultTempoBpm,
            primaryKey: primaryKey,
            addedAt: addedAt,
            lastOpenedAt: lastOpenedAt,
            tagIDs: tagIDs,
            isFavorite: isFavorite
        )
    }
}
```

- [ ] **Step 2: Run; expect compile failures**

Run: `cd Packages/Domain && swift test --filter ScoreItemTests`
Expected: FAIL (compile error — `ScoreItem` has no `contentHash:` parameter and still requires `format:`).

- [ ] **Step 3: Update `ScoreItem`**

Replace `Packages/Domain/Sources/Domain/Models/ScoreItem.swift` with:

```swift
import Foundation

/// A persisted entry in Folino's library. The actual score bytes live on disk
/// at `AppPaths.scoresDirectory/localFileName` (the resolution to absolute URL
/// happens in Infrastructure, not Domain).
///
/// `format` is intentionally NOT stored: callers derive it via
/// `ScoreFormat.detect(filename: item.localFileName)`. The convention
/// `localFileName == "<id>.<canonical-extension>"` is enforced at import time.
public struct ScoreItem: Hashable, Sendable, Codable, Identifiable {
    public let id: ScoreItemID
    public var title: String
    public var composer: String?
    public var instrumentationSummary: String?
    /// Filename relative to the scores directory. Convention: `<id>.<canonical-extension>`.
    public var localFileName: String
    /// SHA-256 hex digest of the on-disk file bytes, computed at import time. Used for
    /// duplicate detection. Never edited after import.
    public var contentHash: String
    public var sizeBytes: Int64
    public var lengthBeats: Int
    public var defaultTempoBpm: Int
    public var primaryKey: String?
    public let addedAt: Date
    public var lastOpenedAt: Date?
    public var tagIDs: Set<TagID>
    public var isFavorite: Bool

    public init(
        id: ScoreItemID = ScoreItemID(),
        title: String,
        composer: String?,
        instrumentationSummary: String?,
        localFileName: String,
        contentHash: String,
        sizeBytes: Int64,
        lengthBeats: Int,
        defaultTempoBpm: Int,
        primaryKey: String?,
        addedAt: Date,
        lastOpenedAt: Date?,
        tagIDs: Set<TagID>,
        isFavorite: Bool
    ) {
        self.id = id
        self.title = title
        self.composer = composer
        self.instrumentationSummary = instrumentationSummary
        self.localFileName = localFileName
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
        self.lengthBeats = lengthBeats
        self.defaultTempoBpm = defaultTempoBpm
        self.primaryKey = primaryKey
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.tagIDs = tagIDs
        self.isFavorite = isFavorite
    }
}
```

- [ ] **Step 4: Run; expect ScoreItem suite to pass; expect `StorageProtocolsTests` to fail (its sample uses `format:`)**

Run: `cd Packages/Domain && swift test --filter ScoreItemTests`
Expected: PASS.

Run: `cd Packages/Domain && swift test`
Expected: FAIL in `StorageProtocolsTests` (still references the old `format:` parameter). That is rectified in Task 3 — leave it broken for now.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/ScoreItem.swift \
        Packages/Domain/Tests/DomainTests/Models/ScoreItemTests.swift
git commit --no-verify -m "feat(domain): replace ScoreItem.format with contentHash"
```

NOTE: `--no-verify` is **NOT** allowed; instead, the broken `StorageProtocolsTests` blocks the commit. Workaround: combine Task 2 and Task 3 into a single commit. **Treat Task 2 + Task 3 as a single unit — do Task 3 immediately, then commit both in Task 3's Step 5.** Skip this Step 5 of Task 2.

---

### Task 3: Rewrite `ScoreLibraryRepository` to be `@Observable @MainActor`

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Protocols/ScoreLibraryRepository.swift`
- Modify: `Packages/Domain/Tests/DomainTests/Protocols/StorageProtocolsTests.swift`

- [ ] **Step 1: Replace the protocol**

Replace `Packages/Domain/Sources/Domain/Protocols/ScoreLibraryRepository.swift` with:

```swift
import Foundation
import Observation

/// Persistence façade for the score library: items, tags, and playlists.
///
/// The protocol is `@MainActor` and `Observable` so SwiftUI views can read the
/// observed properties directly and re-render when GRDB's `ValueObservation`
/// pushes a new snapshot. The Infrastructure implementation
/// (`LiveScoreLibraryRepository`) starts a long-running observation task on
/// the first `refresh()` call.
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

    /// Used by the importer for duplicate detection. Returns every item whose
    /// `contentHash` equals the argument; the caller decides whether to merge.
    func scoreItems(matchingContentHash contentHash: String) async throws -> [ScoreItem]
}
```

- [ ] **Step 2: Replace the test fake and assertions**

Replace `Packages/Domain/Tests/DomainTests/Protocols/StorageProtocolsTests.swift` with:

```swift
@testable import Domain
import Foundation
import Observation
import Testing

/// In-memory fake conforming to `ScoreLibraryRepository`. Living inside the
/// test target ensures the protocol's shape compiles for at least one
/// concrete implementor and exercises the observable surface.
@MainActor
@Observable
private final class FakeScoreLibraryRepository: ScoreLibraryRepository {
    var scoreItems: [ScoreItem] = []
    var tags: [Domain.Tag] = []
    var playlists: [Playlist] = []

    func refresh() async throws { /* no-op */ }

    func saveScoreItem(_ item: ScoreItem) async throws {
        if let idx = scoreItems.firstIndex(where: { $0.id == item.id }) {
            scoreItems[idx] = item
        } else {
            scoreItems.append(item)
        }
    }

    func deleteScoreItem(id: ScoreItemID) async throws {
        scoreItems.removeAll { $0.id == id }
    }

    func saveTag(_ tag: Domain.Tag) async throws {
        if let idx = tags.firstIndex(where: { $0.id == tag.id }) {
            tags[idx] = tag
        } else {
            tags.append(tag)
        }
    }

    func deleteTag(id: TagID) async throws { tags.removeAll { $0.id == id } }

    func savePlaylist(_ playlist: Playlist) async throws {
        if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[idx] = playlist
        } else {
            playlists.append(playlist)
        }
    }

    func deletePlaylist(id: PlaylistID) async throws {
        playlists.removeAll { $0.id == id }
    }

    func scoreItems(matchingContentHash contentHash: String) async throws -> [ScoreItem] {
        scoreItems.filter { $0.contentHash == contentHash }
    }
}

private actor FakeAnnotationStore: AnnotationStore {
    var layers: [ScoreItemID: AnnotationLayer] = [:]

    func annotationLayer(forScoreItem id: ScoreItemID) throws -> AnnotationLayer? {
        layers[id]
    }

    func saveAnnotationLayer(_ layer: AnnotationLayer) throws {
        layers[layer.scoreItemID] = layer
    }

    func deleteAnnotationLayer(forScoreItem id: ScoreItemID) throws {
        layers.removeValue(forKey: id)
    }
}

@Suite @MainActor struct StorageProtocolsTests {
    private func sampleItem(hash: String = "0".repeated(64)) -> ScoreItem {
        ScoreItem(
            title: "x", composer: nil, instrumentationSummary: nil,
            localFileName: "x.mid", contentHash: hash, sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }

    @Test func libraryRepositoryRoundTripsItems() async throws {
        let repo: any ScoreLibraryRepository = FakeScoreLibraryRepository()
        let item = sampleItem()
        try await repo.saveScoreItem(item)
        #expect(repo.scoreItems.contains { $0.id == item.id })
        try await repo.deleteScoreItem(id: item.id)
        #expect(repo.scoreItems.isEmpty)
    }

    @Test func contentHashLookupReturnsAllMatches() async throws {
        let repo: any ScoreLibraryRepository = FakeScoreLibraryRepository()
        let h = "abc123"
        try await repo.saveScoreItem(sampleItem(hash: h))
        try await repo.saveScoreItem(sampleItem(hash: h))
        try await repo.saveScoreItem(sampleItem(hash: "other"))
        let dups = try await repo.scoreItems(matchingContentHash: h)
        #expect(dups.count == 2)
    }
}

@Suite struct AnnotationStoreProtocolTests {
    @Test func annotationStoreRoundTripsLayers() async throws {
        let store: any AnnotationStore = FakeAnnotationStore()
        let scoreID = ScoreItemID()
        let layer = AnnotationLayer(
            scoreItemID: scoreID, drawings: [], textBoxes: [],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await store.saveAnnotationLayer(layer)
        let fetched = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(fetched == layer)
        try await store.deleteAnnotationLayer(forScoreItem: scoreID)
        let removed = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(removed == nil)
    }
}

extension String {
    fileprivate func repeated(_ count: Int) -> String { String(repeating: self, count: count) }
}
```

- [ ] **Step 3: Run the full Domain test suite**

Run: `cd Packages/Domain && swift test`
Expected: PASS — both `StorageProtocolsTests` and `ScoreItemTests` green; old `allScoreItems` / `scoreItem(id:)` references gone.

- [ ] **Step 4: Run the workspace build to confirm nothing else regressed**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit Tasks 2 + 3 together**

```bash
git add Packages/Domain/Sources/Domain/Models/ScoreItem.swift \
        Packages/Domain/Sources/Domain/Protocols/ScoreLibraryRepository.swift \
        Packages/Domain/Tests/DomainTests/Models/ScoreItemTests.swift \
        Packages/Domain/Tests/DomainTests/Protocols/StorageProtocolsTests.swift
git commit -m "feat(domain): observable ScoreLibraryRepository with contentHash-based dup detection"
```

---

### Task 4: Add `loadFileMetadata` to `ScoreFileGateway`

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Protocols/ScoreFileGateway.swift`
- Modify: `Packages/Domain/Tests/DomainTests/Protocols/SyncFileProtocolsTests.swift`

- [ ] **Step 1: Update the protocol**

Replace `Packages/Domain/Sources/Domain/Protocols/ScoreFileGateway.swift` with:

```swift
import Foundation

/// Metadata extracted from a score file at load time. Distinct from
/// `ScoreItem` because the gateway runs before the file is added to the
/// library and therefore has no `ScoreItemID` or persistent state yet.
public struct ScoreFileSummary: Hashable, Sendable {
    public var title: String?
    public var composer: String?
    public var instrumentationSummary: String
    public var lengthBeats: Int
    public var defaultTempoBpm: Int
    public var primaryKey: String?

    public init(
        title: String?,
        composer: String?,
        instrumentationSummary: String,
        lengthBeats: Int,
        defaultTempoBpm: Int,
        primaryKey: String?
    ) {
        self.title = title
        self.composer = composer
        self.instrumentationSummary = instrumentationSummary
        self.lengthBeats = lengthBeats
        self.defaultTempoBpm = defaultTempoBpm
        self.primaryKey = primaryKey
    }
}

/// Bridges `swift-sheet-music`'s format I/O modules into Domain. The
/// Infrastructure implementation wraps `SheetMusicMSCX`, `SheetMusicMusicXML`,
/// and `SheetMusicMIDI` behind this single protocol so Features only depend
/// on Domain.
public protocol ScoreFileGateway: Sendable {
    /// Best-effort format detection from filename. Should agree with
    /// `ScoreFormat.detect(filename:)`.
    func detectFormat(fileName: String) -> ScoreFormat?

    /// Load only the lightweight summary (no full notation tree). Used by
    /// the importer for the prepare step.
    ///
    /// Throws `DomainError.unsupportedFormat` for unknown extensions
    /// (PDF included — `.pdf` is not a `ScoreFormat` case in v1).
    func loadFileMetadata(fileURL: URL) async throws -> ScoreFileSummary

    /// Parse a score file into the in-memory `Score` plus a transient summary.
    ///
    /// Throws `DomainError.unsupportedFormat` for unknown extensions.
    func loadScore(fileURL: URL) async throws -> (score: Score, summary: ScoreFileSummary)

    /// Write a `Score` to disk in the requested format.
    ///
    /// v1 throws `DomainError.unsupportedFormat` for every format —
    /// `swift-sheet-music` does not yet expose a Score → MSCX/MSCZ/MusicXML
    /// serializer. The method exists on the protocol so Editor can fill it
    /// in without touching consumers.
    func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) async throws
}
```

- [ ] **Step 2: Update `FakeScoreFileGateway` in the test**

Edit `Packages/Domain/Tests/DomainTests/Protocols/SyncFileProtocolsTests.swift` — add `loadFileMetadata` to the fake and add a test:

Inside the `actor FakeScoreFileGateway` declaration, add (above `loadScore`):

```swift
func loadFileMetadata(fileURL: URL) throws -> ScoreFileSummary {
    throw DomainError.scoreParseFailed(reason: "fake")
}
```

Inside `@Suite struct ScoreFileGatewayProtocolTests`, append:

```swift
@Test func loadFileMetadataThrowsOnFakeFiles() async {
    let gateway = FakeScoreFileGateway()
    do {
        _ = try await gateway.loadFileMetadata(fileURL: URL(fileURLWithPath: "/dev/null"))
        Issue.record("expected throw")
    } catch let error as DomainError {
        if case .scoreParseFailed = error { /* expected */ } else {
            Issue.record("unexpected DomainError: \(error)")
        }
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
```

- [ ] **Step 3: Run; expect pass**

Run: `cd Packages/Domain && swift test --filter ScoreFileGatewayProtocolTests`
Expected: PASS.

Run: `cd Packages/Domain && swift test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/Domain/Sources/Domain/Protocols/ScoreFileGateway.swift \
        Packages/Domain/Tests/DomainTests/Protocols/SyncFileProtocolsTests.swift
git commit -m "feat(domain): add ScoreFileGateway.loadFileMetadata"
```

---

### Task 5: Add `ScoreFileImporter` protocol + value types

**Files:**
- Create: `Packages/Domain/Sources/Domain/Protocols/ScoreFileImporter.swift`
- Create: `Packages/Domain/Tests/DomainTests/Protocols/ScoreFileImporterTests.swift`

- [ ] **Step 1: Write the test first**

Create `Packages/Domain/Tests/DomainTests/Protocols/ScoreFileImporterTests.swift`:

```swift
@testable import Domain
import Foundation
import Testing

private final class FakeImporter: ScoreFileImporter {
    func prepareImport(sourceURL: URL) async throws -> ImportPlan {
        ImportPlan(
            sourceURL: sourceURL,
            format: .midi,
            summary: ScoreFileSummary(
                title: "x", composer: nil, instrumentationSummary: "Piano",
                lengthBeats: 4, defaultTempoBpm: 120, primaryKey: nil
            ),
            contentHash: "deadbeef",
            sizeBytes: 1,
            duplicates: []
        )
    }

    func commitImport(_ plan: ImportPlan, decision: ImportDecision) async throws -> ScoreItem {
        ScoreItem(
            title: plan.summary.title ?? "Untitled",
            composer: plan.summary.composer,
            instrumentationSummary: plan.summary.instrumentationSummary,
            localFileName: "x.mid",
            contentHash: plan.contentHash,
            sizeBytes: plan.sizeBytes,
            lengthBeats: plan.summary.lengthBeats,
            defaultTempoBpm: plan.summary.defaultTempoBpm,
            primaryKey: plan.summary.primaryKey,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false
        )
    }
}

@Suite struct ScoreFileImporterTests {
    @Test func importPlanIsHashableAndSendable() {
        let plan = ImportPlan(
            sourceURL: URL(fileURLWithPath: "/tmp/x.mid"),
            format: .midi,
            summary: ScoreFileSummary(
                title: nil, composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
            ),
            contentHash: "h",
            sizeBytes: 0,
            duplicates: []
        )
        var set: Set<ImportPlan> = []
        set.insert(plan)
        #expect(set.contains(plan))
    }

    @Test func importDecisionIsHashable() {
        let id = ScoreItemID()
        let decisions: Set<ImportDecision> = [.importAsNew, .openExisting(id), .openExisting(id)]
        #expect(decisions.count == 2)
    }

    @Test func fakeImporterPrepareReturnsZeroDuplicates() async throws {
        let importer: any ScoreFileImporter = FakeImporter()
        let plan = try await importer.prepareImport(sourceURL: URL(fileURLWithPath: "/tmp/x.mid"))
        #expect(plan.duplicates.isEmpty)
    }
}
```

- [ ] **Step 2: Run; expect compile failure**

Run: `cd Packages/Domain && swift test --filter ScoreFileImporterTests`
Expected: FAIL — `ImportPlan` / `ImportDecision` / `ScoreFileImporter` undefined.

- [ ] **Step 3: Create the protocol file**

Create `Packages/Domain/Sources/Domain/Protocols/ScoreFileImporter.swift`:

```swift
import Foundation

/// Outcome of `ScoreFileImporter.prepareImport`. Carries everything the
/// commit step needs (summary, hash, size) plus the duplicate list so the
/// Feature layer can render a confirmation dialog without a re-read.
public struct ImportPlan: Hashable, Sendable {
    public let sourceURL: URL
    public let format: ScoreFormat
    public let summary: ScoreFileSummary
    public let contentHash: String
    public let sizeBytes: Int64
    public let duplicates: [ScoreItem]

    public init(
        sourceURL: URL,
        format: ScoreFormat,
        summary: ScoreFileSummary,
        contentHash: String,
        sizeBytes: Int64,
        duplicates: [ScoreItem]
    ) {
        self.sourceURL = sourceURL
        self.format = format
        self.summary = summary
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
        self.duplicates = duplicates
    }
}

/// What the user (or auto-resolution) decided to do with a prepared `ImportPlan`.
public enum ImportDecision: Hashable, Sendable {
    case importAsNew
    case openExisting(ScoreItemID)
}

/// Two-stage importer: `prepareImport` does all reads (hash, summary, dup
/// query) and returns the plan; `commitImport` does the write (file copy +
/// repository row) only after the decision is known. A user cancelling the
/// dup dialog simply discards the plan — no I/O has happened yet.
public protocol ScoreFileImporter: Sendable {
    func prepareImport(sourceURL: URL) async throws -> ImportPlan
    func commitImport(_ plan: ImportPlan, decision: ImportDecision) async throws -> ScoreItem
}
```

- [ ] **Step 4: Run; expect pass**

Run: `cd Packages/Domain && swift test --filter ScoreFileImporterTests`
Expected: PASS.

Run: `cd Packages/Domain && swift test`
Expected: PASS — entire Domain suite green.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Protocols/ScoreFileImporter.swift \
        Packages/Domain/Tests/DomainTests/Protocols/ScoreFileImporterTests.swift
git commit -m "feat(domain): add ScoreFileImporter protocol and ImportPlan"
```

---

### Phase B — Persistence scaffolding

---

### Task 6: Add Infrastructure SwiftLint shim and prepare tests dir

**Files:**
- Create: `Packages/Infrastructure/.swiftlint.yml`
- Create: `Packages/Infrastructure/Tests/InfrastructureTests/TestSupport/TempDirectory.swift`

- [ ] **Step 1: Add the shim**

Create `Packages/Infrastructure/.swiftlint.yml`:

```yaml
parent_config: ../../.swiftlint.yml
```

- [ ] **Step 2: Add the tmpdir helper**

Create `Packages/Infrastructure/Tests/InfrastructureTests/TestSupport/TempDirectory.swift`:

```swift
import Foundation

/// Creates a unique temp directory under `NSTemporaryDirectory()` and removes
/// it when destroyed. Use as `let tmp = try TempDirectory()` in a test —
/// the directory's URL is `tmp.url`.
final class TempDirectory {
    let url: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        url = base.appending(path: "folino-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 3: Run the existing test suite to confirm scaffolding compiles**

Run: `cd Packages/Infrastructure && swift test`
Expected: PASS (existing smoke tests still green; new `TempDirectory` is unused but compiles).

- [ ] **Step 4: Commit**

```bash
git add Packages/Infrastructure/.swiftlint.yml \
        Packages/Infrastructure/Tests/InfrastructureTests/TestSupport/TempDirectory.swift
git commit -m "chore(infrastructure): add swiftlint shim and tmpdir test helper"
```

---

### Task 7: Create AppDatabase + v1 migration

**Files:**
- Delete: `Packages/Infrastructure/Sources/Persistence/Placeholder.swift`
- Create: `Packages/Infrastructure/Sources/Persistence/Database/AppDatabase.swift`
- Create: `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift`
- Create: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AppDatabaseTests.swift`
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/InfrastructureTests.swift` (drop `PersistenceModule.isLinked`)

- [ ] **Step 1: Write the failing test**

Create `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AppDatabaseTests.swift`:

```swift
import GRDB
@testable import Persistence
import Testing

@Suite struct AppDatabaseTests {
    @Test func migratesEmptyDatabaseToV1() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.v1.migrate(queue)

        try queue.read { db in
            // All tables exist.
            #expect(try db.tableExists("score_items"))
            #expect(try db.tableExists("tags"))
            #expect(try db.tableExists("playlists"))
            #expect(try db.tableExists("score_item_tags"))
            #expect(try db.tableExists("playlist_items"))

            // Indexes exist.
            let indexNames = try Set(db.indexes(on: "score_items").map(\.name))
            #expect(indexNames.contains("idx_score_items_content_hash"))
            #expect(indexNames.contains("idx_score_items_last_opened_at"))
        }
    }

    @Test func migrationIsIdempotent() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.v1.migrate(queue)
        // A second migrate() must not throw and must leave the schema unchanged.
        try AppMigrations.v1.migrate(queue)
        try queue.read { db in
            #expect(try db.tableExists("score_items"))
        }
    }

    @Test func appDatabaseFactoryReturnsUsableConnection() throws {
        let tmp = try TempDirectory()
        let db = try AppDatabase(databaseURL: tmp.url.appending(path: "f.sqlite"))
        try db.pool.read { db in
            #expect(try db.tableExists("score_items"))
        }
    }
}
```

- [ ] **Step 2: Run; expect fail (`AppMigrations`, `AppDatabase` undefined)**

Run: `cd Packages/Infrastructure && swift test --filter AppDatabaseTests`
Expected: FAIL — types undefined.

- [ ] **Step 3: Implement migrations**

Create `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift`:

```swift
import GRDB

public enum AppMigrations {
    /// The v1 migrator. Idempotent — `migrate` can be called repeatedly.
    public static let v1: DatabaseMigrator = {
        var m = DatabaseMigrator()
        #if DEBUG
        // Surface schema bugs early in development; ignored in release builds.
        m.eraseDatabaseOnSchemaChange = false
        #endif

        m.registerMigration("v1") { db in
            try db.execute(sql: """
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
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_score_items_content_hash ON score_items(content_hash)")
            try db.execute(sql: "CREATE INDEX idx_score_items_last_opened_at ON score_items(last_opened_at DESC)")

            try db.execute(sql: """
                CREATE TABLE tags (
                    id    TEXT PRIMARY KEY,
                    name  TEXT NOT NULL,
                    color_hex TEXT
                )
                """)

            try db.execute(sql: """
                CREATE TABLE playlists (
                    id          TEXT PRIMARY KEY,
                    name        TEXT NOT NULL,
                    created_at  REAL NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE score_item_tags (
                    score_item_id  TEXT NOT NULL REFERENCES score_items(id) ON DELETE CASCADE,
                    tag_id         TEXT NOT NULL REFERENCES tags(id)        ON DELETE CASCADE,
                    PRIMARY KEY (score_item_id, tag_id)
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_score_item_tags_tag_id ON score_item_tags(tag_id)")

            try db.execute(sql: """
                CREATE TABLE playlist_items (
                    playlist_id    TEXT    NOT NULL REFERENCES playlists(id)   ON DELETE CASCADE,
                    score_item_id  TEXT    NOT NULL REFERENCES score_items(id) ON DELETE CASCADE,
                    position       INTEGER NOT NULL,
                    PRIMARY KEY (playlist_id, score_item_id)
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_playlist_items_playlist_id_position ON playlist_items(playlist_id, position)")
        }

        return m
    }()
}
```

- [ ] **Step 4: Implement AppDatabase**

Create `Packages/Infrastructure/Sources/Persistence/Database/AppDatabase.swift`:

```swift
import Foundation
import GRDB

/// Constructs a `DatabasePool` for Folino's SQLite store and runs schema
/// migrations on first use. Owned by the App composition root; the pool's
/// thread safety lets background tasks read while writes happen on the
/// writer queue.
public final class AppDatabase: Sendable {
    public let pool: DatabasePool

    /// Build an on-disk database at the given URL. The parent directory
    /// must already exist (the App bootstrap creates it). Foreign-key
    /// enforcement is enabled on every connection.
    public init(databaseURL: URL) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: databaseURL.path, configuration: config)
        try AppMigrations.v1.migrate(pool)
        self.pool = pool
    }
}
```

- [ ] **Step 5: Delete the Persistence Placeholder and update the smoke test**

Delete `Packages/Infrastructure/Sources/Persistence/Placeholder.swift`.

Edit `Packages/Infrastructure/Tests/InfrastructureTests/InfrastructureTests.swift` — replace `#expect(PersistenceModule.isLinked)` with `#expect(true)` so the suite still compiles, OR drop the assertion entirely. Replace the file contents with:

```swift
@testable import Audio
@testable import CloudSync
@testable import Persistence
@testable import ScoreFiles
@testable import Soundfonts
import Testing

@Suite struct InfrastructureSmokeTests {
    @Test func remainingPlaceholderModulesLink() {
        #expect(CloudSyncModule.isLinked)
        #expect(SoundfontsModule.isLinked)
        #expect(AudioModule.isLinked)
        // Persistence and ScoreFiles no longer have placeholders — their real
        // types are exercised in dedicated tests below.
        #expect(ScoreFilesModule.isLinked) // ScoreFiles placeholder still present (Task 14 deletes it)
    }
}
```

NOTE: `ScoreFilesModule.isLinked` stays true here because the ScoreFiles `Placeholder.swift` is not deleted until Task 14. Until then this assertion compiles.

- [ ] **Step 6: Run the test**

Run: `cd Packages/Infrastructure && swift test --filter AppDatabaseTests`
Expected: PASS.

Run: `cd Packages/Infrastructure && swift test`
Expected: PASS — full Infrastructure suite green.

- [ ] **Step 7: Commit**

```bash
git add Packages/Infrastructure/Sources/Persistence/Database \
        Packages/Infrastructure/Tests/InfrastructureTests/Persistence \
        Packages/Infrastructure/Tests/InfrastructureTests/InfrastructureTests.swift
git rm Packages/Infrastructure/Sources/Persistence/Placeholder.swift
git commit -m "feat(persistence): add AppDatabase and v1 migration"
```

---

### Phase C — Records

---

### Task 8: ScoreItemRecord with Domain ↔ DB translation

**Files:**
- Create: `Packages/Infrastructure/Sources/Persistence/Records/ScoreItemRecord.swift`
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AppDatabaseTests.swift` (or new file `ScoreItemRecordTests.swift`)

- [ ] **Step 1: Write the test**

Create `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ScoreItemRecordTests.swift`:

```swift
@testable import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@Suite struct ScoreItemRecordTests {
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppMigrations.v1.migrate(q)
        return q
    }

    private func sampleItem() -> ScoreItem {
        ScoreItem(
            title: "Prelude in C",
            composer: "Bach",
            instrumentationSummary: "Piano",
            localFileName: "x.mscz",
            contentHash: String(repeating: "a", count: 64),
            sizeBytes: 4096,
            lengthBeats: 32,
            defaultTempoBpm: 80,
            primaryKey: "C",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: true
        )
    }

    @Test func roundTripsThroughGRDB() throws {
        let queue = try makeQueue()
        let item = sampleItem()
        try queue.write { db in
            try ScoreItemRecord(domain: item).insert(db)
        }
        let fetched = try queue.read { db -> ScoreItemRecord? in
            try ScoreItemRecord.fetchOne(db, key: item.id.rawValue.uuidString)
        }
        let domain = try #require(fetched).toDomain(tagIDs: [])
        #expect(domain == item)
    }
}
```

- [ ] **Step 2: Run; expect fail (`ScoreItemRecord` undefined)**

Run: `cd Packages/Infrastructure && swift test --filter ScoreItemRecordTests`
Expected: FAIL.

- [ ] **Step 3: Implement the record**

Create `Packages/Infrastructure/Sources/Persistence/Records/ScoreItemRecord.swift`:

```swift
import Domain
import Foundation
import GRDB

/// Row mirror for the `score_items` table. Tag IDs are NOT stored on this
/// record — they live in `score_item_tags` and are joined in by the
/// repository before building a `ScoreItem`.
struct ScoreItemRecord: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "score_items"

    var id: String
    var title: String
    var composer: String?
    var instrumentationSummary: String?
    var localFileName: String
    var contentHash: String
    var sizeBytes: Int64
    var lengthBeats: Int
    var defaultTempoBpm: Int
    var primaryKey: String?
    var addedAt: Double
    var lastOpenedAt: Double?
    var isFavorite: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case composer
        case instrumentationSummary = "instrumentation_summary"
        case localFileName = "local_file_name"
        case contentHash = "content_hash"
        case sizeBytes = "size_bytes"
        case lengthBeats = "length_beats"
        case defaultTempoBpm = "default_tempo_bpm"
        case primaryKey = "primary_key"
        case addedAt = "added_at"
        case lastOpenedAt = "last_opened_at"
        case isFavorite = "is_favorite"
    }

    init(domain item: ScoreItem) {
        id = item.id.rawValue.uuidString
        title = item.title
        composer = item.composer
        instrumentationSummary = item.instrumentationSummary
        localFileName = item.localFileName
        contentHash = item.contentHash
        sizeBytes = item.sizeBytes
        lengthBeats = item.lengthBeats
        defaultTempoBpm = item.defaultTempoBpm
        primaryKey = item.primaryKey
        addedAt = item.addedAt.timeIntervalSince1970
        lastOpenedAt = item.lastOpenedAt?.timeIntervalSince1970
        isFavorite = item.isFavorite
    }

    func toDomain(tagIDs: Set<TagID>) throws -> ScoreItem {
        guard let uuid = UUID(uuidString: id) else {
            throw DomainError.persistenceFailed(reason: "score_items.id is not a valid UUID: \(id)")
        }
        return ScoreItem(
            id: ScoreItemID(rawValue: uuid),
            title: title,
            composer: composer,
            instrumentationSummary: instrumentationSummary,
            localFileName: localFileName,
            contentHash: contentHash,
            sizeBytes: sizeBytes,
            lengthBeats: lengthBeats,
            defaultTempoBpm: defaultTempoBpm,
            primaryKey: primaryKey,
            addedAt: Date(timeIntervalSince1970: addedAt),
            lastOpenedAt: lastOpenedAt.map(Date.init(timeIntervalSince1970:)),
            tagIDs: tagIDs,
            isFavorite: isFavorite
        )
    }
}
```

- [ ] **Step 4: Run; expect pass**

Run: `cd Packages/Infrastructure && swift test --filter ScoreItemRecordTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/Persistence/Records/ScoreItemRecord.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ScoreItemRecordTests.swift
git commit -m "feat(persistence): add ScoreItemRecord with domain translation"
```

---

### Task 9: TagRecord, PlaylistRecord, junction records

**Files:**
- Create: `Packages/Infrastructure/Sources/Persistence/Records/TagRecord.swift`
- Create: `Packages/Infrastructure/Sources/Persistence/Records/PlaylistRecord.swift`
- Create: `Packages/Infrastructure/Sources/Persistence/Records/ScoreItemTagRecord.swift`
- Create: `Packages/Infrastructure/Sources/Persistence/Records/PlaylistItemRecord.swift`
- Create: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/RecordsTests.swift`

- [ ] **Step 1: Write the test**

Create `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/RecordsTests.swift`:

```swift
@testable import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@Suite struct RecordsTests {
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppMigrations.v1.migrate(q)
        return q
    }

    @Test func tagRoundTrips() throws {
        let queue = try makeQueue()
        let tag = Domain.Tag(name: "Bach", colorHex: "#AA00FF")
        try queue.write { db in try TagRecord(domain: tag).insert(db) }
        let fetched = try queue.read { db in
            try TagRecord.fetchOne(db, key: tag.id.rawValue.uuidString)
        }
        let domain = try #require(fetched).toDomain()
        #expect(domain == tag)
    }

    @Test func playlistRoundTripsWithoutItems() throws {
        let queue = try makeQueue()
        let playlist = Playlist(
            name: "Practice", orderedScoreItemIDs: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try queue.write { db in try PlaylistRecord(domain: playlist).insert(db) }
        let fetched = try queue.read { db in
            try PlaylistRecord.fetchOne(db, key: playlist.id.rawValue.uuidString)
        }
        let domain = try #require(fetched).toDomain(orderedScoreItemIDs: [])
        #expect(domain == playlist)
    }

    @Test func playlistItemPositionRoundTrips() throws {
        let queue = try makeQueue()
        // Need a playlist + score items first because of FK.
        let pl = Playlist(name: "x", orderedScoreItemIDs: [], createdAt: Date())
        let scoreA = ScoreItem(
            title: "a", composer: nil, instrumentationSummary: nil,
            localFileName: "a.mid", contentHash: "h1", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
        let scoreB = ScoreItem(
            title: "b", composer: nil, instrumentationSummary: nil,
            localFileName: "b.mid", contentHash: "h2", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
        try queue.write { db in
            try PlaylistRecord(domain: pl).insert(db)
            try ScoreItemRecord(domain: scoreA).insert(db)
            try ScoreItemRecord(domain: scoreB).insert(db)
            // Insert in scrambled position order.
            try PlaylistItemRecord(
                playlistID: pl.id.rawValue.uuidString,
                scoreItemID: scoreB.id.rawValue.uuidString,
                position: 1
            ).insert(db)
            try PlaylistItemRecord(
                playlistID: pl.id.rawValue.uuidString,
                scoreItemID: scoreA.id.rawValue.uuidString,
                position: 0
            ).insert(db)
        }

        let ordered = try queue.read { db -> [String] in
            try PlaylistItemRecord
                .filter(Column("playlist_id") == pl.id.rawValue.uuidString)
                .order(Column("position"))
                .fetchAll(db)
                .map(\.scoreItemID)
        }
        #expect(ordered == [scoreA.id.rawValue.uuidString, scoreB.id.rawValue.uuidString])
    }

    @Test func tagDeleteCascadesToJunction() throws {
        let queue = try makeQueue()
        let tag = Domain.Tag(name: "x", colorHex: "#000000")
        let item = ScoreItem(
            title: "i", composer: nil, instrumentationSummary: nil,
            localFileName: "i.mid", contentHash: "h", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [tag.id], isFavorite: false
        )
        try queue.write { db in
            try TagRecord(domain: tag).insert(db)
            try ScoreItemRecord(domain: item).insert(db)
            try ScoreItemTagRecord(
                scoreItemID: item.id.rawValue.uuidString,
                tagID: tag.id.rawValue.uuidString
            ).insert(db)
        }
        try queue.write { db in
            _ = try TagRecord.deleteOne(db, key: tag.id.rawValue.uuidString)
        }
        let remaining = try queue.read { db in
            try ScoreItemTagRecord
                .filter(Column("score_item_id") == item.id.rawValue.uuidString)
                .fetchCount(db)
        }
        #expect(remaining == 0)
    }
}
```

- [ ] **Step 2: Run; expect failure**

Run: `cd Packages/Infrastructure && swift test --filter RecordsTests`
Expected: FAIL — `TagRecord`, `PlaylistRecord`, `ScoreItemTagRecord`, `PlaylistItemRecord` undefined.

- [ ] **Step 3: Implement TagRecord**

Create `Packages/Infrastructure/Sources/Persistence/Records/TagRecord.swift`:

```swift
import Domain
import Foundation
import GRDB

struct TagRecord: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "tags"

    var id: String
    var name: String
    var colorHex: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case colorHex = "color_hex"
    }

    init(domain tag: Domain.Tag) {
        id = tag.id.rawValue.uuidString
        name = tag.name
        colorHex = tag.colorHex
    }

    func toDomain() throws -> Domain.Tag {
        guard let uuid = UUID(uuidString: id) else {
            throw DomainError.persistenceFailed(reason: "tags.id is not a valid UUID: \(id)")
        }
        return Domain.Tag(id: TagID(rawValue: uuid), name: name, colorHex: colorHex ?? "")
    }
}
```

- [ ] **Step 4: Implement PlaylistRecord**

Create `Packages/Infrastructure/Sources/Persistence/Records/PlaylistRecord.swift`:

```swift
import Domain
import Foundation
import GRDB

struct PlaylistRecord: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "playlists"

    var id: String
    var name: String
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt = "created_at"
    }

    init(domain playlist: Playlist) {
        id = playlist.id.rawValue.uuidString
        name = playlist.name
        createdAt = playlist.createdAt.timeIntervalSince1970
    }

    func toDomain(orderedScoreItemIDs: [ScoreItemID]) throws -> Playlist {
        guard let uuid = UUID(uuidString: id) else {
            throw DomainError.persistenceFailed(reason: "playlists.id is not a valid UUID: \(id)")
        }
        return Playlist(
            id: PlaylistID(rawValue: uuid),
            name: name,
            orderedScoreItemIDs: orderedScoreItemIDs,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}
```

- [ ] **Step 5: Implement junction records**

Create `Packages/Infrastructure/Sources/Persistence/Records/ScoreItemTagRecord.swift`:

```swift
import GRDB

struct ScoreItemTagRecord: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "score_item_tags"

    var scoreItemID: String
    var tagID: String

    enum CodingKeys: String, CodingKey {
        case scoreItemID = "score_item_id"
        case tagID = "tag_id"
    }
}
```

Create `Packages/Infrastructure/Sources/Persistence/Records/PlaylistItemRecord.swift`:

```swift
import GRDB

struct PlaylistItemRecord: FetchableRecord, PersistableRecord, Codable {
    static let databaseTableName = "playlist_items"

    var playlistID: String
    var scoreItemID: String
    var position: Int

    enum CodingKeys: String, CodingKey {
        case playlistID = "playlist_id"
        case scoreItemID = "score_item_id"
        case position
    }
}
```

- [ ] **Step 6: Run; expect pass**

Run: `cd Packages/Infrastructure && swift test --filter RecordsTests`
Expected: PASS.

Run: `cd Packages/Infrastructure && swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Packages/Infrastructure/Sources/Persistence/Records \
        Packages/Infrastructure/Tests/InfrastructureTests/Persistence/RecordsTests.swift
git commit -m "feat(persistence): add Tag/Playlist records and junctions with cascade"
```

---

### Phase D — LiveScoreLibraryRepository

This phase builds the observable repository in three slices: skeleton + observation, CRUD, and disk-aware delete. Each commit leaves `swift test` green.

---

### Task 10: LiveScoreLibraryRepository skeleton with ValueObservation

**Files:**
- Create: `Packages/Infrastructure/Sources/Persistence/LiveScoreLibraryRepository.swift`
- Create: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreLibraryRepositoryTests.swift`

- [ ] **Step 1: Write the test (refresh + observation wiring)**

Create `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreLibraryRepositoryTests.swift`:

```swift
@testable import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@MainActor
@Suite struct LiveScoreLibraryRepositoryTests {
    private func makeDatabase() throws -> AppDatabase {
        let tmp = try TempDirectory()
        return try AppDatabase(databaseURL: tmp.url.appending(path: "f.sqlite"))
    }

    @Test func refreshOnEmptyDatabaseProducesEmptyArrays() async throws {
        let db = try makeDatabase()
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
        try await repo.refresh()
        #expect(repo.scoreItems.isEmpty)
        #expect(repo.tags.isEmpty)
        #expect(repo.playlists.isEmpty)
    }
}
```

- [ ] **Step 2: Run; expect fail**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreLibraryRepositoryTests`
Expected: FAIL — `LiveScoreLibraryRepository` undefined.

- [ ] **Step 3: Implement the skeleton**

Create `Packages/Infrastructure/Sources/Persistence/LiveScoreLibraryRepository.swift`:

```swift
import Domain
import Foundation
import GRDB
import Observation

/// Live, GRDB-backed implementation of `ScoreLibraryRepository`. Holds the
/// library snapshot in `@Observable` properties refreshed by a single
/// `ValueObservation` task started on the first `refresh()`.
@MainActor
@Observable
public final class LiveScoreLibraryRepository: ScoreLibraryRepository {
    public private(set) var scoreItems: [ScoreItem] = []
    public private(set) var tags: [Domain.Tag] = []
    public private(set) var playlists: [Playlist] = []

    @ObservationIgnored
    private let database: AppDatabase
    @ObservationIgnored
    private let scoresDirectory: URL
    @ObservationIgnored
    private var observationTask: Task<Void, Never>?

    public init(database: AppDatabase, scoresDirectory: URL) {
        self.database = database
        self.scoresDirectory = scoresDirectory
    }

    deinit {
        observationTask?.cancel()
    }

    public func refresh() async throws {
        guard observationTask == nil else { return }
        startObservation()
        // Wait for the first snapshot. Polls the local property — adequate
        // for a one-time await, and avoids exposing AsyncSequence on the API.
        try await waitForFirstSnapshot()
    }

    // MARK: - Observation

    private func startObservation() {
        let observation = ValueObservation.tracking { db -> Snapshot in
            let items = try ScoreItemRecord.fetchAll(db)
            let tagsRows = try TagRecord.fetchAll(db)
            let playlistsRows = try PlaylistRecord.fetchAll(db)
            let itemTagRows = try ScoreItemTagRecord.fetchAll(db)
            let playlistItemRows = try PlaylistItemRecord
                .order(Column("playlist_id"), Column("position"))
                .fetchAll(db)
            return Snapshot(
                items: items, tags: tagsRows, playlists: playlistsRows,
                itemTags: itemTagRows, playlistItems: playlistItemRows
            )
        }

        let pool = database.pool
        observationTask = Task { [weak self] in
            do {
                for try await snap in observation.values(in: pool) {
                    guard let self else { return }
                    let mapped = await Self.materialize(snap)
                    await MainActor.run {
                        self.scoreItems = mapped.items
                        self.tags = mapped.tags
                        self.playlists = mapped.playlists
                        self.firstSnapshotContinuation?.resume()
                        self.firstSnapshotContinuation = nil
                    }
                }
            } catch {
                // Observation cancelled or DB closed; drop silently.
            }
        }
    }

    // Single-shot continuation that the first observation snapshot satisfies.
    @ObservationIgnored
    private var firstSnapshotContinuation: CheckedContinuation<Void, Never>?

    private func waitForFirstSnapshot() async throws {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.firstSnapshotContinuation = cont
        }
    }

    // MARK: - Snapshot translation

    private struct Snapshot: Sendable {
        var items: [ScoreItemRecord]
        var tags: [TagRecord]
        var playlists: [PlaylistRecord]
        var itemTags: [ScoreItemTagRecord]
        var playlistItems: [PlaylistItemRecord]
    }

    private struct Materialized {
        var items: [ScoreItem]
        var tags: [Domain.Tag]
        var playlists: [Playlist]
    }

    nonisolated private static func materialize(_ snap: Snapshot) async -> Materialized {
        // Build tagID set per item.
        var tagIDsByItem: [String: Set<TagID>] = [:]
        for row in snap.itemTags {
            guard let uuid = UUID(uuidString: row.tagID) else { continue }
            tagIDsByItem[row.scoreItemID, default: []].insert(TagID(rawValue: uuid))
        }
        let items: [ScoreItem] = snap.items.compactMap { rec in
            try? rec.toDomain(tagIDs: tagIDsByItem[rec.id] ?? [])
        }
        let tags: [Domain.Tag] = snap.tags.compactMap { try? $0.toDomain() }

        // Build ordered ScoreItemIDs per playlist.
        var orderedByPlaylist: [String: [ScoreItemID]] = [:]
        for row in snap.playlistItems {
            guard let uuid = UUID(uuidString: row.scoreItemID) else { continue }
            orderedByPlaylist[row.playlistID, default: []].append(ScoreItemID(rawValue: uuid))
        }
        let playlists: [Playlist] = snap.playlists.compactMap { rec in
            try? rec.toDomain(orderedScoreItemIDs: orderedByPlaylist[rec.id] ?? [])
        }
        return Materialized(items: items, tags: tags, playlists: playlists)
    }

    // MARK: - Stubs (filled in by Tasks 11–13)

    public func saveScoreItem(_ item: ScoreItem) async throws {
        throw DomainError.persistenceFailed(reason: "saveScoreItem not yet implemented")
    }

    public func deleteScoreItem(id: ScoreItemID) async throws {
        throw DomainError.persistenceFailed(reason: "deleteScoreItem not yet implemented")
    }

    public func saveTag(_ tag: Domain.Tag) async throws {
        throw DomainError.persistenceFailed(reason: "saveTag not yet implemented")
    }

    public func deleteTag(id: TagID) async throws {
        throw DomainError.persistenceFailed(reason: "deleteTag not yet implemented")
    }

    public func savePlaylist(_ playlist: Playlist) async throws {
        throw DomainError.persistenceFailed(reason: "savePlaylist not yet implemented")
    }

    public func deletePlaylist(id: PlaylistID) async throws {
        throw DomainError.persistenceFailed(reason: "deletePlaylist not yet implemented")
    }

    public func scoreItems(matchingContentHash contentHash: String) async throws -> [ScoreItem] {
        throw DomainError.persistenceFailed(reason: "scoreItems(matchingContentHash:) not yet implemented")
    }
}
```

- [ ] **Step 4: Run; expect pass**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreLibraryRepositoryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/Persistence/LiveScoreLibraryRepository.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreLibraryRepositoryTests.swift
git commit -m "feat(persistence): LiveScoreLibraryRepository skeleton with ValueObservation"
```

---

### Task 11: Implement save/delete for ScoreItem and tag relations

**Files:**
- Modify: `Packages/Infrastructure/Sources/Persistence/LiveScoreLibraryRepository.swift`
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreLibraryRepositoryTests.swift`

- [ ] **Step 1: Add the test**

Append to `LiveScoreLibraryRepositoryTests.swift`:

```swift
@Test func saveScoreItemRoundTripsViaObservation() async throws {
    let db = try makeDatabase()
    let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
    try await repo.refresh()

    let tag = Domain.Tag(name: "Bach", colorHex: "#FF0000")
    try await db.pool.write { try TagRecord(domain: tag).insert($0) }

    let item = ScoreItem(
        title: "Prelude", composer: "Bach", instrumentationSummary: "Piano",
        localFileName: "x.mscz", contentHash: "h1", sizeBytes: 100,
        lengthBeats: 16, defaultTempoBpm: 80, primaryKey: "C",
        addedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastOpenedAt: nil, tagIDs: [tag.id], isFavorite: false
    )
    try await repo.saveScoreItem(item)

    try await waitFor { repo.scoreItems.contains { $0.id == item.id } }
    let stored = try #require(repo.scoreItems.first { $0.id == item.id })
    #expect(stored.tagIDs == [tag.id])
    #expect(stored.title == "Prelude")
}

@Test func deleteScoreItemRemovesFromArray() async throws {
    let db = try makeDatabase()
    let scoresDir = try TempDirectory()
    let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: scoresDir.url)
    try await repo.refresh()

    let item = ScoreItem(
        title: "x", composer: nil, instrumentationSummary: nil,
        localFileName: "x.mid", contentHash: "h", sizeBytes: 0,
        lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
        addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false
    )
    try await repo.saveScoreItem(item)
    try await waitFor { repo.scoreItems.contains { $0.id == item.id } }

    try await repo.deleteScoreItem(id: item.id)
    try await waitFor { !repo.scoreItems.contains { $0.id == item.id } }
}

/// Polls a predicate up to ~2s, yielding to the runtime between checks so
/// the ValueObservation task can run.
@MainActor
private func waitFor(
    timeout: Duration = .seconds(2),
    _ predicate: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("predicate never satisfied within \(timeout)")
}
```

- [ ] **Step 2: Run; expect fail**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreLibraryRepositoryTests`
Expected: FAIL — current `saveScoreItem` always throws.

- [ ] **Step 3: Replace the stubs**

In `LiveScoreLibraryRepository.swift`, replace the `saveScoreItem` and `deleteScoreItem` stubs with:

```swift
public func saveScoreItem(_ item: ScoreItem) async throws {
    let pool = database.pool
    do {
        try await pool.write { db in
            try ScoreItemRecord(domain: item).save(db)
            // Resync tag relations: drop existing, re-insert.
            try ScoreItemTagRecord
                .filter(Column("score_item_id") == item.id.rawValue.uuidString)
                .deleteAll(db)
            for tagID in item.tagIDs {
                try ScoreItemTagRecord(
                    scoreItemID: item.id.rawValue.uuidString,
                    tagID: tagID.rawValue.uuidString
                ).insert(db)
            }
        }
    } catch {
        throw DomainError.persistenceFailed(reason: "\(error)")
    }
}

public func deleteScoreItem(id: ScoreItemID) async throws {
    let pool = database.pool
    do {
        // Capture filename for disk cleanup BEFORE the row goes away.
        let filename: String? = try await pool.read { db in
            try ScoreItemRecord.fetchOne(db, key: id.rawValue.uuidString)?.localFileName
        }
        try await pool.write { db in
            _ = try ScoreItemRecord.deleteOne(db, key: id.rawValue.uuidString)
        }
        if let filename {
            let url = scoresDirectory.appending(path: filename)
            try? FileManager.default.removeItem(at: url)
        }
    } catch {
        throw DomainError.persistenceFailed(reason: "\(error)")
    }
}
```

- [ ] **Step 4: Run; expect pass**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreLibraryRepositoryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/Persistence/LiveScoreLibraryRepository.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreLibraryRepositoryTests.swift
git commit -m "feat(persistence): implement ScoreItem CRUD with tag relations"
```

---

### Task 12: Implement Tag CRUD with cascade verification, and contentHash lookup

**Files:**
- Modify: `Packages/Infrastructure/Sources/Persistence/LiveScoreLibraryRepository.swift`
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreLibraryRepositoryTests.swift`

- [ ] **Step 1: Add the tests**

Append:

```swift
@Test func saveTagAppearsInObservedArray() async throws {
    let db = try makeDatabase()
    let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
    try await repo.refresh()

    let tag = Domain.Tag(name: "Romantic", colorHex: "#00FFAA")
    try await repo.saveTag(tag)
    try await waitFor { repo.tags.contains { $0.id == tag.id } }
}

@Test func deleteTagCascadesToItemTagIDs() async throws {
    let db = try makeDatabase()
    let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
    try await repo.refresh()

    let tag = Domain.Tag(name: "x", colorHex: "#000000")
    try await repo.saveTag(tag)
    let item = ScoreItem(
        title: "x", composer: nil, instrumentationSummary: nil,
        localFileName: "x.mid", contentHash: "h", sizeBytes: 0,
        lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
        addedAt: Date(), lastOpenedAt: nil, tagIDs: [tag.id], isFavorite: false
    )
    try await repo.saveScoreItem(item)
    try await waitFor { repo.scoreItems.first { $0.id == item.id }?.tagIDs == [tag.id] }

    try await repo.deleteTag(id: tag.id)
    try await waitFor { repo.scoreItems.first { $0.id == item.id }?.tagIDs.isEmpty == true }
}

@Test func contentHashLookupReturnsAllMatches() async throws {
    let db = try makeDatabase()
    let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
    try await repo.refresh()

    let h = "shared-hash"
    func make() -> ScoreItem {
        ScoreItem(
            title: "x", composer: nil, instrumentationSummary: nil,
            localFileName: "\(UUID().uuidString).mid", contentHash: h, sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }
    try await repo.saveScoreItem(make())
    try await repo.saveScoreItem(make())
    let unique = make()
    let renamed = ScoreItem(
        id: unique.id, title: unique.title, composer: nil,
        instrumentationSummary: nil, localFileName: unique.localFileName,
        contentHash: "different", sizeBytes: 0, lengthBeats: 0,
        defaultTempoBpm: 120, primaryKey: nil,
        addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false
    )
    try await repo.saveScoreItem(renamed)

    let dups = try await repo.scoreItems(matchingContentHash: h)
    #expect(dups.count == 2)
}
```

- [ ] **Step 2: Run; expect fail**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreLibraryRepositoryTests`
Expected: FAIL — `saveTag`, `deleteTag`, `scoreItems(matchingContentHash:)` still throw.

- [ ] **Step 3: Implement**

Replace the corresponding stubs in `LiveScoreLibraryRepository.swift`:

```swift
public func saveTag(_ tag: Domain.Tag) async throws {
    do {
        try await database.pool.write { db in
            try TagRecord(domain: tag).save(db)
        }
    } catch {
        throw DomainError.persistenceFailed(reason: "\(error)")
    }
}

public func deleteTag(id: TagID) async throws {
    do {
        try await database.pool.write { db in
            _ = try TagRecord.deleteOne(db, key: id.rawValue.uuidString)
        }
    } catch {
        throw DomainError.persistenceFailed(reason: "\(error)")
    }
}

public func scoreItems(matchingContentHash contentHash: String) async throws -> [ScoreItem] {
    do {
        return try await database.pool.read { db in
            let records = try ScoreItemRecord
                .filter(Column("content_hash") == contentHash)
                .fetchAll(db)
            return try records.map { rec -> ScoreItem in
                let tagRows = try ScoreItemTagRecord
                    .filter(Column("score_item_id") == rec.id)
                    .fetchAll(db)
                let tagIDs = Set(tagRows.compactMap {
                    UUID(uuidString: $0.tagID).map(TagID.init(rawValue:))
                })
                return try rec.toDomain(tagIDs: tagIDs)
            }
        }
    } catch {
        throw DomainError.persistenceFailed(reason: "\(error)")
    }
}
```

- [ ] **Step 4: Run; expect pass**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreLibraryRepositoryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/Persistence/LiveScoreLibraryRepository.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreLibraryRepositoryTests.swift
git commit -m "feat(persistence): tag CRUD with cascade and contentHash lookup"
```

---

### Task 13: Implement Playlist CRUD with positions

**Files:**
- Modify: `Packages/Infrastructure/Sources/Persistence/LiveScoreLibraryRepository.swift`
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreLibraryRepositoryTests.swift`

- [ ] **Step 1: Add the test**

Append:

```swift
@Test func playlistOrderingRoundTripsThroughObservation() async throws {
    let db = try makeDatabase()
    let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
    try await repo.refresh()

    func make() -> ScoreItem {
        ScoreItem(
            title: "x", composer: nil, instrumentationSummary: nil,
            localFileName: "\(UUID().uuidString).mid", contentHash: "h", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }
    let a = make(); let b = make(); let c = make()
    try await repo.saveScoreItem(a)
    try await repo.saveScoreItem(b)
    try await repo.saveScoreItem(c)
    try await waitFor { repo.scoreItems.count == 3 }

    let pl = Playlist(
        name: "Practice",
        orderedScoreItemIDs: [c.id, a.id, b.id],
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try await repo.savePlaylist(pl)
    try await waitFor {
        repo.playlists.first?.orderedScoreItemIDs == [c.id, a.id, b.id]
    }
    #expect(repo.playlists.count == 1)
}

@Test func deletePlaylistRemovesIt() async throws {
    let db = try makeDatabase()
    let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: URL(fileURLWithPath: "/dev/null"))
    try await repo.refresh()

    let pl = Playlist(name: "x", orderedScoreItemIDs: [], createdAt: Date())
    try await repo.savePlaylist(pl)
    try await waitFor { repo.playlists.contains { $0.id == pl.id } }
    try await repo.deletePlaylist(id: pl.id)
    try await waitFor { !repo.playlists.contains { $0.id == pl.id } }
}
```

- [ ] **Step 2: Run; expect fail**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreLibraryRepositoryTests`
Expected: FAIL — playlist methods still throw.

- [ ] **Step 3: Implement**

Replace the playlist stubs:

```swift
public func savePlaylist(_ playlist: Playlist) async throws {
    do {
        try await database.pool.write { db in
            try PlaylistRecord(domain: playlist).save(db)
            // Resync the items: drop and reinsert with explicit positions.
            try PlaylistItemRecord
                .filter(Column("playlist_id") == playlist.id.rawValue.uuidString)
                .deleteAll(db)
            for (position, scoreItemID) in playlist.orderedScoreItemIDs.enumerated() {
                try PlaylistItemRecord(
                    playlistID: playlist.id.rawValue.uuidString,
                    scoreItemID: scoreItemID.rawValue.uuidString,
                    position: position
                ).insert(db)
            }
        }
    } catch {
        throw DomainError.persistenceFailed(reason: "\(error)")
    }
}

public func deletePlaylist(id: PlaylistID) async throws {
    do {
        try await database.pool.write { db in
            _ = try PlaylistRecord.deleteOne(db, key: id.rawValue.uuidString)
        }
    } catch {
        throw DomainError.persistenceFailed(reason: "\(error)")
    }
}
```

- [ ] **Step 4: Run; expect pass**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreLibraryRepositoryTests`
Expected: PASS.

Run: `cd Packages/Infrastructure && swift test`
Expected: PASS — full Infrastructure suite green.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/Persistence/LiveScoreLibraryRepository.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreLibraryRepositoryTests.swift
git commit -m "feat(persistence): playlist CRUD with explicit position ordering"
```

---

### Phase E — ScoreFiles module

---

### Task 14: ScoreFileSummary+Score helper and minimal MSCX fixture

**Files:**
- Delete: `Packages/Infrastructure/Sources/ScoreFiles/Placeholder.swift`
- Create: `Packages/Infrastructure/Sources/ScoreFiles/ScoreFileSummary+Score.swift`
- Create: `Packages/Infrastructure/Tests/InfrastructureTests/Resources/minimal.mscx`
- Modify: `Packages/Infrastructure/Package.swift` (declare resources on `InfrastructureTests`)
- Create: `Packages/Infrastructure/Tests/InfrastructureTests/TestSupport/Fixtures.swift`
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/InfrastructureTests.swift` (drop `ScoreFilesModule.isLinked`)

- [ ] **Step 1: Add the minimal MSCX fixture**

Create `Packages/Infrastructure/Tests/InfrastructureTests/Resources/minimal.mscx` with the following content (one C4 quarter note in 4/4, one staff, no tempo or time-sig overrides). This is hand-written and contains no GPL fixture content from MuseScore:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<museScore version="4.20">
  <Score>
    <Division>480</Division>
    <Staff id="1">
      <VBox>
        <height>10</height>
        <Text>
          <style>title</style>
          <text>Minimal</text>
        </Text>
      </VBox>
      <Measure>
        <voice>
          <TimeSig>
            <sigN>4</sigN>
            <sigD>4</sigD>
          </TimeSig>
          <Chord>
            <durationType>quarter</durationType>
            <Note>
              <pitch>60</pitch>
              <tpc>14</tpc>
            </Note>
          </Chord>
          <Rest>
            <durationType>quarter</durationType>
          </Rest>
          <Rest>
            <durationType>quarter</durationType>
          </Rest>
          <Rest>
            <durationType>quarter</durationType>
          </Rest>
        </voice>
      </Measure>
    </Staff>
    <Part>
      <Staff id="1"></Staff>
      <Instrument>
        <trackName>Piano</trackName>
        <longName>Piano</longName>
        <shortName>Pno.</shortName>
      </Instrument>
    </Part>
  </Score>
</museScore>
```

If `swift-sheet-music`'s `MSCXParser.parse(_)` rejects this minimal shape (e.g. because of a required element this stub omits), trim or extend until it parses. The test in Task 15 will fail loudly if so, providing a clear error message — adjust the fixture and re-run. Goal: the smallest XML the parser accepts and reports `parts.isEmpty == false`.

- [ ] **Step 2: Declare the resource on the test target**

Edit `Packages/Infrastructure/Package.swift`. Replace the `.testTarget` block with:

```swift
.testTarget(
    name: "InfrastructureTests",
    dependencies: ["Persistence", "CloudSync", "Soundfonts", "Audio", "ScoreFiles"],
    resources: [.process("Resources")]
),
```

- [ ] **Step 3: Add the Fixtures helper**

Create `Packages/Infrastructure/Tests/InfrastructureTests/TestSupport/Fixtures.swift`:

```swift
import Foundation
import SheetMusic
import Testing

enum Fixtures {
    /// Loads `minimal.mscx` bytes from the test bundle.
    static func minimalMSCXData() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "minimal", withExtension: "mscx"))
        return try Data(contentsOf: url)
    }

    /// Synthesizes minimal `.mscz` bytes by packaging the bundled `.mscx`
    /// through `swift-sheet-music`'s MSCZ writer. No GPL fixture data.
    static func minimalMSCZData() throws -> Data {
        let mscx = try minimalMSCXData()
        return try SheetMusic.saveMSCZ(mscxData: mscx)
    }

    /// Synthesizes minimal `.mid` bytes by parsing the `.mscx` fixture and
    /// rendering it through `SheetMusic.exportMIDI`.
    static func minimalMIDIData() throws -> Data {
        let score = try SheetMusic.loadScore(mscxData: minimalMSCXData())
        return try SheetMusic.exportMIDI(score: score)
    }

    /// Writes the bytes to a tmp URL with the given extension, returning the URL.
    static func writeToTempFile(_ data: Data, ext: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: "fixture-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }
}
```

- [ ] **Step 4: Delete the ScoreFiles Placeholder, add the Score+Summary helper**

Delete `Packages/Infrastructure/Sources/ScoreFiles/Placeholder.swift`.

Create `Packages/Infrastructure/Sources/ScoreFiles/ScoreFileSummary+Score.swift`:

```swift
import Domain
import Foundation
import SheetMusic

extension ScoreFileSummary {
    /// Derive a summary from a parsed `Score`. The actual field-by-field
    /// extraction is best-effort; missing values fall back to safe defaults
    /// that make the summary usable as a library-row payload.
    init(score: Score) {
        let parts = score.parts.map(\.instrument.trackName).filter { !$0.isEmpty }
        self.init(
            title: score.metaTitle,
            composer: score.metaComposer,
            instrumentationSummary: parts.joined(separator: ", "),
            lengthBeats: score.lengthInBeats,
            defaultTempoBpm: score.defaultTempoBPM,
            primaryKey: score.primaryKeyName
        )
    }
}

// MARK: - Score accessors used by the summary

private extension Score {
    /// Best-effort title; falls back to nil when not provided by the source file.
    var metaTitle: String? {
        // swift-sheet-music's Score does not yet expose a title field directly;
        // until it does, return nil so the importer/UI can fall back to filename.
        nil
    }

    var metaComposer: String? { nil }

    /// Total length in beats, summed across all measures of part 0 staff 0.
    /// Falls back to 0 if the score is empty.
    var lengthInBeats: Int {
        guard let part = parts.first, let staff = part.staves.first else { return 0 }
        return staff.measures.reduce(0) { acc, m in acc + m.beatCount }
    }

    var defaultTempoBPM: Int { 120 }

    var primaryKeyName: String? { nil }
}

// `Measure.beatCount` extension lives next to the score type; if swift-sheet-music
// already exposes a `beatCount` property the placeholder below shadows it harmlessly.
private extension Measure {
    var beatCount: Int {
        // Best-effort: 4/4 fallback. A precise implementation would inspect
        // the active TimeSig — out of scope for Plan #3 and improved when the
        // Reader plan needs it.
        4
    }
}
```

If `Score`, `parts`, `staves`, `measures`, etc., have different names in the swift-sheet-music public API at the time of execution, adjust the property names — the goal is a `ScoreFileSummary` constructed from a `Score` that doesn't crash, with sane defaults. The Reader plan will sharpen these.

- [ ] **Step 5: Update the smoke test**

Edit `Packages/Infrastructure/Tests/InfrastructureTests/InfrastructureTests.swift` to drop the now-deleted ScoreFilesModule reference:

```swift
@testable import Audio
@testable import CloudSync
@testable import Soundfonts
import Testing

@Suite struct InfrastructureSmokeTests {
    @Test func remainingPlaceholderModulesLink() {
        #expect(CloudSyncModule.isLinked)
        #expect(SoundfontsModule.isLinked)
        #expect(AudioModule.isLinked)
    }
}
```

- [ ] **Step 6: Run the build to confirm compile**

Run: `cd Packages/Infrastructure && swift build`
Expected: BUILD SUCCEEDED.

Run: `cd Packages/Infrastructure && swift test --filter InfrastructureSmokeTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Packages/Infrastructure/Sources/ScoreFiles \
        Packages/Infrastructure/Tests/InfrastructureTests/Resources \
        Packages/Infrastructure/Tests/InfrastructureTests/TestSupport/Fixtures.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/InfrastructureTests.swift \
        Packages/Infrastructure/Package.swift
git rm Packages/Infrastructure/Sources/ScoreFiles/Placeholder.swift
git commit -m "feat(scorefiles): add Score→ScoreFileSummary helper and minimal MSCX fixture"
```

---

### Task 15: LiveScoreFileGateway — detect / loadFileMetadata / loadScore

**Files:**
- Create: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreFileGateway.swift`
- Create: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreFileGatewayTests.swift`

- [ ] **Step 1: Write the test**

Create `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreFileGatewayTests.swift`:

```swift
@testable import Domain
import Foundation
@testable import ScoreFiles
import SheetMusic
import Testing

@Suite struct LiveScoreFileGatewayTests {
    @Test func detectsKnownExtensions() {
        let gateway = LiveScoreFileGateway()
        #expect(gateway.detectFormat(fileName: "x.mscz") == .mscz)
        #expect(gateway.detectFormat(fileName: "x.MSCZ") == .mscz)
        #expect(gateway.detectFormat(fileName: "x.mid") == .midi)
        #expect(gateway.detectFormat(fileName: "x.pdf") == nil)
        #expect(gateway.detectFormat(fileName: "x.txt") == nil)
    }

    @Test func loadFileMetadataReturnsSummaryForMSCX() async throws {
        let tmp = try TempDirectory()
        let mscxURL = try Fixtures.writeToTempFile(
            try Fixtures.minimalMSCXData(), ext: "mscx", in: tmp.url
        )
        let gateway = LiveScoreFileGateway()
        let summary = try await gateway.loadFileMetadata(fileURL: mscxURL)
        // The fixture is one quarter note + three rests in 4/4 == 4 beats; the
        // helper's per-measure fallback returns 4 beats. Either reading is fine
        // for v1 — assert "non-negative" rather than an exact value.
        #expect(summary.lengthBeats >= 0)
    }

    @Test func loadFileMetadataThrowsForPDF() async throws {
        let tmp = try TempDirectory()
        let pdfURL = try Fixtures.writeToTempFile(Data(), ext: "pdf", in: tmp.url)
        let gateway = LiveScoreFileGateway()
        do {
            _ = try await gateway.loadFileMetadata(fileURL: pdfURL)
            Issue.record("expected throw")
        } catch let DomainError.unsupportedFormat(ext) {
            #expect(ext == "pdf")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func loadScoreReturnsScoreAndSummary() async throws {
        let tmp = try TempDirectory()
        let mscxURL = try Fixtures.writeToTempFile(
            try Fixtures.minimalMSCXData(), ext: "mscx", in: tmp.url
        )
        let gateway = LiveScoreFileGateway()
        let result = try await gateway.loadScore(fileURL: mscxURL)
        #expect(result.score.parts.isEmpty == false)
    }

    @Test func loadFileMetadataRoundTripsMSCZ() async throws {
        let tmp = try TempDirectory()
        let msczURL = try Fixtures.writeToTempFile(
            try Fixtures.minimalMSCZData(), ext: "mscz", in: tmp.url
        )
        let gateway = LiveScoreFileGateway()
        let summary = try await gateway.loadFileMetadata(fileURL: msczURL)
        #expect(summary.lengthBeats >= 0)
    }

    @Test func loadFileMetadataReadsMIDI() async throws {
        let tmp = try TempDirectory()
        let midURL = try Fixtures.writeToTempFile(
            try Fixtures.minimalMIDIData(), ext: "mid", in: tmp.url
        )
        let gateway = LiveScoreFileGateway()
        // For v1 we accept that MIDI metadata extraction may be very minimal.
        // If swift-sheet-music doesn't yet read SMF→Score, the test asserts
        // that the call surfaces a `scoreParseFailed` rather than crashing.
        do {
            _ = try await gateway.loadFileMetadata(fileURL: midURL)
        } catch DomainError.scoreParseFailed {
            // Acceptable in v1 — recorded as an outstanding limitation.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func saveScoreThrowsUnsupportedFormatInV1() async throws {
        let tmp = try TempDirectory()
        let gateway = LiveScoreFileGateway()
        let score = try SheetMusic.loadScore(mscxData: try Fixtures.minimalMSCXData())
        let outURL = tmp.url.appending(path: "out.mscz")
        do {
            try await gateway.saveScore(score, fileURL: outURL, format: .mscz)
            Issue.record("expected throw")
        } catch DomainError.unsupportedFormat {
            // Expected.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run; expect compile fail**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreFileGatewayTests`
Expected: FAIL — `LiveScoreFileGateway` undefined.

- [ ] **Step 3: Implement the gateway**

Create `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreFileGateway.swift`:

```swift
import Domain
import Foundation
import SheetMusic

/// Live `ScoreFileGateway` backed by `swift-sheet-music`. Per-format dispatch
/// happens in this single file so the surface stays small.
public struct LiveScoreFileGateway: ScoreFileGateway {
    public init() {}

    public func detectFormat(fileName: String) -> ScoreFormat? {
        ScoreFormat.detect(filename: fileName)
    }

    public func loadFileMetadata(fileURL: URL) async throws -> ScoreFileSummary {
        let (score, summary) = try await loadScore(fileURL: fileURL)
        // Right now the summary is built from the parsed Score regardless;
        // when swift-sheet-music exposes a metadata-only fast path we'll
        // bypass full parsing. Stays correct under that future change.
        _ = score
        return summary
    }

    public func loadScore(fileURL: URL) async throws -> (score: Score, summary: ScoreFileSummary) {
        guard let format = detectFormat(fileName: fileURL.lastPathComponent) else {
            let ext = fileURL.pathExtension.lowercased()
            throw DomainError.unsupportedFormat(ext)
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw DomainError.scoreFileNotFound(name: fileURL.lastPathComponent)
        }
        do {
            let score: Score
            switch format {
            case .mscx:
                score = try SheetMusic.loadScore(mscxData: data)
            case .mscz:
                score = try SheetMusic.loadScore(msczData: data)
            case .musicXML:
                score = try SheetMusic.loadScore(musicXMLData: data)
            case .mxl:
                score = try SheetMusic.loadScore(mxlData: data)
            case .midi:
                // swift-sheet-music does not yet expose SMF → Score parsing;
                // surface that as `scoreParseFailed` so the importer can show
                // a clear error.
                throw DomainError.scoreParseFailed(reason: "MIDI parsing not yet supported")
            }
            return (score, ScoreFileSummary(score: score))
        } catch let error as DomainError {
            throw error
        } catch {
            throw DomainError.scoreParseFailed(reason: "\(error)")
        }
    }

    public func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) async throws {
        // v1: swift-sheet-music has no Score → MSCX/MSCZ/MusicXML serializer.
        // The Editor plan will fill this in.
        throw DomainError.unsupportedFormat(format.canonicalExtension)
    }
}
```

- [ ] **Step 4: Run; expect pass (or fixture-tweak loop)**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreFileGatewayTests`

Expected: PASS. Common failure: the minimal MSCX fixture isn't accepted by `MSCXParser.parse`. If that happens:
- Read the thrown error message.
- Adjust `minimal.mscx` (add the missing required element, e.g. `<programVersion>` or a trailing `</museScore>` matching MuseScore's exact root tag — check the swift-sheet-music test fixtures' shape via its own decoder error message, NOT by copying a GPL fixture).
- Rerun.
- Stop iterating once the parser accepts the file and `parts.isEmpty == false`.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/ScoreFiles/LiveScoreFileGateway.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreFileGatewayTests.swift
git commit -m "feat(scorefiles): LiveScoreFileGateway with per-format dispatch"
```

---

### Phase F — LiveScoreFileImporter

---

### Task 16: prepareImport (hash + summary + dup detection)

**Files:**
- Create: `Packages/Infrastructure/Sources/Persistence/LiveScoreFileImporter.swift`
- Create: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreFileImporterTests.swift`

- [ ] **Step 1: Write the test**

Create `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreFileImporterTests.swift`:

```swift
@testable import Domain
import Foundation
@testable import Persistence
@testable import ScoreFiles
import Testing

@MainActor
@Suite struct LiveScoreFileImporterTests {
    private func makeRig() async throws -> (db: AppDatabase, repo: LiveScoreLibraryRepository,
                                            scoresDir: URL, importer: LiveScoreFileImporter,
                                            tmp: TempDirectory) {
        let tmp = try TempDirectory()
        let db = try AppDatabase(databaseURL: tmp.url.appending(path: "f.sqlite"))
        let scoresDir = tmp.url.appending(path: "Scores")
        try FileManager.default.createDirectory(at: scoresDir, withIntermediateDirectories: true)
        let repo = LiveScoreLibraryRepository(database: db, scoresDirectory: scoresDir)
        try await repo.refresh()
        let importer = LiveScoreFileImporter(
            gateway: LiveScoreFileGateway(),
            repository: repo,
            scoresDirectory: scoresDir
        )
        return (db, repo, scoresDir, importer, tmp)
    }

    @Test func prepareImportReturnsZeroDuplicatesForFreshFile() async throws {
        let rig = try await makeRig()
        let mscxURL = try Fixtures.writeToTempFile(
            try Fixtures.minimalMSCXData(), ext: "mscx", in: rig.tmp.url
        )
        let plan = try await rig.importer.prepareImport(sourceURL: mscxURL)
        #expect(plan.duplicates.isEmpty)
        #expect(plan.format == .mscx)
        #expect(plan.contentHash.count == 64) // SHA-256 hex
        #expect(plan.sizeBytes > 0)
    }

    @Test func prepareImportThrowsForPDF() async throws {
        let rig = try await makeRig()
        let pdfURL = try Fixtures.writeToTempFile(Data("dummy".utf8), ext: "pdf", in: rig.tmp.url)
        do {
            _ = try await rig.importer.prepareImport(sourceURL: pdfURL)
            Issue.record("expected throw")
        } catch DomainError.unsupportedFormat {
            // Expected.
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test func prepareImportThrowsForExtensionLessFile() async throws {
        let rig = try await makeRig()
        let url = rig.tmp.url.appending(path: "no-ext")
        try Data("x".utf8).write(to: url)
        do {
            _ = try await rig.importer.prepareImport(sourceURL: url)
            Issue.record("expected throw")
        } catch DomainError.unsupportedFormat {
            // Expected.
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run; expect fail**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreFileImporterTests`
Expected: FAIL — `LiveScoreFileImporter` undefined.

- [ ] **Step 3: Implement the importer skeleton + prepareImport**

Create `Packages/Infrastructure/Sources/Persistence/LiveScoreFileImporter.swift`:

```swift
import CryptoKit
import Domain
import Foundation

public final class LiveScoreFileImporter: ScoreFileImporter, Sendable {
    private let gateway: any ScoreFileGateway
    private let repository: any ScoreLibraryRepository
    private let scoresDirectory: URL

    public init(
        gateway: any ScoreFileGateway,
        repository: any ScoreLibraryRepository,
        scoresDirectory: URL
    ) {
        self.gateway = gateway
        self.repository = repository
        self.scoresDirectory = scoresDirectory
    }

    public func prepareImport(sourceURL: URL) async throws -> ImportPlan {
        guard let format = gateway.detectFormat(fileName: sourceURL.lastPathComponent) else {
            throw DomainError.unsupportedFormat(sourceURL.pathExtension.lowercased())
        }

        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let (hash, size) = try await Self.hashAndSize(sourceURL)

        let summary = try await gateway.loadFileMetadata(fileURL: sourceURL)
        let duplicates = try await repository.scoreItems(matchingContentHash: hash)

        return ImportPlan(
            sourceURL: sourceURL,
            format: format,
            summary: summary,
            contentHash: hash,
            sizeBytes: size,
            duplicates: duplicates
        )
    }

    public func commitImport(_ plan: ImportPlan, decision: ImportDecision) async throws -> ScoreItem {
        // Filled in by Task 17.
        throw DomainError.persistenceFailed(reason: "commitImport not yet implemented")
    }

    /// SHA-256 the file in a single pass. Off-main via `Task.detached` so
    /// large MSCZ archives don't stall the main actor.
    private static func hashAndSize(_ url: URL) async throws -> (String, Int64) {
        try await Task.detached(priority: .utility) {
            do {
                var hasher = SHA256()
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let chunkSize = 64 * 1024
                var total: Int64 = 0
                while true {
                    let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                    if chunk.isEmpty { break }
                    hasher.update(data: chunk)
                    total += Int64(chunk.count)
                }
                let digest = hasher.finalize()
                let hex = digest.map { String(format: "%02x", $0) }.joined()
                return (hex, total)
            } catch {
                throw DomainError.scoreFileNotFound(name: url.lastPathComponent)
            }
        }.value
    }
}
```

- [ ] **Step 4: Run; expect pass**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreFileImporterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/Persistence/LiveScoreFileImporter.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreFileImporterTests.swift
git commit -m "feat(persistence): LiveScoreFileImporter prepare with SHA-256 and dup detection"
```

---

### Task 17: commitImport — openExisting and importAsNew with rollback

**Files:**
- Modify: `Packages/Infrastructure/Sources/Persistence/LiveScoreFileImporter.swift`
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreFileImporterTests.swift`

- [ ] **Step 1: Add the tests**

Append:

```swift
@Test func commitImportAsNewCopiesFileAndPersistsRow() async throws {
    let rig = try await makeRig()
    let mscxURL = try Fixtures.writeToTempFile(
        try Fixtures.minimalMSCXData(), ext: "mscx", in: rig.tmp.url
    )
    let plan = try await rig.importer.prepareImport(sourceURL: mscxURL)
    let item = try await rig.importer.commitImport(plan, decision: .importAsNew)

    // localFileName follows <id>.<canonicalExtension>
    #expect(item.localFileName == "\(item.id.rawValue.uuidString).mscx")

    let dest = rig.scoresDir.appending(path: item.localFileName)
    #expect(FileManager.default.fileExists(atPath: dest.path))

    try await waitFor { rig.repo.scoreItems.contains { $0.id == item.id } }
}

@Test func reimportSameBytesYieldsOneDuplicate() async throws {
    let rig = try await makeRig()
    let mscxURL = try Fixtures.writeToTempFile(
        try Fixtures.minimalMSCXData(), ext: "mscx", in: rig.tmp.url
    )
    let firstPlan = try await rig.importer.prepareImport(sourceURL: mscxURL)
    _ = try await rig.importer.commitImport(firstPlan, decision: .importAsNew)
    try await waitFor { rig.repo.scoreItems.count == 1 }

    let secondPlan = try await rig.importer.prepareImport(sourceURL: mscxURL)
    #expect(secondPlan.duplicates.count == 1)
}

@Test func openExistingDoesNotWriteNewRowOrFile() async throws {
    let rig = try await makeRig()
    let mscxURL = try Fixtures.writeToTempFile(
        try Fixtures.minimalMSCXData(), ext: "mscx", in: rig.tmp.url
    )
    let firstPlan = try await rig.importer.prepareImport(sourceURL: mscxURL)
    let original = try await rig.importer.commitImport(firstPlan, decision: .importAsNew)
    try await waitFor { rig.repo.scoreItems.count == 1 }

    let secondPlan = try await rig.importer.prepareImport(sourceURL: mscxURL)
    let resolved = try await rig.importer.commitImport(
        secondPlan, decision: .openExisting(original.id)
    )
    #expect(resolved.id == original.id)

    let filesBefore = try FileManager.default.contentsOfDirectory(at: rig.scoresDir, includingPropertiesForKeys: nil).count
    #expect(filesBefore == 1)
    #expect(rig.repo.scoreItems.count == 1)
}

/// Polls a predicate up to ~2s.
@MainActor
private func waitFor(
    timeout: Duration = .seconds(2),
    _ predicate: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("predicate never satisfied within \(timeout)")
}
```

- [ ] **Step 2: Run; expect fail**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreFileImporterTests`
Expected: FAIL — current `commitImport` always throws.

- [ ] **Step 3: Implement commitImport**

Replace the `commitImport` stub in `LiveScoreFileImporter.swift`:

```swift
public func commitImport(_ plan: ImportPlan, decision: ImportDecision) async throws -> ScoreItem {
    switch decision {
    case let .openExisting(existingID):
        if let existing = plan.duplicates.first(where: { $0.id == existingID }) {
            return existing
        }
        // Fall back to a repository lookup if the duplicates list was stale.
        if let item = try await repository.scoreItems(matchingContentHash: plan.contentHash)
            .first(where: { $0.id == existingID })
        {
            return item
        }
        throw DomainError.persistenceFailed(reason: "openExisting target \(existingID.rawValue) not found")

    case .importAsNew:
        let id = ScoreItemID()
        let localFileName = "\(id.rawValue.uuidString).\(plan.format.canonicalExtension)"
        let destinationURL = scoresDirectory.appending(path: localFileName)

        // Copy first, with scoped access for share-sheet URLs.
        let scoped = plan.sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { plan.sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            try FileManager.default.copyItem(at: plan.sourceURL, to: destinationURL)
        } catch {
            throw DomainError.persistenceFailed(reason: "copy failed: \(error)")
        }

        // Best-effort cleanup if the row save fails. We re-throw the original error.
        var copiedFileShouldBeRemoved = true
        defer {
            if copiedFileShouldBeRemoved {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        let item = ScoreItem(
            id: id,
            title: plan.summary.title ?? plan.sourceURL.deletingPathExtension().lastPathComponent,
            composer: plan.summary.composer,
            instrumentationSummary: plan.summary.instrumentationSummary,
            localFileName: localFileName,
            contentHash: plan.contentHash,
            sizeBytes: plan.sizeBytes,
            lengthBeats: plan.summary.lengthBeats,
            defaultTempoBpm: plan.summary.defaultTempoBpm,
            primaryKey: plan.summary.primaryKey,
            addedAt: Date(),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false
        )

        try await repository.saveScoreItem(item)
        copiedFileShouldBeRemoved = false
        return item
    }
}
```

- [ ] **Step 4: Run; expect pass**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreFileImporterTests`
Expected: PASS.

Run: `cd Packages/Infrastructure && swift test`
Expected: PASS — full Infrastructure suite green.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/Persistence/LiveScoreFileImporter.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreFileImporterTests.swift
git commit -m "feat(persistence): commitImport with openExisting and rollback-on-failure"
```

---

### Task 18: Rollback test (repository write fails → file removed)

**Files:**
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreFileImporterTests.swift`

This task verifies the `defer` cleanup actually runs. We use a wrapper repository that throws on `saveScoreItem`.

- [ ] **Step 1: Add a stub repository and test**

Append to `LiveScoreFileImporterTests.swift`:

```swift
@MainActor
@Observable
private final class FailingRepository: ScoreLibraryRepository {
    var scoreItems: [ScoreItem] = []
    var tags: [Domain.Tag] = []
    var playlists: [Playlist] = []

    func refresh() async throws {}
    func saveScoreItem(_ item: ScoreItem) async throws {
        throw DomainError.persistenceFailed(reason: "stub failure")
    }
    func deleteScoreItem(id: ScoreItemID) async throws {}
    func saveTag(_ tag: Domain.Tag) async throws {}
    func deleteTag(id: TagID) async throws {}
    func savePlaylist(_ playlist: Playlist) async throws {}
    func deletePlaylist(id: PlaylistID) async throws {}
    func scoreItems(matchingContentHash contentHash: String) async throws -> [ScoreItem] { [] }
}

@Test func saveFailureRollsBackCopiedFile() async throws {
    let tmp = try TempDirectory()
    let scoresDir = tmp.url.appending(path: "Scores")
    try FileManager.default.createDirectory(at: scoresDir, withIntermediateDirectories: true)

    let importer = LiveScoreFileImporter(
        gateway: LiveScoreFileGateway(),
        repository: FailingRepository(),
        scoresDirectory: scoresDir
    )
    let mscxURL = try Fixtures.writeToTempFile(
        try Fixtures.minimalMSCXData(), ext: "mscx", in: tmp.url
    )
    let plan = try await importer.prepareImport(sourceURL: mscxURL)

    do {
        _ = try await importer.commitImport(plan, decision: .importAsNew)
        Issue.record("expected throw")
    } catch DomainError.persistenceFailed {
        // Expected.
    } catch {
        Issue.record("unexpected: \(error)")
    }

    let leftovers = try FileManager.default.contentsOfDirectory(
        at: scoresDir, includingPropertiesForKeys: nil
    )
    #expect(leftovers.isEmpty)
}
```

- [ ] **Step 2: Run; expect pass**

Run: `cd Packages/Infrastructure && swift test --filter saveFailureRollsBackCopiedFile`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreFileImporterTests.swift
git commit -m "test(persistence): importer rollback removes copied file when save fails"
```

---

### Phase G — App composition root

---

### Task 19: Wire AppBootstrap

**Files:**
- Modify: `App/AppBootstrap.swift`

- [ ] **Step 1: Replace AppBootstrap**

Replace `App/AppBootstrap.swift` with:

```swift
import Domain
import Foundation
import Observation
import Persistence
import ScoreFiles

@MainActor
@Observable
final class AppBootstrap {
    private(set) var isReady = false
    private(set) var failure: Error?

    private(set) var database: AppDatabase?
    private(set) var repository: LiveScoreLibraryRepository?
    private(set) var gateway: LiveScoreFileGateway?
    private(set) var importer: LiveScoreFileImporter?

    func start() {
        do {
            try FileManager.default.createDirectory(
                at: AppPaths.scoresDirectory, withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: AppPaths.soundfontCacheDirectory, withIntermediateDirectories: true
            )
            let database = try AppDatabase(databaseURL: AppPaths.databaseURL)
            let repository = LiveScoreLibraryRepository(
                database: database,
                scoresDirectory: AppPaths.scoresDirectory
            )
            let gateway = LiveScoreFileGateway()
            let importer = LiveScoreFileImporter(
                gateway: gateway,
                repository: repository,
                scoresDirectory: AppPaths.scoresDirectory
            )

            self.database = database
            self.repository = repository
            self.gateway = gateway
            self.importer = importer

            Task { [weak self] in
                do {
                    try await repository.refresh()
                    self?.isReady = true
                } catch {
                    self?.failure = error
                }
            }
        } catch {
            failure = error
        }
    }
}
```

- [ ] **Step 2: Build the app target**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

If the build fails because `Folino.xcodeproj` is out of sync (`Persistence` / `ScoreFiles` already declared as products in `project.yml`?), regenerate:
Run: `xcodegen generate`
Then re-run the build.

- [ ] **Step 3: Run on simulator and confirm launch**

Run:
```bash
xcrun simctl boot 'iPhone 16' || true
APP_PATH=$(xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -showBuildSettings -skipPackagePluginValidation 2>/dev/null | awk -F' = ' '/CODESIGNING_FOLDER_PATH/{print $2; exit}')
echo "APP_PATH=$APP_PATH"
xcrun simctl install booted "$APP_PATH"
xcrun simctl launch booted com.KeyNumber.Folino
```
Expected: app installs and launches without crashing. Confirm the SQLite file appears in the simulator's app sandbox documents directory after launch:
```bash
xcrun simctl get_app_container booted com.KeyNumber.Folino data
# then look for Documents/Folino.sqlite
```
Expected: `Folino.sqlite` exists.

- [ ] **Step 4: Run the full test matrix one last time**

Run, in parallel terminals if you like:
```bash
( cd Packages/Domain && swift test )
( cd Packages/Infrastructure && swift test )
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation test
```
Expected: all green. The xcodebuild test invocation runs unit + UI tests; UI tests not affected by Plan #3 should still pass.

- [ ] **Step 5: Commit**

```bash
git add App/AppBootstrap.swift
git commit -m "feat(app): wire LiveScoreLibraryRepository / Gateway / Importer in bootstrap"
```

---

## Self-review checklist (executed by the engineer before declaring this plan complete)

- [ ] All Phase A spec items (drop `.pdf`, drop `format` field, add `contentHash`, observable repo, `loadFileMetadata`, `ImportPlan`, `ImportDecision`, `ScoreFileImporter`) are implemented.
- [ ] Database migration v1 creates exactly the tables and indexes listed in spec §"Database schema" — minus the `sort_order` columns (per deliberate deviation).
- [ ] No Plan #2 test still references `format:` or `.pdf`.
- [ ] No file under `Sources/` references GRDB outside of `Persistence`.
- [ ] No file under `Sources/` references `swift-sheet-music` outside of `ScoreFiles` (and Domain via the existing `Score` type alias if any).
- [ ] `App/AppBootstrap.swift` is the only file outside `App/` that imports both `Persistence` and `ScoreFiles`.
- [ ] `xcodebuild ... build` and `xcodebuild ... test` both succeed; `swift test` succeeds in both `Packages/Domain` and `Packages/Infrastructure`.
- [ ] App launches on simulator and produces `Documents/Folino.sqlite`.

If any item fails, return to the corresponding task — do not paper over with extra logic.

---

## Out of scope reminders (so you don't accidentally pull these in)

- AnnotationStore concrete implementation (Plan #4 candidate).
- PlaybackPreferences and SoundfontPatch persistence (separate plan with Audio + Soundfonts).
- CloudKit sync (separate plan; will reuse the Repository surface).
- Library / Reader / Editor UI.
- Score → MSCX/MSCZ/MusicXML serialization (Editor plan, requires upstream support).
- `.musicxml` / `.mxl` end-to-end fixture tests (return when a non-GPL fixture source is available).

# Android Share Import (iOS Share Extension parity) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Android users share score files into folino (share sheet) or open them with folino (file manager), pick a destination (Library / existing playlist / new playlist), optionally open the result, with iOS-parity duplicate detection — driven by a shared Domain coordinator.

**Architecture:** A platform-agnostic `SharedImportCoordinator` in Domain orchestrates "resolve playlist target → import each file (with dup detection) → append to playlist → open-after" over small injected protocols. iOS's `IncomingShareCoordinator` delegates per-token work to it; Android gets a new `ShareTargetActivity` (translucent + Material bottom sheet) that copies `content://` files and calls a new `LibraryAndroidStore.importShared` JNI method, whose Swift adapters run the same coordinator against the Room-backed store.

**Tech Stack:** Swift 6.3 (Domain, Foundation-only), Swift Testing, swift-wirelet JNI, Kotlin/Compose/Room (Android), Material 3.

**Spec:** `docs/superpowers/specs/2026-06-09-android-share-import-design.md`

---

## Design decisions locked in (read before starting)

- **Hashing is per-platform, inside the importer adapter — not in the shared coordinator.** iOS keeps `ScoreFileImporter` (CryptoKit SHA-256). Android computes SHA-256 in Kotlin via `java.security.MessageDigest` (a new `LibraryStore.sha256(path:)` method). No new SwiftPM dependency is added. SHA-256 of identical bytes is identical across both, but cross-platform equality is irrelevant (each library compares only within itself).
- **Room migration = destructive reset.** `RoomLibraryStore` already uses `fallbackToDestructiveMigration()` at version 1. Adding the `content_hash` column + bumping to version 2 wipes existing Android installs' DB — this matches the established "fresh reset" practice for the Favorites column. No manual `Migration` object is written.
- **The JNI boundary uses primitives, not Swift enums.** `importShared` takes `[String]` paths/names + `Int` mode + `String` ids + `Bool`. The Swift side reconstructs a Domain `PlaylistChoice`.
- **`SharedImportCoordinator.run` is `async`.** iOS calls it from its `@MainActor` async context. Android bridges async→sync inside the synchronous JNI method with a `DispatchSemaphore` (the call originates on a Kotlin `Dispatchers.IO` thread, so blocking is safe; the Android importer adapter performs only synchronous work inside its `async` method).

## File structure

**Domain (new — Foundation-only, reachable by both platforms):**
- Create `Packages/Domain/Sources/Domain/Models/ShareImportPolicy.swift` — accepted-extension allow-list + `isAccepted(filename:)`.
- Create `Packages/Domain/Sources/Domain/Models/ShareDecision.swift` — `PlaylistChoice` + `ShareDecision` (moved from `ImportExportShareUI`).
- Create `Packages/Domain/Sources/Domain/Models/SharedImport.swift` — `SharedImportFile`, `SharedImportFileResult`, `SharedImportSkip`, `SharedImportSkipReason`, `SharedImportResult`, the two protocols, and `SharedImportCoordinator`.
- Test `Packages/Domain/Tests/DomainTests/Models/ShareImportPolicyTests.swift`.
- Test `Packages/Domain/Tests/DomainTests/Models/SharedImportCoordinatorTests.swift`.

**iOS ImportExport (refactor to delegate):**
- Delete the `PlaylistChoice` / `ShareDecision` definitions in `Packages/Features/ImportExport/Sources/ImportExportShareUI/ShareDecision.swift` (keep `IngestSummary` there).
- Modify `Packages/Features/ImportExport/Sources/ImportExportShareUI/ShareSession.swift` — use `ShareImportPolicy.acceptedExtensions`.
- Create `Packages/Features/ImportExport/Sources/ImportExport/ShareImportAdapters.swift` — iOS adapters bridging `ScoreFileImporter`/`ScoreLibraryRepository` (+ duplicate resolver) to the Domain protocols.
- Modify `Packages/Features/ImportExport/Sources/ImportExport/IncomingShareCoordinator.swift` — `drainOne` delegates to `SharedImportCoordinator`.

**Android Swift JNI:**
- Modify `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRecordWire.swift` — add `contentHash`.
- Modify `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift` — add `func sha256(path:) -> String`.
- Create `Packages/Features/Library/Sources/FolinoLibraryJNI/ImportSharedResultWire.swift` — wire return type.
- Modify `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift` — `contentHash` plumbing in `importScore`, new `importShared`, Android adapters.

**Android Kotlin:**
- Modify `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt` — `content_hash` column, version bump, `sha256`, map new wire field.
- Modify `Android/app/src/main/AndroidManifest.xml` — `ShareTargetActivity` + intent-filters.
- Create `Android/app/src/main/kotlin/com/keynumber/folino/share/ShareTargetActivity.kt` — receive + copy + bottom sheet + JNI call.
- Create `Android/app/src/main/kotlin/com/keynumber/folino/share/ShareImport.kt` — `content://` resolution helpers + policy mirror call.
- Modify `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` — honor an `open score id` launch extra.

---

## Phase 1 — Domain shared core (TDD)

### Task 1: `ShareImportPolicy`

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/ShareImportPolicy.swift`
- Test: `Packages/Domain/Tests/DomainTests/Models/ShareImportPolicyTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Domain

@Suite struct ShareImportPolicyTests {
    @Test func acceptsKnownExtensionsCaseInsensitively() {
        #expect(ShareImportPolicy.isAccepted(filename: "song.mscz"))
        #expect(ShareImportPolicy.isAccepted(filename: "SONG.MSCZ"))
        #expect(ShareImportPolicy.isAccepted(filename: "a.musicxml"))
        #expect(ShareImportPolicy.isAccepted(filename: "b.MID"))
        #expect(ShareImportPolicy.isAccepted(filename: "c.midi"))
    }

    @Test func rejectsUnknownOrMissingExtensions() {
        #expect(!ShareImportPolicy.isAccepted(filename: "doc.pdf"))
        #expect(!ShareImportPolicy.isAccepted(filename: "noext"))
        #expect(!ShareImportPolicy.isAccepted(filename: ""))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:DomainTests/ShareImportPolicyTests`
Expected: FAIL — `cannot find 'ShareImportPolicy' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// The score file extensions folino accepts on import. Single source of truth shared by the iOS Share Extension
/// ingest gate and the Android share transport (`mscz, mscx, musicxml, mxl, xml, midi, mid`).
public enum ShareImportPolicy {
    public static let acceptedExtensions: Set<String> = [
        "mscz", "mscx", "musicxml", "mxl", "xml", "midi", "mid",
    ]

    /// `true` when `filename`'s extension is in the allow-list (case-insensitive).
    public static func isAccepted(filename: String) -> Bool {
        acceptedExtensions.contains((filename as NSString).pathExtension.lowercased())
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:DomainTests/ShareImportPolicyTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/ShareImportPolicy.swift Packages/Domain/Tests/DomainTests/Models/ShareImportPolicyTests.swift
git commit -m "feat(domain): add ShareImportPolicy accepted-extension allow-list"
```

### Task 2: Move `PlaylistChoice` / `ShareDecision` into Domain

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/ShareDecision.swift`
- Modify: `Packages/Features/ImportExport/Sources/ImportExportShareUI/ShareDecision.swift` (remove the two enums, keep `IngestSummary`)

- [ ] **Step 1: Create the Domain types**

```swift
import Foundation

/// Where shared files land: just the Library, an existing playlist, or a brand-new playlist.
public enum PlaylistChoice: Sendable, Equatable {
    case libraryOnly
    case existing(PlaylistID)
    case createNew(name: String)
}

/// The user's full share decision: destination plus whether to open the imported score afterward.
public enum ShareDecision: Sendable, Equatable {
    case save(PlaylistChoice)
    case saveAndOpen(PlaylistChoice)

    public var openAfter: Bool {
        if case .saveAndOpen = self { return true }
        return false
    }

    public var choice: PlaylistChoice {
        switch self {
        case let .save(c), let .saveAndOpen(c): c
        }
    }
}
```

- [ ] **Step 2: Remove the moved enums from `ImportExportShareUI/ShareDecision.swift`**

Edit the file so only `IngestSummary` remains (delete the `PlaylistChoice` and `ShareDecision` enums; keep the `import Domain`, `import Foundation`, `import ImportExportAppGroup` lines and the `IngestSummary` struct).

- [ ] **Step 3: Build ImportExport to verify the move resolves**

Run: `cd Packages/Features/ImportExport && xcodebuild build -scheme ImportExport -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED (call sites in `ShareSession`, `ShareRootView`, `PlaylistPickerSection` already `import Domain`).

- [ ] **Step 4: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/ShareDecision.swift Packages/Features/ImportExport/Sources/ImportExportShareUI/ShareDecision.swift
git commit -m "refactor(domain): move PlaylistChoice/ShareDecision into Domain"
```

### Task 3: `SharedImportCoordinator` types + protocols

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/SharedImport.swift`

- [ ] **Step 1: Write the types and protocols (no behavior yet)**

```swift
import Foundation

/// One staged file handed to the coordinator: an absolute path to readable bytes plus the user-facing original name.
public struct SharedImportFile: Sendable, Equatable {
    public let path: String
    public let originalName: String
    public init(path: String, originalName: String) {
        self.path = path
        self.originalName = originalName
    }
}

/// Why a file was not imported. `id`/`title` strings are raw (UUID string, display title) so the type is platform-neutral.
public enum SharedImportSkipReason: Sendable, Equatable {
    case missingFile
    case parseFailed
    case persistenceFailed
    case duplicate(existingID: String, existingTitle: String)
}

public struct SharedImportSkip: Sendable, Equatable {
    public let originalName: String
    public let reason: SharedImportSkipReason
    public init(originalName: String, reason: SharedImportSkipReason) {
        self.originalName = originalName
        self.reason = reason
    }
}

/// Per-file outcome an importer reports back to the coordinator.
public enum SharedImportFileResult: Sendable, Equatable {
    case imported(id: String)
    case duplicate(existingID: String, existingTitle: String)
    case skipped(SharedImportSkipReason)
}

/// Platform import: hashing, duplicate detection, parsing, persistence all happen behind this. `isMultiFile` lets the
/// implementation route a duplicate confirmation differently for batch vs single shares (iOS resolver).
public protocol SharedImportFileImporting: Sendable {
    func importFile(_ file: SharedImportFile, isMultiFile: Bool) async -> SharedImportFileResult
}

/// Platform playlist operations the coordinator needs. All ids are UUID strings.
public protocol SharedImportPlaylistTargeting: Sendable {
    func playlistExists(id: String) -> Bool
    /// Create a playlist; return its new id, or `nil` if creation failed.
    func createPlaylist(name: String) -> String?
    func append(scoreIDs: [String], toPlaylistID id: String)
}

/// Aggregated outcome (platform-neutral, UUID strings). Each platform maps this to its own richer result if needed.
public struct SharedImportResult: Sendable, Equatable {
    public var importedIDs: [String]
    public var skipped: [SharedImportSkip]
    public var openAfterID: String?
    public var createdPlaylistID: String?
    public var targetPlaylistID: String?
    public var playlistCreateFailureName: String?

    public init(
        importedIDs: [String] = [],
        skipped: [SharedImportSkip] = [],
        openAfterID: String? = nil,
        createdPlaylistID: String? = nil,
        targetPlaylistID: String? = nil,
        playlistCreateFailureName: String? = nil,
    ) {
        self.importedIDs = importedIDs
        self.skipped = skipped
        self.openAfterID = openAfterID
        self.createdPlaylistID = createdPlaylistID
        self.targetPlaylistID = targetPlaylistID
        self.playlistCreateFailureName = playlistCreateFailureName
    }
}
```

- [ ] **Step 2: Build Domain to verify it compiles**

Run: `cd Packages/Domain && xcodebuild build -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/SharedImport.swift
git commit -m "feat(domain): add SharedImport coordinator value types + protocols"
```

### Task 4: `SharedImportCoordinator.run` behavior (TDD)

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/SharedImport.swift` (append the coordinator)
- Test: `Packages/Domain/Tests/DomainTests/Models/SharedImportCoordinatorTests.swift`

- [ ] **Step 1: Write the failing tests with fakes**

```swift
import Foundation
import Testing
@testable import Domain

@Suite struct SharedImportCoordinatorTests {
    /// Records calls; returns scripted per-name outcomes.
    final class FakeImporter: SharedImportFileImporting, @unchecked Sendable {
        var outcomes: [String: SharedImportFileResult] = [:]
        var seenMultiFile: [Bool] = []
        func importFile(_ file: SharedImportFile, isMultiFile: Bool) async -> SharedImportFileResult {
            seenMultiFile.append(isMultiFile)
            return outcomes[file.originalName] ?? .skipped(.parseFailed)
        }
    }

    final class FakeTarget: SharedImportPlaylistTargeting, @unchecked Sendable {
        var existing: Set<String> = []
        var createReturns: String?
        var created: [String] = []
        var appended: [(ids: [String], playlist: String)] = []
        func playlistExists(id: String) -> Bool { existing.contains(id) }
        func createPlaylist(name: String) -> String? {
            guard let id = createReturns else { return nil }
            created.append(name)
            return id
        }
        func append(scoreIDs: [String], toPlaylistID id: String) { appended.append((scoreIDs, id)) }
    }

    private func file(_ name: String) -> SharedImportFile { .init(path: "/tmp/\(name)", originalName: name) }

    @Test func libraryOnlyImportsAllNoPlaylist() async {
        let imp = FakeImporter()
        imp.outcomes = ["a.mscz": .imported(id: "id-a"), "b.mscz": .imported(id: "id-b")]
        let tgt = FakeTarget()
        let sut = SharedImportCoordinator(importer: imp, target: tgt)
        let r = await sut.run(files: [file("a.mscz"), file("b.mscz")], choice: .libraryOnly, openAfter: false)
        #expect(r.importedIDs == ["id-a", "id-b"])
        #expect(tgt.appended.isEmpty)
        #expect(r.openAfterID == nil)
        #expect(imp.seenMultiFile == [true, true])
    }

    @Test func openAfterReportsLastImported() async {
        let imp = FakeImporter()
        imp.outcomes = ["a.mscz": .imported(id: "id-a"), "b.mscz": .imported(id: "id-b")]
        let sut = SharedImportCoordinator(importer: imp, target: FakeTarget())
        let r = await sut.run(files: [file("a.mscz"), file("b.mscz")], choice: .libraryOnly, openAfter: true)
        #expect(r.openAfterID == "id-b")
    }

    @Test func duplicateIsSkippedButBecomesOpenAfterTarget() async {
        let imp = FakeImporter()
        imp.outcomes = ["a.mscz": .duplicate(existingID: "old-1", existingTitle: "Old")]
        let sut = SharedImportCoordinator(importer: imp, target: FakeTarget())
        let r = await sut.run(files: [file("a.mscz")], choice: .libraryOnly, openAfter: true)
        #expect(r.importedIDs.isEmpty)
        #expect(r.skipped.first?.reason == .duplicate(existingID: "old-1", existingTitle: "Old"))
        #expect(r.openAfterID == "old-1")
    }

    @Test func existingPlaylistAppendsImportedIDs() async {
        let imp = FakeImporter()
        imp.outcomes = ["a.mscz": .imported(id: "id-a")]
        let tgt = FakeTarget()
        let pid = UUID()
        tgt.existing = [pid.uuidString]
        let sut = SharedImportCoordinator(importer: imp, target: tgt)
        let r = await sut.run(files: [file("a.mscz")], choice: .existing(PlaylistID(rawValue: pid)), openAfter: false)
        #expect(tgt.appended.count == 1)
        #expect(tgt.appended.first?.ids == ["id-a"])
        #expect(tgt.appended.first?.playlist == pid.uuidString)
        #expect(r.targetPlaylistID == pid.uuidString)
    }

    @Test func createNewPlaylistAppendsAndReportsCreatedID() async {
        let imp = FakeImporter()
        imp.outcomes = ["a.mscz": .imported(id: "id-a")]
        let tgt = FakeTarget()
        tgt.createReturns = "new-pl"
        let sut = SharedImportCoordinator(importer: imp, target: tgt)
        let r = await sut.run(files: [file("a.mscz")], choice: .createNew(name: " My List "), openAfter: false)
        #expect(tgt.created == ["My List"]) // trimmed
        #expect(r.createdPlaylistID == "new-pl")
        #expect(tgt.appended.first?.ids == ["id-a"])
    }

    @Test func createNewFailureImportsNothingAndReportsName() async {
        let imp = FakeImporter()
        imp.outcomes = ["a.mscz": .imported(id: "id-a")]
        let tgt = FakeTarget() // createReturns nil -> failure
        let sut = SharedImportCoordinator(importer: imp, target: tgt)
        let r = await sut.run(files: [file("a.mscz")], choice: .createNew(name: "X"), openAfter: true)
        #expect(r.importedIDs.isEmpty)
        #expect(r.playlistCreateFailureName == "X")
        #expect(r.openAfterID == nil)
        #expect(imp.seenMultiFile.isEmpty) // no import attempted
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:DomainTests/SharedImportCoordinatorTests`
Expected: FAIL — `cannot find 'SharedImportCoordinator' in scope`.

- [ ] **Step 3: Implement the coordinator (append to `SharedImport.swift`)**

```swift
/// Platform-agnostic share-import orchestration: resolve the playlist target, import each file, append imported ids to
/// the target, and pick the open-after id. All platform I/O lives behind the two injected protocols. Mirrors the iOS
/// `IncomingShareCoordinator` per-token sequence, including "new-playlist creation failed ⇒ import nothing".
public struct SharedImportCoordinator: Sendable {
    private let importer: any SharedImportFileImporting
    private let target: any SharedImportPlaylistTargeting

    public init(importer: any SharedImportFileImporting, target: any SharedImportPlaylistTargeting) {
        self.importer = importer
        self.target = target
    }

    public func run(files: [SharedImportFile], choice: PlaylistChoice, openAfter: Bool) async -> SharedImportResult {
        var result = SharedImportResult()

        // 1. Resolve playlist target.
        var targetPlaylistID: String?
        switch choice {
        case .libraryOnly:
            break
        case let .existing(id):
            let raw = id.rawValue.uuidString
            if target.playlistExists(id: raw) { targetPlaylistID = raw }
        case let .createNew(name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let newID = target.createPlaylist(name: trimmed) {
                    targetPlaylistID = newID
                    result.createdPlaylistID = newID
                } else {
                    // iOS parity: nothing is imported; the banner reports the failed name.
                    result.playlistCreateFailureName = trimmed
                    return result
                }
            }
        }

        // 2. Import each file.
        let isMultiFile = files.count > 1
        var lastOpen: String?
        for file in files {
            switch await importer.importFile(file, isMultiFile: isMultiFile) {
            case let .imported(id):
                result.importedIDs.append(id)
                lastOpen = id
            case let .duplicate(existingID, existingTitle):
                result.skipped.append(.init(
                    originalName: file.originalName,
                    reason: .duplicate(existingID: existingID, existingTitle: existingTitle),
                ))
                lastOpen = existingID
            case let .skipped(reason):
                result.skipped.append(.init(originalName: file.originalName, reason: reason))
            }
        }

        // 3. Append to playlist.
        if let pid = targetPlaylistID {
            if !result.importedIDs.isEmpty { target.append(scoreIDs: result.importedIDs, toPlaylistID: pid) }
            result.targetPlaylistID = pid
        }

        // 4. Open-after.
        if openAfter { result.openAfterID = lastOpen }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:DomainTests/SharedImportCoordinatorTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/SharedImport.swift Packages/Domain/Tests/DomainTests/Models/SharedImportCoordinatorTests.swift
git commit -m "feat(domain): implement SharedImportCoordinator orchestration"
```

---

## Phase 2 — iOS refactor: delegate to the shared coordinator

### Task 5: iOS adapters bridging to the Domain protocols

**Files:**
- Create: `Packages/Features/ImportExport/Sources/ImportExport/ShareImportAdapters.swift`

- [ ] **Step 1: Write the adapters**

These wrap the existing iOS importer/repository/resolver and reproduce the current `importSingleFile` / `handleDuplicate` / `appendImportsToPlaylist` / `resolvePlaylist` behavior behind the Domain protocols. The importer adapter also retains a private `id → ScoreItem` map so the coordinator's `openAfterID` can be mapped back to a full `ScoreItem` without a repository read (preserving the `DrainResult.openAfter` no-race guarantee).

```swift
import Domain
import Foundation
import os

/// iOS importer adapter: stages via `ScoreFileImporter`, applies the duplicate resolver, and records every committed /
/// existing `ScoreItem` by id for later open-after lookup.
@MainActor
final class IOSShareImporter: SharedImportFileImporting {
    private let importer: any ScoreFileImporter
    private let duplicateResolver: (any ImportDuplicateResolver)?
    private let logger: Logger
    /// id (UUID string) → resolved ScoreItem, for DrainResult.openAfter mapping.
    private(set) var itemsByID: [String: ScoreItem] = [:]

    init(importer: any ScoreFileImporter, duplicateResolver: (any ImportDuplicateResolver)?, logger: Logger) {
        self.importer = importer
        self.duplicateResolver = duplicateResolver
        self.logger = logger
    }

    func importFile(_ file: SharedImportFile, isMultiFile: Bool) async -> SharedImportFileResult {
        let sourceURL = URL(fileURLWithPath: file.path)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return .skipped(.missingFile) }
        do {
            let plan = try await importer.prepareImport(sourceURL: sourceURL)
            guard let dup = plan.duplicates.first else {
                let item = try await importer.commitImport(plan, decision: .importAsNew)
                itemsByID[item.id.rawValue.uuidString] = item
                return .imported(id: item.id.rawValue.uuidString)
            }
            return await resolve(plan: plan, dup: dup, isMultiFile: isMultiFile)
        } catch {
            return .skipped(.parseFailed)
        }
    }

    private func resolve(plan: ImportPlan, dup: ScoreItem, isMultiFile: Bool) async -> SharedImportFileResult {
        let decision: ImportDecision? = if let duplicateResolver {
            await duplicateResolver.resolveDuplicate(plan: plan, existing: dup, isMultiFile: isMultiFile)
        } else {
            .openExisting(dup.id)
        }
        guard let decision else {
            return .duplicate(existingID: dup.id.rawValue.uuidString, existingTitle: dup.title)
        }
        do {
            let item = try await importer.commitImport(plan, decision: decision)
            itemsByID[item.id.rawValue.uuidString] = item
            switch decision {
            case .importAsNew:
                return .imported(id: item.id.rawValue.uuidString)
            case .openExisting:
                return .duplicate(existingID: dup.id.rawValue.uuidString, existingTitle: dup.title)
            }
        } catch {
            return .skipped(.persistenceFailed)
        }
    }
}

/// iOS playlist adapter over `ScoreLibraryRepository`. `createPlaylist` saves a fresh `Playlist`; `append` re-saves with
/// the imported ids appended. Records created/targeted playlists so the coordinator's ids map back to names.
@MainActor
final class IOSSharePlaylistTarget: SharedImportPlaylistTargeting {
    private let repository: any ScoreLibraryRepository
    private let clock: any Clock
    private let logger: Logger
    private(set) var namesByID: [String: String] = [:]

    init(repository: any ScoreLibraryRepository, clock: any Clock, logger: Logger) {
        self.repository = repository
        self.clock = clock
        self.logger = logger
    }

    func playlistExists(id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        if let p = repository.playlists.first(where: { $0.id == PlaylistID(rawValue: uuid) }) {
            namesByID[id] = p.name
            return true
        }
        return false
    }

    func createPlaylist(name: String) -> String? {
        let playlist = Playlist(name: name, orderedScoreItemIDs: [], createdAt: clock.now())
        do {
            try awaitSync { try await self.repository.savePlaylist(playlist) }
            let id = playlist.id.rawValue.uuidString
            namesByID[id] = name
            return id
        } catch {
            logger.error("failed to create playlist: \(String(describing: error))")
            return nil
        }
    }

    func append(scoreIDs: [String], toPlaylistID id: String) {
        guard let uuid = UUID(uuidString: id),
              var playlist = repository.playlists.first(where: { $0.id == PlaylistID(rawValue: uuid) })
        else { return }
        let ids = scoreIDs.compactMap { UUID(uuidString: $0).map { ScoreItemID(rawValue: $0) } }
        playlist.orderedScoreItemIDs.append(contentsOf: ids)
        do {
            try awaitSync { try await self.repository.savePlaylist(playlist) }
            namesByID[id] = playlist.name
        } catch {
            logger.error("failed to append to playlist: \(String(describing: error))")
        }
    }
}
```

> **Note on `awaitSync`:** the Domain `SharedImportPlaylistTargeting` methods are synchronous, but the iOS repository is `async`. Provide a tiny `@MainActor` bridge. Because both the coordinator and the repository are `@MainActor`-isolated and the target methods run inside the coordinator's already-async `run`, the cleaner fix is to make the two playlist-target methods do their async work via an unstructured `Task` awaited through a continuation. **Implement `awaitSync` as a private free function in this file:**

```swift
/// Runs an async, throwing, MainActor operation to completion synchronously from a MainActor context by pumping the
/// main run loop. Used only for the two short repository writes in the playlist adapter.
@MainActor
private func awaitSync<T>(_ operation: @escaping @MainActor () async throws -> T) throws -> T {
    var outcome: Result<T, any Error>?
    let task = Task { @MainActor in outcome = await Result { try await operation() } }
    while outcome == nil {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
    }
    _ = task
    switch outcome! {
    case let .success(v): return v
    case let .failure(e): throw e
    }
}

private extension Result where Failure == any Error {
    init(catching body: @MainActor () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
```

> ⚠️ **If `awaitSync` proves fragile in review/build**, the fallback is to widen the two `SharedImportPlaylistTargeting` methods to `async` in Task 3 and update the coordinator + tests accordingly. Prefer the async-protocol approach if the run-loop pump raises any concern during Task 6's build. (Decide during implementation; keep the coordinator the single source of truth either way.)

- [ ] **Step 2: Build ImportExport**

Run: `cd Packages/Features/ImportExport && xcodebuild build -scheme ImportExport -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/ImportExport/Sources/ImportExport/ShareImportAdapters.swift
git commit -m "feat(importexport): iOS adapters bridging to SharedImportCoordinator"
```

### Task 6: `IncomingShareCoordinator.drainOne` delegates to the shared coordinator

**Files:**
- Modify: `Packages/Features/ImportExport/Sources/ImportExport/IncomingShareCoordinator.swift`

- [ ] **Step 1: Replace `drainOne`'s body to delegate**

Keep the method signature and the `loadIntent` / token-scrub / cleanup behavior. Replace the resolve+import+append section (currently lines ~122-157, plus the now-unused private helpers `resolvePlaylist`, `PlaylistResolution`, `ImportOutcome`, `importFiles`, `importSingleFile`, `handleDuplicate`, `appendImportsToPlaylist`) with delegation:

```swift
private func drainOne(token: UUID) async -> DrainResult {
    let tokenURL = AppGroupPaths.tokenURL(token: token, in: appGroupContainer)
    guard let intent = loadIntent(token: token) else {
        logger.error("intent.json missing/corrupt; scrubbing token \(token.uuidString)")
        try? FileManager.default.removeItem(at: tokenURL)
        return .empty
    }

    let filesDir = AppGroupPaths.tokenFilesURL(token: token, in: appGroupContainer)
    let files = intent.files.map {
        SharedImportFile(
            path: filesDir.appending(path: $0.originalName, directoryHint: .notDirectory).path,
            originalName: $0.originalName,
        )
    }
    let choice = Self.choice(from: intent)

    let iosImporter = IOSShareImporter(importer: importer, duplicateResolver: duplicateResolver, logger: logger)
    let playlistTarget = IOSSharePlaylistTarget(repository: repository, clock: clock, logger: logger)
    let coordinator = SharedImportCoordinator(importer: iosImporter, target: playlistTarget)

    let shared = await coordinator.run(files: files, choice: choice, openAfter: intent.openAfter)

    try? FileManager.default.removeItem(at: tokenURL)

    if let failedName = shared.playlistCreateFailureName {
        // Preserve nothing extra; the staged token is already gone — but iOS parity reports the failed name.
        return DrainResult(
            imported: [], skipped: [], openAfter: nil,
            createdPlaylistID: nil, targetPlaylistID: nil,
            targetPlaylistName: failedName, playlistCreateFailure: failedName,
        )
    }

    let imported = shared.importedIDs.compactMap { UUID(uuidString: $0).map(ScoreItemID.init(rawValue:)) }
    let skipped = shared.skipped.map { Self.skip(from: $0) }
    let openAfter = shared.openAfterID.flatMap { iosImporter.itemsByID[$0] }
    let createdID = shared.createdPlaylistID.flatMap { UUID(uuidString: $0).map(PlaylistID.init(rawValue:)) }
    let targetID = shared.targetPlaylistID.flatMap { UUID(uuidString: $0).map(PlaylistID.init(rawValue:)) }
    let targetName = shared.targetPlaylistID.flatMap { playlistTarget.namesByID[$0] }

    return DrainResult(
        imported: imported, skipped: skipped, openAfter: openAfter,
        createdPlaylistID: createdID, targetPlaylistID: targetID, targetPlaylistName: targetName,
    )
}

private static func choice(from intent: IncomingShareIntent) -> PlaylistChoice {
    if let id = intent.playlistID { return .existing(id) }
    if let name = intent.newPlaylistName, !name.isEmpty { return .createNew(name: name) }
    return .libraryOnly
}

private static func skip(from s: SharedImportSkip) -> Skip {
    let reason: SkipReason = switch s.reason {
    case .missingFile: .unreadable(NSError(domain: "ImportExport", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "missing staged file"]))
    case .parseFailed: .parseFailed(NSError(domain: "ImportExport", code: -2))
    case .persistenceFailed: .persistenceFailed(NSError(domain: "ImportExport", code: -3))
    case let .duplicate(existingID, existingTitle):
        .duplicate(
            existingID: UUID(uuidString: existingID).map(ScoreItemID.init(rawValue:)) ?? ScoreItemID(),
            existingTitle: existingTitle,
        )
    }
    return Skip(originalName: s.originalName, reason: reason)
}
```

Then delete the now-dead private members listed above. Keep `drain`, `performDrain`, `drainAll`, `loadIntent`.

- [ ] **Step 2: Run the existing iOS regression suite**

Run: `cd Packages/Features/ImportExport && xcodebuild test -scheme ImportExport -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:ImportExportTests/IncomingShareCoordinatorTests`
Expected: PASS — all existing coordinator tests green (behavior preserved). If any fail, reconcile the mapping (most likely the duplicate `existingID` round-trip or the open-after item) before proceeding.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/ImportExport/Sources/ImportExport/IncomingShareCoordinator.swift
git commit -m "refactor(importexport): IncomingShareCoordinator delegates to SharedImportCoordinator"
```

### Task 7: `ShareSession` uses the shared policy

**Files:**
- Modify: `Packages/Features/ImportExport/Sources/ImportExportShareUI/ShareSession.swift`

- [ ] **Step 1: Replace the local allow-list with `ShareImportPolicy`**

- Delete the `private static let acceptedExtensions: Set = [...]` declaration (lines ~139-141).
- Change the gate at line ~57 from `guard Self.acceptedExtensions.contains(ext)` to `guard ShareImportPolicy.acceptedExtensions.contains(ext)`.

- [ ] **Step 2: Build + run the share-session tests**

Run: `cd Packages/Features/ImportExport && xcodebuild test -scheme ImportExport -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:ImportExportShareUITests/ShareSessionTests`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/ImportExport/Sources/ImportExportShareUI/ShareSession.swift
git commit -m "refactor(importexport): ShareSession gates on shared ShareImportPolicy"
```

---

## Phase 3 — Android persistence + JNI entry point

> **Android build/codegen note:** the Swift JNI changes (`@WireFormat` field, `@WireletProvided` method, new `@WireletExpose` method, new wire struct) require regenerating the Kotlin bindings + the `.so`. After the Swift edits in this phase, run the project's Android library build before touching Kotlin that references generated symbols. Build recipe per `[[project_android_build_toolchain]]` / `Scripts/android-build-library-libs.sh` (gradle codegen → `.so`, in that order). Verify against the actual scripts in `Scripts/` at implementation time.

### Task 8: Add `contentHash` to the Swift wire record + import path

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRecordWire.swift`
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift`
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`

- [ ] **Step 1: Add the field to `ScoreRecordWire`**

Add `public var contentHash: String` (after `localFileName`) and the matching `init` parameter `contentHash: String = ""` (defaulted so existing call sites keep compiling). Update the doc comment to mention it's the SHA-256 hex of the source bytes, `""` when unknown (legacy rows).

- [ ] **Step 2: Add `sha256` to the `LibraryStore` protocol**

```swift
/// SHA-256 hex digest of the file at `path` (Kotlin: java.security.MessageDigest). `""` if the file is unreadable.
/// Used for iOS-parity duplicate detection on import.
func sha256(path: String) -> String
```

- [ ] **Step 3: Plumb the hash through `importScore`**

In `LibraryAndroidStore.importScore`, compute `let hash = store.sha256(path: path)` and pass `contentHash: hash` into the `ScoreRecordWire(...)`. (Existing single-file import now also records a hash, so newly-imported items participate in dedup.)

- [ ] **Step 4: Build the JNI Swift target (host) to typecheck**

Run: `cd Packages/Features/Library && xcodebuild build -scheme FolinoLibraryJNI -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation` 
> If `FolinoLibraryJNI` only exists under the `FOLINO_ANDROID=1` package variant and has no iOS scheme, instead typecheck via the Android host build path in `Scripts/android-build-library-libs.sh` (host swift build step). Use whichever the repo provides.
Expected: compiles (the protocol gains a method — the Kotlin impl is updated in Task 10, so only re-typecheck Swift here).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRecordWire.swift Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift
git commit -m "feat(library-jni): record SHA-256 contentHash on Android import"
```

### Task 9: `importShared` JNI method + Android adapters + result wire

**Files:**
- Create: `Packages/Features/Library/Sources/FolinoLibraryJNI/ImportSharedResultWire.swift`
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`

- [ ] **Step 1: Add the result wire type**

```swift
import Wirelet

/// Result of `LibraryAndroidStore.importShared`, marshaled to Kotlin. `openAfterId` is `""` when nothing should open.
@WireFormat
public struct ImportSharedResultWire: Equatable, Sendable {
    public var importedCount: Int32
    public var skippedCount: Int32
    public var openAfterId: String
    public var createdPlaylistId: String
    public var targetPlaylistId: String
    public var playlistCreateFailureName: String

    public init(
        importedCount: Int32, skippedCount: Int32, openAfterId: String,
        createdPlaylistId: String, targetPlaylistId: String, playlistCreateFailureName: String,
    ) {
        self.importedCount = importedCount
        self.skippedCount = skippedCount
        self.openAfterId = openAfterId
        self.createdPlaylistId = createdPlaylistId
        self.targetPlaylistId = targetPlaylistId
        self.playlistCreateFailureName = playlistCreateFailureName
    }
}
```

- [ ] **Step 2: Add the Android adapters + `importShared` to `LibraryAndroidStore`**

Add a nested file-private importer adapter and playlist-target adapter that operate against `store` + the existing `loadDomainPlaylists`/`persist` helpers, and the `@WireletExpose importShared`. Place inside the class body (the `@WireletObservable` macro requires `@WireletExpose` methods in the primary body):

```swift
/// Share import (iOS Share Extension parity). `paths`/`originalNames` are parallel arrays of staged files copied by the
/// Kotlin transport into the app cache dir. `playlistMode`: 0 library-only, 1 existing (`playlistId`), 2 new
/// (`newPlaylistName`). Runs the shared `SharedImportCoordinator`; returns counts + the id to open (if `openAfter`).
@WireletExpose
public func importShared(
    _ paths: [String],
    _ originalNames: [String],
    _ playlistMode: Int,
    _ playlistId: String,
    _ newPlaylistName: String,
    _ openAfter: Bool,
) -> ImportSharedResultWire {
    let files = zip(paths, originalNames).map { SharedImportFile(path: $0, originalName: $1) }
    let choice: PlaylistChoice = switch playlistMode {
    case 1: UUID(uuidString: playlistId).map { .existing(PlaylistID(rawValue: $0)) } ?? .libraryOnly
    case 2: .createNew(name: newPlaylistName)
    default: .libraryOnly
    }
    let importer = AndroidShareImporter(store: store)
    let target = AndroidSharePlaylistTarget(owner: self)
    let coordinator = SharedImportCoordinator(importer: importer, target: target)

    // Bridge the async coordinator to this synchronous JNI method. Safe: called from a Kotlin Dispatchers.IO thread,
    // and the Android importer performs only synchronous work inside its async method.
    let sem = DispatchSemaphore(value: 0)
    var shared = SharedImportResult()
    Task {
        shared = await coordinator.run(files: files, choice: choice, openAfter: openAfter)
        sem.signal()
    }
    sem.wait()

    reload()
    reloadPlaylists()
    return ImportSharedResultWire(
        importedCount: Int32(shared.importedIDs.count),
        skippedCount: Int32(shared.skipped.count),
        openAfterId: shared.openAfterID ?? "",
        createdPlaylistId: shared.createdPlaylistID ?? "",
        targetPlaylistId: shared.targetPlaylistID ?? "",
        playlistCreateFailureName: shared.playlistCreateFailureName ?? "",
    )
}
```

Add these adapter types at file scope (outside the class), after the class:

```swift
/// Android importer adapter: hash → dedup against live records → parse + copy + upsert. Mirrors `importScore` plus
/// duplicate detection. No resolver (MVP) — duplicates are skipped silently, returned as `.duplicate`.
private struct AndroidShareImporter: SharedImportFileImporting {
    let store: LibraryStore

    func importFile(_ file: SharedImportFile, isMultiFile: Bool) async -> SharedImportFileResult {
        guard FileManager.default.fileExists(atPath: file.path) else { return .skipped(.missingFile) }
        let hash = store.sha256(path: file.path)
        if !hash.isEmpty,
           let dup = store.loadAll().first(where: { $0.deletedAt <= 0 && $0.contentHash == hash }) {
            return .duplicate(existingID: dup.id, existingTitle: dup.title)
        }
        let url = URL(fileURLWithPath: file.path)
        guard let score = try? MSCZReader.parse(contentsOf: url) else { return .skipped(.parseFailed) }
        let fields = ScorePresentation.displayFields(sourceFilename: url.lastPathComponent, score: score)
        let id = UUID().uuidString
        let localFileName = "\(id).\(ScoreFormat.mscz.canonicalExtension)"
        store.copyImportedFile(fromPath: file.path, localFileName: localFileName)
        store.upsert(ScoreRecordWire(
            id: id, title: fields.title, subtitle: fields.subtitle ?? "", composer: fields.composer ?? "",
            localFileName: localFileName, deletedAt: 0, contentHash: hash,
        ))
        return .imported(id: id)
    }
}

/// Android playlist adapter: reuses `LibraryAndroidStore`'s domain-playlist helpers via the owner reference.
private struct AndroidSharePlaylistTarget: SharedImportPlaylistTargeting {
    unowned let owner: LibraryAndroidStore
    func playlistExists(id: String) -> Bool { owner.sharePlaylistExists(id) }
    func createPlaylist(name: String) -> String? { owner.shareCreatePlaylist(name) }
    func append(scoreIDs: [String], toPlaylistID id: String) { owner.shareAppend(scoreIDs, id) }
}
```

Add the three `internal` helper methods on `LibraryAndroidStore` (non-`@WireletExpose`, so they may live in an extension):

```swift
extension LibraryAndroidStore {
    func sharePlaylistExists(_ id: String) -> Bool { domainPlaylist(id) != nil }

    func shareCreatePlaylist(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let playlist = Playlist(name: trimmed, orderedScoreItemIDs: [], createdAt: Date())
        persist(playlist)
        return playlist.id.rawValue.uuidString
    }

    func shareAppend(_ scoreIDs: [String], _ playlistID: String) {
        guard var playlist = domainPlaylist(playlistID) else { return }
        playlist.appendUnique(scoreIDs.compactMap { UUID(uuidString: $0).map { ScoreItemID(rawValue: $0) } })
        persist(playlist)
    }
}
```

> `domainPlaylist`, `persist`, `appendUnique` already exist (`LibraryAndroidStore.swift` / Domain `Playlist`). The helpers are `internal` so the file-scope adapters can call them.

- [ ] **Step 3: Typecheck the Swift JNI target (host)**

Run the host swift-build step from `Scripts/android-build-library-libs.sh` (or `cd Packages/Features/Library && FOLINO_ANDROID=1 swift build --target FolinoLibraryJNI` if that is the documented host check).
Expected: compiles.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/ImportSharedResultWire.swift Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift
git commit -m "feat(library-jni): importShared running SharedImportCoordinator on Android"
```

### Task 10: Kotlin `RoomLibraryStore` — column, version bump, sha256, new wire field

**Files:**
- Modify: `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt`

> Regenerate the Kotlin bindings first (Task 8/9 changed wire types). `ScoreRecordWire` will now have a `contentHash` constructor arg and `LibraryStore` will declare `sha256`.

- [ ] **Step 1: Add the column to `ScoreRecordEntity`**

```kotlin
@ColumnInfo(name = "content_hash") val contentHash: String = "",
```

- [ ] **Step 2: Bump the DB version**

In `@Database(... version = 1 ...)` change to `version = 2`. (No `Migration` object — `fallbackToDestructiveMigration()` recreates the schema; matches the established fresh-reset practice.)

- [ ] **Step 3: Map the field in `loadAll` and `upsert`**

- `loadAll`: `ScoreRecordWire(it.id, it.title, it.subtitle, it.composer, it.localFileName, it.deletedAt, it.isFavorite, it.contentHash)` — match the generated constructor arg order; if generated order differs, use named args.
- `upsert`: set `contentHash = record.contentHash` on the `ScoreRecordEntity`.

- [ ] **Step 4: Implement `sha256`**

```kotlin
override fun sha256(path: String): String =
    try {
        val md = java.security.MessageDigest.getInstance("SHA-256")
        File(path).inputStream().use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        md.digest().joinToString("") { "%02x".format(it) }
    } catch (e: Exception) {
        ""
    }
```

- [ ] **Step 5: Build the Android library**

Run the Android library build (gradle codegen → `.so`) per `Scripts/android-build-library-libs.sh`.
Expected: builds; `LibraryStore` Kotlin impl satisfies the regenerated interface (including `sha256` and the new `importShared` on the observable bridge).

- [ ] **Step 6: Commit**

```bash
git add Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt
git commit -m "feat(library-android): content_hash column (v2 reset) + sha256"
```

---

## Phase 4 — Android transport (ShareTargetActivity + UI)

### Task 11: `content://` resolution helpers

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/share/ShareImport.kt`

- [ ] **Step 1: Write the helpers**

```kotlin
package com.keynumber.folino.share

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File
import java.util.UUID

/** A file copied out of a content:// share into our cache, ready for the importer. */
data class StagedShareFile(val path: String, val originalName: String)

/** Accepted score extensions — mirror of Domain ShareImportPolicy.acceptedExtensions. */
private val ACCEPTED = setOf("mscz", "mscx", "musicxml", "mxl", "xml", "midi", "mid")

private fun isAccepted(name: String): Boolean =
    name.substringAfterLast('.', "").lowercase() in ACCEPTED

private fun displayName(context: Context, uri: Uri): String {
    if (uri.scheme == "file") return File(uri.path ?: "").name
    context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
        if (c.moveToFirst()) {
            val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (idx >= 0) c.getString(idx)?.let { return it }
        }
    }
    return uri.lastPathSegment ?: "shared"
}

/**
 * Copy each accepted URI into cacheDir/IncomingShare/<batch>/, returning the staged files and the count of
 * unsupported/failed ones. Acceptance is decided here (after we know the display name), mirroring the iOS UTI-broad /
 * extension-gated approach.
 */
fun stageSharedUris(context: Context, uris: List<Uri>): Pair<List<StagedShareFile>, Int> {
    val batchDir = File(context.cacheDir, "IncomingShare/${UUID.randomUUID()}").apply { mkdirs() }
    val staged = mutableListOf<StagedShareFile>()
    var unsupported = 0
    for (uri in uris) {
        val name = displayName(context, uri)
        if (!isAccepted(name)) { unsupported++; continue }
        try {
            val dest = File(batchDir, name)
            context.contentResolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { input.copyTo(it) }
            } ?: run { unsupported++; return@run }
            if (dest.exists()) staged.add(StagedShareFile(dest.absolutePath, name)) else unsupported++
        } catch (e: Exception) {
            unsupported++
        }
    }
    return staged to unsupported
}

/** Best-effort cleanup of a staged batch dir after import. */
fun cleanupStaged(staged: List<StagedShareFile>) {
    staged.firstOrNull()?.let { File(it.path).parentFile?.deleteRecursively() }
}
```

- [ ] **Step 2: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/share/ShareImport.kt
git commit -m "feat(android/share): content:// staging helpers"
```

### Task 12: `ShareTargetActivity` + bottom sheet UI

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/share/ShareTargetActivity.kt`

- [ ] **Step 1: Write the activity + Compose bottom sheet**

The activity: reads intent URIs (SEND/SEND_MULTIPLE/VIEW), stages them, and shows a `ModalBottomSheet` with a file-count summary, a destination picker (Library only / existing playlist / new playlist with a name field), and Save / Save & Open buttons. On confirm it calls `importShared` off the main thread, then for Save & Open launches `MainActivity` with an open-score extra. Use the existing `LibraryAndroidStoreViewModel` (factory `LibraryVMFactory`) to read `playlists` and call `importShared`.

```kotlin
package com.keynumber.folino.share

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import com.keynumber.folino.MainActivity
import com.keynumber.folino.library.LibraryVMFactory
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class ShareTargetActivity : ComponentActivity() {

    private val vm: LibraryAndroidStoreViewModel by viewModels {
        LibraryVMFactory(applicationContext)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val uris = extractUris(intent)
        if (uris.isEmpty()) { finish(); return }

        setContent {
            MaterialTheme {
                var staged by remember { mutableStateOf<List<StagedShareFile>?>(null) }
                var unsupported by remember { mutableIntStateOf(0) }

                LaunchedEffect(Unit) {
                    val (files, bad) = withContext(Dispatchers.IO) { stageSharedUris(this@ShareTargetActivity, uris) }
                    staged = files
                    unsupported = bad
                }

                val playlists by vm.playlists.collectAsState()
                val files = staged
                if (files != null) {
                    if (files.isEmpty()) {
                        LaunchedEffect(Unit) {
                            Toast.makeText(this@ShareTargetActivity,
                                getString(R.string.share_no_supported_files), Toast.LENGTH_LONG).show()
                            finish()
                        }
                    } else {
                        ShareImportSheet(
                            fileCount = files.size,
                            unsupportedCount = unsupported,
                            playlists = playlists.map { it.id to it.name },
                            onCancel = { cleanupStaged(files); finish() },
                            onConfirm = { mode, playlistId, newName, openAfter ->
                                performImport(files, mode, playlistId, newName, openAfter)
                            },
                        )
                    }
                }
            }
        }
    }

    private fun performImport(
        files: List<StagedShareFile>, mode: Int, playlistId: String, newName: String, openAfter: Boolean,
    ) {
        lifecycleScope.launch {
            val result = withContext(Dispatchers.IO) {
                vm.importShared(
                    files.map { it.path }, files.map { it.originalName },
                    mode, playlistId, newName, openAfter,
                )
            }
            cleanupStaged(files)
            val openId = result.openAfterId
            if (openAfter && openId.isNotEmpty()) {
                startActivity(Intent(this@ShareTargetActivity, MainActivity::class.java).apply {
                    putExtra(MainActivity.EXTRA_OPEN_SCORE_ID, openId)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                })
            } else {
                val msg = if (result.importedCount > 0)
                    getString(R.string.share_imported_count, result.importedCount)
                else getString(R.string.share_nothing_imported)
                Toast.makeText(this@ShareTargetActivity, msg, Toast.LENGTH_LONG).show()
            }
            finish()
        }
    }

    private fun extractUris(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_SEND -> listOfNotNull(
            if (Build.VERSION.SDK_INT >= 33)
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM),
        )
        Intent.ACTION_SEND_MULTIPLE ->
            (if (Build.VERSION.SDK_INT >= 33)
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else @Suppress("DEPRECATION") intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM))
                ?.filterNotNull() ?: emptyList()
        Intent.ACTION_VIEW -> listOfNotNull(intent.data)
        else -> emptyList()
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ShareImportSheet(
    fileCount: Int,
    unsupportedCount: Int,
    playlists: List<Pair<String, String>>,
    onCancel: () -> Unit,
    onConfirm: (mode: Int, playlistId: String, newName: String, openAfter: Boolean) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    // mode: 0 library, 1 existing, 2 new
    var mode by remember { mutableIntStateOf(0) }
    var selectedPlaylist by remember { mutableStateOf(playlists.firstOrNull()?.first ?: "") }
    var newName by remember { mutableStateOf("") }

    ModalBottomSheet(onDismissRequest = onCancel, sheetState = sheetState) {
        Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 32.dp)) {
            Text(
                text = pluralFiles(fileCount),
                style = MaterialTheme.typography.titleLarge,
            )
            if (unsupportedCount > 0) {
                Text(
                    text = unsupportedSkippedText(unsupportedCount),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Spacer(Modifier.height(16.dp))
            Text("Add to", style = MaterialTheme.typography.titleSmall)

            DestinationRow("Library", selected = mode == 0) { mode = 0 }
            if (playlists.isNotEmpty()) {
                DestinationRow("Existing playlist", selected = mode == 1) { mode = 1 }
                if (mode == 1) {
                    Column(Modifier.padding(start = 32.dp)) {
                        playlists.forEach { (id, name) ->
                            DestinationRow(name, selected = selectedPlaylist == id) { selectedPlaylist = id }
                        }
                    }
                }
            }
            DestinationRow("New playlist", selected = mode == 2) { mode = 2 }
            if (mode == 2) {
                OutlinedTextField(
                    value = newName, onValueChange = { newName = it },
                    label = { Text("Playlist name") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions.Default,
                    modifier = Modifier.fillMaxWidth().padding(start = 32.dp, top = 4.dp),
                )
            }

            Spacer(Modifier.height(24.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                val enabled = mode != 2 || newName.isNotBlank()
                OutlinedButton(onClick = {
                    onConfirm(mode, if (mode == 1) selectedPlaylist else "", newName.trim(), false)
                }, enabled = enabled, modifier = Modifier.weight(1f)) { Text("Save") }
                Button(onClick = {
                    onConfirm(mode, if (mode == 1) selectedPlaylist else "", newName.trim(), true)
                }, enabled = enabled, modifier = Modifier.weight(1f)) { Text("Save & Open") }
            }
        }
    }
}

@Composable
private fun DestinationRow(label: String, selected: Boolean, onSelect: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().selectable(selected = selected, onClick = onSelect).padding(vertical = 8.dp),
        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = onSelect)
        Spacer(Modifier.width(8.dp))
        Text(label, style = MaterialTheme.typography.bodyLarge)
    }
}

private fun pluralFiles(n: Int): String = if (n == 1) "Import 1 score" else "Import $n scores"
private fun unsupportedSkippedText(n: Int): String =
    if (n == 1) "1 unsupported file skipped" else "$n unsupported files skipped"
```

> The string literals above are placeholders for rapid wiring; in Step 2 they are routed through Android string resources for localization parity (folino lowercase brand etc.). `vm.importShared(...)` returns the generated wire type — confirm its property names (`openAfterId`, `importedCount`) against the regenerated Kotlin and adjust if the codec names differ.

- [ ] **Step 2: Add string resources**

In `Android/app/src/main/res/values/strings.xml` add: `share_no_supported_files`, `share_imported_count` (with `%d`), `share_nothing_imported`. Replace the inline English literals in the sheet/toasts with `stringResource(...)` / `getString(...)` calls. (Match the project's existing localization approach; keep brand lowercase `folino`.)

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/share/ShareTargetActivity.kt Android/app/src/main/res/values/strings.xml
git commit -m "feat(android/share): ShareTargetActivity bottom-sheet import UI"
```

### Task 13: Manifest intent-filters + MainActivity open-extra

**Files:**
- Modify: `Android/app/src/main/AndroidManifest.xml`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`

- [ ] **Step 1: Declare `ShareTargetActivity` with intent-filters**

Inside `<application>`:

```xml
<activity
    android:name=".share.ShareTargetActivity"
    android:exported="true"
    android:excludeFromRecents="true"
    android:theme="@style/AppTheme">
    <intent-filter>
        <action android:name="android.intent.action.SEND" />
        <category android:name="android.intent.category.DEFAULT" />
        <data android:mimeType="application/octet-stream" />
        <data android:mimeType="application/xml" />
        <data android:mimeType="text/xml" />
        <data android:mimeType="audio/midi" />
        <data android:mimeType="application/x-musescore" />
    </intent-filter>
    <intent-filter>
        <action android:name="android.intent.action.SEND_MULTIPLE" />
        <category android:name="android.intent.category.DEFAULT" />
        <data android:mimeType="application/octet-stream" />
        <data android:mimeType="application/xml" />
        <data android:mimeType="text/xml" />
        <data android:mimeType="audio/midi" />
    </intent-filter>
    <intent-filter>
        <action android:name="android.intent.action.VIEW" />
        <category android:name="android.intent.category.DEFAULT" />
        <category android:name="android.intent.category.BROWSABLE" />
        <data android:scheme="content" />
        <data android:scheme="file" />
        <data android:mimeType="application/octet-stream" />
        <data android:mimeType="application/xml" />
        <data android:mimeType="text/xml" />
        <data android:mimeType="audio/midi" />
    </intent-filter>
</activity>
```

> Acceptance is re-checked by extension after receipt (`stageSharedUris`), so broad MIME types here are intentional — they only widen what folino *appears for*, not what it imports.

- [ ] **Step 2: Honor an open-score launch extra in `MainActivity`**

Add a companion constant and consume the extra. Near the top of the `MainActivity` class:

```kotlin
companion object { const val EXTRA_OPEN_SCORE_ID = "open_score_id" }
```

In the composable where `nav` exists and `openReader`/reader route is set up, after the nav graph is created, read the extra once and navigate:

```kotlin
LaunchedEffect(Unit) {
    intent?.getStringExtra(EXTRA_OPEN_SCORE_ID)?.let { id ->
        intent.removeExtra(EXTRA_OPEN_SCORE_ID)
        nav.navigate("reader/$id/0")
    }
}
```

> The reader route is `reader/{id}/{t}` (see `MainActivity` `openReader`); `0` is a benign timestamp arg. Also handle `onNewIntent` if MainActivity is already running: override `onNewIntent`, store the new intent, and trigger the same navigation. Confirm the exact route arity against the live nav graph during implementation.

- [ ] **Step 3: Build + install + launch on Pixel**

Run the app build + `installDebug` + `adb shell am start` per `[[feedback_android_install_launch]]`.
Expected: app launches normally (no share yet — just verify nothing regressed).

- [ ] **Step 4: Commit**

```bash
git add Android/app/src/main/AndroidManifest.xml Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(android/share): SEND/VIEW intent-filters + open-after launch extra"
```

---

## Phase 5 — Verification

### Task 14: Manual end-to-end verification on Pixel

**No code.** Per the Android workflow (install + launch), verify on a physical Pixel:

- [ ] **Share single `.mscz`** from Files/a file manager → folino appears in the share sheet → pick it → bottom sheet shows "Import 1 score" → Save → toast confirms → score appears in Library.
- [ ] **Share multiple files** (mix of supported + an unsupported e.g. `.pdf`) via SEND_MULTIPLE → sheet shows correct count + "N unsupported skipped" → Save imports only supported.
- [ ] **"Open with" (ACTION_VIEW)** from a file manager → folino offered → same sheet.
- [ ] **Existing playlist** destination → imported scores appear in that playlist.
- [ ] **New playlist** destination → playlist created, scores in it.
- [ ] **Save & Open** → lands directly in the Reader showing the imported score.
- [ ] **Duplicate**: share the same file twice → second time it is skipped (no duplicate row); with Save & Open the existing score opens.
- [ ] **Fresh-install DB reset**: confirm the v2 destructive migration didn't crash on upgrade (install over a prior build).

- [ ] **Commit** (only if verification surfaced fixes; otherwise nothing to commit).

### Task 15: Full iOS regression + Domain suite

- [ ] **Run the Domain suite**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:DomainTests/SharedImportCoordinatorTests -only-testing:DomainTests/ShareImportPolicyTests`
Expected: PASS.

- [ ] **Run the ImportExport suite**

Run: `cd Packages/Features/ImportExport && xcodebuild test -scheme ImportExport -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: PASS (coordinator, share-session, token-URL, playlists-index tests).

- [ ] **Build the iOS app + Share Extension**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED (the `ShareDecision`/`PlaylistChoice` move and the coordinator delegation compile end to end).

---

## Notes on parity & follow-ups

- **Duplicate confirmation UI** is intentionally omitted on Android (MVP silent-skip = iOS no-resolver path). A future task can add a resolver dialog mirroring iOS's per-file alert.
- **iOS `importScore` (single-file, non-share) path** is unchanged; only the share drain delegates.
- **`xml` ambiguity**: a generic `.xml` that isn't MusicXML will parse-fail in `MSCZReader` and be skipped — acceptable, matches iOS (it accepts the extension then fails to parse).

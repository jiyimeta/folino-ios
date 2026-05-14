# Share Extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `FolinoShareExtension` target so Folino appears in the iOS share sheet for score files. The extension presents a playlist picker + two actions (`Save` / `Save & Open`), stages the bytes to an App Group container, and hands off to the main app via a `folino://` URL scheme. Main app drains the staged tokens through the existing import pipeline; a launch-time fallback covers cases where the URL handoff didn't reach the main app.

**Architecture:** Approach A from the spec — the extension is a "dumb stager": it never touches the DB. The main app remains the single writer for SQLite. The `ImportExport` SPM package gains three library products: `ImportExportAppGroup` (shared codables / paths), `ImportExport` (main-app drain logic), `ImportExportShareUI` (extension SwiftUI + session). A new `Domain.PlaylistsIndexPublisher` protocol bridges `Persistence` → `ImportExport.PlaylistsIndexWriter` without crossing the Feature → Infrastructure boundary the wrong way.

**Tech Stack:** Swift 6.3, SwiftUI, Swift Testing, XcodeGen + project.yml, App Group entitlement (`group.com.KeyNumber.Folino`), responder-chain `UIApplication.open` trick (with drain-on-launch fallback).

**Spec:** `docs/superpowers/specs/2026-05-15-share-extension-design.md`

---

## File Structure

### New files

```
Packages/Features/ImportExport/
├── Package.swift                                    (rewrite: 3 library products)
├── Sources/
│   ├── ImportExport/
│   │   ├── DrainResult.swift                        (DrainResult, Skip, SkipReason)
│   │   ├── IncomingShareCoordinator.swift           (drain logic)
│   │   ├── PlaylistsIndexWriter.swift               (atomic file write + protocol conformance)
│   │   └── ShareTokenURL.swift                      (URL scheme parser)
│   ├── ImportExportAppGroup/
│   │   ├── AppGroupPaths.swift                      (IDs + path constants)
│   │   ├── IncomingShareIntent.swift                (codable intent payload)
│   │   └── PlaylistsIndex.swift                     (codable playlist snapshot)
│   └── ImportExportShareUI/
│       ├── ActionButtons.swift                      (Save / Save & Open footer)
│       ├── FileSummary.swift                        (collapsible file list)
│       ├── PlaylistPicker.swift                     (single-select + inline create)
│       ├── ShareDecision.swift                      (decision + choice enums)
│       ├── ShareRootView.swift                      (SwiftUI root)
│       └── ShareSession.swift                       (extension service)
└── Tests/
    ├── ImportExportAppGroupTests/
    │   ├── IncomingShareIntentTests.swift
    │   └── PlaylistsIndexTests.swift
    ├── ImportExportShareUITests/
    │   └── ShareSessionTests.swift
    └── ImportExportTests/
        ├── IncomingShareCoordinatorTests.swift
        ├── PlaylistsIndexWriterTests.swift
        └── ShareTokenURLTests.swift

Packages/Domain/Sources/Domain/Protocols/
└── PlaylistsIndexPublisher.swift                    (NEW: bridging protocol)

App/
├── Folino.entitlements                              (modify: add App Groups)
├── Info.plist                                       (modify: CFBundleURLTypes)
└── ShareExtension/                                  (NEW directory)
    ├── FolinoShareExtension.entitlements
    ├── Info.plist
    └── ShareViewController.swift

project.yml                                          (modify: new target, App Group cap)
```

### Modified files

- `Packages/Features/ImportExport/Package.swift` — replace with 3-product layout, delete `Placeholder.swift`
- `Packages/Features/ImportExport/Sources/ImportExport/Placeholder.swift` — delete
- `Packages/Infrastructure/Sources/Persistence/LiveScoreLibraryRepository.swift` — add `publisher: PlaylistsIndexPublisher?` init parameter, invoke after `savePlaylist` / `deletePlaylist`
- `App/AppBootstrap.swift` — share token slot, `acceptIncomingURL` routing, wire `PlaylistsIndexWriter` and `IncomingShareCoordinator`, drain-on-launch
- `App/AppShellView.swift` — drain consumer in `ReadyShell`, banner / Reader push handling, multi-file HUD label

---

## Task 1: Restructure ImportExport package into 3 library products

**Files:**
- Modify: `Packages/Features/ImportExport/Package.swift`
- Delete: `Packages/Features/ImportExport/Sources/ImportExport/Placeholder.swift`

- [ ] **Step 1: Rewrite Package.swift**

```swift
// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "ImportExport",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "ImportExport", targets: ["ImportExport"]),
        .library(name: "ImportExportAppGroup", targets: ["ImportExportAppGroup"]),
        .library(name: "ImportExportShareUI", targets: ["ImportExportShareUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
        .package(path: "../../Domain"),
        .package(path: "../../Utility"),
    ],
    targets: [
        .target(
            name: "ImportExportAppGroup",
            dependencies: ["Domain"],
            plugins: swiftLintPlugins,
        ),
        .target(
            name: "ImportExport",
            dependencies: [
                "ImportExportAppGroup",
                "Domain",
                .product(name: "UtilityCore", package: "Utility"),
            ],
            plugins: swiftLintPlugins,
        ),
        .target(
            name: "ImportExportShareUI",
            dependencies: [
                "ImportExportAppGroup",
                "Domain",
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "UtilityUI", package: "Utility"),
            ],
            plugins: swiftLintPlugins,
        ),
        .testTarget(
            name: "ImportExportAppGroupTests",
            dependencies: ["ImportExportAppGroup"],
        ),
        .testTarget(
            name: "ImportExportTests",
            dependencies: ["ImportExport"],
        ),
        .testTarget(
            name: "ImportExportShareUITests",
            dependencies: ["ImportExportShareUI"],
        ),
    ],
)
```

- [ ] **Step 2: Delete placeholder source**

```bash
rm /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport/Sources/ImportExport/Placeholder.swift
```

- [ ] **Step 3: Create empty source directories so SPM resolves**

```bash
mkdir -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport/Sources/ImportExportAppGroup
mkdir -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport/Sources/ImportExportShareUI
mkdir -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport/Tests/ImportExportAppGroupTests
mkdir -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport/Tests/ImportExportShareUITests
```

Add a tiny `_Module.swift` to each new target+test directory (so SPM doesn't error on an empty target):

```swift
// Sources/ImportExportAppGroup/_Module.swift
// Marker file; remove once real sources exist.
```

```swift
// Sources/ImportExportShareUI/_Module.swift
// Marker file; remove once real sources exist.
```

```swift
// Tests/ImportExportAppGroupTests/_Module.swift
// Marker file; remove once real tests exist.
```

```swift
// Tests/ImportExportShareUITests/_Module.swift
// Marker file; remove once real tests exist.
```

- [ ] **Step 4: Verify package resolves**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport && swift build
```

Expected: build succeeds with no errors. SwiftLint warnings on `_Module.swift` are OK.

- [ ] **Step 5: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Features/ImportExport
git commit -m "Restructure ImportExport package into 3 library products"
```

---

## Task 2: AppGroupPaths shared constants

**Files:**
- Create: `Packages/Features/ImportExport/Sources/ImportExportAppGroup/AppGroupPaths.swift`
- Delete: `Packages/Features/ImportExport/Sources/ImportExportAppGroup/_Module.swift`

- [ ] **Step 1: Write the source**

```swift
// Sources/ImportExportAppGroup/AppGroupPaths.swift
import Foundation

public enum AppGroupIDs {
    public static let identifier = "group.com.KeyNumber.Folino"
}

public enum AppGroupPaths {
    public static let playlistsIndexFilename = "playlists.json"
    public static let incomingImportsDirname = "IncomingImports"
    public static let intentFilename = "intent.json"
    public static let filesDirname = "files"

    public static func container() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupIDs.identifier,
        )
    }

    public static func playlistsIndexURL(in container: URL) -> URL {
        container.appending(path: playlistsIndexFilename, directoryHint: .notDirectory)
    }

    public static func incomingImportsURL(in container: URL) -> URL {
        container.appending(path: incomingImportsDirname, directoryHint: .isDirectory)
    }

    public static func tokenURL(token: UUID, in container: URL) -> URL {
        incomingImportsURL(in: container)
            .appending(path: token.uuidString, directoryHint: .isDirectory)
    }

    public static func tokenIntentURL(token: UUID, in container: URL) -> URL {
        tokenURL(token: token, in: container)
            .appending(path: intentFilename, directoryHint: .notDirectory)
    }

    public static func tokenFilesURL(token: UUID, in container: URL) -> URL {
        tokenURL(token: token, in: container)
            .appending(path: filesDirname, directoryHint: .isDirectory)
    }
}
```

- [ ] **Step 2: Delete the marker**

```bash
rm /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport/Sources/ImportExportAppGroup/_Module.swift
```

- [ ] **Step 3: Verify it builds**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport && swift build --target ImportExportAppGroup
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Features/ImportExport
git commit -m "Add AppGroupPaths constants for share extension container"
```

---

## Task 3: PlaylistsIndex codable type

**Files:**
- Create: `Packages/Features/ImportExport/Sources/ImportExportAppGroup/PlaylistsIndex.swift`
- Create: `Packages/Features/ImportExport/Tests/ImportExportAppGroupTests/PlaylistsIndexTests.swift`
- Delete: `Packages/Features/ImportExport/Tests/ImportExportAppGroupTests/_Module.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ImportExportAppGroupTests/PlaylistsIndexTests.swift
import Domain
import Foundation
import Testing
@testable import ImportExportAppGroup

@Suite("PlaylistsIndex")
struct PlaylistsIndexTests {
    @Test func encodesAndDecodesRoundTrip() throws {
        let original = PlaylistsIndex(
            schemaVersion: 1,
            playlists: [
                .init(id: PlaylistID(), name: "Practice"),
                .init(id: PlaylistID(), name: "Jazz"),
            ],
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlaylistsIndex.self, from: data)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.playlists.count == 2)
        #expect(decoded.playlists[0].name == "Practice")
        #expect(decoded.playlists[0].id == original.playlists[0].id)
    }

    @Test func emptyPlaylistsRoundTrip() throws {
        let original = PlaylistsIndex(schemaVersion: 1, playlists: [])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlaylistsIndex.self, from: data)
        #expect(decoded.playlists.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport && swift test --filter PlaylistsIndexTests
```

Expected: build error — `PlaylistsIndex` not defined.

- [ ] **Step 3: Write the type**

```swift
// Sources/ImportExportAppGroup/PlaylistsIndex.swift
import Domain
import Foundation

public struct PlaylistsIndex: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let playlists: [Entry]

    public init(schemaVersion: Int, playlists: [Entry]) {
        self.schemaVersion = schemaVersion
        self.playlists = playlists
    }

    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public let id: PlaylistID
        public let name: String

        public init(id: PlaylistID, name: String) {
            self.id = id
            self.name = name
        }
    }
}
```

- [ ] **Step 4: Delete marker, run tests**

```bash
rm /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport/Tests/ImportExportAppGroupTests/_Module.swift
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport && swift test --filter PlaylistsIndexTests
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Features/ImportExport
git commit -m "Add PlaylistsIndex codable for share extension"
```

---

## Task 4: IncomingShareIntent codable type

**Files:**
- Create: `Packages/Features/ImportExport/Sources/ImportExportAppGroup/IncomingShareIntent.swift`
- Create: `Packages/Features/ImportExport/Tests/ImportExportAppGroupTests/IncomingShareIntentTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ImportExportAppGroupTests/IncomingShareIntentTests.swift
import Domain
import Foundation
import Testing
@testable import ImportExportAppGroup

@Suite("IncomingShareIntent")
struct IncomingShareIntentTests {
    @Test func encodesAndDecodesWithExistingPlaylist() throws {
        let original = IncomingShareIntent(
            schemaVersion: 1,
            token: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            playlistID: PlaylistID(),
            newPlaylistName: nil,
            openAfter: true,
            files: [
                .init(relativePath: "files/song.mscz", originalName: "song.mscz"),
            ],
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IncomingShareIntent.self, from: data)
        #expect(decoded.token == original.token)
        #expect(decoded.playlistID == original.playlistID)
        #expect(decoded.newPlaylistName == nil)
        #expect(decoded.openAfter == true)
        #expect(decoded.files == original.files)
    }

    @Test func encodesAndDecodesWithNewPlaylistName() throws {
        let original = IncomingShareIntent(
            schemaVersion: 1,
            token: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            playlistID: nil,
            newPlaylistName: "Smoke test",
            openAfter: false,
            files: [],
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IncomingShareIntent.self, from: data)
        #expect(decoded.newPlaylistName == "Smoke test")
        #expect(decoded.playlistID == nil)
        #expect(decoded.openAfter == false)
    }

    @Test func encodesAndDecodesLibraryOnly() throws {
        let original = IncomingShareIntent(
            schemaVersion: 1,
            token: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            playlistID: nil,
            newPlaylistName: nil,
            openAfter: true,
            files: [
                .init(relativePath: "files/a.mscz", originalName: "a.mscz"),
                .init(relativePath: "files/b.musicxml", originalName: "b.musicxml"),
            ],
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IncomingShareIntent.self, from: data)
        #expect(decoded.files.count == 2)
        #expect(decoded.playlistID == nil && decoded.newPlaylistName == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport && swift test --filter IncomingShareIntentTests
```

Expected: build error.

- [ ] **Step 3: Write the type**

```swift
// Sources/ImportExportAppGroup/IncomingShareIntent.swift
import Domain
import Foundation

public struct IncomingShareIntent: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let token: UUID
    public let createdAt: Date
    public let playlistID: PlaylistID?
    public let newPlaylistName: String?
    public let openAfter: Bool
    public let files: [File]

    public init(
        schemaVersion: Int,
        token: UUID,
        createdAt: Date,
        playlistID: PlaylistID?,
        newPlaylistName: String?,
        openAfter: Bool,
        files: [File],
    ) {
        self.schemaVersion = schemaVersion
        self.token = token
        self.createdAt = createdAt
        self.playlistID = playlistID
        self.newPlaylistName = newPlaylistName
        self.openAfter = openAfter
        self.files = files
    }

    public struct File: Codable, Sendable, Equatable {
        public let relativePath: String
        public let originalName: String

        public init(relativePath: String, originalName: String) {
            self.relativePath = relativePath
            self.originalName = originalName
        }
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport && swift test --filter IncomingShareIntentTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Features/ImportExport
git commit -m "Add IncomingShareIntent codable for share extension handoff"
```

---

## Task 5: PlaylistsIndexPublisher Domain protocol

**Files:**
- Create: `Packages/Domain/Sources/Domain/Protocols/PlaylistsIndexPublisher.swift`

- [ ] **Step 1: Write the protocol**

```swift
// Packages/Domain/Sources/Domain/Protocols/PlaylistsIndexPublisher.swift
import Foundation

/// Notifies an out-of-process consumer (the Share Extension) about the
/// current Library playlist set. The live implementation in `ImportExport`
/// writes the snapshot to a shared App Group file; tests can use a
/// no-op stub.
public protocol PlaylistsIndexPublisher: Sendable {
    func publish(playlists: [Playlist]) async
}
```

- [ ] **Step 2: Verify Domain still builds**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Domain && swift build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Domain
git commit -m "Add PlaylistsIndexPublisher protocol for share-extension index"
```

---

## Task 6: PlaylistsIndexWriter

**Files:**
- Create: `Packages/Features/ImportExport/Sources/ImportExport/PlaylistsIndexWriter.swift`
- Create: `Packages/Features/ImportExport/Tests/ImportExportTests/PlaylistsIndexWriterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ImportExportTests/PlaylistsIndexWriterTests.swift
import Domain
import Foundation
import ImportExportAppGroup
import Testing
@testable import ImportExport

@MainActor
@Suite("PlaylistsIndexWriter")
struct PlaylistsIndexWriterTests {
    @Test func writesPlaylistsIndexFileAtomically() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "share-ext-writer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writer = PlaylistsIndexWriter(appGroupContainer: tmp)
        let playlists = [
            Playlist(name: "P1", orderedScoreItemIDs: [], createdAt: .now),
            Playlist(name: "P2", orderedScoreItemIDs: [], createdAt: .now),
        ]

        await writer.publish(playlists: playlists)

        let url = AppGroupPaths.playlistsIndexURL(in: tmp)
        let data = try Data(contentsOf: url)
        let index = try JSONDecoder().decode(PlaylistsIndex.self, from: data)
        #expect(index.schemaVersion == 1)
        #expect(index.playlists.map(\.name) == ["P1", "P2"])
    }

    @Test func overwritesExistingFile() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "share-ext-writer-overwrite-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writer = PlaylistsIndexWriter(appGroupContainer: tmp)
        await writer.publish(playlists: [
            Playlist(name: "old", orderedScoreItemIDs: [], createdAt: .now),
        ])
        await writer.publish(playlists: [
            Playlist(name: "new", orderedScoreItemIDs: [], createdAt: .now),
        ])

        let url = AppGroupPaths.playlistsIndexURL(in: tmp)
        let data = try Data(contentsOf: url)
        let index = try JSONDecoder().decode(PlaylistsIndex.self, from: data)
        #expect(index.playlists.map(\.name) == ["new"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport && swift test --filter PlaylistsIndexWriterTests
```

Expected: build error — `PlaylistsIndexWriter` not defined.

- [ ] **Step 3: Write the writer**

```swift
// Sources/ImportExport/PlaylistsIndexWriter.swift
import Domain
import Foundation
import ImportExportAppGroup
import os

/// Writes `PlaylistsIndex` atomically to the App Group container so the
/// Share Extension can show the current Library playlists in its picker.
/// Conforms to `PlaylistsIndexPublisher` so it can plug into
/// `LiveScoreLibraryRepository` without that target importing ImportExport.
public final class PlaylistsIndexWriter: PlaylistsIndexPublisher {
    private let appGroupContainer: URL
    private let logger = Logger(subsystem: "com.KeyNumber.Folino", category: "PlaylistsIndexWriter")

    public init(appGroupContainer: URL) {
        self.appGroupContainer = appGroupContainer
    }

    public func publish(playlists: [Playlist]) async {
        let entries = playlists.map { PlaylistsIndex.Entry(id: $0.id, name: $0.name) }
        let index = PlaylistsIndex(schemaVersion: 1, playlists: entries)
        do {
            let data = try JSONEncoder().encode(index)
            let destination = AppGroupPaths.playlistsIndexURL(in: appGroupContainer)
            let tmp = destination.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
        } catch {
            logger.error("playlists.json write failed: \(String(describing: error))")
        }
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport && swift test --filter PlaylistsIndexWriterTests
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Features/ImportExport
git commit -m "Add PlaylistsIndexWriter for share-extension index"
```

---

## Task 7: DrainResult / Skip / SkipReason value types

**Files:**
- Create: `Packages/Features/ImportExport/Sources/ImportExport/DrainResult.swift`

- [ ] **Step 1: Write the types**

```swift
// Sources/ImportExport/DrainResult.swift
import Domain
import Foundation

public struct DrainResult: Sendable {
    public let imported: [ScoreItemID]
    public let skipped: [Skip]
    public let openAfter: ScoreItemID?
    public let createdPlaylistID: PlaylistID?
    public let targetPlaylistID: PlaylistID?
    public let targetPlaylistName: String?

    public init(
        imported: [ScoreItemID],
        skipped: [Skip],
        openAfter: ScoreItemID?,
        createdPlaylistID: PlaylistID?,
        targetPlaylistID: PlaylistID?,
        targetPlaylistName: String?,
    ) {
        self.imported = imported
        self.skipped = skipped
        self.openAfter = openAfter
        self.createdPlaylistID = createdPlaylistID
        self.targetPlaylistID = targetPlaylistID
        self.targetPlaylistName = targetPlaylistName
    }

    public static let empty = DrainResult(
        imported: [],
        skipped: [],
        openAfter: nil,
        createdPlaylistID: nil,
        targetPlaylistID: nil,
        targetPlaylistName: nil,
    )
}

public struct Skip: Sendable {
    public let originalName: String
    public let reason: SkipReason

    public init(originalName: String, reason: SkipReason) {
        self.originalName = originalName
        self.reason = reason
    }
}

public enum SkipReason: Sendable {
    case unsupportedFormat
    case unreadable(any Error)
    case parseFailed(any Error)
    case persistenceFailed(any Error)
    case duplicate(existingID: ScoreItemID, existingTitle: String)
}
```

- [ ] **Step 2: Build verify**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport && swift build --target ImportExport
```

Expected: builds.

- [ ] **Step 3: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Features/ImportExport
git commit -m "Add DrainResult/Skip/SkipReason types"
```

---

## Task 8: ShareTokenURL parser

**Files:**
- Create: `Packages/Features/ImportExport/Sources/ImportExport/ShareTokenURL.swift`
- Create: `Packages/Features/ImportExport/Tests/ImportExportTests/ShareTokenURLTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ImportExportTests/ShareTokenURLTests.swift
import Foundation
import Testing
@testable import ImportExport

@Suite("ShareTokenURL")
struct ShareTokenURLTests {
    @Test func parsesValidImportURL() {
        let token = UUID()
        let url = URL(string: "folino://import?token=\(token.uuidString)&open=true")!
        let parsed = ShareTokenURL.parse(url)
        #expect(parsed?.token == token)
        #expect(parsed?.openAfter == true)
    }

    @Test func parsesOpenFalse() {
        let token = UUID()
        let url = URL(string: "folino://import?token=\(token.uuidString)&open=false")!
        let parsed = ShareTokenURL.parse(url)
        #expect(parsed?.openAfter == false)
    }

    @Test func defaultsOpenAfterToFalseWhenMissing() {
        let token = UUID()
        let url = URL(string: "folino://import?token=\(token.uuidString)")!
        let parsed = ShareTokenURL.parse(url)
        #expect(parsed?.openAfter == false)
    }

    @Test func rejectsWrongScheme() {
        let url = URL(string: "file:///tmp/foo.mscz")!
        #expect(ShareTokenURL.parse(url) == nil)
    }

    @Test func rejectsWrongHost() {
        let url = URL(string: "folino://export?token=\(UUID().uuidString)")!
        #expect(ShareTokenURL.parse(url) == nil)
    }

    @Test func rejectsMissingToken() {
        let url = URL(string: "folino://import?open=true")!
        #expect(ShareTokenURL.parse(url) == nil)
    }

    @Test func rejectsMalformedToken() {
        let url = URL(string: "folino://import?token=not-a-uuid&open=true")!
        #expect(ShareTokenURL.parse(url) == nil)
    }

    @Test func builds() {
        let token = UUID()
        let url = ShareTokenURL.build(token: token, openAfter: true)
        #expect(url.scheme == "folino")
        #expect(url.host == "import")
        let parsed = ShareTokenURL.parse(url)
        #expect(parsed?.token == token)
        #expect(parsed?.openAfter == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport && swift test --filter ShareTokenURLTests
```

Expected: build error.

- [ ] **Step 3: Write the parser**

```swift
// Sources/ImportExport/ShareTokenURL.swift
import Foundation

public enum ShareTokenURL {
    public static let scheme = "folino"
    public static let host = "import"

    public struct Parsed: Equatable, Sendable {
        public let token: UUID
        public let openAfter: Bool
    }

    public static func parse(_ url: URL) -> Parsed? {
        guard url.scheme == scheme, url.host == host else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        guard let tokenString = items.first(where: { $0.name == "token" })?.value,
              let token = UUID(uuidString: tokenString) else { return nil }
        let openValue = items.first(where: { $0.name == "open" })?.value
        let openAfter = (openValue == "true" || openValue == "1")
        return Parsed(token: token, openAfter: openAfter)
    }

    public static func build(token: UUID, openAfter: Bool) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [
            URLQueryItem(name: "token", value: token.uuidString),
            URLQueryItem(name: "open", value: openAfter ? "true" : "false"),
        ]
        return components.url!
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport && swift test --filter ShareTokenURLTests
```

Expected: 8 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Features/ImportExport
git commit -m "Add ShareTokenURL parser/builder for folino:// scheme"
```

---

## Task 9: IncomingShareCoordinator — drain logic

**Files:**
- Create: `Packages/Features/ImportExport/Sources/ImportExport/IncomingShareCoordinator.swift`
- Create: `Packages/Features/ImportExport/Tests/ImportExportTests/IncomingShareCoordinatorTests.swift`

- [ ] **Step 1: Write the failing test**

This is the biggest test in the package. It covers six scenarios: single-file library-only, multi-file existing playlist, new-playlist creation, duplicate, partial-failure, and drain-on-launch ordering. Use a fake importer and a fake repository.

```swift
// Tests/ImportExportTests/IncomingShareCoordinatorTests.swift
import Domain
import Foundation
import ImportExportAppGroup
import Testing
import UtilityCore
@testable import ImportExport

@MainActor
@Suite("IncomingShareCoordinator")
struct IncomingShareCoordinatorTests {
    // MARK: - Test fixtures

    final class FakeImporter: ScoreFileImporter, @unchecked Sendable {
        var prepared: [URL] = []
        var committed: [(ImportPlan, ImportDecision)] = []
        var duplicateMap: [String: ScoreItem] = [:]      // filename suffix -> existing item
        var prepareError: Error?
        var commitError: Error?

        func prepareImport(sourceURL: URL) async throws -> ImportPlan {
            if let prepareError { throw prepareError }
            prepared.append(sourceURL)
            let filename = sourceURL.lastPathComponent
            let duplicate = duplicateMap[filename]
            return ImportPlan(
                sourceURL: sourceURL,
                stagedURL: sourceURL,
                format: .mscz,
                summary: ScoreFileSummary(title: filename, partCount: 1, measureCount: 1),
                contentHash: filename,
                sizeBytes: 1,
                duplicates: duplicate.map { [$0] } ?? [],
            )
        }

        func commitImport(_ plan: ImportPlan, decision: ImportDecision) async throws -> ScoreItem {
            if let commitError { throw commitError }
            committed.append((plan, decision))
            if case let .openExisting(id) = decision, let existing = duplicateMap[plan.sourceURL.lastPathComponent], existing.id == id {
                return existing
            }
            return ScoreItem(
                id: ScoreItemID(),
                title: plan.summary.title,
                composers: [],
                tags: [],
                createdAt: .now,
                updatedAt: .now,
                contentHash: plan.contentHash,
                format: .mscz,
                sizeBytes: 1,
                durationSeconds: nil,
                lastOpenedAt: nil,
            )
        }
    }

    final class FakeRepository: ScoreLibraryRepository, @unchecked Sendable {
        var scoreItems: [ScoreItem] = []
        var tags: [Domain.Tag] = []
        var playlists: [Playlist] = []
        var savedPlaylists: [Playlist] = []
        var savedScoreItems: [ScoreItem] = []
        var prefs: [ScoreItemID: ReaderPreferences] = [:]

        func refresh() async throws {}
        func saveScoreItem(_ item: ScoreItem) async throws { savedScoreItems.append(item); scoreItems.append(item) }
        func deleteScoreItem(id: ScoreItemID) async throws { scoreItems.removeAll { $0.id == id } }
        func saveTag(_ tag: Domain.Tag) async throws {}
        func deleteTag(id: TagID) async throws {}
        func savePlaylist(_ playlist: Playlist) async throws {
            savedPlaylists.append(playlist)
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
        func loadReaderPreferences(for scoreItemID: ScoreItemID) async throws -> ReaderPreferences? {
            prefs[scoreItemID]
        }
        func saveReaderPreferences(_ preferences: ReaderPreferences) async throws {
            prefs[preferences.scoreItemID] = preferences
        }
    }

    struct FixedClock: Clock {
        let date: Date
        func now() -> Date { date }
    }

    // MARK: - Helpers

    func makeContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "share-coord-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func stageToken(
        _ container: URL,
        token: UUID,
        playlistID: PlaylistID? = nil,
        newPlaylistName: String? = nil,
        openAfter: Bool = false,
        filenames: [String],
        createdAt: Date = .now,
    ) throws {
        let filesURL = AppGroupPaths.tokenFilesURL(token: token, in: container)
        try FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
        var files: [IncomingShareIntent.File] = []
        for name in filenames {
            let dest = filesURL.appending(path: name, directoryHint: .notDirectory)
            try Data("dummy".utf8).write(to: dest)
            files.append(.init(relativePath: "files/\(name)", originalName: name))
        }
        let intent = IncomingShareIntent(
            schemaVersion: 1,
            token: token,
            createdAt: createdAt,
            playlistID: playlistID,
            newPlaylistName: newPlaylistName,
            openAfter: openAfter,
            files: files,
        )
        let data = try JSONEncoder().encode(intent)
        try data.write(to: AppGroupPaths.tokenIntentURL(token: token, in: container))
    }

    // MARK: - Tests

    @Test func librarOnlySingleFile() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let importer = FakeImporter()
        let repo = FakeRepository()
        let coordinator = IncomingShareCoordinator(
            importer: importer,
            repository: repo,
            appGroupContainer: container,
            clock: FixedClock(date: .now),
        )
        let token = UUID()
        try stageToken(container, token: token, filenames: ["one.mscz"])

        let result = await coordinator.drain(token: token)

        #expect(result.imported.count == 1)
        #expect(result.skipped.isEmpty)
        #expect(result.targetPlaylistID == nil)
        #expect(result.createdPlaylistID == nil)
        #expect(result.openAfter == nil)
        #expect(repo.savedPlaylists.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: AppGroupPaths.tokenURL(token: token, in: container).path))
    }

    @Test func multipleFilesAppendedToExistingPlaylist() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let importer = FakeImporter()
        let repo = FakeRepository()
        let existing = Playlist(name: "Practice", orderedScoreItemIDs: [], createdAt: .now)
        repo.playlists = [existing]
        let coordinator = IncomingShareCoordinator(
            importer: importer,
            repository: repo,
            appGroupContainer: container,
            clock: FixedClock(date: .now),
        )
        let token = UUID()
        try stageToken(container, token: token, playlistID: existing.id, openAfter: true, filenames: ["a.mscz", "b.mscz"])

        let result = await coordinator.drain(token: token)

        #expect(result.imported.count == 2)
        #expect(result.targetPlaylistID == existing.id)
        #expect(result.targetPlaylistName == "Practice")
        #expect(result.openAfter == result.imported.last)
        // The playlist should be saved with ordered IDs matching the two imports.
        let lastSaved = repo.savedPlaylists.last
        #expect(lastSaved?.orderedScoreItemIDs.count == 2)
        #expect(lastSaved?.orderedScoreItemIDs == result.imported)
    }

    @Test func newPlaylistCreatedThenItemsAppended() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let importer = FakeImporter()
        let repo = FakeRepository()
        let coordinator = IncomingShareCoordinator(
            importer: importer,
            repository: repo,
            appGroupContainer: container,
            clock: FixedClock(date: .now),
        )
        let token = UUID()
        try stageToken(container, token: token, newPlaylistName: "Brand new", filenames: ["a.mscz"])

        let result = await coordinator.drain(token: token)

        #expect(result.imported.count == 1)
        #expect(result.createdPlaylistID != nil)
        #expect(result.targetPlaylistName == "Brand new")
        #expect(repo.savedPlaylists.count >= 1)
        #expect(repo.savedPlaylists.first?.name == "Brand new")
    }

    @Test func duplicateIsSilentlyResolvedToExistingItem() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let importer = FakeImporter()
        let repo = FakeRepository()
        let existing = ScoreItem(
            id: ScoreItemID(), title: "Existing", composers: [], tags: [],
            createdAt: .now, updatedAt: .now, contentHash: "dup.mscz",
            format: .mscz, sizeBytes: 1, durationSeconds: nil, lastOpenedAt: nil,
        )
        repo.scoreItems = [existing]
        importer.duplicateMap = ["dup.mscz": existing]
        let coordinator = IncomingShareCoordinator(
            importer: importer,
            repository: repo,
            appGroupContainer: container,
            clock: FixedClock(date: .now),
        )
        let token = UUID()
        try stageToken(container, token: token, openAfter: true, filenames: ["dup.mscz"])

        let result = await coordinator.drain(token: token)

        #expect(result.imported.isEmpty)
        #expect(result.skipped.count == 1)
        if case let .duplicate(existingID, _) = result.skipped[0].reason {
            #expect(existingID == existing.id)
        } else {
            Issue.record("expected duplicate reason")
        }
        #expect(result.openAfter == existing.id)
    }

    @Test func parseFailureSurfacesAsSkip() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let importer = FakeImporter()
        importer.prepareError = NSError(domain: "Test", code: 1)
        let repo = FakeRepository()
        let coordinator = IncomingShareCoordinator(
            importer: importer,
            repository: repo,
            appGroupContainer: container,
            clock: FixedClock(date: .now),
        )
        let token = UUID()
        try stageToken(container, token: token, filenames: ["bad.mscz"])

        let result = await coordinator.drain(token: token)

        #expect(result.imported.isEmpty)
        #expect(result.skipped.count == 1)
        if case .parseFailed = result.skipped[0].reason { } else {
            Issue.record("expected parseFailed")
        }
    }

    @Test func drainOnLaunchProcessesAllTokensInOrder() async throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let importer = FakeImporter()
        let repo = FakeRepository()
        let coordinator = IncomingShareCoordinator(
            importer: importer,
            repository: repo,
            appGroupContainer: container,
            clock: FixedClock(date: .now),
        )
        let earlierToken = UUID()
        let laterToken = UUID()
        try stageToken(
            container, token: laterToken,
            filenames: ["later.mscz"],
            createdAt: Date(timeIntervalSince1970: 2_000),
        )
        try stageToken(
            container, token: earlierToken,
            filenames: ["earlier.mscz"],
            createdAt: Date(timeIntervalSince1970: 1_000),
        )

        let result = await coordinator.drain(token: nil)

        // Earlier-staged token should be processed first; the public DrainResult
        // returns the last completed token, but we can verify both directories
        // are gone.
        #expect(importer.committed.count == 2)
        #expect(importer.committed[0].0.sourceURL.lastPathComponent == "earlier.mscz")
        #expect(importer.committed[1].0.sourceURL.lastPathComponent == "later.mscz")
        #expect(!FileManager.default.fileExists(atPath: AppGroupPaths.tokenURL(token: earlierToken, in: container).path))
        #expect(!FileManager.default.fileExists(atPath: AppGroupPaths.tokenURL(token: laterToken, in: container).path))
        _ = result
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport && swift test --filter IncomingShareCoordinatorTests
```

Expected: build error.

- [ ] **Step 3: Write the coordinator**

```swift
// Sources/ImportExport/IncomingShareCoordinator.swift
import Domain
import Foundation
import ImportExportAppGroup
import UtilityCore
import os

@MainActor
public final class IncomingShareCoordinator {
    private let importer: any ScoreFileImporter
    private let repository: any ScoreLibraryRepository
    private let appGroupContainer: URL
    private let clock: any Clock
    private let logger = Logger(subsystem: "com.KeyNumber.Folino", category: "IncomingShareCoordinator")
    private var inFlight: Task<DrainResult, Never>?

    public init(
        importer: any ScoreFileImporter,
        repository: any ScoreLibraryRepository,
        appGroupContainer: URL,
        clock: any Clock,
    ) {
        self.importer = importer
        self.repository = repository
        self.appGroupContainer = appGroupContainer
        self.clock = clock
    }

    public func drain(token: UUID?) async -> DrainResult {
        if let inFlight {
            _ = await inFlight.value
        }
        let task = Task<DrainResult, Never> { @MainActor in
            await self.performDrain(token: token)
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private func performDrain(token: UUID?) async -> DrainResult {
        if let token {
            return await drainOne(token: token)
        }
        return await drainAll()
    }

    private func drainAll() async -> DrainResult {
        let incomingDir = AppGroupPaths.incomingImportsURL(in: appGroupContainer)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: incomingDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
        ) else {
            return .empty
        }
        // Read all intents, sort by createdAt ascending, drain in order.
        var pairs: [(UUID, Date)] = []
        for entry in entries {
            guard let token = UUID(uuidString: entry.lastPathComponent) else { continue }
            let intentURL = AppGroupPaths.tokenIntentURL(token: token, in: appGroupContainer)
            if let data = try? Data(contentsOf: intentURL),
               let intent = try? JSONDecoder().decode(IncomingShareIntent.self, from: data) {
                pairs.append((token, intent.createdAt))
            } else {
                // Corrupt token: scrub.
                try? FileManager.default.removeItem(at: entry)
            }
        }
        pairs.sort { $0.1 < $1.1 }
        var last: DrainResult = .empty
        for (token, _) in pairs {
            last = await drainOne(token: token)
        }
        return last
    }

    private func drainOne(token: UUID) async -> DrainResult {
        let intentURL = AppGroupPaths.tokenIntentURL(token: token, in: appGroupContainer)
        let tokenURL = AppGroupPaths.tokenURL(token: token, in: appGroupContainer)
        guard let data = try? Data(contentsOf: intentURL),
              let intent = try? JSONDecoder().decode(IncomingShareIntent.self, from: data) else {
            logger.error("intent.json missing/corrupt; scrubbing token \(token.uuidString)")
            try? FileManager.default.removeItem(at: tokenURL)
            return .empty
        }

        // Step 1: resolve target playlist (existing or newly created).
        var targetPlaylist: Playlist?
        var createdPlaylistID: PlaylistID?
        if let existingID = intent.playlistID,
           let existing = repository.playlists.first(where: { $0.id == existingID }) {
            targetPlaylist = existing
        } else if let newName = intent.newPlaylistName, !newName.isEmpty {
            let playlist = Playlist(
                name: newName,
                orderedScoreItemIDs: [],
                createdAt: clock.now(),
            )
            do {
                try await repository.savePlaylist(playlist)
                targetPlaylist = playlist
                createdPlaylistID = playlist.id
            } catch {
                logger.error("failed to create new playlist: \(String(describing: error))")
                // Preserve token for retry.
                return DrainResult(
                    imported: [], skipped: intent.files.map {
                        Skip(originalName: $0.originalName, reason: .persistenceFailed(error))
                    },
                    openAfter: nil,
                    createdPlaylistID: nil,
                    targetPlaylistID: nil,
                    targetPlaylistName: newName,
                )
            }
        }

        // Step 2: process each file.
        var imported: [ScoreItemID] = []
        var skipped: [Skip] = []
        var lastOpenedID: ScoreItemID?

        for file in intent.files {
            let sourceURL = AppGroupPaths.tokenFilesURL(token: token, in: appGroupContainer)
                .appending(path: file.originalName, directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                skipped.append(.init(originalName: file.originalName, reason: .unreadable(
                    NSError(domain: "ImportExport", code: -1, userInfo: [NSLocalizedDescriptionKey: "missing staged file"]),
                )))
                continue
            }
            do {
                let plan = try await importer.prepareImport(sourceURL: sourceURL)
                if let dup = plan.duplicates.first {
                    // Silent dedupe: surface as skip, keep the existing item as openAfter target.
                    skipped.append(.init(
                        originalName: file.originalName,
                        reason: .duplicate(existingID: dup.id, existingTitle: dup.title),
                    ))
                    lastOpenedID = dup.id
                    // Still call commitImport with openExisting so the importer can record activity if desired,
                    // but ignore the returned item for the "imported" list.
                    _ = try? await importer.commitImport(plan, decision: .openExisting(dup.id))
                } else {
                    let item = try await importer.commitImport(plan, decision: .importAsNew)
                    imported.append(item.id)
                    lastOpenedID = item.id
                }
            } catch {
                skipped.append(.init(originalName: file.originalName, reason: .parseFailed(error)))
            }
        }

        // Step 3: update playlist membership if applicable.
        if var playlist = targetPlaylist, !imported.isEmpty {
            playlist.orderedScoreItemIDs.append(contentsOf: imported)
            do {
                try await repository.savePlaylist(playlist)
                targetPlaylist = playlist
            } catch {
                logger.error("failed to update playlist with imports: \(String(describing: error))")
            }
        }

        // Step 4: clean up token dir.
        try? FileManager.default.removeItem(at: tokenURL)

        return DrainResult(
            imported: imported,
            skipped: skipped,
            openAfter: intent.openAfter ? lastOpenedID : nil,
            createdPlaylistID: createdPlaylistID,
            targetPlaylistID: targetPlaylist?.id,
            targetPlaylistName: targetPlaylist?.name,
        )
    }
}
```

- [ ] **Step 4: Run tests**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport && swift test --filter IncomingShareCoordinatorTests
```

Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Features/ImportExport
git commit -m "Add IncomingShareCoordinator drain logic"
```

---

## Task 10: ShareSession (extension service)

**Files:**
- Create: `Packages/Features/ImportExport/Sources/ImportExportShareUI/ShareDecision.swift`
- Create: `Packages/Features/ImportExport/Sources/ImportExportShareUI/ShareSession.swift`
- Create: `Packages/Features/ImportExport/Tests/ImportExportShareUITests/ShareSessionTests.swift`
- Delete: `Packages/Features/ImportExport/Sources/ImportExportShareUI/_Module.swift`
- Delete: `Packages/Features/ImportExport/Tests/ImportExportShareUITests/_Module.swift`

- [ ] **Step 1: Write the decision types**

```swift
// Sources/ImportExportShareUI/ShareDecision.swift
import Domain
import Foundation
import ImportExportAppGroup

public enum PlaylistChoice: Sendable, Equatable {
    case libraryOnly
    case existing(PlaylistID)
    case createNew(name: String)
}

public enum ShareDecision: Sendable, Equatable {
    case save(PlaylistChoice)
    case saveAndOpen(PlaylistChoice)

    public var openAfter: Bool {
        if case .saveAndOpen = self { return true }
        return false
    }

    public var choice: PlaylistChoice {
        switch self {
        case let .save(c), let .saveAndOpen(c): return c
        }
    }
}

public struct IngestSummary: Sendable {
    public let token: UUID
    public let acceptedFiles: [IncomingShareIntent.File]
    public let unsupportedCount: Int

    public init(token: UUID, acceptedFiles: [IncomingShareIntent.File], unsupportedCount: Int) {
        self.token = token
        self.acceptedFiles = acceptedFiles
        self.unsupportedCount = unsupportedCount
    }
}
```

- [ ] **Step 2: Write the failing test**

```swift
// Tests/ImportExportShareUITests/ShareSessionTests.swift
import Domain
import Foundation
import ImportExportAppGroup
import Testing
import UtilityCore
@testable import ImportExportShareUI

@MainActor
@Suite("ShareSession")
struct ShareSessionTests {
    struct FixedClock: Clock {
        let date: Date
        func now() -> Date { date }
    }

    func makeContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "share-session-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func loadPlaylistsReturnsEmptyWhenIndexMissing() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let session = ShareSession(appGroupContainer: container, clock: FixedClock(date: .now))
        #expect(session.loadPlaylists().isEmpty)
    }

    @Test func loadPlaylistsReadsExistingIndex() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let entries = [
            PlaylistsIndex.Entry(id: PlaylistID(), name: "A"),
            PlaylistsIndex.Entry(id: PlaylistID(), name: "B"),
        ]
        let index = PlaylistsIndex(schemaVersion: 1, playlists: entries)
        let data = try JSONEncoder().encode(index)
        try data.write(to: AppGroupPaths.playlistsIndexURL(in: container))

        let session = ShareSession(appGroupContainer: container, clock: FixedClock(date: .now))
        #expect(session.loadPlaylists().map(\.name) == ["A", "B"])
    }

    @Test func finalizeWritesIntentForLibraryOnlySave() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let session = ShareSession(appGroupContainer: container, clock: FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000)))
        let token = UUID()
        // Stage a fake file under files/ so finalize doesn't error.
        let filesURL = AppGroupPaths.tokenFilesURL(token: token, in: container)
        try FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: filesURL.appending(path: "a.mscz"))

        let url = try session.finalize(
            token: token,
            files: [.init(relativePath: "files/a.mscz", originalName: "a.mscz")],
            decision: .save(.libraryOnly),
        )

        #expect(url.scheme == "folino")
        let intentData = try Data(contentsOf: AppGroupPaths.tokenIntentURL(token: token, in: container))
        let intent = try JSONDecoder().decode(IncomingShareIntent.self, from: intentData)
        #expect(intent.token == token)
        #expect(intent.openAfter == false)
        #expect(intent.playlistID == nil)
        #expect(intent.newPlaylistName == nil)
    }

    @Test func finalizeWritesIntentForSaveAndOpenWithNewPlaylist() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let session = ShareSession(appGroupContainer: container, clock: FixedClock(date: .now))
        let token = UUID()
        let filesURL = AppGroupPaths.tokenFilesURL(token: token, in: container)
        try FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: filesURL.appending(path: "a.mscz"))

        _ = try session.finalize(
            token: token,
            files: [.init(relativePath: "files/a.mscz", originalName: "a.mscz")],
            decision: .saveAndOpen(.createNew(name: "Brand new")),
        )

        let intentData = try Data(contentsOf: AppGroupPaths.tokenIntentURL(token: token, in: container))
        let intent = try JSONDecoder().decode(IncomingShareIntent.self, from: intentData)
        #expect(intent.openAfter == true)
        #expect(intent.newPlaylistName == "Brand new")
        #expect(intent.playlistID == nil)
    }

    @Test func discardRemovesTokenDirectory() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let session = ShareSession(appGroupContainer: container, clock: FixedClock(date: .now))
        let token = UUID()
        let filesURL = AppGroupPaths.tokenFilesURL(token: token, in: container)
        try FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: filesURL.appending(path: "a.mscz"))

        session.discard(token: token)

        #expect(!FileManager.default.fileExists(atPath: AppGroupPaths.tokenURL(token: token, in: container).path))
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport && swift test --filter ShareSessionTests
```

Expected: build error.

- [ ] **Step 4: Write the session**

```swift
// Sources/ImportExportShareUI/ShareSession.swift
import Domain
import Foundation
import ImportExportAppGroup
import UniformTypeIdentifiers
import UtilityCore
import UIKit
import os

@MainActor
public final class ShareSession {
    private let appGroupContainer: URL
    private let clock: any Clock
    private let logger = Logger(subsystem: "com.KeyNumber.Folino", category: "ShareSession")

    public init(appGroupContainer: URL, clock: any Clock) {
        self.appGroupContainer = appGroupContainer
        self.clock = clock
    }

    public func loadPlaylists() -> [PlaylistsIndex.Entry] {
        let url = AppGroupPaths.playlistsIndexURL(in: appGroupContainer)
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(PlaylistsIndex.self, from: data) else {
            return []
        }
        return index.playlists
    }

    /// Copies `NSItemProvider` items into the App Group container under `token/files/`.
    public func ingest(items: [NSItemProvider], token: UUID) async -> IngestSummary {
        let filesURL = AppGroupPaths.tokenFilesURL(token: token, in: appGroupContainer)
        try? FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)

        var accepted: [IncomingShareIntent.File] = []
        var unsupported = 0

        for provider in items {
            let supportedTypes = [
                "org.musescore.mscz",
                "org.musescore.mscx",
                "com.recordare.musicxml",
                "com.recordare.musicxml.zipped",
                "public.midi-audio",
            ]
            let matched = supportedTypes.first { provider.hasItemConformingToTypeIdentifier($0) }
            guard let matched else {
                unsupported += 1
                continue
            }
            do {
                let url = try await loadFileRepresentation(provider: provider, typeIdentifier: matched)
                let name = url.lastPathComponent
                let dest = filesURL.appending(path: name, directoryHint: .notDirectory)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                accepted.append(.init(relativePath: "files/\(name)", originalName: name))
            } catch {
                logger.error("ingest failure: \(String(describing: error))")
                unsupported += 1
            }
        }

        return IngestSummary(token: token, acceptedFiles: accepted, unsupportedCount: unsupported)
    }

    public func finalize(
        token: UUID,
        files: [IncomingShareIntent.File],
        decision: ShareDecision,
    ) throws -> URL {
        let (playlistID, newPlaylistName) = decisionToFields(decision.choice)
        let intent = IncomingShareIntent(
            schemaVersion: 1,
            token: token,
            createdAt: clock.now(),
            playlistID: playlistID,
            newPlaylistName: newPlaylistName,
            openAfter: decision.openAfter,
            files: files,
        )
        let data = try JSONEncoder().encode(intent)
        let dest = AppGroupPaths.tokenIntentURL(token: token, in: appGroupContainer)
        let tmp = dest.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
        return ShareTokenURLBuilder.build(token: token, openAfter: decision.openAfter)
    }

    public func discard(token: UUID) {
        try? FileManager.default.removeItem(at: AppGroupPaths.tokenURL(token: token, in: appGroupContainer))
    }

    // MARK: - Helpers

    private func decisionToFields(_ choice: PlaylistChoice) -> (PlaylistID?, String?) {
        switch choice {
        case .libraryOnly: return (nil, nil)
        case let .existing(id): return (id, nil)
        case let .createNew(name): return (nil, name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func loadFileRepresentation(
        provider: NSItemProvider,
        typeIdentifier: String,
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let url {
                    // Copy out of the auto-deleted temp before the closure returns.
                    do {
                        let dst = FileManager.default.temporaryDirectory
                            .appending(path: "share-\(UUID().uuidString)-\(url.lastPathComponent)")
                        if FileManager.default.fileExists(atPath: dst.path) {
                            try FileManager.default.removeItem(at: dst)
                        }
                        try FileManager.default.copyItem(at: url, to: dst)
                        cont.resume(returning: dst)
                    } catch {
                        cont.resume(throwing: error)
                    }
                } else {
                    cont.resume(throwing: NSError(domain: "ShareSession", code: -1))
                }
            }
        }
    }
}

// `ShareTokenURL.build` lives in the `ImportExport` library; ImportExportShareUI
// would have to depend on ImportExport for that one symbol. To keep the
// dependency direction clean (ShareUI ↛ ImportExport main-app code), the
// extension-side build path is duplicated as a tiny mirror.
private enum ShareTokenURLBuilder {
    static func build(token: UUID, openAfter: Bool) -> URL {
        var c = URLComponents()
        c.scheme = "folino"
        c.host = "import"
        c.queryItems = [
            URLQueryItem(name: "token", value: token.uuidString),
            URLQueryItem(name: "open", value: openAfter ? "true" : "false"),
        ]
        return c.url!
    }
}
```

- [ ] **Step 5: Delete markers, run tests**

```bash
rm -f /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport/Sources/ImportExportShareUI/_Module.swift
rm -f /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport/Tests/ImportExportShareUITests/_Module.swift
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport && swift test --filter ShareSessionTests
```

Expected: 5 tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Features/ImportExport
git commit -m "Add ShareSession service for share extension"
```

---

## Task 11: Share UI subviews (file summary, playlist picker, action footer)

**Files:**
- Create: `Packages/Features/ImportExport/Sources/ImportExportShareUI/FileSummary.swift`
- Create: `Packages/Features/ImportExport/Sources/ImportExportShareUI/PlaylistPicker.swift`
- Create: `Packages/Features/ImportExport/Sources/ImportExportShareUI/ActionButtons.swift`

These views are exercised through SwiftUI previews + the root view test in Task 12. No standalone unit tests.

- [ ] **Step 1: FileSummary**

```swift
// Sources/ImportExportShareUI/FileSummary.swift
import ImportExportAppGroup
import SwiftUI

struct FileSummary: View {
    let files: [IncomingShareIntent.File]
    let unsupportedCount: Int
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headlineKey(), bundle: .module)
                .font(.headline)
            if !files.isEmpty {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .imageScale(.small)
                        Text(expanded ? "share_extension.summary.hide_files" : "share_extension.summary.show_files", bundle: .module)
                            .font(.subheadline)
                    }
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(files, id: \.relativePath) { file in
                            Text(file.originalName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.leading, 12)
                }
            }
            if unsupportedCount > 0 {
                Label {
                    Text("share_extension.summary.unsupported_warning_\(unsupportedCount)", bundle: .module)
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.orange)
            }
        }
    }

    private func headlineKey() -> LocalizedStringResource {
        if files.count == 1 {
            return LocalizedStringResource("share_extension.summary.one_score", bundle: .atURL(Bundle.module.bundleURL))
        }
        return LocalizedStringResource(
            "share_extension.summary.n_scores_\(files.count)",
            bundle: .atURL(Bundle.module.bundleURL),
        )
    }
}
```

- [ ] **Step 2: PlaylistPicker**

```swift
// Sources/ImportExportShareUI/PlaylistPicker.swift
import Domain
import ImportExportAppGroup
import SwiftUI

struct PlaylistPicker: View {
    let entries: [PlaylistsIndex.Entry]
    @Binding var selection: PlaylistChoice
    @State private var newName = ""
    @State private var creatingNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("share_extension.picker.title", bundle: .module)
                .font(.headline)
            VStack(spacing: 0) {
                row(label: Text("share_extension.picker.library_only", bundle: .module),
                    isSelected: selection == .libraryOnly,
                    action: { selection = .libraryOnly })
                ForEach(entries) { entry in
                    Divider().padding(.leading, 32)
                    row(label: Text(entry.name),
                        isSelected: selection == .existing(entry.id),
                        action: { selection = .existing(entry.id) })
                }
                Divider().padding(.leading, 32)
                if creatingNew {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                        TextField("share_extension.picker.new_playlist_placeholder", text: $newName)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .onChange(of: newName) { _, value in
                                if value.trimmingCharacters(in: .whitespaces).isEmpty {
                                    selection = .libraryOnly
                                } else {
                                    selection = .createNew(name: value)
                                }
                            }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                } else {
                    Button {
                        creatingNew = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle")
                            Text("share_extension.picker.new_playlist", bundle: .module)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func row(label: Text, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? .tint : .secondary)
                label
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 3: ActionButtons**

```swift
// Sources/ImportExportShareUI/ActionButtons.swift
import SwiftUI

struct ActionButtons: View {
    let disabled: Bool
    let onSave: () -> Void
    let onSaveAndOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSave) {
                Text("share_extension.action.save", bundle: .module)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .disabled(disabled)

            Button(action: onSaveAndOpen) {
                Text("share_extension.action.save_and_open", bundle: .module)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(disabled)
        }
    }
}
```

- [ ] **Step 4: Build verify**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport && swift build --target ImportExportShareUI
```

Expected: builds (string keys may emit warnings until xcstrings exists; that's fine for now).

- [ ] **Step 5: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Features/ImportExport
git commit -m "Add share extension subviews (summary, picker, actions)"
```

---

## Task 12: ShareRootView (SwiftUI root)

**Files:**
- Create: `Packages/Features/ImportExport/Sources/ImportExportShareUI/ShareRootView.swift`

- [ ] **Step 1: Write the root view**

```swift
// Sources/ImportExportShareUI/ShareRootView.swift
import Domain
import ImportExportAppGroup
import SwiftUI

public struct ShareCompletion: Sendable {
    public let outcome: Outcome

    public enum Outcome: Sendable {
        case cancelled
        case submitted(openURL: URL)
    }
}

public struct ShareRootView: View {
    @State private var summary: IngestSummary?
    @State private var playlists: [PlaylistsIndex.Entry] = []
    @State private var selection: PlaylistChoice = .libraryOnly
    @State private var isFinalizing = false
    @State private var fatalError: String?

    private let session: ShareSession
    private let items: [NSItemProvider]
    private let onComplete: (ShareCompletion) -> Void
    private let token = UUID()

    public init(
        session: ShareSession,
        items: [NSItemProvider],
        onComplete: @escaping (ShareCompletion) -> Void,
    ) {
        self.session = session
        self.items = items
        self.onComplete = onComplete
    }

    public var body: some View {
        NavigationStack {
            content
                .padding(20)
                .navigationTitle(Text("share_extension.title", bundle: .module))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            session.discard(token: token)
                            onComplete(.init(outcome: .cancelled))
                        } label: {
                            Text("share_extension.cancel", bundle: .module)
                        }
                    }
                }
                .task {
                    let result = await session.ingest(items: items, token: token)
                    summary = result
                    playlists = session.loadPlaylists()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let fatalError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(fatalError).multilineTextAlignment(.center)
            }
        } else if let summary {
            VStack(alignment: .leading, spacing: 20) {
                FileSummary(files: summary.acceptedFiles, unsupportedCount: summary.unsupportedCount)
                if summary.acceptedFiles.isEmpty {
                    Text("share_extension.no_supported_files", bundle: .module)
                        .foregroundStyle(.secondary)
                } else {
                    PlaylistPicker(entries: playlists, selection: $selection)
                }
                Spacer(minLength: 0)
                ActionButtons(
                    disabled: summary.acceptedFiles.isEmpty || isFinalizing,
                    onSave: { finalize(decision: .save(selection)) },
                    onSaveAndOpen: { finalize(decision: .saveAndOpen(selection)) },
                )
            }
        } else {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("share_extension.loading", bundle: .module)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func finalize(decision: ShareDecision) {
        guard let summary else { return }
        isFinalizing = true
        do {
            let url = try session.finalize(
                token: token,
                files: summary.acceptedFiles,
                decision: decision,
            )
            onComplete(.init(outcome: .submitted(openURL: url)))
        } catch {
            isFinalizing = false
            fatalError = String(describing: error)
        }
    }
}

#Preview("Empty playlists") {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "share-preview-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return ShareRootView(
        session: ShareSession(appGroupContainer: tmp, clock: SystemClock()),
        items: [],
        onComplete: { _ in },
    )
}
```

Note: `SystemClock` here assumes `UtilityCore` provides one. If not, replace with a struct conforming to `Clock` returning `.now`.

- [ ] **Step 2: Build verify**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport && swift build --target ImportExportShareUI
```

Expected: builds.

- [ ] **Step 3: Render preview via Xcode MCP (visual sanity check)**

Use `mcp__xcode__RenderPreview` against `ShareRootView.swift` and inspect the rendered PNG. Verify the title bar, picker, and footer all show. Iterate via Edit + re-render if needed.

- [ ] **Step 4: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Features/ImportExport
git commit -m "Add ShareRootView for share extension"
```

---

## Task 13: ShareExtension localization bundle (xcstrings)

**Files:**
- Create: `Packages/Features/ImportExport/Sources/ImportExportShareUI/Resources/ShareExtension.xcstrings`
- Modify: `Packages/Features/ImportExport/Package.swift` (add resources to `ImportExportShareUI` target)

- [ ] **Step 1: Add resources path to Package.swift**

Edit the `ImportExportShareUI` target to include a resources directory:

```swift
.target(
    name: "ImportExportShareUI",
    dependencies: [
        "ImportExportAppGroup",
        "Domain",
        .product(name: "UtilityCore", package: "Utility"),
        .product(name: "UtilityUI", package: "Utility"),
    ],
    resources: [.process("Resources")],
    plugins: swiftLintPlugins,
),
```

- [ ] **Step 2: Create the xcstrings file**

```bash
mkdir -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport/Sources/ImportExportShareUI/Resources
```

Create `ShareExtension.xcstrings` with the minimum keys needed (en source strings; localizers fill the others later):

```json
{
  "sourceLanguage" : "en",
  "strings" : {
    "share_extension.action.save" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Save" } }
      }
    },
    "share_extension.action.save_and_open" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Save & Open" } }
      }
    },
    "share_extension.cancel" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Cancel" } }
      }
    },
    "share_extension.loading" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Preparing…" } }
      }
    },
    "share_extension.no_supported_files" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "No supported scores were shared." } }
      }
    },
    "share_extension.picker.library_only" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Library only" } }
      }
    },
    "share_extension.picker.new_playlist" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "New playlist…" } }
      }
    },
    "share_extension.picker.new_playlist_placeholder" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Playlist name" } }
      }
    },
    "share_extension.picker.title" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Add to playlist" } }
      }
    },
    "share_extension.summary.hide_files" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Hide files" } }
      }
    },
    "share_extension.summary.n_scores_%lld" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "variations" : {
            "plural" : {
              "one" : { "stringUnit" : { "state" : "translated", "value" : "%lld score" } },
              "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld scores" } }
            }
          }
        }
      }
    },
    "share_extension.summary.one_score" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "1 score" } }
      }
    },
    "share_extension.summary.show_files" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Show files" } }
      }
    },
    "share_extension.summary.unsupported_warning_%lld" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "variations" : {
            "plural" : {
              "one" : { "stringUnit" : { "state" : "translated", "value" : "%lld unsupported file will be skipped" } },
              "other" : { "stringUnit" : { "state" : "translated", "value" : "%lld unsupported files will be skipped" } }
            }
          }
        }
      }
    },
    "share_extension.title" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Folino" } }
      }
    }
  },
  "version" : "1.0"
}
```

- [ ] **Step 3: Build verify**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/ImportExport && swift build --target ImportExportShareUI
```

Expected: builds without resource warnings.

- [ ] **Step 4: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Features/ImportExport
git commit -m "Add ShareExtension.xcstrings localization"
```

---

## Task 14: Wire PlaylistsIndexPublisher into LiveScoreLibraryRepository

**Files:**
- Modify: `Packages/Infrastructure/Sources/Persistence/LiveScoreLibraryRepository.swift`

- [ ] **Step 1: Add the publisher parameter**

Modify the class:

```swift
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
    private let playlistsIndexPublisher: (any PlaylistsIndexPublisher)?
    @ObservationIgnored
    private var observationTask: Task<Void, Never>?

    public init(
        database: AppDatabase,
        scoresDirectory: URL,
        playlistsIndexPublisher: (any PlaylistsIndexPublisher)? = nil,
    ) {
        self.database = database
        self.scoresDirectory = scoresDirectory
        self.playlistsIndexPublisher = playlistsIndexPublisher
    }
    // … rest unchanged …
```

- [ ] **Step 2: Add publish calls after savePlaylist / deletePlaylist**

In `savePlaylist`:

```swift
public func savePlaylist(_ playlist: Playlist) async throws {
    do {
        try await database.pool.write { db in
            try PlaylistRecord(domain: playlist).save(db)
            try PlaylistItemRecord
                .filter(Column("playlist_id") == playlist.id.rawValue.uuidString)
                .deleteAll(db)
            for (position, scoreItemID) in playlist.orderedScoreItemIDs.enumerated() {
                try PlaylistItemRecord(
                    playlistID: playlist.id.rawValue.uuidString,
                    scoreItemID: scoreItemID.rawValue.uuidString,
                    position: position,
                ).insert(db)
            }
        }
        await publishPlaylistsIndexIfNeeded()
    } catch {
        throw DomainError.persistenceFailed(reason: "\(error)")
    }
}

public func deletePlaylist(id: PlaylistID) async throws {
    do {
        try await database.pool.write { db in
            _ = try PlaylistRecord.deleteOne(db, key: id.rawValue.uuidString)
        }
        await publishPlaylistsIndexIfNeeded()
    } catch {
        throw DomainError.persistenceFailed(reason: "\(error)")
    }
}

private func publishPlaylistsIndexIfNeeded() async {
    guard let publisher = playlistsIndexPublisher else { return }
    await publisher.publish(playlists: playlists)
}
```

- [ ] **Step 3: Build the package**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Infrastructure && swift build --target Persistence
```

Expected: builds (the new init parameter has a default, so existing call sites still compile).

- [ ] **Step 4: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Infrastructure
git commit -m "Wire PlaylistsIndexPublisher into LiveScoreLibraryRepository"
```

---

## Task 15: AppBootstrap — share token routing + coordinator wiring

**Files:**
- Modify: `App/AppBootstrap.swift`

- [ ] **Step 1: Add ImportExport import + new properties**

```swift
import Audio
import AVFoundation
import Domain
import Foundation
import ImportExport
import ImportExportAppGroup
import Observation
import Persistence
import ScoreFiles
import Soundfonts
```

Inside the class, add stored properties:

```swift
@MainActor
@Observable
final class AppBootstrap {
    // … existing fields …
    private(set) var incomingShareCoordinator: IncomingShareCoordinator?

    /// Single-slot for an incoming share token. Last-wins.
    private(set) var pendingShareToken: UUID?
    private(set) var pendingShareOpenAfter: Bool = false

    // … existing fields …
}
```

- [ ] **Step 2: Construct coordinator + writer in start()**

In the `start()` method, after `importer` is constructed and before `Task { repository.refresh }`:

```swift
let appGroupContainer = AppGroupPaths.container()
let playlistsIndexPublisher: PlaylistsIndexWriter?
let incomingShareCoordinator: IncomingShareCoordinator?
if let appGroupContainer {
    let writer = PlaylistsIndexWriter(appGroupContainer: appGroupContainer)
    playlistsIndexPublisher = writer
    incomingShareCoordinator = IncomingShareCoordinator(
        importer: importer,
        repository: repository,
        appGroupContainer: appGroupContainer,
        clock: SystemClock(),
    )
} else {
    playlistsIndexPublisher = nil
    incomingShareCoordinator = nil
}
self.incomingShareCoordinator = incomingShareCoordinator
```

Then change the `LiveScoreLibraryRepository` construction to pass the publisher:

```swift
let repository = LiveScoreLibraryRepository(
    database: database,
    scoresDirectory: AppPaths.scoresDirectory,
    playlistsIndexPublisher: playlistsIndexPublisher,
)
```

(Note: this requires moving the repository construction after the App Group resolution. If your file structure differs, adjust order.)

- [ ] **Step 3: Route incoming URL**

Replace `acceptIncomingURL`:

```swift
func acceptIncomingURL(_ url: URL) {
    if let parsed = ShareTokenURL.parse(url) {
        pendingShareToken = parsed.token
        pendingShareOpenAfter = parsed.openAfter
        return
    }
    pendingIncomingURL = url
}

func consumePendingShareToken() -> (UUID, Bool)? {
    guard let token = pendingShareToken else { return nil }
    let pair = (token, pendingShareOpenAfter)
    pendingShareToken = nil
    pendingShareOpenAfter = false
    return pair
}
```

- [ ] **Step 4: Drain-on-launch hook**

After `repository.refresh()` succeeds inside the existing `Task`:

```swift
Task { [weak self] in
    do {
        try await repository.refresh()
        await writer?.publish(playlists: repository.playlists)
        await self?.incomingShareCoordinator?.drain(token: nil)
        self?.isReady = true
    } catch {
        self?.failure = error
    }
}
```

(Where `writer` is the local `let writer = PlaylistsIndexWriter(...)` from Step 2. If `appGroupContainer` is nil, skip the publish/drain — the optional chaining handles it.)

- [ ] **Step 5: Build verify**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS && xcodegen generate
```

Then in Xcode (or via `mcp__xcode__BuildProject`) build the Folino target.

Expected: build succeeds. (`ImportExport` is now a real product, so the existing `dependencies: ImportExport` line in project.yml resolves.)

- [ ] **Step 6: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add App/AppBootstrap.swift
git commit -m "Wire share-extension coordinator + index writer into AppBootstrap"
```

---

## Task 16: AppShellView — drain consumer and result handling

**Files:**
- Modify: `App/AppShellView.swift`

- [ ] **Step 1: Add ImportExport import at top**

```swift
import Domain
import ImportExport
import Library
import LicenseList
import Reader
import Settings
import StoreKit
import SwiftUI
import UtilityUI
```

- [ ] **Step 2: Add a banner state to ReadyShell**

```swift
private struct ReadyShell: View {
    // … existing fields …
    @State private var lastDrainResult: DrainResult?
    @State private var drainBannerMessage: String?
    // … existing init …
}
```

- [ ] **Step 3: Add drain task observers in ReadyShell.body**

After existing `.onChange(of: bootstrap.pendingIncomingURL)` modifier, add:

```swift
.task {
    // Cold launch: drain a token queued before the view appeared.
    if let (_, openAfter) = bootstrap.consumePendingShareToken(),
       let coordinator = bootstrap.incomingShareCoordinator {
        await runDrain(coordinator: coordinator, openAfter: openAfter)
    }
}
.onChange(of: bootstrap.pendingShareToken) { _, newValue in
    guard newValue != nil,
          let (_, openAfter) = bootstrap.consumePendingShareToken(),
          let coordinator = bootstrap.incomingShareCoordinator else { return }
    Task { await runDrain(coordinator: coordinator, openAfter: openAfter) }
}
```

- [ ] **Step 4: Add helper method**

```swift
@MainActor
private func runDrain(coordinator: IncomingShareCoordinator, openAfter: Bool) async {
    let result = await coordinator.drain(token: nil)
    lastDrainResult = result
    // Banner copy
    if !result.imported.isEmpty {
        let target = result.targetPlaylistName ?? "Library"
        drainBannerMessage = "\(result.imported.count) added to \(target)"
    } else if let dup = result.skipped.first, case let .duplicate(_, title) = dup.reason {
        drainBannerMessage = "Already in Library: \(title)"
    } else if let first = result.skipped.first {
        drainBannerMessage = "Couldn't import: \(first.originalName)"
    }
    // Reader push
    if openAfter, let openID = result.openAfter,
       let item = repository.scoreItems.first(where: { $0.id == openID }) {
        if horizontalSizeClass == .regular {
            sidebarPath = NavigationPath()
            detailScoreItem = item
            columnVisibility = .detailOnly
        } else {
            compactPath = NavigationPath()
            compactPath.append(item)
        }
    }
}
```

- [ ] **Step 5: Banner overlay**

In `ReadyShell.body`, alongside the existing `overlay { ... ImportLoadingHUD() }`, add:

```swift
.overlay(alignment: .top) {
    if let message = drainBannerMessage {
        DrainBannerView(message: message)
            .task {
                try? await Task.sleep(for: .seconds(2.5))
                drainBannerMessage = nil
            }
    }
}
.animation(.easeInOut(duration: 0.2), value: drainBannerMessage)
```

Add the view at the bottom of the file:

```swift
private struct DrainBannerView: View {
    let message: String
    var body: some View {
        Text(message)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 12)
            .shadow(radius: 4)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
```

- [ ] **Step 6: Build verify**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS && xcodegen generate
```

Then build via `mcp__xcode__BuildProject` for Folino target. Expected: builds.

- [ ] **Step 7: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add App/AppShellView.swift
git commit -m "Drain incoming share tokens in ReadyShell"
```

---

## Task 17: Add App Groups entitlement to main app

**Files:**
- Modify: `App/Folino.entitlements`

- [ ] **Step 1: Add App Groups key**

Replace the file contents:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudKit</string>
    </array>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.KeyNumber.Folino</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add App/Folino.entitlements
git commit -m "Add App Groups entitlement to main app"
```

> Manual step (does not affect plan progress): the developer must enable the App Group `group.com.KeyNumber.Folino` in the Apple Developer portal and ensure it appears in the provisioning profile for `com.KeyNumber.Folino`. With Automatic signing, Xcode usually adds this on first build.

---

## Task 18: Add CFBundleURLTypes for `folino://`

**Files:**
- Modify: `App/Info.plist`

- [ ] **Step 1: Add URL types entry**

Insert this dict into the top-level `<dict>` (after `ITSAppUsesNonExemptEncryption`, before `LSRequiresIPhoneOS`):

```xml
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>CFBundleURLName</key>
            <string>com.KeyNumber.Folino.share</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>folino</string>
            </array>
        </dict>
    </array>
```

- [ ] **Step 2: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add App/Info.plist
git commit -m "Register folino:// URL scheme for share-extension handoff"
```

---

## Task 19: Create Share Extension target files

**Files:**
- Create: `App/ShareExtension/Info.plist`
- Create: `App/ShareExtension/FolinoShareExtension.entitlements`
- Create: `App/ShareExtension/ShareViewController.swift`

- [ ] **Step 1: Extension Info.plist**

```bash
mkdir -p /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/App/ShareExtension
```

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>$(DEVELOPMENT_LANGUAGE)</string>
    <key>CFBundleDisplayName</key>
    <string>Folino</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>NSExtensionActivationRule</key>
            <dict>
                <key>NSExtensionActivationSupportsFileWithMaxCount</key>
                <integer>10</integer>
            </dict>
        </dict>
        <key>NSExtensionMainStoryboard</key>
        <string></string>
        <key>NSExtensionPrincipalClass</key>
        <string>$(PRODUCT_MODULE_NAME).ShareViewController</string>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.share-services</string>
    </dict>
</dict>
</plist>
```

Note: a predicate-based activation rule restricted to the score UTIs is the
ideal, but iOS share-sheet predicate filtering with custom UTIs has
historical edge cases. Starting with `NSExtensionActivationSupportsFileWithMaxCount = 10`
gives a broad accept-any-file activation that we then filter inside
`ShareSession.ingest` (which only accepts conforming UTIs). This is a
pragmatic v1 choice; tighten later via predicate format if needed.

- [ ] **Step 2: Entitlements**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.KeyNumber.Folino</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 3: ShareViewController**

```swift
// App/ShareExtension/ShareViewController.swift
import ImportExportAppGroup
import ImportExportShareUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UtilityCore

final class ShareViewController: UIViewController {
    private var hostingController: UIHostingController<ShareRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        guard let container = AppGroupPaths.container() else {
            presentFatalError("App Group container unavailable.")
            return
        }

        let session = ShareSession(appGroupContainer: container, clock: SystemClock())
        let items = collectItemProviders()

        let root = ShareRootView(session: session, items: items) { [weak self] completion in
            self?.handleCompletion(completion)
        }

        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        hostingController = host
    }

    private func collectItemProviders() -> [NSItemProvider] {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            return []
        }
        return extensionItems.flatMap { $0.attachments ?? [] }
    }

    private func handleCompletion(_ completion: ShareCompletion) {
        switch completion.outcome {
        case .cancelled:
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        case let .submitted(openURL):
            extensionContext?.completeRequest(returningItems: nil) { _ in
                self.openMainApp(url: openURL)
            }
        }
    }

    /// Walks the responder chain to find a `UIApplication` and invokes its
    /// `open(_:options:completionHandler:)`. Best-effort: if the chain doesn't
    /// reach a `UIApplication` (locked-down extension contexts on future iOS),
    /// the drain-on-launch fallback in the main app still picks up the token.
    private func openMainApp(url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }

    private func presentFatalError(_ message: String) {
        let alert = UIAlertController(title: "Folino", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        })
        present(alert, animated: true)
    }
}
```

- [ ] **Step 4: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add App/ShareExtension
git commit -m "Add FolinoShareExtension target files"
```

---

## Task 20: Register Share Extension target in project.yml

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Add the target**

After the `Folino` target block, before `FolinoTests`, insert:

```yaml
  FolinoShareExtension:
    type: app-extension
    platform: iOS
    sources:
      - path: App/ShareExtension
        excludes:
          - Info.plist
          - FolinoShareExtension.entitlements
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.KeyNumber.Folino.ShareExtension
        PRODUCT_NAME: FolinoShareExtension
        INFOPLIST_FILE: App/ShareExtension/Info.plist
        CODE_SIGN_ENTITLEMENTS: App/ShareExtension/FolinoShareExtension.entitlements
        GENERATE_INFOPLIST_FILE: NO
        SKIP_INSTALL: YES
        TARGETED_DEVICE_FAMILY: 1,2
    dependencies:
      - package: ImportExport
        products: [ImportExportAppGroup, ImportExportShareUI]
      - package: Domain
      - package: Utility
        products: [UtilityCore]
```

- [ ] **Step 2: Embed the extension in the main Folino target**

In the `Folino` target's `dependencies` array, add at the end:

```yaml
      - target: FolinoShareExtension
        embed: true
```

Also update the main `Folino` target's package dependency on `ImportExport` to include the new products explicitly. Replace `- package: ImportExport` with:

```yaml
      - package: ImportExport
        products: [ImportExport, ImportExportAppGroup]
```

- [ ] **Step 3: Regenerate + build**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS && xcodegen generate
```

Build via `mcp__xcode__BuildProject` for both `Folino` and `FolinoShareExtension`. Expected: both succeed.

- [ ] **Step 4: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add project.yml
git commit -m "Add FolinoShareExtension target to project.yml"
```

---

## Task 21: Manual smoke test

**No code changes.** Verify end-to-end behavior on a simulator.

- [ ] **Step 1: Build, install, and launch on simulator**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build
```

Then install + launch via `xcrun simctl` or via Xcode Run.

- [ ] **Step 2: Create at least one playlist in main app**

Open Folino, go to the Library tab → Playlists → create `Smoke test`. Force-quit Folino.

- [ ] **Step 3: Share a single `.mscz` from Files**

Open Files, long-press a `.mscz` → Share → tap Folino. Verify:
- The Share Extension UI renders within ~1 s.
- File summary shows `1 score` with the correct filename.
- Picker shows `Library only`, `Smoke test`, and `+ New playlist…`.
- Tap `Smoke test`, then `Save & Open`.

Verify: Folino opens, HUD shows briefly, then Reader opens with the shared score. Library `Smoke test` now contains the score.

- [ ] **Step 4: Share multiple files**

In Files, select 2–3 `.mscz` files → Share → Folino. Verify summary shows `N scores` (correct count). `Save` (no open) → verify HUD shows briefly, banner reads `<N> added to Library`, Reader does not auto-open.

- [ ] **Step 5: New-playlist inline create**

Share another score → tap `+ New playlist…` → type `From share` → tap `Save & Open`. Verify Folino opens, Reader opens, and the Library now has a `From share` playlist with the score.

- [ ] **Step 6: Cancel**

Share a score → tap `Cancel`. Verify the host app returns to foreground and nothing was added to Library.

- [ ] **Step 7: Duplicate**

Share the same file twice (second time after the first import). The second share should silently dedupe — banner: `Already in Library: <title>`. Library count unchanged.

- [ ] **Step 8: Drain-on-launch fallback** (best-effort)

Force-quit Folino, share a score, then **kill Folino again immediately** before the URL scheme would normally launch it. Cold-launch Folino manually. Verify drain-on-launch processes the staged token.

- [ ] **Step 9: Mark task complete; no commit (manual verification)**

---

## Self-Review Notes

**Spec coverage check:**

- ImportExportAppGroup product → Tasks 1–4 ✓
- ImportExport (main-app) product → Tasks 6–9 ✓
- ImportExportShareUI product → Tasks 10–13 ✓
- Domain.PlaylistsIndexPublisher → Task 5 ✓
- LiveScoreLibraryRepository wiring → Task 14 ✓
- AppBootstrap routing + drain hook → Task 15 ✓
- AppShellView drain consumer + HUD/banner → Task 16 ✓
- App Group entitlement (main) → Task 17 ✓
- folino:// URL scheme registration → Task 18 ✓
- Share Extension target files (Info.plist, entitlements, ShareViewController) → Task 19 ✓
- project.yml extension target + embed → Task 20 ✓
- Manual smoke (drain-on-launch fallback, dedupe, multi-file) → Task 21 ✓

**Things deliberately not in tasks:**

- App Group registration in Apple Developer portal → mentioned as manual prerequisite in Task 17.
- ShareTokenURL.build is duplicated as a private helper in `ShareSession.swift` to avoid `ImportExportShareUI` depending on `ImportExport` (main-app product). Acceptable for this small surface; if more cross-product symbols are needed later, lift them into `ImportExportAppGroup`.
- The `DrainResult` banner copy in Task 16 is hard-coded English. Per spec, real localization keys land alongside the rest of `App/Resources` later; the spec calls this out as v1 polish.

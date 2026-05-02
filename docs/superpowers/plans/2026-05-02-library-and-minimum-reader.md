# Library + Minimum Reader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the first end-to-end interactive surface of Folino — hierarchical Library, minimum Reader, Settings stub with License screen, and import flow with duplicate detection — wired into the existing AppBootstrap.

**Architecture:** Pure SwiftUI Feature packages (`Library`, `Reader`, `Settings`) consume Domain protocols via constructor injection. Plan #3's `LiveScoreLibraryRepository`, `LiveScoreFileGateway`, and `LiveScoreFileImporter` are wired into Library/Reader at the App composition root. Reader composes `SheetMusicUI.ScoreView` directly (an explicit carve-out from the "Features → swift-sheet-music forbidden" rule, documented in `module-architecture.md`).

**Tech Stack:** Swift 6.3, iOS 26+, SwiftUI, `@Observable`, Swift Testing, GRDB-backed `LiveScoreLibraryRepository` (Plan #3), `SheetMusicUI` (`swift-sheet-music`), `cybozu/LicenseList`.

---

## Context for the Implementer

The spec is `docs/superpowers/specs/2026-05-02-library-and-minimum-reader-design.md`. Read sections 1–3 (Goal / Architectural Position / Information Architecture) before starting Task 1. The remaining sections are referenced inline by individual tasks.

Plan #3 (already merged) provides:

- `Domain.ScoreLibraryRepository` — `@MainActor` `Observable` protocol with observed properties `scoreItems: [ScoreItem]`, `tags: [Tag]`, `playlists: [Playlist]` and CRUD methods.
- `Domain.ScoreFileGateway` — async `loadFileMetadata(fileURL:)` / `loadScore(fileURL:)`. Save is stubbed.
- `Domain.ScoreFileImporter` — two-stage `prepareImport(sourceURL:) -> ImportPlan` then `commitImport(_:decision:) -> ScoreItem`, with `ImportDecision = .importAsNew | .openExisting(ScoreItemID)`.
- `Persistence.AppDatabase`, `Persistence.LiveScoreLibraryRepository`, `Persistence.LiveScoreFileImporter`, `ScoreFiles.LiveScoreFileGateway`.
- `App/AppBootstrap.swift` instantiates these and exposes them as `@Observable` properties (`bootstrap.repository`, `bootstrap.gateway`, `bootstrap.importer`).

This plan does not change Domain protocols; it only adds value-type helpers (Task 1).

### Branch and worktree setup (do this once before Task 1)

```bash
# From repo root, on main, working tree clean.
git fetch origin
git switch main
git pull --ff-only

# Create the execution branch off main.
git switch -c feat/library-and-minimum-reader

# (Optional) work in a worktree to keep main free for parallel review.
# git worktree add ../Folino-iOS-library feat/library-and-minimum-reader
# cd ../Folino-iOS-library
```

When the plan is complete and merged, follow `superpowers:finishing-a-development-branch` to merge `feat/library-and-minimum-reader` back into `main`.

### File map

This plan touches these locations (specific files listed per task):

```
Packages/Domain/
  Sources/Domain/
    ScoreItemRootSections.swift            (new, Task 1)
  Tests/DomainTests/
    ScoreItemRootSectionsTests.swift       (new, Task 1)

Packages/Features/Library/
  Sources/Library/
    Library.swift                          (replaces Placeholder.swift, Task 2)
    LibraryRootView.swift                  (new, Task 2 stub → Task 15 final)
    LibraryViewModel.swift                 (new, Task 2 stub → Tasks 16/17/18)
    ScoreListViewModel.swift               (new, Task 5)
    ScoreItemSort.swift                    (new, Task 4)
    ScoreRow.swift                         (new, Task 6)
    ScoreListView.swift                    (new, Tasks 7/8)
    EditTagsSheet.swift                    (new, Task 9)
    AddToPlaylistSheet.swift               (new, Task 10)
    TagsListView.swift                     (new, Task 11)
    TagDetailView.swift                    (new, Task 12)
    PlaylistsListView.swift                (new, Task 13)
    PlaylistDetailView.swift               (new, Task 14)
    Resources/Localizable.xcstrings        (new, Task 24)
  Tests/LibraryTests/
    Fakes/FakeScoreLibraryRepository.swift (new, Task 3)
    Fakes/FakeScoreFileImporter.swift      (new, Task 3)
    Fakes/FakeScoreFileGateway.swift       (new, Task 3)
    ScoreItemSortTests.swift               (new, Task 4)
    ScoreListViewModelTests.swift          (new, Task 5)
    LibraryViewModelTests.swift            (new, Tasks 16/17/18)

Packages/Features/Reader/
  Package.swift                            (modify, Task 19)
  Sources/Reader/
    Reader.swift                           (replaces Placeholder.swift, Task 19)
    ReaderViewModel.swift                  (new, Task 20)
    ReaderView.swift                       (new, Tasks 20/21)
    Resources/Localizable.xcstrings        (new, Task 24)
  Tests/ReaderTests/
    Fakes/FakeScoreFileGateway.swift       (new, Task 20 — separate copy from Library's)
    Fakes/FakeScoreLibraryRepository.swift (new, Task 20)
    ReaderViewModelTests.swift             (new, Tasks 20/21)

Packages/Features/Settings/
  Sources/Settings/
    Settings.swift                         (replaces Placeholder.swift, Task 22)
    SettingsSheet.swift                    (new, Task 22)
    Resources/Localizable.xcstrings        (new, Task 24)
  Tests/SettingsTests/
    SettingsSheetTests.swift               (new, Task 22)

App/
  AppShellView.swift                       (rewrite, Task 23)

docs/engineering/
  module-architecture.md                   (modify, Task 19)
```

### Test discipline

- **Swift Testing only** (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`).
- **Whole-file staging only** — never `git add -p`. The pre-commit hook will reformat and re-stage; commits with partial staging corrupt the split (see `CLAUDE.md`).
- **Run package tests in isolation** via `cd Packages/Features/<Name> && swift test --filter <SuiteName>`.
- **Run the full app build** with `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`. Run this at the end of each phase, not after every task.
- **SwiftUI views are not unit-tested.** Use `#Preview` blocks; visual verification via `mcp__xcode__RenderPreview` or simulator runs (Task 25). The CLAUDE.md preview-first rule applies.

### Convention: error wrapping

The plan calls `repository.saveScoreItem(_:)`, `deleteScoreItem(id:)`, etc. These can throw `DomainError.persistenceFailed(reason:)`. Library code wraps such throws in user-facing alerts at the `LibraryViewModel` level only — individual views call VM methods that don't throw.

---

## Phase A — Domain helpers

### Task 1: Add `mostRecentlyOpened` and `favorites` Array helpers on `ScoreItem`

**Files:**
- Create: `Packages/Domain/Sources/Domain/ScoreItemRootSections.swift`
- Test: `Packages/Domain/Tests/DomainTests/ScoreItemRootSectionsTests.swift`

These helpers power the Library root's "Favorites" and "Recently Opened" sections (spec §Information Architecture).

- [ ] **Step 1: Write the failing test**

Create `Packages/Domain/Tests/DomainTests/ScoreItemRootSectionsTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

@Suite struct ScoreItemRootSectionsTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(
        title: String,
        addedAtOffset: TimeInterval,
        lastOpenedOffset: TimeInterval?,
        isFavorite: Bool = false
    ) -> ScoreItem {
        ScoreItem(
            title: title,
            composer: nil,
            instrumentationSummary: nil,
            localFileName: "\(title).mscx",
            contentHash: title,
            sizeBytes: 0,
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: base.addingTimeInterval(addedAtOffset),
            lastOpenedAt: lastOpenedOffset.map { base.addingTimeInterval($0) },
            tagIDs: [],
            isFavorite: isFavorite
        )
    }

    @Test func mostRecentlyOpenedExcludesNilAndOrdersDesc() {
        let items: [ScoreItem] = [
            Self.makeItem(title: "A", addedAtOffset: 0, lastOpenedOffset: 100),
            Self.makeItem(title: "B", addedAtOffset: 0, lastOpenedOffset: nil),
            Self.makeItem(title: "C", addedAtOffset: 0, lastOpenedOffset: 300),
            Self.makeItem(title: "D", addedAtOffset: 0, lastOpenedOffset: 200),
        ]
        let result = items.mostRecentlyOpened(limit: 5)
        #expect(result.map(\.title) == ["C", "D", "A"])
    }

    @Test func mostRecentlyOpenedRespectsLimit() {
        let items: [ScoreItem] = [
            Self.makeItem(title: "A", addedAtOffset: 0, lastOpenedOffset: 100),
            Self.makeItem(title: "B", addedAtOffset: 0, lastOpenedOffset: 200),
            Self.makeItem(title: "C", addedAtOffset: 0, lastOpenedOffset: 300),
        ]
        #expect(items.mostRecentlyOpened(limit: 2).map(\.title) == ["C", "B"])
    }

    @Test func favoritesFiltersAndSortsByAddedAtDesc() {
        let items: [ScoreItem] = [
            Self.makeItem(title: "A", addedAtOffset: 100, lastOpenedOffset: nil, isFavorite: true),
            Self.makeItem(title: "B", addedAtOffset: 200, lastOpenedOffset: nil, isFavorite: false),
            Self.makeItem(title: "C", addedAtOffset: 300, lastOpenedOffset: nil, isFavorite: true),
            Self.makeItem(title: "D", addedAtOffset: 50, lastOpenedOffset: nil, isFavorite: true),
        ]
        let result = items.favorites(limit: 5)
        #expect(result.map(\.title) == ["C", "A", "D"])
    }

    @Test func favoritesRespectsLimit() {
        let items: [ScoreItem] = [
            Self.makeItem(title: "A", addedAtOffset: 100, lastOpenedOffset: nil, isFavorite: true),
            Self.makeItem(title: "B", addedAtOffset: 200, lastOpenedOffset: nil, isFavorite: true),
            Self.makeItem(title: "C", addedAtOffset: 300, lastOpenedOffset: nil, isFavorite: true),
        ]
        #expect(items.favorites(limit: 2).map(\.title) == ["C", "B"])
    }

    @Test func emptyInputReturnsEmpty() {
        let items: [ScoreItem] = []
        #expect(items.mostRecentlyOpened(limit: 5).isEmpty)
        #expect(items.favorites(limit: 5).isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/Domain && swift test --filter ScoreItemRootSectionsTests`
Expected: compile error — `mostRecentlyOpened` / `favorites` not defined.

- [ ] **Step 3: Implement the helpers**

Create `Packages/Domain/Sources/Domain/ScoreItemRootSections.swift`:

```swift
import Foundation

public extension Array where Element == ScoreItem {
    /// Top items by `lastOpenedAt` desc. Items with `nil` lastOpenedAt are
    /// excluded entirely (they have never been opened).
    func mostRecentlyOpened(limit: Int) -> [ScoreItem] {
        guard limit > 0 else { return [] }
        return self
            .compactMap { item -> (ScoreItem, Date)? in
                guard let lastOpenedAt = item.lastOpenedAt else { return nil }
                return (item, lastOpenedAt)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Favorited items only, ordered by `addedAt` desc, capped at `limit`.
    func favorites(limit: Int) -> [ScoreItem] {
        guard limit > 0 else { return [] }
        return self
            .filter(\.isFavorite)
            .sorted { $0.addedAt > $1.addedAt }
            .prefix(limit)
            .map { $0 }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/Domain && swift test --filter ScoreItemRootSectionsTests`
Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/ScoreItemRootSections.swift \
        Packages/Domain/Tests/DomainTests/ScoreItemRootSectionsTests.swift
git commit -m "feat(domain): add ScoreItem array helpers for Library root sections"
```

---

## Phase B — Library scaffolding

### Task 2: Replace Library Placeholder with module export and stubs

**Files:**
- Delete: `Packages/Features/Library/Sources/Library/Placeholder.swift`
- Create: `Packages/Features/Library/Sources/Library/Library.swift`
- Create: `Packages/Features/Library/Sources/Library/LibraryRootView.swift`
- Create: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`

These are scaffolding stubs. They define the `LibraryRootView` public init that App will call from Task 23, and `LibraryViewModel` shape that Tasks 16–18 will fill in. Compiling against them lets later tasks proceed.

- [ ] **Step 1: Delete Placeholder.swift**

```bash
rm Packages/Features/Library/Sources/Library/Placeholder.swift
```

- [ ] **Step 2: Create the module export marker**

Create `Packages/Features/Library/Sources/Library/Library.swift`:

```swift
/// Module marker — referenced by smoke tests in App-level builds. The Library
/// module's real surface lives in `LibraryRootView`.
public enum LibraryModule {
    public static var isLinked: Bool { true }
}
```

- [ ] **Step 3: Create the LibraryViewModel stub**

Create `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`:

```swift
import Domain
import Foundation
import Observation

/// Top-level view model for the Library screen. Owns import state (file picker,
/// duplicate alert, error alert) and the most-recently-imported `ScoreItem`
/// that the view should auto-push into the Reader. Per-list sort/search state
/// lives in `ScoreListViewModel` (one per list view).
@MainActor
@Observable
public final class LibraryViewModel {
    public let repository: any ScoreLibraryRepository
    public let importer: any ScoreFileImporter
    public let gateway: any ScoreFileGateway

    public init(
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway
    ) {
        self.repository = repository
        self.importer = importer
        self.gateway = gateway
    }
}
```

- [ ] **Step 4: Create the LibraryRootView stub**

Create `Packages/Features/Library/Sources/Library/LibraryRootView.swift`:

```swift
import Domain
import SwiftUI

/// Public entry point for the Library feature. Composes the hierarchical
/// Library IA (Favorites / Browse / Recently Opened) inside a NavigationStack
/// or NavigationSplitView depending on size class. App passes the live
/// adapters (Plan #3) plus a closure that materialises the License view.
@MainActor
public struct LibraryRootView<LicenseContent: View>: View {
    @State private var viewModel: LibraryViewModel
    private let onOpenScore: (ScoreItem) -> Void
    private let licenseContent: () -> LicenseContent

    public init(
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway,
        onOpenScore: @escaping (ScoreItem) -> Void,
        @ViewBuilder licenseContent: @escaping () -> LicenseContent
    ) {
        _viewModel = State(
            wrappedValue: LibraryViewModel(
                repository: repository, importer: importer, gateway: gateway
            )
        )
        self.onOpenScore = onOpenScore
        self.licenseContent = licenseContent
    }

    public var body: some View {
        // Filled in by Task 15.
        Text("Library")
            .navigationTitle("Library")
    }
}
```

- [ ] **Step 5: Build the package**

Run: `cd Packages/Features/Library && swift build`
Expected: builds clean.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Library/Sources/Library/
git commit -m "scaffold(library): module export + LibraryRootView/LibraryViewModel stubs"
```

---

### Task 3: Test fakes (`FakeScoreLibraryRepository`, `FakeScoreFileImporter`, `FakeScoreFileGateway`)

**Files:**
- Create: `Packages/Features/Library/Tests/LibraryTests/Fakes/FakeScoreLibraryRepository.swift`
- Create: `Packages/Features/Library/Tests/LibraryTests/Fakes/FakeScoreFileImporter.swift`
- Create: `Packages/Features/Library/Tests/LibraryTests/Fakes/FakeScoreFileGateway.swift`

Hand-written fakes used by all Library tests. Each fake conforms to its Domain protocol; mutations to the fake's state are visible to the Library code through the protocol surface.

- [ ] **Step 1: Create FakeScoreLibraryRepository**

Create `Packages/Features/Library/Tests/LibraryTests/Fakes/FakeScoreLibraryRepository.swift`:

```swift
import Domain
import Foundation
import Observation

@MainActor
@Observable
final class FakeScoreLibraryRepository: ScoreLibraryRepository {
    var scoreItems: [ScoreItem] = []
    var tags: [Tag] = []
    var playlists: [Playlist] = []

    var savedScoreItems: [ScoreItem] = []
    var deletedScoreItemIDs: [ScoreItemID] = []
    var savedTags: [Tag] = []
    var deletedTagIDs: [TagID] = []
    var savedPlaylists: [Playlist] = []
    var deletedPlaylistIDs: [PlaylistID] = []
    var refreshCount = 0

    /// If non-nil, `saveScoreItem(_:)` throws this error instead of saving.
    var saveScoreItemError: DomainError?
    /// If non-nil, `deleteScoreItem(id:)` throws this error.
    var deleteScoreItemError: DomainError?

    func refresh() async throws {
        refreshCount += 1
    }

    func saveScoreItem(_ item: ScoreItem) async throws {
        if let error = saveScoreItemError { throw error }
        savedScoreItems.append(item)
        if let idx = scoreItems.firstIndex(where: { $0.id == item.id }) {
            scoreItems[idx] = item
        } else {
            scoreItems.append(item)
        }
    }

    func deleteScoreItem(id: ScoreItemID) async throws {
        if let error = deleteScoreItemError { throw error }
        deletedScoreItemIDs.append(id)
        scoreItems.removeAll { $0.id == id }
    }

    func saveTag(_ tag: Tag) async throws {
        savedTags.append(tag)
        if let idx = tags.firstIndex(where: { $0.id == tag.id }) {
            tags[idx] = tag
        } else {
            tags.append(tag)
        }
    }

    func deleteTag(id: TagID) async throws {
        deletedTagIDs.append(id)
        tags.removeAll { $0.id == id }
        for idx in scoreItems.indices {
            scoreItems[idx].tagIDs.remove(id)
        }
    }

    func savePlaylist(_ playlist: Playlist) async throws {
        savedPlaylists.append(playlist)
        if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[idx] = playlist
        } else {
            playlists.append(playlist)
        }
    }

    func deletePlaylist(id: PlaylistID) async throws {
        deletedPlaylistIDs.append(id)
        playlists.removeAll { $0.id == id }
    }

    func scoreItems(matchingContentHash contentHash: String) async throws -> [ScoreItem] {
        scoreItems.filter { $0.contentHash == contentHash }
    }
}
```

- [ ] **Step 2: Create FakeScoreFileImporter**

Create `Packages/Features/Library/Tests/LibraryTests/Fakes/FakeScoreFileImporter.swift`:

```swift
import Domain
import Foundation

final class FakeScoreFileImporter: ScoreFileImporter, @unchecked Sendable {
    /// Plans queued to be returned by `prepareImport`. Consumed FIFO.
    var preparedPlans: [ImportPlan] = []
    /// Errors queued to be thrown by `prepareImport`. Consumed FIFO; if both
    /// `preparedPlans` and `prepareImportErrors` are non-empty, errors take
    /// precedence on the same call.
    var prepareImportErrors: [DomainError] = []

    /// `commitImport` returns this `ScoreItem` factory invoked with the plan
    /// and decision; tests can capture the call by reading `committed`.
    var commitFactory: (@Sendable (ImportPlan, ImportDecision) -> ScoreItem)?
    var commitImportError: DomainError?

    private(set) var preparedSourceURLs: [URL] = []
    private(set) var committed: [(plan: ImportPlan, decision: ImportDecision)] = []

    func prepareImport(sourceURL: URL) async throws -> ImportPlan {
        preparedSourceURLs.append(sourceURL)
        if !prepareImportErrors.isEmpty {
            throw prepareImportErrors.removeFirst()
        }
        guard !preparedPlans.isEmpty else {
            throw DomainError.scoreParseFailed(reason: "FakeScoreFileImporter: no plan queued")
        }
        return preparedPlans.removeFirst()
    }

    func commitImport(_ plan: ImportPlan, decision: ImportDecision) async throws -> ScoreItem {
        if let error = commitImportError { throw error }
        committed.append((plan: plan, decision: decision))
        guard let commitFactory else {
            throw DomainError.persistenceFailed(reason: "FakeScoreFileImporter: no commitFactory set")
        }
        return commitFactory(plan, decision)
    }
}
```

- [ ] **Step 3: Create FakeScoreFileGateway**

Create `Packages/Features/Library/Tests/LibraryTests/Fakes/FakeScoreFileGateway.swift`:

```swift
import Domain
import Foundation

final class FakeScoreFileGateway: ScoreFileGateway, @unchecked Sendable {
    var detectedFormat: ScoreFormat? = .mscx
    var loadFileMetadataResult: Result<ScoreFileSummary, DomainError> =
        .success(ScoreFileSummary(
            title: "Untitled", composer: nil, instrumentationSummary: "",
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
        ))
    var loadScoreError: DomainError?

    func detectFormat(fileName: String) -> ScoreFormat? { detectedFormat }

    func loadFileMetadata(fileURL: URL) async throws -> ScoreFileSummary {
        switch loadFileMetadataResult {
        case let .success(summary): summary
        case let .failure(error): throw error
        }
    }

    func loadScore(fileURL: URL) async throws -> (score: Score, summary: ScoreFileSummary) {
        if let error = loadScoreError { throw error }
        // Library tests do not exercise loaded Scores; provide an empty stub.
        // ScoreFileGateway is async but the fake satisfies both sync and async
        // shapes. Real Score values are exercised by Reader tests via a
        // separate fake (Task 20).
        throw DomainError.scoreParseFailed(reason: "FakeScoreFileGateway.loadScore stubbed")
    }

    func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) async throws {
        throw DomainError.unsupportedFormat(format.canonicalExtension)
    }
}
```

- [ ] **Step 4: Build the test target**

Run: `cd Packages/Features/Library && swift build --target LibraryTests`
Expected: builds clean (no tests run yet — there are no tests against these fakes alone).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Tests/LibraryTests/Fakes/
git commit -m "test(library): add Domain protocol fakes for repository, importer, gateway"
```

---

### Task 4: `ScoreItemSort` comparators

**Files:**
- Create: `Packages/Features/Library/Sources/Library/ScoreItemSort.swift`
- Test: `Packages/Features/Library/Tests/LibraryTests/ScoreItemSortTests.swift`

`ScoreItemSort` is a small enum used by every score-list view (All / Tag-filtered / Playlist). It provides four comparators per the spec: `dateAddedDesc`, `titleAsc`, `composerAsc`, `lastOpenedDesc`. Title and composer use locale-aware diacritic-insensitive comparison.

- [ ] **Step 1: Write the failing tests**

Create `Packages/Features/Library/Tests/LibraryTests/ScoreItemSortTests.swift`:

```swift
import Domain
import Foundation
import Testing
@testable import Library

@Suite struct ScoreItemSortTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(
        title: String,
        composer: String?,
        addedOffset: TimeInterval,
        lastOpenedOffset: TimeInterval?
    ) -> ScoreItem {
        ScoreItem(
            title: title, composer: composer, instrumentationSummary: nil,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: base.addingTimeInterval(addedOffset),
            lastOpenedAt: lastOpenedOffset.map { base.addingTimeInterval($0) },
            tagIDs: [], isFavorite: false
        )
    }

    @Test func dateAddedDescOrdersNewestFirst() {
        let items: [ScoreItem] = [
            Self.makeItem(title: "A", composer: nil, addedOffset: 100, lastOpenedOffset: nil),
            Self.makeItem(title: "B", composer: nil, addedOffset: 300, lastOpenedOffset: nil),
            Self.makeItem(title: "C", composer: nil, addedOffset: 200, lastOpenedOffset: nil),
        ]
        let sorted = ScoreItemSort.dateAddedDesc.apply(to: items)
        #expect(sorted.map(\.title) == ["B", "C", "A"])
    }

    @Test func titleAscIsLocaleAwareAndDiacriticInsensitive() {
        let items: [ScoreItem] = [
            Self.makeItem(title: "Étude", composer: nil, addedOffset: 0, lastOpenedOffset: nil),
            Self.makeItem(title: "Adagio", composer: nil, addedOffset: 0, lastOpenedOffset: nil),
            Self.makeItem(title: "etude", composer: nil, addedOffset: 0, lastOpenedOffset: nil),
            Self.makeItem(title: "Bagatelle", composer: nil, addedOffset: 0, lastOpenedOffset: nil),
        ]
        let sorted = ScoreItemSort.titleAsc.apply(to: items)
        #expect(sorted.map(\.title) == ["Adagio", "Bagatelle", "etude", "Étude"]
            || sorted.map(\.title) == ["Adagio", "Bagatelle", "Étude", "etude"])
    }

    @Test func composerAscPlacesNilAtEnd() {
        let items: [ScoreItem] = [
            Self.makeItem(title: "A", composer: "Mozart", addedOffset: 0, lastOpenedOffset: nil),
            Self.makeItem(title: "B", composer: nil, addedOffset: 0, lastOpenedOffset: nil),
            Self.makeItem(title: "C", composer: "Beethoven", addedOffset: 0, lastOpenedOffset: nil),
        ]
        let sorted = ScoreItemSort.composerAsc.apply(to: items)
        #expect(sorted.map(\.composer) == ["Beethoven", "Mozart", nil])
    }

    @Test func lastOpenedDescPlacesNilAtEnd() {
        let items: [ScoreItem] = [
            Self.makeItem(title: "A", composer: nil, addedOffset: 0, lastOpenedOffset: 100),
            Self.makeItem(title: "B", composer: nil, addedOffset: 0, lastOpenedOffset: nil),
            Self.makeItem(title: "C", composer: nil, addedOffset: 0, lastOpenedOffset: 300),
        ]
        let sorted = ScoreItemSort.lastOpenedDesc.apply(to: items)
        #expect(sorted.map(\.title) == ["C", "A", "B"])
    }
}
```

The `titleAscIsLocaleAwareAndDiacriticInsensitive` test allows either ordering of `etude` / `Étude` because `localizedStandardCompare` may treat them as equivalent — what matters is that both sort *between* `Bagatelle` and the next item with diacritic insensitivity.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/Features/Library && swift test --filter ScoreItemSortTests`
Expected: compile error — `ScoreItemSort` not defined.

- [ ] **Step 3: Implement ScoreItemSort**

Create `Packages/Features/Library/Sources/Library/ScoreItemSort.swift`:

```swift
import Domain
import Foundation

/// Sort options for any score list view (All / Tag-filtered / Playlist).
public enum ScoreItemSort: String, CaseIterable, Sendable, Identifiable {
    case dateAddedDesc
    case titleAsc
    case composerAsc
    case lastOpenedDesc

    public var id: String { rawValue }

    public var labelKey: LocalizedStringResource {
        switch self {
        case .dateAddedDesc: "sort.dateAdded"
        case .titleAsc: "sort.title"
        case .composerAsc: "sort.composer"
        case .lastOpenedDesc: "sort.lastOpened"
        }
    }

    public func apply(to items: [ScoreItem]) -> [ScoreItem] {
        switch self {
        case .dateAddedDesc:
            items.sorted { $0.addedAt > $1.addedAt }
        case .titleAsc:
            items.sorted { lhs, rhs in
                lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        case .composerAsc:
            items.sorted { lhs, rhs in
                switch (lhs.composer, rhs.composer) {
                case let (l?, r?): l.localizedStandardCompare(r) == .orderedAscending
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): false
                }
            }
        case .lastOpenedDesc:
            items.sorted { lhs, rhs in
                switch (lhs.lastOpenedAt, rhs.lastOpenedAt) {
                case let (l?, r?): l > r
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): false
                }
            }
        }
    }
}
```

`localizedStandardCompare` is the Foundation API that gives Finder-like sorting (locale-aware, case-insensitive, diacritic-insensitive, with numeric segments compared as numbers).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/Features/Library && swift test --filter ScoreItemSortTests`
Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/Library/ScoreItemSort.swift \
        Packages/Features/Library/Tests/LibraryTests/ScoreItemSortTests.swift
git commit -m "feat(library): ScoreItemSort with locale-aware comparators"
```

---

### Task 5: `ScoreListViewModel` (filter source + search + sort)

**Files:**
- Create: `Packages/Features/Library/Sources/Library/ScoreListViewModel.swift`
- Test: `Packages/Features/Library/Tests/LibraryTests/ScoreListViewModelTests.swift`

This view model drives any of the three leaf list shapes: All Scores, Tag-filtered, Playlist contents. The differences live in a `Source` enum.

- [ ] **Step 1: Write the failing tests**

Create `Packages/Features/Library/Tests/LibraryTests/ScoreListViewModelTests.swift`:

```swift
import Domain
import Foundation
import Testing
@testable import Library

@Suite @MainActor
struct ScoreListViewModelTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(
        id: ScoreItemID = ScoreItemID(),
        title: String,
        composer: String? = nil,
        addedOffset: TimeInterval = 0,
        tagIDs: Set<TagID> = []
    ) -> ScoreItem {
        ScoreItem(
            id: id,
            title: title, composer: composer, instrumentationSummary: nil,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: base.addingTimeInterval(addedOffset),
            lastOpenedAt: nil, tagIDs: tagIDs, isFavorite: false
        )
    }

    private static func makeRepo(items: [ScoreItem]) -> FakeScoreLibraryRepository {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = items
        return repo
    }

    @Test func sourceAllReturnsEverythingSorted() async {
        let repo = Self.makeRepo(items: [
            Self.makeItem(title: "B", addedOffset: 100),
            Self.makeItem(title: "A", addedOffset: 200),
        ])
        let vm = ScoreListViewModel(source: .all, repository: repo)
        vm.sort = .dateAddedDesc
        #expect(vm.displayedItems.map(\.title) == ["A", "B"])
    }

    @Test func sourceTaggedFiltersByTagID() async {
        let tagID = TagID()
        let repo = Self.makeRepo(items: [
            Self.makeItem(title: "A", tagIDs: [tagID]),
            Self.makeItem(title: "B", tagIDs: []),
            Self.makeItem(title: "C", tagIDs: [tagID]),
        ])
        let vm = ScoreListViewModel(source: .taggedWith(tagID), repository: repo)
        vm.sort = .titleAsc
        #expect(vm.displayedItems.map(\.title) == ["A", "C"])
    }

    @Test func sourcePlaylistPreservesOrderingByDefault() async {
        let id1 = ScoreItemID()
        let id2 = ScoreItemID()
        let id3 = ScoreItemID()
        let repo = Self.makeRepo(items: [
            Self.makeItem(id: id3, title: "C"),
            Self.makeItem(id: id1, title: "A"),
            Self.makeItem(id: id2, title: "B"),
        ])
        let vm = ScoreListViewModel(
            source: .playlist(orderedIDs: [id1, id2, id3]),
            repository: repo
        )
        // Default sort for playlists is .manual; items follow orderedIDs.
        #expect(vm.displayedItems.map(\.title) == ["A", "B", "C"])
    }

    @Test func sourcePlaylistSortOverrideIgnoresManualOrder() async {
        let id1 = ScoreItemID()
        let id2 = ScoreItemID()
        let repo = Self.makeRepo(items: [
            Self.makeItem(id: id1, title: "B", addedOffset: 100),
            Self.makeItem(id: id2, title: "A", addedOffset: 200),
        ])
        let vm = ScoreListViewModel(
            source: .playlist(orderedIDs: [id1, id2]),
            repository: repo
        )
        vm.selectSort(.titleAsc)
        #expect(vm.displayedItems.map(\.title) == ["A", "B"])
    }

    @Test func searchMatchesTitleAndComposerCaseAndDiacriticInsensitively() async {
        let repo = Self.makeRepo(items: [
            Self.makeItem(title: "Étude Op.10", composer: "Chopin"),
            Self.makeItem(title: "Sonata", composer: "Mozart"),
            Self.makeItem(title: "Prelude", composer: "Chopin"),
        ])
        let vm = ScoreListViewModel(source: .all, repository: repo)
        vm.searchQuery = "etude"
        #expect(vm.displayedItems.map(\.title) == ["Étude Op.10"])
        vm.searchQuery = "chopin"
        let chopins = Set(vm.displayedItems.map(\.title))
        #expect(chopins == ["Étude Op.10", "Prelude"])
    }

    @Test func emptySearchQueryReturnsAll() async {
        let repo = Self.makeRepo(items: [
            Self.makeItem(title: "A"),
            Self.makeItem(title: "B"),
        ])
        let vm = ScoreListViewModel(source: .all, repository: repo)
        vm.searchQuery = ""
        #expect(vm.displayedItems.count == 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/Features/Library && swift test --filter ScoreListViewModelTests`
Expected: compile error — `ScoreListViewModel` not defined.

- [ ] **Step 3: Implement ScoreListViewModel**

Create `Packages/Features/Library/Sources/Library/ScoreListViewModel.swift`:

```swift
import Domain
import Foundation
import Observation

/// Drives any of the three leaf score list views (All / Tag-filtered / Playlist).
@MainActor
@Observable
public final class ScoreListViewModel {
    public enum Source: Hashable, Sendable {
        case all
        case taggedWith(TagID)
        case playlist(orderedIDs: [ScoreItemID])
    }

    public let source: Source
    public let repository: any ScoreLibraryRepository
    public var sort: ScoreItemSort
    public var searchQuery: String = ""

    /// `true` when `source == .playlist(...)` and the current sort is the
    /// playlist's manual order (i.e. no explicit sort was picked).
    public var isManualOrderActive: Bool {
        if case .playlist = source { return manualOrder }
        return false
    }

    private var manualOrder: Bool

    public init(source: Source, repository: any ScoreLibraryRepository) {
        self.source = source
        self.repository = repository
        switch source {
        case .all, .taggedWith:
            sort = .dateAddedDesc
            manualOrder = false
        case .playlist:
            sort = .dateAddedDesc // value is ignored while manualOrder is true
            manualOrder = true
        }
    }

    /// Switches off manual order; further reads honour `sort`.
    public func selectSort(_ next: ScoreItemSort) {
        sort = next
        manualOrder = false
    }

    /// Returns to the playlist's manual order. Only valid for `.playlist`.
    public func selectManualOrder() {
        guard case .playlist = source else { return }
        manualOrder = true
    }

    public var displayedItems: [ScoreItem] {
        let scoped = scope(repository.scoreItems)
        let filtered = applySearch(scoped)
        if isManualOrderActive {
            return filtered
        }
        return sort.apply(to: filtered)
    }

    private func scope(_ items: [ScoreItem]) -> [ScoreItem] {
        switch source {
        case .all:
            items
        case let .taggedWith(tagID):
            items.filter { $0.tagIDs.contains(tagID) }
        case let .playlist(orderedIDs):
            // Build by ordered IDs to preserve manual order.
            let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            return orderedIDs.compactMap { lookup[$0] }
        }
    }

    private func applySearch(_ items: [ScoreItem]) -> [ScoreItem] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return items.filter { item in
            if item.title.range(of: trimmed, options: opts, locale: .current) != nil {
                return true
            }
            if let composer = item.composer,
               composer.range(of: trimmed, options: opts, locale: .current) != nil {
                return true
            }
            return false
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/Features/Library && swift test --filter ScoreListViewModelTests`
Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/Library/ScoreListViewModel.swift \
        Packages/Features/Library/Tests/LibraryTests/ScoreListViewModelTests.swift
git commit -m "feat(library): ScoreListViewModel for All/Tagged/Playlist sources"
```

---

## Phase C — Library views

### Task 6: `ScoreRow` view

**Files:**
- Create: `Packages/Features/Library/Sources/Library/ScoreRow.swift`

The single row layout used everywhere in the Library: title (large), composer (subtitle), trailing favorite star.

- [ ] **Step 1: Implement ScoreRow with #Preview**

Create `Packages/Features/Library/Sources/Library/ScoreRow.swift`:

```swift
import Domain
import SwiftUI

struct ScoreRow: View {
    let scoreItem: ScoreItem

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(scoreItem.title)
                    .font(.body)
                    .lineLimit(1)
                if let composer = scoreItem.composer, !composer.isEmpty {
                    Text(composer)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if scoreItem.isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Favorite")
            }
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    let withComposer = ScoreItem(
        title: "Sonata in C major", composer: "W. A. Mozart",
        instrumentationSummary: "Piano",
        localFileName: "x.mscx", contentHash: "x", sizeBytes: 0,
        lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
        addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: true
    )
    let onlyTitle = ScoreItem(
        title: "Untitled Score", composer: nil,
        instrumentationSummary: nil,
        localFileName: "y.mscx", contentHash: "y", sizeBytes: 0,
        lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
        addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false
    )
    return List {
        ScoreRow(scoreItem: withComposer)
        ScoreRow(scoreItem: onlyTitle)
    }
}
```

- [ ] **Step 2: Build the package**

Run: `cd Packages/Features/Library && swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/Library/ScoreRow.swift
git commit -m "feat(library): ScoreRow view with title/composer/favorite star"
```

---

### Task 7: `ScoreListView` shell (List + searchable + sort menu + open closure)

**Files:**
- Create: `Packages/Features/Library/Sources/Library/ScoreListView.swift`

The leaf list view used by All Scores, Tag-filtered, and Playlist contents. This task wires up the layout, sort menu, and `.searchable` — without swipe actions or the context menu (those land in Task 8).

- [ ] **Step 1: Implement ScoreListView shell**

Create `Packages/Features/Library/Sources/Library/ScoreListView.swift`:

```swift
import Domain
import SwiftUI

/// Reusable list of scores. Driven by `ScoreListViewModel`. Caller supplies
/// `onOpen` to handle the row tap (the App composition translates this into
/// either a NavigationStack push or a NavigationSplitView detail selection).
struct ScoreListView: View {
    @Bindable var viewModel: ScoreListViewModel
    let onOpen: (ScoreItem) -> Void

    var body: some View {
        List {
            ForEach(viewModel.displayedItems) { item in
                ScoreRow(scoreItem: item)
                    .onTapGesture { onOpen(item) }
            }
        }
        .searchable(text: $viewModel.searchQuery)
        .toolbar { sortToolbarItem }
    }

    @ToolbarContentBuilder
    private var sortToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if case .playlist = viewModel.source {
                    Button {
                        viewModel.selectManualOrder()
                    } label: {
                        Label("Manual Order", systemImage: viewModel.isManualOrderActive ? "checkmark" : "")
                    }
                    Divider()
                }
                ForEach(ScoreItemSort.allCases) { option in
                    Button {
                        viewModel.selectSort(option)
                    } label: {
                        let isSelected = !viewModel.isManualOrderActive && viewModel.sort == option
                        Label(option.labelKey, systemImage: isSelected ? "checkmark" : "")
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .accessibilityLabel("Sort")
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `cd Packages/Features/Library && swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/Library/ScoreListView.swift
git commit -m "feat(library): ScoreListView shell with searchable + sort menu"
```

---

### Task 8: ScoreListView swipe actions + context menu (Favorite / Delete)

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/ScoreListView.swift`
- Test: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift` (added — Tasks 16/17/18 will append more cases)

Add the swipe actions (leading: favorite toggle, trailing: delete with confirmation alert) and the context menu (Open / Favorite / Delete; tag/playlist items added in Tasks 9 & 10). Per-action repository writes go through new helper methods on `LibraryViewModel`.

- [ ] **Step 1: Add helper methods to LibraryViewModel**

Edit `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`. Replace the file contents with:

```swift
import Domain
import Foundation
import Observation

/// Top-level view model for the Library screen. Owns import state (file picker,
/// duplicate alert, error alert) and the most-recently-imported `ScoreItem`
/// that the view should auto-push into the Reader. Per-list sort/search state
/// lives in `ScoreListViewModel` (one per list view).
@MainActor
@Observable
public final class LibraryViewModel {
    public let repository: any ScoreLibraryRepository
    public let importer: any ScoreFileImporter
    public let gateway: any ScoreFileGateway

    /// The most recent persistence error surfaced through `errorAlertMessage`.
    /// Reset to `nil` when the alert is dismissed.
    public var errorAlertMessage: String?

    public init(
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway
    ) {
        self.repository = repository
        self.importer = importer
        self.gateway = gateway
    }

    public func toggleFavorite(_ scoreItem: ScoreItem) async {
        var updated = scoreItem
        updated.isFavorite.toggle()
        await save(updated)
    }

    public func delete(_ scoreItem: ScoreItem) async {
        do {
            try await repository.deleteScoreItem(id: scoreItem.id)
        } catch {
            errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    public func setTagIDs(_ tagIDs: Set<TagID>, on scoreItem: ScoreItem) async {
        var updated = scoreItem
        updated.tagIDs = tagIDs
        await save(updated)
    }

    func save(_ scoreItem: ScoreItem) async {
        do {
            try await repository.saveScoreItem(scoreItem)
        } catch {
            errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Write LibraryViewModel CRUD tests**

Create `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift`:

```swift
import Domain
import Foundation
import Testing
@testable import Library

@Suite @MainActor
struct LibraryViewModelTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(title: String = "A", isFavorite: Bool = false) -> ScoreItem {
        ScoreItem(
            title: title, composer: nil, instrumentationSummary: nil,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: base, lastOpenedAt: nil, tagIDs: [], isFavorite: isFavorite
        )
    }

    private static func makeVM(
        scoreItems: [ScoreItem] = []
    ) -> (LibraryViewModel, FakeScoreLibraryRepository, FakeScoreFileImporter, FakeScoreFileGateway) {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = scoreItems
        let importer = FakeScoreFileImporter()
        let gateway = FakeScoreFileGateway()
        let vm = LibraryViewModel(repository: repo, importer: importer, gateway: gateway)
        return (vm, repo, importer, gateway)
    }

    @Test func toggleFavoriteFlipsAndSaves() async {
        let original = Self.makeItem(isFavorite: false)
        let (vm, repo, _, _) = Self.makeVM(scoreItems: [original])
        await vm.toggleFavorite(original)
        #expect(repo.savedScoreItems.last?.isFavorite == true)
        #expect(repo.scoreItems.first?.isFavorite == true)
    }

    @Test func deleteCallsRepository() async {
        let item = Self.makeItem()
        let (vm, repo, _, _) = Self.makeVM(scoreItems: [item])
        await vm.delete(item)
        #expect(repo.deletedScoreItemIDs == [item.id])
        #expect(repo.scoreItems.isEmpty)
    }

    @Test func setTagIDsResyncsAndSaves() async {
        let item = Self.makeItem()
        let (vm, repo, _, _) = Self.makeVM(scoreItems: [item])
        let tagID = TagID()
        await vm.setTagIDs([tagID], on: item)
        #expect(repo.savedScoreItems.last?.tagIDs == [tagID])
    }

    @Test func saveSurfacesPersistenceErrorOnAlert() async {
        let item = Self.makeItem()
        let (vm, repo, _, _) = Self.makeVM(scoreItems: [item])
        repo.saveScoreItemError = .persistenceFailed(reason: "disk full")
        await vm.toggleFavorite(item)
        #expect(vm.errorAlertMessage?.contains("disk full") == true)
    }

    @Test func deleteSurfacesPersistenceErrorOnAlert() async {
        let item = Self.makeItem()
        let (vm, repo, _, _) = Self.makeVM(scoreItems: [item])
        repo.deleteScoreItemError = .persistenceFailed(reason: "io error")
        await vm.delete(item)
        #expect(vm.errorAlertMessage?.contains("io error") == true)
    }
}
```

- [ ] **Step 3: Run the tests to verify they pass**

Run: `cd Packages/Features/Library && swift test --filter LibraryViewModelTests`
Expected: all 5 tests pass.

- [ ] **Step 4: Add swipe actions and context menu to ScoreListView**

Edit `Packages/Features/Library/Sources/Library/ScoreListView.swift`. Replace the file contents with:

```swift
import Domain
import SwiftUI

struct ScoreListView: View {
    @Bindable var viewModel: ScoreListViewModel
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    let onEditTags: (ScoreItem) -> Void
    let onAddToPlaylist: (ScoreItem) -> Void

    @State private var pendingDelete: ScoreItem?

    var body: some View {
        List {
            ForEach(viewModel.displayedItems) { item in
                row(for: item)
            }
        }
        .searchable(text: $viewModel.searchQuery)
        .toolbar { sortToolbarItem }
        .alert(
            "Delete \"\(pendingDelete?.title ?? "")\"?",
            isPresented: deleteAlertBinding,
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) {
                Task { await library.delete(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This will remove the score and its file from this device.")
        }
    }

    @ViewBuilder
    private func row(for item: ScoreItem) -> some View {
        ScoreRow(scoreItem: item)
            .contentShape(Rectangle())
            .onTapGesture { onOpen(item) }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    Task { await library.toggleFavorite(item) }
                } label: {
                    Label(
                        item.isFavorite ? "Unfavorite" : "Favorite",
                        systemImage: item.isFavorite ? "star.slash.fill" : "star.fill"
                    )
                }
                .tint(.yellow)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    pendingDelete = item
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .contextMenu {
                Button {
                    onOpen(item)
                } label: {
                    Label("Open", systemImage: "music.note")
                }
                Button {
                    Task { await library.toggleFavorite(item) }
                } label: {
                    Label(
                        item.isFavorite ? "Unfavorite" : "Favorite",
                        systemImage: item.isFavorite ? "star.slash" : "star"
                    )
                }
                Button {
                    onEditTags(item)
                } label: {
                    Label("Edit Tags…", systemImage: "tag")
                }
                Button {
                    onAddToPlaylist(item)
                } label: {
                    Label("Add to Playlist…", systemImage: "music.note.list")
                }
                Divider()
                Button(role: .destructive) {
                    pendingDelete = item
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { isPresented in if !isPresented { pendingDelete = nil } }
        )
    }

    @ToolbarContentBuilder
    private var sortToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if case .playlist = viewModel.source {
                    Button {
                        viewModel.selectManualOrder()
                    } label: {
                        Label("Manual Order", systemImage: viewModel.isManualOrderActive ? "checkmark" : "")
                    }
                    Divider()
                }
                ForEach(ScoreItemSort.allCases) { option in
                    Button {
                        viewModel.selectSort(option)
                    } label: {
                        let isSelected = !viewModel.isManualOrderActive && viewModel.sort == option
                        Label(option.labelKey, systemImage: isSelected ? "checkmark" : "")
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .accessibilityLabel("Sort")
            }
        }
    }
}
```

- [ ] **Step 5: Build**

Run: `cd Packages/Features/Library && swift build`
Expected: builds clean. (Test suite is unchanged in this step; the next tasks add the sheet wiring.)

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Library/Sources/Library/ScoreListView.swift \
        Packages/Features/Library/Sources/Library/LibraryViewModel.swift \
        Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift
git commit -m "feat(library): swipe actions, context menu, delete confirmation"
```

---

### Task 9: `EditTagsSheet` (multi-toggle existing tags + inline create)

**Files:**
- Create: `Packages/Features/Library/Sources/Library/EditTagsSheet.swift`

A sheet that lists every existing `Tag` with a leading checkmark for current membership. Toggling a row mutates the score's `tagIDs` immediately (no Save button). An inline "+ New Tag" row adds and assigns in one step. Default `colorHex` is `"#5856D6"`.

- [ ] **Step 1: Implement EditTagsSheet**

Create `Packages/Features/Library/Sources/Library/EditTagsSheet.swift`:

```swift
import Domain
import SwiftUI

struct EditTagsSheet: View {
    let scoreItem: ScoreItem
    let library: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var newTagName: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.repository.tags) { tag in
                        Button {
                            Task { await toggle(tag) }
                        } label: {
                            HStack {
                                Image(systemName: scoreItem.tagIDs.contains(tag.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(.tint)
                                Text(tag.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                    }
                }
                Section {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                        TextField("New tag", text: $newTagName)
                            .submitLabel(.done)
                            .onSubmit { Task { await commitNewTag() } }
                    }
                }
            }
            .navigationTitle("Tags for \"\(scoreItem.title)\"")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func toggle(_ tag: Tag) async {
        var updated = await currentScoreItem()
        if updated.tagIDs.contains(tag.id) {
            updated.tagIDs.remove(tag.id)
        } else {
            updated.tagIDs.insert(tag.id)
        }
        await library.save(updated)
    }

    private func commitNewTag() async {
        let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tag = Tag(name: trimmed, colorHex: "#5856D6")
        do {
            try await library.repository.saveTag(tag)
        } catch {
            return
        }
        var updated = await currentScoreItem()
        updated.tagIDs.insert(tag.id)
        await library.save(updated)
        newTagName = ""
    }

    /// Re-read from the repository on each operation in case other operations
    /// have mutated the score's tagIDs while this sheet is open.
    private func currentScoreItem() async -> ScoreItem {
        library.repository.scoreItems.first(where: { $0.id == scoreItem.id }) ?? scoreItem
    }
}
```

- [ ] **Step 2: Build**

Run: `cd Packages/Features/Library && swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/Library/EditTagsSheet.swift
git commit -m "feat(library): EditTagsSheet with toggle and inline create"
```

---

### Task 10: `AddToPlaylistSheet` (multi-toggle existing playlists + inline create)

**Files:**
- Create: `Packages/Features/Library/Sources/Library/AddToPlaylistSheet.swift`

Same shape as `EditTagsSheet`. Adding appends to `orderedScoreItemIDs`; removing preserves remaining order.

- [ ] **Step 1: Implement AddToPlaylistSheet**

Create `Packages/Features/Library/Sources/Library/AddToPlaylistSheet.swift`:

```swift
import Domain
import SwiftUI

struct AddToPlaylistSheet: View {
    let scoreItem: ScoreItem
    let library: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var newPlaylistName: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.repository.playlists) { playlist in
                        Button {
                            Task { await toggle(playlist) }
                        } label: {
                            HStack {
                                Image(systemName: playlist.orderedScoreItemIDs.contains(scoreItem.id)
                                    ? "checkmark.circle.fill"
                                    : "circle")
                                    .foregroundStyle(.tint)
                                Text(playlist.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                    }
                }
                Section {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                        TextField("New playlist", text: $newPlaylistName)
                            .submitLabel(.done)
                            .onSubmit { Task { await commitNewPlaylist() } }
                    }
                }
            }
            .navigationTitle("Add \"\(scoreItem.title)\" to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func toggle(_ playlist: Playlist) async {
        var updated = playlist
        if let idx = updated.orderedScoreItemIDs.firstIndex(of: scoreItem.id) {
            updated.orderedScoreItemIDs.remove(at: idx)
        } else {
            updated.orderedScoreItemIDs.append(scoreItem.id)
        }
        do {
            try await library.repository.savePlaylist(updated)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func commitNewPlaylist() async {
        let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let playlist = Playlist(
            name: trimmed,
            orderedScoreItemIDs: [scoreItem.id],
            createdAt: Date()
        )
        do {
            try await library.repository.savePlaylist(playlist)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return
        }
        newPlaylistName = ""
    }
}
```

- [ ] **Step 2: Build**

Run: `cd Packages/Features/Library && swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/Library/AddToPlaylistSheet.swift
git commit -m "feat(library): AddToPlaylistSheet with toggle and inline create"
```

---

## Phase D — Tags & Playlists drill-downs

### Task 11: `TagsListView` with create-tag alert and empty state

**Files:**
- Create: `Packages/Features/Library/Sources/Library/TagsListView.swift`

Lists every `Tag` (sorted A→Z by `localizedStandardCompare`). Toolbar `+` opens an alert with a TextField; submit creates a `Tag` with default colour. Empty state per spec.

- [ ] **Step 1: Implement TagsListView**

Create `Packages/Features/Library/Sources/Library/TagsListView.swift`:

```swift
import Domain
import SwiftUI

struct TagsListView: View {
    let library: LibraryViewModel

    @State private var isCreating = false
    @State private var newTagName: String = ""

    var body: some View {
        Group {
            if sortedTags.isEmpty {
                ContentUnavailableView {
                    Label("No Tags", systemImage: "tag")
                } description: {
                    Text("Add tags from a score's context menu, or tap + above.")
                }
            } else {
                List {
                    ForEach(sortedTags) { tag in
                        NavigationLink(value: LibraryRoute.tagDetail(tag.id)) {
                            HStack {
                                Image(systemName: "tag.fill")
                                    .foregroundStyle(.tint)
                                Text(tag.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(memberCount(of: tag), format: .number)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Tags")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newTagName = ""
                    isCreating = true
                } label: {
                    Image(systemName: "plus").accessibilityLabel("New Tag")
                }
            }
        }
        .alert("New Tag", isPresented: $isCreating) {
            TextField("Tag name", text: $newTagName)
            Button("Add") { Task { await commit() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new tag.")
        }
    }

    private var sortedTags: [Tag] {
        library.repository.tags.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func memberCount(of tag: Tag) -> Int {
        library.repository.scoreItems.reduce(0) { acc, item in
            acc + (item.tagIDs.contains(tag.id) ? 1 : 0)
        }
    }

    private func commit() async {
        let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tag = Tag(name: trimmed, colorHex: "#5856D6")
        do {
            try await library.repository.saveTag(tag)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `cd Packages/Features/Library && swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/Library/TagsListView.swift
git commit -m "feat(library): TagsListView with create alert and empty state"
```

---

### Task 12: `TagDetailView` (filtered ScoreListView + rename + delete)

**Files:**
- Create: `Packages/Features/Library/Sources/Library/TagDetailView.swift`

Filtered All-Scores view scoped to one tag. Toolbar `Edit` menu offers rename and delete (CASCADE strips relations).

- [ ] **Step 1: Implement TagDetailView**

Create `Packages/Features/Library/Sources/Library/TagDetailView.swift`:

```swift
import Domain
import SwiftUI

struct TagDetailView: View {
    let tag: Tag
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    let onEditTags: (ScoreItem) -> Void
    let onAddToPlaylist: (ScoreItem) -> Void
    let onTagDeleted: () -> Void

    @State private var listVM: ScoreListViewModel
    @State private var isRenaming = false
    @State private var renameText: String = ""
    @State private var isConfirmingDelete = false

    init(
        tag: Tag,
        library: LibraryViewModel,
        onOpen: @escaping (ScoreItem) -> Void,
        onEditTags: @escaping (ScoreItem) -> Void,
        onAddToPlaylist: @escaping (ScoreItem) -> Void,
        onTagDeleted: @escaping () -> Void
    ) {
        self.tag = tag
        self.library = library
        self.onOpen = onOpen
        self.onEditTags = onEditTags
        self.onAddToPlaylist = onAddToPlaylist
        self.onTagDeleted = onTagDeleted
        _listVM = State(
            wrappedValue: ScoreListViewModel(source: .taggedWith(tag.id), repository: library.repository)
        )
    }

    var body: some View {
        ScoreListView(
            viewModel: listVM,
            library: library,
            onOpen: onOpen,
            onEditTags: onEditTags,
            onAddToPlaylist: onAddToPlaylist
        )
        .navigationTitle(tag.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameText = tag.name
                        isRenaming = true
                    } label: { Label("Rename…", systemImage: "pencil") }
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: { Label("Delete Tag", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("Edit Tag")
                }
            }
        }
        .alert("Rename Tag", isPresented: $isRenaming) {
            TextField("Tag name", text: $renameText)
            Button("Save") { Task { await commitRename() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Delete \"\(tag.name)\"?",
            isPresented: $isConfirmingDelete
        ) {
            Button("Delete", role: .destructive) {
                Task { await commitDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scores keep their data; only the tag and its assignments are removed.")
        }
    }

    private func commitRename() async {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != tag.name else { return }
        var updated = tag
        updated.name = trimmed
        do {
            try await library.repository.saveTag(updated)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func commitDelete() async {
        do {
            try await library.repository.deleteTag(id: tag.id)
            onTagDeleted()
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `cd Packages/Features/Library && swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/Library/TagDetailView.swift
git commit -m "feat(library): TagDetailView with filtered list, rename, delete"
```

---

### Task 13: `PlaylistsListView` with create-playlist alert and empty state

**Files:**
- Create: `Packages/Features/Library/Sources/Library/PlaylistsListView.swift`

Same shape as TagsListView. Empty state per spec.

- [ ] **Step 1: Implement PlaylistsListView**

Create `Packages/Features/Library/Sources/Library/PlaylistsListView.swift`:

```swift
import Domain
import SwiftUI

struct PlaylistsListView: View {
    let library: LibraryViewModel

    @State private var isCreating = false
    @State private var newPlaylistName: String = ""

    var body: some View {
        Group {
            if sortedPlaylists.isEmpty {
                ContentUnavailableView {
                    Label("No Playlists", systemImage: "music.note.list")
                } description: {
                    Text("Create a playlist with the + button above.")
                }
            } else {
                List {
                    ForEach(sortedPlaylists) { playlist in
                        NavigationLink(value: LibraryRoute.playlistDetail(playlist.id)) {
                            HStack {
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(.tint)
                                Text(playlist.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(playlist.orderedScoreItemIDs.count, format: .number)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newPlaylistName = ""
                    isCreating = true
                } label: {
                    Image(systemName: "plus").accessibilityLabel("New Playlist")
                }
            }
        }
        .alert("New Playlist", isPresented: $isCreating) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Add") { Task { await commit() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new playlist.")
        }
    }

    private var sortedPlaylists: [Playlist] {
        library.repository.playlists.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func commit() async {
        let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let playlist = Playlist(name: trimmed, orderedScoreItemIDs: [], createdAt: Date())
        do {
            try await library.repository.savePlaylist(playlist)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `cd Packages/Features/Library && swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/Library/PlaylistsListView.swift
git commit -m "feat(library): PlaylistsListView with create alert and empty state"
```

---

### Task 14: `PlaylistDetailView` (ordered list, drag reorder, rename, delete)

**Files:**
- Create: `Packages/Features/Library/Sources/Library/PlaylistDetailView.swift`

Shows the playlist's scores in `orderedScoreItemIDs` order. `EditMode` toggles drag handles (`.onMove`). The existing `ScoreListView` is *not* reused here because edit-mode reorder needs raw `ForEach` with `.onMove`, and the manual-order rendering is naturally a separate view.

- [ ] **Step 1: Implement PlaylistDetailView**

Create `Packages/Features/Library/Sources/Library/PlaylistDetailView.swift`:

```swift
import Domain
import SwiftUI

struct PlaylistDetailView: View {
    let playlist: Playlist
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    let onPlaylistDeleted: () -> Void

    @State private var editMode: EditMode = .inactive
    @State private var isRenaming = false
    @State private var renameText: String = ""
    @State private var isConfirmingDelete = false

    var body: some View {
        Group {
            if orderedItems.isEmpty {
                ContentUnavailableView {
                    Label("No Scores in This Playlist", systemImage: "music.note.list")
                } description: {
                    Text("Add scores from the context menu of any score row.")
                }
            } else {
                List {
                    ForEach(orderedItems) { item in
                        ScoreRow(scoreItem: item)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpen(item) }
                    }
                    .onMove(perform: move)
                    .onDelete(perform: removeFromPlaylist)
                }
            }
        }
        .navigationTitle(playlist.name)
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        renameText = playlist.name
                        isRenaming = true
                    } label: { Label("Rename…", systemImage: "pencil") }
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: { Label("Delete Playlist", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("Edit Playlist")
                }
            }
        }
        .alert("Rename Playlist", isPresented: $isRenaming) {
            TextField("Playlist name", text: $renameText)
            Button("Save") { Task { await commitRename() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Delete \"\(playlist.name)\"?",
            isPresented: $isConfirmingDelete
        ) {
            Button("Delete", role: .destructive) {
                Task { await commitDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scores keep their data; only the playlist and its order are removed.")
        }
    }

    private var orderedItems: [ScoreItem] {
        let lookup = Dictionary(uniqueKeysWithValues: library.repository.scoreItems.map { ($0.id, $0) })
        return playlist.orderedScoreItemIDs.compactMap { lookup[$0] }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        var ids = playlist.orderedScoreItemIDs
        ids.move(fromOffsets: offsets, toOffset: destination)
        var updated = playlist
        updated.orderedScoreItemIDs = ids
        Task {
            do {
                try await library.repository.savePlaylist(updated)
            } catch {
                library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func removeFromPlaylist(at offsets: IndexSet) {
        let removedIDs = offsets.map { orderedItems[$0].id }
        var updated = playlist
        updated.orderedScoreItemIDs.removeAll { removedIDs.contains($0) }
        Task {
            do {
                try await library.repository.savePlaylist(updated)
            } catch {
                library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func commitRename() async {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != playlist.name else { return }
        var updated = playlist
        updated.name = trimmed
        do {
            try await library.repository.savePlaylist(updated)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func commitDelete() async {
        do {
            try await library.repository.deletePlaylist(id: playlist.id)
            onPlaylistDeleted()
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `cd Packages/Features/Library && swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/Library/PlaylistDetailView.swift
git commit -m "feat(library): PlaylistDetailView with reorder, rename, delete"
```

---

## Phase E — Library root

### Task 15: `LibraryRootView` sectioned (Favorites / Browse / Recently Opened)

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/LibraryRootView.swift`

Replace the stub from Task 2 with the real hierarchical root. Wire navigation to TagsListView / PlaylistsListView / TagDetailView / PlaylistDetailView. The leaf "All Scores" view uses `ScoreListView` with `source: .all`. Sheets for `EditTagsSheet` / `AddToPlaylistSheet` are also presented here.

- [ ] **Step 1: Replace LibraryRootView**

Edit `Packages/Features/Library/Sources/Library/LibraryRootView.swift`. Replace the file contents with:

```swift
import Domain
import SwiftUI

@MainActor
public struct LibraryRootView<LicenseContent: View>: View {
    @State private var viewModel: LibraryViewModel
    private let onOpenScore: (ScoreItem) -> Void
    private let licenseContent: () -> LicenseContent

    @State private var editTagsTarget: ScoreItem?
    @State private var addToPlaylistTarget: ScoreItem?

    public init(
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway,
        onOpenScore: @escaping (ScoreItem) -> Void,
        @ViewBuilder licenseContent: @escaping () -> LicenseContent
    ) {
        _viewModel = State(
            wrappedValue: LibraryViewModel(
                repository: repository, importer: importer, gateway: gateway
            )
        )
        self.onOpenScore = onOpenScore
        self.licenseContent = licenseContent
    }

    public var body: some View {
        NavigationStack {
            rootList
                .navigationTitle("Library")
                .navigationDestination(for: LibraryRoute.self) { route in
                    destination(for: route)
                }
        }
        .sheet(item: $editTagsTarget) { item in
            EditTagsSheet(scoreItem: item, library: viewModel)
        }
        .sheet(item: $addToPlaylistTarget) { item in
            AddToPlaylistSheet(scoreItem: item, library: viewModel)
        }
        .alert(
            "Library",
            isPresented: errorAlertBinding,
            presenting: viewModel.errorAlertMessage
        ) { _ in
            Button("OK") { viewModel.errorAlertMessage = nil }
        } message: { msg in
            Text(msg)
        }
    }

    @ViewBuilder
    private var rootList: some View {
        let items = viewModel.repository.scoreItems
        let favorites = items.favorites(limit: 5)
        let recents = items.mostRecentlyOpened(limit: 5)

        if items.isEmpty && viewModel.repository.tags.isEmpty && viewModel.repository.playlists.isEmpty {
            ContentUnavailableView {
                Label("No Scores Yet", systemImage: "music.note")
            } description: {
                Text("Import your first score to get started.")
            }
        } else {
            List {
                if !favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(favorites) { item in
                            ScoreRow(scoreItem: item)
                                .contentShape(Rectangle())
                                .onTapGesture { onOpenScore(item) }
                                .contextMenu { rowContextMenu(for: item) }
                        }
                    }
                }
                Section("Browse") {
                    NavigationLink(value: LibraryRoute.allScores) {
                        browseRow(title: "All Scores", systemImage: "music.note", count: items.count)
                    }
                    NavigationLink(value: LibraryRoute.tags) {
                        browseRow(title: "Tags", systemImage: "tag", count: viewModel.repository.tags.count)
                    }
                    NavigationLink(value: LibraryRoute.playlists) {
                        browseRow(title: "Playlists", systemImage: "music.note.list", count: viewModel.repository.playlists.count)
                    }
                }
                if !recents.isEmpty {
                    Section("Recently Opened") {
                        ForEach(recents) { item in
                            ScoreRow(scoreItem: item)
                                .contentShape(Rectangle())
                                .onTapGesture { onOpenScore(item) }
                                .contextMenu { rowContextMenu(for: item) }
                        }
                    }
                }
            }
        }
    }

    private func browseRow(title: LocalizedStringResource, systemImage: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(count, format: .number)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func rowContextMenu(for item: ScoreItem) -> some View {
        Button { onOpenScore(item) } label: {
            Label("Open", systemImage: "music.note")
        }
        Button { Task { await viewModel.toggleFavorite(item) } } label: {
            Label(
                item.isFavorite ? "Unfavorite" : "Favorite",
                systemImage: item.isFavorite ? "star.slash" : "star"
            )
        }
        Button { editTagsTarget = item } label: {
            Label("Edit Tags…", systemImage: "tag")
        }
        Button { addToPlaylistTarget = item } label: {
            Label("Add to Playlist…", systemImage: "music.note.list")
        }
    }

    @ViewBuilder
    private func destination(for route: LibraryRoute) -> some View {
        switch route {
        case .allScores:
            AllScoresContainer(
                library: viewModel,
                onOpen: onOpenScore,
                onEditTags: { editTagsTarget = $0 },
                onAddToPlaylist: { addToPlaylistTarget = $0 }
            )
        case .tags:
            TagsListView(library: viewModel)
        case let .tagDetail(tagID):
            if let tag = viewModel.repository.tags.first(where: { $0.id == tagID }) {
                TagDetailView(
                    tag: tag,
                    library: viewModel,
                    onOpen: onOpenScore,
                    onEditTags: { editTagsTarget = $0 },
                    onAddToPlaylist: { addToPlaylistTarget = $0 },
                    onTagDeleted: { /* NavigationStack pops automatically when destination renders 'Tag not found' */ }
                )
            } else {
                ContentUnavailableView("Tag not found", systemImage: "tag.slash")
            }
        case .playlists:
            PlaylistsListView(library: viewModel)
        case let .playlistDetail(playlistID):
            if let playlist = viewModel.repository.playlists.first(where: { $0.id == playlistID }) {
                PlaylistDetailView(
                    playlist: playlist,
                    library: viewModel,
                    onOpen: onOpenScore,
                    onPlaylistDeleted: { /* same comment as tag */ }
                )
            } else {
                ContentUnavailableView("Playlist not found", systemImage: "music.note.list")
            }
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorAlertMessage != nil },
            set: { isPresented in if !isPresented { viewModel.errorAlertMessage = nil } }
        )
    }
}

private struct AllScoresContainer: View {
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    let onEditTags: (ScoreItem) -> Void
    let onAddToPlaylist: (ScoreItem) -> Void

    @State private var listVM: ScoreListViewModel

    init(
        library: LibraryViewModel,
        onOpen: @escaping (ScoreItem) -> Void,
        onEditTags: @escaping (ScoreItem) -> Void,
        onAddToPlaylist: @escaping (ScoreItem) -> Void
    ) {
        self.library = library
        self.onOpen = onOpen
        self.onEditTags = onEditTags
        self.onAddToPlaylist = onAddToPlaylist
        _listVM = State(
            wrappedValue: ScoreListViewModel(source: .all, repository: library.repository)
        )
    }

    var body: some View {
        ScoreListView(
            viewModel: listVM,
            library: library,
            onOpen: onOpen,
            onEditTags: onEditTags,
            onAddToPlaylist: onAddToPlaylist
        )
        .navigationTitle("All Scores")
    }
}

enum LibraryRoute: Hashable {
    case allScores
    case tags
    case tagDetail(TagID)
    case playlists
    case playlistDetail(PlaylistID)
}
```

- [ ] **Step 2: Build**

Run: `cd Packages/Features/Library && swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/Library/LibraryRootView.swift
git commit -m "feat(library): hierarchical LibraryRootView with sections and routes"
```

---

## Phase F — Import flow

### Task 16: Import — `+` toolbar, `.fileImporter`, prepare/commit happy path

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`
- Modify: `Packages/Features/Library/Sources/Library/LibraryRootView.swift`
- Modify: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift`

Add the `+` toolbar button on `LibraryRootView`, wire `.fileImporter`, call `prepareImport`, then `commitImport(.importAsNew)` on the happy path. The duplicate alert (Task 17) and the error alerts (Task 18) extend this flow.

The Reader auto-push is signalled by `viewModel.pendingScoreToOpen` — App's composition root (Task 23) watches this and pushes navigation.

- [ ] **Step 1: Add import driver to LibraryViewModel**

Edit `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`. Replace the file contents with:

```swift
import Domain
import Foundation
import Observation

@MainActor
@Observable
public final class LibraryViewModel {
    public let repository: any ScoreLibraryRepository
    public let importer: any ScoreFileImporter
    public let gateway: any ScoreFileGateway

    public var errorAlertMessage: String?

    /// Set when an import succeeds; the App composition root watches this and
    /// pushes the Reader. Cleared by the watcher after handling.
    public var pendingScoreToOpen: ScoreItem?

    /// Drives the `.fileImporter` sheet.
    public var isFileImporterPresented = false

    /// Set when `prepareImport` returns at least one duplicate. The view
    /// presents a 3-button alert; choosing one of the buttons drives
    /// `commitImport`.
    public var duplicatePrompt: DuplicatePrompt?

    public struct DuplicatePrompt: Identifiable, Equatable {
        public let id = UUID()
        public let plan: ImportPlan
        public let existing: ScoreItem
    }

    public init(
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway
    ) {
        self.repository = repository
        self.importer = importer
        self.gateway = gateway
    }

    public func toggleFavorite(_ scoreItem: ScoreItem) async {
        var updated = scoreItem
        updated.isFavorite.toggle()
        await save(updated)
    }

    public func delete(_ scoreItem: ScoreItem) async {
        do {
            try await repository.deleteScoreItem(id: scoreItem.id)
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    public func setTagIDs(_ tagIDs: Set<TagID>, on scoreItem: ScoreItem) async {
        var updated = scoreItem
        updated.tagIDs = tagIDs
        await save(updated)
    }

    func save(_ scoreItem: ScoreItem) async {
        do {
            try await repository.saveScoreItem(scoreItem)
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    /// Called by the `.fileImporter` `onCompletion`. Handles security-scoped
    /// access, prepareImport, and either commits immediately or stages a
    /// duplicate prompt.
    public func startImport(from sourceURL: URL) async {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let plan: ImportPlan
        do {
            plan = try await importer.prepareImport(sourceURL: sourceURL)
        } catch {
            errorAlertMessage = describe(error)
            return
        }
        if let existing = plan.duplicates.first {
            duplicatePrompt = DuplicatePrompt(plan: plan, existing: existing)
            return
        }
        await commit(plan: plan, decision: .importAsNew)
    }

    public func commit(plan: ImportPlan, decision: ImportDecision) async {
        do {
            let item = try await importer.commitImport(plan, decision: decision)
            pendingScoreToOpen = item
        } catch {
            errorAlertMessage = describe(error)
        }
    }

    private func describe(_ error: Error) -> String {
        if let domain = error as? DomainError {
            return domain.errorDescription ?? "\(domain)"
        }
        return (error as NSError).localizedDescription
    }
}
```

- [ ] **Step 2: Wire import UI in LibraryRootView**

Edit `Packages/Features/Library/Sources/Library/LibraryRootView.swift`. Add the toolbar `+` button and `.fileImporter` to the `NavigationStack`. Find the `.navigationTitle("Library")` line and add toolbar/fileImporter modifiers. The completed `body` becomes:

```swift
public var body: some View {
    NavigationStack {
        rootList
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.isFileImporterPresented = true
                    } label: {
                        Image(systemName: "plus").accessibilityLabel("Import Score")
                    }
                }
            }
            .fileImporter(
                isPresented: $viewModel.isFileImporterPresented,
                allowedContentTypes: ScoreFileTypes.allowed,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    guard let url = urls.first else { return }
                    Task { await viewModel.startImport(from: url) }
                case let .failure(error):
                    viewModel.errorAlertMessage = error.localizedDescription
                }
            }
            .navigationDestination(for: LibraryRoute.self) { route in
                destination(for: route)
            }
    }
    .sheet(item: $editTagsTarget) { item in
        EditTagsSheet(scoreItem: item, library: viewModel)
    }
    .sheet(item: $addToPlaylistTarget) { item in
        AddToPlaylistSheet(scoreItem: item, library: viewModel)
    }
    .alert(
        "Library",
        isPresented: errorAlertBinding,
        presenting: viewModel.errorAlertMessage
    ) { _ in
        Button("OK") { viewModel.errorAlertMessage = nil }
    } message: { msg in
        Text(msg)
    }
}
```

- [ ] **Step 3: Add ScoreFileTypes helper**

Append to `Packages/Features/Library/Sources/Library/LibraryRootView.swift` (at the bottom of the file, after the `LibraryRoute` enum):

```swift
import UniformTypeIdentifiers

enum ScoreFileTypes {
    /// Content types that the `.fileImporter` accepts. Each is a reasonable
    /// approximation; precise UTType registration is the v1-followup work
    /// (`UTImportedTypeDeclarations` in `App/Info.plist`).
    static var allowed: [UTType] {
        var types: [UTType] = [.xml, .midi]
        // .mscz / .mxl appear as `.zip` to UTType today. Filter post-pick by
        // extension on `prepareImport` (the importer routes by canonical ext).
        types.append(.zip)
        // Plain `.mscx` is XML; explicit `.xml` already covers it.
        return types
    }
}
```

- [ ] **Step 4: Add an import happy-path test**

Append to `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift`:

```swift
extension LibraryViewModelTests {
    private static func makePlan(duplicates: [ScoreItem] = []) -> ImportPlan {
        ImportPlan(
            sourceURL: URL(filePath: "/tmp/x.mscx"),
            format: .mscx,
            summary: ScoreFileSummary(
                title: "Imported", composer: nil,
                instrumentationSummary: "", lengthBeats: 0,
                defaultTempoBpm: 120, primaryKey: nil
            ),
            contentHash: "hash",
            sizeBytes: 100,
            duplicates: duplicates
        )
    }

    @Test func happyPathImportPushesPendingOpen() async {
        let (vm, _, importer, _) = Self.makeVM()
        let plan = Self.makePlan()
        importer.preparedPlans = [plan]
        let imported = Self.makeItem(title: "Imported")
        importer.commitFactory = { _, _ in imported }

        await vm.startImport(from: plan.sourceURL)
        #expect(importer.committed.count == 1)
        if case .importAsNew = importer.committed.first?.decision {} else {
            Issue.record("expected .importAsNew")
        }
        #expect(vm.pendingScoreToOpen?.id == imported.id)
        #expect(vm.duplicatePrompt == nil)
        #expect(vm.errorAlertMessage == nil)
    }

    @Test func duplicateStagesPromptInsteadOfCommitting() async {
        let (vm, _, importer, _) = Self.makeVM()
        let existing = Self.makeItem(title: "Existing")
        let plan = Self.makePlan(duplicates: [existing])
        importer.preparedPlans = [plan]
        importer.commitFactory = { _, _ in existing }

        await vm.startImport(from: plan.sourceURL)
        #expect(importer.committed.isEmpty)
        #expect(vm.duplicatePrompt?.existing.id == existing.id)
        #expect(vm.pendingScoreToOpen == nil)
    }
}
```

- [ ] **Step 5: Run tests**

Run: `cd Packages/Features/Library && swift test --filter LibraryViewModelTests`
Expected: 7 tests pass (5 from Task 8 + 2 added here).

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Library/Sources/Library/LibraryViewModel.swift \
        Packages/Features/Library/Sources/Library/LibraryRootView.swift \
        Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift
git commit -m "feat(library): import flow happy path with .fileImporter"
```

---

### Task 17: Import — duplicate alert (Open / Import as Duplicate / Cancel)

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/LibraryRootView.swift`
- Modify: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift`

Wire the duplicate alert in the view. Each button calls `LibraryViewModel.commit(plan:decision:)` (Open uses `.openExisting`, Import as Duplicate uses `.importAsNew`, Cancel discards).

- [ ] **Step 1: Add the duplicate alert to LibraryRootView**

Edit `Packages/Features/Library/Sources/Library/LibraryRootView.swift`. Find the existing `.alert(...)` for `errorAlertMessage` and add another `.alert` modifier *next to it* on the same view:

```swift
.alert(
    "Already in Your Library",
    isPresented: duplicateAlertBinding,
    presenting: viewModel.duplicatePrompt
) { prompt in
    Button("Open") {
        viewModel.duplicatePrompt = nil
        Task { await viewModel.commit(plan: prompt.plan, decision: .openExisting(prompt.existing.id)) }
    }
    Button("Import as Duplicate") {
        viewModel.duplicatePrompt = nil
        Task { await viewModel.commit(plan: prompt.plan, decision: .importAsNew) }
    }
    Button("Cancel", role: .cancel) {
        viewModel.duplicatePrompt = nil
    }
} message: { prompt in
    Text("\"\(prompt.existing.title)\" is already imported. What do you want to do?")
}
```

Add the helper binding inside the `LibraryRootView` struct:

```swift
private var duplicateAlertBinding: Binding<Bool> {
    Binding(
        get: { viewModel.duplicatePrompt != nil },
        set: { isPresented in if !isPresented { viewModel.duplicatePrompt = nil } }
    )
}
```

- [ ] **Step 2: Test the three decisions**

Append to `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift`:

```swift
extension LibraryViewModelTests {
    @Test func commitOpenExistingReturnsExistingItem() async {
        let (vm, _, importer, _) = Self.makeVM()
        let existing = Self.makeItem(title: "Existing")
        let plan = Self.makePlan(duplicates: [existing])
        importer.commitFactory = { _, decision in
            if case .openExisting = decision { return existing }
            return Self.makeItem(title: "DifferentItem")
        }

        await vm.commit(plan: plan, decision: .openExisting(existing.id))
        #expect(vm.pendingScoreToOpen?.id == existing.id)
    }

    @Test func commitImportAsNewProducesNewItem() async {
        let (vm, _, importer, _) = Self.makeVM()
        let existing = Self.makeItem(title: "Existing")
        let plan = Self.makePlan(duplicates: [existing])
        let new = Self.makeItem(title: "New")
        importer.commitFactory = { _, decision in
            if case .importAsNew = decision { return new }
            return existing
        }

        await vm.commit(plan: plan, decision: .importAsNew)
        #expect(vm.pendingScoreToOpen?.id == new.id)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `cd Packages/Features/Library && swift test --filter LibraryViewModelTests`
Expected: 9 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Sources/Library/LibraryRootView.swift \
        Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift
git commit -m "feat(library): duplicate import alert with 3-button decision"
```

---

### Task 18: Import — error alerts for known DomainError cases

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`
- Modify: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift`

Map known `DomainError` cases to the user-visible strings in the spec's error table. Other errors fall through to `localizedDescription`.

- [ ] **Step 1: Replace `describe` with the error table**

Edit `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`. Replace the `describe` method body:

```swift
private func describe(_ error: Error) -> String {
    if let domain = error as? DomainError {
        switch domain {
        case .unsupportedFormat:
            return String(localized: "Folino can't open this file type.")
        case .scoreParseFailed:
            return String(localized: "This file looks corrupted or isn't a valid score.")
        case .persistenceFailed:
            return String(localized: "There was a problem saving the score. Check available storage.")
        case .scoreFileNotFound, .scoreWriteFailed,
             .soundfontDownloadFailed, .syncFailed, .audioEngineFailed:
            return domain.errorDescription ?? "\(domain)"
        }
    }
    return (error as NSError).localizedDescription
}
```

- [ ] **Step 2: Add tests for each error case**

Append to `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift`:

```swift
extension LibraryViewModelTests {
    @Test func unsupportedFormatErrorMessage() async {
        let (vm, _, importer, _) = Self.makeVM()
        importer.prepareImportErrors = [.unsupportedFormat("xyz")]
        await vm.startImport(from: URL(filePath: "/tmp/x.xyz"))
        #expect(vm.errorAlertMessage == "Folino can't open this file type.")
    }

    @Test func parseErrorMessage() async {
        let (vm, _, importer, _) = Self.makeVM()
        importer.prepareImportErrors = [.scoreParseFailed(reason: "bad bytes")]
        await vm.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(vm.errorAlertMessage == "This file looks corrupted or isn't a valid score.")
    }

    @Test func persistenceErrorMessage() async {
        let (vm, _, importer, _) = Self.makeVM()
        importer.preparedPlans = [Self.makePlan()]
        importer.commitImportError = .persistenceFailed(reason: "disk full")
        await vm.startImport(from: URL(filePath: "/tmp/x.mscx"))
        #expect(vm.errorAlertMessage == "There was a problem saving the score. Check available storage.")
    }
}
```

- [ ] **Step 3: Run tests**

Run: `cd Packages/Features/Library && swift test --filter LibraryViewModelTests`
Expected: 12 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Sources/Library/LibraryViewModel.swift \
        Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift
git commit -m "feat(library): user-visible error messages for known DomainError cases"
```

---

## Phase G — Reader

### Task 19: Reader package adds `SheetMusicUI`; document the carve-out

**Files:**
- Modify: `Packages/Features/Reader/Package.swift`
- Modify: `docs/engineering/module-architecture.md`
- Delete: `Packages/Features/Reader/Sources/Reader/Placeholder.swift`
- Create: `Packages/Features/Reader/Sources/Reader/Reader.swift`

The architecture rule "Features → swift-sheet-music forbidden" must carve out an exception for view-layer libraries (`SheetMusicUI`, eventually `SheetMusicAudio`). Update the doc, then add the dependency to Reader's `Package.swift`.

- [ ] **Step 1: Update module-architecture.md**

Edit `docs/engineering/module-architecture.md`. Find the "Forbidden" bullet list (around line 21–27) and replace the Feature → swift-sheet-music line:

Replace:
```markdown
- Feature → `swift-sheet-music` directly (go through Domain re-exports).
```

With:
```markdown
- Feature → `swift-sheet-music` model / I/O modules directly (go through Domain re-exports for `SheetMusicCore`; route format I/O through `ScoreFileGateway`).

  *Carve-out:* Feature packages **may** depend directly on `SheetMusicUI`
  (and, when wired up later, `SheetMusicAudio`). These are view- and runtime-
  layer libraries whose entire purpose is to be composed inside an iOS shell.
  Wrapping them behind a Domain protocol would add a layer with no testable
  benefit. The Reader package consumes `ScoreView`, `PagedScoreView`, and
  `PlaybackCursorView` from `SheetMusicUI` directly.
```

- [ ] **Step 2: Update Reader Package.swift**

Edit `Packages/Features/Reader/Package.swift`. Replace the file with:

```swift
// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "Reader",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "Reader", targets: ["Reader"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
        .package(path: "../../Domain"),
        .package(path: "../../Utility"),
        .package(url: "git@github.com:jiyimeta/swift-sheet-music.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "Reader",
            dependencies: [
                "Domain",
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "UtilityUI", package: "Utility"),
                .product(name: "SheetMusicUI", package: "swift-sheet-music"),
            ],
            plugins: swiftLintPlugins
        ),
        .testTarget(name: "ReaderTests", dependencies: ["Reader"]),
    ]
)
```

- [ ] **Step 3: Replace Reader Placeholder with module marker**

```bash
rm Packages/Features/Reader/Sources/Reader/Placeholder.swift
```

Create `Packages/Features/Reader/Sources/Reader/Reader.swift`:

```swift
public enum ReaderModule {
    public static var isLinked: Bool { true }
}
```

- [ ] **Step 4: Resolve dependencies and build**

Run: `cd Packages/Features/Reader && swift package resolve && swift build`
Expected: builds clean (Plan #3 already pinned the same `swift-sheet-music` branch through Infrastructure; SwiftPM will reuse the cached resolution).

- [ ] **Step 5: Commit**

```bash
git add docs/engineering/module-architecture.md \
        Packages/Features/Reader/Package.swift \
        Packages/Features/Reader/Sources/Reader/
git commit -m "feat(reader): carve out SheetMusicUI dependency for Reader"
```

---

### Task 20: `ReaderViewModel` + `ReaderView` (load + display + lastOpenedAt)

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Create: `Packages/Features/Reader/Sources/Reader/ReaderView.swift`
- Create: `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakeScoreLibraryRepository.swift`
- Create: `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakeScoreFileGateway.swift`
- Create: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift`

The Reader holds `loadState: .loading | .loaded(Score) | .failed(message)` and updates `lastOpenedAt` exactly once per successful load.

- [ ] **Step 1: Add Reader test fakes**

Create `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakeScoreLibraryRepository.swift`:

```swift
import Domain
import Foundation
import Observation

@MainActor
@Observable
final class FakeScoreLibraryRepository: ScoreLibraryRepository {
    var scoreItems: [ScoreItem] = []
    var tags: [Tag] = []
    var playlists: [Playlist] = []

    var savedScoreItems: [ScoreItem] = []

    func refresh() async throws {}

    func saveScoreItem(_ item: ScoreItem) async throws {
        savedScoreItems.append(item)
        if let idx = scoreItems.firstIndex(where: { $0.id == item.id }) {
            scoreItems[idx] = item
        } else {
            scoreItems.append(item)
        }
    }
    func deleteScoreItem(id: ScoreItemID) async throws {}
    func saveTag(_ tag: Tag) async throws {}
    func deleteTag(id: TagID) async throws {}
    func savePlaylist(_ playlist: Playlist) async throws {}
    func deletePlaylist(id: PlaylistID) async throws {}
    func scoreItems(matchingContentHash contentHash: String) async throws -> [ScoreItem] { [] }
}
```

Create `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakeScoreFileGateway.swift`:

```swift
import Domain
import Foundation

final class FakeScoreFileGateway: ScoreFileGateway, @unchecked Sendable {
    var loadScoreResult: Result<(score: Score, summary: ScoreFileSummary), DomainError>

    init(loadScoreResult: Result<(score: Score, summary: ScoreFileSummary), DomainError> =
        .success((score: Score(division: 480, parts: [], staves: [], metaTags: [:]),
                  summary: ScoreFileSummary(
                    title: "Test", composer: nil, instrumentationSummary: "",
                    lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
                  )))) {
        self.loadScoreResult = loadScoreResult
    }

    func detectFormat(fileName: String) -> ScoreFormat? { .mscx }

    func loadFileMetadata(fileURL: URL) async throws -> ScoreFileSummary {
        throw DomainError.unsupportedFormat("test")
    }

    func loadScore(fileURL: URL) async throws -> (score: Score, summary: ScoreFileSummary) {
        switch loadScoreResult {
        case let .success(value): return value
        case let .failure(error): throw error
        }
    }

    func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) async throws {
        throw DomainError.unsupportedFormat(format.canonicalExtension)
    }
}
```

Note: `Score(division: 480, parts: [], staves: [], metaTags: [:])` uses the public `Score` initialiser from `SheetMusicCore`. If the actual signature differs, the implementer should adjust to match the version installed via SwiftPM (verify by reading `Packages/Features/Reader/.build/checkouts/swift-sheet-music/Sources/SheetMusicCore/Score/Score.swift`).

- [ ] **Step 2: Write the failing tests**

Create `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift`:

```swift
import Domain
import Foundation
import Testing
@testable import Reader

@Suite @MainActor
struct ReaderViewModelTests {
    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }

    @Test func successfulLoadTransitionsToLoadedAndUpdatesLastOpened() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let gateway = FakeScoreFileGateway()
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp")
        )

        await vm.load()
        if case .loaded = vm.loadState {} else {
            Issue.record("expected .loaded, got \(vm.loadState)")
        }
        #expect(repo.savedScoreItems.count == 1)
        #expect(repo.savedScoreItems.first?.lastOpenedAt != nil)
    }

    @Test func loadFailureTransitionsToFailedAndDoesNotSave() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let gateway = FakeScoreFileGateway(
            loadScoreResult: .failure(.scoreFileNotFound(name: "test.mscx"))
        )
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp")
        )

        await vm.load()
        if case .failed = vm.loadState {} else {
            Issue.record("expected .failed, got \(vm.loadState)")
        }
        #expect(repo.savedScoreItems.isEmpty)
    }

    @Test func reloadAfterFailureSucceeds() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        let gateway = FakeScoreFileGateway(
            loadScoreResult: .failure(.scoreParseFailed(reason: "bad"))
        )
        let vm = ReaderViewModel(
            scoreItem: item,
            repository: repo,
            gateway: gateway,
            scoresDirectory: URL(filePath: "/tmp")
        )
        await vm.load()
        if case .failed = vm.loadState {} else {
            Issue.record("expected initial failure")
        }

        gateway.loadScoreResult = .success(.init(
            score: Score(division: 480, parts: [], staves: [], metaTags: [:]),
            summary: ScoreFileSummary(
                title: "Test", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
            )
        ))
        await vm.load()
        if case .loaded = vm.loadState {} else {
            Issue.record("expected .loaded after retry, got \(vm.loadState)")
        }
    }
}
```

- [ ] **Step 3: Run tests to verify failure**

Run: `cd Packages/Features/Reader && swift test --filter ReaderViewModelTests`
Expected: compile error — `ReaderViewModel` not defined.

- [ ] **Step 4: Implement ReaderViewModel**

Create `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`:

```swift
import Domain
import Foundation
import Observation

@MainActor
@Observable
public final class ReaderViewModel {
    public enum LoadState {
        case loading
        case loaded(Score)
        case failed(message: String)
    }

    public private(set) var loadState: LoadState = .loading
    public private(set) var scoreItem: ScoreItem

    @ObservationIgnored
    private let repository: any ScoreLibraryRepository
    @ObservationIgnored
    private let gateway: any ScoreFileGateway
    @ObservationIgnored
    private let scoresDirectory: URL
    @ObservationIgnored
    private var hasUpdatedLastOpened = false

    public init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        gateway: any ScoreFileGateway,
        scoresDirectory: URL
    ) {
        self.scoreItem = scoreItem
        self.repository = repository
        self.gateway = gateway
        self.scoresDirectory = scoresDirectory
    }

    public func load() async {
        loadState = .loading
        let url = scoresDirectory.appending(path: scoreItem.localFileName)
        do {
            let (score, _) = try await gateway.loadScore(fileURL: url)
            loadState = .loaded(score)
            await updateLastOpenedAtOnce()
        } catch {
            let message = describe(error)
            loadState = .failed(message: message)
        }
    }

    private func updateLastOpenedAtOnce() async {
        guard !hasUpdatedLastOpened else { return }
        hasUpdatedLastOpened = true
        var updated = scoreItem
        updated.lastOpenedAt = Date()
        scoreItem = updated
        try? await repository.saveScoreItem(updated)
    }

    private func describe(_ error: Error) -> String {
        if let domain = error as? DomainError {
            switch domain {
            case .scoreFileNotFound:
                return String(localized: "The score file is missing or unreadable.")
            case .scoreParseFailed:
                return String(localized: "This file looks corrupted or isn't a valid score.")
            case .unsupportedFormat:
                return String(localized: "Folino can't open this file type.")
            default:
                return domain.errorDescription ?? "\(domain)"
            }
        }
        return (error as NSError).localizedDescription
    }
}
```

- [ ] **Step 5: Implement ReaderView (display only — file-missing error in Task 21)**

Create `Packages/Features/Reader/Sources/Reader/ReaderView.swift`:

```swift
import Domain
import SheetMusicUI
import SwiftUI

@MainActor
public struct ReaderView: View {
    @State private var viewModel: ReaderViewModel

    public init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        gateway: any ScoreFileGateway,
        scoresDirectory: URL
    ) {
        _viewModel = State(
            wrappedValue: ReaderViewModel(
                scoreItem: scoreItem,
                repository: repository,
                gateway: gateway,
                scoresDirectory: scoresDirectory
            )
        )
    }

    public var body: some View {
        Group {
            switch viewModel.loadState {
            case .loading:
                ProgressView()
                    .controlSize(.large)
            case let .loaded(score):
                ScrollView(.vertical) {
                    ScoreView(score: score)
                        .padding()
                }
            case .failed:
                // Real implementation lands in Task 21.
                ProgressView()
                    .controlSize(.large)
            }
        }
        .navigationTitle(viewModel.scoreItem.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }
}
```

- [ ] **Step 6: Run tests**

Run: `cd Packages/Features/Reader && swift test --filter ReaderViewModelTests`
Expected: all 3 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ \
        Packages/Features/Reader/Tests/ReaderTests/
git commit -m "feat(reader): ReaderViewModel + ReaderView with load and lastOpened update"
```

---

### Task 21: Reader file-missing inline error + Retry

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderView.swift`

Replace the placeholder `.failed` branch with the real `ContentUnavailableView` + Retry button.

- [ ] **Step 1: Replace the .failed branch**

Edit `Packages/Features/Reader/Sources/Reader/ReaderView.swift`. Replace the body's `.failed` case:

```swift
case let .failed(message):
    ContentUnavailableView {
        Label("Could not open this score", systemImage: "exclamationmark.triangle")
    } description: {
        Text(message)
    } actions: {
        Button("Retry") {
            Task { await viewModel.load() }
        }
        .buttonStyle(.borderedProminent)
    }
```

- [ ] **Step 2: Run tests**

Run: `cd Packages/Features/Reader && swift test --filter ReaderViewModelTests`
Expected: all 3 tests pass (no test changes; the view modification doesn't change the VM contract).

- [ ] **Step 3: Build the package**

Run: `cd Packages/Features/Reader && swift build`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderView.swift
git commit -m "feat(reader): file-missing inline error with Retry"
```

---

## Phase H — Settings

### Task 22: SettingsSheet with License row

**Files:**
- Delete: `Packages/Features/Settings/Sources/Settings/Placeholder.swift`
- Create: `Packages/Features/Settings/Sources/Settings/Settings.swift`
- Create: `Packages/Features/Settings/Sources/Settings/SettingsSheet.swift`
- Create: `Packages/Features/Settings/Tests/SettingsTests/SettingsSheetTests.swift`

`Settings` is a sheet with one row that pushes a `LicenseListView`-shaped destination. The Settings module does not depend on `LicenseList`; App injects the destination view as a closure.

- [ ] **Step 1: Replace Placeholder**

```bash
rm Packages/Features/Settings/Sources/Settings/Placeholder.swift
```

Create `Packages/Features/Settings/Sources/Settings/Settings.swift`:

```swift
public enum SettingsModule {
    public static var isLinked: Bool { true }
}
```

- [ ] **Step 2: Implement SettingsSheet**

Create `Packages/Features/Settings/Sources/Settings/SettingsSheet.swift`:

```swift
import SwiftUI

@MainActor
public struct SettingsSheet<LicenseContent: View>: View {
    private let licenseContent: () -> LicenseContent
    @Environment(\.dismiss) private var dismiss

    public init(@ViewBuilder licenseContent: @escaping () -> LicenseContent) {
        self.licenseContent = licenseContent
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("About") {
                    NavigationLink {
                        licenseContent()
                            .navigationTitle("Licenses")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Licenses", systemImage: "doc.text")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsSheet { Text("License placeholder") }
}
```

- [ ] **Step 3: Smoke test**

Create `Packages/Features/Settings/Tests/SettingsTests/SettingsSheetTests.swift`:

```swift
import SwiftUI
import Testing
@testable import Settings

@Suite @MainActor
struct SettingsSheetTests {
    @Test func sheetConstructsWithStubLicenseContent() {
        let sheet = SettingsSheet { Text("License placeholder") }
        // The view is a value; if it constructs, this test passes.
        _ = sheet.body
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd Packages/Features/Settings && swift test --filter SettingsSheetTests`
Expected: passes.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Settings/Sources/Settings/ \
        Packages/Features/Settings/Tests/SettingsTests/
git commit -m "feat(settings): SettingsSheet with License row composition surface"
```

---

## Phase I — App composition

### Task 23: Replace AppShellView with the real chrome

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/LibraryRootView.swift`
- Modify: `App/AppShellView.swift`

Compose `LibraryRootView` + `ReaderView` using `NavigationSplitView` on iPad regular size class and `NavigationStack` on iPhone/compact. App watches `LibraryViewModel.pendingScoreToOpen` via `.onChange` and pushes the Reader. Settings is a sheet from a gear toolbar item. App injects `LicenseListView()` for the License destination.

To make the watcher possible, App must own the `LibraryViewModel` instance (so it can observe its property). Step 1 lifts the VM out of `LibraryRootView`'s internal `@State`; Step 2 wires App.

- [ ] **Step 1: Lift LibraryViewModel out of LibraryRootView**

Edit `Packages/Features/Library/Sources/Library/LibraryRootView.swift`. Replace the init and `_viewModel` initializer:

```swift
@MainActor
public struct LibraryRootView<LicenseContent: View>: View {
    @Bindable var viewModel: LibraryViewModel
    private let onOpenScore: (ScoreItem) -> Void
    private let licenseContent: () -> LicenseContent

    @State private var editTagsTarget: ScoreItem?
    @State private var addToPlaylistTarget: ScoreItem?

    public init(
        viewModel: LibraryViewModel,
        onOpenScore: @escaping (ScoreItem) -> Void,
        @ViewBuilder licenseContent: @escaping () -> LicenseContent
    ) {
        self.viewModel = viewModel
        self.onOpenScore = onOpenScore
        self.licenseContent = licenseContent
    }
    // ... rest of body unchanged
}
```

- [ ] **Step 2: Replace AppShellView**

Edit `App/AppShellView.swift`. Replace the file contents with:

```swift
import Domain
import Library
import LicenseList
import Reader
import Settings
import SwiftUI

struct AppShellView: View {
    let bootstrap: AppBootstrap

    var body: some View {
        Group {
            if let repository = bootstrap.repository,
               let importer = bootstrap.importer,
               let gateway = bootstrap.gateway,
               bootstrap.isReady {
                ReadyShell(
                    repository: repository,
                    importer: importer,
                    gateway: gateway,
                    scoresDirectory: AppPaths.scoresDirectory
                )
            } else if let failure = bootstrap.failure {
                ContentUnavailableView {
                    Label("Folino couldn't start", systemImage: "exclamationmark.triangle")
                } description: {
                    Text((failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription)
                }
            } else {
                ProgressView().controlSize(.large)
            }
        }
    }
}

private struct ReadyShell: View {
    let repository: any ScoreLibraryRepository
    let importer: any ScoreFileImporter
    let gateway: any ScoreFileGateway
    let scoresDirectory: URL

    @State private var libraryVM: LibraryViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var path = NavigationPath()
    @State private var detailScoreItem: ScoreItem?
    @State private var isSettingsPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    init(
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway,
        scoresDirectory: URL
    ) {
        self.repository = repository
        self.importer = importer
        self.gateway = gateway
        self.scoresDirectory = scoresDirectory
        _libraryVM = State(
            wrappedValue: LibraryViewModel(
                repository: repository, importer: importer, gateway: gateway
            )
        )
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar
                } detail: {
                    if let item = detailScoreItem {
                        ReaderView(
                            scoreItem: item,
                            repository: repository,
                            gateway: gateway,
                            scoresDirectory: scoresDirectory
                        )
                    } else {
                        ContentUnavailableView(
                            "Select a score",
                            systemImage: "music.note"
                        )
                    }
                }
            } else {
                NavigationStack(path: $path) {
                    LibraryRootView(
                        viewModel: libraryVM,
                        onOpenScore: { path.append($0) },
                        licenseContent: { LicenseListView() }
                    )
                    .toolbar { settingsToolbarItem }
                    .navigationDestination(for: ScoreItem.self) { item in
                        ReaderView(
                            scoreItem: item,
                            repository: repository,
                            gateway: gateway,
                            scoresDirectory: scoresDirectory
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsSheet { LicenseListView() }
        }
        .onChange(of: libraryVM.pendingScoreToOpen?.id) { _, newID in
            guard let newID,
                  let item = libraryVM.pendingScoreToOpen,
                  item.id == newID else { return }
            libraryVM.pendingScoreToOpen = nil
            if horizontalSizeClass == .regular {
                detailScoreItem = item
                columnVisibility = .detailOnly
            } else {
                path.append(item)
            }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        LibraryRootView(
            viewModel: libraryVM,
            onOpenScore: { item in
                detailScoreItem = item
                columnVisibility = .detailOnly
            },
            licenseContent: { LicenseListView() }
        )
        .toolbar { settingsToolbarItem }
    }

    @ToolbarContentBuilder
    private var settingsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                isSettingsPresented = true
            } label: {
                Image(systemName: "gear").accessibilityLabel("Settings")
            }
        }
    }
}
```

- [ ] **Step 3: Build the app**

Run: `xcodegen generate && xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`
Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
git add App/AppShellView.swift Packages/Features/Library/Sources/Library/LibraryRootView.swift
git commit -m "feat(app): wire Library/Reader/Settings into NavigationSplitView/Stack chrome"
```

---

## Phase J — Localization

### Task 24: Localization sweep — populate en + ja string catalogs

**Files:**
- Create: `Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings`
- Create: `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings`
- Create: `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings`
- Modify: `Packages/Features/Library/Package.swift`
- Modify: `Packages/Features/Reader/Package.swift`
- Modify: `Packages/Features/Settings/Package.swift`

Add `Localizable.xcstrings` files with en + ja entries for every user-visible string. Update each `Package.swift` target's `resources:` to include `.process("Resources")`.

The xcstrings format is a JSON document Xcode reads. We seed it with the strings used in this plan; future Xcode editor sessions will round-trip and pretty-print. For a hand-edited initial seed, a minimal JSON shape per key is:

```json
{
  "sourceLanguage": "en",
  "version": "1.0",
  "strings": {
    "Library": {
      "extractionState": "manual",
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Library" } },
        "ja": { "stringUnit": { "state": "translated", "value": "ライブラリ" } }
      }
    }
  }
}
```

- [ ] **Step 1: Add `resources:` to each Feature target**

Edit `Packages/Features/Library/Package.swift`. Replace the `targets:` block:

```swift
targets: [
    .target(
        name: "Library",
        dependencies: [
            "Domain",
            .product(name: "UtilityCore", package: "Utility"),
            .product(name: "UtilityUI", package: "Utility"),
        ],
        resources: [.process("Resources")],
        plugins: swiftLintPlugins
    ),
    .testTarget(name: "LibraryTests", dependencies: ["Library"]),
]
```

Apply the same change to `Packages/Features/Reader/Package.swift` and `Packages/Features/Settings/Package.swift`.

- [ ] **Step 2: Create the Library xcstrings**

Create `Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings`:

```json
{
  "sourceLanguage": "en",
  "version": "1.0",
  "strings": {
    "Library": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Library" } },
        "ja": { "stringUnit": { "state": "translated", "value": "ライブラリ" } }
      }
    },
    "All Scores": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "All Scores" } },
        "ja": { "stringUnit": { "state": "translated", "value": "すべての楽譜" } }
      }
    },
    "Tags": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Tags" } },
        "ja": { "stringUnit": { "state": "translated", "value": "タグ" } }
      }
    },
    "Playlists": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Playlists" } },
        "ja": { "stringUnit": { "state": "translated", "value": "プレイリスト" } }
      }
    },
    "Favorites": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Favorites" } },
        "ja": { "stringUnit": { "state": "translated", "value": "お気に入り" } }
      }
    },
    "Browse": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Browse" } },
        "ja": { "stringUnit": { "state": "translated", "value": "閲覧" } }
      }
    },
    "Recently Opened": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Recently Opened" } },
        "ja": { "stringUnit": { "state": "translated", "value": "最近開いた" } }
      }
    },
    "Open": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Open" } },
        "ja": { "stringUnit": { "state": "translated", "value": "開く" } }
      }
    },
    "Favorite": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Favorite" } },
        "ja": { "stringUnit": { "state": "translated", "value": "お気に入り" } }
      }
    },
    "Unfavorite": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Unfavorite" } },
        "ja": { "stringUnit": { "state": "translated", "value": "お気に入りを解除" } }
      }
    },
    "Edit Tags…": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Edit Tags…" } },
        "ja": { "stringUnit": { "state": "translated", "value": "タグを編集…" } }
      }
    },
    "Add to Playlist…": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Add to Playlist…" } },
        "ja": { "stringUnit": { "state": "translated", "value": "プレイリストに追加…" } }
      }
    },
    "Delete": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Delete" } },
        "ja": { "stringUnit": { "state": "translated", "value": "削除" } }
      }
    },
    "Cancel": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Cancel" } },
        "ja": { "stringUnit": { "state": "translated", "value": "キャンセル" } }
      }
    },
    "Done": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Done" } },
        "ja": { "stringUnit": { "state": "translated", "value": "完了" } }
      }
    },
    "Save": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Save" } },
        "ja": { "stringUnit": { "state": "translated", "value": "保存" } }
      }
    },
    "Add": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Add" } },
        "ja": { "stringUnit": { "state": "translated", "value": "追加" } }
      }
    },
    "Sort": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Sort" } },
        "ja": { "stringUnit": { "state": "translated", "value": "並び替え" } }
      }
    },
    "sort.dateAdded": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Date Added" } },
        "ja": { "stringUnit": { "state": "translated", "value": "追加日" } }
      }
    },
    "sort.title": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Title" } },
        "ja": { "stringUnit": { "state": "translated", "value": "タイトル" } }
      }
    },
    "sort.composer": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Composer" } },
        "ja": { "stringUnit": { "state": "translated", "value": "作曲家" } }
      }
    },
    "sort.lastOpened": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Last Opened" } },
        "ja": { "stringUnit": { "state": "translated", "value": "最後に開いた" } }
      }
    },
    "Manual Order": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Manual Order" } },
        "ja": { "stringUnit": { "state": "translated", "value": "手動の順序" } }
      }
    },
    "Already in Your Library": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Already in Your Library" } },
        "ja": { "stringUnit": { "state": "translated", "value": "ライブラリに既に存在します" } }
      }
    },
    "Import as Duplicate": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Import as Duplicate" } },
        "ja": { "stringUnit": { "state": "translated", "value": "複製として取り込む" } }
      }
    },
    "Import Score": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Import Score" } },
        "ja": { "stringUnit": { "state": "translated", "value": "楽譜を取り込む" } }
      }
    },
    "Settings": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Settings" } },
        "ja": { "stringUnit": { "state": "translated", "value": "設定" } }
      }
    },
    "No Scores Yet": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "No Scores Yet" } },
        "ja": { "stringUnit": { "state": "translated", "value": "まだ楽譜がありません" } }
      }
    },
    "Import your first score to get started.": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Import your first score to get started." } },
        "ja": { "stringUnit": { "state": "translated", "value": "最初の楽譜を取り込んで始めましょう。" } }
      }
    },
    "No Tags": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "No Tags" } },
        "ja": { "stringUnit": { "state": "translated", "value": "タグなし" } }
      }
    },
    "Add tags from a score's context menu, or tap + above.": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Add tags from a score's context menu, or tap + above." } },
        "ja": { "stringUnit": { "state": "translated", "value": "楽譜のコンテキストメニューから、または上の + ボタンからタグを追加できます。" } }
      }
    },
    "No Playlists": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "No Playlists" } },
        "ja": { "stringUnit": { "state": "translated", "value": "プレイリストなし" } }
      }
    },
    "Create a playlist with the + button above.": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Create a playlist with the + button above." } },
        "ja": { "stringUnit": { "state": "translated", "value": "上の + ボタンでプレイリストを作成できます。" } }
      }
    },
    "No Scores in This Playlist": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "No Scores in This Playlist" } },
        "ja": { "stringUnit": { "state": "translated", "value": "このプレイリストに楽譜がありません" } }
      }
    },
    "Add scores from the context menu of any score row.": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Add scores from the context menu of any score row." } },
        "ja": { "stringUnit": { "state": "translated", "value": "楽譜行のコンテキストメニューから追加できます。" } }
      }
    },
    "Folino can't open this file type.": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Folino can't open this file type." } },
        "ja": { "stringUnit": { "state": "translated", "value": "このファイル形式は対応していません。" } }
      }
    },
    "This file looks corrupted or isn't a valid score.": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "This file looks corrupted or isn't a valid score." } },
        "ja": { "stringUnit": { "state": "translated", "value": "ファイルが破損しているか、有効な楽譜ではありません。" } }
      }
    },
    "There was a problem saving the score. Check available storage.": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "There was a problem saving the score. Check available storage." } },
        "ja": { "stringUnit": { "state": "translated", "value": "楽譜を保存できませんでした。空き容量を確認してください。" } }
      }
    },
    "Select a score": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Select a score" } },
        "ja": { "stringUnit": { "state": "translated", "value": "楽譜を選択してください" } }
      }
    }
  }
}
```

- [ ] **Step 3: Create the Reader xcstrings**

Create `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings`:

```json
{
  "sourceLanguage": "en",
  "version": "1.0",
  "strings": {
    "Could not open this score": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Could not open this score" } },
        "ja": { "stringUnit": { "state": "translated", "value": "この楽譜を開けませんでした" } }
      }
    },
    "The score file is missing or unreadable.": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "The score file is missing or unreadable." } },
        "ja": { "stringUnit": { "state": "translated", "value": "楽譜ファイルが見つからないか読み込めません。" } }
      }
    },
    "Retry": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Retry" } },
        "ja": { "stringUnit": { "state": "translated", "value": "再試行" } }
      }
    },
    "Folino can't open this file type.": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Folino can't open this file type." } },
        "ja": { "stringUnit": { "state": "translated", "value": "このファイル形式は対応していません。" } }
      }
    },
    "This file looks corrupted or isn't a valid score.": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "This file looks corrupted or isn't a valid score." } },
        "ja": { "stringUnit": { "state": "translated", "value": "ファイルが破損しているか、有効な楽譜ではありません。" } }
      }
    }
  }
}
```

- [ ] **Step 4: Create the Settings xcstrings**

Create `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings`:

```json
{
  "sourceLanguage": "en",
  "version": "1.0",
  "strings": {
    "Settings": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Settings" } },
        "ja": { "stringUnit": { "state": "translated", "value": "設定" } }
      }
    },
    "About": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "About" } },
        "ja": { "stringUnit": { "state": "translated", "value": "情報" } }
      }
    },
    "Licenses": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Licenses" } },
        "ja": { "stringUnit": { "state": "translated", "value": "ライセンス" } }
      }
    },
    "Done": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Done" } },
        "ja": { "stringUnit": { "state": "translated", "value": "完了" } }
      }
    }
  }
}
```

- [ ] **Step 5: Build all packages**

Run: `cd Packages/Features/Library && swift build && cd ../Reader && swift build && cd ../Settings && swift build`
Expected: each builds clean.

- [ ] **Step 6: Run all Feature tests as a regression check**

Run:
```bash
cd Packages/Features/Library && swift test
cd ../Reader && swift test
cd ../Settings && swift test
```
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Library/Package.swift \
        Packages/Features/Library/Sources/Library/Resources/ \
        Packages/Features/Reader/Package.swift \
        Packages/Features/Reader/Sources/Reader/Resources/ \
        Packages/Features/Settings/Package.swift \
        Packages/Features/Settings/Sources/Settings/Resources/
git commit -m "feat(localization): en+ja string catalogs for Library/Reader/Settings"
```

---

## Phase K — Verification

### Task 25: Manual verification on iPhone and iPad simulators

This task is hands-on; no commit. Document findings as you go and capture follow-ups in a scratch note. The intent is to confirm the user-visible flow is sound before merging.

- [ ] **Step 1: Verify Xcode is open**

Run: `mcp__xcode__XcodeListWindows`
Expected: shows `Folino.xcodeproj` open.

If not open:
```bash
open Folino.xcodeproj
```

- [ ] **Step 2: Render previews where possible**

For each of these previews, use `mcp__xcode__RenderPreview` and inspect the PNG via `Read`:

- `Packages/Features/Library/Sources/Library/ScoreRow.swift` (`#Preview` shows two row states)
- `Packages/Features/Settings/Sources/Settings/SettingsSheet.swift`

Expected: both render without errors. If the preview plugin needs trust, debug rather than skip.

- [ ] **Step 3: Build and install on iPhone simulator**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build
```

Then install + launch. Hand control to the user with this checklist:
- App opens to "No Scores Yet" empty state.
- Tap `+` → `.fileImporter` shows.
- Pick a `.mscx` file → Reader opens with the score.
- Back to Library → row visible with title/composer.
- Star (swipe leading) → row shows ★.
- Long-press → context menu lists Open / Favorite / Edit Tags / Add to Playlist / Delete.
- Edit Tags → toggle tag → close → tag count appears under "Tags".
- Tags drill-down → tap tag → filtered list shows the score.
- Add to Playlist → create a new playlist → Reader auto-opens the same score (because of `pendingScoreToOpen`? — verify expectations: actually the playlist add does *not* trigger pendingScoreToOpen; only successful imports do).
- Delete from swipe → confirmation alert → row gone.
- Settings gear → License row → LicenseListView shows third-party packages.

- [ ] **Step 4: Build and install on iPad simulator**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPad (A16),OS=latest' \
  -skipPackagePluginValidation build
```

Verify split-view: Library on left, "Select a score" placeholder on right. Tap a score → Reader replaces detail. Sidebar can be hidden via the chevron toggle.

- [ ] **Step 5: Re-import the same file → duplicate alert**

In the simulator, repeat import with the same `.mscx`. Verify the alert "Already in Your Library" shows three buttons; "Open" navigates to the existing score; "Import as Duplicate" creates a second row with the same content; "Cancel" stays in Library with no change.

- [ ] **Step 6: Hand off**

Report the full verification result back to the user. Per CLAUDE.md, do not drive simulator gestures yourself — describe what to look for and let the user confirm.

---

## Self-review checklist (run before opening the merge)

- [ ] All 25 tasks complete and committed
- [ ] `swift test` passes in `Domain`, `Library`, `Reader`, `Settings`
- [ ] `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build` succeeds
- [ ] Manual verification (Task 25) recorded
- [ ] No new SwiftLint warnings

When ready, run `superpowers:finishing-a-development-branch` to merge `feat/library-and-minimum-reader` back into `main`.

# Library Collapsible Sections — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pull Playlists and Tags up to the Library root as collapsible sections (top-5 by recently used, plus See All when N>5), persist fold state, push Favorites one level deeper as a Browse row, and consolidate creation into a toolbar `+` Menu.

**Architecture:** Pure-Swift sort helpers in a new `LibrarySort.swift`; UI changes confined to `LibraryRootScreen.swift`; one new `Source.favorites` case on `ScoreListViewModel` re-uses the existing `ScoreListScreen`; `LibraryRoute` gains a `.favorites` case; create logic lifts into `LibraryViewModel` so root and existing list screens share one path. Fold persistence via `@AppStorage`. Spec: `docs/superpowers/specs/2026-05-08-library-collapsible-sections-design.md`.

**Tech Stack:** Swift 6.3, SwiftUI (iOS 26+), Swift Testing (`@Test`, `#expect`).

---

## File map

- **New:**
  - `Packages/Features/Library/Sources/Library/LibrarySort.swift`
  - `Packages/Features/Library/Tests/LibraryTests/LibrarySortTests.swift`
- **Modify:**
  - `Packages/Features/Library/Sources/Library/LibraryRoute.swift`
  - `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`
  - `Packages/Features/Library/Sources/Library/ScoreListViewModel.swift`
  - `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift`
  - `Packages/Features/Library/Sources/Library/Screens/PlaylistsListScreen.swift`
  - `Packages/Features/Library/Sources/Library/Screens/TagsListScreen.swift`
  - `Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings`
  - `Packages/Features/Library/Tests/LibraryTests/ScoreListViewModelTests.swift`
  - `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift`

---

## Task 1: LibrarySort helpers (recently-used ordering)

**Files:**
- Create: `Packages/Features/Library/Sources/Library/LibrarySort.swift`
- Create: `Packages/Features/Library/Tests/LibraryTests/LibrarySortTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Packages/Features/Library/Tests/LibraryTests/LibrarySortTests.swift`:

```swift
import Domain
import Foundation
@testable import Library
import Testing

@Suite struct LibrarySortTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func item(
        id: ScoreItemID = ScoreItemID(),
        title: String,
        lastOpenedOffset: TimeInterval?,
        tagIDs: Set<TagID> = []
    ) -> ScoreItem {
        ScoreItem(
            id: id,
            title: title, composer: nil, instrumentationSummary: nil,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: base, lastOpenedAt: lastOpenedOffset.map { base.addingTimeInterval($0) },
            tagIDs: tagIDs, isFavorite: false
        )
    }

    // MARK: - playlistsByRecentlyUsed

    @Test func playlistsOrderByMaxLastOpenedOfContainedItems() {
        let a = Self.item(title: "a", lastOpenedOffset: 100)
        let b = Self.item(title: "b", lastOpenedOffset: 300)
        let c = Self.item(title: "c", lastOpenedOffset: 200)
        let p1 = Playlist(name: "P1", orderedScoreItemIDs: [a.id, b.id], createdAt: Self.base)
        let p2 = Playlist(name: "P2", orderedScoreItemIDs: [c.id], createdAt: Self.base)
        let result = playlistsByRecentlyUsed(
            [p1, p2], scoreItems: [a, b, c], limit: 10
        )
        #expect(result.map(\.name) == ["P1", "P2"]) // P1 reaches 300 (b), P2 only 200 (c)
    }

    @Test func emptyPlaylistFallsBackToCreatedAt() {
        let recent = Self.item(title: "recent", lastOpenedOffset: 100)
        let withItem = Playlist(
            name: "WithItem",
            orderedScoreItemIDs: [recent.id],
            createdAt: Self.base.addingTimeInterval(-10_000)
        )
        let empty = Playlist(
            name: "Empty",
            orderedScoreItemIDs: [],
            createdAt: Self.base.addingTimeInterval(10_000)
        )
        let result = playlistsByRecentlyUsed(
            [withItem, empty], scoreItems: [recent], limit: 10
        )
        // Empty's createdAt (base+10_000) > WithItem's max (base+100)
        #expect(result.map(\.name) == ["Empty", "WithItem"])
    }

    @Test func playlistMissingItemIDsTreatedAsAbsent() {
        let live = Self.item(title: "live", lastOpenedOffset: 100)
        let stale = Playlist(
            name: "Stale",
            orderedScoreItemIDs: [ScoreItemID(), ScoreItemID()],
            createdAt: Self.base.addingTimeInterval(50)
        )
        let kept = Playlist(
            name: "Kept",
            orderedScoreItemIDs: [live.id],
            createdAt: Self.base
        )
        let result = playlistsByRecentlyUsed(
            [stale, kept], scoreItems: [live], limit: 10
        )
        #expect(result.map(\.name) == ["Kept", "Stale"]) // Kept 100 vs Stale 50 (createdAt fallback)
    }

    @Test func playlistLimitTruncates() {
        let recent = Self.item(title: "recent", lastOpenedOffset: 100)
        let p1 = Playlist(name: "P1", orderedScoreItemIDs: [recent.id], createdAt: Self.base)
        let p2 = Playlist(name: "P2", orderedScoreItemIDs: [recent.id], createdAt: Self.base.addingTimeInterval(50))
        let p3 = Playlist(name: "P3", orderedScoreItemIDs: [recent.id], createdAt: Self.base.addingTimeInterval(25))
        let result = playlistsByRecentlyUsed([p1, p2, p3], scoreItems: [recent], limit: 2)
        #expect(result.count == 2)
    }

    // MARK: - tagsByRecentlyUsed

    @Test func tagsOrderByMaxLastOpenedOfTaggedItems() {
        let t1 = Tag(name: "t1", colorHex: "#000")
        let t2 = Tag(name: "t2", colorHex: "#000")
        let i1 = Self.item(title: "i1", lastOpenedOffset: 100, tagIDs: [t1.id])
        let i2 = Self.item(title: "i2", lastOpenedOffset: 300, tagIDs: [t2.id])
        let result = tagsByRecentlyUsed([t1, t2], scoreItems: [i1, i2], limit: 10)
        #expect(result.map(\.name) == ["t2", "t1"])
    }

    @Test func tagWithNoTaggedItemsSinksToBottom() {
        let active = Tag(name: "active", colorHex: "#000")
        let stale = Tag(name: "stale", colorHex: "#000")
        let item = Self.item(title: "i", lastOpenedOffset: 50, tagIDs: [active.id])
        let result = tagsByRecentlyUsed([stale, active], scoreItems: [item], limit: 10)
        #expect(result.map(\.name) == ["active", "stale"])
    }

    @Test func tagsTiebreakByNameAscending() {
        let bare1 = Tag(name: "bbb", colorHex: "#000")
        let bare2 = Tag(name: "aaa", colorHex: "#000")
        let result = tagsByRecentlyUsed([bare1, bare2], scoreItems: [], limit: 10)
        #expect(result.map(\.name) == ["aaa", "bbb"])
    }

    @Test func tagLimitTruncates() {
        let tags = (0 ..< 8).map { Tag(name: "tag\($0)", colorHex: "#000") }
        let result = tagsByRecentlyUsed(tags, scoreItems: [], limit: 5)
        #expect(result.count == 5)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --package-path Packages/Features/Library --filter LibrarySortTests
```

Expected: compile error or all tests fail because `playlistsByRecentlyUsed` / `tagsByRecentlyUsed` don't exist.

- [ ] **Step 3: Implement `LibrarySort.swift`**

Create `Packages/Features/Library/Sources/Library/LibrarySort.swift`:

```swift
import Domain
import Foundation

/// Top-N playlists ordered by the most recent `lastOpenedAt` of any contained
/// score item. Empty playlists, or playlists whose every contained ID has no
/// `lastOpenedAt`, fall back to `createdAt`. Ties tiebreak by `name` ascending.
func playlistsByRecentlyUsed(
    _ playlists: [Playlist],
    scoreItems: [ScoreItem],
    limit: Int
) -> [Playlist] {
    guard limit > 0 else { return [] }
    let lookup: [ScoreItemID: ScoreItem] = Dictionary(
        uniqueKeysWithValues: scoreItems.map { ($0.id, $0) }
    )
    let keyed: [(Playlist, Date)] = playlists.map { playlist in
        let dates: [Date] = playlist.orderedScoreItemIDs
            .compactMap { lookup[$0]?.lastOpenedAt }
        let key = dates.max() ?? playlist.createdAt
        return (playlist, key)
    }
    let sorted = keyed.sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
    }
    return Array(sorted.prefix(limit).map(\.0))
}

/// Top-N tags ordered by the most recent `lastOpenedAt` across score items
/// carrying the tag. Tags with no items (or no opened items) sink to the
/// bottom and tiebreak by `name` ascending.
func tagsByRecentlyUsed(
    _ tags: [Tag],
    scoreItems: [ScoreItem],
    limit: Int
) -> [Tag] {
    guard limit > 0 else { return [] }
    var maxByTag: [TagID: Date] = [:]
    for item in scoreItems {
        guard let opened = item.lastOpenedAt else { continue }
        for tagID in item.tagIDs {
            if let existing = maxByTag[tagID], existing >= opened { continue }
            maxByTag[tagID] = opened
        }
    }
    let keyed: [(Tag, Date)] = tags.map { tag in
        (tag, maxByTag[tag.id] ?? .distantPast)
    }
    let sorted = keyed.sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
    }
    return Array(sorted.prefix(limit).map(\.0))
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --package-path Packages/Features/Library --filter LibrarySortTests
```

Expected: all 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/Library/LibrarySort.swift \
        Packages/Features/Library/Tests/LibraryTests/LibrarySortTests.swift
git commit -m "feat(library): add recently-used sort helpers for playlists and tags"
```

---

## Task 2: Add `ScoreListViewModel.Source.favorites`

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/ScoreListViewModel.swift`
- Modify: `Packages/Features/Library/Tests/LibraryTests/ScoreListViewModelTests.swift`

- [ ] **Step 1: Add the failing test**

Append to `ScoreListViewModelTests.swift` (inside the existing `@Suite @MainActor struct ScoreListViewModelTests {`):

```swift
@Test func sourceFavoritesFiltersByIsFavoriteFlag() {
    var fav = Self.makeItem(title: "Fav")
    fav.isFavorite = true
    let plain = Self.makeItem(title: "Plain")
    var fav2 = Self.makeItem(title: "Fav2")
    fav2.isFavorite = true
    let repo = Self.makeRepo(items: [plain, fav, fav2])
    let vm = ScoreListViewModel(source: .favorites, repository: repo)
    vm.sort = .titleAsc
    #expect(vm.displayedItems.map(\.title) == ["Fav", "Fav2"])
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --package-path Packages/Features/Library --filter ScoreListViewModelTests/sourceFavoritesFiltersByIsFavoriteFlag
```

Expected: compile error — `Source` has no `.favorites` case.

- [ ] **Step 3: Add `.favorites` to `ScoreListViewModel`**

In `Packages/Features/Library/Sources/Library/ScoreListViewModel.swift`:

Update `Source` enum (around line 9) to add the new case:

```swift
public enum Source: Hashable, Sendable {
    case all
    case favorites
    case taggedWith(TagID)
    case playlist(orderedIDs: [ScoreItemID])
}
```

Update `init` switch (around line 32) — add `.favorites` to the same branch as `.all` / `.taggedWith`:

```swift
switch source {
case .all, .favorites, .taggedWith:
    sort = .dateAddedDesc
    manualOrder = false
case .playlist:
    sort = .dateAddedDesc
    manualOrder = true
}
```

Update `scope(_:)` switch (around line 65) — add `.favorites` branch:

```swift
private func scope(_ items: [ScoreItem]) -> [ScoreItem] {
    switch source {
    case .all:
        return items
    case .favorites:
        return items.filter(\.isFavorite)
    case let .taggedWith(tagID):
        return items.filter { $0.tagIDs.contains(tagID) }
    case let .playlist(orderedIDs):
        let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return orderedIDs.compactMap { lookup[$0] }
    }
}
```

- [ ] **Step 4: Run all `ScoreListViewModelTests` to verify**

```bash
swift test --package-path Packages/Features/Library --filter ScoreListViewModelTests
```

Expected: all tests pass (existing + new).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/Library/ScoreListViewModel.swift \
        Packages/Features/Library/Tests/LibraryTests/ScoreListViewModelTests.swift
git commit -m "feat(library): add ScoreListViewModel.Source.favorites"
```

---

## Task 3: Lift create-playlist / create-tag into `LibraryViewModel`

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/PlaylistsListScreen.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/TagsListScreen.swift`
- Modify: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift`

- [ ] **Step 1: Add failing tests**

Append to the existing `LibraryViewModelTests` suite in `LibraryViewModelTests.swift` (use the existing helper `makeViewModel()` if present; otherwise mirror the construction style of neighboring tests):

```swift
@Test func createPlaylistTrimmedNonEmptyPersists() async {
    let repo = FakeScoreLibraryRepository()
    let vm = LibraryViewModel(
        repository: repo,
        importer: FakeScoreFileImporter(),
        gateway: FakeScoreFileGateway(),
        shareService: FakeScoreShareService()
    )
    await vm.createPlaylist(name: "  Recital  ")
    #expect(repo.savedPlaylists.count == 1)
    #expect(repo.savedPlaylists.first?.name == "Recital")
    #expect(repo.savedPlaylists.first?.orderedScoreItemIDs.isEmpty == true)
}

@Test func createPlaylistEmptyNameNoOp() async {
    let repo = FakeScoreLibraryRepository()
    let vm = LibraryViewModel(
        repository: repo,
        importer: FakeScoreFileImporter(),
        gateway: FakeScoreFileGateway(),
        shareService: FakeScoreShareService()
    )
    await vm.createPlaylist(name: "   ")
    #expect(repo.savedPlaylists.isEmpty)
}

@Test func createTagTrimmedNonEmptyPersistsWithDefaultColor() async {
    let repo = FakeScoreLibraryRepository()
    let vm = LibraryViewModel(
        repository: repo,
        importer: FakeScoreFileImporter(),
        gateway: FakeScoreFileGateway(),
        shareService: FakeScoreShareService()
    )
    await vm.createTag(name: "  Practice  ")
    #expect(repo.savedTags.count == 1)
    #expect(repo.savedTags.first?.name == "Practice")
    #expect(repo.savedTags.first?.colorHex == "#5856D6")
}

@Test func createTagEmptyNameNoOp() async {
    let repo = FakeScoreLibraryRepository()
    let vm = LibraryViewModel(
        repository: repo,
        importer: FakeScoreFileImporter(),
        gateway: FakeScoreFileGateway(),
        shareService: FakeScoreShareService()
    )
    await vm.createTag(name: "")
    #expect(repo.savedTags.isEmpty)
}
```

(If the existing test file already constructs a `LibraryViewModel` via a helper, prefer that helper over the inline init. Inspect the file before editing.)

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --package-path Packages/Features/Library --filter LibraryViewModelTests
```

Expected: compile error — `createPlaylist` / `createTag` don't exist.

- [ ] **Step 3: Add the methods to `LibraryViewModel`**

In `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`, append inside the class (e.g. after `setTagIDs(...)`):

```swift
public func createPlaylist(name: String) async {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let playlist = Playlist(name: trimmed, orderedScoreItemIDs: [], createdAt: Date())
    do {
        try await repository.savePlaylist(playlist)
    } catch {
        errorAlertMessage = describe(error)
    }
}

public func createTag(name: String) async {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let tag = Tag(name: trimmed, colorHex: "#5856D6")
    do {
        try await repository.saveTag(tag)
    } catch {
        errorAlertMessage = describe(error)
    }
}
```

- [ ] **Step 4: Switch existing screens to call these methods**

Replace the `onCreate:` body in `Packages/Features/Library/Sources/Library/Screens/PlaylistsListScreen.swift`:

```swift
import Domain
import SwiftUI

struct PlaylistsListScreen: View {
    let library: LibraryViewModel

    var body: some View {
        PlaylistsListView(
            playlists: sortedPlaylists,
            onCreate: { name in
                Task { await library.createPlaylist(name: name) }
            }
        )
    }

    private var sortedPlaylists: [Playlist] {
        library.repository.playlists.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
```

Replace the `onCreate:` body in `Packages/Features/Library/Sources/Library/Screens/TagsListScreen.swift`:

```swift
import Domain
import SwiftUI

struct TagsListScreen: View {
    let library: LibraryViewModel

    var body: some View {
        TagsListView(
            tags: sortedTags,
            memberCount: memberCount(of:),
            onCreate: { name in
                Task { await library.createTag(name: name) }
            }
        )
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
}
```

- [ ] **Step 5: Run tests**

```bash
swift test --package-path Packages/Features/Library --filter LibraryViewModelTests
```

Expected: all 4 new tests + existing tests pass.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Library/Sources/Library/LibraryViewModel.swift \
        Packages/Features/Library/Sources/Library/Screens/PlaylistsListScreen.swift \
        Packages/Features/Library/Sources/Library/Screens/TagsListScreen.swift \
        Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift
git commit -m "refactor(library): lift playlist/tag creation into LibraryViewModel"
```

---

## Task 4: Add `LibraryRoute.favorites` and "See All" localization

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/LibraryRoute.swift`
- Modify: `Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add `.favorites` route case**

Replace `Packages/Features/Library/Sources/Library/LibraryRoute.swift`:

```swift
import Domain
import Foundation

/// Internal route enum for Library's NavigationStack destinations.
/// Defined here (not inside `LibraryRootScreen`) so `TagsListView` and
/// `PlaylistsListView` can `NavigationLink(value: LibraryRoute.…)` without
/// importing the screen.
enum LibraryRoute: Hashable {
    case allScores
    case favorites
    case tags
    case tagDetail(TagID)
    case playlists
    case playlistDetail(PlaylistID)
}
```

(Compilation will break in `LibraryRootScreen.destination(for:)` because the switch is no longer exhaustive — Task 5 fixes this. Don't run a build between these tasks; finish Task 5 first.)

- [ ] **Step 2: Add "See All" string**

Open `Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings` in a text editor (it is a JSON file). Insert a new top-level entry inside `"strings"`, alphabetically between existing entries (e.g. after the existing `"Search"` block if present, or right before `"Tags"`):

```json
    "See All" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "See All"
          }
        },
        "ja" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "すべて表示"
          }
        }
      }
    },
```

(JSON requires the trailing comma if another entry follows; omit if it's the last entry. Verify the file still parses by running `python3 -m json.tool < <path>` or by opening it in Xcode.)

- [ ] **Step 3: Verify file is valid JSON**

```bash
python3 -m json.tool < Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings > /dev/null && echo OK
```

Expected: prints `OK`.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Sources/Library/LibraryRoute.swift \
        Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings
git commit -m "feat(library): add .favorites route and 'See All' localization"
```

(Build is intentionally broken between this commit and Task 5's commit. Tasks 4–5 are paired; an executor that wants a green commit per task can squash these locally.)

---

## Task 5: LibraryRootScreen — Browse section overhaul + Favorites destination

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift`

- [ ] **Step 1: Replace `browseSection` and `favoritesSection`, add `FavoritesScreen`, route the new case**

Open `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift` and apply the following changes.

**5a. Delete** the entire `favoritesSection(_:)` helper (lines ~167–178 — the function starting `private func favoritesSection(_ favorites: [ScoreItem]) -> some View`).

**5b. Replace** the existing `browseSection(items:)` helper:

```swift
@ViewBuilder
private func browseSection(items: [ScoreItem]) -> some View {
    let favoriteCount = items.filter(\.isFavorite).count
    Section {
        NavigationLink(value: LibraryRoute.allScores) {
            browseRow(title: "All Scores", systemImage: "music.note", count: items.count)
        }
        if favoriteCount > 0 {
            NavigationLink(value: LibraryRoute.favorites) {
                browseRow(title: "Favorites", systemImage: "heart.fill", count: favoriteCount)
            }
        }
    } header: {
        Text("Browse", bundle: .module)
    }
}
```

**5c. Replace** `rootList` body (the `if items.isEmpty …` / `else { List { … } }` block — around line 142). Drop the `favorites` line and the call to `favoritesSection`:

```swift
@ViewBuilder
private var rootList: some View {
    let items = viewModel.repository.scoreItems
    let recents = items.mostRecentlyOpened(limit: 5)

    if items.isEmpty && viewModel.repository.tags.isEmpty && viewModel.repository.playlists.isEmpty {
        ContentUnavailableView {
            Label {
                Text("No Scores Yet", bundle: .module)
            } icon: {
                Image(systemName: "music.note")
            }
        } description: {
            Text("Import your first score to get started.", bundle: .module)
        }
    } else {
        List {
            browseSection(items: items)
            // Tasks 6 + 7 will insert playlistsSection / tagsSection here.
            recentsSection(recents)
        }
    }
}
```

**5d. Update** `destination(for:)` — add the new `.favorites` branch right after `.allScores`:

```swift
case .favorites:
    FavoritesScreen(
        library: viewModel,
        onOpen: onOpenScore,
        onEditTags: { editTagsTarget = $0 },
        onAddToPlaylist: { addToPlaylistTarget = $0 }
    )
```

**5e. Add** a `FavoritesScreen` private wrapper at the bottom of the file (sibling of the existing private `AllScoresScreen` near line 345):

```swift
private struct FavoritesScreen: View {
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
            wrappedValue: ScoreListViewModel(source: .favorites, repository: library.repository)
        )
    }

    var body: some View {
        ScoreListScreen(
            viewModel: listVM,
            library: library,
            onOpen: onOpen,
            onEditTags: onEditTags,
            onAddToPlaylist: onAddToPlaylist
        )
        .navigationTitle(Text("Favorites", bundle: .module))
    }
}
```

- [ ] **Step 2: Build the Library package to confirm it compiles**

```bash
swift build --package-path Packages/Features/Library
```

Expected: builds clean.

- [ ] **Step 3: Run the existing test suite**

```bash
swift test --package-path Packages/Features/Library
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift
git commit -m "feat(library): move Favorites under Browse, add Favorites destination"
```

---

## Task 6: Playlists collapsible section on root

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift`

- [ ] **Step 1: Add AppStorage state and section helper**

In `LibraryRootScreen` (the struct around line 7), add new properties next to the existing `@State` lines:

```swift
@AppStorage("library.section.playlists.expanded") private var playlistsExpanded: Bool = true
```

Add a new helper near the other `*Section` helpers:

```swift
@ViewBuilder
private func playlistsSection(allPlaylists: [Playlist], scoreItems: [ScoreItem]) -> some View {
    if !allPlaylists.isEmpty {
        let total = allPlaylists.count
        let topN = playlistsByRecentlyUsed(allPlaylists, scoreItems: scoreItems, limit: 5)
        Section(isExpanded: $playlistsExpanded) {
            ForEach(topN) { playlist in
                NavigationLink(value: LibraryRoute.playlistDetail(playlist.id)) {
                    HStack {
                        Image(systemName: "music.note.list").foregroundStyle(.tint)
                        Text(playlist.name).foregroundStyle(.primary)
                        Spacer()
                        Text(playlist.orderedScoreItemIDs.count, format: .number)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if total > 5 {
                NavigationLink(value: LibraryRoute.playlists) {
                    HStack {
                        Text("See All", bundle: .module).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        } header: {
            HStack {
                Text("Playlists", bundle: .module)
                Spacer()
                Text(total, format: .number).foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 2: Wire it into `rootList`**

Update the `List` body inside `rootList` to include the new section between `browseSection` and `recentsSection`:

```swift
List {
    browseSection(items: items)
    playlistsSection(
        allPlaylists: viewModel.repository.playlists,
        scoreItems: items
    )
    // Task 7 will insert tagsSection here.
    recentsSection(recents)
}
.listStyle(.sidebar)
```

(Note: `Section(isExpanded:)` requires a `List` style that supports section disclosure. iOS uses `.sidebar` or `.insetGrouped`. The current root has no explicit style — set `.listStyle(.sidebar)` so the chevron renders. If snapshot tests of root visuals exist, update them.)

- [ ] **Step 3: Build and test**

```bash
swift build --package-path Packages/Features/Library
swift test --package-path Packages/Features/Library
```

Expected: builds clean, all tests pass.

- [ ] **Step 4: Verify with a SwiftUI preview**

Open `Packages/Features/Library/Package.swift` in Xcode (must be running with the project window open per the global iOS workflow). If `LibraryRootScreen` has no `#Preview`, add one inside `#if DEBUG` at the bottom of the file using the existing fakes — minimum content:

```swift
#if DEBUG
#Preview("Root with playlists") {
    LibraryRootPreviewHost(playlistCount: 7, tagCount: 0, scoreCount: 12)
}
#endif
```

(`LibraryRootPreviewHost` is whatever existing preview host is already in the file. If none exists, skip the preview step and rely on the simulator smoke test in Task 9.)

Then `mcp__xcode__RenderPreview` to render and `Read` the resulting PNG. Expected: Playlists section header shows count + chevron; expanding shows ≤5 rows + See All; collapsing hides them.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift
git commit -m "feat(library): collapsible Playlists section on root with persisted fold"
```

---

## Task 7: Tags collapsible section on root

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift`

- [ ] **Step 1: Add AppStorage state and section helper**

Add another property next to `playlistsExpanded`:

```swift
@AppStorage("library.section.tags.expanded") private var tagsExpanded: Bool = true
```

Add a helper mirroring `playlistsSection`:

```swift
@ViewBuilder
private func tagsSection(allTags: [Tag], scoreItems: [ScoreItem]) -> some View {
    if !allTags.isEmpty {
        let total = allTags.count
        let topN = tagsByRecentlyUsed(allTags, scoreItems: scoreItems, limit: 5)
        Section(isExpanded: $tagsExpanded) {
            ForEach(topN) { tag in
                NavigationLink(value: LibraryRoute.tagDetail(tag.id)) {
                    HStack {
                        Image(systemName: "tag.fill").foregroundStyle(.tint)
                        Text(tag.name).foregroundStyle(.primary)
                        Spacer()
                        Text(memberCount(of: tag, in: scoreItems), format: .number)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if total > 5 {
                NavigationLink(value: LibraryRoute.tags) {
                    HStack {
                        Text("See All", bundle: .module).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        } header: {
            HStack {
                Text("Tags", bundle: .module)
                Spacer()
                Text(total, format: .number).foregroundStyle(.secondary)
            }
        }
    }
}

private func memberCount(of tag: Tag, in scoreItems: [ScoreItem]) -> Int {
    scoreItems.reduce(0) { acc, item in acc + (item.tagIDs.contains(tag.id) ? 1 : 0) }
}
```

- [ ] **Step 2: Wire it into `rootList`**

Update the `List` body:

```swift
List {
    browseSection(items: items)
    playlistsSection(allPlaylists: viewModel.repository.playlists, scoreItems: items)
    tagsSection(allTags: viewModel.repository.tags, scoreItems: items)
    recentsSection(recents)
}
.listStyle(.sidebar)
```

- [ ] **Step 3: Build and test**

```bash
swift build --package-path Packages/Features/Library
swift test --package-path Packages/Features/Library
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift
git commit -m "feat(library): collapsible Tags section on root with persisted fold"
```

---

## Task 8: Toolbar `+` Menu and create alerts

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift`

- [ ] **Step 1: Add state for create alerts**

Inside `LibraryRootScreen` add:

```swift
@State private var isCreatingPlaylist: Bool = false
@State private var newPlaylistName: String = ""
@State private var isCreatingTag: Bool = false
@State private var newTagName: String = ""
```

- [ ] **Step 2: Replace `importButton` with a Menu**

Replace the existing `importButton` computed property with this `addMenu`:

```swift
private var addMenu: some View {
    Menu {
        Button {
            viewModel.isFileImporterPresented = true
        } label: {
            Label {
                Text("Import Score", bundle: .module)
            } icon: {
                Image(systemName: "square.and.arrow.down")
            }
        }
        Button {
            newPlaylistName = ""
            isCreatingPlaylist = true
        } label: {
            Label {
                Text("New Playlist", bundle: .module)
            } icon: {
                Image(systemName: "music.note.list")
            }
        }
        Button {
            newTagName = ""
            isCreatingTag = true
        } label: {
            Label {
                Text("New Tag", bundle: .module)
            } icon: {
                Image(systemName: "tag")
            }
        }
    } label: {
        Image(systemName: "plus").accessibilityLabel(Text("Add", bundle: .module))
    }
}
```

Then update `importToolbar` to reference the new label (rename for clarity is optional; the simplest change is to swap the button reference inline):

```swift
@ToolbarContentBuilder
private var importToolbar: some ToolbarContent {
    #if os(iOS)
        ToolbarItem(placement: .topBarTrailing) { addMenu }
    #else
        ToolbarItem(placement: .automatic) { addMenu }
    #endif
}
```

- [ ] **Step 3: Wire the create alerts**

Add two `.alert(...)` modifiers attached to the outer `NavigationStack(path: $path) { ... }` block — they sit alongside the existing `.alert` modifiers near the bottom of `body`:

```swift
.alert(Text("New Playlist", bundle: .module), isPresented: $isCreatingPlaylist) {
    TextField(text: $newPlaylistName) { Text("Playlist name", bundle: .module) }
    Button {
        let name = newPlaylistName
        newPlaylistName = ""
        Task { await viewModel.createPlaylist(name: name) }
    } label: { Text("Add", bundle: .module) }
    Button(role: .cancel) { newPlaylistName = "" } label: { Text("Cancel", bundle: .module) }
} message: {
    Text("Enter a name for the new playlist.", bundle: .module)
}
.alert(Text("New Tag", bundle: .module), isPresented: $isCreatingTag) {
    TextField(text: $newTagName) { Text("Tag name", bundle: .module) }
    Button {
        let name = newTagName
        newTagName = ""
        Task { await viewModel.createTag(name: name) }
    } label: { Text("Add", bundle: .module) }
    Button(role: .cancel) { newTagName = "" } label: { Text("Cancel", bundle: .module) }
} message: {
    Text("Enter a name for the new tag.", bundle: .module)
}
```

(Strings "Enter a name for the new playlist." / "Enter a name for the new tag." / "Playlist name" / "Tag name" / "Cancel" already exist in `Localizable.xcstrings` since `PlaylistsListView` / `TagsListView` use them. Verify with `grep` if uncertain.)

- [ ] **Step 4: Build and test**

```bash
swift build --package-path Packages/Features/Library
swift test --package-path Packages/Features/Library
```

Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift
git commit -m "feat(library): root toolbar Menu for Import/New Playlist/New Tag"
```

---

## Task 9: Whole-app build + smoke test

**Files:** none (verification only)

- [ ] **Step 1: Regenerate Xcode project (no `project.yml` changes, but harmless)**

```bash
xcodegen generate
```

Expected: project regenerates without errors.

- [ ] **Step 2: Build the app for simulator**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    -skipPackagePluginValidation build
```

Expected: BUILD SUCCEEDED. No new warnings beyond the pre-existing baseline.

- [ ] **Step 3: Run all tests**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    -skipPackagePluginValidation test
```

Expected: all tests pass.

- [ ] **Step 4: Manual smoke test on simulator**

Install + launch the app. Verify:

- Library root shows Browse (All Scores + Favorites if any), then collapsible Playlists / Tags (only when non-empty), then Recently Opened.
- Tap a Playlist / Tag header chevron — section collapses; relaunching the app keeps the collapsed state.
- Toolbar `+` opens a Menu with Import Score / New Playlist / New Tag.
- "New Playlist" alert creates the playlist; the section appears (or grows) immediately.
- See All only appears once you have ≥6 playlists or tags; tapping pushes to the existing list screen, whose `+` toolbar still works.
- Tap Favorites under Browse → opens the score list filtered to favorites; the row hides again when no favorites remain.

If any check fails, fix and re-test. Do not commit fixes from this task — they belong to the previous task that introduced the regression.

- [ ] **Step 5: Final commit (only if any cosmetic touch-ups were needed)**

```bash
# only if there were fix-ups
git add -A
git commit -m "chore(library): smoke-test fixes"
```

---

## Self-Review notes

- **Spec coverage:** Browse (All Scores + Favorites) → Task 5. Playlists section → Task 6. Tags section → Task 7. AppStorage fold → Tasks 6/7. Toolbar Menu → Task 8. Favorites screen via ScoreListScreen → Tasks 2 + 5. Recently-used sort + tests → Task 1. Lifted create methods → Task 3. Localization → Task 4.
- **No placeholders.** Every code block is concrete; the only deferred decision is "use the existing preview host if one is already in the file" which is documented inline.
- **Type consistency.** `playlistsByRecentlyUsed` / `tagsByRecentlyUsed` signatures used in Task 1 match the call sites in Tasks 6/7. `createPlaylist(name:)` / `createTag(name:)` defined in Task 3 are called from Task 8 and from updated screens in Task 3.
- **Tasks 4 + 5 are paired:** the route enum gains `.favorites` in Task 4 but the switch becomes exhaustive only in Task 5. An executor that needs every commit green should squash these two locally; otherwise they form a known intermediate state.

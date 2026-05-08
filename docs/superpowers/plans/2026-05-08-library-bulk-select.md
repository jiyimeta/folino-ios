# Library Bulk Select Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a multi-select editing mode to the three score-listing screens (All Scores, Tag detail, Playlist detail) with bulk delete, add-to-playlist, and add-tags actions.

**Architecture:** All work lands inside `Packages/Features/Library/`. `LibraryViewModel` gets four new bulk methods that iterate existing repository calls. Two new pure SwiftUI sheets (`BulkAddToPlaylistSheet`, `BulkEditTagsSheet`) and their thin `…Screen` wrappers. `ScoreListView` and `PlaylistDetailView` gain selection bindings and a shared bottom action bar; their owning Screens wire selection state, sheet presentation, and the per-context delete alert. No Domain or Infrastructure changes.

**Tech Stack:** Swift 6.3, SwiftUI, Swift Testing, iOS 26+. Spec: `docs/superpowers/specs/2026-05-08-library-bulk-select-design.md`.

---

## Conventions

- **Test command (fast loop):**
  `swift test --package-path /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Library --filter <SuiteName>`
- **Full build (final task only):**
  `xcodebuild -project /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`
- All file paths are absolute under `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/`. Where the task header says `Modify: <relative path>`, the relative path is under that root.
- Pre-commit hook auto-runs SwiftFormat + SwiftLint on staged Swift files. If a commit fails on lint, fix the issue and re-stage; never `--no-verify`.
- Each task ends with a commit. Use the message body shown.

---

### Task 1: `LibraryViewModel.bulkDelete`

**Files:**
- Test (create): `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelBulkTests.swift`
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelBulkTests.swift`:

```swift
import Domain
import Foundation
@testable import Library
import Testing

@Suite @MainActor
struct LibraryViewModelBulkTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem(title: String) -> ScoreItem {
        ScoreItem(
            title: title, composer: nil, instrumentationSummary: nil,
            localFileName: "\(title).mscx", contentHash: title,
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: base, lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }

    private struct VMFixture {
        let vm: LibraryViewModel
        let repo: FakeScoreLibraryRepository
    }

    private static func makeVM(scoreItems: [ScoreItem] = []) -> VMFixture {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = scoreItems
        let vm = LibraryViewModel(
            repository: repo,
            importer: FakeScoreFileImporter(),
            gateway: FakeScoreFileGateway(),
            shareService: FakeScoreShareService()
        )
        return VMFixture(vm: vm, repo: repo)
    }

    // MARK: - bulkDelete

    @Test func bulkDeleteRemovesAllPassedIDs() async {
        let a = Self.makeItem(title: "A")
        let b = Self.makeItem(title: "B")
        let c = Self.makeItem(title: "C")
        let f = Self.makeVM(scoreItems: [a, b, c])

        await f.vm.bulkDelete([a.id, c.id])

        #expect(Set(f.repo.deletedScoreItemIDs) == [a.id, c.id])
        #expect(f.repo.scoreItems.map(\.id) == [b.id])
        #expect(f.vm.errorAlertMessage == nil)
    }

    @Test func bulkDeleteEmptyIsNoOp() async {
        let f = Self.makeVM(scoreItems: [Self.makeItem(title: "A")])
        await f.vm.bulkDelete([])
        #expect(f.repo.deletedScoreItemIDs.isEmpty)
        #expect(f.vm.errorAlertMessage == nil)
    }

    @Test func bulkDeleteStopsAtFirstError() async {
        let a = Self.makeItem(title: "A")
        let b = Self.makeItem(title: "B")
        let f = Self.makeVM(scoreItems: [a, b])
        f.repo.deleteScoreItemError = .persistenceFailed

        await f.vm.bulkDelete([a.id, b.id])

        #expect(f.repo.deletedScoreItemIDs.isEmpty) // FakeRepo throws before recording
        #expect(f.vm.errorAlertMessage != nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/Features/Library --filter LibraryViewModelBulkTests`
Expected: FAIL — `value of type 'LibraryViewModel' has no member 'bulkDelete'`

- [ ] **Step 3: Implement `bulkDelete`**

Append to `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`, just below `delete(_:)`:

```swift
    public func bulkDelete(_ ids: Set<ScoreItemID>) async {
        for id in ids {
            do {
                try await repository.deleteScoreItem(id: id)
            } catch {
                errorAlertMessage = describe(error)
                return
            }
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/Features/Library --filter LibraryViewModelBulkTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/Library/LibraryViewModel.swift Packages/Features/Library/Tests/LibraryTests/LibraryViewModelBulkTests.swift
git commit -m "feat(library): bulkDelete on LibraryViewModel"
```

---

### Task 2: `LibraryViewModel.bulkRemoveFromPlaylist`

**Files:**
- Modify: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelBulkTests.swift`
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`

- [ ] **Step 1: Write the failing tests**

Append inside the `LibraryViewModelBulkTests` suite (above the closing `}`):

```swift
    // MARK: - bulkRemoveFromPlaylist

    @Test func bulkRemoveFromPlaylistFiltersAndPreservesOrder() async {
        let a = Self.makeItem(title: "A")
        let b = Self.makeItem(title: "B")
        let c = Self.makeItem(title: "C")
        let f = Self.makeVM(scoreItems: [a, b, c])
        let playlist = Playlist(
            name: "P",
            orderedScoreItemIDs: [a.id, b.id, c.id],
            createdAt: Self.base
        )
        f.repo.playlists = [playlist]

        await f.vm.bulkRemoveFromPlaylist([a.id, c.id], from: playlist)

        #expect(f.repo.savedPlaylists.last?.orderedScoreItemIDs == [b.id])
        #expect(f.repo.scoreItems.count == 3) // scores stay
    }

    @Test func bulkRemoveFromPlaylistEmptyIsNoOp() async {
        let a = Self.makeItem(title: "A")
        let f = Self.makeVM(scoreItems: [a])
        let playlist = Playlist(
            name: "P", orderedScoreItemIDs: [a.id], createdAt: Self.base
        )
        f.repo.playlists = [playlist]

        await f.vm.bulkRemoveFromPlaylist([], from: playlist)

        #expect(f.repo.savedPlaylists.isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/Features/Library --filter LibraryViewModelBulkTests`
Expected: FAIL — `no member 'bulkRemoveFromPlaylist'`.

- [ ] **Step 3: Implement**

Append to `LibraryViewModel.swift` below `bulkDelete`:

```swift
    public func bulkRemoveFromPlaylist(
        _ ids: Set<ScoreItemID>,
        from playlist: Playlist
    ) async {
        guard !ids.isEmpty else { return }
        var updated = playlist
        updated.orderedScoreItemIDs.removeAll { ids.contains($0) }
        guard updated.orderedScoreItemIDs != playlist.orderedScoreItemIDs else { return }
        do {
            try await repository.savePlaylist(updated)
        } catch {
            errorAlertMessage = describe(error)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/Features/Library --filter LibraryViewModelBulkTests`
Expected: PASS (5 tests total).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/Library/LibraryViewModel.swift Packages/Features/Library/Tests/LibraryTests/LibraryViewModelBulkTests.swift
git commit -m "feat(library): bulkRemoveFromPlaylist on LibraryViewModel"
```

---

### Task 3: `LibraryViewModel.bulkAddToPlaylist`

**Files:**
- Modify: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelBulkTests.swift`
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`

- [ ] **Step 1: Write the failing tests**

Append inside the suite:

```swift
    // MARK: - bulkAddToPlaylist

    @Test func bulkAddToPlaylistAppendsMissingPreservesOrder() async {
        let a = Self.makeItem(title: "A")
        let b = Self.makeItem(title: "B")
        let c = Self.makeItem(title: "C")
        let f = Self.makeVM(scoreItems: [a, b, c])
        let playlist = Playlist(
            name: "P", orderedScoreItemIDs: [a.id], createdAt: Self.base
        )
        f.repo.playlists = [playlist]

        await f.vm.bulkAddToPlaylist([b.id, a.id, c.id], to: playlist)

        // a already present; b and c appended in caller order, a not duplicated.
        #expect(f.repo.savedPlaylists.last?.orderedScoreItemIDs == [a.id, b.id, c.id])
    }

    @Test func bulkAddToPlaylistAllPresentIsNoOp() async {
        let a = Self.makeItem(title: "A")
        let f = Self.makeVM(scoreItems: [a])
        let playlist = Playlist(
            name: "P", orderedScoreItemIDs: [a.id], createdAt: Self.base
        )
        f.repo.playlists = [playlist]

        await f.vm.bulkAddToPlaylist([a.id], to: playlist)

        #expect(f.repo.savedPlaylists.isEmpty)
    }

    @Test func bulkAddToPlaylistEmptyIsNoOp() async {
        let f = Self.makeVM()
        let playlist = Playlist(name: "P", orderedScoreItemIDs: [], createdAt: Self.base)
        f.repo.playlists = [playlist]

        await f.vm.bulkAddToPlaylist([], to: playlist)

        #expect(f.repo.savedPlaylists.isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/Features/Library --filter LibraryViewModelBulkTests`
Expected: FAIL — `no member 'bulkAddToPlaylist'`.

- [ ] **Step 3: Implement**

Append to `LibraryViewModel.swift`:

```swift
    public func bulkAddToPlaylist(
        _ orderedIDs: [ScoreItemID],
        to playlist: Playlist
    ) async {
        guard !orderedIDs.isEmpty else { return }
        let existing = Set(playlist.orderedScoreItemIDs)
        let toAppend = orderedIDs.filter { !existing.contains($0) }
        guard !toAppend.isEmpty else { return }
        var updated = playlist
        updated.orderedScoreItemIDs.append(contentsOf: toAppend)
        do {
            try await repository.savePlaylist(updated)
        } catch {
            errorAlertMessage = describe(error)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/Features/Library --filter LibraryViewModelBulkTests`
Expected: PASS (8 tests total).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/Library/LibraryViewModel.swift Packages/Features/Library/Tests/LibraryTests/LibraryViewModelBulkTests.swift
git commit -m "feat(library): bulkAddToPlaylist on LibraryViewModel"
```

---

### Task 4: `LibraryViewModel.bulkAddTags`

**Files:**
- Modify: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelBulkTests.swift`
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`

- [ ] **Step 1: Write the failing tests**

Append:

```swift
    // MARK: - bulkAddTags

    @Test func bulkAddTagsUnionsTagSets() async {
        let tagA = TagID()
        let tagB = TagID()
        var item1 = Self.makeItem(title: "1"); item1.tagIDs = [tagA]
        var item2 = Self.makeItem(title: "2"); item2.tagIDs = []
        let f = Self.makeVM(scoreItems: [item1, item2])

        await f.vm.bulkAddTags([item1.id, item2.id], tagIDs: [tagB])

        let saved1 = f.repo.scoreItems.first { $0.id == item1.id }
        let saved2 = f.repo.scoreItems.first { $0.id == item2.id }
        #expect(saved1?.tagIDs == [tagA, tagB])
        #expect(saved2?.tagIDs == [tagB])
    }

    @Test func bulkAddTagsSkipsWritesWhenAlreadyHasAll() async {
        let tagA = TagID()
        var item = Self.makeItem(title: "1"); item.tagIDs = [tagA]
        let f = Self.makeVM(scoreItems: [item])

        await f.vm.bulkAddTags([item.id], tagIDs: [tagA])

        #expect(f.repo.savedScoreItems.isEmpty)
    }

    @Test func bulkAddTagsEmptyTagsIsNoOp() async {
        let item = Self.makeItem(title: "1")
        let f = Self.makeVM(scoreItems: [item])

        await f.vm.bulkAddTags([item.id], tagIDs: [])

        #expect(f.repo.savedScoreItems.isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/Features/Library --filter LibraryViewModelBulkTests`
Expected: FAIL — `no member 'bulkAddTags'`.

- [ ] **Step 3: Implement**

Append to `LibraryViewModel.swift`:

```swift
    public func bulkAddTags(
        _ ids: Set<ScoreItemID>,
        tagIDs: Set<TagID>
    ) async {
        guard !ids.isEmpty, !tagIDs.isEmpty else { return }
        for id in ids {
            guard let item = repository.scoreItems.first(where: { $0.id == id }) else { continue }
            let merged = item.tagIDs.union(tagIDs)
            guard merged != item.tagIDs else { continue }
            var updated = item
            updated.tagIDs = merged
            do {
                try await repository.saveScoreItem(updated)
            } catch {
                errorAlertMessage = describe(error)
                return
            }
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/Features/Library --filter LibraryViewModelBulkTests`
Expected: PASS (11 tests total).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/Library/LibraryViewModel.swift Packages/Features/Library/Tests/LibraryTests/LibraryViewModelBulkTests.swift
git commit -m "feat(library): bulkAddTags on LibraryViewModel"
```

---

### Task 5: Localization strings

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add the new keys**

Insert these entries in alphabetical order inside the top-level `"strings" : { … }` object. (Keys are by source-language string. Insert each as a sibling — order doesn't affect correctness, alphabetical just keeps diffs sane.) Each entry follows the existing schema (`"localizations" : { "en" : { "stringUnit" : { … } }, "ja" : { "stringUnit" : { … } } }`).

| Source key | en | ja |
| --- | --- | --- |
| `Add %lld scores to playlist` | `Add %lld scores to playlist` | `%lld 件をプレイリストに追加` |
| `Delete %lld scores?` | `Delete %lld scores?` | `%lld 件のスコアを削除しますか？` |
| `Delete completely` | `Delete completely` | `完全に削除` |
| `Remove from playlist` | `Remove from playlist` | `プレイリストから削除` |
| `Select` | `Select` | `選択` |
| `Tags for %lld scores` | `Tags for %lld scores` | `%lld 件のスコアにタグを追加` |
| `This will remove the scores and their files from this device.` | `This will remove the scores and their files from this device.` | `スコアとファイルがこの端末から削除されます。` |
| `%lld selected` | `%lld selected` | `%lld 件選択中` |

For each row, the JSON to insert looks like (example for `Select`):

```json
"Select" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Select"
      }
    },
    "ja" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "選択"
      }
    }
  }
},
```

- [ ] **Step 2: Verify JSON is valid**

Run: `python3 -c 'import json; json.load(open("Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings"))' && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings
git commit -m "feat(library): add bulk-select localization strings"
```

---

### Task 6: `BulkActionBar` shared view

**Files:**
- Create: `Packages/Features/Library/Sources/Library/Views/BulkActionBar.swift`

A small shared view used by both `ScoreListView` (bottom) and `PlaylistDetailView` (bottom). Three buttons; all disabled when `selectionCount == 0`.

- [ ] **Step 1: Write the view**

```swift
import SwiftUI

struct BulkActionBar: View {
    let selectionCount: Int
    let onAddToPlaylist: () -> Void
    let onEditTags: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            barButton(systemImage: "music.note.list", labelKey: "Add to Playlist", action: onAddToPlaylist)
            barButton(systemImage: "tag", labelKey: "Tags", action: onEditTags)
            barButton(systemImage: "trash", labelKey: "Delete", role: .destructive, action: onDelete)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.bar)
        .disabled(selectionCount == 0)
    }

    @ViewBuilder
    private func barButton(
        systemImage: String,
        labelKey: LocalizedStringKey,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(labelKey, bundle: .module)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
    #Preview("Enabled") {
        BulkActionBar(selectionCount: 3, onAddToPlaylist: {}, onEditTags: {}, onDelete: {})
    }
    #Preview("Disabled") {
        BulkActionBar(selectionCount: 0, onAddToPlaylist: {}, onEditTags: {}, onDelete: {})
    }
#endif
```

- [ ] **Step 2: Build the package**

Run: `swift build --package-path Packages/Features/Library`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Views/BulkActionBar.swift
git commit -m "feat(library): BulkActionBar shared view"
```

---

### Task 7: `BulkAddToPlaylistSheet`

**Files:**
- Create: `Packages/Features/Library/Sources/Library/Views/BulkAddToPlaylistSheet.swift`

- [ ] **Step 1: Write the view**

```swift
import Domain
import SwiftUI

struct BulkAddToPlaylistSheet: View {
    let selectionCount: Int
    let selectedIDs: Set<ScoreItemID>
    let allPlaylists: [Playlist]
    let onPick: (Playlist) -> Void
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newPlaylistName: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(allPlaylists) { playlist in
                        Button { onPick(playlist) } label: {
                            HStack {
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(.tint)
                                Text(playlist.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                let already = playlist.orderedScoreItemIDs.filter { selectedIDs.contains($0) }.count
                                if already > 0 {
                                    Text("\(already)/\(selectionCount)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                        TextField(text: $newPlaylistName) { Text("New playlist", bundle: .module) }
                            .submitLabel(.done)
                            .onSubmit { commitNewPlaylist() }
                        Button { commitNewPlaylist() } label: {
                            Text("Create", bundle: .module)
                        }
                        .buttonStyle(.borderless)
                        .disabled(trimmedNewPlaylistName.isEmpty)
                    }
                }
            }
            .navigationTitle(Text("Add \(selectionCount) scores to playlist", bundle: .module))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    #if os(iOS)
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { dismiss() } label: { Text("Cancel", bundle: .module) }
                        }
                    #else
                        ToolbarItem(placement: .automatic) {
                            Button { dismiss() } label: { Text("Cancel", bundle: .module) }
                        }
                    #endif
                }
        }
    }

    private var trimmedNewPlaylistName: String {
        newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitNewPlaylist() {
        let trimmed = trimmedNewPlaylistName
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        newPlaylistName = ""
    }
}

#if DEBUG
    #Preview {
        struct Host: View {
            let scoreA = ScoreItemID()
            let scoreB = ScoreItemID()
            var body: some View {
                BulkAddToPlaylistSheet(
                    selectionCount: 2,
                    selectedIDs: [scoreA, scoreB],
                    allPlaylists: [
                        Playlist(name: "Daily warm-up", orderedScoreItemIDs: [scoreA], createdAt: Date()),
                        Playlist(name: "Recital set", orderedScoreItemIDs: [], createdAt: Date()),
                    ],
                    onPick: { _ in },
                    onCreate: { _ in }
                )
            }
        }
        return Host()
    }
#endif
```

- [ ] **Step 2: Build the package**

Run: `swift build --package-path Packages/Features/Library`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Views/BulkAddToPlaylistSheet.swift
git commit -m "feat(library): BulkAddToPlaylistSheet"
```

---

### Task 8: `BulkAddToPlaylistScreen`

**Files:**
- Create: `Packages/Features/Library/Sources/Library/Screens/BulkAddToPlaylistScreen.swift`

- [ ] **Step 1: Write the screen**

```swift
import Domain
import SwiftUI

struct BulkAddToPlaylistScreen: View {
    let selectedIDs: Set<ScoreItemID>
    let orderedSelectedIDs: [ScoreItemID]   // caller's preferred order, e.g. as displayed
    let library: LibraryViewModel
    let onCommit: () -> Void                // called after successful pick or create

    var body: some View {
        BulkAddToPlaylistSheet(
            selectionCount: selectedIDs.count,
            selectedIDs: selectedIDs,
            allPlaylists: library.repository.playlists,
            onPick: { playlist in Task { await commitPick(playlist) } },
            onCreate: { name in Task { await commitCreate(name) } }
        )
    }

    private func commitPick(_ playlist: Playlist) async {
        await library.bulkAddToPlaylist(orderedSelectedIDs, to: playlist)
        onCommit()
    }

    private func commitCreate(_ name: String) async {
        let playlist = Playlist(
            name: name,
            orderedScoreItemIDs: orderedSelectedIDs,
            createdAt: Date()
        )
        do {
            try await library.repository.savePlaylist(playlist)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return
        }
        onCommit()
    }
}
```

- [ ] **Step 2: Build the package**

Run: `swift build --package-path Packages/Features/Library`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Screens/BulkAddToPlaylistScreen.swift
git commit -m "feat(library): BulkAddToPlaylistScreen"
```

---

### Task 9: `BulkEditTagsSheet`

**Files:**
- Create: `Packages/Features/Library/Sources/Library/Views/BulkEditTagsSheet.swift`

- [ ] **Step 1: Write the view**

```swift
import Domain
import SwiftUI

struct BulkEditTagsSheet: View {
    let selectionCount: Int
    let allTags: [Tag]
    let onCommit: (Set<TagID>) -> Void
    let onCreateTag: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var checked: Set<TagID> = []
    @State private var newTagName: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(allTags) { tag in
                        Button {
                            if checked.contains(tag.id) { checked.remove(tag.id) }
                            else { checked.insert(tag.id) }
                        } label: {
                            HStack {
                                Image(systemName: checked.contains(tag.id) ? "checkmark.circle.fill" : "circle")
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
                        TextField(text: $newTagName) { Text("New tag", bundle: .module) }
                            .submitLabel(.done)
                            .onSubmit { commitNewTag() }
                        Button { commitNewTag() } label: {
                            Text("Create", bundle: .module)
                        }
                        .buttonStyle(.borderless)
                        .disabled(trimmedNewTagName.isEmpty)
                    }
                }
            }
            .navigationTitle(Text("Tags for \(selectionCount) scores", bundle: .module))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar { toolbarItems }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Text("Cancel", bundle: .module) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { onCommit(checked) } label: { Text("Done", bundle: .module) }
                    .disabled(checked.isEmpty)
            }
        #else
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Text("Cancel", bundle: .module) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button { onCommit(checked) } label: { Text("Done", bundle: .module) }
                    .disabled(checked.isEmpty)
            }
        #endif
    }

    private var trimmedNewTagName: String {
        newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitNewTag() {
        let trimmed = trimmedNewTagName
        guard !trimmed.isEmpty else { return }
        onCreateTag(trimmed)
        newTagName = ""
    }
}

#if DEBUG
    #Preview {
        BulkEditTagsSheet(
            selectionCount: 3,
            allTags: [
                Tag(name: "Practice", colorHex: "#5856D6"),
                Tag(name: "Recital", colorHex: "#FF9500"),
            ],
            onCommit: { _ in },
            onCreateTag: { _ in }
        )
    }
#endif
```

- [ ] **Step 2: Build the package**

Run: `swift build --package-path Packages/Features/Library`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Views/BulkEditTagsSheet.swift
git commit -m "feat(library): BulkEditTagsSheet"
```

---

### Task 10: `BulkEditTagsScreen`

**Files:**
- Create: `Packages/Features/Library/Sources/Library/Screens/BulkEditTagsScreen.swift`

The screen drives both the "tap Done" path (union add) and the "create new tag" path (saves the tag, then auto-checks it inside the sheet). Because the sheet manages `checked` itself, "auto-check after create" is handled by the sheet re-rendering with `allTags` containing the new tag — the user sees it appear at the bottom and can tap to check, OR we can extend the sheet to take a `checked` binding. To keep the surface narrow, the screen passes a synthetic flow: on create, immediately commit the union of `[newTag]` with the user's already-checked set and dismiss. (See Task 9: the sheet calls `onCreateTag` and clears the field; the screen then performs the create-and-commit.)

- [ ] **Step 1: Write the screen**

```swift
import Domain
import Foundation
import SwiftUI

struct BulkEditTagsScreen: View {
    let selectedIDs: Set<ScoreItemID>
    let library: LibraryViewModel
    let onCommit: () -> Void

    var body: some View {
        BulkEditTagsSheet(
            selectionCount: selectedIDs.count,
            allTags: library.repository.tags,
            onCommit: { tagIDs in Task { await commitUnion(tagIDs) } },
            onCreateTag: { name in Task { await commitCreate(name) } }
        )
    }

    private func commitUnion(_ tagIDs: Set<TagID>) async {
        await library.bulkAddTags(selectedIDs, tagIDs: tagIDs)
        onCommit()
    }

    private func commitCreate(_ name: String) async {
        let tag = Tag(name: name, colorHex: "#5856D6")
        do {
            try await library.repository.saveTag(tag)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return
        }
        await library.bulkAddTags(selectedIDs, tagIDs: [tag.id])
        onCommit()
    }
}
```

- [ ] **Step 2: Build the package**

Run: `swift build --package-path Packages/Features/Library`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Screens/BulkEditTagsScreen.swift
git commit -m "feat(library): BulkEditTagsScreen"
```

---

### Task 11: `ScoreListView` selection mode

`ScoreListView` gains selection state and the bottom action bar. The tap-to-open and per-row swipe actions stay; in edit mode SwiftUI hides the swipe actions and surfaces the row's selection circle.

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Views/ScoreListView.swift`

- [ ] **Step 1: Add selection bindings and bulk callbacks**

In the struct definition (lines 4–17 of the current file), add new stored properties before `@ViewBuilder let rowMenu`:

```swift
    @Binding var editMode: EditMode
    @Binding var selectedIDs: Set<ScoreItemID>
    let bulkContext: BulkContext
    let onBulkAddToPlaylist: () -> Void
    let onBulkEditTags: () -> Void
    let onBulkDelete: () -> Void
```

Define `BulkContext` at file scope, above the struct:

```swift
enum BulkContext {
    case scores
    case playlist
}
```

(Note: `EditMode` is iOS-only. Wrap the binding behind `#if os(iOS)` in the call site if cross-platform; this view file is already iOS-leaning. For the binding declaration above, leave it iOS-only by gating the property with `#if os(iOS)`.)

Replace the property additions with the iOS-gated form:

```swift
    #if os(iOS)
        @Binding var editMode: EditMode
    #endif
    @Binding var selectedIDs: Set<ScoreItemID>
    let bulkContext: BulkContext
    let onBulkAddToPlaylist: () -> Void
    let onBulkEditTags: () -> Void
    let onBulkDelete: () -> Void
```

- [ ] **Step 2: Switch the `List` to a selection list and add the bottom bar**

Replace the existing `var body` (`List { ForEach(items) … } .searchable… .toolbar… .alert…`) with:

```swift
    var body: some View {
        list
            .searchable(text: $searchText)
            .toolbar { sortToolbarItem }
            .toolbar { editToolbarItem }
            #if os(iOS)
            .environment(\.editMode, $editMode)
            #endif
            .navigationTitle(navigationTitleText)
            .safeAreaInset(edge: .bottom) {
                if isEditing {
                    BulkActionBar(
                        selectionCount: selectedIDs.count,
                        onAddToPlaylist: onBulkAddToPlaylist,
                        onEditTags: onBulkEditTags,
                        onDelete: onBulkDelete
                    )
                }
            }
            .alert(
                Text("Delete \"\(pendingDelete?.title ?? "")\"?", bundle: .module),
                isPresented: deleteAlertBinding,
                presenting: pendingDelete
            ) { item in
                Button(role: .destructive) {
                    onConfirmDelete(item)
                } label: {
                    Text("Delete", bundle: .module)
                }
                Button(role: .cancel) {} label: {
                    Text("Cancel", bundle: .module)
                }
            } message: { _ in
                Text("This will remove the score and its file from this device.", bundle: .module)
            }
    }

    @ViewBuilder
    private var list: some View {
        List(selection: $selectedIDs) {
            ForEach(items) { item in
                row(for: item)
                    .tag(item.id)
            }
        }
    }

    private var isEditing: Bool {
        #if os(iOS)
            return editMode.isEditing
        #else
            return false
        #endif
    }

    private var navigationTitleText: Text {
        if isEditing, !selectedIDs.isEmpty {
            return Text("\(selectedIDs.count) selected", bundle: .module)
        }
        return Text("")
    }

    @ToolbarContentBuilder
    private var editToolbarItem: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        #endif
    }
```

Note: keep the existing `private func row(for:)`, `deleteAlertBinding`, `sortToolbarItem`, `sortMenu` helpers unchanged.

- [ ] **Step 3: Update the `#Preview` host to supply the new bindings**

Replace the `ScoreListViewPreviewHost` struct (around lines 172–203) with:

```swift
    private struct ScoreListViewPreviewHost: View {
        @State private var searchText: String = ""
        @State private var pendingDelete: ScoreItem?
        @State private var sort: ScoreItemSort = .dateAddedDesc
        @State private var isManualOrderActive: Bool = false
        #if os(iOS)
            @State private var editMode: EditMode = .inactive
        #endif
        @State private var selectedIDs: Set<ScoreItemID> = []

        let items: [ScoreItem]
        let showsManualOrderOption: Bool

        var body: some View {
            NavigationStack {
                ScoreListView(
                    items: items,
                    searchText: $searchText,
                    sort: sort,
                    isManualOrderActive: isManualOrderActive,
                    showsManualOrderOption: showsManualOrderOption,
                    pendingDelete: $pendingDelete,
                    onTap: { _ in },
                    onToggleFavorite: { _ in },
                    onConfirmDelete: { _ in },
                    onSelectSort: { sort = $0; isManualOrderActive = false },
                    onSelectManualOrder: { isManualOrderActive = true },
                    editMode: $editMode,
                    selectedIDs: $selectedIDs,
                    bulkContext: .scores,
                    onBulkAddToPlaylist: {},
                    onBulkEditTags: {},
                    onBulkDelete: {}
                ) { _ in
                    Button("Open") {}
                    Button("Delete", role: .destructive) {}
                }
                .navigationTitle("All Scores")
            }
        }
    }
```

(For `#if !os(iOS)` builds the `editMode` `@State` won't exist; that's acceptable because `ScoreListView` only declares the binding under `#if os(iOS)`. The init order in Swift requires we still pass all bindings; if you're targeting macOS in the same file, gate the call site with `#if os(iOS)` blocks. Folino is iOS-only, so this works as-is.)

- [ ] **Step 4: Build the package**

Run: `swift build --package-path Packages/Features/Library`
Expected: `Build complete!`

- [ ] **Step 5: Run tests (regression)**

Run: `swift test --package-path Packages/Features/Library`
Expected: all tests pass (including the bulk tests from Tasks 1–4).

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Views/ScoreListView.swift
git commit -m "feat(library): selection mode and bulk action bar in ScoreListView"
```

---

### Task 12: `ScoreListScreen` wiring

`ScoreListScreen` owns the new state and presents the bulk sheets and the per-context delete alert.

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Screens/ScoreListScreen.swift`

- [ ] **Step 1: Replace the file with the new wiring**

```swift
import Domain
import SwiftUI

struct ScoreListScreen: View {
    @Bindable var viewModel: ScoreListViewModel
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    let onEditTags: (ScoreItem) -> Void
    let onAddToPlaylist: (ScoreItem) -> Void

    @State private var pendingDelete: ScoreItem?
    #if os(iOS)
        @State private var editMode: EditMode = .inactive
    #endif
    @State private var selectedIDs: Set<ScoreItemID> = []
    @State private var bulkSheet: BulkSheet?
    @State private var bulkDeletePrompt: BulkDeletePrompt?

    private enum BulkSheet: Identifiable {
        case addToPlaylist
        case editTags
        var id: Int { switch self { case .addToPlaylist: 0; case .editTags: 1 } }
    }

    private struct BulkDeletePrompt: Identifiable {
        let id = UUID()
        let count: Int
    }

    var body: some View {
        ScoreListView(
            items: viewModel.displayedItems,
            searchText: $viewModel.searchQuery,
            sort: viewModel.sort,
            isManualOrderActive: viewModel.isManualOrderActive,
            showsManualOrderOption: isPlaylistSource,
            pendingDelete: $pendingDelete,
            onTap: onOpen,
            onToggleFavorite: { item in Task { await library.toggleFavorite(item) } },
            onConfirmDelete: { item in Task { await library.delete(item) } },
            onSelectSort: { viewModel.selectSort($0) },
            onSelectManualOrder: { viewModel.selectManualOrder() },
            editMode: editModeBinding,
            selectedIDs: $selectedIDs,
            bulkContext: bulkContext,
            onBulkAddToPlaylist: { bulkSheet = .addToPlaylist },
            onBulkEditTags: { bulkSheet = .editTags },
            onBulkDelete: { bulkDeletePrompt = BulkDeletePrompt(count: selectedIDs.count) }
        ) { item in
            scoreRowMenu(
                item: item,
                library: library,
                onOpen: onOpen,
                onEditTags: onEditTags,
                onAddToPlaylist: onAddToPlaylist,
                onRequestDelete: { pendingDelete = $0 }
            )
        }
        .sheet(item: $bulkSheet) { which in
            switch which {
            case .addToPlaylist:
                BulkAddToPlaylistScreen(
                    selectedIDs: selectedIDs,
                    orderedSelectedIDs: orderedSelectedIDs,
                    library: library,
                    onCommit: { exitSelectionMode(); bulkSheet = nil }
                )
            case .editTags:
                BulkEditTagsScreen(
                    selectedIDs: selectedIDs,
                    library: library,
                    onCommit: { exitSelectionMode(); bulkSheet = nil }
                )
            }
        }
        .alert(
            Text("Delete \(bulkDeletePrompt?.count ?? 0) scores?", bundle: .module),
            isPresented: bulkDeleteAlertBinding,
            presenting: bulkDeletePrompt
        ) { _ in
            Button(role: .destructive) {
                let ids = selectedIDs
                Task {
                    await library.bulkDelete(ids)
                    exitSelectionMode()
                }
            } label: {
                Text("Delete", bundle: .module)
            }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: { _ in
            Text("This will remove the scores and their files from this device.", bundle: .module)
        }
    }

    private var isPlaylistSource: Bool {
        if case .playlist = viewModel.source { return true }
        return false
    }

    private var bulkContext: BulkContext {
        // ScoreListScreen is used for All Scores and Tag detail today.
        // Playlist detail uses PlaylistDetailScreen, which has its own
        // delete-prompt UX and never instantiates ScoreListScreen.
        .scores
    }

    private var orderedSelectedIDs: [ScoreItemID] {
        viewModel.displayedItems
            .map(\.id)
            .filter { selectedIDs.contains($0) }
    }

    private var editModeBinding: Binding<EditMode> {
        #if os(iOS)
            return $editMode
        #else
            return .constant(.inactive)
        #endif
    }

    private var bulkDeleteAlertBinding: Binding<Bool> {
        Binding(
            get: { bulkDeletePrompt != nil },
            set: { isPresented in if !isPresented { bulkDeletePrompt = nil } }
        )
    }

    private func exitSelectionMode() {
        selectedIDs = []
        #if os(iOS)
            editMode = .inactive
        #endif
    }
}
```

- [ ] **Step 2: Build the package**

Run: `swift build --package-path Packages/Features/Library`
Expected: `Build complete!`

- [ ] **Step 3: Run tests (regression)**

Run: `swift test --package-path Packages/Features/Library`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Screens/ScoreListScreen.swift
git commit -m "feat(library): wire bulk select state in ScoreListScreen"
```

---

### Task 13: `PlaylistDetailView` selection mode

`PlaylistDetailView` already drives `EditMode` for reorder. Add the selection binding and bottom action bar; existing `onMove` / `onDelete` keep working.

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Views/PlaylistDetailView.swift`

- [ ] **Step 1: Add selection bindings and bulk callbacks**

In the struct's stored-property block (currently lines 5–11 of `PlaylistDetailView`), add after `let onDelete: () -> Void`:

```swift
    @Binding var selectedIDs: Set<ScoreItemID>
    let onBulkAddToPlaylist: () -> Void
    let onBulkEditTags: () -> Void
    let onBulkDelete: () -> Void
```

(`editMode` is already an internal `@State` here; keep it as-is.)

- [ ] **Step 2: Switch the `List` to selection and add the bottom bar**

Replace the inner list block:

```swift
                List {
                    ForEach(items) { item in
                        ScoreRow(scoreItem: item)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpen(item) }
                    }
                    .onMove(perform: onMove)
                    .onDelete(perform: onRemoveFromPlaylist)
                }
```

with:

```swift
                List(selection: $selectedIDs) {
                    ForEach(items) { item in
                        ScoreRow(scoreItem: item)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpen(item) }
                            .tag(item.id)
                    }
                    .onMove(perform: onMove)
                    .onDelete(perform: onRemoveFromPlaylist)
                }
```

Then add a `.safeAreaInset(edge: .bottom)` modifier on the outer `Group`. Find the line:

```swift
        .navigationTitle(playlistName)
```

Insert just above it:

```swift
        .safeAreaInset(edge: .bottom) {
            #if os(iOS)
                if editMode.isEditing {
                    BulkActionBar(
                        selectionCount: selectedIDs.count,
                        onAddToPlaylist: onBulkAddToPlaylist,
                        onEditTags: onBulkEditTags,
                        onDelete: onBulkDelete
                    )
                }
            #endif
        }
```

- [ ] **Step 3: Update the `#Preview` blocks**

Replace both `#Preview` calls (Filled and Empty) so they pass the new arguments. Add a `@State` host above:

```swift
    private struct PlaylistDetailViewPreviewHost: View {
        let playlistName: String
        let items: [ScoreItem]
        @State private var selectedIDs: Set<ScoreItemID> = []

        var body: some View {
            NavigationStack {
                PlaylistDetailView(
                    playlistName: playlistName,
                    items: items,
                    onOpen: { _ in },
                    onMove: { _, _ in },
                    onRemoveFromPlaylist: { _ in },
                    onRename: { _ in },
                    onDelete: {},
                    selectedIDs: $selectedIDs,
                    onBulkAddToPlaylist: {},
                    onBulkEditTags: {},
                    onBulkDelete: {}
                )
            }
        }
    }

    #Preview("Filled") {
        PlaylistDetailViewPreviewHost(
            playlistName: "Daily warm-up",
            items: PlaylistDetailViewPreview.items
        )
    }

    #Preview("Empty") {
        PlaylistDetailViewPreviewHost(playlistName: "Empty Set", items: [])
    }
```

- [ ] **Step 4: Build the package**

Run: `swift build --package-path Packages/Features/Library`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Views/PlaylistDetailView.swift
git commit -m "feat(library): selection mode and bulk action bar in PlaylistDetailView"
```

---

### Task 14: `PlaylistDetailScreen` wiring

`PlaylistDetailScreen` owns selection state, presents bulk sheets, and shows the three-button delete alert (Remove from playlist / Delete completely / Cancel).

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Screens/PlaylistDetailScreen.swift`

- [ ] **Step 1: Replace the file**

```swift
import Domain
import Foundation
import SwiftUI

struct PlaylistDetailScreen: View {
    let playlist: Playlist
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    let onPlaylistDeleted: () -> Void

    @State private var selectedIDs: Set<ScoreItemID> = []
    @State private var bulkSheet: BulkSheet?
    @State private var bulkDeletePrompt: BulkDeletePrompt?

    private enum BulkSheet: Identifiable {
        case addToPlaylist, editTags
        var id: Int { switch self { case .addToPlaylist: 0; case .editTags: 1 } }
    }

    private struct BulkDeletePrompt: Identifiable {
        let id = UUID()
        let count: Int
    }

    var body: some View {
        PlaylistDetailView(
            playlistName: playlist.name,
            items: orderedItems,
            onOpen: onOpen,
            onMove: { offsets, destination in move(from: offsets, to: destination) },
            onRemoveFromPlaylist: { offsets in removeFromPlaylist(at: offsets) },
            onRename: { newName in Task { await commitRename(newName) } },
            onDelete: { Task { await commitDelete() } },
            selectedIDs: $selectedIDs,
            onBulkAddToPlaylist: { bulkSheet = .addToPlaylist },
            onBulkEditTags: { bulkSheet = .editTags },
            onBulkDelete: { bulkDeletePrompt = BulkDeletePrompt(count: selectedIDs.count) }
        )
        .sheet(item: $bulkSheet) { which in
            switch which {
            case .addToPlaylist:
                BulkAddToPlaylistScreen(
                    selectedIDs: selectedIDs,
                    orderedSelectedIDs: orderedSelectedIDs,
                    library: library,
                    onCommit: { selectedIDs = []; bulkSheet = nil }
                )
            case .editTags:
                BulkEditTagsScreen(
                    selectedIDs: selectedIDs,
                    library: library,
                    onCommit: { selectedIDs = []; bulkSheet = nil }
                )
            }
        }
        .confirmationDialog(
            Text("Delete \(bulkDeletePrompt?.count ?? 0) scores?", bundle: .module),
            isPresented: bulkDeleteAlertBinding,
            presenting: bulkDeletePrompt
        ) { _ in
            Button {
                let ids = selectedIDs
                Task {
                    await library.bulkRemoveFromPlaylist(ids, from: currentPlaylist())
                    selectedIDs = []
                }
            } label: {
                Text("Remove from playlist", bundle: .module)
            }
            Button(role: .destructive) {
                let ids = selectedIDs
                Task {
                    await library.bulkDelete(ids)
                    selectedIDs = []
                }
            } label: {
                Text("Delete completely", bundle: .module)
            }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        }
    }

    private var orderedItems: [ScoreItem] {
        let lookup = Dictionary(uniqueKeysWithValues: library.repository.scoreItems.map { ($0.id, $0) })
        return currentPlaylist().orderedScoreItemIDs.compactMap { lookup[$0] }
    }

    private var orderedSelectedIDs: [ScoreItemID] {
        orderedItems.map(\.id).filter { selectedIDs.contains($0) }
    }

    private var bulkDeleteAlertBinding: Binding<Bool> {
        Binding(
            get: { bulkDeletePrompt != nil },
            set: { isPresented in if !isPresented { bulkDeletePrompt = nil } }
        )
    }

    /// Re-read the playlist on each touch so reorder/save round-trips work.
    private func currentPlaylist() -> Playlist {
        library.repository.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        var ids = currentPlaylist().orderedScoreItemIDs
        ids.move(fromOffsets: offsets, toOffset: destination)
        var updated = currentPlaylist()
        updated.orderedScoreItemIDs = ids
        Task { await save(updated) }
    }

    private func removeFromPlaylist(at offsets: IndexSet) {
        let removedIDs = offsets.map { orderedItems[$0].id }
        var updated = currentPlaylist()
        updated.orderedScoreItemIDs.removeAll { removedIDs.contains($0) }
        Task { await save(updated) }
    }

    private func commitRename(_ newName: String) async {
        var updated = currentPlaylist()
        updated.name = newName
        await save(updated)
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

    private func save(_ updated: Playlist) async {
        do {
            try await library.repository.savePlaylist(updated)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Build the package**

Run: `swift build --package-path Packages/Features/Library`
Expected: `Build complete!`

- [ ] **Step 3: Run tests (regression)**

Run: `swift test --package-path Packages/Features/Library`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Screens/PlaylistDetailScreen.swift
git commit -m "feat(library): wire bulk select state in PlaylistDetailScreen"
```

---

### Task 15: Full app build + smoke

**Files:** None modified (verification only).

- [ ] **Step 1: Regenerate Xcode project (only if `project.yml` changed; it didn't, but harmless)**

Run: `xcodegen generate`
Expected: project regenerates without errors.

- [ ] **Step 2: Build the full app**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`
Expected: `** BUILD SUCCEEDED **`. No SwiftLint failures.

- [ ] **Step 3: Smoke checklist (manual, on simulator)**

Launch the app. Walk through:
- All Scores → Select → check 2 rows → bottom bar enables → "Tags" → check a tag → Done → confirm tag appears on both rows.
- All Scores → Select → check 2 rows → "Add to Playlist" → tap a playlist → confirm both rows now appear in that playlist (open the playlist detail).
- All Scores → Select → check 2 rows → "Delete" → confirm "Delete 2 scores?" alert → Delete → both rows gone.
- Tag detail → same three actions.
- Playlist detail → Select → check 2 rows → "Delete" → confirm 3-button alert appears → "Remove from playlist" → both rows leave the playlist but remain in All Scores. Repeat with "Delete completely" on a fresh selection → both rows gone from All Scores.
- Playlist detail → still able to reorder rows (drag handles) while in edit mode.

If any step fails, file a follow-up before merging. No automated UI test is required.

- [ ] **Step 4: Final commit (only if smoke surfaced a fix)**

If smoke passes cleanly, no extra commit; the previous task's commit is the last. If a fix is needed, commit it with a descriptive message.

---

## Self-Review Notes (already applied)

- All four spec methods (`bulkDelete`, `bulkRemoveFromPlaylist`, `bulkAddToPlaylist`, `bulkAddTags`) have a TDD task each (1–4).
- Localization keys from the spec table appear in Task 5.
- Both list views (`ScoreListView`, `PlaylistDetailView`) get selection state in Tasks 11 and 13. Both Screens get wiring in Tasks 12 and 14. The shared `BulkActionBar` in Task 6 backs both.
- "Three-button delete alert in Playlist detail" is implemented via `confirmationDialog` (Task 14), which on iOS surfaces as the action-sheet-style with Remove / Delete completely / Cancel. The plain-alert version is used in `ScoreListScreen` (Task 12).
- `bulkContext` parameter is included in `ScoreListView` for forward-compat / clarity. `ScoreListScreen` always passes `.scores` because Playlist detail uses a different view; the enum is still useful for future use and reads as documentation at the call site.
- The `BulkContext` enum lives at file scope of `ScoreListView.swift`, so other files reference it as an unqualified `BulkContext`.
- `currentPlaylist()` in `PlaylistDetailScreen` re-reads from the repository — needed because reorder + bulk add/remove both mutate the playlist and we must avoid stale reads between operations.
- Empty-input no-op semantics match spec for all four bulk methods. Partial-failure-stops-at-first-error matches spec.

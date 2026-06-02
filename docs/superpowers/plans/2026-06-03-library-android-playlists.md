# Library Android — Playlists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the iOS Library Playlists feature (manually-ordered score collections) to Android, sharing all ordering/membership/projection logic with iOS and matching iOS's join-table persistence.

**Architecture:** Pure playlist logic is lifted into Domain (`Playlist` membership helpers + `PlaylistPresentation`), called by both the iOS `LibraryViewModel`/screens and the Android Swift `LibraryAndroidStore`. The store exposes playlist data as `@WireletObservable` `StateFlow`s and mutations as `Void` `@WireletExpose` methods (bridge cannot return values). Kotlin/Room is a rule-free backend with `playlists` + `playlist_items(position)` tables mirroring iOS GRDB. Compose adds a drawer destination, drag-handle reorder, and single/bulk add-to-playlist.

**Tech Stack:** Swift 6.3, Swift Testing, Domain (Foundation-only), swift-wirelet v0.3.2 (`@WireFormat`/`@WireletObservable`/`@WireletProvided`), Kotlin/Room 2.6.1 + KSP, Jetpack Compose Material3, `sh.calvin.reorderable` (Apache-2.0).

**Spec:** `docs/superpowers/specs/2026-06-03-library-android-playlists-design.md`

---

## Test command reference

- **Domain pure tests:** `cd Packages/Domain && xcrun swift test --filter <Name>`
  (if the SwiftLint build plugin blocks `swift test`, fall back to
  `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17'`).
- **Library JNI host tests:** `cd Packages/Features/Library && FOLINO_ANDROID=1 xcrun swift test --filter LibraryAndroidStoreTests`.
- **iOS Library feature tests (after refactor):**
  `xcodebuild test -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
  (iPhone 16 sim is not installed; use iPhone 17).
- **Android cross-compile (codegen → compile, JNI_OnLoad):** `Scripts/android-build-libs.sh`.
- **Android install + launch:** `Android/gradlew -p Android :app:installDebug` then
  `adb shell am start -n com.keynumber.folino/.MainActivity`.

---

## File Structure

**Domain (new / shared logic):**
- Create `Packages/Domain/Sources/Domain/Models/Playlist+Membership.swift` — `appendingUnique`, `toggleMembership`, `removing`.
- Create `Packages/Domain/Sources/Domain/Presentation/PlaylistPresentation.swift` — `orderedLiveIDs`, `liveMemberCount`.
- Create `Packages/Domain/Tests/DomainTests/PlaylistMembershipTests.swift`, `Packages/Domain/Tests/DomainTests/PlaylistPresentationTests.swift`.

**iOS Library (refactor to shared helpers):**
- Modify `Packages/Features/Library/Sources/Library/LibraryViewModel.swift` (`bulkAddToPlaylist`, `bulkRemoveFromPlaylist`).
- Modify `Packages/Features/Library/Sources/Library/Screens/AddToPlaylistScreen.swift` (`toggle`).
- Modify `Packages/Features/Library/Sources/Library/Screens/PlaylistDetailScreen.swift` (`orderedItems`, `removeFromPlaylist`).
- Modify `Packages/Features/Library/Sources/Library/Screens/PlaylistsListScreen.swift` (`memberCount`).
- Modify `Packages/Features/Library/Sources/Library/Screens/LibraryRootCollapsibleSections.swift:65` (member count).

**Android Swift bridge (new wire types + store):**
- Create `Packages/Features/Library/Sources/FolinoLibraryJNI/PlaylistRowWire.swift`, `PlaylistPickWire.swift`, `PlaylistRecordWire.swift`, `PlaylistItemWire.swift`.
- Modify `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift` (protocol additions).
- Modify `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift` (playlist observables + methods).
- Modify `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift` (fake + tests).

**Android Kotlin backend:**
- Modify `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt` (tables, DAO, migration, new methods).

**Android Compose UI:**
- Modify `Android/app/build.gradle.kts` (reorderable dep).
- Modify `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` (drawer + routes).
- Create `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/PlaylistsListScreen.kt`.
- Create `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/PlaylistDetailScreen.kt`.
- Create `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/AddToPlaylistSheet.kt`.
- Modify `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt` (row overflow + bulk CAB).
- Modify `Android/app/src/main/res/values/strings.xml` (new strings).

---

## Phase A — Shared Domain logic (TDD)

### Task A1: `Playlist` membership helpers

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/Playlist+Membership.swift`
- Test: `Packages/Domain/Tests/DomainTests/PlaylistMembershipTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Domain

struct PlaylistMembershipTests {
    private func ids(_ n: Int) -> [ScoreItemID] {
        (0..<n).map { _ in ScoreItemID() }
    }

    @Test func `appendingUnique adds only absent ids, preserving order`() {
        let a = ScoreItemID(); let b = ScoreItemID(); let c = ScoreItemID()
        var playlist = Playlist(name: "P", orderedScoreItemIDs: [a, b], createdAt: Date())
        playlist.appendingUnique([b, c, c])
        #expect(playlist.orderedScoreItemIDs == [a, b, c])
    }

    @Test func `toggleMembership appends when absent and removes when present`() {
        let a = ScoreItemID(); let b = ScoreItemID()
        var playlist = Playlist(name: "P", orderedScoreItemIDs: [a], createdAt: Date())
        playlist.toggleMembership(b)
        #expect(playlist.orderedScoreItemIDs == [a, b])
        playlist.toggleMembership(a)
        #expect(playlist.orderedScoreItemIDs == [b])
    }

    @Test func `removing drops the given ids and keeps order`() {
        let a = ScoreItemID(); let b = ScoreItemID(); let c = ScoreItemID()
        var playlist = Playlist(name: "P", orderedScoreItemIDs: [a, b, c], createdAt: Date())
        playlist.removing([b])
        #expect(playlist.orderedScoreItemIDs == [a, c])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/Domain && xcrun swift test --filter PlaylistMembershipTests`
Expected: FAIL — `value of type 'Playlist' has no member 'appendingUnique'`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

public extension Playlist {
    /// Append the IDs not already present, preserving existing order followed by
    /// the new IDs' first-seen order. De-duplicates within `ids` too.
    /// (iOS single-add + `LibraryViewModel.bulkAddToPlaylist` semantics.)
    mutating func appendingUnique(_ ids: [ScoreItemID]) {
        var seen = Set(orderedScoreItemIDs)
        for id in ids where !seen.contains(id) {
            orderedScoreItemIDs.append(id)
            seen.insert(id)
        }
    }

    /// Append if absent, remove if present. (iOS `AddToPlaylistScreen.toggle`.)
    mutating func toggleMembership(_ id: ScoreItemID) {
        if let idx = orderedScoreItemIDs.firstIndex(of: id) {
            orderedScoreItemIDs.remove(at: idx)
        } else {
            orderedScoreItemIDs.append(id)
        }
    }

    /// Remove the given IDs, preserving the order of the rest.
    /// (iOS `removeFromPlaylist` / `bulkRemoveFromPlaylist`.)
    mutating func removing(_ ids: Set<ScoreItemID>) {
        orderedScoreItemIDs.removeAll { ids.contains($0) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/Domain && xcrun swift test --filter PlaylistMembershipTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/Playlist+Membership.swift Packages/Domain/Tests/DomainTests/PlaylistMembershipTests.swift
git commit -m "feat(domain): shared Playlist membership helpers"
```

### Task A2: `PlaylistPresentation` projection

**Files:**
- Create: `Packages/Domain/Sources/Domain/Presentation/PlaylistPresentation.swift`
- Test: `Packages/Domain/Tests/DomainTests/PlaylistPresentationTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Domain

struct PlaylistPresentationTests {
    @Test func `orderedLiveIDs keeps order and drops non-live ids`() {
        let a = ScoreItemID(); let b = ScoreItemID(); let c = ScoreItemID()
        let playlist = Playlist(name: "P", orderedScoreItemIDs: [a, b, c], createdAt: Date())
        let result = PlaylistPresentation.orderedLiveIDs(playlist, liveIDs: [c, a])
        #expect(result == [a, c]) // b excluded, order preserved
    }

    @Test func `liveMemberCount counts only live members`() {
        let a = ScoreItemID(); let b = ScoreItemID(); let c = ScoreItemID()
        let playlist = Playlist(name: "P", orderedScoreItemIDs: [a, b, c], createdAt: Date())
        #expect(PlaylistPresentation.liveMemberCount(playlist, liveIDs: [a, c]) == 2)
        #expect(PlaylistPresentation.liveMemberCount(playlist, liveIDs: []) == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/Domain && xcrun swift test --filter PlaylistPresentationTests`
Expected: FAIL — `cannot find 'PlaylistPresentation' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Pure projection of a playlist against the set of currently-live score IDs.
/// Shared by the iOS `PlaylistDetailScreen` / `PlaylistsListScreen` and the
/// Android `LibraryAndroidStore` so both derive identical display data.
public enum PlaylistPresentation {
    /// The playlist's ordered IDs filtered to those still live, order preserved.
    public static func orderedLiveIDs(_ playlist: Playlist, liveIDs: Set<ScoreItemID>) -> [ScoreItemID] {
        playlist.orderedScoreItemIDs.filter { liveIDs.contains($0) }
    }

    /// Count of the playlist's members that are still live.
    public static func liveMemberCount(_ playlist: Playlist, liveIDs: Set<ScoreItemID>) -> Int {
        playlist.orderedScoreItemIDs.reduce(0) { $0 + (liveIDs.contains($1) ? 1 : 0) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/Domain && xcrun swift test --filter PlaylistPresentationTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Presentation/PlaylistPresentation.swift Packages/Domain/Tests/DomainTests/PlaylistPresentationTests.swift
git commit -m "feat(domain): PlaylistPresentation live projection helpers"
```

---

## Phase B — iOS refactor to shared helpers

### Task B1: Route iOS sites through the shared helpers

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift:164-194`
- Modify: `Packages/Features/Library/Sources/Library/Screens/AddToPlaylistScreen.swift:18-30`
- Modify: `Packages/Features/Library/Sources/Library/Screens/PlaylistDetailScreen.swift:96-143`
- Modify: `Packages/Features/Library/Sources/Library/Screens/PlaylistsListScreen.swift:1-33`
- Modify: `Packages/Features/Library/Sources/Library/Screens/LibraryRootCollapsibleSections.swift:60-70`

- [ ] **Step 1: Refactor `LibraryViewModel.bulkRemoveFromPlaylist` and `bulkAddToPlaylist`**

Replace the body of `bulkRemoveFromPlaylist` (currently lines 164-177):

```swift
    func bulkRemoveFromPlaylist(
        _ ids: Set<ScoreItemID>,
        from playlist: Playlist,
    ) async {
        guard !ids.isEmpty else { return }
        var updated = playlist
        updated.removing(ids)
        guard updated.orderedScoreItemIDs != playlist.orderedScoreItemIDs else { return }
        do {
            try await repository.savePlaylist(updated)
        } catch {
            currentError = error
        }
    }
```

Replace the body of `bulkAddToPlaylist` (currently lines 179-194):

```swift
    func bulkAddToPlaylist(
        _ orderedIDs: [ScoreItemID],
        to playlist: Playlist,
    ) async {
        guard !orderedIDs.isEmpty else { return }
        var updated = playlist
        updated.appendingUnique(orderedIDs)
        guard updated.orderedScoreItemIDs != playlist.orderedScoreItemIDs else { return }
        do {
            try await repository.savePlaylist(updated)
        } catch {
            currentError = error
        }
    }
```

- [ ] **Step 2: Refactor `AddToPlaylistScreen.toggle`**

Replace `toggle(_:)` (lines 18-30):

```swift
    private func toggle(_ playlist: Playlist) async {
        var updated = playlist
        updated.toggleMembership(scoreItem.id)
        do {
            try await library.repository.savePlaylist(updated)
        } catch {
            library.currentError = error
        }
    }
```

- [ ] **Step 3: Refactor `PlaylistDetailScreen.orderedItems` and `removeFromPlaylist`**

Replace `orderedItems` (lines 96-99):

```swift
    private var orderedItems: [ScoreItem] {
        let lookup = Dictionary(uniqueKeysWithValues: library.repository.scoreItems.map { ($0.id, $0) })
        return PlaylistPresentation
            .orderedLiveIDs(currentPlaylist(), liveIDs: Set(lookup.keys))
            .compactMap { lookup[$0] }
    }
```

Replace `removeFromPlaylist(_:)` (lines 139-143):

```swift
    private func removeFromPlaylist(_ item: ScoreItem) {
        var updated = currentPlaylist()
        updated.removing([item.id])
        Task { await save(updated) }
    }
```

- [ ] **Step 4: Refactor `PlaylistsListScreen.memberCount`**

Replace the `memberCount` closure (lines 10-14):

```swift
            memberCount: { playlist in
                PlaylistPresentation.liveMemberCount(playlist, liveIDs: liveIDs)
            },
```

(`liveIDs` already exists at lines 30-32.)

- [ ] **Step 5: Refactor `LibraryRootCollapsibleSections` member count**

At `LibraryRootCollapsibleSections.swift:65`, replace the inline
`playlist.orderedScoreItemIDs.reduce(0) { ... liveIDs.contains ... }` member-count
computation with `PlaylistPresentation.liveMemberCount(playlist, liveIDs: liveIDs)`
(keep whatever local `liveIDs`/live-set variable the surrounding function already
builds; if it is a `[ScoreItemID]`, wrap with `Set(...)`).

- [ ] **Step 6: Run the iOS Library tests to verify no regression**

Run: `xcodebuild test -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: PASS — existing `LibraryViewModelBulkTests`, `LibraryViewModelTests`, `ScoreListViewModelTests`, `LibrarySortTests` all green (behavior preserved).

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Library/Sources/Library
git commit -m "refactor(library): route iOS playlist logic through shared Domain helpers"
```

---

## Phase C — Android wire types

### Task C1: Add the four `@WireFormat` playlist wire structs

**Files:**
- Create: `Packages/Features/Library/Sources/FolinoLibraryJNI/PlaylistRowWire.swift`
- Create: `Packages/Features/Library/Sources/FolinoLibraryJNI/PlaylistPickWire.swift`
- Create: `Packages/Features/Library/Sources/FolinoLibraryJNI/PlaylistRecordWire.swift`
- Create: `Packages/Features/Library/Sources/FolinoLibraryJNI/PlaylistItemWire.swift`

- [ ] **Step 1: Write `PlaylistRowWire.swift`**

```swift
import Wirelet

/// Display projection of a playlist row (list screen): name + live member count.
@WireFormat
public struct PlaylistRowWire: Equatable, Sendable {
    public var id: String
    public var name: String
    public var memberCount: Int32

    public init(id: String, name: String, memberCount: Int32) {
        self.id = id
        self.name = name
        self.memberCount = memberCount
    }
}
```

- [ ] **Step 2: Write `PlaylistPickWire.swift`**

```swift
import Wirelet

/// A playlist option in the Add-to-playlist sheet. `contains` is the focused
/// score's current membership (always false for the bulk sheet).
@WireFormat
public struct PlaylistPickWire: Equatable, Sendable {
    public var id: String
    public var name: String
    public var contains: Bool

    public init(id: String, name: String, contains: Bool) {
        self.id = id
        self.name = name
        self.contains = contains
    }
}
```

- [ ] **Step 3: Write `PlaylistRecordWire.swift`**

```swift
import Wirelet

/// Persistence projection of a playlist's own row (without its membership),
/// 1:1 with the iOS GRDB `playlists` table.
@WireFormat
public struct PlaylistRecordWire: Equatable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Double // Unix time (Date.timeIntervalSince1970)

    public init(id: String, name: String, createdAt: Double) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
```

- [ ] **Step 4: Write `PlaylistItemWire.swift`**

```swift
import Wirelet

/// One playlist-membership row. Order is carried by `position` (0-based),
/// mirroring the iOS GRDB `playlist_items` table. A `[String]` field cannot
/// live inside a `@WireFormat` struct, so membership is modeled as flat rows.
@WireFormat
public struct PlaylistItemWire: Equatable, Sendable {
    public var playlistId: String
    public var scoreItemId: String
    public var position: Int32

    public init(playlistId: String, scoreItemId: String, position: Int32) {
        self.playlistId = playlistId
        self.scoreItemId = scoreItemId
        self.position = position
    }
}
```

- [ ] **Step 5: Verify the package still builds**

Run: `cd Packages/Features/Library && FOLINO_ANDROID=1 xcrun swift build`
Expected: build succeeds (macro expansion of the four `@WireFormat` structs OK).

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/Playlist*.swift
git commit -m "feat(library-jni): playlist wire types"
```

---

## Phase D — Backend protocol + Swift store (host TDD)

### Task D1: Extend the `LibraryStore` protocol and the test fake

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift`
- Modify: `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift:7-35`

- [ ] **Step 1: Add the playlist methods to the protocol**

Append inside the `LibraryStore` protocol body:

```swift
    /// Every persisted playlist row (without membership).
    func loadPlaylists() -> [PlaylistRecordWire]

    /// Every membership row, ordered by `(playlistId, position)`.
    func loadPlaylistItems() -> [PlaylistItemWire]

    /// Insert or replace a playlist row by `record.id`.
    func upsertPlaylist(_ record: PlaylistRecordWire)

    /// Replace ALL membership rows for `playlistId` with `items` (drop + reinsert
    /// with the given positions) — mirrors the iOS `savePlaylist` semantics.
    func replacePlaylistItems(_ playlistId: String, _ items: [PlaylistItemWire])

    /// Remove a playlist row and all of its membership rows.
    func deletePlaylist(id: String)
```

- [ ] **Step 2: Extend the test fake to implement them**

In `LibraryAndroidStoreTests.swift`, add stored state and methods to `FakeLibraryStore`:

```swift
    var playlistRecords: [PlaylistRecordWire] = []
    var playlistItems: [PlaylistItemWire] = []

    func loadPlaylists() -> [PlaylistRecordWire] { playlistRecords }

    func loadPlaylistItems() -> [PlaylistItemWire] {
        playlistItems.sorted {
            $0.playlistId == $1.playlistId ? $0.position < $1.position : $0.playlistId < $1.playlistId
        }
    }

    func upsertPlaylist(_ record: PlaylistRecordWire) {
        if let idx = playlistRecords.firstIndex(where: { $0.id == record.id }) {
            playlistRecords[idx] = record
        } else {
            playlistRecords.append(record)
        }
    }

    func replacePlaylistItems(_ playlistId: String, _ items: [PlaylistItemWire]) {
        playlistItems.removeAll { $0.playlistId == playlistId }
        playlistItems.append(contentsOf: items)
    }

    func deletePlaylist(id: String) {
        playlistRecords.removeAll { $0.id == id }
        playlistItems.removeAll { $0.playlistId == id }
    }
```

- [ ] **Step 3: Verify it compiles (existing tests still pass)**

Run: `cd Packages/Features/Library && FOLINO_ANDROID=1 xcrun swift test --filter LibraryAndroidStoreTests`
Expected: PASS — the 12 existing tests still pass; the fake now satisfies the protocol.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift
git commit -m "feat(library-jni): LibraryStore playlist backend protocol + fake"
```

### Task D2: Store scaffolding — playlist observables, helpers, `reloadPlaylists`, `createPlaylist`

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`
- Test: `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
    @Test func `createPlaylist adds a name-sorted row with zero live members`() {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)

        store.createPlaylist("Recital")
        store.createPlaylist("Daily")
        store.createPlaylist("   ") // blank ignored

        #expect(store.playlists.map(\.name) == ["Daily", "Recital"]) // localizedStandardCompare
        #expect(store.playlists.allSatisfy { $0.memberCount == 0 })
        #expect(backend.playlistRecords.count == 2)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/Features/Library && FOLINO_ANDROID=1 xcrun swift test --filter LibraryAndroidStoreTests`
Expected: FAIL — `value of type 'LibraryAndroidStore' has no member 'playlists'`.

- [ ] **Step 3: Add observables, helpers, reload, and `createPlaylist`**

Add the import at the top (Domain is already imported):

```swift
// (Domain already imported for ScoreFormat/ScorePresentation — also gives
//  Playlist, PlaylistID, ScoreItemID, PlaylistPresentation.)
```

Add stored observable properties next to `scores`/`deletedScores`:

```swift
    public var playlists: [PlaylistRowWire] = []
    public var selectedPlaylistItems: [ScoreRowWire] = []
    public var addSheetPlaylists: [PlaylistPickWire] = []

    @ObservationIgnored private var selectedPlaylistID: String?
    @ObservationIgnored private var addSheetScoreID: String?
```

In `init`, after the existing `reload()`, add `reloadPlaylists()`.

Add these helpers and methods (anywhere in the class body):

```swift
    // MARK: - Playlists

    private func scoreItemID(_ raw: String) -> ScoreItemID? {
        UUID(uuidString: raw).map(ScoreItemID.init(rawValue:))
    }

    /// Set of live (`deletedAt <= 0`) score IDs, for membership projection.
    private func liveScoreIDs(_ records: [ScoreRecordWire]) -> Set<ScoreItemID> {
        Set(records.filter { $0.deletedAt <= 0 }.compactMap { scoreItemID($0.id) })
    }

    /// Build Domain `Playlist` values from the backend's record + item rows
    /// (items already ordered by position), mirroring iOS materialization.
    private func loadDomainPlaylists() -> [Playlist] {
        let items = store.loadPlaylistItems()
        var idsByPlaylist: [String: [ScoreItemID]] = [:]
        for item in items {
            guard let sid = scoreItemID(item.scoreItemId) else { continue }
            idsByPlaylist[item.playlistId, default: []].append(sid)
        }
        return store.loadPlaylists().compactMap { rec in
            guard let uuid = UUID(uuidString: rec.id) else { return nil }
            return Playlist(
                id: PlaylistID(rawValue: uuid),
                name: rec.name,
                orderedScoreItemIDs: idsByPlaylist[rec.id] ?? [],
                createdAt: Date(timeIntervalSince1970: rec.createdAt),
            )
        }
    }

    private func domainPlaylist(_ id: String) -> Playlist? {
        loadDomainPlaylists().first { $0.id.rawValue.uuidString == id }
    }

    /// Persist a playlist: upsert its row, then drop + reinsert its membership
    /// with explicit positions (iOS `savePlaylist` parity).
    private func persist(_ playlist: Playlist) {
        let pid = playlist.id.rawValue.uuidString
        store.upsertPlaylist(PlaylistRecordWire(
            id: pid,
            name: playlist.name,
            createdAt: playlist.createdAt.timeIntervalSince1970,
        ))
        let items = playlist.orderedScoreItemIDs.enumerated().map { offset, id in
            PlaylistItemWire(playlistId: pid, scoreItemId: id.rawValue.uuidString, position: Int32(offset))
        }
        store.replacePlaylistItems(pid, items)
    }

    /// Recompute every playlist-derived observable from one backend snapshot.
    private func reloadPlaylists() {
        let domain = loadDomainPlaylists()
        let records = store.loadAll()
        let liveIDs = liveScoreIDs(records)

        playlists = domain
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map {
                PlaylistRowWire(
                    id: $0.id.rawValue.uuidString,
                    name: $0.name,
                    memberCount: Int32(PlaylistPresentation.liveMemberCount($0, liveIDs: liveIDs)),
                )
            }

        recomputeSelectedItems(domain: domain, records: records, liveIDs: liveIDs)
        refreshAddSheet(domain: domain)
    }

    private func recomputeSelectedItems(domain: [Playlist], records: [ScoreRecordWire], liveIDs: Set<ScoreItemID>) {
        guard let sel = selectedPlaylistID,
              let playlist = domain.first(where: { $0.id.rawValue.uuidString == sel }) else {
            selectedPlaylistItems = []
            return
        }
        var rowByID: [ScoreItemID: ScoreRowWire] = [:]
        for record in records where record.deletedAt <= 0 {
            if let sid = scoreItemID(record.id) { rowByID[sid] = Self.row(record) }
        }
        selectedPlaylistItems = PlaylistPresentation
            .orderedLiveIDs(playlist, liveIDs: liveIDs)
            .compactMap { rowByID[$0] }
    }

    private func refreshAddSheet(domain: [Playlist]) {
        let focus = addSheetScoreID.flatMap(scoreItemID)
        addSheetPlaylists = domain
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map {
                PlaylistPickWire(
                    id: $0.id.rawValue.uuidString,
                    name: $0.name,
                    contains: focus.map($0.orderedScoreItemIDs.contains) ?? false,
                )
            }
    }

    @WireletExpose
    public func createPlaylist(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        persist(Playlist(name: trimmed, orderedScoreItemIDs: [], createdAt: Date()))
        reloadPlaylists()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/Features/Library && FOLINO_ANDROID=1 xcrun swift test --filter LibraryAndroidStoreTests`
Expected: PASS — new `createPlaylist` test plus the existing 12.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift
git commit -m "feat(library-jni): playlist observables + createPlaylist"
```

### Task D3: `renamePlaylist` and `deletePlaylist`

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`
- Test: `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func `renamePlaylist updates the name; blank is ignored`() {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)
        store.createPlaylist("Old")
        let id = try! #require(store.playlists.first).id

        store.renamePlaylist(id, "New")
        #expect(store.playlists.map(\.name) == ["New"])

        store.renamePlaylist(id, "  ")
        #expect(store.playlists.map(\.name) == ["New"]) // unchanged
    }

    @Test func `deletePlaylist removes the row and its membership`() {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)
        store.createPlaylist("P")
        let id = try! #require(store.playlists.first).id

        store.deletePlaylist(id)
        #expect(store.playlists.isEmpty)
        #expect(backend.playlistRecords.isEmpty)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/Features/Library && FOLINO_ANDROID=1 xcrun swift test --filter LibraryAndroidStoreTests`
Expected: FAIL — no member `renamePlaylist`.

- [ ] **Step 3: Implement**

```swift
    @WireletExpose
    public func renamePlaylist(_ id: String, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var playlist = domainPlaylist(id) else { return }
        playlist.name = trimmed
        persist(playlist)
        reloadPlaylists()
    }

    @WireletExpose
    public func deletePlaylist(_ id: String) {
        store.deletePlaylist(id: id)
        if selectedPlaylistID == id { selectedPlaylistID = nil }
        reloadPlaylists()
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/Features/Library && FOLINO_ANDROID=1 xcrun swift test --filter LibraryAndroidStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library
git commit -m "feat(library-jni): rename + delete playlist"
```

### Task D4: membership mutations — `addToPlaylist`, `removeFromPlaylist`, `bulkAddToPlaylist`, `createPlaylistWithScores`

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`
- Test: `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func `addToPlaylist appends unique; bulkAdd de-dupes; createWithScores seeds membership`() {
        let backend = FakeLibraryStore()
        backend.records = ["a", "b", "c"].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createPlaylist("P")
        let pid = try! #require(store.playlists.first).id

        store.addToPlaylist("a", pid)
        store.addToPlaylist("a", pid) // duplicate ignored
        store.bulkAddToPlaylist(pid, ["b", "a", "c"]) // only b, c new
        #expect(store.playlists.first?.memberCount == 3)

        store.removeFromPlaylist("b", pid)
        #expect(store.playlists.first?.memberCount == 2)

        store.createPlaylistWithScores("Q", ["c", "c", "a"])
        let q = try! #require(store.playlists.first { $0.name == "Q" })
        #expect(q.memberCount == 2) // c, a (de-duped)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/Features/Library && FOLINO_ANDROID=1 xcrun swift test --filter LibraryAndroidStoreTests`
Expected: FAIL — no member `addToPlaylist`.

- [ ] **Step 3: Implement**

```swift
    @WireletExpose
    public func addToPlaylist(_ scoreId: String, _ playlistId: String) {
        guard let sid = scoreItemID(scoreId), var playlist = domainPlaylist(playlistId) else { return }
        playlist.appendingUnique([sid])
        persist(playlist)
        reloadPlaylists()
    }

    @WireletExpose
    public func removeFromPlaylist(_ scoreId: String, _ playlistId: String) {
        guard let sid = scoreItemID(scoreId), var playlist = domainPlaylist(playlistId) else { return }
        playlist.removing([sid])
        persist(playlist)
        reloadPlaylists()
    }

    @WireletExpose
    public func bulkAddToPlaylist(_ playlistId: String, _ scoreIds: [String]) {
        guard var playlist = domainPlaylist(playlistId) else { return }
        let ids = scoreIds.compactMap(scoreItemID)
        guard !ids.isEmpty else { return }
        playlist.appendingUnique(ids)
        persist(playlist)
        reloadPlaylists()
    }

    @WireletExpose
    public func createPlaylistWithScores(_ name: String, _ scoreIds: [String]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var playlist = Playlist(name: trimmed, orderedScoreItemIDs: [], createdAt: Date())
        playlist.appendingUnique(scoreIds.compactMap(scoreItemID))
        persist(playlist)
        reloadPlaylists()
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/Features/Library && FOLINO_ANDROID=1 xcrun swift test --filter LibraryAndroidStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library
git commit -m "feat(library-jni): playlist membership mutations"
```

### Task D5: `selectPlaylist` + `setPlaylistOrder`

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`
- Test: `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func `selectPlaylist exposes ordered live items; soft-deleted excluded`() {
        let backend = FakeLibraryStore()
        backend.records = ["a", "b", "c"].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createPlaylist("P")
        let pid = try! #require(store.playlists.first).id
        store.bulkAddToPlaylist(pid, ["a", "b", "c"])

        store.selectPlaylist(pid)
        #expect(store.selectedPlaylistItems.map(\.id) == ["a", "b", "c"])

        store.delete("b") // soft-delete b
        #expect(store.selectedPlaylistItems.map(\.id) == ["a", "c"])
        #expect(store.playlists.first?.memberCount == 2)
    }

    @Test func `setPlaylistOrder reorders live members and preserves hidden ones`() {
        let backend = FakeLibraryStore()
        backend.records = ["a", "b", "c"].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createPlaylist("P")
        let pid = try! #require(store.playlists.first).id
        store.bulkAddToPlaylist(pid, ["a", "b", "c"])
        store.selectPlaylist(pid)

        store.setPlaylistOrder(pid, ["c", "a", "b"])
        #expect(store.selectedPlaylistItems.map(\.id) == ["c", "a", "b"])
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/Features/Library && FOLINO_ANDROID=1 xcrun swift test --filter LibraryAndroidStoreTests`
Expected: FAIL — no member `selectPlaylist`.

- [ ] **Step 3: Implement**

```swift
    @WireletExpose
    public func selectPlaylist(_ id: String) {
        selectedPlaylistID = id
        reloadPlaylists()
    }

    /// Reorder a playlist to the given live order. Members hidden from the UI
    /// (e.g. soft-deleted, not shown) are appended after, so they are not lost.
    @WireletExpose
    public func setPlaylistOrder(_ playlistId: String, _ orderedIds: [String]) {
        guard var playlist = domainPlaylist(playlistId) else { return }
        let members = Set(playlist.orderedScoreItemIDs)
        let requested = orderedIds.compactMap(scoreItemID).filter { members.contains($0) }
        let requestedSet = Set(requested)
        let hidden = playlist.orderedScoreItemIDs.filter { !requestedSet.contains($0) }
        playlist.orderedScoreItemIDs = requested + hidden
        persist(playlist)
        reloadPlaylists()
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/Features/Library && FOLINO_ANDROID=1 xcrun swift test --filter LibraryAndroidStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library
git commit -m "feat(library-jni): select playlist + reorder"
```

### Task D6: add-sheet driver (`beginAddToPlaylist`/`beginBulkAddToPlaylist`) + `deleteMany`; wire playlist refresh into score mutations

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`
- Test: `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func `beginAddToPlaylist marks playlists containing the score`() {
        let backend = FakeLibraryStore()
        backend.records = ["a", "b"].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createPlaylist("P")
        let pid = try! #require(store.playlists.first).id
        store.addToPlaylist("a", pid)

        store.beginAddToPlaylist("a")
        #expect(store.addSheetPlaylists.map(\.contains) == [true])
        store.beginAddToPlaylist("b")
        #expect(store.addSheetPlaylists.map(\.contains) == [false])

        store.beginBulkAddToPlaylist()
        #expect(store.addSheetPlaylists.map(\.contains) == [false])
    }

    @Test func `deleteMany soft-deletes all and updates playlist counts`() {
        let backend = FakeLibraryStore()
        backend.records = ["a", "b", "c"].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createPlaylist("P")
        let pid = try! #require(store.playlists.first).id
        store.bulkAddToPlaylist(pid, ["a", "b", "c"])

        store.deleteMany(["a", "b"])
        #expect(Set(store.scores.map(\.id)) == ["c"])
        #expect(store.deletedScores.count == 2)
        #expect(store.playlists.first?.memberCount == 1)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/Features/Library && FOLINO_ANDROID=1 xcrun swift test --filter LibraryAndroidStoreTests`
Expected: FAIL — no member `beginAddToPlaylist`.

- [ ] **Step 3: Implement the add-sheet drivers and `deleteMany`**

```swift
    @WireletExpose
    public func beginAddToPlaylist(_ scoreId: String) {
        addSheetScoreID = scoreId
        refreshAddSheet(domain: loadDomainPlaylists())
    }

    @WireletExpose
    public func beginBulkAddToPlaylist() {
        addSheetScoreID = nil
        refreshAddSheet(domain: loadDomainPlaylists())
    }

    /// Bulk soft-delete (All Scores CAB "Delete"); mirrors iOS `bulkDelete`.
    @WireletExpose
    public func deleteMany(_ ids: [String]) {
        let now = Date().timeIntervalSince1970
        var all = store.loadAll()
        let idSet = Set(ids)
        for idx in all.indices where idSet.contains(all[idx].id) {
            all[idx].deletedAt = now
            store.upsert(all[idx])
        }
        reload(using: all)
        reloadPlaylists()
    }
```

- [ ] **Step 4: Keep playlist counts live after single-score mutations**

At the end of the existing `delete`, `restore`, `permanentlyDelete`, `restoreMany`,
and `permanentlyDeleteMany` methods, add a trailing `reloadPlaylists()` call so
member counts / selected items reflect score-level changes. (Each already calls
`reload(...)` for the score lists; append `reloadPlaylists()` after it.)

- [ ] **Step 5: Run to verify pass**

Run: `cd Packages/Features/Library && FOLINO_ANDROID=1 xcrun swift test --filter LibraryAndroidStoreTests`
Expected: PASS — all playlist tests plus the original 12.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Library
git commit -m "feat(library-jni): add-to-playlist sheet driver + bulk delete"
```

---

## Phase E — Kotlin Room backend

### Task E1: Room tables, DAOs, migration, and `LibraryStore` impl

**Files:**
- Modify: `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt`

> The Kotlin wire data classes (`PlaylistRowWire`, `PlaylistPickWire`,
> `PlaylistRecordWire`, `PlaylistItemWire`) are generated by the wirelet Kotlin
> codegen from the Swift `@WireFormat` structs — do not hand-write them. They
> become available after Phase C is built (Task G1 runs codegen).

- [ ] **Step 1: Add the two entities + DAO queries**

Add to `RoomLibraryStore.kt`:

```kotlin
@Entity(tableName = "playlists")
data class PlaylistEntity(
    @PrimaryKey val id: String,
    val name: String,
    @ColumnInfo(name = "created_at") val createdAt: Double,
)

@Entity(
    tableName = "playlist_items",
    primaryKeys = ["playlist_id", "score_item_id"],
)
data class PlaylistItemEntity(
    @ColumnInfo(name = "playlist_id") val playlistId: String,
    @ColumnInfo(name = "score_item_id") val scoreItemId: String,
    val position: Int,
)

@Dao
interface PlaylistDao {
    @Query("SELECT * FROM playlists")
    fun loadPlaylists(): List<PlaylistEntity>

    @Query("SELECT * FROM playlist_items ORDER BY playlist_id, position")
    fun loadItems(): List<PlaylistItemEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsertPlaylist(record: PlaylistEntity)

    @Query("DELETE FROM playlist_items WHERE playlist_id = :playlistId")
    fun deleteItems(playlistId: String)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun insertItems(items: List<PlaylistItemEntity>)

    @Query("DELETE FROM playlists WHERE id = :id")
    fun deletePlaylist(id: String)

    @androidx.room.Transaction
    fun replaceItems(playlistId: String, items: List<PlaylistItemEntity>) {
        deleteItems(playlistId)
        insertItems(items)
    }

    @androidx.room.Transaction
    fun deletePlaylistCascade(id: String) {
        deleteItems(id)
        deletePlaylist(id)
    }
}
```

- [ ] **Step 2: Register entities, bump version, add the DAO accessor + migration**

Update the `@Database` annotation and class:

```kotlin
@Database(
    entities = [ScoreRecordEntity::class, PlaylistEntity::class, PlaylistItemEntity::class],
    version = 2,
    exportSchema = false,
)
abstract class LibraryDatabase : RoomDatabase() {
    abstract fun dao(): ScoreRecordDao
    abstract fun playlistDao(): PlaylistDao
}

val MIGRATION_1_2 = object : androidx.room.migration.Migration(1, 2) {
    override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS `playlists` " +
                "(`id` TEXT NOT NULL, `name` TEXT NOT NULL, `created_at` REAL NOT NULL, PRIMARY KEY(`id`))",
        )
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS `playlist_items` " +
                "(`playlist_id` TEXT NOT NULL, `score_item_id` TEXT NOT NULL, `position` INTEGER NOT NULL, " +
                "PRIMARY KEY(`playlist_id`, `score_item_id`))",
        )
    }
}
```

In the `Room.databaseBuilder(...)` chain, add `.addMigrations(MIGRATION_1_2)` before `.build()`. Add `private val playlistDao = db.playlistDao()` next to the existing `dao`.

- [ ] **Step 3: Implement the new `LibraryStore` methods**

```kotlin
    override fun loadPlaylists(): List<PlaylistRecordWire> =
        playlistDao.loadPlaylists().map { PlaylistRecordWire(it.id, it.name, it.createdAt) }

    override fun loadPlaylistItems(): List<PlaylistItemWire> =
        playlistDao.loadItems().map { PlaylistItemWire(it.playlistId, it.scoreItemId, it.position) }

    override fun upsertPlaylist(record: PlaylistRecordWire) {
        playlistDao.upsertPlaylist(PlaylistEntity(record.id, record.name, record.createdAt))
    }

    override fun replacePlaylistItems(playlistId: String, items: List<PlaylistItemWire>) {
        playlistDao.replaceItems(
            playlistId,
            items.map { PlaylistItemEntity(it.playlistId, it.scoreItemId, it.position) },
        )
    }

    override fun deletePlaylist(id: String) {
        playlistDao.deletePlaylistCascade(id)
    }
```

(`PlaylistItemWire.position` is `Int32` in Swift → `Int` in Kotlin; assign directly.)

- [ ] **Step 4: Compile-check the module** (full verification is the device build in Phase G)

Run: `Scripts/android-build-libs.sh`
Expected: codegen + cross-compile succeed; generated wire classes resolve; no `RoomLibraryStore` errors. (See Task G1 for environment/PATH notes.)

- [ ] **Step 5: Commit**

```bash
git add Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt
git commit -m "feat(android-library): Room playlists + playlist_items backend (migration 1->2)"
```

---

## Phase F — Compose UI

> No Compose unit tests in this project (matching the pilot); UI is verified by
> the device build in Phase G. Each task ends by compiling via the Android build.

### Task F1: Reorderable dependency, strings, drawer destination, nav routes

**Files:**
- Modify: `Android/app/build.gradle.kts:55-75`
- Modify: `Android/app/src/main/res/values/strings.xml`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`

- [ ] **Step 1: Add the reorderable dependency**

In `Android/app/build.gradle.kts` `dependencies { ... }`:

```kotlin
    implementation("sh.calvin.reorderable:reorderable:2.4.3")
```

- [ ] **Step 2: Add strings**

In `Android/app/src/main/res/values/strings.xml`, add:

```xml
    <string name="nav_playlists">Playlists</string>
    <string name="playlists_title">Playlists</string>
    <string name="playlists_empty_title">No playlists</string>
    <string name="playlists_empty_hint">Tap + to create a playlist.</string>
    <string name="playlists_create">New playlist</string>
    <string name="playlists_name_hint">Playlist name</string>
    <string name="playlists_member_count">%1$d scores</string>
    <string name="playlists_delete">Delete playlist</string>
    <string name="playlists_delete_confirm_title">Delete \"%1$s\"?</string>
    <string name="playlists_delete_confirm_message">The scores stay in your library.</string>
    <string name="playlists_rename">Rename</string>
    <string name="playlist_remove_from">Remove from playlist</string>
    <string name="playlist_reorder_handle">Reorder</string>
    <string name="add_to_playlist">Add to playlist</string>
    <string name="add_to_playlist_done">Done</string>
    <string name="create">Create</string>
    <string name="rename">Rename</string>
    <string name="save">Save</string>
```

- [ ] **Step 3: Add the drawer destination + routes in `MainActivity.kt`**

In `LibraryNavGraph`, extend `drawerCapable`:

```kotlin
    val drawerCapable = currentRoute == "list" || currentRoute == "recentlyDeleted" || currentRoute == "playlists"
```

Add a drawer item (after the All Scores item, before the divider). Add the icon
import `androidx.compose.material.icons.automirrored.filled.QueueMusic`:

```kotlin
                NavigationDrawerItem(
                    icon = { Icon(Icons.AutoMirrored.Filled.QueueMusic, contentDescription = null) },
                    label = { Text(stringResource(R.string.nav_playlists)) },
                    selected = currentRoute == "playlists",
                    onClick = { switchTo("playlists") },
                    modifier = Modifier.padding(horizontal = 12.dp),
                )
```

Add the routes in the inner `NavHost` (next to `"list"`/`"recentlyDeleted"`). Add
`import com.keynumber.folino.ui.library.PlaylistsListScreen` and
`import com.keynumber.folino.ui.library.PlaylistDetailScreen`:

```kotlin
            composable("playlists") {
                PlaylistsListScreen(
                    viewModel = vm,
                    onOpenPlaylist = { id, name ->
                        nav.navigate("playlist/$id/${URLEncoder.encode(name, "UTF-8")}")
                    },
                    onOpenDrawer = openDrawer,
                )
            }
            composable(
                "playlist/{id}/{name}",
                arguments = listOf(
                    navArgument("id") { type = NavType.StringType },
                    navArgument("name") { type = NavType.StringType },
                ),
            ) { entry ->
                val id = entry.arguments?.getString("id") ?: ""
                val name = URLDecoder.decode(entry.arguments?.getString("name") ?: "", "UTF-8")
                PlaylistDetailScreen(
                    viewModel = vm,
                    playlistId = id,
                    playlistName = name,
                    onOpenScore = { row -> nav.navigate("reader/${URLEncoder.encode(row.title, "UTF-8")}") },
                    onBack = { nav.popBackStack() },
                )
            }
```

- [ ] **Step 4: Build** (after the screens in F2–F3 exist this will fully resolve; for now the dep + strings + drawer compile against the new screens added next). Defer the build to Task F2's build step.

- [ ] **Step 5: Commit**

```bash
git add Android/app/build.gradle.kts Android/app/src/main/res/values/strings.xml Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(android-library): reorderable dep, playlists drawer + routes"
```

### Task F2: `PlaylistsListScreen.kt`

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/PlaylistsListScreen.kt`

- [ ] **Step 1: Write the screen**

A Scaffold with hamburger top bar (`onOpenDrawer`), a FAB `+` opening a
create-name `AlertDialog` (calls `viewModel.createPlaylist(name)`), and a
`LazyColumn` over `viewModel.playlists.collectAsStateWithLifecycle()`. Each
`ListItem`: headline = name, supporting = `stringResource(R.string.playlists_member_count, row.memberCount)`,
leading `Icons.AutoMirrored.Filled.QueueMusic`, trailing `MoreVert` overflow with
"Delete playlist" → confirm `AlertDialog` (`viewModel.deletePlaylist(row.id)`).
Tapping the row calls `onOpenPlaylist(row.id, row.name)`. Empty state mirrors
`LibraryScreen.EmptyState`.

```kotlin
package com.keynumber.folino.ui.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.library.PlaylistRowWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlaylistsListScreen(
    viewModel: LibraryAndroidStoreViewModel,
    onOpenPlaylist: (String, String) -> Unit,
    onOpenDrawer: () -> Unit,
) {
    val playlists by viewModel.playlists.collectAsStateWithLifecycle()
    var showCreate by remember { mutableStateOf(false) }
    var pendingDelete by remember { mutableStateOf<PlaylistRowWire?>(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.playlists_title)) },
                navigationIcon = {
                    IconButton(onClick = onOpenDrawer) {
                        Icon(Icons.Filled.Menu, contentDescription = stringResource(R.string.nav_open_menu))
                    }
                },
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = { showCreate = true }) {
                Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.playlists_create))
            }
        },
    ) { padding ->
        if (playlists.isEmpty()) {
            Box(Modifier.padding(padding).fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(stringResource(R.string.playlists_empty_title), style = MaterialTheme.typography.titleMedium)
                    Text(stringResource(R.string.playlists_empty_hint), style = MaterialTheme.typography.bodyMedium)
                }
            }
        } else {
            LazyColumn(Modifier.padding(padding).fillMaxSize()) {
                items(playlists, key = { it.id }) { row ->
                    PlaylistRow(
                        row = row,
                        onClick = { onOpenPlaylist(row.id, row.name) },
                        onRequestDelete = { pendingDelete = row },
                    )
                }
            }
        }
    }

    if (showCreate) {
        NameDialog(
            title = stringResource(R.string.playlists_create),
            confirmLabel = stringResource(R.string.create),
            onConfirm = { name -> viewModel.createPlaylist(name); showCreate = false },
            onDismiss = { showCreate = false },
        )
    }

    pendingDelete?.let { row ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(stringResource(R.string.playlists_delete_confirm_title, row.name)) },
            text = { Text(stringResource(R.string.playlists_delete_confirm_message)) },
            confirmButton = {
                TextButton(onClick = { viewModel.deletePlaylist(row.id); pendingDelete = null }) {
                    Text(stringResource(R.string.playlists_delete))
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PlaylistRow(row: PlaylistRowWire, onClick: () -> Unit, onRequestDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    ListItem(
        headlineContent = { Text(row.name.ifEmpty { "Untitled" }) },
        supportingContent = { Text(stringResource(R.string.playlists_member_count, row.memberCount)) },
        leadingContent = { Icon(Icons.AutoMirrored.Filled.QueueMusic, contentDescription = null) },
        trailingContent = {
            Box {
                IconButton(onClick = { menu = true }) {
                    Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.more))
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.playlists_delete)) },
                        onClick = { menu = false; onRequestDelete() },
                    )
                }
            }
        },
        modifier = Modifier.clickable(onClick = onClick),
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun NameDialog(
    title: String,
    confirmLabel: String,
    initial: String = "",
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                singleLine = true,
                label = { Text(stringResource(R.string.playlists_name_hint)) },
            )
        },
        confirmButton = {
            TextButton(enabled = text.isNotBlank(), onClick = { onConfirm(text) }) { Text(confirmLabel) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}
```

- [ ] **Step 2: Build** (drawer + routes from F1 now resolve `PlaylistsListScreen`; `PlaylistDetailScreen` is added in F3 — temporarily comment its route usage in `MainActivity.kt` if building before F3, or implement F3 before building). Run: `Scripts/android-build-libs.sh` then `Android/gradlew -p Android :app:assembleDebug`.
Expected: compiles once F3 also exists.

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/PlaylistsListScreen.kt
git commit -m "feat(android-library): PlaylistsListScreen"
```

### Task F3: `PlaylistDetailScreen.kt` (drag-to-reorder)

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/PlaylistDetailScreen.kt`

- [ ] **Step 1: Write the screen**

`LaunchedEffect(playlistId) { viewModel.selectPlaylist(playlistId) }`. Observe
`selectedPlaylistItems`. Maintain a local `mutableStateListOf` mirror so drag
feels immediate, syncing from the StateFlow when it changes and committing the
new order via `viewModel.setPlaylistOrder(playlistId, items.map { it.id })` on
drag end. Top bar: back arrow, title = `playlistName`, overflow (Rename →
`NameDialog` → `viewModel.renamePlaylist`; Delete → confirm → `viewModel.deletePlaylist` then `onBack()`).
Reorder via `sh.calvin.reorderable.ReorderableItem` + `rememberReorderableLazyListState`,
with a drag-handle icon (`Icons.Filled.DragHandle`) using `Modifier.draggableHandle()`.
Row tap → `onOpenScore(row)`; trailing overflow "Remove from playlist" →
`viewModel.removeFromPlaylist(row.id, playlistId)`.

```kotlin
package com.keynumber.folino.ui.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.library.ScoreRowWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel
import sh.calvin.reorderable.ReorderableItem
import sh.calvin.reorderable.rememberReorderableLazyListState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlaylistDetailScreen(
    viewModel: LibraryAndroidStoreViewModel,
    playlistId: String,
    playlistName: String,
    onOpenScore: (ScoreRowWire) -> Unit,
    onBack: () -> Unit,
) {
    LaunchedEffect(playlistId) { viewModel.selectPlaylist(playlistId) }
    val items by viewModel.selectedPlaylistItems.collectAsStateWithLifecycle()

    // Local mirror so a drag reorders immediately; re-sync when the store emits.
    val local = remember { mutableStateListOf<ScoreRowWire>() }
    LaunchedEffect(items) {
        if (local.map { it.id } != items.map { it.id }) {
            local.clear(); local.addAll(items)
        }
    }

    var showRename by remember { mutableStateOf(false) }
    var showDelete by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }

    val listState = rememberLazyListState()
    val reorderState = rememberReorderableLazyListState(listState) { from, to ->
        local.add(to.index, local.removeAt(from.index))
        viewModel.setPlaylistOrder(playlistId, local.map { it.id })
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(playlistName) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.cancel))
                    }
                },
                actions = {
                    Box {
                        IconButton(onClick = { menu = true }) {
                            Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.more))
                        }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.playlists_rename)) },
                                onClick = { menu = false; showRename = true },
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.playlists_delete)) },
                                onClick = { menu = false; showDelete = true },
                            )
                        }
                    }
                },
            )
        },
    ) { padding ->
        if (local.isEmpty()) {
            Box(Modifier.padding(padding).fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(stringResource(R.string.playlists_empty_hint), style = MaterialTheme.typography.bodyMedium)
            }
        } else {
            LazyColumn(state = listState, modifier = Modifier.padding(padding).fillMaxSize()) {
                items(local, key = { it.id }) { row ->
                    ReorderableItem(reorderState, key = row.id) {
                        var rowMenu by remember { mutableStateOf(false) }
                        val title = row.title.ifEmpty { "Untitled" }
                        val headline = if (row.subtitle.isEmpty()) title else "$title ${row.subtitle}"
                        ListItem(
                            headlineContent = { Text(headline) },
                            supportingContent = { if (row.composer.isNotEmpty()) Text(row.composer) },
                            leadingContent = {
                                IconButton(modifier = Modifier.draggableHandle(), onClick = {}) {
                                    Icon(
                                        Icons.Filled.DragHandle,
                                        contentDescription = stringResource(R.string.playlist_reorder_handle),
                                    )
                                }
                            },
                            trailingContent = {
                                Box {
                                    IconButton(onClick = { rowMenu = true }) {
                                        Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.more))
                                    }
                                    DropdownMenu(expanded = rowMenu, onDismissRequest = { rowMenu = false }) {
                                        DropdownMenuItem(
                                            text = { Text(stringResource(R.string.playlist_remove_from)) },
                                            onClick = {
                                                rowMenu = false
                                                viewModel.removeFromPlaylist(row.id, playlistId)
                                            },
                                        )
                                    }
                                }
                            },
                            modifier = Modifier.clickable { onOpenScore(row) },
                        )
                    }
                }
            }
        }
    }

    if (showRename) {
        NameDialog(
            title = stringResource(R.string.playlists_rename),
            confirmLabel = stringResource(R.string.rename),
            initial = playlistName,
            onConfirm = { name -> viewModel.renamePlaylist(playlistId, name); showRename = false },
            onDismiss = { showRename = false },
        )
    }
    if (showDelete) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showDelete = false },
            title = { Text(stringResource(R.string.playlists_delete_confirm_title, playlistName)) },
            text = { Text(stringResource(R.string.playlists_delete_confirm_message)) },
            confirmButton = {
                TextButton(onClick = { viewModel.deletePlaylist(playlistId); showDelete = false; onBack() }) {
                    Text(stringResource(R.string.playlists_delete))
                }
            },
            dismissButton = { TextButton(onClick = { showDelete = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}
```

> `Modifier.draggableHandle()` is an extension provided inside `ReorderableItem`'s
> scope by `sh.calvin.reorderable`. If the installed library version exposes a
> different handle API, adapt to that version's documented handle modifier.

- [ ] **Step 2: Build**

Run: `Scripts/android-build-libs.sh` then `Android/gradlew -p Android :app:assembleDebug`
Expected: compiles (F1 routes + F2 + F3 all resolve).

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/PlaylistDetailScreen.kt
git commit -m "feat(android-library): PlaylistDetailScreen with drag-to-reorder"
```

### Task F4: `AddToPlaylistSheet.kt`

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/AddToPlaylistSheet.kt`

- [ ] **Step 1: Write the sheet**

A `ModalBottomSheet` observing `viewModel.addSheetPlaylists`. A `bulk` flag
switches between single (checkbox toggle) and bulk (tap-to-add) behavior. Always
offers "New playlist" at the top, opening `NameDialog`.

```kotlin
package com.keynumber.folino.ui.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddToPlaylistSheet(
    viewModel: LibraryAndroidStoreViewModel,
    /** Non-null = single-score (checkbox toggle); null = bulk (tap-to-add). */
    scoreId: String?,
    bulkScoreIds: List<String>,
    onDismiss: () -> Unit,
) {
    val picks by viewModel.addSheetPlaylists.collectAsStateWithLifecycle()
    var showCreate by remember { mutableStateOf(false) }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        ListItem(
            headlineContent = { Text(stringResource(R.string.playlists_create)) },
            leadingContent = { Icon(Icons.Filled.Add, contentDescription = null) },
            modifier = Modifier.clickable { showCreate = true },
        )
        LazyColumn(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
            items(picks, key = { it.id }) { pick ->
                if (scoreId != null) {
                    ListItem(
                        headlineContent = { Text(pick.name) },
                        trailingContent = { Checkbox(checked = pick.contains, onCheckedChange = null) },
                        modifier = Modifier.clickable {
                            if (pick.contains) {
                                viewModel.removeFromPlaylist(scoreId, pick.id)
                            } else {
                                viewModel.addToPlaylist(scoreId, pick.id)
                            }
                        },
                    )
                } else {
                    ListItem(
                        headlineContent = { Text(pick.name) },
                        modifier = Modifier.clickable {
                            viewModel.bulkAddToPlaylist(pick.id, bulkScoreIds)
                            onDismiss()
                        },
                    )
                }
            }
        }
    }

    if (showCreate) {
        NameDialog(
            title = stringResource(R.string.playlists_create),
            confirmLabel = stringResource(R.string.create),
            onConfirm = { name ->
                val ids = if (scoreId != null) listOf(scoreId) else bulkScoreIds
                viewModel.createPlaylistWithScores(name, ids)
                showCreate = false
                onDismiss()
            },
            onDismiss = { showCreate = false },
        )
    }
}
```

- [ ] **Step 2: Build**

Run: `Android/gradlew -p Android :app:assembleDebug`
Expected: compiles.

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/AddToPlaylistSheet.kt
git commit -m "feat(android-library): AddToPlaylistSheet (single + bulk)"
```

### Task F5: All Scores — row overflow add + bulk CAB selection

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt`

- [ ] **Step 1: Add selection-mode state + CAB top bar**

Mirror `RecentlyDeletedScreen`'s selection pattern: `selectionMode` + `selectedIds`
(`mutableStateListOf<String>()`), `combinedClickable` on rows (tap = open or toggle,
long-press = enter selection + toggle). When `selectionMode`, the `TopAppBar` shows
the count, a Close icon (exit), and actions: "Add to playlist" (opens the bulk
`AddToPlaylistSheet` after `viewModel.beginBulkAddToPlaylist()`), and "Delete"
(`viewModel.deleteMany(selectedIds.toList())` + exit). When not in selection mode,
keep the existing hamburger top bar + FAB import.

- [ ] **Step 2: Add per-row overflow "Add to playlist" (non-selection mode)**

Give `ScoreRow` a trailing `MoreVert` overflow (only when not in selection mode)
with "Add to playlist", which sets a `singleAddTarget = row.id` state, calls
`viewModel.beginAddToPlaylist(row.id)`, and shows the single `AddToPlaylistSheet`.
Keep swipe-to-delete + Undo for the non-selection state.

Concrete additions (showing the changed `LibraryScreen` body essentials):

```kotlin
    var selectionMode by remember { mutableStateOf(false) }
    val selectedIds = remember { mutableStateListOf<String>() }
    var singleAddTarget by remember { mutableStateOf<String?>(null) }
    var showBulkAddSheet by remember { mutableStateOf(false) }

    fun exitSelection() { selectionMode = false; selectedIds.clear() }
    fun toggle(id: String) {
        if (selectedIds.contains(id)) selectedIds.remove(id) else selectedIds.add(id)
        if (selectedIds.isEmpty()) selectionMode = false
    }
```

Selection-mode top bar (replaces the plain `TopAppBar` when `selectionMode`):

```kotlin
            if (selectionMode) {
                TopAppBar(
                    title = { Text(selectedIds.size.toString()) },
                    navigationIcon = {
                        IconButton(onClick = { exitSelection() }) {
                            Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.cancel))
                        }
                    },
                    actions = {
                        IconButton(
                            enabled = selectedIds.isNotEmpty(),
                            onClick = { viewModel.beginBulkAddToPlaylist(); showBulkAddSheet = true },
                        ) {
                            Icon(
                                Icons.AutoMirrored.Filled.PlaylistAdd,
                                contentDescription = stringResource(R.string.add_to_playlist),
                            )
                        }
                        IconButton(
                            enabled = selectedIds.isNotEmpty(),
                            onClick = { viewModel.deleteMany(selectedIds.toList()); exitSelection() },
                        ) {
                            Icon(Icons.Filled.Delete, contentDescription = stringResource(R.string.library_delete))
                        }
                    },
                )
            } else {
                // existing hamburger TopAppBar
            }
```

Rows use `combinedClickable` (import `androidx.compose.foundation.combinedClickable`
and `androidx.compose.foundation.ExperimentalFoundationApi`):

```kotlin
        onClick = { if (selectionMode) toggle(row.id) else onOpenScore(row) },
        onLongClick = { if (!selectionMode) selectionMode = true; toggle(row.id) },
```

`ScoreRow` gains a leading selection check (when `selectionMode`, like
`TrashRow`) and a trailing `MoreVert` overflow (when not in selection mode) with
one item "Add to playlist":

```kotlin
                onClick = {
                    singleAddTarget = row.id
                    viewModel.beginAddToPlaylist(row.id)
                },
```

Sheets at the end of the composable:

```kotlin
    singleAddTarget?.let { id ->
        AddToPlaylistSheet(
            viewModel = viewModel,
            scoreId = id,
            bulkScoreIds = emptyList(),
            onDismiss = { singleAddTarget = null },
        )
    }
    if (showBulkAddSheet) {
        AddToPlaylistSheet(
            viewModel = viewModel,
            scoreId = null,
            bulkScoreIds = selectedIds.toList(),
            onDismiss = { showBulkAddSheet = false; exitSelection() },
        )
    }
```

Add string `<string name="library_delete">Delete</string>` to `strings.xml` if not
present, and the icon imports `androidx.compose.material.icons.filled.Close`,
`androidx.compose.material.icons.automirrored.filled.PlaylistAdd`,
`androidx.compose.material.icons.filled.CheckCircle`,
`androidx.compose.material.icons.outlined.RadioButtonUnchecked`.

- [ ] **Step 3: Build**

Run: `Android/gradlew -p Android :app:assembleDebug`
Expected: compiles.

- [ ] **Step 4: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt Android/app/src/main/res/values/strings.xml
git commit -m "feat(android-library): All Scores row add-to-playlist + bulk CAB"
```

---

## Phase G — Build + device verification

### Task G1: Cross-compile, install, launch, hand off for gesture verification

**Files:** none (build + device).

- [ ] **Step 1: Cross-compile the Swift libraries (codegen → compile → JNI_OnLoad)**

Run: `Scripts/android-build-libs.sh`
Notes: this regenerates the wirelet observable codegen (`.wirelet-observable-jni.json`
sidecar) and cross-compiles. If `swift` toolchain errors occur, prefix with the
release toolchain path: `PATH="/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH"`.
On a fresh worktree, this also generates the Settings jextract bindings needed by
`:app`.
Expected: three `.so` build, generated Kotlin wire classes (`PlaylistRecordWire`,
`PlaylistItemWire`, `PlaylistRowWire`, `PlaylistPickWire`) and the regenerated
`LibraryAndroidStoreViewModel` (new StateFlows + methods) present.

- [ ] **Step 2: Install on the Pixel 8a**

Run: `Android/gradlew -p Android :app:installDebug`
Expected: BUILD SUCCESSFUL, app installed.

- [ ] **Step 3: Launch**

Run: `adb shell am start -n com.keynumber.folino/.MainActivity`
Expected: app launches, no crash; `adb logcat` shows the three `.so` loaded and
JNI methods registered (no `UnsatisfiedLinkError`).

- [ ] **Step 4: Hand off to the user for gesture verification**

Ask the user to verify on-device (these are gestures/flows previews and the host
tests can't cover):
- Drawer → Playlists; create a playlist via FAB; it appears name-sorted with "0 scores".
- All Scores: row overflow → Add to playlist → toggle membership; count updates.
- All Scores: long-press → selection mode; select several → Add to playlist (bulk) and Delete.
- Open a playlist; drag-handle reorder; reopen to confirm the order persisted.
- Remove a score from the playlist; rename the playlist; delete the playlist.
- Kill + relaunch the app: playlists, membership, and order survive (Room persisted,
  migration succeeded with existing imported scores intact).

- [ ] **Step 5: (after the user confirms) Final no-op commit / branch wrap**

Nothing to commit if all prior tasks committed. Proceed to the
finishing-a-development-branch skill to decide merge/PR.

---

## Self-review notes (author)

- **Spec coverage:** join-table persistence (E1), shared Domain logic (A1/A2) +
  iOS refactor (B1), bridge-constraint store surface (D2–D6), wire types (C1),
  Compose drawer/list/detail/sheet/All-Scores (F1–F5), device verification (G1).
  Bulk Delete (CAB) → `deleteMany` (D6, F5). All spec sections map to a task.
- **Reorder hidden-member safety:** `setPlaylistOrder` re-appends members not in
  the submitted live order (soft-deleted) so they survive reordering (D5).
- **Generated vs hand-written Kotlin:** wire data classes are codegen output;
  only Room entities/DAO/`RoomLibraryStore` are hand-written (E1).
- **Version pin:** swift-wirelet stays at v0.3.2; no `project.yml` change (the
  reorderable dep is Gradle-only).
</content>

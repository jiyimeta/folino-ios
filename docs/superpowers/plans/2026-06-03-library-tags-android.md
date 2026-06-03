# Library Tags — Android Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the Library *tag* feature to Android at iOS content-parity (tags list, tag detail, single-score tag editing, bulk tag assignment) via the existing swift-wirelet + Kotlin/Room/Compose pattern.

**Architecture:** All tag *logic* lives in the Swift `LibraryAndroidStore` (`@WireletObservable`); Kotlin/Room is a rule-free backend implementing the `@WireletProvided` `LibraryStore` protocol. Tag membership is a join table (`tags` + `tag_items`), mirroring the Playlists port (no `position` — tags are unordered; bulk-add is union). No color picker (iOS has none); creation defaults `colorHex` to `#5856D6`. Tags are reached via a drawer destination only (no Library-root section).

**Tech Stack:** Swift 6.3, swift-wirelet (`@WireFormat` / `@WireletObservable` / `@WireletProvided`), Kotlin + Jetpack Compose (Material3), Room. Spec: `docs/superpowers/specs/2026-06-03-library-tags-android-design.md`.

**Conventions used by this plan:**
- Swift host tests run on macOS with `FOLINO_ANDROID=1` (the JNI target carries no SwiftLint plugin, so it builds on the host). Use `xcrun swift` — the bare `swift`/`swiftly` shim is broken on this machine (see memory `project_android_build_toolchain`). Command (verified green as baseline — 20 tests):
  `FOLINO_ANDROID=1 xcrun swift test --package-path Packages/Features/Library --filter LibraryAndroidStoreTests`
- The JNI `.so` rebuild + wirelet codegen: `Scripts/android-build-library-libs.sh`.
- App build/install: `Android/gradlew -p Android :app:installDebug` (toolchain caveats: see memory `project_android_build_toolchain`).
- Per CLAUDE.md, each Bash call is a single command — no `&&` chaining. Env-prefix form (`FOLINO_ANDROID=1 swift test …`) is one command and is fine.

---

## File Structure

**Swift (new), `Packages/Features/Library/Sources/FolinoLibraryJNI/`:**
- `TagRowWire.swift` — tags-list display projection (`id, name, colorHex, memberCount`).
- `TagRecordWire.swift` — persistence projection (`id, name, colorHex`).
- `TagItemWire.swift` — membership row (`tagId, scoreItemId`).
- `TagPickWire.swift` — edit-tags sheet row (`id, name, contains`).

**Swift (modified):**
- `LibraryStore.swift` — add 5 tag backend methods to the `@WireletProvided` protocol.
- `LibraryAndroidStore.swift` — add `tags` / `selectedTagItems` / `editSheetTags` observables and the tag `@WireletExpose` methods + private helpers; call `reloadTags()` from `init` and from the existing delete/restore/purge paths.
- `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift` — extend `FakeLibraryStore`; add tag tests.

**Kotlin (modified), `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/`:**
- `RoomLibraryStore.kt` — `TagEntity`, `TagItemEntity`, `TagDao`, DB version `2 → 3` + `MIGRATION_2_3`, and `LibraryStore` tag-method impls.

**Compose (new), `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/`:**
- `TagsListScreen.kt`
- `TagDetailScreen.kt`
- `EditTagsSheet.kt`

**Compose (modified):**
- `LibraryScreen.kt` — row overflow "Edit tags"; selection-CAB "Tag" action.
- `MainActivity.kt` — drawer "Tags" item; routes `tags` and `tag/{id}/{name}`.
- `Android/app/src/main/res/values/strings.xml` — tag strings.

---

## Task 1: Swift wire types

**Files:**
- Create: `Packages/Features/Library/Sources/FolinoLibraryJNI/TagRowWire.swift`
- Create: `Packages/Features/Library/Sources/FolinoLibraryJNI/TagRecordWire.swift`
- Create: `Packages/Features/Library/Sources/FolinoLibraryJNI/TagItemWire.swift`
- Create: `Packages/Features/Library/Sources/FolinoLibraryJNI/TagPickWire.swift`

- [ ] **Step 1: Create the four wire types**

`TagRowWire.swift`:

```swift
import Wirelet

/// Display projection of a tag row (Tags list): name, color, live member count.
@WireFormat
public struct TagRowWire: Equatable, Sendable {
    public var id: String          // TagID UUID string
    public var name: String
    public var colorHex: String    // "#RRGGBB"
    public var memberCount: Int32  // live (non-deleted) scores carrying this tag

    public init(id: String, name: String, colorHex: String, memberCount: Int32) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.memberCount = memberCount
    }
}
```

`TagRecordWire.swift`:

```swift
import Wirelet

/// Persistence projection of a tag (mirrors Domain `Tag`).
@WireFormat
public struct TagRecordWire: Equatable, Sendable {
    public var id: String
    public var name: String
    public var colorHex: String

    public init(id: String, name: String, colorHex: String) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}
```

`TagItemWire.swift`:

```swift
import Wirelet

/// One tag-membership row (the score `scoreItemId` carries tag `tagId`).
@WireFormat
public struct TagItemWire: Equatable, Sendable {
    public var tagId: String
    public var scoreItemId: String

    public init(tagId: String, scoreItemId: String) {
        self.tagId = tagId
        self.scoreItemId = scoreItemId
    }
}
```

`TagPickWire.swift`:

```swift
import Wirelet

/// A tag option in the Edit-tags sheet. `contains` is the focused score's
/// current membership (always false for the bulk sheet).
@WireFormat
public struct TagPickWire: Equatable, Sendable {
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

- [ ] **Step 2: Verify it compiles**

Run: `FOLINO_ANDROID=1 xcrun swift build --package-path Packages/Features/Library --product FolinoLibraryJNI`
Expected: build succeeds (the new types compile; `@WireFormat` macro expands).

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/Tag*.swift
git commit -m "feat(android-library): add Tag wire types (Row/Record/Item/Pick)"
```

---

## Task 2: Extend `LibraryStore` protocol + test fake (scaffolding)

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift`
- Modify: `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift:36-65` (the `FakeLibraryStore` playlist block — add a tag block right after it)

- [ ] **Step 1: Add the tag methods to the `@WireletProvided` protocol**

Append these inside the `LibraryStore` protocol body in `LibraryStore.swift`, after `func deletePlaylist(id: String)`:

```swift
    // MARK: - Tags

    /// Every persisted tag row.
    func loadTags() -> [TagRecordWire]

    /// Insert or replace a tag row by `record.id`.
    func upsertTag(_ record: TagRecordWire)

    /// Remove a tag row AND all of its membership rows (cascade).
    func deleteTag(id: String)

    /// Every tag-membership row.
    func loadTagItems() -> [TagItemWire]

    /// Replace ALL membership rows for `tagId` with `items` (drop + reinsert).
    func replaceTagItems(_ tagId: String, _ items: [TagItemWire])
```

- [ ] **Step 2: Implement the new methods in `FakeLibraryStore`**

Add this block to `FakeLibraryStore` in the test file (e.g. after the playlist `deletePlaylist(id:)` impl, before the closing brace at line 66):

```swift
    var tagRecords: [TagRecordWire] = []
    var tagItems: [TagItemWire] = []

    func loadTags() -> [TagRecordWire] {
        tagRecords
    }

    func upsertTag(_ record: TagRecordWire) {
        if let idx = tagRecords.firstIndex(where: { $0.id == record.id }) {
            tagRecords[idx] = record
        } else {
            tagRecords.append(record)
        }
    }

    func deleteTag(id: String) {
        tagRecords.removeAll { $0.id == id }
        tagItems.removeAll { $0.tagId == id }
    }

    func loadTagItems() -> [TagItemWire] {
        tagItems
    }

    func replaceTagItems(_ tagId: String, _ items: [TagItemWire]) {
        tagItems.removeAll { $0.tagId == tagId }
        tagItems.append(contentsOf: items)
    }
```

- [ ] **Step 3: Verify the test target still compiles (existing tests pass)**

Run: `FOLINO_ANDROID=1 xcrun swift test --package-path Packages/Features/Library --filter LibraryAndroidStoreTests`
Expected: PASS — all existing tests still green (the protocol grew but the store doesn't call the new methods yet; the fake satisfies the protocol so the target compiles).

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift
git commit -m "feat(android-library): add tag methods to LibraryStore protocol + test fake"
```

---

## Task 3: Tag CRUD in `LibraryAndroidStore` (create/rename/delete + member count)

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`
- Test: `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `LibraryAndroidStoreTests` (before the closing brace at line 401):

```swift
    @Test func `createTag adds a name-sorted row; blank ignored; default color`() {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)

        store.createTag("Recital")
        store.createTag("Daily")
        store.createTag("   ") // blank ignored

        #expect(store.tags.map(\.name) == ["Daily", "Recital"]) // localizedStandardCompare
        #expect(store.tags.allSatisfy { $0.memberCount == 0 })
        #expect(store.tags.allSatisfy { $0.colorHex == "#5856D6" })
        #expect(backend.tagRecords.count == 2)
    }

    @Test func `renameTag updates name keeping color; blank ignored`() throws {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)
        store.createTag("Old")
        let id = try #require(store.tags.first).id

        store.renameTag(id, "New")
        #expect(store.tags.map(\.name) == ["New"])
        #expect(store.tags.first?.colorHex == "#5856D6") // color preserved

        store.renameTag(id, "  ")
        #expect(store.tags.map(\.name) == ["New"]) // unchanged
    }

    @Test func `deleteTag removes the row and its membership`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(id: a, title: "A", subtitle: "", composer: "", localFileName: "\(a).mscz", deletedAt: 0),
        ]
        let store = LibraryAndroidStore(store: backend)
        store.createTag("P")
        let id = try #require(store.tags.first).id
        store.setTagAssigned(a, id, true)
        #expect(store.tags.first?.memberCount == 1)

        store.deleteTag(id)
        #expect(store.tags.isEmpty)
        #expect(backend.tagRecords.isEmpty)
        #expect(backend.tagItems.isEmpty) // membership cascaded
    }
```

> Note: `deleteTag` test uses `setTagAssigned`, implemented in Task 4. If executing strictly task-by-task, this test will not compile until Task 4 lands. Either implement Task 4's `setTagAssigned` signature stub now, or move the `deleteTag` assertion about membership to Task 4. Simplest: add the `setTagAssigned` method in Step 2 of THIS task (its body is small and self-contained — see code below) so all three CRUD tests compile and pass here.

- [ ] **Step 2: Add observables + helpers + CRUD methods (incl. `setTagAssigned`)**

In `LibraryAndroidStore`, add observable properties after the playlist ones (`addSheetPlaylists`, line 31):

```swift
    public var tags: [TagRowWire] = []
    public var selectedTagItems: [ScoreRowWire] = []
    public var editSheetTags: [TagPickWire] = []
```

Add private state after `addSheetScoreID` (line 34):

```swift
    @ObservationIgnored private var selectedTagID: String?
    @ObservationIgnored private var editSheetScoreID: String?
```

In `init` (after `reloadPlaylists()`, line 39), add:

```swift
        reloadTags()
```

Add a new `// MARK: - Tags` section at the end of the type (before the final closing brace) with the helpers and CRUD methods:

```swift
    // MARK: - Tags

    /// tagId -> set of member scoreItemId strings, from the backend's join rows.
    private func tagMembership() -> [String: Set<String>] {
        var membership: [String: Set<String>] = [:]
        for item in store.loadTagItems() {
            membership[item.tagId, default: []].insert(item.scoreItemId)
        }
        return membership
    }

    /// Set of live (`deletedAt <= 0`) score id strings, for member-count math.
    private func liveScoreIDStrings(_ records: [ScoreRecordWire]) -> Set<String> {
        Set(records.filter { $0.deletedAt <= 0 }.map(\.id))
    }

    /// Recompute every tag-derived observable from one backend snapshot.
    private func reloadTags() {
        let records = store.loadAll()
        let live = liveScoreIDStrings(records)
        let membership = tagMembership()
        let tagRecords = store.loadTags()
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        tags = tagRecords.map { rec in
            let members = membership[rec.id] ?? []
            return TagRowWire(
                id: rec.id,
                name: rec.name,
                colorHex: rec.colorHex,
                memberCount: Int32(members.intersection(live).count),
            )
        }
        recomputeSelectedTagItems(records: records, membership: membership)
        refreshEditSheet(tagRecords: tagRecords, membership: membership)
    }

    /// Live scores carrying `selectedTagID`, sorted by title (tags are unordered).
    private func recomputeSelectedTagItems(records: [ScoreRecordWire], membership: [String: Set<String>]) {
        guard let sel = selectedTagID else {
            selectedTagItems = []
            return
        }
        let members = membership[sel] ?? []
        selectedTagItems = records
            .filter { $0.deletedAt <= 0 && members.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map(Self.row)
    }

    /// Edit-tags sheet rows: every tag, `contains` reflecting the focused score
    /// (nil focus = bulk sheet, all false).
    private func refreshEditSheet(tagRecords: [TagRecordWire], membership: [String: Set<String>]) {
        let focus = editSheetScoreID
        editSheetTags = tagRecords.map { rec in
            TagPickWire(
                id: rec.id,
                name: rec.name,
                contains: focus.map { (membership[rec.id] ?? []).contains($0) } ?? false,
            )
        }
    }

    @WireletExpose
    public func createTag(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // iOS parity: default color is purple; no picker.
        store.upsertTag(TagRecordWire(id: UUID().uuidString, name: trimmed, colorHex: "#5856D6"))
        reloadTags()
    }

    @WireletExpose
    public func renameTag(_ id: String, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let existing = store.loadTags().first(where: { $0.id == id }) else { return }
        store.upsertTag(TagRecordWire(id: id, name: trimmed, colorHex: existing.colorHex))
        reloadTags()
    }

    @WireletExpose
    public func deleteTag(_ id: String) {
        store.deleteTag(id: id)
        if selectedTagID == id { selectedTagID = nil }
        reloadTags()
    }

    /// Toggle one score's membership in one tag (single-score edit sheet).
    @WireletExpose
    public func setTagAssigned(_ scoreId: String, _ tagId: String, _ assigned: Bool) {
        var members = tagMembership()[tagId] ?? []
        if assigned { members.insert(scoreId) } else { members.remove(scoreId) }
        store.replaceTagItems(tagId, members.map { TagItemWire(tagId: tagId, scoreItemId: $0) })
        reloadTags()
    }
```

- [ ] **Step 3: Run the tests**

Run: `FOLINO_ANDROID=1 xcrun swift test --package-path Packages/Features/Library --filter LibraryAndroidStoreTests`
Expected: PASS (the three new CRUD tests + all existing tests).

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift
git commit -m "feat(android-library): tag CRUD + membership toggle in LibraryAndroidStore"
```

---

## Task 4: Bulk union-add + member-count-excludes-deleted

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`
- Test: `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `LibraryAndroidStoreTests`:

```swift
    @Test func `bulkAddTag unions scores into a tag without duplicates`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let b = "00000000-0000-0000-0000-0000000000b2"
        let c = "00000000-0000-0000-0000-0000000000c3"
        let backend = FakeLibraryStore()
        backend.records = [a, b, c].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createTag("T")
        let t = try #require(store.tags.first).id

        store.setTagAssigned(a, t, true)
        store.bulkAddTag(t, [a, b, c]) // a already present → not duplicated
        #expect(store.tags.first?.memberCount == 3)
        #expect(backend.tagItems.filter { $0.tagId == t }.count == 3)
    }

    @Test func `bulkAddTag with empty inputs is a no-op`() throws {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)
        store.createTag("T")
        let t = try #require(store.tags.first).id

        store.bulkAddTag(t, [])
        #expect(store.tags.first?.memberCount == 0)
        #expect(backend.tagItems.isEmpty)
    }

    @Test func `tag member count excludes soft-deleted scores`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let b = "00000000-0000-0000-0000-0000000000b2"
        let backend = FakeLibraryStore()
        backend.records = [a, b].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createTag("T")
        let t = try #require(store.tags.first).id
        store.bulkAddTag(t, [a, b])
        #expect(store.tags.first?.memberCount == 2)

        store.delete(a) // soft-delete a member
        #expect(store.tags.first?.memberCount == 1) // excluded from live count
    }
```

> The `tag member count excludes soft-deleted scores` test asserts that `delete(_:)` refreshes tag counts. That requires Task 6's wiring of `reloadTags()` into `setDeletedAt`. To keep this task self-contained, implement that one-line wiring as part of Step 2 here (it is also re-listed in Task 6 for completeness — applying it once is enough; the second application is a no-op).

- [ ] **Step 2: Add `bulkAddTag` and wire `reloadTags()` into `setDeletedAt`**

Add to the `// MARK: - Tags` section:

```swift
    /// Union-add a set of scores into one tag (bulk CAB). Never removes existing
    /// members; mirrors iOS `bulkAddTags` union semantics.
    @WireletExpose
    public func bulkAddTag(_ tagId: String, _ scoreIds: [String]) {
        guard !scoreIds.isEmpty else { return }
        var members = tagMembership()[tagId] ?? []
        members.formUnion(scoreIds)
        store.replaceTagItems(tagId, members.map { TagItemWire(tagId: tagId, scoreItemId: $0) })
        reloadTags()
    }
```

In the existing private `setDeletedAt(_:_:)` method (currently lines 123-130), add `reloadTags()` after `reloadPlaylists()`:

```swift
    private func setDeletedAt(_ id: String, _ stamp: Double) {
        var all = store.loadAll()
        guard let idx = all.firstIndex(where: { $0.id == id }) else { return }
        all[idx].deletedAt = stamp
        store.upsert(all[idx])
        reload(using: all)
        reloadPlaylists()
        reloadTags()
    }
```

- [ ] **Step 3: Run the tests**

Run: `FOLINO_ANDROID=1 xcrun swift test --package-path Packages/Features/Library --filter LibraryAndroidStoreTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift
git commit -m "feat(android-library): bulk union-add tags + live member count on soft-delete"
```

---

## Task 5: Tag detail selection + edit-sheet focus

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`
- Test: `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `LibraryAndroidStoreTests`:

```swift
    @Test func `selectTag exposes its live members sorted by title`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let b = "00000000-0000-0000-0000-0000000000b2"
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(id: a, title: "Zebra", subtitle: "", composer: "", localFileName: "\(a).mscz", deletedAt: 0),
            ScoreRecordWire(id: b, title: "Apple", subtitle: "", composer: "", localFileName: "\(b).mscz", deletedAt: 0),
        ]
        let store = LibraryAndroidStore(store: backend)
        store.createTag("T")
        let t = try #require(store.tags.first).id
        store.bulkAddTag(t, [a, b])

        store.selectTag(t)
        // title-sorted: "Apple" (b) then "Zebra" (a)
        #expect(store.selectedTagItems.map(\.id) == [b, a])
    }

    @Test func `beginEditTags marks tags containing the focused score`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let b = "00000000-0000-0000-0000-0000000000b2"
        let backend = FakeLibraryStore()
        backend.records = [a, b].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createTag("T")
        let t = try #require(store.tags.first).id
        store.setTagAssigned(a, t, true)

        store.beginEditTags(a)
        #expect(store.editSheetTags.map(\.contains) == [true])
        store.beginEditTags(b)
        #expect(store.editSheetTags.map(\.contains) == [false])

        store.beginBulkEditTags()
        #expect(store.editSheetTags.map(\.contains) == [false]) // bulk: nothing pre-checked
    }
```

- [ ] **Step 2: Add `selectTag`, `beginEditTags`, `beginBulkEditTags`**

Add to the `// MARK: - Tags` section:

```swift
    @WireletExpose
    public func selectTag(_ id: String) {
        selectedTagID = id
        reloadTags()
    }

    @WireletExpose
    public func beginEditTags(_ scoreId: String) {
        editSheetScoreID = scoreId
        reloadTags()
    }

    @WireletExpose
    public func beginBulkEditTags() {
        editSheetScoreID = nil
        reloadTags()
    }
```

- [ ] **Step 3: Run the tests**

Run: `FOLINO_ANDROID=1 xcrun swift test --package-path Packages/Features/Library --filter LibraryAndroidStoreTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift
git commit -m "feat(android-library): tag selection + edit-sheet focus in LibraryAndroidStore"
```

---

## Task 6: Keep tag counts fresh across remaining delete/restore/purge paths

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`
- Test: `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift`

`setDeletedAt` was wired in Task 4. The remaining methods that mutate live/deleted state and currently call `reloadPlaylists()` must also call `reloadTags()`: `permanentlyDelete`, `restoreMany`, `permanentlyDeleteMany`, and `deleteMany`. (`importScore` adds a brand-new untagged score — no tag membership can reference it yet — so it does not need `reloadTags()`; `restore` and `delete` route through `setDeletedAt`.)

- [ ] **Step 1: Write the failing test**

Add to `LibraryAndroidStoreTests`:

```swift
    @Test func `bulk soft-delete updates tag member count`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let b = "00000000-0000-0000-0000-0000000000b2"
        let c = "00000000-0000-0000-0000-0000000000c3"
        let backend = FakeLibraryStore()
        backend.records = [a, b, c].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createTag("T")
        let t = try #require(store.tags.first).id
        store.bulkAddTag(t, [a, b, c])
        #expect(store.tags.first?.memberCount == 3)

        store.deleteMany([a, b])
        #expect(store.tags.first?.memberCount == 1) // only c is live

        store.restoreMany([a, b])
        #expect(store.tags.first?.memberCount == 3) // back to live
    }

    @Test func `permanent purge keeps tag rows but drops purged members from count`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(id: a, title: "A", subtitle: "", composer: "", localFileName: "\(a).mscz", deletedAt: 10),
        ]
        let store = LibraryAndroidStore(store: backend)
        store.createTag("T")
        let t = try #require(store.tags.first).id
        store.bulkAddTag(t, [a]) // a is soft-deleted, so count is already 0

        store.permanentlyDelete(a)
        #expect(store.tags.map(\.name) == ["T"]) // tag row survives
        #expect(store.tags.first?.memberCount == 0)
    }
```

- [ ] **Step 2: Add `reloadTags()` to the four remaining methods**

In each method below, add `reloadTags()` immediately after its existing `reloadPlaylists()` call:

- `permanentlyDelete(_:)` (currently ~line 91)
- `restoreMany(_:)` (currently ~line 105)
- `permanentlyDeleteMany(_:)` (currently ~line 121)
- `deleteMany(_:)` (currently ~line 179)

Example (`deleteMany`):

```swift
        reload(using: all)
        reloadPlaylists()
        reloadTags()
    }
```

- [ ] **Step 3: Run the tests**

Run: `FOLINO_ANDROID=1 xcrun swift test --package-path Packages/Features/Library --filter LibraryAndroidStoreTests`
Expected: PASS (all tag + playlist + score tests green).

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift
git commit -m "feat(android-library): refresh tag counts on bulk delete/restore/purge"
```

---

## Task 7: Rebuild the JNI library + regenerate wirelet codegen

**Files:**
- Run: `Scripts/android-build-library-libs.sh` (no source edits)

- [ ] **Step 1: Cross-compile the JNI `.so` and regenerate bindings**

Run: `Scripts/android-build-library-libs.sh`
Expected: builds `FolinoLibraryJNI` for `aarch64-unknown-linux-android28` (and x86_64), stages `libFolinoLibraryJNI.so` + Swift runtime into `Android/FolinoLibraryAndroid/src/main/jniLibs/{arm64-v8a,x86_64}/`. If the toolchain/`swiftly` shim errors, follow memory `project_android_build_toolchain` (use the `/Library` Swift 6.3.2 toolchain on `PATH`).

- [ ] **Step 2: Confirm the new exposed methods + observables are in the generated ViewModel**

Run: `XcodeGrep`/`rg` for the generated names:
`rg -l "bulkAddTag|setTagAssigned|selectTag|beginEditTags|fun .*Tags" Android/FolinoLibraryAndroid/build/generated`
Expected: the generated `LibraryAndroidStoreViewModel.kt` contains StateFlows `tags`, `selectedTagItems`, `editSheetTags` and `external` methods `createTag`, `renameTag`, `deleteTag`, `selectTag`, `beginEditTags`, `beginBulkEditTags`, `setTagAssigned`, `bulkAddTag`; codecs `TagRowWireCodec`, `TagRecordWireCodec`, `TagItemWireCodec`, `TagPickWireCodec` exist; and the generated `LibraryStore` interface gained the five tag methods.

If codegen is missing any method, re-check the `@WireletExpose` annotations in `LibraryAndroidStore.swift` and re-run.

- [ ] **Step 3: Commit any tracked generated/binary outputs**

```bash
git add -A Android/FolinoLibraryAndroid/src/main/jniLibs
git commit -m "build(android-library): rebuild JNI with tag bridge methods"
```
(If `jniLibs` is gitignored, this is a no-op — skip the commit. `build/generated` is regenerated by Gradle and should not be committed.)

---

## Task 8: Room backend — tag entities, DAO, migration v2→v3

**Files:**
- Modify: `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt`

- [ ] **Step 1: Add the tag entities**

After `PlaylistItemEntity` (line 54), add:

```kotlin
@Entity(tableName = "tags")
data class TagEntity(
    @PrimaryKey val id: String,
    val name: String,
    @ColumnInfo(name = "color_hex") val colorHex: String,
)

@Entity(
    tableName = "tag_items",
    primaryKeys = ["tag_id", "score_item_id"],
    indices = [androidx.room.Index("tag_id"), androidx.room.Index("score_item_id")],
)
data class TagItemEntity(
    @ColumnInfo(name = "tag_id") val tagId: String,
    @ColumnInfo(name = "score_item_id") val scoreItemId: String,
)
```

- [ ] **Step 2: Add the `TagDao`**

After `PlaylistDao` (line 87), add:

```kotlin
@Dao
interface TagDao {
    @Query("SELECT * FROM tags")
    fun loadTags(): List<TagEntity>

    @Query("SELECT * FROM tag_items")
    fun loadItems(): List<TagItemEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsertTag(record: TagEntity)

    @Query("DELETE FROM tag_items WHERE tag_id = :tagId")
    fun deleteItems(tagId: String)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun insertItems(items: List<TagItemEntity>)

    @Query("DELETE FROM tags WHERE id = :id")
    fun deleteTag(id: String)

    @androidx.room.Transaction
    fun replaceItems(tagId: String, items: List<TagItemEntity>) {
        deleteItems(tagId)
        insertItems(items)
    }

    @androidx.room.Transaction
    fun deleteTagCascade(id: String) {
        deleteItems(id)
        deleteTag(id)
    }
}
```

- [ ] **Step 3: Register entities, bump DB version, add the DAO accessor + migration**

Update the `@Database` annotation (lines 89-97) to include the tag entities and version 3:

```kotlin
@Database(
    entities = [
        ScoreRecordEntity::class,
        PlaylistEntity::class,
        PlaylistItemEntity::class,
        TagEntity::class,
        TagItemEntity::class,
    ],
    version = 3,
    exportSchema = false,
)
abstract class LibraryDatabase : RoomDatabase() {
    abstract fun dao(): ScoreRecordDao
    abstract fun playlistDao(): PlaylistDao
    abstract fun tagDao(): TagDao
}
```

After `MIGRATION_1_2` (line 111), add:

```kotlin
val MIGRATION_2_3 = object : androidx.room.migration.Migration(2, 3) {
    override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS `tags` " +
                "(`id` TEXT NOT NULL, `name` TEXT NOT NULL, `color_hex` TEXT NOT NULL, PRIMARY KEY(`id`))",
        )
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS `tag_items` " +
                "(`tag_id` TEXT NOT NULL, `score_item_id` TEXT NOT NULL, " +
                "PRIMARY KEY(`tag_id`, `score_item_id`))",
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS `index_tag_items_tag_id` ON `tag_items` (`tag_id`)")
        db.execSQL("CREATE INDEX IF NOT EXISTS `index_tag_items_score_item_id` ON `tag_items` (`score_item_id`)")
    }
}
```

- [ ] **Step 4: Register the migration on the builder + implement the protocol methods**

Update the builder (line 130) to add the migration:

```kotlin
    ).allowMainThreadQueries().addMigrations(MIGRATION_1_2, MIGRATION_2_3).build()
```

Add the DAO field after `playlistDao` (line 133):

```kotlin
    private val tagDao = db.tagDao()
```

Implement the new `LibraryStore` methods (add before the final closing brace, after `deletePlaylist`):

```kotlin
    override fun loadTags(): List<TagRecordWire> =
        tagDao.loadTags().map { TagRecordWire(it.id, it.name, it.colorHex) }

    override fun upsertTag(record: TagRecordWire) {
        tagDao.upsertTag(TagEntity(record.id, record.name, record.colorHex))
    }

    override fun deleteTag(id: String) {
        tagDao.deleteTagCascade(id)
    }

    override fun loadTagItems(): List<TagItemWire> =
        tagDao.loadItems().map { TagItemWire(it.tagId, it.scoreItemId) }

    override fun replaceTagItems(tagId: String, items: List<TagItemWire>) {
        tagDao.replaceItems(tagId, items.map { TagItemEntity(it.tagId, it.scoreItemId) })
    }
```

> Note: the generated Kotlin `LibraryStore` interface and `TagRecordWire`/`TagItemWire` data classes come from Task 7's codegen; this file just implements/maps them.

- [ ] **Step 5: Verify Kotlin compiles**

Run: `Android/gradlew -p Android :FolinoLibraryAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL (Room annotation processor accepts the new entities, DAO, and v3 schema).

- [ ] **Step 6: Commit**

```bash
git add Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt
git commit -m "feat(android-library): Room tags + tag_items tables, migration v2->v3"
```

---

## Task 9: Tag strings

**Files:**
- Modify: `Android/app/src/main/res/values/strings.xml`

- [ ] **Step 1: Add the tag strings**

Insert before the closing `</resources>` (after line 39):

```xml
    <string name="nav_tags">Tags</string>
    <string name="tags_title">Tags</string>
    <string name="tags_empty_title">No tags</string>
    <string name="tags_empty_hint">Tap + to create a tag.</string>
    <string name="tags_create">New tag</string>
    <string name="tags_name_hint">Tag name</string>
    <string name="tags_member_count">%1$d scores</string>
    <string name="tags_delete">Delete tag</string>
    <string name="tags_delete_confirm_title">Delete \"%1$s\"?</string>
    <string name="tags_delete_confirm_message">The scores stay in your library.</string>
    <string name="tags_rename">Rename</string>
    <string name="edit_tags">Edit tags</string>
    <string name="edit_tags_title">Tags</string>
    <string name="edit_tags_apply">Apply</string>
    <string name="tag_add">Tag</string>
    <string name="tag_remove_from">Remove from tag</string>
```

- [ ] **Step 2: Commit**

```bash
git add Android/app/src/main/res/values/strings.xml
git commit -m "feat(android-library): add tag string resources"
```

---

## Task 10: `TagsListScreen` (Compose)

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/TagsListScreen.kt`

Modeled on `PlaylistsListScreen.kt`. Reuses the existing `NameDialog` (declared `internal` in `PlaylistsListScreen.kt`, same package).

- [ ] **Step 1: Create the screen**

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
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.Label
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
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
import com.keynumber.folino.library.TagRowWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TagsListScreen(
    viewModel: LibraryAndroidStoreViewModel,
    onOpenTag: (String, String) -> Unit,
    onOpenDrawer: () -> Unit,
) {
    val tags by viewModel.tags.collectAsStateWithLifecycle()
    var showCreate by remember { mutableStateOf(false) }
    var pendingDelete by remember { mutableStateOf<TagRowWire?>(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.tags_title)) },
                navigationIcon = {
                    IconButton(onClick = onOpenDrawer) {
                        Icon(Icons.Filled.Menu, contentDescription = stringResource(R.string.nav_open_menu))
                    }
                },
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = { showCreate = true }) {
                Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.tags_create))
            }
        },
    ) { padding ->
        if (tags.isEmpty()) {
            Box(
                Modifier
                    .padding(padding)
                    .fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(stringResource(R.string.tags_empty_title), style = MaterialTheme.typography.titleMedium)
                    Text(stringResource(R.string.tags_empty_hint), style = MaterialTheme.typography.bodyMedium)
                }
            }
        } else {
            LazyColumn(
                Modifier
                    .padding(padding)
                    .fillMaxSize(),
            ) {
                items(tags, key = { it.id }) { row ->
                    TagRow(
                        row = row,
                        onClick = { onOpenTag(row.id, row.name) },
                        onRequestDelete = { pendingDelete = row },
                    )
                }
            }
        }
    }

    if (showCreate) {
        NameDialog(
            title = stringResource(R.string.tags_create),
            confirmLabel = stringResource(R.string.create),
            onConfirm = { name ->
                viewModel.createTag(name)
                showCreate = false
            },
            onDismiss = { showCreate = false },
        )
    }

    pendingDelete?.let { row ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(stringResource(R.string.tags_delete_confirm_title, row.name)) },
            text = { Text(stringResource(R.string.tags_delete_confirm_message)) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.deleteTag(row.id)
                    pendingDelete = null
                }) {
                    Text(stringResource(R.string.tags_delete))
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
private fun TagRow(row: TagRowWire, onClick: () -> Unit, onRequestDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    ListItem(
        headlineContent = { Text(row.name.ifEmpty { "Untitled" }) },
        supportingContent = { Text(stringResource(R.string.tags_member_count, row.memberCount)) },
        leadingContent = { Icon(Icons.Outlined.Label, contentDescription = null) },
        trailingContent = {
            Box {
                IconButton(onClick = { menu = true }) {
                    Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.more))
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.tags_delete)) },
                        onClick = {
                            menu = false
                            onRequestDelete()
                        },
                    )
                }
            }
        },
        modifier = Modifier.clickable(onClick = onClick),
    )
}
```

- [ ] **Step 2: Commit** (compiles together with Task 13 wiring; verify build there)

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/TagsListScreen.kt
git commit -m "feat(android-library): TagsListScreen (create/delete, member count)"
```

---

## Task 11: `TagDetailScreen` (Compose)

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/TagDetailScreen.kt`

Modeled on `PlaylistDetailScreen.kt`, minus drag-reorder (tags are unordered). Row overflow → "Remove from tag" (`setTagAssigned(id, tagId, false)`); top bar → rename / delete tag.

- [ ] **Step 1: Create the screen**

```kotlin
package com.keynumber.folino.ui.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.Label
import androidx.compose.material3.AlertDialog
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TagDetailScreen(
    viewModel: LibraryAndroidStoreViewModel,
    tagId: String,
    tagName: String,
    onOpenScore: (ScoreRowWire) -> Unit,
    onBack: () -> Unit,
) {
    LaunchedEffect(tagId) { viewModel.selectTag(tagId) }
    val items by viewModel.selectedTagItems.collectAsStateWithLifecycle()

    var showRename by remember { mutableStateOf(false) }
    var showDelete by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(tagName) },
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
                                text = { Text(stringResource(R.string.tags_rename)) },
                                onClick = {
                                    menu = false
                                    showRename = true
                                },
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.tags_delete)) },
                                onClick = {
                                    menu = false
                                    showDelete = true
                                },
                            )
                        }
                    }
                },
            )
        },
    ) { padding ->
        if (items.isEmpty()) {
            Box(
                Modifier
                    .padding(padding)
                    .fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Text(stringResource(R.string.tags_empty_hint), style = MaterialTheme.typography.bodyMedium)
            }
        } else {
            LazyColumn(
                Modifier
                    .padding(padding)
                    .fillMaxSize(),
            ) {
                items(items, key = { it.id }) { row ->
                    var rowMenu by remember { mutableStateOf(false) }
                    val title = row.title.ifEmpty { "Untitled" }
                    val headline = if (row.subtitle.isEmpty()) title else "$title ${row.subtitle}"
                    ListItem(
                        headlineContent = { Text(headline) },
                        supportingContent = { if (row.composer.isNotEmpty()) Text(row.composer) },
                        leadingContent = { Icon(Icons.Outlined.Label, contentDescription = null) },
                        trailingContent = {
                            Box {
                                IconButton(onClick = { rowMenu = true }) {
                                    Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.more))
                                }
                                DropdownMenu(expanded = rowMenu, onDismissRequest = { rowMenu = false }) {
                                    DropdownMenuItem(
                                        text = { Text(stringResource(R.string.tag_remove_from)) },
                                        onClick = {
                                            rowMenu = false
                                            viewModel.setTagAssigned(row.id, tagId, false)
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

    if (showRename) {
        NameDialog(
            title = stringResource(R.string.tags_rename),
            confirmLabel = stringResource(R.string.rename),
            initial = tagName,
            onConfirm = { name ->
                viewModel.renameTag(tagId, name)
                showRename = false
            },
            onDismiss = { showRename = false },
        )
    }
    if (showDelete) {
        AlertDialog(
            onDismissRequest = { showDelete = false },
            title = { Text(stringResource(R.string.tags_delete_confirm_title, tagName)) },
            text = { Text(stringResource(R.string.tags_delete_confirm_message)) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.deleteTag(tagId)
                    showDelete = false
                    onBack()
                }) {
                    Text(stringResource(R.string.tags_delete))
                }
            },
            dismissButton = { TextButton(onClick = { showDelete = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/TagDetailScreen.kt
git commit -m "feat(android-library): TagDetailScreen (members, rename/delete, remove-from-tag)"
```

---

## Task 12: `EditTagsSheet` + wire into `LibraryScreen` (row menu + bulk CAB)

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/EditTagsSheet.kt`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt`

`EditTagsSheet` handles both modes (like `AddToPlaylistSheet`): single-score (live checkbox toggle via `editSheetTags.contains` + `setTagAssigned`) and bulk (local multi-select + `bulkAddTag` per selected tag on Apply). Both offer inline create.

- [ ] **Step 1: Create `EditTagsSheet.kt`**

```kotlin
package com.keynumber.folino.ui.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
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
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
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
fun EditTagsSheet(
    viewModel: LibraryAndroidStoreViewModel,
    /** Non-null = single-score (live checkbox toggle); null = bulk (multi-select + Apply). */
    scoreId: String?,
    bulkScoreIds: List<String>,
    onDismiss: () -> Unit,
) {
    val picks by viewModel.editSheetTags.collectAsStateWithLifecycle()
    var showCreate by remember { mutableStateOf(false) }
    // Bulk-mode local selection (single mode toggles the store directly).
    val bulkSelected = remember { mutableStateListOf<String>() }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        ListItem(
            headlineContent = { Text(stringResource(R.string.tags_create)) },
            leadingContent = { Icon(Icons.Filled.Add, contentDescription = null) },
            modifier = Modifier.clickable { showCreate = true },
        )
        LazyColumn(
            Modifier
                .fillMaxWidth()
                .padding(bottom = 8.dp),
        ) {
            items(picks, key = { it.id }) { pick ->
                if (scoreId != null) {
                    ListItem(
                        headlineContent = { Text(pick.name) },
                        trailingContent = { Checkbox(checked = pick.contains, onCheckedChange = null) },
                        modifier = Modifier.clickable {
                            viewModel.setTagAssigned(scoreId, pick.id, !pick.contains)
                        },
                    )
                } else {
                    val checked = bulkSelected.contains(pick.id)
                    ListItem(
                        headlineContent = { Text(pick.name) },
                        trailingContent = { Checkbox(checked = checked, onCheckedChange = null) },
                        modifier = Modifier.clickable {
                            if (checked) bulkSelected.remove(pick.id) else bulkSelected.add(pick.id)
                        },
                    )
                }
            }
        }
        if (scoreId == null) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                TextButton(
                    enabled = bulkSelected.isNotEmpty(),
                    onClick = {
                        // Union-add each selected tag across all selected scores.
                        bulkSelected.forEach { tagId -> viewModel.bulkAddTag(tagId, bulkScoreIds) }
                        onDismiss()
                    },
                ) {
                    Text(stringResource(R.string.edit_tags_apply))
                }
            }
        }
    }

    if (showCreate) {
        NameDialog(
            title = stringResource(R.string.tags_create),
            confirmLabel = stringResource(R.string.create),
            onConfirm = { name ->
                viewModel.createTag(name)
                showCreate = false
            },
            onDismiss = { showCreate = false },
        )
    }
}
```

> Single-mode inline create just adds the tag (iOS parity: it does not auto-assign); the new row appears unchecked for the user to tap. Bulk-mode create adds the tag, leaving it for the user to select before Apply.

- [ ] **Step 2: Add the row "Edit tags" entry + bulk "Tag" CAB action in `LibraryScreen.kt`**

Add imports near the existing icon imports (around line 14):

```kotlin
import androidx.compose.material.icons.outlined.Label
```

In `LibraryScreen`, add state next to `singleAddTarget`/`showBulkAddSheet` (after line 74):

```kotlin
    var singleTagTarget by remember { mutableStateOf<String?>(null) }
    var showBulkTagSheet by remember { mutableStateOf(false) }
```

In the selection-mode `TopAppBar` `actions` (after the PlaylistAdd `IconButton`, before the Delete one, around line 121), add a Tag action:

```kotlin
                        IconButton(
                            enabled = selectedIds.isNotEmpty(),
                            onClick = {
                                viewModel.beginBulkEditTags()
                                showBulkTagSheet = true
                            },
                        ) {
                            Icon(
                                Icons.Outlined.Label,
                                contentDescription = stringResource(R.string.tag_add),
                            )
                        }
```

In the `ScoreRow(...)` call (after `onAddToPlaylist = { … }`, around line 188), add:

```kotlin
                        onEditTags = {
                            singleTagTarget = row.id
                            viewModel.beginEditTags(row.id)
                        },
```

Add the sheet hosts after the existing playlist sheet hosts (after line 213, before the final `}` of `LibraryScreen`):

```kotlin
    singleTagTarget?.let { id ->
        EditTagsSheet(
            viewModel = viewModel,
            scoreId = id,
            bulkScoreIds = emptyList(),
            onDismiss = { singleTagTarget = null },
        )
    }
    if (showBulkTagSheet) {
        EditTagsSheet(
            viewModel = viewModel,
            scoreId = null,
            bulkScoreIds = selectedIds.toList(),
            onDismiss = {
                showBulkTagSheet = false
                exitSelection()
            },
        )
    }
```

Update `ScoreRow`'s signature (line 218) to accept the new callback:

```kotlin
private fun ScoreRow(
    row: ScoreRowWire,
    selectionMode: Boolean,
    selected: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    onDelete: () -> Unit,
    onAddToPlaylist: () -> Unit,
    onEditTags: () -> Unit,
) {
```

In `ScoreRow`'s overflow `DropdownMenu` (after the "Add to playlist" `DropdownMenuItem`, around line 257), add:

```kotlin
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.edit_tags)) },
                            onClick = {
                                menu = false
                                onEditTags()
                            },
                        )
```

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/EditTagsSheet.kt Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt
git commit -m "feat(android-library): EditTagsSheet + row Edit-tags + bulk Tag CAB action"
```

---

## Task 13: Navigation — drawer "Tags" + routes

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`

- [ ] **Step 1: Import the new screens + a Tag icon**

Add to the imports block (alongside the existing library screen imports, lines 51-54, and icon imports ~line 16):

```kotlin
import androidx.compose.material.icons.outlined.Label
import com.keynumber.folino.ui.library.TagsListScreen
import com.keynumber.folino.ui.library.TagDetailScreen
```

- [ ] **Step 2: Make `tags` drawer-capable**

Update the `drawerCapable` expression (line 108):

```kotlin
    val drawerCapable = currentRoute == "list" || currentRoute == "recentlyDeleted" ||
        currentRoute == "playlists" || currentRoute == "tags"
```

- [ ] **Step 3: Add the drawer item**

In `drawerContent`, after the Playlists `NavigationDrawerItem` (line 159), add:

```kotlin
                NavigationDrawerItem(
                    icon = { Icon(Icons.Outlined.Label, contentDescription = null) },
                    label = { Text(stringResource(R.string.nav_tags)) },
                    selected = currentRoute == "tags",
                    onClick = { switchTo("tags") },
                    modifier = Modifier.padding(horizontal = 12.dp),
                )
```

- [ ] **Step 4: Add the routes**

In the inner `NavHost` (after the `playlist/{id}/{name}` composable, around line 215), add:

```kotlin
            composable("tags") {
                TagsListScreen(
                    viewModel = vm,
                    onOpenTag = { id, name ->
                        nav.navigate("tag/$id/${URLEncoder.encode(name, "UTF-8")}")
                    },
                    onOpenDrawer = openDrawer,
                )
            }
            composable(
                "tag/{id}/{name}",
                arguments = listOf(
                    navArgument("id") { type = NavType.StringType },
                    navArgument("name") { type = NavType.StringType },
                ),
            ) { entry ->
                val id = entry.arguments?.getString("id") ?: ""
                val name = URLDecoder.decode(entry.arguments?.getString("name") ?: "", "UTF-8")
                TagDetailScreen(
                    viewModel = vm,
                    tagId = id,
                    tagName = name,
                    onOpenScore = openReader,
                    onBack = { nav.popBackStack() },
                )
            }
```

- [ ] **Step 5: Build the whole app**

Run: `Android/gradlew -p Android :app:assembleDebug`
Expected: BUILD SUCCESSFUL — all Compose screens compile, navigation resolves, generated ViewModel methods (`createTag`, `selectTag`, `beginEditTags`, `beginBulkEditTags`, `setTagAssigned`, `bulkAddTag`, `renameTag`, `deleteTag`) and StateFlows (`tags`, `selectedTagItems`, `editSheetTags`) are present.

- [ ] **Step 6: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(android-library): drawer Tags destination + tag routes"
```

---

## Task 14: On-device verification (install + migration)

**Files:** none (verification only). Per memory `feedback_android_install_launch`, Android changes are verified by install + launch on a device.

- [ ] **Step 1: Migration test — install OVER an existing v2 build**

With the device already running a pre-tags build (DB at v2, ideally with some scores + playlists):

Run: `Android/gradlew -p Android :app:installDebug`
Then launch: `adb shell am start -n com.KeyNumber.Folino/com.keynumber.folino.MainActivity`
(Confirm the exact applicationId/activity via `adb shell cmd package list packages | rg folino` if needed.)
Expected: app launches without an `IllegalStateException`/Room migration crash; existing scores and playlists are intact (proves `MIGRATION_2_3` ran cleanly on populated data).

- [ ] **Step 2: Functional smoke (hand to user, or drive minimally)**

Verify on-device:
- Drawer → "Tags" opens the Tags list (empty state initially).
- FAB → create two tags; they appear name-sorted with "0 scores".
- All Scores → a row's overflow → "Edit tags" → toggle a tag on; reopen the sheet → it stays checked; tag's member count becomes 1.
- Multi-select two scores → CAB "Tag" action → select a tag → Apply; that tag's count reflects the union.
- Open a tag → its tagged scores are listed; row overflow → "Remove from tag" drops it; top bar → rename and delete tag work (delete pops back).
- Soft-delete a tagged score from All Scores → the tag's member count decreases; restore → it returns.

- [ ] **Step 3: Final full-suite Swift host test (regression guard)**

Run: `FOLINO_ANDROID=1 xcrun swift test --package-path Packages/Features/Library --filter LibraryAndroidStoreTests`
Expected: all tag + playlist + score store tests PASS.

- [ ] **Step 4: (Optional) record outcome**

If the user wants the branch merged, follow `superpowers:finishing-a-development-branch`. No commit needed for verification itself.

---

## Self-Review

**Spec coverage:**
- Tags list (CRUD, member count) → Tasks 3, 10. ✓
- Tag detail (members, rename/delete) → Tasks 5, 11. ✓
- Single-score tag editing (toggle + inline create) → Tasks 3 (`setTagAssigned`), 12 (`EditTagsSheet` single mode + row menu). ✓
- Bulk tag assignment (union) → Tasks 4 (`bulkAddTag`), 12 (CAB action + bulk sheet). ✓
- No color picker; default `#5856D6` → Task 3 (`createTag`). ✓
- No root section; drawer only → Task 13. ✓
- Join-table membership (`tags`/`tag_items`, no position) → Task 8. ✓
- DB v2→v3 migration → Task 8; verified Task 14. ✓
- Logic in Swift, Kotlin rule-free → Tasks 3-6 (Swift) vs Task 8 (Room). ✓
- Member count excludes soft-deleted + stays fresh on delete/restore/purge → Tasks 4, 6. ✓

**Deviation from spec (intentional, lower risk):** the spec's `bulkAddTags(tagIds:[String], scoreIds:[String])` (two list args) is replaced by `bulkAddTag(tagId:String, scoreIds:[String])` (single list arg, identical shape to the proven `bulkAddToPlaylist`), with the Kotlin bulk sheet looping over selected tags. This is exactly the fallback the spec's Risks section authorized, chosen up front to eliminate the two-`[String]`-arg codegen uncertainty. Union semantics are unchanged.

**Placeholder scan:** no TBD/TODO; every code step shows complete code. ✓

**Type consistency:** `TagRowWire(id,name,colorHex,memberCount)`, `TagRecordWire(id,name,colorHex)`, `TagItemWire(tagId,scoreItemId)`, `TagPickWire(id,name,contains)` are used identically across Swift defs (Task 1), protocol/store (Tasks 2-6), Room maps (Task 8), and Compose (Tasks 10-12). Method names (`createTag`, `renameTag`, `deleteTag`, `selectTag`, `beginEditTags`, `beginBulkEditTags`, `setTagAssigned`, `bulkAddTag`) match between Swift `@WireletExpose` and Kotlin call sites. ✓

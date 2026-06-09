# Favorites — Android port + bulk favorite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the Favorites feature to Android at parity with iOS, and add a bulk-favorite action to both platforms' multi-select modes.

**Architecture:** The favorite flag already lives on the shared Domain model (`ScoreItem.isFavorite`) and iOS GRDB column. We extend the JNI wire projections (`ScoreRecordWire`, `ScoreRowWire`) and the Swift-resident `LibraryAndroidStore` with favorite/unfavorite operations (mirroring the existing `delete`/`restore` precedent — no `Bool` is sent over the bridge), reset the Android Room DB to a fresh v1 schema that includes `is_favorite`, and build the Android UI (row star toggle, drawer entry, dedicated screen, CAB action) by extracting the reusable score-list scaffold out of `LibraryScreen`. iOS gains a bulk-favorite action in its existing `BulkActionBar`.

**Tech Stack:** Swift 6.3 / Swift Testing, swift-wirelet JNI bridge, Kotlin + Jetpack Compose (Material 3), Room.

**Spec:** `docs/superpowers/specs/2026-06-09-favorites-android-design.md`

**Key design decisions baked into this plan:**
- The bridge exposes four no-arg-Bool methods — `favorite(id)`, `unfavorite(id)`, `favoriteMany(ids)`, `unfavoriteMany(ids)` — mirroring `delete`/`restore`, so no `Bool` argument crosses JNI (matches the existing exposed surface, which only uses `String` / `[String]`).
- `isFavorite` is added to both wire structs with a Swift `init` default of `false`, so the ~30 existing `ScoreRecordWire(...)` test constructors keep compiling unchanged.
- iOS reuses the existing `library.score.favorite.action` ("Favorite") / `library.score.unfavorite.action` ("Unfavorite") localized keys for the bulk action — no new iOS strings.
- Bulk-favorite decision rule (both platforms): if **every** selected score is already favorited → unfavorite all; otherwise → favorite all.

---

## File Structure

**Phase 1 — shared Swift bridge + iOS view model (host-testable):**
- `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRecordWire.swift` — add `isFavorite`
- `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRowWire.swift` — add `isFavorite`
- `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift` — `favorites` observable, favorite/unfavorite[Many], row mapping, import call site, search recompute
- `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift` — new favorite tests
- `Packages/Features/Library/Sources/Library/LibraryViewModel.swift` — `bulkSetFavorite`
- `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelBulkTests.swift` — new bulk-favorite tests

**Phase 2 — iOS bulk-favorite UI:**
- `Packages/Features/Library/Sources/Library/Views/BulkActionBar.swift` — favorite menu item
- `Packages/Features/Library/Sources/Library/Views/ScoreListView.swift` — plumb `onBulkFavorite` + `allFavorited`
- `Packages/Features/Library/Sources/Library/Screens/ScoreListScreen.swift` — wire decision rule

**Phase 3 — Android Room:**
- `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt` — column, v1 reset, drop migrations, destructive fallback, mapping

**Phase 4 — Android UI:**
- `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/ScoreListScaffold.kt` — NEW reusable scaffold (extracted from LibraryScreen) with star toggle + CAB favorite
- `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt` — slimmed to a wrapper
- `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/FavoritesListScreen.kt` — NEW wrapper
- `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` — drawer entry + route
- `Android/app/src/main/res/values/strings.xml` — favorites strings

**Phase 5 — verification.**

---

## Phase 1 — Shared Swift bridge + iOS view model

Build/test surface for this whole phase (run from repo root):

```
cd Packages/Features/Library && xcodebuild test -scheme FolinoLibraryJNI -destination 'platform=iOS Simulator,name=iPhone 17'
```

(If a `swift test` works in this package it is faster, but per project memory SwiftLint's plugin breaks `swift test`; use the xcodebuild form above. `Library` and `FolinoLibraryJNI` are separate schemes — test each where indicated.)

### Task 1: Add `isFavorite` to `ScoreRecordWire`

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRecordWire.swift`

- [ ] **Step 1: Add the stored property + defaulted init parameter**

Replace the struct body so it reads:

```swift
@WireFormat
public struct ScoreRecordWire: Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var composer: String
    public var localFileName: String // "<id>.mscz" — built in Swift, iOS naming convention
    public var deletedAt: Double // 0 == live; >0 == soft-deleted at that Unix time
    public var isFavorite: Bool // mirrors iOS ScoreItem.isFavorite

    public init(
        id: String,
        title: String,
        subtitle: String,
        composer: String,
        localFileName: String,
        deletedAt: Double,
        isFavorite: Bool = false,
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
        self.localFileName = localFileName
        self.deletedAt = deletedAt
        self.isFavorite = isFavorite
    }
}
```

- [ ] **Step 2: Build the package to confirm the `@WireFormat` macro accepts the new property**

Run: `cd Packages/Features/Library && xcodebuild build -scheme FolinoLibraryJNI -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED. (The default `= false` keeps every existing `ScoreRecordWire(...)` call site compiling.)

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRecordWire.swift
git commit -m "feat(library): add isFavorite to ScoreRecordWire"
```

### Task 2: Add `isFavorite` to `ScoreRowWire`

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRowWire.swift`

- [ ] **Step 1: Add the stored property + defaulted init parameter**

Replace the struct body so it reads:

```swift
@WireFormat
public struct ScoreRowWire: Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var composer: String
    public var isFavorite: Bool

    public init(id: String, title: String, subtitle: String, composer: String, isFavorite: Bool = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
        self.isFavorite = isFavorite
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `cd Packages/Features/Library && xcodebuild build -scheme FolinoLibraryJNI -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRowWire.swift
git commit -m "feat(library): add isFavorite to ScoreRowWire"
```

### Task 3: `LibraryAndroidStore` favorites surface

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`
- Test: `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Append these tests inside `struct LibraryAndroidStoreTests { ... }` (before the closing brace):

```swift
    // MARK: - Favorites

    @Test func `favorite sets the flag, surfaces it on the row, and lists it under favorites`() {
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(id: "a", title: "A", subtitle: "", composer: "", localFileName: "a.mscz", deletedAt: 0),
        ]
        let store = LibraryAndroidStore(store: backend)
        #expect(store.favorites.isEmpty)
        #expect(store.scores.first?.isFavorite == false)

        store.favorite("a")

        #expect(store.scores.first?.isFavorite == true)
        #expect(store.favorites.map(\.id) == ["a"])
        #expect(backend.records.first?.isFavorite == true)
    }

    @Test func `unfavorite clears the flag and removes it from favorites`() {
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(
                id: "a", title: "A", subtitle: "", composer: "", localFileName: "a.mscz",
                deletedAt: 0, isFavorite: true,
            ),
        ]
        let store = LibraryAndroidStore(store: backend)
        #expect(store.favorites.map(\.id) == ["a"])

        store.unfavorite("a")

        #expect(store.favorites.isEmpty)
        #expect(store.scores.first?.isFavorite == false)
        #expect(backend.records.first?.isFavorite == false)
    }

    @Test func `favorites excludes soft-deleted scores`() {
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(
                id: "a", title: "A", subtitle: "", composer: "", localFileName: "a.mscz",
                deletedAt: 0, isFavorite: true,
            ),
            ScoreRecordWire(
                id: "b", title: "B", subtitle: "", composer: "", localFileName: "b.mscz",
                deletedAt: 999, isFavorite: true,
            ),
        ]
        let store = LibraryAndroidStore(store: backend)
        // Only the live favorite shows.
        #expect(store.favorites.map(\.id) == ["a"])
    }

    @Test func `favoriteMany favorites all; unfavoriteMany clears all`() {
        let backend = FakeLibraryStore()
        backend.records = ["a", "b", "c"].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)

        store.favoriteMany(["a", "c"])
        #expect(Set(store.favorites.map(\.id)) == ["a", "c"])

        store.unfavoriteMany(["a", "c"])
        #expect(store.favorites.isEmpty)
    }

    @Test func `favorite unknown id is a no-op`() {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)
        store.favorite("nope")
        #expect(store.favorites.isEmpty)
        #expect(backend.records.isEmpty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Packages/Features/Library && xcodebuild test -scheme FolinoLibraryJNI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FolinoLibraryJNITests/LibraryAndroidStoreTests`
Expected: FAIL — `favorite`, `unfavorite`, `favoriteMany`, `unfavoriteMany`, and `store.favorites` do not exist yet (compile error).

- [ ] **Step 3: Add the `favorites` observable property**

In `LibraryAndroidStore`, next to `public var deletedScores: [ScoreRowWire] = []` (around line 44), add:

```swift
    public var favorites: [ScoreRowWire] = []
```

- [ ] **Step 4: Carry `isFavorite` through the row projection**

Replace the `Self.row` helper (around line 201) with:

```swift
    private static func row(_ record: ScoreRecordWire) -> ScoreRowWire {
        ScoreRowWire(
            id: record.id,
            title: record.title,
            subtitle: record.subtitle,
            composer: record.composer,
            isFavorite: record.isFavorite,
        )
    }
```

- [ ] **Step 5: Compute `favorites` in `reload` and `setSearchQuery`**

In `reload(using:)` (around line 186), after the line `scores = searchFiltered(allScoreRows)`, add:

```swift
        favorites = searchFiltered(allScoreRows.filter(\.isFavorite))
```

In `setSearchQuery(_:)` (around line 119), after `scores = searchFiltered(allScoreRows)`, add:

```swift
        favorites = searchFiltered(allScoreRows.filter(\.isFavorite))
```

- [ ] **Step 6: Add the exposed favorite operations**

Add these methods inside the class body (place them just after `restore(_:)`, around line 116, to sit beside the soft-delete pair they mirror):

```swift
    /// Mark a score as a favorite (iOS parity: flips `ScoreItem.isFavorite`).
    @WireletExpose
    public func favorite(_ id: String) {
        setFavorite(id, true)
    }

    /// Clear a score's favorite flag.
    @WireletExpose
    public func unfavorite(_ id: String) {
        setFavorite(id, false)
    }

    /// Bulk favorite (All Scores CAB). No-op for ids already favorited.
    @WireletExpose
    public func favoriteMany(_ ids: [String]) {
        setFavoriteMany(ids, true)
    }

    /// Bulk unfavorite (All Scores CAB).
    @WireletExpose
    public func unfavoriteMany(_ ids: [String]) {
        setFavoriteMany(ids, false)
    }

    private func setFavorite(_ id: String, _ value: Bool) {
        var all = store.loadAll()
        guard let idx = all.firstIndex(where: { $0.id == id }), all[idx].isFavorite != value else { return }
        all[idx].isFavorite = value
        store.upsert(all[idx])
        reload(using: all)
        reloadPlaylists()
        reloadTags()
    }

    private func setFavoriteMany(_ ids: [String], _ value: Bool) {
        let idSet = Set(ids)
        var all = store.loadAll()
        var changed = false
        for idx in all.indices where idSet.contains(all[idx].id) && all[idx].isFavorite != value {
            all[idx].isFavorite = value
            store.upsert(all[idx])
            changed = true
        }
        guard changed else { return }
        reload(using: all)
        reloadPlaylists()
        reloadTags()
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `cd Packages/Features/Library && xcodebuild test -scheme FolinoLibraryJNI -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FolinoLibraryJNITests/LibraryAndroidStoreTests`
Expected: PASS (all existing tests + the 5 new favorite tests).

- [ ] **Step 8: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift
git commit -m "feat(library): favorite/unfavorite bridge ops + favorites list"
```

### Task 4: iOS `LibraryViewModel.bulkSetFavorite`

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`
- Test: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelBulkTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `struct LibraryViewModelBulkTests { ... }` (before the closing brace):

```swift
    // MARK: - bulkSetFavorite

    @Test func `bulk set favorite true marks all selected`() async {
        let a = Self.makeItem(title: "A")
        let b = Self.makeItem(title: "B")
        let f = Self.makeVM(scoreItems: [a, b])

        await f.vm.bulkSetFavorite([a.id, b.id], favorite: true)

        #expect(f.repo.scoreItems.first { $0.id == a.id }?.isFavorite == true)
        #expect(f.repo.scoreItems.first { $0.id == b.id }?.isFavorite == true)
    }

    @Test func `bulk set favorite false clears all selected`() async {
        var a = Self.makeItem(title: "A"); a.isFavorite = true
        var b = Self.makeItem(title: "B"); b.isFavorite = true
        let f = Self.makeVM(scoreItems: [a, b])

        await f.vm.bulkSetFavorite([a.id, b.id], favorite: false)

        #expect(f.repo.scoreItems.allSatisfy { $0.isFavorite == false })
    }

    @Test func `bulk set favorite skips items already in the target state`() async {
        var a = Self.makeItem(title: "A"); a.isFavorite = true
        let f = Self.makeVM(scoreItems: [a])

        await f.vm.bulkSetFavorite([a.id], favorite: true)

        #expect(f.repo.savedScoreItems.isEmpty) // no write — already favorited
    }

    @Test func `bulk set favorite empty is no op`() async {
        let f = Self.makeVM(scoreItems: [Self.makeItem(title: "A")])
        await f.vm.bulkSetFavorite([], favorite: true)
        #expect(f.repo.savedScoreItems.isEmpty)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/Features/Library && xcodebuild test -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LibraryTests/LibraryViewModelBulkTests`
Expected: FAIL — `bulkSetFavorite` does not exist (compile error).

- [ ] **Step 3: Implement `bulkSetFavorite`**

In `LibraryViewModel`, add this method right after `toggleFavorite(_:)` (around line 68):

```swift
    func bulkSetFavorite(_ ids: Set<ScoreItemID>, favorite: Bool) async {
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let item = repository.scoreItems.first(where: { $0.id == id }) else { continue }
            guard item.isFavorite != favorite else { continue }
            var updated = item
            updated.isFavorite = favorite
            do {
                try await repository.saveScoreItem(updated)
            } catch {
                currentError = error
                return
            }
        }
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/Features/Library && xcodebuild test -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LibraryTests/LibraryViewModelBulkTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/Library/LibraryViewModel.swift Packages/Features/Library/Tests/LibraryTests/LibraryViewModelBulkTests.swift
git commit -m "feat(library): LibraryViewModel.bulkSetFavorite"
```

---

## Phase 2 — iOS bulk-favorite UI

### Task 5: Bulk-favorite action in the iOS CAB

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Views/BulkActionBar.swift`
- Modify: `Packages/Features/Library/Sources/Library/Views/ScoreListView.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/ScoreListScreen.swift`

- [ ] **Step 1: Add favorite inputs to `BulkActionBar`**

In `BulkActionBar`, add two stored properties after `let onEditTags: () -> Void` (line 10):

```swift
    let allFavorited: Bool
    let onFavorite: () -> Void
```

Then add a favorite button to `actionMenuContent`, immediately after the `onEditTags` button (after line 65, inside the `@ViewBuilder private var actionMenuContent`):

```swift
        Button(action: onFavorite) {
            Label {
                let key: LocalizedStringKey = allFavorited
                    ? "library.score.unfavorite.action"
                    : "library.score.favorite.action"
                Text(key, bundle: .module)
            } icon: {
                Image(systemName: allFavorited ? "star.slash" : "star")
            }
        }
```

Update both `#Preview` blocks at the bottom of the file to pass the new arguments — add `allFavorited: false,` and `onFavorite: {},` to each `BulkActionBar(...)` call (the "Enabled" preview around line 93 and the "Disabled" preview around line 107).

- [ ] **Step 2: Plumb the inputs through `ScoreListView`**

In `ScoreListView`, add two stored properties after `let onBulkEditTags: () -> Void` (line 47):

```swift
    let onBulkFavorite: () -> Void
    let allSelectedFavorited: Bool
```

In `listWithChrome`, update the `BulkActionBar(...)` construction (around line 66) to pass them:

```swift
                    BulkActionBar(
                        selectionCount: selectedIDs.count,
                        availableShareFormats: availableShareFormats,
                        onShare: onBulkShare,
                        onAddToPlaylist: onBulkAddToPlaylist,
                        onEditTags: onBulkEditTags,
                        onDelete: onBulkDelete,
                        allFavorited: allSelectedFavorited,
                        onFavorite: onBulkFavorite,
                    )
```

Update `ScoreListViewPreviewHost` (around line 262) to pass the new arguments to its `ScoreListView(...)` call — add after `onBulkEditTags: {},`:

```swift
                onBulkFavorite: {},
                allSelectedFavorited: false,
```

- [ ] **Step 3: Wire the decision rule in `ScoreListScreen`**

In `ScoreListScreen`, add a computed property after `selectedItems` (around line 106):

```swift
    private var allSelectedFavorited: Bool {
        let items = selectedItems
        return !items.isEmpty && items.allSatisfy(\.isFavorite)
    }
```

In `listContent`, update the `ScoreListView(...)` call (around line 51): after the `onBulkDelete:` closure (which ends around line 75), add these two arguments:

```swift
            onBulkFavorite: {
                let ids = selectedIDs
                let makeFavorite = !allSelectedFavorited
                Task {
                    await library.bulkSetFavorite(ids, favorite: makeFavorite)
                    exitSelectionMode()
                }
            },
            allSelectedFavorited: allSelectedFavorited,
```

- [ ] **Step 4: Build the package + verify the previews compile**

Run: `cd Packages/Features/Library && xcodebuild build -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Views/BulkActionBar.swift Packages/Features/Library/Sources/Library/Views/ScoreListView.swift Packages/Features/Library/Sources/Library/Screens/ScoreListScreen.swift
git commit -m "feat(library): bulk favorite action in iOS selection mode"
```

---

## Phase 3 — Android Room (collapse to fresh v1)

### Task 6: `is_favorite` column + v1 reset + destructive fallback

**Files:**
- Modify: `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt`

- [ ] **Step 1: Add the entity column**

Replace `ScoreRecordEntity` (lines 17–25) with:

```kotlin
/** Room row — 1:1 with the Swift `ScoreRecordWire`. */
@Entity(tableName = "score_records")
data class ScoreRecordEntity(
    @PrimaryKey val id: String,
    val title: String,
    val subtitle: String,
    val composer: String,
    @ColumnInfo(name = "local_file_name") val localFileName: String,
    @ColumnInfo(name = "deleted_at") val deletedAt: Double,
    @ColumnInfo(name = "is_favorite") val isFavorite: Boolean = false,
)
```

- [ ] **Step 2: Reset the database version to 1**

Replace the `@Database(...)` annotation (lines 139–149) — change `version = 3` to `version = 1`:

```kotlin
@Database(
    entities = [
        ScoreRecordEntity::class,
        PlaylistEntity::class,
        PlaylistItemEntity::class,
        TagEntity::class,
        TagItemEntity::class,
    ],
    version = 1,
    exportSchema = false,
)
abstract class LibraryDatabase : RoomDatabase() {
    abstract fun dao(): ScoreRecordDao
    abstract fun playlistDao(): PlaylistDao
    abstract fun tagDao(): TagDao
}
```

- [ ] **Step 3: Delete the migration objects**

Delete the entire `val MIGRATION_1_2 = ...` block (lines 156–168) and the entire `val MIGRATION_2_3 = ...` block (lines 170–184).

- [ ] **Step 4: Swap migrations for destructive fallback in the database builder**

Replace the `Room.databaseBuilder(...)` chain (lines 199–203) with:

```kotlin
    private val db = Room.databaseBuilder(
        context.applicationContext,
        LibraryDatabase::class.java,
        "folino-library.db",
    ).allowMainThreadQueries().fallbackToDestructiveMigration().build()
```

- [ ] **Step 5: Map the new field in `loadAll` and `upsert`**

Replace `loadAll()` (lines 214–217) with:

```kotlin
    override fun loadAll(): List<ScoreRecordWire> =
        dao.loadAll().map {
            ScoreRecordWire(it.id, it.title, it.subtitle, it.composer, it.localFileName, it.deletedAt, it.isFavorite)
        }
```

Replace `upsert(...)` (lines 219–230) with:

```kotlin
    override fun upsert(record: ScoreRecordWire) {
        dao.upsert(
            ScoreRecordEntity(
                id = record.id,
                title = record.title,
                subtitle = record.subtitle,
                composer = record.composer,
                localFileName = record.localFileName,
                deletedAt = record.deletedAt,
                isFavorite = record.isFavorite,
            ),
        )
    }
```

> Note: the generated Kotlin `ScoreRecordWire` constructor now has 7 positional args (the bridge regenerates it from the Swift `@WireFormat` during the Android build). The `loadAll` positional call above passes all 7.

- [ ] **Step 6: Build the Android library module**

Per project memory (fresh worktree caveat), the Android build needs the wirelet codegen to run before the native libs. Build the app module:

Run: `Android/gradlew -p Android :app:assembleDebug` (or open in Android Studio and Build).
Expected: BUILD SUCCESSFUL. If `ScoreRecordWire` is reported with the wrong arity, the wirelet codegen has not regenerated — run the project's `Scripts/android-build-libs.sh` (or the documented codegen step) first, then rebuild.

- [ ] **Step 7: Commit**

```bash
git add Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt
git commit -m "feat(library-android): is_favorite column; reset Room to fresh v1"
```

---

## Phase 4 — Android UI

### Task 7: Extract `ScoreListScaffold` with star toggle + CAB favorite

This refactors the body of `LibraryScreen` into a reusable `ScoreListScaffold` so the Favorites screen can render the identical list (selection, CAB, sheets, swipe-delete) without duplication, and adds the favorite affordances. `LibraryScreen` becomes a thin wrapper.

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/ScoreListScaffold.kt`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt`

- [ ] **Step 1: Create `ScoreListScaffold.kt`**

Create the file with this content (this is the current `LibraryScreen` body, parameterized by `scores` / `titleRes` / `emptyTitleRes` / `emptyHintRes` / `importAction`, with the star toggle and CAB favorite added):

```kotlin
package com.keynumber.folino.ui.library

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
import androidx.compose.material.icons.automirrored.outlined.Label
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material.icons.outlined.StarBorder
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.keynumber.folino.R
import com.keynumber.folino.library.ScoreRowWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Reusable scores-list surface shared by the All Scores and Favorites screens.
 * Owns search, multi-select (CAB), row swipe-to-delete, the star toggle, and the
 * add-to-playlist / edit-tags / export sheets. The caller supplies the score
 * list, the titles, and — for All Scores only — the import FAB action.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScoreListScaffold(
    viewModel: LibraryAndroidStoreViewModel,
    scores: List<ScoreRowWire>,
    titleRes: Int,
    emptyTitleRes: Int,
    emptyHintRes: Int,
    onOpenScore: (ScoreRowWire) -> Unit,
    onOpenDrawer: () -> Unit,
    importAction: (() -> Unit)? = null,
) {
    var searchQuery by remember { mutableStateOf("") }
    androidx.compose.runtime.LaunchedEffect(searchQuery) { viewModel.setSearchQuery(searchQuery) }
    androidx.compose.runtime.DisposableEffect(Unit) { onDispose { viewModel.setSearchQuery("") } }
    val context = LocalContext.current
    val snackbarHost = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()

    var selectionMode by remember { mutableStateOf(false) }
    val selectedIds = remember { mutableStateListOf<String>() }
    var singleAddTarget by remember { mutableStateOf<String?>(null) }
    var showBulkAddSheet by remember { mutableStateOf(false) }
    var singleTagTarget by remember { mutableStateOf<String?>(null) }
    var showBulkTagSheet by remember { mutableStateOf(false) }

    var exportFormats by remember {
        mutableStateOf<List<com.keynumber.folino.library.ScoreExportFormatWire>>(emptyList())
    }
    var exportTargets by remember { mutableStateOf<List<String>>(emptyList()) }
    var showExportSheet by remember { mutableStateOf(false) }
    var exporting by remember { mutableStateOf(false) }
    val exportFailedMsg = stringResource(R.string.export_failed)

    fun exitSelection() {
        selectionMode = false
        selectedIds.clear()
    }

    fun toggle(id: String) {
        if (selectedIds.contains(id)) selectedIds.remove(id) else selectedIds.add(id)
        if (selectedIds.isEmpty()) selectionMode = false
    }

    fun beginExport(ids: List<String>) {
        if (ids.isEmpty()) return
        exportTargets = ids
        scope.launch {
            val formats = withContext(Dispatchers.Default) { viewModel.exportFormats(ids.first()) }
            exportFormats = formats
            showExportSheet = true
        }
    }

    fun runExport(token: String) {
        showExportSheet = false
        val ids = exportTargets
        scope.launch {
            exporting = true
            val dir = com.keynumber.folino.export.ScoreShareLauncher.exportsDir(context).absolutePath
            val paths = withContext(Dispatchers.Default) {
                ids.map { viewModel.exportScore(it, token, dir) }
            }
            exporting = false
            if (paths.any { it.isEmpty() }) {
                snackbarHost.showSnackbar(exportFailedMsg)
                return@launch
            }
            com.keynumber.folino.export.ScoreShareLauncher.share(context, paths)
        }
    }

    // CAB favorite: if every selected score is already favorited, the action clears
    // them all; otherwise it favorites them all (matches iOS bulk-favorite rule).
    val selectedAllFavorited = selectedIds.isNotEmpty() &&
        selectedIds.all { id -> scores.firstOrNull { it.id == id }?.isFavorite == true }

    Scaffold(
        topBar = {
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
                            onClick = {
                                if (selectedAllFavorited) {
                                    viewModel.unfavoriteMany(selectedIds.toList())
                                } else {
                                    viewModel.favoriteMany(selectedIds.toList())
                                }
                                exitSelection()
                            },
                        ) {
                            Icon(
                                if (selectedAllFavorited) Icons.Filled.Star else Icons.Outlined.StarBorder,
                                contentDescription = stringResource(R.string.favorite_add),
                            )
                        }
                        IconButton(
                            enabled = selectedIds.isNotEmpty(),
                            onClick = { beginExport(selectedIds.toList()) },
                        ) {
                            Icon(Icons.Filled.IosShare, contentDescription = stringResource(R.string.export))
                        }
                        IconButton(
                            enabled = selectedIds.isNotEmpty(),
                            onClick = {
                                viewModel.beginBulkAddToPlaylist()
                                showBulkAddSheet = true
                            },
                        ) {
                            Icon(
                                Icons.AutoMirrored.Filled.PlaylistAdd,
                                contentDescription = stringResource(R.string.add_to_playlist),
                            )
                        }
                        IconButton(
                            enabled = selectedIds.isNotEmpty(),
                            onClick = {
                                viewModel.beginBulkEditTags()
                                showBulkTagSheet = true
                            },
                        ) {
                            Icon(
                                Icons.AutoMirrored.Outlined.Label,
                                contentDescription = stringResource(R.string.tag_add),
                            )
                        }
                        IconButton(
                            enabled = selectedIds.isNotEmpty(),
                            onClick = {
                                viewModel.deleteMany(selectedIds.toList())
                                exitSelection()
                            },
                        ) {
                            Icon(Icons.Filled.Delete, contentDescription = stringResource(R.string.library_delete))
                        }
                    },
                )
            } else {
                TopAppBar(
                    title = { Text(stringResource(titleRes)) },
                    navigationIcon = {
                        IconButton(onClick = onOpenDrawer) {
                            Icon(Icons.Filled.Menu, contentDescription = stringResource(R.string.nav_open_menu))
                        }
                    },
                )
            }
        },
        snackbarHost = { SnackbarHost(snackbarHost) },
        floatingActionButton = {
            if (!selectionMode && importAction != null) {
                FloatingActionButton(onClick = importAction) {
                    Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.library_import))
                }
            }
        },
    ) { padding ->
        Column(
            Modifier
                .padding(padding)
                .fillMaxSize(),
        ) {
            if (!selectionMode) {
                LibrarySearchField(query = searchQuery, onQueryChange = { searchQuery = it })
            }
            if (scores.isEmpty()) {
                if (searchQuery.isBlank()) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(stringResource(emptyTitleRes), style = MaterialTheme.typography.titleMedium)
                            Text(stringResource(emptyHintRes), style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                } else {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text(
                            stringResource(R.string.search_no_results),
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
            } else {
                LazyColumn(Modifier.fillMaxSize()) {
                    items(scores, key = { it.id }) { row ->
                        ScoreRow(
                            row = row,
                            selectionMode = selectionMode,
                            selected = selectedIds.contains(row.id),
                            onClick = { if (selectionMode) toggle(row.id) else onOpenScore(row) },
                            onLongClick = {
                                if (!selectionMode) selectionMode = true
                                toggle(row.id)
                            },
                            onToggleFavorite = {
                                if (row.isFavorite) viewModel.unfavorite(row.id) else viewModel.favorite(row.id)
                            },
                            onDelete = {
                                viewModel.delete(row.id)
                                scope.launch {
                                    val result = snackbarHost.showSnackbar(
                                        message = context.getString(R.string.library_deleted),
                                        actionLabel = context.getString(R.string.library_undo),
                                    )
                                    if (result == SnackbarResult.ActionPerformed) viewModel.restore(row.id)
                                }
                            },
                            onAddToPlaylist = {
                                singleAddTarget = row.id
                                viewModel.beginAddToPlaylist(row.id)
                            },
                            onEditTags = {
                                singleTagTarget = row.id
                                viewModel.beginEditTags(row.id)
                            },
                            onExport = { beginExport(listOf(row.id)) },
                        )
                    }
                }
            }
        }
    }

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
            onDismiss = {
                showBulkAddSheet = false
                exitSelection()
            },
        )
    }
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
    if (showExportSheet) {
        ExportFormatSheet(
            formats = exportFormats,
            onPick = { runExport(it) },
            onDismiss = { showExportSheet = false },
        )
    }
    if (exporting) {
        Box(
            Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.scrim.copy(alpha = 0.32f)),
            contentAlignment = Alignment.Center,
        ) {
            CircularProgressIndicator()
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
private fun ScoreRow(
    row: ScoreRowWire,
    selectionMode: Boolean,
    selected: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    onToggleFavorite: () -> Unit,
    onDelete: () -> Unit,
    onAddToPlaylist: () -> Unit,
    onEditTags: () -> Unit,
    onExport: () -> Unit,
) {
    val content: @Composable () -> Unit = {
        var menu by remember { mutableStateOf(false) }
        val title = row.title.ifEmpty { "Untitled" }
        val headline = if (row.subtitle.isEmpty()) title else "$title ${row.subtitle}"
        ListItem(
            headlineContent = { Text(headline) },
            supportingContent = { if (row.composer.isNotEmpty()) Text(row.composer) },
            leadingContent = {
                if (selectionMode) {
                    Icon(
                        if (selected) Icons.Filled.CheckCircle else Icons.Outlined.RadioButtonUnchecked,
                        contentDescription = null,
                    )
                } else {
                    Icon(Icons.Filled.MusicNote, contentDescription = null)
                }
            },
            trailingContent = {
                if (!selectionMode) {
                    Row {
                        IconButton(onClick = onToggleFavorite) {
                            Icon(
                                if (row.isFavorite) Icons.Filled.Star else Icons.Outlined.StarBorder,
                                contentDescription = stringResource(
                                    if (row.isFavorite) R.string.favorite_remove else R.string.favorite_add,
                                ),
                            )
                        }
                        Box {
                            IconButton(onClick = { menu = true }) {
                                Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.more))
                            }
                            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                                DropdownMenuItem(
                                    text = {
                                        Text(
                                            stringResource(
                                                if (row.isFavorite) R.string.favorite_remove else R.string.favorite_add,
                                            ),
                                        )
                                    },
                                    onClick = {
                                        menu = false
                                        onToggleFavorite()
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.export)) },
                                    onClick = {
                                        menu = false
                                        onExport()
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.add_to_playlist)) },
                                    onClick = {
                                        menu = false
                                        onAddToPlaylist()
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.edit_tags)) },
                                    onClick = {
                                        menu = false
                                        onEditTags()
                                    },
                                )
                            }
                        }
                    }
                }
            },
            colors = if (selected) {
                ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.secondaryContainer)
            } else {
                ListItemDefaults.colors()
            },
            modifier = Modifier.combinedClickable(onClick = onClick, onLongClick = onLongClick),
        )
    }

    if (selectionMode) {
        content()
    } else {
        val dismissState = rememberSwipeToDismissBoxState(
            confirmValueChange = {
                if (it == SwipeToDismissBoxValue.EndToStart) {
                    onDelete()
                    true
                } else {
                    false
                }
            },
        )
        SwipeToDismissBox(
            state = dismissState,
            enableDismissFromStartToEnd = false,
            backgroundContent = {
                Box(
                    Modifier
                        .fillMaxSize()
                        .padding(horizontal = 16.dp),
                    contentAlignment = Alignment.CenterEnd,
                ) {
                    Icon(Icons.Filled.Delete, contentDescription = null)
                }
            },
        ) { content() }
    }
}
```

- [ ] **Step 2: Slim `LibraryScreen.kt` to a wrapper**

Replace the ENTIRE contents of `LibraryScreen.kt` with:

```kotlin
package com.keynumber.folino.ui.library

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.library.ScoreRowWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel

@Composable
fun LibraryScreen(
    viewModel: LibraryAndroidStoreViewModel,
    onOpenScore: (ScoreRowWire) -> Unit,
    onOpenDrawer: () -> Unit,
) {
    val scores by viewModel.scores.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri != null) {
            val displayName = originalDisplayName(context, uri)
            val cacheFile = java.io.File(context.cacheDir, displayName)
            context.contentResolver.openInputStream(uri)?.use { input ->
                cacheFile.outputStream().use { output -> input.copyTo(output) }
            }
            viewModel.importScore(cacheFile.absolutePath)
        }
    }

    ScoreListScaffold(
        viewModel = viewModel,
        scores = scores,
        titleRes = R.string.library_title,
        emptyTitleRes = R.string.library_empty_title,
        emptyHintRes = R.string.library_empty_hint,
        onOpenScore = onOpenScore,
        onOpenDrawer = onOpenDrawer,
        importAction = { picker.launch(arrayOf("*/*")) },
    )
}

/// The picked document's original display name (e.g. "Now_is_the_time.mscz"),
/// used to name the cache file so the Swift side derives the title from it.
private fun originalDisplayName(context: android.content.Context, uri: android.net.Uri): String {
    var name: String? = null
    context.contentResolver.query(
        uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null,
    )?.use { cursor ->
        if (cursor.moveToFirst()) {
            val idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (idx >= 0) name = cursor.getString(idx)
        }
    }
    return (name ?: "score.mscz").replace('/', '_')
}
```

- [ ] **Step 3: Build the app module**

Run: `Android/gradlew -p Android :app:assembleDebug`
Expected: BUILD SUCCESSFUL. (Resolves `R.string.favorite_add` / `favorite_remove` only after Task 9 adds them — if building this task in isolation fails on those two symbols, do Task 9 Step 1 first. The recommended order is Task 9 before a full build.)

- [ ] **Step 4: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/ScoreListScaffold.kt Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt
git commit -m "refactor(library-android): extract ScoreListScaffold; add star toggle + CAB favorite"
```

### Task 8: Drawer entry + Favorites route in `MainActivity`

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`

- [ ] **Step 1: Add imports**

Add to the import block (near the other icon imports, ~line 14 and ~line 65):

```kotlin
import androidx.compose.material.icons.filled.Star
import com.keynumber.folino.ui.library.FavoritesListScreen
```

- [ ] **Step 2: Make the Favorites route drawer-capable**

Replace the `drawerCapable` assignment (lines 129–130) with:

```kotlin
    val drawerCapable = currentRoute == "list" || currentRoute == "recentlyDeleted" ||
        currentRoute == "playlists" || currentRoute == "tags" || currentRoute == "favorites"
```

- [ ] **Step 3: Add the drawer item (directly under All Scores)**

Immediately after the All Scores `NavigationDrawerItem` (it ends at line 167, the one whose label is `nav_all_scores`), insert:

```kotlin
                NavigationDrawerItem(
                    icon = { Icon(Icons.Filled.Star, contentDescription = null) },
                    label = { Text(stringResource(R.string.nav_favorites)) },
                    selected = currentRoute == "favorites",
                    onClick = { switchTo("favorites") },
                    modifier = Modifier.padding(horizontal = 12.dp),
                )
```

- [ ] **Step 4: Register the `favorites` composable route**

In the inner `NavHost(nav, startDestination = "list")` block, immediately after the `composable("list") { ... }` block (it ends at line 211), insert:

```kotlin
            composable("favorites") {
                FavoritesListScreen(
                    viewModel = vm,
                    onOpenScore = openReader,
                    onOpenDrawer = openDrawer,
                )
            }
```

- [ ] **Step 5: Build the app module**

Run: `Android/gradlew -p Android :app:assembleDebug`
Expected: BUILD SUCCESSFUL (requires `FavoritesListScreen` from Task 9 and `nav_favorites` string from Task 9 — build after Task 9).

- [ ] **Step 6: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(library-android): Favorites drawer entry + route"
```

### Task 9: `FavoritesListScreen` + strings

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/FavoritesListScreen.kt`
- Modify: `Android/app/src/main/res/values/strings.xml`

- [ ] **Step 1: Add the strings**

In `Android/app/src/main/res/values/strings.xml`, add (next to the other `nav_*` / `library_*` entries):

```xml
    <string name="nav_favorites">Favorites</string>
    <string name="favorites_empty_title">No favorites yet</string>
    <string name="favorites_empty_hint">Tap the star on a score to add it here.</string>
    <string name="favorite_add">Add to favorites</string>
    <string name="favorite_remove">Remove from favorites</string>
```

- [ ] **Step 2: Create `FavoritesListScreen.kt`**

```kotlin
package com.keynumber.folino.ui.library

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.library.ScoreRowWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel

/**
 * Favorites screen — the same scores list surface as All Scores, fed by the
 * store's `favorites` flow and without the import FAB.
 */
@Composable
fun FavoritesListScreen(
    viewModel: LibraryAndroidStoreViewModel,
    onOpenScore: (ScoreRowWire) -> Unit,
    onOpenDrawer: () -> Unit,
) {
    val favorites by viewModel.favorites.collectAsStateWithLifecycle()
    ScoreListScaffold(
        viewModel = viewModel,
        scores = favorites,
        titleRes = R.string.nav_favorites,
        emptyTitleRes = R.string.favorites_empty_title,
        emptyHintRes = R.string.favorites_empty_hint,
        onOpenScore = onOpenScore,
        onOpenDrawer = onOpenDrawer,
        importAction = null,
    )
}
```

> Note: `viewModel.favorites` is the generated Kotlin `StateFlow<List<ScoreRowWire>>` for the `favorites` observable added to `LibraryAndroidStore` in Task 3. It is generated by the Observable bridge during the Android build.

- [ ] **Step 3: Build the whole app**

Run: `Android/gradlew -p Android :app:assembleDebug`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/FavoritesListScreen.kt Android/app/src/main/res/values/strings.xml
git commit -m "feat(library-android): FavoritesListScreen + favorites strings"
```

---

## Phase 5 — Verification

### Task 10: Full build + device check

- [ ] **Step 1: iOS — build the Library package and the app**

Run: `cd Packages/Features/Library && xcodebuild build -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17'`
Then build the app: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED for both. (Per project policy, do NOT install/launch the iOS simulator — leave manual run to the user.)

- [ ] **Step 2: iOS — full Library + JNI test suites**

Run:
`cd Packages/Features/Library && xcodebuild test -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17'`
`cd Packages/Features/Library && xcodebuild test -scheme FolinoLibraryJNI -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: all PASS.

- [ ] **Step 3: Android — build, install, launch on Pixel**

Run:
`Android/gradlew -p Android :app:installDebug`
`adb shell am start -n com.keynumber.folino/.MainActivity`
Expected: app launches. Because the DB was reset to v1 with destructive fallback, an existing pre-favorites install is wiped on first launch — confirm the app starts cleanly (empty library) rather than crashing on a downgrade.

- [ ] **Step 4: Android — manual smoke (hand to the user / verify directly)**

Confirm:
- Tapping the star on a row toggles favorite (filled ↔ outline) and the row's overflow shows "Add/Remove from favorites".
- The drawer shows **Favorites** under All Scores; opening it lists only favorited scores; empty state shows when none.
- Multi-select (long-press) shows a star action in the CAB; it favorites all when the selection is mixed/none, and unfavorites all when every selected score is already favorited.

- [ ] **Step 5: Final commit (if any lint/format fixups remain)**

```bash
git add -A
git commit -m "chore(favorites): lint/format fixups"
```

---

## Self-Review

**Spec coverage:**
- Data model / Room v1 reset → Task 6. ✓
- Wire `isFavorite` (record + row) → Tasks 1, 2. ✓
- Bridge favorite ops (mirroring delete/restore, no Bool over JNI) → Task 3. ✓
- Shared favorites filter → satisfied by the shared `ScoreItem.isFavorite` flag + identical `filter(\.isFavorite)` in both the iOS VM and the bridge; no trivial wrapper helper added (deliberate deviation from the spec's "shared helper" phrasing — a one-line boolean filter is not worth abstracting, unlike `ScoreSearch`). ✓ (documented)
- Android row star toggle + overflow item → Task 7. ✓
- Android FavoritesListScreen → Task 9. ✓
- Android drawer entry (always visible, under All Scores) → Task 8. ✓
- Android CAB bulk favorite → Task 7. ✓
- iOS bulk favorite in selection mode → Tasks 4, 5. ✓
- Localization (Android strings; iOS reuses existing keys) → Task 9; iOS keys confirmed present. ✓
- Tests (bridge favorite, iOS bulk) → Tasks 3, 4. ✓
- Verification incl. Pixel migration-wipe check → Task 10. ✓

**Type consistency:** `favorite`/`unfavorite`/`favoriteMany`/`unfavoriteMany` used identically in the bridge (Task 3) and Android UI (Task 7). `bulkSetFavorite(_:favorite:)` defined in Task 4 and called in Task 5. `ScoreListScaffold` signature defined in Task 7 and called identically in Tasks 7 (LibraryScreen) and 9 (FavoritesListScreen). `isFavorite` added to both wire structs (Tasks 1–2), mapped in Room (Task 6) and the row projection (Task 3).

**Build-order note:** Tasks 7–9 are mutually dependent at the Kotlin symbol level (scaffold ↔ screen ↔ strings ↔ route). Implement all three, then run the first green Android build. The per-task build steps say so.

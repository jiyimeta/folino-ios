# Library Android Recently Deleted Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Recently Deleted (Trash) screen to the Android Library: soft-deleted scores can be restored or permanently removed (record + file), with single-row and bulk (multi-select) actions.

**Architecture:** All Trash *logic* lives in the shared Swift `LibraryAndroidStore` (iOS parity): a new `deletedScores` observable (sorted desc), plus `permanentlyDelete` / `restoreMany` / `permanentlyDeleteMany` exposed over JNI. The Kotlin `@WireletProvided` backend gains one rule-free `deleteRecord` primitive (Room DELETE). The Compose UI is Android-idiomatic: overflow-menu entry, leading-swipe restore, AlertDialog confirm, and a Contextual Action Bar for bulk selection.

**Tech Stack:** Swift 6.3 (`@WireletObservable` / `@WireletProvided`, swift-wirelet 0.3.1), Swift Testing, Kotlin/Compose Material3, Room 2.6.1, JNI bridge.

**Spec:** `docs/superpowers/specs/2026-06-02-library-android-recently-deleted-design.md`

**Build/test reference (verified for this repo):**
- Host Swift tests: `FOLINO_ANDROID=1 xcrun swift test --filter LibraryAndroidStoreTests` run from `Packages/Features/Library`. The `FOLINO_ANDROID=1` flag selects the JNI-only package variant (no SwiftLint plugin, no ScoreUI/Utility), so plain `swift test` does NOT work — it fails on platform constraints.
- Android `.so` cross-compile: `Scripts/android-build-library-libs.sh` (needs the `/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain` toolchain on `PATH` — the swiftly shim is broken on this machine).
- App install/launch: `Android/gradlew -p Android :app:installDebug` then `adb shell am start -n com.keynumber.folino/.MainActivity`.

---

## File Structure

**Modify:**
- `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift` — add `deleteRecord(id:)` to the `@WireletProvided` protocol.
- `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift` — add `deletedScores` observable; `permanentlyDelete`, `restoreMany`, `permanentlyDeleteMany`; refactor `reload`.
- `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift` — extend `FakeLibraryStore`; add Trash tests.
- `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt` — add Room DELETE query + `deleteRecord` impl.
- `Android/app/src/main/res/values/strings.xml` — new strings.
- `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt` — overflow-menu "Recently Deleted" entry.
- `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` — `recentlyDeleted` nav route.

**Create:**
- `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/RecentlyDeletedScreen.kt` — the Trash screen (normal + CAB selection).

---

## Task 1: Backend `deleteRecord` primitive

Add the one missing persistence primitive: delete a record by id. Pure plumbing — no behavior change yet (nothing calls it), so the existing 6 host tests must still pass.

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift`
- Modify: `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt`
- Modify (test fake): `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift`

- [ ] **Step 1: Add `deleteRecord` to the Swift `@WireletProvided` protocol**

In `LibraryStore.swift`, add the method to the protocol (after `removeFile`):

```swift
    /// Permanently remove a persisted row by id. Pairs with `removeFile` for a
    /// full purge (the Swift store calls both). Soft-delete does NOT call this.
    func deleteRecord(id: String)
```

- [ ] **Step 2: Implement `deleteRecord` in the test fake so the test target still compiles**

In `LibraryAndroidStoreTests.swift`, inside `FakeLibraryStore`, add (after `removeFile`):

```swift
    func deleteRecord(id: String) {
        records.removeAll { $0.id == id }
    }
```

- [ ] **Step 3: Run existing host tests — they must still pass**

Run (from `Packages/Features/Library`):

```bash
FOLINO_ANDROID=1 xcrun swift test --filter LibraryAndroidStoreTests
```

Expected: `6 tests in 1 suite passed`.

- [ ] **Step 4: Implement `deleteRecord` in Kotlin `RoomLibraryStore`**

In `RoomLibraryStore.kt`, add to the `ScoreRecordDao` interface (after `upsert`):

```kotlin
    @Query("DELETE FROM score_records WHERE id = :id")
    fun delete(id: String)
```

And add the override to `RoomLibraryStore` (after `upsert`, before `copyImportedFile`):

```kotlin
    override fun deleteRecord(id: String) {
        dao.delete(id)
    }
```

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift \
        Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift \
        Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt
git commit -m "feat(android): add deleteRecord primitive to Library persistence backend"
```

---

## Task 2: Swift store — `deletedScores`, `permanentlyDelete`, bulk (TDD)

Add the Trash logic to the shared Swift store, mirroring iOS `RecentlyDeletedViewModel` (sort desc) and `LibraryViewModel` (permanent delete = removeFile + deleteRecord; bulk = loop).

**Files:**
- Test: `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift`
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`

- [ ] **Step 1: Write the failing tests**

Append these to the `LibraryAndroidStoreTests` struct in `LibraryAndroidStoreTests.swift`:

```swift
    @Test func `deletedScores lists soft-deleted rows sorted by deletedAt descending`() {
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(id: "old", title: "Old", subtitle: "", composer: "", localFileName: "old.mscz", deletedAt: 100),
            ScoreRecordWire(id: "live", title: "Live", subtitle: "", composer: "", localFileName: "live.mscz", deletedAt: 0),
            ScoreRecordWire(id: "new", title: "New", subtitle: "", composer: "", localFileName: "new.mscz", deletedAt: 200),
        ]
        let store = LibraryAndroidStore(store: backend)
        #expect(store.scores.map(\.id) == ["live"])
        #expect(store.deletedScores.map(\.id) == ["new", "old"]) // most-recently-deleted first
    }

    @Test func `permanentlyDelete removes the record and its file, dropping it from both lists`() {
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(id: "x", title: "X", subtitle: "", composer: "", localFileName: "x.mscz", deletedAt: 50),
        ]
        let store = LibraryAndroidStore(store: backend)
        #expect(store.deletedScores.map(\.id) == ["x"])

        store.permanentlyDelete("x")

        #expect(store.deletedScores.isEmpty)
        #expect(store.scores.isEmpty)
        #expect(backend.records.isEmpty)             // record deleted
        #expect(backend.removedFiles == ["x.mscz"])  // file removed
    }

    @Test func `permanentlyDelete unknown id is a no-op`() {
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(id: "x", title: "X", subtitle: "", composer: "", localFileName: "x.mscz", deletedAt: 50),
        ]
        let store = LibraryAndroidStore(store: backend)
        store.permanentlyDelete("nope")
        #expect(backend.records.map(\.id) == ["x"])
        #expect(backend.removedFiles.isEmpty)
    }

    @Test func `restoreMany clears deletedAt for all given ids in one pass`() {
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(id: "a", title: "A", subtitle: "", composer: "", localFileName: "a.mscz", deletedAt: 10),
            ScoreRecordWire(id: "b", title: "B", subtitle: "", composer: "", localFileName: "b.mscz", deletedAt: 20),
        ]
        let store = LibraryAndroidStore(store: backend)
        #expect(store.deletedScores.count == 2)

        store.restoreMany(["a", "b"])

        #expect(store.deletedScores.isEmpty)
        #expect(Set(store.scores.map(\.id)) == ["a", "b"])
    }

    @Test func `permanentlyDeleteMany purges all given ids and their files`() {
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(id: "a", title: "A", subtitle: "", composer: "", localFileName: "a.mscz", deletedAt: 10),
            ScoreRecordWire(id: "b", title: "B", subtitle: "", composer: "", localFileName: "b.mscz", deletedAt: 20),
            ScoreRecordWire(id: "c", title: "C", subtitle: "", composer: "", localFileName: "c.mscz", deletedAt: 0),
        ]
        let store = LibraryAndroidStore(store: backend)

        store.permanentlyDeleteMany(["a", "b"])

        #expect(backend.records.map(\.id) == ["c"])           // live row untouched
        #expect(Set(backend.removedFiles) == ["a.mscz", "b.mscz"])
        #expect(store.deletedScores.isEmpty)
        #expect(store.scores.map(\.id) == ["c"])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (from `Packages/Features/Library`):

```bash
FOLINO_ANDROID=1 xcrun swift test --filter LibraryAndroidStoreTests
```

Expected: compile error — `store` has no member `deletedScores` / `permanentlyDelete` / `restoreMany` / `permanentlyDeleteMany`.

- [ ] **Step 3: Implement the store changes**

In `LibraryAndroidStore.swift`:

(a) Add the second observable property, right after `public var scores: [ScoreRowWire] = []`:

```swift
    public var deletedScores: [ScoreRowWire] = []
```

(b) Add the new exposed methods after the existing `restore(_:)` method (before `private func setDeletedAt`):

```swift
    /// Permanent purge (iOS parity, `permanentlyDeleteScoreItem`): remove the
    /// managed file, then the record. Unknown id is a no-op.
    @WireletExpose
    public func permanentlyDelete(_ id: String) {
        let all = store.loadAll()
        guard let record = all.first(where: { $0.id == id }) else { return }
        store.removeFile(localFileName: record.localFileName)
        store.deleteRecord(id: id)
        reload()
    }

    /// Bulk restore (iOS `bulkRestore`): clear `deletedAt` for each id, then
    /// reload once. Unknown ids are skipped.
    @WireletExpose
    public func restoreMany(_ ids: [String]) {
        var all = store.loadAll()
        for id in ids {
            guard let idx = all.firstIndex(where: { $0.id == id }) else { continue }
            all[idx].deletedAt = 0
            store.upsert(all[idx])
        }
        reload(using: all)
    }

    /// Bulk permanent purge (iOS `bulkPermanentlyDelete`): remove file + record
    /// for each id, then reload once.
    @WireletExpose
    public func permanentlyDeleteMany(_ ids: [String]) {
        let idSet = Set(ids)
        for record in store.loadAll() where idSet.contains(record.id) {
            store.removeFile(localFileName: record.localFileName)
            store.deleteRecord(id: record.id)
        }
        reload()
    }
```

(c) Replace the existing `reload(using:)` method body so it populates **both** lists and add a small projection helper. Replace:

```swift
    private func reload(using records: [ScoreRecordWire]? = nil) {
        scores = (records ?? store.loadAll())
            .filter { $0.deletedAt <= 0 }
            .map { ScoreRowWire(id: $0.id, title: $0.title, subtitle: $0.subtitle, composer: $0.composer) }
    }
```

with:

```swift
    private func reload(using records: [ScoreRecordWire]? = nil) {
        let all = records ?? store.loadAll()
        scores = all
            .filter { $0.deletedAt <= 0 }
            .map(Self.row)
        // Recently Deleted: soft-deleted rows, most-recently-trashed first
        // (mirrors iOS RecentlyDeletedViewModel). Sorting happens here, before
        // projection, so ScoreRowWire need not carry deletedAt.
        deletedScores = all
            .filter { $0.deletedAt > 0 }
            .sorted { $0.deletedAt > $1.deletedAt }
            .map(Self.row)
    }

    private static func row(_ record: ScoreRecordWire) -> ScoreRowWire {
        ScoreRowWire(id: record.id, title: record.title, subtitle: record.subtitle, composer: record.composer)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run (from `Packages/Features/Library`):

```bash
FOLINO_ANDROID=1 xcrun swift test --filter LibraryAndroidStoreTests
```

Expected: `11 tests in 1 suite passed` (6 existing + 5 new).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift \
        Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift
git commit -m "feat(android): Trash logic in LibraryAndroidStore (deletedScores, permanent delete, bulk)"
```

---

## Task 3: Strings + RecentlyDeletedScreen (Compose, normal + CAB selection)

Build the Trash screen. No unit tests (Compose UI); correctness is verified by the full build in Task 5. Provide complete code.

**Files:**
- Modify: `Android/app/src/main/res/values/strings.xml`
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/RecentlyDeletedScreen.kt`

- [ ] **Step 1: Add strings**

In `strings.xml`, add these inside `<resources>` (before `</resources>`):

```xml
    <string name="library_recently_deleted">Recently Deleted</string>
    <string name="more">More</string>
    <string name="cancel">Cancel</string>
    <string name="recently_deleted_title">Recently Deleted</string>
    <string name="recently_deleted_restore">Restore</string>
    <string name="recently_deleted_delete">Delete permanently</string>
    <string name="recently_deleted_delete_confirm_title">Permanently delete \"%1$s\"?</string>
    <string name="recently_deleted_delete_bulk_confirm_title">Permanently delete %1$d scores?</string>
    <string name="recently_deleted_delete_confirm_message">This score and its file will be removed from this device.</string>
    <string name="recently_deleted_empty_title">Trash is Empty</string>
    <string name="recently_deleted_empty_hint">Deleted scores will appear here</string>
```

- [ ] **Step 2: Create `RecentlyDeletedScreen.kt`**

Create `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/RecentlyDeletedScreen.kt` with:

```kotlin
package com.keynumber.folino.ui.library

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DeleteForever
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Restore
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.library.ScoreRowWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecentlyDeletedScreen(
    viewModel: LibraryAndroidStoreViewModel,
    onOpenScore: (ScoreRowWire) -> Unit,
    onBack: () -> Unit,
) {
    val deleted by viewModel.deletedScores.collectAsStateWithLifecycle()
    var selectionMode by remember { mutableStateOf(false) }
    val selectedIds = remember { mutableStateListOf<String>() }
    var pendingSingleDelete by remember { mutableStateOf<ScoreRowWire?>(null) }
    var showBulkDeleteDialog by remember { mutableStateOf(false) }

    fun exitSelection() {
        selectionMode = false
        selectedIds.clear()
    }

    fun toggle(id: String) {
        if (selectedIds.contains(id)) selectedIds.remove(id) else selectedIds.add(id)
        if (selectedIds.isEmpty()) selectionMode = false
    }

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
                                viewModel.restoreMany(selectedIds.toList())
                                exitSelection()
                            },
                        ) {
                            Icon(
                                Icons.Filled.Restore,
                                contentDescription = stringResource(R.string.recently_deleted_restore),
                            )
                        }
                        IconButton(
                            enabled = selectedIds.isNotEmpty(),
                            onClick = { showBulkDeleteDialog = true },
                        ) {
                            Icon(
                                Icons.Filled.DeleteForever,
                                contentDescription = stringResource(R.string.recently_deleted_delete),
                            )
                        }
                    },
                )
            } else {
                TopAppBar(
                    title = { Text(stringResource(R.string.recently_deleted_title)) },
                    navigationIcon = {
                        IconButton(onClick = onBack) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                        }
                    },
                )
            }
        },
    ) { padding ->
        if (deleted.isEmpty()) {
            EmptyTrash(
                Modifier
                    .padding(padding)
                    .fillMaxSize(),
            )
        } else {
            LazyColumn(
                Modifier
                    .padding(padding)
                    .fillMaxSize(),
            ) {
                items(deleted, key = { it.id }) { row ->
                    TrashRow(
                        row = row,
                        selectionMode = selectionMode,
                        selected = selectedIds.contains(row.id),
                        onClick = { if (selectionMode) toggle(row.id) else onOpenScore(row) },
                        onLongClick = {
                            if (!selectionMode) selectionMode = true
                            toggle(row.id)
                        },
                        onRestore = { viewModel.restore(row.id) },
                        onRequestPermanentDelete = { pendingSingleDelete = row },
                    )
                }
            }
        }
    }

    pendingSingleDelete?.let { row ->
        PermanentDeleteDialog(
            title = stringResource(
                R.string.recently_deleted_delete_confirm_title,
                row.title.ifEmpty { "Untitled" },
            ),
            onConfirm = {
                viewModel.permanentlyDelete(row.id)
                pendingSingleDelete = null
            },
            onDismiss = { pendingSingleDelete = null },
        )
    }

    if (showBulkDeleteDialog) {
        PermanentDeleteDialog(
            title = stringResource(R.string.recently_deleted_delete_bulk_confirm_title, selectedIds.size),
            onConfirm = {
                viewModel.permanentlyDeleteMany(selectedIds.toList())
                showBulkDeleteDialog = false
                exitSelection()
            },
            onDismiss = { showBulkDeleteDialog = false },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
private fun TrashRow(
    row: ScoreRowWire,
    selectionMode: Boolean,
    selected: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    onRestore: () -> Unit,
    onRequestPermanentDelete: () -> Unit,
) {
    val content: @Composable () -> Unit = {
        var menuExpanded by remember { mutableStateOf(false) }
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
                    Box {
                        IconButton(onClick = { menuExpanded = true }) {
                            Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.more))
                        }
                        DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.recently_deleted_restore)) },
                                onClick = {
                                    menuExpanded = false
                                    onRestore()
                                },
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.recently_deleted_delete)) },
                                onClick = {
                                    menuExpanded = false
                                    onRequestPermanentDelete()
                                },
                            )
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
        // Leading swipe (start->end) = Restore — a safe, reversible action, so a
        // swipe is appropriate. Permanent delete is irreversible and is NOT bound
        // to a swipe; it goes through the row menu + confirm dialog.
        val dismissState = rememberSwipeToDismissBoxState(
            confirmValueChange = {
                if (it == SwipeToDismissBoxValue.StartToEnd) {
                    onRestore()
                    true
                } else {
                    false
                }
            },
        )
        SwipeToDismissBox(
            state = dismissState,
            enableDismissFromStartToEnd = true,
            enableDismissFromEndToStart = false,
            backgroundContent = {
                Box(
                    Modifier
                        .fillMaxSize()
                        .padding(horizontal = 16.dp),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    Icon(Icons.Filled.Restore, contentDescription = null)
                }
            },
        ) { content() }
    }
}

@Composable
private fun PermanentDeleteDialog(title: String, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(stringResource(R.string.recently_deleted_delete_confirm_message)) },
        confirmButton = {
            TextButton(onClick = onConfirm) { Text(stringResource(R.string.recently_deleted_delete)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
        },
    )
}

@Composable
private fun EmptyTrash(modifier: Modifier) {
    Box(modifier, contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(stringResource(R.string.recently_deleted_empty_title), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(R.string.recently_deleted_empty_hint), style = MaterialTheme.typography.bodyMedium)
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/res/values/strings.xml \
        Android/app/src/main/kotlin/com/keynumber/folino/ui/library/RecentlyDeletedScreen.kt
git commit -m "feat(android): RecentlyDeletedScreen with restore, permanent delete, bulk selection"
```

(The screen is not yet reachable — that is Task 4. It builds because it depends only on the generated VM API from Tasks 1-2 and existing Compose deps.)

---

## Task 4: Wire the entry point — overflow menu + nav route

Make the screen reachable: an overflow ("more") menu on the Library top app bar → "Recently Deleted", and a nav route that reuses the same Library view-model instance (so both screens share the `StateFlow`s).

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`

- [ ] **Step 1: Add the overflow menu to `LibraryScreen`**

In `LibraryScreen.kt`:

(a) Add these imports (alongside the existing `androidx.compose.material3.*` imports):

```kotlin
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
```

(Note: `import androidx.compose.runtime.getValue` is already present — do not duplicate it. Add only the imports not already in the file.)

(b) Change the `LibraryScreen` signature to add the new callback:

```kotlin
fun LibraryScreen(
    viewModel: LibraryAndroidStoreViewModel,
    onOpenScore: (ScoreRowWire) -> Unit,
    onOpenSettings: () -> Unit,
    onOpenRecentlyDeleted: () -> Unit,
) {
```

(c) Replace the `TopAppBar`'s `actions = { ... }` block (currently just the Settings `IconButton`) with the Settings icon plus an overflow menu:

```kotlin
                actions = {
                    IconButton(onClick = onOpenSettings) {
                        Icon(
                            Icons.Filled.Settings,
                            contentDescription = stringResource(R.string.nav_settings),
                        )
                    }
                    var menuExpanded by remember { mutableStateOf(false) }
                    IconButton(onClick = { menuExpanded = true }) {
                        Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.more))
                    }
                    DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.library_recently_deleted)) },
                            onClick = {
                                menuExpanded = false
                                onOpenRecentlyDeleted()
                            },
                        )
                    }
                },
```

- [ ] **Step 2: Add the nav route in `MainActivity`**

In `MainActivity.kt`, in the `LibraryNavGraph` composable:

(a) Add the import:

```kotlin
import com.keynumber.folino.ui.library.RecentlyDeletedScreen
```

(b) Pass the new callback to `LibraryScreen` in the `composable("list")` block:

```kotlin
        composable("list") {
            LibraryScreen(
                viewModel = vm,
                onOpenScore = { row ->
                    nav.navigate("reader/${URLEncoder.encode(row.title, "UTF-8")}")
                },
                onOpenSettings = onOpenSettings,
                onOpenRecentlyDeleted = { nav.navigate("recentlyDeleted") },
            )
        }
```

(c) Add a new `composable("recentlyDeleted")` block inside the same `NavHost` (after the `composable("list")` block, before the `composable("reader/{title}")` block). It reuses `vm` (declared at the top of `LibraryNavGraph`), so the deleted-list `StateFlow` is shared with the main list:

```kotlin
        composable("recentlyDeleted") {
            RecentlyDeletedScreen(
                viewModel = vm,
                onOpenScore = { row ->
                    nav.navigate("reader/${URLEncoder.encode(row.title, "UTF-8")}")
                },
                onBack = { nav.popBackStack() },
            )
        }
```

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt \
        Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(android): reach Recently Deleted via Library overflow menu"
```

---

## Task 5: Device build + manual verification

Tasks 1-2 changed the Swift store **and** the wire schema (new observable prop + 3 new exposed methods + 1 new provided method), so the `.so` and the Kotlin generated code must be rebuilt. This task is a verification gate — not TDD.

**Build ordering (from the persistence slice — getting it wrong yields `UnsatisfiedLinkError`):** the wirelet observable codegen writes a `.wirelet-observable-jni.json` sidecar that the SwiftPM bridge plugin reads to emit `JNI_OnLoad`. Follow the same sequence the persistence merge used: Kotlin-side codegen (Gradle) → Swift cross-compile (`.so` with `JNI_OnLoad`) → assemble/install. The `Scripts/android-build-library-libs.sh` cross-compile runs the Swift-side codegen via the SwiftPM plugin; the Gradle `installDebug` runs the Kotlin-side `generateWirelet*` tasks. If a nested `swift-wirelet/.build` is stale (`invalid access` during codegen), remove `Packages/Features/Library/.build/checkouts/swift-wirelet/.build` and retry.

- [ ] **Step 1: Cross-compile the JNI `.so` for both ABIs**

Run (from repo root):

```bash
PATH="/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH" Scripts/android-build-library-libs.sh
```

Expected: ends with `libFolinoLibraryJNI.so + runtime staged under .../jniLibs/{arm64-v8a,x86_64}/`.

- [ ] **Step 2: Build + install the app on the connected Pixel**

Run (from repo root):

```bash
PATH="/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH" Android/gradlew -p Android :app:installDebug --no-daemon
```

Expected: `BUILD SUCCESSFUL`, app installed. (Gradle runs `generateWireletCodecsMain`, `generateWireletObservableViewModelsMain`, `generateWireletProvidedInterfacesMain` — these pick up the new `deletedScores` prop, the 3 new exposed methods, and the new `deleteRecord` provided method.)

- [ ] **Step 3: Launch**

```bash
adb shell am start -n com.keynumber.folino/.MainActivity
```

- [ ] **Step 4: Manual verification checklist**

Verify on the device (no crashes throughout — watch `adb logcat` for `UnsatisfiedLinkError` / `wirelet`):

1. Import a `.mscz` (FAB) → row appears in the main list.
2. Swipe-delete the row → snackbar appears; the row leaves the main list.
3. Top app bar overflow (⋮) → **Recently Deleted** → the deleted row is present.
4. Leading-swipe the row (left→right) → it is restored and disappears from Trash; go back → it is in the main list again.
5. Re-delete it → return to Trash → row ⋮ menu → **Delete permanently** → confirm dialog → confirm → row gone from Trash. (Go back: not in main list either.)
6. Import 2-3 scores, delete them all, open Trash → **long-press** a row → selection mode (count in app bar, checkboxes) → select multiple → **Restore** (toolbar) restores all; re-delete, reselect → **Delete permanently** → "Permanently delete N scores?" → confirm → all gone.
7. Empty the trash entirely → empty state ("Trash is Empty") shows.
8. Kill and relaunch the app → a soft-deleted (not purged) score is still in Trash; permanently-deleted ones do not reappear (persistence survives restart).

- [ ] **Step 5: Final commit (if the build required any staged regen artifacts)**

The generated Kotlin and the `.so`/sidecar are gitignored, so there is normally nothing to commit here. If any tracked file changed, commit it:

```bash
git status --short
# if anything tracked changed:
git add -A
git commit -m "chore(android): regen wirelet bridge for Recently Deleted"
```

---

## Self-Review notes

- **Spec coverage:** deletedScores + sort desc (Task 2) ✓; permanent delete = removeFile + deleteRecord (Tasks 1-2) ✓; bulk restore/permanent (Task 2 + Task 3 CAB) ✓; backend `deleteRecord` (Task 1) ✓; overflow-menu entry (Task 4) ✓; leading-swipe restore + AlertDialog confirm + CAB (Task 3) ✓; host tests (Tasks 1-2) ✓; device verify (Task 5) ✓. Out-of-scope items (empty-trash, auto-purge, search/sort, share, Reader, localization) are intentionally absent.
- **Type consistency:** `deletedScores`, `permanentlyDelete(_:)`, `restoreMany(_:)`, `permanentlyDeleteMany(_:)`, `deleteRecord(id:)`, `Self.row(_:)` are used identically across tasks. Kotlin call sites (`viewModel.deletedScores`, `.restore`, `.restoreMany`, `.permanentlyDelete`, `.permanentlyDeleteMany`) match the generated names. String ids match between `strings.xml` and `stringResource` calls.
- **No placeholders:** every code/command step is concrete.

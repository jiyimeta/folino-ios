# Android Library Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the iOS Library score-list search (title-or-composer, case- and diacritic-insensitive substring) to Android at parity, driven by shared Domain matching logic and an Android-idiom search field row.

**Architecture:** Lift the iOS matching logic into a Foundation-only `Domain.ScoreSearch` helper. iOS `ScoreListViewModel` and the Android `LibraryAndroidStore` bridge both call it. The Android bridge keeps unfiltered backing arrays and exposes already-filtered observables (`scores` / `selectedPlaylistItems` / `selectedTagItems`); Compose never filters. A reusable Compose search field row sits below each list screen's `TopAppBar`.

**Tech Stack:** Swift 6.3 (Domain, FolinoLibraryJNI via swift-wirelet), Kotlin/Jetpack Compose (Material3), Android cross-compile toolchain (swift-6.3.2-RELEASE).

**Worktree:** `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-library-search` on branch `worktree-android-library-search`. Run all commands against this path.

---

## File Structure

- **Create:** `Packages/Domain/Sources/Domain/ScoreSearch.swift` — shared matching predicate.
- **Create:** `Packages/Domain/Tests/DomainTests/ScoreSearchTests.swift` — host unit tests for the predicate.
- **Modify:** `Packages/Features/Library/Sources/Library/ScoreListViewModel.swift` — delegate `applySearch` to `ScoreSearch`.
- **Modify:** `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift` — backing arrays, `setSearchQuery`, filtered observables.
- **Modify:** `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift` — bridge search test (host, FOLINO_ANDROID build). *(Confirm exact existing test filename in Step.)*
- **Create:** `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibrarySearchField.kt` — reusable search input row.
- **Modify:** `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt` — search on All list.
- **Modify:** `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/TagDetailScreen.kt` — search on tag detail.
- **Modify:** `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/PlaylistDetailScreen.kt` — search on playlist detail (disable reorder while searching).
- **Modify:** `Android/app/src/main/res/values/strings.xml` — `search_hint`, `search_no_results`.

---

## Task 1: Shared Domain matching helper (`ScoreSearch`)

**Files:**
- Create: `Packages/Domain/Sources/Domain/ScoreSearch.swift`
- Test: `Packages/Domain/Tests/DomainTests/ScoreSearchTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Domain/Tests/DomainTests/ScoreSearchTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

struct ScoreSearchTests {
    @Test func `empty query matches everything`() {
        #expect(ScoreSearch.matches(title: "Sonata", composer: "Mozart", query: ""))
        #expect(ScoreSearch.matches(title: "Sonata", composer: nil, query: "   "))
    }

    @Test func `matches title substring case insensitively`() {
        #expect(ScoreSearch.matches(title: "Moonlight Sonata", composer: nil, query: "sonata"))
        #expect(ScoreSearch.matches(title: "Moonlight Sonata", composer: nil, query: "MOON"))
    }

    @Test func `matches composer substring`() {
        #expect(ScoreSearch.matches(title: "Prelude", composer: "Chopin", query: "chop"))
    }

    @Test func `matches diacritic insensitively`() {
        #expect(ScoreSearch.matches(title: "Étude Op.10", composer: nil, query: "etude"))
    }

    @Test func `no match returns false`() {
        #expect(!ScoreSearch.matches(title: "Prelude", composer: "Chopin", query: "mozart"))
    }

    @Test func `nil composer does not match and does not crash`() {
        #expect(!ScoreSearch.matches(title: "Prelude", composer: nil, query: "chopin"))
    }

    @Test func `query is trimmed before matching`() {
        #expect(ScoreSearch.matches(title: "Sonata", composer: nil, query: "  sonata  "))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run (from worktree root):
```
xcodebuild test -scheme Domain-Package -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:DomainTests/ScoreSearchTests
```
(Run against `Packages/Domain` — if the `-scheme` is not found, run `xcodebuild -list -workspace .` or build the package scheme from Xcode; the scheme is `Domain` or `Domain-Package`.)
Expected: FAIL — "cannot find 'ScoreSearch' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Packages/Domain/Sources/Domain/ScoreSearch.swift`:

```swift
import Foundation

/// Shared score-list search predicate. Both the iOS `ScoreListViewModel` and the
/// Android `LibraryAndroidStore` bridge use this so the matching rules stay
/// identical across platforms (iOS/Android parity: share logic, never reimplement).
///
/// Mirrors the iOS `.searchable` behavior: the query is trimmed; an empty query
/// matches everything; otherwise the query must appear as a case- and
/// diacritic-insensitive substring of the title or the composer.
public enum ScoreSearch {
    public static func matches(title: String, composer: String?, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if title.range(of: trimmed, options: opts, locale: .current) != nil { return true }
        if let composer, composer.range(of: trimmed, options: opts, locale: .current) != nil { return true }
        return false
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: same command as Step 2.
Expected: PASS — all 7 tests green.

- [ ] **Step 5: Commit**

```
git -C <worktree> add Packages/Domain/Sources/Domain/ScoreSearch.swift Packages/Domain/Tests/DomainTests/ScoreSearchTests.swift
git -C <worktree> commit -m "feat(domain): add shared ScoreSearch matching predicate"
```

---

## Task 2: Refactor iOS `ScoreListViewModel.applySearch` to use `ScoreSearch`

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/ScoreListViewModel.swift:79-94`
- Test (existing, must stay green): `Packages/Features/Library/Tests/LibraryTests/ScoreListViewModelTests.swift:87-109`

- [ ] **Step 1: Replace the inline matcher**

In `ScoreListViewModel.swift`, replace the whole `applySearch` method (lines 79-94) with:

```swift
    private func applySearch(_ items: [ScoreItem]) -> [ScoreItem] {
        items.filter { ScoreSearch.matches(title: $0.title, composer: $0.composer, query: searchQuery) }
    }
```

(`Domain` is already imported at line 1. The empty-query short-circuit now lives in `ScoreSearch.matches`.)

- [ ] **Step 2: Run the existing iOS search tests to verify they still pass**

Run:
```
xcodebuild test -scheme Library-Package -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation -only-testing:LibraryTests/ScoreListViewModelTests
```
(If `Library-Package` scheme is not found, use `Library`.)
Expected: PASS — including `search matches title and composer case and diacritic insensitively` and `empty search query returns all`.

- [ ] **Step 3: Commit**

```
git -C <worktree> add Packages/Features/Library/Sources/Library/ScoreListViewModel.swift
git -C <worktree> commit -m "refactor(library-ios): use shared ScoreSearch in ScoreListViewModel"
```

---

## Task 3: Android bridge — filtered observables + `setSearchQuery`

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`
- Test: `Packages/Features/Library/Tests/FolinoLibraryJNITests/<existing>.swift`

- [ ] **Step 1: Add backing storage and the search-query field**

In `LibraryAndroidStore`, immediately after the `selectedTagID` / `editSheetScoreID` declarations (around line 59), add:

```swift
    // Search (iOS parity). `searchQuery` filters the three displayed score lists
    // via the shared Domain `ScoreSearch`. Unfiltered backings let setSearchQuery
    // recompute the observables without re-reading the backend.
    @ObservationIgnored private var searchQuery = ""
    @ObservationIgnored private var allScoreRows: [ScoreRowWire] = []
    @ObservationIgnored private var selectedPlaylistRows: [ScoreRowWire] = []
    @ObservationIgnored private var selectedTagRows: [ScoreRowWire] = []
```

- [ ] **Step 2: Add the filter helper**

Add this private method next to `private static func row(...)` (after line 184):

```swift
    /// Filter a row list by the current search query using the shared predicate.
    private func searchFiltered(_ rows: [ScoreRowWire]) -> [ScoreRowWire] {
        rows.filter { ScoreSearch.matches(title: $0.title, composer: $0.composer, query: searchQuery) }
    }
```

- [ ] **Step 3: Route `scores` through the backing + filter**

In `reload(using:)` (lines 168-180), replace the `scores = all...` assignment so the live rows go to the backing first, then the filtered result to the observable:

```swift
        allScoreRows = all
            .filter { $0.deletedAt <= 0 }
            .map(Self.row)
        scores = searchFiltered(allScoreRows)
```

(Leave the `deletedScores` block unchanged — Recently Deleted has no search.)

- [ ] **Step 4: Route `selectedPlaylistItems` through the backing + filter**

In `recomputeSelectedItems(domain:records:liveIDs:)` (lines 364-378), replace both assignment paths:

```swift
    private func recomputeSelectedItems(domain: [Playlist], records: [ScoreRecordWire], liveIDs: Set<ScoreItemID>) {
        guard let sel = selectedPlaylistID,
              let playlist = domain.first(where: { $0.id.rawValue.uuidString == sel })
        else {
            selectedPlaylistRows = []
            selectedPlaylistItems = []
            return
        }
        var rowByID: [ScoreItemID: ScoreRowWire] = [:]
        for record in records where record.deletedAt <= 0 {
            if let sid = scoreItemID(record.id) { rowByID[sid] = Self.row(record) }
        }
        selectedPlaylistRows = PlaylistPresentation
            .orderedLiveIDs(playlist, liveIDs: liveIDs)
            .compactMap { rowByID[$0] }
        selectedPlaylistItems = searchFiltered(selectedPlaylistRows)
    }
```

- [ ] **Step 5: Route `selectedTagItems` through the backing + filter**

In `recomputeSelectedTagItems(records:membership:)` (lines 513-523), replace both assignment paths:

```swift
    private func recomputeSelectedTagItems(records: [ScoreRecordWire], membership: [String: Set<String>]) {
        guard let sel = selectedTagID else {
            selectedTagRows = []
            selectedTagItems = []
            return
        }
        let members = membership[sel] ?? []
        selectedTagRows = records
            .filter { $0.deletedAt <= 0 && members.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map(Self.row)
        selectedTagItems = searchFiltered(selectedTagRows)
    }
```

- [ ] **Step 6: Add the `setSearchQuery` exposed method**

Add this `@WireletExpose` method inside the primary class body (e.g. right after `restore(_:)` near line 107, so it stays in the primary body — NOT in an extension):

```swift
    /// Set the search query and recompute the three displayed score lists from
    /// their unfiltered backings. iOS parity: empty query shows everything.
    @WireletExpose
    public func setSearchQuery(_ query: String) {
        searchQuery = query
        scores = searchFiltered(allScoreRows)
        selectedPlaylistItems = searchFiltered(selectedPlaylistRows)
        selectedTagItems = searchFiltered(selectedTagRows)
    }
```

- [ ] **Step 7: Write the bridge host test**

First find the existing bridge test file:
```
ls Packages/Features/Library/Tests/FolinoLibraryJNITests/
```
Add a test to the existing suite (or a new file `ScoreSearchBridgeTests.swift` in that directory) that drives a fake `LibraryStore`, imports two scores, sets a query, and asserts `scores` filters. Use the same fake-store pattern the existing tests use. Minimal new test:

```swift
import Foundation
import Testing
@testable import FolinoLibraryJNI

struct ScoreSearchBridgeTests {
    @Test func `setSearchQuery filters scores by title`() {
        let store = FakeLibraryStore() // reuse the existing test fake
        store.records = [
            ScoreRecordWire(id: "1", title: "Moonlight Sonata", subtitle: "", composer: "Beethoven", localFileName: "1.mscz", deletedAt: 0),
            ScoreRecordWire(id: "2", title: "Prelude", subtitle: "", composer: "Chopin", localFileName: "2.mscz", deletedAt: 0),
        ]
        let sut = LibraryAndroidStore(store: store, pdfRenderer: FakePdfRenderer(), audioExporter: FakeAudioExporter())
        sut.setSearchQuery("sonata")
        #expect(sut.scores.map(\.id) == ["1"])
        sut.setSearchQuery("")
        #expect(Set(sut.scores.map(\.id)) == ["1", "2"])
    }
}
```

**Adapt the fake type names** (`FakeLibraryStore`, `FakePdfRenderer`, `FakeAudioExporter`, and `.records`) to whatever the existing test file already defines — read it first and match exactly.

- [ ] **Step 8: Run the bridge host test**

Run:
```
FOLINO_ANDROID=1 xcrun swift test --package-path Packages/Features/Library --filter ScoreSearchBridgeTests
```
Expected: PASS. (This verifies the matching LOGIC and that the bridge compiles in the Android package configuration on the macOS host. It does NOT verify Android-runtime diacritic folding — that is Task 10.)

- [ ] **Step 9: Commit**

```
git -C <worktree> add Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift Packages/Features/Library/Tests/FolinoLibraryJNITests/
git -C <worktree> commit -m "feat(library-android): add setSearchQuery and filtered list observables"
```

---

## Task 4: Add Android search strings

**Files:**
- Modify: `Android/app/src/main/res/values/strings.xml`

- [ ] **Step 1: Add the two strings**

Insert before the closing `</resources>` in `Android/app/src/main/res/values/strings.xml`:

```xml
    <string name="search_hint">Search</string>
    <string name="search_no_results">No results</string>
```

- [ ] **Step 2: Commit**

```
git -C <worktree> add Android/app/src/main/res/values/strings.xml
git -C <worktree> commit -m "feat(library-android): add search strings"
```

---

## Task 5: Reusable Compose search field

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibrarySearchField.kt`

- [ ] **Step 1: Create the composable**

Create `LibrarySearchField.kt`:

```kotlin
package com.keynumber.folino.ui.library

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.keynumber.folino.R

/// Persistent search input row placed below a screen's TopAppBar. No full-screen
/// "active" SearchBar overlay — typing filters the list in place. Leading search
/// icon; trailing clear button appears once there is text.
@Composable
fun LibrarySearchField(
    query: String,
    onQueryChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    OutlinedTextField(
        value = query,
        onValueChange = onQueryChange,
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        singleLine = true,
        placeholder = { Text(stringResource(R.string.search_hint)) },
        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
        trailingIcon = {
            if (query.isNotEmpty()) {
                IconButton(onClick = { onQueryChange("") }) {
                    Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.cancel))
                }
            }
        },
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
    )
}
```

- [ ] **Step 2: Commit**

```
git -C <worktree> add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibrarySearchField.kt
git -C <worktree> commit -m "feat(library-android): add reusable LibrarySearchField composable"
```

---

## Task 6: Wire search into `LibraryScreen` (All list)

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt`

- [ ] **Step 1: Add query state and sync to the bridge**

After `val scores by viewModel.scores.collectAsStateWithLifecycle()` (line 72), add:

```kotlin
    var searchQuery by remember { mutableStateOf("") }
    androidx.compose.runtime.LaunchedEffect(searchQuery) { viewModel.setSearchQuery(searchQuery) }
    androidx.compose.runtime.DisposableEffect(Unit) { onDispose { viewModel.setSearchQuery("") } }
```

(The `LaunchedEffect(searchQuery)` fires once on entry with `""`, resetting any query carried over from another screen, and again on each keystroke.)

- [ ] **Step 2: Render the search field + filtered empty state**

Replace the content lambda body (lines 221-267, the `if (scores.isEmpty()) { EmptyState... } else { LazyColumn... }` block) with a `Column` that always shows the search field above the list, and distinguishes the no-scores-at-all empty state from the no-results state:

```kotlin
    ) { padding ->
        Column(
            Modifier
                .padding(padding)
                .fillMaxSize(),
        ) {
            // Hide search while in selection mode (CAB owns the bar/content focus).
            if (!selectionMode) {
                LibrarySearchField(query = searchQuery, onQueryChange = { searchQuery = it })
            }
            if (scores.isEmpty()) {
                if (searchQuery.isBlank()) {
                    EmptyState(Modifier.fillMaxSize())
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
```

(`EmptyState` already exists and takes a `Modifier`. `Column` is already imported at line 9.)

- [ ] **Step 3: Build `:app` (deferred to Task 9 codegen) — for now just commit the source**

```
git -C <worktree> add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt
git -C <worktree> commit -m "feat(library-android): search field on All Scores list"
```

---

## Task 7: Wire search into `TagDetailScreen`

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/TagDetailScreen.kt`

- [ ] **Step 1: Add query state and sync to the bridge**

After `val items by viewModel.selectedTagItems.collectAsStateWithLifecycle()` (line 49), add:

```kotlin
    var searchQuery by remember { mutableStateOf("") }
    LaunchedEffect(searchQuery) { viewModel.setSearchQuery(searchQuery) }
    androidx.compose.runtime.DisposableEffect(Unit) { onDispose { viewModel.setSearchQuery("") } }
```

(`LaunchedEffect` and `mutableStateOf`/`remember` are already imported.)

- [ ] **Step 2: Render search field + filtered empty state**

Replace the content lambda body (lines 89-134, the `if (items.isEmpty()) {...} else {...}` block) with:

```kotlin
    ) { padding ->
        androidx.compose.foundation.layout.Column(
            Modifier
                .padding(padding)
                .fillMaxSize(),
        ) {
            LibrarySearchField(query = searchQuery, onQueryChange = { searchQuery = it })
            if (items.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(
                        stringResource(
                            if (searchQuery.isBlank()) R.string.tags_empty_hint else R.string.search_no_results,
                        ),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            } else {
                LazyColumn(Modifier.fillMaxSize()) {
                    items(items, key = { it.id }) { row ->
                        var rowMenu by remember { mutableStateOf(false) }
                        val title = row.title.ifEmpty { "Untitled" }
                        val headline = if (row.subtitle.isEmpty()) title else "$title ${row.subtitle}"
                        ListItem(
                            headlineContent = { Text(headline) },
                            supportingContent = { if (row.composer.isNotEmpty()) Text(row.composer) },
                            leadingContent = { Icon(Icons.AutoMirrored.Outlined.Label, contentDescription = null) },
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
    }
```

- [ ] **Step 3: Commit**

```
git -C <worktree> add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/TagDetailScreen.kt
git -C <worktree> commit -m "feat(library-android): search field on tag detail"
```

---

## Task 8: Wire search into `PlaylistDetailScreen` (disable reorder while searching)

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/PlaylistDetailScreen.kt`

Reordering a filtered subset would corrupt the stored order, so when a query is active we render a plain (non-reorderable) list.

- [ ] **Step 1: Add query state and sync to the bridge**

After `val items by viewModel.selectedPlaylistItems.collectAsStateWithLifecycle()` (line 53), add:

```kotlin
    var searchQuery by remember { mutableStateOf("") }
    LaunchedEffect(searchQuery) { viewModel.setSearchQuery(searchQuery) }
    androidx.compose.runtime.DisposableEffect(Unit) { onDispose { viewModel.setSearchQuery("") } }
    val searching = searchQuery.isNotBlank()
```

- [ ] **Step 2: Render the search field and branch list rendering**

Replace the content lambda body (lines 108-163, the `if (local.isEmpty()) {...} else { LazyColumn ... }` block) with:

```kotlin
    ) { padding ->
        androidx.compose.foundation.layout.Column(
            Modifier
                .padding(padding)
                .fillMaxSize(),
        ) {
            LibrarySearchField(query = searchQuery, onQueryChange = { searchQuery = it })
            if (local.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(
                        stringResource(
                            if (searching) R.string.search_no_results else R.string.playlists_empty_hint,
                        ),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            } else {
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize(),
                ) {
                    items(local, key = { it.id }) { row ->
                        ReorderableItem(reorderState, key = row.id) {
                            var rowMenu by remember { mutableStateOf(false) }
                            val title = row.title.ifEmpty { "Untitled" }
                            val headline = if (row.subtitle.isEmpty()) title else "$title ${row.subtitle}"
                            ListItem(
                                headlineContent = { Text(headline) },
                                supportingContent = { if (row.composer.isNotEmpty()) Text(row.composer) },
                                leadingContent = {
                                    if (!searching) {
                                        IconButton(modifier = Modifier.draggableHandle(), onClick = {}) {
                                            Icon(
                                                Icons.Filled.DragHandle,
                                                contentDescription = stringResource(R.string.playlist_reorder_handle),
                                            )
                                        }
                                    }
                                },
                                trailingContent = {
                                    Box {
                                        IconButton(onClick = { rowMenu = true }) {
                                            Icon(
                                                Icons.Filled.MoreVert,
                                                contentDescription = stringResource(R.string.more),
                                            )
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
    }
```

The drag handle is hidden while `searching`, so the reorder gesture is unavailable on the filtered subset; the `reorderState` callback (which writes `setPlaylistOrder`) can then only fire on the full, unfiltered list.

- [ ] **Step 3: Commit**

```
git -C <worktree> add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/PlaylistDetailScreen.kt
git -C <worktree> commit -m "feat(library-android): search field on playlist detail; disable reorder while searching"
```

---

## Task 9: Regenerate Android bridge bindings and compile

The Swift bridge gained `setSearchQuery`, so the generated Kotlin `LibraryAndroidStoreViewModel` must be regenerated (the Compose tasks above call `viewModel.setSearchQuery`). Reader/Settings bindings are unchanged and may be copied from the primary checkout to avoid re-cross-compiling them. Follow the **android-build-toolchain** memory for the exact toolchain PATH.

- [ ] **Step 1: Copy unchanged Reader/Settings generated bindings + jniLibs from primary**

```
cp -R /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Android/FolinoReaderAndroid/src/main/java-generated <worktree>/Android/FolinoReaderAndroid/src/main/java-generated
cp -R /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Android/FolinoReaderAndroid/src/main/jniLibs <worktree>/Android/FolinoReaderAndroid/src/main/jniLibs
cp -R /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Android/FolinoSettingsAndroid/src/main/java-generated <worktree>/Android/FolinoSettingsAndroid/src/main/java-generated
cp -R /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Android/FolinoSettingsAndroid/src/main/jniLibs <worktree>/Android/FolinoSettingsAndroid/src/main/jniLibs
```

(Each `cp -R` is a separate Bash call. If a destination already exists, remove it first or copy into it consistently with the existing worktree convention.)

- [ ] **Step 2: Regenerate the Library bridge (.so + java-generated) for the changed Swift**

Resolve the wirelet pin if needed, then run the Library libs build script with the cross-compile toolchain (per android-build-toolchain memory — `/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin` prefixed on PATH):

```
PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH <worktree>/Scripts/android-build-library-libs.sh
```

Expected: regenerates `Android/FolinoLibraryAndroid/src/main/jniLibs/**/*.so` and the Library `java-generated` bindings, now including `setSearchQuery` on the generated `LibraryAndroidStoreViewModel`.

If the script fails on the wirelet `Package.resolved` drift, follow the **wirelet-resolved-drift** memory (resolve → chmod → gradle codegen → rebuild .so). The correct wirelet pin for Library is `ba1b8e3` (already in `Packages/Features/Library/Package.swift`).

- [ ] **Step 3: Compile the Android app**

```
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH <worktree>/Android/gradlew -p <worktree>/Android :app:compileDebugKotlin --no-daemon
```
Expected: BUILD SUCCESSFUL. If `compileDebugKotlin` complains that `setSearchQuery` is unresolved, the codegen in Step 2 did not pick up the new method — re-run Step 2 and confirm `LibraryAndroidStoreViewModel` in `java-generated` contains `setSearchQuery`.

- [ ] **Step 4: Commit regenerated bindings if they are tracked**

Check `git -C <worktree> status`. `jniLibs` / `java-generated` are typically gitignored (per project memory). Commit only what is tracked:

```
git -C <worktree> status
# commit only tracked changes, if any
```

---

## Task 10: Install, launch, and verify on a physical Pixel (incl. diacritic check)

Per the Android parity rule, Android changes are verified by install + launch, not just a build.

- [ ] **Step 1: Install the debug build on the connected Pixel**

```
PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH <worktree>/Android/gradlew -p <worktree>/Android :app:installDebug --no-daemon
```
Expected: `Installed on 1 device`.

- [ ] **Step 2: Launch the app**

```
adb shell am start -n com.keynumber.folino/.MainActivity
```

- [ ] **Step 3: Manual verification checklist**

Import (or ensure present) a score whose title contains a diacritic, e.g. "Étude". Then verify:
- All Scores: search field appears below the top bar; typing `son` filters to titles/composers containing "son"; clearing restores the full list; `zzz` shows "No results".
- **Diacritic:** typing `etude` (no accent) matches "Étude". **If it does NOT match**, Android's `range(of:options:.diacriticInsensitive)` is a no-op on the cross-compiled Foundation — implement the fallback (Step 4) and rebuild from Task 9.
- Tag detail: the ellipsis (Rename/Delete) still works; search filters the tagged subset; "No results" on a non-matching query; clearing restores.
- Playlist detail: the ellipsis (Rename/Delete) still works; with an empty query the drag handles show and reorder persists; with a non-empty query the drag handles disappear and the list is filtered; clearing restores the reorderable full list.
- Navigation: searching in All, then opening a tag/playlist, shows an unfiltered detail list (query reset on screen entry).

- [ ] **Step 4 (only if diacritic match failed): add a portable folding fallback in `ScoreSearch`**

Replace the matching body in `Packages/Domain/Sources/Domain/ScoreSearch.swift` with an explicit fold that does not rely on `CompareOptions.diacriticInsensitive`:

```swift
public enum ScoreSearch {
    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    public static func matches(title: String, composer: String?, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let needle = fold(trimmed)
        if fold(title).contains(needle) { return true }
        if let composer, fold(composer).contains(needle) { return true }
        return false
    }
}
```

Re-run Task 1 Step 4 (host tests stay green), then Task 9 (rebuild), then re-verify Step 3. If `folding` is also a no-op on Android, fall back to a manual Unicode decomposition + combining-mark strip in `fold` (NFD via `decomposedStringWithCanonicalMapping`, drop scalars in the combining-marks ranges, then `lowercased()`).

- [ ] **Step 5: Report verification results to the user** (screenshots or a written pass/fail per checklist item). Do not claim done until the diacritic case passes on-device.

---

## Self-Review Notes

- **Spec coverage:** shared Domain helper (Task 1) ✓; iOS refactor behavior-preserving (Task 2) ✓; Android bridge filtered observables + `setSearchQuery` (Task 3) ✓; three list contexts wired (Tasks 6/7/8) ✓; Android-idiom search row below TopAppBar, ellipsis preserved (Tasks 5–8) ✓; strings (Task 4) ✓; Domain + bridge + iOS tests (Tasks 1–3) ✓; Pixel install+launch incl. diacritic + fallback (Task 10) ✓.
- **Type consistency:** `setSearchQuery(_:)`, `searchFiltered(_:)`, backings `allScoreRows`/`selectedPlaylistRows`/`selectedTagRows`, `LibrarySearchField(query:onQueryChange:modifier:)`, strings `search_hint`/`search_no_results` are used consistently across tasks.
- **Risk:** Android diacritic folding is the one unknown; Task 10 verifies it on-device and Step 4 gives the concrete fallback.
- **Out of scope (unchanged):** Recently Deleted (no search), `values-ja` localization, match highlighting.

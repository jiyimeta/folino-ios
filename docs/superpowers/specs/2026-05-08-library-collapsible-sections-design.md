# Library — Collapsible Playlists / Tags Sections

Status: Draft (2026-05-08)
Owner: Kiichi
Module: `Packages/Features/Library`

## Goal

Pull Playlists and Tags up from one-level-deep list screens into collapsible sections on the Library root, so the user can see and reach them without an extra push. Collapse state persists across launches. As a paired cleanup, push Favorites one level deeper into the Browse section so the root stays focused on the most-used directories.

## Non-Goals

- Editing, reordering, deleting playlists / tags from the root sections (continues to live on the detail / list screens).
- New filtering, search, or smart-list behaviour on Playlists / Tags themselves.
- Touching the bulk-select feature, importer, share flow, or any non-Library module.
- Any change to the iPad sidebar layout (Folino's current Library renders as a single `NavigationStack`; this spec keeps that shape).

## Library Root — Final Layout

```
List
├ Section: Browse                    (always visible)
│   ├ All Scores                →    (existing route .allScores)
│   └ Favorites                 →    (NEW route .favorites; row hidden when zero favorites)
├ Section: Playlists [N]  ⌄          (NEW; collapsible; hidden when N == 0)
│   ├ Playlist row × min(5, N)       (recently-used order)
│   └ See All →                      (only when N > 5; pushes existing PlaylistsListScreen)
├ Section: Tags [N]  ⌄               (NEW; collapsible; hidden when N == 0)
│   ├ Tag row × min(5, N)            (recently-used order)
│   └ See All →                      (only when N > 5; pushes existing TagsListScreen)
└ Section: Recently Opened           (existing; hidden when zero)
```

The standalone Favorites section at root and the Browse rows for Tags / Playlists are removed. `ContentUnavailableView` for the all-empty Library is preserved (no scores AND no playlists AND no tags).

## Detailed Behaviour

### Sections

- `Section(isExpanded: $expanded)` is used for Playlists and Tags so the disclosure chevron is rendered by SwiftUI. (iOS 26+ target — fine.)
- Section header text is bold count-suffixed: `Playlists  12` / `Tags  12`. Use the existing localized strings; append the count as a trailing `Text(count, format: .number).foregroundStyle(.secondary)` inside the header `HStack`.
- Section body is rendered only when expanded. Nothing is rendered when the underlying collection is empty (the whole section is dropped).
- Every row in the Playlists / Tags sections is a `NavigationLink(value: …)` to the existing detail route — tap behaviour is unchanged from today's list screens.

### "Recently used" ordering

Top-N is **5**, matching the existing Favorites / Recently Opened limits.

`Packages/Features/Library/Sources/Library/LibrarySort.swift` (new) hosts pure helpers:

```swift
func playlistsByRecentlyUsed(
    _ playlists: [Playlist],
    scoreItems: [ScoreItem],
    limit: Int
) -> [Playlist]

func tagsByRecentlyUsed(
    _ tags: [Tag],
    scoreItems: [ScoreItem],
    limit: Int
) -> [Tag]
```

- **Playlist key:** max `lastOpenedAt` over `scoreItems` whose ID is in `orderedScoreItemIDs`. Missing IDs are skipped. If the playlist has no resolvable items, fall back to `playlist.createdAt`. Sort by key descending; tiebreak by `name` ascending.
- **Tag key:** max `lastOpenedAt` over `scoreItems` carrying that tag. If the tag has no items (or none with `lastOpenedAt`), fall back to `Date.distantPast` so it sinks below tagged-but-stale tags; tiebreak by `name` ascending.
- Helpers index `scoreItems` into a `[ScoreItemID: ScoreItem]` lookup once before iterating playlists / tags. Acceptable cost given Library scale (hundreds, not millions).

These helpers live inside the Library feature module — they are presentation policy, not domain truth. `ScoreItemSort.swift` already defines the parallel concept for ScoreItems.

### "See All" rows

- Shown only when `count > 5`.
- Pushes via the existing `LibraryRoute.playlists` / `LibraryRoute.tags` — no new route. The pushed screen is the existing `PlaylistsListScreen` / `TagsListScreen`, which retains its `+` toolbar (covered below).
- Row visual: `Image(systemName: "chevron.right")` style is provided by `NavigationLink` automatically; label reads "See All" (`.secondary` foregroundStyle to differentiate from data rows).

### Fold persistence

- LibraryRootScreen owns two `@AppStorage` keys, both default `true`:
  - `library.section.playlists.expanded`
  - `library.section.tags.expanded`
- When the underlying collection is empty the section is hidden, but the AppStorage value remains untouched — re-creating a playlist/tag respects the user's last collapse choice.

### Toolbar `+` Menu

The current trailing-bar `+` button (which opens the file importer) becomes a `Menu`:

```swift
Menu {
    Button {
        viewModel.isFileImporterPresented = true
    } label: { Label("Import Score", systemImage: "square.and.arrow.down") }

    Button {
        newPlaylistName = ""
        isCreatingPlaylist = true
    } label: { Label("New Playlist", systemImage: "music.note.list") }

    Button {
        newTagName = ""
        isCreatingTag = true
    } label: { Label("New Tag", systemImage: "tag") }
} label: {
    Image(systemName: "plus")
        .accessibilityLabel(Text("Add", bundle: .module))
}
```

- Two new local `@State` pairs (`isCreatingPlaylist` / `newPlaylistName`, `isCreatingTag` / `newTagName`) drive two name-entry alerts identical in shape to the alerts in today's `PlaylistsListView` / `TagsListView`.
- The "OK" button on each alert calls a new `LibraryViewModel` method (below).
- The existing `+` toolbars on `PlaylistsListScreen` / `TagsListScreen` stay in place — both entry points are intentionally retained per the user's request to keep See All a self-contained workspace.

### Favorites screen (new destination)

Favorites moves from a root section to a Browse row that pushes a full `ScoreListScreen` filtered to favorites.

- `LibraryRoute.favorites` — new case.
- `ScoreListViewModel.Source.favorites` — new case (`Source` is `Hashable, Sendable`; just adding a case).
- `ScoreListViewModel.scope(_:)` adds a branch: `case .favorites: return items.filter(\.isFavorite)`.
- `ScoreListViewModel.init` initialises `.favorites` with `sort = .dateAddedDesc`, `manualOrder = false` (same as `.all` / `.taggedWith`).
- A small wrapper screen `FavoritesScreen` (sibling of the existing private `AllScoresScreen` inside `LibraryRootScreen.swift`) hosts the `ScoreListViewModel` and sets `navigationTitle("Favorites")`.
- Browse row "Favorites" is hidden when the favourite count is zero (consistent with how the old Favorites section behaved — never showing an empty row at root).

The previous `favoritesSection(_:)` / `recentsSection(_:)` helpers in `LibraryRootScreen` are split: `favoritesSection` is deleted, `recentsSection` stays.

## ViewModel changes

### `LibraryViewModel`

Add two methods (asynchronous, error-routing through the existing `errorAlertMessage` / `describe(_:)` pipeline):

```swift
public func createPlaylist(name: String) async {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
        try await repository.savePlaylist(
            Playlist(name: trimmed, orderedScoreItemIDs: [], createdAt: Date())
        )
    } catch {
        errorAlertMessage = describe(error)
    }
}

public func createTag(name: String) async {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
        try await repository.saveTag(
            Tag(name: trimmed, colorHex: nil)
        )
    } catch {
        errorAlertMessage = describe(error)
    }
}
```

(Exact `Tag` / `Playlist` initialisers are whatever the existing `PlaylistsListScreen` / `TagsListScreen` already use — these are lifted, not invented.)

`PlaylistsListScreen.swift` / `TagsListScreen.swift` are updated to call these ViewModel methods from their existing `+` flow, removing the duplicated initialisers from those screens.

### `ScoreListViewModel`

`Source` adds `.favorites`. `scope` adds a `case .favorites` branch. `init` treats `.favorites` like `.all` / `.taggedWith` for sort defaults.

## Routing

`LibraryRoute` adds:

```swift
case favorites
```

`LibraryRootScreen.destination(for:)` adds the corresponding branch that constructs a `ScoreListViewModel(source: .favorites, repository:)` and renders `ScoreListScreen` with title "Favorites".

`LibraryRoute.tags` / `.playlists` are unchanged.

## File map

- **Edit:** `LibraryRootScreen.swift`, `LibraryViewModel.swift`, `LibraryRoute.swift`, `ScoreListViewModel.swift`, `PlaylistsListScreen.swift` (route create-playlist call to ViewModel), `TagsListScreen.swift` (same for tags).
- **New:** `LibrarySort.swift`, `LibrarySortTests.swift` (under `Packages/Features/Library/Tests/LibraryTests/`).
- **Localizable.xcstrings (`Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings`):** add keys "New Playlist" (button + alert title) / "New Tag" (button + alert title) / "Favorites" (Browse row label and screen title) / "See All" / "Add" if not already present. Re-use existing copy where possible.
- **Untouched:** Domain protocols, Infrastructure adapters, App composition, `module-architecture.md`. No new SwiftPM targets.

## Testing

### `LibrarySortTests` (Swift Testing, new)

- `playlistsByRecentlyUsed` orders by max contained-item `lastOpenedAt` desc.
- Empty playlist falls back to `createdAt`.
- Playlist whose `orderedScoreItemIDs` reference deleted IDs is treated as if those IDs are absent (no crash, falls back to remaining items / `createdAt`).
- Limit truncates the result.
- `tagsByRecentlyUsed` orders by max tagged-item `lastOpenedAt` desc.
- Tag with zero tagged items sinks to the bottom and tiebreaks by `name` asc.

### Manual / preview verification

- Open `Packages/Features/Library/Package.swift` in Xcode. Drive a `LibraryRootScreen` preview seeded with playlists / tags / scores; verify:
  - Sections collapse and expand; state survives a preview restart (AppStorage backs the same UserDefaults).
  - "See All" row appears only when count > 5.
  - Toolbar `+` Menu shows three options; each works.
  - Favorites Browse row hides when no favorites exist; pushes to a sortable list when present.
- Build the app to a simulator (`xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`) and smoke-test the flow once.

### Existing tests

- Library feature tests using fakes (if any depend on `LibraryRoute` cases or root layout) are updated to match the new route enum / structure. Run `swift test` inside `Packages/Features/Library`.

## Risks & open questions

- **Empty state during onboarding.** A first-launch user sees only `ContentUnavailableView` until they import. The Browse section appears immediately after the first import; the Playlists / Tags sections only appear after the first creation. This mirrors today's behaviour (no regressions).
- **AppStorage key naming.** `library.section.<x>.expanded` is unscoped to user identity, which is fine — fold preference is device-local UI state, not user data, and CloudKit sync of a UI toggle is unjustified.
- **Two creation entry points for Playlists / Tags** (root toolbar Menu + See All screen `+`) is intentional, per the user's requirement that both stay reachable. We accept the small duplication.
- **Sort cost.** `tagsByRecentlyUsed` is O(scores × tags-per-score) for the lookup phase. With Library-scale data this is negligible; revisit only if profiling on a synthetic large library shows it dominates root-render cost.

## Out of scope (future)

- Drag-to-reorder playlists / tags within their root sections.
- "Pinned" playlists or tags (manual override of recency).
- Sidebar adoption on iPad (`NavigationSplitView`).

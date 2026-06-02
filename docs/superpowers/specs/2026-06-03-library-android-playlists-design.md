# Library Android — Playlists

**Date:** 2026-06-03
**Status:** Design (approved for plan)
**Predecessors:** `2026-06-01-library-android-pilot-design.md`, `2026-06-02-library-android-persistence-design.md`, `2026-06-02-library-android-recently-deleted-design.md`

## Summary

Port the iOS Library **Playlists** feature to Android, on top of the existing
Android Library foundation (Swift `LibraryAndroidStore` + Kotlin/Room backend +
Compose UI + `@WireletObservable`/`@WireletProvided` JNI bridges). A playlist is
a **manually ordered** sequence of scores (iOS `Playlist.orderedScoreItemIDs`).

Per the project parity rule (logic → iOS parity & shared; UI placement → Android
idioms), all ordering / membership / projection **logic** lives in shared Swift
(Domain helpers, called by both the iOS `LibraryViewModel` and the Android
`LibraryAndroidStore`); Kotlin/Room remains a rule-free persistence backend with
the **same join-table representation** iOS uses (`playlists` +
`playlist_items(position)`); Compose follows Android idioms (drawer destination,
FAB to create, drag-handle reorder, long-press CAB bulk selection).

## Goals

- All Scores parity for organizing scores into manual playlists, end to end:
  create, rename, delete, add (single + bulk), remove, **drag-to-reorder**, view
  ordered contents, open a score.
- Logic shared with iOS (no divergent reimplementation), persistence semantics
  identical to iOS (position-column join table, drop-and-reinsert on save).
- Device-validated on Pixel 8a (install + launch; manual gestures by the user).

## Non-Goals

- Tags, Favorites, Search, Sort, Share/Export, Edit Info — separate phases.
- iOS `LibraryRoot` hub layout and **recently-used ranking** of playlists
  (`LibrarySort.swift`) — that ranking is hub-only; Android uses a drawer +
  name-sorted dedicated lists, matching the dedicated iOS `PlaylistsListScreen`
  (which sorts by name, not recency).
- Smart playlists (iOS defers these to v1.x as well).
- Bulk share / bulk edit-tags actions that iOS exposes inside `PlaylistDetail`
  (both depend on features not yet on Android).

## Bridge constraints (verified against swift-wirelet v0.3.2)

These shape the API and were confirmed in the library source:

1. **`@WireletExpose` methods return `Void` only** (Kotlin→Swift). Detail/list
   data therefore flows through **observable `StateFlow` properties**, never a
   synchronous getter.
2. **`@WireFormat` structs cannot have a `[String]` field** (primitive arrays
   unsupported as fields). So `orderedScoreItemIDs` is never carried inside a
   wire struct — it is represented as **flat `PlaylistItemWire` rows** with a
   `position: Int32`.
3. **`@WireletExpose` method *arguments* may be `[String]`** (v0.3.2) and
   `@WireFormat` / `[@WireFormat]`. Reorder passes the final order as
   `[String]`.
4. **`@WireletProvided` backend methods may return values** (existing
   `loadAll() -> [ScoreRecordWire]`), including `[@WireFormat]`, and accept
   `[@WireFormat]` arguments.
5. **Observable props** support primitives, `String`, `@WireFormat`,
   `[@WireFormat]`, and optionals — but **not** `[String]`. Lists of playlists /
   items are therefore arrays of `@WireFormat` row structs.

## Persistence model (matches iOS)

iOS (`LiveScoreLibraryRepository`, GRDB) uses a normalized join table:

- `playlists(id, name, created_at)`
- `playlist_items(playlist_id, score_item_id, position)` — order is the
  `position` column.
- **Load:** fetch `playlist_items` ordered by `(playlist_id, position)`, group
  per playlist into `orderedScoreItemIDs`.
- **Save** (`savePlaylist`): upsert the `playlists` row, then **delete all
  `playlist_items` for that playlist and reinsert with `position` from
  `orderedScoreItemIDs.enumerated()`** (membership rewritten wholesale).

Android mirrors this exactly in Room (representation adapted to Room idioms, as
the pilot adapted `deletedAt: Date?` → `Double` sentinel; semantics identical):

- Room `playlists(id PK, name, created_at REAL)`
- Room `playlist_items(playlist_id, score_item_id, position)`, indexed on
  `playlist_id`; rows for a playlist removed on delete (cascade or explicit).
- DB **version 1 → 2** with a `Migration(1, 2)` that `CREATE`s the two new
  tables. `score_records` is untouched (imported scores must survive).
  `fallbackToDestructiveMigration` is **not** used.

## Shared Domain logic (parity)

The iOS playlist mutation/projection logic is currently inlined across
`LibraryViewModel`, `AddToPlaylistScreen`, `PlaylistDetailScreen`, and
`PlaylistsListScreen`. Lift the pure pieces into **Domain** (Foundation-only),
following the `ScorePresentation` precedent (already shared by the iOS importer
and the Android store):

```swift
extension Playlist {
    /// Append IDs not already present, preserving order. (iOS single add + bulkAddToPlaylist)
    mutating func appendingUnique(_ ids: [ScoreItemID])
    /// Append if absent, remove if present. (iOS AddToPlaylistScreen.toggle)
    mutating func toggleMembership(_ id: ScoreItemID)
    /// Remove the given IDs. (iOS removeFromPlaylist / bulkRemoveFromPlaylist)
    mutating func removing(_ ids: Set<ScoreItemID>)
}

enum PlaylistPresentation {
    /// orderedScoreItemIDs filtered to live IDs, order preserved. (iOS PlaylistDetail.orderedItems)
    static func orderedLiveIDs(_ playlist: Playlist, liveIDs: Set<ScoreItemID>) -> [ScoreItemID]
    /// Count of live members. (iOS PlaylistsListScreen / LibraryRootCollapsibleSections)
    static func liveMemberCount(_ playlist: Playlist, liveIDs: Set<ScoreItemID>) -> Int
}
```

- **iOS refactor:** replace the inline array operations at the sites above with
  these helpers. Pure value-type unit tests cover them. This is an iOS-side
  change scoped to the Library feature (no Domain *protocol* change, no
  cross-feature ripple).
- **Android:** `LibraryAndroidStore` builds `Playlist` Domain values from the
  backend's `PlaylistRecordWire` + ordered `PlaylistItemWire` rows and calls the
  **same** helpers. The wire boundary stays `String`; only the store internals
  use Domain types (`PlaylistID`/`ScoreItemID` via `UUID(uuidString:)`).
- **Reorder** needs no shared helper: the Compose reorderable list yields the
  final ordered list, and both platforms simply persist that order.
- **Name sort** (`localizedStandardCompare`) stays at each call site (one-liner,
  shared by tags too); optionally a small `Playlist` name comparator later.

## Wire types

Display / interaction projections (new):

```swift
@WireFormat struct PlaylistRowWire  { var id: String; var name: String; var memberCount: Int32 }
@WireFormat struct PlaylistPickWire { var id: String; var name: String; var contains: Bool }
```

Persistence projections (new, backend protocol):

```swift
@WireFormat struct PlaylistRecordWire { var id: String; var name: String; var createdAt: Double }
@WireFormat struct PlaylistItemWire   { var playlistId: String; var scoreItemId: String; var position: Int32 }
```

Score rows reuse the existing `ScoreRowWire`.

## Swift `LibraryAndroidStore` surface (additions)

Observable (`StateFlow`) properties:

- `playlists: [PlaylistRowWire]` — name-sorted; `memberCount` via
  `PlaylistPresentation.liveMemberCount` (live = `deletedAt <= 0` and present).
- `selectedPlaylistItems: [ScoreRowWire]` — ordered live items of the currently
  selected playlist (for the detail screen).
- `addSheetPlaylists: [PlaylistPickWire]` — playlists for the Add-to-playlist
  sheet, with `contains` set for the focused score (single) or `false` (bulk).

`@WireletExpose` methods (all `Void`):

- `selectPlaylist(_ id: String)` — recompute `selectedPlaylistItems`.
- `createPlaylist(_ name: String)` — trims; ignores empty (iOS parity).
- `renamePlaylist(_ id: String, _ name: String)`
- `deletePlaylist(_ id: String)`
- `addToPlaylist(_ scoreId: String, _ playlistId: String)` — `appendingUnique`.
- `removeFromPlaylist(_ scoreId: String, _ playlistId: String)` — `removing`.
- `setPlaylistOrder(_ playlistId: String, _ orderedIds: [String])` — reorder.
- `bulkAddToPlaylist(_ playlistId: String, _ scoreIds: [String])` —
  `appendingUnique` (de-duped append; iOS parity).
- `createPlaylistWithScores(_ name: String, _ scoreIds: [String])` — sheet's
  "New playlist" (single or bulk).
- `deleteMany(_ ids: [String])` — bulk soft-delete for the All Scores CAB
  "Delete" action (iOS `bulkDelete` parity); symmetric with the existing
  `restoreMany` / `permanentlyDeleteMany`, one reload at the end.
- `beginAddToPlaylist(_ scoreId: String)` / `beginBulkAddToPlaylist()` — build
  `addSheetPlaylists`.

After any mutation the store reassigns `playlists` (and `selectedPlaylistItems`
/ `addSheetPlaylists` as relevant), reusing a single backend snapshot where
possible (the established `reload(using:)` pattern). Persistence goes through
the backend's `upsertPlaylist` + `replacePlaylistItems` (positions assigned from
the ordered array) and `deletePlaylist`, matching iOS's drop-and-reinsert.

Soft-deleted scores drop out of `selectedPlaylistItems` and `memberCount` but
remain in `playlist_items`; restoring the score brings it back (iOS compactMap
projection parity — no proactive purge of IDs).

## Kotlin backend (`LibraryStore` protocol + `RoomLibraryStore`) additions

```swift
@WireletProvided protocol LibraryStore {
    // ... existing score methods ...
    func loadPlaylists() -> [PlaylistRecordWire]
    func loadPlaylistItems() -> [PlaylistItemWire]            // ordered by (playlist_id, position)
    func upsertPlaylist(_ record: PlaylistRecordWire)
    func replacePlaylistItems(_ playlistId: String, _ items: [PlaylistItemWire])  // drop + reinsert
    func deletePlaylist(id: String)                          // also removes its playlist_items
}
```

Kotlin `RoomLibraryStore` implements these against the two new tables. It stays
rule-free: it persists exactly the rows / positions Swift computes and makes no
ordering or membership decisions.

## Compose UI (Android idioms)

- **Navigation drawer** (`MainActivity.kt`): add a "Playlists" destination
  (route `"playlists"`, e.g. `Icons.AutoMirrored.Filled.QueueMusic`); add it to
  `drawerCapable`.
- **PlaylistsListScreen.kt** (new): observes `playlists`; hamburger top bar; FAB
  `+` opens a create-name dialog (`createPlaylist`); each row shows name + "N
  scores", taps into detail (passing `id` + `name` as nav args); delete via row
  overflow → confirm dialog (`deletePlaylist`). Empty state.
- **PlaylistDetailScreen.kt** (new): `LaunchedEffect(id)` calls
  `selectPlaylist(id)` and observes `selectedPlaylistItems`. Top bar: back arrow,
  playlist name, overflow (Rename → dialog; Delete → confirm → pop). Body: a
  `sh.calvin.reorderable` `LazyColumn` with a **drag handle** per row; drag end
  commits via `setPlaylistOrder(id, newOrder)`. Row tap → Reader stub; remove
  from playlist via swipe or row overflow (`removeFromPlaylist`). Empty state.
- **AddToPlaylistSheet.kt** (new, `ModalBottomSheet`), shared by single + bulk:
  - Single: opened from an All Scores row overflow ("Add to playlist") after
    `beginAddToPlaylist(scoreId)`; lists `addSheetPlaylists` with checkboxes
    reflecting `contains`; toggling calls `addToPlaylist` / `removeFromPlaylist`
    (iOS toggle parity). "New playlist" → `createPlaylistWithScores(name, [id])`.
  - Bulk: opened from the CAB "Add to playlist" after `beginBulkAddToPlaylist()`;
    tap a playlist → `bulkAddToPlaylist(id, selectedIds)` and dismiss. "New
    playlist" → `createPlaylistWithScores(name, selectedIds)`.
- **All Scores (LibraryScreen.kt)** enhancements:
  - Per-row overflow (`MoreVert`) with "Add to playlist".
  - **Bulk selection mode**: long-press → CAB, same structure as
    `RecentlyDeletedScreen` (count title, close to exit, selection checkmarks).
    CAB actions: "Add to playlist" (bulk sheet) and "Delete" (existing
    soft-delete, applied across the selection). Swipe-to-delete + Undo remains
    for the non-selection state.

## Testing

Host tests (`FOLINO_ANDROID=1 xcrun swift test --filter LibraryAndroidStoreTests`)
extended with a playlists-capable fake `LibraryStore`:

- create / rename / delete; add / remove (single); `bulkAddToPlaylist` de-dupes;
  `setPlaylistOrder` reflects new order; `createPlaylistWithScores`.
- `selectedPlaylistItems` ordering + exclusion of soft-deleted scores;
  `memberCount` excludes soft-deleted; restore re-includes.
- Domain helpers (`appendingUnique`, `toggleMembership`, `removing`,
  `PlaylistPresentation.*`) get pure value-type unit tests in `DomainTests`, and
  the iOS `LibraryViewModel` tests continue to pass after the refactor.

## Build / dependency / parity notes

- Add `sh.calvin.reorderable` (Apache-2.0; not GPL — satisfies the no-GPL
  constraint) to the Android app `build.gradle.kts`. No `project.yml` change
  (that file governs SwiftPM/Xcode only).
- swift-wirelet stays at v0.3.2 (no new wirelet capability needed; `[String]`
  args and `[@WireFormat]` props/returns already exist).
- After Android changes: cross-compile (codegen → compile, verify JNI_OnLoad) →
  `:app:installDebug` → `adb shell am start -n com.keynumber.folino/.MainActivity`
  on the Pixel 8a; real reorder/selection gestures verified by the user.
- Fresh worktrees: run `Scripts/android-build-libs.sh` before `installDebug`
  (Settings jextract bindings), per the toolchain notes.

## Risks / open questions

- **Room migration correctness:** the 1→2 migration must preserve existing
  `score_records`. Covered by an instrumented or host check that an upgraded DB
  keeps imported scores and gains empty playlist tables.
- **Android store internals adopting Domain types:** requires `Domain` to expose
  the `Playlist` initializer paths the store needs; `LibraryAndroidStore` already
  imports `Domain`, so no new dependency edge.
- **iOS refactor blast radius:** lifting the inline ops touches four Library
  files; keep each substitution behavior-preserving and lean on existing
  `LibraryViewModel` / `ScoreListViewModel` tests plus the new Domain unit tests.
- **`replacePlaylistItems` write volume:** mirrors iOS's wholesale rewrite;
  acceptable at pilot list sizes (`allowMainThreadQueries()` already accepted).
</content>
</invoke>

# Library Tags — Android Port Design

**Date:** 2026-06-03
**Status:** Approved (design)
**Scope:** Port the iOS Library *tag* feature to Android at full parity, following the established swift-wirelet bridge + Kotlin/Room/Compose pattern used for Playlists and Recently Deleted.

## Goal

Bring the Library tag feature to Android with the same *content* as iOS:

- A **Tags list** (create, rename, delete; shows live member count per tag).
- A **Tag detail** screen (the scores tagged with a given tag; rename/delete the tag).
- **Single-score tag editing** (toggle tags on/off for one score; create a tag inline).
- **Bulk tag assignment** from multi-select (union-add a set of tags to a set of scores).

UI *placement* follows Android idioms (drawer destination, FAB for create, CAB for bulk), not the iOS sidebar layout.

## Non-goals

- **No color picker.** iOS tag creation takes only a name (`onCreate: (String) -> Void`); the color defaults to `#5856D6` and the list tints all tag icons uniformly rather than per-tag. Android matches this — `colorHex` flows through the wire types and is stored, but no picker UI is built. (A picker can be added later on both platforms together if desired.)
- **No Library-root "Tags" section.** iOS shows a top-5-recently-used collapsible section in the Library root sidebar. Android navigation is drawer-based; like the Playlists port, tags are reached only through a drawer destination. The `tagsByRecentlyUsed` sorting helper is iOS-only and is not ported.
- No CloudSync / cross-device concerns beyond what local persistence already covers.

## Source-of-truth references (iOS)

- Domain model: `Packages/Domain/Sources/Domain/Models/Tag.swift` — `Tag(id: TagID, name: String, colorHex: String)`.
- Membership: `Packages/Domain/Sources/Domain/Models/ScoreItem.swift` — `ScoreItem.tagIDs: Set<TagID>`.
- Repository: `Packages/Domain/Sources/Domain/Protocols/ScoreLibraryRepository.swift` — `saveTag(_:)`, `deleteTag(id:)`.
- Persistence schema: `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift` — `tags` table + `score_item_tags` junction.
- UI semantics being mirrored:
  - `Packages/Features/Library/Sources/Library/Views/TagsListView.swift` (list, create, swipe-delete, member count).
  - `Packages/Features/Library/Sources/Library/Views/EditTagsSheet.swift` (single-score toggle + inline create).
  - `BulkEditTagsSheet.swift` / `LibraryViewModel.bulkAddTags(_:tagIDs:)` (union-add semantics).
  - `LibraryViewModel.createTag(name:)` — default color `#5856D6`.

## Android pattern references (already shipped)

- Swift bridge store: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`.
- Provided backend protocol: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift`.
- Existing membership pattern: Playlists (`PlaylistRowWire`, `PlaylistItemWire`, `PlaylistPickWire`, `loadPlaylistItems`/`replacePlaylistItems`, `addSheetPlaylists` with a `contains` flag).
- Kotlin backend: `Android/FolinoLibraryAndroid/src/main/kotlin/.../RoomLibraryStore.kt` (currently DB v2, `MIGRATION_1_2`).
- Compose screens: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/{PlaylistsListScreen,PlaylistDetailScreen,AddToPlaylistSheet}.kt`.
- Navigation: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` (`LibraryNavGraph`, drawer).
- Build: `Scripts/android-build-library-libs.sh`.

## Architecture

Identical layering to Playlists: **all logic in Swift, Kotlin is a rule-free Room backend.**

```
Swift Domain (Tag, TagID, ScoreItem.tagIDs)
      │
LibraryAndroidStore (@WireletObservable)  ── all tag logic: CRUD, membership, member count, projection
      │  observable: tags, selectedTagItems, editSheetTags
      │  @WireletExpose: createTag / renameTag / deleteTag / selectTag /
      │                  beginEditTags / setTagAssigned / bulkAddTags
      ▼
LibraryStore (@WireletProvided)  ── rule-free: loadTags/upsertTag/deleteTag, loadTagItems/replaceTagItems
      ▼
RoomLibraryStore (Kotlin)  ── tags + tag_items tables, DB v2 → v3 migration
      ▼
Compose UI  ── TagsListScreen, TagDetailScreen, EditTagsSheet, bulk via All-Scores CAB
```

### Membership representation — join table

Mirror iOS Infrastructure's `score_item_tags` and the Android Playlists pattern. Tags differ from playlists in two ways: **unordered** (no `position` column) and **bulk-add is union** (never removes existing assignments).

- `tags` table: `id TEXT PK, name TEXT, color_hex TEXT`.
- `tag_items` table: `tag_id TEXT, score_item_id TEXT`, composite PK `(tag_id, score_item_id)`. Index on `tag_id` (and `score_item_id` for the per-score edit lookup).

The Swift store reconstructs membership from `loadTagItems()` the same way `loadDomainPlaylists()` reconstructs playlist membership, and persists with `replaceTagItems(tagId, items)` (drop + reinsert, mirroring `replacePlaylistItems`).

## Swift changes (`Packages/Features/Library/Sources/FolinoLibraryJNI/`)

### New `@WireFormat` wire types

```swift
@WireFormat
public struct TagRowWire: Equatable, Sendable {   // Tags list row
    public var id: String          // TagID UUID string
    public var name: String
    public var colorHex: String    // "#RRGGBB"; default "#5856D6"
    public var memberCount: Int32  // live (non-deleted) scores carrying this tag
}

@WireFormat
public struct TagRecordWire: Equatable, Sendable {  // persistence projection
    public var id: String
    public var name: String
    public var colorHex: String
}

@WireFormat
public struct TagItemWire: Equatable, Sendable {     // membership row
    public var tagId: String
    public var scoreItemId: String
}

@WireFormat
public struct TagPickWire: Equatable, Sendable {     // edit-tags sheet row
    public var id: String
    public var name: String
    public var contains: Bool       // is this tag currently on the focused score?
}
```

### `LibraryStore` protocol additions (Kotlin-implemented)

```swift
func loadTags() -> [TagRecordWire]
func upsertTag(_ record: TagRecordWire)
func deleteTag(id: String)                              // also drops its tag_items rows
func loadTagItems() -> [TagItemWire]                    // all membership rows
func replaceTagItems(_ tagId: String, _ items: [TagItemWire])  // drop + reinsert for one tag
```

### `LibraryAndroidStore` additions

Observable properties (reassigned wholesale, StateFlow path):

```swift
public var tags: [TagRowWire] = []
public var selectedTagItems: [ScoreRowWire] = []
public var editSheetTags: [TagPickWire] = []
```

`@WireletExpose` methods:

| Method | Semantics (iOS parity) |
| --- | --- |
| `createTag(_ name: String)` | Trim; ignore empty. New `Tag` with `colorHex = "#5856D6"`; upsert; `reloadTags()`. |
| `renameTag(_ id: String, _ name: String)` | Trim; ignore empty; upsert renamed tag. |
| `deleteTag(_ id: String)` | `store.deleteTag(id:)` (drops membership too); clear selection if it was selected; reload. |
| `selectTag(_ id: String)` | Set `selectedTagID`; recompute `selectedTagItems`. |
| `beginEditTags(_ scoreId: String)` | Set focused score; refresh `editSheetTags` with `contains` flags. |
| `setTagAssigned(_ scoreId, _ tagId, _ assigned: Bool)` | Toggle one membership; `replaceTagItems` for that tag; reload. |
| `bulkAddTags(_ tagIds: [String], _ scoreIds: [String])` | Union-add each tag to each score (never removes); reload. |

Internal helpers mirror the Playlists block: `reloadTags()` rebuilds `tags` (sorted by name, with live member count), recomputes `selectedTagItems` and `editSheetTags` from one backend snapshot. Member count = number of live (`deletedAt <= 0`) score IDs in the tag's membership set — a trivial set intersection computed inline in Swift (no Domain helper needed; YAGNI). `reloadTags()` is also called from the existing delete/restore/purge paths (alongside `reloadPlaylists()`) so member counts stay correct when scores are soft-deleted or purged.

## Kotlin changes (`Android/FolinoLibraryAndroid/`)

`RoomLibraryStore.kt`:

```kotlin
@Entity(tableName = "tags")
data class TagEntity(
    @PrimaryKey val id: String,
    val name: String,
    @ColumnInfo(name = "color_hex") val colorHex: String,
)

@Entity(tableName = "tag_items", primaryKeys = ["tag_id", "score_item_id"],
        indices = [Index("tag_id"), Index("score_item_id")])
data class TagItemEntity(
    @ColumnInfo(name = "tag_id") val tagId: String,
    @ColumnInfo(name = "score_item_id") val scoreItemId: String,
)
```

- `TagDao` with: load all tags, upsert, delete by id (+ delete its tag_items), load all tag_items, delete tag_items by tag_id, insert tag_items.
- `LibraryDatabase` bumped to **version 3** with `MIGRATION_2_3` creating `tags` and `tag_items` (+ indices). No change to existing tables.
- `RoomLibraryStore` implements the new `LibraryStore` methods. `deleteTag(id)` deletes the tag row and its membership in a single transaction. `replaceTagItems(tagId, items)` deletes that tag's rows then inserts the new set, in a transaction.

## Compose UI (`Android/app/src/main/kotlin/com/keynumber/folino/ui/library/`)

- **`TagsListScreen.kt`** (new) — modeled on `PlaylistsListScreen`. FAB → create-tag dialog (name only). Each row: tag name + member count, tap → detail, overflow/swipe → delete (with confirm). Empty state.
- **`TagDetailScreen.kt`** (new) — modeled on `PlaylistDetailScreen`. Lists `selectedTagItems`; top-bar actions for rename (dialog) and delete (confirm → pop back). Tapping a score opens the Reader. (No drag-reorder — tags are unordered.)
- **`EditTagsSheet.kt`** (new) — modeled on `AddToPlaylistSheet`. Bound to `editSheetTags`; checkbox/toggle list calling `setTagAssigned`; inline create row. Used from the score row's overflow menu ("Edit tags").
- **Bulk** — extend the existing All-Scores selection CAB with a "Tag" action that presents a tag-pick sheet (multi-select tags) and calls `bulkAddTags(tagIds, scoreIds)` (union-add). Reuses the CAB scaffolding added for the Playlists bulk action.
- **`MainActivity.kt`** — add a drawer item "Tags"; add routes `tags` (→ `TagsListScreen`) and `tag/{id}/{name}` (→ `TagDetailScreen`, calling `selectTag(id)` on entry). Wording per Android idiom.

## Localization

- iOS string keys live under the Library module's catalog (`library.tags`, `library.tags.empty.*`, `library.tag.create.placeholder`, `library.tags.editScore.title`, `library.tag.delete.message`). Android Compose copy uses its own string resources; keep wording at content parity with iOS (English source; the brand stays lowercase `folino` if it ever appears).

## Testing & verification

- **Swift store logic** — unit tests against a fake `LibraryStore` (in-memory), mirroring the existing Playlists store tests: create/rename/delete tag, toggle membership, bulk union-add, member-count excludes soft-deleted scores, `deleteTag` cascades membership.
- **Build** — `Scripts/android-build-library-libs.sh` rebuilds `FolinoLibraryJNI` for Android; wirelet codegen regenerates the ViewModel + codecs for the new wire types and exposed methods.
- **On-device** — `installDebug` + `adb` launch on Pixel; verify: create/rename/delete a tag, assign/unassign on a single score, bulk-tag from CAB, member counts, and the **Room v2 → v3 migration** on an existing install (no data loss, tags tables created).
- iOS is untouched; existing iOS Library tests must still pass (no Domain protocol signature changes — `Tag` and `ScoreItem.tagIDs` already exist).

## Risks / notes

- **Migration on upgrade** — must test v2 → v3 against a populated DB, not just a fresh install (memory of the Playlists 1→2 verification applies here).
- **Wire codegen for `[String]` args** — `bulkAddTags(_ tagIds: [String], _ scoreIds: [String])` and the `replaceTagItems(_:_:)` list arg rely on the swift-wirelet `[String]` / list-arg support already pinned (v0.3.2 / multi-arg invoke fix). Confirm the pinned wirelet revision covers two list args in one exposed method; if not, fall back to per-tag granularity (`bulkAddTag(tagId, scoreIds)`) called in a Kotlin loop.
- **Empty/whitespace names** — trimmed and ignored in Swift, matching iOS.

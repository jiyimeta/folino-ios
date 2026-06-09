# Favorites — Android port + bulk favorite (iOS & Android)

Date: 2026-06-09
Status: Approved design, pre-implementation

## Goal

Bring the Favorites feature to Android at parity with iOS, and add a new
"bulk favorite" capability to both platforms' multi-select modes.

iOS already ships single-score favoriting (small star indicator on a row,
leading swipe, overflow-menu toggle, a conditional `Favorites` browse entry,
and a `FavoritesScreen`). Android has none of it. This spec ports the feature
to Android using Android-idiomatic placement, and — per the user's request —
extends both platforms with a bulk favorite action driven from the existing
selection mode.

## Non-goals

- Per-score favorite ordering / "favorited at" timestamps. Favorites stay a
  plain boolean; the Favorites list reuses the library's existing sort.
- Sync changes. `isFavorite` already round-trips through GRDB on iOS; Android
  persists locally via Room. No CloudKit/sync work here.
- Reworking the iOS single-favorite UI (swipe / star indicator / Favorites
  screen). Those stay exactly as they are.

## Platform parity rules applied

- **Logic / data → match iOS, share the code.** The favorite flag, its
  persistence semantics, the toggle operation, and the favorites filter all
  behave identically on both platforms and are expressed once in shared
  Swift (Domain + the JNI store), not reimplemented in Kotlin.
- **UI placement → Android idioms.** Android uses a tappable star toggle on
  the row and an always-visible drawer entry rather than mirroring iOS's
  leading-swipe + conditional browse section.

## Data model & persistence

### iOS — no change

- `Packages/Domain/Sources/Domain/Models/ScoreItem.swift` already has
  `isFavorite: Bool`.
- `Packages/Infrastructure/Sources/Persistence/Records/ScoreItemRecord.swift`
  already maps it to the `is_favorite` column (created in GRDB migration v1).

### Android — collapse to a fresh v1 schema (pre-release)

Android has not shipped its first release, so we are free to destroy existing
(dev-only) databases and we do **not** want to carry migration history. Rather
than adding a `MIGRATION_3_4`, collapse the whole schema back to a single v1:

- Add `@ColumnInfo("is_favorite") val isFavorite: Boolean` (default `false`)
  to `ScoreRecordEntity` in
  `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt`.
- **Reset `@Database(..., version = 1)`.** The v1 schema is whatever Room
  derives from the current entity set — which already includes playlists,
  playlist_items, tags, tag_items, and now `score_records.is_favorite`. There
  is no separate hand-written CREATE for the new column; the entity defines it.
- **Delete the migration objects** `MIGRATION_1_2` and `MIGRATION_2_3` and
  remove the `.addMigrations(...)` call entirely. No `MIGRATION_3_4` is added.
- **Add `.fallbackToDestructiveMigration()`** so any existing dev install
  (currently at DB version 3) is wiped and rebuilt at v1 cleanly instead of
  crashing on the version downgrade. This is acceptable precisely because the
  app is pre-release.
- iOS persistence is untouched — this collapse is Android-Room-only and does
  not affect the iOS GRDB schema or its migration history.

## Shared logic & wirelet bridge

The bridge already carries scores between the iOS-resident store and the
Kotlin UI. Favorites adds one field to two wire projections and one (overloaded)
mutation:

- `ScoreRecordWire` (persistence projection) — add `isFavorite: Bool`.
- `ScoreRowWire` (display projection) — add `isFavorite: Bool` so the row can
  render the star and the CAB can decide add-vs-remove.
- `LibraryStore` (`@WireletProvided` contract) — add:
  - `setFavorite(id: String, isFavorite: Bool)` — single toggle target.
  - `setFavorite(ids: [String], isFavorite: Bool)` — bulk apply.
- `LibraryAndroidStore` (`@WireletObservable` / `@WireletExpose`
  implementation) — implement both by reusing the existing iOS favorite path
  (load record(s), set `isFavorite`, `save`). No new business rule is written
  in Kotlin.

### Favorites filter — shared Domain helper

Mirror how `ScoreSearch` was lifted into shared Domain: the
"keep only favorites" predicate lives in one shared Swift helper that both the
iOS `ScoreListViewModel(source: .favorites)` path and the Android favorites
list call, so the two platforms cannot drift. (iOS already filters with
`items.filter(\.isFavorite)`; this codifies that as the shared definition.)

## Android UI

### Row toggle affordance

- Each score row shows a trailing **star icon**: `Icons.Filled.Star` when
  favorited, `Icons.Outlined.StarBorder` when not. Tapping it toggles via
  `setFavorite(id:isFavorite:)`.
- The row overflow (`⋮`) menu also gets an **Add to favorites / Remove from
  favorites** item (label switches on current state), matching how tag /
  playlist membership is offered there.
- **No swipe-to-favorite.** Swipe in Material is conventionally for
  dismiss/archive; a reversible favorite toggle is not an idiomatic swipe
  action, so it is omitted.

### FavoritesListScreen (new)

- New `FavoritesListScreen.kt` under
  `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/`, following the
  `TagsListScreen` / playlist-detail list pattern.
- Shows the favorites-filtered list (shared helper). Rows support the same
  tap-to-open, star toggle, overflow menu, and multi-select CAB as the main
  library list.
- Empty state when no favorites exist (drawer entry is always visible — see
  below — so the empty case is reachable).

### Drawer entry

- Add a **Favorites** item to the navigation drawer in
  `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`, using a
  star icon.
- **Always visible** (per decision), placed directly under **All Scores**,
  above Playlists.
- Register a `composable("favorites")` route and include `"favorites"` in the
  `drawerCapable` set so the drawer is reachable from the screen.

### CAB — bulk favorite

- Add a **Favorite** action to the existing multi-select contextual action bar
  (the one already used for bulk delete / tagging).
- Decision rule: if **every** selected row is already favorited, the action
  **removes** favorite from all; otherwise (none or mixed) it **adds** favorite
  to all. The action calls `setFavorite(ids:isFavorite:)` once.

## iOS UI — bulk favorite (new)

- Add a **Favorite** action to the existing iOS selection/edit mode toolbar
  (the same multi-select surface that already supports bulk delete / add to
  playlist / tag).
- Same add-vs-remove decision rule as Android (all-favorited → remove,
  otherwise → add), applied over the selection via the shared favorite path.
- Single-score favoriting, the star indicator, the leading swipe, and
  `FavoritesScreen` are unchanged.

## Localization

- **Android** `strings.xml`: `nav_favorites`, `favorites_title`,
  `favorites_empty`, `action_add_favorite`, `action_remove_favorite`,
  `action_favorite_bulk` (and a remove-bulk variant if the CAB label switches).
- **iOS**: add the bulk-favorite action key(s) to the `Library` package
  xcstrings, reusing the existing `library.score.favorite.action` /
  `library.score.unfavorite.action` naming scheme for the bulk variant.

## Testing

- **Android store**: `setFavorite` single + bulk persists; favorites filter
  returns only favorited scores; a freshly created v1 DB has the
  `is_favorite` column and defaults new scores to not-favorited. (No migration
  test — there is no migration to test; destructive fallback wipes any older
  dev DB.)
- **iOS**: bulk favorite over a selection toggles all selected scores using the
  all-favorited → remove / otherwise → add rule; the shared filter returns the
  expected set.
- **Shared filter helper**: unit-tested once in Domain.

## Verification

- **Android** (per project rule): build, install on Pixel, launch. Because the
  DB is reset to v1 with destructive fallback, an existing dev install is wiped
  on first launch — confirm the app starts cleanly with an empty/rebuilt
  library rather than crashing. Then exercise star toggle, drawer entry,
  FavoritesListScreen, and CAB bulk favorite.
- **iOS**: build the `Library` package scheme and the app; confirm the new
  bulk-favorite action. Manual run is left to the user per the iOS no-launch
  rule.

## Files touched (map)

**iOS / shared Swift**
- `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRecordWire.swift` — `isFavorite`
- `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRowWire.swift` — `isFavorite`
- `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift` — `setFavorite` (single + bulk)
- `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift` — implementations
- shared Domain helper for the favorites filter (new, under `Packages/Domain`)
- iOS selection-mode toolbar (Library Screens) — bulk favorite action + strings

**Android**
- `Android/FolinoLibraryAndroid/.../library/RoomLibraryStore.kt` — entity column, reset to `version = 1`, delete `MIGRATION_1_2`/`MIGRATION_2_3` + `.addMigrations(...)`, add `.fallbackToDestructiveMigration()`
- `Android/app/.../MainActivity.kt` — drawer entry + `favorites` route + `drawerCapable`
- `Android/app/.../ui/library/FavoritesListScreen.kt` — new
- `Android/app/.../ui/library/LibraryScreen.kt` — row star toggle, overflow item, CAB favorite action
- `Android/app/.../res/values/strings.xml` — favorites strings

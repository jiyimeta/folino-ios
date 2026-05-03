# Library + Minimum Reader Design

**Status:** Draft for review
**Date:** 2026-05-02
**Successor of:** Plan #3 (Persistence and File Gateway). Plan #4 in the implementation roadmap.

## Goal

Ship the first end-to-end interactive surface of Folino: import a score, see it in a hierarchical Library, open it in a minimum Reader, and manage tags / playlists / favorites. This is the first plan that produces a build a user can demo.

The Reader in this plan is intentionally a thin wrapper over `SheetMusicUI.ScoreView` (vertical scroll, no zoom/page toggle, no toolbar). Reader v2 — pinch zoom, paged mode, staff visibility — is a separate plan.

## Architectural Position

```
App  ──▶ Library ──▶ Domain ◀── Infrastructure (Plan #3)
 │   ╲   Reader  ──▶ Domain
 │    ╲  Settings──▶ Domain
 │     ╲                       
 │      ╲▶ LicenseList (App-only)
 │
 └─ wires the Plan #3 adapters (LiveScoreLibraryRepository,
    LiveScoreFileGateway, LiveScoreFileImporter) into each Feature.
```

No Feature → Feature edges. Settings does not depend on Library or Reader. App is the only place that wires concrete adapters in.

Plan #3 already produced:
- `AppDatabase`, `LiveScoreLibraryRepository` (`@MainActor @Observable`, ValueObservation-driven)
- `LiveScoreFileGateway` (per-format dispatch through `swift-sheet-music`)
- `LiveScoreFileImporter` (two-stage `prepareImport` / `commitImport`)
- `AppBootstrap` that exposes them as `@Observable` properties on the App side.

This plan consumes them; it does not add new Domain protocols or new Infrastructure adapters. The only Domain-layer change is one helper covered in §6.

## Information Architecture

### Top-level surface

iPad uses `NavigationSplitView` with a 2-column layout: **Library (sidebar)** and **Reader (detail)**. iPhone uses `NavigationStack` rooted at the same Library view; the Reader is pushed.

When the Reader is opened on iPad, the column visibility flips to `.detailOnly` so the score has full screen. The standard `NavigationSplitView` chevron toggle remains available so the user can bring the sidebar back without leaving the Reader.

### Library root (hierarchical)

The Library root is a `List` with these sections, in order:

1. **Favorites** — up to 5 favorited score rows ordered by `addedAt` desc (most-recently-added favorites surface first), plus an "All Favorites" navigation link if there are more than 5. If no favorites, the section is omitted entirely (not "0 results"). Note: `ScoreItem` has no `favoritedAt` timestamp; v1 uses `addedAt` for this ordering. A `favoritedAt` field can be added in a later plan if the ordering proves wrong in practice.
2. **Browse** — three navigation rows:
   - `All Scores  [count] ›`
   - `Tags        [count] ›`
   - `Playlists   [count] ›`
3. **Recently Opened** — up to 5 most-recently-opened score rows (`lastOpenedAt` desc, nulls excluded). Omitted if empty.

The Favorites and Recently Opened sections are *windows* into the underlying score list, not separate destinations. Tapping a row in either section pushes the Reader directly.

### Drill-downs

Each Browse row pushes a dedicated child view:

- **All Scores** → sortable, searchable list of every `ScoreItem`.
- **Tags** → list of `Tag` rows (name + member count). Tapping a tag pushes a filtered All-Scores-style list scoped to that tag.
- **Playlists** → list of `Playlist` rows (name + member count). Tapping a playlist pushes an *ordered* list (the playlist's `orderedScoreItemIDs`).

All three "leaf" list types (All Scores, Tag-filtered, Playlist contents) share one row layout and one `.searchable` modifier. The differences live in the data source.

## Module Composition

### Packages/Features/Library

Public surface:

```swift
import Domain

@MainActor
public struct LibraryRootView<LicenseContent: View>: View {
    public init(
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway,
        licenseContent: @escaping () -> LicenseContent
    )
}
```

The `licenseContent` closure is invoked when the Settings sheet wants to render its License row. App passes `{ LicenseListView() }`. This keeps `Library` independent of `LicenseList`.

Internal types:
- `LibraryViewModel` — `@MainActor @Observable`. Holds `repository`, `importer`, `gateway`. Owns sort/search/sheet UI state. Drives the import pipeline (`prepareImport` → confirm dialog → `commitImport`).
- `ScoreListViewModel` — drives any of the three leaf list shapes (All / Tag-filtered / Playlist-ordered) via an enum `ListSource`.
- `TagDetailView`, `PlaylistDetailView`, `AllScoresView`, `TagsListView`, `PlaylistsListView` — pure views, no separate VMs.

### Packages/Features/Reader

Adds dependency on `SheetMusicUI` (and transitively on `SheetMusic`) by editing `Package.swift`. Public surface:

```swift
import Domain

@MainActor
public struct ReaderView: View {
    public init(
        scoreItem: ScoreItem,
        repository: any ScoreLibraryRepository,
        gateway: any ScoreFileGateway,
        scoresDirectory: URL
    )
}
```

The Reader resolves the on-disk URL itself from `scoresDirectory.appending(path: scoreItem.localFileName)`. `scoresDirectory` is supplied by App at the wiring boundary (it lives in `AppPaths`, which is App-internal).

### Packages/Features/Settings

Public surface:

```swift
@MainActor
public struct SettingsSheet<LicenseContent: View>: View {
    public init(licenseContent: @escaping () -> LicenseContent)
}
```

Single `Form` with one `NavigationLink("Licenses")` row. The destination is `licenseContent()`. Future plans will add SoundFonts / Sync / Reader-prefs sections.

### App composition root

`AppShellView.swift` is rewritten to host the real chrome:

```
AppShellView
  ├─ ProgressView while !bootstrap.isReady
  └─ when ready: 
       NavigationSplitView (iPad regular size class)
         sidebar: LibraryRootView(...)
         detail:  Color.clear (Reader pushes here via NavigationLink(value:))
       OR
       NavigationStack (iPhone / compact size class)
         root: LibraryRootView(...)
```

Library is composed with the bootstrap's repository/importer/gateway plus the License closure. Settings is presented as a `.sheet` from a Library toolbar gear icon; App provides the `licenseContent: { LicenseListView() }` closure.

## Library: Detailed Behavior

### Row content

Every score row in every list shape (root sections, All Scores, Tag-filtered, Playlist contents) uses the same layout:

- **Title** (large) — `ScoreItem.title`
- **Composer** (subtitle, secondary color) — `ScoreItem.composer`, omitted if nil
- **Trailing**: `★` icon (filled, accent color) iff `isFavorite == true`. No icon otherwise.

Format is *not* surfaced in the row. Folino's positioning is "import any format, view it, export it" — making format invisible in routine UI is a deliberate product choice. Format is still derivable via `ScoreFormat.detect(filename:)` for code paths that need it.

### Sort

A toolbar `Menu` exposes 4 options on All Scores, Tag-filtered, and Playlist views (Playlist also keeps "Manual order" as the default and primary):

- **Date Added** ↓ (default for All / Tag-filtered)
- **Title** A→Z (locale-aware, diacritic-insensitive)
- **Composer** A→Z (locale-aware, diacritic-insensitive)
- **Last Opened** ↓ (nulls last)

For Playlists:
- **Manual** (default; uses `orderedScoreItemIDs`)
- The 4 above as alternatives.

The sort selection is a per-view UI-state (not persisted in v1).

### Search

A `.searchable` modifier is applied to All Scores, Tag-filtered, and Playlist contents. It is **not** applied to the Library root (the root sections are not searchable as a unit).

- Fields searched: `title`, `composer`. Matching uses `String.range(of:options: [.caseInsensitive, .diacriticInsensitive], locale: .current)`.
- Empty query → unfiltered list.
- No-match → SwiftUI's standard "No Results" `ContentUnavailableView` (provided by `.searchable` automatically when the result set is empty).

Kana folding (ひらがな ⇄ カタカナ) is **out of scope**; tracked as v1 follow-up.

### Per-row actions

**Swipe (leading edge)**: `★ Favorite` toggle. Updates `ScoreItem.isFavorite` via `repository.saveScoreItem(_:)`.

**Swipe (trailing edge)**:
- `Delete` (destructive). Triggers a confirmation alert ("Delete '<title>'? This will remove the score and its file from this device.") with `[Delete] [Cancel]`. On confirm, call `repository.deleteScoreItem(id:)` (which also removes the on-disk file — already implemented in Plan #3).

**Context menu (long-press)**: Full set, in this order:
1. `Open` — pushes Reader (redundant with tap, but expected on context menus)
2. `★ Favorite` (toggles, label flips to `Unfavorite`)
3. `Edit Tags…` — opens the tag-assign sheet (see §Tags)
4. `Add to Playlist…` — opens the playlist-assign sheet (see §Playlists)
5. `Delete` (destructive) — same confirmation as the swipe action

Identical for both list and root-section rows.

### Tags

**Browse**: `Library Root → Tags ›` pushes `TagsListView`. Shows each `Tag` as a row: name + count. A toolbar `+` opens an alert with a single `TextField` ("Tag name"). Submit calls `repository.saveTag(_:)`.

If 0 tags: `ContentUnavailableView` with title "No Tags", message "Add tags from a score's context menu, or tap + above.", icon `tag`.

**Tag detail (drill-down)**: Tapping a tag row pushes `TagDetailView`, which is essentially `AllScoresView` filtered by `scoreItem.tagIDs.contains(tag.id)`. The view's navigation title is the tag name. Toolbar has an `Edit` menu with:
- `Rename…` — alert with TextField
- `Delete Tag` — confirmation alert. On confirm, `repository.deleteTag(id:)` (DB CASCADE strips the relations; the scores themselves stay).

**Assign**: From a score row's context menu → `Edit Tags…` → sheet titled "Tags for '<title>'". Renders a `List` of every existing tag with a leading checkmark for current membership. Tapping a row toggles membership *immediately* (no Save button). At the bottom, an inline "+ New Tag" row reveals a TextField and adds the tag (and assigns it to the current score). Dismissing the sheet ends the editing session — no transactional commit.

Toggle implementation: read the current `ScoreItem`, mutate `tagIDs`, call `repository.saveScoreItem(_:)`. The `LiveScoreLibraryRepository.saveScoreItem` already resyncs the `score_item_tags` junction (`drop existing → re-insert`), so partial states cannot leak.

**No tag color picker in v1** — `Tag.colorHex` is required by the Domain model, so tag creation/rename writes a fixed default `"#5856D6"` (system indigo). The library does not display the color anywhere; tags render in the app's accent color. The picker UI is the v1 follow-up; existing rows keep their stored value when the picker ships.

### Playlists

**Browse**: `Library Root → Playlists ›` pushes `PlaylistsListView`. Each `Playlist` row shows name + member count. Toolbar `+` opens the create alert.

If 0 playlists: `ContentUnavailableView` with title "No Playlists", message "Create a playlist with the + button above.", icon `music.note.list`.

**Playlist detail**: `PlaylistDetailView` shows the ordered scores. Navigation title is the playlist name. Toolbar:
- `Sort` menu (Manual default + 4 sort options as in §Sort).
- `Edit` toolbar button toggles `EditMode`. In edit mode, `.onMove` reorders rows; `.onDelete` removes a member from the playlist (does *not* delete the score). Reordering builds a new `orderedScoreItemIDs`, then calls `repository.savePlaylist(_:)` (Plan #3's implementation drops + reinserts `playlist_items` with explicit positions).
- `Edit` menu (kebab/3-dot, separate from `EditMode`):
  - `Rename…`
  - `Delete Playlist` — confirmation alert. CASCADE strips the relations.

Empty playlist: `ContentUnavailableView` with title "No Scores in This Playlist", message "Add scores from the context menu of any score row.", icon `music.note.list`.

**Assign**: From a score row's context menu → `Add to Playlist…` → sheet titled "Add '<title>' to Playlist". Renders a `List` of every existing playlist with a leading checkmark for current membership. Tapping toggles membership. The add operation appends to the end of `orderedScoreItemIDs`; remove preserves remaining order. Inline "+ New Playlist" row at the bottom does the same flow as the toolbar create.

## Reader: Detailed Behavior

The Reader does only these things in this plan:

1. **Load** — on `onAppear`, load the parsed `Score` from `gateway.loadScore(fileURL:)` where the URL is `scoresDirectory.appending(path: scoreItem.localFileName)`. Render a `ProgressView` until loaded.

2. **Display** — render the loaded `Score` with `SheetMusicUI.ScoreView(score:)` using default `ScoreViewOptions()`. Vertical scroll, no zoom, no page mode toggle, no staff visibility, no playback cursor.

3. **Update last opened** — on the same `onAppear` (after load succeeds), make a mutable copy of `scoreItem` with `lastOpenedAt = Date()` and call `repository.saveScoreItem(_:)`. The repository's ValueObservation pushes the update back into the Library; the Reader does not re-read from the repository to drive its own UI.

4. **Close** — the standard `NavigationStack` back button (or the iPad sidebar toggle) returns to Library. No additional close button.

5. **File-missing error** — if `gateway.loadScore` throws `DomainError.scoreFileNotFound` or any error caught at the boundary, render an inline `ContentUnavailableView` with title "Could not open this score", message "The score file is missing or unreadable.", and a single `Retry` button that re-attempts the load. No "delete this row" option in v1; that lives in the Library row's swipe.

The `ScoreItem` is passed in by value at construction. The Reader does *not* observe the repository for updates to the score it's currently displaying; if the user edits tags/favorite of the open score from another part of the app (which v1 does not allow — the Reader is full-screen), staleness would be acceptable.

### Concurrency

`gateway.loadScore` is `async throws` and is wrapped in `Task.detached(priority: .userInitiated)` inside Infrastructure (Plan #3 fix), so calling it from the MainActor `onAppear` will not block the UI. The Reader holds an `@State var loadState: LoadState` (`.loading`, `.loaded(Score)`, `.failed(Error)`) and re-renders on transition.

## Import Flow

### Trigger

Library's toolbar (rightmost) shows a `+` button (system image `plus`). Tap presents a `.fileImporter` configured with:

- `allowedContentTypes`: derived from `ScoreFormat` cases. v1 supported: `.mscx`, `.mscz`, `.musicxml`, `.mxl`, `.midi`. Mapped to UTTypes: `public.xml`, `com.apple.itunes.audio.mscz` (or a custom UTI declared in App; if not, fall back to `public.zip` filtered by extension), `com.recordare.musicxml`, `com.recordare.musicxml-zip`, `public.midi-audio`. *Exact UTType selection is left to the implementation plan; the spec only requires that all five formats can be selected.*
- `allowsMultipleSelection: false` for v1. Multi-import is a follow-up.

### Pipeline

```
.fileImporter selects URL  
   → start security-scoped access on the URL  
     (call .startAccessingSecurityScopedResource() and balance with .stop... in defer)
   → importer.prepareImport(sourceURL:) → ImportPlan  
   → if plan.duplicates is empty:
        commitImport(plan, decision: .importAsNew) → ScoreItem
        → push Reader(scoreItem: result)
     else:
        present 3-button alert (see below)  
        → commit with chosen decision → ScoreItem  
        → push Reader(scoreItem: result)
```

The Reader push is a navigation event on the same `NavigationStack` / split-view detail column. On iPad, the sidebar collapses to `.detailOnly` after import.

### Duplicate alert

When `plan.duplicates.first` is non-nil:

```
Title:    "Already in Your Library"
Message:  "'<existing.title>' is already imported. What do you want to do?"
Buttons:
  • Open                — decision = .openExisting(existing.id)
  • Import as Duplicate — decision = .importAsNew
  • Cancel              — discard plan, no I/O
```

If `plan.duplicates.count > 1` (the same content hash appears for several library rows — possible only after explicit "Import as Duplicate" was used previously), the Open button targets `duplicates.first`. The choice is incidental: file bytes are identical across duplicates, so the user reaches an indistinguishable Reader regardless. v1 does not surface a chooser.

### Error UX

Errors thrown by `prepareImport` or `commitImport` surface as a `.alert`:

| Error case                                | Alert title              | Alert message                                                  |
| ----------------------------------------- | ------------------------ | -------------------------------------------------------------- |
| `DomainError.unsupportedFormat(_)`        | "Unsupported File"       | "Folino can't open this file type."                             |
| `DomainError.scoreParseFailed(_)`         | "Couldn't Read Score"    | "This file looks corrupted or isn't a valid score."             |
| `DomainError.persistenceFailed(_)`        | "Couldn't Save Score"    | "There was a problem saving the score. Check available storage." |
| `DomainError.scoreFileNotFound(_)`        | (see Reader §, not Import) | —                                                              |
| any other `Error`                         | "Import Failed"          | use `(error as NSError).localizedDescription`                   |

All alert strings live in `Library/Resources/Localizable.xcstrings` (see §Localization).

## Domain Helper

To render Library row content cleanly in an "Up to N most recent" pattern, add one Domain extension:

```swift
public extension Array where Element == ScoreItem {
    /// Top N items by `lastOpenedAt` desc. Items with nil are excluded.
    func mostRecentlyOpened(limit: Int) -> [ScoreItem]

    /// Favorited items only, ordered by `addedAt` desc, capped at `limit`.
    func favorites(limit: Int) -> [ScoreItem]
}
```

These are pure value helpers in the Domain module, used by `LibraryViewModel`. Test them with Swift Testing — boundary cases (empty, fewer than N, exactly N, all-nil-lastOpened, mixed favorites).

No new protocols. No new Infrastructure adapters.

## Localization

`Library/Resources/Localizable.xcstrings`, `Reader/Resources/Localizable.xcstrings`, `Settings/Resources/Localizable.xcstrings`. All UI text in those modules goes through string catalogs from the start (en + ja).

User-visible strings to localize include (non-exhaustive):

- Section titles: "Favorites", "Browse", "Recently Opened"
- Browse row labels: "All Scores", "Tags", "Playlists"
- Empty state titles + messages (Library, Tags, Playlists, Tag-filtered, Playlist contents)
- Sort menu labels
- Context menu actions, swipe action labels
- Import alert (title / message / 3 buttons)
- Error alerts (4 cases above)
- Reader inline error
- Settings: "Settings", "Licenses", "Done"

Translations are written by hand to start; the catalog format supports a follow-up pass for review by a native speaker.

## Out-of-Scope (this plan only)

Tracked as v1 follow-ups (still on the v1 roadmap):

- **Multi-file import** — `allowsMultipleSelection: true` plus a progress UI for batch operations.
- **Search kana-folding** — ひらがな ⇄ カタカナ normalization in title/composer search.
- **Tag color UI** — picker on tag create/rename, color chip on rows.

Tracked as post-v1:

- **Reader v2** — pinch zoom, vertical scroll ⇄ horizontal page toggle (`PagedScoreView`), staff visibility toggles, mixer controls, full-screen mode toggle.
- **Annotations** — drawing layer, text boxes, anchored to `(systemIndex, relativeRect)`. Plan needs the `AnnotationLayer` model from Domain plus a CloudKit sync slot.
- **Playback** — audio engine, transport controls, cursor, A–B repeat, mixer state, persistent `PlaybackPreferences`. Background-audio entitlement included if user opts in.
- **SoundFont management** — Settings section for download/evict, network status, manual switch. Cache lives in `Caches/Soundfonts/`.
- **CloudKit Sync** — replication of `ScoreItem`, `Tag`, `Playlist`, `AnnotationLayer`, and the bytes via `CKAsset`. Settings shows last-sync timestamp + manual refresh.
- **Editor** — score mutation, MusicXML / MSCZ export. Both block on upstream `swift-sheet-music` work.
- **PDF export** — `SheetMusicPDF` integration.

## Testing Strategy

### Library tests (`Packages/Features/Library/Tests`)

Hand-written `FakeScoreLibraryRepository` (`@MainActor`, `@Observable`, holds in-memory arrays, mutates them in `save*` / `delete*` so the same observation pattern as `LiveScoreLibraryRepository` is exercised) and `FakeScoreFileImporter` (plays back canned `ImportPlan` / `ImportDecision` outcomes).

Coverage:
- `LibraryViewModel` sort/search predicates produce the expected order across each `ListSource`.
- Favorites toggle: tapping the swipe-leading button mutates `isFavorite` and the observed array reflects it on next read.
- Delete: confirmation flow calls `deleteScoreItem(id:)`.
- Tag assign sheet: toggle adds/removes `tagIDs`, "+ New Tag" inline path.
- Playlist assign sheet: toggle appends/removes; reorder invokes `savePlaylist` with the new `orderedScoreItemIDs`.
- Import alert: 3-button flow each picks the right `ImportDecision` and triggers a Reader push.
- Empty states: each list type emits the expected `ContentUnavailableView` configuration.

### Reader tests (`Packages/Features/Reader/Tests`)

Fake `ScoreFileGateway` (returns canned `Score` or throws `scoreFileNotFound`), fake repository.

Coverage:
- `loadState` transitions: `.loading` → `.loaded` on success, `.loading` → `.failed` on error.
- `lastOpenedAt` is updated exactly once on successful load (call to `saveScoreItem` observed on the fake).
- File-missing path renders the inline error.

### Settings tests (`Packages/Features/Settings/Tests`)

Trivially smoke-test `SettingsSheet` renders with a stub `licenseContent` closure.

### App-level tests

No new App-level tests in this plan. The wiring is a one-time composition; existing AppBootstrap tests cover the adapter hookup.

### UI tests

Defer XCUITest until at least one user flow is stable across iterations. v1 follow-up.

## Implementation Order (preview, locked in by the plan doc)

This is an outline only — the implementation plan in `docs/superpowers/plans/2026-05-02-library-and-minimum-reader.md` will break each into TDD tasks.

1. Domain helpers (`mostRecentlyOpened`, `favoritesByRecency`) + tests.
2. Library: data shape (`LibraryViewModel`, `ListSource`, `FakeScoreLibraryRepository`) + sort/search tests.
3. Library: row, list, swipe, context menu, alert flows (no tag/playlist UI yet).
4. Library: Tags drill-down + assign sheet + create/rename/delete.
5. Library: Playlists drill-down + assign sheet + reorder + create/rename/delete.
6. Library: root sections (Favorites, Browse, Recently Opened) + empty states.
7. Library: import flow (`+` toolbar → `.fileImporter` → prepare → confirm → commit → push).
8. Reader: `Package.swift` adds `SheetMusicUI`. `ReaderView` with `loadState` + `ScoreView` + lastOpened update + inline error.
9. Settings: stub sheet with License row composition surface.
10. App: rewrite `AppShellView` to host `NavigationSplitView` / `NavigationStack` with Library + Reader + Settings sheet wired from `AppBootstrap`.
11. Localization sweep: ensure every string lives in a string catalog, en + ja translations populated.
12. Manual verification on iPad and iPhone simulators (`mcp__xcode__RenderPreview` for layout, simulator run for the full flow).

## Risks and Open Questions

- **`allowedContentTypes` for `.mscz` and MusicXML** — Apple does not register UTTypes for these. We may need to declare `UTImportedTypeDeclarations` in `Info.plist` to give the file picker proper filtering. The implementation plan should verify each format actually appears in the `.fileImporter` UI on iOS 26 simulator before locking the UTType set.
- **`ScoreView` reflow on size class change** — `SheetMusicUI.ScoreView` lays out against an available width. iPad split-view → full-screen transition will trigger a relayout. This should "just work" via SwiftUI's `GeometryReader` inside `ScoreView`, but worth verifying with a multi-page score.
- **Sheet vs. fullScreenCover for Settings** — sheet is the right pattern here (Settings is dismissable, not modal-blocking). No risk, just confirming convention.
- **Reader's `lastOpenedAt` race** — if the user rapidly taps two scores in succession, both Readers will fire `saveScoreItem`. The repository serializes writes through GRDB's pool, so there's no data race; the only consequence is two harmless writes. Acceptable.

---

End of design.

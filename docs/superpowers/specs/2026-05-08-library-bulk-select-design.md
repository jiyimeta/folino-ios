# Library Bulk Select — Design

Add a multi-select mode to the Library so users can pick several score
items at once and apply bulk actions: delete, add to a playlist, and
add tags. Available on the three score-listing screens — All Scores,
Tag detail, Playlist detail.

## Goals

- A `Select` entry point on each score-list toolbar opens an editing
  mode where rows show selection circles and a bottom action bar
  appears.
- Bulk actions:
  - **Delete** — All Scores / Tag detail: confirm alert "Delete N
    scores?" → deletes record + on-device file. Playlist detail:
    alert with three choices: *Remove from playlist* / *Delete
    completely* / *Cancel*.
  - **Add to Playlist** — pick one playlist (or create a new one);
    every selected score gets appended to that playlist if not
    already present.
  - **Tags** — pick one or more tags (or create new ones); the
    chosen tags are union-added to every selected score.
- Standard iOS pattern: `EditButton` + `List(selection:)`.
  `EditMode` controls visibility of the bottom action bar.
- Reorder in Playlist detail keeps working — selection circles and
  drag handles coexist (selection replaces the per-row delete circle).

## Non-goals

- Long-press to enter selection mode (the toolbar `Select` button is
  the sole entry point).
- Multi-playlist toggle in the bulk Add-to-Playlist sheet (a single
  target playlist per invocation).
- "Remove tag from N scores" in the bulk Tags sheet — only union add.
- Folding bulk into the existing single-row `AddToPlaylistSheet` /
  `EditTagsSheet`. Those stay as-is.
- New Domain protocols. Bulk methods iterate existing repository
  calls.
- Bulk share (out of scope; single-row share already exists).
- Drag-to-reorder while in selection mode in All Scores / Tag detail.

## Architecture

All work is inside `Packages/Features/Library/`. No new dependencies,
no Domain or Infrastructure changes.

```
LibraryViewModel  (new bulk methods)
       ▲
       │  used by
       │
ScoreListScreen ─────┐
PlaylistDetailScreen ┤   (own selection state, present sheets)
                     │
                     ├── ScoreListView         (selection + bottom action bar)
                     ├── PlaylistDetailView    (selection + bottom action bar)
                     ├── BulkAddToPlaylistScreen / Sheet
                     └── BulkEditTagsScreen / Sheet
```

## LibraryViewModel — bulk methods

```swift
public func bulkDelete(_ ids: Set<ScoreItemID>) async
public func bulkRemoveFromPlaylist(_ ids: Set<ScoreItemID>, from playlist: Playlist) async
public func bulkAddToPlaylist(_ orderedIDs: [ScoreItemID], to playlist: Playlist) async
public func bulkAddTags(_ ids: Set<ScoreItemID>, tagIDs: Set<TagID>) async
```

Behavior contract:

- All four iterate the existing repository calls (`deleteScoreItem`,
  `savePlaylist`, `saveScoreItem`). No new Domain abstraction.
- On the first thrown error, stop and write the message to
  `errorAlertMessage`. Items processed before the failure stay
  changed (best-effort, matches the rest of the app's error model).
- `bulkAddToPlaylist` appends only IDs not already in
  `playlist.orderedScoreItemIDs`, preserving the caller's order for
  the new tail. One `savePlaylist` call.
- `bulkRemoveFromPlaylist` filters those IDs out and calls
  `savePlaylist` once.
- `bulkAddTags` reads each `ScoreItem` from the repository, unions
  `tagIDs` into `item.tagIDs`, and calls `saveScoreItem`. Items
  whose tag set is unchanged are skipped (no-op write).
- `bulkDelete` calls `deleteScoreItem(id:)` per ID.
- Empty input set: each method returns immediately, no error.

## Screen-level selection state

Both `ScoreListScreen` and `PlaylistDetailScreen` own:

```swift
@State private var editMode: EditMode = .inactive
@State private var selectedIDs: Set<ScoreItemID> = []
@State private var bulkAction: BulkAction?     // drives sheet/alert presentation
```

`BulkAction` is a private enum with cases like `.addToPlaylist`,
`.editTags`, `.confirmDelete`, `.playlistDeleteChoice`.

When `editMode` flips back to `.inactive` (Done tapped, or after a
successful bulk action), the screen clears `selectedIDs`.

## ScoreListView changes

Add bindings:

```swift
@Binding var editMode: EditMode
@Binding var selectedIDs: Set<ScoreItemID>
let onBulkDelete: () -> Void
let onBulkAddToPlaylist: () -> Void
let onBulkEditTags: () -> Void
```

Switch the `List` to `List(selection: $selectedIDs)` (gated by
`editMode == .active` for the bottom bar visibility, but binding
selection always is fine — selection circles only appear in edit
mode anyway).

Toolbar: keep the existing sortMenu; add `EditButton()` (top-leading
on iOS, automatic on macOS). Disable swipe actions while editing
(selection circles already replace the trailing `Delete` swipe;
leading favorite-swipe is hidden by EditMode automatically).

Bottom action bar: rendered via `safeAreaInset(edge: .bottom)` only
when `editMode == .active`. Three buttons; all disabled when
`selectedIDs.isEmpty`. Title in the navigation bar shows
`"\(selectedIDs.count) selected"` when active (via
`navigationTitle` swap).

The screen passes `BulkContext` (an enum: `.scores` vs `.playlist`)
so the view can label the third button `Delete` vs `Delete…` and
the screen can show the right alert.

## PlaylistDetailView changes

Same bottom bar pattern. Existing `EditButton` already toggles
`editMode`; we reuse it. `List(selection: $selectedIDs)` is added
alongside `.onMove` and `.onDelete`. The per-row swipe-delete keeps
working outside edit mode; in edit mode the selection circles
replace the red minus circles.

`onDelete` (the swipe / EditMode minus) becomes unreachable while
selection is bound — that's fine because the bulk Delete bar
button covers both single and multi removal once selection mode is
on. Swipe-delete still works when not in edit mode.

`PlaylistDetailScreen` stays the owner of the
`bulkRemoveFromPlaylist` vs `bulkDelete` decision via the
three-button alert.

## BulkAddToPlaylistScreen + Sheet

New files mirroring `AddToPlaylistScreen` / `AddToPlaylistSheet`:

`BulkAddToPlaylistSheet`:

```swift
let selectionCount: Int                       // shown in title
let allPlaylists: [Playlist]
let onPick: (Playlist) -> Void                // tap row → caller appends + dismisses
let onCreate: (String) -> Void                // create new playlist with selected
```

Layout: list of playlists with a small trailing count badge
"`K` / `N`" showing how many of the selected scores are already
included (pure visual hint, not interactive). Bottom section is the
existing pattern: `New playlist` TextField + `Create` button.
Tapping a row commits and dismisses. Toolbar `Cancel` only.

`BulkAddToPlaylistScreen` wires this to
`library.bulkAddToPlaylist(orderedIDs, to: playlist)` and on
success dismisses + clears the screen's selection.

## BulkEditTagsScreen + Sheet

`BulkEditTagsSheet`:

```swift
let selectionCount: Int
let allTags: [Tag]
@State private var checked: Set<TagID> = []
let onCommit: (Set<TagID>) -> Void            // union-add to selected scores
let onCreateTag: (String) -> Void             // creates and auto-checks
```

Layout: list of tags with checkboxes, all initially OFF (since this
is union-add, not state-edit). New-tag input row at the bottom with
explicit `Create` button. Toolbar `Cancel` and `Done`. `Done` calls
`onCommit(checked)` and dismisses; if `checked.isEmpty`, `Done` is
disabled.

`BulkEditTagsScreen` wires to
`library.bulkAddTags(ids, tagIDs:)` then dismisses + clears the
screen's selection. New tags created via `onCreateTag` go through
`repository.saveTag` first (matching `EditTagsScreen`'s existing
pattern); the resulting tag is auto-added to `checked`.

## Bulk Delete UX

Plain confirmation alert in All Scores / Tag detail:

> Title: "Delete \(N) scores?"
> Message: "This will remove the scores and their files from this device."
> Buttons: `Delete` (destructive) / `Cancel`.

Action sheet — three-button alert in Playlist detail:

> Title: "Delete \(N) scores?"
> Message: (none)
> Buttons:
> - `Remove from playlist` (default)
> - `Delete completely` (destructive)
> - `Cancel`

Both flows call into `LibraryViewModel.bulkDelete` /
`bulkRemoveFromPlaylist`. After completion the screen dismisses
edit mode.

## Localization

New keys, English + Japanese:

| Key (en) | ja |
| --- | --- |
| `Select` | 選択 |
| `%lld selected` | %lld 件選択中 |
| `Delete %lld scores?` | %lld 件のスコアを削除しますか？ |
| `This will remove the scores and their files from this device.` | スコアとファイルがこの端末から削除されます。 |
| `Remove from playlist` | プレイリストから削除 |
| `Delete completely` | 完全に削除 |
| `Add %lld scores to playlist` | %lld 件をプレイリストに追加 |
| `Tags for %lld scores` | %lld 件のスコアにタグを追加 |
| `Add to Playlist` | プレイリストに追加 |
| `Tags` | タグ |

Existing `New playlist` / `New tag` / `Create` / `Cancel` / `Done`
keys are reused.

## Testing

`Tests/LibraryTests/LibraryViewModelBulkTests.swift` — Swift Testing,
backed by `FakeScoreLibraryRepository`. Cases:

- `bulkDelete` removes every passed ID; empty input is a no-op;
  failure on item 2 leaves item 1 deleted and surfaces
  `errorAlertMessage`.
- `bulkRemoveFromPlaylist` filters the IDs out; preserves remaining
  order; empty input no-op.
- `bulkAddToPlaylist` appends only missing IDs; preserves caller's
  order for the appended tail; idempotent if all IDs already there.
- `bulkAddTags` unions tag IDs; skips writes when the tag set
  doesn't change; partial failure stops and surfaces error.

UI behavior (selection / bottom bar / sheets) is verified via
`#Preview` blocks plus a manual smoke run on a simulator. No XCUI
test added — matches the existing Library test discipline.

## Files

New:

- `Packages/Features/Library/Sources/Library/Views/BulkAddToPlaylistSheet.swift`
- `Packages/Features/Library/Sources/Library/Views/BulkEditTagsSheet.swift`
- `Packages/Features/Library/Sources/Library/Screens/BulkAddToPlaylistScreen.swift`
- `Packages/Features/Library/Sources/Library/Screens/BulkEditTagsScreen.swift`
- `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelBulkTests.swift`

Edited:

- `LibraryViewModel.swift` — four bulk methods.
- `Views/ScoreListView.swift` — selection bindings, bottom bar,
  EditButton, title swap.
- `Views/PlaylistDetailView.swift` — selection binding, bottom bar.
- `Screens/ScoreListScreen.swift` — selection state, bulk-action
  presentation, alerts.
- `Screens/PlaylistDetailScreen.swift` — same.
- `Resources/Localizable.xcstrings` — new strings.

## Risks

- **PlaylistDetail edit-mode collision** — selection circles will
  hide the per-row red minus that today triggers
  `onRemoveFromPlaylist(at:)`. Reorder handles still appear. Net
  effect: in selection mode, removing a single row goes through the
  bulk Delete bar instead of the minus circle. Acceptable — the
  bulk path covers it. Verify on simulator before merging.
- **Drag-to-reorder + selection in same gesture** — uncommon but
  possible to start a drag from a selected row. iOS handles this
  natively; we just need to not interfere. No special code.
- **Best-effort error handling** — partial success on bulk failure
  matches existing single-item behavior. Surface the first error;
  user can retry.

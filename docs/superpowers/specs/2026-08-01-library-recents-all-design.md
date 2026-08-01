# Library root: show every opened score in Recently Opened

Date: 2026-08-01
Status: approved
Scope: iOS only. Android is explicitly out of scope for this change.

## Problem

The Library root's "Recently Opened" section is capped at five items
(`LibraryRootScreen.swift`, `items.mostRecentlyOpened(limit: 5)`). Five is too
few to be a useful re-entry point once a user has a working set of a dozen or
more scores: the score they want has usually already fallen off the list, so the
section stops being a shortcut and they navigate through All Scores instead.

Android already lists *every* opened score in its recents surface
(`LibraryAndroidStore.reloadRecents` applies no limit, bucketing the results into
today / this week / earlier via the shared `RecencyBucket` classifier). So iOS is
the platform that diverges, and the divergence is a cap that nothing depends on.

## Goal

The Library root's Recently Opened section lists every score that has ever been
opened, most-recently-opened first, with no cap — while keeping the Library root
responsive and giving the user a way to get the long list out of the way.

## Design

### 1. Domain — lift the cap into an option

`Packages/Domain/Sources/Domain/ScoreItemRootSections.swift`

```swift
public func mostRecentlyOpened(limit: Int? = nil) -> [ScoreItem]
```

`nil` means unlimited. The existing semantics are otherwise unchanged: items with
a `nil` `lastOpenedAt` have never been opened and stay excluded, and the result is
sorted by `lastOpenedAt` descending.

The implementation already sorts the full array before truncating, so making the
truncation conditional does not change the amount of work done — only the length
of the array that comes back.

### 2. `LibraryRootScreen`

`Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift`

```swift
recentlyOpened = items.mostRecentlyOpened()
```

The surrounding `onChange(of: viewModel.repository.scoreItems, initial: true)`
recompute stays exactly as it is. It already runs once per repository change
rather than once per body evaluation, which is the property that matters here.

### 3. `LibraryRootRecentsSection` — collapsible

`Packages/Features/Library/Sources/Library/Screens/LibraryRootRecentsSection.swift`

The bare `Section` becomes a `CollapsibleSection(isExpanded:count:)`, matching
`LibraryRootPlaylistsSection` and `LibraryRootTagsSection`:

- expansion state persists in `@AppStorage("library.section.recents.expanded")`,
  defaulting to expanded, so the existing behavior is what a user sees on upgrade;
- the header carries a count badge, supplied by `CollapsibleSection(count:)`;
- when collapsed, `CollapsibleSection` does not evaluate its content closure at
  all, so not a single row is built. That is the escape hatch for a user whose
  recents list has grown to hundreds of entries.

Row contents are untouched: tap-to-open, the trailing ellipsis `Menu`, both
`swipeActions` edges, and the `contextMenu` all stay as they are.

The section keeps its existing `if !recents.isEmpty` guard, so a library with no
opened scores still renders nothing.

### 4. Presentation choice: one flat section

The recents list stays a single flat section ordered by `lastOpenedAt` descending.
It is deliberately *not* split into today / this week / earlier buckets the way
Android does. Per the repo's iOS/Android parity rule, shared *logic* must match
across platforms while *presentation and placement* follow each platform's own
idiom — and the classifier that would do the bucketing (`RecencyBucket`) is
already shared, so nothing about that rule is being violated by rendering the
same data flat on iOS.

## Performance

The concern that motivates the collapsible section is worth stating precisely,
because most of it turns out to be already-shipped cost:

| Concern | Reality |
| --- | --- |
| Building N rows | `List` is lazy — it materializes visible rows plus a small buffer. `ScoreListView` already streams the entire library through structurally identical rows on the All Scores screen. |
| Sort cost | `mostRecentlyOpened` already sorts the full array before `prefix`. Removing the cap changes neither the number of sorts nor their complexity. |
| Array copy | The `@State private var recentlyOpened` array gets longer. `ScoreItem` is a value type; this is a shallow copy of a contiguous buffer. |
| Recompute frequency | Unchanged — driven by `onChange(of: repository.scoreItems)`, i.e. once per repository mutation, not per body evaluation. |
| Per-row menu cost | `scoreRowMenu` builds a fixed set of buttons and does not iterate playlists or tags, so it is O(1) per row and unaffected by library size. |

The one genuinely new lever is the collapsed state, which takes the cost to zero
outright.

## Testing

Add to `Packages/Domain/Tests/DomainTests/ScoreItemRootSectionsTests.swift`:

- omitting `limit` returns every opened item, ordered by `lastOpenedAt`
  descending;
- omitting `limit` still excludes items whose `lastOpenedAt` is `nil`.

The existing `limit`-passing tests stay as they are and continue to cover the
capped path (still used by nothing in the app after this change, but the option
remains part of the API and is cheap to keep correct).

## Localization

No new keys. The section header keeps `library.recentlyOpened`, and the count
badge renders a number through `Text(count, format: .number)` inside
`CollapsibleSection`.

## Out of scope

- Android. Its recents surface already shows every opened score, so this change
  closes a gap rather than opening one. No Android work is required or planned as
  part of this.
- Any change to the All Scores / Favorites / tag / playlist screens.
- Thumbnails, per-row detail changes, or new sort options.

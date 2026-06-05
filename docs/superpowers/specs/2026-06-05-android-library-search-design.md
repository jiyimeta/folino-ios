# Android Library Search — Design

**Date:** 2026-06-05
**Branch:** `worktree-android-library-search`
**Status:** Approved (pending spec review)

## Goal

Bring the Library score-list search feature to Android at parity with iOS. On
iOS, `.searchable` filters the All / Favorites / Tag-detail / Playlist-detail
lists by **title OR composer**, case- and diacritic-insensitive, with an empty
query showing everything. Android currently has **no** search.

Per the repo's iOS/Android parity rules: the *matching logic* must be shared
(lifted to Domain, not reimplemented in Kotlin); the *UI placement* follows
Android idioms.

## Scope

In scope — search over the three Android list contexts that map to iOS's
searchable lists:

- All scores (`LibraryScreen`, observable `scores`)
- Playlist detail (`PlaylistDetailScreen`, observable `selectedPlaylistItems`)
- Tag detail (`TagDetailScreen`, observable `selectedTagItems`)

Out of scope:

- Recently Deleted (iOS has no search there either).
- Search history, suggestions, or full-screen search overlay.
- New search fields beyond title/composer (no subtitle/tag/instrumentation
  matching — matches iOS exactly).

## Current state (reference)

iOS search logic lives inline in
`Packages/Features/Library/Sources/Library/ScoreListViewModel.swift`
(`applySearch`, ~lines 79–94):

```swift
private func applySearch(_ items: [ScoreItem]) -> [ScoreItem] {
    let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return items }
    let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    return items.filter { item in
        if item.title.range(of: trimmed, options: opts, locale: .current) != nil { return true }
        if let composer = item.composer,
           composer.range(of: trimmed, options: opts, locale: .current) != nil { return true }
        return false
    }
}
```

It is `private` to the view model — not in Domain, no Android equivalent.

The Android Library bridge is a single `@WireletObservable` class
(`Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`)
exposing `scores`, `selectedPlaylistItems`, `selectedTagItems` (all
`[ScoreRowWire]`, fields: id/title/subtitle/composer). It follows a
"filter Swift-side, expose a dedicated observable" pattern (e.g.
`selectTag(id)` → recomputes `selectedTagItems`). Kotlin/Compose collects these
observables and never filters.

## Design

### 1. Shared matching logic (Domain)

New file `Packages/Domain/Sources/Domain/ScoreSearch.swift`. Field-argument
form so both iOS `ScoreItem` and Android `ScoreRowWire` can call it without a
shared type dependency:

```swift
public enum ScoreSearch {
    /// True when `query` (trimmed) appears as a case- and diacritic-insensitive
    /// substring of `title` or `composer`. An empty/whitespace query matches
    /// everything, mirroring iOS `.searchable` behavior.
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

Foundation-only; lives in Domain so both the Library feature (iOS) and
`FolinoLibraryJNI` (Android bridge) can import it. Confirm `FolinoLibraryJNI`'s
`Package.swift` depends on `Domain` (add if missing).

### 2. iOS refactor (behavior-preserving)

`ScoreListViewModel.applySearch` delegates to `ScoreSearch.matches`:

```swift
private func applySearch(_ items: [ScoreItem]) -> [ScoreItem] {
    items.filter { ScoreSearch.matches(title: $0.title, composer: $0.composer, query: searchQuery) }
}
```

The empty-query short-circuit now lives inside `matches`. Existing
`ScoreListViewModelTests` search assertions must stay green.

### 3. Android bridge (`LibraryAndroidStore.swift`)

Mirror the `selectTag → selectedTagItems` pattern — filter Swift-side, expose
already-filtered observables:

- Hold unfiltered backing arrays internally: `allScoreRows`,
  `selectedPlaylistRows`, `selectedTagRows`.
- The observables `scores` / `selectedPlaylistItems` / `selectedTagItems` are
  always assigned the `ScoreSearch`-filtered result of their backing array.
- Store `private var searchQuery = ""`.
- Add `@WireletExpose func setSearchQuery(_ query: String)` — stores the query
  and recomputes all three observables from their backings.
- Every existing reload/select path (`reload(using:)`, `reloadPlaylists()`,
  `selectPlaylist(_:)`, `reloadTags()`, `selectTag(_:)`) writes its result to
  the backing array and then applies the current query when assigning the
  observable, so filtering survives data refreshes.
- Filtering uses `ScoreSearch.matches(title: row.title, composer: row.composer, query:)`.
- **Kotlin never filters** — parity rule.

Reminder (file header constraint): `@WireletExpose` methods must live in the
primary class body, not an extension, or the bridge macro drops them.

### 4. Compose UI (Android idiom)

A reusable composable `LibrarySearchField` placed as an **independent row below
the `TopAppBar`** in `LibraryScreen`, `PlaylistDetailScreen`, `TagDetailScreen`.
The existing TopAppBars (drawer hamburger / back / title / ellipsis) are left
untouched — the ellipsis menus stay fully usable because the search field is a
separate row, not a takeover of the bar.

- A persistent search input (Material3, not the full-screen "active" SearchBar
  expansion — no suggestion overlay). On each keystroke calls
  `viewModel.setSearchQuery(text)`; the screen renders the already-filtered
  observable.
- Local Compose state holds the text; on disposal the screen calls
  `setSearchQuery("")` so the query resets per-screen (matching iOS's
  per-screen view-model lifetime).
- Empty state: when the query is non-empty and the filtered list is empty, show
  a "No results" message.

### 5. Strings

Add to `Android/app/src/main/res/values/strings.xml` (English only — `:app`
has no localized variants today):

- `search_hint` — placeholder, e.g. "Search".
- `search_no_results` — empty-state, e.g. "No results".

## Testing

- **Domain — `ScoreSearchTests` (Swift Testing):**
  - substring match in title
  - case-insensitive ("etude" matches "Etude")
  - diacritic-insensitive ("etude" matches "Étude Op.10") — load-bearing
  - empty / whitespace query → matches everything
  - composer match
  - `nil` composer does not crash and does not match
- **iOS:** existing `ScoreListViewModelTests` search tests stay green (refactor
  only — no behavior change).
- **Android:** build (`:app` + `:FolinoLibraryAndroid`), then install + launch
  on a physical Pixel and verify search on all three list contexts, including a
  diacritic case (per Android parity rule: install + launch is done, not just a
  build check).

## Risks

- **Diacritic folding on Android Swift target.** `range(of:options:.diacriticInsensitive)`
  is ICU-backed. swift-sheet-music already runs Foundation on Android, but
  diacritic folding specifically is unverified on the cross-compiled
  swift-corelibs-foundation. **Mitigation:** add an Android-run test (or the
  Pixel diacritic check) early; if folding is a no-op on Android, fall back to a
  manual normalization in `ScoreSearch` (e.g. `folding(options:locale:)` or
  explicit decomposition + diacritic stripping) that behaves identically on both
  platforms. Resolve before declaring done.
- **Backing-array discipline.** Every code path that rebuilds a list observable
  must go through the backing array + current query, or search state silently
  drops on the next reload. Covered by routing all reload/select paths through
  the same apply step.

## Out-of-scope follow-ups (not now)

- Localizing the Android search strings (`values-ja`).
- Highlighting matched substrings in results.

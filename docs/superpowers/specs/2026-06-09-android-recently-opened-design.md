# Android Recently Opened — Design

**Date:** 2026-06-09
**Status:** Approved (design); implementation gated — see §0.
**Scope:** Android Library only. iOS already ships the underlying `lastOpenedAt` model and its surfaces.

## 0. Implementation gate (read first)

A separate session is **collapsing all Room migrations into a fresh v1 schema** (the app has not had its first release, so historical migrations are being discarded). Do **not** start implementation until:

1. The user explicitly signals the migration-collapse work has landed, and
2. `main` is merged into the working branch, and
3. The new `last_opened_at` column is folded **directly into the collapsed v1 `score_records` definition** — **no `MIGRATION_*` object is added**.

Until then this spec describes the end state, not a migration path. Every reference below to "the schema" means the post-collapse fresh v1 schema.

## 1. Goal

Surface a **Recently Opened** experience on Android at content-parity with iOS, placed per Android idioms:

- A drawer **"Recent" destination** showing the full open-history of scores, grouped by **Today / This week / Earlier**.
- The **Playlists** and **Tags** lists ordered by **most-recently-used** (parity with iOS `playlistsByRecentlyUsed` / `tagsByRecentlyUsed`).

The dividing line that keeps "Recent" distinct from "All scores": **Recent is a behavior-driven history** (only scores you have opened, time-sorted, no sort/filter controls); **All scores is the collection** (every score, sortable by title/composer/added). To preserve that distinction, **All scores must not gain a "recently opened" sort option** — `last-opened` ordering is the exclusive identity of the Recent destination.

## 2. Non-goals

- **No cross-device sync of `lastOpenedAt`.** Android persistence is local Room; there is no CloudKit on Android. iOS syncs `lastOpenedAt` via CloudSync, so the value will diverge per device. Accepted.
- **No "remove from recent"**, no bulk/CAB selection in the Recent screen. It is a read-only resume list.
- **No "recently opened" sort** added to All scores (see §1).
- **No change to the iOS surfaces.** iOS keeps its 5-item inline shelf. The only iOS-side change is the mechanical import update from lifting shared helpers (§5).

## 3. Architecture overview

The Android Library follows the established split: **all policy lives in Swift** (`LibraryAndroidStore`, the `@WireletProvided` store), and the Kotlin `RoomLibraryStore` is a rule-free backend that persists whatever record Swift hands it. `lastOpenedAt` rides that same path — Swift computes the timestamp and calls `upsert`; Kotlin just stores the column.

Derivation logic (grouping, recently-used ordering) lives in **shared Domain** so iOS and Android compute identically.

```
Score opened (any list row → openReader lambda in MainActivity)
  └─▶ vm.markOpened(id)  [@WireletExpose]
        └─▶ Swift LibraryAndroidStore.markOpened: set record.lastOpenedAt = now, upsert  [policy: 0-sentinel]
              └─▶ Kotlin RoomLibraryStore.upsert → score_records.last_opened_at

Recent screen / Playlists / Tags
  └─▶ Swift LibraryAndroidStore reloads from records (lastOpenedAt populated)
        └─▶ Domain helpers (Swift-side, before projection):
              RecencyBucket.classify(date:now:calendar:)  → recentToday/recentThisWeek/recentEarlier
              playlistsByRecentlyUsed / tagsByRecentlyUsed (on [ScoreOpenInfo])  → ordered playlists/tags
              └─▶ Compose renders the projected, already-grouped/ordered lists verbatim
```

## 4. Persistence & wire (Android)

### 4.1 `ScoreRecordWire`
Add one field, mirroring the existing `deletedAt` sentinel convention exactly:

```swift
public var lastOpenedAt: Double // 0 == never opened; >0 == Unix time of last open
```

Rationale: matches `deletedAt` (`Double`, `0` sentinel) — `0` (1970) is never a real open instant, so it is a safe "never opened" sentinel and avoids marshaling an `Optional` across JNI. Update the memberwise `init` and all call sites.

### 4.2 Swift `LibraryAndroidStore` mapping
- When projecting `ScoreItem → ScoreRecordWire`: `lastOpenedAt = item.lastOpenedAt?.timeIntervalSince1970 ?? 0` (same shape as `deletedAt`).
- When projecting `ScoreRecordWire → ScoreItem`: `lastOpenedAt = wire.lastOpenedAt > 0 ? Date(timeIntervalSince1970: wire.lastOpenedAt) : nil`.

This keeps `ScoreItem.lastOpenedAt: Date?` as the single source of truth; the `0 ⇄ nil` bridge lives only at the wire boundary.

### 4.3 Room (post-collapse v1 — no migration)
Add to `ScoreRecordEntity`:

```kotlin
@ColumnInfo(name = "last_opened_at") val lastOpenedAt: Double, // 0 == never opened
```

Folded into the **fresh v1** `score_records` table definition. `RoomLibraryStore.loadAll` / `upsert` carry the field through. **No `MIGRATION_*` object** (see §0).

## 5. Shared Domain logic

### 5.1 Already shared (reuse as-is, iOS-only consumer)
- `[ScoreItem].mostRecentlyOpened(limit:)` — `Domain/ScoreItemRootSections.swift`. Excludes `nil` `lastOpenedAt`. Used by the iOS 5-item shelf; **Android does not use it** (Android groups records directly via §5.2). Left unchanged.

### 5.2 New shared classifier — recency bucket
The Android wire carries no `[ScoreItem]`, so grouping is expressed as a pure per-date classifier (no `ScoreItem` dependency), keeping the parity-sensitive boundary rules in one shared place:

```swift
public enum RecencyBucket: Sendable, Equatable { case today, thisWeek, earlier }

public extension RecencyBucket {
    /// Classify `date` relative to `now` using `calendar`. Callers pass the device's
    /// current date and `Calendar.current`. Both injected for testability.
    static func classify(_ date: Date, now: Date, calendar: Calendar) -> RecencyBucket
}
```

- Boundaries (device's local calendar): **today** = same calendar day as `now`; **thisWeek** = same `.weekOfYear` granularity as `now` (respects `calendar.firstWeekday`) but not today; **earlier** = everything else.
- Each platform owns its own partition+sort loop over this classifier. The Android `LibraryAndroidStore` sorts live opened records by `lastOpenedAt` desc, classifies each, and fills three `[ScoreRowWire]` buckets; empty buckets render no section. Trashed records (`deletedAt > 0`) and never-opened records (`lastOpenedAt == 0`) are excluded before classifying.

### 5.3 Lift recently-used helpers into Domain (on a minimal projection)
Move `playlistsByRecentlyUsed` and `tagsByRecentlyUsed` from `Packages/Features/Library/Sources/Library/LibrarySort.swift` into Domain (public). **Refactor their input from `scoreItems: [ScoreItem]` to a minimal projection** because the Android wire cannot build a full `ScoreItem`:

```swift
public struct ScoreOpenInfo: Sendable, Equatable {
    public let id: ScoreItemID
    public let lastOpenedAt: Date?
    public let tagIDs: Set<TagID>
    public init(id: ScoreItemID, lastOpenedAt: Date?, tagIDs: Set<TagID>)
}

public func playlistsByRecentlyUsed(_ playlists: [Playlist], openInfo: [ScoreOpenInfo], limit: Int) -> [Playlist]
public func tagsByRecentlyUsed(_ tags: [Tag], openInfo: [ScoreOpenInfo], limit: Int) -> [Tag]
```

Body logic is unchanged (max `lastOpenedAt` over members; `createdAt` / `.distantPast` fallbacks; `name` tiebreak). iOS call sites (`LibraryRootCollapsibleSections.swift:15,78`) adapt with one `.map { ScoreOpenInfo(id: $0.id, lastOpenedAt: $0.lastOpenedAt, tagIDs: $0.tagIDs) }`. Existing `LibrarySortTests` move to `DomainTests` and construct `ScoreOpenInfo` directly. This is a move + signature refinement within existing packages — no new package, no new layer boundary, behavior identical.

## 6. Score-open write-back (Android) — resolved

The Android Reader has **no** reference to the Library store, and all score-open navigation funnels through one lambda — `openReader` in `MainActivity.LibraryNavGraph` (`MainActivity.kt:217`), used by every list (All / Recently Deleted / Playlist detail / Tag detail / the new Recent). So the seam is there, not in the Reader:

- Add `@WireletExpose public func markOpened(_ id: String)` to `LibraryAndroidStore` (mirrors the `setDeletedAt` pattern: load records, set the row's `lastOpenedAt = Date().timeIntervalSince1970`, `upsert`, then `reload()` + `reloadPlaylists()` + `reloadTags()`). Unknown id is a no-op.
- Call `vm.markOpened(row.id)` inside `openReader`, before `nav.navigate(...)`.

This is **once per open by construction** (the lambda fires once per navigation, never during reading) and reuses the existing record-mutation path. `FolinoReaderAndroid` is untouched. Opening a trashed score from Recently Deleted still stamps harmlessly — the Recent screen filters `deletedAt > 0` out regardless.

## 7. UI (Android Compose)

### 7.1 Drawer destination
- New `NavigationDrawerItem` **"Recent"**, route `recent`, placed **directly below "All Scores"** (resume is a primary affordance), above Playlists.
- Icon: `Icons.Outlined.History`.
- String resource keyed to match the iOS key scheme (`library.recentlyOpened`); add the Android string entry alongside `nav_all_scores` etc.
- Default landing destination is **unchanged** (`list` / All Scores). Recent is one drawer tap away.

### 7.2 `RecentScreen`
- Consumes three `StateFlow<List<ScoreRowWire>>` projected by the store (`recentToday`, `recentThisWeek`, `recentEarlier`) — grouping happens Swift-side (§5.2); Compose renders verbatim.
- Renders a `LazyColumn` with **section headers Today / This week / Earlier** (omit a section whose list is empty), rows reuse the existing `ScoreRow` composable and `openReader`.
- Row tap → `openReader` (which calls `markOpened`, so the item floats to Today on return).
- **Empty state** when all three lists are empty: a centered message (e.g. "まだ楽譜を開いていません" — final copy per the Android string catalog; user-facing brand stays lowercase `folino`).
- Read-only: no overflow "remove", no multi-select.

### 7.3 Playlists & Tags ordering
- `reloadPlaylists` / `reloadTags` in `LibraryAndroidStore` sort via the lifted Domain helpers (§5.3) with `limit = full count` (reorder, not top-N) before projecting to `PlaylistRowWire` / `TagRowWire`. The Kotlin `PlaylistsListScreen` / `TagsListScreen` already render the projected order verbatim — **no Kotlin changes**.

## 8. Testing

**Domain (Swift Testing — `@Suite`/`@Test`/`#expect`; the high-value, fully-runnable layer):**
- `RecencyBucket.classify`: boundary cases with injected `now` + a fixed Gregorian `Calendar` (same instant → today; earlier same day → today; yesterday same week → thisWeek; 8 days ago → earlier; week-rollover around `firstWeekday`).
- `playlistsByRecentlyUsed` / `tagsByRecentlyUsed`: ported from `LibrarySortTests`, rewritten to construct `ScoreOpenInfo`; confirm max-over-members ordering, `createdAt` / `.distantPast` fallbacks, and `name` tiebreak intact after the refactor.

**Android & Swift bridge (verified by build + Pixel install/launch, per the project's Android habit — the `FolinoLibraryJNI` / Room targets are not in the iOS test loop):**
- `lastOpenedAt` round-trips: open a score → it appears under Today in Recent; relaunch → still present (Room persisted); never-opened scores absent.
- Playlists/Tags reorder by recent use after opening a member.
- No migration test (collapsed v1, per §0).

## 9. Open items for the plan

1. ~~Reader→store seam~~ — resolved in §6 (`markOpened` via `openReader`).
2. Confirm "This week" matches `Calendar.current.firstWeekday` so the boundary reads naturally for the locale.
3. String catalog entry (`R.string.nav_recent`) + final Japanese empty-state copy.

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
Reader opens score
  └─▶ shared repository.saveScoreItem(item with lastOpenedAt = now)   [iOS path reused]
        └─▶ Swift LibraryAndroidStore.upsert(ScoreRecordWire)         [policy: 0-sentinel mapping]
              └─▶ Kotlin RoomLibraryStore.upsert → score_records.last_opened_at

Recent screen / Playlists / Tags
  └─▶ load ScoreItems (lastOpenedAt populated)
        └─▶ Domain helpers: groupByRecency(now:) / mostRecentlyOpened / playlistsByRecentlyUsed / tagsByRecentlyUsed
              └─▶ Compose renders grouped / ordered lists
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

### 5.1 Already shared (reuse as-is)
- `[ScoreItem].mostRecentlyOpened(limit:)` — `Domain/ScoreItemRootSections.swift`. Excludes `nil` `lastOpenedAt`. The Recent screen calls it with a large/effectively-unbounded limit to get the full history.

### 5.2 New shared helper — recency grouping
Add to Domain a pure, testable grouping function:

```swift
public enum RecencyBucket: Sendable { case today, thisWeek, earlier }

extension [ScoreItem] {
    /// Opened items (lastOpenedAt != nil), sorted desc, partitioned into Today / This week / Earlier
    /// using `calendar` against `now`. `now` and `calendar` are injected for testability;
    /// callers pass the device's current date and `Calendar.current`.
    public func groupedByRecency(now: Date, calendar: Calendar) -> [(RecencyBucket, [ScoreItem])]
}
```

- Boundaries use the device's local calendar: **Today** = same calendar day as `now`; **This week** = within the current week (per `calendar`) but not today; **Earlier** = everything else. Trashed items (`deletedAt != nil`) are filtered out by the caller before grouping (the Recent screen passes the live list).
- Empty buckets are omitted from the result.

### 5.3 Lift `LibrarySort` helpers into Domain
Move `playlistsByRecentlyUsed(_:scoreItems:limit:)` and `tagsByRecentlyUsed(_:scoreItems:limit:)` from `Packages/Features/Library/Sources/Library/LibrarySort.swift` into Domain, making them `public`. Update the iOS Library to import them from Domain (mechanical; behavior unchanged). Android then calls the same functions. This is a move within existing packages — no new package, no new layer boundary.

## 6. Reader write-back (Android)

iOS stamps the timestamp once per open via `ReaderViewModel.updateLastOpenedAtOnce()` → `repository.saveScoreItem(updated)`. Android reuses this shared code path rather than reimplementing it.

**Integration point to resolve in the plan:** the Android Reader currently has no path to the Library store. The implementation must wire score-open so it invokes the shared "mark opened" save (set `lastOpenedAt = now`, save once per open — never repeatedly while reading). The plan must identify the concrete seam (shared repository reference vs. a JNI callback into `LibraryAndroidStore`) and confirm the once-per-open guard mirrors `hasUpdatedLastOpened`.

## 7. UI (Android Compose)

### 7.1 Drawer destination
- New `NavigationDrawerItem` **"Recent"**, route `recent`, placed **directly below "All Scores"** (resume is a primary affordance), above Playlists.
- Icon: `Icons.Outlined.History`.
- String resource keyed to match the iOS key scheme (`library.recentlyOpened`); add the Android string entry alongside `nav_all_scores` etc.
- Default landing destination is **unchanged** (`list` / All Scores). Recent is one drawer tap away.

### 7.2 `RecentScreen`
- Loads live (non-trashed) score items, calls `groupedByRecency(now:calendar:)`.
- Renders a `LazyColumn` with **section headers Today / This week / Earlier** (omit empty sections), rows reuse the existing score-row composable.
- Row tap → navigate to Reader (which re-stamps `lastOpenedAt`, so the item floats to Today on return).
- **Empty state** when no score has ever been opened: a centered message (e.g. "まだ楽譜を開いていません" — final copy per the Android string catalog; user-facing brand stays lowercase `folino`).
- Read-only: no overflow "remove", no multi-select.

### 7.3 Playlists & Tags ordering
- Playlists list and Tags list render in **recently-used order** via the lifted Domain helpers (§5.3), passing the current score-item set. Visual rows unchanged.

## 8. Testing

**Domain (Swift Testing — `@Suite`/`@Test`/`#expect`):**
- `groupedByRecency`: today/thisWeek/earlier boundary cases with injected `now` + fixed `Calendar` (item exactly at midnight boundary, item 6 days ago, week rollover); `nil` `lastOpenedAt` excluded; empty buckets omitted; descending order within a bucket.
- `mostRecentlyOpened`: regression for the large-limit (full-history) call.
- `playlistsByRecentlyUsed` / `tagsByRecentlyUsed`: move existing iOS tests with the functions; confirm empty/fallback/tiebreak behavior intact after the lift.

**Android:**
- `RoomLibraryStore` round-trip: `upsert` with `lastOpenedAt > 0` and `== 0` reads back identically; `loadAll` carries the column.
- Wire mapping (`0 ⇄ nil`) covered by a Swift store test.
- No migration test (collapsed v1, per §0).

**Reader:**
- Android once-per-open guard: opening a score sets `lastOpenedAt`, and it is not re-stamped on subsequent in-session interactions.

## 9. Open items for the plan

1. Resolve the Reader→Library-store seam (§6) — the one genuinely unknown integration point.
2. Confirm exact "This week" semantics against `Calendar.current.firstWeekday` so iOS and Android agree if/when iOS adopts `groupedByRecency`.
3. String catalog entry + final Japanese empty-state copy.

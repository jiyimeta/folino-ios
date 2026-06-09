# Android Recently Opened Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Recent" experience to the Android Library — a drawer destination listing opened scores grouped Today / This week / Earlier, plus recently-used ordering of the Playlists and Tags lists — at content-parity with iOS.

**Architecture:** Policy stays in Swift (`LibraryAndroidStore`), Kotlin/Room is a rule-free backend, ordering/grouping logic lives in shared Domain. `lastOpenedAt` rides the existing `deletedAt` 0-sentinel wire convention. Score-open is stamped via a new `markOpened` exposed method called from the single `openReader` navigation lambda — the Reader is untouched.

**Tech Stack:** Swift 6.3 (Domain, FolinoLibraryJNI/`@WireletObservable`), Kotlin/Room/Jetpack Compose (Android), swift-wirelet JNI bridge, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-09-android-recently-opened-design.md`

---

## ⛔ Implementation Gate (per spec §0)

**Do not start Phase 3 (Room) until the user signals the migration-collapse work has landed and `main` is merged in.** Phases 1–2 (shared Domain + Swift wire/store) are platform-neutral and have no Room dependency, but per the user's instruction **wait for the explicit go-ahead before starting any phase.** When Phase 3 begins, fold `last_opened_at` into the already-collapsed fresh v1 `score_records` definition — **add no `MIGRATION_*` object.**

---

## File Structure

**Created:**
- `Packages/Domain/Sources/Domain/RecencyBucket.swift` — the `RecencyBucket` enum + `classify` classifier.
- `Packages/Domain/Sources/Domain/RecentlyUsedSort.swift` — `ScoreOpenInfo` + the two recently-used sort helpers (moved from Library).
- `Packages/Domain/Tests/DomainTests/RecencyBucketTests.swift` — classifier tests.
- `Packages/Domain/Tests/DomainTests/RecentlyUsedSortTests.swift` — ported sort tests.
- `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/RecentScreen.kt` — the Recent destination UI.

**Modified:**
- `Packages/Features/Library/Sources/Library/LibrarySort.swift` — **deleted** (contents moved to Domain).
- `Packages/Features/Library/Sources/Library/Screens/LibraryRootCollapsibleSections.swift` — adapt the two call sites to `openInfo:`.
- `Packages/Features/Library/Tests/LibraryTests/LibrarySortTests.swift` — **deleted** (moved to DomainTests).
- `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRecordWire.swift` — add `lastOpenedAt`.
- `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift` — `markOpened`, three recent observables, recently-used ordering.
- `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt` — `last_opened_at` column + mapping (Phase 3, gated).
- `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` — `markOpened` in `openReader`, "Recent" drawer item + route.
- `Android/app/src/main/res/values/strings.xml` (+ `values-ja/`) — `nav_recent`, `recent_empty`.

---

## Test commands

- **Domain (Swift Testing, runnable):** from repo root
  `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
  (Run inside `Packages/Domain` if the root scheme isn't visible; fallback scheme name `Domain-Package`. `swift test` is broken here by the SwiftLint build-tool plugin's macOS requirement — use xcodebuild + an iOS Simulator. iPhone 16 sim is not installed; use iPhone 17.)
- **iOS Library package builds:** inside `Packages/Features/Library`
  `xcodebuild build -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
- **Android build + device:** see Phase 5. Fresh worktree must run `Scripts/android-build-libs.sh` (gradle codegen → `.so`) before `assembleDebug`.

---

## Phase 1 — Shared Domain (platform-neutral, fully TDD)

### Task 1: `RecencyBucket.classify`

**Files:**
- Create: `Packages/Domain/Sources/Domain/RecencyBucket.swift`
- Test: `Packages/Domain/Tests/DomainTests/RecencyBucketTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Domain/Tests/DomainTests/RecencyBucketTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

@Suite struct RecencyBucketTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 1 // Sunday
        return c
    }

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    // now = Wednesday 2026-06-10 12:00 UTC; that week (Sun-start) is 06-07 … 06-13.
    private var now: Date { at(2026, 6, 10) }

    @Test func sameInstantIsToday() {
        #expect(RecencyBucket.classify(now, now: now, calendar: calendar) == .today)
    }

    @Test func earlierSameDayIsToday() {
        #expect(RecencyBucket.classify(at(2026, 6, 10, 6), now: now, calendar: calendar) == .today)
    }

    @Test func yesterdaySameWeekIsThisWeek() {
        #expect(RecencyBucket.classify(at(2026, 6, 9), now: now, calendar: calendar) == .thisWeek)
    }

    @Test func weekStartSundayIsThisWeek() {
        #expect(RecencyBucket.classify(at(2026, 6, 7), now: now, calendar: calendar) == .thisWeek)
    }

    @Test func previousSaturdayIsEarlier() {
        #expect(RecencyBucket.classify(at(2026, 6, 6), now: now, calendar: calendar) == .earlier)
    }

    @Test func eightDaysAgoIsEarlier() {
        #expect(RecencyBucket.classify(at(2026, 6, 2), now: now, calendar: calendar) == .earlier)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: FAIL — `cannot find 'RecencyBucket' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Packages/Domain/Sources/Domain/RecencyBucket.swift`:

```swift
import Foundation

/// Recency partition for "recently opened" surfaces. Shared so iOS and Android classify identically.
public enum RecencyBucket: Sendable, Equatable {
    case today
    case thisWeek
    case earlier
}

public extension RecencyBucket {
    /// Classify `date` relative to `now` using `calendar`. `today` = same calendar day; `thisWeek` = same
    /// `.weekOfYear` (respects `calendar.firstWeekday`) but a different day; `earlier` = neither. Callers pass the
    /// device's current date and `Calendar.current`; both are injected for testability.
    static func classify(_ date: Date, now: Date, calendar: Calendar) -> RecencyBucket {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
        return .earlier
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/RecencyBucket.swift Packages/Domain/Tests/DomainTests/RecencyBucketTests.swift
git commit -m "feat(domain): add RecencyBucket.classify for recently-opened grouping"
```

---

### Task 2: Move recently-used helpers to Domain on a `ScoreOpenInfo` projection

**Files:**
- Create: `Packages/Domain/Sources/Domain/RecentlyUsedSort.swift`
- Create: `Packages/Domain/Tests/DomainTests/RecentlyUsedSortTests.swift`
- Delete: `Packages/Features/Library/Sources/Library/LibrarySort.swift`
- Delete: `Packages/Features/Library/Tests/LibraryTests/LibrarySortTests.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/LibraryRootCollapsibleSections.swift:15,78`

- [ ] **Step 1: Create the Domain helper file (moved + refactored)**

Create `Packages/Domain/Sources/Domain/RecentlyUsedSort.swift`. Body logic is copied verbatim from the old `LibrarySort.swift`; only the input type changes from `[ScoreItem]` to `[ScoreOpenInfo]` (the helpers only ever read `id`, `lastOpenedAt`, `tagIDs`):

```swift
import Foundation

/// Minimal projection of a score for recently-used ordering — the only fields the sort helpers read. The Android
/// persistence wire cannot build a full `ScoreItem`, so the shared helpers take this instead.
public struct ScoreOpenInfo: Sendable, Equatable {
    public let id: ScoreItemID
    public let lastOpenedAt: Date?
    public let tagIDs: Set<TagID>

    public init(id: ScoreItemID, lastOpenedAt: Date?, tagIDs: Set<TagID>) {
        self.id = id
        self.lastOpenedAt = lastOpenedAt
        self.tagIDs = tagIDs
    }
}

/// Top-N playlists ordered by the most recent `lastOpenedAt` of any contained score. Empty playlists, or playlists
/// whose every contained ID has no `lastOpenedAt`, fall back to `createdAt`. Ties tiebreak by `name` ascending.
public func playlistsByRecentlyUsed(
    _ playlists: [Playlist],
    openInfo: [ScoreOpenInfo],
    limit: Int,
) -> [Playlist] {
    guard limit > 0 else { return [] }
    let lookup: [ScoreItemID: ScoreOpenInfo] = Dictionary(
        uniqueKeysWithValues: openInfo.map { ($0.id, $0) },
    )
    let keyed: [(Playlist, Date)] = playlists.map { playlist in
        let dates: [Date] = playlist.orderedScoreItemIDs
            .compactMap { lookup[$0]?.lastOpenedAt }
        let key = dates.max() ?? playlist.createdAt
        return (playlist, key)
    }
    let sorted = keyed.sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
    }
    return Array(sorted.prefix(limit).map(\.0))
}

/// Top-N tags ordered by the most recent `lastOpenedAt` across score items carrying the tag. Tags with no items (or no
/// opened items) sink to the bottom and tiebreak by `name` ascending.
public func tagsByRecentlyUsed(
    _ tags: [Tag],
    openInfo: [ScoreOpenInfo],
    limit: Int,
) -> [Tag] {
    guard limit > 0 else { return [] }
    var maxByTag: [TagID: Date] = [:]
    for item in openInfo {
        guard let opened = item.lastOpenedAt else { continue }
        for tagID in item.tagIDs {
            if let existing = maxByTag[tagID], existing >= opened { continue }
            maxByTag[tagID] = opened
        }
    }
    let keyed: [(Tag, Date)] = tags.map { tag in
        (tag, maxByTag[tag.id] ?? .distantPast)
    }
    let sorted = keyed.sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
    }
    return Array(sorted.prefix(limit).map(\.0))
}
```

- [ ] **Step 2: Delete the old Library copy**

```bash
git rm Packages/Features/Library/Sources/Library/LibrarySort.swift
```

- [ ] **Step 3: Port the tests to DomainTests**

`git mv` the existing test file, then apply a mechanical transform inside it. The transform recipe (the file currently constructs full `ScoreItem` values just to pass `scoreItems:`):

1. Replace the call-site label `scoreItems:` → `openInfo:`.
2. Replace each `ScoreItem(...)` literal used only as sort input with `ScoreOpenInfo(id: <id>, lastOpenedAt: <lastOpenedAt>, tagIDs: <tagIDs>)`, dropping all other `ScoreItem` fields.
3. Change `import Library`/`@testable import Library` → `@testable import Domain`.

```bash
git mv Packages/Features/Library/Tests/LibraryTests/LibrarySortTests.swift \
       Packages/Domain/Tests/DomainTests/RecentlyUsedSortTests.swift
```

Then edit `RecentlyUsedSortTests.swift` per the recipe. Example of the transform for one playlist case and one tag case (apply the same shape to every existing case in the file):

```swift
// BEFORE (in old LibrarySortTests):
//   let recent = ScoreItem(title: "R", composer: nil, instrumentationSummary: nil,
//                          localFileName: "r.mscz", contentHash: "", sizeBytes: 0, lengthBeats: 0,
//                          defaultTempoBpm: 0, primaryKey: nil, addedAt: .distantPast,
//                          lastOpenedAt: t2, tagIDs: [], isFavorite: false)
//   let result = playlistsByRecentlyUsed([p1, p2, p3], scoreItems: [recent], limit: 2)
// AFTER:
let recent = ScoreOpenInfo(id: recentID, lastOpenedAt: t2, tagIDs: [])
let result = playlistsByRecentlyUsed([p1, p2, p3], openInfo: [recent], limit: 2)

// Tag case BEFORE:
//   let i1 = ScoreItem(..., lastOpenedAt: t1, tagIDs: [tagA], ...)
//   let result = tagsByRecentlyUsed([t1, t2], scoreItems: [i1, i2], limit: 10)
// AFTER:
let i1 = ScoreOpenInfo(id: id1, lastOpenedAt: t1, tagIDs: [tagA.id])
let result = tagsByRecentlyUsed([tagA, tagB], openInfo: [i1, i2], limit: 10)
```

Preserve every assertion and every distinct scenario from the original file (max-over-members, `createdAt` fallback for unopened playlists, `.distantPast` sink for tags with no opened members, `name` tiebreak, `limit` truncation, empty-input cases).

- [ ] **Step 4: Adapt the iOS call sites**

In `Packages/Features/Library/Sources/Library/Screens/LibraryRootCollapsibleSections.swift`:

Line ~15 becomes:
```swift
let topN = playlistsByRecentlyUsed(
    allPlaylists,
    openInfo: scoreItems.map { ScoreOpenInfo(id: $0.id, lastOpenedAt: $0.lastOpenedAt, tagIDs: $0.tagIDs) },
    limit: 5,
)
```

Line ~78 becomes:
```swift
let topN = tagsByRecentlyUsed(
    allTags,
    openInfo: scoreItems.map { ScoreOpenInfo(id: $0.id, lastOpenedAt: $0.lastOpenedAt, tagIDs: $0.tagIDs) },
    limit: 5,
)
```

`Library` already imports `Domain`, so `ScoreOpenInfo` and the functions resolve. Confirm no other references to the old symbols remain:
```bash
rg -n "playlistsByRecentlyUsed|tagsByRecentlyUsed" Packages/Features/Library
```
Expected: only the two adapted call sites in `LibraryRootCollapsibleSections.swift`.

- [ ] **Step 5: Run Domain tests**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: PASS — all ported `RecentlyUsedSortTests` plus `RecencyBucketTests`.

- [ ] **Step 6: Build the iOS Library package**

Run (inside `Packages/Features/Library`): `xcodebuild build -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED, with `Compiling LibraryRootCollapsibleSections.swift`.

- [ ] **Step 7: Commit**

```bash
git add Packages/Domain/Sources/Domain/RecentlyUsedSort.swift \
        Packages/Domain/Tests/DomainTests/RecentlyUsedSortTests.swift \
        Packages/Features/Library/Sources/Library/Screens/LibraryRootCollapsibleSections.swift
git rm  Packages/Features/Library/Sources/Library/LibrarySort.swift \
        Packages/Features/Library/Tests/LibraryTests/LibrarySortTests.swift
git commit -m "refactor(domain): lift recently-used sort to Domain on ScoreOpenInfo"
```

---

## Phase 2 — Wire + Swift store (Android-gated Swift; no Room yet)

### Task 3: Add `lastOpenedAt` to `ScoreRecordWire`

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRecordWire.swift`
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift:93-100` (the one `upsert` literal)

- [ ] **Step 1: Add the field + init param**

In `ScoreRecordWire.swift`, after `deletedAt`, add the stored property, the doc line, and the init parameter + assignment:

```swift
    public var deletedAt: Double // 0 == live; >0 == soft-deleted at that Unix time
    public var lastOpenedAt: Double // 0 == never opened; >0 == Unix time of last open

    public init(
        id: String,
        title: String,
        subtitle: String,
        composer: String,
        localFileName: String,
        deletedAt: Double,
        lastOpenedAt: Double,
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.composer = composer
        self.localFileName = localFileName
        self.deletedAt = deletedAt
        self.lastOpenedAt = lastOpenedAt
    }
```

- [ ] **Step 2: Fix the one construction call site**

In `LibraryAndroidStore.importScore` (`LibraryAndroidStore.swift:93`), the new record is created with `deletedAt: 0`; a freshly imported score has never been opened, so add `lastOpenedAt: 0`:

```swift
        store.upsert(ScoreRecordWire(
            id: id,
            title: fields.title,
            subtitle: fields.subtitle ?? "",
            composer: fields.composer ?? "",
            localFileName: localFileName,
            deletedAt: 0,
            lastOpenedAt: 0,
        ))
```

- [ ] **Step 3: Confirm no other constructors**

Run: `rg -n "ScoreRecordWire\(" Packages/Features/Library/Sources`
Expected: only the `importScore` literal (other store methods mutate `all[idx].deletedAt` on loaded records, which now carry `lastOpenedAt` automatically). If any other literal exists, add `lastOpenedAt: 0`.

- [ ] **Step 4: Commit** (build verification happens at Task 4, which compiles together)

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRecordWire.swift \
        Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift
git commit -m "feat(library/android): carry lastOpenedAt on ScoreRecordWire (0-sentinel)"
```

---

### Task 4: `LibraryAndroidStore` — markOpened, recent buckets, recently-used ordering

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`

- [ ] **Step 1: Add the three recent observables**

After `public var deletedScores: [ScoreRowWire] = []` (line ~44) add:

```swift
    public var recentToday: [ScoreRowWire] = []
    public var recentThisWeek: [ScoreRowWire] = []
    public var recentEarlier: [ScoreRowWire] = []
```

- [ ] **Step 2: Populate the buckets in `reload`**

At the end of `reload(using:)` (after `deletedScores = ...`, line ~198), add a call to a new private helper, then implement it. Inside `reload`:

```swift
        reloadRecents(from: all)
```

Add this private method (below `reload`):

```swift
    /// Live, opened records (deletedAt <= 0 && lastOpenedAt > 0), newest first, classified into the three
    /// recency buckets via the shared Domain classifier. Mirrors iOS recency grouping; uses the device's clock.
    private func reloadRecents(from records: [ScoreRecordWire]) {
        let calendar = Calendar.current
        let now = Date()
        let opened = records
            .filter { $0.deletedAt <= 0 && $0.lastOpenedAt > 0 }
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
        var today: [ScoreRowWire] = []
        var week: [ScoreRowWire] = []
        var earlier: [ScoreRowWire] = []
        for record in opened {
            let date = Date(timeIntervalSince1970: record.lastOpenedAt)
            switch RecencyBucket.classify(date, now: now, calendar: calendar) {
            case .today: today.append(Self.row(record))
            case .thisWeek: week.append(Self.row(record))
            case .earlier: earlier.append(Self.row(record))
            }
        }
        recentToday = today
        recentThisWeek = week
        recentEarlier = earlier
    }
```

- [ ] **Step 3: Add the `markOpened` exposed method**

Add near `delete`/`restore` (after line ~115). It mirrors the `setDeletedAt` mutation pattern but stamps `lastOpenedAt`:

```swift
    /// Stamp `lastOpenedAt = now` for `id` and rebuild the displayed lists. Called from the Android navigation
    /// layer the moment a score is opened (iOS parity: `ReaderViewModel.updateLastOpenedAtOnce`). Once per open by
    /// construction — the caller fires it once per navigation. Unknown id is a no-op.
    @WireletExpose
    public func markOpened(_ id: String) {
        var all = store.loadAll()
        guard let idx = all.firstIndex(where: { $0.id == id }) else { return }
        all[idx].lastOpenedAt = Date().timeIntervalSince1970
        store.upsert(all[idx])
        reload(using: all)
        reloadPlaylists()
        reloadTags()
    }
```

- [ ] **Step 4: Build the `[ScoreOpenInfo]` projection helper**

Add a private helper that assembles `ScoreOpenInfo` from records + the tag join (inverting `tagMembership`'s `tagId -> scoreIds` to `scoreId -> tagIDs`):

```swift
    /// Project live records into the minimal `[ScoreOpenInfo]` the recently-used sort helpers consume.
    private func loadScoreOpenInfo(_ records: [ScoreRecordWire]) -> [ScoreOpenInfo] {
        // Invert the tag join: scoreItemId string -> Set<TagID>.
        var tagsByScore: [String: Set<TagID>] = [:]
        for item in store.loadTagItems() {
            guard let uuid = UUID(uuidString: item.tagId) else { continue }
            tagsByScore[item.scoreItemId, default: []].insert(TagID(rawValue: uuid))
        }
        return records.compactMap { record in
            guard let sid = scoreItemID(record.id) else { return nil }
            let opened = record.lastOpenedAt > 0 ? Date(timeIntervalSince1970: record.lastOpenedAt) : nil
            return ScoreOpenInfo(id: sid, lastOpenedAt: opened, tagIDs: tagsByScore[record.id] ?? [])
        }
    }
```

- [ ] **Step 5: Order playlists by recent use**

In `reloadPlaylists()` (line ~369), replace the name-sort with the Domain helper. Build `openInfo` once and order with `limit = domain.count` (reorder, not top-N):

```swift
    private func reloadPlaylists() {
        let domain = loadDomainPlaylists()
        let records = store.loadAll()
        let liveIDs = liveScoreIDs(records)
        let openInfo = loadScoreOpenInfo(records)

        playlists = playlistsByRecentlyUsed(domain, openInfo: openInfo, limit: domain.count)
            .map {
                PlaylistRowWire(
                    id: $0.id.rawValue.uuidString,
                    name: $0.name,
                    memberCount: Int32(PlaylistPresentation.liveMemberCount($0, liveIDs: liveIDs)),
                )
            }

        recomputeSelectedItems(domain: domain, records: records, liveIDs: liveIDs)
        refreshAddSheet(domain: domain)
    }
```

(Leave `refreshAddSheet`'s name-sort as-is — the add-to-playlist picker stays alphabetical, matching iOS.)

- [ ] **Step 6: Order tags by recent use**

In `reloadTags()` (line ~518), build Domain `[Tag]` from the records and order via the helper, then map back to `TagRowWire` (preserving member-count math). Replace the name-sort:

```swift
    private func reloadTags() {
        let records = store.loadAll()
        let live = liveScoreIDStrings(records)
        let membership = tagMembership()
        let openInfo = loadScoreOpenInfo(records)
        let tagRecords = store.loadTags()
        let domainTags = tagRecords.map { Tag(id: TagID(rawValue: UUID(uuidString: $0.id)!), name: $0.name, colorHex: $0.colorHex) }
        let orderedTags = tagsByRecentlyUsed(domainTags, openInfo: openInfo, limit: domainTags.count)

        tags = orderedTags.map { tag in
            let idString = tag.id.rawValue.uuidString
            let members = membership[idString] ?? []
            return TagRowWire(
                id: idString,
                name: tag.name,
                colorHex: tag.colorHex,
                memberCount: Int32(members.intersection(live).count),
            )
        }
        recomputeSelectedTagItems(records: records, membership: membership)
        refreshEditSheet(tagRecords: tagRecords, membership: membership)
    }
```

Note: tag id strings come from `createTag` (`UUID().uuidString`), so `UUID(uuidString:)` always succeeds; if defensively desired use `compactMap` and skip malformed ids. Keep `refreshEditSheet`'s tag order alphabetical via its existing `tagRecords` ordering (or sort there) — the edit sheet is not a recency surface.

- [ ] **Step 7: Verify the wirelet bridge regenerates**

The three new `public var` observables and `markOpened` are picked up by the `@WireletObservable` macro only when they live in the primary class body (per the file header note) — they do. There is no separate Swift build in the iOS test loop for this Android-gated target; it compiles during the Android build (Phase 5). Do a syntax sanity check:
```bash
rg -n "recentToday|recentThisWeek|recentEarlier|func markOpened" Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift
```
Expected: the three observables + the exposed method present.

- [ ] **Step 8: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift
git commit -m "feat(library/android): markOpened, recent buckets, recently-used playlist/tag order"
```

---

## Phase 3 — Room backend (⛔ GATED — start only after the migration-collapse merge)

### Task 5: `last_opened_at` column in the collapsed v1 schema

**Files:**
- Modify: `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt`

- [ ] **Step 1: Re-sync with the collapsed schema**

After the user confirms the collapse landed and `main` is merged, open `RoomLibraryStore.kt` and confirm `ScoreRecordEntity`, the `@Database(version = 1, ...)`, and the (now removed) `MIGRATION_*` objects reflect the fresh v1. The steps below assume that state.

- [ ] **Step 2: Add the column to the entity**

In `ScoreRecordEntity`, after `deletedAt`:

```kotlin
@Entity(tableName = "score_records")
data class ScoreRecordEntity(
    @PrimaryKey val id: String,
    val title: String,
    val subtitle: String,
    val composer: String,
    @ColumnInfo(name = "local_file_name") val localFileName: String,
    @ColumnInfo(name = "deleted_at") val deletedAt: Double,
    @ColumnInfo(name = "last_opened_at") val lastOpenedAt: Double, // 0 == never opened
)
```

No `MIGRATION_*` object and no `addMigrations(...)` entry for this — the column is part of v1.

- [ ] **Step 3: Carry the field in the DAO mapping**

In `RoomLibraryStore.loadAll`, include `lastOpenedAt` when building the wire:

```kotlin
    override fun loadAll(): List<ScoreRecordWire> =
        dao.loadAll().map {
            ScoreRecordWire(it.id, it.title, it.subtitle, it.composer, it.localFileName, it.deletedAt, it.lastOpenedAt)
        }
```

And in `upsert`, persist it:

```kotlin
    override fun upsert(record: ScoreRecordWire) {
        dao.upsert(
            ScoreRecordEntity(
                id = record.id,
                title = record.title,
                subtitle = record.subtitle,
                composer = record.composer,
                localFileName = record.localFileName,
                deletedAt = record.deletedAt,
                lastOpenedAt = record.lastOpenedAt,
            ),
        )
    }
```

The Kotlin `ScoreRecordWire` is generated from the Swift `@WireFormat` struct (Task 3), so its constructor now takes the extra trailing `lastOpenedAt: Double` after `.so` regeneration in Phase 5.

- [ ] **Step 4: Commit**

```bash
git add Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt
git commit -m "feat(library/android): persist last_opened_at in Room v1"
```

---

## Phase 4 — Compose UI (Kotlin)

### Task 6: Strings + "Recent" drawer destination + write-back

**Files:**
- Modify: `Android/app/src/main/res/values/strings.xml`
- Modify: `Android/app/src/main/res/values-ja/strings.xml`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`

- [ ] **Step 1: Add string resources**

In `values/strings.xml`:
```xml
<string name="nav_recent">Recent</string>
<string name="recent_empty">No scores opened yet</string>
```
In `values-ja/strings.xml`:
```xml
<string name="nav_recent">最近開いた</string>
<string name="recent_empty">まだ楽譜を開いていません</string>
```
(Confirm the project's string-catalog format — these mirror the existing `nav_all_scores` / `library_recently_deleted` entries in the same files.)

- [ ] **Step 2: Stamp `lastOpenedAt` in the open lambda**

In `MainActivity.kt`, the `openReader` lambda (line ~217) is the single choke point for every score open. Add the `markOpened` call before navigating:

```kotlin
    val openReader: (com.keynumber.folino.library.ScoreRowWire) -> Unit = { row ->
        vm.markOpened(row.id)
        val t = URLEncoder.encode(row.title, "UTF-8")
        nav.navigate("reader/${row.id}/$t")
    }
```

- [ ] **Step 3: Add the History icon import + drawer item**

Add the import near the other icon imports (line ~13-19):
```kotlin
import androidx.compose.material.icons.outlined.History
```
Add `"recent"` to `drawerCapable` (line ~201):
```kotlin
    val drawerCapable = currentRoute == "list" || currentRoute == "recentlyDeleted" ||
        currentRoute == "playlists" || currentRoute == "tags" || currentRoute == "recent"
```
Insert the drawer item directly below the All Scores item (after its closing `)` at line ~239, before the Playlists item):
```kotlin
                NavigationDrawerItem(
                    icon = { Icon(Icons.Outlined.History, contentDescription = null) },
                    label = { Text(stringResource(R.string.nav_recent)) },
                    selected = currentRoute == "recent",
                    onClick = { switchTo("recent") },
                    modifier = Modifier.padding(horizontal = 12.dp),
                )
```

- [ ] **Step 4: Register the `recent` route**

In the inner `NavHost` (line ~276), add a destination after the `"list"` composable:
```kotlin
            composable("recent") {
                RecentScreen(
                    viewModel = vm,
                    onOpenScore = openReader,
                    onOpenDrawer = openDrawer,
                )
            }
```
Add the import:
```kotlin
import com.keynumber.folino.ui.library.RecentScreen
```

- [ ] **Step 5: Commit** (compiles together with Task 7)

```bash
git add Android/app/src/main/res/values/strings.xml \
        Android/app/src/main/res/values-ja/strings.xml \
        Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(library/android): Recent drawer destination + markOpened on open"
```

---

### Task 7: `RecentScreen`

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/RecentScreen.kt`

- [ ] **Step 1: Write the screen**

Model the scaffold/top-bar/`ScoreRow` usage on the existing `LibraryScreen.kt` / `RecentlyDeletedScreen.kt` (same package). It consumes the three projected StateFlows and renders up to three sections, omitting empty ones; empty state when all three are empty.

```kotlin
package com.keynumber.folino.ui.library

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.library.ScoreRowWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecentScreen(
    viewModel: LibraryAndroidStoreViewModel,
    onOpenScore: (ScoreRowWire) -> Unit,
    onOpenDrawer: () -> Unit,
) {
    val today by viewModel.recentToday.collectAsStateWithLifecycle()
    val thisWeek by viewModel.recentThisWeek.collectAsStateWithLifecycle()
    val earlier by viewModel.recentEarlier.collectAsStateWithLifecycle()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.nav_recent)) },
                navigationIcon = {
                    IconButton(onClick = onOpenDrawer) {
                        Icon(Icons.Filled.Menu, contentDescription = null)
                    }
                },
            )
        },
    ) { padding ->
        if (today.isEmpty() && thisWeek.isEmpty() && earlier.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Text(stringResource(R.string.recent_empty), style = MaterialTheme.typography.bodyLarge)
            }
            return@Scaffold
        }
        LazyColumn(modifier = Modifier.fillMaxSize().padding(padding)) {
            recentSection(R.string.recent_today, today, onOpenScore)
            recentSection(R.string.recent_this_week, thisWeek, onOpenScore)
            recentSection(R.string.recent_earlier, earlier, onOpenScore)
        }
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.recentSection(
    headerRes: Int,
    rows: List<ScoreRowWire>,
    onOpenScore: (ScoreRowWire) -> Unit,
) {
    if (rows.isEmpty()) return
    item {
        Text(
            stringResource(headerRes),
            style = MaterialTheme.typography.titleSmall,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
    }
    items(rows, key = { it.id }) { row ->
        ScoreRow(row = row, onClick = { onOpenScore(row) })
    }
}
```

- [ ] **Step 2: Add the three section-header strings**

In `values/strings.xml`:
```xml
<string name="recent_today">Today</string>
<string name="recent_this_week">This week</string>
<string name="recent_earlier">Earlier</string>
```
In `values-ja/strings.xml`:
```xml
<string name="recent_today">今日</string>
<string name="recent_this_week">今週</string>
<string name="recent_earlier">それ以前</string>
```

- [ ] **Step 3: Reconcile `ScoreRow` signature**

Confirm `ScoreRow`'s actual parameter list in `LibraryScreen.kt` (it may take additional params such as selection state or an overflow menu). Match the call in `recentSection` to the real signature — the Recent list is read-only, so pass no selection/CAB params (use the same minimal call `LibraryScreen` makes for a plain tap, or the simplest overload). If `ScoreRow` requires more, supply read-only defaults (no selection, no long-press handler).

- [ ] **Step 4: Commit** (build verification in Phase 5)

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/RecentScreen.kt \
        Android/app/src/main/res/values/strings.xml \
        Android/app/src/main/res/values-ja/strings.xml
git commit -m "feat(library/android): RecentScreen with Today/This week/Earlier sections"
```

---

## Phase 5 — Build & device verification

### Task 8: Build, install, and verify on Pixel

**Files:** none (verification only)

- [ ] **Step 1: Regenerate the JNI bindings + native libs**

A fresh worktree (and any change to the Swift `@WireFormat` / `@WireletObservable` surface) must regenerate the Kotlin bridge + `.so`:
```bash
Scripts/android-build-libs.sh
```
This produces the updated generated `LibraryAndroidStoreViewModel` (now with `recentToday/recentThisWeek/recentEarlier` flows + `markOpened`) and the `ScoreRowWire`/`ScoreRecordWire` Kotlin data classes (the latter with the new trailing `lastOpenedAt`).
Expected: completes without error; generated sources reference the new symbols.

- [ ] **Step 2: Assemble + install the debug app**

```bash
./gradlew :app:installDebug
```
(Run from `Android/`. Use the project's documented toolchain PATH for cross-compile per the Android-build notes.)
Expected: `INSTALL` success.

- [ ] **Step 3: Launch on the connected Pixel**

```bash
adb shell am start -n com.keynumber.folino/.MainActivity
```

- [ ] **Step 4: Manual acceptance checks**

Verify on-device (this is the project's primary Android verification path):
1. Fresh state: open the drawer → "Recent" appears directly below "All Scores" with the history icon; tapping it shows the empty state ("まだ楽譜を開いていません").
2. Open a score from All Scores, back out, open Recent → the score appears under **今日**.
3. Open a second score, return to Recent → most-recently-opened is first under 今日.
4. Force-stop + relaunch → Recent still lists the opened scores (Room persisted `last_opened_at`).
5. Add a score to a playlist and a tag, open that score, then visit Playlists / Tags → that playlist / tag has floated to the top (recently-used order).
6. A never-opened score does **not** appear in Recent.

- [ ] **Step 5: Final commit (if any reconciliation edits were needed)**

```bash
git add -A
git commit -m "chore(library/android): reconcile Recent UI after device verification"
```

---

## Self-Review

- **Spec coverage:** §1 Recent destination → Tasks 4,6,7; history-vs-collection (no last-opened sort on All) → respected (All Scores list untouched). §2 non-goals → no remove/CAB (Task 7 read-only), local-only (no sync code), All sort unchanged. §4 wire/Room → Tasks 3,5. §5.1 mostRecentlyOpened untouched → confirmed (not modified). §5.2 classifier → Task 1. §5.3 lifted helpers on ScoreOpenInfo → Task 2. §6 markOpened via openReader → Task 4 (method) + Task 6 (call). §7.1 drawer → Task 6. §7.2 RecentScreen → Task 7. §7.3 playlist/tag order → Task 4. §8 tests → Domain TDD in Tasks 1-2; Android device verification in Task 8.
- **Type consistency:** `RecencyBucket.classify(_:now:calendar:)`, `ScoreOpenInfo(id:lastOpenedAt:tagIDs:)`, `playlistsByRecentlyUsed(_:openInfo:limit:)`, `tagsByRecentlyUsed(_:openInfo:limit:)`, `markOpened(_:)`, `recentToday/recentThisWeek/recentEarlier`, `ScoreRecordWire(... deletedAt:lastOpenedAt:)` — used identically across tasks and the spec.
- **Gate:** Phase 3 (Room) is explicitly gated; Phases 1-2 (Domain + Swift) and Phase 4 (UI) reference the Kotlin `lastOpenedAt` only via regenerated bindings produced after Phase 3 lands, so the full Android build (Phase 5) must run after the gate clears.

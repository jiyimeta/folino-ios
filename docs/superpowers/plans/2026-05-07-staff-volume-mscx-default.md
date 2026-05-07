# Staff Volume — MSCX Default + Persisted Override Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Folino's hard-coded `1.0` per-staff volume with a value sourced from the score's mscx CC7 (`<controller ctrl="7" value="N"/>`), and persist the user's slider adjustment as a per-score override that survives across sessions.

**Architecture:** Three layers. (1) `ReaderPreferences` gains `staffVolumeOverrides: [StaffAddress: Double]` clamped to `[0, 1]`, persisted in a new SQLite column via migration v5. (2) `ReaderViewModel` resolves volume by `liveDrag → override → mscxCC7/127 → 1.0` and follows the same drag-only / commit-persists split tempo already uses. (3) `InspectorView` calls `commitVolume` on slider release; the body of the binding stays the same shape.

**Tech Stack:** Swift 6, SwiftUI / Observation, GRDB, Swift Testing (`@Test`/`#expect`).

**Reference spec:** `docs/superpowers/specs/2026-05-07-staff-volume-mscx-default-design.md`

---

## File Inventory

**Modify:**
- `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift` — new field + init clamp (Task 1)
- `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesTests.swift` — new tests for clamp + Codable (Task 1)
- `Packages/Infrastructure/Sources/Persistence/Records/ReaderPreferencesRecord.swift` — encode / decode the new column (Task 2)
- `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ReaderPreferencesRecordTests.swift` — round-trip tests (Task 2)
- `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift` — add `migrateV5`, `upToV4` (Task 3)
- `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` — `scoreDefaultVolume`, lookup chain, `commitVolume` (Tasks 4–7)
- `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift` — replace existing volume test, add new ones (Tasks 5–6)
- `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift` — engine-seed tests (Task 7)
- `Packages/Features/Reader/Sources/Reader/InspectorView.swift` — slider `onEditingChanged` (Task 8)

**Create:** None.

---

## Task 1: Domain — `staffVolumeOverrides` on `ReaderPreferences`

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift`
- Test: `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesTests.swift`

- [ ] **Step 1.1: Write the failing tests**

Append to `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesTests.swift` (inside the `@Suite struct ReaderPreferencesTests {}` body):

```swift
@Test func staffVolumeOverridesDefaultToEmpty() {
    let prefs = ReaderPreferences(
        scoreItemID: ScoreItemID(),
        staffSize: 14,
        hiddenStaves: []
    )
    #expect(prefs.staffVolumeOverrides.isEmpty)
}

@Test func staffVolumeOverridesAreClampedToZeroThroughOne() {
    let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    let belowRange = ReaderPreferences(
        scoreItemID: ScoreItemID(),
        staffSize: 14,
        hiddenStaves: [],
        staffVolumeOverrides: [address: -0.5]
    )
    #expect(belowRange.staffVolumeOverrides[address] == 0)

    let aboveRange = ReaderPreferences(
        scoreItemID: ScoreItemID(),
        staffSize: 14,
        hiddenStaves: [],
        staffVolumeOverrides: [address: 2.0]
    )
    #expect(aboveRange.staffVolumeOverrides[address] == 1)

    let inRange = ReaderPreferences(
        scoreItemID: ScoreItemID(),
        staffSize: 14,
        hiddenStaves: [],
        staffVolumeOverrides: [address: 0.42]
    )
    #expect(inRange.staffVolumeOverrides[address] == 0.42)
}

@Test func staffVolumeOverridesRoundTripThroughCodable() throws {
    let address1 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    let address2 = StaffAddress(partIndex: 1, staffIndexInPart: 1)
    let prefs = ReaderPreferences(
        scoreItemID: ScoreItemID(),
        staffSize: 14,
        hiddenStaves: [],
        staffVolumeOverrides: [address1: 0.25, address2: 0.8]
    )
    let data = try JSONEncoder().encode(prefs)
    let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
    #expect(decoded.staffVolumeOverrides == prefs.staffVolumeOverrides)
}
```

- [ ] **Step 1.2: Run the tests — expect compile failure**

```bash
swift test --package-path Packages/Domain --filter ReaderPreferencesTests
```

Expected: build error referencing `staffVolumeOverrides` (parameter does not exist).

- [ ] **Step 1.3: Add the property + init parameter**

Edit `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift`. After the `staffProgramOverrides` property declaration, add:

```swift
/// User-chosen volume `[0, 1]` per staff that overrides the score's mscx CC7.
/// Absent entries fall back to the score's `InstrumentChannel.volume`
/// (mapped from `0…127` to `0…1`), then to `1.0` if the score has no
/// matching part. Matches the override-overlay shape of
/// `staffProgramOverrides`.
public var staffVolumeOverrides: [StaffAddress: Double]
```

In the initializer's parameter list — directly after `staffProgramOverrides: [StaffAddress: Int] = [:],` — add:

```swift
staffVolumeOverrides: [StaffAddress: Double] = [:],
```

In the initializer body — after the `self.staffProgramOverrides = ...` clamp line — add:

```swift
self.staffVolumeOverrides = staffVolumeOverrides.mapValues { min(max($0, 0), 1) }
```

- [ ] **Step 1.4: Run the tests — expect pass**

```bash
swift test --package-path Packages/Domain --filter ReaderPreferencesTests
```

Expected: all `ReaderPreferencesTests` tests pass, including the three new ones.

- [ ] **Step 1.5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift \
        Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesTests.swift
git commit -m "$(cat <<'EOF'
feat(domain): add staffVolumeOverrides to ReaderPreferences

Per-staff volume override `[0, 1]`, clamped on init. Parallels the
existing staffProgramOverrides shape; defaults to empty.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Infrastructure — Persist `staffVolumeOverrides` on `ReaderPreferencesRecord`

**Files:**
- Modify: `Packages/Infrastructure/Sources/Persistence/Records/ReaderPreferencesRecord.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ReaderPreferencesRecordTests.swift`

- [ ] **Step 2.1: Write the failing tests**

Append to `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ReaderPreferencesRecordTests.swift` (inside the `@Suite struct ReaderPreferencesRecordTests {}` body):

```swift
@Test func emptyVolumeOverridesEncodesAsEmptyJSON() throws {
    let prefs = ReaderPreferences(
        scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: []
    )
    let record = ReaderPreferencesRecord(domain: prefs)
    #expect(record.staffVolumeOverrides == "[]")
}

@Test func volumeOverridesRoundTripThroughDomain() throws {
    let address1 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    let address2 = StaffAddress(partIndex: 1, staffIndexInPart: 1)
    let prefs = ReaderPreferences(
        scoreItemID: ScoreItemID(),
        staffSize: 14,
        hiddenStaves: [],
        staffVolumeOverrides: [address1: 0.25, address2: 0.75]
    )
    let record = ReaderPreferencesRecord(domain: prefs)
    let restored = try record.toDomain()
    #expect(restored.staffVolumeOverrides == [address1: 0.25, address2: 0.75])
}
```

- [ ] **Step 2.2: Run the tests — expect compile failure**

```bash
swift test --package-path Packages/Infrastructure --filter ReaderPreferencesRecordTests
```

Expected: build error — `staffVolumeOverrides` not a member of `ReaderPreferencesRecord`.

- [ ] **Step 2.3: Add the field, encoding, and decoding**

Edit `Packages/Infrastructure/Sources/Persistence/Records/ReaderPreferencesRecord.swift`.

After the existing `var staffProgramOverrides: String` property line, add:

```swift
var staffVolumeOverrides: String
```

In `enum CodingKeys` — directly after `case staffProgramOverrides = "staff_program_overrides"` — add:

```swift
case staffVolumeOverrides = "staff_volume_overrides"
```

In `init(domain prefs: ReaderPreferences)` — directly after the block that builds `staffProgramOverrides` — add:

```swift
let sortedVolumeOverrides = prefs.staffVolumeOverrides
    .sorted { $0.key < $1.key }
    .map { Self.encodeVolumeTriple(address: $0.key, volume: $0.value) }
let volumeOverridesData = try? JSONEncoder().encode(sortedVolumeOverrides)
staffVolumeOverrides = volumeOverridesData.flatMap {
    String(data: $0, encoding: .utf8)
} ?? "[]"
```

In `func toDomain() throws -> ReaderPreferences` — directly after the existing `decodedOverrides` / `overrides` block (the program-override decode), add:

```swift
let decodedVolumeOverrides: [[Double]] = (try? JSONDecoder().decode(
    [[Double]].self,
    from: Data(staffVolumeOverrides.utf8)
)) ?? []
var volumeOverrides: [StaffAddress: Double] = [:]
for triple in decodedVolumeOverrides where triple.count == 3 {
    let address = StaffAddress(
        partIndex: Int(triple[0]),
        staffIndexInPart: Int(triple[1])
    )
    volumeOverrides[address] = triple[2]
}
```

In the `return ReaderPreferences(...)` call at the bottom of `toDomain()`, add `staffVolumeOverrides: volumeOverrides,` directly after the existing `staffProgramOverrides: overrides,` line.

At the bottom of the file — directly after the existing `private static func encodeTriple(...)` — add:

```swift
private static func encodeVolumeTriple(address: StaffAddress, volume: Double) -> [Double] {
    [Double(address.partIndex), Double(address.staffIndexInPart), volume]
}
```

- [ ] **Step 2.4: Run the tests — expect pass**

```bash
swift test --package-path Packages/Infrastructure --filter ReaderPreferencesRecordTests
```

Expected: all `ReaderPreferencesRecordTests` pass. The pre-existing `encodesAndDecodesViaSQLite` test will still fail until Task 3 lands the `staff_volume_overrides` column. (It runs `AppMigrations.all.migrate(queue)` and then inserts a record; the record now has a column the schema doesn't.) That's expected — defer it to Task 3.

If Step 2.4 reports `encodesAndDecodesViaSQLite` failing with a "no such column: staff_volume_overrides" error, that's the right failure. Proceed to commit; Task 3 fixes it.

- [ ] **Step 2.5: Commit**

```bash
git add Packages/Infrastructure/Sources/Persistence/Records/ReaderPreferencesRecord.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ReaderPreferencesRecordTests.swift
git commit -m "$(cat <<'EOF'
feat(persistence): encode/decode staffVolumeOverrides

Adds the staff_volume_overrides column field to ReaderPreferencesRecord.
Round-trips via the same triple-array JSON shape as staff_program_overrides
but with a Double volume slot. The matching DB migration lands in the
next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Infrastructure — Migration v5

**Files:**
- Modify: `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift`

- [ ] **Step 3.1: Add the migration body and the `upToV4` migrator**

Edit `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift`.

In the `static let all` migrator — directly after `m.registerMigration("v4", migrate: migrateV4)` — add:

```swift
m.registerMigration("v5", migrate: migrateV5)
```

After the `static let upToV3` migrator declaration block, add:

```swift
/// Migrator that registers v1 + v2 + v3 + v4 only — useful for tests
/// that want to exercise a v5 upgrade against rows already inserted at
/// the previous schema.
static let upToV4: DatabaseMigrator = {
    var m = DatabaseMigrator()
    m.registerMigration("v1", migrate: migrateV1)
    m.registerMigration("v2", migrate: migrateV2)
    m.registerMigration("v3", migrate: migrateV3)
    m.registerMigration("v4", migrate: migrateV4)
    return m
}()
```

At the bottom of the file — directly after `migrateV4` — add:

```swift
// MARK: - v5

private static func migrateV5(_ db: Database) throws {
    try db.execute(sql: """
    ALTER TABLE reader_preferences
    ADD COLUMN staff_volume_overrides TEXT NOT NULL DEFAULT '[]'
    """)
}
```

- [ ] **Step 3.2: Run the suite — expect Task 2's deferred test to pass**

```bash
swift test --package-path Packages/Infrastructure --filter ReaderPreferencesRecordTests
```

Expected: `encodesAndDecodesViaSQLite` now passes — the column exists at insert time.

- [ ] **Step 3.3: Add a v4 → v5 upgrade test**

Append to `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ReaderPreferencesRecordTests.swift` (inside the `@Suite struct ReaderPreferencesRecordTests {}` body):

```swift
@Test func migrationV5BackfillsEmptyVolumeOverridesOnExistingRows() throws {
    let queue = try DatabaseQueue()
    try AppMigrations.upToV4.migrate(queue)

    let scoreID = ScoreItemID()
    let prefsID = ReaderPreferencesID()
    try queue.write { db in
        try db.execute(
            sql: """
            INSERT INTO score_items (id, title, local_file_name, content_hash,
                size_bytes, length_beats, default_tempo_bpm, added_at)
            VALUES (?, 'T', 'f.mscx', 'h', 0, 0, 120, 0)
            """,
            arguments: [scoreID.rawValue.uuidString]
        )
        try db.execute(
            sql: """
            INSERT INTO reader_preferences (
                id, score_item_id, staff_size, hidden_staff_ids,
                staff_program_overrides, honor_layout_breaks
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                prefsID.rawValue.uuidString,
                scoreID.rawValue.uuidString,
                14.0,
                "[]",
                "[]",
                1,
            ]
        )
    }

    try AppMigrations.all.migrate(queue)

    let fetched = try queue.read {
        try ReaderPreferencesRecord
            .filter(Column("score_item_id") == scoreID.rawValue.uuidString)
            .fetchOne($0)
    }
    let unwrapped = try #require(fetched)
    #expect(unwrapped.staffVolumeOverrides == "[]")
    let restored = try unwrapped.toDomain()
    #expect(restored.staffVolumeOverrides.isEmpty)
}
```

- [ ] **Step 3.4: Run the new test — expect pass**

```bash
swift test --package-path Packages/Infrastructure --filter ReaderPreferencesRecordTests/migrationV5BackfillsEmptyVolumeOverridesOnExistingRows
```

Expected: pass. (The test imports `Domain` for `ReaderPreferencesID`; if your suite uses `import Domain` already at the top of the file, no change is needed — verify the existing file has `import Domain` and add it only if missing.)

- [ ] **Step 3.5: Commit**

```bash
git add Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ReaderPreferencesRecordTests.swift
git commit -m "$(cat <<'EOF'
feat(persistence): add migration v5 for staff_volume_overrides column

Additive ALTER TABLE that backfills existing rows with '[]'. Adds an
upToV4 migrator parallel to upToV2/upToV3 so the v5-step test can
construct a pre-migration row.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: ReaderViewModel — `scoreDefaultVolume(for:)`

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Test: (added in Task 5 alongside the lookup change)

- [ ] **Step 4.1: Add the helper**

Edit `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`.

Directly after the existing `private func scoreDefaultBank(for address: StaffAddress) -> Int? { ... }` method, add:

```swift
/// CC7 (Channel Volume) from the part's first channel, mapped from
/// MIDI's 0…127 to the slider's 0…1. Returns nil when the score has no
/// matching part — callers fall back to `defaultStaffVolume`. Mirrors
/// `swift-sheet-music`'s `PlaybackEngine.initialStaffVolume`.
private func scoreDefaultVolume(for address: StaffAddress) -> Double? {
    guard
        case let .loaded(score) = loadState,
        score.parts.indices.contains(address.partIndex)
    else { return nil }
    let cc7 = score.parts[address.partIndex].instrument.channel.volume
    let clamped = max(0, min(127, cc7))
    return Double(clamped) / 127.0
}
```

- [ ] **Step 4.2: Build to confirm no syntax break**

```bash
swift build --package-path Packages/Features/Reader
```

Expected: build succeeds. (No call sites yet — that's Task 5.)

- [ ] **Step 4.3: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift
git commit -m "$(cat <<'EOF'
feat(reader): add scoreDefaultVolume helper for mscx CC7 → 0…1 mapping

Used by the upcoming volume(for:) merge chain and engine seeding —
returns nil for scores missing the part so callers fall back to the
defaultStaffVolume.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: ReaderViewModel — Replace `staffVolumes` with the merge chain

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift`

- [ ] **Step 5.1: Replace the existing volume test with mscx-aware tests**

In `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift`, delete the existing `staffVolumeDefaultsToOneAndIsClampedOnSet` test (lines 194–207).

In its place, paste:

```swift
@Test func volumeFallsBackToOneWhenLoadStateHasNoParts() {
    let vm = makeVMNoLoad()
    let address = StaffAddress(partIndex: 0, staffIndexInPart: 1)
    #expect(vm.volume(for: address) == 1.0)
}

@Test func volumeUsesScoreCC7WhenNoOverride() async {
    let item = Self.makeItem()
    let repo = FakeScoreLibraryRepository()
    repo.scoreItems = [item]
    let score = Score(
        division: 480,
        parts: [
            Part(
                id: "P0", trackName: "Vn",
                instrument: Instrument(id: "v", channels: [InstrumentChannel(volume: 64)]),
                staves: [Staff()]
            ),
        ],
        metaTags: [:]
    )
    let vm = ReaderViewModel(
        scoreItem: item, repository: repo,
        gateway: FakeScoreFileGateway(loadScoreResult: .success((
            score: score,
            summary: ScoreFileSummary(
                title: "T", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
            )
        ))),
        scoresDirectory: URL(filePath: "/tmp"),
        defaultStaffSize: 14
    )
    await vm.load()
    let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    let value = vm.volume(for: address)
    #expect(abs(value - 64.0 / 127.0) < 0.0001)
}

@Test func volumeUsesPersistedOverrideWhenPresent() async {
    let item = Self.makeItem()
    let repo = FakeScoreLibraryRepository()
    repo.scoreItems = [item]
    let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    repo.storedReaderPreferences[item.id] = ReaderPreferences(
        scoreItemID: item.id,
        staffSize: 14,
        hiddenStaves: [],
        staffVolumeOverrides: [address: 0.3]
    )
    let score = Score(
        division: 480,
        parts: [
            Part(
                id: "P0", trackName: "Vn",
                instrument: Instrument(id: "v", channels: [InstrumentChannel(volume: 100)]),
                staves: [Staff()]
            ),
        ],
        metaTags: [:]
    )
    let vm = ReaderViewModel(
        scoreItem: item, repository: repo,
        gateway: FakeScoreFileGateway(loadScoreResult: .success((
            score: score,
            summary: ScoreFileSummary(
                title: "T", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
            )
        ))),
        scoresDirectory: URL(filePath: "/tmp"),
        defaultStaffSize: 14
    )
    await vm.load()
    #expect(vm.volume(for: address) == 0.3)
}
```

- [ ] **Step 5.2: Run the tests — expect compile failure**

```bash
swift test --package-path Packages/Features/Reader --filter ReaderViewModelTests
```

Expected: build fails on `staffVolumeOverrides` (the lookup chain isn't there yet) and/or runtime failure (`vm.volume` still hits the old `staffVolumes` path returning 1.0 even when CC7 = 64).

- [ ] **Step 5.3: Rename `staffVolumes` → `liveStaffVolumes` and rewire `volume(for:)`**

In `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`, locate the line:

```swift
public private(set) var staffVolumes: [StaffAddress: Double] = [:]
```

Replace with:

```swift
/// Transient per-staff volume during a slider drag. Populated by
/// `setVolume`, cleared by `commitVolume`. Lives on the VM so SwiftUI
/// re-renders the slider as the value moves.
public private(set) var liveStaffVolumes: [StaffAddress: Double] = [:]
```

Locate `volume(for:)`:

```swift
public func volume(for address: StaffAddress) -> Double {
    staffVolumes[address] ?? Self.defaultStaffVolume
}
```

Replace with:

```swift
public func volume(for address: StaffAddress) -> Double {
    liveStaffVolumes[address]
        ?? preferences.staffVolumeOverrides[address]
        ?? scoreDefaultVolume(for: address)
        ?? Self.defaultStaffVolume
}
```

Locate `setVolume(_:for:)`:

```swift
public func setVolume(_ value: Double, for address: StaffAddress) {
    let clamped = min(max(value, 0), 1)
    staffVolumes[address] = clamped
    guard let flatIndex = flattenedStaffIndex(for: address) else { return }
    Task { await playbackController?.setStaffVolume(staff: flatIndex, volume: clamped) }
}
```

Replace with:

```swift
public func setVolume(_ value: Double, for address: StaffAddress) {
    let clamped = min(max(value, 0), 1)
    liveStaffVolumes[address] = clamped
    guard let flatIndex = flattenedStaffIndex(for: address) else { return }
    Task { await playbackController?.setStaffVolume(staff: flatIndex, volume: clamped) }
}
```

- [ ] **Step 5.4: Update `mutatePreferences` and `initialPlaybackPreferences` reads**

Locate `mutatePreferences`. The struct is rebuilt field-by-field in:

```swift
let normalized = ReaderPreferences(
    id: copy.id,
    scoreItemID: copy.scoreItemID,
    staffSize: copy.staffSize,
    hiddenStaves: copy.hiddenStaves,
    staffProgramOverrides: copy.staffProgramOverrides,
    tempoMultiplier: copy.tempoMultiplier,
    honorLayoutBreaks: copy.honorLayoutBreaks
)
```

Replace with:

```swift
let normalized = ReaderPreferences(
    id: copy.id,
    scoreItemID: copy.scoreItemID,
    staffSize: copy.staffSize,
    hiddenStaves: copy.hiddenStaves,
    staffProgramOverrides: copy.staffProgramOverrides,
    staffVolumeOverrides: copy.staffVolumeOverrides,
    tempoMultiplier: copy.tempoMultiplier,
    honorLayoutBreaks: copy.honorLayoutBreaks
)
```

Locate `initialPlaybackPreferences(for:)`. The line that reads `staffVolumes`:

```swift
volume: staffVolumes[entry.address] ?? Self.defaultStaffVolume,
```

Replace with:

```swift
volume: preferences.staffVolumeOverrides[entry.address]
    ?? scoreDefaultVolume(for: entry.address)
    ?? Self.defaultStaffVolume,
```

- [ ] **Step 5.5: Run the tests — expect pass**

```bash
swift test --package-path Packages/Features/Reader --filter ReaderViewModelTests
```

Expected: all `ReaderViewModelTests` pass, including the three new ones from Step 5.1.

- [ ] **Step 5.6: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(reader): resolve staff volume via override → mscx CC7 → 1.0

Renames the transient drag dict to liveStaffVolumes, and routes
volume(for:) and the engine-seed lookup through preferences.staffVolumeOverrides
falling back to the score's CC7 (mapped 0…127 to 0…1). Tests cover
the three branches.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: ReaderViewModel — Add `commitVolume`

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift`

- [ ] **Step 6.1: Write the failing tests**

Append to `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift` (inside the `@Suite @MainActor struct ReaderViewModelTests {}` body, just above the trailing `private func makeVMNoLoad()` helper):

```swift
@Test func setVolumeUpdatesLiveDictWithoutPersisting() async {
    let item = Self.makeItem()
    let repo = FakeScoreLibraryRepository()
    repo.scoreItems = [item]
    let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    let score = Score(
        division: 480,
        parts: [
            Part(
                id: "P0", trackName: "Vn",
                instrument: Instrument(id: "v", channels: [InstrumentChannel(volume: 100)]),
                staves: [Staff()]
            ),
        ],
        metaTags: [:]
    )
    let vm = ReaderViewModel(
        scoreItem: item, repository: repo,
        gateway: FakeScoreFileGateway(loadScoreResult: .success((
            score: score,
            summary: ScoreFileSummary(
                title: "T", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
            )
        ))),
        scoresDirectory: URL(filePath: "/tmp"),
        defaultStaffSize: 14
    )
    await vm.load()
    let savesBefore = repo.savedReaderPreferences.count

    vm.setVolume(0.4, for: address)

    #expect(vm.liveStaffVolumes[address] == 0.4)
    #expect(vm.volume(for: address) == 0.4)
    #expect(vm.preferences.staffVolumeOverrides[address] == nil)
    #expect(repo.savedReaderPreferences.count == savesBefore)
}

@Test func commitVolumePersistsOverrideAndClearsLiveValue() async {
    let item = Self.makeItem()
    let repo = FakeScoreLibraryRepository()
    repo.scoreItems = [item]
    let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    let score = Score(
        division: 480,
        parts: [
            Part(
                id: "P0", trackName: "Vn",
                instrument: Instrument(id: "v", channels: [InstrumentChannel(volume: 100)]),
                staves: [Staff()]
            ),
        ],
        metaTags: [:]
    )
    let vm = ReaderViewModel(
        scoreItem: item, repository: repo,
        gateway: FakeScoreFileGateway(loadScoreResult: .success((
            score: score,
            summary: ScoreFileSummary(
                title: "T", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
            )
        ))),
        scoresDirectory: URL(filePath: "/tmp"),
        defaultStaffSize: 14
    )
    await vm.load()
    vm.setVolume(0.4, for: address)
    let savesBefore = repo.savedReaderPreferences.count

    await vm.commitVolume(0.4, for: address)

    #expect(vm.preferences.staffVolumeOverrides[address] == 0.4)
    #expect(vm.liveStaffVolumes[address] == nil)
    #expect(vm.volume(for: address) == 0.4)
    #expect(repo.savedReaderPreferences.count == savesBefore + 1)
}

@Test func commitVolumeClampsOutOfRangeValues() async {
    let item = Self.makeItem()
    let repo = FakeScoreLibraryRepository()
    repo.scoreItems = [item]
    let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    let score = Score(
        division: 480,
        parts: [
            Part(
                id: "P0", trackName: "Vn",
                instrument: Instrument(id: "v"), staves: [Staff()]
            ),
        ],
        metaTags: [:]
    )
    let vm = ReaderViewModel(
        scoreItem: item, repository: repo,
        gateway: FakeScoreFileGateway(loadScoreResult: .success((
            score: score,
            summary: ScoreFileSummary(
                title: "T", composer: nil, instrumentationSummary: "",
                lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil
            )
        ))),
        scoresDirectory: URL(filePath: "/tmp"),
        defaultStaffSize: 14
    )
    await vm.load()

    await vm.commitVolume(-0.5, for: address)
    #expect(vm.preferences.staffVolumeOverrides[address] == 0)

    await vm.commitVolume(2.0, for: address)
    #expect(vm.preferences.staffVolumeOverrides[address] == 1)
}
```

- [ ] **Step 6.2: Run the tests — expect compile failure**

```bash
swift test --package-path Packages/Features/Reader --filter ReaderViewModelTests
```

Expected: build error — `commitVolume` is not a member of `ReaderViewModel`.

- [ ] **Step 6.3: Implement `commitVolume`**

Edit `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`. Directly after the existing `setVolume(_:for:)` method body, add:

```swift
/// Slider release: persist the value as the per-score override and
/// clear the transient drag entry. Forwards to the engine so the
/// post-clamp value is what gets played.
public func commitVolume(_ value: Double, for address: StaffAddress) async {
    let clamped = min(max(value, 0), 1)
    await mutatePreferences { $0.staffVolumeOverrides[address] = clamped }
    liveStaffVolumes[address] = nil
    guard let flatIndex = flattenedStaffIndex(for: address) else { return }
    await playbackController?.setStaffVolume(staff: flatIndex, volume: clamped)
}
```

- [ ] **Step 6.4: Run the tests — expect pass**

```bash
swift test --package-path Packages/Features/Reader --filter ReaderViewModelTests
```

Expected: all three new tests pass.

- [ ] **Step 6.5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(reader): add commitVolume for slider-release persistence

setVolume stays drag-only (engine + liveStaffVolumes); commitVolume
clamps the value, writes it through ReaderPreferences (mutatePreferences),
clears the transient entry, and forwards to the engine. Mirrors the
two-stage tempo pattern.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: ReaderViewModel — Engine seeding via override / mscx

**Files:**
- Modify: (none — Task 5 already updated `initialPlaybackPreferences`)
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift`

- [ ] **Step 7.1: Write the failing tests**

Append to `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift` (inside the `@Suite @MainActor struct ReaderViewModelPlaybackTests {}` body, just before the closing `}`):

```swift
@Test func engineSeedUsesPersistedOverrideOverMscx() async {
    let item = Self.makeItem()
    let repo = FakeScoreLibraryRepository()
    repo.scoreItems = [item]
    let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    repo.storedReaderPreferences[item.id] = ReaderPreferences(
        scoreItemID: item.id,
        staffSize: 14,
        hiddenStaves: [],
        staffVolumeOverrides: [address: 0.3]
    )
    let score = Score(
        division: 480,
        parts: [
            Part(
                id: "P0", trackName: "Vn",
                instrument: Instrument(id: "v", channels: [InstrumentChannel(volume: 100)]),
                staves: [Staff()]
            ),
        ],
        metaTags: [:]
    )
    let controller = FakePlaybackController()
    let vm = ReaderViewModel(
        scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
        scoresDirectory: URL(filePath: "/tmp"),
        playbackController: controller
    )
    await vm.load()
    await vm.prepareForPlayback()

    let seeded = try #require(controller.lastLoadedPreferences)
    let staff0 = try #require(seeded.perStaff.first { $0.staffIndex == 0 })
    #expect(staff0.volume == 0.3)
}

@Test func engineSeedUsesMscxWhenNoOverride() async {
    let item = Self.makeItem()
    let repo = FakeScoreLibraryRepository()
    repo.scoreItems = [item]
    let score = Score(
        division: 480,
        parts: [
            Part(
                id: "P0", trackName: "Vn",
                instrument: Instrument(id: "v", channels: [InstrumentChannel(volume: 80)]),
                staves: [Staff()]
            ),
        ],
        metaTags: [:]
    )
    let controller = FakePlaybackController()
    let vm = ReaderViewModel(
        scoreItem: item, repository: repo, gateway: Self.makeGateway(score: score),
        scoresDirectory: URL(filePath: "/tmp"),
        playbackController: controller
    )
    await vm.load()
    await vm.prepareForPlayback()

    let seeded = try #require(controller.lastLoadedPreferences)
    let staff0 = try #require(seeded.perStaff.first { $0.staffIndex == 0 })
    #expect(abs(staff0.volume - 80.0 / 127.0) < 0.0001)
}
```

- [ ] **Step 7.2: Run the tests — expect pass**

```bash
swift test --package-path Packages/Features/Reader --filter ReaderViewModelPlaybackTests
```

Expected: all `ReaderViewModelPlaybackTests` pass, including the two new ones. (Task 5 already wired `initialPlaybackPreferences` through the merge chain — these tests verify it.)

- [ ] **Step 7.3: Commit**

```bash
git add Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift
git commit -m "$(cat <<'EOF'
test(reader): cover engine seed using override and mscx CC7

Adds two cases to ReaderViewModelPlaybackTests pinning the
initialPlaybackPreferences merge chain — override wins when present,
mscx CC7 wins when no override is set.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: InspectorView — Slider drag/commit wiring

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/InspectorView.swift`

- [ ] **Step 8.1: Replace the staff slider with the two-stage variant**

In `Packages/Features/Reader/Sources/Reader/InspectorView.swift`, locate the staff row block (currently lines 218–229):

```swift
@ViewBuilder
private func staffRow(address: StaffAddress) -> some View {
    let volumeBinding = Binding<Double>(
        get: { viewModel.volume(for: address) },
        set: { viewModel.setVolume($0, for: address) }
    )
    let isMuted = viewModel.mutedStaves.contains(address)
    let isSolo = viewModel.soloStaves.contains(address)
    VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 8) {
            Slider(value: volumeBinding, in: 0 ... 1)
                .disabled(isMuted || !viewModel.soloStaves.isEmpty && !isSolo)
                .padding(.vertical, -8)
```

Replace the `Slider(...)` line and its `.disabled(...)` / `.padding(...)` modifiers with:

```swift
            Slider(
                value: volumeBinding,
                in: 0 ... 1,
                onEditingChanged: { editing in
                    if !editing {
                        let final = volumeBinding.wrappedValue
                        Task { await viewModel.commitVolume(final, for: address) }
                    }
                }
            )
            .disabled(isMuted || !viewModel.soloStaves.isEmpty && !isSolo)
            .padding(.vertical, -8)
```

`volumeBinding`'s `set` already routes through `setVolume`, so drag updates flow through `liveStaffVolumes`; release falls into `onEditingChanged: false` and persists.

- [ ] **Step 8.2: Build the Reader package**

```bash
swift build --package-path Packages/Features/Reader
```

Expected: build succeeds.

- [ ] **Step 8.3: Render the existing `#Preview` and confirm the slider seeds at the mscx default**

Use the Xcode tab whose workspace is `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Folino.xcodeproj` (per the global iOS workflow in `~/.claude/CLAUDE.md`). The Folino project includes `InspectorView.swift` and its `#Preview`.

```
mcp__xcode__RenderPreview
  tabIdentifier:   <the windowtab whose workspace ends in /Folino-iOS/Folino.xcodeproj>
  filePath:        Packages/Features/Reader/Sources/Reader/InspectorView.swift
  previewIndex:    0    # the existing default preview
```

Read the resulting PNG. Expected: the staff slider thumbs are not all at the rightmost position (`1.0`); they reflect whatever CC7 the preview's fixture score declares (or `100/127 ≈ 0.787` if the fixture uses the InstrumentChannel default).

If the preview fixture has CC7 = 100 by default, the visual difference vs. before is modest — confirm by inspecting the rendered slider thumb position. A value at exactly the right edge means the merge chain isn't wired up; redo Task 5.

- [ ] **Step 8.4: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/InspectorView.swift
git commit -m "$(cat <<'EOF'
feat(reader): persist staff volume on slider release

Slider drag still drives engine + liveStaffVolumes via setVolume;
onEditingChanged: false now calls commitVolume, which writes the
override into ReaderPreferences. The binding shape is unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Final verification

**Files:** none — runs the full suite and a simulator smoke test.

- [ ] **Step 9.1: Run every package's tests**

```bash
swift test --package-path Packages/Domain
swift test --package-path Packages/Infrastructure
swift test --package-path Packages/Features/Reader
```

Expected: all green. If anything red, diagnose before continuing.

- [ ] **Step 9.2: Build the iOS app**

Use the project's documented build path. `~/.claude/CLAUDE.md` notes that iOS-26-era plugin trust may require building from Xcode, but `xcodebuild` from CLI works for clean builds:

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation build
```

Expected: build succeeds. Any compile error here means a call site to `staffVolumes` was missed — search and fix.

- [ ] **Step 9.3: Manual simulator smoke test**

Steps:

1. Boot a simulator (`xcrun simctl boot <UDID>`) and `xcrun simctl install` / `launch` the built app, OR launch via Xcode.
2. Open a score whose mscx has at least one part with CC7 != 100 (the existing fixture set has one — reuse the score used by program-override tests).
3. Open the Inspector. Confirm the staff slider thumbs are not at unity — they reflect the mscx values.
4. Drag a slider, release. The thumb stays at the released position.
5. Background the app, kill it, relaunch it, reopen the same score. The slider remains where you left it (override loaded from DB).
6. For a slider you have NOT touched, the thumb still reflects the mscx default — no override was written.

Hand control to the user for Step 3–6. Describe what to verify; do NOT script gestures.

- [ ] **Step 9.4: Final summary commit (if any tidy-ups)**

If steps 1–3 surface lint warnings or doc-comment touch-ups, fix them now, run tests once more, and commit. Otherwise this step is a no-op.

---

## Self-Review Notes

- **Spec coverage:** Goals 1–3 of the spec map to Tasks 1, 5, 7. Non-goals are honored (no reset UI, no mute/solo persistence, no metronome volume). Behaviour-matrix rows are each covered by tests in Tasks 5, 6, 7.
- **Type consistency:** `commitVolume` is referenced consistently from the InspectorView change in Task 8 and the tests in Task 6. `liveStaffVolumes`, `staffVolumeOverrides`, and `scoreDefaultVolume(for:)` keep their names across all task references.
- **Migration safety:** v5 is purely additive — pre-existing rows get `staff_volume_overrides = '[]'`, decoded as an empty dict. Test `migrationV5BackfillsEmptyVolumeOverridesOnExistingRows` pins this.
- **Test parity with existing patterns:** Domain tests follow the `staffProgramOverrides` shape exactly. Record tests follow the same. VM tests reuse the `FakeScoreLibraryRepository` / `FakePlaybackController` already used by neighbouring tests.

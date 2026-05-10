# Reader Staff Clef Override Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-staff default clef picker to the Reader inspector's Visual tab, persisted per score, applied as a display-only override on the rendered Score; while restructuring the Visual tab, also relocate the per-staff visibility (eye) toggle from the Playback tab.

**Architecture:** Domain stores the override map as `[StaffAddress: String]` (rawType strings — keeps Domain's dependency on `SheetMusicCore` only, avoids `SheetMusicLayout`). Reader-side `Score.applying(clefOverrides:)` rewrites the staff's opening clef before the existing `filtered(hidingStaves:)` step (filter reindexes, so override must run first). Inspector's Visual tab gains per-Part sections that mirror the Playback tab's structure; each staff row becomes `[Clef Menu] [Eye]`.

**Tech Stack:** Swift 6.3, SwiftUI, GRDB (SQLite), Swift Testing, swift-sheet-music ≥ `8f96b11`.

**Spec:** `docs/superpowers/specs/2026-05-10-reader-staff-clef-override-design.md`

---

## File Map

**Created**

- `Packages/Features/Reader/Sources/Reader/Score+ApplyingClefOverrides.swift` — pure `Score` transformation.
- `Packages/Features/Reader/Tests/ReaderTests/ScoreApplyingClefOverridesTests.swift` — transformation tests.
- `Packages/Features/Reader/Sources/Reader/Views/ClefMenuChoice.swift` — Reader-internal enum naming the v1 picker vocabulary (rawType + display label + family grouping).

**Modified**

- `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift` — add `staffClefOverrides`.
- `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesTests.swift` — round-trip + legacy decode + invalid-rawType drop.
- `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift` — add `migrateV6`.
- `Packages/Infrastructure/Sources/Persistence/Records/ReaderPreferencesRecord.swift` — add column + JSON encode/decode for `staffClefOverrides`.
- `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ReaderPreferencesRecordTests.swift` — round-trip + empty case + SQLite migration test.
- `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` — `effectiveClef` / `hasClefOverride` / `setClefOverride` / `clearClefOverride`.
- `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift` — VM behavior.
- `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift` — apply overrides before filter.
- `Packages/Features/Reader/Sources/Reader/Screens/InspectorScreen.swift` — restructure Visual tab, add clef menu, drop eye from Playback tab.
- `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings` — five new keys.

---

## Task 1: Domain — `staffClefOverrides` field

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift`
- Test: `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesTests.swift` (inside the `@Suite struct ReaderPreferencesTests` body):

```swift
@Test func clefOverrideRoundTripsThroughCodable() throws {
    let address = StaffAddress(partIndex: 0, staffIndexInPart: 1)
    let prefs = ReaderPreferences(
        scoreItemID: ScoreItemID(),
        staffSize: 14,
        hiddenStaves: [],
        staffClefOverrides: [address: "G8vb"]
    )
    let data = try JSONEncoder().encode(prefs)
    let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
    #expect(decoded.staffClefOverrides == [address: "G8vb"])
}

@Test func clefOverrideDecodesAsEmptyWhenAbsentFromJSON() throws {
    // Hand-crafted JSON missing `staffClefOverrides` (legacy shape).
    let scoreID = ScoreItemID()
    let prefsID = ReaderPreferencesID()
    let json = """
    {
      "id": { "rawValue": "\(prefsID.rawValue.uuidString)" },
      "scoreItemID": { "rawValue": "\(scoreID.rawValue.uuidString)" },
      "staffSize": 14,
      "hiddenStaves": [],
      "staffProgramOverrides": {},
      "staffVolumeOverrides": {}
    }
    """
    let decoded = try JSONDecoder().decode(
        ReaderPreferences.self, from: Data(json.utf8)
    )
    #expect(decoded.staffClefOverrides.isEmpty)
}

@Test func clefOverrideInitializerDropsUnknownRawType() {
    let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    let prefs = ReaderPreferences(
        scoreItemID: ScoreItemID(),
        staffSize: 14,
        hiddenStaves: [],
        staffClefOverrides: [address: "not-a-real-clef"]
    )
    #expect(prefs.staffClefOverrides.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/Domain && swift test --filter ReaderPreferencesTests/clefOverrideRoundTripsThroughCodable`
Expected: FAIL — `Argument passed to call that takes no arguments` or `Cannot find 'staffClefOverrides' in scope`.

- [ ] **Step 3: Add the field**

Modify `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift`. Inside the struct, after `staffVolumeOverrides`:

```swift
/// User-chosen display-only clef per staff that overrides the score's
/// authored opening clef. Values are `NotatedClef.rawType` strings
/// (e.g. `"G"`, `"G8vb"`, `"F8va"`, `"alto"`). Stored as `String` to
/// avoid pulling `SheetMusicLayout` into Domain — the Reader feature
/// converts via `NotatedClef(rawType:)` at the use site. Unknown
/// rawTypes are dropped by the initializer.
public var staffClefOverrides: [StaffAddress: String]
```

Add the parameter to the initializer signature (after `staffVolumeOverrides:`):

```swift
staffClefOverrides: [StaffAddress: String] = [:],
```

In the initializer body, after the existing `staffVolumeOverrides` clamp, drop unknown rawTypes:

```swift
self.staffClefOverrides = staffClefOverrides.filter { _, raw in
    Self.knownClefRawTypes.contains(raw)
}
```

Add the static set near the other static constants at the top of the struct:

```swift
/// Allow-list of `NotatedClef.rawType` values the Domain initializer
/// accepts. Mirrors `NotatedClef`'s parseable forms in
/// `swift-sheet-music`. Kept here as a literal set so Domain stays
/// `SheetMusicCore`-only.
public static let knownClefRawTypes: Set<String> = [
    "G", "G8va", "G8vb", "G15ma", "G15mb",
    "F", "F8va", "F8vb",
    "C3", "C4",
    "PERC",
]
```

Add `staffClefOverrides` to `CodingKeys`:

```swift
private enum CodingKeys: String, CodingKey {
    case id, scoreItemID, staffSize, hiddenStaves, staffProgramOverrides
    case staffVolumeOverrides, tempoMultiplier, honorLayoutBreaks
    case repeatMode, abRepeat
    case staffClefOverrides
}
```

In `init(from:)`, after the existing `volumeOverrides` decode and before `self.init(...)`:

```swift
let clefOverrides = try c.decodeIfPresent(
    [StaffAddress: String].self, forKey: .staffClefOverrides
) ?? [:]
```

Pass it through to the designated init call:

```swift
self.init(
    id: id, scoreItemID: scoreItemID, staffSize: staffSize,
    hiddenStaves: hiddenStaves, staffProgramOverrides: programOverrides,
    staffVolumeOverrides: volumeOverrides,
    staffClefOverrides: clefOverrides,
    tempoMultiplier: tempo,
    honorLayoutBreaks: honorBreaks, repeatMode: mode, abRepeat: ab
)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/Domain && swift test --filter ReaderPreferencesTests`
Expected: PASS — all three new tests + existing tests still green.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesTests.swift
git commit -m "Domain: add staffClefOverrides to ReaderPreferences"
```

---

## Task 2: Persistence — SQLite migration v6 + record round-trip

**Files:**
- Modify: `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift`
- Modify: `Packages/Infrastructure/Sources/Persistence/Records/ReaderPreferencesRecord.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ReaderPreferencesRecordTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ReaderPreferencesRecordTests.swift`:

```swift
@Test func emptyClefOverridesEncodesAsEmptyJSON() throws {
    let prefs = ReaderPreferences(
        scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: []
    )
    let record = ReaderPreferencesRecord(domain: prefs)
    #expect(record.staffClefOverrides == "[]")
}

@Test func clefOverridesRoundTripThroughDomain() throws {
    let address1 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    let address2 = StaffAddress(partIndex: 1, staffIndexInPart: 1)
    let prefs = ReaderPreferences(
        scoreItemID: ScoreItemID(),
        staffSize: 14,
        hiddenStaves: [],
        staffClefOverrides: [address1: "G8vb", address2: "F"]
    )
    let record = ReaderPreferencesRecord(domain: prefs)
    let restored = try record.toDomain()
    #expect(restored.staffClefOverrides == [address1: "G8vb", address2: "F"])
}

@Test func clefOverridesPersistThroughSQLite() throws {
    let queue = try DatabaseQueue()
    try AppMigrations.all.migrate(queue)
    let scoreID = ScoreItemID()
    try queue.write { db in
        try db.execute(
            sql: """
            INSERT INTO score_items (id, title, local_file_name, content_hash,
                size_bytes, length_beats, default_tempo_bpm, added_at)
            VALUES (?, 'T', 'f.mscx', 'h', 0, 0, 120, 0)
            """,
            arguments: [scoreID.rawValue.uuidString]
        )
    }
    let address = StaffAddress(partIndex: 0, staffIndexInPart: 1)
    let prefs = ReaderPreferences(
        scoreItemID: scoreID,
        staffSize: 14,
        hiddenStaves: [],
        staffClefOverrides: [address: "G8vb"]
    )
    try queue.write { try ReaderPreferencesRecord(domain: prefs).save($0) }
    let fetched = try queue.read {
        try ReaderPreferencesRecord
            .filter(Column("score_item_id") == scoreID.rawValue.uuidString)
            .fetchOne($0)
    }
    let unwrapped = try #require(fetched)
    let restored = try unwrapped.toDomain()
    #expect(restored.staffClefOverrides == [address: "G8vb"])
}

@Test func v6MigrationAddsColumnWithEmptyDefault() throws {
    let queue = try DatabaseQueue()
    try AppMigrations.upToV5.migrate(queue)
    let scoreID = ScoreItemID()
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
                staff_program_overrides, staff_volume_overrides, honor_layout_breaks
            ) VALUES (?, ?, 14, '[]', '[]', '[]', 1)
            """,
            arguments: [UUID().uuidString, scoreID.rawValue.uuidString]
        )
    }
    try AppMigrations.all.migrate(queue)
    let value: String? = try queue.read { db in
        try String.fetchOne(
            db,
            sql: "SELECT staff_clef_overrides FROM reader_preferences WHERE score_item_id = ?",
            arguments: [scoreID.rawValue.uuidString]
        )
    }
    #expect(value == "[]")
}
```

In the same file's `AppMigrations` namespace test surface, also add an `upToV5` migrator constant. Open `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift` and add (right after `upToV4`):

```swift
/// Migrator that registers v1 + v2 + v3 + v4 + v5 only — useful for
/// tests that want to exercise a v6 upgrade against rows already
/// inserted at the previous schema.
static let upToV5: DatabaseMigrator = {
    var m = DatabaseMigrator()
    m.registerMigration("v1", migrate: migrateV1)
    m.registerMigration("v2", migrate: migrateV2)
    m.registerMigration("v3", migrate: migrateV3)
    m.registerMigration("v4", migrate: migrateV4)
    m.registerMigration("v5", migrate: migrateV5)
    return m
}()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/Infrastructure && swift test --filter ReaderPreferencesRecordTests/emptyClefOverridesEncodesAsEmptyJSON`
Expected: FAIL — `Cannot find 'upToV5' in type 'AppMigrations'` and/or `staffClefOverrides` not a member of `ReaderPreferencesRecord`.

- [ ] **Step 3: Register `migrateV6` in the migrator chain**

In `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift`, inside the `static let all` block, append `m.registerMigration("v6", migrate: migrateV6)` after the v5 line:

```swift
static let all: DatabaseMigrator = {
    var m = DatabaseMigrator()
    m.registerMigration("v1", migrate: migrateV1)
    m.registerMigration("v2", migrate: migrateV2)
    m.registerMigration("v3", migrate: migrateV3)
    m.registerMigration("v4", migrate: migrateV4)
    m.registerMigration("v5", migrate: migrateV5)
    m.registerMigration("v6", migrate: migrateV6)
    return m
}()
```

At the bottom of the file (after `migrateV5`):

```swift
// MARK: - v6

private static func migrateV6(_ db: Database) throws {
    try db.execute(sql: """
    ALTER TABLE reader_preferences
    ADD COLUMN staff_clef_overrides TEXT NOT NULL DEFAULT '[]'
    """)
}
```

- [ ] **Step 4: Add the column to `ReaderPreferencesRecord`**

In `Packages/Infrastructure/Sources/Persistence/Records/ReaderPreferencesRecord.swift`:

Add the property after `staffVolumeOverrides`:

```swift
var staffClefOverrides: String
```

Add the coding key:

```swift
case staffClefOverrides = "staff_clef_overrides"
```

In `init(domain:)`, after the existing volume-overrides block:

```swift
let sortedClefOverrides = prefs.staffClefOverrides
    .sorted { $0.key < $1.key }
    .map { Self.encodeClefTriple(address: $0.key, rawType: $0.value) }
let clefOverridesData = try? JSONEncoder().encode(sortedClefOverrides)
staffClefOverrides = clefOverridesData.flatMap {
    String(data: $0, encoding: .utf8)
} ?? "[]"
```

In `toDomain()`, after the volume-overrides decoding:

```swift
struct ClefTripleRow: Decodable {
    let partIndex: Int
    let staffIndexInPart: Int
    let rawType: String
}
let decodedClefOverrides: [ClefTripleRow] = (try? JSONDecoder().decode(
    [ClefTripleRow].self,
    from: Data(staffClefOverrides.utf8)
)) ?? []
var clefOverrides: [StaffAddress: String] = [:]
for row in decodedClefOverrides {
    let address = StaffAddress(
        partIndex: row.partIndex,
        staffIndexInPart: row.staffIndexInPart
    )
    clefOverrides[address] = row.rawType
}
```

Add `staffClefOverrides: clefOverrides` to the returned `ReaderPreferences(...)` initializer call.

Add the encoder helper next to the existing helpers at the bottom:

```swift
private static func encodeClefTriple(
    address: StaffAddress, rawType: String
) -> ClefTripleEncoded {
    ClefTripleEncoded(
        partIndex: address.partIndex,
        staffIndexInPart: address.staffIndexInPart,
        rawType: rawType
    )
}

private struct ClefTripleEncoded: Encodable {
    let partIndex: Int
    let staffIndexInPart: Int
    let rawType: String
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd Packages/Infrastructure && swift test --filter ReaderPreferencesRecordTests`
Expected: PASS — all four new tests + existing record tests still green.

- [ ] **Step 6: Commit**

```bash
git add Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift Packages/Infrastructure/Sources/Persistence/Records/ReaderPreferencesRecord.swift Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ReaderPreferencesRecordTests.swift
git commit -m "Persistence: add staff_clef_overrides column (migration v6)"
```

---

## Task 3: Reader — `Score.applying(clefOverrides:)`

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Score+ApplyingClefOverrides.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ScoreApplyingClefOverridesTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Packages/Features/Reader/Tests/ReaderTests/ScoreApplyingClefOverridesTests.swift`:

```swift
@testable import Reader
import SheetMusicCore
import Testing

@Suite struct ScoreApplyingClefOverridesTests {
    @Test func emptyOverridesReturnsEqualScore() {
        let score = makeScore(staffDefaultClefs: ["G", "F"])
        let result = score.applying(clefOverrides: [:])
        #expect(result == score)
    }

    @Test func overrideRewritesExplicitMeasure0Clef() {
        // Staff with an explicit measure-0 clef change as the very first
        // voice element on voice 0.
        var score = makeScore(staffDefaultClefs: [nil])
        score.parts[0].staves[0].measures = [
            Measure(voices: [
                Voice(elements: [
                    .clef(Clef(concertClefType: "G")),
                ]),
            ]),
        ]
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let result = score.applying(clefOverrides: [address: "G8vb"])
        guard case let .clef(rewritten) =
                result.parts[0].staves[0].measures[0].voices[0].elements[0]
        else { Issue.record("expected rewritten clef"); return }
        #expect(rewritten.concertClefType == "G8vb")
    }

    @Test func overrideSetsDefaultClefWhenNoExplicitMeasure0Clef() {
        var score = makeScore(staffDefaultClefs: [nil])
        // Voice 0 starts with a chord, not a clef.
        score.parts[0].staves[0].measures = [
            Measure(voices: [
                Voice(elements: [
                    .rest(duration: NoteDuration(unit: .whole)),
                ]),
            ]),
        ]
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let result = score.applying(clefOverrides: [address: "F"])
        #expect(result.parts[0].staves[0].defaultClefType == "F")
        // Original measure 0 element 0 is untouched.
        if case .clef = result.parts[0].staves[0].measures[0].voices[0].elements[0] {
            Issue.record("override must not insert a clef voice element")
        }
    }

    @Test func midScoreClefChangePreserved() {
        var score = makeScore(staffDefaultClefs: [nil])
        score.parts[0].staves[0].measures = [
            Measure(voices: [
                Voice(elements: [
                    .clef(Clef(concertClefType: "G")),
                    .rest(duration: NoteDuration(unit: .whole)),
                ]),
            ]),
            Measure(voices: [
                Voice(elements: [
                    .clef(Clef(concertClefType: "F")),
                    .rest(duration: NoteDuration(unit: .whole)),
                ]),
            ]),
        ]
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let result = score.applying(clefOverrides: [address: "G8vb"])
        // Measure 0 element 0 → rewritten.
        if case let .clef(c) =
                result.parts[0].staves[0].measures[0].voices[0].elements[0] {
            #expect(c.concertClefType == "G8vb")
        } else {
            Issue.record("measure 0 clef rewrite missing")
        }
        // Measure 1 element 0 → preserved.
        if case let .clef(c) =
                result.parts[0].staves[0].measures[1].voices[0].elements[0] {
            #expect(c.concertClefType == "F")
        } else {
            Issue.record("mid-score clef change must be preserved")
        }
    }

    @Test func overrideForNonExistentStaffIsNoOp() {
        let score = makeScore(staffDefaultClefs: ["G"])
        let result = score.applying(clefOverrides: [
            StaffAddress(partIndex: 99, staffIndexInPart: 0): "G8vb",
        ])
        #expect(result == score)
    }

    // Builds a Score with N staves under one Part. Each entry in
    // `staffDefaultClefs` becomes one staff with that defaultClefType
    // and one empty measure (so layout has something to anchor to).
    private func makeScore(staffDefaultClefs: [String?]) -> Score {
        let staves = staffDefaultClefs.map { rawType in
            Staff(
                defaultClefType: rawType,
                measures: [Measure(voices: [Voice(elements: [])])]
            )
        }
        return Score(
            division: 480,
            parts: [
                Part(
                    id: "P0",
                    instrument: Instrument(id: "x", channels: []),
                    staves: staves
                ),
            ],
            metaTags: [:]
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/Features/Reader && swift test --filter ScoreApplyingClefOverridesTests`
Expected: FAIL — `Cannot find 'applying' as a method of 'Score'`.

- [ ] **Step 3: Implement the transformation**

Create `Packages/Features/Reader/Sources/Reader/Score+ApplyingClefOverrides.swift`:

```swift
import SheetMusicCore

extension Score {
    /// Returns a copy of the score with each staff's opening clef
    /// rewritten according to `clefOverrides`. The map is keyed by
    /// the pre-`filtered(hidingStaves:)` staff address — apply this
    /// transform *before* filtering, otherwise the filter's reindex
    /// invalidates the keys.
    ///
    /// For each `(staff, rawType)`:
    /// - If the staff's measure 0, voice 0, element 0 is an explicit
    ///   `<Clef>` voice element, that element's `concertClefType` is
    ///   rewritten to `rawType`. The `transposingClefType` is cleared
    ///   so the override doesn't collide with a stale transpose.
    /// - Otherwise `Staff.defaultClefType = rawType`. The layout
    ///   engine synthesizes the opening clef from this when no
    ///   explicit measure-0 clef is present.
    ///
    /// Mid-score clef changes (any explicit `<Clef>` element at
    /// position other than measure 0 / voice 0 / element 0) are not
    /// touched.
    ///
    /// Overrides targeting staves that don't exist in this score are
    /// skipped silently — no error, no crash.
    func applying(clefOverrides: [StaffAddress: String]) -> Score {
        guard !clefOverrides.isEmpty else { return self }
        var copy = self
        for (address, rawType) in clefOverrides {
            guard copy.parts.indices.contains(address.partIndex) else { continue }
            guard copy.parts[address.partIndex].staves.indices
                .contains(address.staffIndexInPart) else { continue }
            let p = address.partIndex
            let s = address.staffIndexInPart
            if let firstElement = copy.parts[p].staves[s]
                .measures.first?.voices.first?.elements.first,
                case .clef = firstElement
            {
                copy.parts[p].staves[s].measures[0].voices[0].elements[0] =
                    .clef(Clef(concertClefType: rawType))
            } else {
                copy.parts[p].staves[s].defaultClefType = rawType
            }
        }
        return copy
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/Features/Reader && swift test --filter ScoreApplyingClefOverridesTests`
Expected: PASS — all five tests green.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Score+ApplyingClefOverrides.swift Packages/Features/Reader/Tests/ReaderTests/ScoreApplyingClefOverridesTests.swift
git commit -m "Reader: add Score.applying(clefOverrides:) transformation"
```

---

## Task 4: Reader — ViewModel API for clef override

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift` (inside the existing test suite — match the file's existing pattern of building a VM via the local fakes):

```swift
@Test func setClefOverrideUpdatesPreferencesAndPersists() async throws {
    let item = ScoreItem.preview()
    let repo = FakeScoreLibraryRepository()
    let gateway = FakeScoreFileGateway(score: makeTwoStaffScore())
    let vm = ReaderViewModel(
        scoreItem: item, repository: repo, gateway: gateway,
        scoresDirectory: URL(filePath: "/tmp")
    )
    await vm.load()
    let address = StaffAddress(partIndex: 0, staffIndexInPart: 1)
    await vm.setClefOverride("G8vb", for: address)
    #expect(vm.preferences.staffClefOverrides == [address: "G8vb"])
    #expect(repo.savedReaderPreferences.last?.staffClefOverrides == [address: "G8vb"])
    #expect(vm.hasClefOverride(for: address))
}

@Test func clearClefOverrideRemovesEntry() async throws {
    let item = ScoreItem.preview()
    let repo = FakeScoreLibraryRepository()
    let gateway = FakeScoreFileGateway(score: makeTwoStaffScore())
    let vm = ReaderViewModel(
        scoreItem: item, repository: repo, gateway: gateway,
        scoresDirectory: URL(filePath: "/tmp")
    )
    await vm.load()
    let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    await vm.setClefOverride("F", for: address)
    await vm.clearClefOverride(for: address)
    #expect(vm.preferences.staffClefOverrides.isEmpty)
    #expect(!vm.hasClefOverride(for: address))
}

@Test func effectiveClefReturnsOverrideThenAuthored() async throws {
    let item = ScoreItem.preview()
    let repo = FakeScoreLibraryRepository()
    var score = makeTwoStaffScore()
    // Authored opening clef on staff (0,0) is "G", on (0,1) is `nil`
    // with defaultClefType "F".
    score.parts[0].staves[0].measures = [
        Measure(voices: [Voice(elements: [
            .clef(Clef(concertClefType: "G")),
        ])]),
    ]
    score.parts[0].staves[1].defaultClefType = "F"
    let gateway = FakeScoreFileGateway(score: score)
    let vm = ReaderViewModel(
        scoreItem: item, repository: repo, gateway: gateway,
        scoresDirectory: URL(filePath: "/tmp")
    )
    await vm.load()
    #expect(vm.effectiveClef(for: StaffAddress(partIndex: 0, staffIndexInPart: 0)) == "G")
    #expect(vm.effectiveClef(for: StaffAddress(partIndex: 0, staffIndexInPart: 1)) == "F")
    let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    await vm.setClefOverride("G8vb", for: address)
    #expect(vm.effectiveClef(for: address) == "G8vb")
}
```

If `makeTwoStaffScore()` doesn't already exist in this test file, add this private helper near the bottom of the suite:

```swift
private func makeTwoStaffScore() -> Score {
    Score(
        division: 480,
        parts: [
            Part(
                id: "P0",
                instrument: Instrument(id: "x", channels: []),
                staves: [
                    Staff(measures: [Measure(voices: [Voice(elements: [])])]),
                    Staff(measures: [Measure(voices: [Voice(elements: [])])]),
                ]
            ),
        ],
        metaTags: [:]
    )
}
```

If `FakeScoreLibraryRepository` doesn't expose `savedReaderPreferences` already, peek at `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakeScoreLibraryRepository.swift` — the existing test for `setVolume` (search for `saveReaderPreferences`) shows the pattern. Use whatever shape that fake already provides; if a tracking array doesn't exist, add one analogously to the existing volume / program override tests in this same test file.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/Features/Reader && swift test --filter ReaderViewModelTests/setClefOverrideUpdatesPreferencesAndPersists`
Expected: FAIL — `Value of type 'ReaderViewModel' has no member 'setClefOverride'`.

- [ ] **Step 3: Implement the VM API**

In `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`, add four methods near the existing `setStaffProgram` / `clearStaffProgramOverride` block (around line 265–283):

```swift
/// Returns the rawType the renderer will use for this staff: the
/// override if one is set, otherwise the score's authored opening
/// clef (explicit measure-0 clef, else `Staff.defaultClefType`),
/// falling back to `"G"` if neither exists or the staff isn't in
/// the score.
public func effectiveClef(for address: StaffAddress) -> String {
    if let override = preferences.staffClefOverrides[address] {
        return override
    }
    return authoredClef(for: address) ?? "G"
}

public func hasClefOverride(for address: StaffAddress) -> Bool {
    preferences.staffClefOverrides[address] != nil
}

public func setClefOverride(_ rawType: String, for address: StaffAddress) async {
    await mutatePreferences { $0.staffClefOverrides[address] = rawType }
}

public func clearClefOverride(for address: StaffAddress) async {
    await mutatePreferences {
        $0.staffClefOverrides.removeValue(forKey: address)
    }
}

private func authoredClef(for address: StaffAddress) -> String? {
    guard case let .loaded(score) = loadState,
          score.parts.indices.contains(address.partIndex),
          score.parts[address.partIndex].staves.indices
              .contains(address.staffIndexInPart)
    else { return nil }
    let staff = score.parts[address.partIndex].staves[address.staffIndexInPart]
    if let first = staff.measures.first?.voices.first?.elements.first,
       case let .clef(c) = first
    {
        return c.concertClefType
    }
    return staff.defaultClefType
}
```

Update `mutatePreferences` (around line 567) to thread `staffClefOverrides` through the re-seat pass — find the `let normalized = ReaderPreferences(...)` call and add `staffClefOverrides: copy.staffClefOverrides,` to the argument list, ordered to match the initializer signature (after `staffVolumeOverrides`).

Also update `loadOrSeedPreferences` (around line 549) to seed an empty map — the call site uses the default `[:]` argument so no change needed unless the seeded `ReaderPreferences(...)` enumerates parameters explicitly. Check: it currently passes only `scoreItemID:`, `staffSize:`, `hiddenStaves:`. The new field's default is `[:]`, so this is already correct.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/Features/Reader && swift test --filter ReaderViewModelTests`
Expected: PASS — three new tests + all existing ReaderViewModelTests still green.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift
git commit -m "Reader: add VM API for staff clef override"
```

---

## Task 5: Reader — Apply override in `ReaderRootScreen`

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`

This task has no new test — the rendering pipeline is verified manually via the inspector preview / simulator in Task 8. The only change here is wiring; the `Score.applying(clefOverrides:)` and VM persistence are already covered.

- [ ] **Step 1: Insert the override step before `filtered`**

In `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`, replace the body of `case let .loaded(score):` (around lines 114–133):

```swift
case let .loaded(score):
    let withClefs = score.applying(clefOverrides: viewModel.preferences.staffClefOverrides)
    let visible = withClefs.filtered(hidingStaves: viewModel.preferences.hiddenStaves)
    switch layoutMode {
    case .vertical:
        VerticalScoreContainer(
            score: visible,
            staffSize: viewModel.preferences.staffSize,
            honorLayoutBreaks: viewModel.preferences.honorLayoutBreaks,
            playbackCursor: viewModel.playbackCursor,
            viewModel: viewModel
        )
    case .horizontal:
        HorizontalScoreContainer(
            score: visible,
            staffSize: viewModel.preferences.staffSize,
            honorLayoutBreaks: viewModel.preferences.honorLayoutBreaks,
            playbackCursor: viewModel.playbackCursor,
            viewModel: viewModel
        )
    }
```

- [ ] **Step 2: Build to confirm no compile error**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift
git commit -m "Reader: apply staff clef overrides before hidden-staff filter"
```

---

## Task 6: Reader — `ClefMenuChoice` helper

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Views/ClefMenuChoice.swift`

This is a small Reader-internal type the inspector uses to drive the Menu. Keeping it next to the inspector view simplifies grouping (Treble / Bass / C) and label formatting without leaking through the VM.

- [ ] **Step 1: Create the file**

Create `Packages/Features/Reader/Sources/Reader/Views/ClefMenuChoice.swift`:

```swift
import Foundation

/// Picker vocabulary for the Reader's per-staff clef override menu.
/// Constrains the v1 UI to ten clefs; the underlying override map
/// stores any `NotatedClef.rawType` string, so future expansion is
/// purely additive here.
enum ClefMenuChoice: Hashable, CaseIterable {
    case trebleG, trebleG8va, trebleG8vb, trebleG15ma, trebleG15mb
    case bassF, bassF8va, bassF8vb
    case altoC3, tenorC4

    var rawType: String {
        switch self {
        case .trebleG: "G"
        case .trebleG8va: "G8va"
        case .trebleG8vb: "G8vb"
        case .trebleG15ma: "G15ma"
        case .trebleG15mb: "G15mb"
        case .bassF: "F"
        case .bassF8va: "F8va"
        case .bassF8vb: "F8vb"
        case .altoC3: "C3"
        case .tenorC4: "C4"
        }
    }

    /// Short label shown in the menu row and on the menu's button label.
    var displayLabel: String {
        switch self {
        case .altoC3: "Alto"
        case .tenorC4: "Tenor"
        default: rawType
        }
    }

    static let trebleFamily: [ClefMenuChoice] = [
        .trebleG, .trebleG8va, .trebleG8vb, .trebleG15ma, .trebleG15mb,
    ]
    static let bassFamily: [ClefMenuChoice] = [
        .bassF, .bassF8va, .bassF8vb,
    ]
    static let cFamily: [ClefMenuChoice] = [
        .altoC3, .tenorC4,
    ]

    /// Looks up the menu choice for an arbitrary rawType. Returns
    /// `nil` for rawTypes outside the v1 picker (e.g. `"PERC"`) — the
    /// menu renders these as a fallback label without highlighting any
    /// item.
    static func from(rawType: String) -> ClefMenuChoice? {
        allCases.first { $0.rawType == rawType }
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `cd Packages/Features/Reader && swift build`
Expected: build succeeds with no warnings.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Views/ClefMenuChoice.swift
git commit -m "Reader: add ClefMenuChoice helper for the inspector picker"
```

---

## Task 7: Localization — five new keys

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings`

The xcstrings format is JSON-shaped. Insert the new keys alongside the existing `reader.preferences.*` block.

- [ ] **Step 1: Add the keys**

Open `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings`. Inside the top-level `"strings"` object, add these five entries (the file is sorted alphabetically by key — insert next to the existing `reader.preferences.*` block):

```json
"reader.preferences.clef" : {
  "localizations" : {
    "en" : {
      "stringUnit" : { "state" : "translated", "value" : "Clef" }
    },
    "ja" : {
      "stringUnit" : { "state" : "translated", "value" : "音部記号" }
    }
  }
},
"reader.preferences.clef.resetDefault" : {
  "localizations" : {
    "en" : {
      "stringUnit" : { "state" : "translated", "value" : "Use score's clef" }
    },
    "ja" : {
      "stringUnit" : { "state" : "translated", "value" : "スコアの音部記号を使う" }
    }
  }
},
"reader.preferences.clef.section.bass" : {
  "localizations" : {
    "en" : {
      "stringUnit" : { "state" : "translated", "value" : "Bass" }
    },
    "ja" : {
      "stringUnit" : { "state" : "translated", "value" : "Bass" }
    }
  }
},
"reader.preferences.clef.section.cClefs" : {
  "localizations" : {
    "en" : {
      "stringUnit" : { "state" : "translated", "value" : "C" }
    },
    "ja" : {
      "stringUnit" : { "state" : "translated", "value" : "C" }
    }
  }
},
"reader.preferences.clef.section.treble" : {
  "localizations" : {
    "en" : {
      "stringUnit" : { "state" : "translated", "value" : "Treble" }
    },
    "ja" : {
      "stringUnit" : { "state" : "translated", "value" : "Treble" }
    }
  }
},
```

(The Japanese values for the section headers are kept in English on purpose — music notation conventions in Japanese app copy commonly leave "Treble" / "Bass" / "C" untranslated. The user can revise later.)

- [ ] **Step 2: Build to confirm xcstrings parses**

Run: `cd Packages/Features/Reader && swift build`
Expected: build succeeds (any JSON syntax error fails the resource compilation step).

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings
git commit -m "Reader: localize clef picker copy"
```

---

## Task 8: Inspector — restructure Visual tab + clef Menu

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/InspectorScreen.swift`

This is the largest UI step. We replace the current 3-row Visual tab with a structure that mirrors the Playback tab (General section + per-Part sections with per-staff rows), drop the eye button from the Playback tab's per-staff row, and add a clef Menu next to the eye button on the Visual tab.

- [ ] **Step 1: Drop the eye button from the Playback tab's per-staff row**

In `Packages/Features/Reader/Sources/Reader/Screens/InspectorScreen.swift`, in `staffRow(address:)` (around lines 226–274), remove the `visibilityButton(address: address)` call inside the trailing `HStack`. The HStack should now end with the M button.

The `visibilityButton(address:)` helper function (around lines 334–347) stays — it's reused on the Visual tab.

- [ ] **Step 2: Restructure `visualContent`**

Replace the entire `visualContent` ViewBuilder (around lines 94–109) with:

```swift
@ViewBuilder
private var visualContent: some View {
    Section {
        layoutRow
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

        staffSizeRow
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

        breakPolicyRow
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    ForEach(score.parts.indices, id: \.self) { partIndex in
        let part = score.parts[partIndex]
        Section {
            ForEach(part.staves.indices, id: \.self) { staffIndex in
                visualStaffRow(address: StaffAddress(
                    partIndex: partIndex,
                    staffIndexInPart: staffIndex
                ))
            }
        } header: {
            Text(part.instrument.longName ?? part.trackName ?? "-")
                .font(.headline)
                .padding(.bottom, -8)
        }
        .headerProminence(.increased)
        .padding(.bottom, -8)
    }
}
```

- [ ] **Step 3: Add `visualStaffRow(address:)`**

Add this method to `InspectorScreen` (place it next to `staffRow(address:)`):

```swift
@ViewBuilder
private func visualStaffRow(address: StaffAddress) -> some View {
    HStack(spacing: 8) {
        Spacer()
        clefMenu(address: address)
        visibilityButton(address: address)
    }
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
}
```

- [ ] **Step 4: Add `clefMenu(address:)`**

Add the menu method to `InspectorScreen`:

```swift
@ViewBuilder
private func clefMenu(address: StaffAddress) -> some View {
    let effective = viewModel.effectiveClef(for: address)
    let hasOverride = viewModel.hasClefOverride(for: address)
    let label = ClefMenuChoice.from(rawType: effective)?.displayLabel ?? effective
    Menu {
        if hasOverride {
            Button {
                Task { await viewModel.clearClefOverride(for: address) }
            } label: {
                Label {
                    Text("reader.preferences.clef.resetDefault", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.uturn.backward")
                }
            }
            Divider()
        }
        Section {
            ForEach(ClefMenuChoice.trebleFamily, id: \.self) { choice in
                Button(choice.displayLabel) {
                    Task {
                        await viewModel.setClefOverride(choice.rawType, for: address)
                    }
                }
            }
        } header: {
            Text("reader.preferences.clef.section.treble", bundle: .module)
        }
        Section {
            ForEach(ClefMenuChoice.bassFamily, id: \.self) { choice in
                Button(choice.displayLabel) {
                    Task {
                        await viewModel.setClefOverride(choice.rawType, for: address)
                    }
                }
            }
        } header: {
            Text("reader.preferences.clef.section.bass", bundle: .module)
        }
        Section {
            ForEach(ClefMenuChoice.cFamily, id: \.self) { choice in
                Button(choice.displayLabel) {
                    Task {
                        await viewModel.setClefOverride(choice.rawType, for: address)
                    }
                }
            }
        } header: {
            Text("reader.preferences.clef.section.cClefs", bundle: .module)
        }
    } label: {
        HStack(spacing: 4) {
            Text(label)
                .lineLimit(1)
                .foregroundStyle(hasOverride ? Color.accentColor : Color.primary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 4)
    }
    .menuIndicator(.hidden)
    .accessibilityLabel(Text("reader.preferences.clef", bundle: .module))
}
```

- [ ] **Step 5: Build to confirm it compiles**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Render the inspector preview**

In `Packages/Features/Reader/Sources/Reader/Screens/InspectorScreen.swift`, the existing `#Preview` block at the bottom uses a 2-part / 3-staff fixture (Violin + Piano). Render it via the Xcode MCP tooling:

Run: `mcp__xcode__RenderPreview` against `InspectorScreen.swift`.
`Read` the resulting PNG. Visually confirm:
1. Compact preview shows the segmented Picker. Switch to "Visual".
2. Visual tab shows: General section (3 rows) → Violin section (1 staff row with `[G ▾] [Eye]`) → Piano section (2 staff rows with `[G ▾] [Eye]` / `[F ▾] [Eye]` matching the score's authored clefs).
3. Playback tab's per-staff rows no longer show an eye icon (only Slider, S, M).

If the preview fails to render, debug the cause (printable summary in the MCP error). Stay on the preview path; do not fall back to the simulator for layout verification per the project's iOS workflow.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/InspectorScreen.swift
git commit -m "Reader: clef picker + relocated eye toggle in Visual tab"
```

---

## Task 9: Manual end-to-end verification

**Files:** none changed in this task — sanity check via simulator.

The render path and persistence are unit-tested. This task confirms the full loop works: open a score → pick a clef → see the staff re-render → close and reopen → override survives.

- [ ] **Step 1: Build and install on the iOS simulator**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build 2>&1 | tail -5`
Then install + launch via `xcrun simctl install booted ...` / `xcrun simctl launch booted com.KeyNumber.Folino` (or via the Xcode IDE).

- [ ] **Step 2: Smoke test the override loop**

1. Open any score with a treble + bass piano staff.
2. Inspector → Visual tab → on the treble staff's row, tap the clef menu → pick "G8vb".
3. Confirm the rendered staff repaints with the G8vb glyph; notes do not move (visual annotation only — pitch positions stay).
4. Close the Reader, reopen the same score, confirm the override persists.
5. Inspector → Visual → tap clef menu → "Use score's clef". Confirm the staff returns to "G".
6. Pick a clef that re-positions notes (treble → "Alto"). Confirm noteheads move to alto-clef positions.
7. Hide the staff via the Visual tab's eye toggle, then unhide. Override persists across the toggle.

Hand control back to the user — describe what you saw and let them confirm. Do not drive simulator gestures programmatically per the project's iOS workflow.

- [ ] **Step 3: No commit — verification only**

If anything misbehaves, file a follow-up task; do not patch on this branch unless the bug is in this plan's code.

---

## Self-Review Notes

- All five spec keys (`reader.preferences.clef[.resetDefault|.section.treble|.section.bass|.section.cClefs]`) are added in Task 7 and consumed in Task 8.
- All ten v1 picker rawTypes (5 × treble, 3 × bass, 2 × C) live in `ClefMenuChoice` (Task 6) and are filtered through `ReaderPreferences.knownClefRawTypes` (Task 1) which adds `"PERC"` for forward-compat (won't appear in the picker).
- Task 5 places `applying(clefOverrides:)` *before* `filtered(hidingStaves:)` per the spec correction — the override map keys are pre-filter `StaffAddress` values, and applying after filter would invalidate them.
- `mutatePreferences` re-seats through the initializer; Task 4 explicitly threads `staffClefOverrides` through that re-seat.
- Tasks are bite-sized: each has a failing test (where applicable), a focused implementation step, a green-test confirmation, and one commit. Tasks 5 / 7 / 9 don't add tests because they're wiring / data / manual verification — flagged inline.

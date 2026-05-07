# Honor authored layout breaks — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-score Inspector toggle that lets users opt out of the
`<LayoutBreak>` markup authored in `.mscx` files, so the layout engine can
wrap measures purely on available width.

**Architecture:** New `Bool honorLayoutBreaks` field on `ReaderPreferences`
(default `true`), persisted via a v4 GRDB migration. `ReaderViewModel`
exposes a setter; `Vertical-` and `HorizontalScoreContainer` thread the value
into `ScoreViewOptions(breakPolicy:)` (`true → .honor`, `false → .ignoreAll`).
Inspector's Visual section gets a `Toggle` row.

**Tech stack:** Swift 6.3, SwiftUI, GRDB, Swift Testing, swift-sheet-music
(`SheetMusicLayout.LayoutBreakPolicy`).

**Spec:** `docs/superpowers/specs/2026-05-07-honor-authored-breaks-design.md`

---

## File map

| Path | Change |
| --- | --- |
| `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift` | Add `honorLayoutBreaks: Bool` field + init param |
| `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift` | New v4 migrator + register in `all` and add `upToV3` helper for tests |
| `Packages/Infrastructure/Sources/Persistence/Records/ReaderPreferencesRecord.swift` | New field + coding key, round-trip in `init(domain:)` / `toDomain()` |
| `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ReaderPreferencesRecordTests.swift` | Round-trip tests |
| `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AppDatabaseTests.swift` | v3→v4 migration test |
| `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` | `setHonorLayoutBreaks(_:)`; thread the field through `mutatePreferences` and seed-defaults |
| `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift` | Setter test |
| `Packages/Features/Reader/Sources/Reader/HorizontalScoreContainer.swift` | New `honorLayoutBreaks` prop, threaded into `ScoreViewOptions` and `TaskKey` |
| `Packages/Features/Reader/Sources/Reader/VerticalScoreContainer.swift` | Same |
| `Packages/Features/Reader/Sources/Reader/ReaderView.swift` | Pass `viewModel.preferences.honorLayoutBreaks` to both containers |
| `Packages/Features/Reader/Sources/Reader/InspectorView.swift` | New `breakPolicyRow` in `visualContent` |
| `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings` | "Honor authored breaks" (en + ja) |

---

## Task 1: Add `honorLayoutBreaks` field to `ReaderPreferences`

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift`

- [ ] **Step 1: Add the stored property and init parameter**

Open `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift`. Inside
the `ReaderPreferences` struct, add a new stored property right after
`tempoMultiplier`:

```swift
    /// When `true` (default), the layout engine honors authored
    /// `<LayoutBreak>line` / `<LayoutBreak>page` markup, so the engraver's
    /// chosen system / page boundaries are reproduced. When `false`, the
    /// engine ignores both forms and wraps measures purely on the
    /// available view width — useful when the score was authored for a
    /// different page size.
    public var honorLayoutBreaks: Bool
```

In the initializer's parameter list, insert `honorLayoutBreaks: Bool = true`
after `tempoMultiplier`. In the body, set
`self.honorLayoutBreaks = honorLayoutBreaks` immediately after the
`tempoMultiplier` assignment.

The full initializer should read:

```swift
    public init(
        id: ReaderPreferencesID = ReaderPreferencesID(),
        scoreItemID: ScoreItemID,
        staffSize: CGFloat,
        hiddenStaves: Set<StaffAddress>,
        staffProgramOverrides: [StaffAddress: Int] = [:],
        tempoMultiplier: Double? = nil,
        honorLayoutBreaks: Bool = true
    ) {
        self.id = id
        self.scoreItemID = scoreItemID
        self.staffSize = min(max(staffSize, Self.minStaffSize), Self.maxStaffSize)
        self.hiddenStaves = hiddenStaves
        self.staffProgramOverrides = staffProgramOverrides.mapValues { min(max($0, 0), 127) }
        self.tempoMultiplier = tempoMultiplier.map {
            min(max($0, Self.minTempoMultiplier), Self.maxTempoMultiplier)
        }
        self.honorLayoutBreaks = honorLayoutBreaks
    }
```

- [ ] **Step 2: Build the Domain package**

Run from the worktree root:

```bash
cd Packages/Domain && swift build
```

Expected: build succeeds. (No Domain-internal call sites construct
`ReaderPreferences` without the new defaulted param, so existing call sites
elsewhere will keep compiling — that's verified in later tasks.)

- [ ] **Step 3: Commit**

```bash
cd ../..
git add Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift
git commit -m "feat(domain): add honorLayoutBreaks flag to ReaderPreferences"
```

---

## Task 2: v4 migration adds `honor_layout_breaks` column (TDD)

**Files:**
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AppDatabaseTests.swift`
- Modify: `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift`

- [ ] **Step 1: Add an `upToV3` helper to `AppMigrations`**

We need a helper that registers `v1` + `v2` + `v3` only, parallel to the
existing `upToV2`, so the migration test can insert a row at the v3 schema
and then upgrade.

Open `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift`.
Just under the existing `upToV2` static, add:

```swift
    /// Migrator that registers v1 + v2 + v3 only — useful for tests that
    /// want to exercise a v4 upgrade against rows already inserted at the
    /// previous schema.
    static let upToV3: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        m.registerMigration("v2", migrate: migrateV2)
        m.registerMigration("v3", migrate: migrateV3)
        return m
    }()
```

- [ ] **Step 2: Write the failing migration test**

Open `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AppDatabaseTests.swift`.
Add a new test at the end of the suite:

```swift
    @Test func migratingToV4DefaultsHonorLayoutBreaksToTrue() throws {
        let queue = try DatabaseQueue()
        try AppMigrations.upToV3.migrate(queue)

        // Insert a parent score row, then a v3-shape reader_preferences row
        // (no honor_layout_breaks column yet).
        let scoreID = "00000000-0000-0000-0000-000000000001"
        let prefsID = "11111111-1111-1111-1111-111111111111"
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO score_items (id, title, local_file_name, content_hash,
                    size_bytes, length_beats, default_tempo_bpm, added_at)
                VALUES (?, 'T', 'f.mscx', 'h', 0, 0, 120, 0)
                """,
                arguments: [scoreID]
            )
            try db.execute(
                sql: """
                INSERT INTO reader_preferences
                    (id, score_item_id, staff_size, hidden_staff_ids, staff_program_overrides)
                VALUES (?, ?, 14, '[]', '[]')
                """,
                arguments: [prefsID, scoreID]
            )
        }

        // Run v4.
        try AppMigrations.all.migrate(queue)

        let value = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT honor_layout_breaks FROM reader_preferences WHERE id = ?",
                arguments: [prefsID]
            )
        }
        #expect(value == 1)
    }
```

- [ ] **Step 3: Run the test and verify it fails**

```bash
cd Packages/Infrastructure
swift test --filter AppDatabaseTests.migratingToV4DefaultsHonorLayoutBreaksToTrue
```

Expected: FAIL — the column doesn't exist yet (or the test references
`AppMigrations.upToV3` and the v4 migration is missing).

- [ ] **Step 4: Implement the v4 migration**

Open `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift`.

In the `all` migrator, register v4 right after v3:

```swift
    static let all: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1", migrate: migrateV1)
        m.registerMigration("v2", migrate: migrateV2)
        m.registerMigration("v3", migrate: migrateV3)
        m.registerMigration("v4", migrate: migrateV4)
        return m
    }()
```

At the bottom of the file, add the migrator function:

```swift
    // MARK: - v4

    private static func migrateV4(_ db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE reader_preferences
        ADD COLUMN honor_layout_breaks INTEGER NOT NULL DEFAULT 1
        """)
    }
```

- [ ] **Step 5: Run the test and verify it passes**

```bash
swift test --filter AppDatabaseTests.migratingToV4DefaultsHonorLayoutBreaksToTrue
```

Expected: PASS.

- [ ] **Step 6: Run the full Infrastructure suite**

```bash
swift test
```

Expected: all tests pass. The existing `ReaderPreferencesRecordTests` may
still pass at this point because the record doesn't yet decode the new
column — GRDB tolerates extra columns. We'll wire it in the next task.

- [ ] **Step 7: Commit**

```bash
cd ../..
git add Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift \
  Packages/Infrastructure/Tests/InfrastructureTests/Persistence/AppDatabaseTests.swift
git commit -m "feat(persistence): v4 migration adds honor_layout_breaks column"
```

---

## Task 3: Round-trip the field through `ReaderPreferencesRecord` (TDD)

**Files:**
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ReaderPreferencesRecordTests.swift`
- Modify: `Packages/Infrastructure/Sources/Persistence/Records/ReaderPreferencesRecord.swift`

- [ ] **Step 1: Write the failing record round-trip test**

Open the test file and add:

```swift
    @Test func honorLayoutBreaksRoundTripsThroughDomain() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            honorLayoutBreaks: false
        )
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored.honorLayoutBreaks == false)
    }

    @Test func honorLayoutBreaksDefaultsToTrueOnDomainConstruction() throws {
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: []
        )
        #expect(prefs.honorLayoutBreaks == true)
        let record = ReaderPreferencesRecord(domain: prefs)
        let restored = try record.toDomain()
        #expect(restored.honorLayoutBreaks == true)
    }
```

- [ ] **Step 2: Run and verify both tests fail**

```bash
cd Packages/Infrastructure
swift test --filter ReaderPreferencesRecordTests.honorLayoutBreaksRoundTripsThroughDomain
swift test --filter ReaderPreferencesRecordTests.honorLayoutBreaksDefaultsToTrueOnDomainConstruction
```

Expected: FAIL — `ReaderPreferences.init` accepts the param now (Task 1) so
the second test compiles, but `ReaderPreferencesRecord` doesn't yet preserve
or expose the value, so the first test's `restored.honorLayoutBreaks ==
false` assertion fails (it'll see the domain default `true`).

- [ ] **Step 3: Add the field to `ReaderPreferencesRecord`**

Open `Packages/Infrastructure/Sources/Persistence/Records/ReaderPreferencesRecord.swift`.

Add the stored property after `staffProgramOverrides`:

```swift
    var staffProgramOverrides: String
    var honorLayoutBreaks: Bool
```

Add the coding key:

```swift
    enum CodingKeys: String, CodingKey {
        case id
        case scoreItemId = "score_item_id"
        case staffSize = "staff_size"
        case hiddenStaffIds = "hidden_staff_ids"
        case staffProgramOverrides = "staff_program_overrides"
        case honorLayoutBreaks = "honor_layout_breaks"
    }
```

Set it in `init(domain:)`. After the existing `staffProgramOverrides`
assignment block, add:

```swift
        honorLayoutBreaks = prefs.honorLayoutBreaks
```

In `toDomain()`, pass it to the `ReaderPreferences` initializer:

```swift
        return ReaderPreferences(
            id: ReaderPreferencesID(rawValue: idUUID),
            scoreItemID: ScoreItemID(rawValue: scoreUUID),
            staffSize: CGFloat(staffSize),
            hiddenStaves: Set(decodedHidden),
            staffProgramOverrides: overrides,
            honorLayoutBreaks: honorLayoutBreaks
        )
```

- [ ] **Step 4: Run the new tests and verify they pass**

```bash
swift test --filter ReaderPreferencesRecordTests
```

Expected: all `ReaderPreferencesRecordTests` pass, including the two new
tests.

- [ ] **Step 5: Run the full Infrastructure suite**

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
cd ../..
git add Packages/Infrastructure/Sources/Persistence/Records/ReaderPreferencesRecord.swift \
  Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ReaderPreferencesRecordTests.swift
git commit -m "feat(persistence): round-trip honor_layout_breaks through record"
```

---

## Task 4: `ReaderViewModel.setHonorLayoutBreaks` (TDD)

**Files:**
- Modify: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`

- [ ] **Step 1: Write the failing setter test**

Open the test file and add this test alongside the other staff-size tests:

```swift
    @Test func setHonorLayoutBreaksPersistsAndUpdatesPreferences() async {
        let item = Self.makeItem()
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = [item]
        repo.storedReaderPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, staffSize: 14, hiddenStaves: []
        )
        let vm = ReaderViewModel(
            scoreItem: item, repository: repo,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: 14
        )
        await vm.load()
        #expect(vm.preferences.honorLayoutBreaks == true)

        await vm.setHonorLayoutBreaks(false)
        #expect(vm.preferences.honorLayoutBreaks == false)
        #expect(repo.savedReaderPreferences.last?.honorLayoutBreaks == false)

        await vm.setHonorLayoutBreaks(true)
        #expect(vm.preferences.honorLayoutBreaks == true)
        #expect(repo.savedReaderPreferences.last?.honorLayoutBreaks == true)
    }
```

- [ ] **Step 2: Run and verify the test fails**

```bash
cd Packages/Features/Reader
swift test --filter ReaderViewModelTests.setHonorLayoutBreaksPersistsAndUpdatesPreferences
```

Expected: FAIL — `setHonorLayoutBreaks` is not defined.

- [ ] **Step 3: Implement the setter**

Open `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`. Right
after `decrementStaffSize()` (around line 140), add:

```swift
    public func setHonorLayoutBreaks(_ value: Bool) async {
        await mutatePreferences { $0.honorLayoutBreaks = value }
    }
```

- [ ] **Step 4: Update `mutatePreferences` to thread the new field**

In the same file, find `mutatePreferences` (around line 442). Update the
re-seat block to include `honorLayoutBreaks`:

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

- [ ] **Step 5: Run the test and verify it passes**

```bash
swift test --filter ReaderViewModelTests.setHonorLayoutBreaksPersistsAndUpdatesPreferences
```

Expected: PASS.

- [ ] **Step 6: Run the full Reader suite**

```bash
swift test
```

Expected: all Reader tests pass.

- [ ] **Step 7: Commit**

```bash
cd ../../..
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
  Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift
git commit -m "feat(reader): add ReaderViewModel.setHonorLayoutBreaks"
```

---

## Task 5: Thread `honorLayoutBreaks` through both score containers and `ReaderView`

The three files in this task depend on each other (adding a new property to
the containers without updating `ReaderView`'s call sites breaks the build).
Edit all three before running `swift build`, then commit as one atomic
change.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/HorizontalScoreContainer.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/VerticalScoreContainer.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderView.swift`

- [ ] **Step 1: Update `HorizontalScoreContainer`**

Open `Packages/Features/Reader/Sources/Reader/HorizontalScoreContainer.swift`.

In the struct's stored properties (around line 17–21), insert the new
property right after `staffSize`:

```swift
    let score: Score
    let staffSize: CGFloat
    let honorLayoutBreaks: Bool
    let playbackCursor: ScoreCursor?
    @Bindable var viewModel: ReaderViewModel
```

In the body, change the `.task(id:)` call (around line 61) to include the
new value:

```swift
            .task(id: TaskKey(
                score: score, size: staffSize,
                honorLayoutBreaks: honorLayoutBreaks
            )) {
                rebuildLayout()
            }
```

Update `rebuildLayout()` (around line 76) to pass the policy:

```swift
    private func rebuildLayout() {
        let opts = ScoreViewOptions(
            staffSize: staffSize,
            systemGap: staffSize * 1.25,
            wrapToViewWidth: false,
            includeTitleFrame: false,
            breakPolicy: honorLayoutBreaks ? .honor : .ignoreAll,
            showBreakIndicators: false
        )
        let natural = LayoutEngine.naturalContentWidth(
            score: score, options: opts
        )
        document = LayoutEngine.layout(
            score: score, options: opts, availableWidth: natural
        )
    }
```

Update `TaskKey` (around line 132):

```swift
    private struct TaskKey: Hashable {
        let scoreSignature: Int
        let size: CGFloat
        let honorLayoutBreaks: Bool

        init(score: Score, size: CGFloat, honorLayoutBreaks: Bool) {
            scoreSignature = score.parts.count
                ^ (score.totalStaffCount << 8)
                ^ (score.division << 16)
            self.size = size
            self.honorLayoutBreaks = honorLayoutBreaks
        }
    }
```

- [ ] **Step 2: Update `VerticalScoreContainer`**

Open `Packages/Features/Reader/Sources/Reader/VerticalScoreContainer.swift`.

Add the new stored property immediately after `staffSize`:

```swift
    let score: Score
    let staffSize: CGFloat
    let honorLayoutBreaks: Bool
    let playbackCursor: ScoreCursor?
    @Bindable var viewModel: ReaderViewModel
```

(Adjust insertion to sit right after `staffSize` regardless of the existing
property order.)

Update the `.task(id: TaskKey(...))` call (around line 96):

```swift
                .task(id: TaskKey(
                    score: score, size: staffSize, width: layoutWidth,
                    honorLayoutBreaks: honorLayoutBreaks
                )) {
                    await rebuildLayout(width: layoutWidth)
                }
```

Update `rebuildLayout(width:)` (around line 287):

```swift
    private func rebuildLayout(width: CGFloat) {
        let opts = ScoreViewOptions(
            staffSize: staffSize,
            systemGap: staffSize * 1.25,
            wrapToViewWidth: true,
            includeTitleFrame: true,
            breakPolicy: honorLayoutBreaks ? .honor : .ignoreAll,
            showBreakIndicators: false
        )
        document = LayoutEngine.layout(
            score: score, options: opts, availableWidth: width
        )
        lastWidth = width
    }
```

Update `TaskKey` (around line 370):

```swift
    private struct TaskKey: Hashable {
        let scoreSignature: Int
        let size: CGFloat
        let width: CGFloat
        let honorLayoutBreaks: Bool

        init(score: Score, size: CGFloat, width: CGFloat, honorLayoutBreaks: Bool) {
            scoreSignature = score.parts.count
                ^ (score.totalStaffCount << 8)
                ^ (score.division << 16)
            self.size = size
            self.width = width
            self.honorLayoutBreaks = honorLayoutBreaks
        }
    }
```

- [ ] **Step 3: Update `ReaderView` call sites**

Open `Packages/Features/Reader/Sources/Reader/ReaderView.swift`. In the
`content` view-builder (around line 86), pass
`viewModel.preferences.honorLayoutBreaks` into both containers:

```swift
            switch viewModel.layoutMode {
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

- [ ] **Step 4: Build the package**

```bash
cd Packages/Features/Reader
swift build
```

Expected: build succeeds.

- [ ] **Step 5: Run the full Reader suite**

```bash
swift test
```

Expected: all tests pass (no new tests yet — Task 4's setter test still
exercises this code path indirectly through `ReaderView` only at runtime).

- [ ] **Step 6: Commit**

```bash
cd ../../..
git add Packages/Features/Reader/Sources/Reader/HorizontalScoreContainer.swift \
  Packages/Features/Reader/Sources/Reader/VerticalScoreContainer.swift \
  Packages/Features/Reader/Sources/Reader/ReaderView.swift
git commit -m "feat(reader): thread honorLayoutBreaks into score containers"
```

---

## Task 6: Inspector toggle row + localization

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/InspectorView.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add the toggle row to the Visual section**

Open `Packages/Features/Reader/Sources/Reader/InspectorView.swift`.

In `visualContent` (around line 90), append a third row after `staffSizeRow`:

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
    }
```

Add the new row builder right after `staffSizeRow`:

```swift
    @ViewBuilder
    private var breakPolicyRow: some View {
        let binding = Binding<Bool>(
            get: { viewModel.preferences.honorLayoutBreaks },
            set: { newValue in
                Task { await viewModel.setHonorLayoutBreaks(newValue) }
            }
        )
        Toggle("Honor authored breaks", isOn: binding)
    }
```

- [ ] **Step 2: Add localized strings**

Open `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings`.
Inside the top-level `"strings"` object, add the new entry alphabetically
(between `"Hide All"` and `"Layout"`):

```json
    "Honor authored breaks": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Honor authored breaks" } },
        "ja": { "stringUnit": { "state": "translated", "value": "楽譜の改行・改ページに従う" } }
      }
    },
```

If you (the user) prefer a different Japanese rendering, swap the `ja`
value here — the rest of the wiring is independent of the string.

- [ ] **Step 3: Build the package**

```bash
cd Packages/Features/Reader
swift build
```

Expected: build succeeds.

- [ ] **Step 4: Render the InspectorView preview to verify the row appears**

CLAUDE.md (global) requires verifying UI changes via SwiftUI preview before
the simulator. Open `Folino.xcodeproj` in Xcode (must already be running
per the global instructions) and use
`mcp__xcode__RenderPreview` against `InspectorView`'s existing `#Preview`
in `InspectorView.swift`. `Read` the resulting PNG.

Expected: the Visual section now shows three rows — Layout buttons, Staff
size stepper, and the new "Honor authored breaks" toggle.

If the preview render fails (build error, plugin trust prompt, etc.), debug
on the preview path — do NOT switch to simulator verification per the
global CLAUDE.md directive.

- [ ] **Step 5: Run the full Reader suite once more**

```bash
swift test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
cd ../../..
git add Packages/Features/Reader/Sources/Reader/InspectorView.swift \
  Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings
git commit -m "feat(reader): add Honor-authored-breaks toggle to Inspector visual section"
```

---

## Task 7: Final verification

- [ ] **Step 1: Run all relevant package test suites**

```bash
cd Packages/Domain && swift test && cd ../..
cd Packages/Infrastructure && swift test && cd ../..
cd Packages/Features/Reader && swift test && cd ../..
```

Expected: all green.

- [ ] **Step 2: Build the full app**

From the worktree root:

```bash
xcodegen generate
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Hand off to the user**

The simulator-level verification (open a real `.mscx` with authored breaks,
toggle the new switch, confirm the layout reflows) is best done by hand —
per CLAUDE.md, programmatic gestures aren't a good fit. Ask the user to:

1. Open a score known to have `<LayoutBreak>` markup (e.g. anything authored
   for letter / A4 in MuseScore).
2. Open the Inspector → Visual.
3. Toggle "Honor authored breaks" off; the systems should re-pack to fill
   the iPad's width.
4. Toggle back on; the original system boundaries should return.
5. Reopen the score later — the choice should persist (per-score).

If the user reports a regression in either of the two layout modes
(vertical / horizontal), the most likely culprit is a missing `TaskKey`
update — re-check Task 5.

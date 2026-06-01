# Library Metadata Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Library's single-field rename alert with a `Form`-based edit sheet that edits title/subtitle/composer/arranger/lyricist/copyright and shows a read-only source + date-added section.

**Architecture:** Three new editable fields are added to `ScoreItem` + a GRDB v10 migration. A new Domain protocol `ScoreMetadataReading` (impl `LiveScoreMetadataReader`) parses the on-disk file on demand — mirroring the existing share path — to read `Score.source` (for the source label) and metaTags (to pre-fill legacy items whose new columns are still NULL). The sheet lives in the Library feature; `LibraryViewModel` gains `loadFileMetadata` + `saveMetadata`.

**Tech Stack:** Swift 6.3, SwiftUI, GRDB, swift-sheet-music (`SheetMusicCore`), Swift Testing (`@Test`/`#expect`).

---

## Conventions for every task

- **Build/test command (package-isolated):** memory note — `swift test` is broken by the SwiftLint build-tool plugin's macOS requirement. Use xcodebuild against an iOS simulator. iPhone 16 is NOT installed on this machine; use **iPhone 17**.
  - From a package dir, e.g. `Packages/Domain`:
    `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
    If the bare scheme name fails, retry with the `-Package` suffix (`-scheme Domain-Package`). Run `xcodebuild -list` in the package dir to confirm.
- **App build:** `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation build`
- **Commit discipline:** stage whole files only (no `git add -p`). The pre-commit hook runs SwiftFormat + `swiftlint --fix` and writes fixes back; if it fails, re-stage and re-commit.
- **Comments:** reflow at the 120-col SwiftLint budget. American English in prose; keep Apple/Swift API spellings (`cancelled`).
- **Languages for every new xcstrings key:** `en`, `ja`, `ko`, `zh-Hans`, `zh-Hant`.

---

## Task 1: Add arranger/lyricist/copyright to `ScoreItem` (Domain)

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ScoreItem.swift`
- Test: `Packages/Domain/Tests/DomainTests/Models/ScoreItemTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `ScoreItemTests.swift` (inside the existing test struct/suite; if the suite uses a `makeItem` helper, ignore it and build the item inline as below):

```swift
@Test func `new credit fields round-trip through Codable`() throws {
    let item = ScoreItem(
        title: "Sonata",
        composer: "Beethoven",
        arranger: "Liszt",
        lyricist: "Schiller",
        copyright: "© 1824",
        instrumentationSummary: nil,
        localFileName: "x.mscx",
        contentHash: "h",
        sizeBytes: 1,
        lengthBeats: 0,
        defaultTempoBpm: 120,
        primaryKey: nil,
        addedAt: Date(timeIntervalSince1970: 0),
        lastOpenedAt: nil,
        tagIDs: [],
        isFavorite: false,
    )
    let data = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(ScoreItem.self, from: data)
    #expect(decoded.arranger == "Liszt")
    #expect(decoded.lyricist == "Schiller")
    #expect(decoded.copyright == "© 1824")
}

@Test func `decoding legacy JSON without credit fields yields nil`() throws {
    // A ScoreItem encoded before the new fields existed has no arranger/lyricist/copyright keys.
    let json = """
    {"id":{"rawValue":"00000000-0000-0000-0000-000000000000"},"title":"Old","localFileName":"o.mscx",\
    "contentHash":"h","sizeBytes":1,"lengthBeats":0,"defaultTempoBpm":120,"addedAt":0,"tagIDs":[],"isFavorite":false}
    """
    let decoded = try JSONDecoder().decode(ScoreItem.self, from: Data(json.utf8))
    #expect(decoded.arranger == nil)
    #expect(decoded.lyricist == nil)
    #expect(decoded.copyright == nil)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation` (from `Packages/Domain`)
Expected: FAIL — compile error, `ScoreItem` has no `arranger` argument.

- [ ] **Step 3: Add the fields + init params**

In `ScoreItem.swift`, add three stored properties immediately after `public var composer: String?`:

```swift
public var composer: String?
public var arranger: String?
public var lyricist: String?
public var copyright: String?
```

Add three init parameters immediately after `composer: String?,` (all default to nil so existing labeled call sites keep compiling):

```swift
composer: String?,
arranger: String? = nil,
lyricist: String? = nil,
copyright: String? = nil,
```

Add the three assignments immediately after `self.composer = composer`:

```swift
self.composer = composer
self.arranger = arranger
self.lyricist = lyricist
self.copyright = copyright
```

- [ ] **Step 4: Run the test to verify it passes**

Run the same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/ScoreItem.swift Packages/Domain/Tests/DomainTests/Models/ScoreItemTests.swift
git commit -m "feat(domain): add arranger/lyricist/copyright to ScoreItem"
```

---

## Task 2: Add arranger/lyricist/copyright to `ScoreFileSummary` (Domain)

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Protocols/ScoreFileGateway.swift` (the `ScoreFileSummary` struct, lines ~4–31)
- Test: `Packages/Domain/Tests/DomainTests/Protocols/ScoreFileImporterTests.swift` (or a new `ScoreFileSummaryTests.swift` in the same dir if that file has no room — prefer adding to the existing file)

- [ ] **Step 1: Write the failing test**

Add to `Packages/Domain/Tests/DomainTests/Protocols/ScoreFileImporterTests.swift`:

```swift
@Test func `score file summary carries credit fields`() {
    let summary = ScoreFileSummary(
        title: "T",
        composer: "C",
        arranger: "A",
        lyricist: "L",
        copyright: "©",
        instrumentationSummary: "",
        lengthBeats: 0,
        defaultTempoBpm: 120,
        primaryKey: nil,
    )
    #expect(summary.arranger == "A")
    #expect(summary.lyricist == "L")
    #expect(summary.copyright == "©")
}
```

- [ ] **Step 2: Run to verify it fails**

Run (from `Packages/Domain`): `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: FAIL — compile error, no `arranger` argument.

- [ ] **Step 3: Add fields + init params (with nil defaults)**

In `ScoreFileGateway.swift`, in `ScoreFileSummary`, add after `public var composer: String?`:

```swift
public var composer: String?
public var arranger: String?
public var lyricist: String?
public var copyright: String?
```

Add init params after `composer: String?,` (defaults keep all existing call sites — fakes, `ScoreFileSummary+Score` — compiling):

```swift
composer: String?,
arranger: String? = nil,
lyricist: String? = nil,
copyright: String? = nil,
```

Add assignments after `self.composer = composer`:

```swift
self.composer = composer
self.arranger = arranger
self.lyricist = lyricist
self.copyright = copyright
```

- [ ] **Step 4: Run to verify it passes** — same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Protocols/ScoreFileGateway.swift Packages/Domain/Tests/DomainTests/Protocols/ScoreFileImporterTests.swift
git commit -m "feat(domain): add credit fields to ScoreFileSummary"
```

---

## Task 3: New Domain protocol — `ScoreMetadataReading`, `ScoreSourceKind`, `ScoreFileMetadata`

**Files:**
- Create: `Packages/Domain/Sources/Domain/Protocols/ScoreMetadataReading.swift`
- Test: `Packages/Domain/Tests/DomainTests/Protocols/ScoreMetadataReadingTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Domain/Tests/DomainTests/Protocols/ScoreMetadataReadingTests.swift`:

```swift
import Foundation
@testable import Domain
import Testing

struct ScoreMetadataReadingTests {
    @Test func `metadata value type stores its fields`() {
        let meta = ScoreFileMetadata(
            source: .museScore(majorVersion: 4),
            composer: "C",
            arranger: "A",
            lyricist: "L",
            copyright: "©",
        )
        #expect(meta.source == .museScore(majorVersion: 4))
        #expect(meta.composer == "C")
        #expect(meta.arranger == "A")
        #expect(meta.lyricist == "L")
        #expect(meta.copyright == "©")
    }

    @Test func `source kinds are equatable`() {
        #expect(ScoreSourceKind.midi == .midi)
        #expect(ScoreSourceKind.museScore(majorVersion: 3) != .museScore(majorVersion: 4))
    }
}
```

- [ ] **Step 2: Run to verify it fails** — Expected: FAIL (types undefined).

- [ ] **Step 3: Create the protocol file**

Create `Packages/Domain/Sources/Domain/Protocols/ScoreMetadataReading.swift`:

```swift
import Foundation

/// The originating file format of a score, recovered by parsing the file. Domain-pure mirror of swift-sheet-music's
/// `ScoreSource` so Features can render a source label without importing the music engine. MuseScore carries its
/// detected wire-format major version (2, 3, or 4).
public enum ScoreSourceKind: Hashable, Sendable {
    case museScore(majorVersion: Int)
    case musicXML
    case midi
    case pdf
    case unknown
}

/// Read-only metadata recovered from a score file on demand: the source format plus the human-readable credit
/// metaTags. Used by the Library's edit sheet to show the source and to pre-fill credit fields that have never been
/// edited (NULL columns). Edits are persisted to `ScoreItem`, not back into the file.
public struct ScoreFileMetadata: Hashable, Sendable {
    public let source: ScoreSourceKind
    public let composer: String?
    public let arranger: String?
    public let lyricist: String?
    public let copyright: String?

    public init(
        source: ScoreSourceKind,
        composer: String?,
        arranger: String?,
        lyricist: String?,
        copyright: String?,
    ) {
        self.source = source
        self.composer = composer
        self.arranger = arranger
        self.lyricist = lyricist
        self.copyright = copyright
    }
}

/// Parses an existing library item's on-disk file to recover its `ScoreFileMetadata`. The parse happens on demand
/// (when the edit sheet opens), mirroring how `ScoreShareService` reads `Score.source` lazily — never eagerly per
/// library row.
public protocol ScoreMetadataReading: Sendable {
    func readMetadata(for item: ScoreItem) async throws -> ScoreFileMetadata
}
```

- [ ] **Step 4: Run to verify it passes** — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Protocols/ScoreMetadataReading.swift Packages/Domain/Tests/DomainTests/Protocols/ScoreMetadataReadingTests.swift
git commit -m "feat(domain): add ScoreMetadataReading protocol and value types"
```

---

## Task 4: `ScoreItemRecord` columns + GRDB migration v10 (Infrastructure)

**Files:**
- Modify: `Packages/Infrastructure/Sources/Persistence/Records/ScoreItemRecord.swift`
- Modify: `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ScoreItemRecordTests.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreLibraryRepositoryTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `ScoreItemRecordTests.swift`:

```swift
@Test func `record round-trips credit fields`() throws {
    let item = ScoreItem(
        title: "T",
        composer: "C",
        arranger: "A",
        lyricist: "L",
        copyright: "©",
        instrumentationSummary: nil,
        localFileName: "x.mscx",
        contentHash: "h",
        sizeBytes: 1,
        lengthBeats: 0,
        defaultTempoBpm: 120,
        primaryKey: nil,
        addedAt: Date(timeIntervalSince1970: 0),
        lastOpenedAt: nil,
        tagIDs: [],
        isFavorite: false,
    )
    let record = ScoreItemRecord(domain: item)
    let back = try record.toDomain(tagIDs: [])
    #expect(back.arranger == "A")
    #expect(back.lyricist == "L")
    #expect(back.copyright == "©")
}
```

Add to `LiveScoreLibraryRepositoryTests.swift` (mirror an existing save→read test in that file for rig setup; the assertion is what matters):

```swift
@Test func `saving and reading back preserves credit fields`() async throws {
    let rig = try await makeRig()                 // use this file's existing rig/helper name
    defer { withExtendedLifetime(rig) {} }        // match the file's existing lifetime pattern
    var item = Self.makeItem()                    // use this file's existing item factory
    item.arranger = "A"
    item.lyricist = "L"
    item.copyright = "©"
    try await rig.repository.saveScoreItem(item)
    try await rig.repository.refresh()
    let stored = try #require(rig.repository.scoreItems.first { $0.id == item.id })
    #expect(stored.arranger == "A")
    #expect(stored.lyricist == "L")
    #expect(stored.copyright == "©")
}
```

> Note for implementer: open `LiveScoreLibraryRepositoryTests.swift` first and copy its exact rig/helper/lifetime idioms (names like `makeRig`, `makeItem`, `withExtendedLifetime` may differ). Keep the three assertions; adapt the scaffolding to match the file.

- [ ] **Step 2: Run to verify they fail**

Run (from `Packages/Infrastructure`): `xcodebuild test -scheme Infrastructure -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: FAIL — `toDomain` doesn't carry the fields / column missing.

- [ ] **Step 3: Add record fields + migration**

In `ScoreItemRecord.swift`:

Add stored vars after `var composer: String?`:

```swift
var composer: String?
var arranger: String?
var lyricist: String?
var copyright: String?
```

Add to `CodingKeys` after `case composer` (single-word columns need no raw value):

```swift
case composer
case arranger
case lyricist
case copyright
```

In `init(domain item:)`, after `composer = item.composer`:

```swift
composer = item.composer
arranger = item.arranger
lyricist = item.lyricist
copyright = item.copyright
```

In `toDomain(tagIDs:)`, in the `ScoreItem(...)` construction, after `composer: composer,`:

```swift
composer: composer,
arranger: arranger,
lyricist: lyricist,
copyright: copyright,
```

In `Migrations.swift`, register v10 in the `static let all` block after the `m.registerMigration("v9", ...)` line:

```swift
m.registerMigration("v9", migrate: migrateV9)
m.registerMigration("v10", migrate: migrateV10)
```

Add the migration function alongside the others (mirror the v8 ALTER pattern):

```swift
/// Adds the human-readable credit columns surfaced by the Library edit sheet. All are NULL for existing rows
/// (column default). NULL means "never edited" — the edit sheet pre-fills such fields from the on-disk file the
/// first time it opens; an explicit empty string means the user cleared the field.
private static func migrateV10(_ db: Database) throws {
    try db.execute(sql: "ALTER TABLE score_items ADD COLUMN arranger TEXT")
    try db.execute(sql: "ALTER TABLE score_items ADD COLUMN lyricist TEXT")
    try db.execute(sql: "ALTER TABLE score_items ADD COLUMN copyright TEXT")
}
```

- [ ] **Step 4: Run to verify they pass** — same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/Persistence/Records/ScoreItemRecord.swift Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ScoreItemRecordTests.swift Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreLibraryRepositoryTests.swift
git commit -m "feat(persistence): persist credit fields via GRDB migration v10"
```

---

## Task 5: Extract credit metaTags at import (Infrastructure)

**Files:**
- Modify: `Packages/Infrastructure/Sources/ScoreFiles/ScoreFileSummary+Score.swift`
- Modify: `Packages/Infrastructure/Sources/Persistence/LiveScoreFileImporter.swift` (the `ScoreItem(...)` in `commitImport`)
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/ScoreFileSummaryFromScoreTests.swift` (new)

- [ ] **Step 1: Write the failing test**

Create `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/ScoreFileSummaryFromScoreTests.swift`:

```swift
import Domain
import Foundation
@testable import Infrastructure
import SheetMusicCore
import Testing

struct ScoreFileSummaryFromScoreTests {
    @Test func `summary extracts credit metaTags`() {
        let score = Score(
            division: 480,
            metaTags: [
                "composer": "Beethoven",
                "arranger": "Liszt",
                "lyricist": "Schiller",
                "copyright": "© 1824",
            ],
        )
        let summary = ScoreFileSummary(score: score)
        #expect(summary.composer == "Beethoven")
        #expect(summary.arranger == "Liszt")
        #expect(summary.lyricist == "Schiller")
        #expect(summary.copyright == "© 1824")
    }

    @Test func `summary leaves missing credit metaTags nil`() {
        let summary = ScoreFileSummary(score: Score(division: 480))
        #expect(summary.arranger == nil)
        #expect(summary.lyricist == nil)
        #expect(summary.copyright == nil)
    }
}
```

> Implementer note: confirm the `@testable import Infrastructure` module name matches the package's library product (it may be `Infrastructure`). If `Score` / `SheetMusicCore` import fails, check how `ScoreFileSummary+Score.swift` imports the engine (it uses `import SheetMusic`) and mirror that import in the test.

- [ ] **Step 2: Run to verify it fails** — Expected: FAIL (`summary.arranger` is always nil).

- [ ] **Step 3: Read the metaTags in the summary init**

In `ScoreFileSummary+Score.swift`, after the existing `let composer = score.metaTags["composer"]?.nonEmpty` line, add:

```swift
let composer = score.metaTags["composer"]?.nonEmpty
let arranger = score.metaTags["arranger"]?.nonEmpty
let lyricist = score.metaTags["lyricist"]?.nonEmpty
let copyright = score.metaTags["copyright"]?.nonEmpty
```

In the same file's `self.init(...)` call, pass them after `composer: composer,`:

```swift
composer: composer,
arranger: arranger,
lyricist: lyricist,
copyright: copyright,
```

- [ ] **Step 4: Pass them through the importer**

In `LiveScoreFileImporter.swift` `commitImport`, in the `let item = ScoreItem(...)` construction, after `composer: plan.summary.composer,`:

```swift
composer: plan.summary.composer,
arranger: plan.summary.arranger,
lyricist: plan.summary.lyricist,
copyright: plan.summary.copyright,
```

- [ ] **Step 5: Run to verify it passes** — Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/Infrastructure/Sources/ScoreFiles/ScoreFileSummary+Score.swift Packages/Infrastructure/Sources/Persistence/LiveScoreFileImporter.swift Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/ScoreFileSummaryFromScoreTests.swift
git commit -m "feat(import): snapshot arranger/lyricist/copyright metaTags on import"
```

---

## Task 6: `LiveScoreMetadataReader` + `ScoreFileMetadata(score:)` mapping (Infrastructure)

**Files:**
- Create: `Packages/Infrastructure/Sources/ScoreFiles/ScoreFileMetadata+Score.swift`
- Create: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreMetadataReader.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/ScoreFileMetadataFromScoreTests.swift` (new)
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreMetadataReaderTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

Create `ScoreFileMetadataFromScoreTests.swift`:

```swift
import Domain
import Foundation
@testable import Infrastructure
import SheetMusicCore
import Testing

struct ScoreFileMetadataFromScoreTests {
    @Test func `maps museScore v4 source and credit metaTags`() {
        let score = Score(
            division: 480,
            metaTags: ["composer": "C", "arranger": "A", "lyricist": "L", "copyright": "©"],
            source: .museScore(.v4),
        )
        let meta = ScoreFileMetadata(score: score)
        #expect(meta.source == .museScore(majorVersion: 4))
        #expect(meta.composer == "C")
        #expect(meta.arranger == "A")
        #expect(meta.lyricist == "L")
        #expect(meta.copyright == "©")
    }

    @Test func `maps each source kind`() {
        #expect(ScoreFileMetadata(score: Score(division: 1, source: .museScore(.v3))).source == .museScore(majorVersion: 3))
        #expect(ScoreFileMetadata(score: Score(division: 1, source: .museScore(.v2))).source == .museScore(majorVersion: 2))
        #expect(ScoreFileMetadata(score: Score(division: 1, source: .musicXML)).source == .musicXML)
        #expect(ScoreFileMetadata(score: Score(division: 1, source: .midi)).source == .midi)
        #expect(ScoreFileMetadata(score: Score(division: 1, source: .pdf)).source == .pdf)
        #expect(ScoreFileMetadata(score: Score(division: 1, source: .unknown)).source == .unknown)
    }
}
```

Create `LiveScoreMetadataReaderTests.swift` (fixture-driven, mirroring `LiveScoreShareServiceTests` rig — the bundled `minimal.mscz` parses as MuseScore v4):

```swift
import Domain
import Foundation
@testable import Infrastructure
import Testing

struct LiveScoreMetadataReaderTests {
    @Test func `reads museScore source from an on-disk mscz`() async throws {
        let tmp = try TempDirectory()
        defer { withExtendedLifetime(tmp) {} }
        let scores = tmp.url.appending(path: "Scores")
        try FileManager.default.createDirectory(at: scores, withIntermediateDirectories: true)
        let localFileName = "abc.mscz"
        try Fixtures.minimalMSCZData().write(to: scores.appending(path: localFileName))

        let reader = LiveScoreMetadataReader(
            gateway: LiveScoreFileGateway(),
            scoresDirectory: scores,
        )
        let item = ScoreItem(
            title: "T", composer: nil, instrumentationSummary: nil,
            localFileName: localFileName, contentHash: "h", sizeBytes: 1,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        let meta = try await reader.readMetadata(for: item)
        #expect(meta.source == .museScore(majorVersion: 4))
    }
}
```

> Implementer note: `TempDirectory` and `Fixtures` live in `Packages/Infrastructure/Tests/InfrastructureTests/TestSupport/`. `LiveScoreFileGateway()` is the real gateway used by the existing share-service tests.

- [ ] **Step 2: Run to verify they fail** — Expected: FAIL (types/initializers undefined).

- [ ] **Step 3: Create the mapping extension**

Create `Packages/Infrastructure/Sources/ScoreFiles/ScoreFileMetadata+Score.swift`. Match the engine import used by `ScoreFileSummary+Score.swift` (`import SheetMusic`):

```swift
import Domain
import Foundation
import SheetMusic

extension ScoreFileMetadata {
    /// Build the Domain-side read-only metadata from a parsed `Score`. Maps `Score.source` into the engine-free
    /// `ScoreSourceKind` and pulls the credit metaTags (empty strings normalized to nil via `nonEmpty`).
    init(score: Score) {
        self.init(
            source: ScoreSourceKind(source: score.source),
            composer: score.metaTags["composer"]?.nonEmpty,
            arranger: score.metaTags["arranger"]?.nonEmpty,
            lyricist: score.metaTags["lyricist"]?.nonEmpty,
            copyright: score.metaTags["copyright"]?.nonEmpty,
        )
    }
}

extension ScoreSourceKind {
    init(source: ScoreSource) {
        switch source {
        case let .museScore(version):
            switch version {
            case .v2: self = .museScore(majorVersion: 2)
            case .v3: self = .museScore(majorVersion: 3)
            case .v4: self = .museScore(majorVersion: 4)
            }
        case .musicXML: self = .musicXML
        case .midi: self = .midi
        case .pdf: self = .pdf
        case .unknown: self = .unknown
        }
    }
}
```

> Implementer note: if `nonEmpty` is not visible here, check where `ScoreFileSummary+Score.swift` gets it (same module) and use the identical accessor.

- [ ] **Step 4: Create the reader**

Create `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreMetadataReader.swift` (mirror `LiveScoreShareService`'s gateway + scoresDirectory shape):

```swift
import Domain
import Foundation
import SheetMusic

/// Reads read-only metadata (source format + credit metaTags) from a library item's on-disk file by parsing it on
/// demand via the score gateway — the same lazy parse the share service uses. Used by the Library edit sheet to show
/// the source and to pre-fill credit fields that have never been edited.
public struct LiveScoreMetadataReader: ScoreMetadataReading {
    private let gateway: any ScoreFileGateway
    private let scoresDirectory: URL

    public init(gateway: any ScoreFileGateway, scoresDirectory: URL) {
        self.gateway = gateway
        self.scoresDirectory = scoresDirectory
    }

    public func readMetadata(for item: ScoreItem) async throws -> ScoreFileMetadata {
        let url = scoresDirectory.appending(path: item.localFileName)
        let (score, _) = try await gateway.loadScore(fileURL: url)
        return ScoreFileMetadata(score: score)
    }
}
```

- [ ] **Step 5: Run to verify they pass** — Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/Infrastructure/Sources/ScoreFiles/ScoreFileMetadata+Score.swift Packages/Infrastructure/Sources/ScoreFiles/LiveScoreMetadataReader.swift Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/ScoreFileMetadataFromScoreTests.swift Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreMetadataReaderTests.swift
git commit -m "feat(infra): add LiveScoreMetadataReader for on-demand source + credits"
```

---

## Task 7: `LibraryViewModel` gains `metadataReader`, `loadFileMetadata`, `saveMetadata` + App wiring

This task threads the new dependency end-to-end so the app and tests compile. It keeps the existing `rename` method (removed in Task 9 with the alert).

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`
- Create: `Packages/Features/Library/Tests/LibraryTests/Fakes/FakeScoreMetadataReading.swift`
- Modify: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift` (the `makeVM` helper + new tests)
- Modify: `App/AppBootstrap.swift`
- Modify: `App/AppShellView.swift`
- Test: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift`

- [ ] **Step 1: Write the failing tests + fake**

Create `Packages/Features/Library/Tests/LibraryTests/Fakes/FakeScoreMetadataReading.swift`:

```swift
import Domain
import Foundation

final class FakeScoreMetadataReading: ScoreMetadataReading, @unchecked Sendable {
    var result: Result<ScoreFileMetadata, DomainError> = .success(
        ScoreFileMetadata(source: .unknown, composer: nil, arranger: nil, lyricist: nil, copyright: nil),
    )

    func readMetadata(for item: ScoreItem) throws -> ScoreFileMetadata {
        switch result {
        case let .success(meta): return meta
        case let .failure(error): throw error
        }
    }
}
```

In `LibraryViewModelTests.swift`, update the `VMFixture` struct + `makeVM` to add the reader, and add tests:

```swift
private struct VMFixture {
    let vm: LibraryViewModel
    let repo: FakeScoreLibraryRepository
    let importer: FakeScoreFileImporter
    let gateway: FakeScoreFileGateway
    let share: FakeScoreShareService
    let metadataReader: FakeScoreMetadataReading
}

private static func makeVM(scoreItems: [ScoreItem] = []) -> VMFixture {
    let repo = FakeScoreLibraryRepository()
    repo.scoreItems = scoreItems
    let importer = FakeScoreFileImporter()
    let gateway = FakeScoreFileGateway()
    let share = FakeScoreShareService()
    let metadataReader = FakeScoreMetadataReading()
    let vm = LibraryViewModel(
        repository: repo, importer: importer, gateway: gateway,
        shareService: share, metadataReader: metadataReader,
    )
    return VMFixture(vm: vm, repo: repo, importer: importer, gateway: gateway, share: share, metadataReader: metadataReader)
}

@Test func `save metadata trims title and stores all fields`() async {
    let item = Self.makeItem(title: "Old")
    let f = Self.makeVM(scoreItems: [item])
    let fields = EditableScoreInfo(
        title: "  New  ", subtitle: "Sub", composer: "C", arranger: "A", lyricist: "L", copyright: "©",
    )
    await f.vm.saveMetadata(item, fields: fields)
    let saved = f.repo.savedScoreItems.last
    #expect(saved?.title == "New")
    #expect(saved?.composer == "C")
    #expect(saved?.arranger == "A")
    #expect(saved?.lyricist == "L")
    #expect(saved?.copyright == "©")
}

@Test func `save metadata with blank title is ignored`() async {
    let item = Self.makeItem(title: "Keep")
    let f = Self.makeVM(scoreItems: [item])
    let fields = EditableScoreInfo(title: "   ", subtitle: "", composer: "", arranger: "", lyricist: "", copyright: "")
    await f.vm.saveMetadata(item, fields: fields)
    #expect(f.repo.savedScoreItems.isEmpty)
}

@Test func `load file metadata returns reader result`() async {
    let item = Self.makeItem()
    let f = Self.makeVM(scoreItems: [item])
    f.metadataReader.result = .success(
        ScoreFileMetadata(source: .museScore(majorVersion: 4), composer: "C", arranger: "A", lyricist: nil, copyright: nil),
    )
    let meta = await f.vm.loadFileMetadata(for: item)
    #expect(meta?.source == .museScore(majorVersion: 4))
    #expect(meta?.arranger == "A")
}

@Test func `load file metadata swallows errors as nil`() async {
    let item = Self.makeItem()
    let f = Self.makeVM(scoreItems: [item])
    f.metadataReader.result = .failure(.scoreParseFailed(reason: "x"))
    let meta = await f.vm.loadFileMetadata(for: item)
    #expect(meta == nil)
}
```

> Implementer note: `EditableScoreInfo` is created in Task 8. To keep Task 7 self-contained and green, add a minimal `EditableScoreInfo` definition NOW as part of Task 7 (Step 3) — Task 8 will build the sheet UI around it. (It is small enough to live with the view model concern until then.)

- [ ] **Step 2: Run to verify they fail** — from `Packages/Features/Library`:
  `xcodebuild test -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
  Expected: FAIL — `metadataReader` arg / `EditableScoreInfo` / `saveMetadata` / `loadFileMetadata` undefined.

- [ ] **Step 3: Add the dependency, the value type, and the methods**

In `LibraryViewModel.swift`, add the stored property after `let shareService: any ScoreShareService`:

```swift
let shareService: any ScoreShareService
let metadataReader: any ScoreMetadataReading
```

Add the init param after `shareService: any ScoreShareService,` and assign it:

```swift
public init(
    repository: any ScoreLibraryRepository,
    importer: any ScoreFileImporter,
    gateway: any ScoreFileGateway,
    shareService: any ScoreShareService,
    metadataReader: any ScoreMetadataReading,
) {
    self.repository = repository
    self.importer = importer
    self.gateway = gateway
    self.shareService = shareService
    self.metadataReader = metadataReader
}
```

Add the `EditableScoreInfo` value type and the two methods (place near `rename`/`save`):

```swift
/// Mutable form payload for the edit-info sheet. Empty strings are meaningful — saving an empty field clears it
/// (persisted as `""`, which suppresses future file pre-fill).
struct EditableScoreInfo: Equatable {
    var title: String
    var subtitle: String
    var composer: String
    var arranger: String
    var lyricist: String
    var copyright: String
}

/// Read the on-disk file's source + credit metaTags. Errors collapse to nil so a transient parse failure simply
/// leaves the source label / pre-fill empty instead of blocking editing.
func loadFileMetadata(for item: ScoreItem) async -> ScoreFileMetadata? {
    try? await metadataReader.readMetadata(for: item)
}

/// Apply the edited fields to the item and persist. Title is required (trimmed, non-empty); other fields are stored
/// trimmed, with empties persisted as `""` so they are treated as explicit user values, not "never edited".
func saveMetadata(_ item: ScoreItem, fields: EditableScoreInfo) async {
    let trimmedTitle = fields.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else { return }
    var updated = item
    updated.title = trimmedTitle
    updated.subtitle = fields.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
    updated.composer = fields.composer.trimmingCharacters(in: .whitespacesAndNewlines)
    updated.arranger = fields.arranger.trimmingCharacters(in: .whitespacesAndNewlines)
    updated.lyricist = fields.lyricist.trimmingCharacters(in: .whitespacesAndNewlines)
    updated.copyright = fields.copyright.trimmingCharacters(in: .whitespacesAndNewlines)
    await save(updated)
}
```

- [ ] **Step 4: Wire the dependency through App**

In `App/AppBootstrap.swift`, add a stored property after `shareService`:

```swift
private(set) var shareService: LiveScoreShareService?
private(set) var metadataReader: LiveScoreMetadataReader?
```

In `installAudioStack(gateway:)`, after the `shareService = LiveScoreShareService(...)` assignment, add:

```swift
metadataReader = LiveScoreMetadataReader(
    scoresDirectory: AppPaths.scoresDirectory,
    gateway: gateway,
)
```

> Note: `LiveScoreMetadataReader.init` is `(gateway:scoresDirectory:)`. Use the correct argument labels — `LiveScoreMetadataReader(gateway: gateway, scoresDirectory: AppPaths.scoresDirectory)`.

In `App/AppShellView.swift`:

Add the ReadyShell stored property after `let shareService: any ScoreShareService`:

```swift
let shareService: any ScoreShareService
let metadataReader: any ScoreMetadataReading
```

Add the init param after `shareService: any ScoreShareService,`, assign it, and pass it into the `LibraryViewModel(...)`:

```swift
init(
    bootstrap: AppBootstrap,
    repository: any ScoreLibraryRepository,
    importer: any ScoreFileImporter,
    gateway: any ScoreFileGateway,
    shareService: any ScoreShareService,
    metadataReader: any ScoreMetadataReading,
    scoresDirectory: URL,
    versionHistoryPresenter: VersionHistoryPresenter,
) {
    ...
    self.shareService = shareService
    self.metadataReader = metadataReader
    ...
    _libraryVM = State(
        wrappedValue: LibraryViewModel(
            repository: repository,
            importer: importer,
            gateway: gateway,
            shareService: shareService,
            metadataReader: metadataReader,
        ),
    )
    ...
}
```

Update the guard-let that unwraps bootstrap dependencies and the `ReadyShell(...)` instantiation to include the reader:

```swift
if let repository = bootstrap.repository,
   let importer = bootstrap.importer,
   let gateway = bootstrap.gateway,
   let shareService = bootstrap.shareService,
   let metadataReader = bootstrap.metadataReader,
   bootstrap.isReady
{
    ReadyShell(
        bootstrap: bootstrap,
        repository: repository,
        importer: importer,
        gateway: gateway,
        shareService: shareService,
        metadataReader: metadataReader,
        scoresDirectory: AppPaths.scoresDirectory,
        versionHistoryPresenter: versionHistoryPresenter,
    )
}
```

> Implementer note: the guard-let above is the documented shape; open `AppShellView.swift` and match the actual surrounding code exactly (it may bind differently). Add `metadataReader` to whatever unwrap already exists.

- [ ] **Step 5: Run Library tests to verify pass** — Expected: PASS.

- [ ] **Step 6: Build the app to verify wiring compiles**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Library/Sources/Library/LibraryViewModel.swift Packages/Features/Library/Tests/LibraryTests/Fakes/FakeScoreMetadataReading.swift Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift App/AppBootstrap.swift App/AppShellView.swift
git commit -m "feat(library): wire metadataReader, add saveMetadata + loadFileMetadata"
```

---

## Task 8: `EditScoreInfoSheet` view + pre-fill init + localization

**Files:**
- Create: `Packages/Features/Library/Sources/Library/Views/EditScoreInfoSheet.swift`
- Create: `Packages/Features/Library/Sources/Library/Views/EditableScoreInfo+PreFill.swift`
- Modify: `Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings`
- Test: `Packages/Features/Library/Tests/LibraryTests/EditableScoreInfoPreFillTests.swift` (new)

- [ ] **Step 1: Write the failing test for the pure pre-fill logic**

Create `Packages/Features/Library/Tests/LibraryTests/EditableScoreInfoPreFillTests.swift`:

```swift
import Domain
import Foundation
@testable import Library
import Testing

@MainActor
struct EditableScoreInfoPreFillTests {
    private static func item(
        subtitle: String? = nil, composer: String? = nil,
        arranger: String? = nil, lyricist: String? = nil, copyright: String? = nil,
    ) -> ScoreItem {
        ScoreItem(
            title: "T", composer: composer, arranger: arranger, lyricist: lyricist, copyright: copyright,
            instrumentationSummary: nil, localFileName: "x.mscx", contentHash: "h", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0), lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        ).withSubtitle(subtitle)
    }

    @Test func `NULL field is pre-filled from file metadata`() {
        let meta = ScoreFileMetadata(source: .unknown, composer: nil, arranger: "FromFile", lyricist: nil, copyright: nil)
        let fields = EditableScoreInfo(item: Self.item(arranger: nil), fileMetadata: meta)
        #expect(fields.arranger == "FromFile")
    }

    @Test func `explicitly cleared field is not re-filled`() {
        let meta = ScoreFileMetadata(source: .unknown, composer: nil, arranger: "FromFile", lyricist: nil, copyright: nil)
        let fields = EditableScoreInfo(item: Self.item(arranger: ""), fileMetadata: meta)
        #expect(fields.arranger == "")
    }

    @Test func `stored value wins over file metadata`() {
        let meta = ScoreFileMetadata(source: .unknown, composer: nil, arranger: "FromFile", lyricist: nil, copyright: nil)
        let fields = EditableScoreInfo(item: Self.item(arranger: "Stored"), fileMetadata: meta)
        #expect(fields.arranger == "Stored")
    }

    @Test func `nil metadata falls back to empty strings`() {
        let fields = EditableScoreInfo(item: Self.item(), fileMetadata: nil)
        #expect(fields.title == "T")
        #expect(fields.arranger == "")
        #expect(fields.composer == "")
    }
}

private extension ScoreItem {
    func withSubtitle(_ value: String?) -> ScoreItem {
        var copy = self
        copy.subtitle = value
        return copy
    }
}
```

- [ ] **Step 2: Run to verify it fails** — Expected: FAIL (`EditableScoreInfo(item:fileMetadata:)` undefined).

- [ ] **Step 3: Implement the pure pre-fill init**

Create `Packages/Features/Library/Sources/Library/Views/EditableScoreInfo+PreFill.swift`:

```swift
import Domain

extension EditableScoreInfo {
    /// Build the sheet's initial field values. For each optional credit field: a stored value (including an explicit
    /// empty string the user previously saved) wins; only a NULL column falls back to the file's metaTag. Subtitle is
    /// not a metaTag, so it comes straight from the stored value.
    init(item: ScoreItem, fileMetadata: ScoreFileMetadata?) {
        self.init(
            title: item.title,
            subtitle: item.subtitle ?? "",
            composer: item.composer ?? fileMetadata?.composer ?? "",
            arranger: item.arranger ?? fileMetadata?.arranger ?? "",
            lyricist: item.lyricist ?? fileMetadata?.lyricist ?? "",
            copyright: item.copyright ?? fileMetadata?.copyright ?? "",
        )
    }
}
```

- [ ] **Step 4: Run to verify it passes** — Expected: PASS.

- [ ] **Step 5: Add localization keys**

Add these keys to `Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings` (each with `en`/`ja`/`ko`/`zh-Hans`/`zh-Hant`, state `"translated"`, matching the existing JSON shape):

| Key | en | ja | ko | zh-Hans | zh-Hant |
| --- | --- | --- | --- | --- | --- |
| `library.score.editInfo.action` | Edit Info | 情報を編集 | 정보 편집 | 编辑信息 | 編輯資訊 |
| `library.score.editInfo.title` | Edit Info | 情報を編集 | 정보 편집 | 编辑信息 | 編輯資訊 |
| `library.score.field.title` | Title | タイトル | 제목 | 标题 | 標題 |
| `library.score.field.subtitle` | Subtitle | サブタイトル | 부제 | 副标题 | 副標題 |
| `library.score.field.composer` | Composer | 作曲者 | 작곡가 | 作曲 | 作曲 |
| `library.score.field.arranger` | Arranger | 編曲者 | 편곡자 | 编曲 | 編曲 |
| `library.score.field.lyricist` | Lyricist | 作詞者 | 작사가 | 作词 | 作詞 |
| `library.score.field.copyright` | Copyright | 著作権 | 저작권 | 版权 | 版權 |
| `library.score.info.section` | Information | 情報 | 정보 | 信息 | 資訊 |
| `library.score.field.source` | Source | ソース | 소스 | 来源 | 來源 |
| `library.score.field.dateAdded` | Date Added | 追加日時 | 추가 날짜 | 添加日期 | 加入日期 |
| `library.score.source.unknown` | Unknown | 不明 | 알 수 없음 | 未知 | 未知 |

One entry's exact JSON shape to follow (repeat per key):

```json
"library.score.field.dateAdded" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Date Added" } },
    "ja" : { "stringUnit" : { "state" : "translated", "value" : "追加日時" } },
    "ko" : { "stringUnit" : { "state" : "translated", "value" : "추가 날짜" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "添加日期" } },
    "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "加入日期" } }
  }
}
```

- [ ] **Step 6: Create the sheet view**

Create `Packages/Features/Library/Sources/Library/Views/EditScoreInfoSheet.swift`:

```swift
import Domain
import SwiftUI
import UtilityUI

/// Modal metadata editor for a single score. Editable credit fields (top section) plus a read-only info section
/// (source format + date added). Title is required; Save is disabled while it is blank. On appear the on-disk file is
/// parsed once to fill the source label and pre-fill any never-edited credit field.
@MainActor
struct EditScoreInfoSheet: View {
    let viewModel: LibraryViewModel
    let item: ScoreItem
    @Environment(\.dismiss) private var dismiss

    @State private var fields: EditableScoreInfo
    @State private var sourceKind: ScoreSourceKind?
    @State private var didLoad = false

    init(viewModel: LibraryViewModel, item: ScoreItem) {
        self.viewModel = viewModel
        self.item = item
        // Initial values from stored columns only; the .task pass refines with file pre-fill.
        _fields = State(initialValue: EditableScoreInfo(item: item, fileMetadata: nil))
    }

    private var trimmedTitle: String {
        fields.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent { TextField("", text: $fields.title) } label: {
                        Text("library.score.field.title", bundle: .module)
                    }
                    LabeledContent { TextField("", text: $fields.subtitle) } label: {
                        Text("library.score.field.subtitle", bundle: .module)
                    }
                    LabeledContent { TextField("", text: $fields.composer) } label: {
                        Text("library.score.field.composer", bundle: .module)
                    }
                    LabeledContent { TextField("", text: $fields.arranger) } label: {
                        Text("library.score.field.arranger", bundle: .module)
                    }
                    LabeledContent { TextField("", text: $fields.lyricist) } label: {
                        Text("library.score.field.lyricist", bundle: .module)
                    }
                    LabeledContent { TextField("", text: $fields.copyright, axis: .vertical) } label: {
                        Text("library.score.field.copyright", bundle: .module)
                    }
                }

                Section {
                    LabeledContent {
                        Text(Self.sourceLabel(sourceKind))
                    } label: {
                        Text("library.score.field.source", bundle: .module)
                    }
                    LabeledContent {
                        Text(item.addedAt, format: .dateTime.year().month().day().hour().minute())
                    } label: {
                        Text("library.score.field.dateAdded", bundle: .module)
                    }
                } header: {
                    Text("library.score.info.section", bundle: .module)
                }
            }
            .navigationTitle(Text("library.score.editInfo.title", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { L10n.Common.cancel }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let snapshot = fields
                        Task {
                            await viewModel.saveMetadata(item, fields: snapshot)
                            dismiss()
                        }
                    } label: { L10n.Common.save }
                        .disabled(trimmedTitle.isEmpty)
                }
            }
            .task {
                guard !didLoad else { return }
                didLoad = true
                let meta = await viewModel.loadFileMetadata(for: item)
                sourceKind = meta?.source
                fields = EditableScoreInfo(item: item, fileMetadata: meta)
            }
        }
    }

    /// Human-readable source label. MuseScore/MusicXML/MIDI/PDF are brand/format literals (identical across locales);
    /// only "Unknown" / a missing parse is localized.
    static func sourceLabel(_ kind: ScoreSourceKind?) -> String {
        switch kind {
        case let .museScore(major): "MuseScore \(major)"
        case .musicXML: "MusicXML"
        case .midi: "MIDI"
        case .pdf: "PDF"
        case .unknown, nil:
            String(localized: "library.score.source.unknown", bundle: .module)
        }
    }
}

#Preview {
    // Lightweight preview: a stub item; the .task pre-fill is skipped because no real file exists.
    EditScoreInfoSheet(
        viewModel: PreviewSupport.libraryViewModel(),
        item: PreviewSupport.sampleScoreItem(),
    )
}
```

> Implementer note on `#Preview`: Library may already have a preview-support helper. Search the Library sources for an existing `PreviewSupport` / sample-item factory and an existing `LibraryViewModel` preview constructor; reuse it. If none exists, build the item inline with the `ScoreItem(...)` initializer and construct a `LibraryViewModel` with the existing Library test/preview fakes, OR gate the preview body to only render the `Form` with a constant `EditableScoreInfo` if wiring a full view model in a preview is heavy. The preview must compile and render the form.

- [ ] **Step 7: Run Library tests** — Expected: PASS.

- [ ] **Step 8: Render the preview and verify layout**

Per the iOS preview workflow: ensure Xcode is open on `Folino.xcodeproj`, render `EditScoreInfoSheet`'s `#Preview` via `mcp__xcode__RenderPreview`, and `Read` the PNG. Confirm: two sections, six editable rows (copyright multi-line), and an info section with Source + Date Added. Iterate against the snapshot if labels overflow.

- [ ] **Step 9: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Views/EditScoreInfoSheet.swift Packages/Features/Library/Sources/Library/Views/EditableScoreInfo+PreFill.swift Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings Packages/Features/Library/Tests/LibraryTests/EditableScoreInfoPreFillTests.swift
git commit -m "feat(library): add EditScoreInfoSheet and pre-fill logic"
```

---

## Task 9: Integrate the sheet — replace rename with "Edit Info" across menus and screens

**Files:**
- Create: `Packages/Features/Library/Sources/Library/Screens/EditScoreInfoSheetModifier.swift`
- Modify: `Packages/Features/Library/Sources/Library/Views/ScoreRowMenu.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/ScoreRowMenu+Library.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/ScoreListScreen.swift`
- Delete: `Packages/Features/Library/Sources/Library/Screens/LibraryRootRenameScoreAlert.swift`
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift` (remove `rename`)

- [ ] **Step 1: Rename the menu action `onRename` → `onEditInfo` and relabel the button**

In `ScoreRowMenu.swift`, change the parameter `onRename: @escaping (ScoreItem) -> Void,` to `onEditInfo: @escaping (ScoreItem) -> Void,`, and change the button body from:

```swift
Button { onRename(item) } label: {
    Label {
        L10n.Common.rename
    } icon: {
        Image(systemName: "pencil")
    }
}
```

to:

```swift
Button { onEditInfo(item) } label: {
    Label {
        Text("library.score.editInfo.action", bundle: .module)
    } icon: {
        Image(systemName: "square.and.pencil")
    }
}
```

In `ScoreRowMenu+Library.swift`, rename the wrapper's `onRename` param to `onEditInfo` and forward it as `onEditInfo: onEditInfo` in the inner `scoreRowMenu(...)` call.

- [ ] **Step 2: Create the sheet modifier**

Create `Packages/Features/Library/Sources/Library/Screens/EditScoreInfoSheetModifier.swift` (mirror the deleted `LibraryRootRenameScoreAlert` shape):

```swift
import Domain
import SwiftUI

/// Presents `EditScoreInfoSheet` for the bound item. Mirrors the old rename-alert modifier so each screen wires it
/// with one line.
@MainActor
struct EditScoreInfoSheetModifier: ViewModifier {
    let viewModel: LibraryViewModel
    @Binding var target: ScoreItem?

    func body(content: Content) -> some View {
        content.sheet(item: $target) { item in
            EditScoreInfoSheet(viewModel: viewModel, item: item)
        }
    }
}

extension View {
    @MainActor
    func editScoreInfoSheet(viewModel: LibraryViewModel, target: Binding<ScoreItem?>) -> some View {
        modifier(EditScoreInfoSheetModifier(viewModel: viewModel, target: target))
    }
}
```

> `ScoreItem` is `Identifiable` (confirmed), so `.sheet(item:)` works directly.

- [ ] **Step 3: Rewire `LibraryRootScreen`**

In `LibraryRootScreen.swift`:

Replace the rename state:

```swift
@State private var pendingRenameScore: ScoreItem?
@State private var renameScoreText = ""
```

with:

```swift
@State private var editInfoTarget: ScoreItem?
```

Replace the alert modifier application:

```swift
.libraryRootRenameScoreAlert(
    viewModel: viewModel,
    pending: $pendingRenameScore,
    text: $renameScoreText,
)
```

with:

```swift
.editScoreInfoSheet(viewModel: viewModel, target: $editInfoTarget)
```

Replace the menu closure (in `sectionRowMenu`):

```swift
onRename: { item in
    renameScoreText = item.title
    pendingRenameScore = item
},
```

with:

```swift
onEditInfo: { item in editInfoTarget = item },
```

- [ ] **Step 4: Rewire `ScoreListScreen`**

Open `ScoreListScreen.swift` and apply the identical transformation:
- Replace its rename state (`renameText` + `pendingRename`, and any `@State` for them) with a single `@State private var editInfoTarget: ScoreItem?`.
- Replace its rename alert/sheet modifier application (whatever it uses to present rename — search for `rename` in the file) with `.editScoreInfoSheet(viewModel: library, target: $editInfoTarget)` (use the view model variable name this screen already holds — it passes `library:` to `scoreRowMenu`).
- Replace the menu closure `onRename: { item in renameText = item.title; pendingRename = item }` with `onEditInfo: { item in editInfoTarget = item }`.

> If `ScoreListScreen` was relying on the same `LibraryRootRenameScoreAlert` modifier, that modifier is being deleted — switch it to `.editScoreInfoSheet`.

- [ ] **Step 5: Delete the rename alert and the view model method**

Delete `Packages/Features/Library/Sources/Library/Screens/LibraryRootRenameScoreAlert.swift`.

In `LibraryViewModel.swift`, delete the `rename(_:to:)` method:

```swift
func rename(_ scoreItem: ScoreItem, to newTitle: String) async {
    let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != scoreItem.title else { return }
    var updated = scoreItem
    updated.title = trimmed
    await save(updated)
}
```

Search the Library sources + tests for any remaining references to `rename(`, `pendingRename`, `renameText`, `renameScoreText`, `libraryRootRenameScoreAlert`, `library.score.rename` and resolve each (delete stale rename tests; the rename xcstrings keys may be left in place — they are harmless — or removed if no longer referenced).

- [ ] **Step 6: Build the package and run tests**

Run (from `Packages/Features/Library`):
`xcodebuild test -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED, all tests PASS. Fix any leftover `onRename` / rename references the compiler flags.

- [ ] **Step 7: Build the full app**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add -A Packages/Features/Library App
git commit -m "feat(library): replace rename alert with Edit Info sheet"
```

---

## Task 10: Manual smoke verification (simulator)

**Files:** none (verification only)

- [ ] **Step 1: Build, install, launch on the iPhone 17 simulator**

Build the app (Task 9 Step 7 command), then install + launch via `xcrun simctl` (or run from Xcode). Hand control to the user to verify the flow — do not drive gestures programmatically.

- [ ] **Step 2: Verify (user-driven checklist)**

Ask the user to confirm:
- The `…` row menu shows **"Edit Info"** (情報を編集) with a pencil-and-square icon, and no separate "Rename".
- Opening it shows the editable section (Title/Subtitle/Composer/Arranger/Lyricist/Copyright) and an Information section (Source, Date Added).
- For an existing MuseScore item: Source reads e.g. "MuseScore 4"/"MuseScore 3"; never-edited Arranger/Lyricist/Copyright pre-fill from the file if present.
- Editing a field + Save persists (reopen shows the saved value); clearing a field + Save leaves it empty on reopen (no re-fill).
- Blank title disables Save.
- Date Added label reads 追加日時 in Japanese.

- [ ] **Step 3: No commit** (verification only). If issues surface, loop back to the relevant task.

---

## Self-Review notes (for the executor)

- **Spec coverage:** editable fields (Task 1/8), read-only source + date added (Task 6/8), GRDB v10 (Task 4), on-demand parse for source + legacy pre-fill (Task 6/8), NULL-vs-"" semantics (Task 7 `saveMetadata` + Task 8 pre-fill init + tests), import snapshot of new metaTags (Task 5), file never rewritten (no save-to-file code anywhere), localization incl. 追加日時 (Task 8), rename action replaced (Task 9). All covered.
- **Type consistency:** `EditableScoreInfo` (memberwise init order: title, subtitle, composer, arranger, lyricist, copyright) is used identically in Task 7 tests, Task 8 init, and the sheet. `ScoreFileMetadata.init(source:composer:arranger:lyricist:copyright:)` and `ScoreSourceKind.museScore(majorVersion:)` are consistent across Tasks 3/6/7/8. `LiveScoreMetadataReader.init(gateway:scoresDirectory:)` consistent across Task 6/7.
- **Known soft spots (read the file first):** Task 4 repository test scaffolding, Task 7 AppShellView guard-let shape, Task 8 `#Preview` support helper, Task 9 `ScoreListScreen` rename UI — each flagged inline with a "read first / mirror existing" note.

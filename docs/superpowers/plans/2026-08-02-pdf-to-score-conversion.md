# PDF → Score Conversion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the OMR result of an imported PDF the item's primary content — a real `.mscz` score — while keeping the original PDF viewable behind a reader toggle and re-readable on demand.

**Architecture:** A PDF is converted to `.mscz` inside `commitImport` (and lazily, on first reader open, for items imported before this change). The original PDF stays on disk as `<id>.pdf` and four new `ScoreItem` fields record the origin. The reader gains a display-source axis (`score` / `originalPDF`) that swaps `ReaderCapabilities` and the rendered container; everything else in the app sees an ordinary `.mscz` item.

**Tech Stack:** Swift 6.3, SwiftUI, GRDB (Persistence), PDFKit, `swift-sheet-music` (`SheetMusicPDF.PDFImporter` via `PDFPlaybackParser`), Swift Testing.

## Global Constraints

- iOS-only this iteration. Every decision rule (`PDFOriginState`, `PDFReparsePolicy`, `ReaderCapabilities.resolve`) lands in **Domain** as a pure function so the Android follow-up reuses it instead of reimplementing. Do **not** touch `Android/` or the `Folino*JNI` targets.
- Module boundaries hold: Domain is Foundation-only, Features never import `swift-sheet-music` or Infrastructure, Infrastructure never imports Features.
- New tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`).
- User-facing brand is lowercase `folino`; user-facing strings never use internal feature names ("Reader", "Editor").
- Localized strings live in `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings`, keyed `reader.<feature>.<thing>`. Add the key with its English + Japanese value; the remaining locales (ko, zh-Hans, zh-Hant) may stay untranslated and will be filled at release time.
- Comment paragraphs reflow at 120 columns.
- Build/test destination is always `platform=iOS Simulator,name=iPhone 17 Pro Max` with `-skipPackagePluginValidation`. `swift test` does not work in this repo.
- Package test scheme names: `Domain`, `Infrastructure-Package`, `Reader`.
- Never use `git add -p` / hunk staging (the pre-commit hook rewrites files).

---

## File Structure

**Domain (`Packages/Domain/Sources/Domain/`)**
- `Models/ScoreItem.swift` — modify: four new PDF-origin fields.
- `Models/PDFOriginState.swift` — create: the three-state derivation.
- `Models/ReaderDisplaySource.swift` — create: `score` / `originalPDF`.
- `Models/ReaderCapabilities.swift` — modify: `resolve(format:displaySource:)`.
- `Models/PDFReparsePolicy.swift` — create: confirmation rule.
- `Models/ReaderPreferences.swift` — modify: `hasStaffBoundOverrides` + `clearingStaffBoundOverrides()`.

**Infrastructure**
- `Sources/Persistence/Database/Migrations.swift` — modify: `v15`.
- `Sources/Persistence/Records/ScoreItemRecord.swift` — modify: four columns.
- `Sources/Persistence/LiveScoreLibraryRepository.swift` — modify: duplicate query.
- `Sources/ScoreFiles/PDFScoreConverter.swift` — create: parse → write `.mscz` → summarize.
- `Sources/Persistence/LiveScoreFileImporter.swift` — modify: PDF branch in `commitImport`.

**Reader feature (`Packages/Features/Reader/Sources/Reader/`)**
- `ReaderViewModel.swift` — modify: `displaySource`, computed `capabilities`, `originalPDFDocument`, `isConversionInProgress`.
- `ReaderViewModel+Load.swift` — modify: lazy conversion, display-source-aware load.
- `ReaderViewModel+PDFConversion.swift` — create: conversion + re-read flows.
- `Screens/ScoreContentView.swift` — modify: branch on display source.
- `Screens/ReaderTopOverlay.swift` — modify: source toggle + re-read menu item.
- `Screens/PDF/PDFSourceNotice.swift` — create (replaces `PDFPlaybackNotice.swift`).

**App**
- `App/AppBootstrap.swift` (or wherever the importer is built) — modify: inject the parser into the importer.

---

### Task 1: Domain — PDF-origin fields and state

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ScoreItem.swift`
- Create: `Packages/Domain/Sources/Domain/Models/PDFOriginState.swift`
- Test: `Packages/Domain/Tests/DomainTests/Models/PDFOriginStateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ScoreItem.sourcePDFFileName: String?`, `.sourcePDFContentHash: String?`, `.pdfDerivedContentHash: String?`, `.pdfConversionFailed: Bool`, all with `init` defaults (`nil`, `nil`, `nil`, `false`) placed **after** `museScoreMajorVersion`; `enum PDFOriginState { case notPDF, unconverted, converted }`; `ScoreItem.pdfOriginState: PDFOriginState`.

- [ ] **Step 1: Write the failing test**

```swift
import Domain
import Foundation
import Testing

@Suite("PDFOriginState")
struct PDFOriginStateTests {
    private func item(
        localFileName: String,
        sourcePDFFileName: String? = nil,
        pdfDerivedContentHash: String? = nil,
    ) -> ScoreItem {
        ScoreItem(
            id: ScoreItemID(),
            title: "t",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: localFileName,
            contentHash: "hash",
            sizeBytes: 1,
            lengthBeats: 0,
            defaultTempoBpm: 0,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
            sourcePDFFileName: sourcePDFFileName,
            pdfDerivedContentHash: pdfDerivedContentHash,
        )
    }

    @Test("An item with no PDF origin is notPDF")
    func plainScore() {
        #expect(item(localFileName: "a.mscz").pdfOriginState == .notPDF)
    }

    @Test("A PDF-origin item still stored as a PDF is unconverted")
    func stillPDF() {
        let subject = item(localFileName: "a.pdf", sourcePDFFileName: "a.pdf")
        #expect(subject.pdfOriginState == .unconverted)
    }

    @Test("A PDF-origin item with a derived hash and a score file is converted")
    func converted() {
        let subject = item(
            localFileName: "a.mscz",
            sourcePDFFileName: "a.pdf",
            pdfDerivedContentHash: "derived",
        )
        #expect(subject.pdfOriginState == .converted)
    }

    @Test("A derived hash without a score file is still unconverted")
    func derivedHashButStillPDF() {
        let subject = item(
            localFileName: "a.pdf",
            sourcePDFFileName: "a.pdf",
            pdfDerivedContentHash: "derived",
        )
        #expect(subject.pdfOriginState == .unconverted)
    }

    @Test("Defaults keep every pre-existing construction site on notPDF")
    func defaults() {
        let subject = item(localFileName: "a.mscz")
        #expect(subject.sourcePDFFileName == nil)
        #expect(subject.sourcePDFContentHash == nil)
        #expect(subject.pdfDerivedContentHash == nil)
        #expect(subject.pdfConversionFailed == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run from `Packages/Domain`:
`xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Domain/PDFOriginStateTests`
Expected: compile failure — `sourcePDFFileName` is not an argument of `ScoreItem.init`.

- [ ] **Step 3: Add the fields to `ScoreItem`**

Add the stored properties after `museScoreMajorVersion`, and the matching `init` parameters (defaulted, in the same order, at the end of the parameter list so existing call sites are unaffected):

```swift
/// The original PDF this item was read from, as `<id>.pdf` in the scores directory. Non-nil for every PDF-origin
/// item — both one still displayed as a PDF and one converted to notation.
public var sourcePDFFileName: String?
/// SHA-256 of the original PDF's bytes. Duplicate detection matches this as well as `contentHash`, so re-importing
/// the same PDF is still recognized after the item's own bytes became an `.mscz`.
public var sourcePDFContentHash: String?
/// `contentHash` of the `.mscz` exactly as the conversion wrote it. `contentHash` drifting away from this value is
/// the definition of "the user edited the score".
public var pdfDerivedContentHash: String?
/// The last conversion attempt failed, or produced nothing playable. Keeps the reader from re-running an expensive
/// OMR pass on every open; an explicit re-read clears it.
public var pdfConversionFailed: Bool
```

- [ ] **Step 4: Create `PDFOriginState.swift`**

```swift
import Foundation

/// Where an item's notation came from, and how far the PDF → score conversion got. Derived, never stored — the fields
/// on `ScoreItem` are the state; this is the one place that reads them. iOS and (later) Android both branch on this so
/// the two platforms cannot disagree about what a PDF-origin item is.
public enum PDFOriginState: Hashable, Sendable {
    /// Never came from a PDF.
    case notPDF
    /// Came from a PDF and is still displayed as one: the conversion hasn't run yet, or it failed.
    case unconverted
    /// Came from a PDF and is now a real score. The original stays on disk as a sidecar.
    case converted
}

public extension ScoreItem {
    var pdfOriginState: PDFOriginState {
        guard sourcePDFFileName != nil else { return .notPDF }
        let isStillPDF = ScoreFormat.detect(filename: localFileName) == .pdf
        return (!isStillPDF && pdfDerivedContentHash != nil) ? .converted : .unconverted
    }

    /// True when the user has edited the notation since the conversion wrote it.
    var isPDFDerivedScoreEdited: Bool {
        guard let derived = pdfDerivedContentHash else { return false }
        return derived != contentHash
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Same command as Step 2. Expected: PASS.

- [ ] **Step 6: Build every dependent package to catch broken call sites**

Run from the repo root:
`xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED (the defaults mean no call site changes).

- [ ] **Step 7: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/ScoreItem.swift Packages/Domain/Sources/Domain/Models/PDFOriginState.swift Packages/Domain/Tests/DomainTests/Models/PDFOriginStateTests.swift
git commit -m "feat(domain): record where a score item's PDF came from"
```

---

### Task 2: Domain — display source, capabilities, re-read policy

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/ReaderDisplaySource.swift`
- Create: `Packages/Domain/Sources/Domain/Models/PDFReparsePolicy.swift`
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderCapabilities.swift`
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift`
- Test: `Packages/Domain/Tests/DomainTests/Models/PDFReparsePolicyTests.swift`, `Packages/Domain/Tests/DomainTests/ReaderCapabilitiesTests.swift` (extend)

**Interfaces:**
- Consumes: Task 1's `PDFOriginState`.
- Produces: `enum ReaderDisplaySource { case score, originalPDF }`;
  `ReaderCapabilities.resolve(format: ScoreFormat?, displaySource: ReaderDisplaySource) -> ReaderCapabilities`;
  `PDFReparsePolicy.needsConfirmation(isScoreEdited: Bool, hasStaffBoundPreferences: Bool, hasMusicalAnnotations: Bool) -> Bool`;
  `ReaderPreferences.hasStaffBoundOverrides: Bool`; `ReaderPreferences.clearingStaffBoundOverrides() -> ReaderPreferences`.

- [ ] **Step 1: Write the failing tests**

Create `PDFReparsePolicyTests.swift`:

```swift
import Domain
import Testing

@Suite("PDFReparsePolicy")
struct PDFReparsePolicyTests {
    @Test("Nothing to lose needs no confirmation")
    func clean() {
        #expect(!PDFReparsePolicy.needsConfirmation(
            isScoreEdited: false, hasStaffBoundPreferences: false, hasMusicalAnnotations: false,
        ))
    }

    @Test("Any one kind of user work triggers confirmation", arguments: [
        (true, false, false), (false, true, false), (false, false, true),
    ])
    func dirty(edited: Bool, prefs: Bool, ink: Bool) {
        #expect(PDFReparsePolicy.needsConfirmation(
            isScoreEdited: edited, hasStaffBoundPreferences: prefs, hasMusicalAnnotations: ink,
        ))
    }
}
```

Append to `ReaderCapabilitiesTests.swift`:

```swift
@Test("Showing the original PDF disables every engraving-derived setting")
func originalPDFSourceIsPDFCapable() {
    let caps = ReaderCapabilities.resolve(format: .mscz, displaySource: .originalPDF)
    #expect(caps == .forPDF)
}

@Test("Showing the score keeps full score capabilities")
func scoreSourceIsScoreCapable() {
    let caps = ReaderCapabilities.resolve(format: .mscz, displaySource: .score)
    #expect(caps == .forScore)
}

@Test("A still-unconverted PDF is PDF-capable on either axis")
func pdfFormatIsAlwaysPDFCapable() {
    #expect(ReaderCapabilities.resolve(format: .pdf, displaySource: .score) == .forPDF)
}
```

Append to `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesTests.swift`:

```swift
@Test("Staff-bound overrides are detected and cleared, leaving sound-only settings alone")
func staffBoundOverrides() {
    let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    let prefs = ReaderPreferences(
        scoreItemID: ScoreItemID(),
        staffSize: 14,
        hiddenStaves: [address],
        staffClefOverrides: [address: "F"],
        tempoMultiplier: 1.5,
        transposeSemitones: 3,
        masterVolume: 2.0,
    )
    #expect(prefs.hasStaffBoundOverrides)
    let cleared = prefs.clearingStaffBoundOverrides()
    #expect(!cleared.hasStaffBoundOverrides)
    #expect(cleared.hiddenStaves.isEmpty)
    #expect(cleared.staffClefOverrides.isEmpty)
    #expect(cleared.transposeSemitones == 0)
    #expect(cleared.tempoMultiplier == 1.5)
    #expect(cleared.masterVolume == 2.0)
}
```

- [ ] **Step 2: Run to verify failure**

From `Packages/Domain`:
`xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`
Expected: compile failure — `ReaderDisplaySource` / `PDFReparsePolicy` / `hasStaffBoundOverrides` undefined.

- [ ] **Step 3: Create `ReaderDisplaySource.swift`**

```swift
import Foundation

/// Which rendition of a PDF-derived item the reader is showing. Orthogonal to `ReaderLayoutMode`: each source carries
/// its own set of allowed layout modes, which is why this is a separate axis and not a fourth layout mode.
public enum ReaderDisplaySource: String, Hashable, Sendable, Codable {
    /// The engraved notation — the default, and the only option for an item that never came from a PDF.
    case score
    /// The original PDF's pages, fixed-layout, exactly as the file was imported.
    case originalPDF
}
```

- [ ] **Step 4: Extend `ReaderCapabilities`**

Keep `resolve(format:)` as-is (call sites and Android depend on it) and add the two-axis overload:

```swift
/// Capabilities for a reader session, given what it is currently showing. A fixed-layout PDF page can't be
/// re-engraved, so showing the original disables every layout-derivation setting even when the item itself is a
/// perfectly ordinary score. Settings that only affect sound (tempo, A4, mixer, master volume) are not on this axis
/// and stay available.
public static func resolve(format: ScoreFormat?, displaySource: ReaderDisplaySource) -> ReaderCapabilities {
    displaySource == .originalPDF ? .forPDF : resolve(format: format)
}
```

- [ ] **Step 5: Create `PDFReparsePolicy.swift`**

```swift
import Foundation

/// Whether re-reading the original PDF would throw away work the user did on top of the previous read. One rule,
/// applied by every platform, so a destructive action is never silent on one and guarded on the other.
public enum PDFReparsePolicy {
    /// - Parameters:
    ///   - isScoreEdited: the notation differs from what the conversion wrote (`ScoreItem.isPDFDerivedScoreEdited`).
    ///   - hasStaffBoundPreferences: any staff-index-addressed setting is set — clef override, hidden staff, program
    ///     or volume override, or a non-zero transpose. A better read can renumber staves, which invalidates all of
    ///     them.
    ///   - hasMusicalAnnotations: at least one stroke is anchored to the notation (page-anchored ink on the original
    ///     is unaffected by a re-read and does not count).
    public static func needsConfirmation(
        isScoreEdited: Bool,
        hasStaffBoundPreferences: Bool,
        hasMusicalAnnotations: Bool,
    ) -> Bool {
        isScoreEdited || hasStaffBoundPreferences || hasMusicalAnnotations
    }
}
```

- [ ] **Step 6: Extend `ReaderPreferences`**

Add to the existing type (below the initializers):

```swift
/// Whether any setting addressed by staff index is set. These are exactly the settings a re-read invalidates.
var hasStaffBoundOverrides: Bool {
    !hiddenStaves.isEmpty
        || !staffProgramOverrides.isEmpty
        || !staffVolumeOverrides.isEmpty
        || !staffClefOverrides.isEmpty
        || transposeSemitones != 0
}

/// A copy with every staff-index-addressed setting reset. Sound-only settings (tempo, A4, master volume, repeat) and
/// `staffSize` survive — they don't reference staves by index.
func clearingStaffBoundOverrides() -> ReaderPreferences {
    var copy = self
    copy.hiddenStaves = []
    copy.staffProgramOverrides = [:]
    copy.staffVolumeOverrides = [:]
    copy.staffClefOverrides = [:]
    copy.transposeSemitones = 0
    copy.hasSeededAuthoredVisibility = false
    return copy
}
```

Mark both `public`.

- [ ] **Step 7: Run the tests to verify they pass**

Same command as Step 2. Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Packages/Domain
git commit -m "feat(domain): add the reader display-source axis and the re-read policy"
```

---

### Task 3: Persistence — migration v15 and duplicate detection

**Files:**
- Modify: `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift`
- Modify: `Packages/Infrastructure/Sources/Persistence/Records/ScoreItemRecord.swift`
- Modify: `Packages/Infrastructure/Sources/Persistence/LiveScoreLibraryRepository.swift:345`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreLibraryRepositoryTests.swift` (extend)

**Interfaces:**
- Consumes: Task 1's `ScoreItem` fields.
- Produces: `score_items` columns `source_pdf_file_name`, `source_pdf_content_hash`, `pdf_derived_content_hash`, `pdf_conversion_failed`; `scoreItems(matchingContentHash:)` also matches `source_pdf_content_hash`.

- [ ] **Step 1: Write the failing test**

Append to `LiveScoreLibraryRepositoryTests.swift`:

```swift
@Test("PDF-origin fields round-trip through the database")
func pdfOriginFieldsRoundTrip() async throws {
    let repo = try await makeRepository()
    var item = sampleItem(hash: "mscz-hash")
    item.localFileName = "\(item.id.rawValue.uuidString).mscz"
    item.sourcePDFFileName = "\(item.id.rawValue.uuidString).pdf"
    item.sourcePDFContentHash = "pdf-hash"
    item.pdfDerivedContentHash = "mscz-hash"
    item.pdfConversionFailed = false
    try await repo.saveScoreItem(item)

    let reloaded = try #require(repo.scoreItems.first { $0.id == item.id })
    #expect(reloaded.sourcePDFFileName == item.sourcePDFFileName)
    #expect(reloaded.sourcePDFContentHash == "pdf-hash")
    #expect(reloaded.pdfDerivedContentHash == "mscz-hash")
    #expect(reloaded.pdfOriginState == .converted)
}

@Test("Re-importing the same PDF is a duplicate even after conversion")
func duplicateMatchesOriginalPDFHash() async throws {
    let repo = try await makeRepository()
    var item = sampleItem(hash: "mscz-hash")
    item.localFileName = "\(item.id.rawValue.uuidString).mscz"
    item.sourcePDFFileName = "\(item.id.rawValue.uuidString).pdf"
    item.sourcePDFContentHash = "pdf-hash"
    item.pdfDerivedContentHash = "mscz-hash"
    try await repo.saveScoreItem(item)

    let matches = try await repo.scoreItems(matchingContentHash: "pdf-hash")
    #expect(matches.map(\.id) == [item.id])
}
```

(Use the file's existing `makeRepository()` / `sampleItem(hash:)` helpers; if `sampleItem` returns a `let`-only value, copy it into a `var` first as above.)

- [ ] **Step 2: Run to verify failure**

From `Packages/Infrastructure`:
`xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/LiveScoreLibraryRepositoryTests`
Expected: FAIL — the reloaded item's new fields are `nil` (the record drops them) and the duplicate query returns `[]`.

- [ ] **Step 3: Register migration v15**

In `Migrations.swift`, add `m.registerMigration("v15", migrate: migrateV15)` after the `v14` line, and at the end of the type:

```swift
// MARK: - v15

/// Records where an item's notation came from when it was read out of a PDF: the original PDF sidecar's file name and
/// hash, the hash of the `.mscz` the conversion produced (drift from `content_hash` means the user edited it), and a
/// sticky "we tried and it wasn't readable" flag that keeps the reader from re-running OMR on every open. All NULL /
/// 0 for existing rows, which is exactly `PDFOriginState.notPDF` — PDF rows back-fill on their next open.
private static func migrateV15(_ db: Database) throws {
    try db.execute(sql: "ALTER TABLE score_items ADD COLUMN source_pdf_file_name TEXT")
    try db.execute(sql: "ALTER TABLE score_items ADD COLUMN source_pdf_content_hash TEXT")
    try db.execute(sql: "ALTER TABLE score_items ADD COLUMN pdf_derived_content_hash TEXT")
    try db.execute(sql: """
    ALTER TABLE score_items
    ADD COLUMN pdf_conversion_failed INTEGER NOT NULL DEFAULT 0
    """)
}
```

- [ ] **Step 4: Extend `ScoreItemRecord`**

Add the four properties, their `CodingKeys` (`source_pdf_file_name`, `source_pdf_content_hash`, `pdf_derived_content_hash`, `pdf_conversion_failed`), the assignments in `init(domain:)`, and the arguments in `toDomain(tagIDs:)`.

- [ ] **Step 5: Widen the duplicate query**

In `LiveScoreLibraryRepository.scoreItems(matchingContentHash:)` replace the filter:

```swift
// The original PDF's hash counts too: once a PDF is converted, the row's own `content_hash` is the `.mscz`'s, so
// matching only that would let the same PDF be imported twice.
let records = try ScoreItemRecord
    .filter(
        (Column("content_hash") == contentHash || Column("source_pdf_content_hash") == contentHash)
            && Column("deleted_at") == nil,
    )
    .fetchAll(db)
```

- [ ] **Step 6: Run the tests to verify they pass**

Same command as Step 2, then the whole suite:
`xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Packages/Infrastructure
git commit -m "feat(persistence): persist a score item's PDF origin (migration v15)"
```

---

### Task 4: Infrastructure — `PDFScoreConverter`

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/PDFConversionFacts.swift`
- Create: `Packages/Infrastructure/Sources/ScoreFiles/PDFScoreConverter.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/PDFScoreConverterTests.swift`

**Interfaces:**
- Consumes: `PDFPlaybackParser` (Domain protocol), `ScoreFileGateway.saveScore` / `.loadFileMetadata`, `Score.hasPlayableContent`.
- Produces:

```swift
// Domain — so the Reader feature can speak it without importing Infrastructure (Task 6).
public struct PDFConversionFacts: Sendable {
    public let fileName: String
    public let contentHash: String
    public let sizeBytes: Int64
    public let summary: ScoreFileSummary
    public init(fileName: String, contentHash: String, sizeBytes: Int64, summary: ScoreFileSummary)
}

// Infrastructure.
public enum PDFConversionOutcome: Sendable {
    case converted(PDFConversionFacts)
    case notReadable

    public var facts: PDFConversionFacts? { … }
}

public struct PDFScoreConverter: Sendable {
    public init(parser: any PDFPlaybackParser, gateway: any ScoreFileGateway)
    public func convert(pdfURL: URL, destinationMSCZ: URL) async -> PDFConversionOutcome
}
```

- [ ] **Step 1: Write the failing test**

```swift
import Domain
import Foundation
@testable import ScoreFiles
import SheetMusicCore
import Testing

private struct StubParser: PDFPlaybackParser {
    let result: Result<PDFPlaybackParseResult, any Error>
    func parse(pdfURL _: URL) async throws -> PDFPlaybackParseResult { try result.get() }
}

@Suite("PDFScoreConverter")
struct PDFScoreConverterTests {
    @Test("A playable parse writes the mscz and reports its facts")
    func writesMSCZ() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pdfURL = tmp.appending(path: "source.pdf")
        try Data().write(to: pdfURL)
        let destination = tmp.appending(path: "out.mscz")

        let converter = PDFScoreConverter(
            parser: StubParser(result: .success(playableParseResult())),
            gateway: LiveScoreFileGateway(),
        )
        let outcome = await converter.convert(pdfURL: pdfURL, destinationMSCZ: destination)

        guard case let .converted(facts) = outcome else {
            Issue.record("expected .converted, got \(outcome)")
            return
        }
        #expect(facts.fileName == "out.mscz")
        #expect(!facts.contentHash.isEmpty)
        #expect(facts.sizeBytes > 0)
        #expect(facts.summary.lengthBeats > 0)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("A parse that throws is not readable and writes nothing")
    func parseFailure() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let destination = tmp.appending(path: "out.mscz")

        let converter = PDFScoreConverter(
            parser: StubParser(result: .failure(DomainError.scoreParseFailed(reason: "nope"))),
            gateway: LiveScoreFileGateway(),
        )
        let outcome = await converter.convert(
            pdfURL: tmp.appending(path: "source.pdf"),
            destinationMSCZ: destination,
        )

        #expect(outcome.isNotReadable)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("A parse with no playable content is not readable")
    func silentParse() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let destination = tmp.appending(path: "out.mscz")

        let converter = PDFScoreConverter(
            parser: StubParser(result: .success(emptyParseResult())),
            gateway: LiveScoreFileGateway(),
        )
        let outcome = await converter.convert(
            pdfURL: tmp.appending(path: "source.pdf"),
            destinationMSCZ: destination,
        )

        #expect(outcome.isNotReadable)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

private extension PDFConversionOutcome {
    var isNotReadable: Bool { if case .notReadable = self { return true } else { return false } }
}
```

Build `playableParseResult()` and `emptyParseResult()` as file-private helpers returning
`PDFPlaybackParseResult(score:geometry:diagnostics:)`. For the score, reuse the fixture style already in
`Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/` — read `SheetMusicPDFPlaybackGeometryTests.swift`
first and copy its score/geometry construction rather than inventing one. `playableParseResult()` must contain at
least one chord with a note (so `hasPlayableContent` is true); `emptyParseResult()` must contain none.

- [ ] **Step 2: Run to verify failure**

From `Packages/Infrastructure`:
`xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/PDFScoreConverterTests`
Expected: compile failure — `PDFScoreConverter` undefined.

- [ ] **Step 3: Implement the converter**

```swift
import CryptoKit
import Domain
import Foundation

/// The result of reading a PDF into notation.
public enum PDFConversionOutcome: Sendable {
    /// The PDF was read and the score was written. Everything the caller needs to update the library row.
    case converted(PDFConversionFacts)
    /// The parse threw, or it succeeded but decoded nothing playable (e.g. an OMR pass over a raster "print to PDF"
    /// that finds staff lines but no noteheads). The caller keeps displaying the PDF.
    case notReadable

    public var facts: PDFConversionFacts? {
        if case let .converted(facts) = self { return facts }
        return nil
    }
}

/// Reads a PDF into a `Score` and writes it as `.mscz`. The single implementation of "convert a PDF", shared by
/// import, the reader's lazy migration of an older PDF item, and the explicit re-read — so the three can't drift.
///
/// The written file is re-read through `loadFileMetadata` rather than deriving a summary from the parsed `Score`, so a
/// converted item's metadata comes from exactly the same code path as a natively imported `.mscz`.
public struct PDFScoreConverter: Sendable {
    private let parser: any PDFPlaybackParser
    private let gateway: any ScoreFileGateway

    public init(parser: any PDFPlaybackParser, gateway: any ScoreFileGateway) {
        self.parser = parser
        self.gateway = gateway
    }

    public func convert(pdfURL: URL, destinationMSCZ: URL) async -> PDFConversionOutcome {
        do {
            let result = try await parser.parse(pdfURL: pdfURL)
            guard result.score.hasPlayableContent else { return .notReadable }
            try await gateway.saveScore(result.score, fileURL: destinationMSCZ, format: .mscz)
            let summary = try await gateway.loadFileMetadata(fileURL: destinationMSCZ)
            let (hash, size) = try Self.hashAndSize(destinationMSCZ)
            return .converted(PDFConversionFacts(
                fileName: destinationMSCZ.lastPathComponent,
                contentHash: hash,
                sizeBytes: size,
                summary: summary,
            ))
        } catch {
            // Any failure leaves the PDF exactly as it was — including a half-written destination.
            try? FileManager.default.removeItem(at: destinationMSCZ)
            return .notReadable
        }
    }

    private static func hashAndSize(_ url: URL) throws -> (String, Int64) {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/ScoreFiles/PDFScoreConverter.swift Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/PDFScoreConverterTests.swift
git commit -m "feat(scorefiles): add the PDF to mscz converter"
```

---

### Task 5: Import — convert on commit

**Files:**
- Modify: `Packages/Infrastructure/Sources/Persistence/LiveScoreFileImporter.swift:64-133`
- Modify: `App/AppBootstrap.swift` (importer construction)
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/PDFImportTests.swift` (extend)

**Interfaces:**
- Consumes: Task 4's `PDFScoreConverter`, Task 1's `ScoreItem` fields.
- Produces: `LiveScoreFileImporter.init(gateway:repository:scoresDirectory:pdfConverter:)` — a new **optional** trailing parameter `pdfConverter: PDFScoreConverter? = nil`. With `nil`, a PDF import behaves exactly as it does today.

- [ ] **Step 1: Write the failing tests**

Append to `PDFImportTests.swift` (reuse the file's existing fixture PDF and fake repository; read it first):

```swift
@Test("Importing a readable PDF stores the converted score and keeps the original")
func convertsOnImport() async throws {
    let env = try makeEnvironment(pdfConverter: converterStub(.converted))
    let plan = try await env.importer.prepareImport(sourceURL: env.fixturePDFURL)
    let item = try await env.importer.commitImport(plan, decision: .importAsNew)

    #expect(item.localFileName.hasSuffix(".mscz"))
    #expect(item.sourcePDFFileName == "\(item.id.rawValue.uuidString).pdf")
    #expect(item.sourcePDFContentHash == plan.contentHash)
    #expect(item.pdfDerivedContentHash == item.contentHash)
    #expect(!item.pdfConversionFailed)
    #expect(item.pdfOriginState == .converted)
    #expect(FileManager.default.fileExists(
        atPath: env.scoresDirectory.appending(path: item.sourcePDFFileName!).path,
    ))
    #expect(FileManager.default.fileExists(
        atPath: env.scoresDirectory.appending(path: item.localFileName).path,
    ))
}

@Test("An unreadable PDF imports as a PDF item and remembers the failure")
func fallsBackWhenNotReadable() async throws {
    let env = try makeEnvironment(pdfConverter: converterStub(.notReadable))
    let plan = try await env.importer.prepareImport(sourceURL: env.fixturePDFURL)
    let item = try await env.importer.commitImport(plan, decision: .importAsNew)

    #expect(item.localFileName.hasSuffix(".pdf"))
    #expect(item.contentHash == plan.contentHash)
    #expect(item.pdfConversionFailed)
    #expect(item.pdfOriginState == .unconverted)
}

@Test("The title still comes from the file name, not the parsed notation")
func titleComesFromFilename() async throws {
    let env = try makeEnvironment(pdfConverter: converterStub(.converted))
    let plan = try await env.importer.prepareImport(sourceURL: env.fixturePDFURL)
    let item = try await env.importer.commitImport(plan, decision: .importAsNew)
    #expect(item.title == ScorePresentation.title(fromFilename: env.fixturePDFURL.lastPathComponent))
}
```

`converterStub(_:)` returns a `PDFScoreConverter` built from a stub parser that yields a playable or empty parse
(same helpers as Task 4). `makeEnvironment(pdfConverter:)` wires the importer with a temp scores directory.

- [ ] **Step 2: Run to verify failure**

From `Packages/Infrastructure`:
`xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/PDFImportTests`
Expected: compile failure — `init` has no `pdfConverter` parameter.

- [ ] **Step 3: Add the converter to the importer and branch in `commitImport`**

Store `private let pdfConverter: PDFScoreConverter?` and accept it in `init` (defaulted `nil`, last parameter).

In `commitImport`'s `.importAsNew` case, after the staged file has been moved to `destinationURL` and before the
`ScoreItem` is built, insert:

```swift
// A PDF is read into notation right here, so the row that lands in the library is a normal score row: correct
// length, tempo, parts, thumbnail, and an editable file. The original PDF stays next to it — the reader's
// original-PDF view and the re-read action both need it. An unreadable PDF simply stays a PDF item.
var localFileName = localFileName
var contentHash = plan.contentHash
var sizeBytes = plan.sizeBytes
var summary = plan.summary
var sourcePDFFileName: String?
var sourcePDFContentHash: String?
var pdfDerivedContentHash: String?
var pdfConversionFailed = false

if plan.format == .pdf {
    sourcePDFFileName = localFileName
    sourcePDFContentHash = plan.contentHash
    let msczName = "\(id.rawValue.uuidString).\(ScoreFormat.mscz.canonicalExtension)"
    let outcome = await pdfConverter?.convert(
        pdfURL: destinationURL,
        destinationMSCZ: scoresDirectory.appending(path: msczName),
    ) ?? .notReadable
    if let facts = outcome.facts {
        localFileName = facts.fileName
        contentHash = facts.contentHash
        sizeBytes = facts.sizeBytes
        summary = facts.summary
        pdfDerivedContentHash = facts.contentHash
    } else {
        pdfConversionFailed = true
    }
}
```

Then build the `ScoreItem` from those locals instead of `plan.*` — note `title` keeps using
`ScorePresentation.title(fromFilename: plan.sourceURL.lastPathComponent)` — and pass the four new fields.

Adjust the cleanup `defer`: on failure it must remove the converted `.mscz` as well as `destinationURL`. Capture
both URLs in a local array and remove each.

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2, then the full Infrastructure suite. Expected: PASS.

- [ ] **Step 5: Inject the converter at the composition root**

In `App/`, find where `LiveScoreFileImporter(...)` is constructed (grep `LiveScoreFileImporter(`) and pass
`pdfConverter: PDFScoreConverter(parser: LivePDFPlaybackParser(), gateway: gateway)`, reusing the same gateway
instance the importer already receives.

- [ ] **Step 6: Build the app**

`xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Packages/Infrastructure App
git commit -m "feat(import): read an imported PDF into notation at commit time"
```

---

### Task 6: Reader — lazy conversion of PDF items on open

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/ReaderViewModel+PDFConversion.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`, `ReaderViewModel+Load.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPDFConversionTests.swift`

**Interfaces:**
- Consumes: `PDFOriginState`, `ScoreFileGateway`, `PDFPlaybackParser`.
- Produces: `ReaderViewModel.isConvertingPDF: Bool`;
  `ReaderViewModel.convertPDFIfNeeded(url: URL) async -> URL?` — returns the URL of the score file to load when the
  conversion produced one, `nil` when the item stays a PDF. The Reader owns a `PDFScoreConversion` closure injected at
  `init` so the feature never imports Infrastructure:

```swift
/// Injected by the App: reads the PDF at `pdfURL` and writes `<id>.mscz`, answering the facts the reader needs to
/// update the row. `nil` on builds without ssm's PDF importer. Domain-only types, so the Reader stays independent of
/// Infrastructure.
typealias PDFScoreConversion = @Sendable (_ pdfURL: URL, _ destinationMSCZ: URL) async -> PDFConversionFacts?
```

`PDFConversionFacts` is the Domain type from Task 4. The App builds this closure as
`{ await converter.convert(pdfURL: $0, destinationMSCZ: $1).facts }`, which is the whole reason the outcome carries a
`facts` accessor — the Reader never sees `PDFConversionOutcome` or any Infrastructure type.

- [ ] **Step 1: Write the failing test**

```swift
import Domain
import Foundation
@testable import Reader
import Testing

@Suite("Reader PDF conversion on open")
@MainActor
struct ReaderViewModelPDFConversionTests {
    @Test("Opening an unconverted PDF converts it and loads the score")
    func convertsOnOpen() async throws {
        let env = try ReaderTestEnvironment.pdfItem(conversion: .succeeds)
        await env.viewModel.load()

        #expect(env.viewModel.scoreItem.pdfOriginState == .converted)
        #expect(env.viewModel.scoreItem.localFileName.hasSuffix(".mscz"))
        #expect(env.viewModel.loadState.score != nil)
        #expect(env.repository.savedItems.last?.pdfDerivedContentHash != nil)
    }

    @Test("A failed conversion falls back to the PDF and is not retried")
    func remembersFailure() async throws {
        let env = try ReaderTestEnvironment.pdfItem(conversion: .fails)
        await env.viewModel.load()

        #expect(env.viewModel.scoreItem.pdfConversionFailed)
        if case .loadedPDF = env.viewModel.loadState {} else { Issue.record("expected .loadedPDF") }

        env.conversionCallCount = 0
        await env.viewModel.load()
        #expect(env.conversionCallCount == 0)
    }

    @Test("An already-converted item never runs the conversion")
    func skipsConverted() async throws {
        let env = try ReaderTestEnvironment.convertedItem()
        await env.viewModel.load()
        #expect(env.conversionCallCount == 0)
    }
}
```

Build `ReaderTestEnvironment` on top of the fakes already in `Packages/Features/Reader/Tests/ReaderTests/` — read
`ReaderViewModelPDFLoadTests.swift` first and extend its fake gateway / repository rather than writing new ones.

- [ ] **Step 2: Run to verify failure**

From `Packages/Features/Reader`:
`xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/ReaderViewModelPDFConversionTests`
Expected: compile failure.

- [ ] **Step 3: Add the injection point and the state**

In `ReaderViewModel`, add `@ObservationIgnored let pdfConversion: PDFScoreConversion?` (defaulted `nil` in `init`,
placed next to `pdfPlaybackParser`) and `private(set) var isConvertingPDF = false`.

- [ ] **Step 4: Implement the conversion path**

Create `ReaderViewModel+PDFConversion.swift`:

```swift
import Domain
import Foundation

extension ReaderViewModel {
    /// Reads a PDF item into notation on the way to displaying it, so items imported before folino learned to convert
    /// catch up the first time they're opened. Returns the score file's URL when the conversion produced one, `nil`
    /// when the item stays a PDF.
    ///
    /// A failure is sticky (`pdfConversionFailed`): OMR is expensive and re-running it on every open of a PDF folino
    /// already knows it can't read would make those items feel broken. The re-read action clears the flag.
    func convertPDFIfNeeded(url: URL) async -> URL? {
        guard scoreItem.pdfOriginState == .unconverted,
              !scoreItem.pdfConversionFailed,
              let pdfConversion
        else { return nil }

        isConvertingPDF = true
        defer { isConvertingPDF = false }

        let msczName = "\(scoreItem.id.rawValue.uuidString).\(ScoreFormat.mscz.canonicalExtension)"
        let destination = scoresDirectory.appending(path: msczName)
        let facts = await pdfConversion(url, destination)

        var updated = scoreItem
        // Back-fill the sidecar name for rows that predate the PDF-origin columns.
        updated.sourcePDFFileName = scoreItem.sourcePDFFileName ?? scoreItem.localFileName
        updated.sourcePDFContentHash = scoreItem.sourcePDFContentHash ?? scoreItem.contentHash
        guard let facts else {
            updated.pdfConversionFailed = true
            await persist(updated)
            return nil
        }
        updated.localFileName = facts.fileName
        updated.contentHash = facts.contentHash
        updated.sizeBytes = facts.sizeBytes
        updated.lengthBeats = facts.summary.lengthBeats
        updated.defaultTempoBpm = facts.summary.defaultTempoBpm
        updated.primaryKey = facts.summary.primaryKey
        updated.instrumentationSummary = facts.summary.instrumentationSummary
        updated.pdfDerivedContentHash = facts.contentHash
        updated.pdfConversionFailed = false
        await persist(updated)
        return scoresDirectory.appending(path: facts.fileName)
    }

    private func persist(_ item: ScoreItem) async {
        scoreItem = item
        try? await repository.saveScoreItem(item)
    }
}
```

`ScoreItem.contentHash` is `let`; if the compiler rejects the assignment, rebuild the value with the memberwise
initializer exactly as `EditorViewModel.performSave` does (`Packages/Features/Editor/Sources/Editor/EditorViewModel+Persistence.swift:34`)
and add a small `private func rebuilt(_:contentHash:...)` helper rather than repeating the initializer twice.

Make `scoresDirectory` internal (drop `private`) so this extension can reach it.

- [ ] **Step 5: Call it from `load()`**

In `ReaderViewModel.load()`, replace the PDF branch:

```swift
if format == .pdf {
    if let scoreURL = await convertPDFIfNeeded(url: url) {
        capabilities = ReaderCapabilities.resolve(format: .mscz, displaySource: displaySource)
        await loadScoreFile(url: scoreURL)
    } else {
        await loadPDF(url: url)
    }
} else {
    await loadScoreFile(url: url)
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Same command as Step 2, then the whole `Reader` suite. Expected: PASS.

- [ ] **Step 7: Wire the closure at the composition root**

`ReaderRootScreen.init` gains a `pdfConversion: PDFScoreConversion? = nil` parameter, threaded straight into
`ReaderViewModel`. In `App/` (grep `ReaderRootScreen(` — `AppShellView.swift` and any iPad detail-pane call site),
pass:

```swift
pdfConversion: { pdfURL, destination in
    await pdfScoreConverter.convert(pdfURL: pdfURL, destinationMSCZ: destination).facts
},
```

reusing the same `PDFScoreConverter` instance built for the importer in Task 5.

- [ ] **Step 8: Build the app**

`xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 9: Commit**

```bash
git add Packages/Features/Reader Packages/Domain App
git commit -m "feat(reader): convert an older PDF item to notation on first open"
```

---

### Task 7: Reader — the display-source axis

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`, `ReaderViewModel+Load.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderDisplaySourceTests.swift`

**Interfaces:**
- Consumes: Task 2's `ReaderDisplaySource` / `resolve(format:displaySource:)`.
- Produces: `ReaderViewModel.displaySource: ReaderDisplaySource` (private setter),
  `ReaderViewModel.canShowOriginalPDF: Bool`,
  `ReaderViewModel.setDisplaySource(_:) async`,
  `ReaderViewModel.originalPDFDocument: PDFDocument?`,
  `ReaderViewModel.savedScoreLayoutMode: ReaderLayoutMode?` (view-model-held, so the root screen can restore it).

- [ ] **Step 1: Write the failing test**

```swift
import Domain
@testable import Reader
import Testing

@Suite("Reader display source")
@MainActor
struct ReaderDisplaySourceTests {
    @Test("A converted item can show the original; a plain score cannot")
    func availability() async throws {
        #expect(try ReaderTestEnvironment.convertedItem().viewModel.canShowOriginalPDF)
        #expect(!(try ReaderTestEnvironment.scoreItem().viewModel.canShowOriginalPDF))
    }

    @Test("Switching to the original swaps in PDF capabilities and back again")
    func capabilitiesFollowSource() async throws {
        let env = try ReaderTestEnvironment.convertedItem()
        await env.viewModel.load()
        #expect(env.viewModel.capabilities == .forScore)

        await env.viewModel.setDisplaySource(.originalPDF)
        #expect(env.viewModel.capabilities == .forPDF)
        #expect(env.viewModel.originalPDFDocument != nil)

        await env.viewModel.setDisplaySource(.score)
        #expect(env.viewModel.capabilities == .forScore)
    }

    @Test("An unconverted PDF item is pinned to the original")
    func unconvertedIsPinned() async throws {
        let env = try ReaderTestEnvironment.pdfItem(conversion: .fails)
        await env.viewModel.load()
        #expect(env.viewModel.displaySource == .originalPDF)
        #expect(!env.viewModel.canShowOriginalPDF) // no toggle: there is nothing to toggle to
    }
}
```

- [ ] **Step 2: Run to verify failure**

Same command shape as Task 6 Step 2 with `-only-testing:ReaderTests/ReaderDisplaySourceTests`.
Expected: compile failure.

- [ ] **Step 3: Implement**

In `ReaderViewModel`:

```swift
/// Which rendition is on screen. Only a converted PDF item can be on `.originalPDF` by choice; an item folino
/// couldn't read is pinned there because there is nothing else to show.
private(set) var displaySource: ReaderDisplaySource = .score

/// The original PDF, opened lazily the first time the user asks for it — a reader session that never toggles never
/// pays for it.
private(set) var originalPDFDocument: PDFDocument?

/// The layout mode the score side was on before switching to the original, restored on the way back. Horizontal has
/// no meaning on fixed-layout pages, so the switch clamps it and this is what un-clamps it.
var savedScoreLayoutMode: ReaderLayoutMode?

/// Whether the reader should offer the 楽譜 / 原本 PDF toggle at all.
var canShowOriginalPDF: Bool {
    scoreItem.pdfOriginState == .converted
}

func setDisplaySource(_ source: ReaderDisplaySource) async {
    guard source != displaySource else { return }
    if source == .originalPDF, originalPDFDocument == nil {
        guard let name = scoreItem.sourcePDFFileName,
              let doc = PDFDocument(url: scoresDirectory.appending(path: name)),
              doc.pageCount > 0
        else { return }
        originalPDFDocument = doc
    }
    displaySource = source
    capabilities = ReaderCapabilities.resolve(
        format: ScoreFormat.detect(filename: scoreItem.localFileName),
        displaySource: source,
    )
    analytics.log(.readerDisplaySourceChanged(source))
}
```

Replace `capabilities`'s assignment in `load()` with the two-axis `resolve`, and in `loadPDF` set
`displaySource = .originalPDF` (an unconverted item has no score side).

Add the analytics event to `AnalyticsEvent+Factories.swift` following the file's existing pattern
(`readerDisplaySourceChanged(_:)`, name `reader_display_source_changed`, parameter `source` = the raw value).

- [ ] **Step 4: Run the tests to verify they pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader Packages/Domain
git commit -m "feat(reader): add the score / original-PDF display axis"
```

---

### Task 8: Reader — render and toggle the original

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ScoreContentView.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: Task 7's `displaySource` / `originalPDFDocument` / `canShowOriginalPDF` / `savedScoreLayoutMode`.
- Produces: no new API — a UI wiring task.

- [ ] **Step 1: Render the original when it's selected**

In `ScoreContentView`, the branch that currently picks a container from `loadState` gains a preceding check: when
`viewModel.displaySource == .originalPDF`, render the existing PDF containers (`PagedPDFContainer` /
`VerticalPDFContainer`) against `viewModel.originalPDFDocument` and `pdfLayoutMode`, regardless of `loadState`. Read
the file's current `loadedPDF` branch and reuse it verbatim — the only change is where the document comes from.

- [ ] **Step 2: Add the toggle to the top overlay**

In `ReaderTopOverlay`, next to the existing layout / inspector buttons, add — shown only when
`viewModel.canShowOriginalPDF`:

```swift
/// Switches between the notation folino read out of the PDF and the original pages. Two distinct documents, so this
/// is a source switch, not a layout mode: page and vertical stay available on both sides.
private func displaySourceToggle() -> some View {
    Button {
        Task {
            let next: ReaderDisplaySource = viewModel.displaySource == .score ? .originalPDF : .score
            await viewModel.setDisplaySource(next)
        }
    } label: {
        Label {
            Text(
                viewModel.displaySource == .score
                    ? "reader.displaySource.showOriginal"
                    : "reader.displaySource.showScore",
                bundle: .module,
            )
        } icon: {
            Image(systemName: viewModel.displaySource == .score ? "doc.richtext" : "music.note.list")
        }
    }
}
```

Wrap it in the same `overlayButton(...)` chrome the neighboring buttons use (read them first and match).

- [ ] **Step 3: Round-trip the layout mode**

In `ReaderRootScreen`, add:

```swift
.onChange(of: viewModel.displaySource) { _, source in
    // Horizontal has no meaning on fixed-layout pages. Remember what the score side was on so coming back doesn't
    // silently demote the user's choice — page and vertical need no clamping and round-trip untouched.
    switch source {
    case .originalPDF:
        if layoutMode == .horizontal {
            viewModel.savedScoreLayoutMode = .horizontal
            layoutModeRaw = ReaderLayoutMode.page.rawValue
        }
    case .score:
        if let saved = viewModel.savedScoreLayoutMode {
            layoutModeRaw = saved.rawValue
            viewModel.savedScoreLayoutMode = nil
        }
    }
}
```

- [ ] **Step 4: Add the strings**

Add to `Localizable.xcstrings` (en + ja):

| Key | en | ja |
| --- | --- | --- |
| `reader.displaySource.showOriginal` | Original PDF | 原本 PDF |
| `reader.displaySource.showScore` | Sheet music | 楽譜 |

- [ ] **Step 5: Verify with a preview**

Add a `#Preview` to `ReaderTopOverlay.swift` exercising both toggle states, render it with
`mcp__xcode__RenderPreview`, and read the PNG. Confirm the two labels and icons read correctly and the pill matches
its neighbors.

- [ ] **Step 6: Build the Reader package**

From `Packages/Features/Reader`:
`xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`
Expected: BUILD SUCCEEDED, with `Compiling` lines for the files you touched (an app-level build can incrementally
skip an edited package and report a false SUCCEEDED).

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Reader
git commit -m "feat(reader): let a converted item switch back to its original PDF"
```

---

### Task 9: Reader — on-PDF cursor in the original view

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel+PDFPlayback.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPDFPlaybackTests.swift` (extend)

**Interfaces:**
- Consumes: Task 7's `setDisplaySource`, existing `parsePDFForPlayback(url:)` and `PDFPlaybackState`.
- Produces: `ReaderViewModel.prepareOriginalPDFCursorIfNeeded() async` — called from `setDisplaySource` when moving to
  `.originalPDF`.

- [ ] **Step 1: Write the failing test**

```swift
@Test("Switching to the original parses once for the cursor when the score is untouched")
func parsesForCursor() async throws {
    let env = try ReaderTestEnvironment.convertedItem()
    await env.viewModel.load()
    await env.viewModel.setDisplaySource(.originalPDF)
    #expect(env.viewModel.isPDFPlaybackReady)
    #expect(env.parseCallCount == 1)

    await env.viewModel.setDisplaySource(.score)
    await env.viewModel.setDisplaySource(.originalPDF)
    #expect(env.parseCallCount == 1) // once per session, not once per switch
}

@Test("An edited score gets no on-PDF cursor")
func editedScoreHasNoCursor() async throws {
    let env = try ReaderTestEnvironment.convertedItem(edited: true)
    await env.viewModel.load()
    await env.viewModel.setDisplaySource(.originalPDF)
    #expect(!env.viewModel.isPDFPlaybackReady)
    #expect(env.parseCallCount == 0)
}
```

- [ ] **Step 2: Run to verify failure**

`-only-testing:ReaderTests/ReaderViewModelPDFPlaybackTests`. Expected: FAIL.

- [ ] **Step 3: Implement**

Add to `ReaderViewModel+PDFPlayback.swift`:

```swift
/// The cursor drawn on an original PDF page comes from the OMR geometry side-car, which only exists as a product of
/// a parse. A converted item doesn't parse at open time any more, so the original view asks for it on first switch —
/// once per session, in the background, with the pages already on screen.
///
/// Gated on the notation being untouched: after an edit, the geometry describes a score that is no longer what's
/// playing, and a cursor drawn from it would point at the wrong bar.
func prepareOriginalPDFCursorIfNeeded() async {
    guard case .idle = pdfPlayback,
          !scoreItem.isPDFDerivedScoreEdited,
          let name = scoreItem.sourcePDFFileName
    else { return }
    await parsePDFForPlayback(url: scoresDirectory.appending(path: name))
}
```

Call it from `setDisplaySource` after `displaySource = source`, for `.originalPDF` only, in a detached `Task` so the
switch itself stays instant:

```swift
if source == .originalPDF {
    Task { [weak self] in await self?.prepareOriginalPDFCursorIfNeeded() }
}
```

`playbackScore` must keep returning the **loaded** score for a converted item — the parsed one is only there for its
geometry. Change its first line to:

```swift
// For a converted item the loaded score is the source of truth; the PDF parse exists only to place the cursor on
// the original pages.
if loadState.score == nil, case let .ready(data) = pdfPlayback { return data.score }
return loadState.score
```

- [ ] **Step 4: Run the tests to verify they pass**

Expected: PASS. Run the full `Reader` suite too — `playbackScore`'s change touches transport tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader
git commit -m "feat(reader): keep the on-PDF cursor when viewing the original"
```

---

### Task 10: Reader — the re-read action

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel+PDFConversion.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift`, `ReaderRootScreen.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPDFConversionTests.swift` (extend)

**Interfaces:**
- Consumes: Task 2's `PDFReparsePolicy` / `clearingStaffBoundOverrides()`, Task 6's conversion closure.
- Produces: `ReaderViewModel.canReReadPDF: Bool`, `ReaderViewModel.reReadNeedsConfirmation: Bool`,
  `ReaderViewModel.reReadPDF() async`, `ReaderViewModel.reReadError: String?`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("A clean converted item needs no confirmation")
func noConfirmationWhenClean() async throws {
    let env = try ReaderTestEnvironment.convertedItem()
    await env.viewModel.load()
    #expect(env.viewModel.canReReadPDF)
    #expect(!env.viewModel.reReadNeedsConfirmation)
}

@Test("Edits, staff-bound settings, or notation ink each require confirmation")
func confirmationWhenDirty() async throws {
    let env = try ReaderTestEnvironment.convertedItem(edited: true)
    await env.viewModel.load()
    #expect(env.viewModel.reReadNeedsConfirmation)
}

@Test("A successful re-read rewrites the score and resets staff-bound settings")
func reReadResets() async throws {
    let env = try ReaderTestEnvironment.convertedItem(edited: true)
    await env.viewModel.load()
    env.viewModel.layoutModel.hiddenStaves = [StaffAddress(partIndex: 0, staffIndexInPart: 0)]

    await env.viewModel.reReadPDF()

    #expect(env.viewModel.scoreItem.pdfDerivedContentHash == env.viewModel.scoreItem.contentHash)
    #expect(!env.viewModel.scoreItem.isPDFDerivedScoreEdited)
    #expect(env.viewModel.layoutModel.hiddenStaves.isEmpty)
    #expect(env.viewModel.reReadError == nil)
}

@Test("A failed re-read changes nothing and reports the error")
func reReadFailureIsInert() async throws {
    let env = try ReaderTestEnvironment.convertedItem(conversion: .fails)
    await env.viewModel.load()
    let before = env.viewModel.scoreItem

    await env.viewModel.reReadPDF()

    #expect(env.viewModel.scoreItem.contentHash == before.contentHash)
    #expect(env.viewModel.scoreItem.localFileName == before.localFileName)
    #expect(env.viewModel.reReadError != nil)
}

@Test("Re-reading an unreadable PDF clears the failure flag and retries")
func retryClearsFlag() async throws {
    let env = try ReaderTestEnvironment.pdfItem(conversion: .succeedsOnSecondCall)
    await env.viewModel.load()
    #expect(env.viewModel.scoreItem.pdfConversionFailed)

    await env.viewModel.reReadPDF()
    #expect(env.viewModel.scoreItem.pdfOriginState == .converted)
}
```

- [ ] **Step 2: Run to verify failure**

`-only-testing:ReaderTests/ReaderViewModelPDFConversionTests`. Expected: compile failure.

- [ ] **Step 3: Implement the flow**

Append to `ReaderViewModel+PDFConversion.swift`:

```swift
extension ReaderViewModel {
    /// Any PDF-origin item can be read again — including one folino failed to read, where this is the retry.
    var canReReadPDF: Bool {
        scoreItem.sourcePDFFileName != nil && pdfConversion != nil
    }

    /// Whether re-reading would discard user work, and therefore has to ask first.
    var reReadNeedsConfirmation: Bool {
        PDFReparsePolicy.needsConfirmation(
            isScoreEdited: scoreItem.isPDFDerivedScoreEdited,
            hasStaffBoundPreferences: preferences.hasStaffBoundOverrides,
            hasMusicalAnnotations: !annotationDrawings.isEmpty,
        )
    }

    /// Read the original PDF again, replacing the notation with a fresh parse. Writes to a scratch file first and
    /// swaps it in only on success, so a failed re-read leaves the score the user has exactly as it was.
    ///
    /// Staff-bound settings are reset afterwards: a better parse can renumber staves, and a clef override or hidden
    /// staff pointing at a different staff than the user chose is worse than no override at all. Ink anchored to the
    /// notation is kept — it may shift, which the confirmation says, and erasing a user's annotations to spare them
    /// an offset is the worse failure.
    func reReadPDF() async {
        guard let name = scoreItem.sourcePDFFileName, let pdfConversion else { return }
        reReadError = nil
        isConvertingPDF = true
        defer { isConvertingPDF = false }

        let pdfURL = scoresDirectory.appending(path: name)
        let scratch = scoresDirectory.appending(path: "\(scoreItem.id.rawValue.uuidString).reread.mscz")
        guard let facts = await pdfConversion(pdfURL, scratch) else {
            try? FileManager.default.removeItem(at: scratch)
            reReadError = String(localized: "reader.pdf.reread.failed", bundle: .module)
            return
        }

        let msczName = "\(scoreItem.id.rawValue.uuidString).\(ScoreFormat.mscz.canonicalExtension)"
        let destination = scoresDirectory.appending(path: msczName)
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: scratch)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            reReadError = String(localized: "reader.pdf.reread.failed", bundle: .module)
            return
        }

        var updated = scoreItem
        updated.localFileName = msczName
        updated.contentHash = facts.contentHash
        updated.sizeBytes = facts.sizeBytes
        updated.lengthBeats = facts.summary.lengthBeats
        updated.defaultTempoBpm = facts.summary.defaultTempoBpm
        updated.primaryKey = facts.summary.primaryKey
        updated.instrumentationSummary = facts.summary.instrumentationSummary
        updated.pdfDerivedContentHash = facts.contentHash
        updated.pdfConversionFailed = false
        scoreItem = updated
        try? await repository.saveScoreItem(updated)

        await resetStaffBoundPreferences()
        pdfPlayback = .idle // the geometry belongs to the previous parse
        await setDisplaySource(.score)
        await load()
    }

    private func resetStaffBoundPreferences() async {
        await preferencesStore.mutate { prefs in prefs = prefs.clearingStaffBoundOverrides() }
    }
}
```

Add `var reReadError: String?` to `ReaderViewModel`. If `preferencesStore.mutate` doesn't accept whole-value
replacement, assign the individual fields inside the closure instead (`prefs.hiddenStaves = []`, …) — read
`ReaderPreferencesStore` first and match its signature.

`scoreItem` mutations again go through the memberwise rebuild helper from Task 6 if `contentHash` stays `let`.

- [ ] **Step 4: Wire the menu item and the confirmation**

In `ReaderTopOverlay`'s overflow menu (`scoreOverflowMenu()`, and the non-compact `scoreActionButtons()` menu), add
when `viewModel.canReReadPDF`:

```swift
Button { onReReadPDF() } label: {
    Label {
        Text("reader.pdf.reread.action", bundle: .module)
    } icon: {
        Image(systemName: "arrow.clockwise.circle")
    }
}
```

with a new `var onReReadPDF: () -> Void = {}` parameter, passed from `ReaderRootScreen` as
`{ isReReadConfirmPresented = viewModel.reReadNeedsConfirmation; if !viewModel.reReadNeedsConfirmation { Task { await viewModel.reReadPDF() } } }`.

In `ReaderRootScreen` add the alert:

```swift
.alert(
    Text("reader.pdf.reread.confirm.title", bundle: .module),
    isPresented: $isReReadConfirmPresented,
) {
    Button(role: .cancel) {} label: { L10n.Common.cancel }
    Button(role: .destructive) { Task { await viewModel.reReadPDF() } } label: {
        Text("reader.pdf.reread.confirm.action", bundle: .module)
    }
} message: {
    Text("reader.pdf.reread.confirm.body", bundle: .module)
}
.alert(
    Text("reader.pdf.reread.failed.title", bundle: .module),
    isPresented: Binding(
        get: { viewModel.reReadError != nil },
        set: { if !$0 { viewModel.reReadError = nil } },
    ),
) {
    Button {} label: { L10n.Common.ok }
} message: {
    Text(viewModel.reReadError ?? "")
}
```

- [ ] **Step 5: Add the strings**

| Key | en | ja |
| --- | --- | --- |
| `reader.pdf.reread.action` | Read the PDF again | PDF から読み取り直す |
| `reader.pdf.reread.confirm.title` | Read this PDF again? | PDF から読み取り直しますか？ |
| `reader.pdf.reread.confirm.body` | Your note edits and per-staff settings (clef, visibility, instrument, volume, transposition) will be lost. Annotations are kept but may shift. | 音符の編集内容と、譜表ごとの設定（音部記号・表示/非表示・音色・音量・移調）は失われます。書き込みは残りますが、位置がずれることがあります。 |
| `reader.pdf.reread.confirm.action` | Read again | 読み取り直す |
| `reader.pdf.reread.failed.title` | Couldn't read this PDF | PDF を読み取れませんでした |
| `reader.pdf.reread.failed` | folino couldn't read sheet music out of this PDF. The score is unchanged. | この PDF から楽譜を読み取れませんでした。楽譜はそのままです。 |

- [ ] **Step 6: Run the tests, then build the package**

Expected: PASS / BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Reader
git commit -m "feat(reader): let the user read a PDF again, with a gate on losing work"
```

---

### Task 11: Reader — rewrite the caveat dialog and reset its flag

**Files:**
- Delete: `Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFPlaybackNotice.swift`
- Create: `Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFSourceNotice.swift`
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift:83` (the settings-key enum)
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`, `ReaderTopOverlay.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: Task 1's `pdfOriginState`.
- Produces: `ReaderGlobalSettingsKey.pdfSourceNoticeDismissed = "readerPdfSourceNoticeDismissed"`;
  `View.pdfSourceNoticeAlert(originState:isPresented:onDontShowAgain:)`.

- [ ] **Step 1: Add the new key, keep the old one**

In the settings-key enum:

```swift
/// The old PDF-playback caveat's suppression flag. Left in place, unread by iOS: the message it silenced is gone,
/// and Android still reads it until its own follow-up ships.
public static let pdfPlaybackNoticeDismissed = "readerPdfPlaybackNoticeDismissed"
/// Suppression flag for the PDF-source notice. A NEW key on purpose — the message now explains that folino read the
/// PDF into editable notation and how to correct it, which is worth showing once even to someone who dismissed the
/// old caveat.
public static let pdfSourceNoticeDismissed = "readerPdfSourceNoticeDismissed"
```

- [ ] **Step 2: Write the new notice**

Create `PDFSourceNotice.swift`, replacing `PDFPlaybackNotice.swift` (keep the iOS-18 / iOS-26 emphasized-button
handling verbatim — copy it from the file you're deleting):

```swift
import Domain
import SwiftUI
import UtilityUI

/// Body copy for the PDF-source notice: what folino did with the PDF, and what the user can do about it.
private func pdfSourceNoticeBodyKey(for state: PDFOriginState) -> String.LocalizationValue {
    state == .converted ? "reader.pdf.source.notice.body" : "reader.pdf.source.unavailable.body"
}

private func pdfSourceNoticeTitleKey(for state: PDFOriginState) -> String.LocalizationValue {
    state == .converted ? "reader.pdf.source.notice.title" : "reader.pdf.source.unavailable.title"
}

extension View {
    /// Explains that folino read this PDF into notation — that it is now an ordinary, editable score, that a
    /// misread note can be fixed with the note-input button, and that the original pages are one tap away.
    ///
    /// Two buttons: an emphasized OK that closes it for now, and a plain "Don't show again" that suppresses the
    /// automatic presentation. The explanation stays reachable from the PDF badge.
    func pdfSourceNoticeAlert(
        originState: PDFOriginState,
        isPresented: Binding<Bool>,
        onDontShowAgain: @escaping () -> Void,
    ) -> some View {
        alert(
            Text(String(localized: pdfSourceNoticeTitleKey(for: originState), bundle: .module)),
            isPresented: isPresented,
        ) {
            if #available(iOS 26, *) {
                Button(role: .confirm) {} label: { L10n.Common.ok }
            } else {
                Button {} label: { L10n.Common.ok }
                    .keyboardShortcut(.defaultAction)
            }
            Button { onDontShowAgain() } label: {
                Text("reader.pdf.source.notice.dismiss", bundle: .module)
            }
        } message: {
            Text(String(localized: pdfSourceNoticeBodyKey(for: originState), bundle: .module))
        }
    }
}
```

- [ ] **Step 3: Present it on the first open of a converted item**

In `ReaderRootScreen`, swap the `@AppStorage` key to `pdfSourceNoticeDismissed`, replace
`.pdfPlaybackNoticeAlert(...)` with `.pdfSourceNoticeAlert(originState: viewModel.scoreItem.pdfOriginState, …)`, and
replace the `onChange(of: viewModel.isPDFPlaybackReady)` trigger with:

```swift
.onChange(of: viewModel.scoreItem.pdfOriginState, initial: true) { _, state in
    // Show it once the item's origin is settled — for a lazily converted item that's after the conversion, not at
    // open. `.notPDF` never triggers.
    guard state != .notPDF, !hasAutoShownPDFNotice, !pdfSourceNoticeDismissed else { return }
    hasAutoShownPDFNotice = true
    isPDFNoticePresented = true
}
```

The PDF badge in `ReaderTopOverlay` keeps opening the same alert; only the callback name changes.

- [ ] **Step 4: Add the strings**

| Key | en | ja |
| --- | --- | --- |
| `reader.pdf.source.notice.title` | Read into sheet music | PDF から楽譜を読み取りました |
| `reader.pdf.source.notice.body` | folino read this PDF into sheet music, so playback, transposition, and display settings all work. If a note came out wrong, fix it right here with the note button above. The original PDF is always one tap away. | この PDF を解析して楽譜に変換しました。再生・移調・表示の調整が使えます。読み取りが間違っている音符は、上の音符ボタンからその場で直せます。元の PDF はいつでも表示を切り替えて見られます。 |
| `reader.pdf.source.notice.dismiss` | Don't show again | 今後表示しない |
| `reader.pdf.source.unavailable.title` | Shown as a PDF | PDF として表示しています |
| `reader.pdf.source.unavailable.body` | folino couldn't read sheet music out of this PDF, so it's shown as it is. You can try again any time from the menu. | この PDF からは楽譜を読み取れませんでした。PDF としてそのまま表示します。メニューからいつでも読み取り直せます。 |

Remove the now-unreferenced `reader.pdf.playback.notice.*` / `reader.pdf.playback.unavailable.*` keys from
`Localizable.xcstrings`. Grep for each key first — `xcstringstool` does not remove stale keys automatically and a
literal without a bundle argument is easy to miss.

- [ ] **Step 5: Verify with a preview**

Add a `#Preview` presenting the alert in both origin states, render with `mcp__xcode__RenderPreview`, read the PNG,
and check the copy fits and the OK button is the emphasized one.

- [ ] **Step 6: Build the package and commit**

```bash
git add Packages/Features/Reader Packages/Domain
git commit -m "feat(reader): explain what folino did with the PDF, and show it once more"
```

---

### Task 12: Library, share, and delete carry the sidecar

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Views/ScoreRow.swift` (badge condition)
- Modify: `Packages/Domain/Sources/Domain/Presentation/ScorePresentation.swift` (badge helper)
- Modify: `Packages/ScoreUI/Sources/ScoreUI/ShareSubmenu.swift` (original-PDF entry)
- Modify: the purge / hard-delete path in `Packages/Infrastructure/Sources/Persistence/LiveScoreLibraryRepository.swift`
- Test: `Packages/Domain/Tests/DomainTests/Presentation/ScorePresentationPDFTests.swift` (extend)

**Interfaces:**
- Consumes: Task 1's `pdfOriginState`.
- Produces: `ScorePresentation.showsPDFBadge(for: ScoreItem) -> Bool`.

- [ ] **Step 1: Write the failing test**

```swift
@Test("A converted item still carries the PDF badge")
func convertedItemKeepsBadge() {
    #expect(ScorePresentation.showsPDFBadge(for: convertedPDFItem()))
    #expect(ScorePresentation.showsPDFBadge(for: unconvertedPDFItem()))
    #expect(!ScorePresentation.showsPDFBadge(for: plainScoreItem()))
}
```

(Build the three fixtures with the helper already in that file.)

- [ ] **Step 2: Run to verify failure**

From `Packages/Domain`, `-only-testing:Domain/ScorePresentationPDFTests`. Expected: compile failure.

- [ ] **Step 3: Implement the badge helper**

```swift
/// Whether the library row and reader header should mark this item as PDF-derived. Stays true after conversion: the
/// badge's job is to say "this notation was machine-read and may contain mistakes", which a converted item needs
/// more than an unconverted one, not less.
static func showsPDFBadge(for item: ScoreItem) -> Bool {
    item.pdfOriginState != .notPDF
}
```

Point `ScoreRow`'s badge condition (currently a `format == .pdf` check — grep for `PDFBadge` / `ScoreSourceKind`) at
this helper, and do the same for the reader header's badge in `ReaderTopOverlay`.

- [ ] **Step 4: Offer the original in the share sheet**

In `ShareSubmenu`, add an entry — only when `item.pdfOriginState == .converted` — that shares the sidecar bytes
unchanged, labeled distinctly from the existing "PDF" entry (which renders the current score):

| Key | en | ja |
| --- | --- | --- |
| `share.format.originalPDF` | Original PDF | 元の PDF |

Follow the file's existing `ShareFormatMenuItems` pattern; the share service resolves the URL as
`scoresDirectory/<sourcePDFFileName>`.

- [ ] **Step 5: Carry the sidecar through delete and purge**

Find the path that removes `localFileName` from disk when an item is purged from Recently Deleted (grep
`removeItem(at:` in `LiveScoreLibraryRepository`), and remove `sourcePDFFileName` alongside it. Leaving the PDF
behind would silently retain the largest file of a deleted item.

- [ ] **Step 6: Run the Domain and Infrastructure suites, then build the app**

Expected: PASS / BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Packages App
git commit -m "feat(library): keep the PDF origin visible, shareable, and deletable"
```

---

### Task 13: Full verification pass

**Files:** none — a verification task.

- [ ] **Step 1: Run every affected package suite**

From each package directory:
- `Packages/Domain`: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`
- `Packages/Infrastructure`: same with `-scheme Infrastructure-Package`
- `Packages/Features/Reader`: same with `-scheme Reader`
- `Packages/Features/Library`: same with `-scheme Library`

Expected: all PASS.

- [ ] **Step 2: Build the app**

`xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED with no new warnings.

- [ ] **Step 3: Confirm the iOS 18 floor**

The deployment target is iOS 18.0, and an app build can report a false SUCCEEDED when it incrementally skips an
edited package. Confirm no raw iOS-26-only API was introduced: grep the diff for `@available(iOS 26`, `ToolbarSpacer`,
`role: .confirm`, and `glassEffect`, and check each hit is either inside an existing availability branch (the notice
alert's OK button is) or routed through `UtilityUI/GlassEffectCompat`.

- [ ] **Step 4: Report to the user**

Summarize what landed, what is left for the Android follow-up, and hand over for manual device verification: import a
MuseScore-exported PDF, confirm it appears as a normal score, toggle to the original and back, edit a note, then
re-read and confirm the dialog appears and the edit is discarded.

---

## Self-Review

**Spec coverage:**
- §1 Domain fields / `PDFOriginState` → Task 1.
- §2 migration v15 / duplicate query → Task 3.
- §3 `PDFScoreConverter` + import branch → Tasks 4, 5.
- §4 lazy migration on open → Task 6.
- §5 display source, capabilities, layout round-trip, lazy document, on-PDF cursor → Tasks 7, 8, 9.
- §6 re-read + confirmation policy + preference reset → Tasks 2, 10.
- §7 dialog rewrite + key reset → Task 11.
- §8 badge, share, delete → Task 12.
- Testing section → distributed across every task plus Task 13.

**Placeholders:** none — every step names files, commands, and code.

**Type consistency:** `PDFConversionFacts` (Domain) is produced by `PDFScoreConverter` (Task 4, via the `facts`
accessor added in Task 6) and consumed by the Reader's `PDFScoreConversion` closure (Tasks 6, 10).
`pdfOriginState` / `isPDFDerivedScoreEdited` (Task 1) are used in Tasks 6, 7, 9, 10, 11, 12.
`clearingStaffBoundOverrides()` / `hasStaffBoundOverrides` (Task 2) are used in Task 10.
`resolve(format:displaySource:)` (Task 2) is used in Tasks 6 and 7.

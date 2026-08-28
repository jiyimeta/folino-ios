# Revert to Original Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep every score's import-time bytes as a sidecar, and let the user put them back after note editing.

**Architecture:** A lazily-captured sidecar file holds the original bytes; three columns on `score_items` name it, hash it, and record what it is. Capture happens at the Editor's single write choke point, keyed off the sidecar's existence rather than a database flag so a crash can never overwrite a real original with edited bytes. Restore, capture, and every decision around them sit behind one Domain protocol (`ScoreOriginalStore`) with pure Domain planners, so the Reader, the Library and eventually Android all drive the same code.

**Tech Stack:** Swift 6.3, SwiftUI, GRDB (SQLite), Swift Testing, swift-sheet-music.

**Spec:** `docs/superpowers/specs/2026-08-16-revert-to-original-design.md`

## Global Constraints

- Strict layered SPM modules. Domain is Foundation-only. Features never import Infrastructure, another Feature, or `swift-sheet-music`. See `docs/engineering/module-architecture.md`.
- Dependency injection is constructor-only. `EnvironmentValues` is never a service locator.
- New tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`).
- `swift test` does not work in this repo. Every test run is `xcodebuild test -scheme <Pkg|Pkg-Package> -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`, run from the package directory.
- SwiftLint caps files at 400 lines. `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift` is at 286 — v18's body goes in its own file.
- User-facing brand name is lowercase `folino`. Localization keys follow `module.feature.thing`.
- Comment paragraphs reflow at 120 columns.
- Do not add or remove SwiftPM dependencies.

## Deviations from the spec, decided while planning

Three refinements. They are improvements the spec's own reasoning implies; the spec file is updated in Task 14.

1. **The migration does not scan the scores directory.** Migrations run from `AppDatabase.init(databaseURL:)`, which has no scores directory. Orphan recovery moves into capture instead: when the plan is computed, the caller offers any same-stem non-MuseScore source file it found on disk, and adopting one is authoritative evidence of `importTime`. This deletes a whole one-time reconciliation pass.
2. **Revert lives in Infrastructure behind a Domain protocol, not in the Reader.** `EditScoreInfoSheet` is presented from the Library as well as the Reader, so putting the operation in `ReaderViewModel` would either duplicate it or make the sheet behave differently depending on where it was opened.
3. **The score-info entry point therefore appears wherever that sheet appears,** including from the Library's row menu → "楽曲情報". The Library *row menu itself* still gets no revert item, which is what was ruled out.

Two smaller ones, both stated so they are not mistaken for oversights:

4. **The score-info sheet's ink warning is worded conditionally rather than measured.** The Editor's confirmation can say "your handwriting *will* shift" because the Reader knows what ink is loaded; the sheet is presented from the Library too, which does not load annotations at all. Rather than plumb an annotation query through the composition root for one sentence, the sheet says "handwriting anchored to the notation may move" unconditionally. `RevertPolicy.warnings` still takes `hasMusicalAnnotations` — the Editor uses it — the sheet simply passes `true`.
5. **Revert verifies the restored bytes against `original_content_hash`** (spec "What changes"), which the first draft of this plan omitted. Task 7 throws on a mismatch rather than adopting whatever it found.
6. **The hash check runs before the file is touched, not after.** Task 7's own code block above originally hashed the *destination* — i.e. it swapped the sidecar into place (or deleted the sibling `.mscz`) and only then compared the resulting hash against `original_content_hash`, throwing after the mutation had already happened. That meant a corrupted sidecar was discovered only once the user's edit and its only backup were both gone — the exact failure deviation 5 exists to prevent. What shipped in `LiveScoreOriginalStore.swift` (Task 7) hashes the *source* — the sidecar, or the adopt-target — before `swapIn` or the sibling delete runs, and refuses with both the edit and the backup still intact if it disagrees. This is corrected in Task 14, both in Task 7's code block above and in the spec's "What changes" section.

---

## File Structure

**Domain — `Packages/Domain/Sources/Domain/`**

| File | Responsibility |
| --- | --- |
| `Models/OriginalProvenance.swift` | Create. What a captured original's bytes are. |
| `Models/ScoreItem.swift` | Modify. Three stored properties + `Codable` back-compat. |
| `Models/ScoreItem+Original.swift` | Create. Sidecar naming, adoptable candidates, `capturingOriginal`, `adoptingRevertedOriginal`. |
| `Logic/OriginalCapture.swift` | Create. Pure `plan(for:adoptableSourceFileName:)`. |
| `Logic/RevertPolicy.swift` | Create. Pure file plan + user-facing warnings. |
| `Protocols/ScoreOriginalStore.swift` | Create. The capture/restore seam. |

**Infrastructure — `Packages/Infrastructure/Sources/`**

| File | Responsibility |
| --- | --- |
| `Persistence/Database/Migrations+V18.swift` | Create. Three columns + the `legacyUnknown` pre-stamp. |
| `Persistence/Database/Migrations.swift` | Modify. Register v18. |
| `Persistence/Database/Migrations+TestSupport.swift` | Modify. Add `upToV17`. |
| `Persistence/Records/ScoreItemRecord.swift` | Modify. Three columns. |
| `Persistence/LiveScoreLibraryRepository.swift` | Modify. `filesBackingRow` + duplicate query. |
| `ScoreFiles/LiveScoreOriginalStore.swift` | Create. All file I/O for capture and restore. |

**Features**

| File | Responsibility |
| --- | --- |
| `Editor/.../EditorViewModel.swift` | Modify. Hold the store; `canRevert`; `revertToOriginal()`. |
| `Editor/.../EditorViewModel+Persistence.swift` | Modify. Capture before the first write. |
| `Editor/.../Screens/EditorChromeView+Toolbar.swift` | Modify. The `⋯` menu item. |
| `Editor/.../Screens/EditorChromeView+Revert.swift` | Create. Confirmation dialog. |
| `Editor/.../NoopScoreOriginalStore.swift` | Create. So the Editor's own `#Preview` factory still builds. |
| `Reader/.../ReaderViewModel+PDFReread.swift` | Modify. Clear the sidecar on a successful re-read. |
| `Reader/.../ReaderViewModel+Conformances.swift` | Modify. `ScoreInfoEditing` revert conformance. |
| `Reader/.../NoopScoreServices.swift` | Modify. A no-op store, so the ~30 preview and test constructions keep working. |
| `Reader/.../Screens/ReaderRootScreen.swift` | Modify. Take the real store and the two host members. |
| `Library/.../LibraryViewModel.swift` | Modify. Hold the store. |
| `Library/.../LibraryViewModel+Revert.swift` | Create. The conformance, kept out of a file near the 400-line cap. |

**ScoreUI**

| File | Responsibility |
| --- | --- |
| `ScoreUI/ScoreInfoEditing.swift` | Modify. Two protocol members. |
| `ScoreUI/EditScoreInfoSheet.swift` | Modify. The revert row. |
| `ScoreUI/RevertToOriginalConfirmation.swift` | Create. Shared confirmation + scope choice. |

**App**

| File | Responsibility |
| --- | --- |
| `App/AppBootstrap.swift` | Modify. Construct and publish `LiveScoreOriginalStore`. |
| `App/AppShellView.swift` | Modify. Carry it to the Reader, the Library and the editable reader. |
| `App/EditableReaderScreen.swift` | Modify. Pass it to `EditorViewModel`. |

---

## Task 1: Domain — provenance, item fields, and the capture planner

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/OriginalProvenance.swift`
- Create: `Packages/Domain/Sources/Domain/Models/ScoreItem+Original.swift`
- Create: `Packages/Domain/Sources/Domain/Logic/OriginalCapture.swift`
- Modify: `Packages/Domain/Sources/Domain/Models/ScoreItem.swift`
- Test: `Packages/Domain/Tests/DomainTests/OriginalCaptureTests.swift`

**Interfaces:**
- Consumes: `ScoreItem`, `ScoreFormat`, `PDFOriginState` (all existing).
- Produces:
  - `enum OriginalProvenance: String, Hashable, Sendable, Codable { case importTime, conversionOutput, legacyUnknown }`
  - `ScoreItem.originalFileName: String?`, `.originalContentHash: String?`, `.originalProvenance: OriginalProvenance?` (all `var`, all with `nil` defaults at the end of the memberwise `init`)
  - `ScoreItem.originalSidecarFileName: String`
  - `ScoreItem.adoptableSourceFileNames: [String]`
  - `ScoreItem.canRevertToOriginal: Bool`
  - `ScoreItem.capturingOriginal(fileName:contentHash:provenance:) -> ScoreItem`
  - `enum OriginalCapturePlan: Hashable, Sendable { case none, adopt(fileName: String, provenance: OriginalProvenance), copy(sidecarFileName: String, provenance: OriginalProvenance) }`
  - `enum OriginalCapture { static func plan(for: ScoreItem, adoptableSourceFileName: String?) -> OriginalCapturePlan }`

- [ ] **Step 1: Write the failing tests**

Create `Packages/Domain/Tests/DomainTests/OriginalCaptureTests.swift`:

```swift
@testable import Domain
import Foundation
import Testing

@Suite("Original capture planning")
struct OriginalCaptureTests {
    private func item(
        localFileName: String,
        originalFileName: String? = nil,
        originalProvenance: OriginalProvenance? = nil,
        contentHash: String = "hash-current",
        sourcePDFFileName: String? = nil,
        pdfDerivedContentHash: String? = nil,
    ) -> ScoreItem {
        var item = ScoreItem(
            title: "t",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: localFileName,
            contentHash: contentHash,
            sizeBytes: 1,
            lengthBeats: 1,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
            sourcePDFFileName: sourcePDFFileName,
            pdfDerivedContentHash: pdfDerivedContentHash,
        )
        item.originalFileName = originalFileName
        item.originalProvenance = originalProvenance
        return item
    }

    @Test func `an item that already has an original is not captured again`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz")
        #expect(OriginalCapture.plan(for: subject, adoptableSourceFileName: nil) == .none)
    }

    @Test func `an unconverted pdf is never captured`() {
        let subject = item(localFileName: "ID.pdf")
        #expect(OriginalCapture.plan(for: subject, adoptableSourceFileName: nil) == .none)
    }

    @Test func `a musicxml source is adopted where it already sits`() {
        let subject = item(localFileName: "ID.musicxml")
        #expect(
            OriginalCapture.plan(for: subject, adoptableSourceFileName: nil)
                == .adopt(fileName: "ID.musicxml", provenance: .importTime),
        )
    }

    @Test func `a midi source is adopted where it already sits`() {
        let subject = item(localFileName: "ID.mid")
        #expect(
            OriginalCapture.plan(for: subject, adoptableSourceFileName: nil)
                == .adopt(fileName: "ID.mid", provenance: .importTime),
        )
    }

    @Test func `an orphaned source file beside an mscz is adopted as import-time`() {
        let subject = item(localFileName: "ID.mscz", originalProvenance: .legacyUnknown)
        #expect(
            OriginalCapture.plan(for: subject, adoptableSourceFileName: "ID.musicxml")
                == .adopt(fileName: "ID.musicxml", provenance: .importTime),
        )
    }

    @Test func `a plain mscz import is copied to a sidecar as import-time`() {
        let subject = item(localFileName: "ID.mscz")
        #expect(
            OriginalCapture.plan(for: subject, adoptableSourceFileName: nil)
                == .copy(sidecarFileName: "ID.original.mscz", provenance: .importTime),
        )
    }

    @Test func `an mscx import keeps its own extension in the sidecar name`() {
        let subject = item(localFileName: "ID.mscx")
        #expect(
            OriginalCapture.plan(for: subject, adoptableSourceFileName: nil)
                == .copy(sidecarFileName: "ID.original.mscx", provenance: .importTime),
        )
    }

    @Test func `a converted pdf captures the conversion output`() {
        let subject = item(
            localFileName: "ID.mscz",
            contentHash: "h",
            sourcePDFFileName: "ID.pdf",
            pdfDerivedContentHash: "h",
        )
        #expect(
            OriginalCapture.plan(for: subject, adoptableSourceFileName: nil)
                == .copy(sidecarFileName: "ID.original.mscz", provenance: .conversionOutput),
        )
    }

    @Test func `a pre-stamped legacy row keeps its legacy provenance when copied`() {
        let subject = item(localFileName: "ID.mscz", originalProvenance: .legacyUnknown)
        #expect(
            OriginalCapture.plan(for: subject, adoptableSourceFileName: nil)
                == .copy(sidecarFileName: "ID.original.mscz", provenance: .legacyUnknown),
        )
    }

    @Test func `adoptable candidates are the non-museScore canonical siblings`() {
        let subject = item(localFileName: "ID.mscz")
        #expect(subject.adoptableSourceFileNames == ["ID.musicxml", "ID.mxl", "ID.mid"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run from `Packages/Domain`:

```
xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/OriginalCaptureTests
```

Expected: FAIL — `cannot find 'OriginalCapture' in scope`, `value of type 'ScoreItem' has no member 'originalFileName'`.

- [ ] **Step 3: Add `OriginalProvenance`**

Create `Packages/Domain/Sources/Domain/Models/OriginalProvenance.swift`:

```swift
import Foundation

/// What a captured original's bytes actually are. Stored on `ScoreItem` so the confirmation dialog can be honest
/// about what reverting will produce without having to re-derive it from a row's history, which is not recorded.
///
/// The raw values are persisted in `score_items.original_provenance`; do not rename them.
public enum OriginalProvenance: String, Hashable, Sendable, Codable {
    /// The bytes folino imported, captured by this feature or recovered as an untouched source file.
    case importTime
    /// The score exactly as the PDF conversion wrote it. The PDF itself is a separate sidecar
    /// (`sourcePDFFileName`) and is not what this describes.
    case conversionOutput
    /// Captured from a row that predates this feature, where whether it had already been edited cannot be known.
    case legacyUnknown
}
```

- [ ] **Step 4: Add the three stored properties to `ScoreItem`**

In `Packages/Domain/Sources/Domain/Models/ScoreItem.swift`, after `pdfConversionFailed`'s declaration:

```swift
    /// The file holding this item's original bytes, in the scores directory, or `nil` when nothing has been captured.
    /// Usually `<id>.original.<ext>`, but for a MusicXML / MXL / MIDI import it is the source file itself — the
    /// column names a file, not a pattern, exactly as `sourcePDFFileName` does.
    public var originalFileName: String?
    /// SHA-256 of `originalFileName`'s bytes, in the importer's hex-digest format. Verifies a restore, answers "has
    /// this been edited" without touching disk, and joins duplicate detection.
    public var originalContentHash: String?
    /// What those bytes are. Non-nil with a `nil` `originalFileName` for a row the v18 migration pre-stamped as
    /// predating this feature; capture keeps that value.
    public var originalProvenance: OriginalProvenance?
```

Add three parameters to the memberwise `init`, after `pdfConversionFailed: Bool = false,`:

```swift
        originalFileName: String? = nil,
        originalContentHash: String? = nil,
        originalProvenance: OriginalProvenance? = nil,
```

and the three assignments at the end of its body:

```swift
        self.originalFileName = originalFileName
        self.originalContentHash = originalContentHash
        self.originalProvenance = originalProvenance
```

In `init(from decoder:)`, add three lines to the `try self.init(...)` call after `pdfConversionFailed:`:

```swift
            originalFileName: c.decodeIfPresent(String.self, forKey: .originalFileName),
            originalContentHash: c.decodeIfPresent(String.self, forKey: .originalContentHash),
            originalProvenance: c.decodeIfPresent(OriginalProvenance.self, forKey: .originalProvenance),
```

All three are optional, so the hand-written decoder keeps decoding payloads written before they existed.

- [ ] **Step 5: Add `ScoreItem+Original.swift`**

Create `Packages/Domain/Sources/Domain/Models/ScoreItem+Original.swift`:

```swift
import Foundation

extension ScoreItem {
    /// Where a copied original goes: the item's own stem, marked, keeping the current file's extension so
    /// `ScoreFormat.detect` — which reads only the last extension — still identifies it.
    public var originalSidecarFileName: String {
        let stem = URL(fileURLWithPath: localFileName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: localFileName).pathExtension
        return "\(stem).original.\(ext)"
    }

    /// Files that, if one of them is on disk beside the score, IS this item's untouched import. Only reachable for a
    /// MusicXML / MXL / MIDI import whose first edit wrote a sibling `.mscz` and left the source behind — before this
    /// feature that orphan was a leak; here it is the original. PDF is excluded: `sourcePDFFileName` owns that file.
    ///
    /// Canonical extensions only, because `localFileName == "<id>.<canonical-extension>"` is enforced at import.
    public var adoptableSourceFileNames: [String] {
        let stem = URL(fileURLWithPath: localFileName).deletingPathExtension().lastPathComponent
        return [ScoreFormat.musicXML, .mxl, .midi].map { "\(stem).\($0.canonicalExtension)" }
    }

    public var canRevertToOriginal: Bool {
        originalFileName != nil
    }

    /// The row once an original has been captured. Nothing else about the item changes — capture happens *before* the
    /// write that would make it necessary, so no content-derived field has moved yet.
    public func capturingOriginal(
        fileName: String,
        contentHash: String,
        provenance: OriginalProvenance,
    ) -> ScoreItem {
        var copy = self
        copy.originalFileName = fileName
        copy.originalContentHash = contentHash
        copy.originalProvenance = provenance
        return copy
    }
}
```

- [ ] **Step 5b: Carry the three columns through `rebuilt`**

`ScoreItem+PDFConversion.swift`'s private `rebuilt(...)` reconstructs the row through the memberwise initializer, so anything it does not name **silently resets to the default** — which for the three new columns means a PDF re-read or a failed-conversion stamp would erase a captured original while leaving its sidecar on disk, where `filesBackingRow` can no longer find it. Add to the `ScoreItem(...)` call at the end of `rebuilt`, after `pdfConversionFailed:`:

```swift
            originalFileName: originalFileName,
            originalContentHash: originalContentHash,
            originalProvenance: originalProvenance,
```

This is the same class of bug the existing `// Adopt the cleared value wholesale rather than copying field by field` comment in `ReaderViewModel+PDFReread.swift` was written about.

- [ ] **Step 6: Add the planner**

Create `Packages/Domain/Sources/Domain/Logic/OriginalCapture.swift`:

```swift
import Foundation

/// What to do about the original immediately before a write would overwrite the score file.
public enum OriginalCapturePlan: Hashable, Sendable {
    /// Nothing to do: already captured, or this item's file is not one the editor can overwrite.
    case none
    /// Register a file that is already on disk. No bytes are copied, so this cannot fail halfway.
    case adopt(fileName: String, provenance: OriginalProvenance)
    /// Copy the item's current file to `sidecarFileName` first.
    case copy(sidecarFileName: String, provenance: OriginalProvenance)
}

/// Decides that plan. Pure, so iOS and Android cannot disagree about when an original is taken or what it is called.
public enum OriginalCapture {
    /// - Parameter adoptableSourceFileName: the first of `item.adoptableSourceFileNames` the caller found on disk, or
    ///   `nil`. Finding one is stronger evidence than any stored provenance — it is a file the editor has never been
    ///   able to write — so it wins over a `legacyUnknown` pre-stamp.
    public static func plan(
        for item: ScoreItem,
        adoptableSourceFileName: String?,
    ) -> OriginalCapturePlan {
        guard item.originalFileName == nil else { return .none }
        guard let format = ScoreFormat.detect(filename: item.localFileName) else { return .none }
        // An item still displayed as a PDF has no notation to edit, so nothing can overwrite it.
        if format == .pdf { return .none }
        // A non-MuseScore source is never written over: `saveDestination` sends the edit to a sibling `.mscz`, and
        // `LiveScoreFileGateway.saveScore` cannot encode these formats at all.
        if format != .mscx, format != .mscz {
            return .adopt(fileName: item.localFileName, provenance: .importTime)
        }
        if let adoptableSourceFileName {
            return .adopt(fileName: adoptableSourceFileName, provenance: .importTime)
        }
        return .copy(sidecarFileName: item.originalSidecarFileName, provenance: copyProvenance(for: item))
    }

    private static func copyProvenance(for item: ScoreItem) -> OriginalProvenance {
        if let stamped = item.originalProvenance { return stamped }
        return item.pdfOriginState == .converted ? .conversionOutput : .importTime
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run from `Packages/Domain`:

```
xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/OriginalCaptureTests
```

Expected: PASS, 10 tests.

- [ ] **Step 8: Run the whole Domain suite**

```
xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Expected: PASS. Any failure here is a call site that constructs `ScoreItem` positionally; the three new parameters are trailing and defaulted, so there should be none.

- [ ] **Step 9: Commit**

```bash
git add Packages/Domain
git commit -m "feat(domain): capture planning for a score's original bytes"
```

---

## Task 2: Persistence — migration v18, columns, deletion, duplicates

**Files:**
- Create: `Packages/Infrastructure/Sources/Persistence/Database/Migrations+V18.swift`
- Modify: `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift:29`
- Modify: `Packages/Infrastructure/Sources/Persistence/Database/Migrations+TestSupport.swift:141`
- Modify: `Packages/Infrastructure/Sources/Persistence/Records/ScoreItemRecord.swift`
- Modify: `Packages/Infrastructure/Sources/Persistence/LiveScoreLibraryRepository.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/MigrationV18Tests.swift`

**Interfaces:**
- Consumes: `OriginalProvenance`, `ScoreItem.originalFileName` / `.originalContentHash` / `.originalProvenance` from Task 1.
- Produces: columns `original_file_name`, `original_content_hash`, `original_provenance` on `score_items`; `AppMigrations.upToV17`; `filesBackingRow` including the original; `scoreItems(matchingContentHash:)` matching it.

- [ ] **Step 1: Write the failing tests**

Create `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/MigrationV18Tests.swift`:

```swift
import Foundation
import GRDB
@testable import Persistence
import Testing

/// v18 adds the three original-bytes columns and pre-stamps the rows whose original can never be recovered:
/// a MuseScore file the editor may already have overwritten. Every other shape is left `NULL` so capture can
/// classify it from better evidence later.
@Suite("Migration v18")
struct MigrationV18Tests {
    private func database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppMigrations.upToV17.migrate(queue)
        return queue
    }

    private func insert(
        _ db: Database,
        id: String,
        localFileName: String,
        contentHash: String = "h",
        pdfDerivedContentHash: String? = nil,
    ) throws {
        try db.execute(sql: """
        INSERT INTO score_items (id, title, local_file_name, content_hash, size_bytes,
                                  length_beats, default_tempo_bpm, added_at, pdf_derived_content_hash)
        VALUES (?, 't', ?, ?, 0, 0, 120, 0, ?)
        """, arguments: [id, localFileName, contentHash, pdfDerivedContentHash])
    }

    private func provenance(_ queue: DatabaseQueue, id: String) throws -> String? {
        try queue.read { db in
            try String.fetchOne(db, sql: "SELECT original_provenance FROM score_items WHERE id = ?", arguments: [id])
        }
    }

    @Test func `a plain mscz import is stamped legacy unknown`() throws {
        let queue = try database()
        try queue.write { db in try insert(db, id: "a", localFileName: "a.mscz") }
        try AppMigrations.all.migrate(queue)
        #expect(try provenance(queue, id: "a") == "legacyUnknown")
    }

    @Test func `an mscx import is stamped legacy unknown`() throws {
        let queue = try database()
        try queue.write { db in try insert(db, id: "a", localFileName: "a.mscx") }
        try AppMigrations.all.migrate(queue)
        #expect(try provenance(queue, id: "a") == "legacyUnknown")
    }

    @Test func `a musicxml import is left unstamped`() throws {
        let queue = try database()
        try queue.write { db in try insert(db, id: "a", localFileName: "a.musicxml") }
        try AppMigrations.all.migrate(queue)
        #expect(try provenance(queue, id: "a") == nil)
    }

    @Test func `an unedited converted pdf is left unstamped`() throws {
        let queue = try database()
        try queue.write { db in
            try insert(db, id: "a", localFileName: "a.mscz", contentHash: "h", pdfDerivedContentHash: "h")
        }
        try AppMigrations.all.migrate(queue)
        #expect(try provenance(queue, id: "a") == nil)
    }

    @Test func `an already-edited converted pdf is stamped legacy unknown`() throws {
        let queue = try database()
        try queue.write { db in
            try insert(db, id: "a", localFileName: "a.mscz", contentHash: "edited", pdfDerivedContentHash: "fresh")
        }
        try AppMigrations.all.migrate(queue)
        #expect(try provenance(queue, id: "a") == "legacyUnknown")
    }

    @Test func `the file name and hash columns start empty`() throws {
        let queue = try database()
        try queue.write { db in try insert(db, id: "a", localFileName: "a.mscz") }
        try AppMigrations.all.migrate(queue)
        let (name, hash): (String?, String?) = try queue.read { db in
            let row = try #require(try Row.fetchOne(
                db,
                sql: "SELECT original_file_name, original_content_hash FROM score_items WHERE id = 'a'",
            ))
            return (row[0], row[1])
        }
        #expect(name == nil)
        #expect(hash == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run from `Packages/Infrastructure`:

```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/MigrationV18Tests
```

Expected: FAIL — `type 'AppMigrations' has no member 'upToV17'`.

- [ ] **Step 3: Write the migration**

Create `Packages/Infrastructure/Sources/Persistence/Database/Migrations+V18.swift`:

```swift
import GRDB

extension AppMigrations {
    // MARK: - v18

    /// Adds the three columns that name, hash, and classify a score's original bytes.
    ///
    /// The interesting half is the pre-stamp. Capture is lazy — it takes the file immediately before the first edit
    /// overwrites it — which is exactly right for a row imported after this shipped, and wrong for one imported
    /// before it: the editor may already have overwritten the import bytes, and nothing in the schema records
    /// whether it did. So a `.mscx`/`.mscz` row is stamped `legacyUnknown` here, and capture keeps that value,
    /// which is what puts a caveat on that item's confirmation dialog.
    ///
    /// Every other shape is deliberately left `NULL`, because better evidence exists later:
    ///   * a row whose file is still MusicXML / MXL / MIDI has never been saved by the editor — a save would have
    ///     switched `local_file_name` to `.mscz` — so its file IS the import;
    ///   * a converted PDF whose `content_hash` still equals `pdf_derived_content_hash` is unedited, and capture
    ///     will class it `conversionOutput`;
    ///   * a `.mscz` row with an orphaned MusicXML sibling on disk is recovered at capture time, which is where the
    ///     scores directory is reachable — a migration only gets a `Database`.
    static func migrateV18(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE score_items ADD COLUMN original_file_name TEXT")
        try db.execute(sql: "ALTER TABLE score_items ADD COLUMN original_content_hash TEXT")
        try db.execute(sql: "ALTER TABLE score_items ADD COLUMN original_provenance TEXT")
        try db.execute(sql: """
        UPDATE score_items
        SET original_provenance = 'legacyUnknown'
        WHERE (LOWER(local_file_name) LIKE '%.mscz' OR LOWER(local_file_name) LIKE '%.mscx')
          AND (pdf_derived_content_hash IS NULL OR pdf_derived_content_hash <> content_hash)
        """)
    }
}
```

- [ ] **Step 4: Register v18 and add `upToV17`**

In `Migrations.swift`, after line 29 (`m.registerMigration("v17", …)`):

```swift
        m.registerMigration("v18", migrate: migrateV18)
```

Extend the header comment on line 3-6 to mention `Migrations+V18.swift` alongside v16 and v17.

In `Migrations+TestSupport.swift`, after the `upToV16` block (line 141), add:

```swift
    /// Migrator that registers v1 … v17 only — useful for tests that want to exercise the v18 upgrade against rows
    /// already inserted at the previous schema.
    static let upToV17: DatabaseMigrator = {
        var m = upToV16
        m.registerMigration("v17", migrate: migrateV17)
        return m
    }()
```

- [ ] **Step 5: Run the migration tests to verify they pass**

```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/MigrationV18Tests
```

Expected: PASS, 6 tests.

- [ ] **Step 6: Map the columns on the record**

In `ScoreItemRecord.swift`, add after `var pdfConversionFailed: Bool`:

```swift
    var originalFileName: String?
    var originalContentHash: String?
    var originalProvenance: String?
```

Add to `CodingKeys`:

```swift
        case originalFileName = "original_file_name"
        case originalContentHash = "original_content_hash"
        case originalProvenance = "original_provenance"
```

Add to `init(domain:)`:

```swift
        originalFileName = item.originalFileName
        originalContentHash = item.originalContentHash
        originalProvenance = item.originalProvenance?.rawValue
```

Add to the `ScoreItem(...)` call in `toDomain(tagIDs:)`, after `pdfConversionFailed:`:

```swift
            originalFileName: originalFileName,
            originalContentHash: originalContentHash,
            originalProvenance: originalProvenance.flatMap(OriginalProvenance.init(rawValue:)),
```

An unrecognised raw value decodes as `nil` rather than throwing, matching how the other record decoders treat an unreadable column: a row the app can otherwise open must not fail the whole read.

- [ ] **Step 7: Write the failing repository tests**

Append to `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/MigrationV18Tests.swift` — no, create a separate suite. Create `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ScoreItemOriginalColumnsTests.swift`:

```swift
import Domain
import Foundation
import GRDB
@testable import Persistence
import Testing

@Suite("score_items original columns")
struct ScoreItemOriginalColumnsTests {
    private func item(originalFileName: String?, originalContentHash: String?) -> ScoreItem {
        var item = ScoreItem(
            title: "t",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: "ID.mscz",
            contentHash: "current",
            sizeBytes: 1,
            lengthBeats: 1,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
        item.originalFileName = originalFileName
        item.originalContentHash = originalContentHash
        item.originalProvenance = originalFileName == nil ? nil : .importTime
        return item
    }

    @Test func `the record round-trips the three columns`() throws {
        let subject = item(originalFileName: "ID.original.mscz", originalContentHash: "orig")
        let record = ScoreItemRecord(domain: subject)
        let restored = try record.toDomain(tagIDs: [])
        #expect(restored.originalFileName == "ID.original.mscz")
        #expect(restored.originalContentHash == "orig")
        #expect(restored.originalProvenance == .importTime)
    }

    @Test func `an unrecognised provenance decodes as nil`() throws {
        var record = ScoreItemRecord(domain: item(originalFileName: "ID.original.mscz", originalContentHash: "o"))
        record.originalProvenance = "somethingElse"
        #expect(try record.toDomain(tagIDs: []).originalProvenance == nil)
    }

    @Test func `every file backing a row is listed for deletion`() throws {
        var record = ScoreItemRecord(domain: item(originalFileName: "ID.original.mscz", originalContentHash: "o"))
        record.sourcePDFFileName = "ID.pdf"
        let files = LiveScoreLibraryRepository.filesBackingRow(record)
        #expect(Set(files) == ["ID.mscz", "ID.pdf", "ID.original.mscz"])
    }

    @Test func `an original that is the item's own file is not listed twice`() throws {
        var record = ScoreItemRecord(domain: item(originalFileName: nil, originalContentHash: nil))
        record.originalFileName = "ID.mscz"
        #expect(LiveScoreLibraryRepository.filesBackingRow(record) == ["ID.mscz"])
    }
}
```

- [ ] **Step 8: Run them to verify they fail**

```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/ScoreItemOriginalColumnsTests
```

Expected: FAIL — `filesBackingRow` is `private`, and it does not return the original.

- [ ] **Step 9: Extend `filesBackingRow` and duplicate detection**

In `LiveScoreLibraryRepository.swift`, change `filesBackingRow` from `private` to `internal` (the tests reach it; nothing outside the module does) and add the original:

```swift
    /// Every file in the scores directory that belongs to a row. Usually just the score, but an item folino read out
    /// of a PDF also owns the original sidecar — leaving that behind would silently retain the largest file of an
    /// item the user deleted — and an edited item owns the copy of the bytes it was imported with.
    nonisolated static func filesBackingRow(_ row: ScoreItemRecord) -> [String] {
        var names = [row.localFileName]
        if let sidecar = row.sourcePDFFileName, sidecar != row.localFileName {
            names.append(sidecar)
        }
        // For a MusicXML / MIDI import the original IS a file the row already names elsewhere in the general case,
        // so de-duplicate rather than assuming a distinct sidecar.
        if let original = row.originalFileName, !names.contains(original) {
            names.append(original)
        }
        return names
    }
```

In `scoreItems(matchingContentHash:)`, extend the filter and its comment:

```swift
                // Trashed rows are excluded so duplicate detection treats them as gone. The original PDF's hash counts
                // too: once a PDF has been read into notation the row's own `content_hash` is the `.mscz`'s, so
                // matching only that would let the same PDF be imported a second time. The captured original's hash
                // counts for the same reason once a score has been edited.
                let records = try ScoreItemRecord
                    .filter(
                        (
                            Column("content_hash") == contentHash
                                || Column("source_pdf_content_hash") == contentHash
                                || Column("original_content_hash") == contentHash
                        )
                            && Column("deleted_at") == nil,
                    )
                    .fetchAll(db)
```

`LiveScoreLibraryRepository.swift` is 397 lines before this step and SwiftLint warns at 400. If the additions push it over, move `scoreItems(matchingContentHash:)` into a new `LiveScoreLibraryRepository+Duplicates.swift` rather than adding a file-level disable — the file already does several unrelated jobs.

- [ ] **Step 10: Run the full Infrastructure suite**

```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Expected: PASS.

- [ ] **Step 11: Commit**

```bash
git add Packages/Infrastructure Packages/Domain
git commit -m "feat(persistence): v18 columns for a score's original bytes"
```

---

## Task 3: The `ScoreOriginalStore` seam and capture

**Files:**
- Create: `Packages/Domain/Sources/Domain/Protocols/ScoreOriginalStore.swift`
- Create: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreOriginalStore.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreOriginalStoreCaptureTests.swift`

**Interfaces:**
- Consumes: `OriginalCapture.plan(for:adoptableSourceFileName:)`, `ScoreItem.capturingOriginal(fileName:contentHash:provenance:)`, `ScoreItem.adoptableSourceFileNames` from Task 1.
- Produces:
  - `protocol ScoreOriginalStore: Sendable` with
    `func captureOriginalIfNeeded(for item: ScoreItem) async throws -> ScoreItem`
    and `func revertToOriginal(_ item: ScoreItem, restoringScoreInfo: Bool) async throws -> ScoreItem`
    and `func discardOriginal(for item: ScoreItem) async throws -> ScoreItem`
  - `struct LiveScoreOriginalStore: ScoreOriginalStore` with `init(scoresDirectory: URL, gateway: any ScoreFileGateway)`

`revertToOriginal` is implemented in Task 7 and `discardOriginal` in Task 8; this task declares all three and implements capture, so the protocol is not reshaped twice.

- [ ] **Step 1: Write the failing tests**

Create `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreOriginalStoreCaptureTests.swift`:

```swift
import CryptoKit
import Domain
import Foundation
@testable import ScoreFiles
import Testing

@Suite("LiveScoreOriginalStore capture")
struct LiveScoreOriginalStoreCaptureTests {
    private func makeDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "original-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func item(localFileName: String) -> ScoreItem {
        ScoreItem(
            title: "t",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: localFileName,
            contentHash: "current",
            sizeBytes: 1,
            lengthBeats: 1,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
    }

    @Test func `an mscz import is copied to a sidecar with its hash recorded`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data("imported".utf8)
        try bytes.write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: FakeGateway())

        let captured = try await store.captureOriginalIfNeeded(for: item(localFileName: "ID.mscz"))

        #expect(captured.originalFileName == "ID.original.mscz")
        #expect(captured.originalContentHash == hex(bytes))
        #expect(captured.originalProvenance == .importTime)
        #expect(try Data(contentsOf: dir.appending(path: "ID.original.mscz")) == bytes)
    }

    @Test func `a second capture leaves the first sidecar alone`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data("imported".utf8)
        try original.write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: FakeGateway())

        let first = try await store.captureOriginalIfNeeded(for: item(localFileName: "ID.mscz"))
        try Data("edited".utf8).write(to: dir.appending(path: "ID.mscz"))
        let second = try await store.captureOriginalIfNeeded(for: first)

        #expect(second.originalContentHash == first.originalContentHash)
        #expect(try Data(contentsOf: dir.appending(path: "ID.original.mscz")) == original)
    }

    /// The failure a database flag would have caused: the row's capture never got written, but the score file was
    /// already overwritten. Keying off the sidecar means the second attempt finds it and does not re-copy.
    @Test func `a capture whose row update was lost does not overwrite the sidecar`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data("imported".utf8)
        try original.write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: FakeGateway())

        _ = try await store.captureOriginalIfNeeded(for: item(localFileName: "ID.mscz"))
        // Simulate the kill: the returned item is thrown away, and the file is overwritten by the edit that follows.
        try Data("edited".utf8).write(to: dir.appending(path: "ID.mscz"))

        let recovered = try await store.captureOriginalIfNeeded(for: item(localFileName: "ID.mscz"))

        #expect(recovered.originalContentHash == hex(original))
        #expect(try Data(contentsOf: dir.appending(path: "ID.original.mscz")) == original)
    }

    @Test func `a musicxml import adopts its own file and copies nothing`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data("<score-partwise/>".utf8)
        try bytes.write(to: dir.appending(path: "ID.musicxml"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: FakeGateway())

        let captured = try await store.captureOriginalIfNeeded(for: item(localFileName: "ID.musicxml"))

        #expect(captured.originalFileName == "ID.musicxml")
        #expect(captured.originalContentHash == hex(bytes))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "ID.original.musicxml").path) == false)
    }

    @Test func `an orphaned musicxml beside an mscz is adopted instead of copied`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let orphan = Data("<score-partwise/>".utf8)
        try orphan.write(to: dir.appending(path: "ID.musicxml"))
        try Data("edited".utf8).write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: FakeGateway())
        var subject = item(localFileName: "ID.mscz")
        subject.originalProvenance = .legacyUnknown

        let captured = try await store.captureOriginalIfNeeded(for: subject)

        #expect(captured.originalFileName == "ID.musicxml")
        #expect(captured.originalProvenance == .importTime)
        #expect(captured.originalContentHash == hex(orphan))
    }

    @Test func `an item with no file on disk is returned untouched`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: FakeGateway())

        let captured = try await store.captureOriginalIfNeeded(for: item(localFileName: "ID.mscz"))

        #expect(captured.originalFileName == nil)
    }
}

/// Minimal `ScoreFileGateway` double. Capture never parses, so every member throws; the revert tests replace this.
private struct FakeGateway: ScoreFileGateway {
    func detectFormat(fileName: String) -> ScoreFormat? { ScoreFormat.detect(filename: fileName) }
    func loadFileMetadata(fileURL _: URL) async throws -> ScoreFileSummary {
        throw DomainError.unsupportedFormat("test")
    }

    func loadScore(fileURL _: URL) async throws -> (score: Score, summary: ScoreFileSummary) {
        throw DomainError.unsupportedFormat("test")
    }

    func saveScore(_: Score, fileURL _: URL, format _: ScoreFormat) async throws {
        throw DomainError.unsupportedFormat("test")
    }
}
```

- [ ] **Step 2: Run to verify failure**

```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/LiveScoreOriginalStoreCaptureTests
```

Expected: FAIL — `cannot find 'LiveScoreOriginalStore' in scope`.

- [ ] **Step 3: Declare the protocol**

Create `Packages/Domain/Sources/Domain/Protocols/ScoreOriginalStore.swift`:

```swift
import Foundation

/// Keeps and restores the bytes a score was imported with.
///
/// One seam for three callers that must not disagree: the Editor captures before its first write, the Reader
/// restores and reloads, and the score-info sheet restores from wherever it was opened. Everything that decides
/// *what* to do is a pure function in this module; an implementation of this protocol only performs it.
public protocol ScoreOriginalStore: Sendable {
    /// Copies (or adopts) the item's current file as its original, unless one is already recorded. Returns the item
    /// to persist — unchanged when nothing was captured. Never throws for a missing file: an item whose bytes are
    /// gone has bigger problems than a missing original, and failing here would block the save that follows.
    func captureOriginalIfNeeded(for item: ScoreItem) async throws -> ScoreItem

    /// Writes the original's bytes back over the item's file and returns the row that describes the result. Content
    /// -derived fields always come from a fresh parse of those bytes; the credit fields do only when
    /// `restoringScoreInfo` is true.
    func revertToOriginal(_ item: ScoreItem, restoringScoreInfo: Bool) async throws -> ScoreItem

    /// Forgets the recorded original, deleting the sidecar if the original is one. For a re-read, which replaces the
    /// notation the original was the baseline of.
    func discardOriginal(for item: ScoreItem) async throws -> ScoreItem
}
```

- [ ] **Step 4: Implement capture**

Create `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreOriginalStore.swift`:

```swift
import CryptoKit
import Domain
import Foundation

/// File-side half of `ScoreOriginalStore`. Every decision it makes comes from `OriginalCapture` / `RevertPolicy` in
/// Domain; this type only moves bytes and rebuilds the row.
public struct LiveScoreOriginalStore: ScoreOriginalStore {
    private let scoresDirectory: URL
    private let gateway: any ScoreFileGateway

    public init(scoresDirectory: URL, gateway: any ScoreFileGateway) {
        self.scoresDirectory = scoresDirectory
        self.gateway = gateway
    }

    public func captureOriginalIfNeeded(for item: ScoreItem) async throws -> ScoreItem {
        let plan = OriginalCapture.plan(for: item, adoptableSourceFileName: adoptableSourceFileName(for: item))
        switch plan {
        case .none:
            return item
        case let .adopt(fileName, provenance):
            guard let facts = try? Self.hashAndSize(of: scoresDirectory.appending(path: fileName)) else {
                return item
            }
            return item.capturingOriginal(
                fileName: fileName,
                contentHash: facts.contentHash,
                provenance: provenance,
            )
        case let .copy(sidecarFileName, provenance):
            let source = scoresDirectory.appending(path: item.localFileName)
            let destination = scoresDirectory.appending(path: sidecarFileName)
            // The sidecar's existence is the marker, so re-check it here rather than trusting the row: a capture
            // whose row update was lost must find the file and adopt it, not copy the edited bytes over it.
            if !FileManager.default.fileExists(atPath: destination.path) {
                guard (try? Self.copyAtomically(from: source, to: destination)) != nil else { return item }
            }
            guard let facts = try? Self.hashAndSize(of: destination) else { return item }
            return item.capturingOriginal(
                fileName: sidecarFileName,
                contentHash: facts.contentHash,
                provenance: provenance,
            )
        }
    }

    /// The first candidate that is actually on disk — an untouched import file left beside an edited `.mscz`.
    private func adoptableSourceFileName(for item: ScoreItem) -> String? {
        item.adoptableSourceFileNames.first {
            FileManager.default.fileExists(atPath: scoresDirectory.appending(path: $0).path)
        }
    }

    /// Copies through a scratch name and renames, so a kill mid-copy cannot leave a truncated file sitting at the
    /// sidecar's path — where the existence check would then trust it.
    private static func copyAtomically(from source: URL, to destination: URL) throws {
        let scratch = destination.deletingLastPathComponent()
            .appending(path: "\(destination.lastPathComponent).capturing")
        try? FileManager.default.removeItem(at: scratch)
        try FileManager.default.copyItem(at: source, to: scratch)
        try FileManager.default.moveItem(at: scratch, to: destination)
    }

    /// SHA-256 + size, in the importer's hex-digest format. Same shape as `EditorFileFacts.hashAndSize`, which stays
    /// where it is: the Editor cannot import Infrastructure.
    static func hashAndSize(of url: URL) throws -> (contentHash: String, sizeBytes: Int64) {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var total: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }

    public func revertToOriginal(_ item: ScoreItem, restoringScoreInfo _: Bool) async throws -> ScoreItem {
        // Implemented in Task 7.
        item
    }

    public func discardOriginal(for item: ScoreItem) async throws -> ScoreItem {
        // Implemented in Task 8.
        item
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/LiveScoreOriginalStoreCaptureTests
```

Expected: PASS, 6 tests.

- [ ] **Step 6: Commit**

```bash
git add Packages/Domain Packages/Infrastructure
git commit -m "feat(infrastructure): capture a score's original bytes before the first edit"
```

---

## Task 4: Capture at the Editor's write choke point

> **Execute Tasks 4 and 5 as one unit and commit once.** Task 4 makes `originalStore` a required initializer argument, which leaves the App target unable to compile until Task 5's wiring lands. Task 4's own verification only runs the Editor scheme, so the breakage would not surface until much later.

**Files:**
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift`
- Create: `Packages/Features/Editor/Sources/Editor/NoopScoreOriginalStore.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/Views/EditorPadView.swift:206`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Persistence.swift`
- Test: `Packages/Features/Editor/Tests/EditorTests/EditorViewModelPersistenceTests.swift`
- Test: `Packages/Features/Editor/Tests/EditorTests/Support/Fakes.swift`

**Interfaces:**
- Consumes: `ScoreOriginalStore.captureOriginalIfNeeded(for:)` from Task 3.
- Produces: `EditorViewModel.init(scoreItem:scoresDirectory:gateway:repository:originalStore:playback:)` — a new `originalStore: any ScoreOriginalStore` parameter placed before `playback`.

- [ ] **Step 0: Add a no-op store the Editor's own previews can use**

`PreviewEditorFactory.makeViewModel` in `Views/EditorPadView.swift:206` builds an `EditorViewModel` from **source**, not from the test target, so it cannot reach the test fake — without this the Editor package stops compiling. Create `Packages/Features/Editor/Sources/Editor/NoopScoreOriginalStore.swift`:

```swift
import Domain
import Foundation

/// Does nothing, for previews. A preview never writes, so it never needs an original.
struct NoopScoreOriginalStore: ScoreOriginalStore {
    // swiftlint:disable:next async_without_await
    func captureOriginalIfNeeded(for item: ScoreItem) async throws -> ScoreItem { item }
    // swiftlint:disable:next async_without_await
    func revertToOriginal(_ item: ScoreItem, restoringScoreInfo _: Bool) async throws -> ScoreItem { item }
    // swiftlint:disable:next async_without_await
    func discardOriginal(for item: ScoreItem) async throws -> ScoreItem { item }
}
```

The `async_without_await` rule is opt-in-enabled in this repo's `.swiftlint.yml`; every `async` member that never awaits needs the disable comment. Apply the same to the `FakeGateway` / `StubGateway` doubles introduced in Tasks 3 and 7, and to the stubbed store members in `LiveScoreOriginalStore` until Tasks 7 and 8 fill them in.

Then pass `originalStore: NoopScoreOriginalStore(),` at `EditorPadView.swift:206`.

- [ ] **Step 1: Add a fake store to the test support file**

In `Packages/Features/Editor/Tests/EditorTests/Support/Fakes.swift`, append:

```swift
/// Records what the view model asked for and hands back an item stamped as captured, so the save path's ordering
/// can be asserted without touching the file system.
final class FakeScoreOriginalStore: ScoreOriginalStore, @unchecked Sendable {
    var captureCalls: [ScoreItem] = []
    var revertCalls: [(ScoreItem, Bool)] = []

    func captureOriginalIfNeeded(for item: ScoreItem) async throws -> ScoreItem {
        captureCalls.append(item)
        guard item.originalFileName == nil else { return item }
        return item.capturingOriginal(
            fileName: item.originalSidecarFileName,
            contentHash: "captured-hash",
            provenance: .importTime,
        )
    }

    func revertToOriginal(_ item: ScoreItem, restoringScoreInfo: Bool) async throws -> ScoreItem {
        revertCalls.append((item, restoringScoreInfo))
        return item
    }

    func discardOriginal(for item: ScoreItem) async throws -> ScoreItem { item }
}
```

- [ ] **Step 2: Write the failing tests**

In `EditorViewModelPersistenceTests.swift`, add to the `performSave` section:

```swift
    @Test func `the first save captures the original before writing`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gateway = FakeScoreFileGateway()
        let repository = FakeScoreLibraryRepository()
        let originalStore = FakeScoreOriginalStore()
        let vm = EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: dir,
            gateway: gateway,
            repository: repository,
            originalStore: originalStore,
            playback: nil,
        )
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.applyCommand(InputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14))

        await vm.flushPendingSave()

        #expect(originalStore.captureCalls.count == 1)
        let saved = try #require(repository.savedScoreItems.first)
        #expect(saved.originalFileName == "score.original.mscz")
        #expect(saved.originalContentHash == "captured-hash")
        #expect(vm.scoreItem.originalFileName == "score.original.mscz")
    }

    @Test func `the capture is asked for before the gateway writes`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gateway = FakeScoreFileGateway()
        let repository = FakeScoreLibraryRepository()
        let originalStore = FakeScoreOriginalStore()
        let vm = EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: dir,
            gateway: gateway,
            repository: repository,
            originalStore: originalStore,
            playback: nil,
        )
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.applyCommand(InputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14))

        await vm.flushPendingSave()

        // The store saw an item that had not been written yet; the gateway ran afterwards.
        #expect(originalStore.captureCalls.first?.originalFileName == nil)
        #expect(gateway.savedCalls.count == 1)
    }

    @Test func `a clean flush never asks for a capture`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let originalStore = FakeScoreOriginalStore()
        let vm = EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: dir,
            gateway: FakeScoreFileGateway(),
            repository: FakeScoreLibraryRepository(),
            originalStore: originalStore,
            playback: nil,
        )
        vm.beginSession(score: EditorFixtures.fourQuarterRests())

        await vm.flushPendingSave()

        #expect(originalStore.captureCalls.isEmpty)
    }
```

Update every other `EditorViewModel(` construction in the Editor test target to pass `originalStore: FakeScoreOriginalStore(),` before `playback:`.

- [ ] **Step 3: Run to verify failure**

Run from `Packages/Features/Editor`:

```
xcodebuild test -scheme Editor -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:EditorTests/EditorViewModelPersistenceTests
```

Expected: FAIL — `extra argument 'originalStore' in call`.

- [ ] **Step 4: Add the dependency**

In `EditorViewModel.swift`, beside the other injected dependencies:

```swift
    @ObservationIgnored let originalStore: any ScoreOriginalStore
    /// Mirrors `scoreItem.canRevertToOriginal` as an OBSERVED property. `scoreItem` is `@ObservationIgnored`, so a
    /// toolbar reading it directly would not re-evaluate when the session's first autosave captures the original —
    /// the `⋯` item would not appear until the chrome happened to rebuild for some other reason.
    public internal(set) var hasCapturedOriginal: Bool
```

and in `init`, a parameter `originalStore: any ScoreOriginalStore,` placed after `repository:` and before `playback:`, with `self.originalStore = originalStore` and `hasCapturedOriginal = scoreItem.canRevertToOriginal` in the body.

`internal(set)`, not `private(set)`: the operations live in same-type extensions in other files, which `private` does not reach — the existing declarations at `EditorViewModel.swift:74-80` carry a comment saying exactly this. For the same reason, change `editor` on line 14 from `public private(set)` to `public internal(set)`; Task 9's revert path clears it from `EditorViewModel+Revert.swift`.

- [ ] **Step 5: Capture inside `performSave`**

In `EditorViewModel+Persistence.swift`, replace the body of `performSave()` up to the `saveScore` call:

```swift
    private func performSave() async {
        guard let score, isDirty else { return }
        let destination = Self.saveDestination(for: scoreItem, scoresDirectory: scoresDirectory)
        // BEFORE the write, and only here: this is the last moment the file still holds the bytes the score was
        // imported with. Editing metadata does not touch the file, so nothing earlier can have moved them. A capture
        // that fails returns the item unchanged rather than throwing, so a full disk costs the original, not the edit.
        let itemToSave = (try? await originalStore.captureOriginalIfNeeded(for: scoreItem)) ?? scoreItem
        do {
            try await gateway.saveScore(score, fileURL: destination.url, format: destination.format)
            let facts = try EditorFileFacts.hashAndSize(of: destination.url)
            let newItem = ScoreItem(
                id: itemToSave.id,
                title: itemToSave.title,
                subtitle: itemToSave.subtitle,
                composer: itemToSave.composer,
                arranger: itemToSave.arranger,
                lyricist: itemToSave.lyricist,
                copyright: itemToSave.copyright,
                instrumentationSummary: itemToSave.instrumentationSummary,
                localFileName: destination.isSiblingCopy
                    ? destination.url.lastPathComponent
                    : itemToSave.localFileName,
                contentHash: facts.contentHash,
                sizeBytes: facts.sizeBytes,
                lengthBeats: itemToSave.lengthBeats,
                defaultTempoBpm: itemToSave.defaultTempoBpm,
                primaryKey: itemToSave.primaryKey,
                addedAt: itemToSave.addedAt,
                lastOpenedAt: itemToSave.lastOpenedAt,
                tagIDs: itemToSave.tagIDs,
                isFavorite: itemToSave.isFavorite,
                deletedAt: itemToSave.deletedAt,
                museScoreMajorVersion: itemToSave.museScoreMajorVersion,
                sourcePDFFileName: itemToSave.sourcePDFFileName,
                sourcePDFContentHash: itemToSave.sourcePDFContentHash,
                pdfDerivedContentHash: itemToSave.pdfDerivedContentHash,
                pdfConversionFailed: itemToSave.pdfConversionFailed,
                originalFileName: itemToSave.originalFileName,
                originalContentHash: itemToSave.originalContentHash,
                originalProvenance: itemToSave.originalProvenance,
            )
```

Leave the rest of the method (`repository.saveScoreItem`, the sibling flag, `isDirty = false`, the swallowing `catch`) as it is, and add one line beside `scoreItem = newItem`:

```swift
            hasCapturedOriginal = newItem.canRevertToOriginal
```

**Two things in this rewrite are deliberate; do not "simplify" them away.**

First, every field now reads from `itemToSave` rather than `scoreItem`, which is what carries the capture forward — reverting any of them to `scoreItem` silently discards it.

Second, the four PDF-origin fields (`sourcePDFFileName`, `sourcePDFContentHash`, `pdfDerivedContentHash`, `pdfConversionFailed`) are carried through. **The current code omits them,** so today the first autosave of a PDF-derived score quietly erases its PDF origin: the sidecar stops being deleted with the row, the display-source switch and the re-read disappear, and `isPDFDerivedScoreEdited` starts answering `false`. That is a pre-existing bug this task fixes as a side effect of having to touch the same initializer. Keep the lines.

- [ ] **Step 6: Run the Editor suite**

```
xcodebuild test -scheme Editor -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Expected: PASS.

- [ ] **Step 7: Do not commit yet**

The App target does not compile until Task 5 wires the store in. Continue straight into Task 5 and commit both together.

---

## Task 5: App wiring for capture

> Same commit as Task 4.

**Files:**
- Modify: `App/AppBootstrap.swift:100`
- Modify: `App/AppShellView.swift` (the bootstrap-derived dependencies and `EditableReaderScreen` construction at `:418`)
- Modify: `App/EditableReaderScreen.swift:21-37`

**Interfaces:**
- Consumes: `LiveScoreOriginalStore(scoresDirectory:gateway:)` from Task 3, the new `EditorViewModel` init from Task 4.
- Produces: an `originalStore` threaded from the composition root to the Editor.

- [ ] **Step 1: Build the store in the bootstrap**

In `AppBootstrap.swift`, immediately after the `LiveScoreFileGateway` construction on line 100:

```swift
            let originalStore = LiveScoreOriginalStore(scoresDirectory: scoresDirectory, gateway: gateway)
```

The scores directory is `AppPaths.scoresDirectory`, already used twice in this file around lines 97 and 105.

The store must survive past `start()`, so it is not enough to build a local: give `AppBootstrap` a `private(set) var originalStore: LiveScoreOriginalStore?` alongside the other dependencies it already publishes, and assign it here.

- [ ] **Step 2: Carry it into the shell**

`AppShellView` is what constructs both the Reader and `EditableReaderScreen`, and it receives its dependencies from the bootstrap by hand. Add an `originalStore: any ScoreOriginalStore` stored property and initializer parameter to `AppShellView`, alongside the gateway and repository it already takes, and pass the bootstrap's value at the site that unwraps the bootstrap's dependencies (around `AppShellView.swift:25-27`).

- [ ] **Step 3: Thread it through `EditableReaderScreen`**

Add `originalStore: any ScoreOriginalStore,` to `EditableReaderScreen.init` after `repository:`, and pass it to `EditorViewModel(...)` as `originalStore: originalStore,`.

There is exactly one construction site, `AppShellView.swift:418`. Confirm with:

```bash
grep -rn "EditableReaderScreen(" App --include="*.swift"
```

- [ ] **Step 4: Build the app**

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add App Packages/Features/Editor
git commit -m "feat(editor): capture the original before the first autosave"
```

---

## Task 6: Domain — the revert plan and its warnings

**Files:**
- Create: `Packages/Domain/Sources/Domain/Logic/RevertPolicy.swift`
- Modify: `Packages/Domain/Sources/Domain/Models/ScoreItem+Original.swift`
- Test: `Packages/Domain/Tests/DomainTests/RevertPolicyTests.swift`

**Interfaces:**
- Consumes: Task 1's `ScoreItem` properties.
- Produces:
  - `enum RevertFilePlan: Hashable, Sendable { case restoreSidecar(sidecarFileName: String, over: String), adoptExistingFile(originalFileName: String, deleting: String) }`
  - `enum RevertPolicy { static func filePlan(for: ScoreItem) -> RevertFilePlan?; static func warnings(for: ScoreItem, hasMusicalAnnotations: Bool) -> RevertWarnings }`
  - `struct RevertWarnings: OptionSet, Sendable { static let musicalAnnotationsMayShift; static let originalMayNotBeImportTime }`
  - `struct RevertedOriginalFacts: Hashable, Sendable { let localFileName: String; let contentHash: String; let sizeBytes: Int64; let summary: ScoreFileSummary }`
  - `ScoreItem.adoptingRevertedOriginal(_:restoringScoreInfo:) -> ScoreItem`

- [ ] **Step 1: Write the failing tests**

Create `Packages/Domain/Tests/DomainTests/RevertPolicyTests.swift`:

```swift
@testable import Domain
import Foundation
import Testing

@Suite("Revert policy")
struct RevertPolicyTests {
    private func item(
        localFileName: String,
        originalFileName: String?,
        provenance: OriginalProvenance? = .importTime,
    ) -> ScoreItem {
        var item = ScoreItem(
            title: "Kept Title",
            subtitle: "Kept Subtitle",
            composer: "Kept Composer",
            instrumentationSummary: "Kept Instrumentation",
            localFileName: localFileName,
            contentHash: "current",
            sizeBytes: 10,
            lengthBeats: 10,
            defaultTempoBpm: 100,
            primaryKey: "C",
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: true,
        )
        item.originalFileName = originalFileName
        item.originalContentHash = originalFileName == nil ? nil : "orig"
        item.originalProvenance = originalFileName == nil ? nil : provenance
        return item
    }

    private var summary: ScoreFileSummary {
        ScoreFileSummary(
            title: "File Title",
            subtitle: "File Subtitle",
            composer: "File Composer",
            instrumentationSummary: "File Instrumentation",
            lengthBeats: 99,
            defaultTempoBpm: 88,
            primaryKey: "G",
        )
    }

    // MARK: - filePlan

    @Test func `an item with no original has no plan`() {
        #expect(RevertPolicy.filePlan(for: item(localFileName: "ID.mscz", originalFileName: nil)) == nil)
    }

    @Test func `a sidecar is restored over the item's file`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz")
        #expect(
            RevertPolicy.filePlan(for: subject)
                == .restoreSidecar(sidecarFileName: "ID.original.mscz", over: "ID.mscz"),
        )
    }

    @Test func `a source file is adopted back and the sibling mscz deleted`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.musicxml")
        #expect(
            RevertPolicy.filePlan(for: subject)
                == .adoptExistingFile(originalFileName: "ID.musicxml", deleting: "ID.mscz"),
        )
    }

    // MARK: - warnings

    @Test func `ink anchored to the notation earns a warning`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz")
        #expect(RevertPolicy.warnings(for: subject, hasMusicalAnnotations: true)
            .contains(.musicalAnnotationsMayShift))
    }

    @Test func `no ink means no shift warning`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz")
        #expect(RevertPolicy.warnings(for: subject, hasMusicalAnnotations: false)
            .contains(.musicalAnnotationsMayShift) == false)
    }

    @Test func `a legacy original warns that it may not be the import`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz", provenance: .legacyUnknown)
        #expect(RevertPolicy.warnings(for: subject, hasMusicalAnnotations: false)
            .contains(.originalMayNotBeImportTime))
    }

    @Test func `a conversion output does not carry the legacy caveat`() {
        let subject = item(
            localFileName: "ID.mscz",
            originalFileName: "ID.original.mscz",
            provenance: .conversionOutput,
        )
        #expect(RevertPolicy.warnings(for: subject, hasMusicalAnnotations: false)
            .contains(.originalMayNotBeImportTime) == false)
    }

    // MARK: - adoptingRevertedOriginal

    private var facts: RevertedOriginalFacts {
        RevertedOriginalFacts(
            localFileName: "ID.musicxml",
            contentHash: "orig",
            sizeBytes: 42,
            summary: summary,
        )
    }

    @Test func `content-derived fields always come from the restored file`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.musicxml")
        let reverted = subject.adoptingRevertedOriginal(facts, restoringScoreInfo: false)
        #expect(reverted.localFileName == "ID.musicxml")
        #expect(reverted.contentHash == "orig")
        #expect(reverted.sizeBytes == 42)
        #expect(reverted.lengthBeats == 99)
        #expect(reverted.defaultTempoBpm == 88)
        #expect(reverted.primaryKey == "G")
        #expect(reverted.instrumentationSummary == "File Instrumentation")
    }

    @Test func `credits are kept unless the caller asks for them`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.musicxml")
        let reverted = subject.adoptingRevertedOriginal(facts, restoringScoreInfo: false)
        #expect(reverted.title == "Kept Title")
        #expect(reverted.subtitle == "Kept Subtitle")
        #expect(reverted.composer == "Kept Composer")
    }

    @Test func `credits come from the file when asked for`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.musicxml")
        let reverted = subject.adoptingRevertedOriginal(facts, restoringScoreInfo: true)
        #expect(reverted.title == "File Title")
        #expect(reverted.subtitle == "File Subtitle")
        #expect(reverted.composer == "File Composer")
    }

    @Test func `a file with no title keeps the item's title`() {
        var untitled = facts
        untitled = RevertedOriginalFacts(
            localFileName: facts.localFileName,
            contentHash: facts.contentHash,
            sizeBytes: facts.sizeBytes,
            summary: ScoreFileSummary(
                title: nil,
                composer: nil,
                instrumentationSummary: "x",
                lengthBeats: 1,
                defaultTempoBpm: 1,
                primaryKey: nil,
            ),
        )
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.musicxml")
        #expect(subject.adoptingRevertedOriginal(untitled, restoringScoreInfo: true).title == "Kept Title")
    }

    @Test func `the item forgets its original and keeps the user's own labels`() {
        let subject = item(localFileName: "ID.mscz", originalFileName: "ID.musicxml")
        let reverted = subject.adoptingRevertedOriginal(facts, restoringScoreInfo: true)
        #expect(reverted.originalFileName == nil)
        #expect(reverted.originalContentHash == nil)
        #expect(reverted.originalProvenance == nil)
        #expect(reverted.isFavorite)
        #expect(reverted.addedAt == Date(timeIntervalSince1970: 0))
    }
}
```

- [ ] **Step 2: Run to verify failure**

```
xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/RevertPolicyTests
```

Expected: FAIL — `cannot find 'RevertPolicy' in scope`.

- [ ] **Step 3: Write the policy**

Create `Packages/Domain/Sources/Domain/Logic/RevertPolicy.swift`:

```swift
import Foundation

/// How the original gets back into place.
public enum RevertFilePlan: Hashable, Sendable {
    /// The original is a copy folino took: write it over the item's file, then drop the copy.
    case restoreSidecar(sidecarFileName: String, over: String)
    /// The original is the source file itself, untouched since import: make it the item's file again and delete the
    /// `.mscz` the editor wrote beside it. Nothing is copied, so there is no half-written state to recover from.
    case adoptExistingFile(originalFileName: String, deleting: String)
}

/// What the user is told before a revert.
public struct RevertWarnings: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Ink anchored to the notation is kept, but a stroke written against an edited passage can land elsewhere once
    /// the passage is the original again. Erasing the ink to spare the offset would be the worse failure.
    public static let musicalAnnotationsMayShift = RevertWarnings(rawValue: 1 << 0)
    /// This item predates the feature, so what was captured may already have been edited.
    public static let originalMayNotBeImportTime = RevertWarnings(rawValue: 1 << 1)
}

/// One rule for both platforms, so a destructive action is never softer on one than the other.
public enum RevertPolicy {
    public static func filePlan(for item: ScoreItem) -> RevertFilePlan? {
        guard let originalFileName = item.originalFileName else { return nil }
        // Cannot arise from any state this code writes — a capture that adopts the item's own file is immediately
        // followed by the save that moves `localFileName` to the sibling `.mscz` — but restoring a file over itself
        // and then deleting it would destroy the score, so refuse rather than trust that.
        guard originalFileName != item.localFileName else { return nil }
        if originalFileName == item.originalSidecarFileName {
            return .restoreSidecar(sidecarFileName: originalFileName, over: item.localFileName)
        }
        return .adoptExistingFile(originalFileName: originalFileName, deleting: item.localFileName)
    }

    public static func warnings(for item: ScoreItem, hasMusicalAnnotations: Bool) -> RevertWarnings {
        var warnings: RevertWarnings = []
        if hasMusicalAnnotations { warnings.insert(.musicalAnnotationsMayShift) }
        if item.originalProvenance == .legacyUnknown { warnings.insert(.originalMayNotBeImportTime) }
        return warnings
    }
}
```

- [ ] **Step 4: Add the facts type and the row rebuild**

Append to `Packages/Domain/Sources/Domain/Models/ScoreItem+Original.swift`:

```swift
/// What a restored original turned out to be on disk, plus a fresh parse of it.
public struct RevertedOriginalFacts: Hashable, Sendable {
    public let localFileName: String
    public let contentHash: String
    public let sizeBytes: Int64
    public let summary: ScoreFileSummary

    public init(localFileName: String, contentHash: String, sizeBytes: Int64, summary: ScoreFileSummary) {
        self.localFileName = localFileName
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
        self.summary = summary
    }
}

extension ScoreItem {
    /// The row once the original's bytes are back.
    ///
    /// Content-derived fields are *replaced*, not merged — unlike `adoptingPDFConversion`, which keeps a field the
    /// conversion couldn't supply. Here the file is authoritative by definition: leaving `lengthBeats` describing the
    /// edited version would simply be wrong. Credits are the user's, so they move only when asked, and even then a
    /// file with no title cannot blank a title the item is required to have. Tags, favourite, the trash stamp, the
    /// date added and every PDF-origin field are untouched; reverting to a conversion's output restores
    /// `contentHash == pdfDerivedContentHash` on its own.
    public func adoptingRevertedOriginal(
        _ facts: RevertedOriginalFacts,
        restoringScoreInfo: Bool,
    ) -> ScoreItem {
        let credits = restoringScoreInfo ? facts.summary : nil
        return ScoreItem(
            id: id,
            title: credits?.title ?? title,
            subtitle: restoringScoreInfo ? credits?.subtitle : subtitle,
            composer: restoringScoreInfo ? credits?.composer : composer,
            arranger: restoringScoreInfo ? credits?.arranger : arranger,
            lyricist: restoringScoreInfo ? credits?.lyricist : lyricist,
            copyright: restoringScoreInfo ? credits?.copyright : copyright,
            instrumentationSummary: facts.summary.instrumentationSummary,
            localFileName: facts.localFileName,
            contentHash: facts.contentHash,
            sizeBytes: facts.sizeBytes,
            lengthBeats: facts.summary.lengthBeats,
            defaultTempoBpm: facts.summary.defaultTempoBpm,
            primaryKey: facts.summary.primaryKey,
            addedAt: addedAt,
            lastOpenedAt: lastOpenedAt,
            tagIDs: tagIDs,
            isFavorite: isFavorite,
            deletedAt: deletedAt,
            // No `?? museScoreMajorVersion` fallback, unlike `rebuilt`: reverting a MusicXML import back to its own
            // file must land on `nil`, not keep the version of the `.mscz` the editor wrote over it.
            museScoreMajorVersion: facts.summary.museScoreMajorVersion,
            sourcePDFFileName: sourcePDFFileName,
            sourcePDFContentHash: sourcePDFContentHash,
            pdfDerivedContentHash: pdfDerivedContentHash,
            pdfConversionFailed: pdfConversionFailed,
            originalFileName: nil,
            originalContentHash: nil,
            originalProvenance: nil,
        )
    }
}
```

- [ ] **Step 5: Run to verify the tests pass**

```
xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/RevertPolicyTests
```

Expected: PASS, 12 tests.

- [ ] **Step 6: Commit**

```bash
git add Packages/Domain
git commit -m "feat(domain): revert plan, warnings and row rebuild"
```

---

## Task 7: Infrastructure — perform the revert

**Files:**
- Modify: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreOriginalStore.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreOriginalStoreRevertTests.swift`

**Interfaces:**
- Consumes: `RevertPolicy.filePlan(for:)`, `RevertedOriginalFacts`, `ScoreItem.adoptingRevertedOriginal(_:restoringScoreInfo:)` from Task 6.
- Produces: a working `LiveScoreOriginalStore.revertToOriginal(_:restoringScoreInfo:)`.

- [ ] **Step 1: Write the failing tests**

Create `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreOriginalStoreRevertTests.swift`:

```swift
import CryptoKit
import Domain
import Foundation
@testable import ScoreFiles
import SheetMusic
import Testing

@Suite("LiveScoreOriginalStore revert")
struct LiveScoreOriginalStoreRevertTests {
    private func makeDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "original-revert-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func item(localFileName: String, originalFileName: String) -> ScoreItem {
        var item = ScoreItem(
            title: "Kept",
            composer: "Kept",
            instrumentationSummary: "Kept",
            localFileName: localFileName,
            contentHash: "edited",
            sizeBytes: 6,
            lengthBeats: 1,
            defaultTempoBpm: 60,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
        item.originalFileName = originalFileName
        item.originalContentHash = nil
        item.originalProvenance = .importTime
        return item
    }

    @Test func `a sidecar is written back over the score and then removed`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data("imported".utf8)
        try original.write(to: dir.appending(path: "ID.original.mscz"))
        try Data("edited".utf8).write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())

        let reverted = try await store.revertToOriginal(
            item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz"),
            restoringScoreInfo: false,
        )

        #expect(try Data(contentsOf: dir.appending(path: "ID.mscz")) == original)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "ID.original.mscz").path) == false)
        #expect(reverted.localFileName == "ID.mscz")
        #expect(reverted.contentHash == hex(original))
        #expect(reverted.originalFileName == nil)
    }

    @Test func `a source file becomes the item's file again and the sibling mscz is deleted`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data("<score-partwise/>".utf8)
        try original.write(to: dir.appending(path: "ID.musicxml"))
        try Data("edited".utf8).write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())

        let reverted = try await store.revertToOriginal(
            item(localFileName: "ID.mscz", originalFileName: "ID.musicxml"),
            restoringScoreInfo: false,
        )

        #expect(reverted.localFileName == "ID.musicxml")
        #expect(reverted.contentHash == hex(original))
        #expect(try Data(contentsOf: dir.appending(path: "ID.musicxml")) == original)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "ID.mscz").path) == false)
    }

    @Test func `a missing original leaves the score alone and throws`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let edited = Data("edited".utf8)
        try edited.write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())

        await #expect(throws: DomainError.self) {
            _ = try await store.revertToOriginal(
                item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz"),
                restoringScoreInfo: false,
            )
        }
        #expect(try Data(contentsOf: dir.appending(path: "ID.mscz")) == edited)
    }

    @Test func `an item with no original throws rather than doing nothing quietly`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("edited".utf8).write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())
        var subject = item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz")
        subject.originalFileName = nil

        await #expect(throws: DomainError.self) {
            _ = try await store.revertToOriginal(subject, restoringScoreInfo: false)
        }
    }

    @Test func `an original whose bytes no longer match its recorded hash is refused`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("corrupted".utf8).write(to: dir.appending(path: "ID.original.mscz"))
        try Data("edited".utf8).write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())
        var subject = item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz")
        subject.originalContentHash = hex(Data("imported".utf8))

        await #expect(throws: DomainError.self) {
            _ = try await store.revertToOriginal(subject, restoringScoreInfo: false)
        }
    }

    @Test func `credits come back from the file when asked for`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("imported".utf8).write(to: dir.appending(path: "ID.original.mscz"))
        try Data("edited".utf8).write(to: dir.appending(path: "ID.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())

        let reverted = try await store.revertToOriginal(
            item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz"),
            restoringScoreInfo: true,
        )

        #expect(reverted.title == "Stub Title")
        #expect(reverted.composer == "Stub Composer")
    }
}

/// Returns a fixed summary for any file, so the tests assert the store's plumbing rather than the parser's output.
private struct StubGateway: ScoreFileGateway {
    func detectFormat(fileName: String) -> ScoreFormat? { ScoreFormat.detect(filename: fileName) }

    func loadFileMetadata(fileURL _: URL) async throws -> ScoreFileSummary { Self.summary }

    func loadScore(fileURL _: URL) async throws -> (score: Score, summary: ScoreFileSummary) {
        throw DomainError.unsupportedFormat("test")
    }

    func saveScore(_: Score, fileURL _: URL, format _: ScoreFormat) async throws {
        throw DomainError.unsupportedFormat("test")
    }

    static let summary = ScoreFileSummary(
        title: "Stub Title",
        composer: "Stub Composer",
        instrumentationSummary: "Stub Instrumentation",
        lengthBeats: 17,
        defaultTempoBpm: 77,
        primaryKey: "F",
    )
}
```

- [ ] **Step 2: Run to verify failure**

```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/LiveScoreOriginalStoreRevertTests
```

Expected: FAIL — the stub implementation returns the item unchanged.

- [ ] **Step 3: Implement `revertToOriginal`**

Replace the placeholder in `LiveScoreOriginalStore.swift`:

```swift
    /// Writes the original back and rebuilds the row from it.
    ///
    /// File first, row second, on purpose. A kill between them leaves the file restored and the row's hash stale —
    /// the user opens their original and loses nothing, and the next save or revert corrects the hash. The other
    /// order would leave a row claiming the original over a file that still held the edits, which is worse.
    public func revertToOriginal(_ item: ScoreItem, restoringScoreInfo: Bool) async throws -> ScoreItem {
        let restoredFacts = try Self.restoreFile(for: item, in: scoresDirectory)
        let restored = scoresDirectory.appending(path: restoredFacts.localFileName)
        let summary = try await gateway.loadFileMetadata(fileURL: restored)
        return item.adoptingRevertedOriginal(
            RevertedOriginalFacts(
                localFileName: restoredFacts.localFileName,
                contentHash: restoredFacts.contentHash,
                sizeBytes: restoredFacts.sizeBytes,
                summary: summary,
            ),
            restoringScoreInfo: restoringScoreInfo,
        )
    }

    /// Performs the file plan from `RevertPolicy.filePlan(for:)` and returns the restored file's identity and hash.
    ///
    /// Verifies the source's hash — the sidecar, or the adopt-target — **before touching anything**. The whole
    /// promise of this feature is that the bytes coming back are the bytes that went in, so a corrupted original
    /// must be refused with the edit and its only backup both still intact, not discovered only after they are
    /// gone: the copy or adoption that follows is byte-for-byte, so hashing the source proves exactly what hashing
    /// the result would have proven, without first destroying the evidence a retry would need.
    private static func restoreFile(
        for item: ScoreItem,
        in scoresDirectory: URL,
    ) throws -> (localFileName: String, contentHash: String, sizeBytes: Int64) {
        guard let plan = RevertPolicy.filePlan(for: item) else {
            throw DomainError.scoreWriteFailed(reason: "no original recorded for \(item.localFileName)")
        }
        switch plan {
        case let .restoreSidecar(sidecarFileName, over):
            let sidecar = scoresDirectory.appending(path: sidecarFileName)
            guard FileManager.default.fileExists(atPath: sidecar.path) else {
                throw DomainError.scoreFileNotFound(name: sidecarFileName)
            }
            let facts = try verifiedHashAndSize(of: sidecar, against: item.originalContentHash, name: sidecarFileName)
            try swapIn(sidecar, over: scoresDirectory.appending(path: over))
            try? FileManager.default.removeItem(at: sidecar)
            return (over, facts.contentHash, facts.sizeBytes)
        case let .adoptExistingFile(originalFileName, deleting):
            let source = scoresDirectory.appending(path: originalFileName)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw DomainError.scoreFileNotFound(name: originalFileName)
            }
            let facts = try verifiedHashAndSize(of: source, against: item.originalContentHash, name: originalFileName)
            try? FileManager.default.removeItem(at: scoresDirectory.appending(path: deleting))
            return (originalFileName, facts.contentHash, facts.sizeBytes)
        }
    }

    /// Hashes `url` and, when `expectedHash` is non-`nil`, throws before returning if it disagrees — the check the
    /// caller must run before mutating anything.
    private static func verifiedHashAndSize(
        of url: URL,
        against expectedHash: String?,
        name: String,
    ) throws -> (contentHash: String, sizeBytes: Int64) {
        let facts = try hashAndSize(of: url)
        if let expected = expectedHash, expected != facts.contentHash {
            throw DomainError.scoreWriteFailed(reason: "restored original does not match its recorded hash (\(name))")
        }
        return facts
    }

    /// Copies `source` over `destination` through a scratch file, so a failure part-way cannot leave the score
    /// truncated. `replaceItemAt` needs the scratch to be a real file it can move into place.
    private static func swapIn(_ source: URL, over destination: URL) throws {
        let scratch = destination.deletingLastPathComponent()
            .appending(path: "\(destination.lastPathComponent).reverting")
        try? FileManager.default.removeItem(at: scratch)
        try FileManager.default.copyItem(at: source, to: scratch)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: scratch)
            } else {
                try FileManager.default.moveItem(at: scratch, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        }
    }
```

Note: the shipped code additionally runs the file-side work (`restoreFile`, plus the hash) off the caller's `@MainActor` via `Task.detached`, mirroring `captureOriginalIfNeeded`'s shape — omitted from the block above for the same reason `Task 3`'s block omits that detail, but present in `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreOriginalStore.swift`.

- [ ] **Step 4: Run to verify the tests pass**

```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/LiveScoreOriginalStoreRevertTests
```

Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure
git commit -m "feat(infrastructure): restore a score's original bytes"
```

---

## Task 8: Discard the original when the PDF is read again

**Files:**
- Modify: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreOriginalStore.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel+PDFReread.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/NoopScoreServices.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift:149,174`
- Modify: `App/AppShellView.swift:425`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreOriginalStoreRevertTests.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/Support/PDFReaderTestRig.swift` and the PDF re-read suite beside it

**Interfaces:**
- Consumes: `ScoreOriginalStore.discardOriginal(for:)` from Task 3.
- Produces: `ReaderViewModel.originalStore` (injected), and a `reReadPDF()` that clears the recorded original.

- [ ] **Step 1: Write the failing store test**

Append to `LiveScoreOriginalStoreRevertTests.swift`:

```swift
@Suite("LiveScoreOriginalStore discard")
struct LiveScoreOriginalStoreDiscardTests {
    private func makeDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "original-discard-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func item(localFileName: String, originalFileName: String?) -> ScoreItem {
        var item = ScoreItem(
            title: "t",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: localFileName,
            contentHash: "c",
            sizeBytes: 1,
            lengthBeats: 1,
            defaultTempoBpm: 60,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
        item.originalFileName = originalFileName
        item.originalContentHash = originalFileName == nil ? nil : "o"
        item.originalProvenance = originalFileName == nil ? nil : .conversionOutput
        return item
    }

    @Test func `discarding removes the sidecar and clears the columns`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("baseline".utf8).write(to: dir.appending(path: "ID.original.mscz"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())

        let cleared = try await store.discardOriginal(
            for: item(localFileName: "ID.mscz", originalFileName: "ID.original.mscz"),
        )

        #expect(cleared.originalFileName == nil)
        #expect(cleared.originalContentHash == nil)
        #expect(cleared.originalProvenance == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "ID.original.mscz").path) == false)
    }

    @Test func `discarding never deletes a file the item still uses`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("source".utf8).write(to: dir.appending(path: "ID.musicxml"))
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())

        _ = try await store.discardOriginal(for: item(localFileName: "ID.mscz", originalFileName: "ID.musicxml"))

        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "ID.musicxml").path))
    }

    @Test func `discarding an item with no original is a no-op`() async throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LiveScoreOriginalStore(scoresDirectory: dir, gateway: StubGateway())
        let subject = item(localFileName: "ID.mscz", originalFileName: nil)
        #expect(try await store.discardOriginal(for: subject) == subject)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/LiveScoreOriginalStoreDiscardTests
```

Expected: FAIL — the placeholder returns the item unchanged.

- [ ] **Step 3: Implement `discardOriginal`**

Replace the placeholder in `LiveScoreOriginalStore.swift`:

```swift
    /// Forgets the original.
    ///
    /// Only a sidecar folino copied is deleted. When the original is the source file itself — a MusicXML import
    /// whose editor save went to a sibling `.mscz` — that file is the item's own history, and a re-read cannot
    /// happen for it anyway (re-read only exists for PDF-origin items).
    public func discardOriginal(for item: ScoreItem) async throws -> ScoreItem {
        guard let originalFileName = item.originalFileName else { return item }
        if originalFileName == item.originalSidecarFileName {
            try? FileManager.default.removeItem(at: scoresDirectory.appending(path: originalFileName))
        }
        var cleared = item
        cleared.originalFileName = nil
        cleared.originalContentHash = nil
        cleared.originalProvenance = nil
        return cleared
    }
```

- [ ] **Step 4: Inject the store into `ReaderViewModel` — with a default**

`ReaderViewModel` is constructed in roughly thirty places: seven `#Preview` factories inside the Reader's own sources (`ReaderTransportControl+Previews.swift:35`, `VerticalScoreContainerPreviews.swift:14` and `:46`, `PagedScoreContainerPreviews.swift:17`, `PlaybackInspectorScreen.swift:334`, `ClefMenu.swift:72`, `ReaderToolbar.swift:300`), the one production site at `ReaderRootScreen.swift:174`, and some twenty-five in the test target. A required parameter would break all of them.

So give it a default:

```swift
    @ObservationIgnored let originalStore: any ScoreOriginalStore
```

with the initializer parameter `originalStore: any ScoreOriginalStore = NoopScoreOriginalStore(),` placed immediately after `repository:`. Put `NoopScoreOriginalStore` in the Reader's existing `Sources/Reader/NoopScoreServices.swift`, matching the no-op doubles already there (three members, each returning its argument, each with `// swiftlint:disable:next async_without_await`).

The default is for previews and for tests that do not exercise revert. **The production path must not take it**, which is the next step.

- [ ] **Step 5: Thread the real store to the production Reader**

`ReaderRootScreen` builds the view model, and the App builds `ReaderRootScreen` — the Editor's route through `EditableReaderScreen` does not reach this one. Two edits:

- add `originalStore: any ScoreOriginalStore` to `ReaderRootScreen.init` (around `:149`) and pass it to `ReaderViewModel(...)` at `:174`;
- pass `AppShellView`'s `originalStore` (added in Task 5) where it calls `makeReader` / constructs `ReaderRootScreen`, around `AppShellView.swift:425`.

Without this the Reader's discard and revert are silently no-ops, and every test still passes because they use the fake.

- [ ] **Step 6: Write the failing Reader test**

The Reader's PDF tests are driven by `PDFReaderTestRig` (`ReaderTests/Support/PDFReaderTestRig.swift:114`) — a bare view model will not do, because `reReadPDF()` returns immediately unless `originalPDFFileName` and `pdfConversion` are both set (`ReaderViewModel+PDFReread.swift:30`). Add an `originalStore` parameter to the rig, defaulted to a new `FakeScoreOriginalStore` in the Reader test target's fakes (three members plus `var discardCalls: [ScoreItem] = []` recorded in `discardOriginal`, returning the item with the three original fields cleared), and append to the existing PDF re-read suite:

```swift
    @Test func `re-reading the pdf forgets the captured original`() async throws {
        let store = FakeScoreOriginalStore()
        let rig = PDFReaderTestRig(converted: true, originalStore: store)
        var item = rig.viewModel.scoreItem
        item.originalFileName = "\(item.id.rawValue.uuidString).original.mscz"
        item.originalContentHash = "orig"
        item.originalProvenance = .conversionOutput
        rig.viewModel.scoreItem = item

        await rig.viewModel.reReadPDF()

        #expect(store.discardCalls.count == 1)
        #expect(store.discardCalls.first?.originalFileName == "\(item.id.rawValue.uuidString).original.mscz")
        #expect(rig.viewModel.scoreItem.originalFileName == nil)
    }
```

Match the rig's actual initializer and property names — read `PDFReaderTestRig.swift` before writing this, and follow whatever the existing re-read tests in that file do to reach the view model.

The second assertion is the one that matters: it fails if the discard is handed a row whose original has already been cleared, which is exactly what happens if `ScoreItem+PDFConversion.rebuilt` was not fixed in Task 1 Step 5b. Without it the sidecar would stay on disk forever, unreferenced and unnameable by `filesBackingRow`, and the test would still be green.

- [ ] **Step 7: Clear the original on re-read**

In `reReadPDF()`, replace the row-update block:

```swift
        let updated = scoreItem.adoptingPDFConversion(
            rewritten,
            sourcePDFFileName: sidecarName,
            sourcePDFContentHash: scoreItem.originalPDFContentHash,
        )
        // The captured original was the baseline of the parse this just replaced, so it is no longer the original of
        // anything on screen. Drop it; the next edit captures the new conversion's output.
        let cleared = (try? await originalStore.discardOriginal(for: updated)) ?? updated
        scoreItem = cleared
        try? await repository.saveScoreItem(cleared)
```

- [ ] **Step 8: Run the Reader and Infrastructure suites, and build the app**

```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

then from `Packages/Features/Reader`:

```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

then, because Step 5 changed `ReaderRootScreen.init`:

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```

Expected: PASS / BUILD SUCCEEDED.

- [ ] **Step 9: Commit**

```bash
git add Packages/Infrastructure Packages/Features/Reader App
git commit -m "feat(reader): drop the captured original when the pdf is read again"
```

---

## Task 9: Editor view model — revert without flushing

**Files:**
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift`
- Create: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Revert.swift`
- Test: `Packages/Features/Editor/Tests/EditorTests/EditorViewModelRevertTests.swift`

**Interfaces:**
- Consumes: `ScoreOriginalStore.revertToOriginal(_:restoringScoreInfo:)`, `RevertPolicy.warnings(for:hasMusicalAnnotations:)`.
- Produces:
  - `EditorViewModel.canRevertToOriginal: Bool`
  - `EditorViewModel.revertWarnings(hasMusicalAnnotations: Bool) -> RevertWarnings`
  - `EditorViewModel.revertToOriginal() async`
  - `EditorViewModel.onRevertCompleted: @MainActor (ScoreItem) -> Void` — the App mirrors it into the Reader, which reloads.
  - `EditorViewModel.revertError: String?`

- [ ] **Step 1: Write the failing tests**

Create `Packages/Features/Editor/Tests/EditorTests/EditorViewModelRevertTests.swift`:

```swift
import Domain
@testable import Editor
import Foundation
import Testing

@MainActor
@Suite("EditorViewModel revert")
struct EditorViewModelRevertTests {
    private func makeTempScoresDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "editor-revert-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeViewModel(
        item: ScoreItem,
        originalStore: FakeScoreOriginalStore,
        gateway: FakeScoreFileGateway = FakeScoreFileGateway(),
        repository: FakeScoreLibraryRepository = FakeScoreLibraryRepository(),
        directory: URL,
    ) -> EditorViewModel {
        EditorViewModel(
            scoreItem: item,
            scoresDirectory: directory,
            gateway: gateway,
            repository: repository,
            originalStore: originalStore,
            playback: nil,
        )
    }

    private func capturedItem() -> ScoreItem {
        var item = EditorFixtures.sampleItem()
        item.originalFileName = "score.original.mscz"
        item.originalContentHash = "orig"
        item.originalProvenance = .importTime
        return item
    }

    @Test func `revert is unavailable until an original exists`() {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = makeViewModel(
            item: EditorFixtures.sampleItem(),
            originalStore: FakeScoreOriginalStore(),
            directory: dir,
        )
        #expect(vm.canRevertToOriginal == false)
    }

    @Test func `revert is available once an original exists`() {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = makeViewModel(item: capturedItem(), originalStore: FakeScoreOriginalStore(), directory: dir)
        #expect(vm.canRevertToOriginal)
    }

    /// The bug this guards: going through `endSession()` would flush the pending autosave and write the very edits
    /// being discarded, one moment before discarding them.
    @Test func `reverting does not write the pending edit first`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gateway = FakeScoreFileGateway()
        let store = FakeScoreOriginalStore()
        let vm = makeViewModel(item: capturedItem(), originalStore: store, gateway: gateway, directory: dir)
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.applyCommand(InputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14))

        await vm.revertToOriginal()

        #expect(gateway.savedCalls.isEmpty)
        #expect(store.revertCalls.count == 1)
        #expect(store.revertCalls.first?.1 == false)
    }

    @Test func `reverting persists the rebuilt row and notifies the host`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let vm = makeViewModel(
            item: capturedItem(),
            originalStore: FakeScoreOriginalStore(),
            repository: repository,
            directory: dir,
        )
        var notified: ScoreItem?
        vm.onRevertCompleted = { notified = $0 }
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.applyCommand(InputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14))

        await vm.revertToOriginal()

        #expect(repository.savedScoreItems.count == 1)
        #expect(notified?.id == vm.scoreItem.id)
        #expect(vm.canUndo == false)
    }

    @Test func `a legacy original carries its caveat into the warnings`() {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var item = capturedItem()
        item.originalProvenance = .legacyUnknown
        let vm = makeViewModel(item: item, originalStore: FakeScoreOriginalStore(), directory: dir)
        let warnings = vm.revertWarnings(hasMusicalAnnotations: false)
        #expect(warnings.contains(.originalMayNotBeImportTime))
    }
}
```

Extend the Editor's `FakeScoreOriginalStore` from Task 4 so `revertToOriginal` returns an item with the original cleared:

```swift
    func revertToOriginal(_ item: ScoreItem, restoringScoreInfo: Bool) async throws -> ScoreItem {
        revertCalls.append((item, restoringScoreInfo))
        var cleared = item
        cleared.originalFileName = nil
        cleared.originalContentHash = nil
        cleared.originalProvenance = nil
        return cleared
    }
```

- [ ] **Step 2: Run to verify failure**

```
xcodebuild test -scheme Editor -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:EditorTests/EditorViewModelRevertTests
```

Expected: FAIL — `value of type 'EditorViewModel' has no member 'canRevertToOriginal'`.

- [ ] **Step 3: Add the stored members**

In `EditorViewModel.swift`, beside the other host callbacks:

```swift
    /// Fired after a successful revert with the rebuilt row. The App mirrors it into the Reader, which reloads the
    /// score from disk — the Editor cannot reach the Reader directly.
    public var onRevertCompleted: @MainActor (ScoreItem) -> Void = { _ in }
    /// Set when a revert failed, for the chrome to surface. Cleared at the start of each attempt.
    public internal(set) var revertError: String?
```

`internal(set)`, not `private(set)` — `EditorViewModel+Revert.swift` is a different file in the same module, and `private` does not reach across files. Task 4 changed `editor` for the same reason; if it was not, do it now.

- [ ] **Step 4: Write the revert path**

Create `Packages/Features/Editor/Sources/Editor/EditorViewModel+Revert.swift`:

```swift
import Domain
import Foundation

extension EditorViewModel {
    /// Reads the observed mirror, not `scoreItem` — `scoreItem` is `@ObservationIgnored`, so a toolbar bound to it
    /// would not notice the capture that the session's first autosave performs.
    public var canRevertToOriginal: Bool {
        hasCapturedOriginal
    }

    /// What the confirmation has to say. The annotation half is the host's to answer — the Editor cannot see the ink.
    public func revertWarnings(hasMusicalAnnotations: Bool) -> RevertWarnings {
        RevertPolicy.warnings(for: scoreItem, hasMusicalAnnotations: hasMusicalAnnotations)
    }

    /// Puts the original's bytes back and tears the session down.
    ///
    /// Deliberately NOT via `endSession()`: that flushes the pending autosave, which would write the edits this is
    /// discarding a moment before discarding them. The debounce is cancelled instead, and `isDirty` cleared so a
    /// later flush — the scene going inactive, say — cannot resurrect them either.
    public func revertToOriginal() async {
        revertError = nil
        autosaveTask?.cancel()
        autosaveTask = nil
        isDirty = false
        do {
            let reverted = try await originalStore.revertToOriginal(scoreItem, restoringScoreInfo: false)
            try await repository.saveScoreItem(reverted)
            scoreItem = reverted
            hasCapturedOriginal = false
            // Drop the editor last: `canUndo` reads through it, so the toolbar goes inert only once the score on
            // disk is actually the original.
            editor = nil
            selection = .none
            selectedItem = nil
            caretItem = nil
            // The host is holding the edited score and drawing it; leaving the session open would leave the user
            // looking at the very edits this just discarded. Ending it is also what stops playback before the file
            // underneath the engine changes.
            onRevertCompleted(reverted)
        } catch {
            revertError = String(localized: "editor.revert.failed", bundle: .module)
        }
    }
}
```

- [ ] **Step 5: Add the localized string**

In `Packages/Features/Editor/Sources/Editor/Resources/Localizable.xcstrings`, add `editor.revert.failed` with the five locales the file already carries (`en`, `ja`, `ko`, `zh-Hans`, `zh-Hant`). English: `Couldn't restore the original.` Japanese: `オリジナルに戻せませんでした。` Match the existing entries' tone for ko / zh-Hans / zh-Hant by following how `reader.pdf.reread.failed` is phrased in the Reader's catalog.

- [ ] **Step 6: Run the Editor suite**

```
xcodebuild test -scheme Editor -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Editor
git commit -m "feat(editor): revert to the original without flushing the pending edit"
```

---

## Task 10: Editor chrome — the overflow item and its confirmation

**Files:**
- Modify: `Packages/Features/Editor/Sources/Editor/Screens/EditorChromeView+Toolbar.swift`
- Create: `Packages/Features/Editor/Sources/Editor/Screens/EditorChromeView+Revert.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/Screens/EditorChromeView.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `EditorViewModel.canRevertToOriginal`, `.revertWarnings(hasMusicalAnnotations:)`, `.revertToOriginal()`, `.revertError` from Task 9.
- Produces: `EditorChromeView.hasMusicalAnnotations: Bool` — a new initializer parameter the App fills from the Reader seam.

- [ ] **Step 1: Add the state and the dialog**

Create `Packages/Features/Editor/Sources/Editor/Screens/EditorChromeView+Revert.swift`:

```swift
import Domain
import SwiftUI

extension EditorChromeView {
    /// Folded into a `⋯` menu rather than added as a sixth bar item on purpose. The row already runs five items
    /// wide, and iOS 26 collapses a bar it cannot fit into an overflow menu of its own choosing — which would take
    /// undo and redo with it. Choosing what folds beats being folded.
    var overflowMenu: some View {
        Menu {
            Button(role: .destructive) {
                isConfirmingRevert = true
            } label: {
                Label {
                    Text("editor.revert.action", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.counterclockwise")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel(Text("editor.chrome.more", bundle: .module))
    }

    /// The confirmation. Destructive and not undoable, so it names what goes and what stays, and adds the caveat
    /// for an item whose recorded original predates the feature.
    func revertConfirmation(on content: some View) -> some View {
        content
            .confirmationDialog(
                Text("editor.revert.confirm.title", bundle: .module),
                isPresented: $isConfirmingRevert,
                titleVisibility: .visible,
            ) {
                Button(role: .destructive) {
                    Task { await viewModel.revertToOriginal() }
                } label: {
                    Text("editor.revert.confirm.action", bundle: .module)
                }
                Button(role: .cancel) {} label: {
                    Text("editor.revert.confirm.cancel", bundle: .module)
                }
            } message: {
                Text(revertMessage)
            }
    }

    private var revertMessage: String {
        let warnings = viewModel.revertWarnings(hasMusicalAnnotations: hasMusicalAnnotations)
        var lines = [String(localized: "editor.revert.confirm.body", bundle: .module)]
        if warnings.contains(.musicalAnnotationsMayShift) {
            lines.append(String(localized: "editor.revert.confirm.inkMayShift", bundle: .module))
        }
        if warnings.contains(.originalMayNotBeImportTime) {
            lines.append(String(localized: "editor.revert.confirm.mayNotBeImport", bundle: .module))
        }
        return lines.joined(separator: "\n\n")
    }
}
```

- [ ] **Step 2: Hold the state and the new input**

In `EditorChromeView.swift`, add:

```swift
    @State var isConfirmingRevert = false
```

and an initializer parameter `let hasMusicalAnnotations: Bool` alongside `bottomTransportClearance`, defaulted to `false` so previews stay short. Leave it **internal** — `bottomTransportClearance` beside it is `private`, and copying that would put it out of reach of `EditorChromeView+Revert.swift`, which is a different file. Apply the dialog by wrapping the existing body's root: change `var body: some View { … }` so its final expression is `revertConfirmation(on: <existing root>)`.

- [ ] **Step 3: Add the toolbar item**

In `EditorChromeView+Toolbar.swift`, insert as the FIRST `.topBarTrailing` item, before undo:

```swift
        if viewModel.canRevertToOriginal {
            ToolbarItem(placement: .topBarTrailing) { overflowMenu }
        }
```

- [ ] **Step 4: Add the localized strings**

Add to the Editor's `Localizable.xcstrings`, in all locales the file already carries:

| Key | English | Japanese |
| --- | --- | --- |
| `editor.chrome.more` | `More` | `その他` |
| `editor.revert.action` | `Revert to Original` | `オリジナルに戻す` |
| `editor.revert.confirm.title` | `Revert to Original?` | `オリジナルに戻しますか？` |
| `editor.revert.confirm.action` | `Revert` | `元に戻す` |
| `editor.revert.confirm.cancel` | `Cancel` | `キャンセル` |
| `editor.revert.confirm.body` | `Every note change you made will be discarded. Your handwriting, tags and playback settings are kept.` | `加えた音符の変更はすべて破棄されます。手書き・タグ・再生設定はそのまま残ります。` |
| `editor.revert.confirm.inkMayShift` | `Handwriting anchored to the notation may move.` | `楽譜に紐づいた手書きは位置がずれることがあります。` |
| `editor.revert.confirm.mayNotBeImport` | `This score was in your library before folino started keeping originals, so the saved version may already include earlier edits.` | `この楽譜は folino がオリジナルを保存し始める前からライブラリにあるため、保存されている状態には以前の編集が含まれている可能性があります。` |

Follow `project_localization_key_scheme`: `module.feature.thing`. Supply ko / zh-Hans / zh-Hant alongside — the five locales this catalog carries — matching the register of the neighbouring strings.

- [ ] **Step 5: Verify the toolbar by preview**

Add a `#Preview` to `EditorChromeView+Previews.swift` that mounts the chrome for an item whose `originalFileName` is set, then render it:

```
mcp__xcode__RenderPreview
```

with the `Editor` scheme active, and `Read` the PNG. Confirm the `⋯` appears and that undo / redo / 完了 have NOT been folded into a system overflow menu. If they have, drop the `⋯` down to `.secondaryAction` placement and re-render.

- [ ] **Step 6: Run the Editor suite and commit**

```
xcodebuild test -scheme Editor -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

```bash
git add Packages/Features/Editor
git commit -m "feat(editor): revert-to-original in the editing toolbar"
```

---

## Task 11: App wiring — reload the reader after a revert

**Files:**
- Modify: `App/EditableReaderScreen.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderEditingHost.swift`

**Interfaces:**
- Consumes: `EditorViewModel.onRevertCompleted` from Task 9, `EditorChromeView.hasMusicalAnnotations` from Task 10.
- Produces: `ReaderEditingHost.requestReloadAfterRevert: @MainActor (ScoreItem) -> Void` and `ReaderEditingHost.hasMusicalAnnotations: Bool`, both set by the Reader and read by the App.

- [ ] **Step 1: Add the two seam members**

In `ReaderEditingHost`, following the file's existing conventions for host-to-App state:

```swift
    /// Answers whether any ink is anchored to the notation, so the Editor's confirmation can say whether reverting
    /// will move it. A provider rather than a stored mirror, matching `hiddenStavesProvider`: the answer changes as
    /// the user draws, and a value copied at wiring time would be stale by the time the dialog opens.
    public var hasMusicalAnnotationsProvider: @MainActor () -> Bool = { false }
    /// Filled by the Reader. The App calls it when a revert lands; the Reader adopts the rebuilt row, leaves the
    /// editing session, stops playback and reloads the score from disk.
    public var requestReloadAfterRevert: @MainActor (ScoreItem) -> Void = { _ in }
```

Both are filled in the Reader's existing host-wiring block in `ReaderRootScreen.swift` (around `:295-305`, beside `hiddenStavesProvider`), capturing the view model weakly the way its neighbours do.

`requestReloadAfterRevert`'s body, on the `ReaderViewModel`: stop playback first — the file under the audio engine is about to change, and this repo has a history of crashes from tearing down or swapping under a live render thread — then adopt the item, request the editing session exit the same way `onDone` does, set `pdfPlayback = .idle` for a PDF-origin item, and `await load()`. The tail after the stop is exactly what `reReadPDF()` already does at `ReaderViewModel+PDFReread.swift:64-68`; follow it.

- [ ] **Step 2: Connect them in the composition root**

In `EditableReaderScreen.wireOnce()`:

```swift
        editorViewModel.onRevertCompleted = { [editingHost] item in
            editingHost.requestReloadAfterRevert(item)
        }
```

and in the chrome builder, pass `hasMusicalAnnotations: editingHost.hasMusicalAnnotationsProvider()`.

- [ ] **Step 3: Build and smoke-test on the simulator**

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```

Then install and launch, import an `.mscz`, edit a note, revert from the `⋯` menu, and confirm the score redraws as it was and the `⋯` disappears. This is the one step in the plan that previews cannot answer — it exercises the file swap, the row update and the reader reload together.

- [ ] **Step 4: Commit**

```bash
git add App Packages/Features/Reader
git commit -m "feat(app): reload the reader after a revert"
```

---

## Task 12: The score-info entry point

> **Execute Tasks 12 and 13 as one unit and commit once.** Task 12 adds a member to `ScoreInfoEditing`, which leaves `ReaderViewModel` and `LibraryViewModel` no longer conforming until Task 13. Task 12's verification runs only the ScoreUI scheme, where that breakage is invisible.

**Files:**
- Modify: `Packages/ScoreUI/Sources/ScoreUI/ScoreInfoEditing.swift`
- Modify: `Packages/ScoreUI/Sources/ScoreUI/EditScoreInfoSheet.swift`
- Create: `Packages/ScoreUI/Sources/ScoreUI/RevertToOriginalSection.swift`
- Modify: `Packages/ScoreUI/Sources/ScoreUI/Resources/Localizable.xcstrings`
- Test: `Packages/ScoreUI/Tests/ScoreUITests/RevertToOriginalSectionTests.swift`

**Interfaces:**
- Consumes: `RevertPolicy.warnings(for:hasMusicalAnnotations:)`, `ScoreItem.canRevertToOriginal`.
- Produces: one member on `ScoreInfoEditing` —
  `func revertToOriginal(_ item: ScoreItem, restoringScoreInfo: Bool) async`.

- [ ] **Step 1: Write the failing test**

Create `Packages/ScoreUI/Tests/ScoreUITests/RevertToOriginalSectionTests.swift`:

```swift
import Domain
@testable import ScoreUI
import Testing

@Suite("Revert section visibility")
struct RevertToOriginalSectionTests {
    private func item(originalFileName: String?) -> ScoreItem {
        var item = ScoreItem(
            title: "t",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: "ID.mscz",
            contentHash: "c",
            sizeBytes: 1,
            lengthBeats: 1,
            defaultTempoBpm: 60,
            primaryKey: nil,
            addedAt: .distantPast,
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
        item.originalFileName = originalFileName
        item.originalProvenance = originalFileName == nil ? nil : .importTime
        return item
    }

    @Test func `the section is hidden for a score that was never edited`() {
        #expect(item(originalFileName: nil).canRevertToOriginal == false)
    }

    @Test func `the section is shown once an original exists`() {
        #expect(item(originalFileName: "ID.original.mscz").canRevertToOriginal)
    }
}
```

- [ ] **Step 2: Run to verify it compiles and passes**

Run from `Packages/ScoreUI`:

```
xcodebuild test -scheme ScoreUI -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ScoreUITests/RevertToOriginalSectionTests
```

Expected: PASS (the property came from Task 1). This suite exists to pin the visibility rule the section reads.

- [ ] **Step 3: Extend the protocol**

In `ScoreInfoEditing.swift`:

```swift
    /// Restores the score's original bytes. `restoringScoreInfo` additionally re-reads the credit fields from that
    /// file; content-derived fields come from it either way.
    func revertToOriginal(_ item: ScoreItem, restoringScoreInfo: Bool) async
```

There is one double to update, `PreviewInfoEditing` at `EditScoreInfoSheet.swift:182`:

```swift
    // swiftlint:disable:next async_without_await
    func revertToOriginal(_: ScoreItem, restoringScoreInfo _: Bool) async {}
```

Deliberately **not** adding a `hasMusicalAnnotations` member. This sheet is presented from the Library as well as the Reader, and the Library does not load annotations — answering it would mean plumbing an annotation query through the composition root for one sentence of copy. The sheet's wording is conditional instead ("handwriting anchored to the notation *may* move"), so it is true either way. The Editor's own confirmation keeps the precise version, because there the Reader knows.

- [ ] **Step 4: Add the section**

Create `Packages/ScoreUI/Sources/ScoreUI/RevertToOriginalSection.swift`:

```swift
import Domain
import SwiftUI

/// The score-info sheet's way back to the original. Shown only once an original exists — a score nobody has edited
/// has nothing to revert, and an inert row would just raise the question.
///
/// Unlike the editing toolbar's version, this one offers the choice of bringing the title and credits back with the
/// notation: the sheet is where those fields live, so it is the only place the distinction is legible.
struct RevertToOriginalSection: View {
    let model: any ScoreInfoEditing
    let item: ScoreItem
    let onCompleted: () -> Void

    @State private var isChoosingScope = false

    var body: some View {
        Section {
            // The dialog hangs off the BUTTON, not off the `Section`. A presentation modifier on a Section is
            // handed to every row it contains, and the copy that is not the one the user tapped tears the
            // presentation down the instant it opens — a bug this repo has already shipped once.
            Button(role: .destructive) {
                isChoosingScope = true
            } label: {
                Text("scoreUI.revert.action", bundle: .module)
            }
            .confirmationDialog(
                Text("scoreUI.revert.confirm.title", bundle: .module),
                isPresented: $isChoosingScope,
                titleVisibility: .visible,
            ) {
                Button(role: .destructive) { revert(restoringScoreInfo: false) } label: {
                    Text("scoreUI.revert.confirm.scoreOnly", bundle: .module)
                }
                Button(role: .destructive) { revert(restoringScoreInfo: true) } label: {
                    Text("scoreUI.revert.confirm.scoreAndInfo", bundle: .module)
                }
                Button(role: .cancel) {} label: {
                    Text("scoreUI.revert.confirm.cancel", bundle: .module)
                }
            } message: {
                Text(message)
            }
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        String(localized: "scoreUI.revert.footer", bundle: .module)
    }

    /// `hasMusicalAnnotations: true` unconditionally — see the note in the protocol step. The ink line is worded as
    /// a possibility, so it is honest for a score with no ink at all; the provenance line still varies per item.
    private var message: String {
        let warnings = RevertPolicy.warnings(for: item, hasMusicalAnnotations: true)
        var lines = [String(localized: "scoreUI.revert.confirm.body", bundle: .module)]
        if warnings.contains(.musicalAnnotationsMayShift) {
            lines.append(String(localized: "scoreUI.revert.confirm.inkMayShift", bundle: .module))
        }
        if warnings.contains(.originalMayNotBeImportTime) {
            lines.append(String(localized: "scoreUI.revert.confirm.mayNotBeImport", bundle: .module))
        }
        return lines.joined(separator: "\n\n")
    }

    private func revert(restoringScoreInfo: Bool) {
        Task {
            await model.revertToOriginal(item, restoringScoreInfo: restoringScoreInfo)
            onCompleted()
        }
    }
}
```

- [ ] **Step 5: Mount it in the sheet**

In `EditScoreInfoSheet.swift`, inside the `Form`, after `infoSection`:

```swift
                if item.canRevertToOriginal {
                    RevertToOriginalSection(model: model, item: item) { dismiss() }
                }
```

The sheet dismisses on completion because every field it is showing has just been re-derived; keeping it open would display stale values.

- [ ] **Step 6: Add the localized strings**

| Key | English | Japanese |
| --- | --- | --- |
| `scoreUI.revert.action` | `Revert to Original` | `オリジナルに戻す` |
| `scoreUI.revert.footer` | `Goes back to the file folino imported. Handwriting, tags and playback settings are kept.` | `folino が取り込んだときのファイルに戻します。手書き・タグ・再生設定はそのまま残ります。` |
| `scoreUI.revert.confirm.title` | `Revert to Original?` | `オリジナルに戻しますか？` |
| `scoreUI.revert.confirm.scoreOnly` | `Revert the Score` | `楽譜だけ戻す` |
| `scoreUI.revert.confirm.scoreAndInfo` | `Revert the Score and Info` | `楽譜と楽曲情報を戻す` |
| `scoreUI.revert.confirm.cancel` | `Cancel` | `キャンセル` |
| `scoreUI.revert.confirm.body` | `Every note change will be discarded.` | `加えた音符の変更はすべて破棄されます。` |
| `scoreUI.revert.confirm.inkMayShift` | `Handwriting anchored to the notation may move.` | `楽譜に紐づいた手書きは位置がずれることがあります。` |
| `scoreUI.revert.confirm.mayNotBeImport` | `This score was in your library before folino started keeping originals, so the saved version may already include earlier edits.` | `この楽譜は folino がオリジナルを保存し始める前からライブラリにあるため、保存されている状態には以前の編集が含まれている可能性があります。` |

- [ ] **Step 7: Render the sheet and check it**

Add a `#Preview` variant whose item has `originalFileName` set, render it with `mcp__xcode__RenderPreview` under the `ScoreUI` scheme, and `Read` the PNG. Confirm the destructive row reads clearly under the info section and the footer wraps without truncation.

- [ ] **Step 8: Run the ScoreUI suite and commit**

```
xcodebuild test -scheme ScoreUI -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Do **not** commit yet — the Reader and the Library stop conforming to `ScoreInfoEditing` until Task 13. Continue straight into it.

---

## Task 13: Conform the Reader and the Library

> Same commit as Task 12.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel+Conformances.swift`
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`
- Create: `Packages/Features/Library/Sources/Library/LibraryViewModel+Revert.swift`
- Modify: `App/AppShellView.swift:161`
- Test: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelRevertTests.swift`

**Interfaces:**
- Consumes: `ScoreInfoEditing`'s new member from Task 12; `ScoreOriginalStore` from Task 3.
- Produces: `LibraryViewModel.init(..., originalStore:)` and the Reader's conformance.

`LibraryViewModel.swift` is 368 lines against SwiftLint's 400-line cap, so the new method goes in `LibraryViewModel+Revert.swift` rather than inline. Check `LiveScoreLibraryRepository.swift` too — it was 397 lines before Task 2 added to it; if it now warns, move `scoreItems(matchingContentHash:)` into a `LiveScoreLibraryRepository+Duplicates.swift`.

- [ ] **Step 1: Write the failing Library test**

There is no `LibraryFixtures` in this target. The Library tests build their subjects with `Self.makeItem()` and `Self.makeVM()` (the `VMFixture` helpers at the top of `LibraryTests/LibraryViewModelTests.swift:11-44`) — read those first and follow them exactly, extending `makeVM` with an `originalStore:` argument.

Create `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelRevertTests.swift`:

```swift
    @Test func `reverting persists the rebuilt row`() async throws {
        let store = FakeScoreOriginalStore()
        let repository = FakeScoreLibraryRepository()
        let vm = Self.makeVM(repository: repository, originalStore: store)
        var item = Self.makeItem()
        item.originalFileName = "ID.original.mscz"
        item.originalProvenance = .importTime

        await vm.revertToOriginal(item, restoringScoreInfo: true)

        #expect(store.revertCalls.count == 1)
        #expect(store.revertCalls.first?.1 == true)
        #expect(repository.savedScoreItems.count == 1)
        #expect(repository.savedScoreItems.first?.originalFileName == nil)
    }
```

Add a `FakeScoreOriginalStore` to the Library test target mirroring the Editor's.

- [ ] **Step 2: Run to verify failure**

Run from `Packages/Features/Library`:

```
xcodebuild test -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:LibraryTests/LibraryViewModelRevertTests
```

Expected: FAIL — `extra argument 'originalStore' in call`.

- [ ] **Step 3: Conform the Library**

Add `let originalStore: any ScoreOriginalStore` (internal, so the extension file reaches it) and the matching `init` parameter to `LibraryViewModel`, immediately after `repository:`. Then, in `LibraryViewModel+Revert.swift`:

```swift
import Domain
import Foundation

extension LibraryViewModel {
    /// The Library's half of `ScoreInfoEditing`'s revert. Nothing to reload here — the row's own change is what the
    /// list is bound to. A Reader showing this score in an iPad split view keeps its loaded copy until it is
    /// reopened; see the note in the plan's "Known limitations".
    public func revertToOriginal(_ item: ScoreItem, restoringScoreInfo: Bool) async {
        do {
            let reverted = try await originalStore.revertToOriginal(item, restoringScoreInfo: restoringScoreInfo)
            try await repository.saveScoreItem(reverted)
        } catch {
            currentError = error
        }
    }
}
```

`currentError` exists on `LibraryViewModel` (`LibraryViewModel.swift:32`). It does **not** exist on `ReaderViewModel` — see the next step.

The construction sites that need the new argument: `AppShellView.swift:161`, and in the test target `LibraryViewModelTests`'s `makeVM`, plus `LibraryViewModelBulkTests`, `LibraryViewModelShareTests`, `LibraryViewModelVocalTunerTests` and `LibraryAnalyticsTests` if they build their own. Give the parameter no default — the Library has exactly one production site, and a default would let a real one slip through as a no-op.

- [ ] **Step 4: Conform the Reader**

In `ReaderViewModel+Conformances.swift`:

```swift
    func revertToOriginal(_ item: ScoreItem, restoringScoreInfo: Bool) async {
        // Errors are swallowed, matching `saveMetadata` right above: the Reader has no error banner yet, and the
        // score on disk is untouched when the store throws.
        guard let reverted = try? await originalStore.revertToOriginal(
            item,
            restoringScoreInfo: restoringScoreInfo,
        ) else { return }
        try? await repository.saveScoreItem(reverted)
        scoreItem = reverted
        await load()
    }
```

`ReaderViewModel` has no `currentError` — the existing `saveMetadata` in this same file swallows and says so in a comment. Do not invent one.

`originalStore` is already on `ReaderViewModel` from Task 8, so nothing new is injected here.

- [ ] **Step 5: Update the composition root**

Pass `originalStore` where `LibraryViewModel` is constructed, at `AppShellView.swift:161`.

- [ ] **Step 6: Run every affected suite and build the app**

```
xcodebuild test -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```

Expected: PASS / BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Packages/ScoreUI Packages/Features App
git commit -m "feat: revert to original from the score info sheet"
```

---

## Task 14: Parity marker, spec reconciliation, and the end-to-end check

**Files:**
- Modify: `Packages/ScoreUI/Sources/ScoreUI/RevertToOriginalSection.swift`
- Modify: `docs/engineering/ios-android-parity.md` (generated)
- Modify: `docs/superpowers/specs/2026-08-16-revert-to-original-design.md`

- [ ] **Step 1: Mark the Android gap**

At the top of `RevertToOriginalSection.swift`:

```swift
// PARITY(android): Revert to original — Android needs the same two entry points and confirmations, plus the three
//   `original_*` columns in its Room schema and the v18 pre-stamp rule. Every decision is already a Domain pure
//   function (OriginalCapture, RevertPolicy, ScoreItem+Original) and the seam is ScoreOriginalStore, so Android
//   wires UI, persistence, and a Kotlin-side implementation of that protocol; the capture call goes at its own save
//   choke point when note editing lands there (SP4).
```

- [ ] **Step 2: Regenerate the ledger**

```
Scripts/parity-report.py
```

The `parity-ledger` pre-commit hook fails if `docs/engineering/ios-android-parity.md` drifted, so this must run before the commit.

- [ ] **Step 3: Reconcile the spec with the three planning deviations**

In `docs/superpowers/specs/2026-08-16-revert-to-original-design.md`:

- Under "Provenance", replace the orphan-recovery bullet's "The migration needs one directory scan to find orphans" paragraph with the capture-time recovery described in Task 3, and note that migrations only receive a `Database`.
- Under "Where the logic lives", replace "revert belongs beside `reReadPDF` in the Reader" with the `ScoreOriginalStore` seam, and say why: the score-info sheet is presented from the Library too.
- Under "Entry points", note that the score-info entry point therefore appears wherever that sheet is presented, while the Library's row menu still has no revert item, and that the sheet's ink warning is worded as a possibility rather than measured (the Library does not load annotations).
- Under "Known limitations" (add the section if the spec has none), record the iPad split-view case from this plan.

- [ ] **Step 4: Run every suite**

```
xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

```
xcodebuild test -scheme Editor -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

```
xcodebuild test -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

```
xcodebuild test -scheme ScoreUI -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

Expected: all PASS.

- [ ] **Step 5: End-to-end on the simulator**

Build, install, launch, and walk all four shapes. This is the acceptance gate for the whole plan.

1. **MuseScore round trip.** Import an `.mscz`. Note its file's SHA-256 from the container beforehand. Edit a note, leave edit mode, reopen, revert from the score-info sheet choosing "楽譜だけ戻す". Pull the file back out and confirm the digest matches the import exactly.
2. **MusicXML round trip.** Import a `.musicxml`. Edit a note — the "saved as .mscz" notice appears. Revert. Confirm the library row plays the original and that the `.mscz` is gone from the container.
3. **PDF interaction.** Open a PDF-origin score, edit a note, re-read the PDF, then confirm the revert row is gone (the original was discarded). Edit again and confirm it comes back.
4. **Score info.** Edit the title in the sheet, then revert choosing "楽譜と楽曲情報を戻す", and confirm the title returns to the file's.

- [ ] **Step 6: Commit**

```bash
git add docs Packages/ScoreUI
git commit -m "docs: reconcile the revert spec with the implementation and mark the android gap"
```

---

## Known limitations

**iPad split view.** Reverting from the Library's score-info sheet while the same score is open in the detail Reader leaves that Reader holding the copy it loaded — which may include the edits just discarded. Starting to edit from there would capture the restored original and then overwrite it with the stale in-memory score, quietly undoing the revert. The Reader adopts the restored file on its next open.

Closing this properly means a change-notification path from the repository to an open Reader, which does not exist yet and is a larger change than this feature. Note it in the spec, add it to Task 14 Step 5's manual walk as a *known* behaviour rather than a bug, and revisit if it turns out to be reachable in practice.

## Self-review notes

- **Spec coverage.** Storage model → Tasks 1-2. Capture and the file-as-marker rule → Tasks 1, 3, 4. Other writers / PDF re-read → Task 8. Revert semantics and side effects → Tasks 6, 7. Atomicity → Tasks 3, 7. Provenance and migration → Tasks 1, 2. Duplicate detection → Task 2. Domain placement and parity → Tasks 1, 6, 14. Entry points → Tasks 10, 12, 13. Testing → each task's own steps plus Task 14 Step 5. Forward compatibility → nothing to build; the three decisions are recorded in the spec and honoured by `ScoreOriginalStore`'s shape.
- **The one spec line with no task** is "editing and undoing back to the start does not restore the original", which is documented behaviour rather than code. It is asserted indirectly by Task 4's capture test.
- **Naming is consistent across tasks:** `originalFileName` / `originalContentHash` / `originalProvenance`, `originalSidecarFileName`, `capturingOriginal`, `adoptingRevertedOriginal`, `captureOriginalIfNeeded`, `revertToOriginal`, `discardOriginal`, `hasCapturedOriginal`, `RevertFilePlan`, `RevertWarnings`, `RevertedOriginalFacts`.
- **Two task pairs must land as single commits:** 4+5 (the App does not build between them) and 12+13 (the Reader and the Library stop conforming between them). Both are flagged at the top of the task.
- **Access levels that a `private` habit would get wrong:** `EditorViewModel.editor`, `.revertError`, `.hasCapturedOriginal` are `internal(set)` because the operations live in extensions in other files; `EditorChromeView.hasMusicalAnnotations` is internal for the same reason, despite its `private` neighbour.

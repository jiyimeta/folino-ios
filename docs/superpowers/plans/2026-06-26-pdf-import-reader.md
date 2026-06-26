# PDF Import & Read-Only Reader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import `.pdf` files as first-class library items and read them in the reader (page + vertical-continuous modes) with playback/layout settings gated off and a "PDF" badge in library and reader.

**Architecture:** Reuse `ScoreItem` (PDF-ness derived from the file extension via `ScoreFormat.detect`). The gateway gains a PDF metadata-only path; PDFs are never parsed into a `Score`. The reader adds a `.loadedPDF(PDFDocument)` load state and two PDF containers that reuse the existing `ScoreScrollHost` (gestures/zoom/page-turn) with PDFKit-rasterized page images. A single `ReaderCapabilities` value gates playback/layout UI. PencilKit annotation on PDFs is a **separate follow-up plan** (`2026-06-26-pdf-annotation.md`).

**Tech Stack:** Swift 6.3, SwiftUI, PDFKit (rasterizer only — not `PDFView`), GRDB (no schema change in this plan), Swift Testing, `xcodebuild test` on iPhone 17 Pro Max simulator.

## Global Constraints

- Swift 6.3, iOS 26+, universal (iPad + iPhone), bundle id `com.KeyNumber.Folino`.
- Brand literals are NOT localized (iOS parity): the badge text is the literal `"PDF"`.
- User-facing brand name is lowercase `folino`; `Folino` only for type/scheme/bundle.
- `public` only across module boundaries; default `internal` otherwise.
- New tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`).
- Package tests run via `xcodebuild test -scheme <Pkg|Pkg-Package> -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'` (run from the package dir). `swift test` does NOT work in this repo.
- Comment paragraphs reflow at 120 columns.
- iOS/Android parity: logic added here (format detection, capability model) is shared Domain — do not encode iOS-only assumptions into it.
- Layout settings that require a parsed `Score` (staff size, system breaks, transpose, per-part visibility, clef, playback, horizontal mode) MUST be unavailable for PDF.
- PDF reader modes: page and vertical-continuous only. No horizontal.

---

## File Structure

**Modified:**
- `Packages/Domain/Sources/Domain/ScoreFormat.swift` — add `.pdf` case.
- `Packages/Domain/Sources/Domain/Models/ShareImportPolicy.swift` — accept `"pdf"`.
- `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreFileGateway.swift` — PDF metadata branch; `loadScore` rejects PDF.
- `Packages/Infrastructure/Sources/Persistence/LiveScoreFileImporter.swift` — PDF title from `/Title`.
- `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` — `LoadState.loadedPDF`, capabilities, PDF load branch.
- `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift` — PDF container dispatch.
- `Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift` — PDF inspector button + badge.
- `Packages/Features/Library/Sources/Library/Views/ScoreRow.swift` — PDF badge.
- `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift` — `.pdf` UTType.
- `App/Info.plist` — `public.pdf` document type.

**Created:**
- `Packages/Domain/Sources/Domain/Models/ReaderCapabilities.swift` — capability flags.
- `Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFPageProvider.swift` — rasterizer + windowed cache.
- `Packages/Features/Reader/Sources/Reader/Screens/PDF/PagedPDFContainer.swift` — page mode.
- `Packages/Features/Reader/Sources/Reader/Screens/PDF/VerticalPDFContainer.swift` — vertical continuous.
- `Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFLayoutInspectorScreen.swift` — thin page/vertical inspector + note.
- Test files alongside each (paths given per task).

---

## Task 1: Add `.pdf` to `ScoreFormat`

**Files:**
- Modify: `Packages/Domain/Sources/Domain/ScoreFormat.swift`
- Test: `Packages/Domain/Tests/DomainTests/ScoreFormatPDFTests.swift`

**Interfaces:**
- Produces: `ScoreFormat.pdf`; `ScoreFormat.detect("x.pdf") == .pdf`; `ScoreFormat.pdf.canonicalExtension == "pdf"`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Domain

@Suite struct ScoreFormatPDFTests {
    @Test func detectsPDFExtension() {
        #expect(ScoreFormat.detect(filename: "song.pdf") == .pdf)
        #expect(ScoreFormat.detect(filename: "SONG.PDF") == .pdf)
    }

    @Test func canonicalExtensionForPDF() {
        #expect(ScoreFormat.pdf.canonicalExtension == "pdf")
    }

    @Test func nonPDFUnaffected() {
        #expect(ScoreFormat.detect(filename: "a.mscz") == .mscz)
        #expect(ScoreFormat.detect(filename: "a.unknownext") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:DomainTests/ScoreFormatPDFTests` (from `Packages/Domain`)
Expected: FAIL — `.pdf` is not a member of `ScoreFormat`.

- [ ] **Step 3: Add the case and detection**

In `ScoreFormat.swift`, add `case pdf` after `case midi`. Update `canonicalExtension` to add `case .pdf: "pdf"`. Update `detect` to add `case "pdf": return .pdf` before `default`. Replace the stale doc comment that says PDF returns `nil`:

```swift
public enum ScoreFormat: String, Hashable, Sendable, Codable, CaseIterable {
    case mscx
    case mscz
    case musicXML
    case mxl
    case midi
    case pdf

    /// The default file extension folino writes when exporting this format.
    public var canonicalExtension: String {
        switch self {
        case .mscx: "mscx"
        case .mscz: "mscz"
        case .musicXML: "musicxml"
        case .mxl: "mxl"
        case .midi: "mid"
        case .pdf: "pdf"
        }
    }

    /// Best-effort detection from a filename or path. Case-insensitive on the extension. PDF is detected here but is
    /// never parsed into a `Score` — it is displayed as a fixed-layout document (see the PDF reader).
    public static func detect(filename: String) -> ScoreFormat? {
        guard let dotIndex = filename.lastIndex(of: ".") else { return nil }
        let ext = filename[filename.index(after: dotIndex)...].lowercased()
        switch ext {
        case "mscx": return .mscx
        case "mscz": return .mscz
        case "musicxml", "xml": return .musicXML
        case "mxl": return .mxl
        case "mid", "midi", "smf": return .midi
        case "pdf": return .pdf
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2. Expected: PASS.

> Note: adding a case to a `CaseIterable` enum may surface non-exhaustive `switch` errors elsewhere (e.g. `LiveScoreFileGateway.loadScore`). Those are handled in Task 3 — if the Domain target alone compiles, proceed; Infrastructure compiles after Task 3.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/ScoreFormat.swift Packages/Domain/Tests/DomainTests/ScoreFormatPDFTests.swift
git commit -m "feat(domain): add .pdf to ScoreFormat"
```

---

## Task 2: Accept `.pdf` in the import allow-list

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ShareImportPolicy.swift`
- Test: `Packages/Domain/Tests/DomainTests/ShareImportPolicyPDFTests.swift`

**Interfaces:**
- Produces: `ShareImportPolicy.isAccepted(filename: "x.pdf") == true`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Domain

@Suite struct ShareImportPolicyPDFTests {
    @Test func acceptsPDF() {
        #expect(ShareImportPolicy.isAccepted(filename: "score.pdf"))
        #expect(ShareImportPolicy.isAccepted(filename: "SCORE.PDF"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:DomainTests/ShareImportPolicyPDFTests` (from `Packages/Domain`)
Expected: FAIL — `pdf` not in `acceptedExtensions`.

- [ ] **Step 3: Add `"pdf"` to the set**

```swift
public static let acceptedExtensions: Set = [
    "mscz", "mscx", "musicxml", "mxl", "xml", "midi", "mid", "pdf",
]
```

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/ShareImportPolicy.swift Packages/Domain/Tests/DomainTests/ShareImportPolicyPDFTests.swift
git commit -m "feat(domain): accept .pdf in share import policy"
```

---

## Task 3: Gateway PDF metadata path + reject PDF in loadScore

**Files:**
- Modify: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreFileGateway.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/LiveScoreFileGatewayPDFTests.swift`
- Test fixture: `Packages/Infrastructure/Tests/InfrastructureTests/Fixtures/sample.pdf` (a 2-page PDF with `/Title` = "Sample Title"; generate via the snippet in Step 1's note).

**Interfaces:**
- Consumes: `ScoreFormat.pdf` (Task 1).
- Produces: `loadFileMetadata(fileURL:)` for a `.pdf` returns a `ScoreFileSummary` with `title == <PDF /Title or nil>`, `lengthBeats == 0`, `defaultTempoBpm == 0`, `instrumentationSummary == ""`. `loadScore(fileURL:)` for a `.pdf` throws `DomainError.unsupportedFormat("pdf")`.

- [ ] **Step 1: Write the failing test**

> Fixture note: create `sample.pdf` once with a script (do NOT inline a heredoc per repo bash rules). Write `Scripts/make-sample-pdf.swift` that uses PDFKit to build a 2-page PDF with `documentAttributes[.titleAttribute] = "Sample Title"`, run it with `swift Scripts/make-sample-pdf.swift <out>`, and move the output into the Fixtures dir. Commit the `.pdf` as a binary fixture.

```swift
import Foundation
import Testing
@testable import Infrastructure
import Domain

@Suite struct LiveScoreFileGatewayPDFTests {
    private func fixtureURL() -> URL {
        Bundle.module.url(forResource: "sample", withExtension: "pdf")!
    }

    @Test func loadFileMetadataReturnsPDFSummary() async throws {
        let gateway = LiveScoreFileGateway()
        let summary = try await gateway.loadFileMetadata(fileURL: fixtureURL())
        #expect(summary.title == "Sample Title")
        #expect(summary.lengthBeats == 0)
        #expect(summary.defaultTempoBpm == 0)
        #expect(summary.instrumentationSummary == "")
    }

    @Test func loadScoreRejectsPDF() async {
        let gateway = LiveScoreFileGateway()
        await #expect(throws: DomainError.self) {
            _ = try await gateway.loadScore(fileURL: fixtureURL())
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Infrastructure -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:InfrastructureTests/LiveScoreFileGatewayPDFTests` (from `Packages/Infrastructure`)
Expected: FAIL — non-exhaustive switch / unsupportedFormat thrown by current detect path.

- [ ] **Step 3: Implement the PDF branch**

At the top of `LiveScoreFileGateway.swift` add `import PDFKit`. Replace `loadFileMetadata` and add a PDF guard + `.pdf` switch case in `loadScore`:

```swift
public func loadFileMetadata(fileURL: URL) async throws -> ScoreFileSummary {
    if detectFormat(fileName: fileURL.lastPathComponent) == .pdf {
        return try Self.pdfSummary(fileURL: fileURL)
    }
    let (_, summary) = try await loadScore(fileURL: fileURL)
    return summary
}

/// Builds a metadata-only summary for a PDF without parsing any notation. `/Title` becomes the title when present;
/// musical fields are zeroed because a PDF carries no notation. Page count is intentionally not stored — the reader
/// reads it from the document at open time.
static func pdfSummary(fileURL: URL) throws -> ScoreFileSummary {
    guard let doc = PDFDocument(url: fileURL), doc.pageCount > 0 else {
        throw DomainError.scoreParseFailed(reason: "Unreadable or empty PDF")
    }
    let title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
        .flatMap { $0.isEmpty ? nil : $0 }
    return ScoreFileSummary(
        title: title,
        composer: nil,
        instrumentationSummary: "",
        lengthBeats: 0,
        defaultTempoBpm: 0,
        primaryKey: nil,
    )
}
```

In `loadScore`, immediately after the `guard let format = …` block, add:

```swift
if format == .pdf {
    throw DomainError.unsupportedFormat("pdf")
}
```

(The detached `switch format` still only handles the 5 parseable formats; PDF is rejected before it, so the switch stays exhaustive over the reachable cases. If the compiler requires the switch to handle `.pdf`, add `case .pdf: throw DomainError.unsupportedFormat("pdf")` inside it instead.)

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2. Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/ScoreFiles/LiveScoreFileGateway.swift Packages/Infrastructure/Tests/InfrastructureTests/LiveScoreFileGatewayPDFTests.swift Packages/Infrastructure/Tests/InfrastructureTests/Fixtures/sample.pdf Scripts/make-sample-pdf.swift
git commit -m "feat(infra): PDF metadata path in gateway; reject PDF in loadScore"
```

---

## Task 4: Import a PDF end-to-end (title from `/Title`)

**Files:**
- Modify: `Packages/Infrastructure/Sources/Persistence/LiveScoreFileImporter.swift:102-121` (the `ScoreItem` construction at commit).
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/PDFImportTests.swift`

**Interfaces:**
- Consumes: gateway PDF metadata (Task 3), `ImportPlan` (`sourceURL`, `stagedURL`, `format`, `summary`, `contentHash`, `sizeBytes`, `duplicates`), `ImportDecision.importAsNew`.
- Produces: importing `sample.pdf` yields a `ScoreItem` with `localFileName == "<id>.pdf"`, `title == "Sample Title"`, `lengthBeats == 0`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import Infrastructure
import Domain

@Suite struct PDFImportTests {
    @Test func importsPDFAsNewItem() async throws {
        let env = try ImporterTestEnvironment()          // existing helper used by other importer tests
        let src = Bundle.module.url(forResource: "sample", withExtension: "pdf")!
        let plan = try await env.importer.prepareImport(sourceURL: src)
        #expect(plan.format == .pdf)
        let item = try await env.importer.commitImport(plan, decision: .importAsNew)
        #expect(item.localFileName == "\(item.id.rawValue.uuidString).pdf")
        #expect(item.title == "Sample Title")
        #expect(item.lengthBeats == 0)
        #expect(ScoreFormat.detect(filename: item.localFileName) == .pdf)
    }
}
```

> If no shared `ImporterTestEnvironment` exists, mirror the setup in the nearest existing importer test (same package) — construct `LiveScoreFileImporter` with the same fakes it uses. Reuse, don't invent.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Infrastructure -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:InfrastructureTests/PDFImportTests` (from `Packages/Infrastructure`)
Expected: FAIL — title is filename-derived ("sample"), not "Sample Title".

- [ ] **Step 3: Use `/Title` for PDF in commit**

In `commitImport`, replace the `title:` argument so PDFs prefer `summary.title`, all other formats keep the existing filename-derived title:

```swift
let filenameTitle = ScorePresentation.title(fromFilename: plan.sourceURL.lastPathComponent)
let title = plan.format == .pdf ? (plan.summary.title ?? filenameTitle) : filenameTitle
let item = ScoreItem(
    id: id,
    title: title,
    subtitle: plan.summary.subtitle,
    composer: plan.summary.composer,
    arranger: plan.summary.arranger,
    lyricist: plan.summary.lyricist,
    copyright: plan.summary.copyright,
    instrumentationSummary: plan.summary.instrumentationSummary,
    localFileName: localFileName,
    contentHash: plan.contentHash,
    sizeBytes: plan.sizeBytes,
    lengthBeats: plan.summary.lengthBeats,
    defaultTempoBpm: plan.summary.defaultTempoBpm,
    primaryKey: plan.summary.primaryKey,
    addedAt: Date(),
    lastOpenedAt: nil,
    tagIDs: [],
    isFavorite: false,
)
```

(`localFileName` is already `"<id>.<format.canonicalExtension>"`, which yields `.pdf` for PDFs since Task 1 set `canonicalExtension`.)

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/Persistence/LiveScoreFileImporter.swift Packages/Infrastructure/Tests/InfrastructureTests/PDFImportTests.swift
git commit -m "feat(infra): import PDF as a ScoreItem using /Title"
```

---

## Task 5: Wire PDF into the file picker & document types

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift` (`ScoreFileTypes.allowed`).
- Modify: `App/Info.plist` (`CFBundleDocumentTypes`).

**Interfaces:**
- Produces: the document picker offers PDFs; the system "Open in folino" sheet lists folino for `.pdf`.

This task is verified by build + manual smoke (not a unit test — UTType/Info.plist plumbing isn't unit-testable). Fold the build check into the steps.

- [ ] **Step 1: Add `.pdf` to the importer's allowed types**

In `ScoreFileTypes.allowed`, append `.pdf` to the parent-fallback array:

```swift
static let allowed: [UTType] = {
    let specific = ["mscx", "mscz", "musicxml", "mxl"]
        .compactMap { UTType(filenameExtension: $0) }
    return specific + [.xml, .zip, .midi, .pdf]
}()
```

- [ ] **Step 2: Add a PDF document type to Info.plist**

In `App/Info.plist`, add a new dict to the `CFBundleDocumentTypes` array (after the MIDI entry). PDF is a system UTI (`com.adobe.pdf` / `public.pdf` via `UTType.pdf.identifier` = `com.adobe.pdf`), so no `UTImportedTypeDeclarations` entry is needed:

```xml
<dict>
    <key>CFBundleTypeName</key>
    <string>PDF Document</string>
    <key>LSHandlerRank</key>
    <string>Alternate</string>
    <key>LSItemContentTypes</key>
    <array>
        <string>com.adobe.pdf</string>
    </array>
</dict>
```

Use `LSHandlerRank` `Alternate` (folino is not the primary PDF handler).

- [ ] **Step 3: Build the app and confirm it compiles**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift App/Info.plist
git commit -m "feat(import): offer PDF in file picker and document types"
```

---

## Task 6: `ReaderCapabilities` (Domain)

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/ReaderCapabilities.swift`
- Test: `Packages/Domain/Tests/DomainTests/ReaderCapabilitiesTests.swift`

**Interfaces:**
- Produces:
  - `ReaderCapabilities.forScore` → `canPlay=true, canChangeLayout=true, canTranspose=true, canEditStaves=true, availableLayoutModes=[.vertical,.horizontal,.page]`.
  - `ReaderCapabilities.forPDF` → `canPlay=false, canChangeLayout=false, canTranspose=false, canEditStaves=false, availableLayoutModes=[.page,.vertical]`.
  - `static func resolve(format: ScoreFormat?) -> ReaderCapabilities` returning `.forPDF` when `format == .pdf`, else `.forScore`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Domain

@Suite struct ReaderCapabilitiesTests {
    @Test func pdfDisablesEverythingButPageAndVertical() {
        let c = ReaderCapabilities.resolve(format: .pdf)
        #expect(c.canPlay == false)
        #expect(c.canChangeLayout == false)
        #expect(c.canTranspose == false)
        #expect(c.canEditStaves == false)
        #expect(c.availableLayoutModes == [.page, .vertical])
    }

    @Test func scoreEnablesAll() {
        let c = ReaderCapabilities.resolve(format: .mscz)
        #expect(c.canPlay)
        #expect(c.canChangeLayout)
        #expect(c.availableLayoutModes == [.vertical, .horizontal, .page])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:DomainTests/ReaderCapabilitiesTests` (from `Packages/Domain`)
Expected: FAIL — type does not exist.

- [ ] **Step 3: Implement**

```swift
/// What a reader session is allowed to do, derived once from the item's format. PDFs carry no notation, so playback
/// and all layout-derivation settings are unavailable; only page and vertical-continuous viewing remain. This is the
/// single source of truth the reader UI consults — when PDF gains parsed playback later, only `resolve` changes.
public struct ReaderCapabilities: Hashable, Sendable {
    public var canPlay: Bool
    public var canChangeLayout: Bool
    public var canTranspose: Bool
    public var canEditStaves: Bool
    public var availableLayoutModes: [ReaderLayoutMode]

    public static let forScore = ReaderCapabilities(
        canPlay: true,
        canChangeLayout: true,
        canTranspose: true,
        canEditStaves: true,
        availableLayoutModes: [.vertical, .horizontal, .page],
    )

    public static let forPDF = ReaderCapabilities(
        canPlay: false,
        canChangeLayout: false,
        canTranspose: false,
        canEditStaves: false,
        availableLayoutModes: [.page, .vertical],
    )

    public static func resolve(format: ScoreFormat?) -> ReaderCapabilities {
        format == .pdf ? .forPDF : .forScore
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/ReaderCapabilities.swift Packages/Domain/Tests/DomainTests/ReaderCapabilitiesTests.swift
git commit -m "feat(domain): add ReaderCapabilities"
```

---

## Task 7: `LoadState.loadedPDF` + ViewModel PDF load branch

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` (`LoadState` enum lines 11-20; `load()` lines 270-286; add a stored `capabilities`).
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPDFLoadTests.swift`

**Interfaces:**
- Consumes: `ReaderCapabilities.resolve(format:)` (Task 6); `ScoreFormat.detect` (Task 1).
- Produces: after `load()` on a PDF item, `loadState` is `.loadedPDF(let doc)` with `doc.pageCount > 0`; `viewModel.capabilities == .forPDF`. The `LoadState.score` accessor still returns `nil` for `.loadedPDF`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import Reader
import Domain

@Suite @MainActor struct ReaderViewModelPDFLoadTests {
    @Test func loadsPDFIntoLoadedPDFState() async throws {
        let env = try ReaderTestEnvironment(fixtureResource: "sample", ext: "pdf")  // mirror existing reader test setup
        await env.viewModel.load()
        guard case let .loadedPDF(doc) = env.viewModel.loadState else {
            Issue.record("expected .loadedPDF, got \(env.viewModel.loadState)")
            return
        }
        #expect(doc.pageCount > 0)
        #expect(env.viewModel.capabilities == .forPDF)
    }
}
```

> Mirror the nearest existing `ReaderViewModel` test's environment construction (same package). If it injects a `gateway`/`annotationStore`/`scoresDirectory`, copy the fixture PDF into `scoresDirectory` as `<id>.pdf` and build the `ScoreItem` with that `localFileName`.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/ReaderViewModelPDFLoadTests` (from `Packages/Features/Reader`)
Expected: FAIL — `.loadedPDF` does not exist; PDF load currently routes to `.failed`.

- [ ] **Step 3: Extend `LoadState` and branch `load()`**

Add `import PDFKit` at the top of `ReaderViewModel.swift`. Extend the enum:

```swift
enum LoadState {
    case loading
    case loaded(Score)
    case loadedPDF(PDFDocument)
    case failed(error: Error)

    var score: Score? {
        if case let .loaded(score) = self { return score }
        return nil
    }
}
```

Add a stored capability (default `.forScore`) near the other stored properties:

```swift
private(set) var capabilities: ReaderCapabilities = .forScore
```

Branch `load()`:

```swift
func load() async {
    loadState = .loading
    visibleScore = nil
    let format = ScoreFormat.detect(filename: scoreItem.localFileName)
    capabilities = ReaderCapabilities.resolve(format: format)
    let url = scoresDirectory.appending(path: scoreItem.localFileName)
    if format == .pdf {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            loadState = .failed(error: DomainError.scoreParseFailed(reason: "Unreadable or empty PDF"))
            return
        }
        await loadOrSeedPreferences()
        clampLayoutModeToCapabilities()
        loadState = .loadedPDF(doc)
        await loadAnnotations()
        await updateLastOpenedAtOnce()
        return
    }
    do {
        let (score, _) = try await gateway.loadScore(fileURL: url)
        await loadOrSeedPreferences()
        loadState = .loaded(score)
        recomputeVisibleScore()
        pipSession.armIfReady()
        await loadAnnotations()
        await updateLastOpenedAtOnce()
    } catch {
        loadState = .failed(error: error)
        visibleScore = nil
    }
}
```

Add a helper that resets the persisted layout mode to a PDF-allowed one if it is currently `.horizontal`:

```swift
/// PDFs don't support horizontal mode. If the global layout mode is horizontal when a PDF opens, fall back to page so
/// the reader never lands in an unsupported mode. Page/vertical are left untouched.
private func clampLayoutModeToCapabilities() {
    let key = ReaderGlobalSettingsKey.layoutMode
    let raw = UserDefaults.standard.string(forKey: key) ?? ReaderLayoutMode.page.rawValue
    let mode = ReaderLayoutMode(rawValue: raw) ?? .page
    if !capabilities.availableLayoutModes.contains(mode) {
        UserDefaults.standard.set(ReaderLayoutMode.page.rawValue, forKey: key)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPDFLoadTests.swift
git commit -m "feat(reader): add loadedPDF state and PDF load branch"
```

---

## Task 8: `PDFPageProvider` (rasterizer + windowed cache)

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFPageProvider.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/PDFPageProviderTests.swift`

**Interfaces:**
- Produces:
  - `init(document: PDFDocument, windowRadius: Int = 2)`
  - `var pageCount: Int`
  - `func pageSize(_ index: Int) -> CGSize` (PDF point size of the page's `.mediaBox`)
  - `func image(pageIndex: Int, targetScale: CGFloat) -> CGImage?` — rasterizes at `targetScale` (points × scale = pixels), caches by page, and on a request for page *p* evicts pages outside `p ± windowRadius`. A repeat call at a higher `targetScale` returns a larger bitmap (re-rasterized).

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import PDFKit
import Testing
@testable import Reader

@Suite @MainActor struct PDFPageProviderTests {
    private func provider(window: Int = 2) -> PDFPageProvider {
        let url = Bundle.module.url(forResource: "sample", withExtension: "pdf")!
        return PDFPageProvider(document: PDFDocument(url: url)!, windowRadius: window)
    }

    @Test func rendersPageImage() {
        let p = provider()
        let img = p.image(pageIndex: 0, targetScale: 1)
        #expect(img != nil)
    }

    @Test func higherScaleYieldsLargerBitmap() {
        let p = provider()
        let small = p.image(pageIndex: 0, targetScale: 1)!
        let big = p.image(pageIndex: 0, targetScale: 2)!
        #expect(big.width > small.width)
    }

    @Test func reportsPageCount() {
        #expect(provider().pageCount >= 1)
    }
}
```

> Add `sample.pdf` to the Reader test bundle resources (copy the Task 3 fixture; ensure the Reader test target lists it under `resources`). Reuse the same binary.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/PDFPageProviderTests` (from `Packages/Features/Reader`)
Expected: FAIL — type does not exist.

- [ ] **Step 3: Implement**

```swift
import CoreGraphics
import PDFKit
import UIKit

/// Rasterizes PDF pages to `CGImage` on demand and caches a sliding window of pages around the one most recently
/// requested. The reader draws the cached bitmap (cheap to blit) instead of re-running `drawPDFPage` every frame; on a
/// zoom commit the caller re-requests the visible page at the new scale, replacing the cached bitmap so content stays
/// crisp. Memory stays bounded by `windowRadius` regardless of document length.
@MainActor
final class PDFPageProvider {
    let pageCount: Int
    private let document: PDFDocument
    private let windowRadius: Int
    private struct Entry { var image: CGImage; var scale: CGFloat }
    private var cache: [Int: Entry] = [:]

    init(document: PDFDocument, windowRadius: Int = 2) {
        self.document = document
        self.windowRadius = max(0, windowRadius)
        pageCount = document.pageCount
    }

    func pageSize(_ index: Int) -> CGSize {
        guard let page = document.page(at: index) else { return .zero }
        return page.bounds(for: .mediaBox).size
    }

    func image(pageIndex: Int, targetScale: CGFloat) -> CGImage? {
        guard pageIndex >= 0, pageIndex < pageCount else { return nil }
        evictOutsideWindow(center: pageIndex)
        let scale = max(0.1, targetScale)
        if let entry = cache[pageIndex], abs(entry.scale - scale) < 0.01 {
            return entry.image
        }
        guard let page = document.page(at: pageIndex) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: pixelSize))
            // Flip into PDF's bottom-left origin and scale points → pixels.
            cg.translateBy(x: 0, y: pixelSize.height)
            cg.scaleBy(x: scale, y: -scale)
            cg.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
            page.draw(with: .mediaBox, to: cg)
        }
        guard let cgImage = image.cgImage else { return nil }
        cache[pageIndex] = Entry(image: cgImage, scale: scale)
        return cgImage
    }

    func purge() { cache.removeAll() }

    private func evictOutsideWindow(center: Int) {
        let lo = center - windowRadius, hi = center + windowRadius
        for key in cache.keys where key < lo || key > hi {
            cache.removeValue(forKey: key)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2. Expected: PASS (all three).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFPageProvider.swift Packages/Features/Reader/Tests/ReaderTests/PDFPageProviderTests.swift
git commit -m "feat(reader): add PDFPageProvider with windowed raster cache"
```

---

## Task 9: `VerticalPDFContainer` (vertical-continuous viewing)

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Screens/PDF/VerticalPDFContainer.swift`

**Interfaces:**
- Consumes: `PDFPageProvider` (Task 8); `ScoreScrollHost` (existing generic: bindings `contentOffset`, `contentInsetTop`, `pendingScroll`; flags `alwaysBounceVertical/Horizontal`, `centerVertically/Horizontally`; `expectedContentSize: () -> CGSize`; `onPinchBegan/Changed/Ended`; `annotationOverlay`; `@ViewBuilder content`); `PinchState`.
- Produces: `VerticalPDFContainer(document: PDFDocument, viewModel: ReaderViewModel)`.

This is view code; it is verified by the integration build in Task 11 and manual smoke. No standalone unit test.

- [ ] **Step 1: Implement the container**

Vertical-continuous PDF: stack every page top-to-bottom at viewport width, scroll vertically, pinch-zoom via the same committed-zoom model the score containers use. The page width is the viewport width × committed zoom; each page's height follows its aspect ratio. Pages render through `PDFPageProvider` at the on-screen pixel scale.

```swift
import PDFKit
import SwiftUI

/// Vertical-continuous PDF viewing. Pages are stacked at viewport width and scrolled vertically, riding the shared
/// `ScoreScrollHost` scroll/pinch infrastructure so zoom and gestures match the score reader. Distinct from the score
/// vertical *reflow* (PDFs are fixed-layout): here "vertical" just means a continuous scroll of fixed pages.
struct VerticalPDFContainer: View {
    let document: PDFDocument
    @Bindable var viewModel: ReaderViewModel

    @State private var provider: PDFPageProvider?
    @State private var contentOffset: CGPoint = .zero
    @State private var contentInsetTop: CGFloat = 0
    @State private var pendingScroll: ScoreScrollCommand?
    @State private var pinch = PinchState()
    @State private var committedZoom: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let provider = ensureProvider()
            let baseWidth = geo.size.width
            ScoreScrollHost(
                contentOffset: $contentOffset,
                contentInsetTop: $contentInsetTop,
                pendingScroll: $pendingScroll,
                alwaysBounceVertical: true,
                alwaysBounceHorizontal: false,
                centerVertically: false,
                centerHorizontally: true,
                expectedContentSize: { expectedSize(provider: provider, baseWidth: baseWidth) },
                onPinchBegan: { anchor, _ in pinch.anchor = anchor },
                onPinchChanged: { scale, _ in pinch.magnification = scale },
                onPinchEnded: { scale, _, _ in
                    committedZoom = clampZoom(committedZoom * scale)
                    pinch.magnification = 1
                },
            ) {
                pageStack(provider: provider, baseWidth: baseWidth)
                    .scaleEffect(pinch.magnification, anchor: pinch.anchor)
            }
        }
    }

    private func pageStack(provider: PDFPageProvider, baseWidth: CGFloat) -> some View {
        let width = baseWidth * committedZoom
        return VStack(spacing: 8) {
            ForEach(0 ..< provider.pageCount, id: \.self) { index in
                PDFPageImage(provider: provider, index: index, width: width)
            }
        }
    }

    private func expectedSize(provider: PDFPageProvider, baseWidth: CGFloat) -> CGSize {
        let width = baseWidth * committedZoom
        var height: CGFloat = 0
        for i in 0 ..< provider.pageCount {
            let size = provider.pageSize(i)
            height += size.height == 0 ? 0 : width * (size.height / size.width)
            height += 8
        }
        return CGSize(width: width, height: height)
    }

    private func ensureProvider() -> PDFPageProvider {
        if let provider { return provider }
        let new = PDFPageProvider(document: document)
        DispatchQueue.main.async { self.provider = new }
        return new
    }

    private func clampZoom(_ z: CGFloat) -> CGFloat { min(max(z, 1), 6) }
}

/// One page rendered at `width` points. Re-rasterizes via the provider whenever the on-screen width (× display scale)
/// changes, so content is sharp at the committed zoom level.
private struct PDFPageImage: View {
    let provider: PDFPageProvider
    let index: Int
    let width: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let size = provider.pageSize(index)
        let height = size.width == 0 ? width : width * (size.height / size.width)
        return Group {
            if let cg = provider.image(pageIndex: index, targetScale: max(0.1, (width / max(size.width, 1)) * displayScale)) {
                Image(decorative: cg, scale: displayScale).resizable()
            } else {
                Color(.secondarySystemBackground)
            }
        }
        .frame(width: width, height: height)
    }
}
```

- [ ] **Step 2: Build the Reader package**

Run: `xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'` (from `Packages/Features/Reader`)
Expected: BUILD SUCCEEDED (confirm with `Compiling VerticalPDFContainer.swift` in the log, per the feature-package verification rule).

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/PDF/VerticalPDFContainer.swift
git commit -m "feat(reader): add VerticalPDFContainer"
```

---

## Task 10: `PagedPDFContainer` (page mode)

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Screens/PDF/PagedPDFContainer.swift`

**Interfaces:**
- Consumes: `PDFPageProvider` (Task 8); `PageState` (existing `@Observable`: `pageIndex`, `freezeFirstPageOffset`, `dragTranslationX`, `isDragging`); `TapOverlay` (existing — leading/trailing tap columns); `ScoreScrollHost`.
- Produces: `PagedPDFContainer(document: PDFDocument, viewModel: ReaderViewModel)`.

Page count = `provider.pageCount` (1 physical page = 1 reader page). Page-turn uses the same `PageState` + `TapOverlay` + zoom-reset pattern as `PagedScoreContainer`.

- [ ] **Step 1: Implement the container**

```swift
import PDFKit
import SwiftUI

/// Page-mode PDF viewing: one physical PDF page per reader page, with the same tap-zone page turn, zoom reset, and turn
/// animation as the score paged reader. Page boundaries come straight from the PDF page count instead of system
/// pagination.
struct PagedPDFContainer: View {
    let document: PDFDocument
    @Bindable var viewModel: ReaderViewModel

    @State private var provider: PDFPageProvider?
    @State private var pageState = PageState()
    @State private var pinch = PinchState()
    @State private var committedZoom: CGFloat = 1

    private let pageTransition: Animation = .easeOut(duration: 0.18)

    var body: some View {
        GeometryReader { geo in
            let provider = ensureProvider()
            ZStack {
                currentPage(provider: provider, viewport: geo.size)
                    .scaleEffect(pinch.magnification, anchor: pinch.anchor)
                TapOverlay(
                    onNextPage: { turn(by: 1, pageCount: provider.pageCount) },
                    onPrevPage: { turn(by: -1, pageCount: provider.pageCount) },
                    onFirstPage: { goTo(0) },
                    onLastPage: { goTo(provider.pageCount - 1) },
                )
            }
        }
    }

    private func currentPage(provider: PDFPageProvider, viewport: CGSize) -> some View {
        let index = min(max(pageState.pageIndex, 0), max(provider.pageCount - 1, 0))
        let size = provider.pageSize(index)
        // Fit the page within the viewport (contain), then apply committed zoom.
        let fit = fitScale(page: size, viewport: viewport)
        let width = size.width * fit * committedZoom
        let height = size.height * fit * committedZoom
        return Group {
            if let cg = provider.image(pageIndex: index, targetScale: fit * committedZoom * UIScreen.main.scale) {
                Image(decorative: cg, scale: UIScreen.main.scale).resizable()
            } else {
                Color(.secondarySystemBackground)
            }
        }
        .frame(width: width, height: height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fitScale(page: CGSize, viewport: CGSize) -> CGFloat {
        guard page.width > 0, page.height > 0 else { return 1 }
        return min(viewport.width / page.width, viewport.height / page.height)
    }

    private func turn(by delta: Int, pageCount: Int) {
        goTo(min(max(pageState.pageIndex + delta, 0), max(pageCount - 1, 0)))
    }

    private func goTo(_ index: Int) {
        committedZoom = 1
        pinch.magnification = 1
        withAnimation(pageTransition) { pageState.pageIndex = index }
    }

    private func ensureProvider() -> PDFPageProvider {
        if let provider { return provider }
        let new = PDFPageProvider(document: document)
        DispatchQueue.main.async { self.provider = new }
        return new
    }
}
```

> If `TapOverlay`'s initializer differs from the closure labels above, match its real signature (it is the same control `PagedScoreContainer` uses — reuse it exactly, adapting closure names).

- [ ] **Step 2: Build the Reader package**

Run: `xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'` (from `Packages/Features/Reader`)
Expected: BUILD SUCCEEDED (confirm `Compiling PagedPDFContainer.swift`).

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/PDF/PagedPDFContainer.swift
git commit -m "feat(reader): add PagedPDFContainer"
```

---

## Task 11: Dispatch PDF containers from `ReaderRootScreen`

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift` (the `content` switch, lines 183-249; the `layoutMode` computed property lines 33-39).

**Interfaces:**
- Consumes: `LoadState.loadedPDF` (Task 7); `PagedPDFContainer` / `VerticalPDFContainer` (Tasks 9-10); `viewModel.capabilities`.
- Produces: a PDF renders in page or vertical mode; horizontal is never reachable for PDF.

- [ ] **Step 1: Add a `.loadedPDF` branch to `content`**

In the `switch viewModel.loadState` add, after the `.loaded` case:

```swift
case let .loadedPDF(document):
    switch pdfLayoutMode {
    case .vertical:
        VerticalPDFContainer(document: document, viewModel: viewModel)
    case .page, .horizontal:
        PagedPDFContainer(document: document, viewModel: viewModel)
    }
```

Add a computed property that resolves the persisted layout mode against PDF capabilities (horizontal collapses to page):

```swift
/// The layout mode to use for PDFs: the persisted mode if it is PDF-allowed, else page. Guards against a stale
/// horizontal selection carried over from a score.
private var pdfLayoutMode: ReaderLayoutMode {
    viewModel.capabilities.availableLayoutModes.contains(layoutMode) ? layoutMode : .page
}
```

- [ ] **Step 2: Build the app**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift
git commit -m "feat(reader): dispatch PDF containers by layout mode"
```

---

## Task 12: Gate playback & inspectors; add PDF layout inspector

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFLayoutInspectorScreen.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift` (inspector buttons, lines 110-154).
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderTransportControl.swift` (gate transport on `canPlay`).
- Strings: `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings` (or the Reader module's existing `.xcstrings`) — add `reader.pdf.settingsNote` and `reader.pdf.layoutSection`.

**Interfaces:**
- Consumes: `viewModel.capabilities`; `LoadState.loadedPDF`.
- Produces: for a PDF, the top overlay shows a single layout-inspector button (page/vertical + note); no playback inspector button; the transport control shows no playback affordances.

- [ ] **Step 1: Create the PDF layout inspector**

```swift
import Domain
import SwiftUI

/// The PDF reader's only inspector: a page/vertical mode toggle plus a one-line note explaining that display
/// adjustment and playback are unavailable for PDFs. Mirrors the score Visual inspector's layout row, restricted to the
/// two PDF-allowed modes.
struct PDFLayoutInspectorScreen: View {
    @AppStorage(ReaderGlobalSettingsKey.layoutMode)
    private var layoutModeRaw: String = ReaderLayoutMode.page.rawValue

    var body: some View {
        List {
            Section {
                HStack {
                    Text("reader.preferences.layoutDirection", bundle: .module)
                    Spacer()
                    Picker(selection: $layoutModeRaw) {
                        Image(systemName: "book.pages").tag(ReaderLayoutMode.page.rawValue)
                        Image(systemName: "arrow.up.and.down.text.horizontal")
                            .tag(ReaderLayoutMode.vertical.rawValue)
                    } label: {
                        Text("reader.preferences.layoutDirection", bundle: .module)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 96)
                    .fixedSize()
                }
            } footer: {
                Text("reader.pdf.settingsNote", bundle: .module)
            }
        }
    }
}
```

Add the string `reader.pdf.settingsNote` with value (en) `"Display adjustment and playback aren't available for PDF scores."` and an appropriate Japanese translation `"PDF 楽譜では表示調整・再生は利用できません。"`.

- [ ] **Step 2: Gate the inspector buttons in `ReaderTopOverlay`**

The current `inspectorButtons(score:)` requires a `Score`. Add a PDF-aware path. Where the overlay decides what to show (the call site that currently passes a `Score`), branch on capabilities:

```swift
// Where inspector buttons are rendered:
if viewModel.capabilities.canPlay {
    inspectorButtons(score: score)        // existing: playback + visual, needs a Score
} else {
    pdfLayoutButton                       // new: single layout button
}
```

Add:

```swift
private var pdfLayoutButton: some View {
    overlayButton(
        systemImage: "text.page",
        label: Text("reader.toolbar.showDisplaySettings", bundle: .module),
    ) {
        viewModel.isVisualInspectorPresented.toggle()
    }
    .popover(isPresented: $viewModel.isVisualInspectorPresented) {
        PDFLayoutInspectorScreen()
            .frame(idealWidth: 320, idealHeight: 200)
            .presentationDetents([.medium])
            .presentationCompactAdaptation(.sheet)
    }
}
```

> The top overlay only has a `Score` in the `.loaded` case. For `.loadedPDF` there is no `Score`, so the existing `inspectorButtons(score:)` is never reached (its call is already inside a `case .loaded`/`if let score`). Ensure the overlay renders `pdfLayoutButton` in the `.loadedPDF` case. If the overlay currently keys off `case .loaded`, add an `else if case .loadedPDF = viewModel.loadState` branch that shows `pdfLayoutButton` and the badge (Task 13).

- [ ] **Step 3: Gate the transport control**

`ReaderTransportControl`'s `collapsedLayout` already guards the transport pill on `if case .loaded = viewModel.loadState`, so `.loadedPDF` shows no transport pill automatically. Confirm the expanded/seek-bar paths are likewise gated. Add an explicit guard at the top of the transport row so playback never renders without `canPlay`:

```swift
// In ReaderTransportControl, wrap the transport content:
if viewModel.capabilities.canPlay {
    // existing transport row / pill
}
```

Keep the reset-zoom and any page-navigation affordances available (they apply to PDFs too).

- [ ] **Step 4: Build the app**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFLayoutInspectorScreen.swift Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift Packages/Features/Reader/Sources/Reader/Screens/ReaderTransportControl.swift Packages/Features/Reader/Sources/Reader/Resources
git commit -m "feat(reader): gate playback/inspectors for PDF; add PDF layout inspector"
```

---

## Task 13: "PDF" badge in reader header and library row

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift` (header).
- Modify: `Packages/Features/Library/Sources/Library/Views/ScoreRow.swift` (lines 8-19).

**Interfaces:**
- Consumes: `viewModel.capabilities` (reader); `ScoreFormat.detect(filename: scoreItem.localFileName)` (library row).
- Produces: a literal `"PDF"` pill in both places, shown only for PDFs.

- [ ] **Step 1: Define a shared badge view**

Add a small reusable badge near the top overlay (or in a shared Reader/Library view file — if a shared UI module is the right home, place it in `UtilityUI`; otherwise duplicate the trivial view in each module to avoid a new cross-module dependency). Minimal pill:

```swift
struct PDFBadge: View {
    var body: some View {
        Text(verbatim: "PDF")            // brand literal — NOT localized
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.18), in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text(verbatim: "PDF"))
    }
}
```

- [ ] **Step 2: Show the badge in the reader header**

In `ReaderTopOverlay`, in the header HStack (near the back button / title area), add when the item is a PDF:

```swift
if !viewModel.capabilities.canPlay {   // canPlay==false ⇔ PDF in this plan
    PDFBadge()
}
```

- [ ] **Step 3: Show the badge in the library row**

In `ScoreRow.swift`, add the badge beside the title. Reuse the same `.overlay`/`HStack` area as the favorite star. Compute PDF-ness from the filename:

```swift
private var isPDF: Bool {
    ScoreFormat.detect(filename: scoreItem.localFileName) == .pdf
}
```

Render it after the title text (trailing), e.g. inside the title `HStack`:

```swift
HStack(spacing: 4) {
    Text("\(titleText) \(subtitleText)")
        .lineLimit(1)
        .overlay(alignment: .leading) {
            if scoreItem.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.tint)
                    .offset(x: -12)
                    .accessibilityLabel(Text("library.score.favorite.action", bundle: .module))
            }
        }
    if isPDF { PDFBadge() }
}
```

- [ ] **Step 4: Build the app**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Render-verify the badge (preview)**

Add a `#Preview` to `ScoreRow.swift` with a PDF `ScoreItem` (`localFileName: "x.pdf"`) and a non-PDF one, render via `mcp__xcode__RenderPreview`, and confirm the pill shows only on the PDF row.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift Packages/Features/Library/Sources/Library/Views/ScoreRow.swift
git commit -m "feat: add PDF badge in reader header and library row"
```

---

## Task 14: Full-app test pass & manual smoke

**Files:** none (verification task).

- [ ] **Step 1: Run the Domain + Infrastructure + Reader package tests**

Run each from its package dir:
- `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'`
- `xcodebuild test -scheme Infrastructure -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'`
- `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'`

Expected: all PASS.

- [ ] **Step 2: Build the full app**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Hand off manual verification to the user**

Per project workflow, do NOT auto-launch the simulator. Ask the user to clean-build and verify on device/simulator:
- Import a `.pdf` (share sheet + document picker) → appears in library with a "PDF" badge.
- Open it → renders in page mode; tap-zone page turn; pinch-zoom stays crisp after release.
- Switch to vertical mode via the layout inspector → continuous scroll of pages.
- Confirm no playback controls, no staff-size/transpose/clef/visibility settings, no horizontal mode.
- Confirm the one-line "settings unavailable" note in the PDF layout inspector.
- Confirm the "PDF" badge in the reader header.

---

## Out of Scope (follow-up plans)

- **PDF PencilKit annotation** — page-relative anchors (`DrawingAnchorKind`), PDF capture/display, canvas integration into the PDF containers. Separate plan `2026-06-26-pdf-annotation.md`.
- **Library thumbnails** — no thumbnail infrastructure exists for any format today; adding first-page PDF thumbnails (and score thumbnails) is a separate feature.
- **Playback cursor / notation parse on PDF** — future `swift-sheet-music` work.
- **Android** — shared logic (format detection, capability model) must remain platform-neutral; the Android PDF reader/rasterizer is a separate Android plan.

## Self-Review Notes

- Spec coverage: import (T1–T5), reader page+vertical (T7–T11), gating + note (T6, T12), badge (T13). Annotation and thumbnails explicitly deferred with rationale.
- Type consistency: `LoadState.loadedPDF(PDFDocument)`, `ReaderCapabilities.resolve(format:)`, `PDFPageProvider.image(pageIndex:targetScale:)`, `PDFBadge`, `pdfLayoutMode` used consistently across tasks.
- Known integration risk flagged in T9/T10/T12: exact `ScoreScrollHost` content/zoom wiring and `TapOverlay` initializer must match the existing score containers — the plan instructs mirroring them rather than inventing new gesture code.

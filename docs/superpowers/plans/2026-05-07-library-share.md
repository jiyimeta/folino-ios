# Library Share Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-row share support to the Library, exposing source-format / PDF / MIDI export via the standard iOS share sheet, reachable from both the long-press context menu and a new trailing ellipsis button.

**Architecture:** A new Domain protocol `ScoreShareService` describes "materialize an item in a chosen format and return a URL." `Infrastructure/ScoreFiles/LiveScoreShareService` implements it on top of `swift-sheet-music` (`MSCZWriter`, `PDFExporter`, `SheetMusic.exportMIDI`) and the existing `ScoreFileGateway`. The Library feature exposes a single `scoreRowMenu` view-builder driven by a new `requestShare` method on `LibraryViewModel`, presented through a share sheet wrapper added to `Utility/UtilityUI`.

**Tech Stack:** Swift 6.3, SwiftUI, Swift Testing (`@Test`/`#expect`), `swift-sheet-music` (`SheetMusic`, `SheetMusicMSCX.MSCZWriter`, `SheetMusicPDF.PDFExporter`), iOS 26+ only.

---

## File Structure

**Create:**
- `Packages/Domain/Sources/Domain/Protocols/ScoreShareService.swift` — `ScoreShareFormat` enum + `ScoreShareService` protocol.
- `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift` — concrete share service, dispatches per format, manages temp directory.
- `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift` — round-trip + magic-byte + sanitization tests.
- `Packages/Utility/Sources/UtilityUI/ActivityViewControllerRepresentable.swift` — iOS-only `UIActivityViewController` wrapper.
- `Packages/Features/Library/Sources/Library/ScoreRowMenu.swift` — single source of truth for the row menu (long-press + ellipsis).
- `Packages/Features/Library/Tests/LibraryTests/Fakes/FakeScoreShareService.swift` — in-memory fake for view-model tests.
- `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelShareTests.swift` — share-flow tests.

**Modify:**
- `Packages/Features/Library/Package.swift:23-30` — add `UtilityUI` to `Library` target deps (already present — sanity check, no edit if so).
- `Packages/Features/Library/Sources/Library/LibraryViewModel.swift` — inject `shareService`, add `shareTarget`, `isPreparingShare`, `requestShare`.
- `Packages/Features/Library/Sources/Library/ScoreListView.swift` — replace inline `contextMenuButtons` with `scoreRowMenu`, add trailing ellipsis.
- `Packages/Features/Library/Sources/Library/LibraryRootView.swift` — replace inline `rowContextMenu`, add trailing ellipsis to favorites/recents, present share sheet + preparing overlay.
- `Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings` — add `"Share…"`, `"Preparing…"`, `"More"`.
- `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift` — update `makeVM` to wire the new fake.
- `App/AppPaths.swift` — add `shareTempDirectory`.
- `App/AppBootstrap.swift` — wipe-and-recreate `shareTempDirectory` at launch, build `LiveScoreShareService`.
- `App/AppShellView.swift` — thread `shareService` into `LibraryViewModel`.

---

## Task 1: Domain — `ScoreShareFormat` and `ScoreShareService`

Domain stays Foundation-only: no UTType, no UIKit, no labels.

**Files:**
- Create: `Packages/Domain/Sources/Domain/Protocols/ScoreShareService.swift`

- [ ] **Step 1: Create the protocol file**

```swift
import Foundation

/// Selectable share format on a library row. `.sourceFormat` is the
/// "share what came in" entry; the concrete on-disk format it resolves
/// to depends on the item — see `ScoreShareService.resolvedSourceFormat(for:)`.
public enum ScoreShareFormat: Hashable, Sendable {
    case sourceFormat
    case pdf
    case midi
}

/// Materializes a `ScoreItem` in a requested share format as a temporary
/// file and returns its URL. Domain-pure: no UI, no UTType, no locale.
public protocol ScoreShareService: Sendable {
    /// Selectable formats for this item, in display order. All v1 items
    /// return `[.sourceFormat, .pdf, .midi]`.
    func availableFormats(for item: ScoreItem) -> [ScoreShareFormat]

    /// What the source-format entry resolves to for this item. Library
    /// uses this to build the menu label. `.mscx` resolves to `.mscz`
    /// (wrapped via MSCZWriter); other formats resolve to themselves.
    func resolvedSourceFormat(for item: ScoreItem) -> ScoreFormat

    /// Materialize the chosen format as a temporary file and return its
    /// URL. The implementation manages the temp directory; callers must
    /// not delete the returned file.
    func prepareShare(
        item: ScoreItem,
        format: ScoreShareFormat
    ) async throws -> URL
}
```

- [ ] **Step 2: Build Domain in isolation**

Run: `cd Packages/Domain && swift build`
Expected: Build succeeds. No tests added — `ScoreShareFormat` is a plain enum and the protocol has no behavior.

- [ ] **Step 3: Commit**

```bash
git add Packages/Domain/Sources/Domain/Protocols/ScoreShareService.swift
git commit -m "feat(domain): add ScoreShareService protocol and ScoreShareFormat"
```

---

## Task 2: Infrastructure — `LiveScoreShareService` skeleton + format helpers

Stubs the live service so the Library can be wired against the real type. Implements only `availableFormats(for:)` and `resolvedSourceFormat(for:)`; `prepareShare` throws `unsupportedFormat` until subsequent tasks fill it in.

**Files:**
- Create: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift`
- Create: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@testable import Domain
import Foundation
@testable import ScoreFiles
import SheetMusic
import Testing

@Suite struct LiveScoreShareServiceTests {
    private static func makeItem(localFileName: String) -> ScoreItem {
        ScoreItem(
            title: "T", composer: nil, instrumentationSummary: nil,
            localFileName: localFileName, contentHash: "h",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120,
            primaryKey: nil, addedAt: .init(timeIntervalSince1970: 0),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }

    private static func makeService(in tmp: URL) -> LiveScoreShareService {
        LiveScoreShareService(
            scoresDirectory: tmp.appending(path: "Scores"),
            shareTempDirectory: tmp.appending(path: "Share"),
            gateway: LiveScoreFileGateway()
        )
    }

    @Test func availableFormatsAlwaysReturnsAllThree() throws {
        let tmp = try TempDirectory()
        let svc = Self.makeService(in: tmp.url)
        let item = Self.makeItem(localFileName: "abc.mscz")
        #expect(svc.availableFormats(for: item) == [.sourceFormat, .pdf, .midi])
    }

    @Test func resolvedSourceFormatMapsMSCXToMSCZ() throws {
        let tmp = try TempDirectory()
        let svc = Self.makeService(in: tmp.url)
        #expect(svc.resolvedSourceFormat(for: Self.makeItem(localFileName: "x.mscx")) == .mscz)
        #expect(svc.resolvedSourceFormat(for: Self.makeItem(localFileName: "x.mscz")) == .mscz)
        #expect(svc.resolvedSourceFormat(for: Self.makeItem(localFileName: "x.musicxml")) == .musicXML)
        #expect(svc.resolvedSourceFormat(for: Self.makeItem(localFileName: "x.mxl")) == .mxl)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreShareServiceTests`
Expected: Compilation error — `LiveScoreShareService` not defined.

- [ ] **Step 3: Add the service skeleton**

```swift
import Domain
import Foundation
import SheetMusic

/// Live `ScoreShareService` backed by `swift-sheet-music`. Companion to
/// `LiveScoreFileGateway` in the same module.
public struct LiveScoreShareService: ScoreShareService {
    private let scoresDirectory: URL
    private let shareTempDirectory: URL
    private let gateway: any ScoreFileGateway

    public init(
        scoresDirectory: URL,
        shareTempDirectory: URL,
        gateway: any ScoreFileGateway
    ) {
        self.scoresDirectory = scoresDirectory
        self.shareTempDirectory = shareTempDirectory
        self.gateway = gateway
    }

    public func availableFormats(for _: ScoreItem) -> [ScoreShareFormat] {
        // TODO: re-evaluate when LiveScoreFileGateway gains MIDI parsing —
        // PDF/MIDI for a `.midi` item would fail with `scoreParseFailed`
        // until then. Imports of `.midi` are currently blocked.
        [.sourceFormat, .pdf, .midi]
    }

    public func resolvedSourceFormat(for item: ScoreItem) -> ScoreFormat {
        // localFileName follows the import-time invariant
        // "<id>.<canonical-extension>", so detect() is total here.
        switch ScoreFormat.detect(filename: item.localFileName)! {
        case .mscx, .mscz: .mscz
        case .musicXML: .musicXML
        case .mxl: .mxl
        case .midi: .midi
        }
    }

    public func prepareShare(
        item _: ScoreItem,
        format _: ScoreShareFormat
    ) async throws -> URL {
        throw DomainError.unsupportedFormat("share")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreShareServiceTests`
Expected: Both tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift
git commit -m "feat(infra): scaffold LiveScoreShareService with format helpers"
```

---

## Task 3: Infrastructure — title sanitization helper

Pure function so the path-construction tests stay fast and don't need files on disk.

**Files:**
- Modify: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift`
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `LiveScoreShareServiceTests`:

```swift
    @Test func sanitizeTitleReplacesPathAndNullBytes() {
        #expect(LiveScoreShareService.sanitize(title: "a/b") == "a_b")
        #expect(LiveScoreShareService.sanitize(title: "a:b") == "a_b")
        #expect(LiveScoreShareService.sanitize(title: "a\\b") == "a_b")
        #expect(LiveScoreShareService.sanitize(title: "a\u{0000}b") == "a_b")
    }

    @Test func sanitizeTitleTrimsTo100Chars() {
        let input = String(repeating: "x", count: 250)
        #expect(LiveScoreShareService.sanitize(title: input).count == 100)
    }

    @Test func sanitizeTitleFallsBackToScoreWhenEmpty() {
        #expect(LiveScoreShareService.sanitize(title: "") == "score")
        #expect(LiveScoreShareService.sanitize(title: "///") == "score")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreShareServiceTests`
Expected: Compile error — `sanitize` not found.

- [ ] **Step 3: Add sanitization helper**

Inside `LiveScoreShareService`, just below the initializer, add:

```swift
    /// Internal for tests. Replaces filesystem-hostile characters,
    /// trims to ≤100 chars, falls back to `"score"` if empty.
    static func sanitize(title: String) -> String {
        let bad: Set<Character> = ["/", ":", "\\", "\u{0000}"]
        let cleaned = String(title.map { bad.contains($0) ? "_" : $0 })
        let stripped = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_ "))
        let candidate = stripped.isEmpty ? "score" : stripped
        return String(candidate.prefix(100))
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreShareServiceTests`
Expected: All five tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift
git commit -m "feat(infra): add filename sanitization for share output"
```

---

## Task 4: Infrastructure — `prepareShare` for source-format pass-through (mscz / musicxml / mxl)

For non-mscx source formats the share is `FileManager.copyItem` from the scores directory into the temp directory.

**Files:**
- Modify: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift`
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Append:

```swift
    @Test func prepareShareSourceMSCZCopiesBytesIntoTemp() async throws {
        let tmp = try TempDirectory()
        let scores = tmp.url.appending(path: "Scores")
        let shareTmp = tmp.url.appending(path: "Share")
        try FileManager.default.createDirectory(at: scores, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shareTmp, withIntermediateDirectories: true)

        let mscz = try Fixtures.minimalMSCZData()
        let local = "abc.mscz"
        try mscz.write(to: scores.appending(path: local))

        let svc = LiveScoreShareService(
            scoresDirectory: scores,
            shareTempDirectory: shareTmp,
            gateway: LiveScoreFileGateway()
        )
        let item = Self.makeItem(localFileName: local)

        let url = try await svc.prepareShare(item: item, format: .sourceFormat)
        #expect(url.deletingLastPathComponent().path == shareTmp.path)
        #expect(url.pathExtension == "mscz")
        #expect(try Data(contentsOf: url) == mscz)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreShareServiceTests/prepareShareSourceMSCZCopiesBytesIntoTemp`
Expected: Fails — `prepareShare` throws `unsupportedFormat`.

- [ ] **Step 3: Implement source-format dispatch**

Replace the body of `prepareShare` and add helpers:

```swift
    public func prepareShare(
        item: ScoreItem,
        format: ScoreShareFormat
    ) async throws -> URL {
        let title = Self.sanitize(title: item.title)
        switch format {
        case .sourceFormat:
            return try await prepareSourceFormat(item: item, sanitizedTitle: title)
        case .pdf, .midi:
            throw DomainError.unsupportedFormat("share")
        }
    }

    private func prepareSourceFormat(
        item: ScoreItem,
        sanitizedTitle: String
    ) async throws -> URL {
        let sourceURL = scoresDirectory.appending(path: item.localFileName)
        let resolved = resolvedSourceFormat(for: item)
        let destination = shareTempDirectory.appending(
            path: "\(sanitizedTitle).\(resolved.canonicalExtension)"
        )
        try? FileManager.default.removeItem(at: destination)

        guard let onDisk = ScoreFormat.detect(filename: item.localFileName) else {
            throw DomainError.unsupportedFormat(sourceURL.pathExtension)
        }
        if onDisk == .mscx {
            // Filled in by Task 5.
            throw DomainError.unsupportedFormat("mscx")
        }
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            throw DomainError.scoreFileNotFound(name: item.localFileName)
        }
        return destination
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreShareServiceTests`
Expected: All tests pass, including the new mscz copy test.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift
git commit -m "feat(infra): prepareShare copies non-mscx source files into temp"
```

---

## Task 5: Infrastructure — `prepareShare` wraps `.mscx` via `MSCZWriter`

**Files:**
- Modify: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift`
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Append:

```swift
    @Test func prepareShareWrapsMSCXAsMSCZ() async throws {
        let tmp = try TempDirectory()
        let scores = tmp.url.appending(path: "Scores")
        let shareTmp = tmp.url.appending(path: "Share")
        try FileManager.default.createDirectory(at: scores, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shareTmp, withIntermediateDirectories: true)

        let mscx = try Fixtures.minimalMSCXData()
        let local = "abc.mscx"
        try mscx.write(to: scores.appending(path: local))

        let svc = LiveScoreShareService(
            scoresDirectory: scores,
            shareTempDirectory: shareTmp,
            gateway: LiveScoreFileGateway()
        )
        let item = Self.makeItem(localFileName: local)

        let url = try await svc.prepareShare(item: item, format: .sourceFormat)
        #expect(url.pathExtension == "mscz")
        // Round-trip: produced bytes load via SheetMusic's .mscz parser.
        let bytes = try Data(contentsOf: url)
        _ = try SheetMusic.loadScore(msczData: bytes)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreShareServiceTests/prepareShareWrapsMSCXAsMSCZ`
Expected: Fails — currently throws `unsupportedFormat("mscx")`.

- [ ] **Step 3: Replace the mscx branch with the wrap**

Add at the top of the file:

```swift
import SheetMusicMSCX
```

Replace the `if onDisk == .mscx { throw ... }` block with:

```swift
        if onDisk == .mscx {
            let mscxData: Data
            do {
                mscxData = try Data(contentsOf: sourceURL)
            } catch {
                throw DomainError.scoreFileNotFound(name: item.localFileName)
            }
            let msczData: Data
            do {
                msczData = try MSCZWriter.write(mscxData: mscxData)
            } catch {
                throw DomainError.scoreWriteFailed(reason: "\(error)")
            }
            do {
                try msczData.write(to: destination)
            } catch {
                throw DomainError.scoreWriteFailed(reason: "\(error)")
            }
            return destination
        }
```

If `SheetMusicMSCX` is not already a transitive product of `SheetMusic`, add it to the `ScoreFiles` target dependencies in `Packages/Infrastructure/Package.swift`. Verify by building first; only edit `Package.swift` if the build complains about the import.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreShareServiceTests`
Expected: All tests pass, including the new mscx wrap.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift \
        Packages/Infrastructure/Package.swift
git commit -m "feat(infra): wrap mscx as mscz via MSCZWriter for share"
```

(Drop `Package.swift` from the `git add` if it wasn't modified.)

---

## Task 6: Infrastructure — `prepareShare` for `.pdf`

`PDFExporter` is `@MainActor`; load detached, then hop to main for the render.

**Files:**
- Modify: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift`
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Append:

```swift
    @Test func prepareSharePDFStartsWithPDFMagic() async throws {
        let tmp = try TempDirectory()
        let scores = tmp.url.appending(path: "Scores")
        let shareTmp = tmp.url.appending(path: "Share")
        try FileManager.default.createDirectory(at: scores, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shareTmp, withIntermediateDirectories: true)

        let mscz = try Fixtures.minimalMSCZData()
        let local = "abc.mscz"
        try mscz.write(to: scores.appending(path: local))

        let svc = LiveScoreShareService(
            scoresDirectory: scores,
            shareTempDirectory: shareTmp,
            gateway: LiveScoreFileGateway()
        )
        let item = Self.makeItem(localFileName: local)

        let url = try await svc.prepareShare(item: item, format: .pdf)
        #expect(url.pathExtension == "pdf")
        let head = try Data(contentsOf: url).prefix(4)
        #expect(head == Data([0x25, 0x50, 0x44, 0x46]))  // %PDF
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreShareServiceTests/prepareSharePDFStartsWithPDFMagic`
Expected: Fails — `prepareShare(.pdf)` throws.

- [ ] **Step 3: Implement PDF dispatch**

Add at the top of the file:

```swift
import SheetMusicPDF
```

Replace the `case .pdf, .midi:` arm of the `switch` in `prepareShare`:

```swift
        case .pdf:
            return try await preparePDF(item: item, sanitizedTitle: title)
        case .midi:
            throw DomainError.unsupportedFormat("share")
```

Add the helper:

```swift
    private func preparePDF(
        item: ScoreItem,
        sanitizedTitle: String
    ) async throws -> URL {
        let sourceURL = scoresDirectory.appending(path: item.localFileName)
        let (score, _) = try await gateway.loadScore(fileURL: sourceURL)
        let pdfData = try await MainActor.run {
            try PDFExporter.export(score: score, options: PDFExporter.Options(title: item.title))
        }
        let destination = shareTempDirectory.appending(path: "\(sanitizedTitle).pdf")
        try? FileManager.default.removeItem(at: destination)
        do {
            try pdfData.write(to: destination)
        } catch {
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        }
        return destination
    }
```

If `SheetMusicPDF` is not a product on the `ScoreFiles` target, add it to `Packages/Infrastructure/Package.swift`'s `ScoreFiles` `dependencies` (alongside `SheetMusic`):

```swift
            .product(name: "SheetMusicPDF", package: "swift-sheet-music"),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreShareServiceTests`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift \
        Packages/Infrastructure/Package.swift
git commit -m "feat(infra): prepareShare renders PDF via PDFExporter"
```

(Drop `Package.swift` if unchanged.)

---

## Task 7: Infrastructure — `prepareShare` for `.midi`

**Files:**
- Modify: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift`
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Append:

```swift
    @Test func prepareShareMIDIStartsWithMThdMagic() async throws {
        let tmp = try TempDirectory()
        let scores = tmp.url.appending(path: "Scores")
        let shareTmp = tmp.url.appending(path: "Share")
        try FileManager.default.createDirectory(at: scores, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shareTmp, withIntermediateDirectories: true)

        let mscz = try Fixtures.minimalMSCZData()
        let local = "abc.mscz"
        try mscz.write(to: scores.appending(path: local))

        let svc = LiveScoreShareService(
            scoresDirectory: scores,
            shareTempDirectory: shareTmp,
            gateway: LiveScoreFileGateway()
        )
        let item = Self.makeItem(localFileName: local)

        let url = try await svc.prepareShare(item: item, format: .midi)
        #expect(url.pathExtension == "mid")
        let head = try Data(contentsOf: url).prefix(4)
        #expect(head == Data([0x4D, 0x54, 0x68, 0x64]))  // "MThd"
    }

    @Test func prepareShareTwiceOverwrites() async throws {
        let tmp = try TempDirectory()
        let scores = tmp.url.appending(path: "Scores")
        let shareTmp = tmp.url.appending(path: "Share")
        try FileManager.default.createDirectory(at: scores, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shareTmp, withIntermediateDirectories: true)

        try Fixtures.minimalMSCZData().write(to: scores.appending(path: "abc.mscz"))
        let svc = LiveScoreShareService(
            scoresDirectory: scores,
            shareTempDirectory: shareTmp,
            gateway: LiveScoreFileGateway()
        )
        let item = Self.makeItem(localFileName: "abc.mscz")

        let first = try await svc.prepareShare(item: item, format: .midi)
        let second = try await svc.prepareShare(item: item, format: .midi)
        #expect(first == second)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreShareServiceTests`
Expected: MIDI tests fail — branch still throws.

- [ ] **Step 3: Implement MIDI dispatch**

Replace the `case .midi: throw ...` arm:

```swift
        case .midi:
            return try await prepareMIDI(item: item, sanitizedTitle: title)
```

Add helper:

```swift
    private func prepareMIDI(
        item: ScoreItem,
        sanitizedTitle: String
    ) async throws -> URL {
        let sourceURL = scoresDirectory.appending(path: item.localFileName)
        let (score, _) = try await gateway.loadScore(fileURL: sourceURL)
        let midiData: Data
        do {
            midiData = try SheetMusic.exportMIDI(score: score)
        } catch {
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        }
        let destination = shareTempDirectory.appending(path: "\(sanitizedTitle).mid")
        try? FileManager.default.removeItem(at: destination)
        do {
            try midiData.write(to: destination)
        } catch {
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        }
        return destination
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/Infrastructure && swift test --filter LiveScoreShareServiceTests`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift
git commit -m "feat(infra): prepareShare renders MIDI via SheetMusic.exportMIDI"
```

---

## Task 8: Utility — `ActivityViewControllerRepresentable`

iOS-only `UIActivityViewController` wrapper, exported from `UtilityUI`.

**Files:**
- Create: `Packages/Utility/Sources/UtilityUI/ActivityViewControllerRepresentable.swift`

- [ ] **Step 1: Build `Utility` to confirm baseline**

Run: `cd Packages/Utility && swift build`
Expected: Builds.

- [ ] **Step 2: Add the wrapper**

```swift
#if os(iOS)
import SwiftUI
import UIKit

/// Bridges `UIActivityViewController` (the system share sheet) into
/// SwiftUI. Use via `.sheet { ActivityViewControllerRepresentable(items: [...]) }`.
public struct ActivityViewControllerRepresentable: UIViewControllerRepresentable {
    private let items: [Any]
    private let activities: [UIActivity]?

    public init(items: [Any], activities: [UIActivity]? = nil) {
        self.items = items
        self.activities = activities
    }

    public func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: activities)
    }

    public func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
#endif
```

- [ ] **Step 3: Build to confirm**

Run: `cd Packages/Utility && swift build`
Expected: Builds. (No tests — UIKit can't be exercised in `swift test` on macOS hosts; this lands behind `#if os(iOS)` and is verified manually in the simulator.)

- [ ] **Step 4: Commit**

```bash
git add Packages/Utility/Sources/UtilityUI/ActivityViewControllerRepresentable.swift
git commit -m "feat(utility): add ActivityViewControllerRepresentable share-sheet wrapper"
```

---

## Task 9: Library — `FakeScoreShareService` test fake

In-memory fake that records calls and lets tests inject success/failure outcomes.

**Files:**
- Create: `Packages/Features/Library/Tests/LibraryTests/Fakes/FakeScoreShareService.swift`

- [ ] **Step 1: Add the fake**

```swift
import Domain
import Foundation

final class FakeScoreShareService: ScoreShareService, @unchecked Sendable {
    var availableFormatsByDefault: [ScoreShareFormat] = [.sourceFormat, .pdf, .midi]
    var resolvedSourceFormatByDefault: ScoreFormat = .mscz

    var prepareShareError: DomainError?
    var prepareShareReturnURL: URL = URL(fileURLWithPath: "/tmp/share-fake")
    private(set) var prepareShareCalls: [(item: ScoreItem, format: ScoreShareFormat)] = []

    /// Tests set this to make `prepareShare` await the closure mid-flight,
    /// so they can observe `vm.isPreparingShare == true` while the call is
    /// in flight.
    var inFlightHook: (@Sendable () async -> Void)?

    func availableFormats(for _: ScoreItem) -> [ScoreShareFormat] {
        availableFormatsByDefault
    }

    func resolvedSourceFormat(for _: ScoreItem) -> ScoreFormat {
        resolvedSourceFormatByDefault
    }

    func prepareShare(item: ScoreItem, format: ScoreShareFormat) async throws -> URL {
        prepareShareCalls.append((item, format))
        if let hook = inFlightHook { await hook() }
        if let error = prepareShareError { throw error }
        return prepareShareReturnURL
    }
}
```

- [ ] **Step 2: Build the test target to confirm it compiles**

Run: `cd Packages/Features/Library && swift build --target LibraryTests`
Expected: Builds (the fake is unused so far; warnings about unused are fine).

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Tests/LibraryTests/Fakes/FakeScoreShareService.swift
git commit -m "test(library): add FakeScoreShareService for view-model tests"
```

---

## Task 10: Library — `LibraryViewModel.requestShare`

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`
- Modify: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift`
- Create: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelShareTests.swift`

- [ ] **Step 1: Update the existing `makeVM` helper to thread `FakeScoreShareService` through**

In `LibraryViewModelTests.swift`, replace the `makeVM` helper so existing tests keep passing once `LibraryViewModel.init` gains a parameter:

```swift
    private static func makeVM(
        scoreItems: [ScoreItem] = []
    ) -> (
        LibraryViewModel,
        FakeScoreLibraryRepository,
        FakeScoreFileImporter,
        FakeScoreFileGateway,
        FakeScoreShareService
    ) {
        let repo = FakeScoreLibraryRepository()
        repo.scoreItems = scoreItems
        let importer = FakeScoreFileImporter()
        let gateway = FakeScoreFileGateway()
        let share = FakeScoreShareService()
        let vm = LibraryViewModel(
            repository: repo, importer: importer, gateway: gateway, shareService: share
        )
        return (vm, repo, importer, gateway, share)
    }
```

Update every call site in this file: existing destructuring patterns like `let (vm, repo, _, _) = …` become `let (vm, repo, _, _, _) = …`. Make this update in every test in the file — do not skip any.

- [ ] **Step 2: Write the new failing share-flow tests**

```swift
import Domain
import Foundation
@testable import Library
import Testing

@Suite @MainActor
struct LibraryViewModelShareTests {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeItem() -> ScoreItem {
        ScoreItem(
            title: "T", composer: nil, instrumentationSummary: nil,
            localFileName: "T.mscz", contentHash: "h",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120,
            primaryKey: nil, addedAt: base, lastOpenedAt: nil,
            tagIDs: [], isFavorite: false
        )
    }

    private static func makeVM() -> (LibraryViewModel, FakeScoreShareService) {
        let repo = FakeScoreLibraryRepository()
        let importer = FakeScoreFileImporter()
        let gateway = FakeScoreFileGateway()
        let share = FakeScoreShareService()
        let vm = LibraryViewModel(
            repository: repo, importer: importer, gateway: gateway, shareService: share
        )
        return (vm, share)
    }

    @Test func requestShareSuccessSetsShareTarget() async {
        let (vm, share) = Self.makeVM()
        share.prepareShareReturnURL = URL(fileURLWithPath: "/tmp/share/T.mscz")
        await vm.requestShare(Self.makeItem(), format: .sourceFormat)
        #expect(vm.shareTarget?.url.path == "/tmp/share/T.mscz")
        #expect(vm.errorAlertMessage == nil)
        #expect(share.prepareShareCalls.count == 1)
        #expect(share.prepareShareCalls.first?.format == .sourceFormat)
    }

    @Test func requestShareFailureSetsErrorAlert() async {
        let (vm, share) = Self.makeVM()
        share.prepareShareError = .scoreParseFailed(reason: "boom")
        await vm.requestShare(Self.makeItem(), format: .pdf)
        #expect(vm.shareTarget == nil)
        #expect(vm.errorAlertMessage == "This file looks corrupted or isn't a valid score.")
    }

    @Test func isPreparingShareTogglesAroundTheCall() async {
        let (vm, share) = Self.makeVM()
        let observed: LockIsolated<[Bool]> = .init([])
        share.inFlightHook = { @Sendable in
            await MainActor.run { observed.withValue { $0.append(vm.isPreparingShare) } }
        }
        await vm.requestShare(Self.makeItem(), format: .midi)
        #expect(observed.value == [true])
        #expect(vm.isPreparingShare == false)
    }
}

/// Tiny lock helper so the test reads `vm.isPreparingShare` from the
/// fake's hook without a Sendable warning. Local to this test file.
private final class LockIsolated<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return _value }
    func withValue(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }; body(&_value)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd Packages/Features/Library && swift test --filter LibraryViewModelShareTests`
Expected: Compile errors — `shareService:`, `requestShare`, `shareTarget`, `isPreparingShare` not defined.

- [ ] **Step 4: Extend `LibraryViewModel`**

Add a stored property and the new state above `errorAlertMessage`:

```swift
    public let shareService: any ScoreShareService

    public var shareTarget: ShareTarget?
    public var isPreparingShare: Bool = false

    public struct ShareTarget: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let url: URL
        public init(url: URL) {
            self.id = UUID()
            self.url = url
        }
    }
```

Update the initializer signature:

```swift
    public init(
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway,
        shareService: any ScoreShareService
    ) {
        self.repository = repository
        self.importer = importer
        self.gateway = gateway
        self.shareService = shareService
    }
```

Add the new method (place it next to `delete`):

```swift
    public func requestShare(_ item: ScoreItem, format: ScoreShareFormat) async {
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let url = try await shareService.prepareShare(item: item, format: format)
            shareTarget = ShareTarget(url: url)
        } catch {
            errorAlertMessage = describe(error)
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd Packages/Features/Library && swift test`
Expected: All Library tests pass — both the existing suite (with the updated `makeVM`) and the new share-flow tests.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Library/Sources/Library/LibraryViewModel.swift \
        Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift \
        Packages/Features/Library/Tests/LibraryTests/LibraryViewModelShareTests.swift
git commit -m "feat(library): LibraryViewModel.requestShare and share-target state"
```

---

## Task 11: Library — `ScoreRowMenu` shared view-builder

Single source of truth for the row menu. Same view-builder is used from `ScoreListView`'s `contextMenu` and ellipsis Menu, and from `LibraryRootView`'s favorites/recents sections.

**Files:**
- Create: `Packages/Features/Library/Sources/Library/ScoreRowMenu.swift`

- [ ] **Step 1: Add the file**

```swift
import Domain
import SwiftUI

/// Single source of truth for the row menu used by both context-menus
/// and trailing ellipsis menus across the Library feature.
@ViewBuilder
func scoreRowMenu(
    item: ScoreItem,
    library: LibraryViewModel,
    onOpen: @escaping (ScoreItem) -> Void,
    onEditTags: @escaping (ScoreItem) -> Void,
    onAddToPlaylist: @escaping (ScoreItem) -> Void,
    onRequestDelete: ((ScoreItem) -> Void)?
) -> some View {
    Button { onOpen(item) } label: {
        Label("Open", systemImage: "music.note")
    }
    Button { Task { await library.toggleFavorite(item) } } label: {
        Label(
            item.isFavorite ? "Unfavorite" : "Favorite",
            systemImage: item.isFavorite ? "star.slash" : "star"
        )
    }
    Button { onEditTags(item) } label: {
        Label("Edit Tags…", systemImage: "tag")
    }
    Button { onAddToPlaylist(item) } label: {
        Label("Add to Playlist…", systemImage: "music.note.list")
    }

    Divider()
    shareSubmenu(item: item, library: library)

    if let onRequestDelete {
        Divider()
        Button(role: .destructive) { onRequestDelete(item) } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

@ViewBuilder
private func shareSubmenu(item: ScoreItem, library: LibraryViewModel) -> some View {
    Menu {
        ForEach(library.shareService.availableFormats(for: item), id: \.self) { format in
            Button {
                Task { await library.requestShare(item, format: format) }
            } label: {
                shareMenuLabel(item: item, format: format, library: library)
            }
        }
    } label: {
        Label("Share…", systemImage: "square.and.arrow.up")
    }
}

@ViewBuilder
private func shareMenuLabel(
    item: ScoreItem,
    format: ScoreShareFormat,
    library: LibraryViewModel
) -> some View {
    switch format {
    case .sourceFormat:
        let resolved = library.shareService.resolvedSourceFormat(for: item)
        switch resolved {
        case .mscz, .mscx:
            Label("MuseScore (.mscz)", systemImage: "doc.zipper")
        case .musicXML:
            Label("MusicXML (.musicxml)", systemImage: "doc.text")
        case .mxl:
            Label("MusicXML (.mxl)", systemImage: "doc.zipper")
        case .midi:
            Label("MIDI", systemImage: "pianokeys")
        }
    case .pdf:
        Label("PDF", systemImage: "doc.richtext")
    case .midi:
        Label("MIDI", systemImage: "pianokeys")
    }
}
```

- [ ] **Step 2: Build the package**

Run: `cd Packages/Features/Library && swift build`
Expected: Builds. (Not yet referenced — adoption happens in Tasks 12–13.)

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/Library/ScoreRowMenu.swift
git commit -m "feat(library): scoreRowMenu shared view-builder with share submenu"
```

---

## Task 12: Library — adopt `scoreRowMenu` in `ScoreListView` + add ellipsis button

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/ScoreListView.swift`

- [ ] **Step 1: Replace `row(for:)` and remove `contextMenuButtons`**

In `ScoreListView`, replace the `@ViewBuilder private func row(for item: ScoreItem)` body with the trailing-ellipsis layout:

```swift
    @ViewBuilder
    private func row(for item: ScoreItem) -> some View {
        HStack(spacing: 0) {
            ScoreRow(scoreItem: item)
                .contentShape(Rectangle())
                .onTapGesture { onOpen(item) }
            Menu {
                scoreRowMenu(
                    item: item,
                    library: library,
                    onOpen: onOpen,
                    onEditTags: onEditTags,
                    onAddToPlaylist: onAddToPlaylist,
                    onRequestDelete: { pendingDelete = $0 }
                )
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("More"))
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await library.toggleFavorite(item) }
            } label: {
                Label(
                    item.isFavorite ? "Unfavorite" : "Favorite",
                    systemImage: item.isFavorite ? "star.slash.fill" : "star.fill"
                )
            }
            .tint(.yellow)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = item
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            scoreRowMenu(
                item: item,
                library: library,
                onOpen: onOpen,
                onEditTags: onEditTags,
                onAddToPlaylist: onAddToPlaylist,
                onRequestDelete: { pendingDelete = $0 }
            )
        }
    }
```

Delete the entire `@ViewBuilder private func contextMenuButtons(for item: ScoreItem) -> some View { … }` method — it has no other callers.

- [ ] **Step 2: Build the package**

Run: `cd Packages/Features/Library && swift build`
Expected: Builds.

- [ ] **Step 3: Run the existing tests to confirm no regressions**

Run: `cd Packages/Features/Library && swift test`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Sources/Library/ScoreListView.swift
git commit -m "feat(library): trailing ellipsis Menu and unified row menu in ScoreListView"
```

---

## Task 13: Library — adopt `scoreRowMenu` in `LibraryRootView` + present share sheet

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/LibraryRootView.swift`

- [ ] **Step 1: Add the `UtilityUI` import at the top**

```swift
import UtilityUI
```

(Library's `Package.swift` already declares `UtilityUI` as a target dependency — confirm by reading the file before this step. If absent, add `.product(name: "UtilityUI", package: "Utility")` to the `Library` target dependencies.)

- [ ] **Step 2: Replace `favoritesSection(_:)` and `recentsSection(_:)` to add the trailing ellipsis**

```swift
    @ViewBuilder
    private func favoritesSection(_ favorites: [ScoreItem]) -> some View {
        if !favorites.isEmpty {
            Section("Favorites") {
                ForEach(favorites) { item in
                    sectionRow(for: item)
                }
            }
        }
    }

    @ViewBuilder
    private func recentsSection(_ recents: [ScoreItem]) -> some View {
        if !recents.isEmpty {
            Section("Recently Opened") {
                ForEach(recents) { item in
                    sectionRow(for: item)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionRow(for item: ScoreItem) -> some View {
        HStack(spacing: 0) {
            ScoreRow(scoreItem: item)
                .contentShape(Rectangle())
                .onTapGesture { onOpenScore(item) }
            Menu {
                scoreRowMenu(
                    item: item,
                    library: viewModel,
                    onOpen: onOpenScore,
                    onEditTags: { editTagsTarget = $0 },
                    onAddToPlaylist: { addToPlaylistTarget = $0 },
                    onRequestDelete: nil
                )
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("More"))
        }
        .contextMenu {
            scoreRowMenu(
                item: item,
                library: viewModel,
                onOpen: onOpenScore,
                onEditTags: { editTagsTarget = $0 },
                onAddToPlaylist: { addToPlaylistTarget = $0 },
                onRequestDelete: nil
            )
        }
    }
```

Delete the existing `@ViewBuilder private func rowContextMenu(for item: ScoreItem)` method — superseded by `scoreRowMenu`.

- [ ] **Step 3: Add the share-sheet `.sheet` and the preparing overlay to `body`**

Inside `LibraryRootView.body`, append two modifiers below the existing `.alert("Already in Your Library", …)`:

```swift
        .sheet(item: $viewModel.shareTarget) { target in
            ActivityViewControllerRepresentable(items: [target.url])
        }
        .overlay {
            if viewModel.isPreparingShare {
                ProgressView("Preparing…")
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
```

- [ ] **Step 4: Build the package**

Run: `cd Packages/Features/Library && swift build`
Expected: Builds.

- [ ] **Step 5: Run the existing tests**

Run: `cd Packages/Features/Library && swift test`
Expected: All pass.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Library/Sources/Library/LibraryRootView.swift \
        Packages/Features/Library/Package.swift
git commit -m "feat(library): trailing ellipsis menu, share sheet, preparing overlay"
```

(Drop `Package.swift` from the `git add` if it wasn't modified.)

---

## Task 14: Library — localized strings

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add three new entries**

Open the file. Inside the top-level `"strings": { … }` object, add (preserving valid JSON commas):

```json
    "Share…": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Share…" } },
        "ja": { "stringUnit": { "state": "translated", "value": "共有…" } }
      }
    },
    "Preparing…": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Preparing…" } },
        "ja": { "stringUnit": { "state": "translated", "value": "準備中…" } }
      }
    },
    "More": {
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "More" } },
        "ja": { "stringUnit": { "state": "translated", "value": "その他" } }
      }
    },
```

Format-name labels (`MuseScore (.mscz)`, `MusicXML (.musicxml)`, `MusicXML (.mxl)`, `PDF`, `MIDI`) are stable across locales and pass through as plain strings. Do **not** add entries for them.

- [ ] **Step 2: Validate JSON parses**

Run: `python3 -m json.tool Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings > /dev/null`
Expected: Exit 0, no output.

- [ ] **Step 3: Build the package**

Run: `cd Packages/Features/Library && swift build`
Expected: Builds.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings
git commit -m "feat(library): localize share menu strings (Share…, Preparing…, More)"
```

---

## Task 15: App — wire `LiveScoreShareService` at the composition root

**Files:**
- Modify: `App/AppPaths.swift`
- Modify: `App/AppBootstrap.swift`
- Modify: `App/AppShellView.swift`

- [ ] **Step 1: Add `shareTempDirectory` to `AppPaths`**

Inside `enum AppPaths`, add:

```swift
    static var shareTempDirectory: URL {
        documentsRoot.appending(path: "ShareTmp")
    }
```

- [ ] **Step 2: Wipe-and-recreate the share temp directory in `AppBootstrap.start`**

Inside `AppBootstrap`, add a stored property next to the other adapters:

```swift
    private(set) var shareService: LiveScoreShareService?
```

In `start()`, immediately after the existing `createDirectory` calls for `scoresDirectory` / `soundfontCacheDirectory`, add:

```swift
            try? FileManager.default.removeItem(at: AppPaths.shareTempDirectory)
            try FileManager.default.createDirectory(
                at: AppPaths.shareTempDirectory, withIntermediateDirectories: true
            )
```

After the line `self.importer = importer` (and before the soundfont resolver block), add:

```swift
            shareService = LiveScoreShareService(
                scoresDirectory: AppPaths.scoresDirectory,
                shareTempDirectory: AppPaths.shareTempDirectory,
                gateway: gateway
            )
```

- [ ] **Step 3: Thread `shareService` into `LibraryViewModel` from `AppShellView`**

In `AppShellView.body`, change the readiness check to also unwrap `shareService`:

```swift
            if let repository = bootstrap.repository,
               let importer = bootstrap.importer,
               let gateway = bootstrap.gateway,
               let shareService = bootstrap.shareService,
               bootstrap.isReady
            {
                ReadyShell(
                    bootstrap: bootstrap,
                    repository: repository,
                    importer: importer,
                    gateway: gateway,
                    shareService: shareService,
                    scoresDirectory: AppPaths.scoresDirectory
                )
            } else if …
```

In `ReadyShell`, add a `let shareService: any ScoreShareService` stored property; update the initializer signature and the `LibraryViewModel(...)` construction:

```swift
    let shareService: any ScoreShareService

    init(
        bootstrap: AppBootstrap,
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway,
        shareService: any ScoreShareService,
        scoresDirectory: URL
    ) {
        self.bootstrap = bootstrap
        self.repository = repository
        self.importer = importer
        self.gateway = gateway
        self.shareService = shareService
        self.scoresDirectory = scoresDirectory
        _libraryVM = State(
            wrappedValue: LibraryViewModel(
                repository: repository,
                importer: importer,
                gateway: gateway,
                shareService: shareService
            )
        )
    }
```

- [ ] **Step 4: Build the app**

Run: `xcodegen generate && xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`
Expected: Build succeeds.

- [ ] **Step 5: Run the app-level tests to confirm no regressions**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation test`
Expected: Tests pass. (If the project's CI configuration excludes UITests for fast loops, only `swift test` per package is required — but the iOS app build must succeed.)

- [ ] **Step 6: Commit**

```bash
git add App/AppPaths.swift App/AppBootstrap.swift App/AppShellView.swift
git commit -m "feat(app): wire LiveScoreShareService and shareTempDirectory at boot"
```

---

## Task 16: Manual UI verification

The spec calls out that share UI is verified manually — context menus, swipe interactions, and `UIActivityViewController` presentation are notoriously brittle to snapshot test on iOS.

**Files:** _(none — manual run)_

- [ ] **Step 1: Run the app on the iPhone 16 simulator**

```sh
xcodebuild -project Folino.xcodeproj -scheme Folino \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    -skipPackagePluginValidation build
xcrun simctl install booted "$(xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -showBuildSettings | awk -F= '/ BUILT_PRODUCTS_DIR =/ {gsub(/ /,""); print $2}')/Folino.app"
xcrun simctl launch booted com.KeyNumber.Folino
```

- [ ] **Step 2: Verify the user-visible behaviors**

In the simulator, with at least one imported score:

1. Tap the trailing **ellipsis** on a Library row → menu appears with `Open / Favorite / Edit Tags / Add to Playlist / Share… / Delete` (favorites + recents sections must omit `Delete`).
2. Tap `Share…` → submenu shows `MuseScore (.mscz)` (or matching source-format label), `PDF`, `MIDI`.
3. Tap `PDF` → "Preparing…" overlay appears briefly → system share sheet appears with a `.pdf` file.
4. Long-press the row → identical menu appears (shared `scoreRowMenu`).
5. Swipe-to-delete still works from the leading/trailing edges.
6. Cancelling the share sheet dismisses it without setting an error alert.
7. Tapping the row body (not the ellipsis) still opens the score in the Reader.

- [ ] **Step 3: Note any issues**

If any verification step fails, do not commit. File an issue inline against the relevant earlier task and revisit.

- [ ] **Step 4: Confirm no further commits required**

Manual verification produces no diff. The feature is complete once all earlier task commits are in place.

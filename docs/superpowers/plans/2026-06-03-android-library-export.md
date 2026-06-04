# Android Library Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an Android user export a Library score (single row + bulk) at iOS format parity — MuseScore v4/v3, PDF, MIDI, M4A — sharing export logic with iOS and writing only the two Android-only primitives (PDF rasterization, M4A encoding) in Kotlin.

**Architecture:** Decision logic (format list, filename sanitize, original-format detection, extensions) is single-sourced in Domain. A thin Swift orchestrator owns format routing on each platform via an exhaustive `switch` (iOS `LiveScoreShareService`; Android `LibraryAndroidStore.exportScore`). MIDI/MSCZ encode with cross-platform `swift-sheet-music`; PDF and audio route to injected Kotlin primitives (`@WireletProvided`). Kotlin produces PDF by drawing the shared `DrawProgram` into an `android.graphics.pdf.PdfDocument`, and audio via the existing `AndroidPlaybackEngine.exportAudioFile`. Kotlin shares the produced file through `FileProvider` + `ACTION_SEND` / `ACTION_SEND_MULTIPLE`.

**Tech Stack:** Swift 6.3 (Domain Foundation+SheetMusicCore; `FolinoLibraryJNI` Android target), swift-wirelet (`@WireletObservable` / `@WireletExpose` / `@WireletProvided`), swift-sheet-music (SheetMusicMSCX/MIDI/Layout, Android Compose+Audio modules), Kotlin/Jetpack Compose (Material3), Room.

**Spec:** `docs/superpowers/specs/2026-06-03-android-library-export-design.md`

---

## Build / Test command reference (use verbatim)

- Domain unit tests (iOS sim; `swift test` is broken by the SwiftLint plugin's macOS requirement):
  `xcodebuild -project Folino.xcodeproj -scheme DomainTests -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation test`
  (If the `DomainTests` scheme is absent, generate it first with `xcodegen generate`, or substitute `-scheme Domain-Package`.)
- iOS Infrastructure tests:
  `xcodebuild -project Folino.xcodeproj -scheme InfrastructureTests -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation test`
- Android-gated Swift host tests (`FolinoLibraryJNI`):
  `FOLINO_ANDROID=1 xcrun swift test --package-path Packages/Features/Library --filter <SuiteName>`
- Android Swift `.so` rebuild (after touching `FolinoLibraryJNI`): `Scripts/android-build-library-libs.sh` with the release toolchain on PATH (see memory: `PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH`).
- Android app build/install: `Android/gradlew -p Android :app:installDebug --no-daemon` (release toolchain on PATH for the embedded Swift build).
- All commands run from the worktree root `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/android-library-export`.

---

## File Structure

**Domain (shared decision logic — layer A):**
- Modify `Packages/Domain/Sources/Domain/Protocols/ScoreShareService.swift` — add `ScoreShareFormat.canonicalExtension`, `.allOrdered`, `.matching(for:)`; add `ScoreExportNaming.sanitize(title:)`.
- Create `Packages/Domain/Tests/DomainTests/ScoreShareFormatTests.swift` — pure tests for the above.

**iOS Infrastructure (refactor — layers B/C, behavior-preserving):**
- Create `Packages/Domain/Sources/Domain/Protocols/ScorePDFRenderer.swift` — new injected-PDF protocol.
- Modify `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift` — delegate to Domain helpers; take a `ScorePDFRenderer` instead of importing `SheetMusicPDF` directly.
- Create `Packages/Infrastructure/Sources/ScoreFiles/CoreGraphicsPDFRenderer.swift` — the iOS `ScorePDFRenderer` wrapping the existing `PDFExporter`.
- Modify `Packages/Infrastructure/Tests/InfrastructureTests/LiveScoreShareServiceTests.swift` (or wherever the sanitize test lives) — adapt to the refactor; assert PDF routing via a fake renderer.
- Modify the App composition root that constructs `LiveScoreShareService` to inject `CoreGraphicsPDFRenderer`.

**Android Swift (`FolinoLibraryJNI` — orchestration B + primitive protocols):**
- Modify `Packages/Features/Library/Package.swift` — add `SheetMusicMIDI` (+`SheetMusic`) to the Android `FolinoLibraryJNI` target deps.
- Create `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreExportPrimitives.swift` — `@WireletProvided` protocols `ScorePdfRenderer`, `ScoreAudioFileExporter`.
- Modify `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift` — add `func scoresDirectoryPath() -> String`.
- Modify `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift` — accept the two new injected services; add `@WireletExpose exportFormats(_:)` and `exportScore(_:_:_:)`.
- Create `Packages/Features/Library/Tests/FolinoLibraryJNITests/ExportScoreTests.swift` — host tests with fake store + fake primitives.

**Android Kotlin (primitives C + share + UI):**
- Create `Android/app/src/main/kotlin/com/keynumber/folino/export/PdfScoreRenderer.kt` — `ScorePdfRenderer` impl (DrawProgram → PdfDocument).
- Create `Android/app/src/main/kotlin/com/keynumber/folino/export/AudioScoreExporter.kt` — `ScoreAudioFileExporter` impl (AndroidPlaybackEngine).
- Create `Android/app/src/main/kotlin/com/keynumber/folino/export/ScoreShareLauncher.kt` — FileProvider URI + `ACTION_SEND[_MULTIPLE]`.
- Create `Android/app/src/main/res/xml/file_paths.xml` — FileProvider paths.
- Modify `Android/app/src/main/AndroidManifest.xml` — add the `<provider>`.
- Modify `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` — `LibraryVMFactory` passes the two new primitives.
- Create `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/ExportFormatSheet.kt` — format-picker ModalBottomSheet (single + bulk).
- Modify `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt` — add Export to the row DropdownMenu and to the selection CAB; host the sheet + share launch + progress + error Snackbar.
- Modify `Android/app/src/main/res/values/strings.xml` (+ localized variants) — export strings.

---

## Phase 1 — Domain shared decision logic (layer A)

### Task 1: `ScoreShareFormat` extensions + `ScoreExportNaming`

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Protocols/ScoreShareService.swift`
- Test: `Packages/Domain/Tests/DomainTests/ScoreShareFormatTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Domain/Tests/DomainTests/ScoreShareFormatTests.swift`:

```swift
import SheetMusicCore
import Testing
@testable import Domain

@Suite struct ScoreShareFormatTests {
    @Test func canonicalExtensions() {
        #expect(ScoreShareFormat.museScoreV4.canonicalExtension == "mscz")
        #expect(ScoreShareFormat.museScoreV3.canonicalExtension == "mscz")
        #expect(ScoreShareFormat.pdf.canonicalExtension == "pdf")
        #expect(ScoreShareFormat.midi.canonicalExtension == "mid")
        #expect(ScoreShareFormat.audioM4A.canonicalExtension == "m4a")
    }

    @Test func allOrderedMatchesIOSMenuOrder() {
        #expect(ScoreShareFormat.allOrdered == [.museScoreV4, .museScoreV3, .pdf, .midi, .audioM4A])
    }

    @Test func matchingMapsSourceToFormat() {
        #expect(ScoreShareFormat.matching(for: .midi) == .midi)
        #expect(ScoreShareFormat.matching(for: .museScore(.v4)) == .museScoreV4)
        #expect(ScoreShareFormat.matching(for: .museScore(.v3)) == .museScoreV3)
        #expect(ScoreShareFormat.matching(for: .museScore(.v2)) == nil)
        #expect(ScoreShareFormat.matching(for: .musicXML) == nil)
        #expect(ScoreShareFormat.matching(for: .pdf) == nil)
        #expect(ScoreShareFormat.matching(for: .unknown) == nil)
    }

    @Test func sanitizeReplacesHostileCharsTrimsAndCaps() {
        #expect(ScoreExportNaming.sanitize(title: "a/b:c\\d") == "a_b_c_d")
        #expect(ScoreExportNaming.sanitize(title: "  __  ") == "score")
        #expect(ScoreExportNaming.sanitize(title: "") == "score")
        #expect(ScoreExportNaming.sanitize(title: String(repeating: "x", count: 200)).count == 100)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Folino.xcodeproj -scheme DomainTests -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation test`
Expected: FAIL — `canonicalExtension` / `allOrdered` / `matching` / `ScoreExportNaming` undefined.

- [ ] **Step 3: Add the helpers to Domain**

Append to `Packages/Domain/Sources/Domain/Protocols/ScoreShareService.swift` (add `import SheetMusicCore` at the top alongside `import Foundation`):

```swift
public extension ScoreShareFormat {
    /// Canonical file extension for the produced file (no leading dot). MuseScore v3/v4 both emit `.mscz`.
    var canonicalExtension: String {
        switch self {
        case .museScoreV4, .museScoreV3: "mscz"
        case .pdf: "pdf"
        case .midi: "mid"
        case .audioM4A: "m4a"
        }
    }

    /// The formats in display order — the single source for both the iOS menu and the Android sheet.
    static var allOrdered: [ScoreShareFormat] { [.museScoreV4, .museScoreV3, .pdf, .midi, .audioM4A] }

    /// The share format that re-emits `source` byte-for-byte, or `nil` for sources we don't expose as a format
    /// (MuseScore 2, MusicXML, PDF, unknown).
    static func matching(for source: ScoreSource) -> ScoreShareFormat? {
        switch source {
        case .midi: .midi
        case .museScore(.v4): .museScoreV4
        case .museScore(.v3): .museScoreV3
        case .museScore(.v2), .musicXML, .pdf, .unknown: nil
        }
    }
}

/// Pure filename derivation for exported scores, shared by iOS and Android so both produce identical filenames.
public enum ScoreExportNaming {
    /// Replace filesystem-hostile characters with `_`, trim leading/trailing `_`/space, fall back to `"score"` when
    /// empty, and cap at 100 characters.
    public static func sanitize(title: String) -> String {
        let bad: Set<Character> = ["/", ":", "\\", "\u{0000}"]
        let cleaned = String(title.map { bad.contains($0) ? "_" : $0 })
        let stripped = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_ "))
        let candidate = stripped.isEmpty ? "score" : stripped
        return String(candidate.prefix(100))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Folino.xcodeproj -scheme DomainTests -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation test`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Protocols/ScoreShareService.swift Packages/Domain/Tests/DomainTests/ScoreShareFormatTests.swift
git commit -m "feat(domain): shared ScoreShareFormat extension + ScoreExportNaming"
```

---

## Phase 2 — iOS refactor (behavior-preserving)

### Task 2: `ScorePDFRenderer` protocol in Domain

**Files:**
- Create: `Packages/Domain/Sources/Domain/Protocols/ScorePDFRenderer.swift`

- [ ] **Step 1: Add the protocol**

```swift
import Foundation
import SheetMusicCore

/// Renders a parsed `Score` to PDF bytes. Injected so the share service stays free of any platform graphics import
/// (CoreGraphics on iOS, `PdfDocument` on Android). Errors throw `DomainError.scoreWriteFailed`.
public protocol ScorePDFRenderer: Sendable {
    /// Render `score` to PDF data. `title` is the display title (used for any in-PDF metadata/header).
    func renderPDF(score: Score, title: String) async throws -> Data
}
```

- [ ] **Step 2: Build Domain to verify it compiles**

Run: `xcodebuild -project Folino.xcodeproj -scheme DomainTests -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Packages/Domain/Sources/Domain/Protocols/ScorePDFRenderer.swift
git commit -m "feat(domain): add ScorePDFRenderer protocol"
```

### Task 3: iOS `CoreGraphicsPDFRenderer` + refactor `LiveScoreShareService`

**Files:**
- Create: `Packages/Infrastructure/Sources/ScoreFiles/CoreGraphicsPDFRenderer.swift`
- Modify: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/LiveScoreShareServiceTests.swift`

- [ ] **Step 1: Create the iOS PDF renderer**

`Packages/Infrastructure/Sources/ScoreFiles/CoreGraphicsPDFRenderer.swift`:

```swift
import Domain
import Foundation
import SheetMusicPDF

/// iOS `ScorePDFRenderer` backed by `swift-sheet-music`'s CoreGraphics `PDFExporter`.
public struct CoreGraphicsPDFRenderer: ScorePDFRenderer {
    public init() {}

    public func renderPDF(score: Score, title: String) async throws -> Data {
        do {
            return try await MainActor.run {
                try PDFExporter.export(score: score, options: PDFExporter.Options(title: title))
            }
        } catch {
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        }
    }
}
```

- [ ] **Step 2: Refactor `LiveScoreShareService` to use Domain helpers + injected renderer**

In `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift`:

1. Remove `import SheetMusicPDF`.
2. Add a stored `private let pdfRenderer: any ScorePDFRenderer` and accept it in `init` (new last parameter).
3. Delete the private `static func sanitize` and `static func matchingFormat`; replace call sites:
   - `Self.sanitize(title:)` → `ScoreExportNaming.sanitize(title:)`
   - `Self.matchingFormat(for:)` → `ScoreShareFormat.matching(for:)`
4. Replace the `availableFormats` literal with `ScoreShareFormat.allOrdered`.
5. Replace `writePDF`'s body to call the injected renderer:

```swift
private func writePDF(
    score: Score,
    item: ScoreItem,
    sanitizedTitle: String,
) async throws -> URL {
    let pdfData = try await pdfRenderer.renderPDF(score: score, title: item.title)
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

(Leave `writeMIDI`, `writeMSCZ`, `writeM4A`, `copyOriginalBytes`, and the `prepareShare` switch unchanged.)

- [ ] **Step 3: Update existing tests + add PDF-routing test**

In the Infrastructure test file: the existing sanitize test now targets `ScoreExportNaming` (move it to Domain in Task 1 already covers sanitize — delete the Infrastructure sanitize test if duplicated). Add a fake renderer and assert PDF routing:

```swift
private struct FakePDFRenderer: ScorePDFRenderer {
    let data: Data
    func renderPDF(score: Score, title: String) async throws -> Data { data }
}

@Test func prepareSharePDFUsesInjectedRenderer() async throws {
    // Arrange a service with FakePDFRenderer(data: Data("PDFBYTES".utf8)) and a fixture score item,
    // then call prepareShare(item:, format: .pdf) and assert the file at the returned URL contains "PDFBYTES".
}
```

Fill the arrange/act/assert using the existing test's fixture-construction helpers in this file (mirror how other `prepareShare` cases build the service + item).

- [ ] **Step 4: Find and update the App composition root**

Run: `grep -rn "LiveScoreShareService(" App Packages` — at each construction site add `pdfRenderer: CoreGraphicsPDFRenderer()` as the new argument.

- [ ] **Step 5: Run iOS Infrastructure tests**

Run: `xcodebuild -project Folino.xcodeproj -scheme InfrastructureTests -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation test`
Expected: PASS (existing cases + new PDF-routing case).

- [ ] **Step 6: Build the app to confirm composition root compiles**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Packages/Infrastructure App
git commit -m "refactor(infra): LiveScoreShareService uses Domain helpers + injected ScorePDFRenderer"
```

---

## Phase 3 — Android Swift orchestration (`FolinoLibraryJNI`)

### Task 4: Add MIDI dependency + `scoresDirectoryPath` to `LibraryStore`

**Files:**
- Modify: `Packages/Features/Library/Package.swift`
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift`

- [ ] **Step 1: Add SheetMusic/MIDI to the Android target deps**

In `Packages/Features/Library/Package.swift`, inside the `isAndroid` `FolinoLibraryJNI` target `dependencies` array, add after the `SheetMusicMSCX` product:

```swift
.product(name: "SheetMusicMIDI", package: "swift-sheet-music"),
.product(name: "SheetMusic", package: "swift-sheet-music"),
```

- [ ] **Step 2: Add `scoresDirectoryPath()` to the provided store protocol**

In `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift`, add to the `LibraryStore` protocol (Scores section):

```swift
/// Absolute path of the directory holding managed `<id>.<ext>` score files (Kotlin: `filesDir/Scores`). The store
/// composes per-file paths from this + `localFileName`.
func scoresDirectoryPath() -> String
```

- [ ] **Step 3: Resolve the Android Swift package to confirm it builds**

Run: `FOLINO_ANDROID=1 xcrun swift build --package-path Packages/Features/Library`
Expected: BUILD SUCCEEDED (the new dep resolves; protocol addition compiles). The Kotlin `RoomLibraryStore` will be updated in Task 8 — the macro bridge regeneration there picks up the new method.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Package.swift Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryStore.swift
git commit -m "feat(android-library): add MIDI dep + scoresDirectoryPath to LibraryStore"
```

### Task 5: `@WireletProvided` export primitive protocols

**Files:**
- Create: `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreExportPrimitives.swift`

- [ ] **Step 1: Declare the two injected primitives**

```swift
import WireletProvided

/// Draws a score to a PDF file. Implemented in Kotlin (loads the score, computes the shared `DrawProgram` layout, and
/// draws each page into an `android.graphics.pdf.PdfDocument`). Swift owns the routing + filename; this is the
/// irreducible Android-only rasterization step.
@WireletProvided
public protocol ScorePdfRenderer {
    /// Render the score at `scoreFilePath` (absolute `.mscz`) to `outPath` (.pdf). Returns `true` on success.
    func renderPdf(_ scoreFilePath: String, _ outPath: String) -> Bool
}

/// Encodes a score to an M4A file. Implemented in Kotlin via `AndroidPlaybackEngine.exportAudioFile`. The irreducible
/// Android-only audio codec step.
@WireletProvided
public protocol ScoreAudioFileExporter {
    /// Render the score at `scoreFilePath` (absolute `.mscz`) to `outPath` (.m4a). Returns `true` on success.
    func exportAudio(_ scoreFilePath: String, _ outPath: String) -> Bool
}
```

- [ ] **Step 2: Build to confirm the macros expand**

Run: `FOLINO_ANDROID=1 xcrun swift build --package-path Packages/Features/Library`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreExportPrimitives.swift
git commit -m "feat(android-library): @WireletProvided PDF + audio export primitives"
```

### Task 6: `exportScore` orchestration + `exportFormats` (TDD with fakes)

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`
- Test: `Packages/Features/Library/Tests/FolinoLibraryJNITests/ExportScoreTests.swift`

- [ ] **Step 1: Write the failing host test**

Create `Packages/Features/Library/Tests/FolinoLibraryJNITests/ExportScoreTests.swift`. Use the existing test conventions in `FolinoLibraryJNITests` for building a fake `LibraryStore` (mirror the fake used by the existing store tests; check `Packages/Features/Library/Tests/FolinoLibraryJNITests/` for the established fake). Bundle a real `.mscz` fixture under `Tests/FolinoLibraryJNITests/Resources/` (reuse the one already there — the suite already declares `resources: [.process("Resources")]`).

```swift
import Foundation
import Testing
@testable import FolinoLibraryJNI

@Suite struct ExportScoreTests {
    // Fake store returning a temp scores dir + one record pointing at a bundled fixture .mscz.
    // Fake ScorePdfRenderer / ScoreAudioFileExporter that record their args and `touch` outPath, returning true.

    @Test func midiExportProducesMidFile() throws {
        // Arrange store with one mscz record; act exportScore(id, "midi", tmpOut);
        // expect returned path ends ".mid" and the file exists & is non-empty.
    }

    @Test func mscz4ExportProducesMsczFile() throws {
        // expect ".mscz" file exists/non-empty.
    }

    @Test func pdfRoutesToInjectedRenderer() throws {
        // act exportScore(id, "pdf", tmpOut);
        // expect fake pdfRenderer.renderPdf was called with (scoreFilePath endsWith ".mscz", outPath endsWith ".pdf")
        // and returned path == that outPath.
    }

    @Test func audioRoutesToInjectedExporter() throws {
        // expect fake audioExporter.exportAudio called with outPath endsWith ".m4a".
    }

    @Test func originalMsczIsCopiedNotReencoded() throws {
        // For a v4-source fixture exported as .museScoreV4, expect bytes identical to the source file.
    }

    @Test func unknownIdReturnsEmptyString() throws {
        #expect(/* exportScore("nope", "midi", tmp) */ true == true) // returns ""
    }
}
```

Flesh out each test body using the fake-store pattern already in the suite. The format string values are the lowercase enum-ish tokens defined in Step 2 (`"museScoreV4"`, `"museScoreV3"`, `"pdf"`, `"midi"`, `"audioM4A"`).

- [ ] **Step 2: Run test to verify it fails**

Run: `FOLINO_ANDROID=1 xcrun swift test --package-path Packages/Features/Library --filter ExportScoreTests`
Expected: FAIL — `exportScore` / injected services not defined.

- [ ] **Step 3: Implement injection + `exportScore` + `exportFormats`**

In `LibraryAndroidStore.swift`:

1. Add stored properties and extend `init` (Wirelet generates the multi-service `create(store:pdfRenderer:audioExporter:)` factory):

```swift
@ObservationIgnored private let pdfRenderer: ScorePdfRenderer
@ObservationIgnored private let audioExporter: ScoreAudioFileExporter

public init(store: LibraryStore, pdfRenderer: ScorePdfRenderer, audioExporter: ScoreAudioFileExporter) {
    self.store = store
    self.pdfRenderer = pdfRenderer
    self.audioExporter = audioExporter
    reload()
    reloadPlaylists()
    reloadTags()
}
```

2. Add a private string → format mapper and the exposed methods:

```swift
private func parseFormat(_ raw: String) -> ScoreShareFormat? {
    switch raw {
    case "museScoreV4": .museScoreV4
    case "museScoreV3": .museScoreV3
    case "pdf": .pdf
    case "midi": .midi
    case "audioM4A": .audioM4A
    default: nil
    }
}

/// Formats + which one is the score's original, for the export sheet. Unknown id → empty.
@WireletExpose
public func exportFormats(_ scoreId: String) -> [ScoreExportFormatWire] {
    guard let record = store.loadAll().first(where: { $0.id == scoreId }) else { return [] }
    let path = "\(store.scoresDirectoryPath())/\(record.localFileName)"
    let original: ScoreShareFormat? = {
        guard let score = try? MSCZReader.parse(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return ScoreShareFormat.matching(for: score.source)
    }()
    return ScoreShareFormat.allOrdered.map {
        ScoreExportFormatWire(format: token(for: $0), isOriginal: $0 == original)
    }
}

/// Produce the chosen format under `outDir` and return its absolute path ("" on failure).
@WireletExpose
public func exportScore(_ scoreId: String, _ format: String, _ outDir: String) -> String {
    guard let fmt = parseFormat(format),
          let record = store.loadAll().first(where: { $0.id == scoreId }) else { return "" }
    let sourcePath = "\(store.scoresDirectoryPath())/\(record.localFileName)"
    let sourceURL = URL(fileURLWithPath: sourcePath)
    guard let score = try? MSCZReader.parse(contentsOf: sourceURL) else { return "" }
    let title = ScoreExportNaming.sanitize(title: record.title)
    let outPath = "\(outDir)/\(title).\(fmt.canonicalExtension)"
    let outURL = URL(fileURLWithPath: outPath)
    try? FileManager.default.removeItem(at: outURL)

    if ScoreShareFormat.matching(for: score.source) == fmt {
        return (try? FileManager.default.copyItem(at: sourceURL, to: outURL)) != nil ? outPath : ""
    }
    switch fmt {
    case .museScoreV4: return writeMSCZ(score, to: outURL, target: .v4) ? outPath : ""
    case .museScoreV3: return writeMSCZ(score, to: outURL, target: .v3) ? outPath : ""
    case .midi:        return writeMIDI(score, to: outURL) ? outPath : ""
    case .pdf:         return pdfRenderer.renderPdf(sourcePath, outPath) ? outPath : ""
    case .audioM4A:    return audioExporter.exportAudio(sourcePath, outPath) ? outPath : ""
    }
}

private func writeMIDI(_ score: Score, to url: URL) -> Bool {
    guard let data = try? SheetMusic.exportMIDI(score: score) else { return false }
    return (try? data.write(to: url)) != nil
}

private func writeMSCZ(_ score: Score, to url: URL, target: MSCXVersion) -> Bool {
    (try? MSCZWriter.write(score: score, options: MSCXEncoderOptions(targetVersion: target), to: url)) != nil
}

private func token(for f: ScoreShareFormat) -> String {
    switch f {
    case .museScoreV4: "museScoreV4"
    case .museScoreV3: "museScoreV3"
    case .pdf: "pdf"
    case .midi: "midi"
    case .audioM4A: "audioM4A"
    }
}
```

3. Add the wire struct near the other `*Wire` types (in the file where `ScoreRowWire` etc. live):

```swift
public struct ScoreExportFormatWire: Sendable {
    public let format: String   // token: museScoreV4 | museScoreV3 | pdf | midi | audioM4A
    public let isOriginal: Bool
    public init(format: String, isOriginal: Bool) { self.format = format; self.isOriginal = isOriginal }
}
```

Add the needed imports to `LibraryAndroidStore.swift`: `import SheetMusic` (exportMIDI), keep `import SheetMusicMSCX` (MSCZWriter/MSCZReader/MSCXVersion/MSCXEncoderOptions), `import Domain`.

- [ ] **Step 4: Run test to verify it passes**

Run: `FOLINO_ANDROID=1 xcrun swift test --package-path Packages/Features/Library --filter ExportScoreTests`
Expected: PASS (all cases). The PDF/audio cases pass via fakes; real Kotlin primitives are verified on device in Phase 6.

- [ ] **Step 5: Run the full Android-gated suite to confirm no regressions**

Run: `FOLINO_ANDROID=1 xcrun swift test --package-path Packages/Features/Library`
Expected: PASS (existing store/playlist/tag suites + ExportScoreTests).

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Library
git commit -m "feat(android-library): exportScore orchestration + exportFormats wire"
```

---

## Phase 4 — Android Kotlin primitives

### Task 7: PDF renderer (`DrawProgram` → `PdfDocument`)

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/export/PdfScoreRenderer.kt`

- [ ] **Step 1: Implement the renderer**

Mirror the per-`DrawCommand` logic in `swift-sheet-music/.../compose/render/ScoreCanvas.kt:80-154`, drawing into a `PdfDocument` page canvas instead of a Compose canvas. Convert millimetres → points (1 mm = 72/25.4 pt). Load the score via the same path the Reader uses (`ScoreHandle.load(file.readBytes())` then `SheetMusicJNI.nativeComputeLayout(handle.raw, widthMM, heightMM)` then `DrawProgramReader.decode`). Install SMuFL metrics once (as the Reader does via `BravuraMetricsBuilder.buildTable(assets)` + `SheetMusicJNI.nativeInstallSMuFLMetrics`).

```kotlin
package com.keynumber.folino.export

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import com.keynumber.folino.library.ScorePdfRenderer
import io.github.jiyimeta.sheetmusic.ScoreHandle
import io.github.jiyimeta.sheetmusic.SheetMusicJNI
import io.github.jiyimeta.sheetmusic.compose.draw.DrawProgramReader
import io.github.jiyimeta.sheetmusic.compose.draw.model.DrawCommand
import java.io.File
import java.io.FileOutputStream

/** Kotlin impl of the Swift @WireletProvided ScorePdfRenderer. Reuses the Reader's layout pipeline. */
class PdfScoreRenderer(private val context: Context) : ScorePdfRenderer {

    override fun renderPdf(scoreFilePath: String, outPath: String): Boolean {
        return try {
            ensureMetrics()
            val bytes = File(scoreFilePath).readBytes()
            val handle = ScoreHandle.load(bytes) ?: return false
            handle.use { h ->
                val programBytes = SheetMusicJNI.nativeComputeLayout(h.raw, PAGE_WIDTH_MM, PAGE_HEIGHT_MM)
                if (programBytes.isEmpty()) return false
                val program = DrawProgramReader.decode(programBytes)
                val doc = PdfDocument()
                for (page in program.pages) {
                    val wPt = (page.widthMM * MM_TO_PT).toInt()
                    val hPt = (page.heightMM * MM_TO_PT).toInt()
                    val pdfPage = doc.startPage(PdfDocument.PageInfo.Builder(wPt, hPt, 1).create())
                    drawCommands(pdfPage.canvas, page.commands)
                    doc.finishPage(pdfPage)
                }
                FileOutputStream(File(outPath)).use { doc.writeTo(it) }
                doc.close()
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun ensureMetrics() {
        if (metricsInstalled) return
        val table = io.github.jiyimeta.sheetmusic.compose.BravuraMetricsBuilder.buildTable(context.assets)
        SheetMusicJNI.nativeInstallSMuFLMetrics(table)
        metricsInstalled = true
    }

    // Coordinate space: commands are in mm; scale canvas to points. Mirror ScoreCanvas's command handling:
    // MoveTo/LineTo/CubicTo build a path; Stroke draws it; FillRect fills; Glyph/Text draw with the right typeface;
    // SetColor updates the active paint color (packed ARGB).
    private fun drawCommands(canvas: Canvas, commands: List<DrawCommand>) {
        canvas.scale(MM_TO_PT.toFloat(), MM_TO_PT.toFloat())
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val path = Path()
        // ... port ScoreCanvas:80-154 exactly, substituting `canvas`/`paint`/`path`,
        //     loading the SMuFL (Bravura) Typeface for Glyph and the default Typeface for Text.
    }

    companion object {
        private const val PAGE_WIDTH_MM = 210.0   // A4; match ReaderViewModel.PAGE_WIDTH_MM
        private const val PAGE_HEIGHT_MM = 297.0
        private const val MM_TO_PT = 72.0 / 25.4
        @Volatile private var metricsInstalled = false
    }
}
```

The `drawCommands` body must be a faithful port of `ScoreCanvas`'s command switch — read that file and replicate each branch. Use the same Bravura `Typeface` loading the Compose renderer uses (find it in `ScoreCanvas.kt` / its font helper) so glyphs render identically. Confirm the exact `PAGE_WIDTH_MM` / `PAGE_HEIGHT_MM` constants from `ReaderViewModel.kt` and reuse them.

- [ ] **Step 2: Compile the app Kotlin**

Run: `Android/gradlew -p Android :app:compileDebugKotlin --no-daemon` (release toolchain on PATH).
Expected: BUILD SUCCESSFUL. (Visual correctness is verified on device in Phase 6.)

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/export/PdfScoreRenderer.kt
git commit -m "feat(android-library): PDF export primitive (DrawProgram -> PdfDocument)"
```

### Task 8: Audio exporter + `RoomLibraryStore.scoresDirectoryPath`

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/export/AudioScoreExporter.kt`
- Modify: `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt`

- [ ] **Step 1: Implement the audio exporter**

```kotlin
package com.keynumber.folino.export

import android.content.Context
import android.os.ParcelFileDescriptor
import com.keynumber.folino.library.ScoreAudioFileExporter
import io.github.jiyimeta.sheetmusic.ScoreHandle
import io.github.jiyimeta.sheetmusic.audio.AndroidPlaybackEngine
import io.github.jiyimeta.sheetmusic.audio.model.AudioExportRange
import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat
import kotlinx.coroutines.runBlocking
import java.io.File

/** Kotlin impl of @WireletProvided ScoreAudioFileExporter via AndroidPlaybackEngine.exportAudioFile. */
class AudioScoreExporter(
    private val context: Context,
    private val engineFactory: () -> AndroidPlaybackEngine,
) : ScoreAudioFileExporter {

    override fun exportAudio(scoreFilePath: String, outPath: String): Boolean {
        return try {
            val bytes = File(scoreFilePath).readBytes()
            val handle = ScoreHandle.load(bytes) ?: return false
            handle.use { h ->
                val outFile = File(outPath).apply { parentFile?.mkdirs(); if (exists()) delete() }
                ParcelFileDescriptor.open(
                    outFile.apply { createNewFile() },
                    ParcelFileDescriptor.MODE_READ_WRITE,
                ).use { pfd ->
                    val engine = engineFactory()
                    runBlocking {
                        engine.exportAudioFile(
                            outputFd = pfd,
                            scoreHandle = h.raw,
                            format = AudioFileFormat.M4a(),
                            range = AudioExportRange.Full,
                        )
                    }
                }
            }
            true
        } catch (e: Exception) {
            false
        }
    }
}
```

The `engineFactory` constructs an `AndroidPlaybackEngine(context, soundfontResolver = FolinoSoundfontResolver(context))` — reuse whatever soundfont resolver the Reader already wires (find it via `grep -rn "AndroidPlaybackEngine(" Android`). If construction is cheap, inline it; otherwise pass a factory as shown.

- [ ] **Step 2: Implement `scoresDirectoryPath` in `RoomLibraryStore`**

In `RoomLibraryStore.kt`, add the override (the scores dir is already computed in the class — reuse that `File`):

```kotlin
override fun scoresDirectoryPath(): String = scoresDir.absolutePath
```

(Confirm the existing field name for the scores directory — the explore showed `File(context.applicationContext.filesDir, "Scores")`. If it's a local in the constructor, promote it to a `private val scoresDir`.)

- [ ] **Step 3: Compile the library + app Kotlin**

Run: `Android/gradlew -p Android :FolinoLibraryAndroid:compileDebugKotlin :app:compileDebugKotlin --no-daemon`
Expected: BUILD SUCCESSFUL — the generated `LibraryStore` Kotlin interface now requires `scoresDirectoryPath()`, satisfied by the override.

- [ ] **Step 4: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/export/AudioScoreExporter.kt Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt
git commit -m "feat(android-library): audio export primitive + scoresDirectoryPath"
```

---

## Phase 5 — Android share + UI

### Task 9: FileProvider + share launcher

**Files:**
- Create: `Android/app/src/main/res/xml/file_paths.xml`
- Modify: `Android/app/src/main/AndroidManifest.xml`
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/export/ScoreShareLauncher.kt`

- [ ] **Step 1: Add the FileProvider paths**

`Android/app/src/main/res/xml/file_paths.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<paths>
    <cache-path name="exports" path="Exports/" />
</paths>
```

- [ ] **Step 2: Declare the provider in the manifest**

Inside `<application>` in `AndroidManifest.xml`:

```xml
<provider
    android:name="androidx.core.content.FileProvider"
    android:authorities="com.keynumber.folino.fileprovider"
    android:exported="false"
    android:grantUriPermissions="true">
    <meta-data
        android:name="android.support.FILE_PROVIDER_PATHS"
        android:resource="@xml/file_paths" />
</provider>
```

- [ ] **Step 3: Implement the share launcher**

```kotlin
package com.keynumber.folino.export

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File

object ScoreShareLauncher {
    private const val AUTHORITY = "com.keynumber.folino.fileprovider"

    fun exportsDir(context: Context): File =
        File(context.cacheDir, "Exports").apply { mkdirs() }

    private fun mime(path: String): String = when (path.substringAfterLast('.').lowercase()) {
        "pdf" -> "application/pdf"
        "mid" -> "audio/midi"
        "m4a" -> "audio/mp4"
        "mscz" -> "application/octet-stream"
        else -> "application/octet-stream"
    }

    fun share(context: Context, paths: List<String>) {
        val files = paths.filter { it.isNotEmpty() }.map { File(it) }.filter { it.exists() }
        if (files.isEmpty()) return
        val uris = ArrayList(files.map { FileProvider.getUriForFile(context, AUTHORITY, it) })
        val intent = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).apply {
                putExtra(Intent.EXTRA_STREAM, uris[0])
                type = mime(files[0].path)
            }
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                type = if (files.map { it.extension }.distinct().size == 1) mime(files[0].path) else "*/*"
            }
        }
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startActivity(Intent.createChooser(intent, null))
    }
}
```

- [ ] **Step 4: Compile**

Run: `Android/gradlew -p Android :app:compileDebugKotlin --no-daemon`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Commit**

```bash
git add Android/app/src/main/res/xml/file_paths.xml Android/app/src/main/AndroidManifest.xml Android/app/src/main/kotlin/com/keynumber/folino/export/ScoreShareLauncher.kt
git commit -m "feat(android-library): FileProvider + ACTION_SEND share launcher"
```

### Task 10: Wire the two primitives into the ViewModel factory

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`

- [ ] **Step 1: Pass the primitives to the generated factory**

Update `LibraryVMFactory.create` (the generated factory now requires all three injected services):

```kotlin
override fun <T : ViewModel> create(modelClass: Class<T>): T =
    LibraryAndroidStoreViewModel.create(
        store = com.keynumber.folino.library.RoomLibraryStore(context),
        pdfRenderer = com.keynumber.folino.export.PdfScoreRenderer(context),
        audioExporter = com.keynumber.folino.export.AudioScoreExporter(
            context,
            engineFactory = { /* construct AndroidPlaybackEngine as the Reader does */ },
        ),
    ) as T
```

(Use the exact `AndroidPlaybackEngine` construction discovered in Task 8 Step 1.)

- [ ] **Step 2: Compile**

Run: `Android/gradlew -p Android :app:compileDebugKotlin --no-daemon`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(android-library): inject PDF + audio primitives into Library VM"
```

### Task 11: Export format sheet (single + bulk)

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/ExportFormatSheet.kt`
- Modify: `Android/app/src/main/res/values/strings.xml` (+ any localized `values-*/strings.xml`)

- [ ] **Step 1: Add strings**

In `strings.xml` (and mirror in localized variants that already translate library strings):

```xml
<string name="export">Export</string>
<string name="export_format_musescore4">MuseScore 4</string>
<string name="export_format_musescore3">MuseScore 3</string>
<string name="export_format_pdf">PDF</string>
<string name="export_format_midi">MIDI</string>
<string name="export_format_audio">Audio (M4A)</string>
<string name="export_original_badge">Original</string>
<string name="export_failed">Export failed</string>
```

- [ ] **Step 2: Implement the sheet**

Mirror `AddToPlaylistSheet.kt`. The sheet lists `viewModel.exportFormats(scoreId)` rows; tapping one triggers the export+share callback supplied by the screen (the screen owns coroutine/progress/share). For bulk, the same format list applies to all selected ids.

```kotlin
@file:OptIn(ExperimentalMaterial3Api::class)
package com.keynumber.folino.ui.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.keynumber.folino.R

private fun labelFor(token: String): Int = when (token) {
    "museScoreV4" -> R.string.export_format_musescore4
    "museScoreV3" -> R.string.export_format_musescore3
    "pdf" -> R.string.export_format_pdf
    "midi" -> R.string.export_format_midi
    "audioM4A" -> R.string.export_format_audio
    else -> R.string.export
}

@Composable
fun ExportFormatSheet(
    formats: List<com.keynumber.folino.library.ScoreExportFormatWire>,
    onPick: (token: String) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        LazyColumn(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
            items(formats, key = { it.format }) { f ->
                ListItem(
                    headlineContent = { Text(stringResource(labelFor(f.format))) },
                    trailingContent = if (f.isOriginal) {
                        { Text(stringResource(R.string.export_original_badge)) }
                    } else null,
                    modifier = Modifier.clickable { onPick(f.format) },
                )
            }
        }
    }
}
```

(`ScoreExportFormatWire` is the generated Kotlin mirror of the Swift wire struct; confirm its generated package — same package as `LibraryAndroidStoreViewModel`.)

- [ ] **Step 3: Compile**

Run: `Android/gradlew -p Android :app:compileDebugKotlin --no-daemon`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/ExportFormatSheet.kt Android/app/src/main/res/values/strings.xml
git commit -m "feat(android-library): export format ModalBottomSheet"
```

### Task 12: Hook the sheet into the row menu + bulk CAB

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt`

- [ ] **Step 1: Add export state + the run-and-share helper**

In the Library screen composable, add state and a coroutine helper that calls `exportScore` off the main thread, then shares (or shows the failure Snackbar):

```kotlin
val context = LocalContext.current
val scope = rememberCoroutineScope()
val snackbar = remember { SnackbarHostState() }   // ensure a SnackbarHost is in the Scaffold
var exportFormats by remember { mutableStateOf<List<com.keynumber.folino.library.ScoreExportFormatWire>>(emptyList()) }
var exportTargets by remember { mutableStateOf<List<String>>(emptyList()) } // score ids
var showExportSheet by remember { mutableStateOf(false) }
var exporting by remember { mutableStateOf(false) }
val exportFailed = stringResource(R.string.export_failed)

fun beginExport(ids: List<String>) {
    if (ids.isEmpty()) return
    exportTargets = ids
    exportFormats = viewModel.exportFormats(ids.first()) // formats are identical across scores
    showExportSheet = true
}

fun runExport(token: String) {
    showExportSheet = false
    val ids = exportTargets
    scope.launch {
        exporting = true
        val dir = com.keynumber.folino.export.ScoreShareLauncher.exportsDir(context).absolutePath
        val paths = withContext(Dispatchers.Default) {
            ids.map { viewModel.exportScore(it, token, dir) }
        }
        exporting = false
        if (paths.any { it.isEmpty() }) {
            snackbar.showSnackbar(exportFailed)
            return@launch
        }
        com.keynumber.folino.export.ScoreShareLauncher.share(context, paths)
    }
}
```

- [ ] **Step 2: Add "Export" to the per-row DropdownMenu**

In the `trailingContent` `DropdownMenu` (LibraryScreen.kt ~283-306), add as the first item:

```kotlin
DropdownMenuItem(
    text = { Text(stringResource(R.string.export)) },
    onClick = {
        menu = false
        onExport()   // new ScoreRow callback → beginExport(listOf(row.id))
    },
)
```

Add an `onExport: () -> Unit` parameter to `ScoreRow` (mirroring `onAddToPlaylist`) and pass `{ beginExport(listOf(row.id)) }` at the call site.

- [ ] **Step 3: Add Export to the selection CAB**

In the selection-mode `TopAppBar` `actions` (LibraryScreen.kt ~104-147), add an IconButton (use `Icons.Filled.IosShare` or `Icons.Filled.Share`):

```kotlin
IconButton(
    enabled = selectedIds.isNotEmpty(),
    onClick = { beginExport(selectedIds.toList()) },
) {
    Icon(Icons.Filled.Share, contentDescription = stringResource(R.string.export))
}
```

- [ ] **Step 4: Render the sheet + progress**

Near the other sheets (AddToPlaylistSheet / EditTagsSheet) in the screen:

```kotlin
if (showExportSheet) {
    ExportFormatSheet(
        formats = exportFormats,
        onPick = { runExport(it) },
        onDismiss = { showExportSheet = false },
    )
}
if (exporting) {
    // simple modal progress; e.g. a Box with CircularProgressIndicator over the content
}
```

Ensure the `Scaffold` has `snackbarHost = { SnackbarHost(snackbar) }`.

- [ ] **Step 5: Compile**

Run: `Android/gradlew -p Android :app:compileDebugKotlin --no-daemon`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 6: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt
git commit -m "feat(android-library): export from row menu + bulk CAB, share on success"
```

---

## Phase 6 — Device verification

### Task 13: Build, install, and verify on Pixel

**Files:** none (verification only)

- [ ] **Step 1: Rebuild the Android Swift `.so`**

Run `Scripts/android-build-library-libs.sh` with the release toolchain on PATH (see the command reference at the top). This regenerates the `FolinoLibraryJNI` `.so` + the wirelet Kotlin bridge for the new `exportScore` / `exportFormats` / injected primitives. Without this the app links a stale library and `exportScore` is missing (see memory: native drift crash).
Expected: script completes; regenerated `.so` + generated Kotlin under `Android/.../generated/`.

- [ ] **Step 2: Install on the device**

Run: `Android/gradlew -p Android :app:installDebug --no-daemon` (release toolchain on PATH).
Expected: `INSTALLED`.

- [ ] **Step 3: Launch and verify (Claude drives install+launch; user verifies UX)**

Launch: `adb shell monkey -p com.keynumber.folino -c android.intent.category.LAUNCHER 1`
Then verify each format end-to-end (single row → Export → format → share sheet appears; check the produced file opens):
- MIDI → `.mid` shared.
- MuseScore v4 / v3 → `.mscz` shared (v4 of a v4-source score is byte-identical copy).
- PDF → `.pdf` renders the score (compare visually to the Reader).
- Audio → `.m4a` plays the synthesized score.
- Bulk: select 2+, Export, pick a format → `ACTION_SEND_MULTIPLE` with all files.
- Failure path: confirm a Snackbar appears if a producer fails.

Capture a screenshot of the share sheet and one exported PDF opened, per the project's Android verification rule.

- [ ] **Step 4: Final commit (if any verification fixups were needed)**

```bash
git add -A
git commit -m "fix(android-library): export device-verification fixups"
```

---

## Self-review notes (for the implementer)

- The Swift `exportScore` `switch fmt` is exhaustive over `ScoreShareFormat`; adding a future format breaks compilation here AND in iOS `LiveScoreShareService.prepareShare` — both must be handled, which is the intended divergence guard.
- Format string tokens are defined once in Swift (`token(for:)` / `parseFormat`) and consumed by Kotlin (`labelFor`); keep these in sync. They are NOT the Domain enum — they're the wire encoding. If you add a format, update `token(for:)`, `parseFormat`, `labelFor`, and `mime`.
- PDF/audio correctness is verified on device (Phase 6), not in unit tests — the host tests only assert routing to the injected primitives.
- If the wirelet revision does not support a 3-arg `@WireletProvided` init, fall back to bundling the two primitives behind a single provided "ExportPrimitives" protocol (one injected service exposing both `renderPdf` and `exportAudio`) — this keeps a single extra `create(...)` argument.

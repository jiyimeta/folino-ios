# Annotated PDF export — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two share formats that export a score as a PDF with the user's
handwritten annotations baked in — one over the engraved notation, one over a
PDF-origin item's original pages.

**Architecture:** Placement is pure geometry and lands in the platform-neutral
`ReaderAnnotationCore` target, so Android reuses it. iOS rasterizes the ink with
PencilKit (the renderer the Reader already uses for static ink) and composes the
page with `CGContext.drawPDFPage`, which replays the base page's content stream
and therefore keeps the notation vector. `LiveScoreShareService` reaches the
renderer through a new Domain protocol so Infrastructure never imports a Feature.

**Tech Stack:** Swift 6.3, iOS 18 floor, SwiftPM packages, Swift Testing,
PencilKit, CoreGraphics/PDFKit, swift-sheet-music 2.3.0 (`SheetMusicPDF`,
`SheetMusicLayout`, `SheetMusicLayoutApple`).

**Spec:** `docs/superpowers/specs/2026-08-31-annotated-pdf-export-design.md`

## Global Constraints

- **Worktree.** All work happens in
  `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/annotated-pdf-export`
  on branch `worktree-annotated-pdf-export`. Every `git` command must be
  `git -C <that absolute path> …`. Never touch the primary checkout.
- **Deployment floor is iOS 18.0.** No raw iOS 26-only API; go through
  `Packages/Utility/Sources/UtilityUI/GlassEffectCompat.swift` if any is needed
  (this plan needs none).
- **Layering.** `Feature → Infrastructure` and `Infrastructure → Feature` are
  both forbidden. `Domain` may not import Infrastructure, Features or App.
  Utility may not import anything else in the repo.
- **New tests use Swift Testing** (`import Testing`, `@Suite`, `@Test`,
  `#expect`). Test function names in this repo use backticked sentences —
  match the surrounding files.
- **Access control:** write new symbols with no access modifier; promote to
  `public` only when something outside the module references it. Tests use
  `@testable import`, never widen access for a test.
- **Comments** reflow at 120 columns, American spelling except where an Apple
  API spells it otherwise (`cancelled`).
- **User-facing copy never contains internal feature names** (`Reader`,
  `Library`, …), and the brand is lowercase `folino`.
- **Localization:** every new user-visible string needs all five locales —
  `en`, `ja`, `ko`, `zh-Hans`, `zh-Hant`.
- **Simulator destination:** `platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394`
  (iPhone 17 Pro Max, already booted). A bare `name=iPhone 17 Pro Max` resolves
  to an OS that is not installed and fails.
- **Build flag:** every `xcodebuild` invocation needs
  `-skipPackagePluginValidation` (SwiftLint build-tool plugin).
- **Do not use partial staging** (`git add -p`). Stage whole files. The
  pre-commit hook rewrites staged Swift files and fails until clean — re-run
  `git add` on the rewritten files and commit again.
- **Do not `git stash`** — the stash stack is shared with parallel sessions.

### Package test commands

Run from the package directory (`cd` first; the schemes are per-package):

| Package | Directory | Scheme |
| --- | --- | --- |
| Domain | `Packages/Domain` | `Domain` |
| Infrastructure | `Packages/Infrastructure` | `Infrastructure-Package` |
| Reader | `Packages/Features/Reader` | `Reader` |
| ScoreUI | `Packages/ScoreUI` | `ScoreUI` |

```bash
xcodebuild test \
  -scheme <Scheme> \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation \
  -only-testing:<Scheme>/<SuiteName>
```

`swift test` does **not** work in this repo — the SwiftLint plugin needs a
context the SwiftPM CLI cannot provide. Always go through `xcodebuild`.

---

## File structure

**Created**

| Path | Responsibility |
| --- | --- |
| `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/PDFVectorOutputTests.swift` | Characterization test: the engraved PDF export is vector. Guards the design's premise. |
| `Packages/Domain/Sources/Domain/Logic/AnnotatedExportAvailability.swift` | Pure rule for which annotated rows an item offers. Shared with Android. |
| `Packages/Domain/Sources/Domain/Protocols/AnnotatedPDFRendering.swift` | The seam Infrastructure calls; implemented in Reader. |
| `Packages/Domain/Tests/DomainTests/AnnotatedExportAvailabilityTests.swift` | Tests for the rule and the filenames. |
| `Packages/Features/Reader/Sources/ReaderAnnotationCore/AnnotatedExportPlanner.swift` | Neutral placement: which drawing lands on which page, with what transform. |
| `Packages/Features/Reader/Tests/ReaderTests/AnnotatedExportPlannerTests.swift` | Tests for the planner. |
| `Packages/Features/Reader/Sources/Reader/Annotation/Export/EngravedExportLayout.swift` | Mirrors `PDFExporter`'s layout resolution to produce page bands. |
| `Packages/Features/Reader/Sources/Reader/Annotation/Export/AnnotatedPDFComposer.swift` | Stamps ink images onto a base PDF's pages, keeping the base vector. |
| `Packages/Features/Reader/Sources/Reader/Annotation/Export/ReaderAnnotatedPDFRenderer.swift` | `AnnotatedPDFRendering` conformance; wires layout + planner + composer. |
| `Packages/Features/Reader/Tests/ReaderTests/EngravedExportLayoutTests.swift` | The drift guard: the mirror agrees with a real export. |
| `Packages/Features/Reader/Tests/ReaderTests/AnnotatedPDFComposerTests.swift` | Composition: page count, vector survival, image XObject, mismatch guard. |

**Modified**

| Path | Change |
| --- | --- |
| `Packages/Domain/Sources/Domain/Protocols/ScoreShareService.swift` | Two new `ScoreShareFormat` cases, `canonicalExtension`, export-name suffixes. |
| `Packages/Domain/Sources/Domain/Analytics/DomainEnums+Analytics.swift` | Analytics tokens for the new cases. |
| `Packages/Features/Reader/Package.swift` | Reader target gains `SheetMusicPDF`. |
| `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift` | Two new dependencies; annotated rows; annotated `prepareShare` branches. |
| `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift` | Fakes for the new dependencies; new cases. |
| `Packages/ScoreUI/Sources/ScoreUI/ShareSubmenu.swift` | Menu label + icon for the new cases. |
| `Packages/ScoreUI/Sources/ScoreUI/Resources/Localizable.xcstrings` | Two new keys × five locales. |
| `Packages/Features/Library/Sources/Library/Views/BulkActionBar.swift` | Exhaustive-switch completion (bulk share never offers these). |
| `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift` | Exhaustive-switch completion + the `PARITY(android)` marker. |
| `Packages/Features/Library/Sources/FolinoLibraryJNI/AnalyticsBridge+TokenMappers.swift` | Token round-trip for the new cases. |
| `App/AppBootstrap.swift` | Inject the renderer and the annotation store into the share service. |
| `docs/engineering/ios-android-parity.md` | Regenerated by `Scripts/parity-report.py`. |

---

## Task 1: Prove the engraved PDF export is vector

The whole design assumes swift-sheet-music writes the notation into the PDF as
paths and glyphs, not as a bitmap. Nothing in the repo asserts that today. This
task adds the assertion first, so that if the premise is false the plan stops
here instead of building four tasks on top of it.

**Files:**
- Create: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/PDFVectorOutputTests.swift`

**Interfaces:**
- Consumes: `Domain.ScorePDFRenderer`, `ScoreFiles.CoreGraphicsPDFRenderer`,
  `SheetMusicCore.Score`.
- Produces: `PDFVectorOutputTests.multiSystemScore(measures:)` — nothing later
  depends on it, but Task 5 writes a similar fixture and should match its shape.

- [ ] **Step 1: Write the test**

Create `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/PDFVectorOutputTests.swift`:

```swift
import CoreGraphics
@testable import Domain
import Foundation
@testable import ScoreFiles
import SheetMusicCore
import Testing

/// Characterization tests for the premise the annotated-PDF export rests on: `CoreGraphicsPDFRenderer` writes the
/// engraved notation into the PDF as vector content (glyphs and paths), not as a page-sized bitmap. Annotated export
/// stamps a raster ink image on top of these pages, which only stays acceptable while the notation underneath is
/// vector. If swift-sheet-music ever switches to rasterizing, these fail.
@Suite("PDF vector output")
struct PDFVectorOutputTests {
    /// A score long enough to paginate: `measures` whole-note bars on one staff.
    static func multiSystemScore(measures: Int) -> Score {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let bars = (0 ..< measures).map { _ in Measure(voices: [Voice(elements: [.chord(chord)])]) }
        return Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: bars)])],
        )
    }

    /// Names of every resource entry of one kind on a page, e.g. `/Font` or `/XObject`.
    static func resourceNames(of page: CGPDFPage, kind: String) -> [String] {
        guard let dict = page.dictionary else { return [] }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { return [] }
        var bucket: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, kind, &bucket), let bucket else { return [] }
        final class Box { var names: [String] = [] }
        let box = Box()
        CGPDFDictionaryApplyBlock(bucket, { key, _, info in
            Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue().names.append(String(cString: key))
            return true
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.names
    }

    @Test
    func `the engraved export embeds fonts rather than rasterizing the page`() async throws {
        let data = try await CoreGraphicsPDFRenderer().renderPDF(
            score: Self.multiSystemScore(measures: 8), title: "Vector probe",
        )
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        #expect(document.numberOfPages >= 1)

        let page = try #require(document.page(at: 1))
        // A rasterized page would carry no fonts at all — every glyph would be pixels.
        #expect(!Self.resourceNames(of: page, kind: "Font").isEmpty)
        // …and it would carry exactly the one image that is the page.
        #expect(Self.resourceNames(of: page, kind: "XObject").isEmpty)
    }

    @Test
    func `a long score paginates into more than one page`() async throws {
        let data = try await CoreGraphicsPDFRenderer().renderPDF(
            score: Self.multiSystemScore(measures: 240), title: "Long",
        )
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        #expect(document.numberOfPages > 1)
    }
}
```

- [ ] **Step 2: Run the tests**

```bash
cd Packages/Infrastructure
xcodebuild test -scheme Infrastructure-Package \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation \
  -only-testing:InfrastructureTests/PDFVectorOutputTests
```

Expected: PASS.

**If `the engraved export embeds fonts…` FAILS, stop and report.** The design's
premise is wrong and the remaining tasks need rework — do not "fix" the test to
make it pass. If only `a long score paginates…` fails, raise `measures` until it
does and note the number used.

- [ ] **Step 3: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/annotated-pdf-export add Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/PDFVectorOutputTests.swift
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/annotated-pdf-export commit -m "test(scorefiles): pin the engraved PDF export as vector output

Annotated export stamps a raster ink image onto these pages, which is only
acceptable while the notation underneath stays vector. Nothing asserted that
before; a swift-sheet-music change to rasterized pages would have shipped
silently."
```

---

## Task 2: Domain — the two formats, the availability rule, the filenames, and every switch they force

Adding a case to `ScoreShareFormat` breaks four exhaustive switches outside
Domain, and one of them is in `ScoreUI`, which the `Reader` package depends on.
Splitting the enum change from those switch completions would leave the tree
uncompilable for Tasks 3-6, so they land here, in one atomic change. The share
service's own switch gets a throwing placeholder that Task 7 replaces with the
real routing.

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Protocols/ScoreShareService.swift`
- Modify: `Packages/Domain/Sources/Domain/Analytics/DomainEnums+Analytics.swift`
- Create: `Packages/Domain/Sources/Domain/Logic/AnnotatedExportAvailability.swift`
- Create: `Packages/Domain/Tests/DomainTests/AnnotatedExportAvailabilityTests.swift`
- Modify: `Packages/ScoreUI/Sources/ScoreUI/ShareSubmenu.swift`
- Modify: `Packages/ScoreUI/Sources/ScoreUI/Resources/Localizable.xcstrings`
- Modify: `Packages/Features/Library/Sources/Library/Views/BulkActionBar.swift`
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/AnalyticsBridge+TokenMappers.swift`
- Modify: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift` (placeholder branch only)
- Modify: `docs/engineering/ios-android-parity.md` (regenerated)

**Interfaces:**
- Consumes: `ScoreShareFormat`, `ScoreExportNaming.sanitize(title:)`.
- Produces:
  - `ScoreShareFormat.annotatedPDF`, `ScoreShareFormat.annotatedOriginalPDF`
  - `ScoreShareFormat.isAnnotated: Bool`
  - `AnnotatedExportAvailability.formats(hasMusicalInk:hasPageInk:hasOriginalPDF:isEngravable:) -> [ScoreShareFormat]`
  - `ScoreExportNaming.fileName(title:format:) -> String`

- [ ] **Step 1: Write the failing tests**

Create `Packages/Domain/Tests/DomainTests/AnnotatedExportAvailabilityTests.swift`:

```swift
@testable import Domain
import Testing

@Suite("AnnotatedExportAvailability")
struct AnnotatedExportAvailabilityTests {
    @Test
    func `a score with no ink offers no annotated row`() {
        #expect(AnnotatedExportAvailability.formats(
            hasMusicalInk: false, hasPageInk: false, hasOriginalPDF: false, isEngravable: true,
        ) == [])
    }

    @Test
    func `an ordinary annotated score offers the engraved row only`() {
        #expect(AnnotatedExportAvailability.formats(
            hasMusicalInk: true, hasPageInk: false, hasOriginalPDF: false, isEngravable: true,
        ) == [.annotatedPDF])
    }

    @Test
    func `an unconverted PDF offers the original row and never the engraved one`() {
        #expect(AnnotatedExportAvailability.formats(
            hasMusicalInk: true, hasPageInk: true, hasOriginalPDF: true, isEngravable: false,
        ) == [.annotatedOriginalPDF])
    }

    @Test
    func `page ink without an original PDF on disk offers nothing`() {
        #expect(AnnotatedExportAvailability.formats(
            hasMusicalInk: false, hasPageInk: true, hasOriginalPDF: false, isEngravable: true,
        ) == [])
    }

    @Test
    func `a converted PDF item annotated on both sources offers both rows in order`() {
        #expect(AnnotatedExportAvailability.formats(
            hasMusicalInk: true, hasPageInk: true, hasOriginalPDF: true, isEngravable: true,
        ) == [.annotatedPDF, .annotatedOriginalPDF])
    }

    @Test
    func `a converted PDF item with only page ink offers the original row only`() {
        #expect(AnnotatedExportAvailability.formats(
            hasMusicalInk: false, hasPageInk: true, hasOriginalPDF: true, isEngravable: true,
        ) == [.annotatedOriginalPDF])
    }

    @Test
    func `annotated filenames are suffixed so they cannot collide with the plain PDF`() {
        #expect(ScoreExportNaming.fileName(title: "Sonata", format: .pdf) == "Sonata.pdf")
        #expect(ScoreExportNaming.fileName(title: "Sonata", format: .annotatedPDF)
            == "Sonata (annotated).pdf")
        #expect(ScoreExportNaming.fileName(title: "Sonata", format: .annotatedOriginalPDF)
            == "Sonata (original annotated).pdf")
        #expect(ScoreExportNaming.fileName(title: "Sonata", format: .midi) == "Sonata.mid")
    }

    @Test
    func `a hostile title is sanitized before the suffix is appended`() {
        #expect(ScoreExportNaming.fileName(title: "a/b:c", format: .annotatedPDF)
            == "a_b_c (annotated).pdf")
        #expect(ScoreExportNaming.fileName(title: "", format: .annotatedPDF)
            == "score (annotated).pdf")
    }

    @Test
    func `only the annotated formats report isAnnotated`() {
        #expect(ScoreShareFormat.annotatedPDF.isAnnotated)
        #expect(ScoreShareFormat.annotatedOriginalPDF.isAnnotated)
        for format in ScoreShareFormat.allOrdered {
            #expect(!format.isAnnotated)
        }
    }

    @Test
    func `allOrdered stays the five plain formats so bulk share is unaffected`() {
        #expect(ScoreShareFormat.allOrdered == [.museScoreV4, .museScoreV3, .pdf, .midi, .audioM4A])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd Packages/Domain
xcodebuild test -scheme Domain \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation \
  -only-testing:DomainTests/AnnotatedExportAvailabilityTests
```

Expected: compile failure — `annotatedPDF` and `AnnotatedExportAvailability`
do not exist.

- [ ] **Step 3: Add the enum cases and the naming helper**

In `Packages/Domain/Sources/Domain/Protocols/ScoreShareService.swift`, add the
two cases to `ScoreShareFormat` after `.audioM4A`:

```swift
    case audioM4A
    /// The engraved notation with the item's musical-anchored ink baked in.
    case annotatedPDF
    /// A PDF-origin item's original pages with its page-anchored ink baked in.
    case annotatedOriginalPDF
```

Update `canonicalExtension` — both are `pdf`:

```swift
    public var canonicalExtension: String {
        switch self {
        case .museScoreV4, .museScoreV3: "mscz"
        case .pdf, .annotatedPDF, .annotatedOriginalPDF: "pdf"
        case .midi: "mid"
        case .audioM4A: "m4a"
        }
    }
```

Leave `allOrdered` exactly as it is, and extend its doc comment:

```swift
    /// The formats in display order — the single source for both the iOS menu and the Android sheet. The annotated
    /// formats are deliberately absent: whether they appear depends on the item's ink, so they come from
    /// `AnnotatedExportAvailability.formats(…)` and are appended after these. Bulk share offers only this list,
    /// because a selection's items do not agree about what ink they carry.
    public static let allOrdered: [ScoreShareFormat] = [.museScoreV4, .museScoreV3, .pdf, .midi, .audioM4A]
```

`matching(for:)` needs no change — it switches over `ScoreSource`, not over
`ScoreShareFormat`, and an annotated export is never the source's own bytes.

Add, in the same file:

```swift
extension ScoreShareFormat {
    /// Whether this format bakes the item's handwriting into the output. Annotated formats never carry the
    /// `isOriginal` flag and never appear in a bulk selection's menu.
    public var isAnnotated: Bool {
        switch self {
        case .annotatedPDF, .annotatedOriginalPDF: true
        case .museScoreV4, .museScoreV3, .pdf, .midi, .audioM4A: false
        }
    }
}
```

Extend `ScoreExportNaming` in the same file:

```swift
    /// Full exported filename for `title` in `format`: the sanitized title, an annotated-export suffix when the
    /// format has one, then the format's canonical extension. The suffix exists because every share lands in one
    /// temp directory — without it an annotated PDF would overwrite the plain PDF of the same item, and vice versa.
    /// Suffixes stay English (they are filenames, not UI copy) so iOS and Android produce identical names.
    public static func fileName(title: String, format: ScoreShareFormat) -> String {
        let stem = sanitize(title: title)
        let suffix = switch format {
        case .annotatedPDF: " (annotated)"
        case .annotatedOriginalPDF: " (original annotated)"
        case .museScoreV4, .museScoreV3, .pdf, .midi, .audioM4A: ""
        }
        return "\(stem)\(suffix).\(format.canonicalExtension)"
    }
```

Create `Packages/Domain/Sources/Domain/Logic/AnnotatedExportAvailability.swift`:

```swift
import Foundation

/// Which annotated-PDF rows an item offers, given what ink it carries and what documents it has. Pure and shared:
/// iOS's share menu and Android's export sheet call this, so the two cannot disagree about when a row appears.
///
/// One export means one base document, and an item can have been annotated on two of them — the engraved notation
/// (`.musical` anchors) and, for a PDF-origin item, the original pages (`.page` anchors). Rather than pick a base and
/// silently drop the other kind of ink, a row is offered per base that actually carries ink.
public enum AnnotatedExportAvailability {
    /// - Parameters:
    ///   - hasMusicalInk: the layer holds at least one `.musical` drawing anchor.
    ///   - hasPageInk: the layer holds at least one `.page` drawing anchor.
    ///   - hasOriginalPDF: `ScoreItem.originalPDFFileName != nil` — the file the page ink was drawn on is on disk.
    ///   - isEngravable: the item has notation to engrave. False while a PDF import is unconverted
    ///     (`ScoreItem.pdfOriginState == .unconverted`), where there is no score to render whatever the ink says.
    /// - Returns: the annotated formats in display order; empty when the item has nothing to bake.
    public static func formats(
        hasMusicalInk: Bool,
        hasPageInk: Bool,
        hasOriginalPDF: Bool,
        isEngravable: Bool,
    ) -> [ScoreShareFormat] {
        var formats: [ScoreShareFormat] = []
        if hasMusicalInk, isEngravable { formats.append(.annotatedPDF) }
        if hasPageInk, hasOriginalPDF { formats.append(.annotatedOriginalPDF) }
        return formats
    }
}
```

- [ ] **Step 4: Complete the analytics switch**

In `Packages/Domain/Sources/Domain/Analytics/DomainEnums+Analytics.swift`, the
`extension ScoreShareFormat` around line 57 maps each case to a token. Add:

```swift
        case .annotatedPDF: "pdf_annotated"
        case .annotatedOriginalPDF: "pdf_original_annotated"
```

Leave the `ScoreFormat` extension near line 10 alone — it is a different enum.

- [ ] **Step 5: Run the Domain tests**

```bash
cd Packages/Domain
xcodebuild test -scheme Domain \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation \
  -only-testing:DomainTests/AnnotatedExportAvailabilityTests
```

Expected: PASS. Then the whole Domain suite:

```bash
xcodebuild test -scheme Domain \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation
```

Expected: PASS.

- [ ] **Step 6: Add the localized menu strings**

Add two keys to `Packages/ScoreUI/Sources/ScoreUI/Resources/Localizable.xcstrings`,
matching the shape of the existing `scoreUI.format.pdf` entry (a `"state":
"translated"` string unit under each locale):

| Key | en | ja | ko | zh-Hans | zh-Hant |
| --- | --- | --- | --- | --- | --- |
| `scoreUI.format.pdf.annotated` | `PDF (annotated)` | `PDF（書き込みあり）` | `PDF (주석 포함)` | `PDF（含标注）` | `PDF（含標注）` |
| `scoreUI.format.originalPDF.annotated` | `Original PDF (annotated)` | `元のPDF（書き込みあり）` | `원본 PDF (주석 포함)` | `原始 PDF（含标注）` | `原始 PDF（含標注）` |

The Japanese wording is 「書き込み」, matching `reader.toolbar.annotate.start`
(「書き込みを開始」), and 「元のPDF」, matching
`reader.displaySource.showOriginal`. Never write an internal feature name
(`Reader`, `Library`, …) into user copy, and the brand is lowercase `folino`.

- [ ] **Step 7: Complete the menu switches**

In `Packages/ScoreUI/Sources/ScoreUI/ShareSubmenu.swift`:

```swift
private func shareMenuFormatText(for format: ScoreShareFormat) -> Text {
    switch format {
    // …existing cases…
    case .annotatedPDF:
        Text("scoreUI.format.pdf.annotated", bundle: .module)
    case .annotatedOriginalPDF:
        Text("scoreUI.format.originalPDF.annotated", bundle: .module)
    }
}

private func shareMenuIconName(for format: ScoreShareFormat) -> String {
    switch format {
    // …existing cases…
    case .annotatedPDF, .annotatedOriginalPDF:
        "square.and.pencil"
    }
}
```

`ShareFormatMenuItems.placeholderFormats` stays the five plain formats: it is
what the menu shows before `loadFormats` answers, and an annotated row that
vanished on load would be worse than one that appeared.

- [ ] **Step 8: Complete the Library switch**

In `Packages/Features/Library/Sources/Library/Views/BulkActionBar.swift`, add to
`bulkShareFormatLabel` — match the surrounding `Label` construction rather than
copying this literally if it differs:

```swift
    case .annotatedPDF, .annotatedOriginalPDF:
        // Unreachable: `bulkAvailableShareFormats` is a fixed list that never includes an annotated format, because
        // a multi-item selection does not agree about what ink its items carry.
        Label("PDF", systemImage: "square.and.pencil")
```

- [ ] **Step 9: Complete the Android JNI switches and leave the parity marker**

These files compile only under `FOLINO_ANDROID=1`, but an exhaustive switch left
alone there breaks the Android build.

In `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`:

- `token(for:)` (~line 504) and the extension at ~line 966: add
  `case .annotatedPDF: "pdf_annotated"` and
  `case .annotatedOriginalPDF: "pdf_original_annotated"` — the same tokens
  Step 4 used for analytics.
- `parseFormat(_:)` (~line 492): add the two matching string cases.
- The export switch (~line 555): add

```swift
        // PARITY(android): Annotated PDF export — Android needs an androidx.ink renderer and a PdfDocument writer to
        //   fill these in. The placement logic is already shared (`AnnotatedExportPlanner` in ReaderAnnotationCore),
        //   as is the availability rule (`AnnotatedExportAvailability`) and the filename
        //   (`ScoreExportNaming.fileName`), so what is missing is the drawing half only.
        case .annotatedPDF, .annotatedOriginalPDF: return ""
```

- `exportFormats` (~line 525) maps `ScoreShareFormat.allOrdered`, which does not
  contain the annotated cases, so the Android sheet keeps its five rows with no
  further change.

In `Packages/Features/Library/Sources/FolinoLibraryJNI/AnalyticsBridge+TokenMappers.swift`,
add the two tokens to both `switch`es (~lines 36 and 50) so a token round-trips.

- [ ] **Step 10: Add the placeholder branch in the share service**

`LiveScoreShareService.prepareShare` switches exhaustively over
`ScoreShareFormat`. Task 7 gives these cases real routing; for now the tree just
has to compile:

```swift
        case .annotatedPDF, .annotatedOriginalPDF:
            // Task 7 replaces this with the real routing; the rows are not offered yet, so this is unreachable.
            throw DomainError.scoreWriteFailed(reason: "annotated export is not wired up yet")
```

- [ ] **Step 11: Regenerate the parity ledger**

```bash
python3 Scripts/parity-report.py
```

The `parity-ledger` pre-commit hook fails when
`docs/engineering/ios-android-parity.md` is stale, so run this before
committing.

- [ ] **Step 12: Build the packages the new cases touch**

From the worktree root:

```bash
cd Packages/ScoreUI
xcodebuild build -scheme ScoreUI \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation
```

```bash
cd Packages/Features/Reader
xcodebuild build -scheme Reader \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation
```

```bash
cd Packages/Infrastructure
xcodebuild build -scheme Infrastructure-Package \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation
```

Expected: BUILD SUCCEEDED for all three. `Reader` is the one that matters most —
it depends on `ScoreUI`, and Tasks 3-6 build it.

- [ ] **Step 13: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/annotated-pdf-export add Packages/Domain Packages/ScoreUI Packages/Features/Library Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift docs/engineering/ios-android-parity.md
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/annotated-pdf-export commit -m "feat(domain): annotated PDF share formats and their availability rule

An item can be annotated on two documents — the engraved notation and, for a
PDF-origin item, the original pages — so one row is offered per base that
actually carries ink rather than picking a base and dropping the other ink.
The rule is pure so Android's export sheet reads the same answer, and the
filenames carry an English suffix so the annotated export cannot overwrite
the plain PDF in the shared temp directory.

The switches the two new cases force land in the same commit: ScoreUI sits
under Reader, so splitting them would leave the tree uncompilable for the
tasks that follow. Bulk share and the Android sheet both read allOrdered,
which is unchanged, so neither gains a row it cannot fulfil."
```

---

## Task 3: The neutral placement planner

**Files:**
- Create: `Packages/Features/Reader/Sources/ReaderAnnotationCore/AnnotatedExportPlanner.swift`
- Create: `Packages/Features/Reader/Tests/ReaderTests/AnnotatedExportPlannerTests.swift`

**Interfaces:**
- Consumes: `AnnotationAnchoringCore.anchorPoint(for:using:)`,
  `PageAnchoringCore.displayStrokeTransforms(_:pageFrames:)`, `StrokeTransform`,
  `AnchorResolving`, `DrawingAnchor`.
- Produces:
  - `InkPlacement { pageIndex: Int, drawingIndex: Int, transform: StrokeTransform }`
  - `EngravedPagePlacement { startY, usableHeight, offsetX, offsetY }` (all `CGFloat`)
  - `AnnotatedExportPlanner.planEngraved(drawings:resolver:pages:) -> [InkPlacement]`
  - `AnnotatedExportPlanner.planPaged(drawings:pageFrames:) -> [InkPlacement]`

This target is cross-compiled for Android, so it may import **Foundation and
Domain only**. `CGFloat` / `CGPoint` / `CGRect` are already shimmed at the top of
`AnnotationAnchoringCore.swift` and `PageAnchoringCore.swift` for that build; use
them and do not add an `import CoreGraphics`.

- [ ] **Step 1: Write the failing tests**

Create `Packages/Features/Reader/Tests/ReaderTests/AnnotatedExportPlannerTests.swift`:

```swift
import CoreGraphics
import Domain
@testable import ReaderAnnotationCore
import Testing

@Suite("AnnotatedExportPlanner")
struct AnnotatedExportPlannerTests {
    /// Resolver that reports a fixed reference point per measure index and a fixed `sp`, so the tests can place an
    /// anchor at a chosen document Y without building a real layout.
    private struct StubResolver: AnchorResolving {
        var pointsByMeasure: [Int: CGPoint]
        var sp: CGFloat = 10

        func resolveAnchor(at point: CGPoint) -> MusicalAnchor? { nil }

        func referencePoint(for anchor: MusicalAnchor) -> (point: CGPoint, sp: CGFloat)? {
            guard let point = pointsByMeasure[anchor.measureIndex] else { return nil }
            return (point, sp)
        }
    }

    private static func musical(measure: Int) -> DrawingAnchor {
        DrawingAnchor(
            kind: .musical(MusicalAnchor(
                measureIndex: measure, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
                dxSp: 0, verticalOffsetSp: 0,
            )),
            encodedDrawing: Data(),
        )
    }

    private static func page(_ index: Int) -> DrawingAnchor {
        DrawingAnchor(kind: .page(PageAnchor(pageIndex: index)), encodedDrawing: Data())
    }

    private static let twoPages = [
        EngravedPagePlacement(startY: 0, usableHeight: 700, offsetX: 50, offsetY: 60),
        EngravedPagePlacement(startY: 700, usableHeight: 700, offsetX: 50, offsetY: 60 - 700),
    ]

    @Test
    func `a stroke lands on the page whose band holds its anchor, offset into page space`() {
        let resolver = StubResolver(pointsByMeasure: [0: CGPoint(x: 100, y: 200)])
        let placements = AnnotatedExportPlanner.planEngraved(
            drawings: [Self.musical(measure: 0)], resolver: resolver, pages: Self.twoPages,
        )
        #expect(placements.count == 1)
        let placement = try! #require(placements.first)
        #expect(placement.pageIndex == 0)
        #expect(placement.drawingIndex == 0)
        #expect(placement.transform.sp == 10)
        #expect(placement.transform.px == 150) // 100 + offsetX
        #expect(placement.transform.py == 260) // 200 + offsetY
    }

    @Test
    func `a stroke past the first band lands on the second page`() {
        let resolver = StubResolver(pointsByMeasure: [3: CGPoint(x: 100, y: 900)])
        let placements = AnnotatedExportPlanner.planEngraved(
            drawings: [Self.musical(measure: 3)], resolver: resolver, pages: Self.twoPages,
        )
        let placement = try! #require(placements.first)
        #expect(placement.pageIndex == 1)
        #expect(placement.transform.px == 150)
        #expect(placement.transform.py == 260) // 900 + (60 - 700)
    }

    @Test
    func `an anchor the layout cannot resolve is dropped, not mis-placed`() {
        let resolver = StubResolver(pointsByMeasure: [:])
        #expect(AnnotatedExportPlanner.planEngraved(
            drawings: [Self.musical(measure: 7)], resolver: resolver, pages: Self.twoPages,
        ).isEmpty)
    }

    @Test
    func `an anchor beyond the last page's band is dropped`() {
        let resolver = StubResolver(pointsByMeasure: [0: CGPoint(x: 0, y: 5000)])
        #expect(AnnotatedExportPlanner.planEngraved(
            drawings: [Self.musical(measure: 0)], resolver: resolver, pages: Self.twoPages,
        ).isEmpty)
    }

    @Test
    func `drawingIndex points back into the input array when some drawings are dropped`() {
        let resolver = StubResolver(pointsByMeasure: [1: CGPoint(x: 10, y: 20)])
        let placements = AnnotatedExportPlanner.planEngraved(
            drawings: [Self.musical(measure: 0), Self.musical(measure: 1)],
            resolver: resolver, pages: Self.twoPages,
        )
        #expect(placements.map(\.drawingIndex) == [1])
    }

    @Test
    func `a page anchor is placed by page width so a differently sized page still fits it`() {
        let frames = [
            CGRect(x: 0, y: 0, width: 400, height: 600),
            CGRect(x: 0, y: 0, width: 800, height: 1200),
        ]
        let placements = AnnotatedExportPlanner.planPaged(
            drawings: [Self.page(0), Self.page(1)], pageFrames: frames,
        )
        #expect(placements.map(\.pageIndex) == [0, 1])
        #expect(placements[0].transform.sp == 400)
        #expect(placements[1].transform.sp == 800)
    }

    @Test
    func `a page anchor beyond the document's pages is dropped`() {
        let frames = [CGRect(x: 0, y: 0, width: 400, height: 600)]
        #expect(AnnotatedExportPlanner.planPaged(drawings: [Self.page(4)], pageFrames: frames).isEmpty)
    }

    @Test
    func `each planner ignores the other planner's anchor kind`() {
        let resolver = StubResolver(pointsByMeasure: [0: CGPoint(x: 0, y: 10)])
        #expect(AnnotatedExportPlanner.planEngraved(
            drawings: [Self.page(0)], resolver: resolver, pages: Self.twoPages,
        ).isEmpty)
        #expect(AnnotatedExportPlanner.planPaged(
            drawings: [Self.musical(measure: 0)],
            pageFrames: [CGRect(x: 0, y: 0, width: 400, height: 600)],
        ).isEmpty)
    }

    @Test
    func `empty inputs produce no placements`() {
        #expect(AnnotatedExportPlanner.planEngraved(
            drawings: [], resolver: StubResolver(pointsByMeasure: [:]), pages: Self.twoPages,
        ).isEmpty)
        #expect(AnnotatedExportPlanner.planPaged(drawings: [Self.page(0)], pageFrames: []).isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd Packages/Features/Reader
xcodebuild test -scheme Reader \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation \
  -only-testing:ReaderTests/AnnotatedExportPlannerTests
```

Expected: compile failure — `AnnotatedExportPlanner` does not exist.

- [ ] **Step 3: Write the planner**

Create `Packages/Features/Reader/Sources/ReaderAnnotationCore/AnnotatedExportPlanner.swift`:

```swift
import Domain
import Foundation

/// Where one stored drawing lands in an exported PDF. Carries a transform rather than transformed geometry: a
/// pixel-erased stroke keeps a PencilKit `mask` the neutral `InkStroke` cannot represent and is stored as a legacy
/// `PKDrawing` archive, so the renderer has to decode the drawing's own bytes and apply the transform to whatever
/// comes back. `StrokeTransform` is the same scale-plus-translate shape the Android JNI seam already consumes.
public struct InkPlacement: Equatable, Sendable {
    /// Index of the destination page in the exported document.
    public let pageIndex: Int
    /// Index into the `drawings` array that was planned.
    public let drawingIndex: Int
    /// Places the drawing's stored (normalized) geometry into that page's own space: points, origin top-left, y down.
    public let transform: StrokeTransform

    public init(pageIndex: Int, drawingIndex: Int, transform: StrokeTransform) {
        self.pageIndex = pageIndex
        self.drawingIndex = drawingIndex
        self.transform = transform
    }
}

/// One page of a paginated engraving, as the exporter will lay it out.
public struct EngravedPagePlacement: Equatable, Sendable {
    /// Document-space Y at which this page's content begins.
    public let startY: CGFloat
    /// The page's usable height — page height minus that page's top and bottom margins. The page owns document Y in
    /// `[startY, startY + usableHeight)`.
    public let usableHeight: CGFloat
    /// Document → page X translation (the page's leading margin).
    public let offsetX: CGFloat
    /// Document → page Y translation (the page's top margin minus `startY`).
    public let offsetY: CGFloat

    public init(startY: CGFloat, usableHeight: CGFloat, offsetX: CGFloat, offsetY: CGFloat) {
        self.startY = startY
        self.usableHeight = usableHeight
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

/// Platform-neutral placement for annotated PDF export: which stored drawing lands on which exported page, and the
/// transform that puts it there. Foundation + Domain only — no PencilKit, no CoreGraphics, no layout engine — so it
/// cross-compiles for Android and is the single source of truth both platforms call. iOS decodes each drawing to a
/// `PKDrawing` and applies the transform; Android feeds the same transform to androidx.ink.
///
/// Sibling of `AnnotationAnchoringCore` (which places ink into a *screen* layout) — the only difference is that the
/// destination is a page of a fixed-size document rather than a scrolling viewport.
public enum AnnotatedExportPlanner {
    /// Engraved base. Resolves each `.musical` anchor against `resolver` (the export layout, NOT the reader's), keeps
    /// it on the page whose band contains the resolved point, and folds that page's offsets into the translation.
    ///
    /// Anchors that fail to resolve — a measure the export layout does not have — are dropped rather than placed at a
    /// guessed position, matching what the Reader does with the same anchor. `.page` anchors are ignored: they belong
    /// to the original PDF, which is a different export.
    public static func planEngraved(
        drawings: [DrawingAnchor],
        resolver: AnchorResolving,
        pages: [EngravedPagePlacement],
    ) -> [InkPlacement] {
        var placements: [InkPlacement] = []
        for (index, drawing) in drawings.enumerated() {
            guard case let .musical(anchor) = drawing.kind,
                  let (point, sp) = AnnotationAnchoringCore.anchorPoint(for: anchor, using: resolver), sp > 0,
                  let pageIndex = pages.firstIndex(where: {
                      point.y >= $0.startY && point.y < $0.startY + $0.usableHeight
                  })
            else { continue }
            let page = pages[pageIndex]
            placements.append(InkPlacement(
                pageIndex: pageIndex,
                drawingIndex: index,
                transform: StrokeTransform(sp: sp, px: point.x + page.offsetX, py: point.y + page.offsetY),
            ))
        }
        return placements
    }

    /// Original-PDF base. `pageFrames` are the destination pages' boxes in points, in page order; pass each page's
    /// own frame with a zero origin, since the geometry produced here is page-local.
    ///
    /// Page anchors normalize to a fraction of page width, so the transform is exact at any page size and no
    /// reflow happens — the pages are the same fixed-layout pages the ink was drawn on.
    public static func planPaged(
        drawings: [DrawingAnchor],
        pageFrames: [CGRect],
    ) -> [InkPlacement] {
        let transforms = PageAnchoringCore.displayStrokeTransforms(drawings, pageFrames: pageFrames)
        var placements: [InkPlacement] = []
        for (index, drawing) in drawings.enumerated() {
            guard case let .page(anchor) = drawing.kind,
                  index < transforms.count, let transform = transforms[index]
            else { continue }
            placements.append(InkPlacement(
                pageIndex: anchor.pageIndex, drawingIndex: index, transform: transform,
            ))
        }
        return placements
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd Packages/Features/Reader
xcodebuild test -scheme Reader \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation \
  -only-testing:ReaderTests/AnnotatedExportPlannerTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/annotated-pdf-export add Packages/Features/Reader/Sources/ReaderAnnotationCore/AnnotatedExportPlanner.swift Packages/Features/Reader/Tests/ReaderTests/AnnotatedExportPlannerTests.swift
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/annotated-pdf-export commit -m "feat(reader-core): plan where annotation ink lands in an exported PDF

Sibling of AnnotationAnchoringCore, with a page of a fixed-size document as
the destination instead of a scrolling viewport. Lives in the neutral target
so the Android export calls the same placement rather than reimplementing it,
and returns a transform rather than geometry so a pixel-erased stroke — which
InkStroke cannot represent and which is stored as a PKDrawing archive —
survives the export."
```

---

## Task 4: Mirror the exporter's page layout

**Files:**
- Modify: `Packages/Features/Reader/Package.swift`
- Create: `Packages/Features/Reader/Sources/Reader/Annotation/Export/EngravedExportLayout.swift`
- Create: `Packages/Features/Reader/Tests/ReaderTests/EngravedExportLayoutTests.swift`

**Interfaces:**
- Consumes: `SheetMusicPDF.PDFExporter.{Options, resolve(options:score:), paginate(systems:page:policy:)}`,
  `SheetMusicLayout.{LayoutEngine, LayoutDocument, ScoreViewOptions}`,
  `ReaderAnnotationCore.EngravedPagePlacement`.
- Produces:
  - `EngravedExportLayout.Resolved { document: LayoutDocument, pages: [EngravedPagePlacement], pageSize: CGSize }`
  - `EngravedExportLayout.resolve(score:options:) -> Resolved`
  - `EngravedExportLayout.exportOptions(title:) -> PDFExporter.Options`

- [ ] **Step 1: Add SheetMusicPDF to the Reader target**

In `Packages/Features/Reader/Package.swift`, inside the `Reader` target's
`dependencies` array, add after the `SheetMusicMSCX` line:

```swift
            .product(name: "SheetMusicPDF", package: "swift-sheet-music"),
```

- [ ] **Step 2: Write the failing test**

Create `Packages/Features/Reader/Tests/ReaderTests/EngravedExportLayoutTests.swift`:

```swift
import CoreGraphics
import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import SheetMusicPDF
import Testing

/// The drift guard for `EngravedExportLayout`. It mirrors five lines of `PDFExporter.export`'s body — the option
/// resolution, the `ScoreViewOptions`, the available width, the layout call and the pagination — so that annotation
/// ink can be placed on the pages the exporter is about to produce. If a swift-sheet-music bump changes any of that,
/// these tests fail instead of the export silently stamping ink at the wrong coordinates.
@Suite("EngravedExportLayout")
struct EngravedExportLayoutTests {
    private let _install: Void = LayoutTestSupport.installed

    private static func score(measures: Int) -> Score {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let bars = (0 ..< measures).map { _ in Measure(voices: [Voice(elements: [.chord(chord)])]) }
        return Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: bars)])],
        )
    }

    private static func exported(_ score: Score, title: String) throws -> CGPDFDocument {
        let data = try PDFExporter.export(score: score, options: EngravedExportLayout.exportOptions(title: title))
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(CGPDFDocument(provider))
    }

    @Test
    @MainActor
    func `the mirrored pagination matches what the exporter actually produces`() throws {
        let score = Self.score(measures: 240)
        let resolved = EngravedExportLayout.resolve(score: score, options: EngravedExportLayout.exportOptions(title: "T"))
        let document = try Self.exported(score, title: "T")
        #expect(resolved.pages.count == document.numberOfPages)
        #expect(resolved.pages.count > 1)
    }

    @Test
    @MainActor
    func `the mirrored page size matches the exported media box`() throws {
        let score = Self.score(measures: 8)
        let resolved = EngravedExportLayout.resolve(score: score, options: EngravedExportLayout.exportOptions(title: "T"))
        let page = try #require(try Self.exported(score, title: "T").page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        #expect(abs(box.width - resolved.pageSize.width) < 0.5)
        #expect(abs(box.height - resolved.pageSize.height) < 0.5)
    }

    @Test
    @MainActor
    func `page bands are contiguous, ascending and non-empty`() throws {
        let resolved = EngravedExportLayout.resolve(
            score: Self.score(measures: 240), options: EngravedExportLayout.exportOptions(title: "T"),
        )
        for page in resolved.pages {
            #expect(page.usableHeight > 0)
        }
        for (earlier, later) in zip(resolved.pages, resolved.pages.dropFirst()) {
            #expect(later.startY >= earlier.startY)
        }
    }

    @Test
    @MainActor
    func `the layout document carries every measure so anchors can resolve`() throws {
        let resolved = EngravedExportLayout.resolve(
            score: Self.score(measures: 12), options: EngravedExportLayout.exportOptions(title: "T"),
        )
        #expect(!resolved.document.systems.isEmpty)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd Packages/Features/Reader
xcodebuild test -scheme Reader \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation \
  -only-testing:ReaderTests/EngravedExportLayoutTests
```

Expected: compile failure — `EngravedExportLayout` does not exist.

- [ ] **Step 4: Write the layout mirror**

Create `Packages/Features/Reader/Sources/Reader/Annotation/Export/EngravedExportLayout.swift`:

```swift
import CoreGraphics
import Foundation
import ReaderAnnotationCore
import SheetMusicCore
import SheetMusicLayout
import SheetMusicPDF

/// Reconstructs the layout that `PDFExporter.export` will use, so annotation ink can be placed on the pages the
/// exporter is about to produce.
///
/// swift-sheet-music exposes the pieces for exactly this: `PDFExporter.resolve` is documented "Public so on-screen
/// previewers can mirror the geometry that the exported PDF will have", and `PDFExporter.paginate` "so previewers can
/// mirror the export layout". What is NOT exposed is the three lines between them — the `ScoreViewOptions`, the
/// available width, and the `LayoutEngine.layout` call — so those are mirrored here.
///
/// Mirroring can drift when swift-sheet-music changes. Two things stop that from becoming misplaced ink:
/// `EngravedExportLayoutTests` compares this against a real export, and `ReaderAnnotatedPDFRenderer` re-checks the
/// page count and media box at run time and skips the ink rather than stamp it at coordinates it cannot trust.
enum EngravedExportLayout {
    struct Resolved {
        /// The engraving the export will draw — also the layout musical anchors must resolve against.
        let document: LayoutDocument
        /// One entry per exported page, in page order.
        let pages: [EngravedPagePlacement]
        /// Every page's size in points. Uniform across the document.
        let pageSize: CGSize
    }

    /// The export options this feature uses. `title` reaches the PDF's metadata, not the page chrome.
    static func exportOptions(title: String) -> PDFExporter.Options {
        PDFExporter.Options(title: title)
    }

    /// - Important: mirrors `PDFExporter.export(score:options:)`. Keep the two in step; the test above is what
    ///   notices when they fall out of it.
    static func resolve(score: Score, options: PDFExporter.Options) -> Resolved {
        let resolved = PDFExporter.resolve(options: options, score: score)
        let layoutOptions = ScoreViewOptions(
            staffSize: resolved.staffSize,
            systemGap: options.systemGap,
            wrapToViewWidth: true,
            breakPolicy: options.breakPolicy,
            showsInvisibleElements: false,
        )
        let availableWidth = max(
            resolved.staffSize * 4,
            resolved.page.size.width
                - resolved.page.oddMargins.leading
                - resolved.page.oddMargins.trailing,
        )
        let document = LayoutEngine.layout(
            score: score, options: layoutOptions, availableWidth: availableWidth,
        )
        let batches = PDFExporter.paginate(
            systems: document.systems, page: resolved.page, policy: options.breakPolicy,
        )
        let pages = batches.enumerated().map { index, batch in
            let margins = resolved.page.margins(forPageIndex: index)
            return EngravedPagePlacement(
                startY: batch.startY,
                usableHeight: max(1, resolved.page.size.height - margins.top - margins.bottom),
                offsetX: margins.leading,
                // The exact translation `PDFPageView` applies to its `Canvas`.
                offsetY: margins.top - batch.startY,
            )
        }
        return Resolved(document: document, pages: pages, pageSize: resolved.page.size)
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd Packages/Features/Reader
xcodebuild test -scheme Reader \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation \
  -only-testing:ReaderTests/EngravedExportLayoutTests
```

Expected: PASS.

If `the mirrored pagination matches…` fails, the mirror is wrong — compare it
line by line against `PDFExporter.export` in
`/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Sources/SheetMusicPDF/PDFExporter.swift`
and fix this file. **Do not weaken the test.**

- [ ] **Step 6: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/annotated-pdf-export add Packages/Features/Reader/Package.swift Packages/Features/Reader/Sources/Reader/Annotation/Export/EngravedExportLayout.swift Packages/Features/Reader/Tests/ReaderTests/EngravedExportLayoutTests.swift
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/annotated-pdf-export commit -m "feat(reader): mirror the PDF exporter's page layout

Placing ink on an exported page needs the pagination the exporter is about to
produce. swift-sheet-music makes resolve() and paginate() public for exactly
this mirroring; the three lines between them are reconstructed here, and a
test compares the result against a real export so a dependency bump fails the
build rather than moving the ink."
```

---

## Task 5: Compose the annotated PDF

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Annotation/Export/AnnotatedPDFComposer.swift`
- Create: `Packages/Features/Reader/Tests/ReaderTests/AnnotatedPDFComposerTests.swift`

**Interfaces:**
- Consumes: `ReaderAnnotationCore.InkPlacement`, `Domain.DrawingAnchor`,
  `InkStrokePencilKitBridge.decodeStoredDrawing(_:)`,
  `InkStrokePencilKitBridge.bakingTransformIntoPoints(_:)`.
- Produces:
  - `AnnotatedPDFComposer.inkScale: CGFloat` (= 4)
  - `AnnotatedPDFComposer.compose(basePDF:drawings:placements:) throws -> Data`

`InkStrokePencilKitBridge.decodeStoredDrawing` and `bakingTransformIntoPoints`
are `static` but have no access modifier (internal to the `Reader` module). The
composer is in the same module, so no access change is needed.

- [ ] **Step 1: Write the failing tests**

Create `Packages/Features/Reader/Tests/ReaderTests/AnnotatedPDFComposerTests.swift`:

```swift
import CoreGraphics
import Domain
import Foundation
import PencilKit
@testable import Reader
@testable import ReaderAnnotationCore
import Testing
import UIKit

@Suite("AnnotatedPDFComposer")
struct AnnotatedPDFComposerTests {
    /// A two-page PDF with real vector content: a filled rectangle and a line per page.
    private static func baseDocument(pages: Int, size: CGSize = CGSize(width: 400, height: 600)) -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var box = CGRect(origin: .zero, size: size)
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for _ in 0 ..< pages {
            context.beginPDFPage(nil)
            context.setFillColor(gray: 0.5, alpha: 1)
            context.fill(CGRect(x: 10, y: 10, width: 100, height: 40))
            context.setStrokeColor(gray: 0, alpha: 1)
            context.stroke(CGRect(x: 20, y: 200, width: 300, height: 100))
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// One stored drawing whose geometry is a short diagonal in normalized space.
    private static func drawing(kind: DrawingAnchorKind) -> DrawingAnchor {
        let stroke = InkStroke(
            tool: .pen, colorRGBA: 0xFF00_00FF, baseWidthSp: 0.2, opacity: 1,
            x: [0, 0.1, 0.2], y: [0, 0.1, 0.2], width: [0.2, 0.2, 0.2],
            force: [1, 1, 1], azimuth: [], altitude: [], timeMillis: [0, 1, 2],
        )
        return DrawingAnchor(kind: kind, encodedDrawing: InkStrokeCodec.encode(stroke))
    }

    private static func open(_ data: Data) throws -> CGPDFDocument {
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(CGPDFDocument(provider))
    }

    private static func xObjectCount(of document: CGPDFDocument, page index: Int) throws -> Int {
        let page = try #require(document.page(at: index))
        let dict = try #require(page.dictionary)
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { return 0 }
        var bucket: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &bucket), let bucket else { return 0 }
        return CGPDFDictionaryGetCount(bucket)
    }

    @Test
    @MainActor
    func `composing with no placements returns a document with the same pages`() throws {
        let base = Self.baseDocument(pages: 2)
        let out = try AnnotatedPDFComposer.compose(basePDF: base, drawings: [], placements: [])
        #expect(try Self.open(out).numberOfPages == 2)
    }

    @Test
    @MainActor
    func `the composed page keeps the base page's size`() throws {
        let base = Self.baseDocument(pages: 1, size: CGSize(width: 400, height: 600))
        let out = try AnnotatedPDFComposer.compose(basePDF: base, drawings: [], placements: [])
        let page = try #require(try Self.open(out).page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        #expect(abs(box.width - 400) < 0.5)
        #expect(abs(box.height - 600) < 0.5)
    }

    @Test
    @MainActor
    func `an annotated page gains an image and an unannotated one does not`() throws {
        let base = Self.baseDocument(pages: 2)
        let drawings = [Self.drawing(kind: .page(PageAnchor(pageIndex: 0)))]
        let placements = [InkPlacement(
            pageIndex: 0, drawingIndex: 0, transform: StrokeTransform(sp: 400, px: 0, py: 0),
        )]
        let out = try AnnotatedPDFComposer.compose(
            basePDF: base, drawings: drawings, placements: placements,
        )
        let document = try Self.open(out)
        #expect(try Self.xObjectCount(of: document, page: 1) > 0)
        #expect(try Self.xObjectCount(of: document, page: 2) == 0)
    }

    @Test
    @MainActor
    func `a placement pointing past the base document's pages is skipped`() throws {
        let base = Self.baseDocument(pages: 1)
        let drawings = [Self.drawing(kind: .page(PageAnchor(pageIndex: 9)))]
        let placements = [InkPlacement(
            pageIndex: 9, drawingIndex: 0, transform: StrokeTransform(sp: 400, px: 0, py: 0),
        )]
        let out = try AnnotatedPDFComposer.compose(
            basePDF: base, drawings: drawings, placements: placements,
        )
        #expect(try Self.open(out).numberOfPages == 1)
    }

    @Test
    @MainActor
    func `a placement with an out-of-range drawing index is skipped`() throws {
        let base = Self.baseDocument(pages: 1)
        let placements = [InkPlacement(
            pageIndex: 0, drawingIndex: 3, transform: StrokeTransform(sp: 400, px: 0, py: 0),
        )]
        let out = try AnnotatedPDFComposer.compose(basePDF: base, drawings: [], placements: placements)
        #expect(try Self.xObjectCount(of: try Self.open(out), page: 1) == 0)
    }

    @Test
    @MainActor
    func `unreadable base bytes throw rather than produce an empty PDF`() {
        #expect(throws: DomainError.self) {
            try AnnotatedPDFComposer.compose(basePDF: Data([0x25, 0x21]), drawings: [], placements: [])
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd Packages/Features/Reader
xcodebuild test -scheme Reader \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation \
  -only-testing:ReaderTests/AnnotatedPDFComposerTests
```

Expected: compile failure — `AnnotatedPDFComposer` does not exist.

- [ ] **Step 3: Write the composer**

Create `Packages/Features/Reader/Sources/Reader/Annotation/Export/AnnotatedPDFComposer.swift`:

```swift
import CoreGraphics
import Domain
import Foundation
import PDFKit
import PencilKit
import ReaderAnnotationCore
import UIKit

/// Stamps annotation ink onto a base PDF's pages and returns the new document's bytes.
///
/// Each page is rebuilt by replaying the base page's content stream with `CGContext.drawPDFPage` and drawing the
/// page's ink on top, which is what keeps the notation vector: `drawPDFPage` copies the page's own drawing commands
/// into the destination rather than rasterizing them, so glyphs stay glyphs and hairlines stay hairlines. Only the
/// ink is an image.
///
/// The ink itself goes through PencilKit — the same renderer `StaticInkLayer` uses for committed ink on screen — so
/// the exported marks look like the ones the user drew, including pressure taper and marker blending, with no second
/// ink renderer to keep in step. It is rasterized at `inkScale`, cropped to the ink's own bounds, so a page with one
/// circled bar costs a small image rather than a page-sized one.
@MainActor
enum AnnotatedPDFComposer {
    /// Rasterization factor for the ink image against the PDF's 72 dpi user space — 4× is ~288 dpi, enough for print.
    static let inkScale: CGFloat = 4

    /// - Parameters:
    ///   - basePDF: the document to stamp. Its pages, sizes and vector content are preserved.
    ///   - drawings: the stored anchors the placements index into.
    ///   - placements: from `AnnotatedExportPlanner`, in page-local coordinates (points, origin top-left, y down).
    /// - Returns: the composed document's bytes.
    /// - Throws: `DomainError.scoreWriteFailed` when `basePDF` cannot be read as a PDF, or when the destination
    ///   context cannot be created.
    static func compose(
        basePDF: Data,
        drawings: [DrawingAnchor],
        placements: [InkPlacement],
    ) throws -> Data {
        guard let provider = CGDataProvider(data: basePDF as CFData),
              let source = CGPDFDocument(provider), source.numberOfPages > 0
        else {
            throw DomainError.scoreWriteFailed(reason: "annotated export: base PDF is unreadable")
        }
        // PDFKit is used only to replay annotations the base file already carries (a highlight made in another app,
        // a form field's appearance); `drawPDFPage` replays the content stream alone. folino's own ink is not a PDF
        // annotation and never comes back through here.
        let pdfKitDocument = PDFDocument(data: basePDF)

        let inkByPage = Dictionary(grouping: placements, by: \.pageIndex)
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            throw DomainError.scoreWriteFailed(reason: "annotated export: could not create the PDF context")
        }

        for pageNumber in 1 ... source.numberOfPages {
            guard let page = source.page(at: pageNumber) else { continue }
            var box = page.getBoxRect(.mediaBox)
            context.beginPDFPage([
                kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size),
            ] as CFDictionary)

            context.saveGState()
            context.drawPDFPage(page)
            context.restoreGState()

            if let pdfKitDocument, let kitPage = pdfKitDocument.page(at: pageNumber - 1) {
                for annotation in kitPage.annotations where annotation.shouldDisplay {
                    context.saveGState()
                    annotation.draw(with: .mediaBox, in: context)
                    context.restoreGState()
                }
            }

            if let placements = inkByPage[pageNumber - 1] {
                drawInk(placements, drawings: drawings, pageSize: box.size, into: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return out as Data
    }

    /// Builds this page's `PKDrawing` in page-local UIKit coordinates, rasterizes the ink's bounding box and draws it
    /// into the PDF page. The context is in PDF orientation (bottom-left origin, y up), so the image lands under a
    /// flip; everything above it is untouched by the flip because it is scoped to a `saveGState`.
    private static func drawInk(
        _ placements: [InkPlacement],
        drawings: [DrawingAnchor],
        pageSize: CGSize,
        into context: CGContext,
    ) {
        var strokes: [PKStroke] = []
        for placement in placements {
            guard placement.drawingIndex >= 0, placement.drawingIndex < drawings.count,
                  var stored = InkStrokePencilKitBridge.decodeStoredDrawing(
                      drawings[placement.drawingIndex].encodedDrawing,
                  )
            else { continue }
            let transform = CGAffineTransform(scaleX: placement.transform.sp, y: placement.transform.sp)
                .concatenating(CGAffineTransform(
                    translationX: placement.transform.px, y: placement.transform.py,
                ))
            stored.transform(using: transform)
            strokes.append(contentsOf: InkStrokePencilKitBridge.bakingTransformIntoPoints(stored).strokes)
        }
        let drawing = PKDrawing(strokes: strokes)
        guard !drawing.strokes.isEmpty else { return }

        // Clip to the page and pad by a point so a stroke's rendered edge is not shaved off by the crop.
        let bounds = drawing.bounds.insetBy(dx: -1, dy: -1)
            .intersection(CGRect(origin: .zero, size: pageSize))
        guard bounds.width > 0, bounds.height > 0 else { return }

        // Stored ink colors are canonical light-appearance sRGB; render under the light trait so a dynamic color
        // inside a legacy PKDrawing archive cannot come out dark-adapted on a white page.
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: bounds, scale: inkScale)
        }
        guard let cgImage = image?.cgImage else { return }

        context.saveGState()
        context.translateBy(x: 0, y: pageSize.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: bounds)
        context.restoreGState()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd Packages/Features/Reader
xcodebuild test -scheme Reader \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation \
  -only-testing:ReaderTests/AnnotatedPDFComposerTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/annotated-pdf-export add Packages/Features/Reader/Sources/Reader/Annotation/Export/AnnotatedPDFComposer.swift Packages/Features/Reader/Tests/ReaderTests/AnnotatedPDFComposerTests.swift
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/annotated-pdf-export commit -m "feat(reader): stamp annotation ink onto a base PDF's pages

drawPDFPage replays each base page's content stream instead of rasterizing
it, so the notation stays vector and only the ink is an image. The ink goes
through PencilKit, the renderer StaticInkLayer already uses, so an exported
mark looks like the one on screen; it is cropped to its own bounds and drawn
under the flip into PDF orientation."
```

---

## Task 6: The renderer that ties it together

**Files:**
- Create: `Packages/Domain/Sources/Domain/Protocols/AnnotatedPDFRendering.swift`
- Create: `Packages/Features/Reader/Sources/Reader/Annotation/Export/ReaderAnnotatedPDFRenderer.swift`
- Modify: `Packages/Features/Reader/Tests/ReaderTests/AnnotatedPDFComposerTests.swift` (append a suite)

**Interfaces:**
- Consumes: `EngravedExportLayout`, `AnnotatedExportPlanner`, `AnnotatedPDFComposer`,
  `LayoutDocumentAnchorResolver`, `Domain.ScorePDFRenderer`.
- Produces:
  - `Domain.AnnotatedPDFRendering` with
    `renderAnnotatedEngravedPDF(score:title:drawings:) async throws -> Data` and
    `renderAnnotatedOriginalPDF(basePDF:drawings:) async throws -> Data`
  - `Reader.ReaderAnnotatedPDFRenderer(pdfRenderer:)` — public, the App
    composition root constructs it.

- [ ] **Step 1: Write the Domain protocol**

Create `Packages/Domain/Sources/Domain/Protocols/AnnotatedPDFRendering.swift`:

```swift
import Foundation
import SheetMusicCore

/// Renders a score, or a PDF-origin item's original file, to PDF bytes with the item's freehand annotations baked in.
///
/// Injected the way `ScorePDFRenderer` is, and for the same reason: baking ink needs the engraving layout and a
/// platform ink renderer, and neither may leak into Domain or Infrastructure. The implementation lives in the Reader
/// feature, which already owns anchor projection and the PencilKit bridge.
///
/// Failures throw `DomainError.scoreWriteFailed`.
public protocol AnnotatedPDFRendering: Sendable {
    /// The engraved notation with `drawings`' `.musical` anchors baked in. `.page` anchors are ignored — they belong
    /// to the original PDF. `title` reaches the PDF's metadata.
    func renderAnnotatedEngravedPDF(
        score: Score, title: String, drawings: [DrawingAnchor],
    ) async throws -> Data

    /// `basePDF`'s own pages with `drawings`' `.page` anchors baked in. `.musical` anchors are ignored. The base
    /// document's page count, sizes and vector content are preserved.
    func renderAnnotatedOriginalPDF(basePDF: Data, drawings: [DrawingAnchor]) async throws -> Data
}
```

- [ ] **Step 2: Write the failing tests**

Append to `Packages/Features/Reader/Tests/ReaderTests/AnnotatedPDFComposerTests.swift`:

```swift
@Suite("ReaderAnnotatedPDFRenderer")
struct ReaderAnnotatedPDFRendererTests {
    private let _install: Void = LayoutTestSupport.installed

    /// `ScorePDFRenderer` that returns a fixed document, so the renderer's mismatch guard can be exercised without
    /// engraving anything.
    private struct StubPDFRenderer: Domain.ScorePDFRenderer {
        let data: Data
        func renderPDF(score: Score, title: String) async throws -> Data { data }
    }

    private static func score(measures: Int) -> Score {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let bars = (0 ..< measures).map { _ in Measure(voices: [Voice(elements: [.chord(chord)])]) }
        return Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: bars)])],
        )
    }

    @Test
    func `the engraved export is a readable PDF even with no ink`() async throws {
        let renderer = ReaderAnnotatedPDFRenderer(pdfRenderer: CoreGraphicsPDFRendererStub())
        let data = try await renderer.renderAnnotatedEngravedPDF(
            score: Self.score(measures: 8), title: "T", drawings: [],
        )
        let provider = try #require(CGDataProvider(data: data as CFData))
        #expect(try #require(CGPDFDocument(provider)).numberOfPages >= 1)
    }

    @Test
    func `a base PDF that disagrees with the plan comes back unstamped rather than mis-stamped`() async throws {
        // A one-page stub for a score that paginates to several: the guard must notice and skip the ink.
        let stub = AnnotatedPDFComposerTests.baseDocumentForGuardTest()
        let renderer = ReaderAnnotatedPDFRenderer(pdfRenderer: StubPDFRenderer(data: stub))
        let drawings = [AnnotatedPDFComposerTests.drawingForGuardTest()]
        let data = try await renderer.renderAnnotatedEngravedPDF(
            score: Self.score(measures: 240), title: "T", drawings: drawings,
        )
        #expect(data == stub)
    }

    @Test
    func `the original-PDF export preserves the base document's pages`() async throws {
        let base = AnnotatedPDFComposerTests.baseDocumentForGuardTest()
        let renderer = ReaderAnnotatedPDFRenderer(pdfRenderer: StubPDFRenderer(data: base))
        let data = try await renderer.renderAnnotatedOriginalPDF(basePDF: base, drawings: [])
        let provider = try #require(CGDataProvider(data: data as CFData))
        #expect(try #require(CGPDFDocument(provider)).numberOfPages == 1)
    }
}
```

Add these two helpers to `AnnotatedPDFComposerTests` (make them `static` and
non-private so the second suite can call them), and a small real renderer stub:

```swift
extension AnnotatedPDFComposerTests {
    static func baseDocumentForGuardTest() -> Data { baseDocument(pages: 1) }
    static func drawingForGuardTest() -> DrawingAnchor {
        drawing(kind: .musical(MusicalAnchor(
            measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
            dxSp: 0, verticalOffsetSp: 0,
        )))
    }
}

/// The real CoreGraphics engraving path, wrapped so the Reader test target does not need to import Infrastructure.
struct CoreGraphicsPDFRendererStub: Domain.ScorePDFRenderer {
    func renderPDF(score: Score, title: String) async throws -> Data {
        try await MainActor.run {
            try PDFExporter.export(score: score, options: PDFExporter.Options(title: title))
        }
    }
}
```

Change `private static func baseDocument` and `private static func drawing` in
`AnnotatedPDFComposerTests` to `static` (drop `private`) so the extension can
reach them.

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd Packages/Features/Reader
xcodebuild test -scheme Reader \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation \
  -only-testing:ReaderTests/ReaderAnnotatedPDFRendererTests
```

Expected: compile failure — `ReaderAnnotatedPDFRenderer` does not exist.

- [ ] **Step 4: Write the renderer**

Create `Packages/Features/Reader/Sources/Reader/Annotation/Export/ReaderAnnotatedPDFRenderer.swift`:

```swift
import CoreGraphics
import Domain
import Foundation
import ReaderAnnotationCore
import SheetMusicCore
import SheetMusicPDF

/// `AnnotatedPDFRendering` for iOS. Composes the three halves of the feature: `EngravedExportLayout` reconstructs the
/// pages the exporter will produce, `AnnotatedExportPlanner` decides which stored drawing lands where, and
/// `AnnotatedPDFComposer` stamps them onto the base document.
///
/// Lives in the Reader feature because projecting a musical anchor needs the engraving layout and rasterizing ink
/// needs PencilKit, both of which already live here. Infrastructure reaches it through the Domain protocol only.
public struct ReaderAnnotatedPDFRenderer: AnnotatedPDFRendering {
    private let pdfRenderer: any ScorePDFRenderer

    /// - Parameter pdfRenderer: the plain engraving-to-PDF path — the same renderer the unannotated `.pdf` share
    ///   uses, so the annotated export's pages are the pages the plain export would have produced.
    public init(pdfRenderer: any ScorePDFRenderer) {
        self.pdfRenderer = pdfRenderer
    }

    public func renderAnnotatedEngravedPDF(
        score: Score, title: String, drawings: [DrawingAnchor],
    ) async throws -> Data {
        let basePDF = try await pdfRenderer.renderPDF(score: score, title: title)
        let placements = await MainActor.run { () -> [InkPlacement] in
            let layout = EngravedExportLayout.resolve(
                score: score, options: EngravedExportLayout.exportOptions(title: title),
            )
            guard agrees(basePDF: basePDF, layout: layout) else { return [] }
            return AnnotatedExportPlanner.planEngraved(
                drawings: drawings,
                resolver: LayoutDocumentAnchorResolver(document: layout.document),
                pages: layout.pages,
            )
        }
        guard !placements.isEmpty else { return basePDF }
        return try await MainActor.run {
            try AnnotatedPDFComposer.compose(
                basePDF: basePDF, drawings: drawings, placements: placements,
            )
        }
    }

    public func renderAnnotatedOriginalPDF(basePDF: Data, drawings: [DrawingAnchor]) async throws -> Data {
        guard let provider = CGDataProvider(data: basePDF as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages > 0
        else {
            throw DomainError.scoreWriteFailed(reason: "annotated export: original PDF is unreadable")
        }
        let frames = (1 ... document.numberOfPages).map { number -> CGRect in
            guard let page = document.page(at: number) else { return .zero }
            // Page-local: the planner's output is stamped in each page's own space, so the origin is dropped.
            return CGRect(origin: .zero, size: page.getBoxRect(.mediaBox).size)
        }
        let placements = AnnotatedExportPlanner.planPaged(drawings: drawings, pageFrames: frames)
        guard !placements.isEmpty else { return basePDF }
        return try await MainActor.run {
            try AnnotatedPDFComposer.compose(
                basePDF: basePDF, drawings: drawings, placements: placements,
            )
        }
    }

    /// The drift guard. `EngravedExportLayout` mirrors five lines of `PDFExporter.export`; if a swift-sheet-music
    /// change moved the pagination, the page count or the page size stops matching and the ink would land on the
    /// wrong page or the wrong spot. Returning `false` here ships the plain engraving instead — a share that is not
    /// annotated is a far better failure than one annotated in the wrong place.
    private func agrees(basePDF: Data, layout: EngravedExportLayout.Resolved) -> Bool {
        guard let provider = CGDataProvider(data: basePDF as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages == layout.pages.count,
              let first = document.page(at: 1)
        else { return false }
        let box = first.getBoxRect(.mediaBox)
        return abs(box.width - layout.pageSize.width) < 1 && abs(box.height - layout.pageSize.height) < 1
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd Packages/Features/Reader
xcodebuild test -scheme Reader \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation
```

Expected: PASS — the whole Reader suite, so nothing the new `SheetMusicPDF`
dependency or the moved helpers broke goes unnoticed.

- [ ] **Step 6: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/annotated-pdf-export add Packages/Domain/Sources/Domain/Protocols/AnnotatedPDFRendering.swift Packages/Features/Reader
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/annotated-pdf-export commit -m "feat(reader): render an annotated PDF for either base

Ties the layout mirror, the neutral planner and the composer together behind
a Domain protocol, so Infrastructure can ask for an annotated export without
importing a Feature. The engraved path re-checks the produced document's page
count and size against the plan and ships the plain engraving when they
disagree, because unannotated is a better failure than mis-annotated."
```

---

## Task 7: Offer and produce the formats from the share service

**Files:**
- Modify: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift`
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift`

**Interfaces:**
- Consumes: `AnnotatedExportAvailability.formats(…)`, `AnnotatedPDFRendering`,
  `AnnotationStore`, `AnnotationLayer`, `ScoreExportNaming.fileName(title:format:)`,
  `ScoreItem.{originalPDFFileName, pdfOriginState}`.
- Produces: `LiveScoreShareService.init(scoresDirectory:shareTempDirectory:gateway:audioExporter:pdfRenderer:annotatedPDFRenderer:annotationStore:)`

- [ ] **Step 1: Write the failing tests**

In `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift`,
add two fakes next to the existing ones:

```swift
    /// `AnnotationStore` returning a fixed layer, so availability can be driven without a database.
    private final class FakeAnnotationStore: Domain.AnnotationStore, @unchecked Sendable {
        var layer: AnnotationLayer?
        func annotationLayer(forScoreItem id: ScoreItemID) async throws -> AnnotationLayer? { layer }
        func saveAnnotationLayer(_ layer: AnnotationLayer) async throws {}
        func deleteAnnotationLayer(forScoreItem id: ScoreItemID) async throws {}
    }

    /// `AnnotatedPDFRendering` returning fixed bytes and recording which entry point ran.
    private final class FakeAnnotatedRenderer: Domain.AnnotatedPDFRendering, @unchecked Sendable {
        enum Call: Equatable { case engraved, original }
        private(set) var calls: [Call] = []
        var data = Data([0xAA])

        func renderAnnotatedEngravedPDF(
            score: Score, title: String, drawings: [DrawingAnchor],
        ) async throws -> Data {
            calls.append(.engraved)
            return data
        }

        func renderAnnotatedOriginalPDF(basePDF: Data, drawings: [DrawingAnchor]) async throws -> Data {
            calls.append(.original)
            return data
        }
    }

    private static func musicalDrawing() -> DrawingAnchor {
        DrawingAnchor(
            kind: .musical(MusicalAnchor(
                measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
                dxSp: 0, verticalOffsetSp: 0,
            )),
            encodedDrawing: Data(),
        )
    }

    private static func pageDrawing() -> DrawingAnchor {
        DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: Data())
    }

    private static func layer(for id: ScoreItemID, drawings: [DrawingAnchor]) -> AnnotationLayer {
        AnnotationLayer(
            scoreItemID: id, drawings: drawings, textBoxes: [], updatedAt: .init(timeIntervalSince1970: 0),
        )
    }
```

Extend the `Rig` initializer to take and hold the two fakes (defaulting to an
empty store and a fresh renderer) and pass them to `LiveScoreShareService`. Then
add a suite of tests:

```swift
    @Test
    func `an unannotated score offers only the five plain formats`() async throws {
        let rig = try Self.makeRig(scoreData: Self.minimalScoreData, localFileName: "s.mscz")
        let formats = await rig.svc.availableFormats(for: rig.item).map(\.format)
        #expect(formats == ScoreShareFormat.allOrdered)
    }

    @Test
    func `musical ink adds the engraved annotated row after the plain formats`() async throws {
        let rig = try Self.makeRig(scoreData: Self.minimalScoreData, localFileName: "s.mscz")
        rig.annotations.layer = Self.layer(for: rig.item.id, drawings: [Self.musicalDrawing()])
        let formats = await rig.svc.availableFormats(for: rig.item).map(\.format)
        #expect(formats == ScoreShareFormat.allOrdered + [.annotatedPDF])
    }

    @Test
    func `page ink without an original PDF on the item adds no row`() async throws {
        let rig = try Self.makeRig(scoreData: Self.minimalScoreData, localFileName: "s.mscz")
        rig.annotations.layer = Self.layer(for: rig.item.id, drawings: [Self.pageDrawing()])
        let formats = await rig.svc.availableFormats(for: rig.item).map(\.format)
        #expect(formats == ScoreShareFormat.allOrdered)
    }

    @Test
    func `no annotated row is ever flagged as the item's original bytes`() async throws {
        let rig = try Self.makeRig(scoreData: Self.minimalScoreData, localFileName: "s.mscz")
        rig.annotations.layer = Self.layer(for: rig.item.id, drawings: [Self.musicalDrawing()])
        let options = await rig.svc.availableFormats(for: rig.item)
        for option in options where option.format.isAnnotated {
            #expect(!option.isOriginal)
        }
    }

    @Test
    func `the engraved annotated share routes to the renderer and writes the suffixed name`() async throws {
        let rig = try Self.makeRig(scoreData: Self.minimalScoreData, localFileName: "s.mscz")
        rig.annotations.layer = Self.layer(for: rig.item.id, drawings: [Self.musicalDrawing()])
        let url = try await rig.svc.prepareShare(item: rig.item, format: .annotatedPDF)
        #expect(url.lastPathComponent == "T (annotated).pdf")
        #expect(rig.annotated.calls == [.engraved])
        #expect(try Data(contentsOf: url) == rig.annotated.data)
    }

    @Test
    func `an annotated share does not overwrite a plain PDF share of the same item`() async throws {
        let rig = try Self.makeRig(scoreData: Self.minimalScoreData, localFileName: "s.mscz")
        rig.annotations.layer = Self.layer(for: rig.item.id, drawings: [Self.musicalDrawing()])
        let plain = try await rig.svc.prepareShare(item: rig.item, format: .pdf)
        let annotated = try await rig.svc.prepareShare(item: rig.item, format: .annotatedPDF)
        #expect(plain != annotated)
        #expect(FileManager.default.fileExists(atPath: plain.path))
        #expect(FileManager.default.fileExists(atPath: annotated.path))
    }

    @Test
    func `an annotated share of an item with no layer throws rather than shipping a blank`() async throws {
        let rig = try Self.makeRig(scoreData: Self.minimalScoreData, localFileName: "s.mscz")
        await #expect(throws: DomainError.self) {
            try await rig.svc.prepareShare(item: rig.item, format: .annotatedPDF)
        }
    }
```

`Self.minimalScoreData` is whatever fixture the existing tests already feed
`makeRig` — reuse the existing constant or helper rather than inventing one, and
match the existing `makeRig` signature.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd Packages/Infrastructure
xcodebuild test -scheme Infrastructure-Package \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation \
  -only-testing:InfrastructureTests/LiveScoreShareServiceTests
```

Expected: compile failure — the initializer has no `annotatedPDFRenderer`.

- [ ] **Step 3: Wire the share service**

In `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift`, add
the two stored properties and initializer parameters:

```swift
    private let annotatedPDFRenderer: any AnnotatedPDFRendering
    private let annotationStore: any AnnotationStore

    public init(
        scoresDirectory: URL,
        shareTempDirectory: URL,
        gateway: any ScoreFileGateway,
        audioExporter: any ScoreAudioExporter,
        pdfRenderer: any ScorePDFRenderer,
        annotatedPDFRenderer: any AnnotatedPDFRendering,
        annotationStore: any AnnotationStore,
    ) {
        // …existing assignments…
        self.annotatedPDFRenderer = annotatedPDFRenderer
        self.annotationStore = annotationStore
    }
```

Replace `availableFormats(for:)`:

```swift
    public func availableFormats(for item: ScoreItem) async -> [ScoreShareFormatOption] {
        let original = await detectOriginalFormat(for: item)
        let plain = ScoreShareFormat.allOrdered.map {
            ScoreShareFormatOption(format: $0, isOriginal: $0 == original)
        }
        let drawings = await drawings(for: item)
        // An annotated export is never the source's own bytes, so these rows are never flagged `isOriginal`.
        let annotated = AnnotatedExportAvailability.formats(
            hasMusicalInk: drawings.contains { if case .musical = $0.kind { true } else { false } },
            hasPageInk: drawings.contains { if case .page = $0.kind { true } else { false } },
            hasOriginalPDF: item.originalPDFFileName != nil,
            isEngravable: item.pdfOriginState != .unconverted,
        ).map { ScoreShareFormatOption(format: $0) }
        return plain + annotated
    }

    /// The item's stored drawing anchors, or none. A store failure degrades to "no ink" — the plain formats still
    /// work, which is better than failing the whole menu over an annotation read.
    private func drawings(for item: ScoreItem) async -> [DrawingAnchor] {
        guard let layer = try? await annotationStore.annotationLayer(forScoreItem: item.id) else { return [] }
        return layer.drawings
    }
```

In `prepareShare(item:format:)`, handle the annotated formats **before** the
score is loaded, since the original-PDF path needs no parse:

```swift
    public func prepareShare(
        item: ScoreItem,
        format: ScoreShareFormat,
    ) async throws -> URL {
        if format == .annotatedOriginalPDF {
            return try await writeAnnotatedOriginalPDF(item: item)
        }

        let sourceURL = scoresDirectory.appending(path: item.localFileName)
        let (score, _) = try await gateway.loadScore(fileURL: sourceURL)

        if format == .annotatedPDF {
            return try await writeAnnotatedEngravedPDF(score: score, item: item)
        }
        if ScoreShareFormat.matching(for: score.source) == format {
            return try copyOriginalBytes(sourceURL: sourceURL, sanitizedTitle: ScoreExportNaming.sanitize(title: item.title))
        }
        // …existing switch, unchanged, with the two annotated cases unreachable…
        case .annotatedPDF, .annotatedOriginalPDF:
            throw DomainError.scoreWriteFailed(reason: "annotated formats are handled above")
        }
    }
```

Add the two writers:

```swift
    private func writeAnnotatedEngravedPDF(score: Score, item: ScoreItem) async throws -> URL {
        let drawings = try await requireDrawings(for: item)
        let data = try await annotatedPDFRenderer.renderAnnotatedEngravedPDF(
            score: score, title: item.title, drawings: drawings,
        )
        return try write(data, item: item, format: .annotatedPDF)
    }

    private func writeAnnotatedOriginalPDF(item: ScoreItem) async throws -> URL {
        guard let name = item.originalPDFFileName else {
            throw DomainError.scoreFileNotFound(name: item.localFileName)
        }
        let url = scoresDirectory.appending(path: name)
        guard let basePDF = try? Data(contentsOf: url) else {
            throw DomainError.scoreFileNotFound(name: name)
        }
        let drawings = try await requireDrawings(for: item)
        let data = try await annotatedPDFRenderer.renderAnnotatedOriginalPDF(
            basePDF: basePDF, drawings: drawings,
        )
        return try write(data, item: item, format: .annotatedOriginalPDF)
    }

    /// An annotated export with no ink is a bug, not a valid share — the row is only offered when the item has some,
    /// so reaching here means the layer went away between the menu opening and the tap.
    private func requireDrawings(for item: ScoreItem) async throws -> [DrawingAnchor] {
        let drawings = await drawings(for: item)
        guard !drawings.isEmpty else {
            throw DomainError.scoreWriteFailed(reason: "annotated export: the item has no annotations")
        }
        return drawings
    }

    private func write(_ data: Data, item: ScoreItem, format: ScoreShareFormat) throws -> URL {
        let destination = shareTempDirectory.appending(
            path: ScoreExportNaming.fileName(title: item.title, format: format),
        )
        try? FileManager.default.removeItem(at: destination)
        do {
            try data.write(to: destination)
        } catch {
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        }
        return destination
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd Packages/Infrastructure
xcodebuild test -scheme Infrastructure-Package \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation
```

Expected: PASS — the whole Infrastructure suite.

- [ ] **Step 5: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/annotated-pdf-export add Packages/Infrastructure
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/annotated-pdf-export commit -m "feat(scorefiles): offer and produce the annotated PDF share formats

The menu already loads its options per item when it opens, so asking the
annotation store what ink an item has costs one indexed read at that moment
rather than per row at list time. A store failure degrades to \"no ink\" so a
bad annotation read cannot take the plain formats down with it, and the
annotated writes go to suffixed filenames so they cannot overwrite the plain
PDF in the shared temp directory."
```

---

## Task 8: Wire the App composition root and build the whole app

Everything user-facing landed in Task 2; what is left is handing the renderer to
the share service and proving the assembled app builds and passes.

**Files:**
- Modify: `App/AppBootstrap.swift`

**Interfaces:**
- Consumes: `Reader.ReaderAnnotatedPDFRenderer(pdfRenderer:)` (Task 6),
  `LiveScoreShareService.init(…annotatedPDFRenderer:annotationStore:)` (Task 7).
- Produces: nothing new.

- [ ] **Step 1: Wire the App composition root**

In `App/AppBootstrap.swift`, at the `LiveScoreShareService` construction (~line
205), pass the two new dependencies. The `annotationStore` local already exists
at ~line 102, but the share service is built in a different function — check
whether `self.annotationStore` (the stored property at ~line 40) is set by then,
and if it is not, thread the local through rather than reordering the bootstrap.

```swift
        shareService = LiveScoreShareService(
            scoresDirectory: AppPaths.scoresDirectory,
            shareTempDirectory: AppPaths.shareTempDirectory,
            gateway: gateway,
            audioExporter: audioExporter,
            pdfRenderer: CoreGraphicsPDFRenderer(),
            annotatedPDFRenderer: ReaderAnnotatedPDFRenderer(pdfRenderer: CoreGraphicsPDFRenderer()),
            annotationStore: annotationStore,
        )
```

Add `import Reader` if the file does not already have it.

- [ ] **Step 2: Build the app and run the full test suite**

```bash
xcodegen generate
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation build
```

Expected: BUILD SUCCEEDED. Then:

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' \
  -skipPackagePluginValidation test
```

Expected: PASS.

If `xcodegen` or package resolution complains about `swift-sheet-music` being
required by two different requirements, delete the stale resolved files and
retry — they are all gitignored regenerables:

```bash
rm -f Folino.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
rm -f Packages/Features/Editor/Package.resolved
rm -f Packages/Features/Library/Package.resolved
```

- [ ] **Step 3: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/annotated-pdf-export add App/AppBootstrap.swift
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/annotated-pdf-export commit -m "feat(app): hand the annotated PDF renderer to the share service

The last wire: the composition root is the only place that may see both a
Feature and an Infrastructure adapter, so it is where the Reader's renderer
meets the share service that asks for it."
```

---

## Task 9: Manual QA on device

PencilKit ink does not appear in simulator screenshots and the export's
appearance is the point, so the last gate is a real device.

**Files:** none.

- [ ] **Step 1: Build and install**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'generic/platform=iOS' -skipPackagePluginValidation build
```

Install onto the user's device **over the existing app** — never uninstall, the
app holds real libraries and handwriting.

- [ ] **Step 2: Hand the checklist to the user**

Ask them to confirm, and report exactly what they answer:

1. Open a multi-page score, annotate a few bars with Apple Pencil, leave
   annotation mode, then Share **from the Reader's own top bar** — the share icon
   at normal width, or the ellipsis menu at narrow width. A **PDF (annotated)**
   row appears under the plain PDF row. (No new code was needed for this: both
   Reader entry points already call the same `ScoreShareService` the Library row
   menu does.)
2. Export it and open the file in Files. The ink is on the right bars; the
   notation is crisp at 400 % zoom (vector), the ink softens (raster, expected).
3. Print it. The ink is legible.
4. Open a score with no annotations. **No** annotated row appears.
5. Open a PDF-origin item that has been converted, annotate the engraved view,
   switch to the original PDF and annotate that too, then Share. Both rows
   appear; each export carries only its own ink.
6. Note whether the exported ink sits where expected given that it re-flows into
   the export's page layout rather than the reading layout.
7. **Share immediately after drawing.** Draw one stroke, leave annotation mode,
   and open the share menu as fast as you can. The annotated row must still be
   there. `AnnotationSaveCoordinator` debounces its writes by 500 ms while
   `availableFormats` reads the store the moment the menu opens, so a fast enough
   tap could in principle read a layer that has not been written yet. Almost
   certainly unreachable by hand — but if the row is missing, the fix is to flush
   the coordinator when annotation mode ends, not to wait longer.
8. Reach the same export from the Library row menu and confirm the file is
   identical — both paths go through one `ScoreShareService`, so a difference
   would mean the Reader is passing a different item.

- [ ] **Step 3: Update the memory index**

Add a line to
`~/.claude/projects/-Users-kiichi-Developer-Personal-ios-apps-Folino-iOS/MEMORY.md`
under **Live / in-flight** only if QA leaves something open. If everything
passes, add nothing — a completed, verified feature is git history, not memory.

---

## Self-review notes

- **Spec coverage.** Vector premise → Task 1. Availability rule, filenames, menu
  copy, every exhaustive switch the new cases force, and the parity marker →
  Task 2. Planner → Task 3. Page bands and the drift guard's test half → Task 4.
  Ink rasterization and composition → Task 5. The drift guard's runtime half and
  the two entry points → Task 6. Share-service rows and routing → Task 7. App
  wiring and the whole-app build → Task 8. Manual QA → Task 9.
- **Out-of-scope items stay out.** No text-box handling, no Android renderer, no
  print path, no Pro gating.
- **The one thing to watch while executing:** Task 7's `Rig` and
  `makeRig` already exist with a specific signature and fixture constant. Read
  the file before editing and extend what is there instead of replacing it.

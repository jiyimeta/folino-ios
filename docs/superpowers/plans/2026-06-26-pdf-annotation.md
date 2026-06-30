# PDF Annotation (PencilKit) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add PencilKit annotation to PDF documents in the reader's **Vertical** mode (parity with the score Vertical M1), anchoring strokes to page-relative coordinates and reusing the existing annotation persistence / canvas infrastructure.

**Architecture:** Generalize the Domain `DrawingAnchor` from a `MusicalAnchor` to a `DrawingAnchorKind` enum (`.musical` | `.page(PageAnchor)`) with backward-compatible decoding (no DB migration — anchors are JSON-blob serialized). Add `PDFAnnotationAnchoring` mirroring `AnnotationAnchoring` but normalizing strokes to per-page fraction coordinates instead of staff-spaces. Wire an `AnnotationOverlaySpec` into `VerticalPDFContainer` (it already rides `ScoreScrollHost`, currently passing `annotationOverlay: nil`) and surface the existing annotate toggle for PDFs.

**Tech Stack:** Swift 6.3, SwiftUI, PencilKit, PDFKit, GRDB (no schema change), Swift Testing, `xcodebuild` on iPhone 17 Pro Max simulator.

## Global Constraints

- Swift 6.3, iOS 26+, universal. `public` only across module boundaries; default `internal`.
- New tests use Swift Testing (`import Testing`, `@Test`, `#expect`).
- Package tests run via `xcodebuild test` from the package dir; the package test scheme is `<Pkg>-Package` (e.g. `Domain` builds with scheme `Domain`; for tests use `Domain` if that scheme is test-configured, else `Domain-Package`). `swift test` does NOT work in this repo. Destination: `platform=iOS Simulator,name=iPhone 17 Pro Max`.
- Feature-package verification: build the package with its own scheme and confirm `Compiling <File>.swift` in the log (an app build alone can skip an edited package and falsely report success).
- No bash compounds (`&&`); use `env -C <dir> <cmd>` / `git -C <repo>`.
- Stage WHOLE files only. The pre-commit hook (SwiftFormat / SwiftLint --fix) may rewrite files and fail — re-stage and re-commit; re-run the build/test after a rewrite.
- Comments reflow at 120 columns.
- iOS/Android parity: the Domain model change (`DrawingAnchorKind` / `PageAnchor`) is shared logic — keep it platform-neutral.
- **Scope:** Vertical PDF mode only. Paged/Horizontal PDF annotation is deferred to ride along with the score Paged/Horizontal annotation (M2). `TextBoxAnchor` stays `MusicalAnchor` (text boxes are never created today and are out of scope).

## Working context

This plan is executed in the worktree `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/pdf-annotation` on branch `worktree-pdf-annotation`, branched from local `main` HEAD which already contains the Plan 1 PDF reader (`ScoreFormat.pdf`, `LoadState.loadedPDF`, `PDFPageProvider`, `VerticalPDFContainer`, `ReaderCapabilities`). Commit on this branch only; do NOT push.

---

## File Structure

**Modified:**
- `Packages/Domain/Sources/Domain/Models/AnnotationLayer.swift` — `DrawingAnchor.anchor` → `kind: DrawingAnchorKind`, custom back-compat Codable.
- `Packages/Features/Reader/Sources/Reader/Annotation/AnnotationAnchoring.swift` — build/read `.musical` via the new enum.
- `Packages/Features/Reader/Sources/Reader/Screens/PDF/VerticalPDFContainer.swift` — wire the annotation overlay.
- `Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift` — surface the annotate toggle for PDFs.

**Created:**
- `Packages/Domain/Sources/Domain/Models/DrawingAnchorKind.swift` — the enum + `PageAnchor`.
- `Packages/Features/Reader/Sources/Reader/Annotation/PDFAnnotationAnchoring.swift` — page-relative capture/display + page-frame geometry.
- Test files per task.

---

## Task 1: Domain — `DrawingAnchorKind` + `PageAnchor` + back-compat `DrawingAnchor`

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/DrawingAnchorKind.swift`
- Modify: `Packages/Domain/Sources/Domain/Models/AnnotationLayer.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Annotation/AnnotationAnchoring.swift`
- Test: `Packages/Domain/Tests/DomainTests/DrawingAnchorKindTests.swift`

**Interfaces:**
- Produces:
  - `enum DrawingAnchorKind: Hashable, Sendable, Codable { case musical(MusicalAnchor); case page(PageAnchor) }`
  - `struct PageAnchor: Hashable, Sendable, Codable { let pageIndex: Int; init(pageIndex: Int) }` (clamps `pageIndex` to `>= 0`).
  - `DrawingAnchor` gains `var kind: DrawingAnchorKind` (replaces `var anchor: MusicalAnchor`); `init(id:kind:encodedDrawing:)`. Decoding old JSON (a top-level `"anchor"` MusicalAnchor, no `"kind"`) yields `.musical`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import Domain

@Suite struct DrawingAnchorKindTests {
    private func musicalAnchor() -> MusicalAnchor {
        MusicalAnchor(measureIndex: 2, tickInMeasure: 480, partIndex: 0, staffIndexInPart: 1, dxSp: 1.5, verticalOffsetSp: -3)
    }

    @Test func roundTripsMusicalKind() throws {
        let a = DrawingAnchor(kind: .musical(musicalAnchor()), encodedDrawing: Data([1, 2, 3]))
        let data = try JSONEncoder().encode(a)
        let back = try JSONDecoder().decode(DrawingAnchor.self, from: data)
        #expect(back == a)
        #expect(back.kind == .musical(musicalAnchor()))
    }

    @Test func roundTripsPageKind() throws {
        let a = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 3)), encodedDrawing: Data([9]))
        let data = try JSONEncoder().encode(a)
        let back = try JSONDecoder().decode(DrawingAnchor.self, from: data)
        #expect(back == a)
        #expect(back.kind == .page(PageAnchor(pageIndex: 3)))
    }

    @Test func decodesLegacyAnchorAsMusical() throws {
        // Legacy on-disk shape: a top-level "anchor" MusicalAnchor and no "kind".
        let legacy = """
        {"id":{"rawValue":"\(UUID().uuidString)"},
         "anchor":{"measureIndex":2,"tickInMeasure":480,"partIndex":0,"staffIndexInPart":1,"dxSp":1.5,"verticalOffsetSp":-3},
         "encodedDrawing":"AQID"}
        """.data(using: .utf8)!
        let back = try JSONDecoder().decode(DrawingAnchor.self, from: legacy)
        #expect(back.kind == .musical(musicalAnchor()))
        #expect(back.encodedDrawing == Data([1, 2, 3]))
    }

    @Test func pageAnchorClampsNegative() {
        #expect(PageAnchor(pageIndex: -5).pageIndex == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `Packages/Domain`): `env -C Packages/Domain xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:DomainTests/DrawingAnchorKindTests`
Expected: FAIL — `DrawingAnchorKind` / `PageAnchor` don't exist and `DrawingAnchor.kind` doesn't exist.

- [ ] **Step 3: Create `DrawingAnchorKind.swift`**

```swift
import Foundation

/// Where a freehand drawing is pinned. Scores anchor to a musical position (survives reflow / staff-size changes);
/// PDFs anchor to a fixed page. One `DrawingAnchor` carries exactly one kind. The Reader projects each kind to screen
/// coordinates with its own anchoring (`AnnotationAnchoring` for `.musical`, `PDFAnnotationAnchoring` for `.page`).
public enum DrawingAnchorKind: Hashable, Sendable, Codable {
    case musical(MusicalAnchor)
    case page(PageAnchor)
}

/// A fixed-layout page position. PDFs never reflow, so the page index plus the stroke geometry (stored normalized to
/// the page's own coordinate frame, 0…1 of the page width) fully locate a stroke. No fractional centroid is stored —
/// the normalized stroke bytes carry the within-page position, mirroring how `MusicalAnchor` + normalized bytes work
/// for scores.
public struct PageAnchor: Hashable, Sendable, Codable {
    public let pageIndex: Int

    public init(pageIndex: Int) {
        self.pageIndex = max(0, pageIndex)
    }
}
```

- [ ] **Step 4: Migrate `DrawingAnchor` in `AnnotationLayer.swift`**

Replace the `DrawingAnchor` struct (keep `TextBoxAnchor` and `AnnotationLayer` unchanged) with a `kind`-based one that decodes the legacy `anchor` key:

```swift
/// A free-hand stroke (or stroke group) anchored to a position inside a document. `encodedDrawing` is opaque to
/// Domain — the Reader decodes it as a `PKDrawing`. `kind` selects musical (score) vs page (PDF) anchoring.
public struct DrawingAnchor: Hashable, Codable, Sendable, Identifiable {
    public let id: AnnotationID
    public var kind: DrawingAnchorKind
    public var encodedDrawing: Data

    public init(id: AnnotationID = AnnotationID(), kind: DrawingAnchorKind, encodedDrawing: Data) {
        self.id = id
        self.kind = kind
        self.encodedDrawing = encodedDrawing
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case encodedDrawing
        case anchor // legacy: a top-level MusicalAnchor written before page anchoring existed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(AnnotationID.self, forKey: .id)
        encodedDrawing = try c.decode(Data.self, forKey: .encodedDrawing)
        if let kind = try c.decodeIfPresent(DrawingAnchorKind.self, forKey: .kind) {
            self.kind = kind
        } else {
            // Pre-PDF data stored the MusicalAnchor directly under "anchor"; map it to .musical.
            let legacy = try c.decode(MusicalAnchor.self, forKey: .anchor)
            kind = .musical(legacy)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(encodedDrawing, forKey: .encodedDrawing)
    }
}
```

- [ ] **Step 5: Update score `AnnotationAnchoring` call sites**

In `AnnotationAnchoring.swift`, `capture` builds the anchor — change the constructed `DrawingAnchor`:

```swift
return DrawingAnchor(kind: .musical(anchor), encodedDrawing: normalized.dataRepresentation())
```

and `display` reads it — change the loop head to extract the musical anchor and skip non-musical kinds:

```swift
static func display(_ drawings: [DrawingAnchor], in document: LayoutDocument) -> PKDrawing {
    var strokes: [PKStroke] = []
    for drawing in drawings {
        guard case let .musical(anchor) = drawing.kind else { continue }
        guard let denormalize = displayTransform(for: anchor, in: document) else { continue }
        guard var stored = try? PKDrawing(data: drawing.encodedDrawing) else { continue }
        stored.transform(using: denormalize)
        strokes.append(contentsOf: stored.strokes)
    }
    return PKDrawing(strokes: strokes)
}
```

Then grep the whole repo for any other use of `DrawingAnchor(anchor:` or `.anchor` on a `DrawingAnchor` and update them (use `rg -n "DrawingAnchor\(anchor:|\.anchor" Packages -g '*.swift'`). Update any test fixtures that build `DrawingAnchor(anchor:)` to `DrawingAnchor(kind: .musical(...))`.

- [ ] **Step 6: Run the Domain test to verify it passes**

Run: `env -C Packages/Domain xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:DomainTests/DrawingAnchorKindTests`
Expected: PASS (4 tests). Then run the full Domain suite to catch fixture breakage: `env -C Packages/Domain xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'` → TEST SUCCEEDED.

- [ ] **Step 7: Verify the Reader package still compiles**

Run: `env -C Packages/Features/Reader xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'`
Expected: BUILD SUCCEEDED (the `AnnotationAnchoring` edits compile against the new `kind`).

- [ ] **Step 8: Commit**

```bash
git -C <repo> add Packages/Domain/Sources/Domain/Models/DrawingAnchorKind.swift Packages/Domain/Sources/Domain/Models/AnnotationLayer.swift Packages/Features/Reader/Sources/Reader/Annotation/AnnotationAnchoring.swift Packages/Domain/Tests/DomainTests/DrawingAnchorKindTests.swift
git -C <repo> commit -m "feat(domain): DrawingAnchorKind (musical/page) with back-compat decoding"
```

(Include any other files the grep in Step 5 required.)

---

## Task 2: `PDFAnnotationAnchoring` — page-relative capture/display

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Annotation/PDFAnnotationAnchoring.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/PDFAnnotationAnchoringTests.swift`

**Interfaces:**
- Consumes: `DrawingAnchor`, `DrawingAnchorKind`, `PageAnchor` (Task 1); `AnnotationAnchorPolicy.representativePoint` (existing).
- Produces:
  - `PDFAnnotationAnchoring.pageIndex(forCentroid: CGPoint, pageFrames: [CGRect]) -> Int?` — the page whose frame contains the centroid, else the page with the nearest vertical center (nil only when `pageFrames` is empty).
  - `PDFAnnotationAnchoring.normalizeTransform(pageFrame: CGRect) -> CGAffineTransform?` — content→page-fraction (translate by `-origin`, scale by `1/width`); nil if `width <= 0`.
  - `PDFAnnotationAnchoring.displayTransform(pageFrame: CGRect) -> CGAffineTransform?` — page-fraction→content (scale by `width`, translate by `+origin`); nil if `width <= 0`.
  - `PDFAnnotationAnchoring.capture(strokes: [PKStroke], pageFrames: [CGRect]) -> [DrawingAnchor]` — one `.page` anchor per stroke, geometry baked to page-fraction.
  - `PDFAnnotationAnchoring.display(_ drawings: [DrawingAnchor], pageFrames: [CGRect]) -> PKDrawing` — re-bakes each `.page` stroke into the current page frame; skips `.musical` and out-of-range indices.

- [ ] **Step 1: Write the failing test** (pure geometry — no PKStroke needed)

```swift
import CoreGraphics
import Testing
@testable import Reader

@Suite struct PDFAnnotationAnchoringTests {
    // Two stacked pages, 100 wide, heights 140 and 120, 8pt gap.
    private let frames = [
        CGRect(x: 0, y: 0, width: 100, height: 140),
        CGRect(x: 0, y: 148, width: 100, height: 120),
    ]

    @Test func picksPageContainingCentroid() {
        #expect(PDFAnnotationAnchoring.pageIndex(forCentroid: CGPoint(x: 50, y: 70), pageFrames: frames) == 0)
        #expect(PDFAnnotationAnchoring.pageIndex(forCentroid: CGPoint(x: 50, y: 200), pageFrames: frames) == 1)
    }

    @Test func picksNearestPageWhenInGap() {
        // y = 144 is in the 8pt gap (140…148); closer to page 0's center (70) vs page 1's (208) -> page 0.
        #expect(PDFAnnotationAnchoring.pageIndex(forCentroid: CGPoint(x: 50, y: 144), pageFrames: frames) == 0)
    }

    @Test func nilForEmptyFrames() {
        #expect(PDFAnnotationAnchoring.pageIndex(forCentroid: .zero, pageFrames: []) == nil)
    }

    @Test func normalizeThenDisplayIsIdentityAtSameFrame() {
        let frame = frames[1]
        let n = PDFAnnotationAnchoring.normalizeTransform(pageFrame: frame)!
        let d = PDFAnnotationAnchoring.displayTransform(pageFrame: frame)!
        let p = CGPoint(x: 30, y: 180)
        let round = p.applying(n).applying(d)
        #expect(abs(round.x - p.x) < 0.0001)
        #expect(abs(round.y - p.y) < 0.0001)
    }

    @Test func normalizedCenterMapsToCenterAcrossZoom() {
        // Capture a page-1 center at one zoom, display at a wider frame: center -> center.
        let capture = CGRect(x: 0, y: 148, width: 100, height: 120)
        let display = CGRect(x: 0, y: 300, width: 200, height: 240) // 2x wider, repositioned
        let n = PDFAnnotationAnchoring.normalizeTransform(pageFrame: capture)!
        let d = PDFAnnotationAnchoring.displayTransform(pageFrame: display)!
        let captureCenter = CGPoint(x: capture.midX, y: capture.midY)
        let displayed = captureCenter.applying(n).applying(d)
        #expect(abs(displayed.x - display.midX) < 0.0001)
        #expect(abs(displayed.y - display.midY) < 0.0001)
    }

    @Test func nilTransformForZeroWidth() {
        #expect(PDFAnnotationAnchoring.normalizeTransform(pageFrame: CGRect(x: 0, y: 0, width: 0, height: 10)) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `env -C Packages/Features/Reader xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/PDFAnnotationAnchoringTests`
Expected: FAIL — `PDFAnnotationAnchoring` does not exist.

- [ ] **Step 3: Implement**

```swift
import CoreGraphics
import Domain
import PencilKit

/// Maps freehand `PKStroke`s to/from `.page` anchors for fixed-layout PDFs. Capture: each stroke → one `DrawingAnchor`
/// whose `PageAnchor` is the page its centroid lands on and whose `encodedDrawing` is the stroke normalized to that
/// page's own frame (origin = page top-left, unit = page width). Display: re-bake each stored stroke into the page's
/// CURRENT content-space frame. Because the normalization is a fraction of page width, the same stroke renders at the
/// correct spot and size at any committed zoom — the committed-zoom factor cancels. Mirrors `AnnotationAnchoring`, with
/// page-frame geometry in place of staff-space anchoring.
enum PDFAnnotationAnchoring {
    /// The page a stroke belongs to: the frame that contains the centroid, else the page whose vertical center is
    /// nearest (covers the inter-page gap). `nil` only when there are no pages.
    static func pageIndex(forCentroid centroid: CGPoint, pageFrames: [CGRect]) -> Int? {
        guard !pageFrames.isEmpty else { return nil }
        if let hit = pageFrames.firstIndex(where: { $0.contains(centroid) }) { return hit }
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, frame) in pageFrames.enumerated() {
            let d = abs(frame.midY - centroid.y)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    /// content→page-fraction: translate by `-origin`, then scale by `1/width`.
    static func normalizeTransform(pageFrame: CGRect) -> CGAffineTransform? {
        guard pageFrame.width > 0 else { return nil }
        return CGAffineTransform(translationX: -pageFrame.minX, y: -pageFrame.minY)
            .concatenating(CGAffineTransform(scaleX: 1 / pageFrame.width, y: 1 / pageFrame.width))
    }

    /// page-fraction→content: scale by `width`, then translate by `+origin`.
    static func displayTransform(pageFrame: CGRect) -> CGAffineTransform? {
        guard pageFrame.width > 0 else { return nil }
        return CGAffineTransform(scaleX: pageFrame.width, y: pageFrame.width)
            .concatenating(CGAffineTransform(translationX: pageFrame.minX, y: pageFrame.minY))
    }

    static func capture(strokes: [PKStroke], pageFrames: [CGRect]) -> [DrawingAnchor] {
        strokes.compactMap { stroke in
            let centroid = AnnotationAnchorPolicy.representativePoint(of: stroke)
            guard let index = pageIndex(forCentroid: centroid, pageFrames: pageFrames) else { return nil }
            guard let normalize = normalizeTransform(pageFrame: pageFrames[index]) else { return nil }
            // Bake the normalize into the points (same rationale as AnnotationAnchoring: PencilKit ignores a lingering
            // per-stroke transform when computing renderable extent, which clamps under zoom).
            var normalized = PKDrawing(strokes: [stroke])
            normalized.transform(using: normalize)
            return DrawingAnchor(kind: .page(PageAnchor(pageIndex: index)), encodedDrawing: normalized.dataRepresentation())
        }
    }

    static func display(_ drawings: [DrawingAnchor], pageFrames: [CGRect]) -> PKDrawing {
        var strokes: [PKStroke] = []
        for drawing in drawings {
            guard case let .page(anchor) = drawing.kind, anchor.pageIndex < pageFrames.count else { continue }
            guard let denormalize = displayTransform(pageFrame: pageFrames[anchor.pageIndex]) else { continue }
            guard var stored = try? PKDrawing(data: drawing.encodedDrawing) else { continue }
            stored.transform(using: denormalize)
            strokes.append(contentsOf: stored.strokes)
        }
        return PKDrawing(strokes: strokes)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `env -C Packages/Features/Reader xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/PDFAnnotationAnchoringTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git -C <repo> add Packages/Features/Reader/Sources/Reader/Annotation/PDFAnnotationAnchoring.swift Packages/Features/Reader/Tests/ReaderTests/PDFAnnotationAnchoringTests.swift
git -C <repo> commit -m "feat(reader): add PDFAnnotationAnchoring (page-relative)"
```

---

## Task 3: Wire annotation into `VerticalPDFContainer` + surface the PDF annotate toggle

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/PDF/VerticalPDFContainer.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift`

**Interfaces:**
- Consumes: `PDFAnnotationAnchoring` (Task 2); `AnnotationOverlaySpec` / `AnnotationCanvasState` (existing, in `AnnotationCanvasView.swift`); `viewModel.isAnnotating`, `viewModel.annotationDrawings`, `viewModel.annotationDrawingsDidChange(_:)`, `viewModel.loadAnnotations()` (existing, loaded in `load()`); `PDFPageProvider.pageSize(_:)` / `pageCount`.
- Produces: drawing on a PDF in Vertical mode is captured, persisted, and re-displayed after reopen; the annotate toggle appears for PDFs.

This is view-integration code, verified by build + Task 4 manual smoke. Note the canvas model: `VerticalPDFContainer` lays pages out at `committedZoom`-scaled width and applies only the live `magnification` via `scaleEffect`. So the canvas's content space IS the committed-zoom-scaled stack: set `documentSize` to that stack size and `zoomScale` to the live `magnification` only (committed zoom is already baked into the geometry).

- [ ] **Step 1: Add annotation state + page-frame geometry to `VerticalPDFContainer`**

Add a projected-drawing state and a helper that computes each page's content-space frame at the current `committedZoom` (mirroring `expectedSize`'s accumulation, 8pt gaps, full content width):

```swift
@State private var projectedAnnotations = PKDrawing()
```

```swift
/// Each page's frame in content space (committed-zoom-scaled stack coordinates) — the same frame `pageStack` lays the
/// pages into. Capture and display both normalize against these, so ink tracks pages across zoom commits. Mirrors
/// `expectedSize`'s height accumulation exactly (full width, 8pt gaps).
private func pageFrames(provider: PDFPageProvider, baseWidth: CGFloat) -> [CGRect] {
    let width = baseWidth * committedZoom
    var frames: [CGRect] = []
    var y: CGFloat = 0
    for i in 0 ..< provider.pageCount {
        let size = provider.pageSize(i)
        let height = size.width == 0 ? width : width * (size.height / size.width)
        frames.append(CGRect(x: 0, y: y, width: width, height: height))
        y += height + 8
    }
    return frames
}
```

Add `import PencilKit` at the top of the file.

- [ ] **Step 2: Build the annotation spec and pass it to `ScoreScrollHost`**

Replace `annotationOverlay: nil,` in the `ScoreScrollHost(...)` call with `annotationOverlay: annotationSpec(provider: provider, baseWidth: baseWidth, viewport: geo.size),` and add the spec + canvas-state builders:

```swift
private func annotationSpec(provider: PDFPageProvider, baseWidth: CGFloat, viewport: CGSize) -> AnnotationOverlaySpec {
    let frames = pageFrames(provider: provider, baseWidth: baseWidth)
    return AnnotationOverlaySpec(
        isAnnotating: viewModel.isAnnotating,
        isPencilPreferred: UIDevice.current.userInterfaceIdiom == .pad,
        displayDrawing: projectedAnnotations,
        onChange: { drawing in
            // The canvas is the source of truth while drawing: keep the displayed projection equal to the live ink so
            // the next render's applyDrawing is a no-op (mirrors VerticalScoreContainer). The model is still captured.
            projectedAnnotations = drawing
            viewModel.annotationDrawingsDidChange(
                PDFAnnotationAnchoring.capture(strokes: drawing.strokes, pageFrames: frames),
            )
        },
        state: {
            let m = pinch.magnification
            let size = expectedSize(provider: provider, baseWidth: baseWidth) // committed-zoom-scaled stack
            let slack: CGFloat = 100_000
            return AnnotationCanvasState(
                documentSize: size,
                zoomScale: m,
                contentOffsetBias: CGPoint(
                    x: -pinch.anchor.x * size.width * (1 - m),
                    y: -pinch.anchor.y * size.height * (1 - m),
                ),
                contentInset: UIEdgeInsets(top: slack, left: slack, bottom: slack, right: slack),
            )
        },
    )
}
```

(Rationale for the bias: the host applies `scaleEffect(m, anchor: pinch.anchor)` to the committed-scaled content; a content point `p` lands at `m·p + anchor·size·(1−m) − scrollOffset`. The canvas must match with `zoomScale = m` and `contentOffset = scrollOffset + bias`, giving `bias = −anchor·size·(1−m)`. At rest `m == 1` → `bias == 0`, `zoomScale == 1`. No padding/inset terms because PDF pages fill the content width and the container adds no top padding.)

- [ ] **Step 3: Reproject on load / zoom-commit**

Re-derive `projectedAnnotations` from the model whenever the model loads or the page geometry changes (committed zoom). Add to the `GeometryReader`'s content (e.g. attach to the `ScoreScrollHost` or the `GeometryReader`):

```swift
.onChange(of: committedZoom) { reproject(provider: provider, baseWidth: baseWidth) }
.onChange(of: viewModel.annotationDrawings) { reproject(provider: provider, baseWidth: baseWidth) }
.task(id: provider.pageCount) { reproject(provider: provider, baseWidth: baseWidth) }
```

```swift
private func reproject(provider: PDFPageProvider, baseWidth: CGFloat) {
    projectedAnnotations = PDFAnnotationAnchoring.display(
        viewModel.annotationDrawings,
        pageFrames: pageFrames(provider: provider, baseWidth: baseWidth),
    )
}
```

(`viewModel.annotationDrawings` is already populated by `loadAnnotations()` in `load()`, which Plan 1's PDF branch calls. `DrawingAnchor` is `Equatable`, so `.onChange(of:)` is valid.)

- [ ] **Step 4: Surface the annotate toggle for PDFs in `ReaderTopOverlay`**

In the `.loadedPDF` branch (currently `pdfLayoutButton.glassEffect(...)`), add the existing `annotationToggleButton()` to its left so PDFs can enter annotation mode:

```swift
} else if case .loadedPDF = viewModel.loadState {
    HStack(spacing: 12) {
        annotationToggleButton()
            .glassEffect(.regular.interactive())
        pdfLayoutButton
            .glassEffect(.regular.interactive())
    }
}
```

(`annotationToggleButton()` only toggles `viewModel.isAnnotating` — no `Score` dependency — so it works unchanged for PDFs. `ReaderCapabilities.forPDF.canAnnotate` is already `true`.)

- [ ] **Step 5: Build the Reader package**

Run: `env -C Packages/Features/Reader xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'`
Expected: BUILD SUCCEEDED (confirm `Compiling VerticalPDFContainer.swift` and `Compiling ReaderTopOverlay.swift`).

- [ ] **Step 6: Build the full app**

Run: `env -C <repo> xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git -C <repo> add Packages/Features/Reader/Sources/Reader/Screens/PDF/VerticalPDFContainer.swift Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift
git -C <repo> commit -m "feat(reader): PDF annotation in vertical mode + annotate toggle"
```

---

## Task 4: Verification & manual handoff

**Files:** none.

- [ ] **Step 1: Run package test suites**

From each package dir:
- `env -C Packages/Domain xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'`
- `env -C Packages/Features/Reader xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'`

Expected: both TEST SUCCEEDED. (If a shared `ModuleCache.noindex` corruption error appears with no source diagnostic after back-to-back runs, remove `~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex` and rebuild — not a source defect.)

- [ ] **Step 2: Build the full app**

Run: `env -C <repo> xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Hand off manual verification (do NOT launch the simulator)**

Manual-smoke checklist for the user:
- Open a PDF in Vertical mode → tap the annotate toggle (pencil icon) → draw with the Apple Pencil → ink lands where drawn.
- Scroll the PDF → ink stays pinned to its page.
- Pinch-zoom and release → ink stays correctly placed and sized on its page.
- Close and reopen the PDF → ink is restored at the same page positions.
- Confirm an existing **score's** annotations still load and display correctly (back-compat: legacy `anchor` decodes to `.musical`).
- Confirm the annotate toggle is hidden/again-shown correctly and finger-vs-Pencil input behaves as in the score reader.

---

## Out of Scope

- **Paged / Horizontal PDF annotation** — deferred to ride with the score Paged/Horizontal annotation work (M2). `PagedPDFContainer` does not use `ScoreScrollHost`, so it needs separate canvas integration.
- **Text-box annotations on PDF** — `TextBoxAnchor` stays `MusicalAnchor`; no PDF text boxes.
- **CloudKit-specific changes** — annotation sync is JSON-blob based (no CKRecord field mapping exists yet); the new `kind` rides inside the existing blob with no extra work.

## Self-Review Notes

- Spec coverage (spec §4): `DrawingAnchorKind`/`PageAnchor` (T1), page-relative capture/display (T2), `AnnotationCanvasView` reuse via `VerticalPDFContainer` overlay (T3), persistence back-compat with no migration (T1 decoding + verified by reusing `AnnotationLayerRecord`'s JSON blob unchanged).
- Type consistency: `DrawingAnchor.kind`, `DrawingAnchorKind.musical/.page`, `PageAnchor.pageIndex`, `PDFAnnotationAnchoring.{pageIndex,normalizeTransform,displayTransform,capture,display}` used consistently across tasks.
- Back-compat is the highest risk: legacy `anchor` decoding is unit-tested (T1 `decodesLegacyAnchorAsMusical`) and the score display path is exercised by the existing Reader suite + manual score check (T4).
- Canvas math (T3) mirrors `VerticalScoreContainer.annotationCanvasState` minus padding/fit, adapted for the PDF container's committed-zoom-in-layout model — view code, gated by build + manual smoke.

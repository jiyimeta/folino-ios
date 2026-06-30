# Pencil Annotation M2b — Horizontal & Paged Hosting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the Vertical-mode Apple Pencil annotation to the Horizontal score, Page score, and Paged PDF reader surfaces, with one annotation set per score projected across all modes.

**Architecture:** Reuse the existing viewport-pinned `AnnotationCanvasController` (installed by `ScoreScrollHost` from a non-`nil` `AnnotationOverlaySpec`) for every mode — it already solves input routing, the tool picker, texture limits, and the echo guard. Each surface supplies a mode-correct `AnnotationCanvasState` (the geometry the canvas mirrors onto PencilKit's own scroll machinery) and a `displayDrawing` (the model projected to that surface's layout). Anchoring stays content-relative and layout-agnostic: `AnnotationAnchoring` (`MusicalAnchor`, scores) and `PDFAnnotationAnchoring` (`PageAnchor`, PDFs) are reused; paged modes add page-scoped projection helpers that map the current page into a viewport-sized "band" coordinate space and merge a page's re-captured strokes back into the full-score layer.

**Tech Stack:** Swift 6.3, SwiftUI + UIKit (`UIViewRepresentable`), PencilKit (`PKCanvasView` / `PKDrawing` / `PKStroke`), `swift-sheet-music` (`LayoutDocument`, `SheetMusicLayout`), Swift Testing.

## Global Constraints

- Target: universal iOS app, iOS 26+, Swift 6.3. All work is inside the `Reader` feature package (`Packages/Features/Reader/`).
- Module boundaries (enforced in review): no Feature→Feature, no Feature→Infrastructure, no Feature→`swift-sheet-music` direct import beyond what Reader already imports (`SheetMusicCore` / `SheetMusicLayout` / `SheetMusicUI` are already Reader deps). No Domain changes (the annotation model `AnnotationLayer` / `DrawingAnchor` / `DrawingAnchorKind` / `MusicalAnchor` / `PageAnchor` is untouched).
- No swift-sheet-music change: the `LayoutDocument.anchorReferencePoint(...)` / `resolveAnchor(at:)` primitives M2a shipped on are reused verbatim.
- New tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`). Package tests run via `xcodebuild` on an iOS Simulator (`swift test` is broken here by the SwiftLint plugin).
- Access modifiers: default `internal`; do **not** add `public` to anything (nothing here crosses the package boundary).
- Comment paragraphs reflow at the SwiftLint `line_length.warning: 120` budget.
- Package test command (run from `Packages/Features/Reader/`):
  `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/<SuiteName>`
  (if `Reader` is not a resolvable scheme, use `Reader-Package`).
- iOS verification policy: **do not** launch the simulator to "confirm" a view. Stop at a green build + green unit tests; hand device/Pencil checks (canvas geometry, gestures) to the user for a manual clean build. Each container task lists exactly what the user should look for.

---

## File Structure

**New / modified files:**

- `Packages/Features/Reader/Sources/Reader/Screens/Horizontal/HorizontalScoreContainer.swift` — **modify**: add annotation state + spec + canvas geometry; pass a non-`nil` `annotationOverlay`. (Task 1)
- `Packages/Features/Reader/Tests/ReaderTests/AnnotationAnchoringTests.swift` — **modify**: add a cross-layout (wrap ↔ natural width) projection test + paged helper tests. (Tasks 1, 2)
- `Packages/Features/Reader/Sources/Reader/Annotation/AnnotationAnchoring.swift` — **modify**: add `partitionByPage`, `displayPaged`, `capturePaged` (score paged projection). (Task 2)
- `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedPageGeometry.swift` — **create**: lift `pageStartY` + add `pageEndY` / `bounds(forPage:)` so the container and `PagedZoomedSurface` share one definition. (Task 3)
- `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedZoomedSurface.swift` — **modify**: call `PagedPageGeometry.pageStartY` instead of its own `fileprivate static`. (Task 3)
- `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift` — **modify**: add annotation state + spec + canvas geometry + page-scoped merge/reseed; pass a non-`nil` `annotationOverlay`. (Task 3)
- `Packages/Features/Reader/Sources/Reader/Annotation/PDFAnnotationAnchoring.swift` — **modify**: add `partitionByPage`, `displayPage`, `capturePage` (PDF paged projection). (Task 4)
- `Packages/Features/Reader/Tests/ReaderTests/PDFAnnotationAnchoringTests.swift` — **modify**: add paged helper tests. (Task 4)
- `Packages/Features/Reader/Sources/Reader/Screens/PDF/PagedPDFContainer.swift` — **modify**: add annotation state + spec + canvas geometry + page-scoped merge/reseed; pass a non-`nil` `annotationOverlay`. (Task 5)

**Untouched (reused as-is):** `AnnotationCanvasView.swift` (controller + `AnnotationCanvasState` + `AnnotationOverlaySpec`), `ScoreScrollHost.swift` (already installs/syncs the overlay for any mode), `ReaderViewModel+AnnotationPersistence.swift` (debounced save), the Domain model, the toolbar / input routing.

---

## Task 1: Horizontal score annotation

Horizontal is the closest mirror of Vertical score: one continuous `LayoutDocument` in a `ScoreScrollHost`, symmetric `scorePadding`, committed zoom = `viewModel.viewportZoom` (no fit-to-width), X scrolled natively, Y carried by `pinch.offsetY`. Capture/display reuse `AnnotationAnchoring` verbatim — no new anchoring code, so the only automated check is a cross-layout projection test proving a stroke captured in one layout resolves in another (the cross-mode-sharing guarantee). The canvas geometry is device-verified.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Horizontal/HorizontalScoreContainer.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/AnnotationAnchoringTests.swift`

**Interfaces:**
- Consumes (existing, unchanged):
  - `AnnotationAnchoring.capture(strokes: [PKStroke], in: LayoutDocument) -> [DrawingAnchor]`
  - `AnnotationAnchoring.display(_ drawings: [DrawingAnchor], in: LayoutDocument) -> PKDrawing`
  - `AnnotationOverlaySpec(isAnnotating:isPencilPreferred:displayDrawing:onChange:state:)`
  - `AnnotationCanvasState(documentSize:zoomScale:contentOffsetBias:contentInset:)`
  - `ReaderViewModel.isAnnotating`, `.viewportZoom`, `.annotationDrawings`, `.annotationDrawingsDidChange(_:)`
  - `PinchState` fields `magnification`, `anchor`, `offsetY`
- Produces: nothing new consumed by later tasks.

- [ ] **Step 1: Write the failing cross-layout projection test**

Add to `AnnotationAnchoringTests.swift` (the suite already has `installed`, `doc(staffSize:)`):

```swift
    /// A natural-width (no-wrap) layout of the same score, as Horizontal mode builds it. Proves an anchor captured in
    /// one layout projects into a different layout — the cross-mode sharing guarantee (Vertical ink shows in Horizontal).
    private func naturalDoc(staffSize: CGFloat = 28) -> LayoutDocument {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = Staff(measures: [measure, measure])
        let score = Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
        )
        var options = ScoreViewOptions()
        options.staffSize = staffSize
        options.wrapToViewWidth = false
        options.includeTitleFrame = false
        let natural = LayoutEngine.naturalContentWidth(score: score, options: options)
        return LayoutEngine.layout(score: score, options: options, availableWidth: natural)
    }

    @Test
    func `anchor captured in a wrap layout resolves in a natural-width layout`() throws {
        let wrap = doc()
        let natural = naturalDoc()
        let centroid = try #require(
            wrap.anchorReferencePoint(measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0)?.point,
        )
        let (anchor, _) = try #require(AnnotationAnchoring.normalizeTransform(forCentroid: centroid, in: wrap))
        // The same musical anchor resolves to a concrete point in the natural-width layout (non-nil display transform).
        #expect(AnnotationAnchoring.displayTransform(for: anchor, in: natural) != nil)
    }
```

- [ ] **Step 2: Run it to verify it passes against current code**

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/AnnotationAnchoring` (from `Packages/Features/Reader/`)
Expected: PASS (this documents an already-true guarantee; it is a regression guard, not red-then-green). If it fails to compile, fix the test fixture before proceeding.

- [ ] **Step 3: Add annotation state to `HorizontalScoreContainer`**

Add the import and `@State`. At the top of the file, change `import Domain` block to also import PencilKit:

```swift
import Domain
import PencilKit
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI
```

Add the projected-ink state alongside the other `@State` (after `committedZoom`):

```swift
    /// The annotation model projected to the current layout. Recomputed on reflow / score-swap and appear — NOT on
    /// scroll/pinch — so per-tick rendering stays cheap. Passed to the canvas as the seed drawing. Mirrors
    /// `VerticalScoreContainer.projectedAnnotations`.
    @State private var projectedAnnotations = PKDrawing()
```

- [ ] **Step 4: Pass the annotation overlay + reproject on reflow**

In `scrollContent(viewport:)`, replace `annotationOverlay: nil, // annotation is Vertical-mode only (M1)` with:

```swift
            annotationOverlay: annotationSpec(viewport: viewport),
```

Then add reproject triggers to the `scrollContent` view chain — append after the existing `.onChange(of: [playbackCursor, scrollAnchorCursor])` modifier:

```swift
        // Reproject (and reseed the canvas) only on reflow / score-swap and initial appear — NOT on
        // `viewModel.annotationDrawings`: while drawing, the canvas is the source of truth (kept equal to the live ink
        // in `annotationSpec`), so reseeding would wipe the just-committed stroke. Mirrors `VerticalScoreContainer`.
        .onChange(of: document) { _, _ in reprojectAnnotations() }
        .onAppear { reprojectAnnotations() }
```

- [ ] **Step 5: Add `annotationSpec`, `annotationCanvasState`, `reprojectAnnotations`**

Add these methods to `HorizontalScoreContainer` (e.g. after `commitPinch`):

```swift
    private func annotationSpec(viewport: CGSize) -> AnnotationOverlaySpec {
        AnnotationOverlaySpec(
            isAnnotating: viewModel.isAnnotating,
            isPencilPreferred: UIDevice.current.userInterfaceIdiom == .pad,
            displayDrawing: projectedAnnotations,
            onChange: { drawing in
                guard let doc = document else { return }
                // Canvas is the source of truth while drawing: keep the projection equal to the live ink so the next
                // render's `applyDrawing` is a no-op (echo guard). The model is still captured for persistence/reflow.
                projectedAnnotations = drawing
                viewModel.annotationDrawingsDidChange(
                    AnnotationAnchoring.capture(strokes: drawing.strokes, in: doc),
                )
            },
            state: { annotationCanvasState(viewport: viewport) },
        )
    }

    /// Geometry the canvas mirrors onto PencilKit's scroll machinery. Same composition as
    /// `VerticalScoreContainer.annotationCanvasState`, adapted for Horizontal: committed zoom = `viewportZoom` (no
    /// fit-to-width), symmetric `scorePadding`, X scrolled natively (no `pinch.offsetX`), Y carried by `pinch.offsetY`.
    /// Vertical centering rides on the host's real `contentOffset` (added by the controller), so it cancels here.
    private func annotationCanvasState(viewport _: CGSize) -> AnnotationCanvasState {
        guard let doc = document else {
            return AnnotationCanvasState(
                documentSize: .zero, zoomScale: 1, contentOffsetBias: .zero, contentInset: .zero,
            )
        }
        let zoomC = viewModel.viewportZoom // committed zoom, no live magnification, no fit-to-width
        let m = pinch.magnification
        let z = zoomC * m
        let pad = scorePadding
        let paddedW = doc.size.width + pad * 2
        let paddedH = doc.size.height + pad * 2
        let anchorTermX = pinch.anchor.x * paddedW * (1 - m) * zoomC
        let anchorTermY = pinch.anchor.y * paddedH * (1 - m) * zoomC
        let slack: CGFloat = 100_000
        return AnnotationCanvasState(
            documentSize: doc.size,
            zoomScale: z,
            contentOffsetBias: CGPoint(
                x: -pad * z - anchorTermX,
                y: -pad * z - anchorTermY - pinch.offsetY,
            ),
            contentInset: UIEdgeInsets(top: slack, left: slack, bottom: slack, right: slack),
        )
    }

    private func reprojectAnnotations() {
        guard let doc = document else { projectedAnnotations = PKDrawing(); return }
        projectedAnnotations = AnnotationAnchoring.display(viewModel.annotationDrawings, in: doc)
    }
```

- [ ] **Step 6: Build the Reader package**

Run: `xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'` (from `Packages/Features/Reader/`)
Expected: BUILD SUCCEEDED, no SwiftLint warnings on the edited file. Confirm `Compiling HorizontalScoreContainer.swift` appears (per the feature-package verification rule, so an app-level incremental skip can't mask an error).

- [ ] **Step 7: Run the anchoring tests**

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/AnnotationAnchoring`
Expected: PASS (all suite tests including the new one).

- [ ] **Step 8: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/Horizontal/HorizontalScoreContainer.swift Packages/Features/Reader/Tests/ReaderTests/AnnotationAnchoringTests.swift
git commit -m "feat(reader): Apple Pencil annotation in Horizontal score mode (M2b)"
```

- [ ] **Step 9: Device verification (hand to user)**

Ask the user to clean-build to a real iPad with Pencil and confirm in Horizontal mode: (a) entering annotation shows the tool picker; (b) Pencil draws ink that sits on the score and stays put while scrolling horizontally; (c) fingers still scroll/pinch; (d) ink stays glued to the music at committed zoom ≠ 1 and during a live pinch; (e) switching to Vertical shows the same strokes at the same musical positions (cross-mode sharing).

---

## Task 2: Score paged projection helpers

Page mode shows one viewport-sized page band at a time. The annotation canvas mirrors only the **current page**, in a "band" coordinate space whose origin is the band's top-left. These pure helpers map between the full-document musical anchoring and that band space, and partition the model by page so a page-scoped re-capture preserves other pages' ink. All unit-testable.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Annotation/AnnotationAnchoring.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/AnnotationAnchoringTests.swift`

**Interfaces:**
- Consumes (existing): `AnnotationAnchoring.anchorPoint(for:in:)`, `.normalizeTransform(forCentroid:in:)`, `.displayTransform(for:in:)`, `AnnotationAnchorPolicy.representativePoint(of:)`, `PKDrawing.transform(using:)`.
- Produces (used by Task 3):
  - `AnnotationAnchoring.partitionByPage(_ drawings: [DrawingAnchor], in: LayoutDocument, pageStartY: CGFloat, pageEndY: CGFloat) -> (onPage: [DrawingAnchor], offPage: [DrawingAnchor])`
  - `AnnotationAnchoring.displayPaged(_ drawings: [DrawingAnchor], in: LayoutDocument, pageStartY: CGFloat, pageEndY: CGFloat, contentPadding: CGFloat) -> PKDrawing`
  - `AnnotationAnchoring.capturePaged(strokes: [PKStroke], in: LayoutDocument, pageStartY: CGFloat, contentPadding: CGFloat) -> [DrawingAnchor]`

- [ ] **Step 1: Write the failing tests**

Add to `AnnotationAnchoringTests.swift`:

```swift
    @Test
    func `partitionByPage splits anchors by resolved y-band`() throws {
        let d = doc()
        // Two anchors: one on measure 0, one on measure 1. Resolve their points to pick a split band.
        let p0 = try #require(d.anchorReferencePoint(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0)?.point)
        let m0 = MusicalAnchor(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0)
        let m1 = MusicalAnchor(measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0)
        let a0 = DrawingAnchor(kind: .musical(m0), encodedDrawing: Data())
        let a1 = DrawingAnchor(kind: .musical(m1), encodedDrawing: Data())
        // Band covering p0.y only (single-system layout => both share a y; widen band to include both, then a zero-height band to exclude).
        let all = AnnotationAnchoring.partitionByPage([a0, a1], in: d, pageStartY: p0.y - 1, pageEndY: p0.y + 1)
        #expect(all.onPage.count + all.offPage.count == 2)
        // A band strictly below every anchor puts all of them off-page; none are dropped.
        let none = AnnotationAnchoring.partitionByPage([a0, a1], in: d, pageStartY: 1_000_000, pageEndY: 2_000_000)
        #expect(none.onPage.isEmpty)
        #expect(none.offPage.count == 2)
    }

    @Test
    func `capturePaged then displayPaged round-trips a band-space stroke`() throws {
        let d = doc()
        let pageStartY: CGFloat = 0
        let contentPadding: CGFloat = 12
        // A stroke sitting on the first staff, expressed in band space (doc point + padding, minus pageStartY).
        let docPoint = try #require(d.anchorReferencePoint(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0)?.point)
        let bandPoint = CGPoint(x: docPoint.x + contentPadding, y: docPoint.y - pageStartY)
        let stroke = PaintTestSupport.dot(at: bandPoint)
        let captured = AnnotationAnchoring.capturePaged(strokes: [stroke], in: d, pageStartY: pageStartY, contentPadding: contentPadding)
        #expect(captured.count == 1)
        let pageEndY = d.size.height
        let shown = AnnotationAnchoring.displayPaged(captured, in: d, pageStartY: pageStartY, pageEndY: pageEndY, contentPadding: contentPadding)
        let outPoint = try #require(shown.strokes.first?.renderBounds.center)
        #expect(abs(outPoint.x - bandPoint.x) < 1.0)
        #expect(abs(outPoint.y - bandPoint.y) < 1.0)
    }

    @Test
    func `displayPaged skips anchors off the page band`() throws {
        let d = doc()
        let docPoint = try #require(d.anchorReferencePoint(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0)?.point)
        let stroke = PaintTestSupport.dot(at: CGPoint(x: docPoint.x + 12, y: docPoint.y))
        let captured = AnnotationAnchoring.capturePaged(strokes: [stroke], in: d, pageStartY: 0, contentPadding: 12)
        // A band far below the stroke yields no displayed strokes.
        let shown = AnnotationAnchoring.displayPaged(captured, in: d, pageStartY: 1_000_000, pageEndY: 2_000_000, contentPadding: 12)
        #expect(shown.strokes.isEmpty)
    }
```

Add a tiny stroke factory + a `renderBounds.center` convenience. Create `Packages/Features/Reader/Tests/ReaderTests/Support/PaintTestSupport.swift` (the `Support/` dir already exists):

```swift
import CoreGraphics
import PencilKit

/// Builds trivial `PKStroke`s for annotation projection tests.
enum PaintTestSupport {
    /// A short two-point stroke centred on `point` (renderBounds.center ≈ `point`).
    static func dot(at point: CGPoint) -> PKStroke {
        let p1 = PKStrokePoint(
            location: CGPoint(x: point.x - 1, y: point.y - 1), timeOffset: 0,
            size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: 0,
        )
        let p2 = PKStrokePoint(
            location: CGPoint(x: point.x + 1, y: point.y + 1), timeOffset: 0.01,
            size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: 0,
        )
        let path = PKStrokePath(controlPoints: [p1, p2], creationDate: Date(timeIntervalSince1970: 0))
        return PKStroke(ink: PKInk(.pen, color: .black), path: path)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/AnnotationAnchoring`
Expected: FAIL — `partitionByPage` / `displayPaged` / `capturePaged` are not members of `AnnotationAnchoring` (compile error).

- [ ] **Step 3: Implement the helpers**

Append to the `AnnotationAnchoring` enum in `AnnotationAnchoring.swift`:

```swift
    /// Split anchors into those whose resolved point falls in the page band `[pageStartY, pageEndY)` and the rest.
    /// Anchors that fail to resolve in this layout go to `offPage` (preserved, never dropped) so a page-scoped
    /// re-capture can't delete ink it cannot currently place.
    static func partitionByPage(
        _ drawings: [DrawingAnchor], in document: LayoutDocument, pageStartY: CGFloat, pageEndY: CGFloat,
    ) -> (onPage: [DrawingAnchor], offPage: [DrawingAnchor]) {
        var onPage: [DrawingAnchor] = []
        var offPage: [DrawingAnchor] = []
        for drawing in drawings {
            guard case let .musical(anchor) = drawing.kind,
                  let (point, _) = anchorPoint(for: anchor, in: document),
                  point.y >= pageStartY, point.y < pageEndY
            else { offPage.append(drawing); continue }
            onPage.append(drawing)
        }
        return (onPage, offPage)
    }

    /// Project the anchors resolving onto `[pageStartY, pageEndY)` into page-local "band" space (band origin = page
    /// top-left): document→band is translate(+contentPadding, -pageStartY), composed onto the per-anchor denormalize.
    static func displayPaged(
        _ drawings: [DrawingAnchor], in document: LayoutDocument,
        pageStartY: CGFloat, pageEndY: CGFloat, contentPadding: CGFloat,
    ) -> PKDrawing {
        let docToBand = CGAffineTransform(translationX: contentPadding, y: -pageStartY)
        var strokes: [PKStroke] = []
        for drawing in drawings {
            guard case let .musical(anchor) = drawing.kind,
                  let (point, _) = anchorPoint(for: anchor, in: document),
                  point.y >= pageStartY, point.y < pageEndY,
                  let denormalize = displayTransform(for: anchor, in: document),
                  var stored = try? PKDrawing(data: drawing.encodedDrawing)
            else { continue }
            stored.transform(using: denormalize.concatenating(docToBand))
            strokes.append(contentsOf: stored.strokes)
        }
        return PKDrawing(strokes: strokes)
    }

    /// Capture band-space strokes (band→document is translate(-contentPadding, +pageStartY)) into musical anchors.
    /// Same normalization as `capture`, after lifting each stroke back into full-document coordinates so the centroid
    /// resolves against the layout.
    static func capturePaged(
        strokes: [PKStroke], in document: LayoutDocument, pageStartY: CGFloat, contentPadding: CGFloat,
    ) -> [DrawingAnchor] {
        let bandToDoc = CGAffineTransform(translationX: -contentPadding, y: pageStartY)
        return strokes.compactMap { stroke in
            var docDrawing = PKDrawing(strokes: [stroke])
            docDrawing.transform(using: bandToDoc)
            guard let docStroke = docDrawing.strokes.first else { return nil }
            let centroid = AnnotationAnchorPolicy.representativePoint(of: docStroke)
            guard let (anchor, normalize) = normalizeTransform(forCentroid: centroid, in: document) else { return nil }
            var normalized = PKDrawing(strokes: [docStroke])
            normalized.transform(using: normalize)
            return DrawingAnchor(kind: .musical(anchor), encodedDrawing: normalized.dataRepresentation())
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/AnnotationAnchoring`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Annotation/AnnotationAnchoring.swift Packages/Features/Reader/Tests/ReaderTests/AnnotationAnchoringTests.swift Packages/Features/Reader/Tests/ReaderTests/Support/PaintTestSupport.swift
git commit -m "feat(reader): score paged annotation projection helpers (M2b)"
```

---

## Task 3: Page score container wiring

Wire the canvas into `PagedScoreContainer`: mirror the current page band, seed it with `displayPaged`, and on every canvas change merge the page's re-captured strokes back into the full model (`offPage + capturePaged`). Reseed when the page index, document, or (read-mode) model changes. A small `PagedPageGeometry` helper shares `pageStartY` / `pageEndY` with `PagedZoomedSurface`. Canvas geometry is device-verified.

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedPageGeometry.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedZoomedSurface.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift`

**Interfaces:**
- Consumes: Task 2's `partitionByPage` / `displayPaged` / `capturePaged`; existing `AnnotationOverlaySpec` / `AnnotationCanvasState`; `PageState.pageIndex`; `pages: [Range<Int>]`; `Self.horizontalContentPadding(viewportWidth:)`.
- Produces:
  - `PagedPageGeometry.pageStartY(forPage: Int, pages: [Range<Int>], doc: LayoutDocument) -> CGFloat`
  - `PagedPageGeometry.pageEndY(forPage: Int, pages: [Range<Int>], doc: LayoutDocument) -> CGFloat`

- [ ] **Step 1: Create `PagedPageGeometry`**

Create `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedPageGeometry.swift`:

```swift
import SheetMusicLayout

/// Page-band vertical bounds in full-document layout coordinates, shared by `PagedZoomedSurface` (clip/offset) and
/// `PagedScoreContainer` (annotation projection + per-page partition). One definition so the band the score is clipped
/// to and the band annotations are projected into can never drift.
enum PagedPageGeometry {
    /// First page renders from doc-Y `0` (title frame visible); every later page starts at the previous page's
    /// last-system bottom (so the gap above its own first system — rehearsal marks — lands on the right page).
    static func pageStartY(forPage index: Int, pages: [Range<Int>], doc: LayoutDocument) -> CGFloat {
        guard index > 0, pages.indices.contains(index - 1) else { return 0 }
        let prevLastIndex = pages[index - 1].upperBound - 1
        guard doc.systems.indices.contains(prevLastIndex) else { return 0 }
        return doc.systems[prevLastIndex].origin.y + doc.systems[prevLastIndex].size.height
    }

    /// Bottom of this page's last system (so anchors below the last system still resolve to this page). Falls back to
    /// the page start for an empty/out-of-range page.
    static func pageEndY(forPage index: Int, pages: [Range<Int>], doc: LayoutDocument) -> CGFloat {
        guard pages.indices.contains(index) else { return pageStartY(forPage: index, pages: pages, doc: doc) }
        let lastSystemIndex = pages[index].upperBound - 1
        guard doc.systems.indices.contains(lastSystemIndex) else {
            return pageStartY(forPage: index, pages: pages, doc: doc)
        }
        return doc.systems[lastSystemIndex].origin.y + doc.systems[lastSystemIndex].size.height
    }
}
```

- [ ] **Step 2: Point `PagedZoomedSurface` at the shared helper**

In `PagedZoomedSurface.swift`, replace the body of the `fileprivate static func pageStartY(...)` so it delegates (keeps the existing call sites compiling):

```swift
    fileprivate static func pageStartY(
        forPage index: Int,
        pages: [Range<Int>],
        doc: LayoutDocument,
    ) -> CGFloat {
        PagedPageGeometry.pageStartY(forPage: index, pages: pages, doc: doc)
    }
```

- [ ] **Step 3: Build to confirm the refactor compiles**

Run: `xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'` (from `Packages/Features/Reader/`)
Expected: BUILD SUCCEEDED. Confirm `Compiling PagedZoomedSurface.swift` and `Compiling PagedPageGeometry.swift` appear.

- [ ] **Step 4: Add annotation imports + state to `PagedScoreContainer`**

Add `import PencilKit` to the import block. Add after `@State var swipeStartCursor`:

```swift
    /// The annotation model for the CURRENT page, projected to band space. Reseeded on page/document/model change;
    /// kept equal to the live ink while drawing so the canvas seed never round-trips an in-progress stroke.
    @State var projectedAnnotations = PKDrawing()
```

- [ ] **Step 5: Pass the annotation overlay + reseed triggers**

In `scrollContent(viewport:)`, replace `annotationOverlay: nil, // annotation is Vertical-mode only (M1)` with:

```swift
            annotationOverlay: annotationSpec(viewport: viewport),
```

Append reseed triggers after the existing `.onChange(of: [playbackCursor, pageAnchorCursor])` modifier (still inside `scrollContent(viewport:)`, so `viewport` is in scope and the closures capture it):

```swift
        .onChange(of: pageState.pageIndex) { _, _ in reprojectCurrentPage(viewport: viewport) }
        .onChange(of: document) { _, _ in reprojectCurrentPage(viewport: viewport) }
        .onChange(of: viewModel.annotationDrawings) { _, _ in
            // Read-mode model changes (load, cross-mode edit) reseed the current page. While drawing, the canvas is the
            // source of truth, so skip — reseeding the round-tripped projection would wipe the in-progress stroke.
            if !viewModel.isAnnotating { reprojectCurrentPage(viewport: viewport) }
        }
        .onAppear { reprojectCurrentPage(viewport: viewport) }
```

- [ ] **Step 6: Add the annotation methods**

Add to `PagedScoreContainer` (e.g. after `commitPinch`):

```swift
    /// Current page's band bounds (full-doc Y) + horizontal gutter; nil until layout is ready.
    private func currentPageBand(viewport: CGSize) -> (startY: CGFloat, endY: CGFloat, contentPadding: CGFloat)? {
        guard let doc = document, pages.indices.contains(pageState.pageIndex) else { return nil }
        let idx = pageState.pageIndex
        return (
            PagedPageGeometry.pageStartY(forPage: idx, pages: pages, doc: doc),
            PagedPageGeometry.pageEndY(forPage: idx, pages: pages, doc: doc),
            Self.horizontalContentPadding(viewportWidth: viewport.width),
        )
    }

    private func annotationSpec(viewport: CGSize) -> AnnotationOverlaySpec {
        AnnotationOverlaySpec(
            isAnnotating: viewModel.isAnnotating,
            isPencilPreferred: UIDevice.current.userInterfaceIdiom == .pad,
            displayDrawing: projectedAnnotations,
            onChange: { drawing in
                guard let doc = document, let band = currentPageBand(viewport: viewport) else { return }
                projectedAnnotations = drawing // canvas is source of truth this page
                // Re-capture THIS page's strokes; keep every other page's anchors verbatim.
                let (_, offPage) = AnnotationAnchoring.partitionByPage(
                    viewModel.annotationDrawings, in: doc, pageStartY: band.startY, pageEndY: band.endY,
                )
                let captured = AnnotationAnchoring.capturePaged(
                    strokes: drawing.strokes, in: doc, pageStartY: band.startY, contentPadding: band.contentPadding,
                )
                viewModel.annotationDrawingsDidChange(offPage + captured)
            },
            state: { annotationCanvasState(viewport: viewport) },
        )
    }

    /// Mirror the current page band onto the viewport-pinned canvas. Document space = the page band (viewport-sized);
    /// the band sits at `pageInsets.leading/top` inside the padded content, scaled by `viewportZoom × magnification`.
    /// Paged mode carries live pan on BOTH `pinch.offsetX` and `pinch.offsetY`. (At rest the page slide offset is 0;
    /// during an active slide the ink does not track — see device-verification notes.)
    private func annotationCanvasState(viewport: CGSize) -> AnnotationCanvasState {
        let zoomC = viewModel.viewportZoom
        let m = pinch.magnification
        let z = zoomC * m
        let padX = pageInsets.leading
        let padY = pageInsets.top
        let paddedW = viewport.width + pageInsets.leading + pageInsets.trailing
        let paddedH = viewport.height + pageInsets.top + pageInsets.bottom
        let anchorTermX = pinch.anchor.x * paddedW * (1 - m) * zoomC
        let anchorTermY = pinch.anchor.y * paddedH * (1 - m) * zoomC
        let slack: CGFloat = 100_000
        return AnnotationCanvasState(
            documentSize: CGSize(width: viewport.width, height: viewport.height),
            zoomScale: z,
            contentOffsetBias: CGPoint(
                x: -padX * z - anchorTermX - pinch.offsetX,
                y: -padY * z - anchorTermY - pinch.offsetY,
            ),
            contentInset: UIEdgeInsets(top: slack, left: slack, bottom: slack, right: slack),
        )
    }

    private func reprojectCurrentPage(viewport: CGSize) {
        guard let doc = document, let band = currentPageBand(viewport: viewport) else {
            projectedAnnotations = PKDrawing(); return
        }
        projectedAnnotations = AnnotationAnchoring.displayPaged(
            viewModel.annotationDrawings, in: doc,
            pageStartY: band.startY, pageEndY: band.endY, contentPadding: band.contentPadding,
        )
    }
```

`reprojectCurrentPage(viewport:)` and `currentPageBand(viewport:)` both take the live `viewport` so the gutter
(`contentPadding`) used to seed the canvas matches the one `displayPaged` projects with. The triggers (Step 5) call
them from inside `scrollContent(viewport:)`, and `annotationSpec(viewport:)`'s `onChange` captures the same `viewport`
— so every call site shares one width. No stored/placeholder viewport.

- [ ] **Step 7: Build the Reader package**

Run: `xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'`
Expected: BUILD SUCCEEDED, `Compiling PagedScoreContainer.swift` present, no SwiftLint warnings.

- [ ] **Step 8: Run the full Reader annotation test set (regression)**

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/AnnotationAnchoring -only-testing:ReaderTests/AnnotationPersistenceTests`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedPageGeometry.swift Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedZoomedSurface.swift Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift
git commit -m "feat(reader): Apple Pencil annotation in Page score mode (M2b)"
```

- [ ] **Step 10: Device verification (hand to user)**

Ask the user to confirm in Page mode on iPad: (a) ink draws on the current page and sits on the music; (b) flipping pages shows each page's own ink (and only that page's); (c) ink survives a round-trip (flip away and back); (d) committing a stroke then flipping does not lose it; (e) a stroke drawn in Vertical appears on the right page here; (f) pinch-zoom keeps the ink glued. Note the known limitation: during the page-slide animation the ink may pop to the new page rather than slide with it.

---

## Task 4: PDF paged projection helpers

Mirror Task 2 for fixed-layout PDFs. The current page maps to a single band-space `pageFrame` (the centered, fitted page rect). Helpers capture/display against that one page and partition the model by `pageIndex`.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Annotation/PDFAnnotationAnchoring.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/PDFAnnotationAnchoringTests.swift`

**Interfaces:**
- Consumes (existing): `PDFAnnotationAnchoring.normalizeTransform(pageFrame:)`, `.displayTransform(pageFrame:)`, `AnnotationAnchorPolicy.representativePoint(of:)`.
- Produces (used by Task 5):
  - `PDFAnnotationAnchoring.partitionByPage(_ drawings: [DrawingAnchor], pageIndex: Int) -> (onPage: [DrawingAnchor], offPage: [DrawingAnchor])`
  - `PDFAnnotationAnchoring.displayPage(_ drawings: [DrawingAnchor], pageIndex: Int, pageFrame: CGRect) -> PKDrawing`
  - `PDFAnnotationAnchoring.capturePage(strokes: [PKStroke], pageIndex: Int, pageFrame: CGRect) -> [DrawingAnchor]`

- [ ] **Step 1: Write the failing tests**

Add to `PDFAnnotationAnchoringTests.swift` (uses `PaintTestSupport` from Task 2; if Task 4 runs before Task 2 in a session, create that file first):

```swift
    @Test func `partitionByPage splits by page index`() {
        let a0 = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: Data())
        let a1 = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 1)), encodedDrawing: Data())
        let split = PDFAnnotationAnchoring.partitionByPage([a0, a1], pageIndex: 1)
        #expect(split.onPage.count == 1)
        #expect(split.offPage.count == 1)
    }

    @Test func `capturePage then displayPage round-trips at the same frame`() throws {
        let frame = CGRect(x: 30, y: 50, width: 200, height: 260) // a centered fitted-page rect in band space
        let point = CGPoint(x: frame.midX + 10, y: frame.midY - 20)
        let stroke = PaintTestSupport.dot(at: point)
        let captured = PDFAnnotationAnchoring.capturePage(strokes: [stroke], pageIndex: 3, pageFrame: frame)
        #expect(captured.count == 1)
        if case let .page(anchor) = try #require(captured.first).kind {
            #expect(anchor.pageIndex == 3)
        } else { Issue.record("expected .page anchor") }
        let shown = PDFAnnotationAnchoring.displayPage(captured, pageIndex: 3, pageFrame: frame)
        let out = try #require(shown.strokes.first?.renderBounds.center)
        #expect(abs(out.x - point.x) < 1.0)
        #expect(abs(out.y - point.y) < 1.0)
    }

    @Test func `displayPage shows only the requested page`() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 120)
        let stroke = PaintTestSupport.dot(at: CGPoint(x: 50, y: 60))
        let captured = PDFAnnotationAnchoring.capturePage(strokes: [stroke], pageIndex: 2, pageFrame: frame)
        #expect(PDFAnnotationAnchoring.displayPage(captured, pageIndex: 5, pageFrame: frame).strokes.isEmpty)
        #expect(!PDFAnnotationAnchoring.displayPage(captured, pageIndex: 2, pageFrame: frame).strokes.isEmpty)
    }
```

Add `import Domain` and `import PencilKit` to the top of `PDFAnnotationAnchoringTests.swift` if not present (the file currently imports only `CoreGraphics`, `@testable import Reader`, `Testing` — add `Domain` for `DrawingAnchor`/`PageAnchor` and `PencilKit` for the stroke factory's return type).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/PDFAnnotationAnchoringTests`
Expected: FAIL — `partitionByPage` / `capturePage` / `displayPage` not members (compile error).

- [ ] **Step 3: Implement the helpers**

Append to the `PDFAnnotationAnchoring` enum:

```swift
    /// Split anchors into those on `pageIndex` and the rest (off-page anchors preserved for the merge).
    static func partitionByPage(
        _ drawings: [DrawingAnchor], pageIndex: Int,
    ) -> (onPage: [DrawingAnchor], offPage: [DrawingAnchor]) {
        var onPage: [DrawingAnchor] = []
        var offPage: [DrawingAnchor] = []
        for drawing in drawings {
            if case let .page(anchor) = drawing.kind, anchor.pageIndex == pageIndex {
                onPage.append(drawing)
            } else {
                offPage.append(drawing)
            }
        }
        return (onPage, offPage)
    }

    /// Display only the anchors on `pageIndex`, denormalized into the band-space `pageFrame` (the centered fitted page).
    static func displayPage(_ drawings: [DrawingAnchor], pageIndex: Int, pageFrame: CGRect) -> PKDrawing {
        guard let denormalize = displayTransform(pageFrame: pageFrame) else { return PKDrawing() }
        var strokes: [PKStroke] = []
        for drawing in drawings {
            guard case let .page(anchor) = drawing.kind, anchor.pageIndex == pageIndex else { continue }
            guard var stored = try? PKDrawing(data: drawing.encodedDrawing) else { continue }
            stored.transform(using: denormalize)
            strokes.append(contentsOf: stored.strokes)
        }
        return PKDrawing(strokes: strokes)
    }

    /// Capture band-space strokes as `.page(pageIndex)` anchors, normalized to `pageFrame`. In paged mode every stroke
    /// belongs to the single visible page, so the page is passed in rather than resolved from the centroid.
    static func capturePage(strokes: [PKStroke], pageIndex: Int, pageFrame: CGRect) -> [DrawingAnchor] {
        guard let normalize = normalizeTransform(pageFrame: pageFrame) else { return [] }
        return strokes.map { stroke in
            var normalized = PKDrawing(strokes: [stroke])
            normalized.transform(using: normalize)
            return DrawingAnchor(
                kind: .page(PageAnchor(pageIndex: pageIndex)),
                encodedDrawing: normalized.dataRepresentation(),
            )
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/PDFAnnotationAnchoringTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Annotation/PDFAnnotationAnchoring.swift Packages/Features/Reader/Tests/ReaderTests/PDFAnnotationAnchoringTests.swift
git commit -m "feat(reader): PDF paged annotation projection helpers (M2b)"
```

---

## Task 5: Paged PDF container wiring

Wire the canvas into `PagedPDFContainer`. The band coordinate space is the viewport; the current page's band-space frame is the centered, fitted page rect (the same geometry `PDFPageView` uses). Seed with `displayPage`, merge with `partitionByPage` + `capturePage` on change, reseed on page/model change. Canvas geometry is device-verified.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/PDF/PagedPDFContainer.swift`

**Interfaces:**
- Consumes: Task 4's `partitionByPage` / `displayPage` / `capturePage`; existing `AnnotationOverlaySpec` / `AnnotationCanvasState`; `PageState.pageIndex`; `document.pageCount`, `document.page(at:)`, `PDFPage.bounds(for: .mediaBox)`.
- Produces: nothing consumed downstream.

- [ ] **Step 1: Add annotation imports + state**

Add `import PencilKit` to the import block (file currently imports `Domain`, `PDFKit`, `SwiftUI`). Add after `@State var committedZoom`:

```swift
    /// The annotation model for the CURRENT PDF page, projected to band space. Reseeded on page/model change; kept
    /// equal to the live ink while drawing so the canvas seed never round-trips an in-progress stroke.
    @State var projectedAnnotations = PKDrawing()
```

- [ ] **Step 2: Add the band-space page-frame helper**

Add to `PagedPDFContainer` (mirrors `PDFPageView`'s fit-and-center math so capture/display land where the page renders):

```swift
    /// The current page's frame in band (viewport) space: the page fitted into the viewport (preserving aspect) and
    /// centered — identical to `PDFPageView`'s composition, so ink normalizes against exactly the rendered page rect.
    private func currentPageFrame(viewport: CGSize) -> CGRect? {
        let idx = min(max(pageState.pageIndex, 0), max(document.pageCount - 1, 0))
        guard let page = document.page(at: idx) else { return nil }
        let b = page.bounds(for: .mediaBox).size
        guard b.width > 0, b.height > 0, viewport.width > 0, viewport.height > 0 else { return nil }
        let fit = min(viewport.width / b.width, viewport.height / b.height)
        let w = b.width * fit
        let h = b.height * fit
        return CGRect(x: (viewport.width - w) / 2, y: (viewport.height - h) / 2, width: w, height: h)
    }
```

- [ ] **Step 3: Pass the annotation overlay + reseed triggers**

In `scrollContent(viewport:)`, replace `annotationOverlay: nil,` with:

```swift
            annotationOverlay: annotationSpec(viewport: viewport),
```

Append after `.ignoresSafeArea()` on the `scrollContent` chain:

```swift
        .onChange(of: pageState.pageIndex) { _, _ in reprojectCurrentPage(viewport: viewport) }
        .onChange(of: viewModel.annotationDrawings) { _, _ in
            if !viewModel.isAnnotating { reprojectCurrentPage(viewport: viewport) }
        }
        .onAppear { reprojectCurrentPage(viewport: viewport) }
```

(`scrollContent(viewport:)` already has `viewport` in scope; the `.onChange`/`.onAppear` close over it.)

- [ ] **Step 4: Add the annotation methods**

Add to `PagedPDFContainer`:

```swift
    private func annotationSpec(viewport: CGSize) -> AnnotationOverlaySpec {
        AnnotationOverlaySpec(
            isAnnotating: viewModel.isAnnotating,
            isPencilPreferred: UIDevice.current.userInterfaceIdiom == .pad,
            displayDrawing: projectedAnnotations,
            onChange: { drawing in
                guard let frame = currentPageFrame(viewport: viewport) else { return }
                let idx = min(max(pageState.pageIndex, 0), max(document.pageCount - 1, 0))
                projectedAnnotations = drawing // canvas is source of truth this page
                let (_, offPage) = PDFAnnotationAnchoring.partitionByPage(viewModel.annotationDrawings, pageIndex: idx)
                let captured = PDFAnnotationAnchoring.capturePage(strokes: drawing.strokes, pageIndex: idx, pageFrame: frame)
                viewModel.annotationDrawingsDidChange(offPage + captured)
            },
            state: { annotationCanvasState(viewport: viewport) },
        )
    }

    /// Mirror the current page band onto the viewport-pinned canvas — same composition as `PagedScoreContainer`
    /// (band documentSize = viewport, band offset by `pageInsets`, zoom = `viewportZoom × magnification`, live pan on
    /// both axes). PDF page mode uses `viewModel.viewportZoom` directly (the value `PDFPageView` is told to scale by).
    private func annotationCanvasState(viewport: CGSize) -> AnnotationCanvasState {
        let zoomC = viewModel.viewportZoom
        let m = pinch.magnification
        let z = zoomC * m
        let padX = pageInsets.leading
        let padY = pageInsets.top
        let paddedW = viewport.width + pageInsets.leading + pageInsets.trailing
        let paddedH = viewport.height + pageInsets.top + pageInsets.bottom
        let anchorTermX = pinch.anchor.x * paddedW * (1 - m) * zoomC
        let anchorTermY = pinch.anchor.y * paddedH * (1 - m) * zoomC
        let slack: CGFloat = 100_000
        return AnnotationCanvasState(
            documentSize: CGSize(width: viewport.width, height: viewport.height),
            zoomScale: z,
            contentOffsetBias: CGPoint(
                x: -padX * z - anchorTermX - pinch.offsetX,
                y: -padY * z - anchorTermY - pinch.offsetY,
            ),
            contentInset: UIEdgeInsets(top: slack, left: slack, bottom: slack, right: slack),
        )
    }

    private func reprojectCurrentPage(viewport: CGSize) {
        guard let frame = currentPageFrame(viewport: viewport) else { projectedAnnotations = PKDrawing(); return }
        let idx = min(max(pageState.pageIndex, 0), max(document.pageCount - 1, 0))
        projectedAnnotations = PDFAnnotationAnchoring.displayPage(viewModel.annotationDrawings, pageIndex: idx, pageFrame: frame)
    }
```

- [ ] **Step 5: Build the Reader package**

Run: `xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'`
Expected: BUILD SUCCEEDED, `Compiling PagedPDFContainer.swift` present, no SwiftLint warnings.

- [ ] **Step 6: Run the PDF anchoring tests (regression)**

Run: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/PDFAnnotationAnchoringTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/PDF/PagedPDFContainer.swift
git commit -m "feat(reader): Apple Pencil annotation in Paged PDF mode (M2b)"
```

- [ ] **Step 8: Whole-feature build + full Reader test run**

Run (from repo root, the app build that exercises every edited container together):
`xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Then the full Reader suite:
`xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'` (from `Packages/Features/Reader/`)
Expected: BUILD SUCCEEDED; all Reader tests PASS.

- [ ] **Step 9: Device verification (hand to user)**

Ask the user to confirm in Paged PDF (both `.page` and `.horizontal` PDF layout modes route here): (a) ink draws on the visible page and sits on it; (b) flipping pages shows each PDF page's own ink; (c) ink survives flip-away-and-back and reopening the document; (d) a stroke drawn in Vertical PDF appears on the right page here; (e) pinch-zoom keeps the ink glued. Same known slide-transient limitation as Page score.

---

## Self-Review

**1. Spec coverage** (against `2026-06-27-pencil-annotation-m2b-horizontal-paged-design.md`):
- §5.1 Horizontal score → Task 1. ✓
- §5.2 Page score → Tasks 2 (projection) + 3 (wiring). ✓
- §5.3 Paged PDF → Tasks 4 (projection) + 5 (wiring). ✓
- §4 cross-mode sharing → no model/anchor change; same `AnnotationLayer` projected per mode (Tasks 1/3/5 all read `viewModel.annotationDrawings`); cross-layout test in Task 1. ✓
- §6 shared refactor → realized as per-content `*Paged` / `*Page` helpers alongside the existing anchoring files (spec's stated alternative), plus `PagedPageGeometry` to DRY the page-band bounds. ✓
- §7 unchanged: model/persistence/`AnnotationCanvasController`/`ScoreScrollHost`/toolbar/ssm — none modified. ✓
- §9 testing: capture↔display identity, cross-layout projection, page filter, page-local reconciliation — all covered by Tasks 1/2/4 unit tests; device items listed per container task. ✓
- §10 staging Horizontal → Page → PDF → Tasks 1 → 2/3 → 4/5. ✓

**2. Placeholder scan:** No TODO/TBD/"handle edge cases"/"similar to Task N" placeholders. `reprojectCurrentPage(viewport:)` (Task 3) and the PDF equivalent (Task 5) thread the live `viewport` from their call sites — no stored or stand-in viewport. Every code step shows complete code.

**3. Type consistency:** `partitionByPage` returns `(onPage:offPage:)` and is consumed as `let (_, offPage) =` in Tasks 3/5. `capturePaged(strokes:in:pageStartY:contentPadding:)`, `displayPaged(_:in:pageStartY:pageEndY:contentPadding:)`, `capturePage(strokes:pageIndex:pageFrame:)`, `displayPage(_:pageIndex:pageFrame:)`, `PagedPageGeometry.pageStartY/pageEndY(forPage:pages:doc:)` — signatures match between their definition tasks (2/4/3) and call sites (3/5). `AnnotationCanvasState` / `AnnotationOverlaySpec` field labels match `AnnotationCanvasView.swift`. `PaintTestSupport.dot(at:)` + `CGRect.center` defined once in Task 2, reused in Task 4.

## Known limitations (documented, not bugs)

- **Slide transient:** the viewport-pinned canvas shows the settled current page; during a page-slide/swipe animation the ink does not slide with the page (it re-seeds to the new page on `pageIndex` change). Acceptable for M2b; revisit if the feel warrants it.
- **Page-boundary clipping:** a stroke whose centroid's musical anchor lands near a page break shows on its one page and is clipped at the band edge — the rigid-anchor contract from the M2 policy doc.

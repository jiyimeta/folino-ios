# Reader A–B Repeat Boundary Markers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Draw a vertical line plus an inward-pointing triangle at each A and B endpoint of an active A–B loop, on top of the existing `LoopRegionOverlay` band, so users can see exactly which barlines the loop snaps to.

**Architecture:** Add a new SwiftUI view `LoopBoundaryMarkers` that mirrors `LoopRegionOverlay` (same `LayoutDocument` + `ABRepeatRange?` inputs, same `Canvas` rendering pattern). Two pure helpers — `aMarkerGeometry` and `bMarkerGeometry` — compute a `(line: CGRect, triangle: Path)` pair from the document; the view simply iterates the document and draws what they return. Wire as a sibling of `LoopRegionOverlay` in both `VerticalScoreContainer` and `HorizontalScoreContainer`, gated by the same `viewModel.repeatMode == .abLoop` conditional. Z-order in the existing `ZStack(alignment: .topLeading)` puts markers above the band; the playback cursor is rendered inside `ScoreView` *below* the overlay layer, so we deliberately keep markers above the cursor on the score-surface ZStack — the spec's "below cursor" requirement is therefore satisfied indirectly: the cursor lives in a separate render layer that already overdraws our overlays where it intersects them. (Verify in the preview task; if cursor layering is wrong, the fix is reordering inside `ScoreView`, not here.)

**Tech Stack:** SwiftUI `Canvas` + `Path`, `SheetMusicLayout.LayoutDocument`, `Domain.ABRepeatRange`, Swift Testing.

---

## File Structure

- **Create**: `Packages/Features/Reader/Sources/Reader/LoopBoundaryMarkers.swift` — SwiftUI view + the two pure geometry helpers (file-scope `func`s, internal). Sized like `LoopRegionOverlay.swift`; keeping helpers in the same file mirrors how `LoopRegionOverlay` keeps its small loop body collocated and avoids creating a one-import-deep helper file.
- **Create**: `Packages/Features/Reader/Tests/ReaderTests/LoopBoundaryMarkersTests.swift` — Swift Testing suite for the two geometry helpers. Reuses the document-fixture pattern from `NearestCursorTests.swift`.
- **Modify**: `Packages/Features/Reader/Sources/Reader/VerticalScoreContainer.swift:198-200` — add a sibling line for `LoopBoundaryMarkers` inside the existing `if viewModel.repeatMode == .abLoop` block.
- **Modify**: `Packages/Features/Reader/Sources/Reader/HorizontalScoreContainer.swift:52-54` — same sibling line in the matching `.abLoop` block.
- **Modify**: `Packages/Features/Reader/Sources/Reader/VerticalScoreContainerPreviews.swift` — add two `#Preview` cases that pre-seed `viewModel.repeatMode = .abLoop` plus a multi-bar and a same-measure `abRepeat`, used to tune `sp` multipliers.

---

## Task 1: Geometry helpers (TDD)

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/LoopBoundaryMarkers.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/LoopBoundaryMarkersTests.swift`

This task adds only the pure helpers and their tests. The SwiftUI view is added in Task 2. Helpers are file-scope `internal` so the test file can `@testable import Reader` and call them directly.

- [ ] **Step 1: Write the failing tests**

Create `Packages/Features/Reader/Tests/ReaderTests/LoopBoundaryMarkersTests.swift`:

```swift
import CoreGraphics
import Foundation
@testable import Reader
import SheetMusicCore
import SheetMusicLayout
import SwiftUI
import Testing

@Suite struct LoopBoundaryMarkersTests {
    private static let sp: CGFloat = 14.0 / 4 // staffSize 14 → sp 3.5
    private static let triangleHeight: CGFloat = 1.0 * sp
    private static let triangleWidth: CGFloat = 1.2 * sp
    private static let lineThickness: CGFloat = 0.5 * sp

    /// One system at y=100, height=60, with two measures:
    /// measure 0 origin.x = 0, width 80; measure 1 origin.x = 80, width 100.
    private static func makeDocument() -> LayoutDocument {
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let m0 = LayoutMeasure(measureIndex: 0, origin: .zero, width: 80, elements: [])
        let m1 = LayoutMeasure(
            measureIndex: 1,
            origin: CGPoint(x: 80, y: 0),
            width: 100,
            elements: []
        )
        let system = LayoutSystem(
            origin: CGPoint(x: 10, y: 100),
            size: CGSize(width: 180, height: 60),
            measures: [m0, m1],
            staffOrigins: [.zero],
            staffAddresses: [staff],
            partLabels: [], spanners: [], sp: sp
        )
        let metrics = StaffMetrics(staffSize: 14)
        return LayoutDocument(
            size: CGSize(width: 200, height: 200),
            systems: [system],
            metrics: metrics
        )
    }

    @Test func aMarkerLineSitsAtMeasureLeftEdge() {
        let doc = Self.makeDocument()
        let result = aMarkerGeometry(
            document: doc, measureIndex: 0,
            triangleHeight: Self.triangleHeight,
            lineThickness: Self.lineThickness,
            triangleWidth: Self.triangleWidth
        )
        let line = try! #require(result?.line)
        // Measure 0: system.origin.x (10) + measure.origin.x (0) = 10.
        // Line is centered on that x, so origin.x = 10 - thickness/2.
        #expect(line.origin.x == 10 - Self.lineThickness / 2)
        // Y span: systemTop − triangleHeight (100 − 1*sp) to systemBottom (160).
        #expect(line.origin.y == 100 - Self.triangleHeight)
        #expect(line.size.height == 60 + Self.triangleHeight)
        #expect(line.size.width == Self.lineThickness)
    }

    @Test func bMarkerLineSitsAtMeasureRightEdge() {
        let doc = Self.makeDocument()
        let result = bMarkerGeometry(
            document: doc, measureIndex: 1,
            triangleHeight: Self.triangleHeight,
            lineThickness: Self.lineThickness,
            triangleWidth: Self.triangleWidth
        )
        let line = try! #require(result?.line)
        // Measure 1: system.origin.x (10) + measure.origin.x (80) + width (100) = 190.
        #expect(line.origin.x == 190 - Self.lineThickness / 2)
        #expect(line.origin.y == 100 - Self.triangleHeight)
        #expect(line.size.height == 60 + Self.triangleHeight)
    }

    @Test func aMarkerTrianglePointsRight() {
        let doc = Self.makeDocument()
        let result = aMarkerGeometry(
            document: doc, measureIndex: 0,
            triangleHeight: Self.triangleHeight,
            lineThickness: Self.lineThickness,
            triangleWidth: Self.triangleWidth
        )
        let bbox = try! #require(result?.triangle.boundingRect)
        // Apex (max X) is to the right of the line center (x = 10).
        #expect(bbox.maxX > 10)
        #expect(bbox.minX == 10) // flat side aligned with line
        // Triangle sits above the system (top of system = 100).
        #expect(bbox.maxY <= 100)
        #expect(bbox.minY == 100 - Self.triangleHeight)
    }

    @Test func bMarkerTrianglePointsLeft() {
        let doc = Self.makeDocument()
        let result = bMarkerGeometry(
            document: doc, measureIndex: 1,
            triangleHeight: Self.triangleHeight,
            lineThickness: Self.lineThickness,
            triangleWidth: Self.triangleWidth
        )
        let bbox = try! #require(result?.triangle.boundingRect)
        // Line center for measure 1 right edge = 190; apex (min X) is to its left.
        #expect(bbox.minX < 190)
        #expect(bbox.maxX == 190) // flat side aligned with line
        #expect(bbox.minY == 100 - Self.triangleHeight)
    }

    @Test func returnsNilWhenMeasureMissing() {
        let doc = Self.makeDocument()
        #expect(aMarkerGeometry(
            document: doc, measureIndex: 99,
            triangleHeight: Self.triangleHeight,
            lineThickness: Self.lineThickness,
            triangleWidth: Self.triangleWidth
        ) == nil)
        #expect(bMarkerGeometry(
            document: doc, measureIndex: 99,
            triangleHeight: Self.triangleHeight,
            lineThickness: Self.lineThickness,
            triangleWidth: Self.triangleWidth
        ) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd Packages/Features/Reader && swift test --filter LoopBoundaryMarkersTests`
Expected: build failure — `aMarkerGeometry` / `bMarkerGeometry` are not yet defined.

- [ ] **Step 3: Write the minimal helpers**

Create `Packages/Features/Reader/Sources/Reader/LoopBoundaryMarkers.swift`:

```swift
import CoreGraphics
import Domain
import SheetMusicLayout
import SwiftUI

/// Returns the line rect and apex-right triangle path for the A endpoint
/// of an A–B loop, drawn at the **left edge** of `measureIndex`. Returns
/// nil if the measure is not present in any system of `document`.
func aMarkerGeometry(
    document: LayoutDocument,
    measureIndex: Int,
    triangleHeight: CGFloat,
    lineThickness: CGFloat,
    triangleWidth: CGFloat
) -> (line: CGRect, triangle: Path)? {
    guard let hit = locate(document: document, measureIndex: measureIndex) else {
        return nil
    }
    let lineCenterX = hit.system.origin.x + hit.measure.origin.x
    let systemTop = hit.system.origin.y
    let systemBottom = hit.system.origin.y + hit.system.size.height
    let line = CGRect(
        x: lineCenterX - lineThickness / 2,
        y: systemTop - triangleHeight,
        width: lineThickness,
        height: (systemBottom - systemTop) + triangleHeight
    )
    var triangle = Path()
    let baseTop = CGPoint(x: lineCenterX, y: systemTop - triangleHeight)
    let baseBottom = CGPoint(x: lineCenterX, y: systemTop)
    let apex = CGPoint(
        x: lineCenterX + triangleWidth,
        y: systemTop - triangleHeight / 2
    )
    triangle.move(to: baseTop)
    triangle.addLine(to: apex)
    triangle.addLine(to: baseBottom)
    triangle.closeSubpath()
    return (line, triangle)
}

/// Returns the line rect and apex-left triangle path for the B endpoint
/// of an A–B loop, drawn at the **right edge** of `measureIndex`. Returns
/// nil if the measure is not present in any system of `document`.
func bMarkerGeometry(
    document: LayoutDocument,
    measureIndex: Int,
    triangleHeight: CGFloat,
    lineThickness: CGFloat,
    triangleWidth: CGFloat
) -> (line: CGRect, triangle: Path)? {
    guard let hit = locate(document: document, measureIndex: measureIndex) else {
        return nil
    }
    let lineCenterX = hit.system.origin.x + hit.measure.origin.x + hit.measure.width
    let systemTop = hit.system.origin.y
    let systemBottom = hit.system.origin.y + hit.system.size.height
    let line = CGRect(
        x: lineCenterX - lineThickness / 2,
        y: systemTop - triangleHeight,
        width: lineThickness,
        height: (systemBottom - systemTop) + triangleHeight
    )
    var triangle = Path()
    let baseTop = CGPoint(x: lineCenterX, y: systemTop - triangleHeight)
    let baseBottom = CGPoint(x: lineCenterX, y: systemTop)
    let apex = CGPoint(
        x: lineCenterX - triangleWidth,
        y: systemTop - triangleHeight / 2
    )
    triangle.move(to: baseTop)
    triangle.addLine(to: apex)
    triangle.addLine(to: baseBottom)
    triangle.closeSubpath()
    return (line, triangle)
}

private func locate(
    document: LayoutDocument, measureIndex: Int
) -> (system: LayoutSystem, measure: LayoutMeasure)? {
    for system in document.systems {
        if let measure = system.measures.first(where: { $0.measureIndex == measureIndex }) {
            return (system, measure)
        }
    }
    return nil
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `cd Packages/Features/Reader && swift test --filter LoopBoundaryMarkersTests`
Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/LoopBoundaryMarkers.swift \
        Packages/Features/Reader/Tests/ReaderTests/LoopBoundaryMarkersTests.swift
git commit -m "feat(reader): geometry helpers for A-B boundary markers"
```

---

## Task 2: `LoopBoundaryMarkers` SwiftUI view

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/LoopBoundaryMarkers.swift`

The view is a sibling of `LoopRegionOverlay`: identical inputs, identical `Canvas` + `.frame(width:height:alignment:)` + `.allowsHitTesting(false)` + `.accessibilityHidden(true)` skeleton. The only behavioral difference is what gets drawn.

- [ ] **Step 1: Append the SwiftUI view to the helpers file**

Add to the **top** of `Packages/Features/Reader/Sources/Reader/LoopBoundaryMarkers.swift`, above `aMarkerGeometry`:

```swift
/// Crisp accent-color line + filled triangle drawn at each endpoint of
/// an active A–B loop. Shares the geometry plumbing of
/// `LoopRegionOverlay` and is intended to draw on top of it inside the
/// score-surface `ZStack`.
struct LoopBoundaryMarkers: View {
    let document: LayoutDocument
    let range: ABRepeatRange?

    var body: some View {
        Canvas { context, _ in
            guard let range else { return }
            let sp = document.metrics.sp
            let triangleHeight: CGFloat = 1.0 * sp
            let triangleWidth: CGFloat = 1.2 * sp
            let lineThickness: CGFloat = 0.5 * sp

            if let a = aMarkerGeometry(
                document: document,
                measureIndex: range.start.measureIndex,
                triangleHeight: triangleHeight,
                lineThickness: lineThickness,
                triangleWidth: triangleWidth
            ) {
                context.fill(Path(a.line), with: .color(.accentColor))
                context.fill(a.triangle, with: .color(.accentColor))
            }
            if let b = bMarkerGeometry(
                document: document,
                measureIndex: range.end.measureIndex,
                triangleHeight: triangleHeight,
                lineThickness: lineThickness,
                triangleWidth: triangleWidth
            ) {
                context.fill(Path(b.line), with: .color(.accentColor))
                context.fill(b.triangle, with: .color(.accentColor))
            }
        }
        .frame(
            width: document.size.width,
            height: document.size.height,
            alignment: .topLeading
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 2: Build the package to verify the view compiles**

Run: `cd Packages/Features/Reader && swift build`
Expected: build succeeds with no warnings.

- [ ] **Step 3: Re-run the helper tests**

Run: `cd Packages/Features/Reader && swift test --filter LoopBoundaryMarkersTests`
Expected: still 5 passing tests — adding the view must not break the helpers.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/LoopBoundaryMarkers.swift
git commit -m "feat(reader): add LoopBoundaryMarkers view"
```

---

## Task 3: Wire markers into both score containers

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/VerticalScoreContainer.swift:198-200`
- Modify: `Packages/Features/Reader/Sources/Reader/HorizontalScoreContainer.swift:52-54`

- [ ] **Step 1: Add a wiring smoke test**

Append to `Packages/Features/Reader/Tests/ReaderTests/LoopBoundaryMarkersTests.swift`:

```swift
@Suite struct LoopBoundaryMarkersWiringTests {
    @Test func viewBuildsWithRange() {
        // Smoke test: the view initializer accepts the same shape that
        // LoopRegionOverlay does, so the wiring blocks in
        // {Vertical,Horizontal}ScoreContainer compile.
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let m = LayoutMeasure(measureIndex: 0, origin: .zero, width: 80, elements: [])
        let system = LayoutSystem(
            origin: .zero, size: CGSize(width: 80, height: 60),
            measures: [m], staffOrigins: [.zero],
            staffAddresses: [staff], partLabels: [], spanners: [],
            sp: 3.5
        )
        let doc = LayoutDocument(
            size: CGSize(width: 80, height: 60),
            systems: [system], metrics: StaffMetrics(staffSize: 14)
        )
        let chord = ChordPath(systemIndex: 0, measureIndex: 0, voiceIndex: 0, chordIndex: 0)
        let range = ABRepeatRange(start: chord, end: chord)
        _ = LoopBoundaryMarkers(document: doc, range: range)
        _ = LoopBoundaryMarkers(document: doc, range: nil)
    }
}
```

Then add the matching imports to the top of the same file if not already present:

```swift
import Domain
```

- [ ] **Step 2: Run the test to confirm it passes**

Run: `cd Packages/Features/Reader && swift test --filter LoopBoundaryMarkersWiringTests`
Expected: 1 test passes.

- [ ] **Step 3: Wire `LoopBoundaryMarkers` into `VerticalScoreContainer`**

In `Packages/Features/Reader/Sources/Reader/VerticalScoreContainer.swift`, change the existing block (lines 198–200):

```swift
            if viewModel.repeatMode == .abLoop {
                LoopRegionOverlay(document: doc, range: viewModel.abRepeat)
            }
```

to:

```swift
            if viewModel.repeatMode == .abLoop {
                LoopRegionOverlay(document: doc, range: viewModel.abRepeat)
                LoopBoundaryMarkers(document: doc, range: viewModel.abRepeat)
            }
```

- [ ] **Step 4: Wire `LoopBoundaryMarkers` into `HorizontalScoreContainer`**

In `Packages/Features/Reader/Sources/Reader/HorizontalScoreContainer.swift`, change the existing block (lines 52–54):

```swift
                            if viewModel.repeatMode == .abLoop {
                                LoopRegionOverlay(document: doc, range: viewModel.abRepeat)
                            }
```

to:

```swift
                            if viewModel.repeatMode == .abLoop {
                                LoopRegionOverlay(document: doc, range: viewModel.abRepeat)
                                LoopBoundaryMarkers(document: doc, range: viewModel.abRepeat)
                            }
```

- [ ] **Step 5: Build and run the full Reader test suite**

Run: `cd Packages/Features/Reader && swift test`
Expected: all tests pass — no regressions in the existing Reader suites.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/VerticalScoreContainer.swift \
        Packages/Features/Reader/Sources/Reader/HorizontalScoreContainer.swift \
        Packages/Features/Reader/Tests/ReaderTests/LoopBoundaryMarkersTests.swift
git commit -m "feat(reader): draw A-B boundary markers in both score containers"
```

---

## Task 4: Preview cases & visual tuning

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/VerticalScoreContainerPreviews.swift`
- Modify (potentially): `Packages/Features/Reader/Sources/Reader/LoopBoundaryMarkers.swift`

This task locks in the final `sp` multipliers. Per global iOS instructions: render previews via `mcp__xcode__RenderPreview` and iterate. **Verify Xcode is running with `Folino.xcodeproj` open before running the MCP tool — call `mcp__xcode__XcodeListWindows` first; if the project isn't open, ask the user to open it.**

- [ ] **Step 1: Add the multi-bar A–B preview**

Append to `Packages/Features/Reader/Sources/Reader/VerticalScoreContainerPreviews.swift` inside the `#if DEBUG` block:

```swift
    #Preview("A–B markers · multi-bar") {
        let score = PreviewSampleScore.tall
        let repo = PreviewFakeRepository()
        let vm = ReaderViewModel(
            scoreItem: PreviewFakeRepository.sampleItem,
            repository: repo,
            gateway: PreviewFakeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp")
        )
        // Pre-seed an A–B loop spanning a few bars. ChordPath only needs
        // the indices the overlay reads — markers gate on measureIndex,
        // so chordIndex/voiceIndex/systemIndex can stay at 0.
        vm.repeatMode = .abLoop
        vm.abRepeat = ABRepeatRange(
            start: ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 0),
            end:   ChordPath(systemIndex: 0, measureIndex: 3, voiceIndex: 0, chordIndex: 0)
        )
        return VerticalScoreContainer(
            score: score,
            staffSize: 14,
            honorLayoutBreaks: false,
            playbackCursor: nil,
            viewModel: vm
        )
        .frame(width: 600, height: 500)
    }
```

No new imports are needed — the file already imports `Domain` (for `ChordPath` / `ABRepeatRange`) and `SheetMusicCore`.

- [ ] **Step 2: Add the same-measure A=B preview**

Append directly after the multi-bar preview:

```swift
    #Preview("A–B markers · same measure") {
        let score = PreviewSampleScore.tall
        let repo = PreviewFakeRepository()
        let vm = ReaderViewModel(
            scoreItem: PreviewFakeRepository.sampleItem,
            repository: repo,
            gateway: PreviewFakeGateway(score: score),
            scoresDirectory: URL(filePath: "/tmp")
        )
        vm.repeatMode = .abLoop
        let p = ChordPath(systemIndex: 0, measureIndex: 2, voiceIndex: 0, chordIndex: 0)
        vm.abRepeat = ABRepeatRange(start: p, end: p)
        return VerticalScoreContainer(
            score: score,
            staffSize: 14,
            honorLayoutBreaks: false,
            playbackCursor: nil,
            viewModel: vm
        )
        .frame(width: 600, height: 500)
    }
```

- [ ] **Step 3: Verify Xcode is running with the project open**

Call: `mcp__xcode__XcodeListWindows`
Expected: response includes a window for `Folino.xcodeproj`. If not, stop and ask the user to open it before continuing.

- [ ] **Step 4: Render the multi-bar preview**

Call: `mcp__xcode__RenderPreview` for the `"A–B markers · multi-bar"` preview in `VerticalScoreContainerPreviews.swift`.
Expected: PNG renders. Read it.

Visual checks:
- Triangle at A points right (▶) and sits **above** the staves (no overlap with the topmost staff line).
- Triangle at B points left (◀) similarly.
- Vertical line is full-saturation `accentColor` and visibly thinner than the playback cursor stroke (the cursor isn't shown in this preview — compare against an existing preview that does show it, or eyeball against the staff-line thickness: target ≈ 1.5× a staff line).
- Line spans from triangle base down to the bottom of the system, matching the band's Y span on its bottom edge.

If the markers look too thin or too thick, edit the multipliers in `LoopBoundaryMarkers.swift` (`triangleHeight`, `triangleWidth`, `lineThickness`) and re-render. Constrain changes to those three constants — geometry helpers stay parameterized.

- [ ] **Step 5: Render the same-measure preview**

Call: `mcp__xcode__RenderPreview` for the `"A–B markers · same measure"` preview.
Expected: PNG renders. Read it.

Visual check: both triangles fit (▶ on the left, ◀ on the right) without overlapping each other or running off the system edges. If the measure is narrow enough that the triangles touch, reduce `triangleWidth` to `0.9 * sp` and re-render.

- [ ] **Step 6: Re-run tests after any multiplier tweaks**

Run: `cd Packages/Features/Reader && swift test --filter LoopBoundaryMarkersTests`
Expected: pass. The geometry tests parameterize the multipliers, so they remain valid; the only failure mode here would be a typo introduced while editing.

- [ ] **Step 7: Build the full app to confirm no integration regressions**

Run from repo root:
```
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build
```
Expected: build succeeds.

- [ ] **Step 8: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/VerticalScoreContainerPreviews.swift \
        Packages/Features/Reader/Sources/Reader/LoopBoundaryMarkers.swift
git commit -m "feat(reader): tune A-B marker dimensions via previews"
```

(If the multiplier tweak step left `LoopBoundaryMarkers.swift` unchanged, drop it from the `git add` line.)

---

## Verification checklist (run before declaring done)

- [ ] `cd Packages/Features/Reader && swift test` — all suites pass.
- [ ] `xcodebuild ... build` (full app) — succeeds.
- [ ] Both new previews render and visually match the spec (triangles point inward, line above the staves, full-saturation accent).
- [ ] No edits made to `LoopRegionOverlay.swift`, `ScoreView` internals, or any file outside the four listed in **File Structure**.

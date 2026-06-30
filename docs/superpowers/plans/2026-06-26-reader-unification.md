# Reader Unification (Score + PDF) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify the paged + vertical reader interaction shell so score and PDF share one implementation, rendering PDF as vector into a `Canvas` so its zoom model is identical to the score's — fixing heavy pinch, pinch-commit scroll jump, blurry zoom, missing PDF page-turn animation, and broken PDF swipe.

**Architecture:** Extract the duplicated pinch-commit math into a pure `ReaderPinchCommit`; make the paged page surface generic over per-page content (`PagedReaderSurface<Page>`); extract the vertical zoom composition into `VerticalReaderShell<Content>`. Score and PDF become thin content providers. PDF pages draw their vector content into a `Canvas` (`PDFPageCanvas`), so `scaleEffect` re-rasterizes them sharp — letting `PDFPageProvider` (raster cache) be deleted.

**Tech Stack:** Swift 6.3, SwiftUI (`Canvas`, `scaleEffect`, `UIViewRepresentable`), PDFKit/CoreGraphics (`drawPDFPage`), Swift Testing, `xcodebuild` on iPhone 17 Pro Max simulator + iPad device for manual gates.

## Global Constraints

- Swift 6.3, iOS 26+, universal. `public` only across module boundaries; default `internal`.
- New tests use Swift Testing (`import Testing`, `@Test`, `#expect`).
- Package builds from the package dir; feature-package verification confirms `Compiling <File>.swift` in the log. Tests: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'` from `Packages/Features/Reader`. `swift test` does NOT work here.
- No bash compounds (`&&`); use `env -C <dir>` / `git -C <repo>`. Stage WHOLE files. Pre-commit hook may rewrite files & fail — re-stage and re-commit.
- All work in worktree `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/pdf-annotation`, branch `worktree-pdf-annotation`. Do NOT push.
- **Behavior preservation:** the score reader's paged page-turn / swipe / pinch / annotation / autoscroll / cursor / AB-loop / tap-seek behavior must be byte-for-byte preserved. Extractions move existing code verbatim; only the seam changes.
- PDF: page/vertical modes only, no horizontal. Annotation Vertical-only (M1 parity). Capability gating + "PDF" badge unchanged.
- Comments reflow at 120 columns. Brand literal `"PDF"` not localized.

## Execution model

This refactor is gesture/animation code: **most verification is manual on device, not unit tests.** Each PHASE ends with a manual device-regression gate the USER performs (build the app, install on the iPad, confirm the listed behaviors). Do NOT proceed to the next phase until the user confirms the gate. The spike (Phase 0) is a hard gate on the whole design.

---

## File Structure

**Created:**
- `Packages/Features/Reader/Sources/Reader/Screens/Shared/ReaderPinchCommit.swift` — pure pinch-commit math.
- `Packages/Features/Reader/Sources/Reader/Screens/Shared/PagedReaderSurface.swift` — generic paged page band (from `PagedZoomedSurface`).
- `Packages/Features/Reader/Sources/Reader/Screens/Shared/PagedReaderNavigation.swift` — generic page-turn/swipe (from `PagedScoreContainer+PageNavigation`).
- `Packages/Features/Reader/Sources/Reader/Screens/Shared/VerticalReaderShell.swift` — generic vertical zoom shell.
- `Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFPageCanvas.swift` — vector PDF page in a `Canvas`.
- `Packages/Features/Reader/Tests/ReaderTests/ReaderPinchCommitTests.swift`, `PagedSwipeOutcomeTests.swift`, `PDFSpikeView.swift` (spike preview).

**Modified:** the three score containers + their surfaces (use the shared pieces), the two PDF containers (reimplement on the shells), `PDFAnnotationAnchoring` page-frame space.

**Deleted:** `PDFPageProvider.swift` + `PDFPageProviderTests.swift` (raster machinery superseded by vector Canvas).

---

## Phase 0 — Spike: PDF as vector `Canvas` under `scaleEffect`

Validates the whole design's core assumption before any refactor. If it fails, STOP and revisit the spec (hybrid fallback).

### Task 0.1: Vector PDF spike view + device check

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFPageCanvas.swift`
- Create: `Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFSpikeView.swift`

**Interfaces:**
- Produces: `PDFPageCanvas(page: PDFPage)` — a `View` drawing one page's vector content into a `Canvas`, fitted to the view size, sharp under `scaleEffect`.

- [ ] **Step 1: Implement `PDFPageCanvas`**

```swift
import PDFKit
import SwiftUI

/// Draws one PDF page's VECTOR content into a SwiftUI `Canvas`. Because `Canvas` re-runs its draw closure at the
/// rendered (post-`scaleEffect`) resolution, the page stays sharp at any zoom — the same mechanism that keeps the
/// score's `ScoreView` Canvas sharp under zoom. No pre-rasterization / cache needed.
struct PDFPageCanvas: View {
    let page: PDFPage

    var body: some View {
        let bounds = page.bounds(for: .mediaBox)
        Canvas(rendersAsynchronously: false) { ctx, size in
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            ctx.withCGContext { cg in
                cg.saveGState()
                // Center within `size`, flip into PDF's bottom-left origin, scale points → view space.
                let drawnW = bounds.width * scale, drawnH = bounds.height * scale
                cg.translateBy(x: (size.width - drawnW) / 2, y: (size.height - drawnH) / 2)
                cg.translateBy(x: 0, y: drawnH)
                cg.scaleBy(x: scale, y: -scale)
                cg.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
                cg.setFillColor(UIColor.white.cgColor)
                cg.fill(bounds)
                page.draw(with: .mediaBox, to: cg)
                cg.restoreGState()
            }
        }
        .aspectRatio(bounds.width / max(bounds.height, 1), contentMode: .fit)
    }
}
```

- [ ] **Step 2: Implement a spike harness with a pinchable PDF page**

```swift
import PDFKit
import SwiftUI

/// Spike: a single PDF page in a Canvas under a live `.scaleEffect`, to confirm on-device that vector drawing stays
/// sharp and pinches smoothly before the reader refactor. Not shipped — used only for the Phase 0 device check.
struct PDFSpikeView: View {
    let document: PDFDocument
    @State private var zoom: CGFloat = 1
    @GestureState private var live: CGFloat = 1

    var body: some View {
        Group {
            if let page = document.page(at: 0) {
                PDFPageCanvas(page: page)
                    .scaleEffect(zoom * live, anchor: .center)
                    .gesture(
                        MagnifyGesture()
                            .updating($live) { value, state, _ in state = value.magnification }
                            .onEnded { value in zoom = max(1, min(6, zoom * value.magnification)) },
                    )
            } else {
                Text(verbatim: "no page")
            }
        }
    }
}
```

- [ ] **Step 3: Build the Reader package**

Run: `env -C Packages/Features/Reader xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'`
Expected: BUILD SUCCEEDED, `Compiling PDFPageCanvas.swift` + `Compiling PDFSpikeView.swift`.

- [ ] **Step 4: Commit**

```bash
git -C <repo> add Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFPageCanvas.swift Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFSpikeView.swift
git -C <repo> commit -m "spike(reader): vector PDF page in a Canvas (Phase 0)"
```

- [ ] **Step 5: DEVICE GATE (user)**

Temporarily route the reader's `.loadedPDF` branch to `PDFSpikeView(document:)` (or add a debug entry), build the app for the iPad, install, open a real multi-page PDF, and pinch-zoom. **User confirms:** (a) the page is sharp at high zoom (not blurry), and (b) pinch is smooth (no jank) — including on a visually dense PDF. If sharp+smooth → proceed to Phase 1 and revert the temporary routing. If janky on complex PDFs → STOP; revisit the spec for the hybrid fallback (raster snapshot during live gesture, vector Canvas on commit).

---

## Phase 1 — `ReaderPinchCommit` (shared pinch math)

### Task 1.1: Extract the pinch-commit math + tests

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Screens/Shared/ReaderPinchCommit.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderPinchCommitTests.swift`

**Interfaces:**
- Produces:
  - `struct PinchCommitInput { baseZoom, magnification: CGFloat; startLocation, currentOffset: CGPoint; offsetX, offsetY: CGFloat }`
  - `struct PinchCommitResult { targetZoom, ratio: CGFloat; rawScrollTarget: CGPoint; isBounceBack, snapToUnit: Bool; compensatedMag: CGFloat }`
  - `enum ReaderPinchCommit { static func resolve(_ input: PinchCommitInput) -> PinchCommitResult }`
- This is the math common to all three score `commitPinch` variants: `combined = baseZoom·magnification`; `targetZoom = combined < 1.05 ? 1 : combined`; `ratio = targetZoom/baseZoom`; `rawScrollTarget = (currentOffset.x + startLocation.x·(ratio−1) − offsetX, currentOffset.y + startLocation.y·(ratio−1) − offsetY)` (UNclamped — each container clamps per its axis); `isBounceBack = targetZoom ≤ 1 && baseZoom ≤ 1`; `snapToUnit = targetZoom ≤ 1`; `compensatedMag = combined/targetZoom`.

- [ ] **Step 1: Write the failing test**

```swift
import CoreGraphics
import Testing
@testable import Reader

@Suite struct ReaderPinchCommitTests {
    private func resolve(base: CGFloat, mag: CGFloat, start: CGPoint = .zero, offset: CGPoint = .zero,
                         offX: CGFloat = 0, offY: CGFloat = 0) -> PinchCommitResult {
        ReaderPinchCommit.resolve(PinchCommitInput(
            baseZoom: base, magnification: mag, startLocation: start, currentOffset: offset, offsetX: offX, offsetY: offY))
    }

    @Test func zoomInComputesTargetAndRatio() {
        let r = resolve(base: 2, mag: 1.5)
        #expect(abs(r.targetZoom - 3) < 1e-9)
        #expect(abs(r.ratio - 1.5) < 1e-9)
        #expect(r.isBounceBack == false)
        #expect(r.snapToUnit == false)
    }

    @Test func nearUnitSnapsToOne() {
        let r = resolve(base: 1, mag: 1.02) // combined 1.02 < 1.05 → target 1
        #expect(abs(r.targetZoom - 1) < 1e-9)
        #expect(r.isBounceBack) // base ≤ 1 && target ≤ 1
        #expect(r.snapToUnit)
    }

    @Test func zoomOutToUnitIsSnapNotBounce() {
        let r = resolve(base: 3, mag: 0.2) // combined 0.6 → target 1, base 3 > 1 → not bounce
        #expect(abs(r.targetZoom - 1) < 1e-9)
        #expect(r.isBounceBack == false)
        #expect(r.snapToUnit)
        #expect(abs(r.compensatedMag - 0.6) < 1e-9) // combined/target = 0.6/1
    }

    @Test func scrollTargetKeepsPointAndSubtractsOffsets() {
        // ratio 2 around start (100,200) from offset (10,20), live offsets (5,7):
        // x = 10 + 100·1 − 5 = 105 ; y = 20 + 200·1 − 7 = 213.
        let r = resolve(base: 1, mag: 2, start: CGPoint(x: 100, y: 200),
                        offset: CGPoint(x: 10, y: 20), offX: 5, offY: 7)
        #expect(abs(r.rawScrollTarget.x - 105) < 1e-9)
        #expect(abs(r.rawScrollTarget.y - 213) < 1e-9)
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `env -C Packages/Features/Reader xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/ReaderPinchCommitTests`
Expected: FAIL — types don't exist.

- [ ] **Step 3: Implement**

```swift
import CoreGraphics

struct PinchCommitInput {
    let baseZoom: CGFloat
    let magnification: CGFloat
    let startLocation: CGPoint
    let currentOffset: CGPoint
    let offsetX: CGFloat
    let offsetY: CGFloat
}

struct PinchCommitResult {
    let targetZoom: CGFloat
    let ratio: CGFloat
    /// Anchor-preserving scroll target BEFORE per-container clamping (vertical/paged clamp `max(0,·)`; horizontal
    /// clamps Y against its post-commit inset). Mirrors the formula the three score `commitPinch`s share.
    let rawScrollTarget: CGPoint
    let isBounceBack: Bool
    let snapToUnit: Bool
    /// `combined / targetZoom` — the magnification to compensate to at the snap-to-unit instant so the visible scale is
    /// invariant before the frame-by-frame decay to 1. Only meaningful when `snapToUnit`.
    let compensatedMag: CGFloat
}

/// The pinch-commit math shared by all reader modes (vertical / horizontal / paged, score + PDF). The view-side
/// orchestration (which offset axes to reset, `animateReset` vs `withAnimation`, the async hop) stays per-mode in the
/// shell; this provides the numbers so the geometry can never diverge again.
enum ReaderPinchCommit {
    static func resolve(_ input: PinchCommitInput) -> PinchCommitResult {
        let combined = input.baseZoom * input.magnification
        let targetZoom: CGFloat = combined < 1.05 ? 1.0 : combined
        let ratio = input.baseZoom == 0 ? 1 : targetZoom / input.baseZoom
        let rawScrollTarget = CGPoint(
            x: input.currentOffset.x + input.startLocation.x * (ratio - 1) - input.offsetX,
            y: input.currentOffset.y + input.startLocation.y * (ratio - 1) - input.offsetY,
        )
        return PinchCommitResult(
            targetZoom: targetZoom,
            ratio: ratio,
            rawScrollTarget: rawScrollTarget,
            isBounceBack: targetZoom <= 1.0 && input.baseZoom <= 1.0,
            snapToUnit: targetZoom <= 1.0,
            compensatedMag: targetZoom == 0 ? 1 : combined / targetZoom,
        )
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: same as Step 2. Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git -C <repo> add Packages/Features/Reader/Sources/Reader/Screens/Shared/ReaderPinchCommit.swift Packages/Features/Reader/Tests/ReaderTests/ReaderPinchCommitTests.swift
git -C <repo> commit -m "feat(reader): add ReaderPinchCommit (shared pinch-commit math)"
```

### Task 1.2: Migrate the three score `commitPinch`s to `ReaderPinchCommit`

**Files:**
- Modify: `Vertical/VerticalScoreContainer.swift:296-359`, `Horizontal/HorizontalScoreContainer.swift:119-183`, `Paged/PagedScoreContainer.swift:207-255`.

**Interfaces:** Consumes `ReaderPinchCommit.resolve` (Task 1.1). Each container keeps its existing orchestration but replaces the inline `combined`/`targetZoom`/`ratio`/`scrollToTarget`/`isBounceBack`/`snapToUnit`/`compensatedMag` computations with the resolved result.

- [ ] **Step 1: Replace the math in `VerticalScoreContainer.commitPinch`**

Inside `commitPinch`, replace the local computations (the lines computing `combined`, `targetZoom`, `ratio`, `scrollToTarget`, `isBounceBack`, `snapToUnit`, and later `compensatedMag`) with:

```swift
let session = pinchSession ?? PinchSession(baseZoom: viewModel.viewportZoom)
pinchSession = nil
let r = ReaderPinchCommit.resolve(PinchCommitInput(
    baseZoom: session.baseZoom, magnification: magnification,
    startLocation: startLocation, currentOffset: currentOffset,
    offsetX: pinch.offsetX, offsetY: 0,
))
let scrollToTarget = CGPoint(x: max(0, r.rawScrollTarget.x), y: max(0, r.rawScrollTarget.y))
```

Then use `r.isBounceBack`, `r.targetZoom`, `r.snapToUnit`, `r.compensatedMag` in the existing branch bodies (which stay verbatim — `animateReset`, the `scrollAbsorbsOffset` check, etc.). The `committedZoom = r.targetZoom` / `viewModel.viewportZoom = r.targetZoom` assignments use `r.targetZoom`.

- [ ] **Step 2: Replace the math in `HorizontalScoreContainer.commitPinch`**

Same pattern, but `offsetX: 0, offsetY: pinch.offsetY` and keep horizontal's post-inset Y clamp:

```swift
let r = ReaderPinchCommit.resolve(PinchCommitInput(
    baseZoom: session.baseZoom, magnification: magnification,
    startLocation: startLocation, currentOffset: currentOffset,
    offsetX: 0, offsetY: pinch.offsetY,
))
let docHeight = document?.size.height ?? 0
let postFramedH = (docHeight + scorePadding * 2) * r.targetZoom
let postInsetTop = max(0, (viewport.height - postFramedH) / 2)
let scrollToTarget = CGPoint(x: max(0, r.rawScrollTarget.x), y: max(-postInsetTop, r.rawScrollTarget.y))
```

Keep the rest of horizontal's body verbatim (its `withAnimation` orchestration, `scrollAbsorbsOffset = postFramedH > viewport.height`).

- [ ] **Step 3: Replace the math in `PagedScoreContainer.commitPinch`**

Same pattern with both offsets:

```swift
let r = ReaderPinchCommit.resolve(PinchCommitInput(
    baseZoom: session.baseZoom, magnification: magnification,
    startLocation: startLocation, currentOffset: currentOffset,
    offsetX: pinch.offsetX, offsetY: pinch.offsetY,
))
let scrollToTarget = CGPoint(x: max(0, r.rawScrollTarget.x), y: max(0, r.rawScrollTarget.y))
```

Keep paged's `withAnimation` / async orchestration verbatim, using `r.*`.

- [ ] **Step 4: Build the app**

Run: `env -C <repo> xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Run Reader tests**

Run: `env -C Packages/Features/Reader xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'`
Expected: TEST SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git -C <repo> add Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalScoreContainer.swift Packages/Features/Reader/Sources/Reader/Screens/Horizontal/HorizontalScoreContainer.swift Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift
git -C <repo> commit -m "refactor(reader): three score containers use ReaderPinchCommit"
```

### Phase 1 DEVICE GATE (user)

Build + install on iPad. **User confirms** pinch zoom in all three score modes (vertical, horizontal, paged) is unchanged: zoom-in, zoom-out, snap-to-unit, bounce-back, and the point under the fingers stays put on commit. Do not proceed until confirmed.

---

## Phase 2 — Generic paged surface + navigation (the page-turn fix)

### Task 2.1: Generic `PagedReaderNavigation` (page-turn/swipe logic)

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Screens/Shared/PagedReaderNavigation.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/PagedSwipeOutcomeTests.swift`
- Modify: `Paged/PagedScoreContainer+PageNavigation.swift` (delegate to the shared logic).

**Interfaces:**
- Produces: `enum PageSwipeOutcome { case commitPrevious, commitNext, cancel }` (moved here) and `enum PagedReaderNavigation` with the PURE helpers `outcome(translationX:predictedEndX:viewportWidth:isAtFirstPage:isAtLastPage:) -> PageSwipeOutcome` and `dampedTranslation(raw:viewportWidth:) -> CGFloat`, plus the animation constants `commitMaxDuration/commitMinDuration/cancelMaxDuration/cancelMinDuration` and the `commitAnimation(...)`/`cancelAnimation(...)` builders. These are the content-agnostic parts currently in `PagedScoreContainer+PageNavigation`.

- [ ] **Step 1: Write the failing test** (the pure `outcome`)

```swift
import CoreGraphics
import Testing
@testable import Reader

@Suite struct PagedSwipeOutcomeTests {
    private func outcome(_ tx: CGFloat, _ pred: CGFloat, first: Bool = false, last: Bool = false) -> PageSwipeOutcome {
        PagedReaderNavigation.outcome(translationX: tx, predictedEndX: pred, viewportWidth: 1000,
                                      isAtFirstPage: first, isAtLastPage: last)
    }

    @Test func commitsNextPastThreshold() { #expect(outcome(-350, -350) == .commitNext) }     // −35% < −30%
    @Test func commitsPreviousPastThreshold() { #expect(outcome(350, 350) == .commitPrevious) } // +35% > +30%
    @Test func cancelsBelowThreshold() { #expect(outcome(100, 100) == .cancel) }                // 10%
    @Test func flingCommitsViaPredictedEnd() { #expect(outcome(50, -400) == .commitNext) }      // small drag, big fling
    @Test func cancelsOffFirstEdge() { #expect(outcome(400, 400, first: true) == .cancel) }
    @Test func cancelsOffLastEdge() { #expect(outcome(-400, -400, last: true) == .cancel) }

    @Test func dampingAsymptotesBelowHalfViewport() {
        let d = PagedReaderNavigation.dampedTranslation(raw: 100_000, viewportWidth: 1000)
        #expect(d < 1000 && d > 400) // approaches but never reaches viewport width
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `env -C Packages/Features/Reader xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/PagedSwipeOutcomeTests`
Expected: FAIL — `PagedReaderNavigation` doesn't exist.

- [ ] **Step 3: Implement `PagedReaderNavigation`** by MOVING the pure pieces from `PagedScoreContainer+PageNavigation.swift` verbatim: `PageSwipeOutcome` (lines 1–12), `dampedTranslation` (108–116), `outcome` (287–309), the four duration constants (233–242), and the `commitAnimation(...)`/`cancelAnimation(...)` builder functions (quote them from the same file). Wrap them as `static` members of `enum PagedReaderNavigation`. Example head:

```swift
import CoreGraphics
import SwiftUI

enum PageSwipeOutcome: Equatable { case commitPrevious, commitNext, cancel }

/// Content-agnostic page-turn / swipe decisions + animation curves, shared by the score and PDF paged readers.
/// Moved verbatim from PagedScoreContainer+PageNavigation so both paged readers (and their swipe handlers) agree.
enum PagedReaderNavigation {
    static let commitMaxDuration = 0.22
    static let commitMinDuration = 0.10
    static let cancelMaxDuration = 0.18
    static let cancelMinDuration = 0.08

    static func outcome(translationX: CGFloat, predictedEndX: CGFloat, viewportWidth: CGFloat,
                        isAtFirstPage: Bool, isAtLastPage: Bool) -> PageSwipeOutcome { /* verbatim body */ }

    static func dampedTranslation(raw: CGFloat, viewportWidth: CGFloat) -> CGFloat { /* verbatim body */ }

    static func commitAnimation(remainingDistance: CGFloat, velocityMagnitude: CGFloat,
                                viewportWidth: CGFloat) -> Animation { /* verbatim body */ }
    static func cancelAnimation(snapBackDistance: CGFloat, viewportWidth: CGFloat) -> Animation { /* verbatim body */ }
}
```

(Quote the real `outcome`/`dampedTranslation`/`commitAnimation`/`cancelAnimation` bodies from `PagedScoreContainer+PageNavigation.swift` — they exist there today.)

- [ ] **Step 4: Point `PagedScoreContainer+PageNavigation` at the moved symbols** — delete its local `PageSwipeOutcome`, `dampedTranslation`, `outcome`, the four constants, and the animation builders; update call sites to `PagedReaderNavigation.outcome(...)`, `PagedReaderNavigation.dampedTranslation(...)`, `PagedReaderNavigation.commitAnimation(...)`, `PagedReaderNavigation.cancelAnimation(...)`, `PagedReaderNavigation.commitMin/MaxDuration`, etc. The stateful methods (`onSwipeChanged`, `onSwipeEnded`, `commitDragTurn`, `goToPage`, `commitPageTurn`, `followCursor`) stay on the container for now (they touch `pages`/`pageState`/`viewModel`).

- [ ] **Step 5: Run to verify pass + build app**

Run: `env -C Packages/Features/Reader xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:ReaderTests/PagedSwipeOutcomeTests` → PASS.
Run: `env -C <repo> xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build` → BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git -C <repo> add Packages/Features/Reader/Sources/Reader/Screens/Shared/PagedReaderNavigation.swift Packages/Features/Reader/Tests/ReaderTests/PagedSwipeOutcomeTests.swift Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer+PageNavigation.swift
git -C <repo> commit -m "refactor(reader): extract PagedReaderNavigation (shared page-turn/swipe)"
```

### Task 2.2: Generic `PagedReaderSurface<Page>` (page band)

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Screens/Shared/PagedReaderSurface.swift`
- Modify: `Paged/PagedZoomedSurface.swift` (becomes a thin score adapter over the generic surface).

**Interfaces:**
- Produces: `struct PagedReaderSurface<Page: View>: View` with the SAME inputs as `PagedZoomedSurface` EXCEPT: drop `document`, `score`, `scoreOptions`, `pages: [Range<Int>]`, `playbackCursor`, `lastManualCursor`, AB-loop; add `pageCount: Int` and `@ViewBuilder pageContent: (Int) -> Page`. Keeps: `viewModel` (for `viewportZoom`), `pinch`, `pageState`, `viewport`, `pageInsets`, `onPrev/Next/First/Last`, `onSwipeChanged`, `onSwipeEnded`, `showsHint`, `onAnyZoneTouchDown`.
- The slide/fade window (`slideSet`/`edgeSet`/`windowIndices`), `BandDragOffset`, the `pageBand` ForEach with per-index `.offset`/`.opacity`/`.zIndex`/`.transition`, the swipe `DragGesture`, the pinch `scaleEffect` composition, and `tapOverlay()` move here VERBATIM. The only change: `pageContent(forPage:)`/`scoreSurface(...)` is replaced by calling the injected `pageContent(idx)` closure, and `pages.count` becomes `pageCount`.

- [ ] **Step 1: Create `PagedReaderSurface<Page>`** by copying `PagedZoomedSurface.swift` and making it generic: remove the score-specific fields and the `pageContent(forPage:doc:)`/`scoreSurface(...)`/`tapSeekGesture(...)`/`pageStartY(...)` helpers; replace the `ForEach(windowIndices)` body's `pageContent(forPage: idx, doc: doc)` call with `pageContent(idx)`; replace every `pages.count` with `pageCount` and `pages.isEmpty` with `pageCount == 0`. Keep `BandDragOffset`, the slide/edge window math, `.modifier(BandDragOffset)`, `.clipped()`, `.padding(pageInsets)`, `.simultaneousGesture(pageSwipeGesture(), including: ...)`, the `.scaleEffect`/`.frame` composition, and `tapOverlay()` verbatim.

- [ ] **Step 2: Reimplement `PagedZoomedSurface` as a score adapter** — keep its current public interface (so `PagedScoreContainer` is unchanged) but have its `body` delegate to `PagedReaderSurface(pageCount: pages.count, pageContent: { idx in scorePage(forPage: idx) }, …passthrough…)`, where `scorePage(forPage:)` is the existing `pageContent(forPage:doc:)` body (the per-page sub-document `ScoreView` band, tap-seek, AB-loop). The `document`/`pages`/`pageStartY`/`scoreSurface`/`tapSeekGesture` helpers stay in `PagedZoomedSurface`.

- [ ] **Step 3: Build the app**

Run: `env -C <repo> xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED (confirm `Compiling PagedReaderSurface.swift`).

- [ ] **Step 4: Commit**

```bash
git -C <repo> add Packages/Features/Reader/Sources/Reader/Screens/Shared/PagedReaderSurface.swift Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedZoomedSurface.swift
git -C <repo> commit -m "refactor(reader): generic PagedReaderSurface; PagedZoomedSurface is its score adapter"
```

### Phase 2 DEVICE GATE (user)

Build + install. **User confirms** the SCORE paged reader is unchanged: page-turn tap zones, the slide/fade animation, swipe (drag + fling + snap-back + edge rubber-band), jump-to-first/last, pinch, tap-seek, cursor page-follow. Do not proceed until confirmed.

---

## Phase 3 — Generic `VerticalReaderShell<Content>`

### Task 3.1: Extract the vertical zoom shell

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Screens/Shared/VerticalReaderShell.swift`
- Modify: `Vertical/VerticalScoreContainer.swift` (use the shell), keep `VerticalZoomedSurface.swift` as the score content.

**Interfaces:**
- Produces: `struct VerticalReaderShell<Content: View>: View` that owns the `ScoreScrollHost` wiring + the vertical `commitPinch` orchestration (verbatim from `VerticalScoreContainer`, using `ReaderPinchCommit`) and applies NO committed-zoom scaleEffect itself (the content applies committed zoom, as `VerticalZoomedSurface` already does). Inputs: `viewModel`, `pinch`, bindings for `liveScrollOffset`/`contentInsetTop`/`pendingScroll`, `committedZoom` binding, `pinchSession` binding, `expectedContentSize: () -> CGSize`, `annotationOverlay: AnnotationOverlaySpec?`, `onPinchCommitDocWidth: () -> CGFloat` (the `document?.size.width` used by the `scrollAbsorbsOffset` check — supplied by the content so the shell stays content-agnostic), and `@ViewBuilder content`.
- The shell hosts `content` inside `ScoreScrollHost`, applies `.scaleEffect(pinch.magnification, anchor: pinch.anchor)` is done by the CONTENT (it already is, in the surfaces) — so the shell only wires the host + commit. The content closure renders the already-zoom-composed surface (score: `VerticalZoomedSurface`; PDF: the page stack with its own `.scaleEffect` composition).

> Note: keep `committedZoom`, `pinchSession`, `liveScrollOffset`, etc. as `@State` on the CONTAINER and pass bindings into the shell, so the existing observation/animation behavior is preserved exactly.

- [ ] **Step 1: Create `VerticalReaderShell`** by moving `VerticalScoreContainer.scrollContent(viewport:)`'s `ScoreScrollHost(...)` wiring and `commitPinch(...)` into the generic shell, parameterizing: `expectedContentSize` (closure in), `annotationOverlay` (in), and the `scrollAbsorbsOffset` doc width via `onPinchCommitDocWidth`. The `content` closure supplies the hosted surface.

- [ ] **Step 2: Reimplement `VerticalScoreContainer.scrollContent`** to call `VerticalReaderShell(... expectedContentSize: { existing closure }, annotationOverlay: annotationSpec(viewport:), onPinchCommitDocWidth: { document?.size.width ?? 0 }) { VerticalZoomedSurface(...) }`. The container keeps layout rebuild, autoscroll, annotation reproject, `effectiveZoom`, `scoreInset`, etc.

- [ ] **Step 3: Build the app**

Run: `env -C <repo> xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED (confirm `Compiling VerticalReaderShell.swift`).

- [ ] **Step 4: Run Reader tests + commit**

Run tests → TEST SUCCEEDED.
```bash
git -C <repo> add Packages/Features/Reader/Sources/Reader/Screens/Shared/VerticalReaderShell.swift Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalScoreContainer.swift
git -C <repo> commit -m "refactor(reader): extract VerticalReaderShell; score vertical uses it"
```

### Phase 3 DEVICE GATE (user)

Build + install. **User confirms** the SCORE vertical reader is unchanged: pinch zoom (in/out/snap/bounce, point-under-fingers), scroll, autoscroll during playback, tap-seek, AB-loop, and **annotation** (draw / scroll / zoom / persist / reopen). Do not proceed until confirmed.

---

## Phase 4 — PDF as content provider over the shared shells

### Task 4.1: PDF paged on `PagedReaderSurface`

**Files:**
- Modify: `PDF/PagedPDFContainer.swift` (reimplement over `PagedReaderSurface` + `PagedReaderNavigation`).

**Interfaces:** Consumes `PagedReaderSurface<Page>`, `PagedReaderNavigation`, `PageState`, `PinchState`, `ReaderPinchCommit`, `PDFPageCanvas`, `LoadState.loadedPDF(PDFDocument)`.

- [ ] **Step 1: Reimplement `PagedPDFContainer`** to mirror `PagedScoreContainer`'s structure but with PDF content: own `pageState`/`pinch`/`pinchSession`/`committedZoom`/`pendingScroll`/`liveScrollOffset`, wire `ScoreScrollHost` (via the same pattern) hosting `PagedReaderSurface(pageCount: document.pageCount, pageContent: { idx in pdfPage(idx) }, onSwipeChanged:/onSwipeEnded: using PagedReaderNavigation, onPrev/Next/First/Last: page-turn helpers)`. `pdfPage(idx)` returns `PDFPageCanvas(page: document.page(at: idx))` framed to the page band. Reuse the page-turn helpers (`goToPage`/`commitPageTurn`/`jumpToPage`) — extract the content-agnostic versions to a small `PagedPDFContainer+Navigation.swift` mirroring the score's, OR call shared helpers. No cursor-follow (PDF has no cursor). Pinch commit uses `ReaderPinchCommit` like the score paged container.

> Use `PagedScoreContainer` + `PagedScoreContainer+PageNavigation` as the reference; the PDF version is the same minus score layout/cursor/tap-seek/AB-loop, with `pageContent = PDFPageCanvas`.

- [ ] **Step 2: Build the app + commit**

Build → BUILD SUCCEEDED (`Compiling PagedPDFContainer.swift`).
```bash
git -C <repo> add Packages/Features/Reader/Sources/Reader/Screens/PDF/PagedPDFContainer.swift
git -C <repo> commit -m "feat(reader): PDF paged reader on the shared PagedReaderSurface"
```

### Task 4.2: PDF vertical on `VerticalReaderShell` + reconcile annotation

**Files:**
- Modify: `PDF/VerticalPDFContainer.swift` (reimplement over `VerticalReaderShell`).
- Modify: `Annotation/PDFAnnotationAnchoring.swift` usage — page frames now computed in UNZOOMED content space.

**Interfaces:** Consumes `VerticalReaderShell<Content>`, `PDFPageCanvas`, `AnnotationOverlaySpec`, `PDFAnnotationAnchoring`, `ReaderPinchCommit`.

- [ ] **Step 1: Reimplement `VerticalPDFContainer`** to host, inside `VerticalReaderShell`, a content view that is a `VStack` of `PDFPageCanvas` at UNZOOMED page sizes, composed with `.scaleEffect(pinch.magnification, anchor: pinch.anchor).scaleEffect(committedZoom × fit, .topLeading).frame(...)` exactly like `VerticalZoomedSurface` does for the score (so the committed-zoom composition is identical). `expectedContentSize` = unzoomed stack × committedZoom × fit. Provide `annotationSpec` using the shared annotation-canvas-state helper (same formula as the score vertical) and `PDFAnnotationAnchoring` with page frames computed in UNZOOMED content space. Keep the `!isAnnotating` reproject guard.

- [ ] **Step 2: Update `PDFAnnotationAnchoring` page-frame computation** so `pageFrames` are unzoomed (no `committedZoom` factor) — committed zoom is now applied by `scaleEffect`, not baked into layout. The capture/display normalization (per-page fraction) is unchanged; only the frame space changes. Existing `PDFAnnotationAnchoringTests` stay green (they pass explicit frames).

- [ ] **Step 3: Build the app + commit**

Build → BUILD SUCCEEDED (`Compiling VerticalPDFContainer.swift`).
```bash
git -C <repo> add Packages/Features/Reader/Sources/Reader/Screens/PDF/VerticalPDFContainer.swift Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFAnnotationAnchoring.swift
git -C <repo> commit -m "feat(reader): PDF vertical reader on VerticalReaderShell; unzoomed annotation frames"
```

### Task 4.3: Delete `PDFPageProvider`

**Files:**
- Delete: `PDF/PDFPageProvider.swift`, `Tests/ReaderTests/PDFPageProviderTests.swift`.

- [ ] **Step 1: Confirm no remaining references** — `rg -n "PDFPageProvider" Packages/Features/Reader` returns nothing after Tasks 4.1–4.2.

- [ ] **Step 2: Delete the files**

```bash
git -C <repo> rm Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFPageProvider.swift Packages/Features/Reader/Tests/ReaderTests/PDFPageProviderTests.swift
```

- [ ] **Step 3: Build the app + Reader tests + commit**

Build → BUILD SUCCEEDED. Tests → TEST SUCCEEDED.
```bash
git -C <repo> commit -m "refactor(reader): delete PDFPageProvider (superseded by vector Canvas)"
```

### Phase 4 DEVICE GATE (user)

Build + install on iPad. **User confirms PDF:** page mode (tap-zone turn, slide/fade animation, swipe, jump-to-edge, pinch sharp + no scroll jump), vertical mode (scroll, pinch sharp + point-under-fingers), annotation (draw / scroll / zoom / persist / reopen), badge + gating intact, and a real multi-page PDF stays smooth.

---

## Phase 5 — Full regression & cleanup

### Task 5.1: Full test + build sweep

- [ ] **Step 1:** `env -C Packages/Domain xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'` → TEST SUCCEEDED.
- [ ] **Step 2:** `env -C Packages/Features/Reader xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'` → TEST SUCCEEDED.
- [ ] **Step 3:** `env -C <repo> xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build` → BUILD SUCCEEDED.
- [ ] **Step 4: Remove the spike harness** — delete `PDFSpikeView.swift` and any temporary `.loadedPDF` routing to it (it was only for Phase 0). Commit.

### Task 5.2: Final device regression (user)

- [ ] **Step 1: Hand off the full manual matrix** to the user (do NOT auto-launch): score vertical / horizontal / paged (pinch, scroll, page-turn, swipe, autoscroll, tap-seek, AB-loop, annotation); PDF vertical / paged (pinch sharp, no scroll jump, page-turn animation + swipe, annotation, badge, gating); score annotation back-compat. Only after the user signs off is the unification complete.

---

## Out of Scope
- Horizontal PDF mode; paged/horizontal PDF annotation (score M2).
- Tiled rendering (vector Canvas makes it unnecessary).
- Pushing / merging to main (separate decision after the user's final sign-off).

## Self-Review Notes
- Spec coverage: vector Canvas (Phase 0, 4), ReaderPinchCommit (Phase 1, fixes scroll jump), PagedReaderSurface + Navigation (Phase 2, fixes animation+swipe), VerticalReaderShell (Phase 3), PDF providers + delete PDFPageProvider (Phase 4), annotation reconcile (4.2), regression (Phase 5). Horizontal migrated to ReaderPinchCommit only (1.2).
- Type consistency: `PinchCommitInput`/`PinchCommitResult`/`ReaderPinchCommit.resolve`, `PageSwipeOutcome`/`PagedReaderNavigation.outcome`/`dampedTranslation`, `PagedReaderSurface<Page>`/`VerticalReaderShell<Content>`, `PDFPageCanvas(page:)` used consistently across tasks.
- Verification reality: only `ReaderPinchCommit` and `PagedReaderNavigation.outcome` are unit-testable; everything else is build + manual device gates (called out per phase). The view extractions are behavior-preserving moves of existing, quoted code — the plan references the exact source blocks to move rather than re-deriving them.
- Risk: each phase is independently committed and device-gated, so a regression is caught at its phase and is revertible.

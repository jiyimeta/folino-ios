# Reader Unification (Score + PDF) — Design

**Date:** 2026-06-26
**Status:** Approved (brainstorm), pending implementation plan
**Branch:** `worktree-pdf-annotation`

## Summary

The PDF reader (Plan 1 + 2) reimplemented the score reader's zoom / pinch / scroll /
page-turn behavior in a divergent, simplified way. That divergence produced a class
of device bugs: heavy pinch, scroll jumps on pinch-commit, blurry zoom, and — in
page mode — missing page-turn animation and broken swipe. The fix is structural:
**unify the reader interaction shell so score and PDF share one implementation, and
render PDF content as vector (into a SwiftUI `Canvas`) so its zoom model is identical
to the score's.**

Key insight: a PDF page is vector content (a CoreGraphics content stream), not a
bitmap. Drawing it into a SwiftUI `Canvas` via `CGContext` lets SwiftUI re-rasterize
it under `scaleEffect` — sharp at any zoom, exactly like the score's `Canvas`. This
eliminates the entire pre-rasterization / cache / windowing machinery
(`PDFPageProvider`) that caused the heavy-pinch and blur bugs, and removes the only
reason the zoom model differed between score and PDF.

## Goals

- One shared interaction shell for **paged** and **vertical** reader modes; score
  and PDF both plug content into it.
- PDF rendered as **vector into `Canvas`** → identical zoom model to the score,
  sharp at any zoom, low memory.
- Fix, structurally (not by patching the PDF containers): heavy pinch, pinch-commit
  scroll jump, blurry zoom, missing page-turn animation, broken swipe.
- De-duplicate the pinch-commit logic currently copied across the three score
  containers.
- Preserve the score reader's behavior exactly (paged animation/swipe/pinch,
  vertical pinch/annotation/autoscroll/cursor, AB-loop, tap-seek).
- Preserve PDF behavior added in Plans 1–2 (page/vertical modes, capability gating,
  badge, Vertical-mode page-relative annotation).

## Non-Goals

- Horizontal PDF mode (PDF has no horizontal; horizontal stays score-only).
- Paged/Horizontal PDF annotation (still deferred to score M2).
- Tiled rendering for extreme zoom (vector Canvas re-rasterization makes it
  unnecessary).
- Changing pagination semantics, capability gating, or the badge.

## Core Decision: PDF as vector `Canvas` content

Instead of rasterizing a PDF page to a `CGImage` and displaying it (which blurs under
`scaleEffect`), draw the page's vector content directly inside a `Canvas`:

```swift
Canvas { ctx, size in
    ctx.withCGContext { cg in
        // fit page mediaBox into `size`, flip to PDF's bottom-left origin
        pdfPage.draw(with: .mediaBox, to: cg)   // PDFKit; or cg.drawPDFPage(cgPage)
    }
}
```

**Committed zoom is applied by GROWING THE PAGE VIEW'S FRAME** (the page `Canvas` is laid
out at `baseSize × committedZoom`), not by a `scaleEffect`. When the frame grows, the
`Canvas` re-runs its draw closure at the larger size, so the vector content rasterizes at
the higher resolution — sharp. Live pinch still rides a transient `scaleEffect`
(magnification), the same as the score; on commit the frame grows and the page re-renders
sharp. No cached bitmaps.

**Device-validated (Phase 0 spike).** Drawing a PDF page into a `Canvas` at a grown frame
renders **vector** PDFs (e.g. MuseScore exports) sharp at any zoom. Earlier "blurry"
spike results were a **test-file confound**: the PDF under test was a PiaScore export — a
**raster (image-backed) PDF that is blurry at the source** and renders blurry even in
Apple's Preview. That is expected and correct: a raster PDF can only be drawn at its
embedded image's resolution; we render it faithfully, like every PDF viewer. No special
handling — vector PDFs are sharp, raster PDFs are source-limited.

**Rendering specifics (for the plan):** draw via CoreGraphics `CGPDFPage`
(`page.pageRef` + `ctx.drawPDFPage`) rather than PDFKit's `PDFPage.draw`, and use
`Canvas(rendersAsynchronously: true)` so the draw runs off the main thread (matching the
score's per-system Canvases). `CGPDFPage` is a CoreGraphics type and is safe to use
off-main; PDFKit's `PDFPage.draw` is not (it traps `EXC_BREAKPOINT` on background
threads). At extreme zoom a single page `Canvas` may approach the layer's max backing
size; that is far beyond sheet-music reading needs and tiling can be added later if ever
required (YAGNI for now).

## Architecture

```
Shared (new, generic)
├─ ReaderPinchCommit            pure pinch-commit math (targetZoom, ratio, scrollTarget,
│                               isBounceBack, snapToUnit) — replaces the commitPinch copies
│                               in the 3 score containers; used by score + PDF.
├─ VerticalReaderShell<Content> ScoreScrollHost wiring + pinch state + commit + scaleEffect
│                               composition + annotation passthrough; takes content + unzoomed
│                               content size + fit + optional autoscroll hook.
├─ PagedReaderSurface<Page>     generic page band: slide/fade transition, neighbor pre-render,
│                               swipe drag, tap zones, pinch composition; takes pageCount +
│                               pageContent:(Int)->Page.
└─ PagedReaderNavigation        generic page-turn/swipe logic (pageCount + turn callbacks +
                                PageState); replaces PagedScoreContainer+PageNavigation's
                                score-coupled version.

Content providers
├─ Score
│   ├─ vertical: continuous ScoreView Canvas + cursor + tap-seek + AB-loop + layout rebuild
│   └─ paged:    per-page ScoreView band (system range) + cursor-follow + tap-seek + AB-loop
└─ PDF
    ├─ vertical: VStack of per-page PDF Canvases + page-relative annotation
    └─ paged:    per-page PDF Canvas (1 physical page = 1 reader page)
```

### Components

1. **`ReaderPinchCommit`** (new, pure/testable). Encapsulates the commit math the
   three score containers currently duplicate: given `baseZoom`, `magnification`,
   `startLocation`, `currentOffset`, and live offsets, produce `targetZoom`, `ratio`,
   the anchor-preserving `scrollTarget` (`currentOffset + start·(ratio−1) − offset`),
   and the `isBounceBack` / `snapToUnit` decisions. The view-side state orchestration
   (the two-phase snap-to-unit animation) stays in the shell but calls this for the
   numbers. Unit-tested. **Fixes the PDF pinch-commit scroll jump** (the PDF container
   had no scroll compensation).

2. **`VerticalReaderShell<Content: View>`** (new, generic). Wraps `ScoreScrollHost`,
   owns `PinchState` + `committedZoom`, wires the pinch callbacks through
   `ReaderPinchCommit`, applies the shared `scaleEffect` composition (live
   magnification + committed zoom × fit-to-width), supplies `expectedContentSize`, and
   passes through an optional `AnnotationOverlaySpec`. Inputs from the content
   provider: the content view (rendered at unzoomed content size), the unzoomed
   content size, horizontal/vertical padding, an optional autoscroll closure
   (score only), and an optional annotation spec. Score's `VerticalZoomedSurface`
   composition logic moves here; the score and PDF vertical containers become thin
   providers.

3. **`PagedReaderSurface<Page: View>`** (new, generic — `PagedZoomedSurface` made
   content-agnostic). Keeps the slide/fade/neighbor-window/swipe/tap machinery; the
   only change is `pageContent(forPage:)` becomes an injected
   `pageContent: (Int) -> Page` closure and pagination becomes `pageCount: Int`
   instead of `pages: [Range<Int>]`. Score passes a closure rendering the clipped
   ScoreView band for page i; PDF passes a per-page PDF `Canvas`. **Restores PDF
   page-turn animation + swipe** (the bare `PagedPDFContainer` had neither).

4. **`PagedReaderNavigation`** (new, generic — `PagedScoreContainer+PageNavigation`
   generalized). The swipe/turn/outcome logic operates on `pageCount`, `PageState`,
   and turn callbacks. Score adds cursor-follow on top; PDF uses it as-is.

5. **PDF content (new)**: a `PDFPageCanvas` view that draws one page's vector content
   into a `Canvas`. Vertical PDF provider stacks these; paged PDF provider shows one.
   Replaces the `CGImage`-based `PDFPageImage` / `PDFPagePageImage`.

### Deletions / reductions

- **`PDFPageProvider`** (raster cache, windowing, `retainWindow`, scale-cap) — deleted.
  PDF content draws directly from the `PDFDocument` the view model already holds
  (`LoadState.loadedPDF(PDFDocument)`). Its rasterization unit tests go with it.
- The bare `VerticalPDFContainer` / `PagedPDFContainer` are reimplemented as thin
  providers over the shared shell/surface (their divergent zoom/scroll/page-turn code
  is removed).
- The in-progress `PDFPinchMath` (Task started during debugging) is subsumed by
  `ReaderPinchCommit` (its `scrollTarget` is the same formula).

## Annotation

PencilKit annotation stays Vertical-mode only (parity with score M1).

- The PDF vertical provider supplies an `AnnotationOverlaySpec` to the shared
  `VerticalReaderShell` exactly as the score vertical provider does. Because both now
  use the identical `scaleEffect` zoom composition, the canvas-mirror geometry
  (`AnnotationCanvasState`: `documentSize`, `zoomScale`, `contentOffsetBias`) is
  computed by the same shared helper for both — removing the PDF's hand-rolled,
  divergent version.
- PDF page-relative anchoring (`DrawingAnchorKind.page` / `PageAnchor` /
  `PDFAnnotationAnchoring`) is unchanged — capture/display still normalize strokes to
  per-page fraction coordinates. Page frames are now computed in **unzoomed** content
  space (committed zoom is applied by `scaleEffect`, not baked into layout), which is
  simpler and zoom-independent.
- The `!isAnnotating` reproject guard (the earlier fix) is preserved.

## Data Flow (vertical, unified)

```
Container (score or PDF)
  builds: unzoomed content view (Canvas), unzoomed content size, padding,
          [score] autoscroll closure + cursor, [PDF] annotation spec
   ▼
VerticalReaderShell<Content>
  ScoreScrollHost(
     expectedContentSize = contentSize × committedZoom × fit,
     onPinch* → ReaderPinchCommit → committedZoom + pendingScroll,
     annotationOverlay = spec)
   { content
       .scaleEffect(magnification, anchor)      // live pinch (shared)
       .scaleEffect(committedZoom × fit, .topLeading)  // committed (shared)
       .frame(framed size) }
```

## Error Handling

- Corrupt / zero-page PDF: unchanged — routes to the reader's existing
  `failed(error)` state (Plan 1).
- `pdfPage.draw` failure inside `Canvas`: the page renders blank (white) for that page;
  no crash. (Same visual fallback as today's nil-image case.)
- Score paths (layout rebuild failure, etc.): unchanged.

## Testing

- **`ReaderPinchCommit`** (unit): `targetZoom`/`ratio`/`scrollTarget` formulas;
  `ratio == 1` → no offset change; zoom-around-point; bounce-back and snap-to-unit
  decisions; clamping. (Absorbs the existing `PDFPinchMath` tests.)
- **`PagedReaderNavigation`** (unit): the `outcome(...)` decision (commit vs cancel at
  thresholds / edges) extracted as a pure function and tested.
- **PDF annotation** (unit): `PDFAnnotationAnchoring` tests stay green with
  unzoomed-space page frames.
- **Score reader regression (manual, on device)** — the critical gate: paged
  page-turn animation + swipe + jump-to-edge, pinch zoom in all three modes,
  vertical annotation draw/persist, autoscroll + tap-seek + AB-loop. The refactor must
  not change any of these.
- **PDF (manual, on device)**: the spike (sharp + smooth pinch), then page-turn
  animation + swipe parity with score, pinch-commit no scroll jump, vertical scroll,
  annotation draw/scroll/zoom/persist, badge + gating intact.
- Package builds per the feature-package rule (`Compiling <File>.swift`); full app
  build; Domain/Reader test suites green.

## iOS/Android Parity

This is an iOS view-layer refactor (SwiftUI shells). No Domain logic changes except
that `DrawingAnchorKind` (Plan 2) already lives in shared Domain. The Android reader is
a separate Compose implementation; it is unaffected and out of scope.

## Risks

1. **`Canvas` + `drawPDFPage` rendering** — RESOLVED by the Phase 0 device spike: vector
   PDFs render sharp via a frame-grown `Canvas`; raster (image-backed) PDFs are
   source-limited (blurry even in Preview) and need no special handling. Use async
   rendering + `CGPDFPage` for smoothness/thread-safety (see Core Decision).
2. **Score reader regression** — the shells are extracted from the working score code;
   the score containers become providers over them. Mitigated by extracting behavior
   verbatim and a full manual regression pass on the score reader before merge.
3. **Scope** — touches shipped score paged + vertical containers. Horizontal is
   migrated only to `ReaderPinchCommit` (DRY), not restructured.

## Open Implementation Details (for the plan)

- Exact generic signatures of `VerticalReaderShell` / `PagedReaderSurface` and the
  content-provider closures.
- Whether `committedZoom` moves onto the shell or stays on `viewModel.viewportZoom`
  (shared today across modes; keep on the VM for continuity).
- The `scaleEffect` order standardization (committed-outer, as the score does today) so
  the shared anchor math matches the score's existing `*zoomC` formula — chosen to
  minimize score behavior change.
- Phasing: (0) spike → (1) `ReaderPinchCommit` extract + migrate score containers →
  (2) `PagedReaderSurface`/`Navigation` generic + migrate score paged → (3) PDF vector
  Canvas content + reimplement PDF containers on the shells → (4) delete
  `PDFPageProvider`, reconcile annotation → (5) full regression.

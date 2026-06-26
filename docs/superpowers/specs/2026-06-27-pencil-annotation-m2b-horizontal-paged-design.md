# Pencil Annotation M2b — Horizontal & Paged Hosting — Design

## 1. Goal & relationship to prior specs

This is **M2b**: the hosting work the M2 anchoring-policy doc explicitly deferred. It brings the Apple
Pencil annotation already shipped in **Vertical** mode (score **and** PDF) to the remaining reader
surfaces — **Horizontal score**, **Page score**, and **Paged PDF** — with **one annotation set per score,
shared across all modes**.

Parent chain (read for context, not re-decided here):

- [`2026-06-22-ipad-pencil-annotation-design.md`](2026-06-22-ipad-pencil-annotation-design.md) — data
  model (`MusicalAnchor`), canvas-hosting decision A1, input routing, persistence, sync.
- [`2026-06-24-pencil-annotation-m2-anchoring-policy-design.md`](2026-06-24-pencil-annotation-m2-anchoring-policy-design.md)
  — anchoring policy (centroid representative point, nearest-staff selection, rigid translate+scale
  reflow). Its **§7 scoped M2a = Vertical only and deferred Horizontal/Paged to M2b** — this doc.
- PDF page anchoring (`Packages/Features/Reader/Sources/Reader/Annotation/PDFAnnotationAnchoring.swift`)
  shipped with PDF import for the **Vertical PDF** reader; M2b extends it to the Paged PDF surface.

This doc changes **no product behavior** beyond surface coverage, **no module boundaries**, **no public
Domain API**, and **no anchoring policy**. It is purely per-mode canvas-hosting + page-flip projection
plumbing, plus tests. Anchoring, model, persistence, and the toolbar / input routing are inherited
unchanged. There is **no upstream swift-sheet-music work** — the forward/inverse primitives the M2 policy
doc gated on (§6 there) are already implemented and in use by M2a.

## 2. What's already in place (inherited, unchanged)

The architecture cleanly separates two layers; M2b touches almost only the second.

| Layer | Type(s) | Role | M2b impact |
| --- | --- | --- | --- |
| **Anchoring (content-relative, layout-agnostic)** | `AnnotationAnchoring` (score → `MusicalAnchor`), `PDFAnnotationAnchoring` (PDF → `PageAnchor`) | Capture = centroid → normalize to musical position / page-fraction; Display = denormalize into the **current layout**. Already projects into *any* layout (Vertical reflow on staff-size change proves it). | **None.** Page/Horizontal are just other layouts of the same content. No new anchor types; cross-mode sharing falls out for free. |
| **Canvas hosting (M1, viewport-pinned)** | `AnnotationCanvasController`, `ScoreScrollHost`, `AnnotationCanvasState`, `AnnotationOverlaySpec` | One **viewport-sized** `PKCanvasView` installed in `ScoreScrollHost`'s `UIScrollView` (pinned to `frameLayoutGuide`), mirroring the host's scroll offset + zoom into PencilKit's own scroll machinery via `AnnotationCanvasState {documentSize, zoomScale, contentOffsetBias, contentInset}`. Viewport-sized to dodge the 16,384 px GPU 2-D texture limit. | **Reused as-is.** Each new surface supplies a non-`nil` `AnnotationOverlaySpec` with mode-correct geometry. |
| **Persistence** | `ReaderViewModel+AnnotationPersistence` | Debounced (~0.5 s) save of the `AnnotationLayer`, keyed by `scoreItemID`. | **None.** |
| **Toolbar / enter-exit / pen picker / input routing** | driven by `viewModel.isAnnotating` (global) | Enter/exit annotation, tool picker, pencil-vs-finger policy. | **None.** Already global; works regardless of mode. |

## 3. Reconciliation with parent §5.2 (hosting evolved between spec and M1)

Parent **§5.1** proposed **A1** = a document-sized `PKCanvasView` inserted as a *sibling of `ScoreView`*
inside the transformed `scoreSurface` `ZStack`; **§5.2** prescribed **Paged = "one canvas per page, sized
to the page sub-document"**, reconciling per-page canvases into the single document-space layer by
re-adding `pageStartY`.

M1 instead shipped the **§5.4 evolution**: a *single viewport-pinned* canvas that mirrors the host's
scroll/zoom, because a document-sized canvas overflows the GPU texture limit on tall continuous scores.
M2b inherits **M1's actual hosting**, so §5.2 is realized as:

> the canvas presents the **current page's** projected strokes; the page-local coordinate bookkeeping §5.2
> describes (re-add `pageStartY` / page origin to reconcile a page-local stroke into the single
> document-space layer) is **unchanged**.

Whether that canvas is the **reused** viewport-pinned instance re-seeded on page flip, or a **fresh
per-page** instance sized to the page (a single page fits within the texture limit, so per-page is also
viable), is an implementation detail decided in the plan against the *current* `PagedScoreContainer` /
`PagedZoomedSurface` / `PagedPDFContainer` code. Either way the user-visible behavior and the page-local
reconciliation are identical. The spec fixes the **behavior and the coordinate contract**, not the canvas
lifetime.

## 4. Cross-mode sharing (confirmed with the user)

**One `AnnotationLayer` per score.** Because anchors are content-relative, the same `drawings` project into
Vertical / Horizontal / Page; a stroke drawn in one mode appears at the **same musical (score) / page (PDF)
position** in the others, and is editable from any mode.

Documented graceful-degradation edge (consistent with the M2 policy's rigid-span edge, §3.2 there): a
single stroke that, in continuous Vertical, visually spans a page break is anchored by its **centroid**, so
in Page mode it renders on the one page its centroid falls on and is **clipped at the page edge**. This is
acceptable and matches the existing rigid-anchor contract; it is not a regression introduced by M2b.

## 5. Per-surface design

### 5.1 Horizontal score (`HorizontalScoreContainer`)

Closest to Vertical. Today it uses `ScoreScrollHost` directly with `annotationOverlay: nil`.

- Supply an `AnnotationOverlaySpec` whose `state` returns an `AnnotationCanvasState` with
  `documentSize = ` the natural (un-wrapped) `doc.size`, `zoomScale = ` committed zoom × live
  magnification, and a `contentOffsetBias` built from the **horizontal** pinch/pan math — the **X axis is
  the native scroll axis here**, a mirror of Vertical's Y.
- Capture/display via `AnnotationAnchoring` (`MusicalAnchor`), resolving anchor reference points in the
  Horizontal `LayoutDocument` — identical to Vertical score, only the layout differs.
- Reproject `projectedAnnotations` on `viewModel.annotationDrawings` change **while not annotating** (the
  canvas is the source of truth during a stroke) — the `VerticalPDFContainer` pattern.

### 5.2 Page score (`PagedScoreContainer`)

Discrete page bands, one visible at a time. The canvas presents the **current page's** strokes.

- **Display:** filter the model's drawings to those whose `MusicalAnchor` resolves onto the **current
  page's system range** (the page→systems mapping `pages: [Range<Int>]` already exists), denormalize into
  the **page-local** coordinate space (re-add `pageStartY` per §3 / parent §5.2), seed the canvas.
- **Capture:** new strokes on the current page → centroid resolves to a musical position that lives on this
  page → `MusicalAnchor` → **merged into the full-score layer** (not a page-scoped sub-layer).
- **On page flip:** re-seed the canvas with the new page's projection. While `isAnnotating`, **commit the
  in-progress stroke before sliding**; suppress mid-stroke flips (tap-zone navigation yields until the
  stroke ends).

### 5.3 Paged PDF (`PagedPDFContainer` — covers both Page and Horizontal PDF)

Same shape as §5.2 but with PDF page anchoring (`PDFAnnotationAnchoring`, `PageAnchor`), already proven in
the Vertical PDF reader.

- **Display:** filter the model to `pageIndex == currentPage`, denormalize into the **visible page rect**,
  seed the canvas.
- **Capture:** new strokes → `PageAnchor(currentPage)`, merged into the full layer.
- The page frame is simply the single visible page — no inter-page gap math (unlike the Vertical PDF stack).

> Note: PDF routes **both** `.page` and `.horizontal` layout modes to `PagedPDFContainer`
> (`ReaderRootScreen` §`loadedPDF`), so this single surface delivers PDF annotation for both modes.

## 6. Small shared refactor (in the course of the work)

The page-flip projection — *filter to current page → denormalize → seed*, and *capture → merge into the
full layer* — is new relative to Vertical's continuous reprojection and is shared by §5.2 and §5.3. Extract
a small **Reader-internal** helper (e.g. `PagedAnnotationProjector`, or per-content functions placed
alongside the existing `AnnotationAnchoring` / `PDFAnnotationAnchoring` files) so `PagedScoreContainer` and
`PagedPDFContainer` don't duplicate it. This mirrors the existing score/PDF anchoring split. **No new
module, no Domain change, no public API.**

## 7. What does NOT change

- **Domain model** — `AnnotationLayer`, `DrawingAnchor`, `DrawingAnchorKind`, `MusicalAnchor`, `PageAnchor`
  are untouched. Sharing is free *because* anchors are content-relative.
- **Persistence** — `ReaderViewModel+AnnotationPersistence`, debounced, keyed by `scoreItemID`.
- **Canvas backbone** — `AnnotationCanvasController` and its install point in `ScoreScrollHost` (already
  mode-agnostic; it just needs a non-`nil` spec).
- **Toolbar / input routing / pen picker** — `isAnnotating`-driven, global.
- **swift-sheet-music** — no upstream change. The forward/inverse `anchorReferencePoint` primitives the M2
  policy doc §6 gated on are already implemented and used by M2a; M2b reuses them verbatim.

## 8. Risks / device-verification items

- **Annotation during page flip** — commit-then-slide; suppress mid-stroke flips. Needs device feel check.
- **X-axis interaction with PencilKit's own scroll machinery** (Horizontal) — Vertical proved the Y axis;
  X is a mirror but the `AnnotationCanvasState` geometry must be device-verified.
- **Coordinate correctness under pinch zoom** — the per-surface `anchorTerm` / `contentOffsetBias` math
  must be ported correctly for each new surface (the only genuinely error-prone part).
- **Page-boundary stroke clipping** in Page mode — cosmetic, expected (§4).

## 9. Testing strategy

- **Unit (Swift Testing)**, extending the existing `AnnotationAnchoring` / `PDFAnnotationAnchoring` suites:
  - capture → display **identity** at a given layout (zero net offset), per new surface's layout;
  - **cross-layout projection** — a stroke captured in a Vertical layout lands at the **same musical
    position** when projected into a Horizontal layout and a Page band (and the reverse);
  - **page filter** selects exactly the strokes whose anchor resolves onto the current page (score) /
    `pageIndex` (PDF);
  - **page-local reconciliation** — `pageStartY` re-add round-trips a captured page-local stroke back to
    the same document-space anchor.
- **Device** — canvas geometry and gestures per surface cannot be unit-tested; build and hand to the user
  for Apple Pencil verification (per the iOS no-simulator-launch workflow).

## 10. Staging (implementation order)

1. **Horizontal score** — validates the X-axis canvas geometry; closest to Vertical, lowest risk.
2. **Page score** — introduces the page-flip projection and the shared `PagedAnnotationProjector`.
3. **Paged PDF** — reuses the projector with `PageAnchor`; also delivers Horizontal PDF.

## 11. Summary of decisions

1. **Scope** = Horizontal score + Page score + Paged PDF — full parity with Vertical (score + PDF).
2. **Sharing** = one `AnnotationLayer` per score, projected across all modes (user-confirmed).
3. **Anchoring / model / policy / persistence / toolbar** = inherited unchanged; **M2b is hosting +
   projection plumbing only**.
4. **Hosting** = inherits M1's viewport-pinned canvas; parent §5.2 is realized as **current-page projection
   with page-local (`pageStartY`) reconciliation**; canvas lifetime (reused vs per-page) is a plan detail.
5. **swift-sheet-music** = no upstream change (the M2 §6 gating primitive already shipped with M2a).
6. **Shared refactor** = extract a small Reader-internal paged-projection helper; no module/Domain change.

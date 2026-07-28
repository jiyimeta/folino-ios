# PDF Import — Design

**Date:** 2026-06-26
**Status:** Approved (brainstorm), pending implementation plan

## Summary

Folino currently imports only parseable sheet-music formats (MuseScore, MusicXML,
MIDI). This adds **PDF** as an importable score format. A PDF is treated as a
first-class library item — it lives in the same library, supports tags,
favorites, soft-delete, CloudKit sync, PencilKit annotation, and the rich
page-turn reader — but it is **not parsed into a musical `Score`**. Because there
is no underlying notation model, the features that require one (playback, staff
size, system breaks, horizontal mode, transpose, per-part visibility, clef
override) are unavailable and hidden in the reader. A **"PDF" badge** in the
library and reader signals this to the user.

Out of scope (explicitly deferred): parsing the PDF into notation, playback
cursor over a PDF, OCR/OMR. A future plan may have `swift-sheet-music` locate
systems on the PDF page and synthesize playback; this design does not.

## Goals

- Import a `.pdf` file via the same paths existing formats use (share extension,
  document picker, `onOpenURL`).
- Treat it as a normal `ScoreItem` (library list, tags, favorites, soft-delete,
  CloudKit, recently-deleted, info editing, export).
- Render it in the reader with **page mode** (rich page-turn parity with scores)
  and a **vertical continuous-scroll** mode. No horizontal mode.
- Support **PencilKit annotation** on PDF pages, anchored to page-relative
  coordinates, sharing the existing annotation persistence / sync / trash.
- **Hide** the inspector/toolbar affordances that don't apply to a PDF, with a
  one-line explanation, so the user understands why.
- Show a **"PDF" badge** in the library row and the reader header.

## Non-Goals

- Parsing PDF content into a `Score` (no notes, measures, parts, or tempo).
- Playback, transpose, tuning, staff-size, system-break, clef, per-part
  visibility — none of these apply to a PDF and are not faked.
- Horizontal reader mode for PDFs.
- OCR / OMR / playback cursor on PDF — future work, designed around but not built.

## Key Decisions (from brainstorm)

1. **Reuse `ScoreItem`** — no separate table/type. PDF-ness is **derived from the
   file extension** via `ScoreFormat` (`item.format == .pdf`); no new stored
   field on `ScoreItem`.
2. **Reader modes for PDF:** page + vertical continuous scroll (no horizontal).
3. **Disabled-settings UX:** hide the inapplicable inspector tabs/rows and reader
   toolbar actions entirely, plus a one-line note in the inspector.
4. **Annotation anchoring:** page-relative coordinates as a **new anchor kind**,
   extending the existing `AnnotationLayer` (not a separate store).
5. **Rendering:** reuse `ScoreScrollHost` / `PagedScoreContainer` for layout,
   gestures, zoom, page-turn, and PencilKit integration. Use **PDFKit only as a
   rasterizer** (`PDFPage.draw(with:to:)` → `CGImage`), **not** `PDFView`. This
   keeps page-turn / zoom / annotation behavior identical to scores and avoids a
   second, divergent reader/annotation/gesture/zoom pipeline.

### Why not full `PDFView`

`PDFView` would give tiled rendering and continuous+paged modes for free, but it
owns its own internal scroll view, zoom machine, and gesture recognizers. That
breaks parity with the app's standardized reader interaction contract (custom
`scaleEffect` zoom with `maximumZoomScale = 1`, tap-zone page turn, iPad edge-tap
insets, viewport-pinned `PKCanvasView` mirroring scroll/zoom). Adopting it would
fork the annotation, zoom, and gesture code into two pipelines — contrary to the
iOS/Android parity rule of not duplicating logic — and make PDF page-turn feel
different from score page-turn, which is the opposite of what we want.

## Architecture

### 1. Domain — format & item

- **`ScoreFormat`** (`Packages/Domain/.../ScoreFormat.swift`): add a `.pdf` case;
  canonical extension `pdf`. Update `detect(filename:)` to return `.pdf` for
  `.pdf` (currently intentionally returns `nil`). Remove/replace the
  "deferred to OCR" comment.
- **`ScoreItem`**: unchanged shape. PDF items have `lengthBeats = 0` and
  `defaultTempoBpm = 0` (unused — playback is hidden). `contentHash` (SHA-256)
  and `sizeBytes` are computed normally and used for duplicate detection. Title
  comes from the filename, exactly as for parseable formats — the PDF `/Title`
  metadata is read but deliberately not used, because exporters bake their own
  internal project name into it (a MuseScore export arrives as
  `/Title = "アイデア#0131"`) and the filename is what the user chose. Composer
  and other credits are left empty and remain freely user-editable as library
  labels via the existing info screen.
- **`ScoreSourceKind.pdf`** already exists and `displayLabel` already maps it to
  `"PDF"` — reused.

### 2. Reader capability gating

Add a single source of truth on `ReaderViewModel`:

```swift
struct ReaderCapabilities {
    var canPlay: Bool          // false for PDF
    var canChangeLayout: Bool  // false for PDF (staff size, breaks, etc.)
    var canTranspose: Bool     // false for PDF
    var canEditStaves: Bool    // false for PDF (visibility, clef)
    var availableLayoutModes: [ReaderLayoutMode]  // PDF: [.page, .vertical]
    var canAnnotate: Bool      // true for both
}
```

Inspectors and the reader toolbar read these flags instead of checking the format
inline. When `swift-sheet-music` later supports PDF playback, only the place that
builds `ReaderCapabilities` changes.

- PDF hides: the playback toolbar button, `PlaybackInspectorScreen` tab, and in
  `VisualInspectorScreen` the staff-size stepper, honor-layout-breaks, collapse
  multi-measure rests, show-invisibles, per-part visibility, clef overrides,
  transpose, A4/tuning.
- PDF keeps: layout-mode picker (page / vertical only), PencilKit annotation
  tools, page navigation, info editing, favorite/tag, export (shares the original
  PDF file unchanged).
- **One-line note** at the top of the (now thin) `VisualInspectorScreen` when the
  item is a PDF: e.g. "PDF 楽譜では表示調整・再生は利用できません" (localized).

### 3. Reader rendering

- **`LoadState` generalization:** the reader's loaded state becomes
  `case score(Score)` / `case pdf(PDFDocument)` (replacing the `Score`-only
  loaded case). `ReaderViewModel` branches at load time: when `item.format == .pdf`
  it opens the PDF document directly from `localFileName` and does **not** call
  the gateway's `loadScore`. Corrupt / zero-page PDFs route to the existing
  `failed(error)` state.
- **`PDFPageProvider`** (new, Reader-internal) — the PDF analog of the
  swift-sheet-music draw-program producer:
  - Opens the `PDFDocument` for the item.
  - `image(pageIndex:targetScale:) -> CGImage` rasterizes a page at a target
    scale via `PDFPage.draw(with:to:)`.
  - **Windowed cache:** keeps only the visible page ±N pages as `CGImage` in an
    `NSCache` (evicted on memory warning). Memory stays bounded regardless of
    document length.
  - **Re-rasterize on zoom commit:** on pinch-end, re-render the visible page(s)
    at the new effective scale so content stays crisp (mirrors the score
    reader's "bake on commit"). During the pinch, `scaleEffect` upscales the
    cached bitmap transiently.
- **`ScoreScrollHost` / `PagedScoreContainer` reuse:** where scores host a
  `Canvas { draw-program }`, PDF hosts a `Canvas` that draws the page `CGImage`.
  - **Page mode:** page boundaries come from the PDF's page count (1 physical
    page = 1 reader page) instead of `LayoutDocument` system pagination. Tap-zone
    page turn, zoom reset, and the turn animation are reused unchanged.
  - **Vertical continuous:** PDF pages are stacked vertically and scrolled,
    fitted to viewport width. Distinct from score vertical *reflow*, but rides the
    same `ScoreScrollHost` scroll infrastructure.
- **Thumbnail:** the first page rasterized to fill the existing library-thumbnail
  slot (same frame the score first-system thumbnail uses).

### 4. Annotation — page-relative anchoring

Extend the existing annotation model rather than adding a parallel store:

```swift
enum DrawingAnchorKind {
    case musical(MusicalAnchor)   // existing scores; survives reflow
    case page(PageAnchor)         // PDF; fixed-layout pages
}

struct PageAnchor {
    var pageIndex: Int
    var originX: Double   // normalized 0..1 within the page
    var originY: Double
}
```

- `DrawingAnchor` / `TextBoxAnchor` replace their `anchor: MusicalAnchor` field
  with `kind: DrawingAnchorKind`. Stroke geometry is normalized to page width so
  it scales with the rendered page. Because PDF pages never reflow, capture and
  display are near-identity (no projection math needed).
- **Persistence migration:** existing annotation rows/records all become
  `.musical`. The persistence schema and CloudKit record shape gain the
  page-anchor representation; a migration maps existing data to `.musical`. (The
  implementation plan must detail the GRDB schema change and the CloudKit field
  addition — additive, backward-compatible.)
- **`AnnotationCanvasView` reuse:** viewport-pinned `PKCanvasView`, scroll/zoom
  mirroring, pencil-only drawing policy — all unchanged. Capture branches: for a
  PDF, instead of `document.resolveAnchor(at:)` (which needs swift-sheet-music
  layout) it records `{ current page index, normalized viewport coordinate }`.
- Persistence, CloudKit sync, and Recently-Deleted reuse the existing annotation
  infrastructure with no second pipeline.

### 5. Import paths

- **`ShareImportPolicy.acceptedExtensions`**: add `"pdf"` so the share extension
  and document picker accept PDFs.
- **`LiveScoreFileGateway`**: add a PDF branch.
  - `detectFormat` resolves `.pdf` (via the updated `ScoreFormat.detect`).
  - `loadFileMetadata` returns a `ScoreFileSummary` for the PDF (page count as a
    length-ish metric, title from `/Title`, no tempo/parts). It must **not** throw
    `unsupportedFormat` for `.pdf` anymore.
  - `loadScore` is **not** used for PDF — the reader opens the document directly.
    Keep `loadScore` throwing for PDF (PDFs have no `Score`); the reader's PDF
    branch never calls it.
- **Two-stage import** (`prepareImport` → `commitImport`), staging directory, and
  duplicate resolution are reused unchanged. The committed file lives at
  `AppPaths.scoresDirectory/<id>.pdf` per the existing `localFileName` convention.

### 6. UI — "PDF" badge

- **Library row (`ScoreRow`):** when `item.format == .pdf`, show a small "PDF"
  pill, placed like the favorite-star overlay (corner of the thumbnail or beside
  the title), so PDFs are identifiable even when the composer line is empty.
  Literal text "PDF" (not localized — it's a fixed designation).
- **Reader header:** the same "PDF" badge near the navigation title, giving a
  persistent visual cue that explains why the settings are reduced.

## Data Flow

```
Import (.pdf)
  ShareImportPolicy accepts "pdf"
   → ScoreFileImporter.prepareImport
       detectFormat → .pdf
       SHA-256 + size + loadFileMetadata (page count, /Title)
       duplicate check by contentHash
   → commitImport (.importAsNew)
       move staged file → scores/<id>.pdf
       ScoreItem{ format=.pdf via extension, lengthBeats=0, tempo=0 }
       persist

Open in reader
  ReaderViewModel.load
   → item.format == .pdf
       open PDFDocument(localFileName)
       LoadState.pdf(document)
       ReaderCapabilities{ canPlay=false, canChangeLayout=false,
                           availableLayoutModes=[.page,.vertical], canAnnotate=true }
  ScoreScrollHost + PagedScoreContainer (page) / vertical stack
   → PDFPageProvider.image(page, scale)  // windowed NSCache, re-raster on zoom
   → Canvas draws CGImage
  AnnotationCanvasView (reused)
   → capture → PageAnchor{ pageIndex, normalized origin }
   → persist via existing AnnotationLayer store + CloudKit
```

## Error Handling

- **Corrupt / unreadable / zero-page PDF on open:** route to the existing reader
  `failed(error)` state with a user-facing message.
- **Corrupt PDF at import:** `loadFileMetadata` surfaces a parse failure through
  the existing import-error path (same UX as a malformed MusicXML).
- **Memory pressure during rendering:** `NSCache` eviction + windowed rendering
  keep the working set bounded; on warning, drop non-visible page bitmaps.
- **Duplicate PDF:** existing `contentHash` duplicate resolver (open-existing vs
  import-as-new) applies unchanged.

## Testing

- **Domain:** `ScoreFormat.detect("x.pdf") == .pdf`; canonical extension; PDF
  item derivation (`item.format == .pdf`).
- **Annotation model:** `DrawingAnchorKind` round-trips `.musical` and `.page`
  through persistence; migration maps legacy rows to `.musical`; `PageAnchor`
  normalization round-trips at a fixed page size.
- **Import (Infrastructure):** importing a fixture `.pdf` produces a `ScoreItem`
  with `format == .pdf`, correct `contentHash`, file at `scores/<id>.pdf`;
  duplicate detection by hash; corrupt-PDF import error.
- **Capabilities:** a PDF item yields `canPlay=false`, `canChangeLayout=false`,
  `availableLayoutModes == [.page, .vertical]`, `canAnnotate=true`; a score item
  yields the full set.
- **Rendering (lightweight):** `PDFPageProvider` returns a non-nil `CGImage` for a
  valid page and caches within the window; re-raster yields a larger bitmap at a
  higher scale. (Pixel-exact rendering is verified manually per the project's
  preview/manual-verification workflow, not in unit tests.)
- **Reader manual verification:** page-turn parity, vertical scroll, pinch-zoom
  sharpness after commit, PencilKit draw + persistence + reopen, badge presence,
  hidden settings — verified in the simulator / on device per project workflow.

New tests use Swift Testing; the import/persistence tests run via `xcodebuild
test` on the iPhone 17 Pro Max simulator per project convention.

## Android Parity

Per the iOS/Android parity rule, the **logic** added here must be shareable and
match iOS: `ScoreFormat.pdf` detection, the capability-gating model, the
page-anchor annotation representation, and the import flow are Domain/shared
concerns and should be lifted so Android reuses them rather than reimplementing.
Android-specific work (its own PDF rasterization via the platform renderer, the
Compose reader surface, file I/O) is deferred to a separate Android plan; this
spec is iOS-first but must not encode iOS-only assumptions into the shared logic.

## Open Implementation Details (for the plan)

- Exact GRDB schema change and CloudKit record-field addition for
  `DrawingAnchorKind`, plus the migration step.
- Where `ReaderCapabilities` is constructed and threaded to each inspector.
- The `LoadState` enum refactor surface and its call sites.
- Windowed cache size (N adjacent pages) and the zoom re-raster trigger point in
  the existing pinch-commit pipeline.
- Badge styling tokens (reuse existing pill/label styling if present).

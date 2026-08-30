# Annotated PDF export — design

2026-08-31. Lets a user hand someone else the score *with their handwriting on
it* — a PDF whose notation is still vector and whose ink is exactly what they
drew.

## The problem

Handwriting is the one thing folino keeps that never leaves the app. A user
marks up a score in the Reader — fingerings, breath marks, circled bars — and
every existing way out drops it:

- `LiveScoreShareService.prepareShare(item:format:)`
  (`Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift`)
  loads the score through the gateway and re-encodes it. `.pdf` goes to
  `ScorePDFRenderer` → swift-sheet-music's `PDFExporter`, which knows nothing
  about `AnnotationLayer`.
- `.mscz` / `.midi` / `.m4a` are notation and audio; ink has no representation
  in any of them.
- Nothing exposes the original PDF of a PDF-origin item at all, annotated or
  not.

So the annotations are visible on the iPad and nowhere else. A teacher cannot
send a marked-up part to a student; a player cannot print their own markings.

## What this covers, and what it does not

**In scope.** A share format that produces a PDF with the item's freehand
annotations baked in, for both of the documents a user can annotate: the
engraved notation, and — for a PDF-origin item — the original PDF's pages.

**Deliberately out of scope.**

- **Text boxes.** `AnnotationLayer.textBoxes` exists in the model, but
  `AnnotationSaveCoordinator.persist` encodes `textBoxes: []` unconditionally
  (see the note on `AnnotationLayers.remappingParts`), so no item in the wild
  has one. When they ship, they get placed by the same planner; nothing here
  forecloses it.
- **Android.** iOS only for now. The placement logic lands in the existing
  neutral core so that the Android half is a renderer and a PDF writer, not a
  second copy of the geometry. A `PARITY(android)` marker records the gap.
- **Editing the exported file.** The output is a flattened deliverable, not a
  round-trippable annotation format. Re-importing it yields a PDF-origin item
  like any other PDF.
- **Printing.** The system share sheet already offers Print for a PDF; no
  separate print path.
- **Any Pro / IAP gating.** The current release ships creation free on every
  platform and excludes IAP; this follows the same line.

## The two bases

An item can carry ink of two kinds, because it has up to two documents to draw
on. `DrawingAnchorKind` (`Packages/Domain/Sources/Domain/Models/DrawingAnchorKind.swift`)
already names them:

- `.musical(MusicalAnchor)` — pinned to `(measureIndex, tickInMeasure,
  partIndex, staffIndexInPart)` plus `sp` offsets, with the stroke geometry
  normalized to that anchor point and the layout's `sp`. Layout-independent by
  construction: it resolves into *any* engraving of the same score.
- `.page(PageAnchor)` — pinned to a page index of the original PDF, with the
  stroke geometry normalized to a fraction of that page's width.

A PDF-origin item that has been converted can hold both: the user can toggle
`ReaderDisplaySource` between the engraved notation and the original pages, and
annotate either.

**One export, one base.** Rather than pick a winner and silently drop the other
kind of ink, the share menu offers a row per base that actually carries ink:

| Item | Rows offered |
| --- | --- |
| Ordinary score, has ink | `PDF (annotated)` |
| Ordinary score, no ink | — |
| Unconverted PDF, has page ink | `Original PDF (annotated)` |
| Converted PDF item, musical ink only | `PDF (annotated)` |
| Converted PDF item, page ink only | `Original PDF (annotated)` |
| Converted PDF item, both | both rows |

The plain `PDF` row is untouched — "give me the clean engraving" stays
available, and a user who has annotated does not lose it.

The condition is a Domain pure function so iOS and Android cannot disagree:

```swift
public enum AnnotatedExportAvailability {
    public static func formats(
        hasMusicalInk: Bool,
        hasPageInk: Bool,
        hasOriginalPDF: Bool,
        isEngravable: Bool,
    ) -> [ScoreShareFormat]
}
```

`isEngravable` is false for an item whose bytes are still a PDF
(`ScoreItem.pdfOriginState == .unconverted`) — there is no notation to engrave,
so the engraved row cannot appear whatever the ink says. `hasOriginalPDF` is
`ScoreItem.originalPDFFileName != nil`.

`ScoreShareFormat` gains `.annotatedPDF` and `.annotatedOriginalPDF`, both with
`canonicalExtension == "pdf"`. `ScoreShareFormat.matching(for:)` never returns
either — an annotated export is by definition not the source's own bytes.

## Where the ink goes: the planner

Placement is pure geometry over `DrawingAnchor` and `InkStroke`, so it belongs
in `ReaderAnnotationCore` — the target that already carries
`AnnotationAnchoringCore` and `PageAnchoringCore`, has no PencilKit and no
CoreGraphics, and is cross-compiled into `FolinoReaderJNI` for Android. A new
`AnnotatedExportPlanner` there composes the pieces that already exist:

```swift
public struct InkPlacement: Equatable, Sendable {
    /// Index of the destination page.
    public let pageIndex: Int
    /// Index into the `drawings` array that was planned — the caller decodes
    /// that drawing's own bytes.
    public let drawingIndex: Int
    /// Places the drawing's stored (normalized) geometry into the destination
    /// page's own coordinate space: points, origin top-left, y down.
    public let transform: StrokeTransform
}

public enum AnnotatedExportPlanner {
    /// Engraved base. `pages` describes the paginated layout: each entry is the
    /// document-space Y band the page covers plus the translation that maps
    /// document space into that page's own space.
    public static func planEngraved(
        drawings: [DrawingAnchor],
        resolver: AnchorResolving,
        pages: [EngravedPagePlacement],
    ) -> [InkPlacement]

    /// Original-PDF base. `pageFrames` are the destination pages' crop boxes
    /// in points, in page order.
    public static func planPaged(
        drawings: [DrawingAnchor],
        pageFrames: [CGRect],
    ) -> [InkPlacement]
}

public struct EngravedPagePlacement: Equatable, Sendable {
    public let startY: CGFloat          // document Y where this page begins
    public let usableHeight: CGFloat    // page height minus this page's margins
    public let offsetX: CGFloat         // margins.leading
    public let offsetY: CGFloat         // margins.top - startY
}
```

`planEngraved` resolves each `.musical` anchor, keeps it when the resolved point
falls in a page's `[startY, startY + usableHeight)` band, and returns that
page's `StrokeTransform` with `(offsetX, offsetY)` folded into the translation.
`planPaged` is `PageAnchoringCore.displayStrokeTransforms` with the destination
page rects — the normalization is a fraction of page width, so a stroke lands at
the right spot and the right size whatever the page's absolute size is.

**The planner returns a transform, not transformed geometry, on purpose.** A
pixel-erased stroke carries a PencilKit `mask` that `InkStroke` cannot represent,
so those drawings are stored as legacy `PKDrawing` archives
(`InkStrokePencilKitBridge.decodeStoredDrawing` reads both formats). Handing back
a transform lets the iOS renderer decode whichever format the drawing is in and
apply the transform with `PKDrawing.transform(using:)` — exactly what
`AnnotationAnchoring.displayPaged` already does for the Reader — instead of
silently dropping erased ink. `StrokeTransform` (uniform scale + translate) is
the same shape the Android JNI seam already consumes.

Neither function touches a graphics framework. Android's implementation of this
feature calls the same two functions and differs only in what it does with the
returned transforms.

**No staff filter.** Stored anchors are in source addressing; a PDF export
engraves the unfiltered score, so the two addressings coincide and the resolver
is used unwrapped. This is the same reason `AnnotationStaffFilter` exists on the
Reader path and is absent here — not an oversight.

## Getting the engraved page bands

`planEngraved` needs the pagination that the exported PDF will actually have.
swift-sheet-music exposes exactly this, deliberately: `PDFExporter.resolve(options:score:)`
is public and documented as *"Public so on-screen previewers can mirror the
geometry that the exported PDF will have"*, `PDFExporter.paginate(systems:page:policy:)`
is public *"so previewers can mirror the export layout"*, and `LayoutEngine.layout`
is public. So the export layout is reconstructed with public API:

```swift
let resolved = PDFExporter.resolve(options: options, score: score)
let layoutOptions = ScoreViewOptions(
    staffSize: resolved.staffSize, systemGap: options.systemGap,
    wrapToViewWidth: true, breakPolicy: options.breakPolicy,
    showsInvisibleElements: false,
)
let availableWidth = max(
    resolved.staffSize * 4,
    resolved.page.size.width
        - resolved.page.oddMargins.leading - resolved.page.oddMargins.trailing,
)
let document = LayoutEngine.layout(
    score: score, options: layoutOptions, availableWidth: availableWidth,
)
let pages = PDFExporter.paginate(
    systems: document.systems, page: resolved.page, policy: options.breakPolicy,
)
```

`document` doubles as the anchor resolver's layout (via
`LayoutDocumentAnchorResolver`), and each `PageBatch.startY` plus
`resolved.page.margins(forPageIndex:)` gives an `EngravedPagePlacement` — the
translation is `(margins.leading, margins.top - startY)`, which is literally
what `PDFPageView` applies to its `Canvas`.

**This mirrors five lines of `PDFExporter.export`'s body, and that is the one
place this design can drift.** Two guards, because a silent drift here means ink
in the wrong place, which is worse than no ink:

1. **Runtime.** After the base PDF is rendered, compare its page count and
   media box against the plan. On any mismatch, return the base PDF **without
   ink** rather than stamping at coordinates that are known to be wrong. The
   share still succeeds; it just isn't annotated.
2. **Test.** A unit test exports a multi-page fixture through the real
   `ScorePDFRenderer` and asserts the plan agrees with the produced document,
   so a swift-sheet-music bump that changes pagination fails the build rather
   than shipping.

Adding a `plan()` entry point to swift-sheet-music would remove the duplication
outright and is the better end state, but it puts an ssm release on this
feature's critical path for five lines that two guards already cover. Left as a
follow-up.

## Rendering the ink

`PKDrawing.image(from:scale:)`, cropped to the ink's bounds, drawn into the PDF
page. This is the same renderer the Reader already uses for static ink
(`StaticInkLayer`), so the export looks like the screen — pressure taper, marker
blending, pencil texture and all — with no second ink renderer to keep in sync.

The ink is raster; **the notation is not**. `PDFExporter` draws the SwiftUI
score straight into a `CGPDFContext` (`ImageRenderer.render { _, drawInto in
drawInto(pdfContext) }`), and `PDFPageView`'s own comment says so: *"the PDF
uses the exact same glyph / staff / spanner pipeline as the on-screen
`ScoreView` — vector output"*. Stamping an image on top adds one image XObject
per annotated page and leaves the page's existing content stream alone.

Scale is 4×, i.e. ~288 dpi against the PDF's 72 dpi user space — enough for
print, and cheap because only the ink's bounding box is rasterized, not the
page. A page with a single circled bar costs a few kilobytes.

## Composition

One code path for both bases:

1. Obtain the base PDF bytes — engraved: the existing `ScorePDFRenderer`;
   original: read `item.originalPDFFileName` from the scores directory.
2. Open it as a `CGPDFDocument`.
3. Into a fresh `CGPDFContext`, for each page: `beginPDFPage` with the source
   page's media box, `drawPDFPage(sourcePage)`, then draw the ink image for that
   page, then `endPDFPage`.

`drawPDFPage` replays the source page's content stream into the destination, so
vector stays vector and embedded fonts stay embedded. It is the standard
watermarking shape.

For the original-PDF base the page frames come from each page's crop box, and
`PageAnchor.pageIndex` indexes the same document the Reader displayed, so the
mapping is exact rather than reconstructed.

## Module placement

Projecting musical ink needs swift-sheet-music's `LayoutDocument`, and
rasterizing it needs PencilKit. Both live in the Reader target today, together
with `LayoutDocumentAnchorResolver` and `InkStrokePencilKitBridge`, and
`Infrastructure → Feature` is forbidden. So:

- **The renderer lives in the `Reader` target**, under
  `Sources/Reader/Annotation/Export/`, beside the `AnnotationAnchoring` logic it
  mirrors. A separate target was considered and rejected: it would buy tidiness
  at the cost of moving two files and widening their access, while `Reader`
  already hosts exactly this kind of non-UI anchoring logic. `Reader` gains one
  dependency, `SheetMusicPDF`.
- **New Domain protocol:**

  ```swift
  public protocol AnnotatedPDFRendering: Sendable {
      func renderAnnotatedEngravedPDF(
          score: Score, title: String, drawings: [DrawingAnchor],
      ) async throws -> Data
      func renderAnnotatedOriginalPDF(
          basePDF: Data, drawings: [DrawingAnchor],
      ) async throws -> Data
  }
  ```

  `Reader`'s `ReaderAnnotatedPDFRenderer` implements it;
  `LiveScoreShareService` takes it as `any AnnotatedPDFRendering` and never sees
  a Feature type. This is the same seam `ScorePDFRenderer` and
  `ScoreAudioExporter` already use.
- `LiveScoreShareService` additionally takes `any AnnotationStore`, so
  `availableFormats(for:)` can ask whether the item has ink. The menu already
  loads per-item options lazily on first open, so this is one indexed read at
  menu-open time, not per row at list time.
- `AppBootstrap` wires the new renderer in, next to `CoreGraphicsPDFRenderer`.
  `project.yml` needs no dependency edit: the App target links `package: Reader`
  with no `products:` filter, so a new product is picked up automatically.

The resulting edge set stays inside the documented architecture: App → Feature,
App → Infrastructure, Infrastructure → Domain, Feature → Domain. Nothing new
points sideways.

## Filenames

`ScoreExportNaming` gains the suffixes so Android produces the same names:

- `.annotatedPDF` → `<sanitized title> (annotated).pdf`
- `.annotatedOriginalPDF` → `<sanitized title> (original annotated).pdf`

Distinct from the plain `.pdf` export's `<sanitized title>.pdf`, which matters:
all three land in the same share temp directory, and a collision would have one
overwrite the other.

## What the user gets, stated plainly

**The ink reflows.** Musical anchors are relative to a measure and a staff, not
to a pixel, so ink is re-projected into the *export's* page layout, which is not
the layout the user was looking at when they drew it. A circle around bar 12
stays a circle around bar 12, scaled by the export's `sp`. This is the contract
the app already honors between Reader layout modes — the same ink already
follows the score between vertical, horizontal and paged views. It is not
pixel-identical to the screen, and the spec says so rather than implying
otherwise.

Consequences worth naming:

- A stroke whose anchor cannot resolve in the export layout is dropped, exactly
  as in the Reader. In practice this means ink anchored to a measure that no
  longer exists.
- A stroke that spans a system break in the export may straddle a page boundary
  and clip at the edge. This is the existing rigid-anchor degradation recorded
  for paged reading, not a new one.
- Page-anchored ink does not reflow at all — the original PDF's pages are fixed
  by definition, and the export is the same document.

## Testing

**Domain (Swift Testing, host).**

- `AnnotatedExportAvailability.formats` across the six rows of the table above,
  including the unconverted-PDF case where the engraved row must not appear.
- `ScoreExportNaming` suffixes, including sanitization and the 100-character
  cap interacting with the suffix.

**ReaderAnnotationCore (host).**

- `planEngraved` assigns a stroke to the page whose band contains its resolved
  anchor, and translates it by that page's offsets; a stroke whose anchor does
  not resolve is dropped, not mis-placed.
- `planPaged` round-trips: normalize a stroke to a page frame via
  `PageAnchoringCore.capturePage`, plan it against a different-sized page, and
  the result is the same fraction of the page.
- Empty inputs and an out-of-range `pageIndex` produce no placement rather than
  trapping.

**Reader (iOS simulator).**

- The layout mirror agrees with the real export: render a multi-page fixture
  through `CoreGraphicsPDFRenderer`, and assert the planner's page count and
  page size match the produced `CGPDFDocument`. This is the drift guard.
- **The notation is still vector.** Parse the output and assert the page's
  resource dictionary carries a `/Font` entry, and that the page is not a single
  full-page image. This also runs against the *un*annotated export, so it fails
  if swift-sheet-music ever starts rasterizing — the premise this whole design
  rests on.
- An annotated page gains an image XObject; a page with no ink does not.
- The mismatch guard: feed a plan whose page count disagrees with the base PDF
  and assert the base bytes come back unstamped.

**Infrastructure.**

- `LiveScoreShareService.availableFormats` includes / excludes the annotated
  rows according to what the injected `AnnotationStore` returns.
- `prepareShare` writes to the suffixed filename and does not collide with a
  plain `.pdf` share of the same item.

**Manual QA on device** (the ink parts previews and the simulator cannot show —
PencilKit ink does not appear in simulator screenshots):

1. Annotate a multi-page score in the Reader, share `PDF (annotated)`, open the
   result in Files. Ink present on the right bars, notation crisp at 400 % zoom.
2. Same, printed — ink legible.
3. A converted PDF item annotated on *both* display sources: two rows appear,
   each carries its own ink and only its own.
4. A score with no ink: no annotated row.

## Forward compatibility

- **Android** implements `AnnotatedExportPlanner`'s callers only: androidx.ink
  renders the returned strokes to a bitmap, `android.graphics.pdf.PdfDocument`
  writes the pages. The planner, the availability rule and the filenames are
  already shared. A `PARITY(android)` marker sits where the Android share sheet
  filters the annotated rows out, so the ledger tracks it and deleting the
  marker deletes the row.
- **Text boxes** become a third input to the planner returning a text placement
  alongside `InkPlacement`; the composition step draws them with CoreText. No
  signature this design pins forecloses that.
- **A vector ink path**, if the raster ever proves insufficient, replaces only
  the rendering step: the planner already hands over per-point geometry and
  widths, which is all a variable-width outline needs. `AnnotatedPDFRendering`
  is the seam that isolates it.
- **An ssm `plan()` API** collapses the mirrored five lines and retires the
  runtime guard. It does not change any type this design introduces.

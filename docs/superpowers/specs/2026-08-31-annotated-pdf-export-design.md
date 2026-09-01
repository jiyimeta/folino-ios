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

The runtime guard compares the produced PDF's page count and every page's media
box against the plan. Those catch a pagination change. They do **not** catch a
change to the three mirrored lines that determine *within-page* geometry
(`ScoreViewOptions`, `availableWidth`, `LayoutEngine.layout`): if swift-sheet-music
changed how `availableWidth` is derived, every system could shift horizontally
while the page count and page size stayed identical — the guard would pass and the
ink would land in the wrong column. Closing that properly means removing the
mirroring rather than guarding it harder, i.e. adding a `plan()` entry point to
swift-sheet-music that returns the layout and pagination the exporter is about to
use, which the existing "follow-up" note already proposes.

## Rendering the ink: a PDF annotation, drawn as vector

**Revised 2026-08-31, after device QA.** The original design flattened a
PencilKit raster into the page body. Two findings replaced it.

### What Apple actually does

A PDF exported from Apple Books, with Pencil markup on it, was taken apart. Per
page it carries exactly one annotation, and the ink is **not** in the page body
— rendering the page's content stream and rendering it through PDFKit differ by
tens of thousands of pixels. The annotations are:

- `/Stamp`, whose Apple-private `/PPK` value is base64 beginning `crdt` — the
  magic of `PKDrawing.dataRepresentation()`. The editable PencilKit drawing is
  stored verbatim.
- `/Square`, carrying `/AAPL:AKAnnotationV2`, an `NSKeyedArchiver` plist, for
  shape markup.

Both have an `/AP` appearance stream, and every one of those streams contains
**zero vector path operators** — just `Do` against an image XObject.

So Apple keeps the ink twice: a raster in `/AP` for anyone to look at, and the
PencilKit blob in a private key so its own apps can hand it back to PencilKit
and edit it. That is why ink drawn in Books can be erased from Files on another
device — the eraser is PencilKit, not a PDF operation, and it works because the
strokes travelled alongside the picture of them.

Two things follow. Raster ink was never the wrong call — Apple rasterizes too.
And erasability comes from the ink being an **annotation object** rather than
part of the page, which is an independent decision from how it is drawn.

What does *not* follow is that folino can join in. The `crdt` container is
private and unreproducible from public API; imitating the rest of Books' shape
was tried and measured not to help. See "No PencilKit blob rides along" below.

### What folino does

**The ink is an annotation, one per stroke.** That is the property this feature
was asked for: a reader can select a mark and delete it in Preview, or in any
standard PDF editor, because removing an annotation is a first-class PDF
operation and the page body is untouched.

Be precise about the limit. This is *not* the Files/Books experience of erasing
a stroke with the Pencil — that is PencilKit editing a drawing Apple stored
privately, and folino cannot produce that container (below). What ships is
selection and deletion of whole strokes as PDF objects.

One annotation **per stroke**, not per page, and that is load-bearing:
`PDFAnnotation` carries a single `/C` and a single border width, so a page
consolidated into one annotation would render all of its marks in one colour and
one width for every viewer. Per-stroke annotations keep each mark's own colour
and width, which is the visible difference a user notices on a page marked up in
red and yellow.

**Its appearance is drawn as vector**, not as a raster. Here folino departs from
Apple deliberately. `PKDrawing.image(from:scale:)` proved unusable: on a real
iPad it returned a fully transparent raster for the user's own strokes while
rendering correctly on the simulator, and twelve hypotheses — invocation style,
tool, colour, storage format, stroke mask, point count, timestamp collisions —
were each falsified on device without finding the cause. The only oracle
available for that call disagrees with the hardware, so no test over it can be
trusted. Vector drawing from `InkStroke`'s own per-point geometry is
deterministic, identical on every destination, and testable.

The visible cost is pressure taper and marker blending, which a single-width
vector stroke approximates rather than reproduces. Monoline — a constant-width
tool — is exact.

**No PencilKit blob rides along, and nothing is locked.** An earlier revision
wrote `PKDrawing.dataRepresentation()` under Apple's `/PPK` key (plus `/PPKType`
and Books' `/F = 644` locking, with the whole page consolidated into one
`/Stamp`), betting that Apple's markup would then adopt folino's ink as an
editable drawing. The bet was settled by experiment rather than left open: taking
one of Apple's own annotated PDFs and swapping **only** the `/PPK` container for
one folino can produce left the markup unrecognized, while imitating every other
field changed nothing. Apple's format requires a private `crdt` container that no
public PencilKit API emits — `dataRepresentation()` produces a `wrd`-prefixed one
— so the blob was inert here and cost roughly 21 KB per page. It is gone, and so
is the locking: `/F` locking exists to keep generic editors away from markup whose
editable truth lives in a private payload, and folino has no such payload. Being
deletable in other editors is the point, not something to defend against.

Decoding the `crdt` container is a separate investigation with its own branch and
its own notes — **see `docs/engineering/crdt-ink-format/`** before spending any
time re-deriving this. If it ever yields a writable format, it slots in as an
extra key on the same annotations; nothing in this design forecloses it.

## Composition

Both bases take the same shape, and neither rewrites the page body:

1. Obtain the base PDF bytes — engraved: the existing `ScorePDFRenderer`;
   original: read `item.originalPDFFileName` from the scores directory.
2. Open it as a `PDFDocument`.
3. For each placement, add one `/Ink` `PDFAnnotation` to its page: bounds from
   the stroke's extent, colour and border width from the stroke itself, and the
   appearance drawn as vector paths from the placed `InkStroke`. No private
   keys, no flags beyond PDFKit's defaults.
4. `dataRepresentation()`.

The original-PDF base gains the most from this. The previous design replayed
every page's content stream into a fresh context, which forced it to reproduce
`/Rotate` by hand and risked the hairline inflation `PDFPageRasterizer`
documents. Adding annotations leaves the original bytes alone, so a rotated
page, an unusual media box, and the file's own existing annotations all keep
working with no code of ours involved.

Page frames still come from each page's media box, and `PageAnchor.pageIndex`
indexes the same document the Reader displayed, so the mapping stays exact.

Annotation coordinates are page space with a bottom-left origin, while
placements are page-local and y-down; the conversion is the one the composer
already performed on a rect, now applied per point.

## Module placement

Projecting musical ink needs swift-sheet-music's `LayoutDocument`, and decoding
and placing the stored strokes needs PencilKit. Both live in the Reader target
today, together with `LayoutDocumentAnchorResolver` and
`InkStrokePencilKitBridge`, and
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
- An annotated page gains one `/Ink` annotation per stroke, carrying that
  stroke's own colour and width; a page with no ink gains none. The annotations
  carry no `/PPK`, no `/PPKType`, no `/AAPL:AKExtras`, and no lock flags, so a
  generic editor can still delete them.
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
5. A page marked in two different colours and widths: both survive as drawn —
   this is what one annotation per stroke buys.
6. A mark drawn in the headroom *above* the top staff of page 1: it exports,
   rather than being silently dropped.
7. The exported file opened in Preview on a Mac: a mark can be selected and
   deleted. It cannot be Pencil-erased in Files — see "No PencilKit blob rides
   along".

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
- **A variable-width outline**, if the single-width vector stroke's flat taper
  ever proves insufficient, replaces only the rendering step: the planner already
  hands over per-point geometry and widths, which is all such an outline needs.
  `AnnotatedPDFRendering` is the seam that isolates it.
- **An Apple-compatible PencilKit payload**, if `docs/engineering/crdt-ink-format/`
  ever produces a writable container, is an extra key on the annotations this
  design already writes — no change to the planner, the composer's geometry, or
  any type here.
- **An ssm `plan()` API** collapses the mirrored five lines and retires the
  runtime guard. It does not change any type this design introduces.

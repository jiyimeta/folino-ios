# PDF Import on Android — Design

- Date: 2026-07-27
- Folino branch: `worktree-pdf-import-android` (off local `main` `551bb9a5`)
- swift-sheet-music branch: `worktree-pdf-import-android` (off local `main` `9e4036b5`)
- Status: design approved, implementation plan pending

## 1. Goal

Bring PDF import to Folino for Android at full parity with iOS: a PDF is a
first-class library item, read in the Reader as the **original page images**,
annotatable, and — once a background OMR parse succeeds — playable with a
cursor drawn on those same pages.

This is the last remaining iOS→Android parity gap
(`docs/product/` describes the feature; the iOS design lives in
`docs/superpowers/specs/2026-06-26-pdf-import-design.md`).

### Non-goals

- PDF *export* on Android — already shipped (`PdfScoreRenderer`), untouched here.
- Library thumbnails — a separate, format-agnostic feature.
- Improving OMR accuracy. The decode pipeline is shared and stays as-is.
- Raster / scanned PDFs. The importer is a vector content-stream interpreter;
  a scanned PDF displays and annotates but never becomes playable.

## 2. What already exists (verified 2026-07-27)

| Layer | State |
| --- | --- |
| ssm decode | `SheetMusicPDF` builds for Android. `Import/PDFReader/` is a Foundation-only pure-Swift PDF reader; `PDFImporter+SwiftReader` drives the same shared interpreter the Apple `CGPDFScanner` front-end drives, so both platforms produce identical `WalkedContent`. |
| ssm JNI | `SheetMusicAndroidJNI/PDFImportBridge.swift` exposes `nativeLoadScoreFromPDF(bytes) -> handle`; Kotlin `ScoreHandle.loadFromPDF` wraps it. |
| ssm geometry | `PDFScoreGeometry` + `PDFGeometryCollector` compile on Android, but `parseWithGeometry` exists **only** in `PDFImporter+AppleEntry` — the Android entry offers `parse` alone. |
| Folino import | `LibraryAndroidStore.importScore` hardcodes `MSCZReader.parse` and `<id>.mscz`. |
| Folino reader | `ReaderViewModel.scoreFile()` hardcodes `<id>.mscz`. Display is `DrawProgram`-based (`ReadyScore` / `HorizontalScore` / `PagedScore`) with an androidx.ink annotation overlay wired for vertical, horizontal and page modes. |
| Rasterization | Nothing. Android framework `PdfRenderer` covers it with **no new dependency**. |

The earlier assumption that Android would need a Kotlin PDF walker (PdfBox-Android)
and a new `SheetMusicPDFCore` package is obsolete: ssm's Android port §A–§E
(`docs/superpowers/specs/2026-07-12-pdf-import-android-design.md`, commits
`52072d87`…`3d5edfbf`) already solved it in Swift.

## 3. Shape of the change

Two layers, mirroring iOS exactly:

1. **Display layer** — the imported PDF is rasterized by `PdfRenderer` and shown
   as-is. Available immediately on open; needs no parse.
2. **Playback layer** — after open, a background OMR parse produces a `Score`
   plus a `PDFScoreGeometry` side-car. On success the transport lights up and a
   cursor is drawn *on the original PDF pages*; taps on the page seek.

The Reader shell (top bar, transport, inspector, FAB, annotation surface,
auto-follow, A–B repeat, mixer, playlist continuation) is shared with the score
path. Only the content surface differs. PiP is the one shell feature a PDF does
not get — see §7.2.

The rejected alternative was to re-engrave the OMR result and show that instead
of the PDF. It needs almost no new plumbing, but it destroys the reason to import
a PDF at all — seeing your own page — and diverges from iOS behavior, which the
parity rule forbids.

## 4. Import, storage, library

### 4.1 Accepted-extension gate

`Domain.ShareImportPolicy.acceptedExtensions` already contains `"pdf"`. Kotlin's
`share/ShareImport.kt` duplicates the set as a literal, carrying a
*"WARNING: must be kept in sync"* comment. Rather than adding `"pdf"` to the
duplicate, expose the Domain set through the Library JNI and delete the Kotlin
literal. One source of truth, and the next format addition can't drift.

`AndroidManifest.xml` gains `application/pdf` on the `SEND`, `SEND_MULTIPLE` and
`VIEW` intent-filters. The Library "+" picker already launches with `*/*`.

### 4.2 Import

`LibraryAndroidStore.importScore` branches on `ScoreFormat.detect(filename:)`:

- **not pdf** — unchanged (`MSCZReader.parse`).
- **pdf** — *no OMR at import time*. Read metadata only and derive the display
  fields by the same rule iOS uses in `LiveScoreFileGateway.pdfSummary`: the
  `/Title` document attribute when present, else the filename stem; musical
  fields empty.

iOS reads `/Title` via PDFKit. Android needs an equivalent that does not run the
decode pipeline, so ssm gains a small entry — `PDFImporter.summary(pdfData:)`
returning page count + document attributes — implemented over the existing
pure-Swift `PDFReaderDocument`. Both platforms then feed the shared
`ScorePresentation.displayFields`, so titles match by construction.

Failure to open the PDF yields the existing `score_import_failed` analytics event
with `reason: "parse_failed"`, and the existing Toast.

### 4.3 Storage

Managed copy is named `<id>.pdf` — the same `"<id>.<canonicalExtension>"`
convention iOS uses. **The Room schema does not change**: `localFileName` already
carries the format in its extension, so there is no migration and no risk to
shipped libraries.

`ReaderViewModel.scoreFile()` stops hardcoding `.mscz` and resolves the record's
`localFileName` instead.

### 4.4 Library row

A "PDF" marker on the row, same information as iOS. Presentation follows Material
conventions (a label in the row's metadata line) rather than copying the iOS badge
styling — per the parity rule, content matches, placement adapts.

## 5. Display

### 5.1 Rasterization

`android.graphics.pdf.PdfRenderer` (framework, API 21+, no dependency added).

`PdfRenderer` allows only one open page at a time, so all access is serialized
through a single dispatcher. Pages are cached in a window around the current page,
mirroring iOS's `PDFPageProvider`; pages outside the window are evicted.

Zoom reuses the score surface's two-stage scheme: `scale` tracks the fingers and
is applied as a layer transform during the gesture, while `rasterScale` is the
resolution the bitmaps were produced at. Exactly one re-raster happens when the
fingers lift. Without this split, every pinch frame would re-render every visible
page.

(The iOS hairline-inflation bug — CoreGraphics applying a 0.75pt stroke floor —
is Apple-specific. Android renders through pdfium. Line weight is still checked
by eye on device.)

### 5.2 State and screens

`ReaderState` gains `ReadyPdf(pageCount, pageSizes)`; the existing `Ready` case
stays `DrawProgram`-only.

Two new files under `FolinoReaderAndroid`, matching iOS's `Screens/PDF/`
one-for-one: a vertical-continuous surface and a paged surface. `ReaderScreen.kt`
(already 2377 lines) receives only the branch point — everything PDF-specific
lives in the new files.

### 5.3 Capability gating

PDFs offer page and vertical modes only; horizontal is unavailable. Transpose,
staff size, voice and clef controls are hidden. The decision comes from Domain
`ReaderCapabilities.forPDF`, crossing through `FolinoReaderJNI` as a wire struct
of the five capability fields — Kotlin never re-derives it from the format. The
inspector shows the same one-line explanation iOS shows, placed per Android
inspector conventions.

## 6. Annotation

Strokes on a PDF anchor to `.page(PageAnchor)` — page index plus geometry
normalized to a fraction of that page's width — identical to iOS, so the stored
JSON is the same on both platforms and a future sync reads either.

iOS's `PDFAnnotationAnchoring` is typed in PencilKit, but its substance (which
page a centroid belongs to, the normalize/display transforms, page partitioning)
is pure geometry. **Lift that into `ReaderAnnotationCore`** — already the
platform-neutral home for the musical-anchor equivalent — operating on the shared
`InkStroke`. iOS keeps only the PencilKit conversion; Android calls the same core
through `FolinoReaderJNI`.

Rendering reuses the existing androidx.ink overlay, placed over the page frame
with `canvas.concat`, exactly as page-mode score annotation already does.

## 7. OMR playback

### 7.1 swift-sheet-music additions

1. `parseWithGeometry(pdfData:)` on the Android entry — the Apple version with
   `walkWithSwiftReader` substituted for `walkDocument`. `PDFGeometryCollector`
   and `PDFScoreGeometry` already build for Android.

2. Geometry JNI in `SheetMusicAndroidJNI`, in the same hand-written-codec style
   as the existing `nativeCursorFrame` / `DecodedFrameCodec`:

   - `nativeLoadScoreWithGeometryFromPDF(bytes) -> handle`
   - `nativePdfCursorRect(handle, cursor) -> page index + rect`
   - `nativePdfHitTest(handle, page, x, y) -> cursor`
   - `nativePdfPageSizes(handle)`
   - `nativePdfDiagnostics(handle)` — severity / location / message
   - `nativeReleasePdfGeometry(handle)`

   iOS flips ssm's y-up coordinates to **top-left-origin, y-down** in its
   Infrastructure adapter before they reach the Reader. Android performs the same
   flip **on the Swift side**, so Kotlin receives values with iOS semantics and
   no coordinate convention is re-implemented per platform.

The geometry stays behind the handle; only a rectangle or a cursor ever crosses
the boundary. Shipping the whole geometry to Kotlin would mean re-implementing
cursor lookup and hit-testing there, which the parity rule forbids.

### 7.2 Folino wiring

Open shows the document immediately. In parallel, a background thread runs
`nativeLoadScoreWithGeometryFromPDF`. The reader tracks the same four states iOS
tracks (`idle` / `parsing` / `ready` / `unavailable`) as a Kotlin enum. The state
value itself is presentation state, but the derived question "can this session
play right now?" (`canPlay || pdfReady`) is a rule, so it moves into a shared
Domain function that both platforms call — iOS directly, Android through
`FolinoReaderJNI`.

On success the parsed score's handle is published through the existing
`_scoreHandle` path, so transport, seek bar, A–B repeat, mixer, metronome,
count-in and playlist continuation all work with no further wiring.

PiP is the exception, and deliberately so: its content view renders
`horizontalProgram()` — notation re-engraved from the parsed score — which is
exactly the substitution this design rejects everywhere else. A PDF therefore
stays PiP-ineligible. Making it eligible would mean giving PiP a PDF-page
renderer of its own, which is out of scope here.

Only the cursor differs: instead of `nativeCursorFrame`, the reader calls
`nativePdfCursorRect` and projects the rect into the page's frame in content
space. Auto-follow feeds the same rect into the existing keep-in-view JNI. A tap
on the page resolves through `nativePdfHitTest` and seeks.

While parsing, the transport is visible but disabled. On failure the reader stays
display-only — the document is already on screen, so a parse failure is never
surfaced as a load error.

The OMR caveat follows iOS's `PDFPlaybackNotice` rather than being invented for
Android: one dialog shown at most once per opened document, with body copy that
differs between "playable, but OMR is best-effort" and "couldn't read this PDF";
an OK action plus a "don't show again" action backed by the shared preference key
`readerPdfPlaybackNoticeDismissed`; and permanent reachability by tapping the PDF
marker. iOS never lists individual importer diagnostics in the UI, so neither does
Android. Only the presentation adapts — a Material `AlertDialog`.

## 8. Verification

**swift-sheet-music**

- The 115 committed PDF unit tests and the corpus oracle must stay
  **byte-identical** — proof that adding the geometry path did not perturb decode.
- Android cross-compile of `SheetMusicPDF` + `SheetMusicAndroidJNI`.
- `Scripts/gate-android-tests.sh` for any new test that touches Apple frameworks.

**Folino**

- Swift package tests (Domain, Library, Reader) via `xcodebuild test` on the
  iPhone 17 Pro Max destination.
- Android unit tests; `Scripts/android-release-check.sh`.
- iOS app build, to prove the `ReaderAnnotationCore` lift didn't regress the
  iOS annotation path.
- On device (Pixel 8a): `installDebug` + launch, then import → display → page turn
  → pinch → annotate → reopen (persistence) → playback cursor → tap-to-seek.

Test material: MuseScore-exported vector PDFs, plus one scanned/raster PDF to
confirm the display-only fallback stays silent.

## 9. Sequencing

The ssm changes land first, on ssm `main`, and are published to mavenLocal as
`0.0.0-SNAPSHOT`; Folino then consumes them without a `-PssmVersion` override.
This keeps the two repositories from developing a version skew mid-feature.

Within the Android build, the order `gradle wirelet codegen → rebuild .so →
assembleDebug` is mandatory. Reversing it produces `.so` files whose `JNI_OnLoad`
lacks the new symbols, and the app crashes at launch.

## 10. Risks

- **PDF reader robustness.** The pure-Swift reader targets MuseScore/Qt output.
  Encrypted PDFs, object streams from other engravers, and ASCII85/LZW filters may
  fail. They must fail cleanly — display-only, no crash — which is the same
  contract iOS has.
- **Memory.** Full-page bitmaps at high zoom are large. The window size and the
  re-raster threshold need tuning on device; the eviction policy is the guard.
- **androidx.ink front buffer.** Known limit: the overlay goes invisible (and can
  ANR) past 65536px in a dimension. Tall PDF pages at high zoom can approach this,
  so the annotation surface must stay viewport-sized rather than content-sized.
- **`PdfRenderer` serialization.** One page open at a time means a slow page can
  stall the queue; rasterization stays off the main thread and is cancellable when
  the window moves.

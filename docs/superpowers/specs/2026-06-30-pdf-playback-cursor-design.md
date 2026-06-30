# PDF playback with on-PDF cursor — design

Status: design (approved)
Date: 2026-06-30

## Problem

folino imports PDFs and displays them in the Reader (Page + Vertical modes,
vector `PDFPageCanvas`, Apple Pencil annotation), but a PDF is display-only:
`ReaderCapabilities.forPDF` sets `canPlay: false` because a PDF carries no
notation. Users want to *play* an imported score PDF and watch a cursor track
the music, the same way native scores do — while still seeing the original PDF.

`swift-sheet-music` (ssm) `origin/main` (`94e214a5`) now ships the pieces that
make this possible on iOS:

- A **public** PDF OMR importer that reconstructs a `Score` from a vector PDF.
- A **geometry side-car** (`PDFScoreGeometry`) that maps the reconstructed
  score's musical positions back to rectangles **in the original PDF's page
  coordinate space**, so a playback cursor can be drawn on the displayed PDF.

OMR is imperfect — it works well only on MuseScore-/ssm-exported vector PDFs and
can mis-parse. ssm surfaces per-location diagnostics (`.info`/`.warning`) but no
confidence score, so the UI must tell the user the feature is best-effort.

This is an **iOS-only** capability: `SheetMusicPDF` is excluded from ssm's
Android build.

## ssm surface consumed (origin/main, verified iOS-usable)

`import SheetMusicPDF` (CoreGraphics/Foundation/PDFKit/SheetMusicCore; no
`@available`/`#if os` gate on the importer or geometry):

- `PDFImporter.parseWithGeometry(pdfURL:options:) throws -> (score: Score, geometry: PDFScoreGeometry)`.
- `PDFScoreGeometry` (`Sendable`, not `Codable`):
  - `cursorRect(for: ScoreCursor, in: Score) -> PDFElementRect?` — full-height
    cursor bar for the current playback cursor (handles `.item` and `.beat`).
  - `hitTest(pageIndex:point:tolerance:) -> ScoreItemID?` — tap-to-seek.
  - `pageSizes: [Int: CGSize]`.
- `PDFElementRect { pageIndex; rect /* y-up, bottom-left */; flipped(pageHeight:) }`.
- `PDFImportOptions { diagnostics: (@Sendable (PDFImportDiagnostic) -> Void)? }`,
  `PDFImportDiagnostic { severity, location, message, context }`.

Time→cursor reuses the existing path: ssm `PlaybackEngine.currentCursor` flows
through Folino's `PlaybackController` → `ReaderPlaybackSession`.

The ssm macOS example's original-PDF cursor view is macOS/AppKit-only and not
reused; Folino writes its own SwiftUI overlay.

## Decisions

1. **Enable + disclosure**: auto-parse on PDF open (background). Show a one-time
   dismissible banner on the first successful PDF playback (mirrors the existing
   page-tap hint, persisted via `@AppStorage`). The existing `PDFBadge` becomes
   tappable and opens a sheet with the same caveat text — available any time,
   even after the banner is dismissed. No always-on footer note.
2. **Modes**: both Vertical (cursor + auto-scroll) and Paged (cursor +
   auto-page-turn).
3. **Tap-to-seek**: included (tap a note/bar on the PDF to jump the cursor).
4. **Caching**: v1 parses once per Reader session, in memory. Disk cache is
   deferred — `PDFScoreGeometry` is not `Codable`, so persistence needs an ssm
   change; future approach keys the cache by bundled-ssm version and resets on
   app update.

## Architecture

Respect the layering `Feature → Domain ← ssm`; Features must not import
`SheetMusicPDF`. ssm's importer + geometry are wrapped behind a **new Domain
protocol**, implemented in Infrastructure (which already imports
`SheetMusicPDF`), and injected into the Reader as an optional dependency
(mirroring the existing optional `playbackController`). The Reader holds an
opaque `any PDFPlaybackGeometry`.

### Domain (pure Foundation/CoreGraphics/SheetMusicCore)

```swift
struct PDFCursorRect: Hashable, Sendable { let pageIndex: Int; let rect: CGRect } // top-left mediaBox
protocol PDFPlaybackGeometry: Sendable {
    var pageSizes: [Int: CGSize] { get }
    func cursorRect(for cursor: ScoreCursor, in score: Score) -> PDFCursorRect?
    func cursor(at point: CGPoint, pageIndex: Int) -> ScoreCursor?   // tap point top-left mediaBox
}
struct PDFParseDiagnostic: Hashable, Sendable { enum Severity { case info, warning }; let severity; let location; let message }
struct PDFPlaybackParseResult: Sendable { let score: Score; let geometry: any PDFPlaybackGeometry; let diagnostics: [PDFParseDiagnostic] }
protocol PDFPlaybackParser: Sendable { func parse(pdfURL: URL) async throws -> PDFPlaybackParseResult }
```

### Infrastructure (Apple-gated, ScoreFiles)

- `LivePDFPlaybackParser`: runs `PDFImporter.parseWithGeometry` off-main,
  collects diagnostics via the options closure (thread-safe box).
- `SheetMusicPDFGeometry: PDFPlaybackGeometry`: wraps `PDFScoreGeometry`; flips y
  to top-left via `pageSizes[page].height` for `cursorRect`; flips the tap point
  to y-up before `hitTest`, maps `ScoreItemID` → `ScoreCursor.item(_)`.

### Reader

- `ReaderViewModel.pdfPlayback: PDFPlaybackLoadState` =
  `.idle | .parsing | .ready(PDFPlaybackData) | .unavailable`, where
  `PDFPlaybackData { score; geometry; diagnostics }`.
- `loadPDF(url:)` still sets `.loadedPDF(doc)` (display is independent), then
  launches `Task { parsePDFForPlayback(url:) }`. On success it loads the parsed
  `Score` into the existing `PlaybackController`; cursor flows through the
  already-wired `ReaderPlaybackSession.observeCursor`.
- `canPlayNow = capabilities.canPlay || pdfPlaybackReady` gates the bottom
  transport and the cursor overlays. `ReaderCapabilities.forPDF.canPlay` stays
  `false` (static format capability); PDF playback availability is runtime.

## Cursor overlay (Approach A — reuse the vector renderer + ink overlay seam)

Keep the PDF containers as-is; add the cursor as a sibling overlay in the same
page-frame coordinate space the ink overlay (`PDFAnnotationAnchoring` /
`StaticInkLayer`) uses.

Per-frame pipeline: `displayCursor` → `geometry.cursorRect(for:in:)` (top-left
mediaBox) → project into the container's page-frame space → translucent
`Rectangle` riding the same `scaleEffect`/offset.

- **Paged** (`PagedPDFContainer`, band space): `fit = min(vw/b.w, vh/b.h)` at
  `pageFrame.origin`. Cursor rect = `pageFrame.origin + flippedRect × fit`; draw
  only when `cursorRect.pageIndex == pageState.pageIndex`. Auto-page-turn:
  `goToPage` when the cursor's page changes (gated on `autoFollowEnabled`).
- **Vertical** (`VerticalPDFSurface`, unzoomed content space): pages at natural
  mediaBox size via `pageFrames(sizes:)`. Cursor rect =
  `pageFrames[pageIndex].origin + flippedRect`. Auto-scroll: scroll the rect into
  view via `pendingScroll` / `ScoreScrollCommand` (gated on `autoFollowEnabled`).
- Cursor visual: translucent `Rectangle`, `.accentColor.opacity(0.6)`.

## Tap-to-seek

Center-region tap → page-frame point → top-left mediaBox point →
`geometry.cursor(at:pageIndex:)` → `playbackController.setCursor`. Active only
when not annotating. In Paged, the center seeks while left/right page-turn
tap-zones keep turning (mirror the score reader's `SeekRegion`).

## Disclosure UX

- One-time dismissible banner on first `.ready`, persisted via
  `ReaderGlobalSettingsKey.pdfPlaybackNoticeDismissed`.
- Tappable `PDFBadge` → caveat sheet (visible for PDFs regardless of outcome;
  when `.unavailable`, the sheet also states playback couldn't be prepared).
- Copy localized in the Reader catalog (`reader.pdf.playback.*`) for
  en/ja/ko/zh-Hans/zh-Hant.

## Testing

- Domain: value-type / protocol-contract tests with a fake geometry.
- Infrastructure: `LivePDFPlaybackParser` against a committed MuseScore-exported
  fixture PDF — non-empty `Score`, non-empty geometry, `cursorRect` resolves.
- Reader: fake parser + fake `PlaybackController` → `loadPDF` reaches `.ready`;
  cursor-rect projection lands on the page; tap-to-seek maps a point to
  `setCursor`.

## Platform note

The Infrastructure adapter is Apple-gated; on Android the parser is not injected
and the PDF reader stays display-only (no divergent Android logic). Domain types
are pure Swift and compile everywhere. Android PDF playback is a future ssm
effort.

## Out of scope / follow-ups

- Disk cache of parse results (needs ssm `Codable` for `PDFScoreGeometry`).
- Full PDF playback inspector (tempo/mixer/transpose).
- Android PDF playback.

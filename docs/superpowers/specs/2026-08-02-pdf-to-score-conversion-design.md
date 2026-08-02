# PDF → Score Conversion — Design

**Date:** 2026-08-02
**Status:** Approved (brainstorm), pending implementation plan
**Supersedes parts of:** `2026-06-26-pdf-import-design.md`, `2026-06-30-pdf-playback-cursor-design.md`

## Summary

Today a PDF import stays a PDF: the reader displays rasterized pages, and a
background OMR pass (`swift-sheet-music`'s `PDFImporter.parseWithGeometry`) is
used for one purpose only — playing the document with a cursor drawn on top of
the original page. The reconstructed `Score` is never persisted, so every
notation-derived feature (layout modes, staff size, transpose, clef override,
part visibility, **note editing**) stays switched off.

This design inverts that. **The OMR result becomes the item's primary content.**
A PDF is converted to `.mscz` at import time and from then on behaves exactly
like any other imported score. The original PDF is kept as a sidecar and is
reachable through a new **original-PDF display toggle** in the reader.

Three user-visible consequences:

1. An imported PDF is a normal score — editable, transposable, re-layoutable.
2. The reader gains a **楽譜 / 原本 PDF** toggle; the original view keeps today's
   fixed-layout behavior (page + vertical, on-PDF cursor, page-anchored ink).
3. A **re-read (更新) action** re-runs OMR against the original PDF, so a user
   benefits from future accuracy improvements in the importer.

The PDF caveat dialog is rewritten to say something positive and actionable —
"we read this PDF into notation; if a note is wrong, fix it with the note-input
button above" — and its "don't show again" flag is reset by moving to a new
storage key, because the message is materially different from the one users
dismissed.

## Goals

- Convert an imported PDF into a real `Score` (`.mscz`) so downstream features
  need no PDF-specific code paths.
- Keep the original PDF viewable, playable, and annotatable, exactly as today.
- Let the user re-run the conversion later, with a confirmation gate when it
  would discard their work.
- Replace the caveat dialog with a positive, instructive message and re-show it
  to everyone once.
- Never regress: a PDF that cannot be read into notation behaves precisely as it
  does today.

## Non-Goals

- **Android.** This iteration is iOS-only. Every decision rule lands in Domain as
  a pure, platform-neutral function (`PDFOriginState`, the re-read confirmation
  policy) so the Android follow-up wires up UI and persistence without
  reimplementing logic. Android keeps its current parse-on-open behavior until
  that follow-up ships.
- Improving OMR accuracy itself — that lives in `swift-sheet-music`.
- Per-score version history / undo of a conversion. The confirmation dialog is
  the only gate; a re-read is not undoable.
- Migrating page-anchored ink onto the engraved score (see Accepted Trade-offs).

## Decisions (from brainstorm)

1. **Convert at import.** The item's `lengthBeats`, tempo, parts, thumbnail, and
   duplicate detection are all correct from the moment it appears in the library.
2. **Existing PDF items convert lazily** — on the next reader open. No bulk
   background migration after update.
3. **Conversion failure keeps today's behavior**: the item stays a `.pdf` item,
   display-only, no toggle. Not an import error.
4. **Original PDF is an independent toggle**, not a fourth layout mode. Display
   source (楽譜 / 原本 PDF) × layout mode (vertical / horizontal / page) are
   orthogonal axes, so the original view keeps both page and vertical.
5. **While the original PDF is shown, engraving-derived settings are disabled** —
   exactly today's `ReaderCapabilities.forPDF`. Settings that only affect sound
   (tempo, A4, mixer, master volume) stay live.
6. **Re-read requires confirmation** when it would discard user work.

## Architecture

### 1. Domain — the PDF-origin axis

`ScoreItem` gains four fields (all defaulted, so existing construction sites
compile unchanged):

```swift
/// The original PDF this item was read from, as `<id>.pdf` in the scores directory.
/// Non-nil for every PDF-origin item, converted or not.
public var sourcePDFFileName: String?
/// SHA-256 of the original PDF bytes. Duplicate detection matches against this as well as
/// `contentHash`, so re-importing the same PDF is still recognized after conversion.
public var sourcePDFContentHash: String?
/// `contentHash` of the `.mscz` as it was written by the conversion. `contentHash` drifting
/// away from this is the definition of "the user edited the score".
public var pdfDerivedContentHash: String?
/// The last conversion attempt failed (or produced nothing playable). Keeps the reader from
/// re-attempting an expensive OMR pass on every open. Cleared by an explicit re-read.
public var pdfConversionFailed: Bool
```

`format` stays derived from `localFileName`, unchanged: a converted item *is* an
`.mscz` item. That is the whole point — no downstream code learns a new case.

One pure function is the single source of truth for the three states, and is
what Android will call later:

```swift
public enum PDFOriginState: Hashable, Sendable {
    case notPDF          // never came from a PDF
    case unconverted     // PDF origin, still displayed as a PDF (failed or not yet attempted)
    case converted       // PDF origin, now a real score, original kept as sidecar
}

public extension ScoreItem { var pdfOriginState: PDFOriginState { … } }
```

Rule: `sourcePDFFileName == nil` → `.notPDF`; else `pdfDerivedContentHash != nil
&& format != .pdf` → `.converted`; else `.unconverted`.

### 2. Persistence — migration v15

`Migrations.swift` registers `v15`, adding four nullable/defaulted columns to
`score_items`: `source_pdf_file_name`, `source_pdf_content_hash`,
`pdf_derived_content_hash`, `pdf_conversion_failed INTEGER NOT NULL DEFAULT 0`.
Additive only; existing rows read back as `.notPDF` except real PDFs, which
back-fill on first open (§4).

`ScoreLibraryRepository.scoreItems(matchingContentHash:)` matches
`content_hash = ? OR source_pdf_content_hash = ?`. Without this, re-importing an
already-converted PDF would no longer be detected as a duplicate.

### 3. Import — conversion is part of the commit

The conversion itself is one shared Infrastructure component so import and
re-read cannot drift apart:

```swift
struct PDFScoreConverter {
    /// Parses `pdfURL` and, when the result has playable content, writes `<id>.mscz`
    /// next to it and returns everything the caller needs to update the row.
    func convert(pdfURL: URL, destinationMSCZ: URL) async -> PDFConversionOutcome
}

enum PDFConversionOutcome {
    case converted(fileName: String, contentHash: String, sizeBytes: Int64, summary: ScoreFileSummary)
    case notReadable   // parse threw, or `Score.hasPlayableContent == false`
}
```

It uses the existing `PDFPlaybackParser` (OMR) and `ScoreFileGateway.saveScore`,
then re-reads the written `.mscz` through `loadFileMetadata` so a converted item's
metadata is derived by exactly the same code as a natively imported `.mscz`.

`LiveScoreFileImporter.commitImport` grows a `.pdf` branch. After the staged file
moves to `<id>.pdf` it calls the converter:

- **Converted** — `localFileName = "<id>.mscz"`, `contentHash` / `sizeBytes` /
  `lengthBeats` / `defaultTempoBpm` / `primaryKey` / `instrumentationSummary` /
  composer-and-credits come from the converted score's summary;
  `sourcePDFFileName = "<id>.pdf"`, `sourcePDFContentHash = plan.contentHash`,
  `pdfDerivedContentHash = contentHash`, `pdfConversionFailed = false`.
  **Title still comes from the PDF's file name** (`ScorePresentation.title(fromFilename:)`)
  — the rule from the original PDF-import design survives: exporters bake their
  own project name into the notation's title field, the file name is what the
  user chose.
- **Not readable** — the row is exactly what it is today, plus
  `sourcePDFFileName` / `sourcePDFContentHash` set and `pdfConversionFailed = true`.

Import of a PDF is now measurably slower. The existing import HUD gains a
"読み取り中" phase label. No cancel affordance (YAGNI); the parse already runs
off the main actor via `LivePDFPlaybackParser`.

### 4. Lazy migration of existing PDF items

`ReaderViewModel.loadPDF` runs first: if the item is `.unconverted` and
`pdfConversionFailed == false`, it runs `PDFScoreConverter` before deciding what
to display, showing the reader's existing loading state with the same
"読み取り中" label.

- Success → save the updated row, then continue down the normal
  `loadScoreFile(url:)` path. The user's next open is a plain score open.
- Failure → set `pdfConversionFailed = true`, display the PDF as today. The flag
  keeps every subsequent open cheap; the re-read action is how the user retries.

Rows imported before v15 have `sourcePDFFileName == nil`; the same code path
back-fills it from `localFileName` on that first open.

### 5. Reader — display source

```swift
enum ReaderDisplaySource: Hashable, Sendable { case score, originalPDF }
```

`ReaderViewModel.displaySource` drives everything:

- **Capabilities become computed**, not stored:
  `ReaderCapabilities.resolve(format:displaySource:)` returns `.forPDF` whenever
  `displaySource == .originalPDF`, `.forScore` otherwise. Every inspector row and
  toolbar affordance already reads capabilities, so *no* call site changes: the
  staff-size stepper, honor-breaks, multi-measure-rest collapse, show-invisibles,
  part visibility, clef override, transpose, and horizontal mode all disappear
  while the original is shown, and come back on toggle. Tempo, A4, mixer, master
  volume, transport, page navigation, and annotation remain available.
- **The toggle is shown only for `.converted` items.** `.unconverted` items are
  pinned to `.originalPDF` with no toggle (today's UI); `.notPDF` items have no
  toggle at all. It sits in the reader's top overlay next to the layout-mode
  control.
- **Layout mode round-trips.** Switching to the original clamps `horizontal → page`
  (the existing `clampLayoutModeToCapabilities`) and remembers the score-side
  mode in view-model state; switching back restores it. Page and vertical carry
  across untouched, which is the reason this is a toggle and not a fourth mode.
- **The original document is opened lazily** on first switch, so a user who never
  toggles never pays for `PDFDocument(url:)`. `loadState` keeps its current shape
  (`.loaded(score)` for a converted item); the reader holds
  `originalPDFDocument: PDFDocument?` alongside it and renders the existing PDF
  containers when `displaySource == .originalPDF`.

#### On-PDF playback cursor in the original view

The cursor drawn on the original page needs the geometry side-car, which only
exists as a product of an OMR pass. After conversion we no longer parse at open
time, so the original view re-runs the parse **lazily, once per session, on first
switch** — the existing `parsePDFForPlayback` path, reused verbatim, with its
`.parsing` / `.ready` / `.unavailable` states. Until it lands, the original view
shows pages without a cursor; playback itself is unaffected because it is driven
by the converted score.

This is gated on the score being **unedited** (`contentHash == pdfDerivedContentHash`).
Once the user edits notes, the geometry describes a score that no longer matches
what is playing, so the original view stays cursor-free. Stated in the inspector
as a one-line note rather than silently.

### 6. Re-read (更新) action

Lives in the reader's overflow menu as **「PDF から読み取り直す」**, shown for any
item with `sourcePDFFileName != nil` — including `.unconverted` ones, where it
doubles as "retry" and clears `pdfConversionFailed`.

Confirmation is decided by a pure Domain function so iOS and Android will apply
one rule:

```swift
enum PDFReparsePolicy {
    /// True when re-reading would discard work the user did on top of the previous parse.
    static func needsConfirmation(
        isScoreEdited: Bool,          // contentHash != pdfDerivedContentHash
        hasStaffBoundPreferences: Bool,
        hasMusicalAnnotations: Bool,
    ) -> Bool
}
```

`hasStaffBoundPreferences` is true when any *staff-index-addressed* preference is
set: `staffClefOverrides`, `hiddenStaves`, `staffProgramOverrides`,
`staffVolumeOverrides`, or `transposeSemitones != 0`. These are the settings a
re-parse invalidates, because a better parse can renumber staves. Layout mode,
zoom, tempo, A4, master volume, and repeat state are not staff-bound and survive.

Flow:

1. No confirmation needed → run immediately with a progress HUD.
2. Otherwise → alert. Title 「PDF から読み取り直しますか？」, body enumerating what
   is lost: 音符の編集内容、譜表ごとの設定（音部記号・表示/非表示・音色・音量・移調）。
   Buttons: キャンセル / 読み取り直す (destructive role).
3. Run `PDFScoreConverter` against the sidecar PDF, writing to a temporary file
   and swapping it into place only on success. A failed re-read changes nothing
   and surfaces an error alert.
4. On success: update the row (hashes, size, length, tempo, credits — title is
   left alone, the user may have renamed it), **reset the staff-bound
   preferences**, and reload the reader.
5. Musical-anchor annotations are **kept**, not cleared — they may shift, which
   the confirmation body says. Erasing a user's ink to protect them from a small
   offset is the worse failure.

### 7. The caveat dialog, rewritten

`PDFPlaybackNotice` becomes `PDFSourceNotice`, presented on the first open of a
`.converted` item. Two buttons as today: emphasized OK, plain 今後表示しない.

Body copy (ja; all five shipped locales get the equivalent):

> この PDF を解析して楽譜に変換しました。再生・移調・表示の調整が使えます。
> 読み取りが間違っている音符は、上の音符ボタンからその場で直せます。
> 元の PDF はいつでも表示を切り替えて見られます。

For `.unconverted` items the existing "読み取れませんでした" copy is kept, with one
sentence added pointing at the re-read action.

**Reset of "don't show again":** the flag moves from
`readerPdfPlaybackNoticeDismissed` to a new key,
`readerPdfSourceNoticeDismissed`. Users who dismissed the old message see the new
one once. The old key is left in place, unread — deleting it buys nothing and
would break a rollback. Android keeps reading the old key until its follow-up
ships, so no cross-platform breakage.

### 8. Library and share

- The library row keeps a **PDF badge** for any item with `sourcePDFFileName != nil`,
  even though its format is now `.mscz` — the badge's job is to say "this notation
  was machine-read and may contain mistakes". Derived through one presentation
  helper so both platforms agree.
- `ShareSubmenu` gains an **原本 PDF** entry for `.converted` items, exporting the
  sidecar bytes unchanged. The existing "PDF" entry keeps meaning "render the
  current score to PDF"; the two are labeled distinctly.
- Delete / restore / purge must carry the sidecar with the item. The trash and
  purge paths currently remove `localFileName`; they gain `sourcePDFFileName`.

## Accepted Trade-offs

- **Disk doubles for PDF items** (original + `.mscz`). The `.mscz` is small next
  to a PDF, and the original is required by both the toggle and the re-read
  action. No sync impact — `CloudSync` is still a placeholder.
- **Ink drawn on a PDF before conversion stays on the original side.** It is
  page-anchored; the engraved score has no equivalent geometry. Switching to the
  original shows it, unchanged. Not migrated.
- **A re-read is not undoable.** Version history is app-release notes, not
  per-score snapshots; building snapshots for this one action is out of scope.
  The confirmation dialog carries that weight.
- **Import is slower for PDFs.** Accepted in exchange for a library row that is
  correct on arrival.

## Testing

- **Domain** — `pdfOriginState` across all field combinations;
  `PDFReparsePolicy.needsConfirmation` truth table;
  `ReaderCapabilities.resolve(format:displaySource:)`; `ScoreItem` codable
  round-trip with the new fields.
- **Infrastructure** — `PDFScoreConverter` against a fixture PDF with a fake
  parser (converted / notReadable); `commitImport` sets every new field on both
  paths; duplicate detection matches an already-converted PDF by
  `sourcePDFContentHash`; migration v15 preserves existing rows and defaults.
- **Reader** — toggling display source swaps capabilities and clamps/restores the
  layout mode; a `.unconverted` item exposes no toggle; lazy conversion on open
  updates the row and lands in `.loaded`; conversion failure sets the flag and
  falls back to PDF display; the re-read flow asks for confirmation exactly when
  the policy says so and resets staff-bound preferences on success.
- Feature tests use hand-written fakes for `PDFPlaybackParser`, gateway, and
  repository — no real OMR in the test loop.

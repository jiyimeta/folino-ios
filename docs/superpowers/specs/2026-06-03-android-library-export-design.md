# Android Library Export — Design

Date: 2026-06-03
Branch: `android-library-export`
Status: design (awaiting review)

## Goal

Let an Android user export a score from a Library row, with the **same format
choices as iOS** (MuseScore v4, MuseScore v3, PDF, MIDI, audio M4A). Both a
single-row action and a multi-select (bulk) action are in scope, matching the
existing Android Library actions (delete / add-to-playlist / tags all have a
single-row path and a selection-mode bulk path).

Per the repo's iOS/Android parity policy: export **logic** is shared with iOS
(and the iOS side is refactored where that enables sharing); only the
irreducible platform primitives that *can only* be written on Android are
written in Kotlin. UI placement follows Android idioms.

## Scope

In scope:

- Single-row export from the per-row overflow menu.
- Bulk export from selection mode.
- All 5 formats at iOS parity. The format that matches the score's original
  source is copied byte-for-byte (no re-encode), exactly as iOS does.
- Android share via the system share sheet (`ACTION_SEND` /
  `ACTION_SEND_MULTIPLE`), which is the Android analogue of the iOS share
  sheet and also offers "Save to Files / Drive".

Out of scope:

- New export formats not present on iOS.
- Changing iOS export behavior (the iOS refactor below is behavior-preserving).
- A dedicated "Exports" archive folder surviving uninstall — exports go to
  cache and are handed straight to the share sheet, matching the iOS
  share-temp model.

## Format feasibility (why the split exists)

`swift-sheet-music` splits into cross-platform targets and Apple-only targets.

| Format | iOS producer | Cross-platform? | Android producer |
| --- | --- | --- | --- |
| MIDI | `SheetMusic.exportMIDI` (SheetMusicMIDI) | ✅ | same Swift call |
| MuseScore v4 | `MSCZWriter.write` (SheetMusicMSCX + SheetMusicZip) | ✅ | same Swift call |
| MuseScore v3 | `MSCZWriter.write` | ✅ | same Swift call |
| PDF | `PDFExporter` (SheetMusicPDF, `import CoreGraphics`) | ❌ Apple-only | Kotlin: `DrawProgram` → `PdfDocument` |
| Audio M4A | `ScoreAudioExporter` → AVFoundation (SheetMusicAudio) | ❌ Apple-only | Kotlin: `AndroidPlaybackEngine.exportAudioFile` |

MIDI and MSCZ reuse the existing cross-platform Swift encoders directly. PDF
and audio are inherently platform-specific on **both** platforms — iOS draws to
a CoreGraphics PDF context / encodes via AVFoundation; Android draws to a
`PdfDocument` canvas / encodes via the existing Android audio module. The
**shared** parts of PDF and audio (the layout engine that produces the
`DrawProgram`, and the cross-platform FluidSynth sample synthesis) are already
cross-platform and reused; only the final rasterization/codec target differs.

## Architecture — three layers (decision C1)

We classify the work into three layers and place each according to parity:

- **(A) Decision logic** — pure, value-in/value-out, no side effects: the
  ordered format list, `sanitize(title:)`, original-format detection from
  `ScoreSource`, and format → file-extension mapping. **Single-sourced in
  Domain**, used by both iOS and Android.
- **(B) Orchestration** — the procedural glue of `prepareShare`: load score →
  if picked format == original, copy bytes, else route by format to the right
  producer → return the output path/URL → funnel errors. This is **logic and
  stays in Swift on both platforms.** It lives once per platform (iOS:
  `LiveScoreShareService`; Android: a single `exportScore` on
  `LibraryAndroidStore`). The two thin orchestrators are kept from diverging by
  Swift's exhaustive `switch` over `ScoreShareFormat`: adding a format breaks
  compilation in both until handled.
- **(C) Platform primitives** — actually producing bytes. MIDI/MSCZ are
  cross-platform Swift. PDF and audio are the only Android-only code, each
  behind a protocol the Swift orchestrator calls.

### Decision: C1 (not C2)

C1 single-sources the decision logic (A) in Domain and keeps a thin
orchestration wrapper (B) once per platform. The rejected alternative C2 would
hoist (B) into one cross-platform Swift orchestrator in a **new shared module**
that both Infrastructure (iOS) and `FolinoLibraryJNI` (Android) depend on.

C1 was chosen for long-term maintainability, not just lower build cost:

- The highest-churn, parity-sensitive part is (A), already single-sourced in
  Domain under C1.
- The most common future change — adding a format — is compiler-guarded across
  both thin orchestrators by Swift's exhaustive `switch`. Silent divergence
  can't happen.
- C2's shared module is a permanent architectural artifact that straddles the
  "Feature → Infrastructure forbidden" boundary, and unifying the genuinely
  different per-platform I/O (`ScoreItem`/`URL`/`shareTempDirectory`/`gateway`
  on iOS vs `scoreId`/path-`String`/`cacheDir`/`MSCZReader` on Android) would
  require an extra abstraction layer that itself must be maintained forever.

C2 would only win if export grows into a substantial subsystem (batch
conversion pipelines, conversion options, shared progress/cancellation). That
is not the current target. If that changes, B can be hoisted into a shared
module later — C1 does not block that.

## Layer A — shared decision logic (Domain)

`ScoreShareFormat` / `ScoreShareFormatOption` already live in Domain
(`Packages/Domain/Sources/Domain/Protocols/ScoreShareService.swift`). Domain
already depends on `SheetMusicCore`, so `ScoreSource` is reachable here.

Add to Domain (pure, Foundation + SheetMusicCore):

- `ScoreShareFormat.canonicalExtension: String` → `mid` / `mscz` / `pdf` /
  `m4a` (mscz for both v3 and v4).
- `ScoreShareFormat.allOrdered: [ScoreShareFormat]` — the canonical order
  `[.museScoreV4, .museScoreV3, .pdf, .midi, .audioM4A]` (today this literal
  lives inline in `LiveScoreShareService.availableFormats`).
- `ScoreShareFormat.matching(for source: ScoreSource) -> ScoreShareFormat?` —
  the original-format mapping currently in
  `LiveScoreShareService.matchingFormat(for:)`.
- `ScoreExportNaming.sanitize(title:) -> String` — the filename sanitizer
  currently `LiveScoreShareService.sanitize(title:)` (replace `/ : \ NUL` with
  `_`, trim, fall back to `"score"`, cap at 100 chars).

These are additive to Domain's surface (no protocol signature change rippling
across Features), so they do not constitute a module-architecture change.

## Layer B/C — iOS refactor (behavior-preserving)

`LiveScoreShareService`
(`Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift`):

- Replace its private `sanitize` / `matchingFormat` and the inline format list
  with the new Domain helpers (delegation; behavior identical).
- Introduce a `ScorePDFRenderer` Domain protocol so PDF sits behind a protocol
  the way audio already sits behind `ScoreAudioExporter`. iOS injects a
  CoreGraphics-backed implementation (wrapping the existing `PDFExporter`).
  This gives iOS and Android the same orchestrator shape: `(B)` routes to
  injected `(C)` producers for PDF and audio, and to cross-platform encoders
  for MIDI/MSCZ.
- Move the existing `sanitize` unit tests to follow the Domain helper.

Net iOS behavior is unchanged; this is the "refactor iOS to enable sharing"
the task invited.

## Layer B/C — Android Swift (`FolinoLibraryJNI`)

`Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`
already imports Domain + SheetMusicMSCX and is the `@WireletObservable` bridge
with many `@WireletExpose` methods. It already injects a Kotlin-backed
`LibraryStore` via `@WireletProvided` — the same mechanism we use for the two
Android export primitives.

Package.swift (`FolinoLibraryJNI` Android target) gains a cross-platform
dependency on `SheetMusicMIDI` (+ `SheetMusic` umbrella) and `SheetMusicLayout`
(for the PDF `DrawProgram`). These are cross-platform targets — not an
architecture change.

Add injected Kotlin primitives (via `@WireletProvided`, like `LibraryStore`):

```swift
// (C) — implemented in Kotlin, called from Swift orchestration.
protocol ScorePdfRenderer {            // draws a precomputed layout to a PDF file
    func renderPdf(drawProgram: Data, outPath: String) -> Bool
}
protocol ScoreAudioFileExporter {      // synth PCM → M4A file
    func exportAudio(scoreHandle: Int64, format: String, outPath: String) -> Bool
}
```

(Exact wire shapes finalized in the plan; the principle is Kotlin implements
only these two, Swift owns the rest.)

Add the orchestration entry point:

```swift
@WireletExpose
public func exportScore(_ scoreId: String, _ format: String, _ outDir: String) -> String
// Returns absolute output path on success, "" on failure (matches the
// existing importScore convention of failing quietly across the bridge).
```

`exportScore` runs the shared (B) flow:

1. Resolve the score's managed file (`<id>.mscz` under `filesDir/Scores`).
2. Parse via `MSCZReader` (already used by `importScore`).
3. `title = ScoreExportNaming.sanitize(score title)`; output path =
   `outDir/<title>.<format.canonicalExtension>`.
4. If `ScoreShareFormat.matching(for: score.source) == format`, copy original
   bytes; else `switch format`:
   - `.museScoreV4` / `.museScoreV3` → `MSCZWriter.write`
   - `.midi` → `SheetMusic.exportMIDI`
   - `.pdf` → compute `DrawProgram` (cross-platform layout) →
     `pdfRenderer.renderPdf(...)`
   - `.audioM4A` → `audioExporter.exportAudio(...)`
5. Return the path (or "").

`exportFormats(scoreId) -> [wire]` is also exposed so the sheet can show the
list and badge the original (using Domain `allOrdered` + `matching(for:)`).

## Layer C / UI — Android Kotlin (app + reuse of Reader modules)

The Kotlin side implements only the two `(C)` primitives and the UI/share glue.
Both primitives need the score loaded as a native handle / layout, which the
Reader already does via the shared `swift-sheet-music` Android modules
(`SheetMusicComposeAndroid` for `DrawProgram` decode/draw,
`SheetMusicAudioAndroid` for `AndroidPlaybackEngine`).

- **PDF primitive** — given a `DrawProgram` (page list of `DrawCommand`s,
  millimetre coordinates), open an `android.graphics.pdf.PdfDocument`, and for
  each page draw the same `DrawCommand`s the Reader's `ScoreCanvas` draws,
  redirected to the page's `android.graphics.Canvas`. Write to `outPath`.
  Factor the per-command draw routine so it is shared between the live
  `ScoreCanvas` (Compose) and the PDF canvas where practical.
- **Audio primitive** — call the already-implemented
  `AndroidPlaybackEngine.exportAudioFile(outputFd, scoreHandle, format = M4A,
  range = Full, progress)`, writing to a `ParcelFileDescriptor` for `outPath`.
- **Share** — new `FileProvider`
  (`com.keynumber.folino.fileprovider`) + `res/xml/file_paths.xml` exposing the
  export cache dir; build `ACTION_SEND` (single) / `ACTION_SEND_MULTIPLE`
  (bulk) with the produced file URI(s) and the correct MIME type, then
  `Intent.createChooser(...)`.
- **Output location** — `context.cacheDir/Exports/`, cleared opportunistically;
  files are transient handoffs to the share sheet (iOS share-temp parity).

### UI placement (Android idioms)

- **Single row** — add an "Export" item to the existing per-row overflow
  `DropdownMenu` (currently Add to Playlist / Edit Tags) in
  `LibraryScreen.kt`. Tapping opens a format-picker `ModalBottomSheet`
  (following the existing `AddToPlaylistSheet` pattern), with the original
  format badged. Selecting a format produces the file and launches the share
  sheet.
- **Bulk** — add an Export action to the existing selection-mode toolbar /
  CAB. Same format sheet; produces one file per selected score and launches
  `ACTION_SEND_MULTIPLE`.
- **Progress / errors** — a determinate or indeterminate indicator while
  producing (audio can be slow; use the `exportAudioFile` progress callback).
  Failures surface as a Snackbar (the Android analogue of the iOS
  `currentError` alert).

## Data flow (single-row PDF example)

row overflow → "Export" → format sheet → "PDF"
→ Kotlin calls `viewModel.exportScore(id, "PDF", cacheExportsDir)`
→ Swift `(B)`: load score, sanitize title, compute `DrawProgram`,
   call injected Kotlin `pdfRenderer.renderPdf(drawProgram, outPath)`
→ Kotlin draws each page's `DrawCommand`s to a `PdfDocument` canvas, writes
   `cacheDir/Exports/<Title>.pdf`, returns success
→ Swift returns the path → Kotlin builds a `FileProvider` URI → `ACTION_SEND`
   chooser.

MIDI/MSCZ follow the same flow but produce bytes entirely in Swift (no Kotlin
primitive). Audio M4A routes to the audio primitive instead of the PDF one.

## Error handling

- Swift `exportScore` returns `""` on any failure (unreadable file, parse
  failure, primitive returned false). Kotlin treats `""` as failure → Snackbar.
- Kotlin primitives catch their own exceptions and return `false`.
- Bulk: if one item fails, surface the failure and stop (matches the iOS
  `requestBulkShare` early-return on first error). Plan may revisit
  partial-success UX.

## Testing

- **Domain (Swift Testing, host):** unit tests for `sanitize(title:)`,
  `matching(for:)`, `canonicalExtension`, `allOrdered`. The migrated iOS
  sanitize tests live here.
- **iOS Infrastructure:** existing `LiveScoreShareService` tests stay green
  after the refactor (delegation behavior-preserving); add a fake
  `ScorePDFRenderer` to assert PDF routing.
- **`FolinoLibraryJNI` (host, `FOLINO_ANDROID=1`):** `exportScore` produces the
  right extension/bytes for MIDI / MSCZ / original-copy, and routes PDF/audio
  to injected fakes. (PDF/audio primitive *fakes* here; real primitives are
  Kotlin.)
- **Android device (Pixel):** real PDF render and real M4A export verified by
  install + launch + share on device, per the project's Android verification
  rule. Kotlin primitive logic that can be unit-tested (e.g. DrawCommand →
  Canvas mapping) gets JVM/Robolectric tests where practical.

## Risks / open items (to resolve in the plan)

- Confirm the Kotlin API to load a Library score (`<id>.mscz` path) into the
  native handle the audio export and layout compute need, reusing the Reader's
  loader rather than adding a new one.
- Confirm the `DrawProgram` is reachable from the Library Kotlin layer (Reader
  uses it; Library must obtain it for a score not currently open).
- `@WireletProvided` multi-service injection: `LibraryAndroidStore` currently
  takes one `LibraryStore`. Adding two more injected services must work with
  the current wirelet bridge (multi-arg provided init); verify against the
  installed wirelet revision.
- MIME types per format for the share intent (`audio/mp4`, `application/pdf`,
  `audio/midi`, MuseScore `application/octet-stream` or vendor type).

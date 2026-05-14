# m4a Audio Share — Design

Add `.m4a` audio export to the Library row share menu, alongside the
existing MuseScore / PDF / MIDI formats. Folino offline-renders the
score through `swift-sheet-music`'s `PlaybackEngine.exportAudioFile`
and writes a single AAC-encoded `.m4a` file per share.

## Goals

- The Library row share menu exposes a new **m4a** entry with
  the same UX as the existing formats (loading spinner during
  prepare, then standard share sheet).
- Audio reflects the score's currently-loaded soundfonts: pre-fetch
  every distinct `(bank, program, isDrums)` patch the score uses
  before kicking the offline render.
- One isolated `AVAudioEngine` per export call — must not interfere
  with `LivePlaybackController`'s live engine.
- Default encoding: **AAC, 128 kbps, stereo, 44.1 kHz**. No
  user-tunable knobs.

## Non-goals

- Reader-side share (`.currentLoop` range export). v1 only ships
  full-score export from the Library.
- Bitrate / sample-rate / channel pickers. Defaults are baked in.
- Soundfont-bundle fallback: if a needed patch can't be fetched
  (offline + uncached), the export errors out rather than rewriting
  the channel to a bundled fallback. Live playback still does the
  fallback rewrite — that policy is intentionally different.
- Progress UI. The existing `isPreparingShare` spinner is reused as-
  is; no `0–100%` bar is added in v1.
- mp3, wav, aiff. iOS doesn't natively encode mp3 (would need
  GPL-incompatible LAME); PCM formats are huge and unnecessary for
  sharing.
- macOS — Folino is iOS-only.

## Architecture

Three modules touched. The new audio-rendering glue lives in the
existing `Audio` target since it already imports `SheetMusicAudio`;
no new SPM dependency is added.

### Domain

- `Domain/Protocols/ScoreShareService.swift`:
  - Add `case audioM4A` to the `ScoreShareFormat` enum.
- New file `Domain/Protocols/ScoreAudioExporter.swift`:
  ```swift
  public protocol ScoreAudioExporter: Sendable {
      func exportM4A(score: Score, to url: URL) async throws
  }
  ```
  Foundation + `Score` (re-exported from `SheetMusicCore`) only.
  No `SheetMusicAudio` types in the protocol surface.

### Audio (Infrastructure)

- New file
  `Packages/Infrastructure/Sources/Audio/LiveScoreAudioExporter.swift`:
  - `init(soundfontResolver: SheetMusicAudio.SoundfontResolver, domainResolver: Domain.SoundfontResolver)`.
  - `exportM4A(score:to:)`:
    1. Walk `score.allStaves` to collect distinct
       `(bank, program, isDrums)` patches (helper shared with
       `LivePlaybackController` — promote `distinctPatchKeys` from
       `private static` to `internal static` on
       `LivePlaybackController`, or extract to a shared file).
    2. For each patch, `try await domainResolver.resolveSoundfont(
       bank:, program:, isDrums:)`. Any throw propagates to the
       caller (no fallback rewrite).
    3. Build a one-shot `PlaybackEngine` with `soundfontResolver`,
       call `prepare(score: score)`.
    4. Call `engine.exportAudioFile(to: url, score: score,
       format: .m4a(.init(sampleRate: 44_100, bitRate: 128_000,
       channels: .stereo)), range: .full)`.
    5. Map any `AudioExportError` to
       `DomainError.scoreWriteFailed(reason:)` so the Library's
       existing error alert path renders it.
  - `@MainActor` because `PlaybackEngine` is `@MainActor`-isolated.

### ScoreFiles (Infrastructure)

- `LiveScoreShareService`:
  - Add stored property `audioExporter: any ScoreAudioExporter`
    and a corresponding `init` parameter.
  - `availableFormats(for:)`: append
    `ScoreShareFormatOption(format: .audioM4A)` (always
    `isOriginal == false`). The format ordering becomes
    `[museScoreV4, museScoreV3, pdf, midi, audioM4A]`.
  - `prepareShare(item:format:)`: new `case .audioM4A` in the
    `switch` — sanitize title, build
    `<title>.m4a` destination under `shareTempDirectory`, delete
    any pre-existing file at that path (matching the other
    formats' pattern), then `try await audioExporter.exportM4A(
    score: score, to: destination)`.

### App

- `AppBootstrap`:
  - After building `soundfontResolver`, build
    `let audioExporter = LiveScoreAudioExporter(
       soundfontResolver: soundfontResolver,
       domainResolver: soundfontResolver,
    )`.
  - Pass `audioExporter` into the `LiveScoreShareService` init.
  - The same `MuseScoreSF2Resolver` instance powers
    `LivePlaybackController` and the audio exporter — fine because
    `PlaybackEngine.exportAudioFile` builds a *dedicated*
    `AVAudioEngine` per call (per the `swift-sheet-music`
    contract).

### Library (UI)

- `Views/ScoreRowMenu.swift`:
  - Append `.audioM4A` to `placeholderFormats`.
  - `shareMenuFormatText`: new `case .audioM4A` returning
    `Text("library.format.m4a", bundle: .module)`.
  - `shareMenuIconName`: new `case .audioM4A` returning
    `"waveform"`.
- Library `Localizable.xcstrings`: add `library.format.m4a` →
  `"M4A"` (English) / `"M4A"` (Japanese — same token).

`LibraryViewModel.requestShare` / `requestBulkShare` are
unchanged — they're format-agnostic and the `isPreparingShare`
spinner already covers the longer m4a render time.

## Data flow (one m4a share)

```
ScoreRowMenu (.audioM4A picked)
  → LibraryViewModel.requestShare(item:format:.audioM4A)
    → isPreparingShare = true
    → LiveScoreShareService.prepareShare(item:, format: .audioM4A)
      → ScoreFileGateway.loadScore(fileURL:) — get parsed Score
      → LiveScoreAudioExporter.exportM4A(score:, to: <tmp>/<title>.m4a)
        → for each distinct (bank, program, isDrums):
            domainResolver.resolveSoundfont(...)   // throws on offline-miss
        → PlaybackEngine().prepare(score:)
        → engine.exportAudioFile(to:, score:, format: .m4a(...), range: .full)
      → return URL
    → shareTarget = ShareTarget(urls: [url])
    → SwiftUI sheet presents iOS share sheet
```

## Error handling

- Soundfont resolve failure (offline + missing patch) → throws to
  `LiveScoreShareService` → `LibraryViewModel.requestShare`'s
  `catch` writes `errorAlertMessage` (existing flow).
- `AudioExportError` from `swift-sheet-music` is wrapped in
  `DomainError.scoreWriteFailed(reason:)` so the Library never
  imports `SheetMusicAudio`.
- Cancellation: not exposed in v1. The existing share UI has no
  cancel button; the spinner just blocks until done. Acceptable
  because score-length renders are typically a few seconds.

## Testing

- **Domain**: type-only changes, no new tests.
- **Audio** (`Packages/Infrastructure/Tests/InfrastructureTests/`):
  - New Swift Testing suite `LiveScoreAudioExporterTests`:
    - With a fake `Domain.SoundfontResolver` whose
      `resolveSoundfont` throws, `exportM4A` rethrows without
      hitting the engine. Verifies the prefetch gate.
    - Optional smoke: a tiny in-memory `Score` with one staff,
      bundled SF2 patches available, asserts the output file
      exists, has `.m4a` extension, and is non-empty. Skipped if
      the bundled SF2 isn't reachable from the test runner — kept
      cheap, not a deep audio assertion.
- **ScoreFiles** (`InfrastructureTests`):
  - Extend `LiveScoreShareServiceTests` (or whichever file
    currently covers it) with:
    - `availableFormats(for:)` returns 5 entries including
      `.audioM4A` with `isOriginal == false` for every source.
    - `prepareShare(.audioM4A)` calls a fake `ScoreAudioExporter`
      with the score + a `<title>.m4a` URL under the temp dir,
      and returns that URL.
- **Library**: no automated UI test; manual smoke through the
  simulator after wiring up.

## Risks

- **Render time**: a 3-minute score at 44.1 kHz takes a non-
  trivial fraction of a second per second of audio on simulator
  — real-device numbers may be 2–5× faster. The spinner is the
  only feedback. If users complain, v2 adds a progress sheet
  using the `progress:` callback from `exportAudioFile`.
- **Soundfont prefetch failures during sharing**: choosing
  "error, don't fallback" is intentional — sharing audio with
  silent piano fallback would be confusing. The error message
  needs to be intelligible; `DomainError.scoreWriteFailed`
  surfaces the underlying `URLError` description today, which is
  acceptable for v1.
- **Concurrent exports**: not blocked. Two simultaneous shares
  would each spin a separate `PlaybackEngine` — fine in theory,
  but untested. Bulk share already iterates serially via
  `requestBulkShare`'s `for` loop, so the realistic case is
  covered.

## Out of scope (future)

- Reader-driven `.currentLoop` export.
- Quality picker (Settings or share sheet).
- Progress UI with cancel.
- Direct write to Files (`UIDocumentPickerViewController`) instead
  of share sheet routing.

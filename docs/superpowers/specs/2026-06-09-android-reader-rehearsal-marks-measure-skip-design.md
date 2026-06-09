# Android Reader — Rehearsal Mark Bubbles & Measure Skip

Date: 2026-06-09
Status: Approved design (pending spec review)

## Goal

Bring two iOS Reader playback-control features to the Android Reader's bottom
transport bar (the seek-bar variant):

1. **Rehearsal mark bubbles** — tappable pills above the seek bar, one per
   rehearsal mark (A, B, サビ, …), positioned along the timeline; tap seeks to
   that mark.
2. **Measure skip buttons** — previous/next-measure step buttons flanking
   play/pause, using Material `NavigateBefore` / `NavigateNext` (`‹` / `›`)
   icons.

Both appear **only when the seek bar is shown** (`showSeekBar == true`). In the
FAB-only mode (seek bar hidden) neither is added — there is no bar to anchor the
bubbles to, and the FAB cluster stays minimal.

## Guiding constraint — iOS/Android parity

Per `CLAUDE.md`: business/譜面 logic must behave identically on both platforms
and be **shared**, not reimplemented. The rehearsal-mark extraction (with its
tempo-weighted fraction) and the measure-step cursor computation (with the
"previous restarts the current measure" idiom) are pure score logic. They are
currently iOS-only, living in the Reader feature package on top of
`SheetMusicCore`. This design **lifts them into swift-sheet-music** so:

- Android calls them over JNI (no Kotlin reimplementation).
- iOS Reader is refactored to call the same shared Swift (no second copy).

UI **placement/presentation** follows Android idioms (Material pills, icon
choice); only the underlying data/logic is shared.

## Current state (verified)

### iOS logic to be lifted (Reader package, built on `SheetMusicCore`)

- `Score+RehearsalMarks.swift` — `Score.rehearsalMarks() -> [ReaderRehearsalMark]`.
  Walks `systemMeasures`, for each `.rehearsalMark` element builds a
  `.beat(measureIndex:, tickInMeasure:)` cursor, fraction =
  `min(max(seconds(at: cursor) / notatedDurationSeconds, 0), 1)`. Empty when no
  marks or zero notated duration. Ordered by position.
- `Score+SeekTime.swift` — `notatedDurationSeconds`, `seconds(at:)`,
  `cursor(atSeconds:)`. Tempo-weighted notated time map (no repeat expansion),
  tempo integrated at measure granularity via `effectiveQuarterBpm(at:)`;
  invariant to the global tempo multiplier.
- `Score+ResolveTickInMeasure.swift` — `tickInMeasure(of:)`,
  `beatTicks(atMeasure:)`, `resolveTickInMeasure(for:)`. Used by measure-step to
  decide rewind-vs-restart and to find beat boundaries.
- Measure-step driver (`ReaderPlaybackSession.swift`):
  - `stepMeasureForward()` → `seek(toMeasureStart: min(cur + 1, count - 1))`.
  - `stepMeasureBackward()` → if `tickInMeasure(of: cursor) < beatTicks(atMeasure: cur)`
    target `cur - 1`, else `cur` (restart); clamp `max(target, 0)`.
  - `seek(toMeasureStart:)` sets cursor to `.beat(measureIndex:, tickInMeasure: 0)`.

### Android Reader (Kotlin/Compose)

- Module: `Android/FolinoReaderAndroid` (+ `Android/app`).
- `ReaderScreen.kt` — `TransportBar` (seek bar ON) vs `PlaybackFab` (OFF). Today
  the transport row is `[|◀ jump-to-start (SkipPrevious)] [▶/⏸ play]`.
- `ReaderSeekBar` — thumbless YouTube-Music-style bar bound to
  `currentTimeSeconds / totalTimeSeconds`, `onSeek { engine.seek(seconds) }`.
- `ReaderAudioViewModel.kt` — exposes `state`, `currentTimeSeconds`,
  `totalTimeSeconds`, `currentCursor: StateFlow<ScoreCursor?>`, etc. Engine has
  `seek(to: ScoreCursor)`.
- **No** rehearsal-mark or measure-boundary data is exposed over JNI today.
- `SheetMusicJNI.kt` has `nativeNearestCursor`, `nativeMeasureFrame`,
  `nativeCursorFrame`, `ScoreCursorCodec.decode/encode` — the cursor wire format
  already round-trips.

## Design

### 1. swift-sheet-music — shared Swift + JNI

**Shared Swift (new home in ssm).** Move the four extension files' contents into
ssm. The pure tick/measure helpers (`tickInMeasure`, `beatTicks`,
`resolveTickInMeasure`) belong in `SheetMusicCore` (Foundation-only, operate on
`Score`). The tempo-weighted time map (`notatedDurationSeconds`, `seconds(at:)`,
`cursor(atSeconds:)`) and `rehearsalMarks()` belong wherever the tempo helper
`effectiveQuarterBpm(at:)` already lives (the same module as the existing
notated time logic — `SheetMusicCore`/`SheetMusicAudioCore`; confirm at
implementation time and co-locate). Public surface:

- `Score.rehearsalMarks() -> [RehearsalMarkEntry]` where
  `RehearsalMarkEntry = (text: String, fraction: Double, cursor: ScoreCursor)`
  (a named struct, not the existing UI-layer `ReaderRehearsalMark`).
- `Score.cursorSteppingMeasure(from: ScoreCursor, direction: MeasureStepDirection) -> ScoreCursor`
  encapsulating both forward (`min(cur+1, last)`) and backward
  (rewind-vs-restart idiom) logic, returning `.beat(measureIndex:, tickInMeasure: 0)`.

**JNI bridges (ssm Android module).**

- `nativeRehearsalMarks(scoreHandle) -> ByteArray` — encodes `[RehearsalMarkEntry]`
  (text UTF-8, fraction Double, cursor via existing `ScoreCursorCodec`). Kotlin
  decodes to `data class RehearsalMark(text, fraction, cursor)`.
- `nativeStepMeasureCursor(scoreHandle, fromCursorBytes, direction: Int) -> ByteArray`
  — returns the target `ScoreCursor` wire bytes.

**iOS refactor (no behavior change).** `Reader`'s `Score.rehearsalMarks()`
becomes a thin map from the shared `RehearsalMarkEntry` to the SwiftUI
`ReaderRehearsalMark` view model. `ReaderPlaybackSession.stepMeasureForward/
Backward` call `score.cursorSteppingMeasure(from:direction:)` for the target,
then route through the existing `seek(toMeasureStart:)`/`setManualCursor`. The
existing seek-time extensions either move to ssm and are re-imported, or stay as
thin re-exports — chosen so the Reader seek bar keeps using the identical map.

### 2. Android UI (Compose)

**`ReaderAudioViewModel` additions.**

- `rehearsalMarks: StateFlow<List<RehearsalMark>>` — loaded once when the score
  handle is set (marks are static per score), via `nativeRehearsalMarks`.
- `stepMeasureBackward()` / `stepMeasureForward()` — read `currentCursor.value`
  (or `.beat(0,0)` when null) → `nativeStepMeasureCursor` → `engine.seek(to: target)`.

**`RehearsalMarkBubbleRow` (new composable, above `ReaderSeekBar` inside
`TransportBar`).**

- Renders only when `rehearsalMarks` is non-empty (otherwise zero height).
- Each mark is a Material pill positioned horizontally by `fraction` across the
  bar's width (align the pill's anchor to the same inset/width the seek bar
  uses, so a pill sits over its timeline point).
- **Current mark** = the last mark with `fraction <= currentFraction`
  (`currentTimeSeconds / totalTimeSeconds`); filled with `primaryContainer`.
  Others use a hairline/outline style.
- Tap → `engine.seek(to: mark.cursor)`.
- Dense/overlapping marks: current pill drawn frontmost (`zIndex`); overlap is
  acceptable for MVP. No iOS-style speech-bubble tail (Android idiom = pills).
- Text truncated with ellipsis at a max width.

**Transport row (in `TransportBar`).** Becomes four controls:

```
  |◀            ‹            ▶/⏸           ›
 jump-start  prev-measure   play/pause   next-measure
 SkipPrevious NavigateBefore             NavigateNext
```

`‹` / `›` are guarded by `isPrepared` (same rule as play/pause). Keep the
existing `|◀` jump-to-start.

### 3. Data flow

```
score handle set ──► VM.loadRehearsalMarks() ──► nativeRehearsalMarks ──► List<RehearsalMark>
                                                                              │
TransportBar ◄── rehearsalMarks StateFlow ◄───────────────────────────────────┘
   │ bubble tap ──► engine.seek(to: cursor)
   │ ‹ / › tap   ──► VM.stepMeasure{Backward,Forward}() ──► nativeStepMeasureCursor(currentCursor) ──► engine.seek(to: target)
```

### 4. Edge cases

- `currentCursor == null` → treat as measure 0 for stepping.
- Forward at last measure / backward at measure 0 → clamped (handled inside
  shared `cursorSteppingMeasure`).
- Zero notated duration or no marks → empty list → no bubble row.
- Current-mark highlight when before the first mark → no mark highlighted.

## Risks / verification points

- **Fraction basis alignment.** The bubble `fraction` is computed against
  `notatedDurationSeconds` (ssm notated map). The Android seek bar positions the
  thumb by `currentTimeSeconds / totalTimeSeconds` from the engine. These must
  share the same time basis or bubbles will drift from the thumb. Verify
  `engine.totalTimeSeconds == notatedDurationSeconds` (no repeat expansion); if
  they differ, expose mark **seconds** instead and divide by the bar's
  `totalTimeSeconds` on the Kotlin side. **Resolve this before finalizing the
  wire format.**
- **iOS refactor regression.** Moving the seek-time extensions to ssm must not
  change the iOS seek bar / rehearsal bar behavior — keep the exact same
  functions, just relocated. Covered by existing Reader tests staying green.

## Testing

- **ssm (Swift Testing):** unit tests for `rehearsalMarks()` fraction
  computation (multi-tempo, time-signature changes, zero-duration) and
  `cursorSteppingMeasure` (forward clamp, backward rewind-vs-restart at first
  beat boundary, measure-0/last clamps). Verify in the **macOS example app**
  (耳/目視) before push, then report → approval → push.
- **iOS:** Reader tests remain green (refactor only).
- **Android:** build (codegen → `.so`) → Pixel install + launch → manual gesture
  check (tap bubble seeks, current-mark highlight tracks playback, `‹`/`›` step
  one measure with correct rewind-vs-restart).

## Sequencing

1. swift-sheet-music worktree (base origin/main). Implement shared Swift + JNI +
   ssm unit tests. Resolve fraction-basis question.
2. mavenLocal publish; verify in macOS example app; report → approval → push.
3. Folino re-pin ssm (`Package.swift` of consuming packages + `project.yml`
   `from:` to the same version).
4. iOS refactor to shared API; confirm Reader builds + tests green.
5. Android: regenerate wirelet codegen → `.so`; add VM methods + Compose UI;
   install + launch on Pixel.

## Out of scope (later)

- Bubble **drag-to-snap** scrubbing (iOS has it; UX-only, not business logic) —
  start with tap-to-seek, add drag later if desired.
- Rehearsal marks / measure skip in the FAB-only (seek-bar-hidden) mode.

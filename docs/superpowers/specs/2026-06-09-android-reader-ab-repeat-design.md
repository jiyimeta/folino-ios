# Android Reader — AB Repeat (3-mode repeat) Design

**Date:** 2026-06-09
**Status:** Approved (design)
**Branch:** `worktree-android-reader-ab-repeat`

## Goal

Bring the iOS Reader's repeat feature to the Android Reader at full parity. iOS
presents three repeat modes through a menu-style picker:

- **Off** — play through without looping.
- **Repeat one** (`loopAll`) — loop the entire score.
- **A–B Loop** (`abLoop`) — loop a user-marked A–B section.

The mode is a global sticky preference; the A–B range is stored per score. When
`abLoop` is active, the user marks point A and point B, each snapping to the
current playback measure, and a translucent band highlights the looped measures.

## Parity Principle

Behavior matches iOS exactly. The iOS state machine lives in
`Packages/Features/Reader/Sources/Reader/RepeatModel.swift` and
`.../RepeatLoop.swift`, which are bound to SwiftUI Observation, GRDB
(`ReaderPreferences`), and the `PlaybackController` protocol — none portable to
Android. The thin state logic (measure-snap, normalize/swap, toggle-off,
mode→loop-range resolution) is reimplemented in Kotlin, mirroring iOS behavior
exactly. This matches the established Android Reader pattern (display inspector,
mixer, A4 calibration): heavy algorithmic work lives in `swift-sheet-music` JNI;
thin UI state lives in Kotlin. UI **placement** follows Android idioms; UI
**content** (labels, icons, mode semantics) matches iOS.

## Existing Foundations (no work needed)

The `swift-sheet-music` Android engine already supports loops:

- `AndroidPlaybackEngine.setLoop(from: ScoreCursor, to: ScoreCursor)`
- `AndroidPlaybackEngine.setLoop(from: ScoreCursor, throughEndOf: ScoreItemID)`
- `AndroidPlaybackEngine.clearLoop()`
- `AndroidPlaybackEngine.loopRange: StateFlow<LoopRange?>` (tick-based, half-open)
- `SheetMusicJNI.nativeLoopHighlightRects(scoreHandle, fromTick, toTick)` → overlay rects
- `ReaderAudioViewModel.currentCursor: StateFlow<ScoreCursor?>` (live playhead)
- `ScoreCursor.Beat(measureIndex, tickInMeasure)` is available on Kotlin.

`LoopRange` is half-open `[startTick, endTick)`.

## Data Model

### RepeatMode (new Kotlin enum)

```kotlin
enum class RepeatMode(val wire: String) {
    OFF("off"),
    LOOP_ALL("loopAll"),
    AB_LOOP("abLoop");
    // wire strings match iOS RepeatMode rawValues for cross-platform consistency
}
```

### AB range

Represented per endpoint by measure/voice/chord indices, mirroring iOS
`ChordPath` (the `systemIndex` is layout-only and unused by the engine, so it is
omitted on Android). For AB-loop purposes the meaningful unit is the **measure**
(A snaps to a measure head, B to a measure end), so the persisted form is the
start and end measure indices plus the snapped voice/chord for fidelity.

```kotlin
data class AbRepeatRange(val startMeasure: Int, val endMeasure: Int)
```

Measure-granular is sufficient: iOS also snaps A/B to measure head/end. Voice and
chord indices are always head/end of the measure, so storing measure indices is
enough to reconstruct the loop and the overlay.

## Persistence

- **Mode (global, sticky):** DataStore key `reader.repeatMode` (string) in
  `SettingsPrefs.kt`, following the existing `clefOverrides` / `a4ReferenceHz`
  pattern. Default `"off"`. Equivalent to iOS `UserDefaults`.
- **AB range (per score):** **First per-score Room persistence on Android.** Add a
  minimal table to `LibraryDatabase` (`FolinoLibraryAndroid`):

  ```
  reader_ab_repeat(scoreId TEXT PRIMARY KEY, startMeasure INT, endMeasure INT)
  ```

  with a `ReaderAbRepeatEntity` + `ReaderAbRepeatDao`, and a v1→v2 additive
  migration (`CREATE TABLE IF NOT EXISTS ...`). YAGNI: scoped to AB repeat only,
  not a general reader-preferences table. Keyed by the same score identifier the
  Reader already uses to open a score. Clearing both endpoints deletes the row.

## State Holder

`ReaderRepeatController` (Kotlin), owned by / surfaced through
`ReaderAudioViewModel`. Holds:

- `mode: StateFlow<RepeatMode>` (sourced from DataStore, written back on change)
- `abRange: StateFlow<AbRepeatRange?>` (loaded from Room for the current score)
- `pendingA`, `pendingB` (transient, not persisted) — staging for an incomplete
  loop, mirroring iOS.

Operations (mirroring iOS `RepeatModel`):

- **`setA()`**: read `currentCursor` → current measure index. If A already set to
  that measure, clear A (toggle). Else `pendingA = measure head`; commit.
- **`setB()`**: same, snapping to measure end (exclusive next-measure head);
  toggle-clear if re-tapped in the same measure.
- **`commitPending()`**: merge pending with existing range; if both endpoints
  exist, `normalize` (swap so A ≤ B), persist to Room, forward to engine; if
  either is missing, clear the range.
- **`setMode(mode)`**: persist to DataStore, re-resolve the active loop range.

### Mode → engine loop range

- `OFF` → `engine.clearLoop()`
- `LOOP_ALL` → loop the whole score (measure 0 head … score end)
- `AB_LOOP` → loop `abRange` (start-measure head … end-measure end), or no loop
  if the range is incomplete.

### Measure → tick resolution (engine wiring)

A (measure head) = `ScoreCursor.Beat(startMeasure, 0)`. The exclusive end of
measure `m` = `ScoreCursor.Beat(m + 1, 0)`. **Open risk:** whether
`Beat(lastMeasure + 1, 0)` resolves for the final measure / full-score loop. The
plan's first step verifies this with `setLoop(from:to:)`. If `Beat`-based cursors
do not resolve robustly at score end, add a small additive helper to
`swift-sheet-music`:

```
nativeMeasureLoopBounds(scoreHandle, fromMeasure, toMeasure) -> (startTick, endTick)
```

mirroring iOS `LivePlaybackController+LoopBounds.loopBounds(for:in:)`. This would
follow the standard ssm flow (worktree → example app verify → report → push →
re-pin in Folino). The plan resolves this before committing to either path.

## UI (Android idiom, iOS-parity content)

### Repeat-mode picker

A Material menu-style picker (`DropdownMenu`/`ExposedDropdownMenuBox`) in
`PlaybackInspectorSheet` "General" section, mirroring iOS inspector placement.
Row: leading `Icons.Default.Repeat` + label "Repeat"/"リピート" + the picker
showing the current mode (mode icon + label + dropdown chevron). Three options:

| Mode | en | ja | Icon |
| --- | --- | --- | --- |
| off | Off | オフ | `repeat` with "off" affordance (Material lacks `repeat.badge.xmark`; use `Icons.Default.Repeat` dimmed, or a Material equivalent) |
| loopAll | Repeat one | 1曲リピート | `Icons.Default.RepeatOne` |
| abLoop | A–B Loop | A–B 区間リピート | reuse iOS `repeat_a_b` asset, or `Repeat` + "AB" affordance |

Strings reuse the exact iOS en/ja values, added to the Android string resources
(en/ja/zh/ko, matching the project's existing 4-locale convention).

### A/B endpoint buttons

Shown **only** when `mode == AB_LOOP`. Because the inspector is a modal bottom
sheet that is dismissed during playback, the A/B controls live in the **transport
area** (near the seek bar; when the seek bar is hidden and the floating FAB is
shown, a compact A/B control sits near the FAB) so they are reachable while
playing. Visual: a two-segment capsule "A" | "B"; each half is accent-tinted when
its endpoint is unset and neutral when set; tap toggles. Mirrors iOS
`ABEndpointPill`, adapted to Material.

### Loop highlight overlay

When `mode == AB_LOOP` and a range is set, draw a translucent accent band over
measures `startMeasure … endMeasure` using
`nativeLoopHighlightRects(scoreHandle, fromTick, toTick)`, mirroring iOS
`LoopRegionOverlay`. Rendered in the same coordinate space as the score canvas
(reuse the existing overlay/transform plumbing used for cursor highlight).

### Settings mirror

iOS duplicates the repeat picker in Settings (global default). Add the same
menu-style picker to the Android Settings Reader section, writing the global
DataStore `reader.repeatMode`.

## Out of Scope

- Playlist continuous-playback interaction ("Repeat on → don't advance to next"):
  Android has no continuous playback yet (iOS-only, unmerged), so there is nothing
  to suppress.
- A general per-score reader-preferences persistence layer: only the AB-repeat
  table is added now.

## Testing

- **Kotlin unit tests** for `ReaderRepeatController`: setA/setB snapping, toggle-off
  on re-tap, normalize/swap when B < A, incomplete-range clears loop, mode
  transitions resolve the correct engine call.
- **Room migration test** v1→v2 (table created, existing data preserved).
- **Manual Pixel verification** (per project rule — Android changes get
  install + launch + manual gesture check): set A/B during playback, hear the
  loop wrap, confirm overlay band, confirm mode persists across app restart and
  AB range persists across score reopen, confirm Settings picker mirrors.

## Risks / Open Questions (resolved in planning)

1. `Beat(lastMeasure+1, 0)` end-tick resolution → may need the small ssm helper.
2. Score-identity key for the Room table must match the identifier the Reader
   uses when opening a score (confirm during planning).
3. Overlay tick→rect plumbing must align with the active layout mode
   (vertical / horizontal / paged); confirm `nativeLoopHighlightRects` output maps
   through the same transform as the cursor highlight in each mode.

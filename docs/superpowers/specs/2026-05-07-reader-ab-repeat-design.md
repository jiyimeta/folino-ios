# Reader A–B Repeat — Design

Date: 2026-05-07
Status: Approved (brainstorming complete, awaiting user spec review)

## Goal

Add a repeat / loop feature to the Reader so the user can practice a passage by
cycling between three modes: **off → loop entire score → A–B section loop**. The
primary use case is practice (slow tempo + repeat a hard 4-bar passage); the
design must also be usable for casual listening and lesson-style navigation.

## Non-goals

- Beat-precision A/B endpoints in v1 (always snapped to measure boundaries).
- Multiple named loop regions per score (only one A/B at a time).
- Cross-score loop persistence beyond what `PlaybackPreferences` already provides.
- Editing the loop with score-internal repeat structures (D.C., volta) — those
  remain orthogonal and are handled by the audio engine when it expands the
  timeline.
- A separate "Clear loop" button. Clearing is a long-press on A/B (rare op).

## User-visible behavior

### Mode cycle button (in Inspector)

A single cycle button lives in `InspectorView`'s **Playback** section, placed
near the existing tempo / metronome controls. Tapping it advances:

```
off  →  loop-all  →  A-B  →  off  →  …
```

State is per-score, persisted in `PlaybackPreferences`. The button shows the
current mode at a glance:

- **off** — repeat icon, secondary tint.
- **loop-all** — repeat icon, accent tint.
- **A-B** — repeat icon with an `A·B` decoration, accent tint.

The exact SF Symbol composition is finalized at implementation time; the
contract is "three visually distinct, instantly readable states."

### A/B pill (overlay on score)

Visible **only when mode == A-B**. Liquid-glass capsule positioned bottom-right
of the Reader, mirroring the existing bottom-left "reset zoom" pill. Two
segments labelled `A` and `B`.

Tap behavior (always-set semantics):

- **Tap A** — set / overwrite A at the head of the cursor's current measure.
- **Tap B** — set / overwrite B at the end of the cursor's current measure.
- **Long-press A or B** — clear that endpoint.

A short haptic confirms each set / clear. Set state is conveyed by:

- Filled vs. outlined segment (filled = set).
- Small subtitle text underneath (`m. 12` etc.) when set, blank when unset.

### Loop region visualization

Visible **only when mode == A-B** and both endpoints are set. The looped span
is shaded on the score with a translucent accent-color band spanning the
affected measures. Suppressed in off / loop-all so the score stays uncluttered
when the band would not correspond to the active loop.

### Playback semantics

| Cursor position when play pressed | Behavior |
| --- | --- |
| `cursor < A` | Play through normally. After reaching B, jump to A; loop thereafter. |
| `A ≤ cursor ≤ B` | Play through. At B, jump to A; loop thereafter. |
| `cursor > B` | Immediately seek to A, then play and loop. |

Same rule applies mid-playback: if the user re-sets B such that the live
playback cursor ends up past the new B, the engine seeks to A on the next
audio frame.

### Edge cases

- **A > B (user sets B in an earlier measure than A)** — auto-swap. The
  on-screen labels also swap so that A is always the earlier marker and B
  the later one. The user sees the labels normalize after the second tap;
  internally the engine receives `start = min, end = max`.
- **Only one of A/B set in mode A-B** — loop is inactive, playback proceeds
  normally. The unset segment shows its placeholder label and pulses subtly to
  invite a tap.
- **Mode toggled off mid-playback** — playback continues uninterrupted, the
  loop is simply removed. No pause / restart.
- **Markers preserved across mode toggles** — entering A-B again shows the
  previous A/B. Persisted per-score in `PlaybackPreferences.abRepeat`.
- **Score-internal repeats (D.C., voltas)** — orthogonal. The engine plays
  whatever the score timeline expands to. `loop-all` simply seeks to the very
  first chord after reaching the last chord. `A-B` clamps within the
  user-selected measure span.

### Snap rule (measure-quantized)

Endpoints always snap to measure boundaries:

- **A** — first chord of the cursor's current measure
  (`voiceIndex = 0, chordIndex = 0` for that measure).
- **B** — last chord of the cursor's current measure (max chord index within
  the measure across all voices, since `ABRepeatRange` endpoints are inclusive).

A 1-bar loop = A and B in the same measure: A at the first chord, B at the
last chord, distinct positions even though the bar is the same.

## Data model

### `RepeatMode` (new, Domain)

```swift
public enum RepeatMode: String, Hashable, Sendable, Codable {
    case off
    case loopAll
    case abLoop
}
```

### `ReaderPreferences` (extended — actual persistence site)

`ReaderPreferences` is the per-score record the repository persists today
(`tempoMultiplier`, `hiddenStaves`, `staffProgramOverrides`). Loop state lives
here so it survives across launches and CloudKit sync, alongside the other
per-score Reader prefs:

```swift
public struct ReaderPreferences {
    // existing fields …
    public var repeatMode: RepeatMode      // new, default .off
    public var abRepeat: ABRepeatRange?    // new, default nil
}
```

`Codable` migration: both new fields are decoded with `.off` / `nil` defaults
when absent, so existing records round-trip cleanly.

`PlaybackPreferences` (the transport struct passed into `engine.load`) keeps
its existing `abRepeat` field; the Reader VM populates it from
`ReaderPreferences` when calling `initialPlaybackPreferences(for:)`.

### `PlaybackController` protocol (no new methods)

The existing `setLoopRange(_ range: ABRepeatRange?) async` is the contract:

| Mode | Argument |
| --- | --- |
| `.off` | `nil` |
| `.loopAll` | `ABRepeatRange(start: <first chord>, end: <last chord>)` |
| `.abLoop` (both set) | the user's `abRepeat` |
| `.abLoop` (one or zero set) | `nil` (loop inactive) |

**Implementation note:** `swift-sheet-music`'s `PlaybackEngine` does not yet
expose a loop primitive — `LivePlaybackController.setLoopRange(_:)` is
currently an empty stub. v1 implements the loop entirely in
`ReaderViewModel` by observing `playbackCursor` and re-issuing
`setCursor(to:)` (which routes through `engine.play(from:in:)` while playing)
when the cursor crosses the upper bound. The controller still receives the
`setLoopRange` calls so a future engine-level loop can take over without
churning the VM.

## Architecture

```
                  ┌──────────────────────────────────┐
                  │ InspectorView (Reader)           │
                  │  ├ Playback section              │
                  │  │  ├ tempo / metronome (exists) │
                  │  │  └ RepeatModeButton (NEW)     │
                  │  └ Visual section (unchanged)    │
                  └──────────────┬───────────────────┘
                                 │ binds to
                                 ▼
              ┌────────────────────────────────┐
              │ ReaderViewModel                │
              │  + repeatMode: RepeatMode      │   ──── persists via
              │  + abRepeat:   ABRepeatRange?  │       repository (existing)
              │  + onAdvanceMode()             │
              │  + onTapA() / onTapB()         │   ──── snap to measure
              │  + onLongPressA() / B()        │       (new helper)
              └──────────────┬─────────────────┘
                             │ effectiveLoopRange()
                             ▼
              ┌────────────────────────────────┐
              │ PlaybackController             │
              │  setLoopRange(_:)              │ existing, unchanged
              └────────────────────────────────┘

         ┌───────────────────────────────┐
         │ ReaderView                    │
         │  ├ score canvas               │
         │  │   └ LoopRegionOverlay (NEW)│   translucent band
         │  └ ReaderBottomOverlay        │
         │      ├ ResetZoomPill (exists) │
         │      └ ABPill (NEW, gated on  │
         │              mode == .abLoop) │
         └───────────────────────────────┘
```

### New view-model surface

```swift
extension ReaderViewModel {
    public var repeatMode: RepeatMode { get }
    public var abRepeat: ABRepeatRange? { get }

    public func advanceRepeatMode() async      // cycles off → all → AB → off
    public func setRepeatA() async             // snap+set A at cursor
    public func setRepeatB() async             // snap+set B at cursor
    public func clearRepeatA() async
    public func clearRepeatB() async
}
```

Each mutator:
1. Computes the snapped `ChordPath` from the current cursor's measure.
2. Updates `abRepeat` (or `repeatMode`).
3. Persists via the existing repository path that handles
   `PlaybackPreferences`.
4. Calls `effectiveLoopRange()` and forwards the result to
   `playbackController.setLoopRange(...)`.

`effectiveLoopRange()` is internal logic:

```swift
func effectiveLoopRange() -> ABRepeatRange? {
    switch repeatMode {
    case .off: return nil
    case .loopAll: return scoreFullRange()   // computed from score model
    case .abLoop:
        guard let r = abRepeat,
              isValid(r) else { return nil }   // both endpoints set
        return normalize(r)                    // auto-swap if start > end
    }
}
```

### Snap helper (new, Reader)

A small pure function in the Reader package:

```swift
func snapMeasureHead(cursor: ChordPath, score: Score) -> ChordPath
func snapMeasureEnd(cursor: ChordPath,  score: Score) -> ChordPath
```

These walk the score's measure structure (already accessible via the existing
score model used for cursor mapping) and return the first / last chord position
within the cursor's current measure. Pure, easy to unit-test.

### New views (Reader package)

- `RepeatModeButton` — three-state cycle button. Owns icon composition and
  accessibility label transitions.
- `ABPill` — bottom-right liquid-glass capsule, two segments. Drives the
  view-model mutators on tap / long-press. Hidden when `repeatMode != .abLoop`.
- `LoopRegionOverlay` — drawn over the score canvas. Translucent accent band
  spanning the looped measures. Reuses whatever measure-rect lookup the
  cursor renderer already uses.

`ReaderBottomOverlay` is extended to host the `ABPill` alongside the existing
reset-zoom button.

## Layout / form factor

- **iPad regular** — Inspector is a side panel, score and inspector are
  visible simultaneously. The cycle button is visible at all times; the A/B
  pill sits at the score's bottom-right. No sheet trips.
- **iPhone compact** — Inspector is a sheet, but the user only opens it once
  per practice session to flip into A-B mode. Once in A-B mode, the A/B pill
  on the score is fully self-sufficient. The user can also see "I'm in A-B
  mode" because the pill is visible whenever the mode is active.
- **First-run discoverability (compact)** — initial release ships without an
  onboarding callout. We rely on the fact that A-B is a power-user feature
  that practice-oriented users will look for. Revisit if telemetry shows
  low discovery.

## Persistence

`ReaderPreferences` is the per-score record persisted by the existing
repository (CloudKit-backed per the Infrastructure layer). Adding
`repeatMode` and `abRepeat` extends the existing `Codable` envelope; legacy
records decode with `.off` / `nil`. No migration required. The view model's
`mutatePreferences` path already routes through
`repository.saveReaderPreferences`, so the new fields persist automatically
when set.

## Testing

- **Domain**: `RepeatMode` round-trip Codable; `PlaybackPreferences` legacy
  decode (no `repeatMode` field) → `.off`; auto-swap helper for `A > B`.
- **Reader (view model)**:
  - `advanceRepeatMode` cycles correctly and forwards the right
    `setLoopRange` argument for each mode.
  - `setRepeatA` snaps to the first chord of the cursor's measure.
  - `setRepeatB` snaps to the last chord of the cursor's measure.
  - `cursor > B` → forwarded `setLoopRange` triggers seek-to-A semantics
    (verified against `FakePlaybackController`'s recorded calls and the
    cursor seed).
  - Markers preserved when toggling A-B → off → A-B.
  - `loopAll` mode passes a range covering the whole score.
- **Reader (view)**: snapshot tests for the cycle button's three states and
  the A/B pill's set/unset variants. Snapshot the loop-region overlay over a
  representative score.

## Open implementation questions (for the plan, not this spec)

1. Exact SF Symbols composition for the three mode states — finalized when
   prototyping in Xcode preview.
2. The measure-rect API used by `LoopRegionOverlay` — needs to confirm what
   the existing cursor renderer exposes vs. needs a small extension on the
   score layout side.
3. Whether `setRepeatA` while playing should fire a tiny haptic *and* a
   visible flash on the band — design polish, not behavior.

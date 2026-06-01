# Reader time-based seek bar — design

**Status:** Draft for review
**Date:** 2026-06-01
**Feature package:** `Packages/Features/Reader`
**Touches:** `Reader`, `Domain`, `Settings`

## Goal

Add a time-based seek bar to the Reader's bottom playback control so users can scrub
through a score by playback time. The control widens to the full screen width (with
horizontal margins) so the bar is large and easy to operate. A Settings toggle lets users
who prefer maximum score area turn the bar off, reverting to today's compact control.

"Time-based" means the bar position is proportional to elapsed **playback duration**
(tempo-weighted), not to measure count — a slow section occupies proportionally more of the
bar than a fast one with the same measure count.

## Key constraint that shaped the design

`PlaybackController` (Domain protocol) exposes no absolute seek-by-time. It has
`currentTimeSeconds` / `totalTimeSeconds` (sync getters), `skip(bySeconds:)` (relative), and
`setCursor(to: ScoreCursor)` (absolute by notated position). Rather than add a new protocol
method — a Domain API change that ripples across Features and needs separate sign-off — the
seek path is built entirely on the existing `setCursor(to:)`, plus a Domain-side time↔cursor
map computed from the score's tempo and measure data. **No `PlaybackController` change.**

## Non-goals

- No repeat/AB-loop timeline expansion. The bar maps over the **notated** timeline (each
  measure counted once). Scrubbing navigates notated position; the engine handles repeats at
  play time as it does today.
- No numeric time labels (elapsed / remaining / total). The bar is label-free and full width.
- No change to vertical-mode viewport bounds.
- No new `PlaybackController` / Domain protocol method.

## Decisions (from brainstorming)

| Question | Decision |
| --- | --- |
| Control layout when ON | Seek bar on top, transport row below, inside one full-width glass card |
| Setting default (new installs) | ON |
| Time labels | None |
| Scrub behavior | During drag: suspend following the real cursor; show a provisional cursor and auto-scroll / page-turn the score to it. Audio + real cursor jump only on release. |
| Seek control widget | Plain SwiftUI `Slider` (value `0...1`, `onEditingChanged`) — not `ResettableSlider`, no double-tap reset |

## Components

### 1. Setting: `showSeekBarEnabled`

- Add to `ReaderGlobalSettingsKey` (Domain, `ReaderLayoutMode.swift`):
  `public static let showSeekBarEnabled = "readerShowSeekBarEnabled"`.
- Settings `readerSection` (`SettingsSheet.swift`): a `Toggle` bound to
  `@AppStorage(ReaderGlobalSettingsKey.showSeekBarEnabled)` defaulting to `true`, with a
  `Label` using a new localized key `settings.reader.showSeekBar` and an SF Symbol
  (candidate: `waveform`).
- `ReaderRootScreen` reads the same `@AppStorage` and passes the bool into
  `ReaderBottomOverlay` and into the viewport-inset computation.

### 2. Domain time↔cursor map

New `Score` extension (Reader-local extension file alongside `Score+EffectiveTempo.swift`, or
Domain if it needs to be shared — Reader-local is fine since only the Reader uses it):

- `var notatedDurationSeconds: Double` — total notated duration, tempo-integrated.
- `func seconds(at cursor: ScoreCursor) -> Double` — cumulative seconds from score start to
  the cursor.
- `func cursor(atSeconds seconds: Double) -> ScoreCursor` — inverse; returns
  `.beat(measureIndex:tickInMeasure:)`, clamped to `0 ... notatedDurationSeconds`.

Computation: walk measures using `effectiveMeasureDurations()` (ticks per measure) and
`division` (ticks per quarter). Seconds for a tick span at quarter-BPM `b` is
`ticks / division × (60 / b)`. Tempo comes from the existing `governingTempo(at:)` /
`effectiveQuarterBpm(at:)`. Mid-measure tempo changes integrate per tempo segment; measure
granularity is acceptable for v1 and can be refined without changing the call sites.

Notes:
- The global tempo multiplier (`TempoModel`) scales all tempos uniformly, so the normalized
  fraction `seconds(at:) / notatedDurationSeconds` is invariant to it — the multiplier is
  ignored here. Local (in-score) tempo changes are included via `governingTempo`.
- Scores with no tempo marking fall back to 120 quarter-BPM (existing `effectiveQuarterBpm`
  default), so the map is always defined for a non-empty score.

### 3. Scrub state on `ReaderPlaybackSession`

Add:

- `private(set) var scrubCursor: ScoreCursor?` — the provisional drag position (observable).
- `var displayCursor: ScoreCursor? { scrubCursor ?? playbackCursor }` — what the score views
  render and auto-scroll to.
- `func beginScrub()` — marks scrub start (sets `scrubCursor` to the current `playbackCursor`
  so the provisional cursor starts where the real one is).
- `func updateScrub(toFraction fraction: Double)` — `scrubCursor =
  score.cursor(atSeconds: fraction × score.notatedDurationSeconds)`; fires `onCursorChanged()`
  so the containers re-scroll.
- `func endScrub()` — commits: `controller.setCursor(to: scrubCursor)`, set
  `rawPlaybackCursor` / `playbackCursor` to the committed cursor, clear `scrubCursor`, fire
  `onCursorChanged()`.

During a drag the real cursor stream keeps arriving (audio plays on), but the views render
`displayCursor`, so they follow the provisional cursor, not the advancing real one. On release
audio + real cursor jump to the provisional position via the existing `setCursor(to:)`.

### 4. Score containers consume `displayCursor`

`ReaderRootScreen.content` passes `viewModel.playbackSession.displayCursor` (instead of
`playbackCursor`) into `VerticalScoreContainer` / `HorizontalScoreContainer` /
`PagedScoreContainer`. Their existing cursor-driven highlight + auto-scroll / pagination then
follow the provisional cursor while scrubbing with no further change.

### 5. Bottom control redesign (`ReaderToolbar.swift` → `ReaderBottomOverlay`)

`ReaderBottomOverlay` takes the new `showSeekBar: Bool`.

- **OFF (`showSeekBar == false`):** unchanged from today — reset-zoom pill (leading float),
  A/B endpoint buttons (AB-loop only), right-aligned transport pill. No visual change.
- **ON (`showSeekBar == true`):** a single full-width glass card:
  - Top row: the seek `Slider` (label-free, full width inside the card margins).
  - Bottom row: transport buttons (`⏮ ◀◀ ▶ ▶▶`), with A/B endpoint buttons on the trailing
    side when in AB-loop mode.
  - reset-zoom stays a separate leading float above the card (not inside it), unchanged.
  - Background: a `RoundedRectangle` with rounded top corners that bleeds to the screen's
    bottom edge, via `.ignoresSafeArea(edges: .bottom)` **only** — bottom safe area is
    ignored (glass reaches the edge under the home indicator), left/right safe areas are
    **not** invaded. Horizontal margins remain.
  - Foreground content: `.padding(.bottom, <bottom safe-area inset>)` so controls sit above
    the home indicator.

Seek `Slider` binding:

- `value` is a computed `Binding<Double>` over `0...1`.
  - `get`: `isScrubbing ? scrubFraction : score.seconds(at: playbackCursor) / notatedDuration`
    (re-renders as `playbackCursor` updates during playback).
  - `set`: store `scrubFraction` and call `session.updateScrub(toFraction:)`.
- `onEditingChanged`: `true` → `session.beginScrub()`; `false` → `session.endScrub()`.
- `isScrubbing` is local `@State` flipped in `onEditingChanged`.

### 6. Viewport limiting (horizontal & page modes, ON and OFF)

`ReaderRootScreen` applies a bottom inset to `content` so the score never renders under the
control — mirroring the existing `.safeAreaPadding(.top, ReaderTopOverlay.height)`:

- Only in **horizontal** and **page** modes. **Vertical** mode gets no bottom inset (score is
  allowed to scroll under the floating control, as today).
- Inset value = `ReaderBottomOverlay` content height for the current state:
  - ON: seek row + transport row + internal padding (excludes the safe-area bleed region).
  - OFF: transport row + padding (today's control height).
- Provide these as static constants on `ReaderBottomOverlay`
  (e.g. `collapsedContentHeight`, `expandedContentHeight`), matching the existing
  `ReaderTopOverlay.height` pattern. `.safeAreaPadding(.bottom, …)` stacks above the existing
  bottom safe area, so the constants exclude the safe-area inset itself.

This bottom inset is the reason the viewport must shrink even when the bar is OFF: the
existing control already overlays the score's bottom-right corner, so horizontal/page mode
should reserve space for it regardless of the toggle.

## Data flow (scrub)

```
drag begins  → Slider.onEditingChanged(true)  → session.beginScrub()
drag moves   → Slider value set → session.updateScrub(toFraction:)
                 → scrubCursor = score.cursor(atSeconds: fraction × notatedDuration)
                 → onCursorChanged() → containers re-scroll to displayCursor (provisional)
drag ends    → Slider.onEditingChanged(false) → session.endScrub()
                 → controller.setCursor(to: scrubCursor)   (audio + real cursor jump)
                 → clear scrubCursor → displayCursor falls back to playbackCursor
```

## Testing

- **Domain time map (Swift Testing):** round-trip `seconds(at:)` ↔ `cursor(atSeconds:)` at
  endpoints and interior points; constant tempo; a mid-score tempo change; no-tempo fallback
  (120 BPM); single-measure score; clamping below 0 and above total.
- **Scrub state (Swift Testing, fake `PlaybackController`):** `beginScrub` seeds `scrubCursor`
  from `playbackCursor`; `updateScrub` moves it and `displayCursor` reflects it while
  `playbackCursor` is untouched; `endScrub` calls `setCursor(to:)` once with the provisional
  cursor and clears `scrubCursor`.
- **Manual / preview:** card layout in ON vs OFF, full-width with margins, glass bleeding to
  the bottom edge but not into left/right safe areas; horizontal & page viewport shrinks above
  the control in both ON and OFF; vertical mode unchanged.

## Risks / open notes

- **Engine time vs computed time:** audio seek uses `setCursor(to:)` (notated position), and
  the live thumb derives from the same Domain map via `playbackCursor`, so the bar and the
  audio stay consistent without depending on `currentTimeSeconds`. Scores with repeats make
  the thumb revisit earlier positions when a section repeats — acceptable for v1 (the thumb
  reflects current notated position).
- **Control height constants:** static constants are predictable here (seek row is our own
  fixed height; transport is 44pt). If content height drifts, switch to an
  `onGeometryChange` measurement feeding the inset — call sites stay the same.
- **Slider thumb smoothness:** updates at cursor (note) granularity during playback. If it
  reads choppy on long notes, add `.animation(.linear, value:)` tweening; no API change.

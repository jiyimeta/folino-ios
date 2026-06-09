# Playlist Continuous Playback — Design

**Date:** 2026-06-09
**Status:** Approved (design) — ready for implementation plan
**Scope:** iOS first; Android follows at logic parity (see Parity).

## Problem

When the user opens a score from a playlist and plays it, playback stops at
the end of that single score. We want the Reader to optionally continue into
the next score in the playlist automatically — **continuous playback, default
ON, but toggleable OFF**.

The hard part is cognitive, not technical. Folino already has a per-score
**repeat** control (`RepeatMode { off, loopAll, abLoop }`) that also decides
"what happens when playback reaches the end of the score." Continuous playback
adds a second answer to the same question ("advance to the next score"). If
both can be ON at once, the user faces a precedence puzzle. The design's job is
to make that puzzle structurally impossible.

## Final Model — one priority ladder, no truth table

Repeat **always wins**; continuous playback is subordinate. This yields a
single ladder with no "both ON" state:

- **repeat = 1曲 (loopAll) / A–B (abLoop)** → the current score loops; playback
  never advances. The continuous-playback control is shown **disabled (greyed)**
  with a hint: "リピート中は次の楽譜へ進みません".
- **repeat = off** → the continuous-playback control is **enabled**, with three
  mutually-exclusive choices:
  - **オフ** — stop at the end of this score.
  - **連続再生** — play through the playlist, stop after the last score. **(default)**
  - **全曲リピート** — play through the playlist; after the last score, wrap to
    the first and continue.

There is no reverse disabling. The relationship is one-directional: repeat is
primary, continuous is subordinate. Because the continuous control is only
reachable when `repeat == off`, the two can never both be active.

Why repeat-wins (not continuous-wins): with `repeat` defaulting to `off` and
continuous defaulting to ON, the common case — open a playlist, hit play —
traverses correctly with zero configuration. A user who explicitly sets "1曲"
or "A–B" to drill a passage gets exactly that; continuous quietly steps aside.
The explicit per-score choice is honored over the ambient default.

## Configuration & Persistence

- The continuous-playback value is a **single global, sticky enum** (one value
  shared everywhere). It is **not** per-score and **not** per-playlist.
- Surfaced in **two places, reading/writing the same value**:
  1. **Reader playback inspector** — shown **only when the Reader was opened in
     a playlist context**. In standalone (non-playlist) context the control is
     not rendered at all (behavior is unchanged from today).
  2. **Settings sheet** — always shown, never disabled (there is no live repeat
     state to gate against in Settings). A caption explains the precedence:
     "楽譜ごとに『1曲／A–B リピート』を設定している場合は、そちらが優先されます"
     (wording TBD).
- Changing the value in the inspector changes the global default for future
  sessions too (sticky), matching the mental model of repeat/shuffle in media
  players. This is the behavior implied by "same control in both places."

## Naming (proposed — finalize during implementation)

- **Control heading:** `プレイリスト` (or omitted), segmented `[ オフ | 連続再生 | 全曲リピート ]`.
- **Internal enum (English):**
  ```swift
  enum PlaylistContinuationMode {
      case off          // stop after the current score
      case playThrough  // advance through the playlist, stop after the last
      case loopPlaylist // advance, then wrap to the first after the last
  }
  ```
- **Global key:** `ReaderGlobalSettingsKey.playlistContinuationMode`
  (stored via `@AppStorage`, raw value backed). Default = `.playThrough`.

These names are straw-man; user reserves the right to adjust copy and identifiers.

## Architecture

### Reader playback provenance (the main new plumbing)

Today the Reader receives only a `ScoreItem`
(`ReaderRootScreen.init(scoreItem:)`) and the navigation
(`.navigationDestination(for: ScoreItem.self)`) discards where the open came
from. The Reader cannot tell "opened from a playlist" from "opened standalone."

Introduce an **optional playback queue** passed into the Reader when, and only
when, the open originates from a playlist:

- Contents: the **ordered, live** `ScoreItemID`s of the playlist (already
  derivable via `PlaylistPresentation.orderedLiveIDs()`), the **current index**,
  and optionally the originating playlist id (for re-deriving liveness on
  advance).
- `nil` queue ⇒ standalone mode ⇒ continuous-playback control is hidden and no
  auto-advance occurs.

Exact type name/shape (e.g. a `ReaderPlaybackQueue` value type in Domain vs. a
Reader-local model) is an implementation-plan decision; the queue's *contents*
and *meaning* are fixed here. Threading it through navigation will require
extending the Library → Reader handoff
(`PlaylistDetailScreen.onOpen` → `LibraryRootScreen` navigation destination →
`ReaderRootScreen`) to carry the queue alongside the `ScoreItem`.

### Advance logic

End-of-score is already detected in `ReaderPlaybackSession.startObservingCursor()`
— the engine sets the cursor to `nil` while `isPlaying`
(`ReaderPlaybackSession.swift:190`). At that point, the advance decision is:

```
if repeat != off            → loop current score (existing behavior); do not advance
else if queue == nil        → stop (standalone)
else switch continuationMode:
    .off          → stop
    .playThrough  → if next index exists: load + auto-play next; else stop
    .loopPlaylist → if next index exists: load + auto-play next;
                    else: load + auto-play first (wrap)
```

- Advancing **auto-starts** playback on the loaded score (continuous implies
  auto-play). A brief load gap between scores is acceptable.
- Each advanced score loads **its own `ReaderPreferences`** — tempo multiplier,
  master/staff volumes, transpose, layout, etc. apply per score, exactly as if
  the user had opened it directly.
- The continuous value is **re-read at each end-of-score** (it is global and may
  have changed mid-session via Settings).

### Shared logic (Domain)

The ladder, the queue model, and the advance/wrap rules are **pure logic** and
belong in Domain so both platforms call the same code (per repo parity rule).
The continuation-mode decision should be expressed as a small pure function,
e.g. `nextAction(currentIndex:queue:repeatMode:continuationMode:) -> AdvanceAction`
returning `.stop | .advance(index) | .loop`, unit-testable without an engine.

## Edge cases

- **Deleted / soft-deleted score mid-session:** skip non-live ids when
  advancing (re-filter via `orderedLiveIDs()` / live check). If no live next
  score remains, stop (or wrap for `loopPlaylist`).
- **Single-item playlist:** `playThrough` stops after the one score;
  `loopPlaylist` loops that one score (effectively the same as 1曲 — acceptable,
  no special-casing).
- **Standalone open:** no control, no auto-advance — unchanged from today.
- **repeat = 1曲 / A–B:** never advances regardless of continuation mode; the
  continuous control is disabled in the inspector.
- **User navigates back to Library mid-playlist:** the Reader session ends
  normally; no background continuation.
- **Continuation value changed in Settings while a playlist is playing:** picked
  up at the next end-of-score (re-read each time).

## Testing

- **Domain (pure):** `nextAction(...)` truth table across `repeatMode` ×
  `continuationMode` × position (first / middle / last) × queue size
  (empty / single / many). Verify wrap, stop, and "repeat wins → no advance."
- **Reader (fakes):** end-of-score (`cursor == nil`) drives advance; advanced
  score loads its own preferences; standalone (`queue == nil`) never advances;
  disabled-control state when `repeat != off`. Uses hand-written fakes for the
  playback controller and preferences store (no real audio engine).
- No simulator run required for logic; UI verification of the inspector control
  (enabled/disabled, default selection) via SwiftUI preview.

## Parity (Android, follow-up)

- **Logic** (ladder, queue, `nextAction`, advance/wrap, liveness skipping) is
  shared in Domain and called by both platforms — not reimplemented.
- **UI placement** follows Android idioms: the continuation control lives in the
  Android Reader's playback inspector and Settings using Material patterns; the
  *content* (three modes, default ON, repeat-priority caption) stays at iOS
  parity. Android lands after the iOS implementation is verified.

## Out of scope (YAGNI)

- Per-playlist or per-score continuous override (explicitly rejected: global
  sticky only).
- "Repeat N times then advance" counts.
- Cross-fade / gapless transitions between scores.
- Shuffle.

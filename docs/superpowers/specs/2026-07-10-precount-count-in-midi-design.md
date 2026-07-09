# Precount (Count-In) via MIDI Sequencer Pre-Roll — Design

- **Date**: 2026-07-10
- **Status**: Design approved; proceeding to plan + implementation.
- **Supersedes**: `2026-07-09-precount-count-in-design.md` (the separate-`AVAudioEngine` approach) and its Folino branch `worktree-precount-count-in`. That approach shipped to on-device test and failed on two counts (below); this redesign replaces it.
- **Repos**: swift-sheet-music (engine — worked on `main`, dev clone `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music`) + Folino (thin consumer — new worktree `worktree-precount-count-in-midi`).

## 1. Why the pivot

The count-in is: press play with the toggle on → sound a metronome count-in (one prepended measure + mid-measure lead-in), cursor pinned at the start tick, then playback begins. The *musical rules* are unchanged from the prior spec (§3 there / §4 here); only the *playback mechanism* changes.

The prior approach played the count-in clicks on a **separate `AVAudioEngine`** (raw WAV buffers) before starting the score's `AVAudioSequencer`. On device it failed twice:

1. **Volume mismatch** — the in-playback metronome is rendered by the engine's AUMIDISynth at MIDI velocity 100/80 through the metronome SF2; a separate raw-WAV player can only *approximate* that loudness (AUMIDISynth's velocity→amplitude curve is closed-source). Ear-tuning `(velocity/127)` then `(velocity/127)²` never matched.
2. **Handoff timing drift** — the separate engine's clock and the sequencer's `start()` are independent, so the seam between the last count-in click and the first note jittered (~5–15 ms, audible).

Both are *structural* to the separate-engine design. A sample-accurate handoff **requires the count-in and the score to share one continuous sequence**, and an exact volume match **requires the clicks to go through the same metronome synth**. Both point to the engine. Hence: move the count-in into the swift-sheet-music playback engine as a **pre-roll region prepended to the score's MIDI sequence**.

## 2. Architecture — where the logic lives now

| Concern | Home | Notes |
|---|---|---|
| Count-in beat computation (prepended measure + anacrusis right-align + lead-in) | **ssm `SheetMusicAudioCore` — new `CountInBeats`** | Pure, tick-based, cross-platform (iOS + Android ssm both use it → parity automatic). Reuses `MetronomeBeat`'s carried-forward-meter walk. |
| Count-in playback (pre-roll region in the sequence, cursor pinning, tick translation) | **ssm `SheetMusicAudioApple` — `PlaybackEngine` + `MetronomeController`** | iOS engine. Android gets its own player later (out of scope). |
| Toggle persistence + UI | **Folino** (unchanged from the prior branch's Task 2/6) | `ReaderGlobalSettingsKey.precountEnabled`, `SettingKey.precount`, Settings + inspector rows. |
| Orchestration | **Folino `ReaderPlaybackSession`** — a single `countIn:` flag | Collapses to `controller.play(countIn: isPrecountEnabled())`. |

**Removed from Folino** (the prior approach's machinery, now unnecessary): `Domain/Logic/PrecountPlan.swift`, `Domain/Protocols/PrecountPlayer.swift`, `Infrastructure/Audio/LivePrecountPlayer.swift`, the `ReaderPlaybackSession` precount orchestration (`isPrecounting`, `precountPlayer`, `precountTask`, `runPrecount`, `cancelPrecount`, the cancel hooks), and the `precountPlayer` injection chain. The prior branch's `PrecountPlan` *tests/rules* port to ssm's `CountInBeats` tests. The user's anacrusis decision (**right-align the pickup as an upbeat**: `1 2 3 4 | 1 2 3 [pickup]`) is preserved.

## 3. The engine mechanism (ssm)

The engine builds one in-memory SMF loaded into one `AVAudioSequencer` (see the exploration notes). Ticks cannot be negative (`MidiWriter` requires monotonic non-negative deltas; sequencer origin is tick 0). So a pre-roll is encoded as **real ticks ahead of the score content**, with the score shifted forward and the cursor pinned during the pre-roll.

### 3a. `play(from: startCursor, in: score, countIn: true)`

1. `let plan = CountInBeats.compute(score: score, startCursor: startCursor)` → `preRollTicks` + the pre-roll click beats (`[MetronomeBeat]`, ticks in `[0, preRollTicks)`) + the governing quarter-BPM at `startCursor`.
2. `baseTick = timeline.frame(forCursor: startCursor)?.tick ?? 0` — the score tick playback begins at.
3. Build the sequence (SMF):
   - **Pre-roll click track** (ticks `[0, preRollTicks)`): built from `plan.beats` via the existing `MetronomeController.metronomeTrack(beats:division:)` (channel 9, notes 76/77, velocity 100/80 → **identical sound/level to the metronome**). Attached to a track whose mute is **NOT** tied to `metronome.isEnabled`, so it sounds even when the metronome toggle is off.
   - **Score content** (ticks `≥ baseTick`), shifted to `[preRollTicks, preRollTicks + (endTick − baseTick))` — i.e. events `< baseTick` are dropped, the rest shifted by `(preRollTicks − baseTick)`.
   - **Body metronome track** (toggle-gated, as today), same shift, beats `≥ baseTick`.
   - **Tempo/time-sig meta**: the score's tempo map filtered/shifted like the content, plus a tempo event at seq tick 0 = the governing tempo at `startCursor`, so the pre-roll plays at the correct tempo. The global `rate` (tempo multiplier) applies on top, unchanged.
4. Load + `sequencer.currentPositionInBeats = 0` + `start()`.
5. Store `SequenceMap { preRollTicks, baseTick }` on the engine (nil / identity when `countIn == false`).

### 3b. Tick translation (`SequenceMap`)

The map is applied only where the engine reads/writes the raw sequencer position:

```
seqTick → scoreTick:  seqTick < preRollTicks ? nil (pre-roll)  : baseTick + (seqTick − preRollTicks)
scoreTick → seqTick:  preRollTicks + (scoreTick − baseTick)     (for scoreTick ≥ baseTick)
```

- `tickCursor()`: `nil` (pre-roll) → keep `currentCursor` pinned at `startCursor`; else map to `timeline.frame(atTick: scoreTick)?.cursor`. **Cursor stays put until real playback begins.**
- `currentTimeSeconds`, `skip(by:)`, `seek`: translate through the map.
- **Loop wrap**: `loopRange` stays in score ticks; the wrap seeks to `toSeq(loop.startTick)`. Since the pre-roll occupies seq `[0, preRollTicks)` and all score content (incl. the loop) is at seq `≥ preRollTicks`, the wrap never re-enters the pre-roll → **the count-in fires once, loops replay only the body**. (Repeat composes for free.)
- End-of-score detection: unchanged once translated.

`PlaybackTimeline` stays entirely in score ticks (no changes to its internals) — the offset lives in the engine's position reads.

### 3c. When `countIn == false`

`SequenceMap` is identity/nil; the sequence is built exactly as today (no pre-roll track, no shift). Zero behavior change to normal playback.

## 4. The count-in algorithm (`CountInBeats.compute`) — unchanged rules, tick-based

Ported verbatim in behavior from the prior spec §3 (all worked-checks and the user's right-align decision hold). Given a start cursor → `(s = startMeasureIndex, o = tickInMeasure)`, `division`:

```
1. TS   = carried-forward nominal TimeSignature governing measure s (default 4/4). NO m2 borrow.
2. step = max(1, division*4/TS.denominator);  N = TS.numerator;  nominalTicks = N*step
3. actualTicks(s) = measures[s].actualLength?.ticks(division)
                    ?? Σ(voice-0 chord ticks, .measure rests resolved)   // MusicXML pickup
4. shim = isScoreAnacrusis(s) ? (nominalTicks − actualTicks(0)) : 0        // s==0 only; both encodings
5. preRollTicks = nominalTicks + shim + o
6. Pre-roll beats at tick k*step for k = 0,1,… while k*step < preRollTicks.
   isDownbeat (strong) when k == 0 or k == N; else weak.
7. quarterBpm = effectiveQuarterBpm(at: startCursor)   // rate multiplier applied globally by the engine
   → returned so the engine seeds the pre-roll tempo event.

isScoreAnacrusis(s) := s == 0 && ( measures[0].irregular
                                   || (0 < actualTicks(0) && actualTicks(0) < nominalTicks(0)) )
```

`CountInBeats` returns `(preRollTicks: Int, beats: [MetronomeBeat], quarterBpm: Double)` (or nil for degenerate scores → engine plays no pre-roll). It lives in `SheetMusicAudioCore` next to `MetronomeBeat.swift` and reuses that file's per-measure carried-forward-TS walk and `.measure`-resolving content sum.

Worked checks (must hold, from the prior spec): 4/4 measure-start = 4 clicks (1 strong); 4/4 beat-3 = 6 clicks (strong k=0,4); MuseScore + MusicXML 1-beat pickup from the pickup bar = 7 clicks (strong k=0,4, right-aligned upbeat); pickup started mid-piece = no shim; mid-score TS change read at the START measure; 6/8 = 6 clicks at eighth step; 2/2 = 2 clicks at half step; empty → nil.

## 5. Folino side (thin)

- `PlaybackController.play()` → `play(countIn: Bool = false)` (Domain protocol). `LivePlaybackController.play(countIn:)` forwards to `engine.play(from: pendingCursor, in: score, countIn:)`.
- `ReaderPlaybackSession.togglePlayback()` play branch → `try await controller.play(countIn: isPrecountEnabled())`. No separate player, no `isPrecounting`, no cancel hooks — pausing during the count-in is an ordinary `controller.pause()` (the sequencer is running; the cursor is pinned so it stays put).
- `isPrecountEnabled: () -> Bool` (reads `ReaderGlobalSettingsKey.precountEnabled`) stays.
- Keep: `ReaderGlobalSettingsKey.precountEnabled`, `SettingKey.precount` (+ caseToken), the Settings toggle, the inspector row, both `Localizable.xcstrings` entries (all from the prior branch — re-applied here).
- Transport glyph: no `isPrecounting` needed — the engine reports `isPlaying == true` during the pre-roll (sequencer running), so the pause glyph shows naturally.
- **Re-pin** all of `project.yml` + the 4 ssm-pinning `Package.swift` (Domain, Infrastructure, Features/Reader, Features/Library) to the new ssm `main` revision once the engine change is pushed (this also resolves the pre-existing ssm drift on Folino main).

## 6. Behavior summary

- **Metronome-independent**: pre-roll clicks are on the always-on track, so they sound with the metronome toggle off.
- **Cursor pinned** during the pre-roll; moves once real playback begins.
- **Pause/resume**: pausing during the count-in stops the sequencer with the cursor at the start; resuming with the toggle on re-runs the count-in from the (pause) position.
- **Fires on every play start** (from stopped and resume-from-pause), when the toggle is on.
- **A–B repeat**: count-in once, then loop the body (pre-roll is before the loop A-point).
- **Export**: count-in is NOT baked into exported audio (`PlaybackEngine+Export.swift` is untouched; it never requests a count-in).
- **Tempo slider**: the pre-roll is in the same sequence, so the `rate` multiplier scales it with the body.

## 7. Testing & verification

- **ssm `SheetMusicAudioCore`**: `CountInBeatsTests` — the §4 matrix (port the prior branch's 15 `PrecountPlanTests` cases as tick assertions: meter, both anacrusis encodings, lead-in, mid-score TS change, 6/8, 2/2, empty). Pure unit tests.
- **ssm `SheetMusicAudioApple`**: `SequenceMap` tick-translation unit tests (round-trip, pre-roll boundary, loop-tick mapping). Sequence-build assertions where feasible (pre-roll clicks present at `[0,preRollTicks)`, content shifted, meta seeded) — inspect the built `MidiFile` before serialization rather than audio.
- **ssm example app (macOS)**: exercise the count-in end-to-end (metronome off + count-in on → clicks then music, cursor pinned; beat-3 start → 6 clicks; loop → count-in once; tempo slider scales it). **Report + get user approval before pushing to ssm main** (ssm discipline).
- **Folino**: `ReaderPlaybackSession` test — toggle on → `controller.play` called with `countIn: true`; toggle off → `countIn: false` (fake controller records the flag). Remove the prior precount tests/fakes.
- **Device**: after ssm push + Folino re-pin, build + install to the iPad; user confirms volume matches the metronome and the handoff is tight.

## 8. Risks / open items

- **Rebuild cost**: a count-in play rebuilds the sequence (shift + pre-roll). Mitigate by caching `MidiRenderer.render(score:)` per score so per-play cost is SMF re-assembly + `sequencer.load`, not a full re-render. Flag if large scores show a start-latency regression; note the drop if any cap is applied.
- **Tick-math boundaries**: loop wrap, end-of-score, and seek across the pre-roll boundary are the bug-prone spots — covered by `SequenceMap` tests + example-app checks.
- **Mid-score content drop**: shifting requires dropping events `< baseTick`; a note sustaining across `baseTick` must still start at `baseTick` (clamp), matching today's mid-score `play(from:)` semantics — verify against the existing seek behavior.
- **Android**: `CountInBeats` (shared) ports; the Android engine needs its own pre-roll playback later — out of scope for this iOS change.
- **`play(countIn:)` default**: defaulted `false` so every other `PlaybackController` caller (remote command center, playlist auto-advance, tests) is unaffected; only `ReaderPlaybackSession.togglePlayback` passes the toggle.

## 9. Implementation order

1. **ssm** `CountInBeats.compute` + tests (`SheetMusicAudioCore`).
2. **ssm** `SequenceMap` + tests; `PlaybackEngine` pre-roll build + tick translation + cursor pin; `MetronomeController` always-on pre-roll track (`SheetMusicAudioApple`).
3. **ssm** example-app verification → report → **user approval** → push ssm `main`.
4. **Folino** new worktree: re-pin to the new ssm revision; `PlaybackController.play(countIn:)`; `ReaderPlaybackSession` orchestration; re-apply the toggle keys + Settings/inspector UI + localization; remove the prior precount machinery; tests.
5. Build the app; install to iPad; **user** confirms volume + timing on device.

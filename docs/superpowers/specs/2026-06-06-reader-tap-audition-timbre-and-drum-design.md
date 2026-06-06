# Reader tap-audition: correct timbre + drum tail handling

**Date:** 2026-06-06
**Status:** Approved design (pre-implementation)
**Scope:** `swift-sheet-music` → `SheetMusicAudioApple.PlaybackEngine` (Apple/iOS only). Folino changes limited to re-pinning ssm. Android has no tap-audition yet (separate future task), so no parity obligation here.

## Background

The Reader auditions a tapped note for a short time. Folino's `ReaderPlaybackSession.setManualCursor` calls `controller.playPreview(noteID:duration:0.5)` only while stopped/paused, which forwards to `PlaybackEngine.playPreview` (ssm).

`playPreview` today:

1. resolves the note's pitch + the staff's MIDI channel;
2. starts the audio graph if the host had parked it (`engine.pause()` between plays for Control Center cosmetics), flagging `previewShouldRepauseEngineOnDrain`;
3. `startNote` (note-on);
4. after `duration`, `stopNote` (note-off), then decrements `activePreviewCount`; when it hits 0 and the flag is set, `engine.pause()` to restore the parked state.

Two defects surface from this.

## Problem 1 — timbre is piano before the first playback

Per-channel GM **program** (instrument) selection happens in `reapplyMixerPrograms()`, which is only called right after `sequencer.start()` — i.e. the first real `play()`. `prepare(score:)` loads the SF2 with the seed preset `(bank 0,0 / program 0)` = GM piano and pre-caches presets, but never *selects* each channel's program. So any `playPreview` before the first playback sounds on program 0 = **piano**. Drum staves (MIDI channel 9) are unaffected — the program byte is ignored on channel 9.

## Problem 2 — drum (cymbal) release tail lingers

The preview already ends with **note-off** (`stopNote`), not an engine stop — the user's "just note-off?" is effectively already the case; `engine.pause()` only restores the host-parked state after the last preview drains. But on a drum channel a cymbal is a one-shot whose decay **ignores note-off**, so it keeps ringing after the 0.5 s note-off and overlaps the next tap. Truncating a ringing drum requires **All Sound Off (CC 120)** (immediate, ignores release), not note-off / All Notes Off (CC 123), which respect the release.

## Design

### 1. Correct timbre at load

In `prepare(score:)`, after `applyMixerState()`, call `reapplyMixerPrograms()` so every non-drum channel's program is selected at load time. Real playback still re-applies programs after `sequencer.start()` (to win the race against the SMF's tick-0 program-change events), so playback behavior is unchanged; only pre-playback previews are fixed. Cost: a few extra `preloadPreset` SF2 reads moved to load time (acceptable; `prepare` is already the slow path).

### 2. Clear-on-new-tap + let drums ring

Replace the `activePreviewCount` + per-note `asyncAfter` scheme with a single pending end-work-item plus a tracked set of sounding channels.

State (main-actor):
- `activePreviewChannels: Set<UInt8>` — channels with a currently sounding preview.
- `previewEndWorkItem: DispatchWorkItem?` — the one pending end-of-preview action.

`playPreview(noteID:duration:velocity:)`:
1. Cancel `previewEndWorkItem`.
2. For each channel in `activePreviewChannels`, send **CC 120 (All Sound Off)** — instantly silences the previous preview, including a ringing cymbal. Clear the set.
3. Resume the graph if parked (unchanged), flagging `previewShouldRepauseEngineOnDrain` when not playing.
4. `startNote(pitch, velocity, channel)`; insert the channel into `activePreviewChannels`.
5. Schedule one `previewEndWorkItem` after `tail`:
   - melodic staff: `tail = duration` (0.5 s) → on fire send note-off (`stopNote`).
   - drum staff (`isDrumStaff`): `tail = drumTail` (initial **2.0 s**, by-ear tunable) → on fire send CC 120 for a clean one-shot end.
   - both: remove the channel from `activePreviewChannels`; if it is now empty and `previewShouldRepauseEngineOnDrain` and not playing, `engine.pause()` and clear the flag.

Net behavior:
- Tap a cymbal → it rings naturally (up to `drumTail`).
- Tap any other note → the previous preview (cymbal included) is cut immediately via CC 120, then the new note plays.
- Melodic previews unchanged (0.5 s note-off).
- The engine re-parks only after the last preview's `tail` elapses with no new tap — so it never pauses mid-cymbal (the old scheme would have paused 0.5 s in).

### Why a single work-item instead of a count

The old `activePreviewCount` allowed overlapping previews to each schedule their own teardown. "Cut the previous preview on a new tap" needs the opposite: at most one preview alive, and a new tap deterministically silences and replaces it. One cancellable work-item + a channel set models that directly and removes the overlap bookkeeping.

## Edge cases

- **Rapid taps:** each cancels the prior work-item and CC 120-clears, so no stuck or overlapping previews; `activePreviewChannels` holds at most the current tap's channel(s).
- **Tap during real playback:** gated off in Folino (`if !isPlaying`), so this path runs only when stopped/paused — CC 120 never disturbs a live stream.
- **Metronome:** a separate node/sampler; CC 120 on the synth's staff channels does not touch it. (Verify in the example app.)
- **CC 120 support:** confirm AUMIDISynth honors CC 120 as immediate all-sound-off in the example app; if a cymbal still rings after CC 120, fall back to a per-channel silence approach (documented during verification).

## Verification

ssm example app, by ear:
1. Open a multi-instrument score, **do not** press play, tap a melodic note → correct instrument (not piano).
2. Tap a cymbal on a drum staff → rings naturally.
3. While it rings, tap another note → cymbal cut immediately, new note clean.
4. Press play once, pause, repeat (1)–(3) → still correct.

Then report → push ssm → re-pin Folino (`Package.swift` ×4 + `project.yml`) → Folino by-ear.

## Tunables / open items

- `drumTail` length (start 2.0 s).
- Whether melodic previews should also be cut by a new tap (yes — CC 120 clears the set regardless of type; consistent).
- Confirm CC 120 efficacy on AUMIDISynth (fallback noted above).

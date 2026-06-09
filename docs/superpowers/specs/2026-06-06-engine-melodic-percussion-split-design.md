# PlaybackEngine Melodic / Percussion Synth Split — Design

**Date:** 2026-06-06
**Status:** Approved design direction (split into two synth units), pre-implementation
**Repo:** swift-sheet-music (iOS / `SheetMusicAudioApple`)
**Driver:** Enables a clean, live, drum-correct whole-score transpose (see
`2026-06-06-reader-transpose-design.md`). Carved out as its own sub-project
because it refactors the shared audio engine's synth topology.

## Goal

Split the single shared `AVAudioUnitMIDIInstrument` ("AUMIDISynth") that
`PlaybackEngine` uses for score playback into **two units**:

- **melodic synth** — all pitched channels.
- **percussion synth** — drum / unpitched channels (GM channel 9).

This lets us apply AUMIDISynth's **global** AudioUnit coarse-tuning parameter
(the only tuning mechanism AUMIDISynth honors) to the melodic unit alone — so a
whole-score transpose shifts pitched content live (including notes already
sounding, zero-artifact) while drums on the separate unit stay at concert
pitch.

## Background — why a split is necessary

The transpose feature needs to shift sounding pitch by N semitones, live,
excluding drums. Investigation of the audio engine showed:

- **AUMIDISynth ignores MIDI tuning RPNs** (the codebase's own A4-calibration
  comment in `PlaybackEngine.swift` documents this). So per-channel coarse-tuning
  RPN (the original transpose attempt) does nothing — confirmed by user test.
- AUMIDISynth **does** honor its **global** AudioUnit Coarse/Fine Tuning
  parameters (ids 901 / 902) — that is exactly what A4 calibration uses
  (`applyMasterTuning`). But "global" means whole-synth: it would also pitch the
  drum channel, turning a snare into a chipmunk snare at ±7.

The clean resolution is to put drums on a **separate** synth unit, so global
coarse tuning on the melodic unit never touches drums. This also retunes
already-sounding notes in real time (no reload, no sequencer swap, no
dropped-sustain artifact) — strictly better than the score-reload or
mid-flight-swap alternatives considered.

There is a strong precedent in the codebase: **`MetronomeController` already
owns its own `AVAudioUnitMIDIInstrument`**, attaches it to the same
`AVAudioEngine`, loads the GM drum bank on channel 9, and routes a dedicated
sequencer track to it via `AVMusicTrack.destinationAudioUnit`. The percussion
synth follows the same pattern.

## Design

### Topology

```
            ┌─ melodicSynth (pitched ch) ─┐
sequencer ──┤                             ├─→ scoreGainMixer ─→ sumMixer ─→ limiter ─→ main
   tracks   └─ percussionSynth (ch 9) ────┘        ▲
            (metronome track) ─→ metronome.sampler ┴─→ sumMixer  (unchanged; bypasses master gain)
```

- Both score synths are created in `prepareSynth`, attached to `engine`, and
  connected to **`scoreGainMixer`** (they are score content, subject to master
  gain — unlike the metronome, which connects to `sumMixer`).
- Teardown disconnects/detaches both, mirroring the current single-synth
  teardown in `prepareSynth` re-entry and `teardown()`.

### State

`var synth: AVAudioUnitMIDIInstrument?` becomes:

```swift
var melodicSynth: AVAudioUnitMIDIInstrument?
var percussionSynth: AVAudioUnitMIDIInstrument?
```

`staffMIDIChannels` and `staffIsDrum` are unchanged — they already encode which
staff is a drum staff. A helper selects the unit for a staff:

```swift
private func synth(forStaff idx: Int) -> AVAudioUnitMIDIInstrument? {
    isDrumStaff(idx) ? percussionSynth : melodicSynth
}
```

Shared, unchanged: `engine`, `scoreGainMixer`/`sumMixer`/`limiter`, `sequencer`,
`masterGain`, `masterTuningCents`, `transposeSemitones`, `mixerChannels`,
timing/cursor state.

### Sequencer track routing

`buildSequencer`'s bulk `for track in sequencer.tracks { track.destinationAudioUnit = synth }`
becomes per-track dispatch: each non-metronome track routes to
`melodicSynth` or `percussionSynth` according to whether its staff is a drum
staff. The metronome track is still redirected afterward by
`metronome.attach(to:)` (unchanged).

Track→staff mapping: MIDI tracks are emitted one per flat staff (in
`MidiRenderer` order) with the metronome track appended last. The plan must
**verify** track index ↔ flat-staff-index alignment and route by
`staffIsDrum[trackIndex]`; if the renderer's ordering needs a lookup, build it
explicitly rather than assuming positional identity.

### Channel allocation

**Unchanged for this sub-project.** Pitched staves keep their assigned channels
(allocator skips 9); drums stay on channel 9. The only change is that channel-9
tracks now go to `percussionSynth` and the rest to `melodicSynth`. The existing
16-channel overflow (no upper-bound guard in `assignChannels`) is **out of
scope** — see Out of Scope.

### Soundfont loading

Both units load the resolver's GM SF2 in `prepareSynth`:

- melodic: `loadSoundFont(into: melodicSynth, url:, bankMSB:0, bankLSB:0, program:0)` (as today).
- percussion: `loadSoundFont(into: percussionSynth, url:, …, channel: 9)` — same
  pattern the metronome uses to make the drum bank resident on channel 9.

This parses the SF2 **twice** (once per AU; each AUMIDISynth has independent
internal state — no shared parse). Resident memory is preset-based (lazy), so
the percussion unit only holds the drum kit; the increment over today is the
drum presets + one AU instance, not a second 205 MB copy. **If profiling shows
the double-parse / residency is a real cost**, the fallback is a small
percussion-only SF2 (e.g. split out via Polyphone) loaded into `percussionSynth`
instead of the full GM SF2. Decide by measurement, not upfront.

### Tuning model (the payoff)

Replace the dead RPN coarse-tuning path (`MIDISynthBuilder.setChannelCoarseTuning`
+ `applyCoarseTuning`) with AU-global tuning, applied per unit:

- **melodic unit** carries calibration **and** transpose:
  `901/902 = MasterTuning.split(cents: masterTuningCents + Double(transposeSemitones) * 100)`.
- **percussion unit** carries calibration only:
  `901/902 = MasterTuning.split(cents: masterTuningCents)` (no transpose).

A single `applyTuning()` recomputes both units' params and is called from
`setMasterTuning(cents:)`, `setTranspose(semitones:)`, and the `prepareSynth`
re-assert (replacing today's separate `applyMasterTuning` + `applyCoarseTuning`
re-asserts). `setTranspose` thus becomes live, smooth, and drum-safe by
construction — no reload, no swap.

Pitch-bend sensitivity setup (4 sites) targets the **melodic** unit only
(percussion ch 9 is already excluded from those loops).

### Per-unit dispatch at the blast-radius sites

- **Mixer** (`applyStaffGain`): send CC7 to `synth(forStaff:)`. `loadProgram` /
  `reapplyMixerPrograms` already guard `midiCh != 9`, so they target
  `melodicSynth`.
- **Preview** (`playPreview`, `cancelActivePreview`): pick the unit via
  `synth(forStaff:)` for the tapped staff.
- **Export** (`PlaybackEngine+Export.swift`): `ScoreSynth` gains a
  `percussionSynth` field; `buildScoreSynth` builds both and loads SF2 into both;
  `ExportPipeline.samplers` (already an array — the pitch-bend loop iterates it)
  includes both, so pitch-bend setup is automatic; per-track routing mirrors the
  live `buildSequencer` dispatch; `applyMixerSnapshot` dispatches CC7 by channel
  to the right unit. (Export does not currently apply transpose/calibration — see
  Out of Scope.)

## Transpose audio end-state (what this unlocks)

After the split, the iOS transpose audio path is: `setTranspose(semitones:)` →
melodic-unit global coarse tuning. Live, retunes held notes, drums on the
percussion unit untouched, composes with A4 calibration. This is the behavior
the example app must demonstrate.

The example app's display fix (use `Score.transposed(bySemitones:)` at the
**layout-build** layer, not just the `scoreContent` argument) is folded into this
sub-project's verification, since the same example app is the test bed. (The
earlier example wiring applied the transform at the wrong layer — layout docs
were rebuilt from the original score.)

## Out of scope (YAGNI / follow-ups)

- **Channel-headroom fix**: with drums on their own unit, pitched staves could
  use all 16 channels of the melodic unit; fixing the `assignChannels`
  overflow is a separate improvement, not required here.
- **Export applying transpose / calibration**: the export pipeline does not
  currently apply `transposeSemitones` or `masterTuningCents` — a pre-existing
  gap, not introduced or fixed here.
- **Android**: FluidSynth supports per-channel tuning (calibration already uses
  it), so Android transpose applies per-channel coarse tuning to non-drum
  channels directly — **no unit split needed on Android**. Android transpose is
  Plan 3 of the transpose feature; this split is iOS-only.

## Testing / verification

No new pure-unit tests for the audio graph (it needs a running AU). Verification
is the **example app**, run by the user before any push. The split touches
shipped playback, so the regression surface is broad — verify ALL of:

- Plain playback (melodic + percussion sound correct, balanced).
- Per-staff **mute / solo / volume** (including a drum staff).
- **Program picker** on a pitched staff changes timbre; hidden/again for drums.
- **Tap-to-audition / preview** on pitched and drum staves.
- **Metronome** on/off still clicks (its separate sampler unaffected).
- **Audio export** renders correctly (both units in the offline pipeline).
- **A4 calibration** slider still retunes pitched content (and is now isolated
  from drums on the percussion unit).

Then the new behavior:
- **Transpose** stepper shifts pitched audio live (including held notes), with no
  reload gap, and **drums do not change pitch**.
- Transpose **and** A4 calibration applied together compose correctly on the
  melodic unit.
- Engraving re-renders with the transpose (display fix) and drum notation is
  unchanged.

## Risks

- **Broad blast radius**: mixer / preview / export / sequencer-routing all assume
  one synth. Mitigation: per-unit changes are mechanical; the metronome is a
  proven template; full example-app regression before push.
- **Track→staff mapping** assumption (sequencer routing) — verify, don't assume
  positional identity.
- **SF2 double-parse** memory/CPU — measure; Polyphone-split fallback ready.
- **Export pipeline** is a separate offline engine — easy to forget; explicitly
  in the plan.

## Workflow

- ssm worktree already exists: `…/swift-sheet-music/.claude/worktrees/transpose`
  (branch `transpose`, rebased onto origin/main which has calibration). The split
  lands on this same branch ahead of the transpose audio wiring.
- Example-app transpose UI already added (iOS toolbar + macOS sidebar); soundfont
  symlinked from primary.
- **Verify in the example app, hand to user, get approval, THEN push.** Re-pin
  Folino to the pushed revision for Plan 2 (Folino iOS transpose).

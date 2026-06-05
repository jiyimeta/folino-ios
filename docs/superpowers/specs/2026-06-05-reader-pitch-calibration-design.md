# Reader Pitch Calibration (A4 reference frequency) — Design

**Date:** 2026-06-05
**Status:** Approved design — pending plan
**Scope:** iOS + Android. Touches `swift-sheet-music` (ssm) engine + Folino Domain/Infra/Feature/Settings.

## Problem

Playback is locked to the concert pitch **A4 = 440 Hz** (baked into the SoundFont synth on
both platforms). Some users want alternative references — most commonly **432 Hz**, but also
orchestral-sharp (442/443 Hz) and down toward baroque (≈415 Hz). We want a user-adjustable A4
reference that retunes playback only; **notation is unchanged** (this is a playback calibration,
not a transposition).

This calibration affects **playback audio only**. It must never change displayed/notated pitch,
note spelling, MIDI export semantics, or the cursor/timeline.

## Goals

- A continuous A4 reference control with range **415–466 Hz** (≈ ±1 semitone around 440),
  default **440.0 Hz**, with snap detents at **432** and **440**.
- **Per-score override** (Reader playback inspector), persisted in `ReaderPreferences`.
- **Global default** (Settings), used when a score has no override.
- Effective value resolution: `score override ?? global default ?? 440`.
- **iOS and Android parity**: identical audible result, shared tuning logic, minimal
  platform-specific glue.

## Non-goals (YAGNI)

- Per-staff / per-voice tuning. One master reference per playback.
- Microtuning / non-equal temperaments / scala tables. Equal temperament only; we only move
  the A4 anchor.
- Changing notation, transposition, or MIDI export.
- Persisting calibration into exported audio renders is **in-scope only if it falls out for
  free** from the engine path; otherwise deferred.

## Physical model

Moving A4 from 440 Hz to `f` Hz is a constant cents offset applied to every pitch:

```
cents = 1200 · log2(f / 440)
```

415 Hz ≈ −101.0¢, 432 Hz ≈ −31.77¢, 442 Hz ≈ +7.85¢, 466 Hz ≈ +98.95¢.
So the 415–466 Hz range is essentially **±100 cents (±1 semitone)**.

## Chosen mechanism — Approach A: MIDI Master Tuning RPN

Both synths are driven by MIDI and both can be retuned **in-band** via the standard MIDI
**Master Tuning** Registered Parameters — no new audio nodes, no SoundFont editing, no native
synth additions:

- **Master Fine Tuning** — RPN `00 01`, 14-bit data entry, center `0x2000` = 0¢, full range
  **±100¢**.
- **Master Coarse Tuning** — RPN `00 02`, data-entry MSB = `64 + semitones` (64 = no shift).

Why this works on both platforms with existing plumbing:

- **iOS** uses `AUMIDISynth` (`kAudioUnitSubType_MIDISynth`), chosen precisely because it honors
  RPNs (the engine already relies on RPN `00 00` pitch-bend-sensitivity). Live CC is sent via
  `MIDISynthBuilder.sendControlChange(...)`.
- **Android** uses **FluidSynth**, which processes Master Fine/Coarse Tuning RPNs, and the JNI
  layer **already exposes** `cc(handle, channel, controller, value)`
  (`FluidSynthNative.kt` / `FluidSynthDriver.kt`).

So Approach A reduces to "send a fixed RPN CC sequence to each melodic channel." No new C++/JNI
function and no new AVAudioUnit are required.

### cents → RPN (shared pure logic)

Lives once in **`SheetMusicAudioCore`** (cross-platform Swift) so both platforms compute
identical messages:

```
func masterTuningRPN(cents: Double) -> [(controller: UInt8, value: UInt8)]
  coarseSemitones = round(cents / 100)                 // ∈ {-1, 0, 1} for our range
  fineCents       = cents - 100 * coarseSemitones      // ∈ [-50, +50]
  fine14          = clamp(8192 + round(fineCents / 100 * 8192), 0, 16383)

  return [
    (101, 0), (100, 2), (6, UInt8(64 + coarseSemitones)),   // Coarse Tuning
    (101, 0), (100, 1), (6, fine14 >> 7), (38, fine14 & 0x7F), // Fine Tuning
    (101, 127), (100, 127),                                  // RPN Null (lock)
  ]
```

(Master tuning = coarse semitones + fine cents, summed by the synth; this keeps fine within its
±100¢ window even if the range later widens.)

### Application points

- Sent to **all melodic channels in use**, skipping the drum channel (MIDI ch 9, 0-indexed).
- (Re)applied: (1) initially after program/synth setup in `prepare`; (2) whenever the user
  changes the value; (3) after **seek** and after any **program change**, if the spike shows the
  synth resets channel RPN state on those events (GM says master tuning persists across program
  change, but the spike confirms per-synth behavior).

### Sharing across platforms

The `(controller, value)` list is produced **once in Swift** (`SheetMusicAudioCore`). iOS sends it
directly. Android obtains the same list through a small JNI bridge export (e.g.
`nativeMasterTuningRPN(cents) -> [Byte]`) and loops `cc()` over it — the only Android-specific code
is the unavoidable channel-iteration glue. This honors the parity rule (shared logic, platform-only
where it must be).

### Fallback — Approach B (only if the spike fails)

If a synth does **not** honor Master Tuning RPNs:

- **iOS:** insert `AVAudioUnitTimePitch` between `scoreGainMixer` and `sumMixer`, set
  `.pitch = cents`, `.rate = 1`. Metronome joins at `sumMixer`, so it stays at 440. Cost: constant
  phase-vocoder latency + minor artifacts.
- **Android:** wrap `fluid_synth_set_gen(GEN_FINETUNE/GEN_COARSETUNE)` (or an octave-tuning table)
  via new JNI; or pre-shift note numbers. Heavier — new native surface.

Approach B is documented but **not built unless required**. The engine API
(`setMasterTuning(cents:)`) is identical for A and B, so the Folino-side layers below are unchanged
regardless of which mechanism lands.

## Verification spike (gates the mechanism)

**Before any Folino integration.** In the ssm example apps:

1. Add a minimal A4 slider to the **iOS** example (`Examples/Apple/SheetMusicExample`) and the
   **Android** example (`Examples/Android`) playback surface.
2. Wire it to `setMasterTuning(cents:)`.
3. Confirm audibly that pitch shifts correctly, **and persists across program change and seek**, on
   both AUMIDISynth and FluidSynth.
4. **Outcome gate:** both honor RPN → Approach A. Either fails → revisit (Approach B for the failing
   platform), and report back before proceeding.

Per workflow rule: verify in the ssm example apps, **report before pushing ssm**, push only after
approval, then re-pin Folino.

## Engine API (swift-sheet-music)

- `SheetMusicAudioCore`: `masterTuningRPN(cents:)` pure helper (+ a `cents(forA4Hz:)` convenience).
- `SheetMusicAudioApple/PlaybackEngine`: `func setMasterTuning(cents: Double)` — sends RPN to all
  melodic channels; remembers the value to reassert after seek/program-change.
- `SheetMusicAudioAndroid/AndroidPlaybackEngine`: `fun setMasterTuning(cents: Double)` — same, via
  `cc()`, using the bridged RPN list.
- Example apps gain a slider bound to the above (test bed + manual regression).

## Folino layering

### Domain (shared, Foundation-only)

- `ReaderPreferences.a4ReferenceHz: Double?` — `nil` = inherit global default. Optional ⇒
  backward-compatible Codable decode (absent → `nil`).
- App-settings store gains `a4ReferenceHz: Double` (default `440.0`) — the global default.
- Pure resolver: `func effectiveA4Hz(scoreOverride: Double?, globalDefault: Double) -> Double` and
  `func a4Cents(_ hz: Double) -> Double` (= `1200·log2(hz/440)`). Used by both platforms.
- `PlaybackController` protocol: `func setMasterTuning(cents: Double) async`.
- `PlaybackPreferences` (engine-load-time): `a4ReferenceHz: Double = 440` → applied in
  `applyPreferences()` as `setMasterTuning(cents:)`.

### Infrastructure (iOS)

- `LivePlaybackController.setMasterTuning(cents:)` → `engine.setMasterTuning(cents:)`.
- `applyPreferences` converts the effective A4 Hz → cents and calls the engine.

### Android integration

- `AndroidPlaybackEngine.setMasterTuning(cents)` reached from the Reader audio view-model, value
  resolved from the same shared resolver (effective Hz → cents).

## UI (content at iOS parity; placement per platform idiom)

### Reader playback inspector (per-score override)

- A4 slider, range **415–466 Hz**, detents/snap at **432** and **440**.
- Primary readout in **Hz** (one decimal, e.g. `440.0 Hz`); secondary cents delta (e.g. `−31.8¢`)
  as a musician-friendly subtitle.
- "Reset to global default" affordance; indicate when the score is overriding the global value.
- **iOS:** new row in the existing dense playback inspector.
- **Android:** new row in the existing playback `ModalBottomSheet` inspector.

### Settings (global default)

- Same slider/readout, sets the app-wide default.
- **iOS:** Settings screen. **Android:** gear-icon Settings.

## Data flow

```
ReaderPreferences.a4ReferenceHz (per score, optional)
        └── effectiveA4Hz(override, globalDefault) ──► a4Cents(hz) ──► PlaybackController.setMasterTuning(cents)
SettingsStore.a4ReferenceHz (global default) ──────────┘                              │
                                                                                      ▼
                                          PlaybackEngine.setMasterTuning(cents) → RPN CC to melodic channels
                                          (iOS: MIDISynthBuilder.sendControlChange / Android: FluidSynth cc())
```

## Testing

- **Domain (Swift Testing):** `effectiveA4Hz` resolution table; `a4Cents` boundary values
  (415/432/440/466); `ReaderPreferences` Codable round-trip incl. absent field → `nil`.
- **ssm `SheetMusicAudioCore`:** `masterTuningRPN(cents:)` golden tests — exact CC sequences for
  0¢, −31.77¢ (432), −100¢ (415), +98.95¢ (466), incl. coarse/fine split and RPN-null lock.
- **Engine:** audio output is verified manually via the example apps (the spike + regression).
  Where the engine exposes a sent-CC hook, assert the emitted sequence.
- **Android:** if any RPN math is mirrored in Kotlin, mirror the golden tests; otherwise rely on the
  bridged Swift list + example-app manual check.

## Open details to confirm during planning

- Exact location/type of the app-global settings store (Settings feature) for `a4ReferenceHz`.
- Whether seek/program-change reassertion is needed (decided by the spike).
- Whether audio **export** should honor calibration now or later (deferred unless free).

## Sequencing

1. **Spike** (ssm example apps, both platforms) → confirm Approach A. Report before push.
2. ssm engine API + shared `masterTuningRPN` + example sliders → verify → **report → push → re-pin**.
3. Folino Domain fields + resolver + protocol method.
4. iOS Infra + Reader inspector + Settings.
5. Android engine wiring + inspector + Settings.
6. Tests at each layer.

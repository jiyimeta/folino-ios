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

## Chosen mechanism — native synth tuning, per platform (spike-confirmed)

Both engines retune by setting their synth's own coarse-semitone + fine-cents tuning — no extra
audio nodes, no SoundFont editing. The **shared logic is the cents→(coarse, fine) split**; the call
that applies it differs per synth (iOS = AudioUnit parameters; Android = MIDI Master Tuning RPN).
Details and spike results below.

> **Spike outcome (2026-06-05, both confirmed audibly in the ssm example apps).** The two synths
> retune by **different mechanisms** — so the original "RPN on both" plan was revised. The
> behavioral result is identical; only the engine-internal call differs. The Folino-side layers
> below are unaffected (the engine API stays `setMasterTuning(cents:)`).

### iOS — AudioUnit Coarse/Fine Tuning parameters (NOT MIDI RPN)

`AUMIDISynth` (`kAudioUnitSubType_MIDISynth`) **ignores** MIDI Master Fine/Coarse Tuning RPNs
(0,1 / 0,2) — verified: sending them produces no audible change. It honors RPN 0,0 (pitch-bend
sensitivity, which the engine already relies on) but not master tuning.

It **does** expose global-scope AudioUnit tuning parameters (confirmed by dumping
`kAudioUnitProperty_ParameterList`):

- id **901 "Coarse Tuning"** — RelativeSemiTones, range ±24
- id **902 "Fine Tuning"** — Cents, range ±99
- (id 900 "Gain", id 903 "Stereo Pan")

Retune via `AudioUnitSetParameter(synth.audioUnit, 901, kAudioUnitScope_Global, 0, coarseSemitones, 0)`
and `…, 902, …, fineCents, 0)`. Applies to every channel, zero latency, zero artifacts. Set/get both
return `noErr` and the value sticks (headless-verified). This replaces the `AVAudioUnitTimePitch`
fallback that was on standby — no extra audio node needed.

### Android — MIDI Master Tuning RPN via FluidSynth `cc()` (confirmed honored)

FluidSynth **does** process Master Fine/Coarse Tuning RPNs, and the JNI layer already exposes
`cc(handle, channel, controller, value)` (`FluidSynthNative.kt` / `FluidSynthDriver.kt`). So Android
sends the standard RPN CC sequence to each melodic channel — **no new C++/JNI function**:

- **Master Fine Tuning** — RPN `00 01`, 14-bit data entry (`fine14 = 8192 + round(fineCents/100·8192)`).
- **Master Coarse Tuning** — RPN `00 02`, data-entry MSB = `64 + coarseSemitones`.

### Shared pure logic (cents → coarse/fine split)

Both mechanisms derive from the same split, so it lives once in **`SheetMusicAudioCore`**
(cross-platform Swift):

```
func split(cents: Double) -> (coarseSemitones: Int, fineCents: Double)
  coarseSemitones = round(cents / 100)            // ∈ {-1, 0, 1} for the 415–466 range
  fineCents       = cents - 100 * coarseSemitones // ∈ [-50, +50]
```

iOS feeds `(coarseSemitones, fineCents)` straight into params 901/902. The Swift helper also exposes
`rpnControlChanges(cents:) -> [CC]` (built on `split`) as the reference RPN encoding. Android does NOT
bridge it: the RPN is FluidSynth-specific MIDI plumbing that iOS never uses, and adding a JNI symbol +
`.so` regen to the fragile Android toolchain isn't worth it for ~12 lines of stable MIDI-standard
math. Instead Android re-implements the same encoding in a small Kotlin `MasterTuning` object **with a
unit test asserting the same golden CC sequences as the Swift tests**, so drift is caught. (The Kotlin
side is Kotlin-only — no `.so` rebuild needed for this feature.)

### Application points

- Applied to **all melodic channels** (drum channel 9 left at concert pitch). iOS's 901/902 are
  global so they cover every channel at once; Android loops the RPN over each melodic channel.
- (Re)applied: (1) after synth setup in `prepare` (persist the stored value across rebuilds);
  (2) whenever the user changes it. Spike result: the retune **persisted across program change and
  seek** on both synths, so no extra re-assert hooks are required.

## Verification spike — PASSED (2026-06-05)

Done in the ssm example apps with a temporary A4 slider:

- **iOS** (`Examples/Apple/SheetMusicExample`, run on macOS): RPN had no effect → pivoted to
  `AudioUnitSetParameter` 901/902 → **(a) pitch tracks the slider with tempo unchanged, (b) persists
  across program change, (c) persists across seek — all OK.**
- **Android** (`Examples/Android`, Pixel 8a): RPN via `cc()` → **(a)/(b)/(c) all OK.** (Also fixed a
  pre-existing stale-example compile error: `ScoreViewModel` now passes an encoded default
  `LayoutOptions` blob to `nativeComputeLayout`.)

Per workflow rule: the production engine work is verified in the ssm example apps, **reported before
pushing ssm**, pushed only after approval, then Folino is re-pinned.

## Engine API (swift-sheet-music)

- `SheetMusicAudioCore`: `MasterTuning.split(cents:)` + `MasterTuning.rpnControlChanges(cents:)` pure
  helpers; `A4Reference.cents(forHz:)` convenience (Hz lives at the UI layer).
- `SheetMusicAudioApple/PlaybackEngine`: `func setMasterTuning(cents: Double)` — sets global
  AudioUnit params 901/902 from `split`; remembers the value to re-apply after synth rebuild.
- `SheetMusicAudioAndroid/AndroidPlaybackEngine`: `fun setMasterTuning(cents: Double)` — builds the RPN
  via the Kotlin `MasterTuning` mirror and sends it via `cc()` to each melodic staff channel (drums
  skipped); remembers the value to re-apply after prepare. Kotlin-only; no JNI/`.so` change.
- Example apps keep the A4 slider bound to the above (test bed + manual regression).

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

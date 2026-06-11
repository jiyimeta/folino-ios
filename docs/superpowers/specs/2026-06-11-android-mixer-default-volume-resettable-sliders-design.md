# Android: mixer default volume parity + double-tap-to-reset sliders

**Date:** 2026-06-11
**Status:** Implemented (pending device verification + review)
**Branch:** `android-mixer-default-resettable-sliders` (Folino + swift-sheet-music)

## Goal

Two related Android parity gaps with iOS:

1. **Mixer default volume.** iOS opens each per-staff mixer slider at the score's
   authored channel volume (MIDI CC7 → 0…1), not a flat 100%. Android always showed
   100% because the shared Android engine dropped the CC7 when building mixer channels.
2. **Double-tap to reset.** iOS settings sliders carry a `ResettableSlider` — a tick at
   the default position plus a double-tap that snaps the value back to its default.
   Android had no such affordance on any slider. Bring it to **all** settings sliders.

## Scope decisions (confirmed with user)

- Mixer default volume: fix the shared engine (`swift-sheet-music`) for full parity —
  the engine seeds the slider from CC7, so initial position *and* the reset target match
  iOS. (Chosen over a Folino-only surface or a reset-target-only minimal change.)
- Double-tap reset: applied to **all 6** Android settings sliders, with the iOS-style
  default tick.

## Part 1 — swift-sheet-music (Android engine)

Pure Kotlin change in the Android audio engine module (`SheetMusicAudioAndroid`):

- `MixerChannel`: add `val defaultVolume: Float = 1.0f` — the score-authored initial
  volume, kept independent of the live `volume` so the UI can offer "reset to the
  score's value" even after the user drags the slider. Mirrors iOS
  `PlaybackMixerModel.defaultVolume(for:)`.
- `AndroidPlaybackEngine.prepare()`: when building `_mixerChannels`, seed both `volume`
  and `defaultVolume` from `StaffParams.channelVolume` (CC7, clamped 0…127, ÷127). The
  SMF stream already carries these CC7 values, so this only aligns the *displayed* /
  reset value with what actually plays — no double application, no synth-apply change.

GM fallback (no explicit channel volume) is `100/127 ≈ 0.787`, matching the wire default
of `StaffParams.channelVolume` and iOS's MuseScore default.

### Distribution (parallel-session-safe)

Published to mavenLocal under a branch-suffixed version
`0.0.0-mixer-resettable-SNAPSHOT` (per the established branch-versioning convention), so
it never collides with the shared `0.0.0-SNAPSHOT` slot other sessions use. All three
AARs (`sheet-music-android`, `-audio-android`, `-compose-android`) are published at that
one version to avoid engine/compose draw-program skew. **Not pushed to origin** — left as
a local commit for review; Folino consumes it via `-PssmVersion`.

## Part 2 — Folino (Android UI)

New shared composable
`FolinoReaderAndroid/.../reader/ui/ResettableSlider.kt` (the reader module already hosts
the shared inspector UI, and the app module depends on it, so Settings can use it too):

- Wraps Material3 `Slider`. Draws a 2×8 dp tick at the default position.
- **Double-tap detection** without breaking drag: observe pointer-downs on the
  `PointerEventPass.Initial` pass *without consuming them*, so the Slider still handles
  drags / single taps normally. Only when a second down lands within the platform
  double-tap timeout do we consume that one gesture and fire `onReset`. Mirrors the iOS
  intent (dual-path thumb + track), adapted to Compose's gesture model.

Applied to all 6 sliders, each with its default:

| Slider | File | Default | Reset action |
| --- | --- | --- | --- |
| Master volume | PlaybackInspectorSheet | 1.0 | set 1.0 + persist |
| Tempo (rate) | PlaybackInspectorSheet (TempoRow) | 1.0 | `onRate(1.0)` |
| A4 per-score | PlaybackInspectorSheet (A4ReferenceRow) | global A4 | set global + persist (clears override, matches iOS) |
| A4 global | app SettingsScreen (A4SliderRow) | 440 | set 440 + persist |
| Staff size | DisplayInspectorSheet (StaffSizeRow) | 28 pt | `onChange(28.0)` |
| Per-staff mixer | PlaybackInspectorSheet (PartMixerSection) | `channel.defaultVolume` (CC7) | `onVolume(staff, defaultVolume)` |

## Verification

- ssm: branch-version AARs present in mavenLocal.
- Folino: `-PssmVersion=0.0.0-mixer-resettable-SNAPSHOT :app:installDebug` on the
  emulator; open a score and confirm (a) the mixer opens at the score's authored
  volumes, (b) double-tapping each slider snaps it to the tick.

## Out of scope / follow-up

- Pushing the ssm branch + normal `0.0.0-SNAPSHOT` republish + iOS re-pin happens when
  the change is reviewed and merged (push is a confirm-gated action).
- iOS behavior is unchanged (already correct).

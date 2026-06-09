# Engine Melodic / Percussion Synth Split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `PlaybackEngine`'s single shared AUMIDISynth into a melodic unit (pitched channels) and a percussion unit (GM channel 9), then apply whole-score transpose as global coarse tuning on the melodic unit only — live, drum-safe, composing with A4 calibration.

**Architecture:** Two `AVAudioUnitMIDIInstrument`s attached to the same `AVAudioEngine`, both connected to `scoreGainMixer`. Sequencer tracks route per-staff to the right unit via `AVMusicTrack.destinationAudioUnit` (the same hook the metronome already uses). Tuning is AU-global per unit: melodic = calibration + transpose, percussion = calibration only. The dead per-channel RPN coarse-tuning path is removed.

**Tech Stack:** Swift 6, `SheetMusicAudioApple` (AudioToolbox / AVFoundation AUMIDISynth), the example app for verification (no audio unit tests).

**Scope:** ssm only, iOS engine. Branch `transpose` at `…/swift-sheet-music/.claude/worktrees/transpose` (abbrev `$SSM`), already rebased onto origin/main (has A4 calibration). Android (FluidSynth, per-channel tuning) is out of scope — see the spec. Channel-headroom fix and export-applies-tuning are out of scope.

---

## File map

- `$SSM/Sources/SheetMusicAudioApple/PlaybackEngine.swift` — state, `prepareSynth`, `buildSequencer`, tuning, preview, teardown (Task 1).
- `$SSM/Sources/SheetMusicAudioApple/PlaybackEngine+Mixer.swift` — `applyStaffGain` (Task 1).
- `$SSM/Sources/SheetMusicAudioApple/MIDISynthBuilder.swift` — remove dead `setChannelCoarseTuning` (Task 1).
- `$SSM/Sources/SheetMusicAudioApple/PlaybackEngine+Export.swift` — `ScoreSynth`, `buildScoreSynth`, routing, `applyMixerSnapshot`, `ExportPipeline.samplers` (Task 2).
- `$SSM/Examples/Apple/SheetMusicExample/macOS/ContentViewMac.swift` + `iOS/ContentView.swift` — display fix: transpose at the layout-build layer (Task 3).

---

## Task 1: Split the live synth + new tuning model

This is one atomic change — renaming `synth` to two units breaks every reference until all are updated, so the build is only green at the end. Touch the sites below, then build.

**Files:**
- Modify: `$SSM/Sources/SheetMusicAudioApple/PlaybackEngine.swift`
- Modify: `$SSM/Sources/SheetMusicAudioApple/PlaybackEngine+Mixer.swift`
- Modify: `$SSM/Sources/SheetMusicAudioApple/MIDISynthBuilder.swift`

- [ ] **Step 1: Replace the `synth` state with two units + a selector**

In `PlaybackEngine.swift`, replace the property at line ~39 (`var synth: AVAudioUnitMIDIInstrument?`) with:

```swift
    /// Pitched-channel synth. Carries A4 calibration AND whole-score
    /// transpose via its global AudioUnit coarse/fine tuning params.
    /// `internal` so the `+Mixer` / `+Export` siblings can read it.
    var melodicSynth: AVAudioUnitMIDIInstrument?
    /// Drum-channel (GM 9) synth. Carries calibration only — never the
    /// transpose — so transposing pitched content leaves drums at
    /// concert pitch. Separate unit because AUMIDISynth tuning is
    /// global-per-AU, not per-channel.
    var percussionSynth: AVAudioUnitMIDIInstrument?

    /// The synth that owns a given flat staff index: percussion for
    /// drum staves, melodic otherwise.
    private func synth(forStaff idx: Int) -> AVAudioUnitMIDIInstrument? {
        isDrumStaff(idx) ? percussionSynth : melodicSynth
    }
```

- [ ] **Step 2: Replace the tuning model**

In `PlaybackEngine.swift`, the methods `setMasterTuning` (~190), `setTranspose` (~274), and `applyCoarseTuning` (~285) plus the RPN call change as follows.

Replace `setMasterTuning`'s body tail and `setTranspose` + `applyCoarseTuning` with a single combined applier:

```swift
    public func setMasterTuning(cents: Double) { // swiftlint:disable:this inclusive_language
        guard state != .exporting else { return }
        masterTuningCents = cents
        applyTuning()
    }

    /// Live whole-score transpose in semitones (clamped −7…+7). Applied
    /// as global coarse tuning on the MELODIC unit only, so pitched
    /// content (incl. already-sounding notes) shifts with zero artifact
    /// and drums on the percussion unit stay at concert pitch. No score
    /// reload.
    public func setTranspose(semitones: Int) {
        let clamped = max(-7, min(7, semitones))
        transposeSemitones = clamped
        applyTuning()
    }

    /// Push the current calibration + transpose onto both units' global
    /// AU tuning params. Melodic carries calibration AND transpose;
    /// percussion carries calibration only. Both expressed in cents and
    /// split into the coarse(901)/fine(902) params by `MasterTuning.split`.
    private func applyTuning() {
        if let melodicSynth {
            Self.applyMasterTuning(
                to: melodicSynth,
                cents: masterTuningCents + Double(transposeSemitones) * 100,
            )
        }
        if let percussionSynth {
            Self.applyMasterTuning(to: percussionSynth, cents: masterTuningCents)
        }
    }
```

Delete the now-unused `applyCoarseTuning(_:to:)` method (~285–293). Keep `applyMasterTuning` (the static helper) and the 901/902 ids unchanged.

- [ ] **Step 3: Remove the dead RPN coarse-tuning builder**

In `MIDISynthBuilder.swift`, delete the `setChannelCoarseTuning(into:semitones:onChannel:)` method (added earlier, now unused — AUMIDISynth ignores tuning RPNs). Leave `setPitchBendSensitivity` and the others.

- [ ] **Step 4: Build both units in `prepareSynth`**

Rewrite `prepareSynth(score:)` (PlaybackEngine.swift ~460–505) to build melodic + percussion. Replace the single-instrument body (lines ~464–493) with:

```swift
        // Melodic unit — all pitched channels.
        let melodic = MIDISynthBuilder.make()
        engine.attach(melodic)
        engine.connect(melodic, to: scoreGainMixer, format: nil)
        if let url {
            try? MIDISynthBuilder.loadSoundFont(
                into: melodic, url: url, bankMSB: 0, bankLSB: 0, program: 0,
            )
        }
        for ch: UInt8 in 0 ..< 16 where ch != 9 {
            MIDISynthBuilder.setPitchBendSensitivity(
                into: melodic, semitones: 12, onChannel: ch,
            )
        }

        // Percussion unit — GM channel 9. Same SF2, drum bank preloaded
        // on channel 9 (mirrors MetronomeController). No pitch-bend setup
        // and no transpose: drums stay at concert pitch.
        let percussion = MIDISynthBuilder.make()
        engine.attach(percussion)
        engine.connect(percussion, to: scoreGainMixer, format: nil)
        if let url {
            try? MIDISynthBuilder.loadSoundFont(
                into: percussion, url: url,
                bankMSB: 0, bankLSB: 0, program: 0, channel: 9,
            )
        }

        melodicSynth = melodic
        percussionSynth = percussion
        // Re-assert calibration + transpose on the fresh units.
        applyTuning()
```

(The `let url = resolver.defaultGMSoundfontURL` and `let channels = …` lines at the top of `prepareSynth`, and the `for (idx, entry) in score.allStaves.enumerated()` loop that fills `staffMIDIChannels`/`staffIsDrum` at the bottom, stay as-is.)

- [ ] **Step 5: Tear down both units**

In `prepareSynth` re-entry teardown (~406–409) and `teardown()` (~1170–1173), replace the single-synth disconnect/detach with both. Find the block:

```swift
        if let oldSynth = synth {
            engine.disconnectNodeOutput(oldSynth)
            engine.detach(oldSynth)
            synth = nil
        }
```

Replace each occurrence with:

```swift
        for old in [melodicSynth, percussionSynth].compactMap({ $0 }) {
            engine.disconnectNodeOutput(old)
            engine.detach(old)
        }
        melodicSynth = nil
        percussionSynth = nil
```

- [ ] **Step 6: Route sequencer tracks per unit in `buildSequencer`**

In `buildSequencer(for:)` (~1030–1049), replace the bulk routing + pitch-bend block:

```swift
        for track in sequencer.tracks {
            if let synth {
                track.destinationAudioUnit = synth
            }
        }
        metronome.attach(to: sequencer)
        sequencer.rate = pendingRate
        sequencer.prepareToPlay()
        if let synth {
            for ch: UInt8 in 0 ..< 16 where ch != 9 {
                MIDISynthBuilder.setPitchBendSensitivity(
                    into: synth, semitones: 12, onChannel: ch,
                )
            }
        }
```

with per-staff routing (tracks are 1-per-staff in `allStaves` order; the metronome track is appended last and is redirected by `metronome.attach`):

```swift
        // Tracks are emitted one per flat staff in score order; route each
        // to its owning unit. The trailing metronome track is redirected by
        // `metronome.attach(to:)` below, so leave indices >= staff count.
        let staffCount = staffIsDrum.count
        for (trackIdx, track) in sequencer.tracks.enumerated() {
            guard trackIdx < staffCount else { continue }
            track.destinationAudioUnit = synth(forStaff: trackIdx)
        }
        metronome.attach(to: sequencer)
        sequencer.rate = pendingRate
        sequencer.prepareToPlay()
        if let melodicSynth {
            for ch: UInt8 in 0 ..< 16 where ch != 9 {
                MIDISynthBuilder.setPitchBendSensitivity(
                    into: melodicSynth, semitones: 12, onChannel: ch,
                )
            }
        }
```

> **Verify the track↔staff assumption** while implementing: confirm `MidiRenderer.render(score:)` emits tracks in `score.allStaves` order (1 per staff), so `sequencer.tracks[i]` ↔ flat staff `i`. Read `MidiRenderer.render`. If the order differs, build an explicit track→staffIndex map and route by that instead of positional index.

- [ ] **Step 7: Per-unit dispatch in `play(from:in:)` pitch-bend re-assert**

`play(from:in:)` (~700–704) has another `for ch … setPitchBendSensitivity(into: synth, …)` loop. Change `synth` → `melodicSynth` (guard `if let melodicSynth`).

- [ ] **Step 8: Per-unit dispatch in the mixer**

In `PlaybackEngine+Mixer.swift`, `applyStaffGain(at:gain:)` (~121–128) currently does `guard let synth, let midiCh = midiChannel(forStaff: staffIdx)`. Change to use the staff's unit:

```swift
    private func applyStaffGain(at staffIdx: Int, gain: Float) {
        guard let unit = synth(forStaff: staffIdx),
              let midiCh = midiChannel(forStaff: staffIdx)
        else { return }
        let cc7 = UInt8(clamping: Int((gain * 127).rounded()))
        MIDISynthBuilder.sendControlChange(
            into: unit, controller: 7, value: cc7, onChannel: midiCh,
        )
    }
```

`synth(forStaff:)` is `private` in `PlaybackEngine.swift`; make it `internal` (drop `private`) so `+Mixer` can call it (it's a different file in the same module).

`loadProgram(forStaff:)` (~354–368) and `reapplyMixerPrograms()` (~302–322) already guard `midiCh != 9`, i.e. they only act on pitched staves → change their `guard let synth` / `synth` usages to `melodicSynth`.

- [ ] **Step 9: Per-unit dispatch in preview**

`playPreview` (~540) does `guard let instrument = synth, let midiChannel = staffMIDIChannels[flatIdx]`. Change to `guard let instrument = synth(forStaff: flatIdx), …`. `cancelActivePreview` (~516–527) sends CC120 on `active.channel` via `synth`; it doesn't know the staff, but it stored `activePreview` — extend `activePreview` to also remember its unit, OR (simpler) send the All-Sound-Off to BOTH units on that channel:

```swift
    private func cancelActivePreview() {
        previewGeneration &+= 1
        if let active = activePreview {
            for unit in [melodicSynth, percussionSynth].compactMap({ $0 }) {
                MIDISynthBuilder.sendControlChange(
                    into: unit, controller: 120, value: 0, onChannel: active.channel,
                )
            }
        }
        activePreview = nil
        previewShouldRepauseEngineOnDrain = false
    }
```

(Sending CC120 to the non-owning unit is harmless — that channel isn't sounding there.) Inside `playPreview`'s same-channel/different-channel cut logic that also references `synth`/`instrument`, use the `instrument` resolved via `synth(forStaff:)`.

- [ ] **Step 10: Sweep for any remaining `synth` references**

Run a search and fix any leftover references to the removed `synth` property:

```bash
grep -rn "\bsynth\b" $SSM/Sources/SheetMusicAudioApple/PlaybackEngine.swift $SSM/Sources/SheetMusicAudioApple/PlaybackEngine+Mixer.swift
```
Every hit must now be `melodicSynth`, `percussionSynth`, or `synth(forStaff:)`. (Export's `ScoreSynth.synth` is a different type — Task 2.)

- [ ] **Step 11: Build**

Run:
```bash
swift build --package-path $SSM --target SheetMusicAudioApple
```
Expected: `Build complete!`. Fix compile errors until green.

- [ ] **Step 12: Commit**

```bash
git -C $SSM add Sources/SheetMusicAudioApple/PlaybackEngine.swift Sources/SheetMusicAudioApple/PlaybackEngine+Mixer.swift Sources/SheetMusicAudioApple/MIDISynthBuilder.swift
git -C $SSM commit -m "feat(audio): split live synth into melodic + percussion units

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Split the export pipeline

Export builds its own offline engine (independent of the live synth), so it compiles fine after Task 1 but still routes everything to one `exportSynth`. Split it to match.

**Files:**
- Modify: `$SSM/Sources/SheetMusicAudioApple/PlaybackEngine+Export.swift`

- [ ] **Step 1: `ScoreSynth` gains a percussion unit + per-staff drum flags**

Replace the `ScoreSynth` struct (~231–234) with:

```swift
    private struct ScoreSynth {
        let melodic: AVAudioUnitMIDIInstrument
        let percussion: AVAudioUnitMIDIInstrument
        let staffChannels: [Int: UInt8]
        /// Flat staff index → is-drum, for per-track routing + mixer dispatch.
        let staffIsDrum: [Int: Bool]
    }
```

- [ ] **Step 2: `buildScoreSynth` builds both units**

In `buildScoreSynth` (~236–292), build a second instrument for percussion and record drum flags. After the existing melodic `instrument` is built/loaded/pitch-bent, before the `return`, add a percussion unit and a `staffIsDrum` map; route program preloads only on the melodic unit for non-drum staves (the existing `midiCh != 9` block already does this — keep it on `instrument`/melodic). Concretely:

- Rename the local `let instrument` to `let melodic` throughout the function.
- After the melodic pitch-bend loop, add:
  ```swift
        let percussion = MIDISynthBuilder.make()
        engine.attach(percussion)
        engine.connect(percussion, to: output, format: nil)
        if let url = resolver.defaultGMSoundfontURL {
            try? MIDISynthBuilder.loadSoundFont(
                into: percussion, url: url,
                bankMSB: 0, bankLSB: 0, program: 0, channel: 9,
            )
        }
  ```
- Build `staffIsDrum` alongside `staffChannels` in the existing `for idx in score.allStaves.indices` loop:
  ```swift
        let isDrum = score.part(at: score.allStaves[idx].address)?
            .instrument.useDrumset == true
        staffIsDrum[idx] = isDrum
  ```
  (declare `var staffIsDrum: [Int: Bool] = [:]` next to `var staffChannels`).
- `return ScoreSynth(melodic: melodic, percussion: percussion, staffChannels: staffChannels, staffIsDrum: staffIsDrum)`.

- [ ] **Step 3: Route export tracks per unit**

In `buildExportPipeline` (~181–188), the routing loop currently sends `i < staffTrackCount` to `exportSynth.synth`. Change to route by drum flag:

```swift
        let staffTrackCount = score.allStaves.count
        for (i, track) in sequencer.tracks.enumerated() {
            if i < staffTrackCount {
                track.destinationAudioUnit = exportSynth.staffIsDrum[i] == true
                    ? exportSynth.percussion
                    : exportSynth.melodic
            } else if let s = metronomeSampler {
                track.destinationAudioUnit = s
            }
        }
```

- [ ] **Step 4: `samplers` includes both units; mixer snapshot dispatches per unit**

In the `ExportPipeline(... samplers: [exportSynth.synth] ...)` construction (~200–205), change to `samplers: [exportSynth.melodic, exportSynth.percussion]` (the pitch-bend setup loop over `pipeline.samplers` at ~74 then covers both — harmless on the percussion unit since ch 9 is excluded).

`applyMixerSnapshot` (~317–334) takes one `synth`. The export's call site (find it — it's where `applyMixerSnapshot(synth: exportSynth.synth, …)` is invoked) must dispatch per staff. Change `applyMixerSnapshot`'s signature to take the `ScoreSynth` and pick the unit per staff:

```swift
    private static func applyMixerSnapshot(
        scoreSynth: ScoreSynth,
        channels: [MixerChannel],
        soloedExists: Bool,
    ) {
        for chan in channels {
            guard case let .staff(idx) = chan.id,
                  let midiCh = scoreSynth.staffChannels[idx]
            else { continue }
            let unit = scoreSynth.staffIsDrum[idx] == true
                ? scoreSynth.percussion : scoreSynth.melodic
            let audible = soloedExists ? chan.isSoloed : !chan.isMuted
            let gain = audible ? chan.volume : 0
            let cc7 = UInt8(clamping: Int((gain * 127).rounded()))
            MIDISynthBuilder.sendControlChange(
                into: unit, controller: 7, value: cc7, onChannel: midiCh,
            )
        }
    }
```

Update the caller to pass `scoreSynth: exportSynth` (drop the separate `synth:`/`staffChannels:` args).

- [ ] **Step 5: Build**

```bash
swift build --package-path $SSM --target SheetMusicAudioApple
```
Expected: `Build complete!`.

- [ ] **Step 6: Commit**

```bash
git -C $SSM add Sources/SheetMusicAudioApple/PlaybackEngine+Export.swift
git -C $SSM commit -m "feat(audio): split export pipeline into melodic + percussion units

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Example display fix — transpose at the layout-build layer

The example renders pre-built `LayoutDocument`s computed from the original score, so the earlier `scoreContent(score: score.transposed(…))` change never affected the engraving. Feed the transposed score into the layout engine instead.

**Files:**
- Modify: `$SSM/Examples/Apple/SheetMusicExample/macOS/ContentViewMac.swift`
- Modify: `$SSM/Examples/Apple/SheetMusicExample/ContentView.swift` (iOS)

- [ ] **Step 1: macOS — lay out the transposed score**

In `ContentViewMac.swift`, add a helper on the view:

```swift
        /// The score handed to the layout engine: the loaded score with
        /// the active transpose applied, so the engraving reflects it.
        private func laidOut(_ s: Score) -> Score {
            s.transposed(bySemitones: transposeSemitones)
        }
```

Then wrap the score passed to EVERY `LayoutEngine.layout(...)`, `LayoutEngine.naturalContentWidth(...)`, and `LayoutEngine.measureContexts(...)` call with `laidOut(...)`:
- `adoptLoadedScore` (~2788–2797): `score: laidOut(loaded)` in both `layout(...)` and `naturalContentWidth(...)`; `measureContexts(for: laidOut(loaded))`.
- `rebuildLayoutsForOptionsChange` (~2847–2856): `score: laidOut(score)` in `layout(...)` and `naturalContentWidth(...)`.
- `adoptEditedScore` (~2877–2886): `score: laidOut(edited)` likewise.
- The vertical `.task` that builds `verticalDoc` (search for `verticalDoc = LayoutEngine.layout`): wrap its `score:`/`availableWidth` score arg with `laidOut(...)`.
- Keep `self.score = loaded/edited` as the ORIGINAL (untransposed) — only the layout inputs are transposed.

`scoreContent(score:)` is already called with `score.transposed(bySemitones: transposeSemitones)` at line ~234 — leave it (hit-testing then matches the transposed engraving). `rebuildLayoutsForOptionsChange()` is already invoked from `.onChange(of: transposeSemitones)`, so the trigger is in place.

- [ ] **Step 2: iOS — lay out the transposed score**

In `ContentView.swift` (the `#if !os(macOS)` view), the iOS path threads `transposeSemitones` into its layout-key structs but builds the layout from the raw score. Apply the same fix: add a `laidOut(_:)` helper and feed `laidOut(score)` into every `LayoutEngine.layout(...)` / `naturalContentWidth(...)` / `measureContexts(...)` call (search them in the file). Keep `transposeSemitones` in the layout keys so the cached layout invalidates on change.

- [ ] **Step 3: Build both platforms**

```bash
xcodebuild -project $SSM/Examples/Apple/SheetMusicExample.xcodeproj -scheme SheetMusicExample -destination 'platform=macOS' -skipPackagePluginValidation CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```
Expected `** BUILD SUCCEEDED **`. (iOS code compiles as part of the same scheme build; if the scheme builds for macOS only, also run with `-destination 'platform=iOS Simulator,name=iPhone 17'`.)

- [ ] **Step 4: Commit**

```bash
git -C $SSM add Examples/Apple/SheetMusicExample/macOS/ContentViewMac.swift Examples/Apple/SheetMusicExample/ContentView.swift
git -C $SSM commit -m "fix(example): apply transpose at the layout-build layer

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Verification (build + user regression gate)

- [ ] **Step 1: Full build**

```bash
swift build --package-path $SSM --target SheetMusicAudioApple
xcodebuild -project $SSM/Examples/Apple/SheetMusicExample.xcodeproj -scheme SheetMusicExample -destination 'platform=macOS' -skipPackagePluginValidation CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```
Both green.

- [ ] **Step 2: HANDOFF — user regression + new-behavior verification**

The split touches shipped playback, so hand to the user to run the example app (macOS) and confirm the full list. Do NOT push until approved.

Regression (must still work):
- Plain playback; melodic + drums both sound, balanced.
- Per-staff mute / solo / volume — including a drum staff.
- Program picker changes a pitched staff's timbre.
- Tap-to-audition / preview on pitched and drum staves.
- Metronome on/off.
- Audio export renders correctly.
- A4 tuning slider (Mixer) still retunes pitched content.

New behavior:
- Transpose stepper shifts pitched audio live (incl. held notes), no reload gap; **drums do NOT change pitch**.
- Transpose + A4 tuning together compose (melodic unit).
- Engraving re-renders with transpose; drum notation unchanged.

Note for the user to watch: whether AUMIDISynth's coarse-tuning param covers the full ±7 (if large transposes clip, that's a finding — fall back to the per-channel pitch-bend or score-reload approach for the out-of-range remainder).

- [ ] **Step 3: Profiling note (memory)**

While verifying, eyeball memory (Xcode debug gauge). If the two-unit SF2 double-load is a real cost, switch the percussion unit to a small drum-only SF2 (Polyphone-split) — otherwise leave it on the shared GM SF2. Report the observation.

---

## Task 5: Push + record revision

- [ ] **Step 1: Push** (only after user approval)

```bash
git -C $SSM push -u origin transpose
```

- [ ] **Step 2: Record HEAD**

```bash
git -C $SSM rev-parse HEAD
```
Record in the transpose project memory + Plan 2's re-pin task.

---

## Self-review notes

- **Spec coverage:** topology + scoreGainMixer (T1.4), state split + selector (T1.1), sequencer routing (T1.6), channel model unchanged (T1.6 keeps allocator), soundfont both units (T1.4 / T2.2), tuning model melodic=cal+transpose / perc=cal (T1.2), pitch-bend melodic-only (T1.4/6/7), mixer (T1.8), preview (T1.9), export (T2), transpose end-state = live melodic global tuning (T1.2), display fix (T3), verification incl. regression + memory profiling (T4). All spec sections map to a task.
- **Out of scope honored:** no channel-headroom allocator change; export does not newly apply transpose/calibration; no Android.
- **Type/name consistency:** `melodicSynth` / `percussionSynth` / `synth(forStaff:)` / `applyTuning()` / `ScoreSynth.melodic|percussion|staffIsDrum` used consistently across tasks.
- **Flagged for implementer verification:** track↔staff ordering in `buildSequencer` (T1.6 note); AUMIDISynth coarse-tuning ±7 range (T4.2 note); SF2 double-load memory (T4.3).

# Reader tap-audition: timbre + drum tail — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a tapped-note audition use the correct instrument before the first playback, and stop a previous preview (including a ringing drum cymbal) the moment a new note is tapped, while letting drums ring naturally.

**Architecture:** All changes are in `swift-sheet-music`'s `SheetMusicAudioApple.PlaybackEngine` (a `@MainActor` class). (1) Select per-channel GM programs in `prepare(score:)` so previews before the first `play()` aren't stuck on the SF2 seed preset (piano). (2) Replace the preview teardown (`activePreviewCount` + per-note `asyncAfter`) with one cancellable `DispatchWorkItem` plus a set of sounding channels, so a new tap cuts the previous preview via All Sound Off (CC 120) and drums get a longer tail. Folino consumes the fix by re-pinning ssm — no Folino source change.

**Tech Stack:** Swift 6, AVFoundation (`AVAudioEngine`, `AVAudioUnitMIDIInstrument` / AUMIDISynth), Dispatch.

**Testing note:** `PlaybackEngine` drives a live AudioUnit with no fake seam, so its audio behavior is verified **by ear in the ssm example app**, not by unit tests — consistent with this project's audio-layer convention (audio adapters are fake/by-ear tested, not asserted against real output). Each code task is verified by `swift build` (compiles) + the example-app pass in Task 3.

---

### Task 1: Select per-channel programs at load (timbre fix)

**Files:**
- Modify: `Sources/SheetMusicAudioApple/PlaybackEngine.swift` (in `prepare(score:)`, the block around `applyMixerState()`)

- [ ] **Step 1: Apply programs after mixer state**

In `prepare(score:)`, find:

```swift
        rebuildMixerChannels(for: score)
        applyMixerState()

        if !engine.isRunning {
            try engine.start()
        }
```

Replace with:

```swift
        rebuildMixerChannels(for: score)
        applyMixerState()
        // Select each non-drum channel's program now. Program selection
        // otherwise only happens in `reapplyMixerPrograms()` right after
        // `sequencer.start()` (the first `play()`), so a tap-preview fired
        // before any playback would sound on the SF2 seed preset
        // (GM program 0 = piano). Real playback re-applies programs after
        // `sequencer.start()` to win the race against the SMF's tick-0
        // program-change events, so playback behavior is unchanged.
        reapplyMixerPrograms()

        if !engine.isRunning {
            try engine.start()
        }
```

- [ ] **Step 2: Build**

Run: `xcrun swift build --package-path . --target SheetMusicAudioApple`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicAudioApple/PlaybackEngine.swift
git commit -m "fix(audio): select per-channel programs in prepare so pre-play previews aren't piano"
```

---

### Task 2: Clear-on-new-tap preview + drum tail

**Files:**
- Modify: `Sources/SheetMusicAudioApple/PlaybackEngine.swift` (preview state vars near line 78; `playPreview(...)` near line 432; `prepare(score:)` teardown near `stop()`)

- [ ] **Step 1: Replace the preview state vars**

Find:

```swift
    /// Preview notes currently sounding (note-off pending). Lets the
    /// drain logic re-pause the audio graph only once the *last*
    /// overlapping preview has ended. Main-actor isolated.
    private var activePreviewCount = 0
```

Replace with:

```swift
    /// MIDI channels with a currently sounding tap-preview note. A new preview
    /// sends All Sound Off (CC 120) to each before starting, so a fresh tap cuts
    /// the previous preview — including a drum one-shot (cymbal) whose decay a
    /// note-off would not truncate. Main-actor isolated.
    private var activePreviewChannels: Set<UInt8> = []
    /// The single pending end-of-preview action (note-off for melodic staves,
    /// CC 120 for drum one-shots) plus the host-parked-graph drain. Cancelled and
    /// replaced on each new tap so only one preview is ever alive.
    private var previewEndWorkItem: DispatchWorkItem?
    /// How long a drum-staff preview rings before it is ended and the graph
    /// drained. Melodic previews use the caller's `duration` (0.5 s); drums ring
    /// longer because a cymbal's musical value is its decay. By-ear tunable.
    private let drumPreviewTail: TimeInterval = 2.0
```

- [ ] **Step 2: Rewrite `playPreview`**

Replace the whole `playPreview(...)` function (from `public func playPreview(` through its closing `}` before `pitch(for:in:)`) with:

```swift
    public func playPreview(
        noteID: NoteID,
        in score: Score,
        duration: TimeInterval = 0.3,
        velocity: UInt8 = 96,
    ) {
        guard state != .exporting else { return }
        guard let pitch = pitch(for: noteID, in: score) else { return }
        let flatIdx = score.allStaves.firstIndex(where: {
            $0.address == noteID.staff
        }) ?? -1
        guard let instrument = synth,
              let midiChannel = staffMIDIChannels[flatIdx]
        else { return }

        // Cut any still-sounding previous preview before starting the new one.
        // All Sound Off (CC 120) is immediate and ignores release, so it also
        // silences a ringing drum one-shot (cymbal) that a note-off would leave
        // decaying. Cancel its pending end action so it can't fire late.
        previewEndWorkItem?.cancel()
        previewEndWorkItem = nil
        for channel in activePreviewChannels {
            MIDISynthBuilder.sendControlChange(
                into: instrument, controller: 120, value: 0, onChannel: channel,
            )
        }
        activePreviewChannels.removeAll()

        // A paused `AVAudioEngine` renders nothing, so resume the graph for the
        // preview; the drain below restores the host-parked state once the
        // preview ends with no follow-up tap.
        if !engine.isRunning {
            try? engine.start()
            if state != .playing {
                previewShouldRepauseEngineOnDrain = true
            }
        }

        instrument.startNote(
            pitch, withVelocity: velocity, onChannel: midiChannel,
        )
        activePreviewChannels.insert(midiChannel)

        // Drums ring for `drumPreviewTail` (the decay is the point); melodic
        // notes ring for the caller's `duration`. End melodic with a note-off
        // and drums with CC 120 (note-off won't stop a one-shot's decay).
        let isDrum = isDrumStaff(flatIdx)
        let tail = isDrum ? drumPreviewTail : duration
        let workItem = DispatchWorkItem { [weak self, weak instrument] in
            if let instrument {
                if isDrum {
                    MIDISynthBuilder.sendControlChange(
                        into: instrument, controller: 120, value: 0,
                        onChannel: midiChannel,
                    )
                } else {
                    instrument.stopNote(pitch, onChannel: midiChannel)
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                activePreviewChannels.remove(midiChannel)
                previewEndWorkItem = nil
                guard activePreviewChannels.isEmpty,
                      previewShouldRepauseEngineOnDrain
                else { return }
                previewShouldRepauseEngineOnDrain = false
                // Don't pause a graph that real playback is now driving.
                if state != .playing, engine.isRunning {
                    engine.pause()
                }
            }
        }
        previewEndWorkItem = workItem
        previewQueue.asyncAfter(deadline: .now() + tail, execute: workItem)
    }
```

- [ ] **Step 3: Cancel a live preview on teardown**

Add this private helper directly above `playPreview`:

```swift
    /// Stop and forget any in-flight tap-preview: cancel the pending end action,
    /// silence every still-sounding preview channel, and clear tracking. Called
    /// on teardown so a ringing preview can't outlive the synth it played on.
    private func cancelActivePreview() {
        previewEndWorkItem?.cancel()
        previewEndWorkItem = nil
        if let synth {
            for channel in activePreviewChannels {
                MIDISynthBuilder.sendControlChange(
                    into: synth, controller: 120, value: 0, onChannel: channel,
                )
            }
        }
        activePreviewChannels.removeAll()
        previewShouldRepauseEngineOnDrain = false
    }
```

In `prepare(score:)`, find:

```swift
        // Stop any in-flight playback before tearing down samplers.
        stop()
```

Replace with:

```swift
        // Stop any in-flight playback before tearing down samplers.
        stop()
        // Drop any ringing tap-preview so it can't outlive this synth.
        cancelActivePreview()
```

- [ ] **Step 4: Build**

Run: `xcrun swift build --package-path . --target SheetMusicAudioApple`
Expected: `Build complete!` (no reference to the removed `activePreviewCount`)

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicAudioApple/PlaybackEngine.swift
git commit -m "fix(audio): cut previous tap-preview on new tap (CC120) and let drums ring"
```

---

### Task 3: By-ear verification in the example app

**Files:** none (manual verification using `Examples/Apple/SheetMusicExample`, which already wires tap → `playPreview`)

- [ ] **Step 1: Build and run the example app**

Open `Examples/Apple/SheetMusicExample` in Xcode (or build the example scheme) and run on a simulator/device. Load a score that has both a melodic multi-instrument part and a drum part with a cymbal.

- [ ] **Step 2: Timbre check (do NOT press play first)**

Tap a melodic note before pressing play.
Expected: it sounds on the correct instrument, **not** piano.

- [ ] **Step 3: Drum ring + cut-on-tap check**

Tap a cymbal on the drum staff → it rings naturally (up to ~2 s).
While it rings, tap another note → the cymbal is cut immediately and the new note plays cleanly.

- [ ] **Step 4: Post-play recheck**

Press play once, pause, then repeat Steps 2–3.
Expected: still correct.

- [ ] **Step 5: Confirm CC 120 efficacy**

If a tapped cymbal still rings *after* a following tap, CC 120 isn't truncating on AUMIDISynth. Record the observation; the fallback is a per-channel silence (e.g. brief gain duck or note-off-all on the channel) — raise before changing approach.

---

### Task 4: Report, push ssm, re-pin Folino

**Files:**
- Modify (Folino): `Packages/Features/Reader/Package.swift`, `Packages/Domain/Package.swift`, `Packages/Infrastructure/Package.swift`, `Packages/Features/Library/Package.swift`, `project.yml`

- [ ] **Step 1: Report the by-ear result and get push approval**

Per project rules, ssm engine changes are reported before push. Summarize the example-app result and ask to push.

- [ ] **Step 2: Push ssm**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/ssm-staff-addresses push origin HEAD:main
```

- [ ] **Step 3: Capture the new ssm commit hash**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/ssm-staff-addresses rev-parse HEAD
```

- [ ] **Step 4: Re-pin Folino to the new hash**

In all four `Package.swift` files and `project.yml`, replace the current `swift-sheet-music` revision with the hash from Step 3. Then:

```bash
xcodegen generate
```

- [ ] **Step 5: Build Reader + hand off**

```bash
xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation
```
Expected: `BUILD SUCCEEDED`. Then hand off to the user for a clean-build by-ear check in Folino.

---

## Self-Review

**Spec coverage:**
- Spec §"Correct timbre at load" → Task 1. ✓
- Spec §"Clear-on-new-tap + let drums ring" (CC 120 on prior channels, drum tail, single work-item, drain) → Task 2. ✓
- Spec §Edge cases (teardown safety) → Task 2 Step 3 (`cancelActivePreview`). ✓
- Spec §Verification (example-app by-ear, CC 120 efficacy) → Task 3. ✓
- Spec §"report → push → re-pin" → Task 4. ✓

**Placeholder scan:** none — every code step shows full code; commands have expected output.

**Type consistency:** `activePreviewChannels: Set<UInt8>`, `previewEndWorkItem: DispatchWorkItem?`, `drumPreviewTail: TimeInterval`, `cancelActivePreview()`, `MIDISynthBuilder.sendControlChange(into:controller:value:onChannel:)`, `isDrumStaff(_:)`, `reapplyMixerPrograms()` — all match the existing engine API and are used consistently across tasks. `activePreviewCount` is fully removed (Task 2 Step 1) and not referenced afterward (it had no other usages).

**Known minor race (documented, accepted):** if a new tap's `cancel()` lands after the old work-item already began executing on `previewQueue`, the old item may send a stray note-off/CC 120 on the same channel right as the new note starts. The window is sub-millisecond against human-paced taps (tail ≥ 0.5 s); not worth synchronizing. Matches the pre-existing scheme's looseness.

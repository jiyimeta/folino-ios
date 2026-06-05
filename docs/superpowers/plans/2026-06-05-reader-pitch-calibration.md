# Reader Pitch Calibration (A4 reference frequency) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user retune playback to an arbitrary A4 reference (415–466 Hz, default 440) per-score in the Reader, with a global default in Settings — playback only, notation unchanged — on both iOS and Android.

**Architecture:** A constant cents offset (`cents = 1200·log2(f/440)`) is applied to every melodic MIDI channel via the standard **MIDI Master Tuning RPN** (coarse `00 02` + fine `00 01`). The cents→RPN encoding is one shared Swift helper in `SheetMusicAudioCore`; iOS sends it through `MusicDeviceMIDIEvent`, Android through FluidSynth `cc()`. Folino threads an `a4ReferenceHz` value (per-score `ReaderPreferences` override + global `@AppStorage` default) down to `PlaybackController.setMasterTuning(cents:)`, mirroring the existing `masterVolume` plumbing.

**Tech Stack:** Swift 6.3, swift-sheet-music (`SheetMusicAudioCore` / `SheetMusicAudioApple` / Android Kotlin+FluidSynth+JNI), Folino Domain/Infrastructure/Features, SwiftUI (iOS), Compose (Android), Swift Testing.

**Cross-repo note:** Phases 0–3 are in **swift-sheet-music** (ssm) — dev clone `~/Developer/Personal/swift-packages/swift-sheet-music`, worked in its own git worktree. Per workflow rule [[feedback_ssm_example_app_verify_before_push]]: verify in the ssm example apps, **report before pushing ssm**, push only after approval, then re-pin Folino (Phase 4). Phases 4–7 are in **Folino** (this worktree, `.claude/worktrees/reader-pitch-calibration`).

**Spike gate:** Phase 0 confirms both synths honor Master Tuning RPN. If either fails, STOP and report — Approach B (iOS `AVAudioUnitTimePitch` / Android `fluid_synth` gen) from the design doc replaces only that platform's engine task; the rest of the plan is unchanged because the engine API (`setMasterTuning(cents:)`) is identical.

---

## Reference: cents → RPN encoding (used throughout)

For an A4 of `f` Hz, `cents = 1200·log2(f/440)`. Split into coarse semitones + fine cents and encode as MIDI CC pairs:

```
coarseSemitones = Int(round(cents / 100))            // -1, 0, +1 over 415–466
fineCents       = cents - 100*Double(coarseSemitones) // [-50, +50]
fine14          = clamp(8192 + Int(round(fineCents/100 * 8192)), 0, 16383)

CC sequence (per channel):
  101=0, 100=2, 6=(64+coarseSemitones), 38=0          // Master Coarse Tuning (RPN 0,2)
  101=0, 100=1, 6=(fine14>>7), 38=(fine14 & 0x7F)     // Master Fine Tuning  (RPN 0,1)
  101=127, 100=127                                     // RPN Null (lock)
```

Both data-entry bytes (CC6 + CC38) are sent for each RPN because AUMIDISynth ignores the update until the full 14-bit value arrives (see `MIDISynthBuilder.setPitchBendSensitivity`).

---

# Phase 0 — Spike: confirm Master Tuning RPN works (GATE)

**Goal:** Prove AUMIDISynth (iOS) and FluidSynth (Android) audibly retune from a hand-sent RPN sequence, and that the retune survives program change + seek. No production code yet.

### Task 0.1: iOS spike in the ssm example app

**Files:**
- Modify: `~/Developer/Personal/swift-packages/swift-sheet-music/Examples/Apple/SheetMusicExample/` (the playback view — find it with the grep below)

- [ ] **Step 1: Locate the example playback view**

Run: `grep -rln "PlaybackEngine\|setMasterGain\|\.setRate" ~/Developer/Personal/swift-packages/swift-sheet-music/Examples/Apple/SheetMusicExample/`
Expected: one or two SwiftUI files that hold a `PlaybackEngine` and render transport controls. Open the one with the transport UI.

- [ ] **Step 2: Add a temporary "A4 Hz" slider wired to a raw RPN send**

In that view, add `@State private var a4Hz: Double = 440` and a `Slider(value: $a4Hz, in: 415...466)`. On change, call a temporary closure that, for `ch in 0..<16 where ch != 9`, sends the RPN sequence from the Reference section directly via `MIDISynthBuilder.sendControlChange(into: engine.synthForSpike, controller:, value:, onChannel: ch)`.

Because `synth` is currently `internal var synth`, expose a throwaway accessor on `PlaybackEngine` for the spike only:

```swift
// PlaybackEngine.swift — TEMPORARY, removed after spike
public func spikeSendMasterTuning(cents: Double) {
    guard let synth else { return }
    let coarse = Int((cents / 100).rounded())
    let fine = cents - 100 * Double(coarse)
    let fine14 = max(0, min(16383, 8192 + Int((fine / 100 * 8192).rounded())))
    for ch: UInt8 in 0 ..< 16 where ch != 9 {
        func cc(_ c: UInt8, _ v: UInt8) { MIDISynthBuilder.sendControlChange(into: synth, controller: c, value: v, onChannel: ch) }
        cc(101, 0); cc(100, 2); cc(6, UInt8(64 + coarse)); cc(38, 0)
        cc(101, 0); cc(100, 1); cc(6, UInt8(fine14 >> 7)); cc(38, UInt8(fine14 & 0x7F))
        cc(101, 127); cc(100, 127)
    }
}
```

Wire the slider's `onChange` to `engine.spikeSendMasterTuning(cents: 1200 * log2(a4Hz / 440))`.

- [ ] **Step 3: Build & run the example, verify audibly**

Run: open `~/Developer/Personal/swift-packages/swift-sheet-music/Examples/Apple/SheetMusicExample` in Xcode, run on a simulator, start playback, drag the slider.
Expected: pitch glides down toward 432/415 and up toward 466 while tempo is unchanged. Confirm the shift **persists after**: (a) changing a staff's instrument program, (b) seeking. Note any case where the tuning resets.

- [ ] **Step 4: Record the outcome**

Write the result (works / resets-after-X / no effect) into the design doc's "Verification spike" section. Do NOT commit the throwaway `spikeSendMasterTuning`.

### Task 0.2: Android spike in the ssm example app

**Files:**
- Modify: `~/Developer/Personal/swift-packages/swift-sheet-music/Examples/Android/` (Compose playback screen)

- [ ] **Step 1: Locate the example playback screen + engine access**

Run: `grep -rln "AndroidPlaybackEngine\|setMasterVolume\|setRate" ~/Developer/Personal/swift-packages/swift-sheet-music/Examples/Android/`
Expected: the Compose screen/ViewModel that owns an `AndroidPlaybackEngine`.

- [ ] **Step 2: Add a temporary tuning method on the engine + a slider**

Add to `AndroidPlaybackEngine.kt` (TEMPORARY):

```kotlin
fun spikeSendMasterTuning(cents: Double) {
    val eng = fluidSynthEngine ?: return
    val coarse = Math.round(cents / 100.0).toInt()
    val fine = cents - 100.0 * coarse
    val fine14 = (8192 + Math.round(fine / 100.0 * 8192.0).toInt()).coerceIn(0, 16383)
    for (ch in 0 until 16) {
        if (ch == 9) continue
        fun cc(c: Int, v: Int) = eng.cc(ch, c, v)   // add a passthrough on FluidSynthEngine if absent
        cc(101, 0); cc(100, 2); cc(6, 64 + coarse); cc(38, 0)
        cc(101, 0); cc(100, 1); cc(6, fine14 shr 7); cc(38, fine14 and 0x7F)
        cc(101, 127); cc(100, 127)
    }
}
```

If `FluidSynthEngine` has no public `cc(channel, controller, value)`, add a thin passthrough to its `driver.cc(...)`. Add a `Slider(415f..466f)` in the Compose screen calling `engine.spikeSendMasterTuning(1200 * log2(hz/440))`.

- [ ] **Step 3: Build, install, launch, verify audibly**

Per [[feedback_android_install_launch]] and [[project_android_build_toolchain]]: build the example `.so`/APK, `installDebug`, `adb shell` launch on the Pixel/emulator, play, drag slider.
Expected: same audible retune + persistence checks as iOS. Record outcome.

- [ ] **Step 4: Revert throwaway code, record outcome in design doc**

### Task 0.3: Decision gate

- [ ] **Both platforms honor RPN** → proceed to Phase 1 (Approach A).
- [ ] **Either platform fails** → STOP. Report to the user with the observed behavior; we switch that platform's engine task to Approach B (design doc §"Fallback") before continuing.

---

# Phase 1 — Shared cents→RPN helper (ssm `SheetMusicAudioCore`)

**Goal:** One tested, platform-neutral function producing the RPN CC sequence. Single source of truth for both engines.

### Task 1.1: `MasterTuning.rpnControlChanges(cents:)`

**Files:**
- Create: `~/Developer/Personal/swift-packages/swift-sheet-music/Sources/SheetMusicAudioCore/MasterTuning.swift`
- Test: `~/Developer/Personal/swift-packages/swift-sheet-music/Tests/SheetMusicAudioCoreTests/MasterTuningTests.swift` (create the test target dir if absent)

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import SheetMusicAudioCore

@Suite struct MasterTuningTests {
    @Test func zeroCentsIsCenteredFineAndNoCoarse() {
        let m = MasterTuning.rpnControlChanges(cents: 0)
        // coarse: 101=0,100=2,6=64,38=0 ; fine: 101=0,100=1,6=64,38=0 ; null
        #expect(m == [
            (101, 0), (100, 2), (6, 64), (38, 0),
            (101, 0), (100, 1), (6, 64), (38, 0),
            (101, 127), (100, 127),
        ].map(MasterTuning.CC.init))
    }

    @Test func minus100CentsIsOneSemitoneDown() {
        // 415 Hz ≈ -100¢ → coarse = -1 (value 63), fine centered
        let m = MasterTuning.rpnControlChanges(cents: -100)
        #expect(m.contains(MasterTuning.CC(controller: 6, value: 63)))  // coarse 64-1
    }

    @Test func cents432IsFineOnly() {
        // 432 Hz ≈ -31.77¢ → coarse 0, fine below center
        let m = MasterTuning.rpnControlChanges(cents: 1200 * log2(432.0 / 440.0))
        let coarse = m[0...3]
        #expect(Array(coarse) == [MasterTuning.CC(controller: 101, value: 0), .init(controller: 100, value: 2), .init(controller: 6, value: 64), .init(controller: 38, value: 0)])
        // fine MSB < 64 (detuned flat)
        let fineMSB = m[6]
        #expect(fineMSB.controller == 6 && fineMSB.value < 64)
    }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `cd ~/Developer/Personal/swift-packages/swift-sheet-music && swift test --filter MasterTuningTests`
Expected: FAIL — `MasterTuning` undefined. (If the full `swift test` is blocked by Android JNI per [[project_sheet_music_dev_clone_and_test_block]], run `swift build --target SheetMusicAudioCore` to confirm compile and run the filtered test target directly.)

- [ ] **Step 3: Implement the helper**

```swift
import Foundation

/// MIDI Master Tuning RPN encoding. Converts a cents offset (relative to
/// A4=440) into the Control-Change sequence that retunes a melodic channel,
/// shared by the Apple and Android playback engines so both retune identically.
public enum MasterTuning {
    public struct CC: Equatable, Sendable {
        public let controller: UInt8
        public let value: UInt8
        public init(controller: UInt8, value: UInt8) {
            self.controller = controller
            self.value = value
        }
        init(_ pair: (UInt8, UInt8)) { self.init(controller: pair.0, value: pair.1) }
    }

    /// CC pairs to send (in order) to one channel. Master tuning = coarse
    /// semitones + fine cents; both data-entry bytes are emitted because
    /// AUMIDISynth requires the full 14-bit value before applying the RPN.
    public static func rpnControlChanges(cents: Double) -> [CC] {
        let coarse = Int((cents / 100).rounded())
        let fineCents = cents - 100 * Double(coarse)
        let fine14 = max(0, min(16383, 8192 + Int((fineCents / 100 * 8192).rounded())))
        let coarseValue = UInt8(max(0, min(127, 64 + coarse)))
        return [
            CC(controller: 101, value: 0), CC(controller: 100, value: 2),
            CC(controller: 6, value: coarseValue), CC(controller: 38, value: 0),
            CC(controller: 101, value: 0), CC(controller: 100, value: 1),
            CC(controller: 6, value: UInt8(fine14 >> 7)), CC(controller: 38, value: UInt8(fine14 & 0x7F)),
            CC(controller: 101, value: 127), CC(controller: 100, value: 127),
        ]
    }
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `cd ~/Developer/Personal/swift-packages/swift-sheet-music && swift test --filter MasterTuningTests`
Expected: PASS.

- [ ] **Step 5: Commit (in the ssm worktree)**

```bash
git -C <ssm-worktree> add Sources/SheetMusicAudioCore/MasterTuning.swift Tests/SheetMusicAudioCoreTests/MasterTuningTests.swift
git -C <ssm-worktree> commit -m "feat(audio-core): MasterTuning RPN encoding (A4 calibration)"
```

---

# Phase 2 — iOS engine: `PlaybackEngine.setMasterTuning(cents:)`

**Goal:** Apply the shared RPN to all melodic channels on the AUMIDISynth, persisting across `prepare`/seek, plus an example-app slider as the live test bed.

### Task 2.1: `MIDISynthBuilder.setMasterTuning`

**Files:**
- Modify: `~/Developer/Personal/swift-packages/swift-sheet-music/Sources/SheetMusicAudioApple/MIDISynthBuilder.swift`

- [ ] **Step 1: Add the method (mirrors `setPitchBendSensitivity`)**

```swift
/// Apply Master Tuning (A4 calibration) on `channel` via the shared
/// `MasterTuning` RPN encoding. Sent through `MusicDeviceMIDIEvent` for the
/// same immediate-delivery reason as `setPitchBendSensitivity`.
static func setMasterTuning(
    into instrument: AVAudioUnitMIDIInstrument,
    cents: Double,
    onChannel channel: UInt8,
) {
    for cc in MasterTuning.rpnControlChanges(cents: cents) {
        sendControlChange(into: instrument, controller: cc.controller, value: cc.value, onChannel: channel)
    }
}
```

Add `import SheetMusicAudioCore` at the top if not already imported.

- [ ] **Step 2: Build the target**

Run: `cd ~/Developer/Personal/swift-packages/swift-sheet-music && swift build --target SheetMusicAudioApple`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git -C <ssm-worktree> add Sources/SheetMusicAudioApple/MIDISynthBuilder.swift
git -C <ssm-worktree> commit -m "feat(audio-apple): MIDISynthBuilder.setMasterTuning"
```

### Task 2.2: `PlaybackEngine.setMasterTuning(cents:)` + persistence

**Files:**
- Modify: `~/Developer/Personal/swift-packages/swift-sheet-music/Sources/SheetMusicAudioApple/PlaybackEngine.swift`

- [ ] **Step 1: Add stored state (next to `masterGain`, ~line 63)**

```swift
/// Current A4-calibration offset in cents (0 = A4 440 Hz). Stored so it
/// survives synth rebuilds in `prepareSynth`, like `masterGain`.
public private(set) var masterTuningCents: Double = 0
```

- [ ] **Step 2: Add the public setter (near `setRate`, ~line 146)**

```swift
/// Retune playback to an A4 reference expressed as a cents offset from 440 Hz
/// (e.g. 432 Hz ≈ -31.77¢). Applies to every melodic channel; the drum
/// channel (9) is left at concert pitch. Persists across `prepare`.
public func setMasterTuning(cents: Double) {
    guard state != .exporting else { return }
    masterTuningCents = cents
    guard let synth else { return }
    for ch: UInt8 in 0 ..< 16 where ch != 9 {
        MIDISynthBuilder.setMasterTuning(into: synth, cents: cents, onChannel: ch)
    }
}
```

- [ ] **Step 3: Re-apply after the synth is (re)built in `prepareSynth`**

In `prepareSynth(score:)`, immediately after the `for ch ... setPitchBendSensitivity` loop (~line 368), add:

```swift
if masterTuningCents != 0 {
    for ch: UInt8 in 0 ..< 16 where ch != 9 {
        MIDISynthBuilder.setMasterTuning(into: instrument, cents: masterTuningCents, onChannel: ch)
    }
}
```

- [ ] **Step 4: If the spike found seek/program-change resets tuning, re-apply there**

Only if Task 0.1 Step 3 observed a reset: after `reapplyMixerPrograms()` (called post-`sequencer.start()`) and at the end of `seek(to:)` / `seek(toTimeSeconds:)`, call the channel loop from Step 2 again. If the spike showed tuning persists, skip this step and note "not needed" in the commit body.

- [ ] **Step 5: Build**

Run: `cd ~/Developer/Personal/swift-packages/swift-sheet-music && swift build --target SheetMusicAudioApple`
Expected: builds clean.

- [ ] **Step 6: Commit**

```bash
git -C <ssm-worktree> add Sources/SheetMusicAudioApple/PlaybackEngine.swift
git -C <ssm-worktree> commit -m "feat(audio-apple): PlaybackEngine.setMasterTuning (A4 calibration)"
```

### Task 2.3: Permanent A4 slider in the iOS example app

**Files:**
- Modify: the iOS example playback view from Task 0.1

- [ ] **Step 1: Replace the throwaway spike slider with a real one**

`@State private var a4Hz: Double = 440`, `Slider(value: $a4Hz, in: 415...466)` with a `Text("\(a4Hz, specifier: "%.1f") Hz")`, `.onChange(of: a4Hz) { _, hz in engine.setMasterTuning(cents: 1200 * log2(hz / 440)) }`. Remove the `spikeSendMasterTuning` method.

- [ ] **Step 2: Build & run, confirm the production path works**

Run in Xcode; verify the slider retunes during playback.

- [ ] **Step 3: Commit**

```bash
git -C <ssm-worktree> add Examples/Apple/SheetMusicExample
git -C <ssm-worktree> commit -m "feat(example-apple): A4 calibration slider"
```

---

# Phase 3 — Android engine: `AndroidPlaybackEngine.setMasterTuning(cents:)`

**Goal:** Same retune on FluidSynth via `cc()`, using the shared RPN encoding bridged from Swift, plus an example slider.

### Task 3.1: Bridge the shared RPN list to Kotlin

**Files:**
- Modify: `~/Developer/Personal/swift-packages/swift-sheet-music/Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift` (or the JNI bridge file that exports `nativeRenderMidi`/`relabelChannelsToTrackIndex`)

- [ ] **Step 1: Find the JNI export pattern**

Run: `grep -rn "nativeRenderMidi\|@_cdecl\|Java_io_github_jiyimeta" ~/Developer/Personal/swift-packages/swift-sheet-music/Sources/SheetMusicAndroidJNI/`
Expected: the existing `@_cdecl`/jextract export style. Mirror it.

- [ ] **Step 2: Export `nativeMasterTuningRPN(centsMilli:) -> [Byte]`**

Add a bridge function that takes cents×1000 as an `Int` (avoid passing `Double` over JNI), calls `MasterTuning.rpnControlChanges(cents: Double(centsMilli)/1000)`, and returns the pairs flattened to a `ByteArray` of `[controller, value, controller, value, …]`. Follow the file's existing return-bytes convention.

- [ ] **Step 3: Build the Android libs**

Run: `~/Developer/Personal/swift-packages/swift-sheet-music/Scripts/android-build-libs.sh` (or the repo's documented cross-compile path per [[project_android_build_toolchain]]).
Expected: `.so` rebuilds with the new symbol.

- [ ] **Step 4: Commit**

```bash
git -C <ssm-worktree> add Sources/SheetMusicAndroidJNI/AudioMidiBridge.swift
git -C <ssm-worktree> commit -m "feat(android-jni): nativeMasterTuningRPN bridge"
```

### Task 3.2: `FluidSynthEngine.setMasterTuning` + `AndroidPlaybackEngine.setMasterTuning`

**Files:**
- Modify: `~/Developer/Personal/swift-packages/swift-sheet-music/Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/synth/FluidSynthEngine.kt`
- Modify: `~/Developer/Personal/swift-packages/swift-sheet-music/Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt`
- Modify: the JNI-bridge Kotlin wrapper that exposes `renderMidi` (to add `masterTuningRPN`)

- [ ] **Step 1: Add `setMasterTuning` to `FluidSynthEngine`**

```kotlin
/** Apply A4 calibration (cents offset from 440) to all melodic channels. */
fun setMasterTuning(rpn: ByteArray) {
    for (ch in 0 until staffCount) {           // staffCount = channels set up in setupStaves
        if (isDrumChannel(ch)) continue
        var i = 0
        while (i < rpn.size) {
            driver.cc(ch, rpn[i].toInt() and 0xFF, rpn[i + 1].toInt() and 0xFF)
            i += 2
        }
    }
}
```

Use the engine's existing notion of how many channels/staves exist and which are drums (the same set `setupStaves` configured). If `FluidSynthEngine` doesn't already track that, add a `private val staffCount` / `drumChannels` captured in `setupStaves`.

- [ ] **Step 2: Add `setMasterTuning(cents:)` to `AndroidPlaybackEngine`**

```kotlin
private var masterTuningCents: Double = 0.0

/** Retune playback to an A4 reference (cents offset from 440). Persists across prepare. */
fun setMasterTuning(cents: Double) {
    if (_state.value == PlaybackState.EXPORTING) return
    masterTuningCents = cents
    val rpn = jniBridge.masterTuningRPN((cents * 1000).toInt())  // -> ByteArray
    fluidSynthEngine?.setMasterTuning(rpn)
}
```

- [ ] **Step 3: Re-apply after `engine.setupStaves(...)` in `prepare`**

In `prepare(scoreHandle:)`, right after `engine.setupStaves(...)` (~line 315), add:

```kotlin
if (masterTuningCents != 0.0) {
    engine.setMasterTuning(jniBridge.masterTuningRPN((masterTuningCents * 1000).toInt()))
}
```

Plus the seek/program-change re-apply only if the Android spike (Task 0.2) found a reset.

- [ ] **Step 4: Build, install, launch, verify**

Per [[feedback_android_install_launch]]: rebuild libs, `installDebug`, `adb shell` launch, confirm retune.

- [ ] **Step 5: Commit**

```bash
git -C <ssm-worktree> add Android/SheetMusicAudioAndroid/...
git -C <ssm-worktree> commit -m "feat(audio-android): AndroidPlaybackEngine.setMasterTuning"
```

### Task 3.3: A4 slider in the Android example app

- [ ] **Step 1:** Replace the throwaway spike slider with a real `Slider(415f..466f)` calling `engine.setMasterTuning(1200 * log2(hz/440))`; remove `spikeSendMasterTuning`.
- [ ] **Step 2:** Build, install, launch, verify.
- [ ] **Step 3:** Commit `feat(example-android): A4 calibration slider`.

### Task 3.4: Report & push ssm

- [ ] **Step 1: Report to the user** — summarize spike outcome + the engine API, that both example apps verify the retune. **Wait for approval.** (Workflow rule [[feedback_ssm_example_app_verify_before_push]].)
- [ ] **Step 2: After approval**, push the ssm branch and capture the merge commit SHA for the Folino re-pin.

---

# Phase 4 — Re-pin Folino to the new ssm

**Files:**
- Modify: `Packages/Domain/Package.swift` (and any other `Package.swift` pinning swift-sheet-music)
- Modify: `project.yml` (the `from:`/`revision:` for swift-sheet-music) per CLAUDE.md (both must move together)

- [ ] **Step 1:** Update the swift-sheet-music pin (revision/version) in every `Package.swift` that references it AND in `project.yml`.
- [ ] **Step 2:** `xcodegen generate`.
- [ ] **Step 3:** Build the app: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build` — expect success against the new engine API.
- [ ] **Step 4:** Commit `build: re-pin swift-sheet-music for A4 calibration`.

---

# Phase 5 — Folino Domain: thread `a4ReferenceHz` (mirror `masterVolume`)

**Goal:** Per-score override field + bounds + Codable + the cents conversion + the protocol method. Pure, Foundation-only, shared by both platforms.

### Task 5.1: `A4Reference` constants + cents helper

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/A4Reference.swift`
- Test: `Packages/Domain/Tests/DomainTests/A4ReferenceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import Domain

@Suite struct A4ReferenceTests {
    @Test func centsAt440IsZero() {
        #expect(abs(A4Reference.cents(forHz: 440)) < 1e-9)
    }
    @Test func cents432IsAboutMinus31_77() {
        #expect(abs(A4Reference.cents(forHz: 432) - (-31.766654)) < 1e-3)
    }
    @Test func effectiveUsesOverrideThenGlobal() {
        #expect(A4Reference.effectiveHz(override: 432, globalDefault: 442) == 432)
        #expect(A4Reference.effectiveHz(override: nil, globalDefault: 442) == 442)
    }
    @Test func boundsClampToRange() {
        #expect(A4Reference.clamp(400) == A4Reference.minHz)
        #expect(A4Reference.clamp(500) == A4Reference.maxHz)
    }
}
```

- [ ] **Step 2: Run, verify it fails**

Run: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DomainTests/A4ReferenceTests` (per [[project_package_test_command]] — `swift test` is broken by the SwiftLint plugin; iPhone 16 sim isn't installed, use iPhone 17).
Expected: FAIL — `A4Reference` undefined.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// A4 reference-frequency (concert pitch) calibration for playback. Notation is
/// unaffected — this only shifts the audio. `cents` is the offset the audio
/// engine applies; `effectiveHz` resolves a per-score override against the
/// global default.
public enum A4Reference {
    public static let minHz: Double = 415
    public static let maxHz: Double = 466
    public static let standardHz: Double = 440

    public static func clamp(_ hz: Double) -> Double { min(max(hz, minHz), maxHz) }

    /// Cents offset from A4=440 for a reference of `hz`. `1200·log2(hz/440)`.
    public static func cents(forHz hz: Double) -> Double { 1200 * log2(hz / standardHz) }

    /// Per-score override wins; otherwise the global default.
    public static func effectiveHz(override: Double?, globalDefault: Double) -> Double {
        override ?? globalDefault
    }
}
```

- [ ] **Step 4: Run, verify it passes** (same command as Step 2) → PASS.

- [ ] **Step 5: Commit** `feat(domain): A4Reference calibration helper`.

### Task 5.2: `ReaderPreferences.a4ReferenceHz` (mirror `masterVolume`)

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift`
- Test: `Packages/Domain/Tests/DomainTests/ReaderPreferencesTests.swift` (add a case; create if absent)

- [ ] **Step 1: Write the failing Codable test**

```swift
@Test func a4ReferenceHzRoundTripsAndDefaultsNil() throws {
    var prefs = ReaderPreferences(scoreItemID: .init(), staffSize: 16, hiddenStaves: [])
    #expect(prefs.a4ReferenceHz == nil)                       // default = inherit global
    prefs.a4ReferenceHz = 432
    let data = try JSONEncoder().encode(prefs)
    let back = try JSONDecoder().decode(ReaderPreferences.self, from: data)
    #expect(back.a4ReferenceHz == 432)
    // Legacy payload without the key decodes to nil:
    let legacy = try JSONEncoder().encode({ var p = prefs; p.a4ReferenceHz = nil; return p }())
    #expect(try JSONDecoder().decode(ReaderPreferences.self, from: legacy).a4ReferenceHz == nil)
}
```

- [ ] **Step 2: Run, verify it fails** (build error — no such property).

- [ ] **Step 3: Add the property, init param, CodingKey, and decode line**

Mirror `masterVolume` exactly:
- Property (after `masterVolume`, ~line 67):
  ```swift
  /// Per-score A4 reference override in Hz. `nil` = inherit the global default.
  /// Clamped to `[A4Reference.minHz, A4Reference.maxHz]` when set.
  public var a4ReferenceHz: Double?
  ```
- Init param (after `masterVolume: Double = 1.0,`): `a4ReferenceHz: Double? = nil,`
- Init body: `self.a4ReferenceHz = a4ReferenceHz.map(A4Reference.clamp)`
- `CodingKeys`: add `a4ReferenceHz`
- `init(from:)`: `let a4 = try c.decodeIfPresent(Double.self, forKey: .a4ReferenceHz)` and pass `a4ReferenceHz: a4` into `self.init(...)`.

- [ ] **Step 4: Run, verify it passes** → PASS.

- [ ] **Step 5: Commit** `feat(domain): ReaderPreferences.a4ReferenceHz override`.

### Task 5.3: `PlaybackPreferences.a4ReferenceHz` + `PlaybackController.setMasterTuning`

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/PlaybackPreferences.swift`
- Modify: `Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift`

- [ ] **Step 1: Add to `PlaybackPreferences`** (mirror `masterVolume`):
  - Property: `public var a4ReferenceHz: Double` (default 440 — already resolved at build time)
  - Init param `a4ReferenceHz: Double = 440,`, body `self.a4ReferenceHz = A4Reference.clamp(a4ReferenceHz)`.

- [ ] **Step 2: Add the protocol method** (after `setMasterVolume`, ~line 50):

```swift
/// Retune playback to an A4 reference, expressed as a cents offset from 440 Hz
/// (use `A4Reference.cents(forHz:)`). Playback only — notation is unchanged.
func setMasterTuning(cents: Double) async
```

- [ ] **Step 3: Build Domain**

Run: `xcodebuild build -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: builds (existing `PlaybackController` conformers now fail to compile — fixed in Phase 6 Task 6.1; if Domain has in-package fakes, add the method there now).

- [ ] **Step 4: Commit** `feat(domain): PlaybackPreferences.a4ReferenceHz + setMasterTuning`.

---

# Phase 6 — iOS Infrastructure + UI

### Task 6.1: `LivePlaybackController.setMasterTuning` + seed at load

**Files:**
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift`

- [ ] **Step 1: Implement the protocol method** (mirror `setMasterVolume`):

```swift
public func setMasterTuning(cents: Double) async {
    engine.setMasterTuning(cents: cents)
}
```

- [ ] **Step 2: Seed it in `load(...)` from `preferences.a4ReferenceHz`**

Where `load(...)` applies `preferences.masterVolume` (grep `masterVolume` in this file), add alongside:

```swift
engine.setMasterTuning(cents: A4Reference.cents(forHz: preferences.a4ReferenceHz))
```

(Apply after `prepare(score:)` so the synth exists; `prepareSynth` also re-applies the stored value, so ordering is safe either way.)

- [ ] **Step 3: Fix any other `PlaybackController` conformers**

Run: `grep -rln "PlaybackController" Packages/*/Sources Packages/*/Tests App` — add `setMasterTuning(cents:)` to every conformer (live + fakes). For fakes: record the last cents in a property for assertions.

- [ ] **Step 4: Build the app + run Infrastructure/Reader tests**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`
Expected: builds clean.

- [ ] **Step 5: Commit** `feat(infra): LivePlaybackController.setMasterTuning + load seed`.

### Task 6.2: Resolve effective A4 when building `PlaybackPreferences`

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/PlaybackPreferences+Initial.swift` (the initial builder from the design doc) — confirm path with `grep -rln "PlaybackPreferences(" Packages/Features/Reader`
- The Reader's global-default source: `@AppStorage("reader.a4ReferenceHz")` (mirrors how layout mode is global per `ReaderPreferences` doc-comment).

- [ ] **Step 1:** When constructing `PlaybackPreferences` from `ReaderPreferences`, set
  `a4ReferenceHz: A4Reference.effectiveHz(override: readerPrefs.a4ReferenceHz, globalDefault: globalA4)`
  where `globalA4` is read from `@AppStorage` (default `A4Reference.standardHz`). Thread `globalA4` into the builder the same way other global Reader settings reach it.
- [ ] **Step 2:** Build the app — expect clean.
- [ ] **Step 3:** Commit `feat(reader): resolve effective A4 into PlaybackPreferences`.

### Task 6.3: Reader playback-inspector A4 row

**Files:**
- Modify: the Reader playback inspector view — find with `grep -rln "masterVolume\|setMasterVolume" Packages/Features/Reader/Sources`
- Modify: the Reader view model that owns prefs + calls `setMasterVolume` (same grep)
- Localization: the Reader `.xcstrings` (add keys per [[project_localization_key_scheme]]: `reader.inspector.a4Reference.*`)

- [ ] **Step 1: Add an A4 slider row** beside the existing master-volume row:
  - `Slider(value: $a4Hz, in: A4Reference.minHz...A4Reference.maxHz)`
  - Primary label `"\(a4Hz, specifier: "%.1f") Hz"`, secondary `"\(cents, specifier: "%+.1f")¢"` where `cents = A4Reference.cents(forHz: a4Hz)`.
  - A "Reset to default" control that sets the per-score override back to `nil` (falls to global). Show an "overriding" indicator when `readerPrefs.a4ReferenceHz != nil`.
  - Snap detents at 432 and 440 (snap when within ~1 Hz on slider-end).
- [ ] **Step 2: Wire the view model** — on change: clamp, store into `ReaderPreferences.a4ReferenceHz`, persist (same path as `masterVolume`), and call `playbackController.setMasterTuning(cents: A4Reference.cents(forHz: effectiveHz))`.
- [ ] **Step 3: Preview-verify** per global iOS rule — add/refresh a `#Preview` of the inspector and render via `mcp__xcode__RenderPreview`; iterate against the snapshot.
- [ ] **Step 4: Build the app** — clean.
- [ ] **Step 5: Commit** `feat(reader-ios): A4 calibration row in playback inspector`.

### Task 6.4: Settings global-default control

**Files:**
- Modify: the Settings feature screen — find with `grep -rln "AppStorage\|SettingsView\|Form" Packages/Features/Settings/Sources`
- Localization: Settings `.xcstrings` (`settings.playback.a4Reference.*`)

- [ ] **Step 1:** Add a slider bound to `@AppStorage("reader.a4ReferenceHz")` (default `A4Reference.standardHz`), range `minHz...maxHz`, same Hz + cents readout, snap detents at 432/440.
- [ ] **Step 2:** Preview-verify; build the app.
- [ ] **Step 3:** Commit `feat(settings-ios): global A4 reference default`.

---

# Phase 7 — Android Infrastructure + UI

**Goal:** Same per-score override + global default, reaching `AndroidPlaybackEngine.setMasterTuning`. Placement follows Android idiom (inspector `ModalBottomSheet` + gear Settings), content at iOS parity.

### Task 7.1: Resolve + apply effective A4 on the Android playback path

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderAudioViewModel.kt`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderPlaybackService.kt` (wherever load-time prefs seed the engine)

- [ ] **Step 1:** Add `fun setA4ReferenceHz(hz: Double)` to `ReaderAudioViewModel` that computes `cents = 1200 * log2(hz/440)` (one line — the shared single-source is the RPN encoding in ssm, already bridged) and calls `engine.setMasterTuning(cents)`.
- [ ] **Step 2:** At playback prepare/load, resolve `effectiveHz = perScoreOverride ?: globalDefault ?: 440.0` (mirror the iOS resolver; reuse the per-score prefs store the Reader already round-trips) and seed `engine.setMasterTuning(...)`.
- [ ] **Step 3:** Build libs + `installDebug` + launch; confirm retune from the resolved value.
- [ ] **Step 4:** Commit `feat(reader-android): apply A4 calibration on playback`.

### Task 7.2: Per-score override persistence (Reader prefs parity)

**Files:**
- The Android Reader preferences store/codec that already round-trips `masterVolume`-equivalent fields — find with `grep -rln "masterVolume\|ReaderPreferences\|a4\|tempoMultiplier" Android/`

- [ ] **Step 1:** Add `a4ReferenceHz: Double?` (nullable = inherit) to the Android-side Reader prefs representation, matching the shared `ReaderPreferences` Codable shape so iOS/Android round-trip the same persisted blob. If prefs sync through a shared encoded form, ensure the new optional key decodes-absent-as-null on both sides.
- [ ] **Step 2:** Room/store migration if the Android prefs are persisted in a versioned DB (bump version + migration, verify on device per [[project_android_build_toolchain]] migration practice).
- [ ] **Step 3:** Build + install + launch; verify a per-score value persists across relaunch.
- [ ] **Step 4:** Commit `feat(reader-android): persist per-score A4 override`.

### Task 7.3: Inspector A4 row (Compose)

**Files:**
- Modify: the Android playback inspector `ModalBottomSheet` — find with `grep -rln "masterVolume\|ModalBottomSheet\|Slider" Android/FolinoReaderAndroid/`
- Android string resources (`values/strings.xml` + locales en/ja/ko/zh-Hans/zh-Hant per the display-inspector precedent)

- [ ] **Step 1:** Add a `Slider(415f..466f)` row beside master volume with `"%.1f Hz"` + `"%+.1f¢"` text, a reset-to-default affordance, and snap at 432/440. On change → `viewModel.setA4ReferenceHz(hz)` + persist the override.
- [ ] **Step 2:** Build + install + launch; verify the row retunes live.
- [ ] **Step 3:** Commit `feat(reader-android): A4 row in playback inspector`.

### Task 7.4: Android Settings global default

**Files:**
- Modify: the Android gear-Settings screen — find with `grep -rln "Settings\|DataStore\|Preference" Android/`

- [ ] **Step 1:** Add a global A4 slider backed by DataStore/SharedPreferences (default 440), range 415–466, same readout + snaps. The Reader's effective-value resolver (Task 7.1 Step 2) reads this default.
- [ ] **Step 2:** Build + install + launch; verify the global default applies to a score with no override and that a per-score override wins.
- [ ] **Step 3:** Commit `feat(settings-android): global A4 reference default`.

---

# Final verification

- [ ] iOS app builds: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`.
- [ ] Domain tests pass: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17'`.
- [ ] ssm `MasterTuningTests` pass.
- [ ] Android builds, installs, launches; A4 row + Settings default both retune audibly and persist (Pixel/emulator per [[feedback_android_install_launch]]).
- [ ] Manual matrix on both platforms: override-only, global-only, override-beats-global, reset-to-default, 432 & 440 snaps, persistence across relaunch.
- [ ] Confirm notation/cursor/export are unchanged by calibration.
```

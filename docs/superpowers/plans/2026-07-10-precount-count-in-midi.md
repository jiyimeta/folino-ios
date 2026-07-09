# Precount via MIDI Pre-Roll — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Play the count-in through the swift-sheet-music playback engine as a pre-roll region prepended to the score's MIDI sequence — so the click matches the metronome exactly and the handoff to playback is sample-accurate — and collapse the Folino side to a `play(countIn:)` flag.

**Architecture:** New pure `CountInBeats` in ssm `SheetMusicAudioCore` computes the pre-roll click schedule (ticks). `PlaybackEngine` (ssm `SheetMusicAudioApple`) prepends an always-on click track ahead of the score, shifts the score forward, pins the cursor during the pre-roll via a `SequenceMap` tick offset, and loops only the body. Folino calls `controller.play(countIn:)` and removes the prior separate-engine machinery.

**Tech Stack:** Swift 6.3, AVFoundation `AVAudioSequencer`, swift-sheet-music (`SheetMusicCore` / `SheetMusicAudioCore` / `SheetMusicAudioApple` / `SheetMusicMIDI`), Folino SPM modules.

## Global Constraints

- **Two repos.** ssm dev clone (worked on `main`): `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music`. Folino worktree: `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/precount-count-in-midi` (branch `worktree-precount-count-in-midi`). Every git command uses `git -C <repo>`; subagents commit to the correct repo via absolute paths.
- **ssm push is gated**: implement + verify in the ssm example app (macOS) → report → **user approval** → then push ssm `main` (per `feedback_ssm_example_app_verify_before_push`). Do NOT push ssm without approval.
- **Design spec**: `docs/superpowers/specs/2026-07-10-precount-count-in-midi-design.md` (Folino worktree). The count-in RULES are §4 there; every asserted click count/offset is authoritative.
- Count-in must be **metronome-independent** (clicks sound with the metronome toggle off), **cursor-pinned** during the pre-roll, **loop-safe** (fires once, before the loop A-point), and **absent from export**.
- ssm `numerator`/`denominator` on `TimeSignature` are `Int` (not `Int?`). `MidiWriter` requires sorted, non-negative ticks (no negative pre-roll).
- New Folino tests use Swift Testing. Match the existing ssm test target's framework/style (check the target before writing).
- `play(countIn:)` defaults `false`; only `ReaderPlaybackSession.togglePlayback` passes the toggle — every other caller is unaffected.
- ssm package tests: run from the ssm repo via its own scheme (verify the scheme/target name first; the full `SheetMusicTests` suite may be Android-JNI-blocked per project memory — target the specific new suites).

## Verified integration points (from engine exploration — verify against live code before editing)

All in `swift-sheet-music/Sources/`:
- `SheetMusicAudioCore/MetronomeBeat.swift`: `struct MetronomeBeat { let tick: Int; let isDownbeat: Bool }`; `PlaybackTimeline.metronomeBeats(score:) -> [MetronomeBeat]` (:28) — per-measure carried-forward TS walk (default 4/4, adopt first `.timeSignature`, break at first `.chord`), `step = max(1, division*4/ts.denominator)`, content-sum via `c.duration.resolved(in: measureDuration).ticks(division:)`, `isDownbeat: i==0 && !isIrregular`.
- `SheetMusicAudioApple/MetronomeController.swift`: `metronomeTrack(beats:division:) -> MidiTrack` (:94, channel 9, notes 76/77, vel 100/80, note-off `+max(1,division/4)`); `isEnabled` `didSet { track?.isMuted = !isEnabled }` (:36); `attach(to:)` grabs `sequencer.tracks.last` (:126); one `sampler` + one `track`.
- `SheetMusicAudioApple/PlaybackEngine.swift`: `play(from:in:)` (:683), `buildSequencer(for:)` (:1058, `MidiRenderer.render` + append metronome track + `MidiWriter.write` + `sequencer.load`), `tickCursor()` (:1121, reads `sequencer.currentPositionInBeats`→tick→`timeline.frame(atTick:)?.cursor`; loop-wrap; end-stop), `startCursorTimer()` (:1102), `pause()` (:950), `stop()` (:963), `skip(by:)` (:906), `currentTimeSeconds` (:856), `totalTimeSeconds` (:896), `setLoop` (:789), `wrapToLoopStart` (:1168), `loopRange`/`sequencerScore` state.
- `SheetMusicMIDI/Render/MidiRenderer.swift`: `render(score:) -> MidiFile` (:16). `MidiFile { division, format, tracks: [MidiTrack] }`, `MidiTrack` holds `[TimedMidiEvent]`, `TimedMidiEvent { tick: Int; event: MidiEvent }`.
- `SheetMusicCore/PlaybackTimeline.swift`: `frame(atTick:)`, `frame(forCursor:)`, `frame(atTime:)`, `Frame { tick, timeSeconds, cursor }`, `totalSeconds`, `division`.
- `SheetMusicCore`: `Score.effectiveQuarterBpm(at: ScoreCursor?) -> Double`, `Score.tickInMeasure(of:)`, `Measure.actualLength/irregular`, `Fraction.ticks(division:)`, `TimeSignature(numerator:denominator:)`, `VoiceElement.timeSignature/.chord`, `VoiceElement.tickCount(division:in:) -> Int?`, `ScoreCursor.beat/.item + measureIndex`.

---

### Task 1: ssm `CountInBeats.compute` + tests (`SheetMusicAudioCore`)

**Files:**
- Create: `swift-sheet-music/Sources/SheetMusicAudioCore/Metronome/CountInBeats.swift`
- Test: `swift-sheet-music/Tests/<ssm-audio-core-test-target>/CountInBeatsTests.swift` (find the test target that covers `SheetMusicAudioCore` — check `Package.swift`; likely `SheetMusicAudioCoreTests` or a shared audio test target)

**Interfaces:**
- Produces: `enum CountInBeats { static func compute(score: Score, startCursor: ScoreCursor?) -> Result? }` where `struct Result { let preRollTicks: Int; let beats: [MetronomeBeat]; let quarterBpm: Double }`.

- [ ] **Step 1: Write the failing tests**

Port the prior `PrecountPlanTests` matrix as TICK assertions. Create `CountInBeatsTests.swift` (match the target's test framework — if the ssm audio-core tests use XCTest, use `XCTestCase`/`XCTAssertEqual`; if Swift Testing, use `@Test`/`#expect`). Fixture builder mirrors the score-construction pattern already used in that test target (find an existing test that builds a `Score` with measures + time signatures + tempo and copy its helpers). Assertions (division 480):

```
- 4/4, start .beat(2,0):        preRollTicks 1920; beats.count 4; isDownbeat [T,F,F,F]
- 4/4, start .beat(1,960):      preRollTicks 2880; beats.count 6; isDownbeat [T,F,F,F,T,F]  (the 6-click example)
- 3/4, start .beat(1,480):      preRollTicks 1920; beats.count 4; isDownbeat [T,F,F,T]
- 6/8, start .beat(0,0):        preRollTicks 1440; beats.count 6; step 240; isDownbeat [T,F,F,F,F,F]
- 2/2, start .beat(0,0):        preRollTicks 1920; beats.count 2; ticks [0,960]
- MuseScore pickup (m0 actualLength 1/4, irregular), start .beat(0,0):
                                preRollTicks 3360; beats.count 7; isDownbeat [T,F,F,F,T,F,F]
- MusicXML pickup (m0 voice0 = [.timeSignature(4/4), quarter rest], no actualLength/irregular), start .beat(0,0):
                                identical: preRollTicks 3360; beats.count 7; isDownbeat [T,F,F,F,T,F,F]
- pickup score, start .beat(2,0):  no shim → preRollTicks 1920; beats.count 4
- m0..2 4/4, m3 3/4, start .beat(3,0):  preRollTicks 1440; beats.count 3   (reads start measure, not m2)
- quarterBpm reflects the tempo at the start cursor (e.g. 120 → 120.0)
- empty score → nil
```

- [ ] **Step 2: Run the tests to verify they fail**

Run from the ssm repo (find the scheme/target): `xcodebuild test -scheme <ssm-scheme> -destination 'platform=macOS' -only-testing:<target>/CountInBeatsTests` (or the ssm repo's documented test command). Expected: FAIL — `CountInBeats` undefined.

- [ ] **Step 3: Write the implementation**

Create `CountInBeats.swift`:

```swift
import SheetMusicCore

/// Computes the count-in ("pre-roll") click schedule for playback starting at `startCursor`: one prepended
/// measure of the effective meter, an anacrusis right-align shim, and the mid-measure lead-in — as ticks,
/// so the playback engine can prepend them to the score's MIDI sequence. Pure; shared by iOS + Android.
public enum CountInBeats {
    public struct Result: Sendable, Equatable {
        /// Total ticks occupied by the pre-roll region (real playback begins here).
        public let preRollTicks: Int
        /// Click beats at ticks in `[0, preRollTicks)`. `isDownbeat` marks the accented (strong) clicks.
        public let beats: [MetronomeBeat]
        /// Quarter-note BPM governing the start position — the engine seeds the pre-roll tempo with it.
        public let quarterBpm: Double

        public init(preRollTicks: Int, beats: [MetronomeBeat], quarterBpm: Double) {
            self.preRollTicks = preRollTicks
            self.beats = beats
            self.quarterBpm = quarterBpm
        }
    }

    public static func compute(score: Score, startCursor: ScoreCursor?) -> Result? {
        guard let measures = score.parts.first?.staves.first?.measures, !measures.isEmpty else { return nil }
        let division = score.division
        guard division > 0 else { return nil }

        let startMeasure = min(max(startCursor?.measureIndex ?? 0, 0), measures.count - 1)
        let startTickInMeasure = startCursor.map { score.tickInMeasure(of: $0) } ?? 0

        func nominalTimeSignature(at index: Int) -> TimeSignature {
            var ts = TimeSignature(numerator: 4, denominator: 4)
            for mi in 0 ... index {
                for element in measures[mi].voices.first?.elements ?? [] {
                    if case let .timeSignature(t) = element { ts = t; break }
                    if case .chord = element { break }
                }
            }
            return ts
        }

        let ts = nominalTimeSignature(at: startMeasure)
        let step = max(1, division * 4 / ts.denominator)
        let numerator = max(1, ts.numerator)
        let nominalTicks = numerator * step

        let shim = anacrusisShim(measures: measures, startMeasure: startMeasure, division: division,
                                 nominalTicks: nominalTicks)
        let quarterBpm = score.effectiveQuarterBpm(at: startCursor)
        guard quarterBpm > 0 else { return nil }

        let preRollTicks = nominalTicks + shim + startTickInMeasure
        var beats: [MetronomeBeat] = []
        var tick = 0
        var k = 0
        while tick < preRollTicks {
            beats.append(MetronomeBeat(tick: tick, isDownbeat: k == 0 || k == numerator))
            tick += step
            k += 1
        }
        guard !beats.isEmpty else { return nil }
        return Result(preRollTicks: preRollTicks, beats: beats, quarterBpm: quarterBpm)
    }

    private static func anacrusisShim(measures: [Measure], startMeasure: Int, division: Int,
                                      nominalTicks: Int) -> Int {
        guard startMeasure == 0 else { return 0 }
        let actual = actualTicks(measures: measures, index: 0, division: division, nominalTicks: nominalTicks)
        let isAnacrusis = measures[0].irregular || (actual > 0 && actual < nominalTicks)
        return isAnacrusis ? max(0, nominalTicks - actual) : 0
    }

    private static func actualTicks(measures: [Measure], index: Int, division: Int, nominalTicks: Int) -> Int {
        if let actualLength = measures[index].actualLength { return actualLength.ticks(division: division) }
        guard let voice0 = measures[index].voices.first else { return 0 }
        let measureDuration = Fraction(numerator: max(1, nominalTicks), denominator: 4 * division)
        return voice0.elements.reduce(0) { $0 + ($1.tickCount(division: division, in: measureDuration) ?? 0) }
    }
}
```

Confirm `MetronomeBeat`'s initializer signature and that `numerator`/`denominator` are `Int` before compiling; adjust the fixture (not the logic) to the real API if needed.

- [ ] **Step 4: Run the tests to verify they pass** — same command; expected PASS.

- [ ] **Step 5: Commit** (in the ssm repo)

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music add Sources/SheetMusicAudioCore/Metronome/CountInBeats.swift Tests/<target>/CountInBeatsTests.swift
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music commit -m "feat(count-in): pure CountInBeats pre-roll click schedule + tests"
```

---

### Task 2: ssm `SequenceMap` + tests (`SheetMusicAudioApple`)

**Files:**
- Create: `swift-sheet-music/Sources/SheetMusicAudioApple/SequenceMap.swift`
- Test: `swift-sheet-music/Tests/<ssm-audio-apple-test-target>/SequenceMapTests.swift`

**Interfaces:**
- Produces: `struct SequenceMap { let preRollTicks: Int; let baseTick: Int; func scoreTick(fromSequencer:) -> Int?; func sequencerTick(fromScore:) -> Int }`.

- [ ] **Step 1: Write the failing tests**

```
- map(preRollTicks: 1920, baseTick: 0):
    scoreTick(fromSequencer: 0)    == nil     (pre-roll)
    scoreTick(fromSequencer: 1919) == nil
    scoreTick(fromSequencer: 1920) == 0
    scoreTick(fromSequencer: 2400) == 480
    sequencerTick(fromScore: 0)    == 1920
    sequencerTick(fromScore: 480)  == 2400
- map(preRollTicks: 1440, baseTick: 960):   // mid-score start at tick 960
    scoreTick(fromSequencer: 1440) == 960
    scoreTick(fromSequencer: 1920) == 1440
    sequencerTick(fromScore: 960)  == 1440
    sequencerTick(fromScore: 1440) == 1920
- identity map(preRollTicks: 0, baseTick: 0): scoreTick(fromSequencer: 500) == 500; sequencerTick(fromScore: 500) == 500
```

- [ ] **Step 2: Run → FAIL** (`SequenceMap` undefined).

- [ ] **Step 3: Implement**

```swift
/// Translates between the playback sequencer's tick space (which begins with a count-in pre-roll region)
/// and the score's own tick space. A count-in shifts all score content forward by `preRollTicks` and starts
/// it at score tick `baseTick`; ticks below `preRollTicks` are the pre-roll (no score position — cursor pinned).
struct SequenceMap: Equatable {
    let preRollTicks: Int
    let baseTick: Int

    static let identity = SequenceMap(preRollTicks: 0, baseTick: 0)

    /// The score tick a raw sequencer tick corresponds to, or nil while inside the pre-roll.
    func scoreTick(fromSequencer sequencerTick: Int) -> Int? {
        sequencerTick < preRollTicks ? nil : baseTick + (sequencerTick - preRollTicks)
    }

    /// The raw sequencer tick a score tick maps to (score tick must be >= baseTick).
    func sequencerTick(fromScore scoreTick: Int) -> Int {
        preRollTicks + (scoreTick - baseTick)
    }
}
```

- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** (ssm repo): `feat(count-in): SequenceMap pre-roll tick translation + tests`.

---

### Task 3: ssm `MetronomeController` — always-on pre-roll click track

**Files:**
- Modify: `swift-sheet-music/Sources/SheetMusicAudioApple/MetronomeController.swift`

**Interfaces:**
- Consumes: `CountInBeats.Result.beats` (Task 1), `metronomeTrack(beats:division:)` (existing).
- Produces: a way to attach a SECOND click track (the pre-roll) whose mute is NOT tied to `isEnabled`, routed to the same sampler (same sound/level). Exact shape below.

- [ ] **Step 1: Read `MetronomeController.swift` fully.** Note: it owns one `sampler`, one `track` (the body metronome, muted via `isEnabled`), and `attach(to:)` grabs `sequencer.tracks.last`. The pre-roll track will be a DIFFERENT track in the same sequence (added by `buildSequencer` in Task 4), also routed to `sampler` but never muted.

- [ ] **Step 2: Add pre-roll track wiring.** Add a stored `private var preRollTrack: AVMusicTrack?` and change `attach(to:)` so that, when a count-in is present, it routes the pre-roll track (a known track index passed from `buildSequencer`) to `sampler` with `isMuted = false` permanently, and the body metronome track keeps its `isEnabled`-driven mute. Concretely, add:

```swift
/// Route an additional always-on click track (the count-in pre-roll) to the metronome sampler. Its mute is
/// never tied to `isEnabled`, so the count-in sounds even when the metronome toggle is off.
func attachPreRoll(track: AVMusicTrack) {
    guard let sampler else { return }
    track.destinationAudioUnit = sampler
    track.isMuted = false
    preRollTrack = track
}
```

and clear `preRollTrack = nil` wherever `track`/attachment is reset (mirror the existing reset in `attach(to:)`).

- [ ] **Step 3: Verify it compiles** (ssm builds). This task has no standalone behavior test (the pre-roll track is exercised in Task 4 / the example app); its gate is that ssm compiles and the existing `MetronomeController`/metronome tests still pass. Run the existing metronome test suite.

- [ ] **Step 4: Commit** (ssm repo): `feat(count-in): always-on pre-roll click track in MetronomeController`.

---

### Task 4: ssm `PlaybackEngine` — pre-roll build, tick translation, cursor pin

**Files:**
- Modify: `swift-sheet-music/Sources/SheetMusicAudioApple/PlaybackEngine.swift`
- Test: `swift-sheet-music/Tests/<target>/PlaybackEnginePreRollTests.swift` (sequence-build assertions on the `MidiFile`, not audio)

**Interfaces:**
- Consumes: `CountInBeats.compute` (Task 1), `SequenceMap` (Task 2), `attachPreRoll` (Task 3).
- Produces: `public func play(from cursor: ScoreCursor?, in score: Score, countIn: Bool = false)` and the engine correctly pins the cursor + shifts content + loops the body.

- [ ] **Step 1: Read `PlaybackEngine.swift`** around `play(from:in:)` (:683), `buildSequencer(for:)` (:1058), `tickCursor()` (:1121), `skip(by:)` (:906), `currentTimeSeconds` (:856), `wrapToLoopStart` (:1168). Note every read of `sequencer.currentPositionInBeats` and every write of it.

- [ ] **Step 2: Write failing sequence-build tests.** Add a testable seam: factor the SMF assembly so a test can obtain the built `MidiFile` for a `(score, startCursor, countIn: true)` and assert:
  - pre-roll click note-ons exist at ticks `[0, preRollTicks)` on the pre-roll track (count matches `CountInBeats`), strong at tick 0.
  - score content that was at score tick `baseTick` now sits at sequencer tick `preRollTicks`; content `< baseTick` is absent.
  - with `countIn: false`, the `MidiFile` is byte-identical to today's build (no pre-roll, no shift).
  Run → FAIL.

- [ ] **Step 3: Implement.** Add an overload / parameter:

```swift
public func play(from cursor: ScoreCursor? = nil, in score: Score, countIn: Bool = false) { ... }
```

Introduce engine state `private var sequenceMap: SequenceMap = .identity`. In the play path, when `countIn == true` and `CountInBeats.compute(score:startCursor:)` returns a non-nil `plan`:
  1. `baseTick = timeline.frame(forCursor: cursor)?.tick ?? 0`; `sequenceMap = SequenceMap(preRollTicks: plan.preRollTicks, baseTick: baseTick)`.
  2. Build the sequence with the shift + pre-roll (new `buildSequencer(for:countIn:)` path):
     - `var midi = cachedRender(score)` (cache `MidiRenderer.render(score:)` per score to avoid re-rendering).
     - Shift + filter each staff track's events: drop `tick < baseTick`; `tick = preRollTicks + (tick - baseTick)`. Do the same for the tempo/time-sig meta track, and prepend a tempo meta at seq tick 0 = `plan.quarterBpm`.
     - Body metronome track: `metronomeBeats(score:)` filtered to `tick >= baseTick`, shifted; `metronomeTrack(...)`.
     - **Pre-roll track**: `metronome.metronomeTrack(beats: plan.beats, division: midi.division)` appended as its own track; after `sequencer.load`, call `metronome.attachPreRoll(track: sequencer.tracks[preRollTrackIndex])` and route the body metronome track as today.
  3. `sequencer.currentPositionInBeats = 0`; `start()`.
  When `countIn == false`: `sequenceMap = .identity` and build exactly as today (delegate to the existing `buildSequencer`).
  4. Translate every raw-position read/write through `sequenceMap`:
     - `tickCursor()`: `let raw = Int(sequencer.currentPositionInBeats * division)`; `guard let scoreTick = sequenceMap.scoreTick(fromSequencer: raw) else { /* pre-roll: keep currentCursor pinned at the start cursor */ return }`; then the existing `timeline.frame(atTick: scoreTick)?.cursor` logic. Loop-wrap compares `raw` against `sequenceMap.sequencerTick(fromScore: loop.endTick)`; wrap seeks to `sequenceMap.sequencerTick(fromScore: loop.startTick)`. End-of-score uses the translated tick.
     - `currentTimeSeconds` / `skip(by:)` / `seek`: translate the same way (score tick ↔ sequencer tick).
  5. Pin the cursor at play time: set `currentCursor = cursor` (or the start-of-score cursor) BEFORE `start()` so the pre-roll shows the start position immediately.

- [ ] **Step 4: Run the sequence-build tests → PASS.** Then confirm the existing playback/loop/seek tests still pass (the `countIn: false` path must be unchanged). Run the ssm playback test suite.

- [ ] **Step 5: Commit** (ssm repo): `feat(count-in): pre-roll region + cursor pin + tick translation in PlaybackEngine`.

---

### Task 5: ssm example-app verification → user approval → push

**Files:** none (manual verification + git push).

- [ ] **Step 1: Build the ssm example app** and add a temporary count-in trigger if needed (a button that calls `play(from:in:countIn: true)` with the metronome off). Follow `feedback_ssm_example_verify_on_mac` (scheme + macOS app) and `feedback_ssm_example_soundfont_symlink` (symlink the soundfont).
- [ ] **Step 2: Verify on macOS**: metronome OFF + count-in → clicks then music, cursor pinned then moving; beat-3 start → 6 clicks; loop → count-in once then body loops; tempo slider scales the count-in; click volume equals the metronome. Capture what you observed.
- [ ] **Step 3: Report to the user** with the verification results and **wait for approval**. Do NOT push before approval.
- [ ] **Step 4: On approval, push ssm `main`**: `git -C <ssm> push origin main` (destructive — only after explicit approval). Record the new HEAD revision for the Folino re-pin.

---

### Task 6: Folino — re-pin, `play(countIn:)`, orchestration, UI, remove old machinery

**Files (Folino worktree `worktree-precount-count-in-midi`):**
- Modify: `project.yml` + `Packages/Domain/Package.swift` + `Packages/Infrastructure/Package.swift` + `Packages/Features/Reader/Package.swift` + `Packages/Features/Library/Package.swift` — re-pin ssm to the new `main` revision from Task 5.
- Modify: `Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift` — `play()` → `play(countIn: Bool)` (keep a default if the protocol allows, else update all conformers).
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift` — forward `countIn` to `engine.play(from:in:countIn:)`.
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift` — `togglePlayback` calls `controller.play(countIn: isPrecountEnabled())`; add `isPrecountEnabled` closure (reads `ReaderGlobalSettingsKey.precountEnabled`).
- Add: `ReaderGlobalSettingsKey.precountEnabled` (`Domain/Models/ReaderLayoutMode.swift`), `SettingKey.precount` + caseToken (`Domain/Analytics/SettingKey.swift`), the Settings toggle (`Features/Settings/.../ReaderSettingsSection.swift` + its `Localizable.xcstrings`), the inspector row (`Features/Reader/.../PlaybackInspectorScreen.swift` + its `Localizable.xcstrings`). (Re-apply from the prior branch `worktree-precount-count-in` — same code; cherry-pick the exact diffs from commits `0729f551` (keys) and `519cd573` (UI) as a reference.)
- Update the `FakePlaybackController` to record the `countIn` flag.

**Interfaces:**
- Consumes: the new ssm `play(from:in:countIn:)`.
- Produces: pressing play with the precount toggle on → `controller.play(countIn: true)`.

- [ ] **Step 1: Re-pin ssm** to the Task-5 revision in `project.yml` + the 4 `Package.swift`; `env -C <worktree> xcodegen generate`; confirm packages resolve.
- [ ] **Step 2: Write the failing Folino test.** In `ReaderTests`, add `ReaderPlaybackSessionPrecountTests`: with `isPrecountEnabled = { true }`, `togglePlayback()` → the fake records `play(countIn: true)`; with `{ false }` → `countIn: false`. (`FakePlaybackController` gains `private(set) var lastPlayCountIn: Bool?`.) Run → FAIL.
- [ ] **Step 3: Implement** the `play(countIn:)` protocol change, the `LivePlaybackController` forward, the `ReaderPlaybackSession` one-line call + `isPrecountEnabled` closure, and re-apply the settings keys + Settings/inspector UI + localization. Run → PASS. Then build the Settings + Reader packages.
- [ ] **Step 4: Build the app** (`xcodebuild -project Folino.xcodeproj -scheme Folino ...`) → BUILD SUCCEEDED. Run `ReaderTests`.
- [ ] **Step 5: Install to the iPad** (`xcrun devicectl device install app --device B0449A61-255F-59F5-9BF1-04BA179E270C <app>`) and hand off to the user to confirm volume + timing on device.
- [ ] **Step 6: Commit** (Folino worktree): `feat(precount): count-in via ssm pre-roll (play(countIn:)); re-pin ssm` — whole-file staging.

## Self-review notes

- **Spec coverage**: §2 (logic homes) → Tasks 1/4/6; §3 (engine mechanism) → Tasks 2/3/4; §4 (algorithm) → Task 1; §5 (Folino thin) → Task 6; §6 (behavior) → Tasks 4/6 + example-app; §7 (testing) → each task's tests + Task 5; §8 risks → Task 4 (rebuild cache, tick boundaries).
- **No placeholders** in the new-component code (Tasks 1-2 are complete). Tasks 3-4-6 are modification tasks whose exact edits depend on live ssm/Folino code — each starts with a "read the file" step and gives precise integration points + the exact tick-translation semantics.
- **Type consistency**: `CountInBeats.Result` (Task 1) is consumed by Task 4; `SequenceMap` (Task 2) by Task 4; `attachPreRoll` (Task 3) by Task 4; `play(countIn:)` (Task 6) matches the ssm `play(from:in:countIn:)` (Task 4).
- **Gated push**: Task 5 is a hard user-approval gate before the ssm push and before Folino can re-pin (Task 6 depends on Task 5's revision).

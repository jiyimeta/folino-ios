# Transpose — Plan 1: swift-sheet-music primitives

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the two shared primitives transpose needs — a `Score.transposed(bySemitones:)` display transform and a live `PlaybackEngine.setTranspose(semitones:)` coarse-tuning method — and verify both in the example app before pushing swift-sheet-music.

**Architecture:** `Score.transposed` is a pure `Score → Score` transform that sits alongside `filtered(hidingStaves:)` / `applying(clefOverrides:)` in `Score+DisplayTransforms.swift`; it shifts key signatures and re-spells notes (skipping drum/percussion staves). Audio transposition is applied live by sending MIDI **RPN 0,2 (Channel Coarse Tuning)** to every pitched channel of the shared AUMIDISynth — no score reload. The example app gets a transpose stepper so the user can eyeball engraving + hear audio before push.

**Tech Stack:** Swift 6, SheetMusicCore (Foundation-only value types), SheetMusicAudioApple (AudioToolbox / AVFoundation AUMIDISynth), Swift Testing.

**Scope note:** This plan is **swift-sheet-music only**, in its own worktree. Folino iOS wiring is Plan 2; the Android FluidSynth `setTranspose` + Android UI is Plan 3. This plan ends at "user-verified, pushed, revision recorded."

---

## Pre-flight

- [ ] **Step 0: Cut the ssm worktree**

The swift-sheet-music dev clone is at `~/Developer/Personal/swift-packages/swift-sheet-music`. Per project convention, do NOT switch its shared checkout's branch — cut a worktree.

Run (from the ssm clone):
```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music worktree add /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/transpose -b transpose
```
Expected: `Preparing worktree (new branch 'transpose')`. All ssm paths below are under that worktree:
`/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/transpose` (abbreviated `$SSM` in commands).

---

## Task 1: `Score.transposed(bySemitones:)` — key-signature transposer helper

**Files:**
- Test: `$SSM/Tests/SheetMusicTests/Score/ScoreTransposeTests.swift` (create)
- Modify: `$SSM/Sources/SheetMusicCore/Score/Score+DisplayTransforms.swift`

- [ ] **Step 1: Write the failing test for the key-signature math**

Create `$SSM/Tests/SheetMusicTests/Score/ScoreTransposeTests.swift`:

```swift
@testable import SheetMusicCore
import Testing

struct ScoreTransposeTests {
    // MARK: - transposedKey (circle-of-fifths key-signature shift)

    @Test func keyUpTwoSemitonesFromCgoesToDmajor() {
        // C major (0) transposed +2 semitones → D major (+2 sharps).
        #expect(Score.transposedKey(0, bySemitones: 2) == 2)
    }

    @Test func keyUpOneSemitonePrefersFlatEnharmonic() {
        // C major (0) +1 semitone is C#(+7) or Db(-5); prefer the
        // ≤6-accidental spelling, Db major (-5).
        #expect(Score.transposedKey(0, bySemitones: 1) == -5)
    }

    @Test func keyDownOneSemitonePrefersSharpEnharmonic() {
        // C major (0) -1 semitone is Cb(-7) or B(+5); prefer B major (+5).
        #expect(Score.transposedKey(0, bySemitones: -1) == 5)
    }

    @Test func keyZeroDeltaIsIdentity() {
        #expect(Score.transposedKey(3, bySemitones: 0) == 3)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run:
```bash
swift test --package-path $SSM --filter ScoreTransposeTests/keyUpTwoSemitonesFromCgoesToDmajor
```
Expected: FAIL to compile — `transposedKey` is not a member of `Score`.

> **Test-run caveat (project memory):** the `SheetMusicTests` target pulls Android JNI bindings and may not build on the macOS host via plain `swift test`. If the command fails to *build* (not just fail the assertion), fall back to opening `$SSM/Package.swift` in Xcode and running `ScoreTransposeTests` there. The example-app verification in Task 4 is the integration backstop either way.

- [ ] **Step 3: Implement `transposedKey`**

Add to `$SSM/Sources/SheetMusicCore/Score/Score+DisplayTransforms.swift` (inside the existing `extension Score`):

```swift
    /// Transpose a key-signature accidental count (`-7…+7`, flats
    /// negative) by `delta` semitones along the circle of fifths.
    /// One semitone up = +7 positions (7 fifths). The result is
    /// normalized to `[-6, +6]` so the simpler enharmonic spelling
    /// wins (e.g. C +1 → Db (-5), not C# (+7)); adding/removing 12
    /// accidentals is an enharmonic respelling of the same pitch set,
    /// so this never changes which pitches sound — only how the key is
    /// written.
    static func transposedKey(_ key: Int, bySemitones delta: Int) -> Int {
        var k = key + 7 * delta
        while k > 6 { k -= 12 }
        while k < -6 { k += 12 }
        return k
    }
```

- [ ] **Step 4: Run to verify the 4 key-math tests pass**

Run:
```bash
swift test --package-path $SSM --filter ScoreTransposeTests
```
Expected: 4 passing (the `transposed`-transform tests come next).

- [ ] **Step 5: Commit**

```bash
git -C $SSM add Sources/SheetMusicCore/Score/Score+DisplayTransforms.swift Tests/SheetMusicTests/Score/ScoreTransposeTests.swift
git -C $SSM commit -m "feat(core): add transposedKey circle-of-fifths helper

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `Score.transposed(bySemitones:)` transform

**Files:**
- Test: `$SSM/Tests/SheetMusicTests/Score/ScoreTransposeTests.swift` (extend)
- Modify: `$SSM/Sources/SheetMusicCore/Score/Score+DisplayTransforms.swift`

- [ ] **Step 1: Write the failing tests**

Append to `ScoreTransposeTests`:

```swift
    // MARK: - transposed(bySemitones:)

    /// One-part, one-staff, one-measure score: C major key sig + a
    /// single C4 (MIDI 60) quarter note. `tpc` 14 = C natural.
    private func makeCMajorScore(useDrumset: Bool = false,
                                 group: String = "pitched") -> Score {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .quarter, notes: [note])
        let voice = Voice(elements: [
            .keySignature(KeySignature(concertKey: 0)),
            .chord(chord),
        ])
        let staff = Staff(group: group, measures: [Measure(voices: [voice])])
        let inst = Instrument(id: "i", longName: "i", useDrumset: useDrumset)
        return Score(division: 480, parts: [
            Part(id: "p0", instrument: inst, staves: [staff]),
        ])
    }

    private func firstNote(_ score: Score) -> Note? {
        guard case let .chord(c) = score.parts[0].staves[0]
            .measures[0].voices[0].elements[1] else { return nil }
        return c.notes.first
    }

    private func firstKey(_ score: Score) -> Int? {
        guard case let .keySignature(k) = score.parts[0].staves[0]
            .measures[0].voices[0].elements[0] else { return nil }
        return k.concertKey
    }

    @Test func transposeZeroIsIdentity() {
        let score = makeCMajorScore()
        #expect(score.transposed(bySemitones: 0) == score)
    }

    @Test func transposeUpTwoShiftsPitchAndKey() {
        let out = makeCMajorScore().transposed(bySemitones: 2)
        // C4 (60) → D4 (62); key C (0) → D (+2).
        #expect(firstNote(out)?.pitch == 62)
        #expect(firstKey(out) == 2)
    }

    @Test func transposeDownThreeShiftsPitch() {
        let out = makeCMajorScore().transposed(bySemitones: -3)
        #expect(firstNote(out)?.pitch == 57) // C4 → A3
    }

    @Test func drumsetPartIsNotTransposed() {
        let out = makeCMajorScore(useDrumset: true).transposed(bySemitones: 2)
        #expect(firstNote(out)?.pitch == 60) // unchanged
        #expect(firstKey(out) == 0)          // unchanged
    }

    @Test func percussionStaffIsNotTransposed() {
        let out = makeCMajorScore(group: "percussion").transposed(bySemitones: 5)
        #expect(firstNote(out)?.pitch == 60)
    }

    @Test func tickStructurePreservedSoCursorsStayValid() {
        let score = makeCMajorScore()
        let out = score.transposed(bySemitones: 4)
        // Same element count / shape — transpose touches pitch only.
        #expect(out.parts[0].staves[0].measures[0].voices[0].elements.count
            == score.parts[0].staves[0].measures[0].voices[0].elements.count)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run:
```bash
swift test --package-path $SSM --filter ScoreTransposeTests
```
Expected: the 6 new tests FAIL to compile — `transposed(bySemitones:)` undefined.

- [ ] **Step 3: Implement `transposed(bySemitones:)`**

Add to the same `extension Score` in `Score+DisplayTransforms.swift`:

```swift
    /// Returns a copy of the score with every pitched note shifted by
    /// `delta` semitones and every key signature transposed to match.
    /// Notes are re-spelled against the **destination** key via
    /// `Note.shifted(bySemitones:in:)`, so the engraving reads in the
    /// new key rather than as a wall of accidentals.
    ///
    /// Skipped, leaving pitch untouched:
    /// - parts whose instrument `useDrumset` is true, and
    /// - staves whose `group` is `"percussion"`
    ///   (unpitched — transposing would re-map drum sounds).
    ///
    /// The active key per note is resolved at **per-measure** granularity
    /// via `activeKey(staff:measureIndex:)`, matching the coarsening the
    /// arrow-key transpose already uses; mid-measure key changes (rare)
    /// take effect from their measure start. Grace notes are transposed
    /// alongside their parent chord.
    ///
    /// Tick structure, note IDs, and element ordering are unchanged —
    /// only `pitch` / `tpc` / `accidental` and `KeySignature.concertKey`
    /// move — so playback cursors and seek positions stay valid against
    /// the transposed score.
    public func transposed(bySemitones delta: Int) -> Score {
        guard delta != 0 else { return self }
        var copy = self
        for partIndex in copy.parts.indices {
            if copy.parts[partIndex].instrument.useDrumset { continue }
            for staffIndex in copy.parts[partIndex].staves.indices {
                if copy.parts[partIndex].staves[staffIndex].group == "percussion" {
                    continue
                }
                let address = StaffAddress(
                    partIndex: partIndex, staffIndexInPart: staffIndex,
                )
                let measures = copy.parts[partIndex].staves[staffIndex].measures
                for measureIndex in measures.indices {
                    let oldKey = activeKey(staff: address, measureIndex: measureIndex)
                    let newKey = Self.transposedKey(oldKey, bySemitones: delta)
                    let voices = copy.parts[partIndex].staves[staffIndex]
                        .measures[measureIndex].voices
                    for voiceIndex in voices.indices {
                        let elements = copy.parts[partIndex].staves[staffIndex]
                            .measures[measureIndex].voices[voiceIndex].elements
                        for elementIndex in elements.indices {
                            switch elements[elementIndex] {
                            case var .keySignature(k):
                                k.concertKey = Self.transposedKey(
                                    k.concertKey, bySemitones: delta,
                                )
                                copy.parts[partIndex].staves[staffIndex]
                                    .measures[measureIndex].voices[voiceIndex]
                                    .elements[elementIndex] = .keySignature(k)
                            case var .chord(c):
                                c.notes = ChordNotes(c.notes.map {
                                    $0.shifted(bySemitones: delta, in: newKey) ?? $0
                                })
                                c.graceNotesBefore = c.graceNotesBefore.map {
                                    Self.transposedGrace($0, delta: delta, key: newKey)
                                }
                                c.graceNotesAfter = c.graceNotesAfter.map {
                                    Self.transposedGrace($0, delta: delta, key: newKey)
                                }
                                copy.parts[partIndex].staves[staffIndex]
                                    .measures[measureIndex].voices[voiceIndex]
                                    .elements[elementIndex] = .chord(c)
                            default:
                                break
                            }
                        }
                    }
                }
            }
        }
        return copy
    }

    private static func transposedGrace(
        _ grace: GraceChord, delta: Int, key: Int,
    ) -> GraceChord {
        var g = grace
        g.notes = ChordNotes(grace.notes.map {
            $0.shifted(bySemitones: delta, in: key) ?? $0
        })
        return g
    }
```

> **Note on `ChordNotes(_:)`:** `Chord.notes` is a `ChordNotes` (pitch-deduped collection). Confirm its initializer-from-sequence signature when implementing — if `ChordNotes(_ seq:)` does not exist, assign element-by-element through its mutating API instead. Re-spelling never collides pitches (each shifted by the same delta), so dedup is a no-op here.

- [ ] **Step 4: Run to verify all transpose tests pass**

Run:
```bash
swift test --package-path $SSM --filter ScoreTransposeTests
```
Expected: all 10 tests PASS (4 key-math + 6 transform).

- [ ] **Step 5: Commit**

```bash
git -C $SSM add Sources/SheetMusicCore/Score/Score+DisplayTransforms.swift Tests/SheetMusicTests/Score/ScoreTransposeTests.swift
git -C $SSM commit -m "feat(core): add Score.transposed(bySemitones:) display transform

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Engine `setTranspose(semitones:)` — live coarse tuning

Audio behavior can't be unit-tested here (it needs a running AU + soundfont); Task 4's example-app run is the verification. These steps build the code and confirm it **compiles**.

**Files:**
- Modify: `$SSM/Sources/SheetMusicAudioApple/MIDISynthBuilder.swift`
- Modify: `$SSM/Sources/SheetMusicAudioApple/PlaybackEngine.swift`

- [ ] **Step 1: Add the coarse-tuning MIDI helper**

Add to `enum MIDISynthBuilder` in `MIDISynthBuilder.swift`, mirroring `setPitchBendSensitivity`:

```swift
    /// Set MIDI **RPN 0,2 (Channel Coarse Tuning)** on `channel` to
    /// `semitones` half-steps (negative = down). Data Entry MSB is
    /// `64 + semitones` (64 = no shift), per the MIDI Tuning spec.
    /// Goes through `MusicDeviceMIDIEvent` (synchronous C API) for the
    /// same race-avoidance reason as `setPitchBendSensitivity`.
    ///
    /// Caller is responsible for NOT calling this on the GM drum
    /// channel (9) — coarse-tuning a drum channel re-maps which drum
    /// sound each key triggers.
    static func setChannelCoarseTuning(
        into instrument: AVAudioUnitMIDIInstrument,
        semitones: Int,
        onChannel channel: UInt8,
    ) {
        let audioUnit = instrument.audioUnit
        let ccStatus = UInt32(0xB0) | UInt32(channel & 0x0F)
        func send(_ controller: UInt8, _ value: UInt8) {
            _ = MusicDeviceMIDIEvent(
                audioUnit, ccStatus, UInt32(controller), UInt32(value), 0,
            )
        }
        let dataEntry = UInt8(max(0, min(127, 64 + semitones)))
        send(101, 0) // RPN MSB
        send(100, 2) // RPN LSB → RPN (0,2) = Channel Coarse Tuning
        send(6, dataEntry) // Data Entry MSB (64 = center)
        send(101, 127) // RPN null (deselect, lock the value in)
        send(100, 127)
    }
```

- [ ] **Step 2: Add transpose state + apply method to the engine**

In `PlaybackEngine.swift`, add a stored property next to `masterGain` / `staffIsDrum` (around line 46–63):

```swift
    /// Whole-score transpose in semitones (`-7…+7`). Applied as MIDI
    /// coarse tuning to every pitched channel; re-applied after each
    /// `prepare(score:)` so a score reload preserves it. `0` = concert.
    public private(set) var transposeSemitones: Int = 0
```

Add the apply method (place it near the other live setters such as the master-volume / mixer methods; if those live in a `+Master` extension you may add this in the main file's `extension PlaybackEngine` alongside `isDrumStaff`):

```swift
    /// Live whole-score transpose. Sends RPN 0,2 coarse tuning to every
    /// pitched channel (all 16 MIDI channels except the GM drum channel
    /// 9). No score reload — instant during playback, zero-artifact.
    /// Clamped to `-7…+7`.
    public func setTranspose(semitones: Int) {
        let clamped = max(-7, min(7, semitones))
        transposeSemitones = clamped
        guard let synth else { return }
        for channel in UInt8(0) ... UInt8(15) where channel != 9 {
            MIDISynthBuilder.setChannelCoarseTuning(
                into: synth, semitones: clamped, onChannel: channel,
            )
        }
    }
```

- [ ] **Step 3: Re-apply transpose at the end of `prepare`'s channel-setup loop**

In `PlaybackEngine.swift`, the prepare path configures each channel's pitch-bend sensitivity around line 352–390 (`setPitchBendSensitivity(into: instrument, semitones: 12, onChannel: ch)`). After that per-channel loop completes, re-assert the current transpose so a reload (soundfont swap, re-prepare) doesn't drop it. Add, immediately after the channel-config loop:

```swift
        // Re-assert any active transpose: a fresh synth resets all
        // channels to concert pitch, so reapply the saved value.
        if transposeSemitones != 0 {
            for channel in UInt8(0) ... UInt8(15) where channel != 9 {
                MIDISynthBuilder.setChannelCoarseTuning(
                    into: instrument, semitones: transposeSemitones,
                    onChannel: channel,
                )
            }
        }
```
(Use whatever local name the loop uses for the synth — `instrument` in the prepare scope per the existing `setPitchBendSensitivity(into: instrument, …)` calls.)

- [ ] **Step 4: Verify the audio target compiles**

Run:
```bash
swift build --package-path $SSM --target SheetMusicAudioApple
```
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git -C $SSM add Sources/SheetMusicAudioApple/MIDISynthBuilder.swift Sources/SheetMusicAudioApple/PlaybackEngine.swift
git -C $SSM commit -m "feat(audio): live whole-score transpose via RPN coarse tuning

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Example-app transpose UI + user verification

**Files:**
- Modify: `$SSM/Examples/Apple/SheetMusicExample/ContentView.swift`

- [ ] **Step 1: Add a transpose stepper to the example**

In `ContentView.swift`:

1. Add state near `staffSize` (line ~19):
```swift
        @State private var transposeSemitones = 0
```

2. Apply the transform where the rendered score is derived. The view renders `score` directly in `scoreContent(score:)`; introduce a transposed view of it. Add a computed helper on the view:
```swift
        private func displayScore(_ base: Score) -> Score {
            base.transposed(bySemitones: transposeSemitones)
        }
```
and pass `displayScore(score)` into the layout/`ScoreView` pipeline in `scoreContent` instead of the raw `score` (replace the `score:` arguments fed to `ScoreView` / `LayoutDocument` building so the engraving reflects the transpose).

3. Add a stepper to the toolbar/controls (next to the existing staff-size / layout controls):
```swift
        Stepper("Transpose: \(transposeSemitones > 0 ? "+" : "")\(transposeSemitones)",
                value: $transposeSemitones, in: -7 ... 7)
            .onChange(of: transposeSemitones) { _, newValue in
                playbackEngine.setTranspose(semitones: newValue)
            }
```

> If `ScoreView`/layout caching keys off `scoreVersion` (a `UUID`), bump `scoreVersion = UUID()` inside the `onChange` too so the engraving re-lays-out on transpose change.

- [ ] **Step 2: Build & run the example app on a simulator**

Open `$SSM/Package.swift` (or the example's Xcode project under `Examples/Apple`) in Xcode, select the `SheetMusicExample` app scheme + an iPhone simulator, and Run. Load a score with a clear key signature and at least one pitched part (and ideally a drum part).

- [ ] **Step 3: HANDOFF — user verification (per user instruction)**

Stop and hand to the user. Ask them to confirm, on the running example app:
- Stepping transpose up/down **re-engraves** notes + key signature correctly (e.g. C major → D major at +2; flats appear at +1).
- Audio pitch **follows** the stepper, live, without restarting playback, with no glitches.
- A **drum/percussion** part does NOT change pitch or get re-engraved.

Do not proceed to push until the user approves.

---

## Task 5: Push & record revision

- [ ] **Step 1: Push the ssm branch** (only after user approval in Task 4)

```bash
git -C $SSM push -u origin transpose
```

- [ ] **Step 2: Record the pushed revision**

Capture the SHA for Plan 2's re-pin:
```bash
git -C $SSM rev-parse HEAD
```
Note it in the Plan 2 doc's re-pin task and in the project memory entry.

> Merging the ssm `transpose` branch to ssm `main` follows the team's normal cadence (may be deferred); Folino pins to the pushed revision regardless.

---

## Self-review notes

- **Spec coverage:** display transform (Task 1–2), drums excluded (Task 2 tests), live engine transpose (Task 3), example verification before push (Task 4), push + re-pin handoff (Task 5). Folino-side protocol/model/UI/PiP are Plan 2; Android is Plan 3 — explicitly out of this plan's scope.
- **Type consistency:** `transposed(bySemitones:)` / `transposedKey(_:bySemitones:)` / `setTranspose(semitones:)` / `setChannelCoarseTuning(into:semitones:onChannel:)` names are used identically across tasks.
- **Open verification items flagged inline:** `ChordNotes` sequence-initializer signature (Task 2 Step 3 note); AUMIDISynth honoring RPN 0,2 with MSB-only data entry (the whole point of the Task 4 audio check); example-app layout-cache invalidation (Task 4 Step 1 note).

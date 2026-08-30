# M2: Ensemble Scratch Creation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Multi-part score creation with an instrument catalog, templates, transposing instruments (written-pitch display and input, imports included), and part add/remove/reorder on existing scores.

**Architecture:** Concert pitch stays the single stored truth; written pitch is derived per part at display time from new `Instrument.transposeChromatic/Diatonic` fields. The instrument catalog and templates are static Domain data (`GMDrumKit` precedent); ssm stays catalog-agnostic with a multi-part `BlankScoreTemplate`. Part add/remove/reorder are ssm `EditIntent`s whose cumulative part-index mapping (derived by diffing `Part.id` snapshots) drives save-time migration of `StaffAddress`-keyed per-score preferences.

**Tech Stack:** Swift 6.3, SwiftUI, Swift Testing (`@Suite`/`@Test`/`#expect`), SwiftPM packages (Domain / ScoreUI / Features / Infrastructure), swift-sheet-music (ssm) local path pin.

**Spec:** `docs/superpowers/specs/2026-08-27-m2-ensemble-creation-design.md` (read it first; also the umbrella `docs/superpowers/specs/2026-08-26-scratch-score-creation-and-pro-design.md`)

## Global Constraints

- Two worktrees, two repos: **folino** = `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/scratch-creation-spec` (branch `worktree-scratch-creation-spec`); **ssm** = `/Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music` (branch `feature/scratch-creation-m1`). Commit each change in its own repo. Never merge ssm to main; no ssm release (umbrella policy).
- folino consumes ssm via local path pin; the 6 pin files (`Packages/*/Package.swift`, `project.yml`) are already modified in the working tree — leave them modified, do NOT commit them.
- ssm tests: `xcrun swift test --filter <SuiteName>` from the ssm worktree root (plain `swift test` may pick the wrong toolchain).
- folino package tests: `xcodebuild test -scheme <Pkg> -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` **from the package directory**. `swift test` does NOT work in the folino repo (SwiftLint plugin needs a macOS host context).
- folino app build: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build` (run `xcodegen generate` first only if `project.yml` changed — this plan does not change it).
- MuseScore (`~/Developer/musescore/MuseScore`) is a **behavioral/UX reference only — GPL, no code ported**. Numeric instrument facts (transposition intervals, GM programs, ranges) are facts, not expression — fine to use.
- No access modifier unless needed; `public` only for cross-module use. New tests use Swift Testing. Whole-file staging only (`git add <file>`, never `-p`).
- User-facing copy: app name is lowercase `folino`; never expose internal feature names (`Editor`, `Library`) in copy; Japanese copy uses 「楽譜」「楽器」 style wording.
- Comment paragraphs reflow at 120 columns.
- TPC/interval math used throughout (verify in tests, don't re-derive):
  `writtenPitchOffset = -transposeChromatic`; `writtenFifthsOffset = 12*transposeDiatonic - 7*transposeChromatic`.
  written pitch = concert pitch + writtenPitchOffset; written tpc = concert tpc + writtenFifthsOffset; written key = `respelledKey(concertKey + writtenFifthsOffset)`.
  Worked check (B♭ clarinet, `transposeDiatonic=-1, transposeChromatic=-2`): offsets = (+2, +2); concert B♭3 (pitch 58, tpc 12) → written C4 (60, 14); concert B♭ major (−2) → written C major (0). F horn (−4, −7) → offsets (+7, +1). E♭ alto sax (−5, −9) → (+9, +3). Octave bass (−7, −12) → (+12, 0).

---

### Task 1: ssm — Instrument transposition fields + written-offset helpers

**Repo:** ssm

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Instrument.swift`
- Test: `Tests/SheetMusicTests/EditingTests/InstrumentTranspositionTests.swift` (create)

**Interfaces:**
- Produces: `Instrument.transposeDiatonic: Int`, `Instrument.transposeChromatic: Int` (both default 0), `Instrument.writtenPitchOffset: Int`, `Instrument.writtenFifthsOffset: Int`, `Instrument.isTransposing: Bool`. Every later task uses these exact names.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import SheetMusicCore

@Suite struct InstrumentTranspositionTests {
    @Test func defaultsAreNonTransposing() {
        let piano = Instrument(id: "piano")
        #expect(piano.transposeDiatonic == 0)
        #expect(piano.transposeChromatic == 0)
        #expect(!piano.isTransposing)
        #expect(piano.writtenPitchOffset == 0)
        #expect(piano.writtenFifthsOffset == 0)
    }

    @Test func bFlatClarinetOffsets() {
        let clarinet = Instrument(id: "clarinet", transposeDiatonic: -1, transposeChromatic: -2)
        #expect(clarinet.isTransposing)
        #expect(clarinet.writtenPitchOffset == 2)
        #expect(clarinet.writtenFifthsOffset == 2)
    }

    @Test func fHornAndAltoSaxAndOctaveOffsets() {
        let horn = Instrument(id: "horn", transposeDiatonic: -4, transposeChromatic: -7)
        #expect(horn.writtenPitchOffset == 7)
        #expect(horn.writtenFifthsOffset == 1)
        let altoSax = Instrument(id: "alto-sax", transposeDiatonic: -5, transposeChromatic: -9)
        #expect(altoSax.writtenPitchOffset == 9)
        #expect(altoSax.writtenFifthsOffset == 3)
        let contrabass = Instrument(id: "contrabass", transposeDiatonic: -7, transposeChromatic: -12)
        #expect(contrabass.writtenPitchOffset == 12)
        #expect(contrabass.writtenFifthsOffset == 0)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `xcrun swift test --filter InstrumentTranspositionTests`. Expected: compile error, `transposeDiatonic` not a member.

- [ ] **Step 3: Implement.** Add to `Instrument` (stored after `drumLineMap`, init parameters after it too, defaults `= 0` so every existing call site compiles unchanged):

```swift
/// mscx `<transposeDiatonic>` — diatonic steps from written to sounding pitch (negative = sounds lower).
public var transposeDiatonic: Int
/// mscx `<transposeChromatic>` — semitones from written to sounding pitch (negative = sounds lower).
public var transposeChromatic: Int

/// Semitones to ADD to a concert (sounding) pitch to get the written pitch.
public var writtenPitchOffset: Int { -transposeChromatic }
/// Line-of-fifths shift to ADD to a concert tpc (or key) to get the written one.
public var writtenFifthsOffset: Int { 12 * transposeDiatonic - 7 * transposeChromatic }
public var isTransposing: Bool { transposeDiatonic != 0 || transposeChromatic != 0 }
```

- [ ] **Step 4: Run to verify pass** — same command, and the full `xcrun swift test` to catch `Equatable`/init fallout. Expected: PASS.
- [ ] **Step 5: Commit** (ssm repo): `git add Sources/SheetMusicCore/Score/Instrument.swift Tests/SheetMusicTests/EditingTests/InstrumentTranspositionTests.swift`, `git commit -m "feat: model instrument transposition on Instrument"`.

---

### Task 2: ssm — mscx round-trip of transposition (transpose tags, tpc2, written key sigs, decoder fallback fix)

**Repo:** ssm

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Instrument.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Instrument.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Note.swift`, `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+KeySignature.swift`, plus the options struct (`MSCXEncoderOptions`) and the Score/Part-level encoder that owns the per-part loop (`MSCXEncoder+Score.swift` / `MSCXEncoder+Measure.swift` — find where measures are encoded per staff and thread a per-part options copy down).
- Modify: the Score-level decoder (`MSCXDecoder+Score.swift`) for the v2/v3 written-key post-pass.
- Test: `Tests/SheetMusicTests/MSCXTests/TransposingInstrumentRoundTripTests.swift` (create)

**Interfaces:**
- Consumes: Task 1's `writtenPitchOffset` / `writtenFifthsOffset`.
- Produces: `MSCXEncoderOptions.writtenFifthsOffset: Int = 0` (per-part copy set by the part-measure encoding loop); `<transposeDiatonic>/<transposeChromatic>` round-trip on `<Instrument>`; `<tpc2>` on notes and `<accidental>` (written key) on KeySigs of transposing parts.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import SheetMusicCore
@testable import SheetMusicMSCX

@Suite struct TransposingInstrumentRoundTripTests {
    /// A one-part, one-measure score whose instrument is a B♭ clarinet holding concert B♭4 (pitch 70, tpc 12).
    private func clarinetScore() -> Score {
        var score = Score.blank(BlankScoreTemplate(
            title: "T", instrumentID: "clarinet", staves: [.init(clefType: "G")], measureCount: 1,
        ))
        score.parts[0].instrument.transposeDiatonic = -1
        score.parts[0].instrument.transposeChromatic = -2
        score.parts[0].staves[0].measures[0].voices[0].elements[2] =
            .chord(Chord(duration: .whole, notes: [Note(pitch: 70, tpc: 12)]))
        return score
    }

    @Test func transposeTagsRoundTrip() throws {
        let score = clarinetScore()
        let data = try MSCXEncoder().encode(score)                 // match the encoder's actual entry point
        let decoded = try MSCXDecoder().decode(data)               // match the decoder's actual entry point
        #expect(decoded.parts[0].instrument.transposeDiatonic == -1)
        #expect(decoded.parts[0].instrument.transposeChromatic == -2)
        #expect(decoded.parts[0].staves[0].measures[0].voices[0].elements[2]
            == score.parts[0].staves[0].measures[0].voices[0].elements[2])
    }

    @Test func encoderWritesTpc2AndWrittenAccidental() throws {
        let xml = try String(decoding: MSCXEncoder().encode(clarinetScore()), as: UTF8.self)
        #expect(xml.contains("<tpc2>14</tpc2>"))          // written C = concert B♭ + writtenFifthsOffset(2)
        #expect(xml.contains("<transposeChromatic>-2</transposeChromatic>"))
    }

    /// v2/v3 files write `<accidental>` = the WRITTEN key on transposing parts; the decoder must convert
    /// back to concert. Craft a minimal v3 KeySig fragment through the full decoder if practical; otherwise
    /// encode with `targetVersion: .v3` and decode, asserting concertKey survives (0 stays 0 written 2 → concert 0).
    @Test func v3AccidentalFallbackConvertsWrittenToConcert() throws {
        var score = clarinetScore()                        // concert C major on a B♭ instrument
        let data = try MSCXEncoder(options: .init(targetVersion: .v3)).encode(score)
        let xml = String(decoding: data, as: UTF8.self)
        #expect(xml.contains("<accidental>2</accidental>"))  // written D major
        let decoded = try MSCXDecoder().decode(data)
        let keyElement = decoded.parts[0].staves[0].measures[0].voices[0].elements[0]
        guard case let .keySignature(k) = keyElement else { Issue.record("no key sig"); return }
        #expect(k.concertKey == 0)                            // converted back to concert
    }
}
```

Adjust encoder/decoder entry-point spellings to the real API (look at any existing suite in `Tests/SheetMusicTests/MSCXTests/` and copy its encode/decode helpers — options may ride on the call, not the initializer).

- [ ] **Step 2: Run to verify failure** — `xcrun swift test --filter TransposingInstrumentRoundTripTests`.

- [ ] **Step 3: Implement.**
  1. Decoder (`MSCXDecoder+Instrument.swift`): read `transposeDiatonic`/`transposeChromatic` as `Int` children, default 0.
  2. Encoder (`MSCXEncoder+Instrument.swift`): emit both tags when either is non-zero, placed before the `<Channel>` blocks (mirror MuseScore's element order: after pitch ranges).
  3. `MSCXEncoderOptions`: add `public var writtenFifthsOffset: Int = 0`. In the Score encoder's per-part measure loop, make a copy of options with `writtenFifthsOffset = part.instrument.writtenFifthsOffset` and pass it down for that part's staff measures.
  4. `MSCXEncoder+Note.swift`: when `options.writtenFifthsOffset != 0`, write `<tpc2>` = `tpc + options.writtenFifthsOffset` immediately after `<tpc>`.
  5. `MSCXEncoder+KeySignature.swift`: for `.v2/.v3` the `<accidental>` value becomes `Score.respelledKey(concertKey + options.writtenFifthsOffset)` (unchanged when offset is 0). For `.v4`, additionally write `<accidental>` with that written value when the offset is non-zero (MuseScore 4 writes both; adding it only for transposing parts keeps existing fixtures byte-stable). `respelledKey` is `internal` on `Score` — reuse it (move it to an `enum KeyMath` in SheetMusicCore if MSCX can't see it; keep one definition).
  6. Decoder post-pass (Score assembly, where parts and staves are already paired and the file version is known): for files with version < 4, for every part with `writtenFifthsOffset != 0`, rewrite each `.keySignature` element on that part's staves: `concertKey = respelledKey(concertKey - offset)`. v4 files decode `<concertKey>` and need nothing. Decoder ignores `<tpc2>` (recomputed when needed).

- [ ] **Step 4: Run the full ssm suite** — `xcrun swift test`. Existing round-trip fixtures with transposing instruments may now legitimately differ (transpose tags are no longer dropped): inspect each failure; update fixture expectations only where the new output is the correct one, and say so in the commit message.
- [ ] **Step 5: Commit** (ssm): `git commit -m "feat: round-trip instrument transposition through mscx (tpc2, written key sigs, v3 fallback fix)"`.

---

### Task 3: ssm — `Score.writtenPitchView()` per-part written display transform

**Repo:** ssm

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Score+DisplayTransforms.swift`
- Test: `Tests/SheetMusicTests/EditingTests/WrittenPitchViewTests.swift` (create)

**Interfaces:**
- Consumes: Task 1 offsets; existing private helpers `transposedChord` / `transposedHarmony` / `transposedNote` and `respelledKey` in the same file.
- Produces: `Score.writtenPitchView() -> Score` — display-only, per-part, exact fifths (no histogram); skips `useDrumset` parts and `"percussion"` staves; tick structure and IDs unchanged.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import SheetMusicCore

@Suite struct WrittenPitchViewTests {
    private func ensemble() -> Score {
        // Part 0: flute (concert), part 1: B♭ clarinet — both one G staff, C major, one whole note concert B♭4.
        var score = Score.blank(BlankScoreTemplate(
            title: "T", instrumentID: "flute", staves: [.init(clefType: "G")], measureCount: 1,
        ))
        var clarinetStaff = score.parts[0].staves[0]
        score.parts.append(Part(
            id: "2",
            instrument: Instrument(id: "clarinet", transposeDiatonic: -1, transposeChromatic: -2),
            staves: [clarinetStaff],
        ))
        for partIndex in score.parts.indices {
            score.parts[partIndex].staves[0].measures[0].voices[0].elements[2] =
                .chord(Chord(duration: .whole, notes: [Note(pitch: 70, tpc: 12)]))
        }
        return score
    }

    @Test func transposingPartMovesConcertPartStays() {
        let written = ensemble().writtenPitchView()
        // Flute untouched.
        guard case let .chord(flute) = written.parts[0].staves[0].measures[0].voices[0].elements[2]
        else { Issue.record("flute"); return }
        #expect(flute.notes.first?.pitch == 70)
        #expect(flute.notes.first?.tpc == 12)
        // Clarinet: concert B♭4 displays as written C5; key sig C major stays 0 + 2 = D major.
        guard case let .chord(cl) = written.parts[1].staves[0].measures[0].voices[0].elements[2]
        else { Issue.record("clarinet"); return }
        #expect(cl.notes.first?.pitch == 72)
        #expect(cl.notes.first?.tpc == 14)
        guard case let .keySignature(k) = written.parts[1].staves[0].measures[0].voices[0].elements[0]
        else { Issue.record("key"); return }
        #expect(k.concertKey == 2)
    }

    @Test func nonTransposingScoreReturnsSelf() {
        let score = Score.blank(BlankScoreTemplate(
            title: "T", instrumentID: "piano", staves: [.init(clefType: "G")], measureCount: 1,
        ))
        #expect(score.writtenPitchView() == score)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `xcrun swift test --filter WrittenPitchViewTests`.

- [ ] **Step 3: Implement.** In `Score+DisplayTransforms.swift`, first extract the per-measure element rewrite loop of `transposed(bySemitones:)` (the `switch` over `.keySignature` / `.chord` / `.harmony`) into a shared private static helper `rewriteMeasure(_:semitones:fifthsDelta:newKey:)` so both transforms use one body. Then:

```swift
/// Returns a copy of the score with every transposing part's notation shifted to WRITTEN pitch: notes,
/// key signatures, and chord symbols move by the part's own interval, exactly (the (diatonic, chromatic)
/// pair fixes the fifths shift — no histogram). Concert-pitch parts, `useDrumset` parts, and `"percussion"`
/// staves pass through untouched. Display-only: tick structure, IDs, and element ordering are unchanged, and
/// playback must keep reading the un-transformed score.
public func writtenPitchView() -> Score {
    guard parts.contains(where: { $0.instrument.isTransposing && !$0.instrument.useDrumset }) else {
        return self
    }
    var copy = self
    for partIndex in copy.parts.indices {
        let instrument = copy.parts[partIndex].instrument
        guard instrument.isTransposing, !instrument.useDrumset else { continue }
        let semitones = instrument.writtenPitchOffset
        let fifths = instrument.writtenFifthsOffset
        for staffIndex in copy.parts[partIndex].staves.indices
            where copy.parts[partIndex].staves[staffIndex].group != "percussion"
        {
            let address = StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex)
            for measureIndex in copy.parts[partIndex].staves[staffIndex].measures.indices {
                let oldKey = activeKey(staff: address, measureIndex: measureIndex)
                let newKey = Self.respelledKey(oldKey + fifths)
                // rewriteMeasure(...) with semitones, fifthsDelta: newKey - oldKey, key: newKey — same
                // in-place pattern transposed(bySemitones:) uses.
            }
        }
    }
    return copy
}
```

Note `activeKey` must be read from `self` (the un-rewritten score), matching `transposed(bySemitones:)`'s pattern of resolving keys before rewriting — check how it does it and mirror exactly (it reads from `copy` progressively; keys ARE being rewritten measure-by-measure, so resolve `oldKey` against `self`, not `copy`, to avoid double-shifting keys of later measures. Add a regression test with a mid-score key change if the shared helper makes this subtle).

- [ ] **Step 4: Run to verify pass**, then full `xcrun swift test`.
- [ ] **Step 5: Commit** (ssm): `git commit -m "feat: per-part written-pitch display transform"`.

---

### Task 4: folino — wire written-pitch view into the display pipeline

**Repo:** folino

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift:444-448` (the `visibleScore` derivation)
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift:703` area (mirrored pipeline)
- Modify: `Packages/Features/Reader/Sources/Reader/PiP/ReaderPiPSession.swift:167` area (mirrored pipeline)
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ScoreContentView.swift:54` area (editing pipeline — transpose forced to 0, written view must stay live)
- Test: extend `Packages/Features/Reader/Tests/ReaderTests/` — find the suite covering `visibleScore`/display derivation (search for `filtered(hidingStaves` in tests) and add a case; if none exists, add `WrittenPitchPipelineTests.swift` at the view-model level with a fake score.

**Interfaces:**
- Consumes: `Score.writtenPitchView()` (Task 3).
- Produces: pipeline order `applying(clefOverrides:) → writtenPitchView() → transposed(bySemitones:) → filtered(hidingStaves:)` at all four sites.

- [ ] **Step 1: Write the failing test** — build a two-part score in-test (same shape as ssm's `WrittenPitchViewTests.ensemble()`, constructed via `Score.blank` + appended clarinet part), drive the view model's display derivation, and `#expect` the clarinet staff's displayed first-note pitch is 72 while playback still reads 70 from the source score.
- [ ] **Step 2: Run to verify failure** — `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests` from `Packages/Features/Reader`.
- [ ] **Step 3: Implement** — insert `.writtenPitchView()` between clef overrides and global transpose at each of the four sites, e.g. in `ReaderViewModel`:

```swift
let withClefs = score.applying(clefOverrides: layoutModel.staffClefOverrides)
let written = withClefs.writtenPitchView()
let transposed = written.transposed(bySemitones: transposeModel.effectiveSemitones)
visibleScore = transposed.filtered(hidingStaves: layoutModel.hiddenStaves)
```

In `ScoreContentView` (editing path, transpose pinned to 0) the written view still applies. Grep for any other `transposed(bySemitones` call sites in Features to be sure all mirrors are covered: `rg -n "transposed\(bySemitones" Packages/Features`.

- [ ] **Step 4: Run to verify pass**, then build the app target.
- [ ] **Step 5: Commit** (folino): `git commit -m "feat: display transposing parts at written pitch"`.

---

### Task 5: ssm — multi-part `BlankScoreTemplate` v2 (+ shared GM percussion map)

**Repo:** ssm

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Score+Blank.swift` (replace single-part template with multi-part)
- Create: `Sources/SheetMusicCore/Score/GMPercussion.swift` (promote the GM drum line map)
- Modify: `Sources/SheetMusicMIDI/Import/MidiImporter+GMDrumTables.swift` (`gmDrumLines` now delegates to `GMPercussion.drumLineMap` — one definition)
- Test: `Tests/SheetMusicTests/EditingTests/BlankScoreTests.swift` (extend)

**Interfaces:**
- Produces (exact shapes later tasks depend on):

```swift
public struct BlankScoreTemplate: Sendable, Equatable {
    public struct StaffPlan: Sendable, Equatable {
        public var clefType: String            // "G", "F", "G8vb", "C3", "PERC", …
        public var isPercussion: Bool          // default false; true → group "percussion", clef "PERC"
        public init(clefType: String, isPercussion: Bool = false)
    }
    public struct PartPlan: Sendable, Equatable {
        public var instrumentID: String
        public var longName: String?
        public var shortName: String?
        public var staves: [StaffPlan]
        public var transposeDiatonic: Int      // default 0
        public var transposeChromatic: Int     // default 0
        public var gmProgram: Int              // default 0; written into InstrumentChannel.program
        public var isDrums: Bool               // default false; true → useDrumset + GMPercussion.drumLineMap
        public init(instrumentID: String, longName: String? = nil, shortName: String? = nil,
                    staves: [StaffPlan], transposeDiatonic: Int = 0, transposeChromatic: Int = 0,
                    gmProgram: Int = 0, isDrums: Bool = false)
    }
    public var title: String
    public var composer: String?
    public var parts: [PartPlan]
    /// Half-open part ranges to group under a `.normal` bracket (SATB, string quartet).
    public var bracketGroups: [Range<Int>]
    public var concertKey: Int
    public var timeNumerator: Int
    public var timeDenominator: Int
    public var tempoBPM: Double
    public var measureCount: Int
    public init(title: String, composer: String? = nil, parts: [PartPlan],
                bracketGroups: [Range<Int>] = [], concertKey: Int = 0,
                timeNumerator: Int = 4, timeDenominator: Int = 4,
                tempoBPM: Double = 120, measureCount: Int = 32)
}
public enum GMPercussion { public static let drumLineMap: [Int: Int] }  // moved from MidiImporter.gmDrumLines
```

This REPLACES the M1 single-part initializer (folino is the only consumer; Task 8 migrates it). Keep a deprecated convenience init only if the ssm test fixtures use the old shape widely — prefer updating the fixtures.

- [ ] **Step 1: Write the failing tests** (extend `BlankScoreTests`):

```swift
@Test func multiPartFactoryBuildsPartsBracketsAndPrograms() {
    let template = BlankScoreTemplate(
        title: "Quartet",
        parts: [
            .init(instrumentID: "violin", longName: "Violin", staves: [.init(clefType: "G")], gmProgram: 40),
            .init(instrumentID: "violin", longName: "Violin", staves: [.init(clefType: "G")], gmProgram: 40),
            .init(instrumentID: "viola", longName: "Viola", staves: [.init(clefType: "C3")], gmProgram: 41),
            .init(instrumentID: "violoncello", longName: "Cello", staves: [.init(clefType: "F")], gmProgram: 42),
        ],
        bracketGroups: [0 ..< 4],
        measureCount: 4,
    )
    let score = Score.blank(template)
    #expect(score.parts.count == 4)
    #expect(Set(score.parts.map(\.id)).count == 4)                      // unique part ids
    #expect(score.parts[0].instrument.channel.program == 40)
    #expect(score.parts[0].staves[0].brackets == [BracketItem(type: .normal, span: 4)])
    #expect(score.parts[1].staves[0].brackets.isEmpty)
    #expect(score.systemMeasures.count == 4)
    for part in score.parts { #expect(part.staves[0].measures.count == 4) }
}

@Test func grandStaffPartStillGetsBrace() {
    let score = Score.blank(BlankScoreTemplate(
        title: "P",
        parts: [.init(instrumentID: "piano", longName: "Piano",
                      staves: [.init(clefType: "G"), .init(clefType: "F")], gmProgram: 0)],
        measureCount: 2,
    ))
    #expect(score.parts[0].staves[0].brackets == [BracketItem(type: .brace, span: 2)])
}

@Test func drumPartIsPercussion() {
    let score = Score.blank(BlankScoreTemplate(
        title: "D",
        parts: [.init(instrumentID: "drumset", longName: "Drum Kit",
                      staves: [.init(clefType: "PERC", isPercussion: true)], isDrums: true)],
        measureCount: 2,
    ))
    #expect(score.parts[0].instrument.useDrumset)
    #expect(score.parts[0].instrument.drumLineMap == GMPercussion.drumLineMap)
    #expect(score.parts[0].staves[0].group == "percussion")
}

@Test func multiPartRoundTripsThroughMSCX() throws {
    // encode → decode → == (reuse this file's existing round-trip helper pattern)
}
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.** Rules:
  - Part ids: `"1"`, `"2"`, … in order (matches mscx convention and guarantees uniqueness for Task 10's mapping).
  - Per part: brace on staff 0 when `staves.count > 1` (as M1). Percussion staff: `group: "percussion"`, `staffType: "stdNormal"` unless a percussion staff type is already modeled — check what the MSCX decoder produces for MuseScore drum staves (`rg '"percussion"' Sources/SheetMusicMSCX`) and mirror it; `lineCount` 5.
  - `bracketGroups`: for each range, compute the anchor part's global first-staff index and `span` = total staves of parts in the range; append `BracketItem(type: .normal, span:)` to the anchor part's staff 0 `brackets` (brackets span the GLOBAL staff order — same convention `filtered(hidingStaves:)` documents).
  - `Instrument`: `id`, `longName`, `shortName`, `trackName: longName`, `channels: [InstrumentChannel(program: plan.gmProgram)]` — check `InstrumentChannel`'s memberwise init parameter order; drums also `useDrumset: true, drumLineMap: GMPercussion.drumLineMap` and the encoder's channel-10 routing comes from `useDrumset` (already handled).
  - Transposition: copy `transposeDiatonic/Chromatic` onto the Instrument.
  - measure 0 signatures + measure rests + `systemMeasures` + tempo + metaTags/titleFrame: unchanged from M1 (concert key only — written keys are display-derived).
  - Update `NewScoreForm`-independent ssm fixtures that used the old template shape.
- [ ] **Step 4: Run** `xcrun swift test` (full suite).
- [ ] **Step 5: Commit** (ssm): `git commit -m "feat: multi-part blank-score factory with bracket groups and drum parts"`.

---

### Task 6: folino Domain — instrument catalog + creation templates

**Repo:** folino

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/ScoreInstrument.swift`
- Create: `Packages/Domain/Sources/Domain/Models/ScoreCreationTemplate.swift`
- Test: `Packages/Domain/Tests/DomainTests/ScoreInstrumentCatalogTests.swift` (create)

**Interfaces:**
- Consumes: `BlankScoreTemplate.PartPlan` / `.StaffPlan` (Task 5, via Domain's `@_exported import SheetMusicCore`).
- Produces:

```swift
/// One catalog instrument: notation metadata + GM sound. Static data in Domain (GMDrumKit precedent) so
/// Android reads the same catalog over JNI. Display names resolve in UI layers via "instrument.<id>" keys.
public struct ScoreInstrument: Sendable, Equatable, Identifiable {
    public enum Family: String, CaseIterable, Sendable {
        case voices, keyboards, strings, woodwinds, brass, guitarAndBass, percussion
    }
    public let id: String                 // stable, e.g. "clarinet-bb"
    public let family: Family
    public let englishName: String        // fallback + xcstrings source value
    public let staves: [BlankScoreTemplate.StaffPlan]
    public let transposeDiatonic: Int
    public let transposeChromatic: Int
    public let gmProgram: Int
    public let isDrums: Bool
    /// Amateur playable range hint (MIDI, concert pitch) — stored for future range warnings, no M2 UI.
    public let amateurRange: ClosedRange<Int>?
    public static let all: [ScoreInstrument]
    public static func instrument(id: String) -> ScoreInstrument?
    public func partPlan() -> BlankScoreTemplate.PartPlan   // longName = englishName; UI overrides with the localized name
}

public struct ScoreCreationTemplate: Sendable, Equatable, Identifiable {
    public let id: String                 // "solo-piano", "voice-piano", "satb", "string-quartet"
    public let instrumentIDs: [String]
    public let bracketGroups: [Range<Int>]
    public static let all: [ScoreCreationTemplate]
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import Domain

@Suite struct ScoreInstrumentCatalogTests {
    @Test func catalogIsWellFormed() {
        #expect(ScoreInstrument.all.count >= 20)
        #expect(Set(ScoreInstrument.all.map(\.id)).count == ScoreInstrument.all.count)
        for instrument in ScoreInstrument.all {
            #expect(!instrument.staves.isEmpty)
            #expect((0 ... 127).contains(instrument.gmProgram))
        }
    }

    @Test func transposingEntriesCarryTheRightIntervals() {
        #expect(ScoreInstrument.instrument(id: "clarinet-bb").map {
            ($0.transposeDiatonic, $0.transposeChromatic) == (-1, -2) } == true)
        #expect(ScoreInstrument.instrument(id: "horn-f").map {
            ($0.transposeDiatonic, $0.transposeChromatic) == (-4, -7) } == true)
        // Tenor voice and guitar carry the octave in the CLEF, not in a transposition.
        #expect(ScoreInstrument.instrument(id: "voice-tenor").map {
            $0.transposeChromatic == 0 && $0.staves.first?.clefType == "G8vb" } == true)
    }

    @Test func templatesResolveAgainstTheCatalog() {
        for template in ScoreCreationTemplate.all {
            for id in template.instrumentIDs {
                #expect(ScoreInstrument.instrument(id: id) != nil)
            }
        }
        #expect(ScoreCreationTemplate.all.map(\.id)
            == ["solo-piano", "voice-piano", "satb", "string-quartet"])
    }
}
```

- [ ] **Step 2: Run to verify failure** — `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` from `Packages/Domain` (check the actual scheme name with `xcodebuild -list`; it may be `Domain-Package`).
- [ ] **Step 3: Implement the catalog data.** ~24 entries (id / family / english name / staves / transpose d,c / GM program / amateur range). The full table — clefs and intervals follow MuseScore's instruments.xml facts; programs are GM standard:

| id | family | name | staves | (d, c) | GM | range |
|---|---|---|---|---|---|---|
| voice-soprano | voices | Soprano | G | 0,0 | 52 | 60–81 |
| voice-alto | voices | Alto | G | 0,0 | 52 | 53–74 |
| voice-tenor | voices | Tenor | G8vb | 0,0 | 52 | 48–69 |
| voice-bass | voices | Bass | F | 0,0 | 52 | 41–62 |
| voice | voices | Voice | G | 0,0 | 52 | 48–79 |
| piano | keyboards | Piano | G+F (grand) | 0,0 | 0 | 21–108 |
| electric-piano | keyboards | Electric Piano | G+F (grand) | 0,0 | 4 | 21–108 |
| organ | keyboards | Organ | G+F (grand) | 0,0 | 19 | 36–96 |
| violin | strings | Violin | G | 0,0 | 40 | 55–91 |
| viola | strings | Viola | C3 | 0,0 | 41 | 48–84 |
| violoncello | strings | Cello | F | 0,0 | 42 | 36–76 |
| contrabass | strings | Contrabass | F | −7,−12 | 43 | 28–62 |
| flute | woodwinds | Flute | G | 0,0 | 73 | 60–96 |
| oboe | woodwinds | Oboe | G | 0,0 | 68 | 58–87 |
| clarinet-bb | woodwinds | Clarinet in B♭ | G | −1,−2 | 71 | 50–89 |
| alto-sax-eb | woodwinds | Alto Saxophone | G | −5,−9 | 65 | 49–80 |
| tenor-sax-bb | woodwinds | Tenor Saxophone | G | −8,−14 | 66 | 44–75 |
| bassoon | woodwinds | Bassoon | F | 0,0 | 70 | 34–72 |
| trumpet-bb | brass | Trumpet in B♭ | G | −1,−2 | 56 | 52–82 |
| horn-f | brass | Horn in F | G | −4,−7 | 60 | 34–77 |
| trombone | brass | Trombone | F | 0,0 | 57 | 40–72 |
| tuba | brass | Tuba | F | 0,0 | 58 | 26–58 |
| guitar | guitarAndBass | Guitar | G8vb | 0,0 | 25 | 40–83 |
| bass-guitar | guitarAndBass | Bass Guitar | F | −7,−12 | 34 | 28–65 |
| drumset | percussion | Drum Kit | PERC (isPercussion) | 0,0 | 0, isDrums | — |

Grand staff = `[StaffPlan(clefType: "G"), StaffPlan(clefType: "F")]`. Templates: solo-piano `["piano"]`; voice-piano `["voice", "piano"]`; satb `["voice-soprano", "voice-alto", "voice-tenor", "voice-bass"]`, brackets `[0..<4]`; string-quartet `["violin", "violin", "viola", "violoncello"]`, brackets `[0..<4]`.

- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit** (folino): `git commit -m "feat: score-instrument catalog and creation templates in Domain"`.

---

### Task 7: folino ScoreUI — instrument picker + instrumentation list editor

**Repo:** folino

**Files:**
- Create: `Packages/ScoreUI/Sources/ScoreUI/InstrumentCatalogPicker.swift`
- Create: `Packages/ScoreUI/Sources/ScoreUI/InstrumentName.swift` (localized-name resolver)
- Modify: `Packages/ScoreUI/Sources/ScoreUI/Resources/Localizable.xcstrings` (or the module's existing xcstrings file — find it with `ls Packages/ScoreUI/Sources/ScoreUI/Resources`)
- Test: `Packages/ScoreUI/Tests/ScoreUITests/InstrumentNameTests.swift` (create)

**Interfaces:**
- Consumes: `ScoreInstrument` (Task 6).
- Produces:
  - `public func localizedInstrumentName(_ instrument: ScoreInstrument) -> String` — resolves `"instrument.<id>"` from the ScoreUI bundle, falling back to `englishName`.
  - `public struct InstrumentCatalogPicker: View` — `init(onPick: @escaping (ScoreInstrument) -> Void)`; a `List` of catalog instruments grouped in `Section`s per `Family` (family header via `"instrumentFamily.<rawValue>"` keys), each row `Button` calls `onPick`. Presented inside whatever sheet/navigation the caller owns.

- [ ] **Step 1: Write the failing test** — `localizedInstrumentName` returns a non-empty string for every catalog entry, and for an unknown-key instrument returns its `englishName`:

```swift
import Testing
@testable import ScoreUI
import Domain

@Suite struct InstrumentNameTests {
    @Test func everyCatalogEntryResolvesToAName() {
        for instrument in ScoreInstrument.all {
            #expect(!localizedInstrumentName(instrument).isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure** (scheme from `xcodebuild -list` in `Packages/ScoreUI`).
- [ ] **Step 3: Implement.** Resolver: `String(localized: String.LocalizationValue("instrument.\(instrument.id)"), bundle: .module)` — if the result equals the key (miss), return `englishName`. Picker: straightforward grouped list; transposing instruments show the localized name (the "in B♭" is part of the name string). Add xcstrings entries for all 24 ids + 7 family keys, in **every locale the file already declares** (inspect the xcstrings `"sourceLanguage"` and existing locale set; ja translations e.g. `instrument.clarinet-bb` = 「クラリネット（B♭）」, `instrumentFamily.voices` = 「声楽」, `instrumentFamily.guitarAndBass` = 「ギター・ベース」 — write natural Japanese, and for ko/zh use standard instrument names).
- [ ] **Step 4: Run to verify pass.** Render a `#Preview` of the picker via `mcp__xcode__RenderPreview` and check the grouping reads correctly.
- [ ] **Step 5: Commit** (folino): `git commit -m "feat: shared instrument catalog picker in ScoreUI"`.

---

### Task 8: folino Library — wizard v2 (templates, free instrument list, clone instrumentation)

**Repo:** folino

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/NewScore/NewScoreForm.swift` (replace `Preset` with an instrumentation list)
- Modify: `Packages/Features/Library/Sources/Library/NewScore/NewScoreSheet.swift` (instrumentation section UI)
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift` (`createScore(from:)` unchanged signature; add `instrumentation(of item: ScoreItem)` loader for clone)
- Modify: `Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings` (new keys)
- Test: `Packages/Features/Library/Tests/LibraryTests/NewScoreTests.swift` (extend)

**Interfaces:**
- Consumes: `ScoreInstrument`, `ScoreCreationTemplate` (Task 6), `InstrumentCatalogPicker` + `localizedInstrumentName` (Task 7), `BlankScoreTemplate` v2 (Task 5), `ScoreFileGateway.loadScore` (existing, for clone).
- Produces:

```swift
struct NewScoreForm: Equatable {
    /// One row of the wizard's instrumentation list — either a catalog pick or a part cloned from an
    /// existing score (which may name an instrument outside the catalog).
    struct PartDraft: Equatable, Identifiable {
        let id: UUID                       // list identity for ForEach/onMove
        var displayName: String
        var plan: BlankScoreTemplate.PartPlan
        static func fromCatalog(_ instrument: ScoreInstrument) -> PartDraft  // localizedInstrumentName + partPlan()
        static func fromExistingPart(_ part: Part) -> PartDraft              // copies clefs (authoredClef per staff),
                                                                             // transpose, program, isDrums, names
    }
    var title = ""
    var composer = ""
    var instrumentation: [PartDraft]       // seeded with solo-piano's expansion
    var bracketGroups: [Range<Int>] = []   // set when a template is applied; cleared on manual edit
    var concertKey = 0
    var timeNumerator = 4; var timeDenominator = 4
    var tempoBPM = 120; var measureCount = 32
    mutating func applyTemplate(_ template: ScoreCreationTemplate)
    mutating func applyInstrumentation(of score: Score)             // clone path
    func template() -> BlankScoreTemplate?                          // nil while title empty OR instrumentation empty
}
```

- [ ] **Step 1: Write the failing tests** (extend `NewScoreTests`):

```swift
@Test func templateExpansionBuildsMultiPartBlankTemplate() {
    var form = NewScoreForm()
    form.title = "Q"
    form.applyTemplate(ScoreCreationTemplate.all.first { $0.id == "string-quartet" }!)
    let template = form.template()
    #expect(template?.parts.count == 4)
    #expect(template?.bracketGroups == [0 ..< 4])
    #expect(template?.parts[2].staves.first?.clefType == "C3")
}

@Test func cloneInstrumentationCopiesTransposingPart() {
    var source = Score.blank(BlankScoreTemplate(
        title: "S",
        parts: [.init(instrumentID: "clarinet-bb", longName: "Clarinet in B♭",
                      staves: [.init(clefType: "G")], transposeDiatonic: -1,
                      transposeChromatic: -2, gmProgram: 71)],
        measureCount: 1,
    ))
    var form = NewScoreForm()
    form.title = "T"
    form.applyInstrumentation(of: source)
    let template = form.template()
    #expect(template?.parts.count == 1)
    #expect(template?.parts[0].transposeChromatic == -2)
    #expect(template?.parts[0].gmProgram == 71)
}

@Test func emptyInstrumentationDisablesCreate() {
    var form = NewScoreForm()
    form.title = "T"
    form.instrumentation = []
    #expect(form.template() == nil)
}
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement the form model.** `fromExistingPart` reads: staves → `StaffPlan(clefType: score.authoredClef(at:) ?? staff.defaultClefType ?? "G", isPercussion: staff.group == "percussion")`; instrument fields directly; `displayName` = `instrument.longName ?? part.trackName ?? instrument.id`. Manual list edits (add/remove/move) clear `bracketGroups` (a hand-edited ensemble no longer matches the template's grouping — simplest correct behavior; grand-staff braces are per-part and unaffected). `template()` maps drafts to `parts:` in list order.
- [ ] **Step 4: Implement the sheet UI.** Replace `layoutSection`'s preset `Picker` with an **instrumentation section**:
  - A `Menu`（or `Picker`-style row）"テンプレート" offering the 4 templates (keys `library.newScore.template.<id>`) plus 「既存の楽譜と同じ編成」 (opens a score picker over `viewModel.repository.scoreItems`, excluding deleted; on pick, `viewModel` loads the `Score` via the gateway off the main actor and calls `form.applyInstrumentation(of:)`; on load failure surface via the sheet's existing alert channel) plus 「楽器を選ぶ」 (opens `InstrumentCatalogPicker`, replacing the list with the single pick — matches "start from an instrument").
  - The current instrumentation as an editable `List` inside the Form section: `ForEach($form.instrumentation)` rows showing `displayName` (+ staff count where > 1), `.onMove` for drag reorder, `.onDelete` for swipe delete, and a trailing 「＋ 楽器を追加」 row presenting `InstrumentCatalogPicker` in a sheet; a pick appends.
  - Keep title/key/time/tempo/measures sections unchanged. New xcstrings keys (en + ja + the file's other locales): `library.newScore.section.instrumentation`, `library.newScore.template`, `library.newScore.template.solo-piano|voice-piano|satb|string-quartet`, `library.newScore.sameAsExisting`, `library.newScore.chooseInstruments`, `library.newScore.addInstrument`.
- [ ] **Step 5: Run tests to verify pass**; render `NewScoreSheet`'s `#Preview` via `mcp__xcode__RenderPreview` and check the instrumentation list reads correctly (template applied, rows listed).
- [ ] **Step 6: Commit** (folino): `git commit -m "feat: multi-part creation wizard with templates and clone-instrumentation"`.

---

### Task 9: ssm — `AddPart` command + intent + wire

**Repo:** ssm

**Files:**
- Create: `Sources/SheetMusicCore/Editing/AddPart.swift`
- Modify: `Sources/SheetMusicCore/Editing/EditIntent.swift` (append `.addPart`)
- Modify: `Sources/SheetMusicCore/Editing/ScoreEditSession.swift` (plan the intent)
- Modify: `Sources/SheetMusicEditWire/Intent/EditIntentCodec.swift` (wire case — append, never renumber; follow the file's own conventions for a new payload struct carrying `PartPlan`)
- Test: `Tests/SheetMusicTests/EditingTests/PartCommandTests.swift` (create)

**Interfaces:**
- Consumes: `BlankScoreTemplate.PartPlan` (Task 5), `MeasureStructure` helpers, `StaffAddress`.
- Produces: `EditIntent.addPart(plan: BlankScoreTemplate.PartPlan, at: Int)`; `AddPart: EditCommand` whose inverse is `RemovePart` (Task 10 — in THIS task, return a placeholder inverse is NOT allowed; implement `AddPart` and `RemovePart`'s apply/inverse pair together if splitting them breaks undo. Recommended: implement both command types in this task, but expose only `.addPart` as an intent; Task 10 adds the `.removePart`/`.movePart` intents, `MovePart`, and the session mapping).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import SheetMusicCore

@Suite struct PartCommandTests {
    /// Two-part score (flute, piano-grand) with 3 measures, a mid-score key change on measure 1, and a note
    /// on the flute so content survival is observable.
    private func fixture() -> Score { /* build via Score.blank(v2) + insert a .keySignature(concertKey: 2)
        at measure 1 voice 0 element 0 of every staff, + one chord on flute measure 0 */ }

    @Test func addPartInsertsRestColumnEverywhereAndRestampsIDs() {
        var session = ScoreEditSession(score: fixture())
        let plan = BlankScoreTemplate.PartPlan(
            instrumentID: "clarinet-bb", longName: "Clarinet in B♭",
            staves: [.init(clefType: "G")], transposeDiatonic: -1, transposeChromatic: -2, gmProgram: 71,
        )
        #expect(session.apply(.addPart(plan: plan, at: 1)))
        let score = session.score
        #expect(score.parts.count == 3)
        #expect(score.parts[1].instrument.id == "clarinet-bb")
        #expect(score.parts[1].staves[0].measures.count == 3)
        // Signature skeleton copied: measure 0 carries key+time, measure 1 carries the key change.
        // (Assert by scanning elements for .keySignature/.timeSignature.)
        // The old part 1 (piano) is now part 2 and its measures are untouched.
        #expect(score.parts[2].staves.count == 2)
        // systemMeasures untouched in count; tempo element's originalStaff survives with a valid address.
        #expect(score.systemMeasures.count == 3)
    }

    @Test func addPartUndoRestoresExactScore() {
        let original = fixture()
        var session = ScoreEditSession(score: original)
        let plan = BlankScoreTemplate.PartPlan(instrumentID: "x", staves: [.init(clefType: "G")])
        #expect(session.apply(.addPart(plan: plan, at: 0)))
        #expect(session.undo())
        #expect(session.score == original)
    }

    @Test func addPartGeneratesUniquePartID() {
        var session = ScoreEditSession(score: fixture())
        #expect(session.apply(.addPart(plan: .init(instrumentID: "x", staves: [.init(clefType: "G")]), at: 2)))
        #expect(Set(session.score.parts.map(\.id)).count == session.score.parts.count)
    }
}
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement `AddPart`** (and the `RemovePart` command type as its inverse — intents for remove come in Task 10):
  - Build the new `Part` from the plan exactly as `Score.blank` does (share a helper: extract `Part(from plan:partID:measureCount:)` into `Score+Blank.swift` and call it from both sites). Its `id` = first free numeric string (`(parts.compactMap { Int($0.id) }.max() ?? 0) + 1` as string — unique even against "1","2" from files).
  - Measures: rest-filled, but copy the **signature skeleton** from reference staff `parts[0].staves[0]`: for each measure, take `MeasureStructure.leadingSignaturePrefix` filtered to `.keySignature`/`.timeSignature` (NOT clefs) and prepend it to the `.rest(duration: .measure)` bar. This keeps mid-score signature changes consistent across staves.
  - Re-stamp: every `PositionedSystemElement.originalStaff` and any model field embedding `StaffAddress` with `partIndex >= at` gets `partIndex + 1`. Find every embedding: `rg -n "StaffAddress" Sources/SheetMusicCore --files-with-matches` — audit each hit (spanners store measure offsets, not addresses; `VoiceElementID`s are not stored in the model, only in commands — verify and document in the command's comment what was audited).
  - Brackets: a bracket on a staff BEFORE the insertion point whose global span crosses the insertion boundary must grow by the inserted staff count (MuseScore extends a bracket when a part is added inside its range). Compute global staff indices before/after, mirroring `filtered(hidingStaves:)`'s flattened-order logic in reverse.
  - Inverse: `RemovePart(partIndex: at)` — which captures, on ITS apply: the removed `Part` (whole value), the insertion index, and every staff's pre-image `brackets` array (cheap, exact restore).
  - Session planning: `case let .addPart(plan, index): return AddPart(plan: plan, at: index)`; refuse (`targetNotFound`) when `index < 0 || index > parts.count`.
  - Wire: append the codec case with a `PartPlanWire` payload struct (strings + ints + staff list) following the codec file's documented tag/length conventions; extend its round-trip test suite the same way the file's existing cases are tested.
- [ ] **Step 4: Run** `xcrun swift test` (full suite).
- [ ] **Step 5: Commit** (ssm): `git commit -m "feat: AddPart edit command with signature skeleton and bracket growth"`.

---

### Task 10: ssm — `RemovePart` / `MovePart` intents + session part-index mapping

**Repo:** ssm

**Files:**
- Create: `Sources/SheetMusicCore/Editing/RemovePart.swift` (if Task 9 placed it elsewhere, move it here), `Sources/SheetMusicCore/Editing/MovePart.swift`
- Modify: `Sources/SheetMusicCore/Editing/EditIntent.swift` (append `.removePart(at: Int)`, `.movePart(from: Int, to: Int)`), `ScoreEditSession.swift` (plan them + mapping API), `EditIntentCodec.swift` (two wire cases)
- Test: `Tests/SheetMusicTests/EditingTests/PartCommandTests.swift` (extend)

**Interfaces:**
- Produces:
  - `EditIntent.removePart(at: Int)` — refused when it would remove the last part (`EditRefusal` with a dedicated reason; check `EditRefusal.Reason`'s existing cases and add `cannotRemoveLastPart` following the enum's conventions).
  - `EditIntent.movePart(from: Int, to: Int)`.
  - `ScoreEditSession.partIndexMapping: [Int: Int?]` — for every part index at the last consume point (or `init`), where that part is NOW (`nil` = removed). Derived by diffing `Part.id` snapshots, so undo/redo are handled for free.
  - `ScoreEditSession.consumePartIndexMapping()` — re-baselines to the current parts.
  - `ScoreEditSession.isPartMappingIdentity: Bool` convenience.

- [ ] **Step 1: Write the failing tests** (extend `PartCommandTests`):

```swift
@Test func removePartDropsColumnAndUndoRestoresIt() {
    let original = fixture()                       // 2 parts
    var session = ScoreEditSession(score: original)
    #expect(session.apply(.removePart(at: 0)))
    #expect(session.score.parts.count == 1)
    #expect(session.undo())
    #expect(session.score == original)
}

@Test func removingLastPartIsRefused() {
    var session = ScoreEditSession(score: /* single-part blank */)
    #expect(!session.apply(.removePart(at: 0)))
    #expect(session.lastRefusal != nil)
}

@Test func movePartReordersAndUndoRestores() {
    let original = fixture()
    var session = ScoreEditSession(score: original)
    #expect(session.apply(.movePart(from: 0, to: 1)))
    #expect(session.score.parts[1].instrument.id == original.parts[0].instrument.id)
    #expect(session.undo())
    #expect(session.score == original)
}

@Test func cumulativeMappingComposesAcrossOpsAndUndo() {
    var session = ScoreEditSession(score: fixture())          // parts A(0), B(1)
    session.apply(.addPart(plan: .init(instrumentID: "x", staves: [.init(clefType: "G")]), at: 0))
    session.apply(.removePart(at: 2))                          // removes B
    // A: 0 → 1, B: 1 → nil
    #expect(session.partIndexMapping == [0: 1, 1: nil])
    session.undo()                                             // B back
    #expect(session.partIndexMapping == [0: 1, 1: 2])
    session.consumePartIndexMapping()
    #expect(session.isPartMappingIdentity)
}

@Test func removedPartBracketsRestoreOnOtherStaves() {
    // 4-part SATB with a cross-part bracket anchored on part 0 spanning 4; remove part 1; the bracket's
    // span shrinks to 3; undo restores span 4 byte-for-byte.
}
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.**
  - `RemovePart.apply`: capture removed `Part` + all staves' bracket pre-image; drop the part; re-anchor brackets over the surviving global staff order (transplant `filtered(hidingStaves:)`'s re-anchor loop — lift that loop into a shared internal helper `Score.reanchoredBrackets(keeping:)` used by both, rather than copying it); re-stamp `originalStaff` partIndex `> at` down by 1, and drop system elements whose `originalStaff` pointed INTO the removed part (re-anchor them to `StaffAddress(partIndex: 0, staffIndexInPart: 0)` instead of dropping — a tempo must survive its anchor part's removal; write a test for exactly that). Inverse: an `AddPart` restore-form carrying the captured part + captured brackets (mirror `InsertMeasure`'s restore-path pattern: a second internal init).
  - `MovePart.apply`: remove + insert of the `Part` value, re-stamp `originalStaff` part indices through the permutation, recompute brackets from the captured pre-image over the new order (safest exact-undo route: capture all brackets, recompute forward, restore capture on inverse). Inverse: `MovePart(from: to, to: from)`.
  - Mapping: store `private var partIDBaseline: [String]` in `ScoreEditSession`, set in `init` and `consumePartIndexMapping()`. `partIndexMapping` = `Dictionary(uniqueKeysWithValues: baseline.enumerated().map { ($0, current.firstIndex(of: $1)) })` where `current = score.parts.map(\.id)`. If `baseline` contains duplicate ids (malformed input file), return the identity mapping and never migrate — corrupting preferences is worse than skipping migration; note this in the doc comment.
  - Wire cases for both intents (scalar payloads — two ints / one int).
- [ ] **Step 4: Run** `xcrun swift test`.
- [ ] **Step 5: Commit** (ssm): `git commit -m "feat: RemovePart/MovePart commands and session part-index mapping"`.

---

### Task 11: folino Editor — instruments sheet, chrome entry, App wiring

**Repo:** folino

**Files:**
- Create: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Parts.swift`
- Create: `Packages/Features/Editor/Sources/Editor/Views/EditorInstrumentsSheet.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/Screens/EditorTopBarView.swift` (entry button)
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift` (sheet flag + visibility seams)
- Modify: `Packages/Features/Editor/Package.swift` (add ScoreUI dependency — mirror how `Packages/Features/Library/Package.swift:66,76` declares it)
- Modify: `App/Sources/...` — the composition root that wires `EditorViewModel` seams (find it: `rg -n "displayToSourceItem" App/Sources`)
- Modify: `Packages/Features/Editor/Sources/Editor/Resources/Localizable.xcstrings`
- Test: `Packages/Features/Editor/Tests/EditorTests/EditorPartsTests.swift` (create)

**Interfaces:**
- Consumes: `.addPart`/`.removePart`/`.movePart` intents (Tasks 9–10), `InstrumentCatalogPicker` + `localizedInstrumentName` (Task 7), `ScoreInstrument.partPlan()` (Task 6).
- Produces on `EditorViewModel`:

```swift
/// Rows for the instruments sheet, derived from the session score.
public struct PartRow: Identifiable, Equatable {
    public let id: String            // Part.id — stable across reorders
    public let index: Int
    public let name: String
    public let staffAddresses: [StaffAddress]
}
public var partRows: [PartRow] { get }
public var canRemovePart: Bool       // parts.count > 1
public var isInstrumentsSheetPresented: Bool  // drives the sheet, on the VM (same reasoning as isConfirmingRevert)
public func addPart(_ plan: BlankScoreTemplate.PartPlan)          // appends at parts.count
public func removePart(at index: Int)
public func movePart(fromOffsets: IndexSet, toOffset: Int)        // List.onMove adapter → .movePart intent
/// Seams the App wires to the Reader's per-score visibility store (Editor must not import Reader).
public var isStaffVisible: @MainActor (StaffAddress) -> Bool
public var onToggleStaffVisibility: @MainActor (StaffAddress) -> Void
```

- [ ] **Step 1: Write the failing tests** — view-model level (Editor tests already build sessions against in-memory scores; mirror an existing suite's setup):

```swift
@Test func addPartAppendsAndRowsRefresh() { /* begin session on 2-part score; addPart; partRows.count == 3 */ }
@Test func removePartRefusedOnLastPart() { /* single-part; canRemovePart == false; removePart(at: 0) no-ops */ }
@Test func movePartAdapterMapsListOffsets() { /* move row 0 below row 1; partRows order flips */ }
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement view model** — each op is `apply(<intent>)` through the same `apply` choke point note edits use (undo/redo and `onScoreChanged` come for free). `movePart(fromOffsets:toOffset:)` converts SwiftUI's `onMove` semantics to a single `(from, to)` — single-item moves only (the list is small; `guard let from = fromOffsets.first`), with `to` adjusted by the SwiftUI off-by-one (`to > from ? to - 1 : to`).
- [ ] **Step 4: Implement the sheet.** `EditorInstrumentsSheet: View` presented from the top bar:
  - `List` + `ForEach(viewModel.partRows)`: row shows name; below it one toggle per staff (label 「第N譜表を表示」 / single-staff parts put the toggle inline on the row) bound to `isStaffVisible`/`onToggleStaffVisibility`; `.onMove` → `movePart`; swipe delete → confirmation dialog (「〈name〉を削除しますか？この楽器の音符も削除されます。取り消すには元に戻すを使えます。」 — Editor-module xcstrings, en + ja + existing locales) → `removePart`. Delete row disabled when `!canRemovePart`.
  - Toolbar `+` presents `InstrumentCatalogPicker` in a nested sheet; pick → `viewModel.addPart(instrument.partPlan())` with `longName` overridden to `localizedInstrumentName(instrument)`.
  - Top-bar entry: add a button (SF Symbol — try `music.note.list`; if it collides visually with existing glyphs pick another plain SF symbol, no custom symbol needed) to `EditorTopBarView` following how its existing buttons are declared and previewed; sets `viewModel.isInstrumentsSheetPresented = true`. **Attach the `.sheet` at the top bar's root view, never on a `Section`** (repo gotcha).
- [ ] **Step 5: App wiring** — where the root wires `displayToSourceItem`, also wire `isStaffVisible` / `onToggleStaffVisibility` to the Reader's layout-settings model (the same store the Reader inspector's staff toggles use — find it: `rg -n "toggleStaff" Packages/Features/Reader`). Follow the existing seam style exactly.
- [ ] **Step 6: Run Editor tests; build the app; render `EditorInstrumentsSheet`'s `#Preview`** (write one with a 3-part preview score) via `mcp__xcode__RenderPreview`.
- [ ] **Step 7: Commit** (folino): `git commit -m "feat: instruments sheet — add/remove/reorder parts and staff visibility from the editor"`.

---

### Task 12: folino — preference migration on save

**Repo:** folino

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/ReaderPreferences+PartRemap.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Persistence.swift` (`performSave` consumes the mapping)
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift` (new `onPartIndicesRemapped` seam)
- Modify: App composition root (wire the seam to the Reader) + the Reader's preference-holding model (add a reload/remap entry point — find the type that owns `hiddenStaves` in memory: `Packages/Features/Reader/Sources/Reader/LayoutSettingsModel.swift`)
- Test: `Packages/Domain/Tests/DomainTests/ReaderPreferencesPartRemapTests.swift` (create), plus an Editor persistence test if the existing suite fakes the repository (check `Packages/Features/Editor/Tests` for a repository fake).

**Interfaces:**
- Consumes: `ScoreEditSession.partIndexMapping` / `consumePartIndexMapping()` / `isPartMappingIdentity` (Task 10).
- Produces:

```swift
extension ReaderPreferences {
    /// Rewrites every part-indexed key for a part add/remove/reorder. `mapping` covers every pre-edit part
    /// index; `nil` = the part was removed (its rows are dropped). Staff indices within a part are unchanged
    /// by part operations, so `staffIndexInPart` is preserved.
    public func remappingParts(_ mapping: [Int: Int?]) -> ReaderPreferences
}
// EditorViewModel:
public var onPartIndicesRemapped: @MainActor ([Int: Int?]) -> Void = { _ in }
```

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import Domain
import SheetMusicCore

@Suite struct ReaderPreferencesPartRemapTests {
    private func prefs() -> ReaderPreferences {
        ReaderPreferences(
            scoreItemID: ScoreItemID(),
            hiddenStaves: [StaffAddress(partIndex: 0, staffIndexInPart: 0),
                           StaffAddress(partIndex: 1, staffIndexInPart: 1)],
            authoredHiddenStaves: [StaffAddress(partIndex: 1, staffIndexInPart: 0)],
            stripProgramOverrides: [MixerStripID(partIndex: 1, instrumentOrdinal: 0): 40],
            stripVolumeOverrides: [MixerStripID(partIndex: 0, instrumentOrdinal: 0): 0.5],
            staffClefOverrides: [StaffAddress(partIndex: 1, staffIndexInPart: 0): "F"],
        )
    }

    @Test func reorderRemapsEveryKeyedCollection() {
        let remapped = prefs().remappingParts([0: 1, 1: 0])
        #expect(remapped.hiddenStaves == [StaffAddress(partIndex: 1, staffIndexInPart: 0),
                                          StaffAddress(partIndex: 0, staffIndexInPart: 1)])
        #expect(remapped.stripProgramOverrides == [MixerStripID(partIndex: 0, instrumentOrdinal: 0): 40])
        #expect(remapped.staffClefOverrides == [StaffAddress(partIndex: 0, staffIndexInPart: 0): "F"])
    }

    @Test func removalDropsThatPartsRows() {
        let remapped = prefs().remappingParts([0: 0, 1: nil])
        #expect(remapped.hiddenStaves == [StaffAddress(partIndex: 0, staffIndexInPart: 0)])
        #expect(remapped.stripProgramOverrides.isEmpty)
        #expect(remapped.staffClefOverrides.isEmpty)
        #expect(remapped.authoredHiddenStaves.isEmpty)
    }

    @Test func unmappedIndexIsDropped() {
        // An address whose partIndex the mapping doesn't know (corrupt row) is dropped, not passed through.
        let remapped = prefs().remappingParts([0: 0])
        #expect(!remapped.hiddenStaves.contains { $0.partIndex == 1 })
    }
}
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement `remappingParts`** — pure value rewrite over the five collections (`hiddenStaves`, `authoredHiddenStaves`, `staffClefOverrides`, `stripProgramOverrides`, `stripVolumeOverrides`); build a fresh copy through the memberwise `init` so the initializer's clamping/filtering still applies.
- [ ] **Step 4: Consume in `performSave`** (after `repository.saveScoreItem(newItem)` succeeds, before `isDirty = false`):

```swift
if let session, !session.isPartMappingIdentity {
    let mapping = session.partIndexMapping
    do {
        if let prefs = try await repository.loadReaderPreferences(for: newItem.id) {
            try await repository.saveReaderPreferences(prefs.remappingParts(mapping))
        }
        session.consumePartIndexMapping()
        onPartIndicesRemapped(mapping)
    } catch {
        // Leave the mapping unconsumed: the next save retries the migration with the same cumulative map.
    }
}
```

(Adapt to how `EditorViewModel` actually holds the session — `session` may be non-optional or named differently; the property was visible as `session?.canUndo` at `EditorViewModel.swift:196`.)

- [ ] **Step 5: Reader in-memory refresh.** Wire `onPartIndicesRemapped` at the App root to a new Reader entry point that flushes any pending preference save, reloads the `ReaderPreferences` row from the repository, and re-seeds the in-memory models that hold `hiddenStaves`/`staffClefOverrides`/strip overrides (follow how the Reader seeds them on score open — search `rg -n "loadReaderPreferences" Packages/Features/Reader` and reuse that path). The mixer strip list itself re-derives from the score via the existing `onScoreChanged` mirror.
- [ ] **Step 6: Run Domain + Editor + Reader package tests; build the app.**
- [ ] **Step 7: Commit** (folino): `git commit -m "feat: migrate StaffAddress-keyed preferences when parts change"`.

---

### Task 13: ssm + folino — written-pitch note input on transposing staves

**Repo:** ssm, then folino

**Files:**
- Modify (ssm): `Sources/SheetMusicCore/Editing/Planners/MeasureAccidentals.swift` (written wrapper), `Sources/SheetMusicCore/Score/Score+ActiveKey.swift` or `PitchSpelling.swift` (written shift helper)
- Test (ssm): `Tests/SheetMusicTests/EditingTests/WrittenInputTests.swift` (create)
- Modify (folino): `Packages/Features/Editor/Sources/Editor/EditorViewModel+Input.swift` (both `inputPitch` sites), `EditorViewModel+Pitch.swift` (`shiftPitch`, `setAccidental`), `NoteNameFormatter.swift` (written display name)
- Test (folino): extend `Packages/Features/Editor/Tests/EditorTests/` input suites with a transposing-staff case.

**Interfaces:**
- Produces (ssm):

```swift
extension MeasureAccidentals {
    /// `plannedPitch`, resolved in the WRITTEN space of the target staff: the letter means the written note
    /// the user sees, and the returned (pitch, tpc) are CONCERT values ready to store. Falls through to
    /// `plannedPitch` unchanged on non-transposing staves.
    public static func plannedConcertPitch(
        forWrittenLetter letter: Character, nearestTo concertReference: Int?,
        at location: VoiceElementID, in score: Score,
    ) -> (pitch: Int, tpc: Int)?
}
extension Score {
    /// `Note.shifted(bySemitones:in:)` computed in the written space of the note's staff; returns the
    /// CONCERT-space result. On a non-transposing staff this equals the plain shift.
    public func shiftedPreservingWrittenSpelling(_ noteID: NoteID, bySemitones delta: Int) -> Note?
}
```

- [ ] **Step 1: Write the failing ssm tests**

```swift
@Suite struct WrittenInputTests {
    // Fixture: B♭ clarinet staff, C major concert (written D major), rest at measure 0.
    @Test func letterCOnClarinetStoresConcertBFlat() {
        // plannedConcertPitch(forWrittenLetter: "C", nearestTo: nil, at: restSlot, in: score)
        // Written C in D major → written C♯? NO: plannedPitch spells the letter as the bar reads it —
        // written D major has C♯ in the key, so letter C means written C♯ (pitch 61 area), concert B♮.
        // Assert against plannedPitch run manually on score.writtenPitchView(): the wrapper must equal
        // "resolve in written view, then subtract the offsets".
        let score = clarinetFixture()
        let written = score.writtenPitchView()
        let expectedWritten = MeasureAccidentals.plannedPitch(
            forLetter: "C", nearestTo: nil, at: slot, in: written)!
        let got = MeasureAccidentals.plannedConcertPitch(
            forWrittenLetter: "C", nearestTo: nil, at: slot, in: score)!
        #expect(got.pitch == expectedWritten.pitch - 2)
        #expect(got.tpc == expectedWritten.tpc - 2)
    }

    @Test func nonTransposingStaffFallsThrough() { /* equals plannedPitch exactly */ }

    @Test func shiftPreservingWrittenSpelling() {
        // Concert B♭ (written C) on clarinet, shift +1 in written space: written C→C♯ (written key D major),
        // concert B♮ tpc 19.
    }
}
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement (ssm).** `plannedConcertPitch`: look up the staff's instrument; when `!isTransposing`, delegate. Otherwise: `let written = score.writtenPitchView()`; call `plannedPitch(forLetter:letter, nearestTo: concertReference.map { $0 + writtenPitchOffset }, at: location, in: written)`; return `(pitch - writtenPitchOffset, tpc - writtenFifthsOffset)`. (One full-score transform per keystroke is acceptable — the editor already re-lays-out the whole score per keystroke; note this in the doc comment as the known cost.) `shiftedPreservingWrittenSpelling`: build the written note (`pitch + po`, `tpc + fo`), written key = `respelledKey(activeKey(at:) + fo)`, run `shifted(bySemitones:in:)`, convert back, recompute `accidental = PitchSpelling.displayedAccidental(forTpc: concertTpc, in: concertKey)`.
- [ ] **Step 4: Implement (folino).** In `EditorViewModel+Input.swift`, both `inputPitch(letter:onRest:)` and `inputPitch(letter:onNote:)` swap `MeasureAccidentals.plannedPitch(forLetter:nearestTo:at:in:)` for `plannedConcertPitch(forWrittenLetter:nearestTo:at:in:)` (reference pitches stay concert — the wrapper converts). In `EditorViewModel+Pitch.swift`, `shiftPitch(bySemitones:)` uses `score.shiftedPreservingWrittenSpelling(noteID, bySemitones: delta)`; `shiftOctave` needs no change (octaves are transposition-invariant); `setAccidental` — route through written space only if `PitchSpelling.respelled` would produce a different letter on a transposing staff: written letter = letter of `tpc + fo`; implement as: build written note, `PitchSpelling.respelled(from: writtenNote, with: accidental)`, convert back, and pass the resulting concert (pitch, tpc) through `.setNotePitch` with the user's accidental glyph. In `NoteNameFormatter`, display the name from `tpc + instrument.writtenFifthsOffset` for notes on transposing staves (find its call sites to get the staff context — the formatter may need the score+address passed in; follow its existing shape).
- [ ] **Step 5: Run** ssm full suite, Editor package tests. Then render the editor `#Preview` path if one exists for the pad; otherwise rely on tests.
- [ ] **Step 6: Commit** ssm (`feat: written-space note input planning for transposing staves`) and folino (`feat: pad input and pitch keys operate in written space on transposing staves`) separately.

---

### Task 14: Analytics, parity markers, wrap-up verification

**Repo:** folino

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Analytics/AnalyticsEvent+Factories.swift` (extend `.scoreCreated`, add `.scorePartsEdited`)
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift` (pass template id + part count), `Packages/Features/Editor/Sources/Editor/EditorViewModel+Parts.swift` (emit part-edit events — follow how the Editor emits existing analytics; if the Editor has no analytics seam, emit from the App layer via an existing hook rather than adding a new dependency)
- Modify: PARITY markers at the three divergence points
- Test: extend the analytics factory test suite (find it: `rg -ln "scoreCreated" Packages/Domain/Tests`)

- [ ] **Step 1: Analytics.** `.scoreCreated(template: String?, partCount: Int)` — template id or `"custom"` / `"cloned"`; `.scorePartsEdited(action: String)` with `"add" | "remove" | "reorder"`. Extend the existing factory tests with the new parameters (mirror the file's test conventions).
- [ ] **Step 2: Parity markers** (one line each, exactly this format, at the point of divergence):
  - `NewScoreSheet.swift`: `// PARITY(android): M2 ensemble wizard — instrumentation list, templates, clone-from-existing on Android's creation flow`
  - `EditorInstrumentsSheet.swift`: `// PARITY(android): M2 instruments sheet — part add/remove/reorder UI and preference remap wiring`
  - `ReaderViewModel.swift` (pipeline): `// PARITY(android): M2 written-pitch view — Android's render pipeline still needs writtenPitchView() between clef overrides and transpose`
  - Run `Scripts/parity-report.py` so the ledger regenerates (the pre-commit hook enforces it).
- [ ] **Step 3: Full verification.**
  - ssm: `xcrun swift test` (full).
  - folino packages touched: Domain, ScoreUI, Library, Editor, Reader, Infrastructure test schemes.
  - App build: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`.
  - Manual round-trip sanity via a Domain-level test if not already covered: create from the string-quartet template through `LiveScoreFileCreator`, reload, `#expect` 4 parts (extend `LiveScoreFileCreatorTests`).
- [ ] **Step 4: Commit** remaining changes: `git commit -m "feat: creation analytics, parity markers for M2"`.
- [ ] **Step 5: Report for on-device verification** (user does this, not simctl automation): create a score from each template; add a clarinet part from the instruments sheet; enter notes on the clarinet staff and confirm the written display (D major key sig against concert C) and concert-pitch playback; import a real B♭ trumpet score and confirm it now displays at written pitch; hide a staff from the instruments sheet; reorder parts and confirm hidden-staff/mixer settings follow their parts after reopening.

---

## Self-review notes (already applied)

- Spec §2 (imports too) → Tasks 2+4; §2 input inversion → Task 13; §3 catalog/templates → Tasks 6–8; §4 factory/commands/mapping → Tasks 5, 9, 10; §5 wizard → Task 8; §6 sheet + migration → Tasks 11–12; §7 tests distributed per task; §8 analytics/parity/order → Task 14 and the task ordering above.
- Type-name consistency: `writtenPitchView()`, `writtenPitchOffset`, `writtenFifthsOffset`, `PartPlan`, `partIndexMapping`, `remappingParts(_:)`, `plannedConcertPitch(forWrittenLetter:...)` are used with the same spelling in every task that touches them.
- Deliberately out of scope (spec): anacrusis (M3), concert/written toggle, range-warning UI, `.scorePartsEdited` per-instrument detail.

# M3: Key/Time Signature Changes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After-the-fact and mid-piece key/time signature changes — time changes re-bar the affected region (split/tie at new barlines, measure count may change), key changes re-spell accidental glyphs — plus cancellation naturals, end-of-system courtesy signatures, and an anacrusis (pickup) option in the creation wizard.

**Architecture:** Key changes are a `CompositeEditCommand` (signature writes on every non-percussion staff + explicit-range renotation via `MeasureAccidentals`). Time changes are one dedicated column-level command (`SetTimeSignature`) whose `apply` re-partitions the whole region across all staves in a single function and whose inverse restores captured pre-image columns byte-for-byte. The re-partition itself lives in a pure `RebarPlanner` that generalizes `CrossBarInputPlanner`'s split/tie machinery from "one slot forward" to "one region, re-barred". Engraving (naturals, courtesy) is layout-side; the model only gains a `showCourtesy` flag.

**Tech Stack:** Swift 6.3, Swift Testing (`@Suite`/`@Test`/`#expect`), swift-sheet-music (ssm) local path pin, SwiftUI Feature packages (Editor / Library / ScoreUI / Domain).

**Spec:** `docs/superpowers/specs/2026-08-27-m3-signature-changes-design.md` (read it first; also the umbrella `docs/superpowers/specs/2026-08-26-scratch-score-creation-and-pro-design.md`).

## Global Constraints

- Two worktrees, two repos: **folino** = `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/scratch-creation-spec` (branch `worktree-scratch-creation-spec`); **ssm** = `/Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music` (branch `feature/scratch-creation-m1`). Commit each change in its own repo. Never merge ssm to main; no ssm release (umbrella policy).
- folino consumes ssm via local path pin; the 6 pin files (`Packages/*/Package.swift`, `project.yml`) are already modified in the working tree — leave them modified, do NOT commit them.
- ssm tests: `xcrun swift test --filter <SuiteName>` from the ssm worktree root (plain `swift test` may pick the wrong toolchain).
- folino package tests: `xcodebuild test -scheme <Pkg> -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` **from the package directory** (check the scheme with `xcodebuild -list`; it may be `<Pkg>-Package`). `swift test` does NOT work in the folino repo.
- folino app build: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build` (this plan does not change `project.yml`).
- MuseScore (`~/Developer/musescore/MuseScore`) is a **behavioral reference only — GPL, no code ported or translated**.
- `EditIntent` case order is the wire format: **append, never renumber**. M3's cases are wire indices 19–22 exactly as listed in Task 3/5.
- Decided semantics (do not re-litigate in tasks): change applies [m, next same-kind change); tuplet or barline-marker conflicts refuse the WHOLE operation; tied chains are split but never merged (A→B→A is not byte-identical; undo is); irregular measures (`actualLength != nil`) are preserved atomically; measure 0 signatures can be changed but not removed; cancellation naturals render only when the new key has zero accidentals; key stores concert values only — written keys stay derived; percussion staves never carry key signatures.
- No access modifier unless needed; `public` only for cross-module use. New tests use Swift Testing. Whole-file staging only (`git add <file>`, never `-p`).
- User-facing copy: app name lowercase `folino`; never expose internal feature names; Editor/ScoreUI xcstrings fill all five locales (en, ja, ko, zh-Hans, zh-Hant); key/time labels are verbatim non-localized (`C / Am`, `4/4`).
- Comment paragraphs reflow at 120 columns.
- All ssm arithmetic on durations uses `Fraction` / integer ticks (`score.division`), never floating point.

---

### Task 1: ssm — `showCourtesy` on KeySignature/TimeSignature + MSCX round-trip

**Repo:** ssm

**Files:**
- Modify: `Sources/SheetMusicCore/Score/KeySignature.swift`, `Sources/SheetMusicCore/Score/TimeSignature.swift`
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+KeySignature.swift`, `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+TimeSignature.swift`
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+KeySignature.swift`, `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+TimeSignature.swift`
- Test: `Tests/SheetMusicTests/SignatureCourtesyFlagTests.swift` (create)

**Interfaces:**
- Produces: `KeySignature.showCourtesy: Bool` and `TimeSignature.showCourtesy: Bool`, stored, default `true`, init parameter appended with default so every existing call site compiles unchanged. MSCX `<showCourtesySig>` decodes into it; the encoder writes `<showCourtesySig>0</showCourtesySig>` only when `false` (MuseScore writes non-default properties only — keeps existing fixtures byte-stable).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import SheetMusicCore
@testable import SheetMusicMSCX

@Suite struct SignatureCourtesyFlagTests {
    @Test func defaultsToTrue() {
        #expect(KeySignature(concertKey: 2).showCourtesy)
        #expect(TimeSignature(numerator: 3, denominator: 4).showCourtesy)
    }

    @Test func showCourtesySigRoundTripsThroughMSCX() throws {
        var score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [.init(instrumentID: "piano", longName: "Piano",
                          staves: [.init(clefType: "G")])],
            measureCount: 2,
        ))
        // A mid-piece key change with courtesy suppressed, at the head of measure 1.
        var key = KeySignature(concertKey: 3)
        key.showCourtesy = false
        score.parts[0].staves[0].measures[1].voices[0].elements.insert(.keySignature(key), at: 0)
        MeasureStructure.shiftTuplets(in: &score.parts[0].staves[0].measures[1].voices[0], by: 1)
        let xml = try String(decoding: MSCXEncoder.encode(score), as: UTF8.self)
        #expect(xml.contains("<showCourtesySig>0</showCourtesySig>"))
        let reparsed = try MSCXParser.parse(MSCXEncoder.encode(score))
        guard case let .keySignature(decoded) = reparsed.parts[0].staves[0].measures[1].voices[0].elements[0]
        else { Issue.record("no key sig"); return }
        #expect(decoded.showCourtesy == false)
        #expect(decoded.concertKey == 3)
    }

    @Test func defaultTrueEmitsNoTag() throws {
        let score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [.init(instrumentID: "piano", longName: "Piano",
                          staves: [.init(clefType: "G")])],
            measureCount: 1,
        ))
        let xml = try String(decoding: MSCXEncoder.encode(score), as: UTF8.self)
        #expect(!xml.contains("showCourtesySig"))
    }
}
```

Adjust `MSCXEncoder.encode` / `MSCXParser.parse` spellings to the real entry points — copy the encode/decode helper from `Tests/SheetMusicTests/EditingTests/BlankScoreTests.swift`. `MeasureStructure` is internal — the test imports `@testable`.

- [ ] **Step 2: Run to verify failure** — `xcrun swift test --filter SignatureCourtesyFlagTests`. Expected: compile error, `showCourtesy` not a member.
- [ ] **Step 3: Implement.** Add the stored property + doc comment ("MSCX `<showCourtesySig>` — whether the end-of-system courtesy for this signature is drawn; layout reads it, nothing else does"). Decoders: read the child element as `1`/`0` (absent → `true`); the three existing fixtures carrying `<showCourtesySig>` now decode it instead of dropping it. Encoders: emit `<showCourtesySig>0</showCourtesySig>` when `false`, placed where MuseScore puts it (before `<concertKey>` / `<sigN>` — check a MuseScore-written fixture in `Tests/SheetMusicTests/Resources/testRepeatsWithKeySigs.mscx` for the order and mirror it).
- [ ] **Step 4: Run the full suite** — `xcrun swift test`. The `testRepeatsWithKeySigs*` fixture round-trips may now legitimately preserve a tag they previously dropped; inspect any failure and update expectations only where the new output is correct.
- [ ] **Step 5: Commit** (ssm): `git add <files>`, `git commit -m "feat: model courtesy-signature visibility and round-trip showCourtesySig"`.

---

### Task 2: ssm — explicit-range renotation API on MeasureAccidentals

**Repo:** ssm

**Files:**
- Modify: `Sources/SheetMusicCore/Editing/Planners/MeasureAccidentals.swift`
- Test: `Tests/SheetMusicTests/EditingTests/MeasureAccidentalsPlannerTests.swift` (extend)

**Interfaces:**
- Consumes: existing `private static func renotate(_:at:measureIndex:keySig:division:measureDuration:) -> [any EditCommand]` and `Score.activeKey(staff:measureIndex:)`.
- Produces: `MeasureAccidentals.renotationCommands(in score: Score, measureRange: Range<Int>) -> [any EditCommand]` — for every non-percussion staff and every measure in `measureRange`, plans `ReplaceVoiceElements` repairs against the key in force *in `score` as given* (i.e. call it on a preview score that already carries the new key). Emits commands only for measures whose renotation actually differs. Skip rules identical to the diff-based path (user accidentals, tied-back notes, disagreeing pitch/tpc, non-standard glyphs — those live inside `renotate` already).

- [ ] **Step 1: Write the failing test** (extend the existing suite; reuse its fixture helpers if it has them):

```swift
@Test func rangeRenotationCoversMeasuresAfterAKeyChange() {
    // Two measures of G major (1 sharp) holding F♯s spelled without glyphs (in key), then flip the
    // score to C major and ask for renotation over 0..<2: every F♯ now needs an explicit ♯ glyph.
    var score = Score.blank(BlankScoreTemplate(
        title: "T",
        parts: [.init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")])],
        concertKey: 1, measureCount: 2,
    ))
    for m in 0 ..< 2 {
        let slot = m == 0 ? 2 : 0
        score.parts[0].staves[0].measures[m].voices[0].elements[slot] =
            .chord(Chord(duration: .whole, notes: [Note(pitch: 66, tpc: 20)]))  // F♯4, in-key in G major
    }
    // Flip the stored key to C major the way SetKeySignature will: rewrite the measure-0 element.
    guard case .keySignature = score.parts[0].staves[0].measures[0].voices[0].elements[0]
    else { Issue.record("expected key sig at [0]"); return }
    score.parts[0].staves[0].measures[0].voices[0].elements[0] = .keySignature(KeySignature(concertKey: 0))

    let repairs = MeasureAccidentals.renotationCommands(in: score, measureRange: 0 ..< 2)
    #expect(repairs.count == 2)   // BOTH measures need a repair — the diff-based path would only find bar 0
    var repaired = score
    for command in repairs { _ = try? command.apply(to: &repaired) }
    for m in 0 ..< 2 {
        let slot = m == 0 ? 2 : 0
        guard case let .chord(chord) = repaired.parts[0].staves[0].measures[m].voices[0].elements[slot]
        else { Issue.record("chord"); return }
        #expect(chord.notes[0].accidental != nil)   // F♯ out of key now carries its glyph
    }
}
```

Check `Note`'s accidental property name and `Accidental` values against `Sources/SheetMusicCore/Score/Note.swift` and adjust the assertion (the renotate path writes whatever glyph type the existing suite asserts — mirror it).

- [ ] **Step 2: Run to verify failure** — `xcrun swift test --filter MeasureAccidentalsPlannerTests`.
- [ ] **Step 3: Implement.** New public static function beside `renotationCommands(in:changedFrom:)`, sharing its per-staff loop shape: for each part/staff (`staff.group != "percussion"` — match the skip the existing code uses; check how `AddPart.signatureReference(in:)` spells the percussion test and reuse that helper or predicate), for each `measureIndex` in `measureRange ∩ measures.indices`, call `renotate(measure, at:, measureIndex:, keySig: score.activeKey(staff:measureIndex:), division:, measureDuration: durations[measureIndex])` and append its commands.
- [ ] **Step 4: Run to verify pass**, then full `xcrun swift test`.
- [ ] **Step 5: Commit** (ssm): `git commit -m "feat: explicit-range accidental renotation for signature changes"`.

---

### Task 3: ssm — SetKeySignature / RemoveKeySignature commands + intents (wire 19, 20)

**Repo:** ssm

**Files:**
- Create: `Sources/SheetMusicCore/Editing/SetKeySignature.swift` (both commands)
- Modify: `Sources/SheetMusicCore/Editing/EditIntent.swift` (append 2 cases)
- Modify: `Sources/SheetMusicCore/Editing/ScoreEditSession+Planning.swift` (plan both intents)
- Modify: `Sources/SheetMusicCore/Editing/EditRefusal.swift` (add `.cannotRemoveInitialSignature`)
- Modify: `Sources/SheetMusicEditWire/Intent/EditIntentCodec.swift` (wire cases 19/20 — follow the file's own payload-struct and index conventions; every field written, no default-skipping)
- Test: `Tests/SheetMusicTests/EditingTests/SetKeySignatureTests.swift` (create)

**Interfaces:**
- Consumes: Task 2's `renotationCommands(in:measureRange:)`; `MeasureStructure.leadingSignaturePrefix` / `mergedLeadingSignatures` / `shiftTuplets` / `removeElements`; `CompositeEditCommand(commands:location:)`.
- Produces:

```swift
// EditIntent — appended after .movePart, in this order (wire 19, 20):
/// Set the concert key in force from `measureIndex` to the next explicit key change (or the end of the
/// score): writes/replaces the `.keySignature` on every non-percussion staff at that measure and
/// re-spells accidental glyphs over the affected span, as one undo step.
case setKeySignature(measureIndex: Int, concertKey: Int)
/// Remove the explicit key change at `measureIndex`, reverting its span to the previous key. Refused
/// with `.cannotRemoveInitialSignature` at measure 0; plans to nothing when no explicit change exists.
case removeKeySignature(measureIndex: Int)

public struct SetKeySignature: EditCommand {
    public let measureIndex: Int
    public let concertKey: Int
    public init(measureIndex: Int, concertKey: Int)
    // apply: on every staff whose `group != "percussion"`: replace the `.keySignature` in measure
    // `measureIndex`'s leading prefix, or insert one at the canonical prefix position
    // (mergedLeadingSignatures order: clef → key → time), shifting tuplets by the insertion delta.
    // Inverse: internal init capturing each staff's prior voice-0 prefix, restored verbatim.
}

public struct RemoveKeySignature: EditCommand {
    public let measureIndex: Int
    public init(measureIndex: Int)
    // apply: refuse .cannotRemoveInitialSignature when measureIndex == 0; refuse .nothingToApply-equivalent
    // is the PLANNER's job (plan to nil) — apply throws .targetNotFound when no explicit key exists there.
    // Removes the `.keySignature` element from every staff's measure via MeasureStructure.removeElements.
    // Inverse: SetKeySignature-style pre-image restore (internal init).
}
```

Planner (`ScoreEditSession+Planning.command(for:)`):

```swift
case let .setKeySignature(measureIndex, concertKey):
    // Nothing to do when the key in force at measureIndex already equals concertKey AND no explicit
    // element sits at measureIndex needing replacement to that same value (idempotence → nil).
    // Otherwise: preview-apply SetKeySignature to a copy, compute the affected range
    // [measureIndex, nextExplicitKeyChange(after: measureIndex) ?? measureCount), and return
    // CompositeEditCommand([SetKeySignature(...)] + MeasureAccidentals.renotationCommands(in: preview,
    // measureRange: range), location: <the SetKeySignature's affectedLocation>).
case let .removeKeySignature(measureIndex):
    // nil when no explicit .keySignature element exists in the leading prefix at measureIndex on the
    // reference staff (first non-percussion staff). Same composite shape, with the restored key.
```

Add a private helper in the planning file: `nextExplicitKeyChange(after m: Int, in score: Score) -> Int?` — scan the reference staff's measures `m+1...`, voice 0 leading prefix, for a `.keySignature`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import SheetMusicCore

@Suite struct SetKeySignatureTests {
    /// Piano + B♭ clarinet + drum kit, 4 bars, G major (1 sharp), an F♯ chord in every bar of the piano,
    /// and an existing explicit key change to D (2 sharps) at bar 2.
    private func fixture() -> Score {
        var score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [
                .init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G")]),
                .init(instrumentID: "clarinet-bb", longName: "Clarinet",
                      staves: [.init(clefType: "G")], transposeDiatonic: -1, transposeChromatic: -2),
                .init(instrumentID: "drumset", longName: "Drums",
                      staves: [.init(clefType: "PERC", isPercussion: true)], isDrums: true),
            ],
            concertKey: 1, measureCount: 4,
        ))
        for part in [0, 1] {
            for m in 0 ..< 4 {
                let slot = m == 0 ? 2 : 0
                score.parts[part].staves[0].measures[m].voices[0].elements[slot] =
                    .chord(Chord(duration: .whole, notes: [Note(pitch: 66, tpc: 20)]))
            }
            score.parts[part].staves[0].measures[2].voices[0].elements
                .insert(.keySignature(KeySignature(concertKey: 2)), at: 0)
            MeasureStructure.shiftTuplets(in: &score.parts[part].staves[0].measures[2].voices[0], by: 1)
        }
        return score
    }

    @Test func setKeyWritesAllStavesSkipsPercussionAndRenotatesTheSpan() {
        var session = ScoreEditSession(score: fixture())
        #expect(session.apply(.setKeySignature(measureIndex: 0, concertKey: 0)))   // G → C major
        let score = session.score
        for part in [0, 1] {
            guard case let .keySignature(k) = score.parts[part].staves[0].measures[0].voices[0].elements[0]
            else { Issue.record("key"); return }
            #expect(k.concertKey == 0)
            // Bars 0 and 1 (the affected span) now show explicit ♯ glyphs; bar 2 onward is D major's span
            // and must be untouched.
            for m in 0 ..< 2 {
                let slot = m == 0 ? 2 : 0
                guard case let .chord(c) = score.parts[part].staves[0].measures[m].voices[0].elements[slot]
                else { Issue.record("chord"); return }
                #expect(c.notes[0].accidental != nil)
            }
        }
        // Percussion staff never carries a key signature.
        #expect(!score.parts[2].staves[0].measures[0].voices[0].elements
            .contains { if case .keySignature = $0 { true } else { false } })
        #expect(score.activeKey(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 3) == 2)  // bar 2's change survives
    }

    @Test func setKeyIsOneUndoStepAndRoundTrips() {
        let original = fixture()
        var session = ScoreEditSession(score: original)
        #expect(session.apply(.setKeySignature(measureIndex: 0, concertKey: -3)))
        #expect(session.undo())
        #expect(session.score == original)
    }

    @Test func setSameKeyPlansToNothing() {
        var session = ScoreEditSession(score: fixture())
        #expect(!session.apply(.setKeySignature(measureIndex: 0, concertKey: 1)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
    }

    @Test func midPieceSetReplacesTheExistingChange() {
        var session = ScoreEditSession(score: fixture())
        #expect(session.apply(.setKeySignature(measureIndex: 2, concertKey: -1)))  // D → F major at bar 2
        #expect(session.score.activeKey(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 3) == -1)
        #expect(session.score.activeKey(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 1) == 1)  // span before untouched
    }

    @Test func removeKeyRevertsToPrevailingAndRoundTrips() {
        let original = fixture()
        var session = ScoreEditSession(score: original)
        #expect(session.apply(.removeKeySignature(measureIndex: 2)))
        #expect(session.score.activeKey(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 3) == 1)  // back to G major
        #expect(!session.score.parts[0].staves[0].measures[2].voices[0].elements
            .contains { if case .keySignature = $0 { true } else { false } })
        #expect(session.undo())
        #expect(session.score == original)
    }

    @Test func removeAtMeasureZeroIsRefused() {
        var session = ScoreEditSession(score: fixture())
        #expect(!session.apply(.removeKeySignature(measureIndex: 0)))
        #expect(session.lastRefusal?.reason == .cannotRemoveInitialSignature)
    }

    @Test func removeWhereNoChangeExistsPlansToNothing() {
        var session = ScoreEditSession(score: fixture())
        #expect(!session.apply(.removeKeySignature(measureIndex: 1)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
    }
}
```

Also assert intermediate state right after apply, not only after the round trip (the InsertMeasure/AddPart suites explain why — symmetric bugs cancel invisibly).

- [ ] **Step 2: Run to verify failure** — `xcrun swift test --filter SetKeySignatureTests`.
- [ ] **Step 3: Implement the two commands** (one file, they share the prefix-splice helpers). Insertion path: find the prefix span via `MeasureStructure.leadingSignaturePrefix`, replace an existing `.keySignature` in place, or insert at the canonical position (after `.clef`, before `.timeSignature`) and `shiftTuplets(by: 1)`. Removal path: `MeasureStructure.removeElements(in:where:)` scoped to the leading prefix (guard: only remove a `.keySignature` sitting in the prefix). Inverse: internal init `SetKeySignature(restoringPrefixes:at:)` carrying `[[ [VoiceElement] ]]` (per part, per staff: the prior full voice-0 prefix) — restore by splicing the prefix span back and re-shifting tuplets. `EditRefusal.Reason` gains `case cannotRemoveInitialSignature` (+ `code` `"edit.cannotRemoveInitialSignature"` + `developerDescription` — follow the two M1 cases).
- [ ] **Step 4: Implement the planner cases** (shape in Interfaces above) and the codec cases. The codec: two new `@WireFormatChoice` cases at indices 19/20 with scalar payload structs (`SetKeySignatureIntentWire { measureIndex, concertKey }`, `RemoveKeySignatureIntentWire { measureIndex }`) — copy the `insertMeasure`/`deleteMeasure` wire structs' exact style, including the byte-layout doc comments the file maintains.
- [ ] **Step 5: Run to verify pass**, then full `xcrun swift test` (the codec's exhaustive-switch tests will catch a missed mirror — Kotlin/TS mirrors are Task 7, and the Swift-side codec tests must pass now).
- [ ] **Step 6: Commit** (ssm): `git commit -m "feat: set/remove key signature commands with span re-spelling"`.

---

### Task 4: ssm — RebarPlanner (pure region re-partition)

**Repo:** ssm

**Files:**
- Create: `Sources/SheetMusicCore/Editing/Planners/RebarPlanner.swift`
- Modify: `Sources/SheetMusicCore/Editing/EditRefusal.swift` (add the two re-bar reasons)
- Test: `Tests/SheetMusicTests/EditingTests/RebarPlannerTests.swift` (create)

**Interfaces:**
- Consumes: `DurationChangeAlgorithm.alignedDurations(forTicks:rtickStart:division:)`, `.alignedRests`, `.makeChordChain(from:durations:)`; `MeasureSlice`; `Score.effectiveMeasureDurations`; `VoiceElement.tickCount(division:in:)`.
- Produces (internal — only `SetTimeSignature` consumes it):

```swift
/// Re-partitions one measure region into bars of a new nominal duration. Pure planning: reads the score,
/// returns the replacement columns, mutates nothing. Throws EditCommand-style refusals.
enum RebarPlanner {
    struct Rebarred {
        /// The region's replacement, one entry per NEW measure column, `systemMeasure` included
        /// (elements re-homed by absolute tick). Column count may differ from the region's old count.
        var columns: [MeasureSlice]
    }

    /// `region` is [firstMeasure, endMeasure) in current measure indices. `numerator`/`denominator` are the
    /// new nominal signature. The FIRST regular column's voice-0 prefix carries the new `.timeSignature`
    /// on every staff (existing `.timeSignature` elements inside the region are dropped; clefs and
    /// `.keySignature` elements are carried at their ticks).
    static func rebar(
        region: Range<Int>, in score: Score, numerator: Int, denominator: Int,
    ) throws -> Rebarred
}
```

New `EditRefusal.Reason` cases: `.rebarWouldSplitTuplet(measureIndex: Int)` and `.rebarWouldDisplaceBarlineMarker(measureIndex: Int)` (the latter covers repeat barlines, `startRepeat`, and special `.barLine` elements whose tick no longer falls on a barline — the spec's `rebarWouldBreakRepeat`, named for what it detects). Both get `code` + `developerDescription` entries.

**Algorithm (implement exactly this; every rule is a decided semantic):**

1. Per (part, staff): compute the region's old measure durations (`[Measure].effectiveMeasureDurations()` on that staff, sliced) and each old measure's absolute start tick within the region.
2. **Irregular measures split the region**: walk the region and cut it into *runs* of regular measures separated by measures with `actualLength != nil`. Irregular columns pass through verbatim (all staves + their `SystemMeasure`). Each regular run re-bars independently at the new nominal duration.
3. Per (staff, voiceIndex) within a run, flatten to a stream of items, each with a start tick: `.timed(VoiceElement, ticks)` for chords/rests (tuplet members grouped — see 4), `.untimed(VoiceElement)` for clefs/dynamics/harmony/spanners at their tick, and a gap for `.locationShift` (re-emit gaps as `.locationShift` at the equivalent position in the new barring; a voice absent from an old measure contributes a measure-long gap, and a new measure whose whole span is gap for that voice simply omits the voice). Old `.timeSignature` elements in the run are dropped; `.keySignature` and `.clef` are untimed carries. `.barLine` elements and `Measure.startRepeat`/special barline properties: record their ticks as *markers* (see 7).
4. **Tuplets are atomic**: a tuplet's member span (contiguous elements `startIndex...endIndex`) becomes ONE stream item of its summed ticks carrying the member elements and the ratio. If it would cross a new barline, throw `.rebarWouldSplitTuplet(measureIndex: <old measure of the tuplet>)`.
5. Emit new columns of `newDuration = Fraction(numerator, denominator)`: fill each new measure from the stream. A timed chord crossing the new barline splits via `alignedDurations` (remaining-in-bar, then per-bar) + `makeChordChain` — interior joints tied, outer ties preserved (makeChordChain already does both; pass the source chord's `tieBack` through on the first piece — check its handling: it sets first piece `tieBack = nil`; wrap it the way `CrossBarInputPlanner.piece` does, preserving `source.tieBack` on the head, and add that as a test case). Rests split via `alignedRests`; a fully-covered new bar of rest becomes `[.rest(duration: .measure)]`. Never merge tied chains.
6. **Remainder**: after the stream is exhausted, pad the final partial bar with `alignedRests` to full length. Every emitted regular column has nominal duration — no `actualLength` is written by re-barring.
7. **Markers re-home exactly**: each recorded barline-marker tick must equal a new column boundary tick; the marker moves onto that boundary (a `.barLine` element goes at the tail of the preceding new measure's voice 0 — mirror where the decoder puts it; `startRepeat` is a `Measure` property on the new column's measures). Otherwise throw `.rebarWouldDisplaceBarlineMarker(measureIndex:)`.
8. **SystemMeasure lane**: convert each region `PositionedSystemElement` to an absolute tick (`measureStartTick + position` — `MeasurePosition` is a fraction; convert via `Fraction`), then re-home into the new column containing that tick with `position = tick - newColumnStartTick`. Preserve document order.
9. All staves must agree on column count (they will — same nominal durations, same region ticks; assert it in DEBUG).

- [ ] **Step 1: Write the failing tests.** Build fixtures via `Score.blank` (division 480; whole = 1920 ticks in 4/4). Cover, as separate `@Test`s:
  - **4/4 → 3/4 shrink**: 2 bars of 4/4 (whole note each) → 3 columns; first whole note becomes dotted-half + quarter tied (or the aligned split `alignedDurations` yields — assert against its actual output, computed in the test via the same API); measure count 2 → 3 (content 8 quarters into 3+3+2, last bar padded with a quarter rest... compute: 3840 ticks / 1440 = 2 full + 960 remainder → 3 columns, last padded with 480 ticks of rest).
  - **3/4 → 4/4 grow**: tied chain NOT merged (seed a chain split across two 3/4 bars, assert both pieces survive with the tie intact).
  - **Rest promotion**: an all-rest region re-bars to `.measure` rests in every column.
  - **Tuplet atomic**: an eighth-note triplet fitting inside a new bar survives with correct new indices; a triplet that would straddle throws `.rebarWouldSplitTuplet`.
  - **Pickup preserved**: region starting with an `actualLength` bar keeps it verbatim and re-bars only the rest.
  - **Mid-region key change + clef carried**: a `.keySignature` at an interior old measure head lands at its tick (head of the new column containing that tick).
  - **Voice-2 gap**: a second voice present only in bar 0 keeps its content and produces no phantom rests in later columns.
  - **SystemMeasure re-home**: a tempo element mid-region lands in the right new column with the right offset.
  - **Barline marker**: a `startRepeat` at a tick that stays a boundary survives; one that doesn't throws `.rebarWouldDisplaceBarlineMarker`.
- [ ] **Step 2: Run to verify failure** — `xcrun swift test --filter RebarPlannerTests`.
- [ ] **Step 3: Implement** per the algorithm above. Keep the flatten/emit halves as separate private functions so each is testable through the public `rebar`.
- [ ] **Step 4: Run to verify pass**, then full `xcrun swift test`.
- [ ] **Step 5: Commit** (ssm): `git commit -m "feat: region re-barring planner"`.

---

### Task 5: ssm — SetTimeSignature / RemoveTimeSignature commands + intents (wire 21, 22)

**Repo:** ssm

**Files:**
- Create: `Sources/SheetMusicCore/Editing/SetTimeSignature.swift` (both commands + the internal restore command)
- Modify: `Sources/SheetMusicCore/Editing/EditIntent.swift` (append 2 cases)
- Modify: `Sources/SheetMusicCore/Editing/ScoreEditSession+Planning.swift`
- Modify: `Sources/SheetMusicEditWire/Intent/EditIntentCodec.swift` (wire 21/22)
- Test: `Tests/SheetMusicTests/EditingTests/SetTimeSignatureTests.swift` (create)

**Interfaces:**
- Consumes: `RebarPlanner.rebar(region:in:numerator:denominator:)` (Task 4); `MeasureSlice`; `MeasureStructure.measureCount`.
- Produces:

```swift
// EditIntent — appended after .removeKeySignature (wire 21, 22):
/// Set the time signature in force from `measureIndex` to the next explicit time change (or the end of
/// the score), re-barring that region: content is re-partitioned into bars of the new length, notes are
/// split and tied at the new barlines, and the measure count may change. One undo step.
case setTimeSignature(measureIndex: Int, numerator: Int, denominator: Int)
/// Remove the explicit time change at `measureIndex`, re-barring its span back to the previous
/// signature. Refused with `.cannotRemoveInitialSignature` at measure 0.
case removeTimeSignature(measureIndex: Int)

public struct SetTimeSignature: EditCommand {
    public let measureIndex: Int
    public let numerator: Int
    public let denominator: Int
    public init(measureIndex: Int, numerator: Int, denominator: Int)
    // apply:
    //  1. validate: measureIndex in range; numerator 1...63; denominator in {1,2,4,8,16,32}
    //     (throw .targetNotFound / .unexpected respectively — the UI never sends bad values, the guard is
    //     for direct command use);
    //  2. region = [measureIndex, nextExplicitTimeChange(after:) ?? measureCount);
    //  3. capture pre-image: the region's columns as [MeasureSlice] + every OUTSIDE spanner whose span
    //     crosses the region, as [(VoiceElementID, Int)] of original nextMeasuresOffset;
    //  4. rebarred = try RebarPlanner.rebar(region:in:numerator:denominator:) — a thrown refusal
    //     propagates with the score untouched;
    //  5. splice: replace the region's measures on every staff and the region's systemMeasures with
    //     rebarred.columns; write the new .timeSignature into the first column's voice-0 prefix on every
    //     staff (canonical clef → key → time position) — RebarPlanner already did this, keep the
    //     responsibility THERE and just assert it here;
    //  6. adjust outside spanners: for a spanner anchored before the region ending inside/after it,
    //     recompute nextMeasuresOffset from the anchor tick and end tick against the new barring
    //     (delta = newColumnCount - oldColumnCount applies to spans that fully cross; spans ENDING inside
    //     the region resolve their end tick to the new column containing it);
    //  7. return RestoreTimeSignatureRegion(range: measureIndex ..< measureIndex + newColumnCount,
    //     columns: <pre-image>, spannerOffsets: <pre-image>).
}

/// Internal inverse: splices `columns` back over `range` and restores the captured spanner offsets
/// verbatim. Its own inverse is another SetTimeSignature-shaped pre-image capture of what it replaces —
/// implement it as a second apply of the same struct type (capture-before-splice), so undo/redo cycle
/// through one code path.
struct RestoreTimeSignatureRegion: EditCommand { ... }

public struct RemoveTimeSignature: EditCommand {
    public let measureIndex: Int
    // apply: measureIndex == 0 → .cannotRemoveInitialSignature; no explicit .timeSignature there →
    // .targetNotFound (planner answers .nothingToApply first). Otherwise: identical to SetTimeSignature
    // with (numerator, denominator) = the signature in force BEFORE measureIndex, and the explicit
    // element at measureIndex dropped instead of replaced. Reuse SetTimeSignature's machinery — implement
    // as a thin wrapper that computes the prevailing signature and delegates, but keep the element-drop.
}
```

Planner: `.setTimeSignature` plans to `nil` when the signature in force at `measureIndex` already equals `numerator/denominator` and no explicit element sits there with a different value; `.removeTimeSignature` plans to `nil` when no explicit change exists at `measureIndex` (> 0). Helper `nextExplicitTimeChange(after:in:)` mirrors Task 3's key helper (reference staff = staff 0 — time signatures are score-wide by model invariant).

**Session interplay to verify in tests, not assume:** the session's automatic `renotatingAccidentals` pass diffs changed measures — after a re-bar every region measure differs, so accidental glyphs inside the region are repaired automatically in the same undo step. Assert it (a re-bar that moves an accidental-carrying note across a barline gets a correct glyph in its new bar).

- [ ] **Step 1: Write the failing tests.** Fixture: piano two staves + clarinet, 4 bars 4/4, notes in bars 0–3, an existing explicit 6/8 change at... no — keep two fixtures: (a) uniform 4/4; (b) 4/4 with an explicit 3/4 at bar 2. Cover as separate `@Test`s:
  - `setAtZeroRebarsWholeScoreAndCountsChange` — 4/4 → 3/4 on fixture (a): measure count grows; every staff and `systemMeasures` agree on the new count; new `.timeSignature(3/4)` at measure 0 on every staff; the whole-note chain split+tied per `alignedDurations`.
  - `setMidPieceRebarsOnlyThatSpan` — on fixture (b): set 2/4 at bar 2; bars 0–1 untouched byte-for-byte.
  - `applyUndoRoundTripsByteForByte` — apply, `#expect(session.undo())`, `session.score == original`; then `redo()` and undo again (exercises `RestoreTimeSignatureRegion`'s own inverse).
  - `tupletConflictRefusesWholeOperationScoreUntouched` — triplet straddling the would-be barline: `apply` returns false, `lastRefusal?.reason == .rebarWouldSplitTuplet(...)`, score unchanged.
  - `removeRevertsToPrevailingAndRoundTrips` — on fixture (b): remove at bar 2; span re-bars back to 4/4; the explicit element is gone; undo restores byte-for-byte.
  - `removeAtZeroRefused`, `setSamePlansToNothing`, `removeWhereNoChangePlansToNothing` — mirror Task 3.
  - `spannerAcrossRegionKeepsItsEndpoints` — a spanner anchored in bar 0 ending in bar 3, re-bar 4/4→2/4 at bar 1: offset recomputed so the end lands on the same tick; undo restores the original offset.
  - `rebarRenotatesMovedAccidentals` — the session-interplay case above.
  - `oneUndoStepOnly` — after apply, exactly one `undo()` restores original (no second entry).
- [ ] **Step 2: Run to verify failure** — `xcrun swift test --filter SetTimeSignatureTests`.
- [ ] **Step 3: Implement** the three command types + planner cases + codec cases 21/22 (`SetTimeSignatureIntentWire { measureIndex, numerator, denominator }`, `RemoveTimeSignatureIntentWire { measureIndex }`).
- [ ] **Step 4: Run to verify pass**, then full `xcrun swift test`.
- [ ] **Step 5: Commit** (ssm): `git commit -m "feat: set/remove time signature commands with region re-barring"`.

---

### Task 6: ssm — round-trip corpus bed (create → change → encode → re-parse → compare)

**Repo:** ssm

**Files:**
- Test: `Tests/SheetMusicTests/EditingTests/SignatureChangeRoundTripTests.swift` (create)

**Interfaces:**
- Consumes: Tasks 3 & 5 intents; `MSCXEncoder`/`MSCXParser` (spellings from `BlankScoreTests`); `Score.withSource(.unknown)` normalization.

This is the umbrella spec's mandated test bed: it must be green before any folino UI work.

- [ ] **Step 1: Write the failing test** — a matrix runner:

```swift
import Testing
@testable import SheetMusicCore
@testable import SheetMusicMSCX

@Suite struct SignatureChangeRoundTripTests {
    /// Ensemble score with content: piano + clarinet, 6 bars, notes spread over the bars (including one
    /// tied pair and one triplet parked where no test signature splits it — bars 4–5), pickup optional.
    private func seed(pickup: Bool) -> Score { /* Score.blank + element writes; pickup variant sets
        measure 0 actualLength = 1/4 and irregular = true by direct mutation (Task 10 adds the factory
        path — this test doesn't wait for it) */ }

    private func roundTrip(_ score: Score) throws -> Score {
        try MSCXParser.parse(MSCXEncoder.encode(score)).withSource(.unknown)
    }

    @Test(arguments: [false, true])
    func keySetAndRemoveSurviveMSCX(pickup: Bool) throws {
        var session = ScoreEditSession(score: seed(pickup: pickup))
        #expect(session.apply(.setKeySignature(measureIndex: 2, concertKey: -2)))
        #expect(try roundTrip(session.score) == session.score.withSource(.unknown))
        #expect(session.apply(.removeKeySignature(measureIndex: 2)))
        #expect(try roundTrip(session.score) == session.score.withSource(.unknown))
    }

    @Test(arguments: [false, true])
    func timeSetAndRemoveSurviveMSCX(pickup: Bool) throws {
        var session = ScoreEditSession(score: seed(pickup: pickup))
        #expect(session.apply(.setTimeSignature(measureIndex: 1, numerator: 3, denominator: 4)))
        #expect(try roundTrip(session.score) == session.score.withSource(.unknown))
        #expect(session.apply(.removeTimeSignature(measureIndex: 1)))
        #expect(try roundTrip(session.score) == session.score.withSource(.unknown))
    }

    @Test func stackedChangesSurvive() throws {
        var session = ScoreEditSession(score: seed(pickup: false))
        #expect(session.apply(.setTimeSignature(measureIndex: 0, numerator: 6, denominator: 8)))
        #expect(session.apply(.setKeySignature(measureIndex: 0, concertKey: 4)))
        #expect(session.apply(.setTimeSignature(measureIndex: 2, numerator: 2, denominator: 4)))
        #expect(try roundTrip(session.score) == session.score.withSource(.unknown))
    }
}
```

- [ ] **Step 2: Run** — `xcrun swift test --filter SignatureChangeRoundTripTests`. Any failure here is an encoder/decoder gap surfaced by the new edit paths (likely candidates: cross-bar tie `<location>` emission over re-barred spans, `actualLength` `len` attributes, mid-piece `<TimeSig>` placement). Fix in the codec, not by weakening the test.
- [ ] **Step 3: Run the full suite**, then commit (ssm): `git commit -m "test: signature-change mscx round-trip corpus bed"`.

---

### Task 7: ssm — fingerprint extension + replay/codec parity (Android & web mirrors)

**Repo:** ssm

**Files:**
- Modify: `Sources/SheetMusicCore/Score/ScoreFingerprint.swift` (hash `actualLength`, `irregular`, `systemMeasures`)
- Modify: `Tests/SheetMusicTests/EditingTests/EditReplayScript.swift` (steps for all four new intents)
- Modify: Kotlin codec mirror under `Android/` and TS mirror under `Web/` (locate via `rg -l "movePart" Android Web` — mirror the Swift codec's 19–22 exactly)
- Regenerate: `Tests/SheetMusicTests/AndroidJNI/EditReplayGoldenTests.swift` committed assets; `Web/sheet-music-web/test/fixtures/edit-replay.json` via `Tools/GenWebFixtures/EditFixtures.swift`
- Test: `Tests/SheetMusicTests/ScoreFingerprintTests.swift` (extend — find the existing suite name with `rg -l "stableFingerprint" Tests`)

**Interfaces:**
- Consumes: Tasks 3 & 5 intents.
- Produces: `stableFingerprint` sensitive to `Measure.actualLength`, `Measure.irregular`, and `Score.systemMeasures` (hash each `PositionedSystemElement`'s measure index, position fraction, and element payload the same way the fingerprint hashes other enums — follow the file's FNV-1a feeding conventions and update its "blind to" doc list).

- [ ] **Step 1: Write the failing fingerprint tests** — three `@Test`s: two scores differing only in `actualLength` / only in `irregular` / only in a `systemMeasures` element hash differently.
- [ ] **Step 2: Run to verify failure**, implement the hash extension, run to verify pass.
- [ ] **Step 3: Extend `EditReplayScript`** with four steps exercising `.setKeySignature`, `.setTimeSignature` (a real re-bar — pick a step score state where it splits at least one note), `.removeTimeSignature`, `.removeKeySignature`, keeping the file's element-index-stability rules (read its doc comment first). `EditReplayDeterminismTests` must still see ≥ 10 distinct fingerprints.
- [ ] **Step 4: Mirror the codec cases** in Kotlin and TS (indices 19–22, every field written). Regenerate the web fixtures (`Tools/GenWebFixtures`) and the Android golden assets per the instructions in `EditReplayGoldenTests.swift` — the fingerprint change alone invalidates ALL committed golden fingerprints; regenerate rather than hand-edit, and say so in the commit message.
- [ ] **Step 5: Run the gates** — `Scripts/preflight.sh --apple`, `--wasm`, `--android` (the Android one needs the release toolchain on PATH — see the repo memory `project_android_build_toolchain` if it fails on toolchain grounds). All green.
- [ ] **Step 6: Commit** (ssm): `git commit -m "feat: wire signature intents across images; fingerprint covers measure irregularity and system lane"`.

---

### Task 8: ssm — cancellation naturals (layout)

**Repo:** ssm

**Files:**
- Modify: `Sources/SheetMusicLayout/Engraving/KeySignatureSteps.swift` (naturals step computation)
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift` (emit naturals when prior key ≠ 0 and new key = 0), `Sources/SheetMusicLayout/Layout/LayoutElement.swift` (carry naturals on `.keySignature`)
- Modify: `Sources/SheetMusicUI/Rendering/KeySignatureRenderer.swift` (draw them)
- Test: `Tests/SheetMusicTests/Layout/Engraving/KeySignatureStepsTests.swift` (extend) + a placement-level test beside the existing key-signature layout tests

**Interfaces:**
- Produces: `LayoutElement.keySignature` gains a `naturals: [...]` component (same step type the sharps/flats use — extend `KeySignatureSteps` with `naturalSteps(cancelling priorKey: Int, clef:)` returning the outgoing key's glyph positions in its own accidental order). Emission rule, exactly: an explicit `.keySignature` element whose resolved key is 0 while the key previously in force was non-zero renders the prior key's positions as natural glyphs (and nothing else); every other key change renders only the new signature. Applies wherever an explicit key signature is emitted mid-score (header path at a change measure, and mid-measure `timedX` path). Width scheduling includes the naturals' advance.

- [ ] **Step 1: Write the failing tests** — `naturalSteps(cancelling: 3, clef: G)` returns the three sharp positions of A major in sharp order; a layout pass over a two-bar score with a G→C change at bar 1 produces a `.keySignature` element at bar 1 whose naturals are non-empty and whose sharps/flats are empty; a G→D change produces naturals-empty. Follow the existing suites' fixture style (they build scores and inspect `LayoutEngine` output).
- [ ] **Step 2: Run to verify failure**, implement, run to verify pass (`xcrun swift test --filter KeySignatureSteps` plus the placement suite).
- [ ] **Step 3: Full suite**, then commit (ssm): `git commit -m "feat: cancellation naturals when a key change lands on C"`.

---

### Task 9: ssm — end-of-system courtesy signatures (layout)

**Repo:** ssm

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift` (+ the system-breaking site — find where systems are cut: `rg -n "synthesizeLeadingKeySig" Sources/SheetMusicLayout` and work outward)
- Test: new layout tests beside Task 8's; `SM_LAYOUT_GOLDEN` re-baseline

**Interfaces:**
- Produces: when the measure OPENING the next system begins with an explicit `.keySignature`/`.timeSignature` whose `showCourtesy == true`, the current system's last measure gets trailing courtesy layout elements — key per staff (written key, same per-staff resolution the leading synthesis uses), time uniform; the naturals rule (Task 8) applies to a courtesy key too. Breaking reserves the courtesy width when deciding whether the next measure fits (same estimation style as the existing header-width scheduling — courtesy width added to the candidate system's trailing edge when its successor opens with a signature change). A change mid-system keeps rendering inline (already works; add a regression assertion).

- [ ] **Step 1: Write the failing tests** — force a system break before a change measure (narrow layout width so the change starts system 2) and assert: the last measure of system 1 emits a trailing `.keySignature`/`.timeSignature` layout element; with `showCourtesy = false` on the model element it does not; a mid-system change emits no courtesy.
- [ ] **Step 2: Run to verify failure**, implement (mirror `synthesizeLeadingKeySig`'s structure for the trailing side), run to verify pass.
- [ ] **Step 3: Layout golden re-baseline** — run with `SM_LAYOUT_GOLDEN=1`, inspect the digest diff (fixtures containing mid-piece signature changes will legitimately move; nothing else should), update the baseline, and name the moved fixtures in the commit message.
- [ ] **Step 4: Full suite**, commit (ssm): `git commit -m "feat: end-of-system courtesy signatures"`.

---

### Task 10: ssm — pickup measure in the blank-score factory

**Repo:** ssm

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Score+Blank.swift`
- Test: `Tests/SheetMusicTests/EditingTests/BlankScoreTests.swift` (extend)

**Interfaces:**
- Produces: `BlankScoreTemplate.pickup: Fraction?` (default `nil`), init parameter appended with default. When set: measure 0 of every staff gets `actualLength = pickup`, `irregular = true`, content one `.rest(duration: .measure)` (resolves through `actualLength`); `measureCount` still counts total bars INCLUDING the pickup; signatures stay on measure 0 as today.

- [ ] **Step 1: Write the failing tests** — factory sets `actualLength`/`irregular` on every staff's bar 0 and nowhere else; `displayedMeasureNumber` skips it (bar 1 displays as measure 1 — check the real API name in `Score+MeasureNumber.swift`); a pickup template round-trips through MSCX (`len` attribute survives — reuse the file's round-trip helper).
- [ ] **Step 2: Run to verify failure**, implement, run to verify pass, full suite.
- [ ] **Step 3: Commit** (ssm): `git commit -m "feat: anacrusis option in the blank-score factory"`.

---

### Task 11: folino — ScoreUI signature pickers + wizard rewire (free-form time, pickup row)

**Repo:** folino

**Files:**
- Create: `Packages/ScoreUI/Sources/ScoreUI/KeySignaturePicker.swift`, `Packages/ScoreUI/Sources/ScoreUI/TimeSignaturePicker.swift`
- Modify: `Packages/ScoreUI/Sources/ScoreUI/Resources/Localizable.xcstrings`
- Modify: `Packages/Features/Library/Sources/Library/NewScore/NewScoreForm.swift` (drop `keyChoices`/`timeChoices`; add `pickup: Fraction?` + `pickupChoices`)
- Modify: `Packages/Features/Library/Sources/Library/NewScore/NewScoreSheet.swift` (`layoutSection` rewires onto the ScoreUI pickers + pickup row; delete the private `keyLabel` and `timeChoiceIndex`)
- Modify: `Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings` (pickup keys)
- Test: `Packages/ScoreUI/Tests/ScoreUITests/SignaturePickerTests.swift` (create), `Packages/Features/Library/Tests/LibraryTests/NewScoreTests.swift` (extend)

**Interfaces:**
- Produces (ScoreUI, the `InstrumentCatalogPicker` contract — just the control, no chrome, no dismissal):

```swift
/// Circle-of-fifths key picker. Labels are verbatim note spellings ("C / Am", "B♭ / Gm") — engraving
/// vocabulary, deliberately not localized.
public struct KeySignaturePicker: View {
    public init(selection: Binding<Int>)          // KeySignature.concertKey, -7...7 offered as the 15 keys
}
public enum KeySignatureLabel {
    /// "C / Am"-style label for a concert key. Public so callers can caption a current value.
    public static func label(for concertKey: Int) -> String
}

/// Time-signature control: preset chips + free numerator (1–63) / denominator (1,2,4,8,16,32) steppers.
public struct TimeSignaturePicker: View {
    public init(numerator: Binding<Int>, denominator: Binding<Int>)
    public static let presets: [(Int, Int)]        // (4,4),(3,4),(2,4),(6,8),(12,8),(2,2),(5,4),(7,8),(9,8),(3,8)
}
```

- Produces (Library): `NewScoreForm.pickup: Fraction? = nil` flowing into `template()` (Task 10's parameter); `static func pickupChoices(numerator: Int, denominator: Int) -> [Fraction]` = multiples of `Fraction(1, max(8, denominator))` strictly less than the nominal duration; the form resets `pickup = nil` whenever the time signature changes to a value the current pickup no longer fits (pickup ≥ nominal).
- The 15-key widening: `KeySignaturePicker` offers −7…+7 (adds C♭/C♯ majors over the wizard's old 13) — the model and `respelledKey` already handle ±7.

- [ ] **Step 1: Write the failing tests.** ScoreUI: `KeySignatureLabel.label(for:)` snapshots for all 15 keys (exact strings — copy the wizard's existing `keyLabel` switch as the expected values, extended with `"C♭ / A♭m"` and `"C♯ / A♯m"`); `TimeSignaturePicker.presets` contains the 10 pairs. Library: `pickupChoices(numerator: 4, denominator: 4)` == `[1/8, 1/4, 3/8, 1/2, 5/8, 3/4, 7/8]` as `Fraction`s; a form with `pickup = 1/4` produces a `template()` whose `pickup == Fraction(1, 4)`; switching the form to 1/8 time clears the now-oversized pickup.
- [ ] **Step 2: Run to verify failure** (both packages' test commands).
- [ ] **Step 3: Implement.** Move the label switch verbatim from `NewScoreSheet` (it is folino code, not a port). `TimeSignaturePicker`: preset row as a horizontal wrap of selectable chips + two `Stepper`s bound to the numerator/denominator (denominator stepper steps through the allowed set, not ±1). Wizard `layoutSection`: `KeySignaturePicker(selection: $form.concertKey)`, `TimeSignaturePicker(numerator: $form.timeNumerator, denominator: $form.timeDenominator)`, then a pickup `Picker` over `[nil] + pickupChoices(...)` labeled `library.newScore.field.pickup` ("Pickup measure" / 「弱起（アウフタクト）」; the nil row is `L10n`-style "None" — check `Packages/Utility/Sources/UtilityUI/Localization.swift` for an existing "none" string before adding one). Fraction labels verbatim ("1/8", "3/8").
- [ ] **Step 4: Run to verify pass**; render the `NewScoreSheet` `#Preview` via `mcp__xcode__RenderPreview` and check the section reads correctly.
- [ ] **Step 5: Commit** (folino): `git commit -m "feat: shared signature pickers; wizard gains free-form meter and a pickup option"`.

---

### Task 12: folino Editor — signature intents on the view model

**Repo:** folino

**Files:**
- Create: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Signatures.swift`
- Test: `Packages/Features/Editor/Tests/EditorTests/EditorSignatureIntentTests.swift` (create — mirror the M1 measure-intent suite's use of the DEBUG `appliedIntents` seam; find it with `rg -l "appliedIntents" Packages/Features/Editor/Tests`)

**Interfaces:**
- Consumes: `EditorViewModel.apply(_:)`, `targetMeasureIndex`, `session?.lastRefusal`; ssm intents (Tasks 3/5); `Score.activeKey`, `Score.effectiveMeasureDuration(at:measureIndex:)`.
- Produces (all on `EditorViewModel`, in the new file):

```swift
public struct EditorTimeSignatureValue: Equatable {
    public var numerator: Int
    public var denominator: Int
}

extension EditorViewModel {
    /// Presentation flags for the two sheets — on the view model, not view-local, because the menu rows
    /// that raise them fold into the overflow ⋯ (the EditorInstrumentsSheet rule).
    public var isKeySignatureSheetPresented: Bool   // stored property added in EditorViewModel.swift
    public var isTimeSignatureSheetPresented: Bool  // (same pattern as isInstrumentsSheetPresented)

    /// The key/time in force at the target measure — what the sheets open showing. nil without a target.
    public var targetConcertKey: Int?
    public var targetTimeSignature: EditorTimeSignatureValue?
    /// Whether an EXPLICIT change of that kind sits at the target measure (> 0) — gates the Remove row.
    public var targetHasExplicitKeyChange: Bool
    public var targetHasExplicitTimeChange: Bool

    /// Apply from the target measure. All four return the apply result and leave refusal surfacing to
    /// the caller (the sheet reads `lastSignatureRefusal`).
    @discardableResult public func setKeySignature(concertKey: Int) -> Bool
    @discardableResult public func removeKeySignatureChange() -> Bool
    @discardableResult public func setTimeSignature(numerator: Int, denominator: Int) -> Bool
    @discardableResult public func removeTimeSignatureChange() -> Bool

    /// The refusal behind the last failed signature apply, already shaped for the alert: nil when the
    /// last apply succeeded. Cleared when a sheet opens.
    public var lastSignatureRefusal: EditRefusal?
    /// Analytics seam, wired at the composition root like onPartsEdited. (kind, action) vocabulary:
    /// ("key"|"time", "set"|"remove").
    public var onSignatureChanged: ((String, String) -> Void)?
}
```

`targetHasExplicitKeyChange`: scan the target measure's voice-0 leading prefix on the first non-percussion staff for `.keySignature` (time: staff 0, `.timeSignature`), false at measure 0. `targetConcertKey` = `score?.activeKey(...)`; `targetTimeSignature` from `effectiveMeasureDuration`'s governing signature — walk the same way `activeKey` does but for `.timeSignature` elements (add a small private helper here; do NOT reverse-derive from the `Fraction`, which conflates a pickup's `actualLength` with the meter).

- [ ] **Step 1: Write the failing tests** — via the `appliedIntents` seam: `setKeySignature(concertKey: -2)` with a selection in bar 2 appends `.setKeySignature(measureIndex: 2, concertKey: -2)`; all four map correspondingly; each is a no-op without a target; `targetHasExplicitKeyChange` is true exactly on a fixture bar carrying an inserted mid-piece key; a refused apply (fixture with a straddling triplet, `.setTimeSignature`) sets `lastSignatureRefusal` and leaves `appliedIntents`' success list unchanged; `onSignatureChanged` fires `("time","set")` on success and not on refusal.
- [ ] **Step 2: Run to verify failure** — Editor package test command.
- [ ] **Step 3: Implement** (stored flags land in `EditorViewModel.swift` beside `isInstrumentsSheetPresented`; everything else in the new file). Success path calls `onSignatureChanged` after `apply` returns true.
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit** (folino): `git commit -m "feat: signature-change surface on the editor view model"`.

---

### Task 13: folino Editor — menu rows, sheets, refusal alert, wiring, analytics

**Repo:** folino

**Files:**
- Modify: `Packages/Features/Editor/Sources/Editor/Screens/EditorTopBarView.swift` (`measureActionRows` + sheet attachments)
- Create: `Packages/Features/Editor/Sources/Editor/Views/EditorKeySignatureSheet.swift`, `Packages/Features/Editor/Sources/Editor/Views/EditorTimeSignatureSheet.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/Resources/Localizable.xcstrings`
- Modify: `Packages/Domain/Sources/Domain/Analytics/AnalyticsEvent+Factories.swift` (`scoreSignatureChanged(kind:action:)` — mirror `scorePartsEdited(action:)`)
- Modify: `App/EditableReaderScreen.swift` (wire `vm.onSignatureChanged` beside `onPartsEdited`)
- Test: `Packages/Domain/Tests/DomainTests/` — extend the analytics factory suite (find it via `rg -l "scorePartsEdited" Packages/Domain/Tests`)

**Interfaces:**
- Consumes: Task 12's view-model surface; `KeySignaturePicker` / `TimeSignaturePicker` / `KeySignatureLabel` (Task 11); `EditorInstrumentsSheet` as the structural template.
- Produces: two menu rows appended to `measureActionRows` (keys `editor.measure.keySignature` / `editor.measure.timeSignature`, disabled via the existing `targetMeasureIndex == nil` rule), two sheets attached at the strip root next to the instruments sheet.

Sheet anatomy (both): `NavigationStack` + `Form`. Header text: measure number (`displayedMeasureNumber` via the view model — expose a tiny `targetDisplayedMeasureNumber: Int?` helper if the M1 surface lacks one) + current value (`KeySignatureLabel.label(for:)` / verbatim `"n/d"`). One scope-explanation footer line (`editor.signature.scopeHint` — "Applies from this measure to the next change." / 「この小節から次の変更点までに適用されます」). Picker section (`KeySignaturePicker` / `TimeSignaturePicker` seeded from the target values). Confirmation-action "Apply" button calls the Task 12 setter; on `true` dismiss, on `false` stay open and present the refusal alert from `lastSignatureRefusal` (localized: `editor.signature.refusal.tuplet` 「◯小節目の連符が新しい小節線とぶつかるため変更できません」 with the measure number interpolated, `editor.signature.refusal.barline` for the marker case, `editor.signature.refusal.generic` fallback — map from the `EditRefusal.Reason` cases added in Task 4). A `Section` with a destructive "Remove change at this measure" row, visible only when `targetHasExplicitKeyChange` / `...TimeChange`, confirmed via `confirmationDialog` (removal re-bars — same caution as the instruments sheet's part delete), calling the remove setter.

- [ ] **Step 1: Write the failing analytics test** — `scoreSignatureChanged(kind: "time", action: "set")` produces the expected event name/parameters (mirror the `scorePartsEdited` test's shape).
- [ ] **Step 2: Run to verify failure; implement the factory; run to verify pass.**
- [ ] **Step 3: Build the UI.** Menu rows + sheets + xcstrings (all five locales; every key carries a `comment`; `Text("key", bundle: .module)` everywhere). Add the `// PARITY(android): M3 signature editing — Android needs the sheet UI; ssm logic is shared` marker at the sheet file head, then run `Scripts/parity-report.py` so the ledger regenerates (the pre-commit hook enforces it).
- [ ] **Step 4: Wire the app seam** — in `App/EditableReaderScreen.swift`, next to the `onPartsEdited` closure: `vm.onSignatureChanged = { kind, action in analytics.log(.scoreSignatureChanged(kind: kind, action: action)) }` (match the surrounding wiring's exact analytics-client spelling).
- [ ] **Step 5: Verify visually and in build.** `#Preview` each sheet and render via `mcp__xcode__RenderPreview`; then Editor package tests; then the full app build command. Check the previews show: pickers seeded with current values, Remove row present/absent per fixture, refusal alert text fitting.
- [ ] **Step 6: Commit** (folino): `git commit -m "feat: key/time signature editing from the measure menu"`.

---

### Task 14: integration verification (no new code)

**Repo:** both

- [ ] **Step 1: ssm full gates** — `xcrun swift test`; `Scripts/preflight.sh --apple --wasm --android` if not run since the last ssm change.
- [ ] **Step 2: folino** — Editor, Library, ScoreUI, Domain package test runs; full app build.
- [ ] **Step 3: Smoke script for the user** (manual, on the iPhone 17 Pro Max simulator): create a piano score with a 1/4 pickup in 4/4 → verify bar numbering; enter notes across two bars; change time to 3/4 at bar 0 → verify split+tie and undo; change time mid-piece at bar 3 → verify earlier bars untouched; add a triplet, attempt a conflicting change → verify the refusal alert names the bar; change key to C from G → verify naturals at the change point; narrow the window so a change opens a system → verify the courtesy at the previous system's tail; save, reopen, verify persistence.
- [ ] **Step 4: Report** — summarize deviations from this plan and anything deferred, for the memory update.

---

## Self-review notes (kept for executors)

- Spec §1–§9 → Tasks: showCourtesy/model (§2→T1), intents/commands (§3→T3,T5), re-bar (§4→T4,T5), key re-spell (§5→T2,T3), naturals (§6→T8), courtesy (§6→T9), anacrusis (§7→T10,T11), UI (§8→T11–T13), tests/corpus (§9→T6,T7, per-task suites). §10 (MIDI gap) is deliberately untouched.
- Wire indices: 19 `setKeySignature`, 20 `removeKeySignature`, 21 `setTimeSignature`, 22 `removeTimeSignature` — Tasks 3 and 5 must land in that order.
- `BlankScoreTemplate` init spellings in test code follow the M2 shape (`parts:`, `concertKey:`, `measureCount:`); if a fixture fails to compile, check `Sources/SheetMusicCore/Score/Score+Blank.swift` for the current parameter list rather than editing the factory.
- Layout tasks (T8/T9) assert against `LayoutEngine` output shapes — read the existing key-signature layout suites first and reuse their fixture helpers; the exact naturals-carrying representation on `LayoutElement.keySignature` may reasonably differ from the sketch as long as the renderer and tests agree.

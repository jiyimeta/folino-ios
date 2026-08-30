# M1: Solo/Piano Scratch Creation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A user can create a blank solo/piano score from the Library's + menu, have it open straight into an edit session, write notes with the existing pad, and grow/shrink it with measure append/insert/delete — the full create → edit → save → read loop.

**Architecture:** The heavy lifting lands in swift-sheet-music (ssm): a `Score.blank(_:)` factory plus `InsertMeasure`/`DeleteMeasure` edit commands surfaced as new `EditIntent` cases (Folino's Editor drives everything through `ScoreEditSession.apply(_ intent:)`). Folino gains a Domain `ScoreFileCreator` protocol + Infrastructure implementation that writes the factory's Score as `.mscx` and registers the library row, a minimal creation form in the Library feature, a `startInEditMode` pass-through on the Reader, and measure actions in the Editor chrome. No paywall in M1 (that is milestone M5).

**Tech Stack:** Swift 6.3, SwiftUI, swift-testing (`@Suite`/`@Test`/`#expect`), GRDB (existing), ssm `SheetMusicCore`/`SheetMusicMSCX`.

**Spec:** `docs/superpowers/specs/2026-08-26-scratch-score-creation-and-pro-design.md` (umbrella). M1 = its milestone table row 1.

## Global Constraints

- Two repos. **ssm work** happens in a dedicated ssm worktree at `~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music` (directory MUST be named `swift-sheet-music` — path-dependency identity). **Folino work** happens in the existing Folino worktree `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/scratch-creation-spec` (branch `worktree-scratch-creation-spec`).
- ssm host tests: `xcrun swift test --package-path <ssm-wt> --filter <SuiteName>`. Folino package tests: `xcodebuild test -scheme <Pkg> -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` from the package dir (`swift test` does NOT work in Folino). Always run builds/tests in the foreground and read the output before proceeding.
- New tests use swift-testing. Whole-value undo assertions (`#expect(editor.score == original)`) are the house style.
- No access modifier unless the symbol is used outside its module; ssm's factory/commands/intents ARE cross-module API and are `public`.
- MuseScore (`~/Developer/musescore/MuseScore`) is a behavioral reference ONLY — it is GPL; never port or translate its code.
- The ssm local pin (6 files: Folino `project.yml` + `Packages/{Domain,Infrastructure}/Package.swift` + `Packages/Features/{Reader,Library,Editor}/Package.swift`) stays UNCOMMITTED in the working tree. Feature commits must never include those 6 files or the generated `Folino.xcodeproj`.
- Commit messages: conventional prefix (`feat:`/`fix:`/`test:`/`docs:`), stage whole files only (`git add <paths>`, never `-p`).
- User-facing copy never says "Reader"/"Editor"/"Library"; the app name is lowercase `folino`. Wizard/menu strings are localized in every locale the target's `Localizable.xcstrings` already carries (en/ja/ko/zh-Hans).
- `EditIntent` case order is wire format: **append cases only, never reorder** (`EditIntent.swift:21` comment); same for `EditIntentWire` in `Sources/SheetMusicEditWire/Intent/EditIntentCodec.swift`.
- `Score.systemMeasures` must stay positionally parallel with every staff's `measures` (invariant at `Score.swift:14-17`); every measure-structure mutation maintains it.

---

### Task 0: Worktree + local pin setup

**Files:**
- Modify (leave uncommitted): `project.yml`, `Packages/Domain/Package.swift`, `Packages/Infrastructure/Package.swift`, `Packages/Features/Reader/Package.swift`, `Packages/Features/Editor/Package.swift`, `Packages/Features/Library/Package.swift`

- [ ] **Step 1: Create the ssm worktree** (base `origin/main`)

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music fetch origin
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music worktree add /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music -b feature/scratch-creation-m1 origin/main
```

- [ ] **Step 2: Point Folino at the ssm worktree**

Run `~/.claude/bin/ssm-local-pin.sh /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/scratch-creation-spec --path /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music`. The script only rewrites the url+exact → path direction; today's pins are `exact: "1.15.0"` so that direction applies. Then VERIFY all 6 files actually changed (`git diff --stat` must list project.yml + 5 Package.swift). If any file is unchanged, edit it by hand: replace the `.package(url: "https://github.com/jiyimeta/swift-sheet-music.git", exact: "1.15.0")` block with `.package(path: "/Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music")` (and in `project.yml`, the `url:`/`exactVersion:` pair with `path: ...`). Do not touch `MARKETING_VERSION`.

- [ ] **Step 3: Regenerate the project and verify resolution**

```bash
env -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/scratch-creation-spec xcodegen
env -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/scratch-creation-spec/Packages/Features/Editor xcodebuild -list
```

The second command's package resolution log must show `swift-sheet-music` resolving to the worktree path (`@ local`), not `@ 1.15.0`. Mixed pins fail with `required using two different requirements` — fix the straggler file.

---

### Task 1 (ssm): `Score.blank(_:)` factory

**Files:**
- Create: `Sources/SheetMusicCore/Score/Score+Blank.swift`
- Test: `Tests/SheetMusicTests/EditingTests/BlankScoreTests.swift`
- Modify: `CHANGELOG.md` (`## [Unreleased]` → Added)

**Interfaces:**
- Produces: `BlankScoreTemplate` (public struct) and `Score.blank(_:) -> Score`. Consumed by Folino's Library wizard (Task 7) via the `@_exported import SheetMusicCore` in Folino Domain.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SheetMusicTests/EditingTests/BlankScoreTests.swift
@testable import SheetMusicCore
import Testing

@Suite("Score.blank")
struct BlankScoreTests {
    private func pianoTemplate(measures: Int = 4) -> BlankScoreTemplate {
        BlankScoreTemplate(
            title: "My Piece", composer: "Me",
            instrumentID: "piano", instrumentName: "Piano",
            staves: [.init(clefType: "G"), .init(clefType: "F")],
            concertKey: 2, timeNumerator: 3, timeDenominator: 4,
            tempoBPM: 90, measureCount: measures,
        )
    }

    @Test("shape: parts, staves, parallel systemMeasures, signatures on every staff")
    func shape() {
        let score = Score.blank(pianoTemplate())
        #expect(score.division == 480)
        #expect(score.parts.count == 1)
        #expect(score.parts[0].staves.count == 2)
        #expect(score.systemMeasures.count == 4)
        for staff in score.parts[0].staves {
            #expect(staff.measures.count == 4)
            let first = staff.measures[0].voices[0].elements
            #expect(first[0] == .keySignature(KeySignature(concertKey: 2)))
            #expect(first[1] == .timeSignature(TimeSignature(numerator: 3, denominator: 4)))
            #expect(first[2].isMeasureRest)
            for measure in staff.measures.dropFirst() {
                #expect(measure.voices[0].elements == [.rest(duration: .measure)])
            }
        }
        #expect(score.parts[0].staves[0].defaultClefType == "G")
        #expect(score.parts[0].staves[1].defaultClefType == "F")
    }

    @Test("tempo lands on systemMeasures[0], grand staff gets a brace")
    func tempoAndBrace() {
        let score = Score.blank(pianoTemplate())
        let tempoElements = score.systemMeasures[0].elements
        #expect(tempoElements.count == 1)
        guard case let .tempo(tempo) = tempoElements[0].element else {
            Issue.record("expected a tempo"); return
        }
        #expect(abs(tempo.beatsPerSecond - 90.0 / 60.0) < 0.0001)
        #expect(score.parts[0].staves[0].brackets == [BracketItem(type: .brace, span: 2)])
        #expect(score.parts[0].staves[1].brackets.isEmpty)
    }

    @Test("metadata: metaTags and title frame")
    func metadata() {
        let score = Score.blank(pianoTemplate())
        #expect(score.metaTags["workTitle"] == "My Piece")
        #expect(score.metaTags["composer"] == "Me")
        let texts = score.titleFrame?.texts ?? []
        #expect(texts.contains(FrameText(style: .title, text: "My Piece")))
        #expect(texts.contains(FrameText(style: .composer, text: "Me")))
    }

    @Test("single-staff template omits brace, nil composer omits composer text")
    func singleStaff() {
        var template = pianoTemplate()
        template.staves = [.init(clefType: "G")]
        template.composer = nil
        let score = Score.blank(template)
        #expect(score.parts[0].staves[0].brackets.isEmpty)
        #expect(score.metaTags["composer"] == nil)
        #expect(!(score.titleFrame?.texts ?? []).contains { $0.style == .composer })
    }

    @Test("round-trips through the mscx encoder semantically")
    func roundTrip() throws {
        let score = Score.blank(pianoTemplate())
        let data = try MSCXEncoder.encode(score)
        let reparsed = try MSCXParser.parse(data)
        #expect(reparsed == score)
    }
}
```

Note: the round-trip test needs `import SheetMusicMSCX` and the parser's real entry point — mirror the invocation used by the existing encoder round-trip suite in `Tests/SheetMusicTests` (search `rg -l "MSCXEncoder.encode" Tests/`); the `==` contract is documented at `Sources/SheetMusicMSCX/MSCXEncoder.swift:8-10`. If exact `==` fails only on encoder-normalized fields (e.g. rewritten part IDs — `MSCXEncoder+Score.swift:18-22`), make the FACTORY emit the normalized form rather than weakening the test.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter BlankScoreTests`
Expected: FAIL — `BlankScoreTemplate` not found.

- [ ] **Step 3: Implement the factory**

```swift
// Sources/SheetMusicCore/Score/Score+Blank.swift

/// Everything needed to lay out an empty score: one part, one or more staves, a key/time/tempo, and N bars of
/// measure rest. The reduced instrument catalog arrives in a later milestone; until then callers pass the
/// instrument fields directly.
public struct BlankScoreTemplate: Sendable, Equatable {
    public struct StaffPlan: Sendable, Equatable {
        /// MuseScore clef-type token stored into `Staff.defaultClefType` ("G", "F", …).
        public var clefType: String
        public init(clefType: String) { self.clefType = clefType }
    }

    public var title: String
    public var composer: String?
    public var instrumentID: String
    public var instrumentName: String?
    public var staves: [StaffPlan]
    /// -7...7, sharps positive — `KeySignature.concertKey`.
    public var concertKey: Int
    public var timeNumerator: Int
    public var timeDenominator: Int
    public var tempoBPM: Double
    public var measureCount: Int

    public init(
        title: String, composer: String? = nil,
        instrumentID: String, instrumentName: String? = nil,
        staves: [StaffPlan],
        concertKey: Int = 0, timeNumerator: Int = 4, timeDenominator: Int = 4,
        tempoBPM: Double = 120, measureCount: Int = 32,
    ) {
        self.title = title
        self.composer = composer
        self.instrumentID = instrumentID
        self.instrumentName = instrumentName
        self.staves = staves
        self.concertKey = concertKey
        self.timeNumerator = timeNumerator
        self.timeDenominator = timeDenominator
        self.tempoBPM = tempoBPM
        self.measureCount = max(1, measureCount)
    }
}

extension Score {
    /// Builds an empty, playable, encodable score from `template`. The first measure of every staff carries the
    /// key and time signature; every measure holds a single full-measure rest; `systemMeasures` is created in
    /// parallel with the tempo on measure 0.
    public static func blank(_ template: BlankScoreTemplate) -> Score {
        let firstMeasure = Measure(voices: [Voice(elements: [
            .keySignature(KeySignature(concertKey: template.concertKey)),
            .timeSignature(TimeSignature(
                numerator: template.timeNumerator,
                denominator: template.timeDenominator,
            )),
            .rest(duration: .measure),
        ])])
        let laterMeasure = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])

        let staves = template.staves.enumerated().map { index, plan in
            Staff(
                defaultClefType: plan.clefType,
                brackets: index == 0 && template.staves.count > 1
                    ? [BracketItem(type: .brace, span: template.staves.count)]
                    : [],
                measures: [firstMeasure] + Array(repeating: laterMeasure, count: template.measureCount - 1),
            )
        }

        var systemMeasures = Array(repeating: SystemMeasure(), count: template.measureCount)
        systemMeasures[0] = SystemMeasure(elements: [PositionedSystemElement(
            position: .start,
            element: .tempo(Tempo(beatsPerSecond: template.tempoBPM / 60.0)),
        )])

        var metaTags = ["workTitle": template.title]
        var frameTexts = [FrameText(style: .title, text: template.title)]
        if let composer = template.composer {
            metaTags["composer"] = composer
            frameTexts.append(FrameText(style: .composer, text: composer))
        }

        return Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: template.instrumentID, longName: template.instrumentName),
                staves: staves,
            )],
            systemMeasures: systemMeasures,
            metaTags: metaTags,
            titleFrame: ScoreFrame(heightSp: 10, texts: frameTexts),
        )
    }
}
```

Check `SystemMeasure`'s memberwise init (`Sources/SheetMusicCore/Score/SystemMeasure.swift`) — if `SystemMeasure(elements:)` isn't the exact label, adapt. Same for `KeySignature(concertKey:)`/`TimeSignature(numerator:denominator:)` default args (both have `visible:` defaulted per their definitions).

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter BlankScoreTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Update CHANGELOG and commit**

Add under `## [Unreleased]` / `### Added`: `- \`Score.blank(_:)\` + \`BlankScoreTemplate\`: build an empty solo/grand-staff score in code.`

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music add Sources/SheetMusicCore/Score/Score+Blank.swift Tests/SheetMusicTests/EditingTests/BlankScoreTests.swift CHANGELOG.md
git -C /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music commit -m "feat: Score.blank factory for empty solo/grand-staff scores"
```

---

### Task 2 (ssm): `InsertMeasure` command

**Files:**
- Create: `Sources/SheetMusicCore/Editing/MeasureSlice.swift`, `Sources/SheetMusicCore/Editing/InsertMeasure.swift`, `Sources/SheetMusicCore/Editing/MeasureStructure.swift`
- Test: `Tests/SheetMusicTests/EditingTests/InsertMeasureTests.swift`
- Modify: `docs/edit-commands.md` (move `InsertMeasure` from planned to the "A. Implemented" table), `CHANGELOG.md`

**Interfaces:**
- Produces: `MeasureSlice` (capture type), `InsertMeasure(measureIndex:)` command, and internal helpers in `MeasureStructure.swift`: `MeasureStructure.blankColumn(for:) -> MeasureSlice`, `MeasureStructure.adjustSpannerOffsets(in:forInsertionAt:)`, `MeasureStructure.adjustSpannerOffsets(in:forDeletionAt:)`, `MeasureStructure.leadingSignaturePrefix(of:) -> [VoiceElement]`. Task 3's `DeleteMeasure` consumes all of these plus `InsertMeasure`'s internal `init(measureIndex:restoredContents:prependedNeighborCounts:)`.

**Semantics** (MuseScore-aligned):
- `measureIndex` ∈ `0...measureCount`; `== measureCount` appends. Out of range → refuse `.targetNotFound`.
- The new column is one blank measure per staff (`[Voice(elements: [.rest(duration: .measure)])]`) plus one `SystemMeasure()`.
- **Insert at 0 moves the score-start signatures**: the leading run of `.keySignature`/`.timeSignature`/`.clef` elements at the head of voice 0 of each staff's old first measure MOVES into the new first measure (before its rest). MuseScore keeps the initial signatures glued to the score start; verify the reference behavior in `~/Developer/musescore/MuseScore` (`src/engraving/dom/edit.cpp`, `Score::insertMeasure`) before implementing — behavior only, no code porting.
- Spanner fix-up: for every element `.spanner(s)` at measure `m` with `s.nextMeasuresOffset == k`, an insertion at index `i` with `m < i && i <= m + k` increments the stored offset by 1.
- Inverse: `DeleteMeasure(measureIndex:)` (Task 3 — until Task 3 lands, return a placeholder is NOT allowed; Tasks 2+3 are committed together, see Step 5).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SheetMusicTests/EditingTests/InsertMeasureTests.swift
@testable import SheetMusicCore
import Testing

@Suite("InsertMeasure")
struct InsertMeasureTests {
    private func twoBarScore() -> Score {
        // Grand staff, 2 measures, signatures on bar 1 — built via the Task 1 factory so the shape is canonical.
        Score.blank(BlankScoreTemplate(
            title: "t", instrumentID: "piano",
            staves: [.init(clefType: "G"), .init(clefType: "F")],
            concertKey: 1, timeNumerator: 4, timeDenominator: 4,
            tempoBPM: 120, measureCount: 2,
        ))
    }

    @Test("append grows every staff and systemMeasures in step")
    func append() throws {
        var score = twoBarScore()
        _ = try InsertMeasure(measureIndex: 2).apply(to: &score)
        #expect(score.systemMeasures.count == 3)
        for staff in score.parts[0].staves {
            #expect(staff.measures.count == 3)
            #expect(staff.measures[2].voices[0].elements == [.rest(duration: .measure)])
        }
    }

    @Test("insert at 0 moves the leading signatures into the new first bar")
    func insertAtZero() throws {
        var score = twoBarScore()
        _ = try InsertMeasure(measureIndex: 0).apply(to: &score)
        for staff in score.parts[0].staves {
            let newFirst = staff.measures[0].voices[0].elements
            #expect(newFirst[0] == .keySignature(KeySignature(concertKey: 1)))
            #expect(newFirst[1] == .timeSignature(TimeSignature(numerator: 4, denominator: 4)))
            #expect(newFirst[2].isMeasureRest)
            // The displaced old first bar keeps only its rest.
            #expect(staff.measures[1].voices[0].elements == [.rest(duration: .measure)])
        }
    }

    @Test("mid-piece insert leaves neighboring signatures attached to their measures")
    func insertMiddle() throws {
        var score = twoBarScore()
        _ = try InsertMeasure(measureIndex: 1).apply(to: &score)
        for staff in score.parts[0].staves {
            #expect(staff.measures[0].voices[0].elements.count == 3) // sigs stay on bar 1
            #expect(staff.measures[1].voices[0].elements == [.rest(duration: .measure)])
        }
    }

    @Test("apply returns an inverse that restores the exact score")
    func inverse() throws {
        for index in [0, 1, 2] {
            var score = twoBarScore()
            let original = score
            let inverse = try InsertMeasure(measureIndex: index).apply(to: &score)
            #expect(score != original)
            _ = try inverse.apply(to: &score)
            #expect(score == original, "index \(index)")
        }
    }

    @Test("out-of-range index refuses")
    func outOfRange() {
        var score = twoBarScore()
        #expect(throws: SheetMusicError.self) {
            try InsertMeasure(measureIndex: 5).apply(to: &score)
        }
    }
}
```

Also add a spanner-offset test once you have inspected `Spanner`'s init (`Sources/SheetMusicCore/Score/Spanner.swift`): build a two-bar score, place a `.spanner` with `nextMeasuresOffset: 1` in bar 0 of staff (0,0), insert at index 1, and `#expect` the stored offset became 2 (and the inverse restores 1).

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter InsertMeasureTests`
Expected: FAIL — `InsertMeasure` not found.

- [ ] **Step 3: Implement**

```swift
// Sources/SheetMusicCore/Editing/MeasureSlice.swift

/// One measure column captured across every staff of every part, plus its `SystemMeasure` — the unit that
/// `DeleteMeasure` removes and its inverse restores verbatim.
public struct MeasureSlice: Sendable, Equatable {
    /// `staffMeasures[partIndex][staffIndexInPart]`.
    public var staffMeasures: [[Measure]]
    public var systemMeasure: SystemMeasure

    public init(staffMeasures: [[Measure]], systemMeasure: SystemMeasure) {
        self.staffMeasures = staffMeasures
        self.systemMeasure = systemMeasure
    }
}
```

```swift
// Sources/SheetMusicCore/Editing/MeasureStructure.swift

/// Shared mechanics for the measure-structure commands (`InsertMeasure` / `DeleteMeasure`).
enum MeasureStructure {
    /// The signature kinds that belong to the score start and travel with it when bar 1 changes identity.
    static func isLeadingSignature(_ element: VoiceElement) -> Bool {
        switch element {
        case .keySignature, .timeSignature, .clef: true
        default: false
        }
    }

    /// The run of leading signature elements at the head of `voice`'s element list.
    static func leadingSignaturePrefix(of voice: Voice) -> [VoiceElement] {
        Array(voice.elements.prefix(while: isLeadingSignature))
    }

    static func measureCount(of score: Score) -> Int {
        score.parts.first?.staves.first?.measures.count ?? 0
    }

    static func blankColumn(for score: Score) -> MeasureSlice {
        MeasureSlice(
            staffMeasures: score.parts.map { part in
                part.staves.map { _ in Measure(voices: [Voice(elements: [.rest(duration: .measure)])]) }
            },
            systemMeasure: SystemMeasure(),
        )
    }

    /// Spanners store a relative forward measure distance; a structural change between a spanner's anchor and its
    /// end must stretch or shrink that distance.
    static func adjustSpannerOffsets(in score: inout Score, forInsertionAt index: Int) {
        adjustSpannerOffsets(in: &score) { anchorMeasure, offset in
            anchorMeasure < index && index <= anchorMeasure + offset ? offset + 1 : offset
        }
    }

    static func adjustSpannerOffsets(in score: inout Score, forDeletionAt index: Int) {
        adjustSpannerOffsets(in: &score) { anchorMeasure, offset in
            anchorMeasure < index && index <= anchorMeasure + offset ? offset - 1 : offset
        }
    }

    private static func adjustSpannerOffsets(in score: inout Score, _ transform: (Int, Int) -> Int) {
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                for measureIndex in score.parts[partIndex].staves[staffIndex].measures.indices {
                    for voiceIndex in score.parts[partIndex].staves[staffIndex].measures[measureIndex].voices.indices {
                        let elements = score.parts[partIndex].staves[staffIndex].measures[measureIndex]
                            .voices[voiceIndex].elements
                        for elementIndex in elements.indices {
                            guard case var .spanner(spanner) = elements[elementIndex] else { continue }
                            spanner.nextMeasuresOffset =
                                transform(measureIndex, spanner.nextMeasuresOffset)
                            score.parts[partIndex].staves[staffIndex].measures[measureIndex]
                                .voices[voiceIndex].elements[elementIndex] = .spanner(spanner)
                        }
                    }
                }
            }
        }
    }
}
```

(Adapt the `.spanner` pattern match to `Spanner`'s real stored-property shape — check `Sources/SheetMusicCore/Score/Spanner.swift:33` first.)

```swift
// Sources/SheetMusicCore/Editing/InsertMeasure.swift

/// Inserts one measure column — one blank bar in every staff plus a parallel `SystemMeasure` — before
/// `measureIndex`; `measureIndex == measureCount` appends. Inserting at 0 moves the score-start signatures
/// (key / time / clef prefix of the old first bar) into the new first bar, mirroring MuseScore.
public struct InsertMeasure: EditCommand {
    public let measureIndex: Int
    /// Set only when this command is the inverse of a `DeleteMeasure`: the exact contents to restore.
    let restoredContents: MeasureSlice?
    /// Also inverse-only: how many merged signature elements `DeleteMeasure` prepended to the neighboring bar,
    /// per part/staff (same shape as `MeasureSlice.staffMeasures`) — stripped before reinserting the slice.
    let prependedNeighborCounts: [[Int]]?

    public init(measureIndex: Int) {
        self.measureIndex = measureIndex
        restoredContents = nil
        prependedNeighborCounts = nil
    }

    init(measureIndex: Int, restoredContents: MeasureSlice, prependedNeighborCounts: [[Int]]) {
        self.measureIndex = measureIndex
        self.restoredContents = restoredContents
        self.prependedNeighborCounts = prependedNeighborCounts
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        let count = MeasureStructure.measureCount(of: score)
        guard measureIndex >= 0, measureIndex <= count, !score.parts.isEmpty else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }

        // Restore path (inverse of a delete): strip the merged prefix the delete added, then reinsert verbatim.
        if let contents = restoredContents {
            if let counts = prependedNeighborCounts, measureIndex < count {
                for partIndex in score.parts.indices {
                    for staffIndex in score.parts[partIndex].staves.indices {
                        let strip = counts[partIndex][staffIndex]
                        guard strip > 0 else { continue }
                        score.parts[partIndex].staves[staffIndex].measures[measureIndex]
                            .voices[0].elements.removeFirst(strip)
                    }
                }
            }
            insert(contents, into: &score)
            return DeleteMeasure(measureIndex: measureIndex)
        }

        // Blank path.
        var column = MeasureStructure.blankColumn(for: score)
        if measureIndex == 0, count > 0 {
            for partIndex in score.parts.indices {
                for staffIndex in score.parts[partIndex].staves.indices {
                    let oldVoice = score.parts[partIndex].staves[staffIndex].measures[0].voices[0]
                    let prefix = MeasureStructure.leadingSignaturePrefix(of: oldVoice)
                    guard !prefix.isEmpty else { continue }
                    score.parts[partIndex].staves[staffIndex].measures[0].voices[0].elements
                        .removeFirst(prefix.count)
                    column.staffMeasures[partIndex][staffIndex].voices[0].elements
                        .insert(contentsOf: prefix, at: 0)
                }
            }
        }
        insert(column, into: &score)
        return DeleteMeasure(measureIndex: measureIndex)
    }

    private func insert(_ column: MeasureSlice, into score: inout Score) {
        MeasureStructure.adjustSpannerOffsets(in: &score, forInsertionAt: measureIndex)
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                score.parts[partIndex].staves[staffIndex].measures
                    .insert(column.staffMeasures[partIndex][staffIndex], at: measureIndex)
            }
        }
        if score.systemMeasures.count >= measureIndex {
            score.systemMeasures.insert(column.systemMeasure, at: measureIndex)
        }
    }
}
```

Note the `score.systemMeasures.count >= measureIndex` guard: fixtures exist whose `systemMeasures` is legitimately empty (`EditingFixtures` never sets it); inserting past its end would crash, and the invariant only binds scores that maintain it. Task 3's delete needs the matching guard.

- [ ] **Step 4: Run tests — the suite compiles only together with Task 3's `DeleteMeasure`**

`InsertMeasure` returns `DeleteMeasure`, so this task's Step 3 and Task 3's Step 3 must both exist before anything compiles. Implement Task 3 immediately after writing this file, then run both suites together (Task 3 Step 4). This is one logical unit split across two task descriptions for reviewability.

- [ ] **Step 5: Commit — deferred to Task 3 Step 5** (single commit for the command pair).

---

### Task 3 (ssm): `DeleteMeasure` command

**Files:**
- Create: `Sources/SheetMusicCore/Editing/DeleteMeasure.swift`
- Test: `Tests/SheetMusicTests/EditingTests/DeleteMeasureTests.swift`
- Modify: `Sources/SheetMusicCore/Editing/EditRefusal.swift`, `docs/edit-commands.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: `MeasureSlice`, `MeasureStructure.*`, `InsertMeasure.init(measureIndex:restoredContents:prependedNeighborCounts:)` from Task 2.
- Produces: `DeleteMeasure(measureIndex:)`, new refusal `EditRefusal.Reason.cannotDeleteOnlyMeasure`.

**Semantics:**
- Refuse `.targetNotFound` out of range; refuse `.cannotDeleteOnlyMeasure` when `measureCount == 1` (a score must keep at least one bar — the factory, layout, and editor all assume it).
- Deleting bar 0 must not lose the score-start signatures: for each of the kinds key/time/clef, if the deleted bar's leading prefix has one and the incoming first bar's own leading prefix does NOT have that kind, prepend the deleted bar's element to the incoming bar (preserving key→time→clef relative order). Record how many elements were prepended per staff — the inverse strips exactly those before restoring the slice. (MuseScore reference: `Score::deleteMeasures` keeps initial clef/key/time on the new first measure unless it declares its own.)
- Spanner fix-up via `MeasureStructure.adjustSpannerOffsets(in:forDeletionAt:)` — run BEFORE removing the column so anchors count in pre-delete indices, matching the insert direction.
- Inverse: `InsertMeasure(measureIndex:restoredContents:prependedNeighborCounts:)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SheetMusicTests/EditingTests/DeleteMeasureTests.swift
@testable import SheetMusicCore
import Testing

@Suite("DeleteMeasure")
struct DeleteMeasureTests {
    private func threeBarScore() -> Score {
        Score.blank(BlankScoreTemplate(
            title: "t", instrumentID: "piano",
            staves: [.init(clefType: "G"), .init(clefType: "F")],
            concertKey: -2, timeNumerator: 6, timeDenominator: 8,
            tempoBPM: 120, measureCount: 3,
        ))
    }

    @Test("delete shrinks every staff and systemMeasures in step")
    func deleteMiddle() throws {
        var score = threeBarScore()
        _ = try DeleteMeasure(measureIndex: 1).apply(to: &score)
        #expect(score.systemMeasures.count == 2)
        for staff in score.parts[0].staves {
            #expect(staff.measures.count == 2)
        }
    }

    @Test("deleting bar 0 carries the signatures onto the new first bar")
    func deleteFirst() throws {
        var score = threeBarScore()
        _ = try DeleteMeasure(measureIndex: 0).apply(to: &score)
        for staff in score.parts[0].staves {
            let first = staff.measures[0].voices[0].elements
            #expect(first[0] == .keySignature(KeySignature(concertKey: -2)))
            #expect(first[1] == .timeSignature(TimeSignature(numerator: 6, denominator: 8)))
            #expect(first[2].isMeasureRest)
        }
    }

    @Test("a first bar with its own signature kind keeps it over the deleted one")
    func deleteFirstWithOwnKey() throws {
        var score = threeBarScore()
        // Give bar 1 its own key change; deleting bar 0 must keep it and only inherit the time signature.
        for staffIndex in score.parts[0].staves.indices {
            score.parts[0].staves[staffIndex].measures[1].voices[0].elements
                .insert(.keySignature(KeySignature(concertKey: 3)), at: 0)
        }
        _ = try DeleteMeasure(measureIndex: 0).apply(to: &score)
        for staff in score.parts[0].staves {
            let first = staff.measures[0].voices[0].elements
            #expect(first.contains(.keySignature(KeySignature(concertKey: 3))))
            #expect(!first.contains(.keySignature(KeySignature(concertKey: -2))))
            #expect(first.contains(.timeSignature(TimeSignature(numerator: 6, denominator: 8))))
        }
    }

    @Test("inverse restores the exact score, including the bar-0 signature merge")
    func inverse() throws {
        for index in [0, 1, 2] {
            var score = threeBarScore()
            let original = score
            let inverse = try DeleteMeasure(measureIndex: index).apply(to: &score)
            _ = try inverse.apply(to: &score)
            #expect(score == original, "index \(index)")
        }
    }

    @Test("deleting the only measure refuses")
    func lastMeasure() {
        var score = Score.blank(BlankScoreTemplate(
            title: "t", instrumentID: "piano", staves: [.init(clefType: "G")], measureCount: 1,
        ))
        #expect(throws: SheetMusicError.self) {
            try DeleteMeasure(measureIndex: 0).apply(to: &score)
        }
    }

    @Test("delete → undo → redo converges")
    func redoConverges() throws {
        var score = threeBarScore()
        let afterDeleteInverse = try DeleteMeasure(measureIndex: 0).apply(to: &score)
        let afterDelete = score
        let redo = try afterDeleteInverse.apply(to: &score) // undo
        _ = try redo.apply(to: &score)                       // redo
        #expect(score == afterDelete)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter DeleteMeasureTests`
Expected: FAIL — `DeleteMeasure` not found.

- [ ] **Step 3: Implement**

Add to `EditRefusal.Reason` (append the case before `unexpected`, and to `code` / `developerDescription`):

```swift
case cannotDeleteOnlyMeasure
// code: "cannot_delete_only_measure"
// developerDescription: "a score must keep at least one measure"
```

```swift
// Sources/SheetMusicCore/Editing/DeleteMeasure.swift

/// Removes one measure column — the bar at `measureIndex` in every staff plus its `SystemMeasure`. Deleting
/// bar 0 re-homes the score-start signatures onto the new first bar (each of key / time / clef only when that
/// bar doesn't declare its own), mirroring MuseScore. The inverse restores the captured column verbatim.
public struct DeleteMeasure: EditCommand {
    public let measureIndex: Int

    public init(measureIndex: Int) {
        self.measureIndex = measureIndex
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        let count = MeasureStructure.measureCount(of: score)
        guard measureIndex >= 0, measureIndex < count, !score.parts.isEmpty else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        guard count > 1 else {
            throw Self.refused(.cannotDeleteOnlyMeasure)
        }

        let slice = MeasureSlice(
            staffMeasures: score.parts.map { part in
                part.staves.map { $0.measures[measureIndex] }
            },
            systemMeasure: score.systemMeasures.indices.contains(measureIndex)
                ? score.systemMeasures[measureIndex] : SystemMeasure(),
        )

        MeasureStructure.adjustSpannerOffsets(in: &score, forDeletionAt: measureIndex)
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                score.parts[partIndex].staves[staffIndex].measures.remove(at: measureIndex)
            }
        }
        if score.systemMeasures.indices.contains(measureIndex) {
            score.systemMeasures.remove(at: measureIndex)
        }

        // Re-home the score-start signatures when bar 0 was deleted.
        var prependedCounts = score.parts.map { $0.staves.map { _ in 0 } }
        if measureIndex == 0 {
            for partIndex in score.parts.indices {
                for staffIndex in score.parts[partIndex].staves.indices {
                    let deletedPrefix = MeasureStructure
                        .leadingSignaturePrefix(of: slice.staffMeasures[partIndex][staffIndex].voices[0])
                    guard !deletedPrefix.isEmpty else { continue }
                    let incoming = score.parts[partIndex].staves[staffIndex].measures[0].voices[0]
                    let incomingPrefix = MeasureStructure.leadingSignaturePrefix(of: incoming)
                    let inherited = deletedPrefix.filter { element in
                        !incomingPrefix.contains { sameSignatureKind($0, element) }
                    }
                    guard !inherited.isEmpty else { continue }
                    score.parts[partIndex].staves[staffIndex].measures[0].voices[0].elements
                        .insert(contentsOf: inherited, at: 0)
                    prependedCounts[partIndex][staffIndex] = inherited.count
                }
            }
        }

        return InsertMeasure(
            measureIndex: measureIndex,
            restoredContents: slice,
            prependedNeighborCounts: prependedCounts,
        )
    }

    private func sameSignatureKind(_ lhs: VoiceElement, _ rhs: VoiceElement) -> Bool {
        switch (lhs, rhs) {
        case (.keySignature, .keySignature), (.timeSignature, .timeSignature), (.clef, .clef): true
        default: false
        }
    }
}
```

- [ ] **Step 4: Run both suites (plus the whole editing group as regression)**

Run: `xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter "InsertMeasureTests|DeleteMeasureTests|ScoreEditorTests"`
Expected: PASS.

- [ ] **Step 5: Update docs and commit the command pair**

`docs/edit-commands.md`: add `InsertMeasure` / `DeleteMeasure` rows to table "A. Implemented" (follow the existing row format), and remove/annotate the corresponding planned item near line 93.

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music add Sources/SheetMusicCore/Editing/MeasureSlice.swift Sources/SheetMusicCore/Editing/MeasureStructure.swift Sources/SheetMusicCore/Editing/InsertMeasure.swift Sources/SheetMusicCore/Editing/DeleteMeasure.swift Sources/SheetMusicCore/Editing/EditRefusal.swift Tests/SheetMusicTests/EditingTests/InsertMeasureTests.swift Tests/SheetMusicTests/EditingTests/DeleteMeasureTests.swift docs/edit-commands.md CHANGELOG.md
git -C /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music commit -m "feat: InsertMeasure / DeleteMeasure structural edit commands"
```

---

### Task 4 (ssm): `EditIntent` cases + wire codec

**Files:**
- Modify: `Sources/SheetMusicCore/Editing/EditIntent.swift`, `Sources/SheetMusicCore/Editing/ScoreEditSession.swift`, `Sources/SheetMusicEditWire/Intent/EditIntentCodec.swift`
- Test: `Tests/SheetMusicTests/EditingTests/ScoreEditSessionMeasureTests.swift` (new), plus extend the existing `EditIntentCodec` round-trip test file (locate with `rg -l "EditIntentWire" Tests/`)

**Interfaces:**
- Produces: `EditIntent.insertMeasure(at: Int)` and `EditIntent.deleteMeasure(at: Int)`, planned by `ScoreEditSession` into the Task 2/3 commands. Folino's `EditorViewModel.apply(_ intent:)` (Task 9) consumes these.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SheetMusicTests/EditingTests/ScoreEditSessionMeasureTests.swift
@testable import SheetMusicCore
import Testing

@MainActor
@Suite("ScoreEditSession measure intents")
struct ScoreEditSessionMeasureTests {
    private func session() -> ScoreEditSession {
        ScoreEditSession(score: Score.blank(BlankScoreTemplate(
            title: "t", instrumentID: "piano", staves: [.init(clefType: "G")], measureCount: 2,
        )))
    }

    @Test("insertMeasure applies and undoes")
    func insertMeasure() {
        let session = session()
        let original = session.score
        #expect(session.apply(.insertMeasure(at: 2)))
        #expect(session.score.parts[0].staves[0].measures.count == 3)
        #expect(session.undo())
        #expect(session.score == original)
    }

    @Test("deleteMeasure applies and undoes")
    func deleteMeasure() {
        let session = session()
        let original = session.score
        #expect(session.apply(.deleteMeasure(at: 0)))
        #expect(session.score.parts[0].staves[0].measures.count == 1)
        #expect(session.undo())
        #expect(session.score == original)
    }

    @Test("deleteMeasure on the only bar refuses with a recorded refusal")
    func refusalSurfaces() {
        let session = ScoreEditSession(score: Score.blank(BlankScoreTemplate(
            title: "t", instrumentID: "piano", staves: [.init(clefType: "G")], measureCount: 1,
        )))
        #expect(!session.apply(.deleteMeasure(at: 0)))
        #expect(session.lastRefusal?.reason == .cannotDeleteOnlyMeasure)
    }
}
```

If `ScoreEditSession` is not `@MainActor`, drop the attribute — mirror `ScoreEditorTests.swift`'s isolation. Check `ScoreEditSession.score`'s access path (the Folino VM reads it, so it is public — mirror how `ScoreEditSessionTests` reads it if a wrapper property is used).

- [ ] **Step 2: Run to verify failure**

Run: `xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter ScoreEditSessionMeasureTests`
Expected: FAIL — `EditIntent` has no member `insertMeasure`.

- [ ] **Step 3: Implement**

Append to `EditIntent` (AFTER `.writeRest`, never mid-enum):

```swift
    /// Insert a blank measure column before `index`; `index == measureCount` appends at the end.
    case insertMeasure(at: Int)
    /// Delete the measure column at `index`.
    case deleteMeasure(at: Int)
```

In `ScoreEditSession`'s private `command(for:in:depth:)` (`ScoreEditSession.swift:117`), add:

```swift
        case let .insertMeasure(index):
            return InsertMeasure(measureIndex: index)
        case let .deleteMeasure(index):
            return DeleteMeasure(measureIndex: index)
```

In `EditIntentCodec.swift`, append the two cases to `EditIntentWire` following the file's existing encode/decode pattern exactly (each case gets the next wire index; the payload is one `Int`). The compiler's exhaustive switches will point at every site to extend.

- [ ] **Step 4: Run the editing + wire suites**

Run: `xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter "ScoreEditSessionMeasureTests|EditIntent"`
Expected: PASS, including the extended codec round-trip cases you added for the two new intents.

- [ ] **Step 5: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music add -A Sources/SheetMusicCore/Editing Sources/SheetMusicEditWire Tests CHANGELOG.md
git -C /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music commit -m "feat: insertMeasure / deleteMeasure edit intents with wire codec support"
```

---

### Task 5 (Folino): `FileFacts.hashAndSize` in UtilityCore

**Files:**
- Create: `Packages/Utility/Sources/UtilityCore/FileFacts.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorFileFacts.swift` (delegate to the new helper)
- Test: `Packages/Utility/Tests/UtilityCoreTests/FileFactsTests.swift`

**Interfaces:**
- Produces: `FileFacts.hashAndSize(of: URL) throws -> (contentHash: String, sizeBytes: Int64)` (SHA-256 hex + byte count). Consumed by Task 6's `LiveScoreFileCreator` and by the Editor's existing save path.

- [ ] **Step 1: Write the failing test**

```swift
// Packages/Utility/Tests/UtilityCoreTests/FileFactsTests.swift
import Foundation
import Testing
@testable import UtilityCore

@Suite("FileFacts")
struct FileFactsTests {
    @Test("hashAndSize returns the SHA-256 hex digest and byte count")
    func hashAndSize() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "filefacts-\(UUID().uuidString).bin")
        try Data("folino".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let facts = try FileFacts.hashAndSize(of: url)
        #expect(facts.sizeBytes == 6)
        // echo -n folino | shasum -a 256
        #expect(facts.contentHash == "1a6f2354cbd6013ffbaa4b1e330a89561ab6b7b8ac7ea0dcbf158b463119b0ba")
    }
}
```

Compute the literal digest yourself before committing (`echo -n folino | shasum -a 256`) and paste the real value — do not trust the one above without checking.

- [ ] **Step 2: Run to verify failure**

Run (from `Packages/Utility`): `xcodebuild test -scheme UtilityCore -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:UtilityCoreTests/FileFactsTests`
Expected: FAIL — `FileFacts` not found. (If the scheme is named differently, `xcodebuild -list` from the package dir and use the package or target scheme that exists.)

- [ ] **Step 3: Implement**

Port the body of the Editor's existing `EditorFileFacts.hashAndSize` (`Packages/Features/Editor/Sources/Editor/EditorFileFacts.swift:7`) into:

```swift
// Packages/Utility/Sources/UtilityCore/FileFacts.swift
import CryptoKit
import Foundation

/// File identity facts the library rows persist: content hash + size. One definition — the importer, the
/// editor's save path, and score creation must all agree byte-for-byte on how these are computed.
public enum FileFacts {
    public static func hashAndSize(of url: URL) throws -> (contentHash: String, sizeBytes: Int64) {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return (hash, Int64(data.count))
    }
}
```

Use the EXISTING Editor implementation's exact algorithm (streaming vs whole-file, hex casing) — read it first and copy the semantics; the row `contentHash` values must stay comparable across all writers. Then reduce `EditorFileFacts.hashAndSize` to `try FileFacts.hashAndSize(of: url)` (Editor's `Package.swift` already depends on `UtilityCore`; if not, add the product dependency to the Editor target). Leave `LiveScoreFileImporter`'s private copy alone in this task — swapping it is a pure refactor with CloudKit-adjacent blast radius; note it as a follow-up comment instead.

- [ ] **Step 4: Run Utility + Editor tests**

Run the Task 5 Step 2 command again (expect PASS), then from `Packages/Features/Editor`: `xcodebuild test -scheme Editor -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`
Expected: PASS — the Editor's persistence tests still agree on hashes.

- [ ] **Step 5: Commit**

```bash
git add Packages/Utility/Sources/UtilityCore/FileFacts.swift Packages/Utility/Tests/UtilityCoreTests/FileFactsTests.swift Packages/Features/Editor/Sources/Editor/EditorFileFacts.swift
git commit -m "feat: shared FileFacts.hashAndSize in UtilityCore"
```

---

### Task 6 (Folino): `ScoreFileCreator` protocol + Live implementation

**Files:**
- Create: `Packages/Domain/Sources/Domain/Protocols/ScoreFileCreator.swift`, `Packages/Infrastructure/Sources/Persistence/LiveScoreFileCreator.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/LiveScoreFileCreatorTests.swift`

**Interfaces:**
- Consumes: `Score.blank` output (any `Score`), `ScoreFileGateway.saveScore(_:fileURL:format:)`, `ScoreLibraryRepository.saveScoreItem(_:)`, `FileFacts.hashAndSize(of:)`, `ScoreFileSummary(score:)` (`Packages/Infrastructure/Sources/ScoreFiles/ScoreFileSummary+Score.swift:8`).
- Produces:

```swift
public protocol ScoreFileCreator: Sendable {
    /// Writes `score` as a new `.mscx` file in the library and registers its row. Returns the created item.
    func createScore(_ score: Score) async throws -> ScoreItem
}
```

- [ ] **Step 1: Write the failing test**

Follow the existing Infrastructure test setup for a tmpdir + repository (find the pattern with `rg -l "saveScoreItem" Packages/Infrastructure/Tests/` and mirror how those tests construct their repository — real GRDB on a temp db if that is what they do; a hand-rolled in-memory fake conforming to `ScoreLibraryRepository` if one already exists in the test target).

```swift
// Packages/Infrastructure/Tests/InfrastructureTests/LiveScoreFileCreatorTests.swift
import Domain
import Foundation
@testable import Persistence
import ScoreFiles
import Testing

@Suite("LiveScoreFileCreator")
struct LiveScoreFileCreatorTests {
    @Test("writes the mscx, registers the row, and derives metadata from the score")
    func createScore() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "creator-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = /* mirror the existing repository test setup */
        let creator = LiveScoreFileCreator(
            gateway: LiveScoreFileGateway(), repository: repository, scoresDirectory: dir,
        )

        let score = Score.blank(BlankScoreTemplate(
            title: "Test Piece", composer: "Someone", instrumentID: "piano",
            staves: [.init(clefType: "G")], tempoBPM: 90, measureCount: 8,
        ))
        let item = try await creator.createScore(score)

        #expect(item.title == "Test Piece")
        #expect(item.composer == "Someone")
        #expect(item.localFileName == "\(item.id.rawValue.uuidString).mscx")
        let fileURL = dir.appending(path: item.localFileName)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        let facts = try FileFacts.hashAndSize(of: fileURL)
        #expect(item.contentHash == facts.contentHash)
        #expect(item.sizeBytes == facts.sizeBytes)
        // Row landed:
        // assert via the repository the same way existing repository tests read rows back.
    }

    @Test("a failed row save removes the orphaned file")
    func rollbackOnRowFailure() async throws {
        // Use a throwing repository stub; assert the .mscx no longer exists afterwards.
    }
}
```

Fill the two `/* … */` holes from the real precedent before running — they are setup mechanics, not design decisions; the design under test is fully specified above.

- [ ] **Step 2: Run to verify failure**

From `Packages/Infrastructure`: `xcodebuild test -scheme Infrastructure -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/LiveScoreFileCreatorTests`
Expected: FAIL — `LiveScoreFileCreator` not found. (Adjust scheme name via `xcodebuild -list`.)

- [ ] **Step 3: Implement**

```swift
// Packages/Domain/Sources/Domain/Protocols/ScoreFileCreator.swift

/// Creates a brand-new score in the library from an in-memory `Score` — the scratch-creation counterpart of
/// `ScoreFileImporter`. No duplicate detection: a freshly built score is never a duplicate.
public protocol ScoreFileCreator: Sendable {
    /// Writes `score` as a new `.mscx` file in the library and registers its row. Returns the created item.
    func createScore(_ score: Score) async throws -> ScoreItem
}
```

```swift
// Packages/Infrastructure/Sources/Persistence/LiveScoreFileCreator.swift
import Domain
import Foundation
import UtilityCore

public struct LiveScoreFileCreator: ScoreFileCreator {
    private let gateway: any ScoreFileGateway
    private let repository: any ScoreLibraryRepository
    private let scoresDirectory: URL

    public init(
        gateway: any ScoreFileGateway,
        repository: any ScoreLibraryRepository,
        scoresDirectory: URL,
    ) {
        self.gateway = gateway
        self.repository = repository
        self.scoresDirectory = scoresDirectory
    }

    public func createScore(_ score: Score) async throws -> ScoreItem {
        let id = ScoreItemID()
        let fileName = "\(id.rawValue.uuidString).mscx"
        let fileURL = scoresDirectory.appending(path: fileName)
        try await gateway.saveScore(score, fileURL: fileURL, format: .mscx)

        do {
            let facts = try FileFacts.hashAndSize(of: fileURL)
            let summary = ScoreFileSummary(score: score)
            let item = ScoreItem(
                id: id,
                title: summary.title ?? "",
                subtitle: summary.subtitle,
                composer: summary.composer,
                arranger: summary.arranger,
                lyricist: summary.lyricist,
                copyright: summary.copyright,
                instrumentationSummary: summary.instrumentationSummary,
                localFileName: fileName,
                contentHash: facts.contentHash,
                sizeBytes: facts.sizeBytes,
                lengthBeats: summary.lengthBeats,
                defaultTempoBpm: summary.defaultTempoBpm,
                primaryKey: summary.primaryKey,
                addedAt: Date(),
                lastOpenedAt: nil,
                tagIDs: [],
                isFavorite: false,
                museScoreMajorVersion: summary.museScoreMajorVersion,
                sourcePDFFileName: nil,
                sourcePDFContentHash: nil,
                pdfDerivedContentHash: nil,
                pdfConversionFailed: false,
            )
            try await repository.saveScoreItem(item)
            return item
        } catch {
            // Same rule as the importer: never leave a file no row points at.
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }
}
```

Adaptations to verify against the real code, not guess: (a) `ScoreFileSummary` field names and whether `title` is optional (`ScoreFileSummary+Score.swift` + the struct's definition in Domain); (b) `ScoreItem.init`'s exact parameter list — mirror `LiveScoreFileImporter.swift:128-152` including the PDF trio labels; (c) whether `ScoreLibraryRepository` being `@MainActor` forces this type to be `@MainActor` or the calls to hop — mirror `LiveScoreFileImporter`'s isolation annotations exactly; (d) `ScoreFileSummary(score:)` lives in the `ScoreFiles` module — if `Persistence` doesn't already depend on it, put `LiveScoreFileCreator.swift` in `Sources/ScoreFiles/` instead and adjust the test's `@testable import`.

- [ ] **Step 4: Run to verify pass**

Task 6 Step 2 command. Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Protocols/ScoreFileCreator.swift Packages/Infrastructure/Sources Packages/Infrastructure/Tests/InfrastructureTests/LiveScoreFileCreatorTests.swift
git commit -m "feat: ScoreFileCreator protocol with mscx-writing live implementation"
```

---

### Task 7 (Folino): Library "New score" form + view-model flow

**Files:**
- Create: `Packages/Features/Library/Sources/Library/NewScore/NewScoreForm.swift`, `Packages/Features/Library/Sources/Library/NewScore/NewScoreSheet.swift`
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift` (new dependency + creation flow), `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift` (menu row), `Packages/Features/Library/Sources/Library/Screens/LibraryRootPresentations.swift` (sheet), `Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings`, `Packages/Domain/Sources/Domain/Analytics/AnalyticsEvent+Factories.swift` (`scoreCreated` event), `App/AppShellView.swift` (inject creator)
- Test: `Packages/Features/Library/Tests/LibraryTests/NewScoreTests.swift`

**Interfaces:**
- Consumes: `ScoreFileCreator` (Task 6), `Score.blank`/`BlankScoreTemplate` (Task 1, visible through Domain's `@_exported import SheetMusicCore`).
- Produces: `NewScoreForm` (form state → `BlankScoreTemplate`), `LibraryViewModel.isNewScoreSheetPresented: Bool`, `LibraryViewModel.createScore(from:) async`, `LibraryViewModel.pendingOpenInEditSession: Bool` (read by Task 8's App wiring alongside the existing `pendingScoreToOpen`).

**Form model** — M1 presets stand in for the M2 instrument catalog:

```swift
// NewScoreForm.swift
import Domain
import Foundation

/// Everything the M1 creation form collects. Presets stand in for the M2 instrument catalog: all three play
/// with the default (piano) sound; they differ in staff layout only.
struct NewScoreForm: Equatable {
    enum Preset: CaseIterable, Equatable {
        case piano        // grand staff: G + F, brace
        case trebleStaff  // single G staff
        case bassStaff    // single F staff

        var staves: [BlankScoreTemplate.StaffPlan] {
            switch self {
            case .piano: [.init(clefType: "G"), .init(clefType: "F")]
            case .trebleStaff: [.init(clefType: "G")]
            case .bassStaff: [.init(clefType: "F")]
            }
        }
    }

    /// The key picker's menu: circle of fifths, C-major center. Raw value is `KeySignature.concertKey`.
    static let keyChoices: [Int] = [0, 1, 2, 3, 4, 5, 6, -1, -2, -3, -4, -5, -6]
    /// numerator/denominator pairs offered by the time picker.
    static let timeChoices: [(Int, Int)] = [(4, 4), (3, 4), (2, 4), (6, 8), (12, 8), (2, 2), (5, 4)]

    var title = ""
    var composer = ""
    var preset = Preset.piano
    var concertKey = 0
    // Two Ints, not a tuple: Equatable synthesis rejects tuple stored properties.
    var timeNumerator = 4
    var timeDenominator = 4
    var tempoBPM = 120
    var measureCount = 32

    /// `nil` while the form isn't submittable (empty title, same rule as `EditableScoreInfo.normalized()`).
    func template() -> BlankScoreTemplate? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        let trimmedComposer = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        return BlankScoreTemplate(
            title: trimmedTitle,
            composer: trimmedComposer.isEmpty ? nil : trimmedComposer,
            instrumentID: "piano",
            instrumentName: "Piano",
            staves: preset.staves,
            concertKey: concertKey,
            timeNumerator: timeNumerator,
            timeDenominator: timeDenominator,
            tempoBPM: Double(tempoBPM),
            measureCount: measureCount,
        )
    }
}
```

**View model additions** (`LibraryViewModel.swift`):

```swift
    // init gains (placed after `metadataReader`, before the defaulted params; update App + every test call site):
    creator: any ScoreFileCreator,

    // state:
    public var isNewScoreSheetPresented = false
    /// Read together with `pendingScoreToOpen`: when true, the App opens the pushed Reader in an edit session.
    public private(set) var pendingOpenInEditSession = false

    public func createScore(from form: NewScoreForm) async {
        guard let template = form.template() else { return }
        do {
            let item = try await creator.createScore(Score.blank(template))
            analytics.log(.scoreCreated())          // exact factory name per the event you add
            pendingOpenInEditSession = true
            pendingScoreToOpen = item               // triggers the existing App navigation watcher
            isNewScoreSheetPresented = false
        } catch {
            // Surface through the same error channel startImport uses — read how importErrorMessage (or its
            // equivalent) is set in LibraryViewModel.startImport and reuse that property + alert.
        }
    }

    /// The App calls this when it consumes `pendingScoreToOpen`.
    public func consumePendingOpenInEditSession() -> Bool {
        defer { pendingOpenInEditSession = false }
        return pendingOpenInEditSession
    }
```

**UI:** In `LibraryRootScreen.addMenu` add a fourth button ABOVE Import (creation is the more primary act once it exists):

```swift
            Button {
                viewModel.isNewScoreSheetPresented = true
            } label: {
                Label { Text("library.newScore.title", bundle: .module) }
                    icon: { Image(systemName: "music.note") }
            }
```

`NewScoreSheet` is a plain `Form` presented from `libraryRootPresentations` via `.sheet(isPresented: $viewModel.isNewScoreSheetPresented)`: a `TextField` for title (required — disable the Create button while `form.template() == nil`, same pattern as `EditScoreInfoSheet`'s Save at `EditScoreInfoSheet.swift:145`), `TextField` composer, `Picker` preset, `Picker` key (label each choice with its localized key name, e.g. "C / Am", "G / Em" — write the 13 strings out), `Picker` time (label "4/4" etc.), `Stepper` tempo (range 20...300), `Stepper` measures (range 1...200). Toolbar: cancel + create (`L10n.Common.cancel`, key `library.newScore.create`). On create: `Task { await viewModel.createScore(from: form) }`.

Localization keys (add to the Library catalog in ALL its locales — en/ja/ko/zh-Hans; Japanese copy must not say "Reader"): `library.newScore.title` (en "New Score", ja 「新規楽譜」), `library.newScore.create` (en "Create", ja 「作成」), `library.newScore.field.title`, `library.newScore.field.composer`, `library.newScore.field.preset`, `library.newScore.preset.piano`, `library.newScore.preset.treble`, `library.newScore.preset.bass`, `library.newScore.field.key`, `library.newScore.field.time`, `library.newScore.field.tempo`, `library.newScore.field.measures`, `library.newScore.error` (creation-failed alert body).

**Analytics:** add `scoreCreated` to `AnalyticsEvent+Factories.swift` following `scoreImported`'s exact shape (`:12-24`), with no parameters in M1.

**App wiring:** `AppShellView.swift` `ReadyShell.init` passes `creator: LiveScoreFileCreator(gateway: <the bootstrap gateway>, repository: <the bootstrap repository>, scoresDirectory: AppPaths.scoresDirectory)` — pull the exact bootstrap property names from `AppBootstrap.swift:105-112` where the other LibraryViewModel dependencies come from.

- [ ] **Step 1: Write the failing tests**

```swift
// Packages/Features/Library/Tests/LibraryTests/NewScoreTests.swift
import Domain
@testable import Library
import Testing

@MainActor
@Suite("New score creation")
struct NewScoreTests {
    final class FakeScoreFileCreator: ScoreFileCreator {
        var created: [Score] = []
        var result: Result<ScoreItem, Error>
        init(result: Result<ScoreItem, Error>) { self.result = result }
        func createScore(_ score: Score) async throws -> ScoreItem {
            created.append(score)
            return try result.get()
        }
    }

    @Test("form without a title produces no template")
    func titleRequired() {
        var form = NewScoreForm()
        form.title = "   "
        #expect(form.template() == nil)
    }

    @Test("form maps to the blank-score template")
    func formMapping() throws {
        var form = NewScoreForm()
        form.title = " Sonata "
        form.composer = ""
        form.preset = .piano
        form.concertKey = -3
        form.timeNumerator = 6
        form.timeDenominator = 8
        form.tempoBPM = 72
        form.measureCount = 16
        let template = try #require(form.template())
        #expect(template.title == "Sonata")
        #expect(template.composer == nil)
        #expect(template.staves.count == 2)
        #expect(template.concertKey == -3)
        #expect(template.timeNumerator == 6)
        #expect(template.measureCount == 16)
    }

    @Test("createScore hands the built score to the creator and arms the edit-session open")
    func createFlow() async throws {
        let item = ScoreItem(/* minimal fixture — mirror how existing LibraryTests build a ScoreItem */)
        let creator = FakeScoreFileCreator(result: .success(item))
        let viewModel = /* construct LibraryViewModel with existing test fakes + this creator */
        var form = NewScoreForm()
        form.title = "Sonata"
        await viewModel.createScore(from: form)
        #expect(creator.created.count == 1)
        #expect(viewModel.pendingScoreToOpen == item)
        #expect(viewModel.consumePendingOpenInEditSession())
        #expect(!viewModel.consumePendingOpenInEditSession()) // one-shot
        #expect(!viewModel.isNewScoreSheetPresented)
    }
}
```

Fill the two fixture holes from the existing `LibraryTests` support files (`rg -l "LibraryViewModel(" Packages/Features/Library/Tests/` shows how every other test builds the VM and items).

- [ ] **Step 2: Run to verify failure** — from `Packages/Features/Library`: `xcodebuild test -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:LibraryTests/NewScoreTests` → FAIL (missing types).

- [ ] **Step 3: Implement** everything in the header block above (form, sheet, VM, menu row, presentations, strings, analytics event, App wiring). Update every existing `LibraryViewModel(` call site (tests + App) for the new `creator:` parameter.

- [ ] **Step 4: Run the full Library suite + build the app** — the Library test command without `-only-testing`, then from the worktree root: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build` → both green.

- [ ] **Step 5: Verify the sheet visually** — add a `#Preview` on `NewScoreSheet` with a fake creator, render via `mcp__xcode__RenderPreview`, and Read the PNG: all fields present, Create disabled with an empty title. Fix layout before committing.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Library Packages/Domain/Sources/Domain/Analytics/AnalyticsEvent+Factories.swift App/AppShellView.swift
git commit -m "feat: new-score creation form in the library"
```

---

### Task 8 (Folino): Open the created score straight into an edit session

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`, `App/EditableReaderScreen.swift`, `App/AppShellView.swift`
- Test: extend `Packages/Features/Reader/Tests/ReaderTests` only if `ReaderRootScreen` has view-model-level tests for session start; otherwise this is view plumbing verified in Task 9's end-to-end pass.

**Interfaces:**
- Consumes: `LibraryViewModel.consumePendingOpenInEditSession()` (Task 7).
- Produces: `ReaderRootScreen.init(..., startInEditMode: Bool = false)` and the same parameter on `EditableReaderScreen.init`.

- [ ] **Step 1: Reader parameter.** Add `startInEditMode: Bool = false` to `ReaderRootScreen.init` (`ReaderRootScreen.swift:181-241`), stored as a `private let`. At the post-load hook where `startScreenshotEditingIfRequested()` runs (`ReaderRootScreen.swift:396`), add before it:

```swift
            if startInEditMode {
                startEditing()
            }
```

Mirror `startScreenshotEditingIfRequested`'s own guards (`ReaderRootScreen.swift:638-645`) — if it waits for layout or checks `isEditing`, the new call follows the same sequencing; read `startEditing()` (`:613-628`) first and reuse whatever preconditions it needs. One-shot: the flag is init-immutable and `load()` runs once per screen instance, matching the screenshot switch's behavior.

- [ ] **Step 2: Thread it through the App.** `EditableReaderScreen.init` (`App/EditableReaderScreen.swift:36-59`) gains `startInEditMode: Bool = false` and forwards it into the `readerBuilder` call / `ReaderRootScreen` construction inside `ReadyShell.makeReader` (`App/AppShellView.swift:441-485`). In the two `pendingScoreToOpen` watchers (`App/AppShellView.swift:285-299`), capture `let openInEdit = libraryVM.consumePendingOpenInEditSession()` when the push happens and pass it to `makeReader`. Check how `makeReader` is invoked from `navigationDestination` — if the destination closure can't carry the flag, store it on `ReadyShell` `@State` at push time and consume it inside `makeReader` (one-shot: reset to `false` after reading).

- [ ] **Step 3: Build.** `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build` → green.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift App/EditableReaderScreen.swift App/AppShellView.swift
git commit -m "feat: open a just-created score straight into an edit session"
```

---

### Task 9 (Folino): Measure actions in the Editor

**Files:**
- Create: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Measures.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/Screens/EditorTopBarView.swift`, `Packages/Features/Editor/Sources/Editor/Resources/Localizable.xcstrings`
- Test: `Packages/Features/Editor/Tests/EditorTests/EditorViewModelMeasureTests.swift`

**Interfaces:**
- Consumes: `EditIntent.insertMeasure/.deleteMeasure` (Task 4), `EditorViewModel.apply(_ intent:) -> Bool` (`EditorViewModel.swift:377`, internal), the VM's existing selection/caret state.
- Produces:

```swift
extension EditorViewModel {
    /// Bar index the measure actions target: the selection's bar, else the caret's, else nil.
    public var targetMeasureIndex: Int? { get }
    public var measureCount: Int { get }        // parts[0].staves[0].measures.count, 0 without a score
    public func appendMeasure()                 // apply(.insertMeasure(at: measureCount))
    public func insertMeasureBeforeTarget()     // needs targetMeasureIndex
    public func deleteTargetMeasure()           // needs targetMeasureIndex; keeps selection sane afterwards
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// Packages/Features/Editor/Tests/EditorTests/EditorViewModelMeasureTests.swift
import Domain
@testable import Editor
import Testing

@MainActor
@Suite("EditorViewModel measure actions")
struct EditorViewModelMeasureTests {
    // Build the VM + session the way the existing EditorViewModel tests do (rg "beginSession" Tests/EditorTests
    // for the canonical setup helper) over a 2-bar blank score:
    private func makeViewModel() -> EditorViewModel {
        /* mirror existing setup; score: Score.blank(BlankScoreTemplate(
            title: "t", instrumentID: "piano", staves: [.init(clefType: "G")], measureCount: 2)) */
    }

    @Test("appendMeasure grows the score by one bar")
    func append() {
        let viewModel = makeViewModel()
        viewModel.appendMeasure()
        #expect(viewModel.measureCount == 3)
    }

    @Test("insert before the selected bar shifts it right")
    func insertBefore() {
        let viewModel = makeViewModel()
        // Select an element in bar 1 the way existing tests select (tap-selection helper or direct set).
        /* select bar 1 */
        viewModel.insertMeasureBeforeTarget()
        #expect(viewModel.measureCount == 3)
    }

    @Test("delete target measure shrinks the score and clears a dangling selection")
    func deleteTarget() {
        let viewModel = makeViewModel()
        /* select bar 1 */
        viewModel.deleteTargetMeasure()
        #expect(viewModel.measureCount == 1)
        #expect(viewModel.targetMeasureIndex == nil || viewModel.targetMeasureIndex == 0)
    }

    @Test("actions without a target are no-ops, not crashes")
    func noTarget() {
        let viewModel = makeViewModel()
        viewModel.insertMeasureBeforeTarget()
        viewModel.deleteTargetMeasure()
        #expect(viewModel.measureCount == 2)
    }
}
```

The selection helpers are the one part to lift from existing Editor tests — the VM's selection model (`selectedItem`, caret) is nontrivial (see `EditorViewModel+Input.swift:42-64` for the shapes) and its test fixtures already exist.

- [ ] **Step 2: Run to verify failure** — from `Packages/Features/Editor`: `xcodebuild test -scheme Editor -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:EditorTests/EditorViewModelMeasureTests` → FAIL.

- [ ] **Step 3: Implement the VM extension.** `targetMeasureIndex` reads `selectedItem`'s id (each case carries a `VoiceElementID`-convertible id with `measureIndex` — reuse the accessor pattern from `deleteSelection`), falling back to the caret item's measure. After `deleteTargetMeasure()` succeeds, clear/re-derive the selection the way existing delete paths do (`rederiveSelection` / clearing `selectedItem`) so nothing points at a removed bar; after `insertMeasureBeforeTarget()` the selection's positional ID is stale — re-derive from `lastAffectedLocation` like every other structural command consumer (`reference_note_editing_durable`: positional IDs drift; re-derive, don't patch).

- [ ] **Step 4: UI.** In `EditorTopBarView`, add three rows to the existing `overflowMenu` (`EditorTopBarView.swift:153-160`) above the revert/done rows, and give the wide (unfolded) layout the same `Menu` as its own `⋯` button if it currently has none — read the two layout variants at `:77-129` and keep `ViewThatFits` honest (the folded variant must stay strictly narrower; see the comment at `:41-45`):

```swift
            Button { viewModel.appendMeasure() } label: {
                Label { Text("editor.measure.append", bundle: .module) }
                    icon: { Image(systemName: "plus.rectangle") }
            }
            Button { viewModel.insertMeasureBeforeTarget() } label: {
                Label { Text("editor.measure.insertBefore", bundle: .module) }
                    icon: { Image(systemName: "plus.rectangle.on.rectangle") }
            }
            .disabled(viewModel.targetMeasureIndex == nil)
            Button(role: .destructive) { viewModel.deleteTargetMeasure() } label: {
                Label { Text("editor.measure.delete", bundle: .module) }
                    icon: { Image(systemName: "minus.rectangle") }
            }
            .disabled(viewModel.targetMeasureIndex == nil || viewModel.measureCount <= 1)
```

Keys in the Editor catalog, all locales: `editor.measure.append` (en "Add Measure at End", ja 「最後に小節を追加」), `editor.measure.insertBefore` (en "Insert Measure Before", ja 「前に小節を挿入」), `editor.measure.delete` (en "Delete Measure", ja 「小節を削除」).

- [ ] **Step 5: Run the full Editor suite** — the Step 2 command without `-only-testing` → PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Editor
git commit -m "feat: measure append/insert/delete actions in the editor"
```

---

### Task 10: End-to-end verification, then the ssm release dance

- [ ] **Step 1: Full builds.** App build + full test run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation test`, plus the full ssm suite `xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music`. All green before claiming anything works.

- [ ] **Step 2: Hand the loop to the user.** Install on the simulator and ask the user to walk: + → New Score (piano, 3/4, D major, 8 bars) → lands in an edit session → write a few notes with the pad → append + insert + delete a measure → undo/redo across a measure op → 完了 → reopen from the library → play it. Report exactly what to try and wait for their verdict. Do NOT proceed to Step 3 without the user's explicit OK — the ssm release mints a version.

- [ ] **Step 3 (after user OK): ssm release.** Merge `feature/scratch-creation-m1` to ssm local main → move the CHANGELOG entries under a new `## [1.16.0] - <date>` heading → commit `chore(release): swift-sheet-music 1.16.0` → push main → wait for CI "Build & test (Apple)" green → push tag `1.16.0` (no `v`). Never push main and the tag together.

- [ ] **Step 4: Re-pin Folino.** Hand-edit the 6 pin files back from the worktree path to `exact: "1.16.0"` (the pin script cannot do path→version; write it manually), `env -C <folino-wt> xcodegen`, verify resolution shows `@ 1.16.0`, run the app build once more, and commit the 6 files as a single `chore: bump swift-sheet-music to 1.16.0` commit.

- [ ] **Step 5: Reconcile memory.** Check the M1 box in `~/.claude/projects/-Users-kiichi-Developer-Personal-ios-apps-Folino-iOS/memory/project_scratch_creation_and_pro.md` and refresh its `MEMORY.md` hook line if stale. Note for the eventual release milestone (NOT now): `docs/product/vision.md:27` still says "folino does not write notes" — it comes out when the feature ships to users.

---

## Out of scope for M1 (explicitly)

- Paywall/quota (M5), instrument catalog + transposing instruments + part add/remove (M2), key/time changes after creation (M3), rehearsal marks (M4), drum entry (M6).
- Anacrusis (pickup bar) in the wizard — deferred to M2's wizard polish (`Measure.actualLength`/`irregular` are the model hooks).
- Android: the commands and intents are shared by construction; the Android wizard/UI follows after the iOS release with `PARITY(android)` markers.
- `LiveScoreFileImporter`'s private `hashAndSize` de-duplication (noted in Task 5).

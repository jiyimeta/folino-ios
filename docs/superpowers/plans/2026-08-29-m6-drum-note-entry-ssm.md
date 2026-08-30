# M6 drum note entry — swift-sheet-music half (§6a + §6b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a drum kit representable and editable in `swift-sheet-music` — a public `GMDrumset`, a fully
decoded/encoded `Instrument.drumset`, and the three edit commands (create a voice, split a rest, set a
notehead) with their wire intents — so the Folino drum pad has something to sit on.

**Architecture:** Two independent halves of the drum-note-entry spec, both entirely inside
`swift-sheet-music`. §6a replaces `Instrument.drumLineMap`'s stored dictionary with a full
`[Int: DrumsetEntry]` table (`drumLineMap` survives as a derived get/set so every existing caller and writer
is untouched), decodes `<Drum>` completely instead of reading only `<line>`, and encodes from that table with
gaps filled from the new public `GMDrumset` — which absorbs the three private functions that already held
the GM table encoder-side. §6b adds `CreateVoice`, `SplitRest` and `SetNoteHead` as ordinary `EditCommand`s
plus `EditIntent` cases 25/26/27, so both platform images plan the same commands from the same scalars.

**Tech Stack:** Swift 6.3, SwiftPM, Swift Testing (`@Suite` / `@Test` / `#expect`), Wirelet
(`@WireFormat` / `@WireFormatChoice`) for the intent codec, MuseScore MSCX as the file format.

**Spec:** `docs/superpowers/specs/2026-08-12-drum-note-entry-design.md` (§6a, §6b, §7, §10). The umbrella is
`docs/superpowers/specs/2026-08-26-scratch-score-creation-and-pro-design.md` (M6).

---

## Scope of THIS plan

Spec §9 orders the work §6a → SP2 → §5.4 → §6b → pad. **That order was deliberately broken on 2026-08-29
(approach ③, user's call):** SP2 landed on the Android note-editing branch, which is not merged, so §5.4 (the
column caret, which must live in `EditorCore`) and §5.1–5.6 (the pad) are still gated. §6a and §6b are not
gated by anything, so they go first and the `EditorCore` wait is not spent idle.

**In this plan:** spec §6a (tasks 1–4) and §6b (tasks 5–9). All of it in `swift-sheet-music`.

**Out of this plan, and why:** §5.4 column caret and §5.1–5.6 drum pad — both require `EditorCore`, which does
not exist on this Folino branch. `DrumPadKey` / `DrumPadLayout` / the voice presets live in `EditorCore` too
(spec §8), so none of them appear here. Folino is not edited at all by this plan beyond a build check.

## Global Constraints

- **Repositories.** Work happens in the ssm worktree
  `~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music`, branch
  `feature/scratch-creation-m1`. The Folino worktree
  `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/scratch-creation-spec` (branch
  `worktree-scratch-creation-spec`) is pinned to that path and is only built, not edited.
- **Do not merge or release ssm.** Per the umbrella spec's ssm policy, everything for this feature stays on
  `feature/scratch-creation-m1` until M1–M4 + M6 are all done; the release is 2.2.0 or later.
- **Wire indices 25, 26, 27 are free and this branch owns them.** Verified 2026-08-29 across every local
  branch: the highest `/// N = ` line in `EditIntentCodec.swift` is 24 everywhere. Re-verify before
  appending with:
  `git branch --format='%(refname:short)' | while read b; do git show "$b:Sources/SheetMusicEditWire/Intent/EditIntentCodec.swift" 2>/dev/null | grep -cE "^/// 2[5-9] = "; done`
  Every count must be 0. **Append; never renumber.**
- **Tests are Swift Testing.** `import Testing`, `@Suite`, `@Test`, `#expect`. No XCTest.
- **Test command:** `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter <Suite>`.
  `swift test` from the Folino side does not work; this is the ssm package, where it does.
- **Full gate before the last commit:** `Scripts/preflight.sh --apple` from the ssm worktree root.
- **Comment style:** reflow `//` and `///` paragraphs at 120 columns, single line per paragraph.
- **Access control:** no `public` unless something outside the module references it. `DrumsetEntry`,
  `GMDrumset`, the three commands and the three intents ARE public (hosts and the wire codec use them);
  their internal helpers are not.
- **`public` on `EditCommand` conformances:** a public protocol's requirements must be public on the
  conforming member, so `affectedLocation` and `apply(to:)` stay public on all three new commands.

---

## File structure

**swift-sheet-music — created**

| Path | Responsibility |
| --- | --- |
| `Sources/SheetMusicCore/Score/GMDrumset.swift` | `DrumsetEntry` value + the public GM table; the single definition of "which drum, on what line, with what head, in which voice" |
| `Sources/SheetMusicCore/Editing/CreateVoice.swift` | Append a rest-filled voice to a measure |
| `Sources/SheetMusicCore/Editing/SplitRest.swift` | Split one rest into two beat-aligned runs at a tick offset |
| `Sources/SheetMusicCore/Editing/SetNoteHead.swift` | Write `Note.headType` |
| `Sources/SheetMusicCore/Editing/ScoreEditSession+DrumPlanning.swift` | The three new intents' `EditIntent` → `EditCommand` translation |
| `Tests/SheetMusicTests/GMDrumsetTests.swift` | The GM table's own content, pinned literally |
| `Tests/SheetMusicTests/Score/InstrumentDrumsetTests.swift` | `drumset` ⇄ `drumLineMap` derivation |
| `Tests/SheetMusicTests/MSCXDrumsetRoundTripTests.swift` | `<Drum>` decode/encode, and the byte-identical gate |
| `Tests/SheetMusicTests/Resources/drumsetEncodeGolden.xml` | The `<Instrument>` block an authored drum part encodes to, recorded BEFORE any source change |
| `Tests/SheetMusicTests/EditingTests/CreateVoiceTests.swift` | `CreateVoice` apply/inverse/refusals |
| `Tests/SheetMusicTests/EditingTests/SplitRestTests.swift` | `SplitRest` apply/inverse/refusals |
| `Tests/SheetMusicTests/EditingTests/SetNoteHeadTests.swift` | `SetNoteHead` apply/inverse/refusals |
| `Tests/SheetMusicTests/EditingTests/DrumIntentTests.swift` | The three intents planned through `ScoreEditSession`, including the composite that writes a cross-head note |

**swift-sheet-music — modified**

| Path | Change |
| --- | --- |
| `Sources/SheetMusicCore/Score/GMPercussion.swift` | `drumLineMap` becomes derived from `GMDrumset.entries` |
| `Sources/SheetMusicCore/Score/Instrument.swift` | `drumset` stored; `drumLineMap` becomes computed get/set; init gains `drumset:` |
| `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Instrument.swift` | Decode `<Drum>` fully |
| `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Instrument.swift` | Encode from `drumset`; the three private GM functions are deleted |
| `Sources/SheetMusicCore/Editing/EditIntent.swift` | Cases 25/26/27 |
| `Sources/SheetMusicCore/Editing/EditRefusal.swift` | `.voiceAlreadyExists` reason + code + description |
| `Sources/SheetMusicCore/Editing/ScoreEditSession+Planning.swift` | One dispatch line for the three new intents |
| `Sources/SheetMusicEditWire/Intent/EditIntentCodec.swift` | Three wire payload structs, three choice cases, the doc-comment index table |
| `Tests/SheetMusicTests/EditingTests/EditRefusalTests.swift` | `sampleReasons` gains the new case |
| `Tests/SheetMusicTests/AndroidJNI/EditIntentCodecTests.swift` | Wire round-trip for the three intents |
| `Tests/SheetMusicTests/EditingTests/EditReplayScript.swift` | Three appended steps |
| `Android/SheetMusicAndroid/src/androidTest/assets/editReplay/` | Re-recorded goldens + new `step-NN.bin` |
| `Web/sheet-music-web/test/fixtures/edit-replay.json` | Re-recorded |
| `Android/.../EditSessionReplayTest.kt` | Step count |
| `docs/edit-commands.md` | The three new commands |
| `CHANGELOG.md` | `## [Unreleased]` entries |

---

## Task 1: `GMDrumset` — one public GM drum table

The three private functions in `MSCXEncoder+Instrument.swift` (`gmDrumHead`, `gmDrumVoiceIndex`,
`gmDrumName`) and `GMPercussion.drumLineMap` are four halves of one table. This task builds the whole table
in `SheetMusicCore` and makes `GMPercussion.drumLineMap` a projection of it. Nothing consumes the new type
yet, so the gate is that the derived line map is byte-for-byte the dictionary it replaced.

**Files:**
- Create: `Sources/SheetMusicCore/Score/GMDrumset.swift`
- Create: `Tests/SheetMusicTests/GMDrumsetTests.swift`
- Create: `Tests/SheetMusicTests/Resources/drumsetEncodeGolden.xml` (recorded, not authored)
- Modify: `Sources/SheetMusicCore/Score/GMPercussion.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public struct DrumsetEntry: Sendable, Equatable` with `var name: String`, `var head: String`,
    `var line: Int`, `var voiceIndex: Int`, `var stem: Int`, `var shortcut: String?` and
    `public init(name:head:line:voiceIndex:stem:shortcut:)` (`shortcut` defaults to `nil`).
  - `public enum GMDrumset` with `public static let entries: [Int: DrumsetEntry]` and
    `public static func entry(forPitch pitch: Int, line: Int) -> DrumsetEntry`.
  - `GMPercussion.drumLineMap` keeps its type `[Int: Int]` and its exact values.

- [ ] **Step 1: Record the pre-change encoder output — do this BEFORE editing any source**

The §6a gate is that an authored drum part still encodes to the same bytes. Capture today's bytes first.

Write `/private/tmp/claude-501/record-drum-golden.swift` is NOT the shape to use — instead add a temporary
test and run it. Create `Tests/SheetMusicTests/RecordDrumGolden.swift`:

```swift
#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicMSCX
    @testable import SheetMusicXMLTools
    import Testing

    @Suite("Record the drumset encode golden")
    struct RecordDrumGolden {
        @Test("write the authored drum part's <Instrument> block to Resources")
        func record() throws {
            let template = BlankScoreTemplate(
                title: "Drums",
                parts: [.init(
                    instrumentID: "drumset", longName: "Drum Kit",
                    staves: [.init(clefType: "PERC", isPercussion: true)],
                    isDrums: true,
                )],
                measureCount: 1,
            )
            let score = Score.blank(template)
            let node = score.parts[0].instrument.encode()
            let xml = XMLTreeSerializer.serialize(node)
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/drumsetEncodeGolden.xml")
            try Data(xml.utf8).write(to: url)
        }
    }
#endif
```

If `XMLTreeSerializer.serialize` does not exist under that name, find the serializer the encoder tests use
(`grep -rn "XMLTreeSerializer" Tests/ Sources/SheetMusicXMLTools/`) and use it; the goal is a stable text
rendering of the one `<Instrument>` node, not a whole file.

- [ ] **Step 2: Run the recorder and keep the file**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter RecordDrumGolden`
Expected: PASS, and `Tests/SheetMusicTests/Resources/drumsetEncodeGolden.xml` exists and contains 27 `<Drum>`
elements (`grep -c "<Drum " Tests/SheetMusicTests/Resources/drumsetEncodeGolden.xml` → 27).

Then delete `Tests/SheetMusicTests/RecordDrumGolden.swift` — it has done its one job, and a test that
rewrites its own fixture would silently absorb the very regression the golden exists to catch.

- [ ] **Step 3: Write the failing test for the table**

Create `Tests/SheetMusicTests/GMDrumsetTests.swift`:

```swift
@testable import SheetMusicCore
import Testing

@Suite("GMDrumset")
struct GMDrumsetTests {
    /// The line map as it stood when it was the only half of the table that was public. Written out literally
    /// rather than read from `GMPercussion`, so this test still fails if both sides are edited together — a drum
    /// that moves line silently re-engraves every existing drum score.
    private static let historicalLineMap: [Int: Int] = [
        35: 6, 36: 6, 37: 2, 38: 2, 39: 2, 40: 2, 41: 8, 42: -1, 43: 7, 44: 9,
        45: 5, 46: -1, 47: 4, 48: 3, 49: -1, 50: 2, 51: 0, 52: -1, 53: 0, 54: 0,
        55: -1, 56: 0, 57: -1, 58: 1, 59: 0, 60: 1, 61: 2,
    ]

    @Test("the table covers exactly the pitches the old private tables did")
    func coverage() {
        #expect(Set(GMDrumset.entries.keys) == Set(35 ... 61))
    }

    @Test("GMPercussion.drumLineMap is the table's lines, unchanged")
    func lineMapUnchanged() {
        #expect(GMPercussion.drumLineMap == Self.historicalLineMap)
        #expect(GMDrumset.entries.mapValues(\.line) == Self.historicalLineMap)
    }

    @Test("cymbals and hi-hats carry the cross head, the side stick and electric snare their own")
    func heads() {
        let cross = Set([42, 44, 46, 49, 51, 52, 53, 54, 55, 57, 59])
        for (pitch, entry) in GMDrumset.entries {
            switch pitch {
            case 37: #expect(entry.head == "slashed1")
            case 40: #expect(entry.head == "slash")
            case _ where cross.contains(pitch): #expect(entry.head == "cross")
            default: #expect(entry.head == "normal")
            }
        }
    }

    @Test("the feet voice is bass drum, pedal hi-hat and low floor tom, stems down")
    func voicesAndStems() {
        for (pitch, entry) in GMDrumset.entries {
            let isFeet = [35, 36, 41, 44].contains(pitch)
            #expect(entry.voiceIndex == (isFeet ? 1 : 0))
            #expect(entry.stem == (isFeet ? 2 : 1))
        }
    }

    @Test("every entry is named — MuseScore drops a nameless <Drum>")
    func names() {
        #expect(GMDrumset.entries[38]?.name == "Acoustic Snare")
        #expect(GMDrumset.entries[42]?.name == "Closed Hi-Hat")
        for entry in GMDrumset.entries.values {
            #expect(!entry.name.isEmpty)
        }
    }

    @Test("a pitch the table does not know still gets a writable entry on the line it is asked for")
    func fallback() {
        let entry = GMDrumset.entry(forPitch: 63, line: 4)
        #expect(entry.line == 4)
        #expect(entry.name == "Drum 63")
        #expect(entry.head == "normal")
        #expect(entry.voiceIndex == 0)
        #expect(entry.stem == 1)
    }

    @Test("a known pitch asked for a different line keeps its name, head and voice")
    func knownPitchWithOverriddenLine() {
        let entry = GMDrumset.entry(forPitch: 42, line: 3)
        #expect(entry.line == 3)
        #expect(entry.head == "cross")
        #expect(entry.name == "Closed Hi-Hat")
    }
}
```

- [ ] **Step 4: Run it to make sure it fails**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter GMDrumsetTests`
Expected: FAIL to build — "cannot find 'GMDrumset' in scope".

- [ ] **Step 5: Write `GMDrumset.swift`**

```swift
import SheetMusicFoundation

/// One drum's engraving identity: which line it sits on, what notehead it wears, and which voice — and so which
/// stem direction — it belongs to. MuseScore's `<Drum>` element, one to one.
///
/// `stem` is MuseScore's own encoding: `1` = up, `2` = down. It is stored rather than derived from `voiceIndex`
/// because it is what the file says, and a chart is free to disagree with the convention.
public struct DrumsetEntry: Sendable, Equatable {
    public var name: String
    public var head: String
    public var line: Int
    public var voiceIndex: Int
    public var stem: Int
    /// MuseScore's `<shortcut>` — the key that selects this drum in its own note-input palette. Carried so a
    /// decoded kit re-encodes to the bytes it came from; nothing in this package reads it.
    public var shortcut: String?

    public init(name: String, head: String, line: Int, voiceIndex: Int, stem: Int, shortcut: String? = nil) {
        self.name = name
        self.head = head
        self.line = line
        self.voiceIndex = voiceIndex
        self.stem = stem
        self.shortcut = shortcut
    }
}

/// The General MIDI drum kit as MuseScore Studio's stock drumset engraves it — the defaults an authored kit gets
/// and the gap-filler for a decoded one.
///
/// This table used to be four separate halves: `GMPercussion.drumLineMap` held the lines publicly, while
/// `MSCXEncoder+Instrument` held the names, heads and voices in three private functions, because MuseScore Studio
/// silently ignores a `<Drum>` entry lacking `<head>` / `<voice>` / `<stem>` and collapses every drum onto one
/// line — so the encoder needed them and nothing else did. Drum note entry needs the same facts on the way IN, so
/// they live in one place now.
///
/// This is NOT "the" drum table. `PDFImporter.defaultDrumLineMap` is deliberately a different one — MuseScore 3's
/// stock drumset, whose lines are what actually positioned the noteheads in the PDF being read — and
/// `MidiImporter.gmDrumHeads` deliberately differs on four pitches, because it is choosing heads for a track that
/// never said what it wanted. Both are left alone.
public enum GMDrumset {
    public static let entries: [Int: DrumsetEntry] = [
        35: DrumsetEntry(name: "Acoustic Bass Drum", head: "normal", line: 6, voiceIndex: 1, stem: 2),
        36: DrumsetEntry(name: "Bass Drum 1", head: "normal", line: 6, voiceIndex: 1, stem: 2),
        37: DrumsetEntry(name: "Side Stick", head: "slashed1", line: 2, voiceIndex: 0, stem: 1),
        38: DrumsetEntry(name: "Acoustic Snare", head: "normal", line: 2, voiceIndex: 0, stem: 1),
        39: DrumsetEntry(name: "Hand Clap", head: "normal", line: 2, voiceIndex: 0, stem: 1),
        40: DrumsetEntry(name: "Electric Snare", head: "slash", line: 2, voiceIndex: 0, stem: 1),
        41: DrumsetEntry(name: "Low Floor Tom", head: "normal", line: 8, voiceIndex: 1, stem: 2),
        42: DrumsetEntry(name: "Closed Hi-Hat", head: "cross", line: -1, voiceIndex: 0, stem: 1),
        43: DrumsetEntry(name: "High Floor Tom", head: "normal", line: 7, voiceIndex: 0, stem: 1),
        44: DrumsetEntry(name: "Pedal Hi-Hat", head: "cross", line: 9, voiceIndex: 1, stem: 2),
        45: DrumsetEntry(name: "Low Tom", head: "normal", line: 5, voiceIndex: 0, stem: 1),
        46: DrumsetEntry(name: "Open Hi-Hat", head: "cross", line: -1, voiceIndex: 0, stem: 1),
        47: DrumsetEntry(name: "Low-Mid Tom", head: "normal", line: 4, voiceIndex: 0, stem: 1),
        48: DrumsetEntry(name: "Hi-Mid Tom", head: "normal", line: 3, voiceIndex: 0, stem: 1),
        49: DrumsetEntry(name: "Crash Cymbal 1", head: "cross", line: -1, voiceIndex: 0, stem: 1),
        50: DrumsetEntry(name: "High Tom", head: "normal", line: 2, voiceIndex: 0, stem: 1),
        51: DrumsetEntry(name: "Ride Cymbal 1", head: "cross", line: 0, voiceIndex: 0, stem: 1),
        52: DrumsetEntry(name: "Chinese Cymbal", head: "cross", line: -1, voiceIndex: 0, stem: 1),
        53: DrumsetEntry(name: "Ride Bell", head: "cross", line: 0, voiceIndex: 0, stem: 1),
        54: DrumsetEntry(name: "Tambourine", head: "cross", line: 0, voiceIndex: 0, stem: 1),
        55: DrumsetEntry(name: "Splash Cymbal", head: "cross", line: -1, voiceIndex: 0, stem: 1),
        56: DrumsetEntry(name: "Cowbell", head: "normal", line: 0, voiceIndex: 0, stem: 1),
        57: DrumsetEntry(name: "Crash Cymbal 2", head: "cross", line: -1, voiceIndex: 0, stem: 1),
        58: DrumsetEntry(name: "Vibraslap", head: "normal", line: 1, voiceIndex: 0, stem: 1),
        59: DrumsetEntry(name: "Ride Cymbal 2", head: "cross", line: 0, voiceIndex: 0, stem: 1),
        60: DrumsetEntry(name: "Hi Bongo", head: "normal", line: 1, voiceIndex: 0, stem: 1),
        61: DrumsetEntry(name: "Low Bongo", head: "normal", line: 2, voiceIndex: 0, stem: 1),
    ]

    /// The entry for `pitch`, placed on `line`. A pitch the GM table does not name still gets a complete,
    /// writable entry: MuseScore drops a `<Drum>` that lacks `<name>` / `<head>` / `<voice>` / `<stem>`
    /// altogether, so an incomplete answer here is the same as no answer at all.
    public static func entry(forPitch pitch: Int, line: Int) -> DrumsetEntry {
        guard var entry = entries[pitch] else {
            return DrumsetEntry(name: "Drum \(pitch)", head: "normal", line: line, voiceIndex: 0, stem: 1)
        }
        entry.line = line
        return entry
    }
}
```

- [ ] **Step 6: Make `GMPercussion.drumLineMap` derived**

In `Sources/SheetMusicCore/Score/GMPercussion.swift`, replace the literal dictionary with:

```swift
    /// GM drum-kit pitch → percussion-staff line index (0 = top line, 4 = middle, 8 = bottom line; negative =
    /// above-staff ledger; ≥ 9 = below-staff). Consumed through `Instrument.drumLineMap`, which the layout
    /// engine reads to place the notehead at the conventional position for that drum instead of applying the
    /// pitched diatonic formula.
    ///
    /// The lines themselves live in `GMDrumset.entries` now, alongside the head, voice and name that belong to
    /// the same drum; this is the lines-only projection every existing caller was written against.
    public static let drumLineMap: [Int: Int] = GMDrumset.entries.mapValues(\.line)
```

Leave the type's own doc comment, `staffTypeName` and `staffGroup` untouched.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter GMDrumsetTests`
Expected: PASS, 6 tests.

- [ ] **Step 8: Run the tests that already consume the line map**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter "BlankScoreTests|MidiImporterDrumTests|DrumChannelTests|PDFImporterDrumStaffTests"`
Expected: PASS, no change.

- [ ] **Step 9: Commit**

```bash
git -C ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music add Sources/SheetMusicCore/Score/GMDrumset.swift Sources/SheetMusicCore/Score/GMPercussion.swift Tests/SheetMusicTests/GMDrumsetTests.swift Tests/SheetMusicTests/Resources/drumsetEncodeGolden.xml
git -C ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music commit -m "feat: the GM drumset is one public table, not four private halves"
```

---

## Task 2: `Instrument.drumset`, with `drumLineMap` as its projection

`drumLineMap` has both readers (the layout engine, the encoder) and writers (`PDFImporter+DrumStaff` assigns
it; `Score.blank` and `MidiImporter` pass it to `init`). Making it a computed get/set over the new stored
`drumset` keeps every one of them compiling and behaving, which is the whole reason the spec calls for a
derived map rather than a second field.

**Files:**
- Modify: `Sources/SheetMusicCore/Score/Instrument.swift`
- Create: `Tests/SheetMusicTests/Score/InstrumentDrumsetTests.swift`

**Interfaces:**
- Consumes: `DrumsetEntry`, `GMDrumset.entry(forPitch:line:)` from Task 1.
- Produces: `Instrument.drumset: [Int: DrumsetEntry]` (stored), `Instrument.drumLineMap: [Int: Int]`
  (computed, get + set), and `Instrument.init(..., drumLineMap:, drumset:, ...)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/Score/InstrumentDrumsetTests.swift`:

```swift
@testable import SheetMusicCore
import Testing

@Suite("Instrument.drumset")
struct InstrumentDrumsetTests {
    @Test("a kit built from a line map gets the GM head, name and voice for each pitch")
    func lineMapInitFillsFromGM() {
        let instrument = Instrument(id: "drumset", useDrumset: true, drumLineMap: [38: 2, 42: -1])
        #expect(instrument.drumset.count == 2)
        #expect(instrument.drumset[38]?.head == "normal")
        #expect(instrument.drumset[38]?.name == "Acoustic Snare")
        #expect(instrument.drumset[42]?.head == "cross")
        #expect(instrument.drumset[42]?.voiceIndex == 0)
    }

    @Test("drumLineMap reads back the lines it was given")
    func lineMapRoundTrips() {
        let instrument = Instrument(id: "drumset", useDrumset: true, drumLineMap: GMPercussion.drumLineMap)
        #expect(instrument.drumLineMap == GMPercussion.drumLineMap)
    }

    @Test("assigning drumLineMap moves a drum's line and keeps everything else about it")
    func assigningKeepsTheRest() {
        var instrument = Instrument(id: "drumset", useDrumset: true, drumset: [
            51: DrumsetEntry(name: "Ride", head: "diamond", line: 0, voiceIndex: 0, stem: 1, shortcut: "R"),
        ])
        instrument.drumLineMap = [51: 3]
        #expect(instrument.drumset[51]?.line == 3)
        #expect(instrument.drumset[51]?.head == "diamond")
        #expect(instrument.drumset[51]?.name == "Ride")
        #expect(instrument.drumset[51]?.shortcut == "R")
    }

    @Test("assigning drumLineMap drops the pitches the new map does not name")
    func assigningReplacesWholesale() {
        var instrument = Instrument(id: "drumset", useDrumset: true, drumLineMap: [38: 2, 42: -1])
        instrument.drumLineMap = [38: 2]
        #expect(Set(instrument.drumset.keys) == [38])
    }

    @Test("an explicit drumset wins over a line map passed alongside it")
    func drumsetWinsOverLineMap() {
        let instrument = Instrument(
            id: "drumset", useDrumset: true,
            drumLineMap: [38: 7],
            drumset: [38: DrumsetEntry(name: "Snare", head: "cross", line: 2, voiceIndex: 0, stem: 1)],
        )
        #expect(instrument.drumLineMap == [38: 2])
        #expect(instrument.drumset[38]?.head == "cross")
    }

    @Test("a pitched instrument has an empty kit")
    func pitchedIsEmpty() {
        let instrument = Instrument(id: "flute")
        #expect(instrument.drumset.isEmpty)
        #expect(instrument.drumLineMap.isEmpty)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter InstrumentDrumsetTests`
Expected: FAIL to build — `Instrument` has no member `drumset`.

- [ ] **Step 3: Change `Instrument`**

Replace the stored `drumLineMap` property with:

```swift
    /// The part's drum kit: MIDI pitch → how that drum is engraved (staff line, notehead, voice, stem, name).
    /// MuseScore's `<Drum>` elements, one to one. Empty for a pitched instrument.
    ///
    /// The layout engine reads only the lines, through `drumLineMap`; the heads and voices are what the MSCX
    /// encoder needs and what drum note entry writes.
    public var drumset: [Int: DrumsetEntry]

    /// Per-pitch staff-line mapping for drum instruments. Key = MIDI pitch (35 = bass drum, 42 = hi-hat, etc.),
    /// value = MuseScore line number (0 = top staff line, 4 = middle, 8 = bottom, negative = above staff). Used
    /// by the UI to position drum noteheads instead of the pitched diatonic formula.
    ///
    /// The lines-only view of `drumset`, which is where they are actually stored. Assigning REPLACES the kit:
    /// a pitch the new map does not name is dropped, exactly as it was when this was the stored property.
    /// A pitch it names that the kit already has keeps its head, voice, stem and name and only moves line; a
    /// pitch that is new gets `GMDrumset`'s defaults.
    public var drumLineMap: [Int: Int] {
        get { drumset.mapValues(\.line) }
        set {
            var next: [Int: DrumsetEntry] = [:]
            next.reserveCapacity(newValue.count)
            for (pitch, line) in newValue {
                if var existing = drumset[pitch] {
                    existing.line = line
                    next[pitch] = existing
                } else {
                    next[pitch] = GMDrumset.entry(forPitch: pitch, line: line)
                }
            }
            drumset = next
        }
    }
```

In `init`, keep the `drumLineMap: [Int: Int] = [:]` parameter where it is and add `drumset: [Int: DrumsetEntry] = [:]`
directly after it. Assign:

```swift
        // Two spellings of one kit, so the many existing callers that build one from lines alone keep working.
        // An explicit `drumset` is the richer of the two and wins; `drumLineMap` is filled out from `GMDrumset`.
        if !drumset.isEmpty {
            self.drumset = drumset
        } else {
            self.drumset = drumLineMap.reduce(into: [:]) { result, pair in
                result[pair.key] = GMDrumset.entry(forPitch: pair.key, line: pair.value)
            }
        }
```

Place that assignment where `self.drumLineMap = drumLineMap` was; there is no stored `drumLineMap` any more.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter InstrumentDrumsetTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Run everything that touches a drum instrument**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter "BlankScoreTests|MidiImporterDrumTests|DrumChannelTests|PDFImporterDrumStaffTests|MSCXEncoderMS3DrumTests|LayoutEngineTests"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git -C ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music add Sources/SheetMusicCore/Score/Instrument.swift Tests/SheetMusicTests/Score/InstrumentDrumsetTests.swift
git -C ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music commit -m "feat: an instrument carries its whole drum kit, not just the lines"
```

---

## Task 3: decode `<Drum>` completely

Today the decoder reads `<line>` and discards `name`, `head`, `voice`, `stem` and `shortcut` — so an imported
chart that puts the ride on a non-standard line keeps the line but loses everything else about it, and
re-encoding invents GM answers in their place.

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Instrument.swift`
- Create: `Tests/SheetMusicTests/MSCXDrumsetRoundTripTests.swift`

**Interfaces:**
- Consumes: `Instrument.drumset` and `GMDrumset.entry(forPitch:line:)`.
- Produces: a decoded `Instrument` whose `drumset` mirrors the file's `<Drum>` elements.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/MSCXDrumsetRoundTripTests.swift`:

```swift
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("MSCX drumset round-trip")
struct MSCXDrumsetRoundTripTests {
    private static let museScoreDrum = """
    <Instrument id="drumset">
      <useDrumset>1</useDrumset>
      <Drum pitch="36">
        <head>normal</head>
        <line>7</line>
        <voice>1</voice>
        <name>Bass Drum 1</name>
        <stem>2</stem>
        <shortcut>B</shortcut>
        </Drum>
      <Drum pitch="51">
        <head>diamond</head>
        <line>3</line>
        <voice>0</voice>
        <name>Ride (my chart)</name>
        <stem>1</stem>
        </Drum>
      </Instrument>
    """

    @Test("every <Drum> child is decoded, not just the line")
    func decodesWholeEntry() throws {
        let node = try XMLTreeParser.parse(Data(Self.museScoreDrum.utf8))
        let instrument = try Instrument.decode(node)

        #expect(instrument.useDrumset)
        #expect(instrument.drumset[36]?.line == 7)
        #expect(instrument.drumset[36]?.voiceIndex == 1)
        #expect(instrument.drumset[36]?.stem == 2)
        #expect(instrument.drumset[36]?.shortcut == "B")
        #expect(instrument.drumset[51]?.head == "diamond")
        #expect(instrument.drumset[51]?.name == "Ride (my chart)")
        #expect(instrument.drumLineMap == [36: 7, 51: 3])
    }

    @Test("a <Drum> missing its optional children falls back to GM rather than dropping the pitch")
    func decodesSparseEntry() throws {
        let xml = """
        <Instrument id="drumset"><useDrumset>1</useDrumset>
          <Drum pitch="42"><line>-1</line></Drum>
        </Instrument>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let instrument = try Instrument.decode(node)

        #expect(instrument.drumset[42]?.line == -1)
        #expect(instrument.drumset[42]?.head == "cross")
        #expect(instrument.drumset[42]?.name == "Closed Hi-Hat")
        #expect(instrument.drumset[42]?.shortcut == nil)
    }

    @Test("a <Drum> with no line at all is still skipped")
    func skipsLinelessEntry() throws {
        let xml = """
        <Instrument id="drumset"><useDrumset>1</useDrumset>
          <Drum pitch="42"><head>cross</head></Drum>
        </Instrument>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let instrument = try Instrument.decode(node)

        #expect(instrument.drumset.isEmpty)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter MSCXDrumsetRoundTripTests`
Expected: FAIL — `decodesWholeEntry` reports `instrument.drumset[36]?.shortcut` is `nil` (and head/name are the
GM ones, not the file's), because the decoder still keeps only the line.

- [ ] **Step 3: Decode the whole element**

In `MSCXDecoder+Instrument.swift`, replace the `drumLineMap` loop with:

```swift
        // <Drum pitch="42"><head>cross</head><line>-1</line><voice>0</voice><name>…</name><stem>1</stem></Drum>
        // — the whole per-pitch engraving entry. `<line>` is the one child that is load-bearing enough to skip
        // the entry over: without it there is nothing to place the notehead by. The others fall back to the GM
        // conventions rather than dropping the drum, because a `<Drum>` that reaches MuseScore without them is
        // ignored outright.
        var drumset: [Int: DrumsetEntry] = [:]
        for drum in node.all("Drum") {
            guard let pitchStr = drum.attributes["pitch"],
                  let pitch = Int(pitchStr),
                  let lineStr = drum.first("line")?.text,
                  let line = Int(lineStr) else { continue }
            let fallback = GMDrumset.entry(forPitch: pitch, line: line)
            drumset[pitch] = DrumsetEntry(
                name: drum.first("name")?.text ?? fallback.name,
                head: drum.first("head")?.text ?? fallback.head,
                line: line,
                voiceIndex: (drum.first("voice")?.text).flatMap { Int($0) } ?? fallback.voiceIndex,
                stem: (drum.first("stem")?.text).flatMap { Int($0) } ?? fallback.stem,
                shortcut: drum.first("shortcut")?.text,
            )
        }
```

and change the `Instrument(...)` call's `drumLineMap: drumLineMap,` to `drumset: drumset,`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter MSCXDrumsetRoundTripTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git -C ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Instrument.swift Tests/SheetMusicTests/MSCXDrumsetRoundTripTests.swift
git -C ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music commit -m "feat(mscx): a <Drum> element is read whole, not for its line alone"
```

---

## Task 4: encode from the kit, and prove the authored bytes did not move

This closes §6a. The encoder stops inventing GM answers and writes what the kit says, and the three private
functions go. Two gates: the authored-kit bytes recorded in Task 1 are unchanged, and a real MuseScore
drumset now survives a decode/encode round trip.

**Files:**
- Modify: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Instrument.swift`
- Modify: `Tests/SheetMusicTests/MSCXDrumsetRoundTripTests.swift`

**Interfaces:**
- Consumes: `Instrument.drumset`, `GMDrumset.entry(forPitch:line:)`.
- Produces: no new API; `Instrument.encode(options:)` keeps its signature.

- [ ] **Step 1: Write the two failing gate tests**

Append to `Tests/SheetMusicTests/MSCXDrumsetRoundTripTests.swift`:

```swift
    @Test("a MuseScore drumset re-encodes to the bytes it was decoded from")
    func reEncodesFaithfully() throws {
        let node = try XMLTreeParser.parse(Data(Self.museScoreDrum.utf8))
        let instrument = try Instrument.decode(node)
        let encoded = instrument.encode()

        let drums = encoded.all("Drum")
        #expect(drums.count == 2)
        let bass = try #require(drums.first { $0.attributes["pitch"] == "36" })
        #expect(bass.children.map(\.name) == ["head", "line", "voice", "name", "stem", "shortcut"])
        #expect(bass.first("head")?.text == "normal")
        #expect(bass.first("line")?.text == "7")
        #expect(bass.first("voice")?.text == "1")
        #expect(bass.first("name")?.text == "Bass Drum 1")
        #expect(bass.first("stem")?.text == "2")
        #expect(bass.first("shortcut")?.text == "B")

        let ride = try #require(drums.first { $0.attributes["pitch"] == "51" })
        #expect(ride.children.map(\.name) == ["head", "line", "voice", "name", "stem"])
        #expect(ride.first("head")?.text == "diamond")
        #expect(ride.first("name")?.text == "Ride (my chart)")
    }

    /// The §6a gate: a kit this package AUTHORS — `Score.blank`'s drum part, whose entries come entirely from
    /// `GMDrumset` — must still encode to the exact bytes it did before the drumset was a real type. The golden
    /// was recorded from the pre-change encoder; a diff here means a GM default moved.
    @Test("an authored drum part encodes byte-identically to the recorded golden")
    func authoredKitIsByteIdentical() throws {
        let template = BlankScoreTemplate(
            title: "Drums",
            parts: [.init(
                instrumentID: "drumset", longName: "Drum Kit",
                staves: [.init(clefType: "PERC", isPercussion: true)],
                isDrums: true,
            )],
            measureCount: 1,
        )
        let score = Score.blank(template)
        let encoded = XMLTreeSerializer.serialize(score.parts[0].instrument.encode())

        let goldenURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/drumsetEncodeGolden.xml")
        let golden = try String(contentsOf: goldenURL, encoding: .utf8)

        #expect(encoded == golden)
    }
```

If `authoredKitIsByteIdentical` cannot reach the golden file from the test bundle, guard the whole suite in
`#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT` and read it through `#filePath` exactly as
`EditReplayWebGoldenTests` does — that is the established pattern in this repo for a test that reads the
checkout.

- [ ] **Step 2: Run them to verify they fail**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter MSCXDrumsetRoundTripTests`
Expected: `reEncodesFaithfully` FAILS — the encoder still derives head/name from the GM tables, so the ride
comes back as `cross` / `Ride Cymbal 1` and the bass drum has no `<shortcut>`. `authoredKitIsByteIdentical`
should already PASS (nothing has changed the authored path yet); if it fails at this point, the golden was
recorded wrong — re-record it from `HEAD~2` before going on.

- [ ] **Step 3: Encode from the kit**

In `MSCXEncoder+Instrument.swift`, replace the body of the `for pitch in drumLineMap.keys.sorted()` loop, and
delete `gmDrumHead`, `gmDrumVoiceIndex` and `gmDrumName` entirely:

```swift
        // MuseScore Studio refuses to apply per-pitch line positions when a `<Drum>` entry lacks `<head>` /
        // `<voice>` / `<stem>` / `<name>` — every drum then renders on the same default line. `DrumsetEntry`
        // carries all four, filled from `GMDrumset` for an authored kit and from the file for a decoded one.
        // Element order matches MuseScore's own writer: head → line → voice → name → stem → shortcut.
        for pitch in drumset.keys.sorted() {
            guard let entry = drumset[pitch] else { continue }
            var drumChildren: [XMLTreeNode] = [
                XMLTreeNode(name: "head", text: entry.head),
                XMLTreeNode(name: "line", text: String(entry.line)),
                XMLTreeNode(name: "voice", text: String(entry.voiceIndex)),
                XMLTreeNode(name: "name", text: entry.name),
                XMLTreeNode(name: "stem", text: String(entry.stem)),
            ]
            if let shortcut = entry.shortcut {
                drumChildren.append(XMLTreeNode(name: "shortcut", text: shortcut))
            }
            children.append(XMLTreeNode(
                name: "Drum",
                attributes: ["pitch": String(pitch)],
                children: drumChildren,
            ))
        }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter MSCXDrumsetRoundTripTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Run the MSCX and importer suites**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter "MSCX|MidiImporter|PDFImporter|MSCZ"`
Expected: PASS.

**One expected behavior change, and it is wanted.** `PDFImporter.defaultDrumLineMap` names pitches 63 and 64,
which the GM table does not. The old encoder wrote no `<name>` for those (`gmDrumName` returned `nil`), which
means MuseScore Studio silently discarded the whole entry; the new one writes `Drum 63` / `Drum 64` so the
entry survives. If a PDF-import test asserts on the absence of `<name>`, update it and say so in the commit —
do not restore the old behavior.

- [ ] **Step 6: Commit**

```bash
git -C ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music add Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Instrument.swift Tests/SheetMusicTests/MSCXDrumsetRoundTripTests.swift
git -C ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music commit -m "feat(mscx): a drum kit encodes what it says, not what GM would have said"
```

---

## Task 5: `CreateVoice`

Spec §6b-3. `ReplaceVoiceElements` refuses a voice that does not exist and nothing in the package creates
one, so a drum key routed to voice 2 has nowhere to write in a bar that only ever had voice 1.

**Files:**
- Create: `Sources/SheetMusicCore/Editing/CreateVoice.swift`
- Modify: `Sources/SheetMusicCore/Editing/EditRefusal.swift`
- Modify: `Tests/SheetMusicTests/EditingTests/EditRefusalTests.swift`
- Create: `Tests/SheetMusicTests/EditingTests/CreateVoiceTests.swift`

**Interfaces:**
- Consumes: `EditCommand`, `ReplaceVoiceElements`, `EditRefusal.Reason`.
- Produces: `public struct CreateVoice: EditCommand` with
  `public init(staff: StaffAddress, measureIndex: Int, voiceIndex: Int)`, and
  `EditRefusal.Reason.voiceAlreadyExists(staff: StaffAddress, measureIndex: Int, voiceIndex: Int)` with code
  `"edit.voiceAlreadyExists"`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/EditingTests/CreateVoiceTests.swift`:

```swift
@testable import SheetMusicCore
import Testing

@Suite("CreateVoice")
struct CreateVoiceTests {
    private static let staff = EditingFixtures.staff0

    @Test("a new voice is one full-measure rest")
    func createsRestFilledVoice() throws {
        var score = EditingFixtures.fourQuarterRests()
        let command = CreateVoice(staff: Self.staff, measureIndex: 0, voiceIndex: 1)

        _ = try command.apply(to: &score)

        let voices = score.parts[0].staves[0].measures[0].voices
        #expect(voices.count == 2)
        #expect(voices[1].elements == [.rest(duration: .measure)])
        #expect(voices[1].tuplets.isEmpty)
    }

    @Test("undo removes the voice again")
    func inverseRemovesIt() throws {
        var score = EditingFixtures.fourQuarterRests()
        let before = score
        let inverse = try CreateVoice(staff: Self.staff, measureIndex: 0, voiceIndex: 1).apply(to: &score)

        _ = try inverse.apply(to: &score)

        #expect(score == before)
    }

    @Test("a voice that already exists is refused rather than overwritten")
    func refusesExistingVoice() {
        var score = EditingFixtures.fourQuarterRests()
        #expect(throws: SheetMusicError.self) {
            _ = try CreateVoice(staff: Self.staff, measureIndex: 0, voiceIndex: 0).apply(to: &score)
        }
        #expect(score.parts[0].staves[0].measures[0].voices.count == 1)
    }

    @Test("a voice index that would leave a gap is refused")
    func refusesGap() {
        var score = EditingFixtures.fourQuarterRests()
        #expect(throws: SheetMusicError.self) {
            _ = try CreateVoice(staff: Self.staff, measureIndex: 0, voiceIndex: 2).apply(to: &score)
        }
    }

    @Test("a measure that does not exist is refused")
    func refusesMissingMeasure() {
        var score = EditingFixtures.fourQuarterRests()
        #expect(throws: SheetMusicError.self) {
            _ = try CreateVoice(staff: Self.staff, measureIndex: 9, voiceIndex: 1).apply(to: &score)
        }
    }

    @Test("the new voice fills a pickup bar to the bar's own length")
    func fillsIrregularMeasure() throws {
        var score = EditingFixtures.fourQuarterRests()
        score.parts[0].staves[0].measures[0].actualLength = Fraction(numerator: 1, denominator: 4)
        score.parts[0].staves[0].measures[0].irregular = true

        _ = try CreateVoice(staff: Self.staff, measureIndex: 0, voiceIndex: 1).apply(to: &score)

        // `.measure` is "however long this bar is", so the pickup needs no special case — the same spelling
        // `Score.blank` writes into an anacrusis.
        #expect(score.parts[0].staves[0].measures[0].voices[1].elements == [.rest(duration: .measure)])
    }
}
```

If `Measure.actualLength` is not a settable `Fraction?` under exactly that name, read
`Sources/SheetMusicCore/Score/Measure.swift` and adapt that one test; the assertion it makes does not change.

- [ ] **Step 2: Run it to verify it fails**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter CreateVoiceTests`
Expected: FAIL to build — "cannot find 'CreateVoice' in scope".

- [ ] **Step 3: Add the refusal reason**

In `EditRefusal.swift`, add to `Reason` (after `.emptyRehearsalMarkText`):

```swift
        /// `CreateVoice` was asked for a voice the measure already has. Distinct from `.targetNotFound` for the
        /// reason `.cannotRemoveLastPart` is: the voice IS there, and a host saying otherwise would be telling
        /// the user something untrue — the caller should be writing into it rather than creating it.
        case voiceAlreadyExists(staff: StaffAddress, measureIndex: Int, voiceIndex: Int)
```

add to `code`:

```swift
        case .voiceAlreadyExists:
            "edit.voiceAlreadyExists"
```

and to `reasonDescription`:

```swift
        case let .voiceAlreadyExists(staff, measureIndex, voiceIndex):
            "measure \(measureIndex) of \(staff) already has voice \(voiceIndex)"
```

In `Tests/SheetMusicTests/EditingTests/EditRefusalTests.swift`, add one entry to `sampleReasons`:

```swift
            .voiceAlreadyExists(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 1,
            ),
```

- [ ] **Step 4: Write `CreateVoice.swift`**

```swift
import SheetMusicFoundation

/// Append a voice to one measure, filled with a single full-measure rest.
///
/// `ReplaceVoiceElements` requires the target voice to already exist and nothing else in this package creates
/// one, so this is what a write into voice 2 of a bar that has only voice 1 has to go through first — the case
/// drum note entry hits constantly, since a bass drum belongs to the feet voice whether or not the bar has one.
///
/// Voices are an array, so only the NEXT index can be created: asking for voice 2 of a one-voice measure would
/// leave a hole where voice 1 should be, and is refused. Asking for a voice that already exists is refused too,
/// rather than quietly emptying it.
///
/// The fill is one `.measure` rest — "however long this bar is" — which is what `Score.blank` writes into an
/// empty bar and what makes a pickup measure need no special case.
public struct CreateVoice: EditCommand {
    public let staff: StaffAddress
    public let measureIndex: Int
    public let voiceIndex: Int

    public init(staff: StaffAddress, measureIndex: Int, voiceIndex: Int) {
        self.staff = staff
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex, elementIndex: 0)
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard score.parts.indices.contains(staff.partIndex),
              score.parts[staff.partIndex].staves.indices.contains(staff.staffIndexInPart)
        else {
            throw Self.refused(.staffNotFound(staff))
        }
        let p = staff.partIndex
        let s = staff.staffIndexInPart
        guard score.parts[p].staves[s].measures.indices.contains(measureIndex) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        let voiceCount = score.parts[p].staves[s].measures[measureIndex].voices.count
        guard voiceIndex >= voiceCount else {
            throw Self.refused(.voiceAlreadyExists(
                staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex,
            ))
        }
        guard voiceIndex == voiceCount else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        score.parts[p].staves[s].measures[measureIndex].voices.append(
            Voice(elements: [.rest(duration: .measure)]),
        )
        return RemoveVoice(staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex)
    }
}

/// `CreateVoice`'s inverse: drop the LAST voice of a measure again. Not public — a host has no reason to
/// remove a voice outright, and `CreateVoice` is the only thing that can put the score in the state this
/// undoes.
struct RemoveVoice: EditCommand {
    let staff: StaffAddress
    let measureIndex: Int
    let voiceIndex: Int

    var affectedLocation: VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex, elementIndex: 0)
    }

    @discardableResult
    func apply(to score: inout Score) throws -> any EditCommand {
        guard score.parts.indices.contains(staff.partIndex),
              score.parts[staff.partIndex].staves.indices.contains(staff.staffIndexInPart)
        else {
            throw Self.refused(.staffNotFound(staff))
        }
        let p = staff.partIndex
        let s = staff.staffIndexInPart
        guard score.parts[p].staves[s].measures.indices.contains(measureIndex),
              score.parts[p].staves[s].measures[measureIndex].voices.indices.contains(voiceIndex),
              voiceIndex == score.parts[p].staves[s].measures[measureIndex].voices.count - 1
        else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        score.parts[p].staves[s].measures[measureIndex].voices.removeLast()
        return CreateVoice(staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex)
    }
}
```

Note the asymmetry that makes the round trip exact: `RemoveVoice` drops the voice wholesale rather than
restoring its contents, because `CreateVoice` is the only thing that could have created it and it created it
empty. If a later command writes into that voice, undo unwinds those writes first — the undo stack is a
stack.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter "CreateVoiceTests|EditRefusalTests"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git -C ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music add Sources/SheetMusicCore/Editing/CreateVoice.swift Sources/SheetMusicCore/Editing/EditRefusal.swift Tests/SheetMusicTests/EditingTests/CreateVoiceTests.swift Tests/SheetMusicTests/EditingTests/EditRefusalTests.swift
git -C ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music commit -m "feat: a measure can grow a voice, so a feet-voice write has somewhere to land"
```

---

## Task 6: `SplitRest`

Spec §6b-4. The column caret lands on a tick, not on an element, so a caret inside a half rest has to be able
to make a slot boundary there before anything can be written.

**Files:**
- Create: `Sources/SheetMusicCore/Editing/SplitRest.swift`
- Create: `Tests/SheetMusicTests/EditingTests/SplitRestTests.swift`

**Interfaces:**
- Consumes: `DurationChangeAlgorithm.alignedRests(forTicks:rtickStart:division:)`,
  `DurationChangeAlgorithm.tickOffset(...)`, `DurationChangeAlgorithm.ensureNotInsideTuplet(...)`,
  `ReplaceVoiceElements`, `Score.effectiveMeasureDuration(at:measureIndex:)`.
- Produces: `public struct SplitRest: EditCommand` with
  `public init(at location: VoiceElementID, tickOffset: Int)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/EditingTests/SplitRestTests.swift`:

```swift
@testable import SheetMusicCore
import Testing

@Suite("SplitRest")
struct SplitRestTests {
    private static func halfRestScore() -> Score {
        var score = EditingFixtures.fourQuarterRests()
        // Elements [1...4] are quarter rests; make [1] a half and drop [2] so the bar still totals 4/4.
        score.parts[0].staves[0].measures[0].voices[0].elements = [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .half),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
        ]
        return score
    }

    private static func slot(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    @Test("a half rest split at its midpoint becomes two quarter rests")
    func splitsAtMidpoint() throws {
        var score = Self.halfRestScore()

        _ = try SplitRest(at: Self.slot(1), tickOffset: 480).apply(to: &score)

        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        #expect(elements == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
        ])
    }

    @Test("an off-beat split is spelled beat-aligned, not greedily")
    func splitsBeatAligned() throws {
        var score = Self.halfRestScore()

        // A quarter into the bar plus an eighth: the tail is 3 eighths, which aligns as eighth + quarter.
        _ = try SplitRest(at: Self.slot(1), tickOffset: 240).apply(to: &score)

        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        #expect(elements[1] == .rest(duration: .eighth))
        #expect(elements[2] == .rest(duration: .eighth))
        #expect(elements[3] == .rest(duration: .quarter))
    }

    @Test("undo restores the single rest")
    func inverseRestores() throws {
        var score = Self.halfRestScore()
        let before = score
        let inverse = try SplitRest(at: Self.slot(1), tickOffset: 480).apply(to: &score)

        _ = try inverse.apply(to: &score)

        #expect(score == before)
    }

    @Test("a full-measure rest splits against the bar's own length")
    func splitsMeasureRest() throws {
        var score = EditingFixtures.fullMeasureRest()

        _ = try SplitRest(at: Self.slot(1), tickOffset: 480).apply(to: &score)

        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        #expect(elements.count == 4)
        #expect(elements[1] == .rest(duration: .quarter))
    }

    @Test("an offset of zero, or past the rest, is refused")
    func refusesOutOfRangeOffset() {
        var score = Self.halfRestScore()
        for offset in [0, 960, 1200, -1] {
            #expect(throws: SheetMusicError.self) {
                _ = try SplitRest(at: Self.slot(1), tickOffset: offset).apply(to: &score)
            }
        }
    }

    @Test("a chord is refused — this splits rests only")
    func refusesChord() {
        var score = EditingFixtures.chordAtIndex1()
        #expect(throws: SheetMusicError.self) {
            _ = try SplitRest(at: Self.slot(1), tickOffset: 240).apply(to: &score)
        }
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter SplitRestTests`
Expected: FAIL to build — "cannot find 'SplitRest' in scope".

- [ ] **Step 3: Write `SplitRest.swift`**

```swift
import SheetMusicFoundation

/// Split the rest at `location` into two beat-aligned runs, with a slot boundary `tickOffset` ticks into it.
///
/// The column caret (spec §5.4) lands on a TICK, not on an element, so a caret sitting inside a half rest has
/// nothing to write into: every write command in this package targets a slot. This makes the slot.
///
/// Both halves are spelled the way MuseScore spells a gap — `DurationChangeAlgorithm.alignedRests`, largest
/// power-of-two duration that both fits and lands on its own boundary — so a split an eighth into a half bar
/// produces `eighth + eighth + quarter`, not `eighth + dotted-quarter`.
///
/// `.measure` is resolved against the bar before the arithmetic: a full-measure rest is "however long this bar
/// is", and asking it for ticks without resolving traps.
///
/// The inverse is a whole-voice `ReplaceVoiceElements`, which restores the rest's original SPELLING — a
/// `.measure` rest comes back as `.measure`, not as a same-length whole rest — and puts back any tuplet spans
/// the splice shifted.
public struct SplitRest: EditCommand {
    public let location: VoiceElementID
    public let tickOffset: Int

    public init(at location: VoiceElementID, tickOffset: Int) {
        self.location = location
        self.tickOffset = tickOffset
    }

    public var affectedLocation: VoiceElementID { location }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let voice = DurationChangeAlgorithm.voice(at: location, in: score) else {
            throw Self.refused(.targetNotFound(location))
        }
        guard voice.elements.indices.contains(location.elementIndex),
              case let .chord(rest) = voice.elements[location.elementIndex],
              rest.notes.isEmpty
        else {
            throw Self.refused(.wrongElementKind(at: location, expected: .rest))
        }
        try DurationChangeAlgorithm.ensureNotInsideTuplet(location, in: score)

        let measureDuration = score.effectiveMeasureDuration(
            at: location.staff, measureIndex: location.measureIndex,
        )
        let totalTicks = rest.duration.resolved(in: measureDuration).ticks(division: score.division)
        guard tickOffset > 0, tickOffset < totalTicks else {
            throw Self.refused(.insufficientRoom(neededTicks: tickOffset, availableTicks: totalTicks))
        }

        let rtickStart = DurationChangeAlgorithm.tickOffset(
            in: voice, upTo: location.elementIndex, division: score.division,
            measureDuration: measureDuration,
        )
        let head = DurationChangeAlgorithm.alignedRests(
            forTicks: tickOffset, rtickStart: rtickStart, division: score.division,
        )
        let tail = DurationChangeAlgorithm.alignedRests(
            forTicks: totalTicks - tickOffset, rtickStart: rtickStart + tickOffset,
            division: score.division,
        )

        var elements = voice.elements
        elements.replaceSubrange(location.elementIndex ... location.elementIndex, with: head + tail)
        let inverse = ReplaceVoiceElements(
            staff: location.staff,
            measureIndex: location.measureIndex,
            voiceIndex: location.voiceIndex,
            elements: voice.elements,
            tuplets: voice.tuplets,
        )
        let write = ReplaceVoiceElements(
            staff: location.staff,
            measureIndex: location.measureIndex,
            voiceIndex: location.voiceIndex,
            elements: elements,
            tuplets: voice.tuplets,
        )
        _ = try write.apply(to: &score)
        return inverse
    }
}
```

`DurationChangeAlgorithm.voice(at:in:)`, `.tickOffset(in:upTo:division:measureDuration:)` and
`.ensureNotInsideTuplet(_:in:)` are `internal` today with signatures that may differ slightly from the calls
above — read `Sources/SheetMusicCore/Editing/DurationChangeAlgorithm.swift` and match them exactly rather
than changing their signatures. `SplitRest` is in the same module, so no access widening is needed.

Tuplets are left untouched deliberately: `ensureNotInsideTuplet` has already refused a rest inside one, and a
tuplet span LATER in the voice indexes into `elements`, so if the splice changes the element count, those
spans need the same shift `DurationChangeAlgorithm.compute` applies. If `SplitRestTests` grows a case with a
following tuplet and it fails, shift the spans past `location.elementIndex` by `head.count + tail.count - 1`
in `write.tuplets` — do not drop them.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter SplitRestTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git -C ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music add Sources/SheetMusicCore/Editing/SplitRest.swift Tests/SheetMusicTests/EditingTests/SplitRestTests.swift
git -C ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music commit -m "feat: a rest splits at a tick, so a column caret has a slot to write into"
```

---

## Task 7: `SetNoteHead`

Spec §6b-5. `InputNote` takes `pitch` and `tpc` only, so a cross-notehead hi-hat cannot be written at all.
Rather than widen `InputNote`'s wire payload — which would change `InputNoteIntentWire`'s committed byte
layout and force every replay golden to be re-recorded — the head is a second command, composed with the
write into one undo step. Both `.inputNote` and `.addNoteToChord` put the new note at a deterministic
`NoteID`, so the composite knows where to aim.

**Files:**
- Create: `Sources/SheetMusicCore/Editing/SetNoteHead.swift`
- Create: `Tests/SheetMusicTests/EditingTests/SetNoteHeadTests.swift`

**Interfaces:**
- Consumes: `NoteID`, `EditCommand`.
- Produces: `public struct SetNoteHead: EditCommand` with
  `public init(at location: NoteID, headType: String?)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/EditingTests/SetNoteHeadTests.swift`:

```swift
@testable import SheetMusicCore
import Testing

@Suite("SetNoteHead")
struct SetNoteHeadTests {
    @Test("the head is written onto the note")
    func writesHead() throws {
        var score = EditingFixtures.chordAtIndex1()

        _ = try SetNoteHead(at: EditingFixtures.noteID(element: 1), headType: "cross").apply(to: &score)

        guard case let .chord(chord) = score[VoiceElementID(EditingFixtures.noteID(element: 1))] else {
            Issue.record("expected a chord"); return
        }
        #expect(chord.notes[0].headType == "cross")
    }

    @Test("undo restores the head the note had, including none")
    func inverseRestores() throws {
        var score = EditingFixtures.chordAtIndex1()
        let before = score
        let inverse = try SetNoteHead(
            at: EditingFixtures.noteID(element: 1), headType: "cross",
        ).apply(to: &score)

        _ = try inverse.apply(to: &score)

        #expect(score == before)
    }

    @Test("nil clears an existing head")
    func clearsHead() throws {
        var score = EditingFixtures.chordAtIndex1()
        _ = try SetNoteHead(at: EditingFixtures.noteID(element: 1), headType: "cross").apply(to: &score)

        _ = try SetNoteHead(at: EditingFixtures.noteID(element: 1), headType: nil).apply(to: &score)

        guard case let .chord(chord) = score[VoiceElementID(EditingFixtures.noteID(element: 1))] else {
            Issue.record("expected a chord"); return
        }
        #expect(chord.notes[0].headType == nil)
    }

    @Test("only the addressed note in the chord changes")
    func leavesSiblingsAlone() throws {
        var score = EditingFixtures.twoNoteChordAtIndex1()

        _ = try SetNoteHead(
            at: EditingFixtures.noteID(element: 1, noteIndex: 1), headType: "cross",
        ).apply(to: &score)

        guard case let .chord(chord) = score[VoiceElementID(EditingFixtures.noteID(element: 1))] else {
            Issue.record("expected a chord"); return
        }
        #expect(chord.notes[0].headType == nil)
        #expect(chord.notes[1].headType == "cross")
    }

    @Test("a note that is not there is refused")
    func refusesMissingNote() {
        var score = EditingFixtures.fourQuarterRests()
        #expect(throws: SheetMusicError.self) {
            _ = try SetNoteHead(at: EditingFixtures.noteID(element: 1), headType: "cross").apply(to: &score)
        }
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter SetNoteHeadTests`
Expected: FAIL to build — "cannot find 'SetNoteHead' in scope".

- [ ] **Step 3: Write `SetNoteHead.swift`**

```swift
import SheetMusicFoundation

/// Write (or clear) one note's notehead override — MuseScore's `<head>`, which round-trips through MSCX on both
/// the decode and encode side.
///
/// The reason it exists: `InputNote` and `AddNoteToChord` carry `pitch` and `tpc` only, so a cross-notehead
/// hi-hat cannot be written by either. Composing the write with this one is what makes a drum key's whole
/// meaning — pitch, head and voice — reachable in a single undo step, without widening a wire payload whose
/// byte layout is already committed.
///
/// `nil` clears the override, which lets the note fall back to the duration-based head the engraver would draw.
///
/// > Note: This command is sugar over `ReplaceVoiceElement` + `CompositeEditCommand`. It exists to give the
/// > operation a domain-meaningful name and to centralise the small bit of validation it performs; callers can
/// > equally well construct the equivalent Composite directly. See `docs/edit-commands.md` for the policy.
public struct SetNoteHead: EditCommand {
    public let location: NoteID
    public let headType: String?

    public init(at location: NoteID, headType: String?) {
        self.location = location
        self.headType = headType
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(location)
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let oldNote = score[location] else {
            throw Self.refused(.noteNotFound(location))
        }
        let veID = VoiceElementID(location)
        guard case var .chord(chord) = score[veID] else {
            throw Self.refused(.wrongElementKind(at: veID, expected: .chord))
        }
        chord.notes[location.noteIndexInChord].headType = headType
        score[veID] = .chord(chord)
        return SetNoteHead(at: location, headType: oldNote.headType)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter SetNoteHeadTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git -C ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music add Sources/SheetMusicCore/Editing/SetNoteHead.swift Tests/SheetMusicTests/EditingTests/SetNoteHeadTests.swift
git -C ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music commit -m "feat: a note's head is writable, so a cross-head hi-hat can be entered"
```

---

## Task 8: intents 25 / 26 / 27 and their wire encoding

The commands are useless to Android until they cross the JNI boundary as scalars. This appends three
`EditIntent` cases, their planning, and their wire payloads.

**Files:**
- Modify: `Sources/SheetMusicCore/Editing/EditIntent.swift`
- Create: `Sources/SheetMusicCore/Editing/ScoreEditSession+DrumPlanning.swift`
- Modify: `Sources/SheetMusicCore/Editing/ScoreEditSession+Planning.swift`
- Modify: `Sources/SheetMusicEditWire/Intent/EditIntentCodec.swift`
- Create: `Tests/SheetMusicTests/EditingTests/DrumIntentTests.swift`
- Modify: `Tests/SheetMusicTests/AndroidJNI/EditIntentCodecTests.swift`

**Interfaces:**
- Consumes: `CreateVoice`, `SplitRest`, `SetNoteHead`.
- Produces:
  - `EditIntent.createVoice(staff: StaffAddress, measureIndex: Int, voiceIndex: Int)` — wire index 25.
  - `EditIntent.splitRest(at: VoiceElementID, tickOffset: Int)` — wire index 26.
  - `EditIntent.setNoteHead(at: NoteID, headType: String?)` — wire index 27.
  - `public struct CreateVoiceIntentWire`, `SplitRestIntentWire`, `SetNoteHeadIntentWire`.

- [ ] **Step 1: Re-verify no other branch has claimed 25**

Run, from the ssm worktree:

```bash
git branch --format='%(refname:short)' | while read b; do printf '%s ' "$b"; git show "$b:Sources/SheetMusicEditWire/Intent/EditIntentCodec.swift" 2>/dev/null | grep -cE "^/// 2[5-9] = "; done
```

Expected: every line ends in `0`. If any branch prints non-zero, STOP and report — the indices have to be
renegotiated, not guessed.

- [ ] **Step 2: Write the failing planning test**

Create `Tests/SheetMusicTests/EditingTests/DrumIntentTests.swift`:

```swift
@testable import SheetMusicCore
import Testing

@Suite("Drum note-entry intents")
struct DrumIntentTests {
    private static let staff = EditingFixtures.staff0

    private static func slot(measure: Int = 0, voice: Int = 0, element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: voice, elementIndex: element)
    }

    @Test("createVoice grows the measure")
    func createVoiceApplies() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())

        #expect(session.apply(.createVoice(staff: Self.staff, measureIndex: 0, voiceIndex: 1)))

        #expect(session.score.parts[0].staves[0].measures[0].voices.count == 2)
    }

    /// A voice that is already there is nothing to do, not a refusal: the drum pad composes
    /// `[createVoice, writeNote]` on every key press and cannot know which bars already have the feet voice.
    /// Refusing here would take the note write down with it, since a composite is all-or-nothing.
    @Test("createVoice on a voice that exists plans to nothing rather than refusing")
    func createVoicePlansToNothing() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())

        #expect(!session.apply(.createVoice(staff: Self.staff, measureIndex: 0, voiceIndex: 0)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
        #expect(session.score.parts[0].staves[0].measures[0].voices.count == 1)
    }

    @Test("splitRest makes a slot boundary at the caret's tick")
    func splitRestApplies() {
        var score = EditingFixtures.fourQuarterRests()
        score.parts[0].staves[0].measures[0].voices[0].elements = [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .half),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
        ]
        let session = ScoreEditSession(score: score)

        #expect(session.apply(.splitRest(at: Self.slot(element: 1), tickOffset: 480)))

        #expect(session.score.parts[0].staves[0].measures[0].voices[0].elements.count == 5)
    }

    @Test("setNoteHead writes the head")
    func setNoteHeadApplies() {
        let session = ScoreEditSession(score: EditingFixtures.chordAtIndex1())

        #expect(session.apply(.setNoteHead(at: EditingFixtures.noteID(element: 1), headType: "cross")))

        guard case let .chord(chord) = session.score[Self.slot(element: 1)] else {
            Issue.record("expected a chord"); return
        }
        #expect(chord.notes[0].headType == "cross")
    }

    /// The shape the drum pad actually issues: write the note, then stamp its head, as ONE undo step. The head
    /// intent addresses a note that does not exist when the composite is PLANNED — planning builds commands from
    /// scalars without touching the score, and the composite applies them in order, so by the time
    /// `SetNoteHead` runs the note is there.
    @Test("a note and its head are one undo step")
    func writeWithHeadIsOneUndoStep() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        let rest = EditingFixtures.restID(element: 1)
        let note = EditingFixtures.noteID(element: 1)

        #expect(session.apply(.composite([
            .inputNote(at: rest, pitch: 42, tpc: 14, duration: .quarter),
            .setNoteHead(at: note, headType: "cross"),
        ])))

        guard case let .chord(chord) = session.score[Self.slot(element: 1)] else {
            Issue.record("expected a chord"); return
        }
        #expect(chord.notes[0].pitch == 42)
        #expect(chord.notes[0].headType == "cross")

        #expect(session.undo())
        #expect(session.score == EditingFixtures.fourQuarterRests())
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter DrumIntentTests`
Expected: FAIL to build — `EditIntent` has no member `createVoice`.

- [ ] **Step 4: Append the three intent cases**

At the END of `EditIntent`'s case list in `Sources/SheetMusicCore/Editing/EditIntent.swift`:

```swift
    /// Append a voice, filled with one full-measure rest, to `measureIndex` of `staff`.
    ///
    /// Plans to nothing when the measure already has that voice — the same rule `.setKeySignature` and
    /// `.movePart` apply to an edit that would restore the score to itself, and the one that lets a drum key
    /// compose `[createVoice, write]` unconditionally: a composite is all-or-nothing, so a refusal here would
    /// take the write with it. A voice index that would leave a hole below it is refused as `.targetNotFound`
    /// by `CreateVoice.apply`, so one place states the range.
    case createVoice(staff: StaffAddress, measureIndex: Int, voiceIndex: Int)

    /// Split the rest at `at` so a slot boundary falls `tickOffset` ticks into it, both halves spelled
    /// beat-aligned. What a column caret landing INSIDE a rest needs before anything can be written there,
    /// since every write command in this package targets a slot rather than a tick.
    ///
    /// An offset of zero, or one at or past the rest's own length, is refused as `.insufficientRoom` by
    /// `SplitRest.apply`; a slot holding a chord is refused as `.wrongElementKind`.
    case splitRest(at: VoiceElementID, tickOffset: Int)

    /// Write `headType` as one note's notehead override, or clear it with `nil`.
    ///
    /// Composed after `.inputNote` / `.addNoteToChord` — as one `.composite`, so it is one undo step — this is
    /// how a drum key writes a cross-head hi-hat: those two intents carry pitch and spelling only, and widening
    /// their wire payload would move byte layouts that are already committed.
    case setNoteHead(at: NoteID, headType: String?)
```

- [ ] **Step 5: Write the planning**

Create `Sources/SheetMusicCore/Editing/ScoreEditSession+DrumPlanning.swift`:

```swift
import SheetMusicFoundation

/// The drum note-entry intents' planning half — `EditIntent` → `EditCommand` for `.createVoice`,
/// `.splitRest` and `.setNoteHead`.
///
/// Split out of `ScoreEditSession+Planning.swift` for the reason the signature and rehearsal-mark planners
/// are: that file's switch is at SwiftLint's body budget, and these three share a subject (making a drum key's
/// whole meaning reachable) rather than a mechanism.
extension ScoreEditSession {
    static func drumInputCommand(for intent: EditIntent, in score: Score) -> (any EditCommand)? {
        switch intent {
        case let .createVoice(staff, measureIndex, voiceIndex):
            // Nothing to do when the voice is already there. The refusals that DO belong to this intent — a
            // gap below the index, a measure that isn't there — stay in `CreateVoice.apply`, so one place
            // states each rule.
            guard let staffRef = score.staff(at: staff),
                  staffRef.measures.indices.contains(measureIndex),
                  voiceIndex >= staffRef.measures[measureIndex].voices.count
            else {
                return nil
            }
            return CreateVoice(staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex)
        case let .splitRest(location, tickOffset):
            return SplitRest(at: location, tickOffset: tickOffset)
        case let .setNoteHead(location, headType):
            return SetNoteHead(at: location, headType: headType)
        default:
            return nil
        }
    }
}
```

`score.staff(at:)` may not exist under that name — check
`grep -n "func staff(" Sources/SheetMusicCore/Score/*.swift` and use whatever accessor `ReplaceVoiceElements`
uses to reach `score.parts[p].staves[s]`; if there is none, index the arrays directly with the same
`indices.contains` guards `CreateVoice.apply` uses.

**`default: return nil` is a hazard here**, the one `ScoreEditSession+Planning`'s doc comment warns about for
`structuralCommand`: an intent nobody wired would resolve to "nothing to apply" instead of failing to build.
It is acceptable ONLY because the caller's switch already narrows to these three cases. Keep the caller's
`case` list and this function's cases in step.

- [ ] **Step 6: Dispatch from the main switch**

In `ScoreEditSession+Planning.swift`'s `command(for:in:depth:)`, add one case:

```swift
        case .createVoice, .splitRest, .setNoteHead:
            // Drum note entry's three additions — a voice to write into, a slot at the caret's tick, and the
            // note's head. Factored into `drumInputCommand` for the same reason the shape-changing intents are
            // factored into `structuralCommand`: to keep this switch under SwiftLint's body budget.
            return drumInputCommand(for: intent, in: score)
```

- [ ] **Step 7: Run the planning test**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter DrumIntentTests`
Expected: PASS, 5 tests. If `createVoicePlansToNothing` reports a different refusal reason than
`.nothingToApply`, read what `ScoreEditSession.apply` records for a `nil` plan and assert that instead — do
not change the session's behavior.

- [ ] **Step 8: Write the failing wire round-trip test**

In `Tests/SheetMusicTests/AndroidJNI/EditIntentCodecTests.swift`, add — matching the file's existing style
for the M4 pair:

```swift
    @Test("createVoice round-trips")
    func createVoiceRoundTrips() throws {
        let intent = EditIntent.createVoice(
            staff: StaffAddress(partIndex: 1, staffIndexInPart: 0), measureIndex: 7, voiceIndex: 1,
        )
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
    }

    @Test("splitRest round-trips")
    func splitRestRoundTrips() throws {
        let intent = EditIntent.splitRest(
            at: VoiceElementID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 2, voiceIndex: 1, elementIndex: 3,
            ),
            tickOffset: 240,
        )
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
    }

    @Test("setNoteHead round-trips, with and without a head")
    func setNoteHeadRoundTrips() throws {
        let note = NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 1, voiceIndex: 0, elementIndex: 2, noteIndexInChord: 1,
        )
        for head in ["cross", nil] as [String?] {
            let intent = EditIntent.setNoteHead(at: note, headType: head)
            #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
        }
    }
```

- [ ] **Step 9: Run it to verify it fails**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter EditIntentCodecTests`
Expected: FAIL to build — `EditIntentWire` has no case for the new intents (the `init(from:)` switch is
exhaustive, so it will not compile once the enum grew).

- [ ] **Step 10: Add the wire payloads**

In `Sources/SheetMusicEditWire/Intent/EditIntentCodec.swift`:

Append to the doc-comment index table:

```
/// 25 = createVoice(CreateVoiceIntentWire)
/// 26 = splitRest(SplitRestIntentWire)
/// 27 = setNoteHead(SetNoteHeadIntentWire)
```

and extend the sentence below it: `… 23…24 for M4 rehearsal marks and 25…27 for M6 drum note entry; 0…4
predate them all …`.

Append the three payload layouts to the doc comment, in the style of `SetRehearsalMarkIntentWire`'s:

```
/// `CreateVoiceIntentWire` (`createVoice`'s payload):
/// ```
/// tag 1: staff         StaffAddressWire, see layout above
/// tag 2: measureIndex  i32, zig-zag varint
/// tag 3: voiceIndex    i32, zig-zag varint
/// ```
///
/// `SplitRestIntentWire` (`splitRest`'s payload):
/// ```
/// tag 1: location    VoiceElementIDWire, see layout above
/// tag 2: tickOffset  i32, zig-zag varint — ticks from the START of the rest, never 0 and never its length
/// ```
///
/// `SetNoteHeadIntentWire` (`setNoteHead`'s payload):
/// ```
/// tag 1: location  NoteIDWire, see PathIDCodecs.swift
/// tag 2: hasHead   u8, varint — 0 = clear the override, 1 = write `head`
/// tag 3: head      string — UTF-8; the encoder writes "" when hasHead == 0, so a byte-for-byte parity check
///                  between platforms should expect that empty string, not an absent tag
/// ```
```

Add the three cases to `EditIntentWire`'s `@WireFormatChoice` enum, in this order, after
`removeRehearsalMark`:

```swift
    case createVoice(CreateVoiceIntentWire)
    case splitRest(SplitRestIntentWire)
    case setNoteHead(SetNoteHeadIntentWire)
```

Add to `init(from:)`:

```swift
        case let .createVoice(staff, measureIndex, voiceIndex):
            self = .createVoice(CreateVoiceIntentWire(
                staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex,
            ))
        case let .splitRest(location, tickOffset):
            self = .splitRest(SplitRestIntentWire(location: location, tickOffset: tickOffset))
        case let .setNoteHead(location, headType):
            self = .setNoteHead(SetNoteHeadIntentWire(location: location, headType: headType))
```

Add to `decoded()`:

```swift
        case let .createVoice(wire):
            let decoded = try wire.decoded()
            return .createVoice(
                staff: decoded.staff, measureIndex: decoded.measureIndex, voiceIndex: decoded.voiceIndex,
            )
        case let .splitRest(wire):
            let decoded = try wire.decoded()
            return .splitRest(at: decoded.location, tickOffset: decoded.tickOffset)
        case let .setNoteHead(wire):
            let decoded = try wire.decoded()
            return .setNoteHead(at: decoded.location, headType: decoded.headType)
```

Append the three structs at the end of the file:

```swift
/// `createVoice`'s payload — which measure of which staff grows a voice, and which index it takes.
@WireFormat
public struct CreateVoiceIntentWire {
    public var staff: StaffAddressWire
    public var measureIndex: Int32
    public var voiceIndex: Int32

    public init(staff: StaffAddress, measureIndex: Int, voiceIndex: Int) {
        self.staff = StaffAddressWire(staff)
        self.measureIndex = Int32(measureIndex)
        self.voiceIndex = Int32(voiceIndex)
    }

    public func decoded() throws -> (staff: StaffAddress, measureIndex: Int, voiceIndex: Int) {
        (staff: try staff.decoded(), measureIndex: Int(measureIndex), voiceIndex: Int(voiceIndex))
    }
}

/// `splitRest`'s payload — the rest, and how far into it the new slot boundary falls.
@WireFormat
public struct SplitRestIntentWire {
    public var location: VoiceElementIDWire
    public var tickOffset: Int32

    public init(location: VoiceElementID, tickOffset: Int) {
        self.location = VoiceElementIDWire(location)
        self.tickOffset = Int32(tickOffset)
    }

    public func decoded() throws -> (location: VoiceElementID, tickOffset: Int) {
        (location: try location.decoded(), tickOffset: Int(tickOffset))
    }
}

/// `setNoteHead`'s payload — the note, and the notehead override to write onto it.
///
/// The head is spelled as a presence flag plus a string rather than as an `Optional<String>` for the reason
/// `InputNoteIntentWire` spells its optional duration that way: the macro emits `unknownTag` for any missing
/// non-optional field, and "clear the override" has to be distinguishable from "write an empty head".
@WireFormat
public struct SetNoteHeadIntentWire {
    public var location: NoteIDWire
    public var hasHead: UInt8
    public var head: String

    public init(location: NoteID, headType: String?) {
        self.location = NoteIDWire(location)
        hasHead = headType == nil ? 0 : 1
        head = headType ?? ""
    }

    public func decoded() throws -> (location: NoteID, headType: String?) {
        (location: try location.decoded(), headType: hasHead == 0 ? nil : head)
    }
}
```

`StaffAddressWire` / `VoiceElementIDWire` / `NoteIDWire` initializers and `decoded()` may be non-throwing or
take labelled arguments — read `Path/StaffAddressCodec.swift` and `Path/PathIDCodecs.swift` and match them
exactly rather than adding `try` that is not needed (the compiler will say so either way).

- [ ] **Step 11: Run the codec tests to verify they pass**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter "EditIntentCodecTests|DrumIntentTests"`
Expected: PASS.

- [ ] **Step 12: Commit**

```bash
git -C ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music add Sources/SheetMusicCore/Editing/EditIntent.swift Sources/SheetMusicCore/Editing/ScoreEditSession+DrumPlanning.swift Sources/SheetMusicCore/Editing/ScoreEditSession+Planning.swift Sources/SheetMusicEditWire/Intent/EditIntentCodec.swift Tests/SheetMusicTests/EditingTests/DrumIntentTests.swift Tests/SheetMusicTests/AndroidJNI/EditIntentCodecTests.swift
git -C ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music commit -m "feat: drum note-entry edit intents, planners and wire encoding"
```

---

## Task 9: replay goldens, docs and the full gate

The replay script is what proves the Android image plans identical commands from identical bytes. Three new
intents that never appear in it are three intents nothing cross-checks.

**Files:**
- Modify: `Tests/SheetMusicTests/EditingTests/EditReplayScript.swift`
- Modify: `Android/SheetMusicAndroid/src/androidTest/assets/editReplay/goldens.txt` (recorded)
- Create: `Android/SheetMusicAndroid/src/androidTest/assets/editReplay/step-NN.bin` (recorded)
- Modify: `Android/SheetMusicAndroid/src/androidTest/java/com/jiyimeta/sheetmusic/EditSessionReplayTest.kt`
- Modify: `Web/sheet-music-web/test/fixtures/edit-replay.json` (recorded)
- Modify: `docs/edit-commands.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: everything from tasks 1–8.
- Produces: nothing new.

- [ ] **Step 1: Learn the score's shape at the end of the current script**

The tail of `EditReplayScript` re-bars the score (steps 12a/12b) and settles it at four measures, so the
element indices there are not the ones the fixture started with. Print them rather than guessing. Add
temporarily to `DrumIntentTests`:

```swift
    @Test("SHAPE — delete me")
    func shape() throws {
        let session = ScoreEditSession(score: EditingFixtures.replayFixture())
        for step in EditReplayScript.standard(staff: EditingFixtures.staff0) {
            switch step {
            case let .intent(intent): _ = session.apply(intent)
            case .undo: _ = session.undo()
            case .redo: _ = session.redo()
            }
        }
        for (m, measure) in session.score.parts[0].staves[0].measures.enumerated() {
            for (v, voice) in measure.voices.enumerated() {
                print("measure \(m) voice \(v): \(voice.elements.map { String(describing: $0).prefix(28) })")
            }
        }
    }
```

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter "DrumIntentTests/shape"`
and read the printed layout. Delete this test afterwards.

- [ ] **Step 2: Append three steps to the script**

At the end of `EditReplayScript.standard(staff:)`'s array, append — filling in the measure/element indices
the previous step showed, and extending the type's `## Index stability` doc comment with a paragraph naming
them (the doc comment is the contract that keeps the script re-orderable):

```swift
        // 14a: M6 — grow a second voice on the last measure, the drum pad's "the feet voice isn't there yet"
        // case. Addresses a MEASURE, not an element, so it is index-stable whatever the re-bar left behind.
        .intent(.createVoice(staff: staff, measureIndex: <last>, voiceIndex: 1)),
        // 14b: split that new voice's full-measure rest at the half-bar, the column caret's "landed inside a
        // rest" case. Element 0 is the whole of a voice this script itself just created, so its index cannot
        // have drifted.
        .intent(.splitRest(
            at: VoiceElementID(staff: staff, measureIndex: <last>, voiceIndex: 1, elementIndex: 0),
            tickOffset: 960,
        )),
        // 14c: write a cross-head hi-hat into the first half of it, as ONE composite — the exact shape a drum
        // key issues, and the only step in this script that encodes `setNoteHead`'s wire bytes at all.
        .intent(.composite([
            .inputNote(
                at: RestID(staff: staff, measureIndex: <last>, voiceIndex: 1, elementIndex: 0),
                pitch: 42, tpc: 14, duration: nil,
            ),
            .setNoteHead(
                at: NoteID(
                    staff: staff, measureIndex: <last>, voiceIndex: 1,
                    elementIndex: 0, noteIndexInChord: 0,
                ),
                headType: "cross",
            ),
        ])),
```

`<last>` is the index of the final measure the shape dump reported (3 if the re-bar settled at four bars).
`tickOffset: 960` is half of a 4/4 bar at `division: 480`; if the last bar is not 4/4 after the re-bar, use
half of whatever its length is.

- [ ] **Step 3: Run the golden test to see it fail**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter "EditReplayWebGoldenTests|EditReplayDeterminismTests|EditReplayGoldenTests"`
Expected: FAIL — the recorded fingerprint chain is now shorter than the script. If instead a `session.apply`
assertion fails, an index in step 2 is wrong: go back to the shape dump rather than deleting the step.

- [ ] **Step 4: Re-record**

Run: `SM_EDIT_REPLAY_RECORD=1 xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter "EditReplayWebGoldenTests|EditReplayGoldenTests"`

Then bump the step count in
`Android/SheetMusicAndroid/src/androidTest/java/com/jiyimeta/sheetmusic/EditSessionReplayTest.kt` by 3, the
same one-line change commit `d41ea2fe` made for M4.

- [ ] **Step 5: Verify the re-recorded goldens**

Run: `xcrun swift test --package-path ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music --filter "EditReplayWebGoldenTests|EditReplayDeterminismTests|EditReplayGoldenTests"`
Expected: PASS. Confirm the new `step-NN.bin` files exist and `goldens.txt` grew by exactly 3 lines
(`git -C <ssm> diff --stat Android/SheetMusicAndroid/src/androidTest/assets/editReplay/`).

- [ ] **Step 6: Document the three commands**

In `docs/edit-commands.md`'s `## A. Implemented` table, add:

```
| `CreateVoice` | — (drum pad, iOS) | — |
| `SplitRest` | — (drum pad, iOS) | — |
| `SetNoteHead` | — (drum pad, iOS) | sugar |
```

and remove them from whatever "not implemented" section names them, if any. Check the file for a section
listing the intents by wire index and add 25/26/27 there too if one exists
(`grep -n "removeRehearsalMark" docs/edit-commands.md`).

In `CHANGELOG.md`, under `## [Unreleased]`:

```markdown
### Added

- `GMDrumset` publishes the General MIDI drum kit — line, notehead, voice, stem and name per pitch — and
  `Instrument.drumset` carries a score's own kit, decoded whole from `<Drum>` instead of for its line alone.
  `Instrument.drumLineMap` is unchanged as the lines-only view of it.
- `CreateVoice`, `SplitRest` and `SetNoteHead` edit commands, with `EditIntent` cases 25, 26 and 27 — what
  drum note entry needs to route a key to its own voice, write at a caret's tick, and give a note a
  cross notehead.
```

- [ ] **Step 7: Run the full Apple gate**

Run: `cd` is not needed — run `~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music/Scripts/preflight.sh --apple` with the ssm worktree as the working directory (the script resolves its own root).
Expected: lint clean, every test PASS. Fix anything it reports before going on; a SwiftLint `file_length` /
`type_body_length` complaint about `EditIntentCodec.swift` is likely — it already carries
`// swiftlint:disable file_length`, so extend the disable rather than splitting the file in this plan.

- [ ] **Step 8: Verify Folino still builds against the new package**

The Folino worktree is path-pinned to this ssm worktree, so a public API change shows up there immediately.

Run:
```bash
xcodebuild -project /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/scratch-creation-spec/Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```
Expected: BUILD SUCCEEDED. If `Folino.xcodeproj` is missing, run `env -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/scratch-creation-spec xcodegen generate` first. Nothing in Folino should
need editing — `drumLineMap` kept its type and both its accessors.

- [ ] **Step 9: Commit**

```bash
git -C ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music add -A
git -C ~/Developer/Personal/swift-packages/wt-scratch-creation/swift-sheet-music commit -m "test: replay goldens cover the drum note-entry intents"
```

---

## Final verification

- [ ] `Scripts/preflight.sh --apple` green from the ssm worktree.
- [ ] `grep -c "<Drum " Tests/SheetMusicTests/Resources/drumsetEncodeGolden.xml` → 27, and
      `MSCXDrumsetRoundTripTests/authoredKitIsByteIdentical` passes — the §6a gate.
- [ ] `git -C <ssm> log --oneline feature/scratch-creation-m1 ~9` shows the nine task commits and nothing on
      `main`.
- [ ] Folino builds against the pin.
- [ ] Report to the user, before anything else is started: what §6a's encoder change did to
      PDF-imported drum parts (pitches 63/64 now carry a `<name>`), and that §5.4 and the pad remain gated on
      the Android note-editing branch's merge.

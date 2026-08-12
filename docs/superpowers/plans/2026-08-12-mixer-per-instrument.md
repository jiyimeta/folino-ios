# Mixer per-instrument strips — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move folino's playback mixer off the staff and onto the swift-sheet-music mixer strip — a (part × distinct instrument) pair — so every row corresponds to something the audio engine can control separately, and a part that changes instrument mid-score becomes reachable.

**Architecture:** The engine already publishes the strip list (`PlaybackEngine.mixerChannels`); folino consumes it through a new Domain value type and never re-derives it. A `MixerStripID` replaces the flattened staff index across the `PlaybackController` protocol, `PlaybackPreferences` and `ReaderPreferences`. Two persisted stores migrate by the same rule. The Reader draws one row per strip, grouped under a part header only when a part is not one-strip-one-staff.

**Tech Stack:** Swift 6.3, SwiftUI, GRDB (SQLite), swift-sheet-music 1.11.0, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-12-mixer-per-instrument-design.md` — read it before Task 1. Every "why" lives there; this plan is the "how".

## Global Constraints

- **Package dependency pin.** The worktree is pinned to a LOCAL PATH copy of swift-sheet-music (`/Users/kiichi/Developer/Personal/swift-packages/wt-strip-name/swift-sheet-music`) because 1.11.0 is not tagged yet. Do NOT change the pin during Tasks 1–10. Task 11 re-pins once the tag exists.
- **Build/test command.** `swift test` does not work in this repo. Per-package: `cd Packages/<path> && xcodebuild test -scheme <Scheme> -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`. Scheme names: `Domain`, `Infrastructure-Package`, `Reader`, `Editor`, `Library`. App build: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`.
- **Architecture rules.** Features depend on Domain (and ScoreUI/Utility) only. Never Feature → Infrastructure. `MixerStripID` / `MixerStrip` are Foundation-only Domain values; `MixerChannel` is named only inside Infrastructure.
- **Comment style.** Reflow `//` and `///` paragraphs at 120 columns, not 80.
- **Access level.** `internal` unless the symbol crosses a module boundary.
- **Tests.** Swift Testing (`@Test`, `#expect`), never XCTest.
- **Commits.** One per task, at the end of the task. Do not push.
- **Do not touch** `hiddenStaves`, `authoredHiddenStaves`, `staffClefOverrides` — those stay `StaffAddress`-keyed. They are notation, not audio.

---

### Task 1: Delete folino's duplicate tie-chain walk

swift-sheet-music 1.11.0 lifted `TiePlanner` and `ElementNavigator` into `SheetMusicCore/Editing/Planners/`, both `public`. folino's Editor still carries its own copies of the same rule. Delete them first so nothing later is written against the wrong one. Call sites need no edit: Editor files already `import SheetMusicCore`, so the unqualified names resolve to the package's.

**Files:**
- Delete: `Packages/Features/Editor/Sources/Editor/TiePlanner.swift`
- Delete: `Packages/Features/Editor/Sources/Editor/ElementNavigator.swift`
- Delete: `Packages/Features/Editor/Tests/EditorTests/TiePlannerTests.swift`
- Delete: `Packages/Features/Editor/Tests/EditorTests/ElementNavigatorTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `SheetMusicCore.TiePlanner.tieTarget(for:in:) -> NoteID?`, `SheetMusicCore.TiePlanner.tieChain(containing:in:) -> [NoteID]`, `SheetMusicCore.ElementNavigator.nextTimedElement(after:in:) -> VoiceElementID?`, `SheetMusicCore.ElementNavigator.previousTimedElement(before:in:) -> VoiceElementID?` become the only implementations.

- [ ] **Step 1: Confirm the package's versions are equivalent before deleting**

Read both pairs side by side and confirm the behaviour matches (they were lifted from folino, so they should):

```bash
diff <(sed -n '1,200p' Packages/Features/Editor/Sources/Editor/TiePlanner.swift) \
     <(sed -n '1,200p' /Users/kiichi/Developer/Personal/swift-packages/wt-strip-name/swift-sheet-music/Sources/SheetMusicCore/Editing/Planners/TiePlanner.swift)
```

Expected: differences in access level (`public`) and doc wording only — the same `tieTarget`, `tieChain`, both-direction walk, and rank-based in-chord pairing. If any BEHAVIOUR differs, stop and report; do not delete.

- [ ] **Step 2: Delete the four files**

```bash
rm Packages/Features/Editor/Sources/Editor/TiePlanner.swift \
   Packages/Features/Editor/Sources/Editor/ElementNavigator.swift \
   Packages/Features/Editor/Tests/EditorTests/TiePlannerTests.swift \
   Packages/Features/Editor/Tests/EditorTests/ElementNavigatorTests.swift
```

- [ ] **Step 3: Run the Editor suite**

Run: `cd Packages/Features/Editor && xcodebuild test -scheme Editor -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`
Expected: PASS. The count drops by the deleted suites' tests; nothing else changes. If a call site fails to resolve `TiePlanner` or `ElementNavigator`, add `import SheetMusicCore` to that file — do not re-add the deleted types.

- [ ] **Step 4: Commit**

```bash
git add -A Packages/Features/Editor
git commit -m "refactor(editor): use the package's tie-chain walk instead of a second copy"
```

---

### Task 2: `MixerStripID` and `MixerStrip` in Domain

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/MixerStrip.swift`
- Create: `Packages/Domain/Tests/DomainTests/Models/MixerStripTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `MixerStripID(partIndex: Int, instrumentOrdinal: Int)` — `Hashable, Sendable, Codable`, encoded as a two-element unkeyed array. `MixerStrip(id:partName:instrumentName:defaultVolume:defaultProgram:isDrums:)` — `Hashable, Sendable`.

- [ ] **Step 1: Write the failing test**

Create `Packages/Domain/Tests/DomainTests/Models/MixerStripTests.swift`:

```swift
import Domain
import Foundation
import Testing

@Suite("MixerStripID")
struct MixerStripTests {
    /// The two-element array shape is load-bearing: the persisted override columns hold rows of
    /// `[key0, key1, value]`, and `StaffAddress` encodes the same way — which is what lets the migration be a
    /// filter on the second integer rather than a rewrite.
    @Test func `encodes as a two element array`() throws {
        let data = try JSONEncoder().encode(MixerStripID(partIndex: 2, instrumentOrdinal: 1))

        #expect(String(data: data, encoding: .utf8) == "[2,1]")
    }

    @Test func `round-trips`() throws {
        let id = MixerStripID(partIndex: 3, instrumentOrdinal: 0)

        let decoded = try JSONDecoder().decode(MixerStripID.self, from: JSONEncoder().encode(id))

        #expect(decoded == id)
    }

    @Test func `is usable as a dictionary key`() {
        let a = MixerStripID(partIndex: 0, instrumentOrdinal: 0)
        let b = MixerStripID(partIndex: 0, instrumentOrdinal: 1)

        #expect(Set([a, b, a]).count == 2)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd Packages/Domain && xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/MixerStripTests`
Expected: FAIL — `cannot find 'MixerStripID' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Packages/Domain/Sources/Domain/Models/MixerStrip.swift`:

```swift
import Foundation

/// One controllable sound in the mixer: a (part × distinct instrument) pair, which is the unit the audio engine
/// addresses. NOT a staff — a grand staff is two staves playing one instrument through one channel, and a part
/// that changes instrument mid-score is one staff driving several.
///
/// `instrumentOrdinal` indexes the part's deduped instruments in first-appearance order, so it is stable for a
/// given score and matches the engine's channel set one-to-one.
public struct MixerStripID: Hashable, Sendable, Codable {
    public let partIndex: Int
    public let instrumentOrdinal: Int

    public init(partIndex: Int, instrumentOrdinal: Int) {
        self.partIndex = partIndex
        self.instrumentOrdinal = instrumentOrdinal
    }

    /// Encoded as a two-element unkeyed array `[partIndex, instrumentOrdinal]`, matching `StaffAddress`. The
    /// persisted override columns hold `[key0, key1, value]` rows, so keeping the shape is what lets a stored
    /// staff-keyed override migrate by dropping rows rather than by being rewritten.
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        partIndex = try container.decode(Int.self)
        instrumentOrdinal = try container.decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(partIndex)
        try container.encode(instrumentOrdinal)
    }
}

/// A strip as the engine reports it, for the mixer to draw. Everything here is the SCORE's authored value, read
/// before any user override is applied — the Infrastructure adapter snapshots it between preparing the engine and
/// seeding it, because the engine's own list is mutated by that seeding.
public struct MixerStrip: Hashable, Sendable, Identifiable {
    public let id: MixerStripID
    /// The part this strip belongs to — a group's title when one is drawn.
    public let partName: String
    /// The instrument driving it, unqualified by the part — a row's label under such a title.
    public let instrumentName: String
    /// The score's authored level, `0 ... 1`. The slider's reset target.
    public let defaultVolume: Double
    /// The score's authored program. On a drum strip this is the KIT.
    public let defaultProgram: Int
    /// Whether the program is a drum kit, so the picker offers that catalog rather than the melodic one.
    public let isDrums: Bool

    public init(
        id: MixerStripID,
        partName: String,
        instrumentName: String,
        defaultVolume: Double,
        defaultProgram: Int,
        isDrums: Bool,
    ) {
        self.id = id
        self.partName = partName
        self.instrumentName = instrumentName
        self.defaultVolume = min(max(defaultVolume, 0), 1)
        self.defaultProgram = min(max(defaultProgram, 0), 127)
        self.isDrums = isDrums
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run the same command as Step 2.
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/MixerStrip.swift Packages/Domain/Tests/DomainTests/Models/MixerStripTests.swift
git commit -m "feat(domain): add MixerStripID and MixerStrip"
```

---

### Task 3: `PlaybackController` addresses strips

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift:80-83`
- Modify: `Packages/Domain/Tests/DomainTests/Protocols/AudioProtocolsTests.swift`
- Modify: `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift`
- Modify: `Packages/Features/Editor/Tests/EditorTests/Support/FakePlaybackController.swift`
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift` (rename only; behaviour lands in Task 7)

**Interfaces:**
- Consumes: `MixerStripID` (Task 2).
- Produces: `func setStripVolume(strip: MixerStripID, volume: Double) async`, `func setStripMute(strip: MixerStripID, isMuted: Bool) async`, `func setStripSolo(strip: MixerStripID, isSolo: Bool) async`, `func setStripInstrument(strip: MixerStripID, program: Int) async`, `func mixerStrips() async -> [MixerStrip]`.

- [ ] **Step 1: Change the protocol**

In `PlaybackController.swift`, replace the four `setStaff*` requirements with:

```swift
    /// Mixer setters, addressed by strip. `bank` is gone with the staff index: the engine's program setter takes
    /// no bank and the adapter had always discarded the argument.
    func setStripVolume(strip: MixerStripID, volume: Double) async
    func setStripMute(strip: MixerStripID, isMuted: Bool) async
    func setStripSolo(strip: MixerStripID, isSolo: Bool) async
    func setStripInstrument(strip: MixerStripID, program: Int) async

    /// The strips of the currently prepared score, in the engine's own order — by part, then by ordinal. Empty
    /// before a score is prepared and after the engine is released; the mixer draws nothing then, because a mixer
    /// describes a prepared engine.
    ///
    /// Values are the SCORE's, not the user's: the adapter snapshots them before seeding the engine with saved
    /// preferences, so `defaultVolume` stays a reset target rather than becoming a copy of the current setting.
    func mixerStrips() async -> [MixerStrip]
```

- [ ] **Step 2: Follow the three fakes**

In each of the three fake controllers, replace the four `setStaff*` methods with the strip-keyed four and add `mixerStrips()`. `Domain/Tests/DomainTests/Protocols/AudioProtocolsTests.swift` — the no-op conformance:

```swift
    func setStripVolume(strip _: MixerStripID, volume _: Double) {}
    func setStripMute(strip _: MixerStripID, isMuted _: Bool) {}
    func setStripSolo(strip _: MixerStripID, isSolo _: Bool) {}
    func setStripInstrument(strip _: MixerStripID, program _: Int) {}
    func mixerStrips() -> [MixerStrip] { [] }
```

`Editor/Tests/EditorTests/Support/FakePlaybackController.swift` — same five, keeping whatever recording the existing `setStaffVolume` / `setStaffSolo` did, re-typed to `MixerStripID`.

`Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift` — record the calls so Task 9's tests can assert on them:

```swift
    private(set) var stripVolumes: [(strip: MixerStripID, volume: Double)] = []
    private(set) var stripMutes: [(strip: MixerStripID, isMuted: Bool)] = []
    private(set) var stripSolos: [(strip: MixerStripID, isSolo: Bool)] = []
    private(set) var stripPrograms: [(strip: MixerStripID, program: Int)] = []
    /// What `mixerStrips()` returns. Set it in a test to stand in for a prepared engine.
    var strips: [MixerStrip] = []

    func setStripVolume(strip: MixerStripID, volume: Double) { stripVolumes.append((strip, volume)) }
    func setStripMute(strip: MixerStripID, isMuted: Bool) { stripMutes.append((strip, isMuted)) }
    func setStripSolo(strip: MixerStripID, isSolo: Bool) { stripSolos.append((strip, isSolo)) }
    func setStripInstrument(strip: MixerStripID, program: Int) { stripPrograms.append((strip, program)) }
    func mixerStrips() -> [MixerStrip] { strips }
```

- [ ] **Step 3: Keep `LivePlaybackController` compiling**

Rename its four methods to match, keeping the existing `channel(forStaff:)` body for now by mapping the strip id straight onto the engine kind, and add a stub `mixerStrips()`:

```swift
    private func channel(_ strip: MixerStripID) -> MixerChannel.Kind {
        .instrument(partIndex: strip.partIndex, ordinal: strip.instrumentOrdinal)
    }

    public func setStripVolume(strip: MixerStripID, volume: Double) {
        engine.setVolume(forChannel: channel(strip), to: Float(volume))
    }

    public func setStripMute(strip: MixerStripID, isMuted: Bool) {
        engine.setMuted(forChannel: channel(strip), to: isMuted)
    }

    public func setStripSolo(strip: MixerStripID, isSolo: Bool) {
        engine.setSoloed(forChannel: channel(strip), to: isSolo)
    }

    public func setStripInstrument(strip: MixerStripID, program: Int) {
        engine.setProgram(forChannel: channel(strip), to: UInt8(clamping: program))
    }

    public func mixerStrips() -> [MixerStrip] { [] }
```

Delete `channel(forStaff:)`. `applyPreferences` still refers to `perStaff` at this point — leave it; Task 4 replaces it. If it no longer compiles because `channel(forStaff:)` is gone, map it inline to `.instrument(partIndex:ordinal: 0)` with a `// replaced in Task 4` comment.

- [ ] **Step 4: Build every affected package**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
Expected: BUILD SUCCEEDED. Then the Domain and Editor suites, both PASS. Reader will not compile yet — its `PlaybackMixerModel` still calls `setStaffVolume`; fix those call sites mechanically to `setStripVolume(strip: MixerStripID(partIndex: …, instrumentOrdinal: 0), …)` with a `// re-keyed in Task 9` comment so the package builds.

- [ ] **Step 5: Commit**

```bash
git add -A Packages
git commit -m "refactor(domain): address the mixer by strip instead of by flattened staff index"
```

---

### Task 4: `PlaybackPreferences` carries strip overrides only

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/PlaybackPreferences.swift:20-38` (`StaffMixerState` → `StripMixerState`), `:56` (`perStaff` → `perStrip`), and the initializer
- Modify: `Packages/Domain/Tests/DomainTests/Models/PlaybackPreferencesTests.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/PlaybackPreferences+Initial.swift`
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift` (`applyPreferences`)

**Interfaces:**
- Consumes: `MixerStripID` (Task 2).
- Produces: `StripMixerState(strip: MixerStripID, volume: Double?, gmProgram: Int?)`; `PlaybackPreferences.perStrip: [StripMixerState]`; `PlaybackPreferences.initial(for:readerPreferences:scoreItemID:)` — note the `defaultVolume:` parameter is gone.

- [ ] **Step 1: Write the failing test**

Add to `Packages/Domain/Tests/DomainTests/Models/PlaybackPreferencesTests.swift`:

```swift
    /// Both fields are independently optional because volume and program are separate override dictionaries: a
    /// strip can carry one and not the other. A non-optional `gmProgram` would need a filler, and the obvious
    /// one — 0 — is Acoustic Grand Piano, so saving a volume would silently retune the strip.
    @Test func `a strip state can carry a volume with no program`() {
        let state = StripMixerState(
            strip: MixerStripID(partIndex: 0, instrumentOrdinal: 0), volume: 0.4, gmProgram: nil,
        )

        #expect(state.volume == 0.4)
        #expect(state.gmProgram == nil)
    }

    @Test func `a strip state clamps the values it does carry`() {
        let state = StripMixerState(
            strip: MixerStripID(partIndex: 0, instrumentOrdinal: 0), volume: 3, gmProgram: 999,
        )

        #expect(state.volume == 1)
        #expect(state.gmProgram == 127)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd Packages/Domain && xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/PlaybackPreferencesTests`
Expected: FAIL — `cannot find 'StripMixerState' in scope`.

- [ ] **Step 3: Replace the type**

In `PlaybackPreferences.swift`, replace `StaffMixerState` with:

```swift
/// One strip's SAVED OVERRIDES — not its resolved settings. Absent means the user never chose, and the engine's
/// own seeding (the score's authored CC 7 and program, applied when it prepared the score) stands.
///
/// `isMuted` / `isSolo` are not here: mute and solo are session-only and were always written `false`.
public struct StripMixerState: Hashable, Sendable, Codable {
    public let strip: MixerStripID
    /// `nil` = no override.
    public var volume: Double?
    /// `nil` = no override. NOT a program of `0`, which is Acoustic Grand Piano.
    public var gmProgram: Int?

    public init(strip: MixerStripID, volume: Double?, gmProgram: Int?) {
        self.strip = strip
        self.volume = volume.map { min(max($0, 0), 1) }
        self.gmProgram = gmProgram.map { min(max($0, 0), 127) }
    }
}
```

Rename the stored property `perStaff` to `perStrip` with type `[StripMixerState]`, and rename the initializer's label to match.

- [ ] **Step 4: Rebuild `initial` from the override dictionaries**

Replace the body of `PlaybackPreferences+Initial.swift` — the `score.allStaves` walk goes away entirely, and so does the `defaultVolume:` parameter:

```swift
import Domain
import Foundation
import SheetMusicCore

extension PlaybackPreferences {
    /// The user's saved overrides, keyed by strip, for the engine to apply on top of what it already seeded from
    /// the score. There is deliberately no score walk here: the strip list only exists once the engine has
    /// prepared the score, and a resolved per-strip list would re-send what `prepare` had just applied.
    static func initial(
        for _: Score,
        readerPreferences: ReaderPreferences,
        scoreItemID: Domain.ScoreItemID,
    ) -> PlaybackPreferences {
        let strips = Set(readerPreferences.stripVolumeOverrides.keys)
            .union(readerPreferences.stripProgramOverrides.keys)
        let states = strips.sorted {
            ($0.partIndex, $0.instrumentOrdinal) < ($1.partIndex, $1.instrumentOrdinal)
        }.map { strip in
            StripMixerState(
                strip: strip,
                volume: readerPreferences.stripVolumeOverrides[strip],
                gmProgram: readerPreferences.stripProgramOverrides[strip],
            )
        }
        let globalA4 = UserDefaults.standard.object(forKey: ReaderGlobalSettingsKey.a4ReferenceHz) as? Double
            ?? A4Reference.standardHz
        return PlaybackPreferences(
            scoreItemID: scoreItemID,
            perStrip: states,
            tempoMultiplier: readerPreferences.tempoMultiplier ?? 1.0,
            abRepeat: readerPreferences.abRepeat,
            masterVolume: readerPreferences.effectiveMasterVolume,
            a4ReferenceHz: A4Reference.effectiveHz(
                override: readerPreferences.a4ReferenceHz,
                globalDefault: globalA4,
            ),
            transposeSemitones: readerPreferences.effectiveTransposeSemitones,
        )
    }
}
```

`stripVolumeOverrides` / `stripProgramOverrides` do not exist until Task 5 — write this now and expect the Reader package not to compile until then. Fix the `initial(...)` call site in `ReaderPlaybackSession` to drop the `defaultVolume:` argument.

- [ ] **Step 5: Send only what is present**

In `LivePlaybackController.applyPreferences`, replace the `perStaff` loop:

```swift
        for state in preferences.perStrip {
            let channel = MixerChannel.Kind.instrument(
                partIndex: state.strip.partIndex, ordinal: state.strip.instrumentOrdinal,
            )
            // Only what the user actually chose. `prepare(score:)` has already seeded every strip from the
            // score, so an absent field means "leave the engine's own value alone" — sending a filler here
            // would overwrite the score with a default.
            if let volume = state.volume { engine.setVolume(forChannel: channel, to: Float(volume)) }
            if let program = state.gmProgram {
                engine.setProgram(forChannel: channel, to: UInt8(clamping: program))
            }
        }
```

Mute and solo are no longer sent from here at all — they were always `false`, which is what `prepare` leaves them at.

- [ ] **Step 6: Run the Domain suite**

Run the Step 2 command without `-only-testing`.
Expected: PASS. Reader/Infrastructure still broken pending Task 5 — that is expected and this task's commit is Domain + Infrastructure only.

- [ ] **Step 7: Commit**

```bash
git add Packages/Domain Packages/Infrastructure Packages/Features/Reader/Sources/Reader/PlaybackPreferences+Initial.swift
git commit -m "refactor(domain): PlaybackPreferences carries per-strip overrides, not a resolved per-staff list"
```

---

### Task 5: `ReaderPreferences` keys its audio overrides by strip

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift` — properties at `:61,65`, initializer at `:111-112`, `hasStaffBoundOverrides` at `:172`, `clearingStaffBoundOverrides` at `:187`, `codableSchemaVersion` at `:211`, and `init(from:)`
- Modify: `Packages/Domain/Sources/Domain/Analytics/AnalyticsEvent+Factories.swift:290-294`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel+PDFReread.swift:15-19`
- Modify: `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesTests.swift`, `ReaderPreferencesUntouchedTests.swift`
- Create: `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesStripMigrationTests.swift`

**Interfaces:**
- Consumes: `MixerStripID` (Task 2).
- Produces: `ReaderPreferences.stripProgramOverrides: [MixerStripID: Int]`, `.stripVolumeOverrides: [MixerStripID: Double]`, `.hasScoreBoundOverrides: Bool`, `.clearingScoreBoundOverrides() -> ReaderPreferences`, `codableSchemaVersion == 3`.

- [ ] **Step 1: Write the failing test**

Create `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesStripMigrationTests.swift`:

```swift
import Domain
import Foundation
import Testing

/// Android persists `ReaderPreferences` through this Codable representation, not through GRDB, so the SQL
/// migration never reaches it. The schema version is what tells a stored `[partIndex, staffIndexInPart]` key from
/// a `[partIndex, instrumentOrdinal]` one, and a blob written before version 3 gets the same collapse the SQL
/// migration performs: keep the part's first entry, drop the rest.
@Suite("ReaderPreferences strip migration")
struct ReaderPreferencesStripMigrationTests {
    private func blob(schemaVersion: Int?, volumeRows: String) -> Data {
        let version = schemaVersion.map { "\"schemaVersion\":\($0)," } ?? ""
        return Data("""
        {\(version)"id":"11111111-1111-1111-1111-111111111111",\
        "scoreItemID":"22222222-2222-2222-2222-222222222222",\
        "hiddenStaves":[],"authoredHiddenStaves":[],"staffProgramOverrides":[],\
        "staffVolumeOverrides":\(volumeRows),"staffClefOverrides":[],\
        "repeatMode":"off","hasSeededAuthoredVisibility":true}
        """.utf8)
    }

    @Test func `a pre-v3 blob keeps only each part's first staff`() throws {
        let data = blob(schemaVersion: 2, volumeRows: "[[0,0,0.25],[0,1,0.75],[1,0,0.5]]")

        let prefs = try JSONDecoder().decode(ReaderPreferences.self, from: data)

        #expect(prefs.stripVolumeOverrides == [
            MixerStripID(partIndex: 0, instrumentOrdinal: 0): 0.25,
            MixerStripID(partIndex: 1, instrumentOrdinal: 0): 0.5,
        ])
    }

    @Test func `a v3 blob is taken as written`() throws {
        let data = blob(schemaVersion: 3, volumeRows: "[[0,0,0.25],[0,1,0.75]]")

        let prefs = try JSONDecoder().decode(ReaderPreferences.self, from: data)

        // Ordinal 1 is a real second strip at v3 — an instrument-change part — and must survive.
        #expect(prefs.stripVolumeOverrides.count == 2)
        #expect(prefs.stripVolumeOverrides[MixerStripID(partIndex: 0, instrumentOrdinal: 1)] == 0.75)
    }

    @Test func `a legacy blob with no version is collapsed too`() throws {
        let data = blob(schemaVersion: nil, volumeRows: "[[0,0,0.25],[0,1,0.75]]")

        let prefs = try JSONDecoder().decode(ReaderPreferences.self, from: data)

        #expect(prefs.stripVolumeOverrides.count == 1)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd Packages/Domain && xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/ReaderPreferencesStripMigrationTests`
Expected: FAIL — `value of type 'ReaderPreferences' has no member 'stripVolumeOverrides'`.

- [ ] **Step 3: Rename the properties and add the decode filter**

Rename `staffProgramOverrides` → `stripProgramOverrides: [MixerStripID: Int]` and `staffVolumeOverrides` → `stripVolumeOverrides: [MixerStripID: Double]`, in the properties, the initializer (keeping its clamping), and `encode(to:)`. **Keep the coding keys `staffProgramOverrides` / `staffVolumeOverrides` unchanged** — the version marker is what disambiguates, so renaming the key too would strand blobs written between the two.

Bump `codableSchemaVersion` to `3`. In `init(from:)`, after decoding the two dictionaries, collapse them when the blob predates 3:

```swift
        // A blob at schema 2 or earlier keyed these by STAFF. A staff and a strip both encode as two integers,
        // so the rows decode without complaint and mean the wrong thing: `[0,1]` was "part 0's second staff",
        // which under strips is "part 0's second instrument" — a different sound. Collapse to the part's first
        // entry, which is what the SQL migration does to the same rows.
        let isPreStrip = (try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0) < 3
        if isPreStrip {
            programOverrides = programOverrides.filter { $0.key.instrumentOrdinal == 0 }
            volumeOverrides = volumeOverrides.filter { $0.key.instrumentOrdinal == 0 }
        }
```

Place it so it runs before the values reach `self.init(...)`. Note the existing decoder already reads `schemaVersion` once for `isLegacy`; reuse that decoded value rather than decoding the key twice.

- [ ] **Step 4: Rename the score-bound members**

`hasStaffBoundOverrides` → `hasScoreBoundOverrides`, `clearingStaffBoundOverrides()` → `clearingScoreBoundOverrides()`, keeping their bodies (with the renamed dictionaries) and updating the doc comments: the subject is "settings addressed by an index the score supplies, which a re-parse can renumber", and a strip id is one. Update the single call site in `ReaderViewModel+PDFReread.swift` and its `hasStaffBoundPreferences:` label to `hasScoreBoundPreferences:`.

- [ ] **Step 5: Follow analytics**

In `AnalyticsEvent+Factories.swift`, change the two reads to the renamed dictionaries. The parameter names `program_override_count` / `volume_override_count` stay — the meaning is still "how many things did the user override", with the unit now strips rather than staves.

- [ ] **Step 6: Update the existing Domain tests**

`ReaderPreferencesTests` and `ReaderPreferencesUntouchedTests` reference the old names; re-key their fixtures to `MixerStripID(partIndex:instrumentOrdinal:)` and rename the two members. Add one assertion to `ReaderPreferencesTests`:

```swift
    @Test func `a strip override alone makes the preferences score-bound`() {
        var prefs = ReaderPreferences(scoreItemID: ScoreItemID(), hiddenStaves: [])
        prefs.stripVolumeOverrides = [MixerStripID(partIndex: 0, instrumentOrdinal: 0): 0.5]

        #expect(prefs.hasScoreBoundOverrides)
        #expect(prefs.clearingScoreBoundOverrides().stripVolumeOverrides.isEmpty)
    }
```

- [ ] **Step 7: Run the Domain suite**

Run the Step 2 command without `-only-testing`.
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Packages/Domain Packages/Features/Reader/Sources/Reader/ReaderViewModel+PDFReread.swift
git commit -m "refactor(domain): key the audio overrides by strip, and collapse pre-v3 blobs on decode"
```

---

### Task 6: v17 migration for the SQL store

**Files:**
- Create: `Packages/Infrastructure/Sources/Persistence/Database/Migrations+V17.swift`
- Create: `Packages/Infrastructure/Sources/Persistence/Database/Migrations+TestSupport.swift`
- Modify: `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift` (register v17; move the `upToVn` migrators out)
- Modify: `Packages/Infrastructure/Sources/Persistence/Records/ReaderPreferencesRecord.swift` (encode/decode the renamed dictionaries)
- Create: `Packages/Infrastructure/Tests/PersistenceTests/MigrationV17Tests.swift`

**Interfaces:**
- Consumes: `MixerStripID` (Task 2), `ReaderPreferences.stripVolumeOverrides` (Task 5).
- Produces: `AppMigrations.migrateV17(_:)`, registered as `"v17"`; `AppMigrations.upToV16` in the new test-support file.

- [ ] **Step 1: Write the failing test**

Create `Packages/Infrastructure/Tests/PersistenceTests/MigrationV17Tests.swift`:

```swift
import Foundation
import GRDB
@testable import Persistence
import Testing

/// v17 re-reads the two override columns as strip-keyed. A staff key and a strip key are both two integers, so
/// the rows survive decoding either way and would silently mean a different sound; the migration drops every row
/// whose second integer is not 0, which is the part's first entry and the only one a strip can inherit.
@Suite("Migration v17")
struct MigrationV17Tests {
    private func database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppMigrations.upToV16.migrate(queue)
        return queue
    }

    private func insertRow(_ db: Database, volumes: String, programs: String) throws {
        try db.execute(sql: """
        INSERT INTO reader_preferences (id, score_item_id, hidden_staff_ids, staff_program_overrides,
            staff_volume_overrides, staff_clef_overrides, repeat_mode, has_seeded_authored_visibility,
            authored_hidden_staves)
        VALUES ('id-1', 'score-1', '[]', ?, ?, '[]', 'off', 1, '[]')
        """, arguments: [programs, volumes])
    }

    @Test func `drops every override past a part's first staff`() throws {
        let queue = try database()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO score_items (id) VALUES ('score-1')")
            try insertRow(db, volumes: "[[0,0,0.25],[0,1,0.75],[1,0,0.5]]", programs: "[[0,0,40],[0,1,40]]")
        }

        try AppMigrations.all.migrate(queue)

        let (volumes, programs): (String, String) = try queue.read { db in
            let row = try Row.fetchOne(db, sql: """
            SELECT staff_volume_overrides, staff_program_overrides FROM reader_preferences
            """)!
            return (row[0], row[1])
        }
        #expect(volumes == "[[0,0,0.25],[1,0,0.5]]")
        #expect(programs == "[[0,0,40]]")
    }

    @Test func `leaves a row with no multi-staff entries byte-identical`() throws {
        let queue = try database()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO score_items (id) VALUES ('score-1')")
            try insertRow(db, volumes: "[[0,0,0.25],[1,0,0.5]]", programs: "[]")
        }

        try AppMigrations.all.migrate(queue)

        let volumes: String = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT staff_volume_overrides FROM reader_preferences")!
        }
        #expect(volumes == "[[0,0,0.25],[1,0,0.5]]")
    }

    /// The record decoders swallow malformed JSON rather than failing a read, so the migration must not be the
    /// one thing that throws on a row the app would otherwise open.
    @Test func `survives malformed column JSON`() throws {
        let queue = try database()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO score_items (id) VALUES ('score-1')")
            try insertRow(db, volumes: "not json", programs: "[]")
        }

        try AppMigrations.all.migrate(queue)

        let volumes: String = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT staff_volume_overrides FROM reader_preferences")!
        }
        #expect(volumes == "[]")
    }
}
```

If `score_items` needs more non-null columns at v16, add them to the insert — read the v16 `CREATE TABLE` and match it.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd Packages/Infrastructure && xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:PersistenceTests/MigrationV17Tests`
Expected: FAIL — `upToV16` does not exist.

- [ ] **Step 3: Move the test-support migrators out**

`Migrations.swift`'s own header asks the next migration to do this. Create `Migrations+TestSupport.swift` and move every `upToVn` migrator declaration there verbatim, adding a file comment:

```swift
import GRDB

/// The partial migrators tests use to build a database at a given schema version, moved out of `Migrations.swift`
/// when v17 was added — that file's own header asked for this rather than growing past SwiftLint's 400-line
/// budget. Behaviour is unchanged; these are the same registrations in a different file.
extension AppMigrations {
    // …the moved `upToVn` declarations…
}
```

Add `upToV16` alongside them, registering v1…v16 exactly as `all` does.

- [ ] **Step 4: Write the migration**

Create `Migrations+V17.swift`:

```swift
import Foundation
import GRDB

extension AppMigrations {
    // MARK: - v17

    /// Re-keys the two audio-override columns from staff to mixer strip. Both hold rows of
    /// `[partIndex, staffIndexInPart, value]`, and a strip key encodes with the same two-integer shape, so this
    /// rewrites contents rather than the table: keep each part's first entry, drop the rest.
    ///
    /// A grand staff's two rows always drove one channel, so the dropped entries never had an independent sound;
    /// the kept one is what the mixer displayed on the part's first row. Program overrides lose nothing at all —
    /// the Reader has only ever written them for every staff of a part at once.
    ///
    /// Malformed JSON is replaced with `[]` rather than throwing: the record decoders already treat an
    /// unreadable column as "no overrides", and a migration that fails the whole open would be stricter than the
    /// app that reads it.
    static func migrateV17(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
        SELECT score_item_id, staff_program_overrides, staff_volume_overrides FROM reader_preferences
        """)
        for row in rows {
            let scoreItemID: String = row["score_item_id"]
            let programs = collapsingToFirstStaff(row["staff_program_overrides"])
            let volumes = collapsingToFirstStaff(row["staff_volume_overrides"])
            try db.execute(sql: """
            UPDATE reader_preferences
            SET staff_program_overrides = ?, staff_volume_overrides = ?
            WHERE score_item_id = ?
            """, arguments: [programs, volumes, scoreItemID])
        }
    }

    /// `[[part, staff, value], …]` with every `staff != 0` row removed, re-encoded. Returns `"[]"` for anything
    /// that does not decode as that shape.
    private static func collapsingToFirstStaff(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[Double]]
        else { return "[]" }
        let kept = rows.filter { $0.count == 3 && $0[1] == 0 }
        guard let out = try? JSONSerialization.data(withJSONObject: kept),
              let string = String(data: out, encoding: .utf8)
        else { return "[]" }
        return string
    }
}
```

`JSONSerialization` will render integers without a decimal point only if they are whole `Double`s — verify the first test's expected strings against what it actually writes and adjust the expectation to the real output if it differs (e.g. `[[0,0,0.25],[1,0,0.5]]`). Do not "fix" this by hand-building strings.

Register it in `Migrations.swift`: `m.registerMigration("v17", migrate: migrateV17)`.

- [ ] **Step 5: Follow the record**

In `ReaderPreferencesRecord.swift`, rename the encode/decode helpers' targets to `stripProgramOverrides` / `stripVolumeOverrides` and build `MixerStripID(partIndex:instrumentOrdinal:)` where they built `StaffAddress`. The column names and the `[[Int]]` / `[[Double]]` row shapes do not change.

- [ ] **Step 6: Run the Infrastructure suite**

Run the Step 2 command without `-only-testing`.
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Packages/Infrastructure
git commit -m "feat(persistence): migrate the audio overrides from staff keys to strip keys"
```

---

### Task 7: The adapter publishes the strip list

**Files:**
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift` — the `load` body, the stub `mixerStrips()` from Task 3, a new stored `snapshotStrips`, and `releaseEngine()`
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController+Reload.swift`
- Create: `Packages/Infrastructure/Tests/AudioTests/LivePlaybackControllerStripTests.swift`

**Interfaces:**
- Consumes: `MixerStrip`, `MixerStripID` (Task 2), `PlaybackPreferences.perStrip` (Task 4).
- Produces: `LivePlaybackController.mixerStrips()` returning the snapshot taken at prepare time.

- [ ] **Step 1: Write the failing test**

Create `Packages/Infrastructure/Tests/AudioTests/LivePlaybackControllerStripTests.swift`. This is the first test in the repo that crosses the swift-sheet-music boundary — every mixer test so far has run against a fake controller, which is why the `.staff` → `.instrument` change could land unnoticed. The resolver returns `nil` for every soundfont, which `PlaybackEngine` accepts: it builds the graph and the mixer channel list without loading samples.

```swift
import Domain
@testable import Audio
import Foundation
import SheetMusicAudio
import SheetMusicCore
import Testing

@MainActor
@Suite("LivePlaybackController strips")
struct LivePlaybackControllerStripTests {
    private struct NullResolver: SheetMusicAudio.SoundfontResolver {
        func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? { nil }
        var defaultGMSoundfontURL: URL? { nil }
    }

    /// One part, one staff, an authored CC 7 of 100/127 and program 40.
    private func score() -> Score {
        Score(
            division: 480,
            parts: [Part(
                id: "P1",
                trackName: "Violin",
                instrument: Instrument(
                    id: "violin", longName: "Violin",
                    channels: [InstrumentChannel(program: 40, volume: 100)],
                ),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: [])])])],
            )],
            systemMeasures: [SystemMeasure()],
        )
    }

    private func controller() -> LivePlaybackController {
        LivePlaybackController(soundfontResolver: NullResolver())
    }

    @Test func `reports one strip per part, addressed by ordinal`() throws {
        let controller = controller()
        try controller.load(
            score: score(), displayTitle: nil,
            preferences: PlaybackPreferences(
                scoreItemID: ScoreItemID(), perStrip: [], tempoMultiplier: 1, abRepeat: nil,
            ),
        )

        let strips = controller.mixerStrips()

        #expect(strips.count == 1)
        #expect(strips[0].id == MixerStripID(partIndex: 0, instrumentOrdinal: 0))
        #expect(strips[0].defaultProgram == 40)
        #expect(!strips[0].isDrums)
    }

    /// The snapshot has to be taken BEFORE the saved preferences are seeded. `load` applies them immediately
    /// after preparing, and the engine's own channel list is mutated in place — so reading it afterwards would
    /// report the user's override as the score's level, and the slider's reset target would reset to itself.
    @Test func `reports the score's level even when an override was loaded`() throws {
        let controller = controller()
        let override = StripMixerState(
            strip: MixerStripID(partIndex: 0, instrumentOrdinal: 0), volume: 0.1, gmProgram: 24,
        )
        try controller.load(
            score: score(), displayTitle: nil,
            preferences: PlaybackPreferences(
                scoreItemID: ScoreItemID(), perStrip: [override], tempoMultiplier: 1, abRepeat: nil,
            ),
        )

        let strip = try #require(controller.mixerStrips().first)

        #expect(strip.defaultProgram == 40)
        #expect(abs(strip.defaultVolume - 100.0 / 127.0) < 0.01)
    }

    @Test func `reports nothing once the engine is released`() throws {
        let controller = controller()
        try controller.load(
            score: score(), displayTitle: nil,
            preferences: PlaybackPreferences(
                scoreItemID: ScoreItemID(), perStrip: [], tempoMultiplier: 1, abRepeat: nil,
            ),
        )
        #expect(!controller.mixerStrips().isEmpty)

        controller.releaseEngine()

        #expect(controller.mixerStrips().isEmpty)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd Packages/Infrastructure && xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:AudioTests/LivePlaybackControllerStripTests`
Expected: FAIL — `mixerStrips()` returns `[]` (the Task 3 stub).

- [ ] **Step 3: Take the snapshot**

Add the stored property beside `loadedPreferences`:

```swift
    /// The engine's strip list as it stood at `prepare(score:)`, BEFORE `applyPreferences` wrote the user's
    /// choices into it. `mixerChannels` is engine state and is mutated in place by the setters, so a late read
    /// would report an override as the score's own level — and every "reset to what the score said" answer built
    /// on it would reset to itself. Cleared wherever the prepared engine goes away.
    private var snapshotStrips: [MixerStrip] = []
```

Add the conversion:

```swift
    /// `mixerChannels` minus the metronome, which is not a part of the score and has no `MixerStripID` — it keeps
    /// its own toggle and its own `setMetronomeEnabled(_:)` path.
    private func stripsFromEngine() -> [MixerStrip] {
        engine.mixerChannels.compactMap { channel in
            guard case let .instrument(partIndex, ordinal) = channel.id else { return nil }
            return MixerStrip(
                id: MixerStripID(partIndex: partIndex, instrumentOrdinal: ordinal),
                partName: channel.partName,
                instrumentName: channel.instrumentName ?? channel.name,
                defaultVolume: Double(channel.volume),
                defaultProgram: Int(channel.program ?? 0),
                isDrums: channel.isDrums,
            )
        }
    }

    public func mixerStrips() -> [MixerStrip] { snapshotStrips }
```

In `load(score:displayTitle:preferences:)`, insert the capture between `engine.pause()` and `applyPreferences(preferences)`:

```swift
        snapshotStrips = stripsFromEngine()
```

In `releaseEngine()`, add `snapshotStrips = []` beside `loadedScore = nil`.

- [ ] **Step 4: Do the same on reload**

In `LivePlaybackController+Reload.swift`, `reloadSoundfont()` runs teardown → prepare → pause → applyPreferences. Add `snapshotStrips = stripsFromEngine()` immediately before its `applyPreferences` call, and `snapshotStrips = []` on the early-return path where the re-prepare throws — that path has already torn the engine down, so an empty list is the truthful answer rather than a stale one. `snapshotStrips` must be `internal`, not `private`, for the extension file to reach it (the same reason `loadedPreferences` is).

- [ ] **Step 5: Run the test to verify it passes**

Run the Step 2 command.
Expected: PASS, 3 tests. Then the whole Infrastructure suite: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/Infrastructure
git commit -m "feat(audio): publish the engine's strip list, snapshotted before preferences are seeded"
```

---

### Task 8: The Android bridge translates, and the gap is recorded

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/ReaderPreferencesReducer.swift:115-125`
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/ReaderPreferencesBridge.swift` (setters ~`:183-192`, list getters ~`:214-234`)
- Modify: `Packages/Features/Library/Tests/FolinoLibraryJNITests/ReaderPreferencesReducerTests.swift`
- Modify: `docs/engineering/ios-android-parity.md` (regenerated, not hand-edited)

**Interfaces:**
- Consumes: `ReaderPreferences.stripVolumeOverrides` / `.stripProgramOverrides` (Task 5).
- Produces: no signature change — the bridge keeps `(part, staff)`.

- [ ] **Step 1: Translate in the reducer**

The Kotlin mixer calls these with a staff index and rebuilds a per-`(part, staff)` map from the list getters. Keep both signatures and map through ordinal 0:

```swift
    static func setStaffProgram(_ p: ReaderPreferences, part: Int, staff _: Int, program: Int) -> ReaderPreferences {
        var c = p
        // Android's mixer is still addressed per staff. Every staff of a part drove one channel even before
        // strips, so a write from any of its rows lands on the part's tick-0 strip.
        c.stripProgramOverrides[MixerStripID(partIndex: part, instrumentOrdinal: 0)] = program
        return c
    }

    static func setStaffVolume(_ p: ReaderPreferences, part: Int, staff _: Int, volume: Double) -> ReaderPreferences {
        var c = p
        c.stripVolumeOverrides[MixerStripID(partIndex: part, instrumentOrdinal: 0)] = volume
        return c
    }
```

- [ ] **Step 2: Emit each strip once, at staff 0**

The getters are list getters — one wire entry per stored key, carrying its own `partIndex` / `staffIndexInPart`. The bridge holds no score, so it cannot know a part's staff count and cannot fan a value across them. Emit `staffIndexInPart: 0`:

```swift
        // One entry per strip, at staff 0. The bridge has the preferences but not the score, so it cannot
        // enumerate a part's staves to repeat the value across them — which means a multi-staff part's second
        // Compose row reads the score's default while the first shows the stored value. Nothing sounds different
        // (those rows always drove one channel); the value appears to move. A one-line Kotlin fallback — read
        // `(part, staff)`, else `(part, 0)` — removes it, and is the first thing to do when Android's mixer is
        // next opened.
```

Keep the wire field names and order exactly as they are; only the value fed to `staffIndexInPart` changes, to `0`.

- [ ] **Step 3: Add the parity marker**

At the top of `ReaderPreferencesBridge`'s mixer section:

```swift
// PARITY(android): mixer strips — Android's mixer is still addressed per staff. Its writes land on the part's
// tick-0 strip and its reads come back at staff 0, so a multi-staff part's second row shows the score's default
// while the first shows the stored value. Following iOS means reading the strip list from the Android engine
// (never re-deriving the dedup rule in Kotlin) and drawing one row per strip.
```

- [ ] **Step 4: Update the reducer tests**

`ReaderPreferencesReducerTests` asserts on `(part: 1, staff: 0)`; add one that a staff-1 write lands on ordinal 0:

```swift
    @Test func `a write from any staff lands on the part's first strip`() {
        let p = ReaderPreferencesReducer.setStaffVolume(base(), part: 1, staff: 1, volume: 0.25)

        #expect(p.stripVolumeOverrides[MixerStripID(partIndex: 1, instrumentOrdinal: 0)] == 0.25)
        #expect(p.stripVolumeOverrides.count == 1)
    }
```

- [ ] **Step 5: Regenerate the parity ledger and run the suite**

Run: `python3 Scripts/parity-report.py` then `cd Packages/Features/Library && xcodebuild test -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`
Expected: the ledger gains the row; tests PASS. The pre-commit `parity-ledger` hook fails the commit if the file drifted, so regenerate rather than hand-editing.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Library docs/engineering/ios-android-parity.md
git commit -m "refactor(jni): map Android's per-staff mixer writes onto the part's first strip"
```

---

### Task 9: `PlaybackMixerModel` is keyed by strip

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/PlaybackMixerModel.swift` (whole file)
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderPlaybackSession.swift` (refresh the strips when a load completes)
- Modify: `Packages/Features/Reader/Tests/ReaderTests/` — the mixer tests
- Delete: `Packages/Features/Reader/Sources/Reader/Score+FlattenedStaffIndex.swift` if nothing else uses it

**Interfaces:**
- Consumes: `MixerStrip` (Task 2), the controller's strip setters and `mixerStrips()` (Tasks 3, 7).
- Produces: `PlaybackMixerModel.strips: [MixerStrip]`, `.volume(for: MixerStripID)`, `.defaultVolume(for:)`, `.setVolume(_:for:)`, `.commitVolume(_:for:)`, `.toggleMute(_:)`, `.toggleSolo(_:)`, `.effectiveProgram(for:)`, `.hasProgramOverride(for:)`, `.setProgram(_:for:)`, `.clearProgramOverride(for:)`, `.refreshStrips()`.

- [ ] **Step 1: Write the failing test**

Add to the Reader mixer tests (create `PlaybackMixerModelStripTests.swift` if the existing file is staff-shaped):

```swift
    @Test func `a program override on one strip leaves its sibling alone`() async {
        let controller = FakePlaybackController()
        controller.strips = [
            MixerStrip(
                id: MixerStripID(partIndex: 0, instrumentOrdinal: 0), partName: "S",
                instrumentName: "ピアノ", defaultVolume: 0.8, defaultProgram: 0, isDrums: false,
            ),
            MixerStrip(
                id: MixerStripID(partIndex: 0, instrumentOrdinal: 1), partName: "S",
                instrumentName: "アコーディオン", defaultVolume: 0.8, defaultProgram: 21, isDrums: false,
            ),
        ]
        let model = PlaybackMixerModel()
        model.host = FakeMixerHost(controller: controller)
        await model.refreshStrips()

        await model.setProgram(30, for: MixerStripID(partIndex: 0, instrumentOrdinal: 1))

        #expect(model.effectiveProgram(for: MixerStripID(partIndex: 0, instrumentOrdinal: 1)) == 30)
        // The sibling still reports the SCORE's program, not the one just set next door.
        #expect(model.effectiveProgram(for: MixerStripID(partIndex: 0, instrumentOrdinal: 0)) == 0)
        #expect(controller.stripPrograms.map(\.strip) == [MixerStripID(partIndex: 0, instrumentOrdinal: 1)])
    }

    @Test func `the slider's reset target is the score's level, not the saved override`() async {
        let controller = FakePlaybackController()
        controller.strips = [MixerStrip(
            id: MixerStripID(partIndex: 0, instrumentOrdinal: 0), partName: "S",
            instrumentName: "ピアノ", defaultVolume: 0.8, defaultProgram: 0, isDrums: false,
        )]
        let model = PlaybackMixerModel()
        model.host = FakeMixerHost(controller: controller)
        await model.refreshStrips()

        await model.commitVolume(0.2, for: MixerStripID(partIndex: 0, instrumentOrdinal: 0))

        #expect(model.volume(for: MixerStripID(partIndex: 0, instrumentOrdinal: 0)) == 0.2)
        #expect(model.defaultVolume(for: MixerStripID(partIndex: 0, instrumentOrdinal: 0)) == 0.8)
    }
```

`FakeMixerHost` is a small `PlaybackMixerHost` returning the fake controller and a `nil` `playbackScore`; write it in the test file if one does not exist.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd Packages/Features/Reader && xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/PlaybackMixerModelStripTests`
Expected: FAIL to compile — `refreshStrips` and the strip-keyed accessors do not exist.

- [ ] **Step 3: Re-key the model**

Every `[StaffAddress: …]` becomes `[MixerStripID: …]`, every `Set<StaffAddress>` becomes `Set<MixerStripID>`, and the score lookups go away: defaults come from `strips`, not from `playbackScore`.

```swift
    private(set) var strips: [MixerStrip] = []
    private(set) var programOverrides: [MixerStripID: Int] = [:]
    private(set) var volumeOverrides: [MixerStripID: Double] = [:]
    private(set) var mutedStrips: Set<MixerStripID> = []
    private(set) var soloStrips: Set<MixerStripID> = []
    private(set) var liveVolumes: [MixerStripID: Double] = [:]

    private func strip(_ id: MixerStripID) -> MixerStrip? { strips.first { $0.id == id } }

    func refreshStrips() async {
        strips = await host?.playbackController?.mixerStrips() ?? []
    }

    func volume(for id: MixerStripID) -> Double {
        liveVolumes[id] ?? volumeOverrides[id] ?? defaultVolume(for: id)
    }

    /// The SCORE's level — the slider's reset target and tick position, independent of any override.
    func defaultVolume(for id: MixerStripID) -> Double {
        strip(id)?.defaultVolume ?? Self.defaultVolume
    }

    func effectiveProgram(for id: MixerStripID) -> Int {
        programOverrides[id] ?? strip(id)?.defaultProgram ?? 0
    }
```

`setVolume` / `commitVolume` / `toggleMute` / `toggleSolo` / `setProgram` / `clearProgramOverride` keep their present shapes with the `flattenedStaffIndex` lookup deleted — the id goes straight to the controller. Delete the per-part program methods (`effectiveProgram(forPartIndex:)`, `setPartProgram`, `clearPartProgramOverride`, `partStaffAddresses`) and the dead per-staff ones (`setStaffProgram`, `clearStaffProgramOverride`). `sync(from:)` reads the renamed `ReaderPreferences` dictionaries.

- [ ] **Step 4: Refresh at every load**

`ReaderPlaybackSession` has two paths that finish a load — `prepareForPlayback` and the `togglePlayback` fallback that runs when the first was cancelled or failed. Both already set `hasLoadedIntoPlayback = true`; call `await mixerModel.refreshStrips()` at each, next to the existing `onReadyForLoopForward` call, and again at the end of `reloadSoundfont`'s caller. Anchoring only to `prepareForPlayback` would leave the mixer empty for the whole session whenever the fallback path ran.

- [ ] **Step 5: Run the Reader suite**

Run the Step 2 command without `-only-testing`.
Expected: PASS. Delete `Score+FlattenedStaffIndex.swift` if the build shows no remaining caller.

- [ ] **Step 6: Commit**

```bash
git add -A Packages/Features/Reader
git commit -m "refactor(reader): key the mixer model by strip and take its defaults from the engine"
```

---

### Task 10: The inspector draws strips

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/PlaybackInspectorScreen.swift:83-104` (the parts section) and the row builder at `:300-336`
- Modify: `Packages/Features/Reader/Sources/Reader/Views/ProgramPicker.swift` (take a strip, not a part index)
- Modify: `Packages/Features/Reader/Sources/Reader/Views/StaffVisibilityButton.swift` (per-staff accessibility label)

**Interfaces:**
- Consumes: `PlaybackMixerModel.strips` and its strip-keyed accessors (Task 9).
- Produces: no new API — this is the view layer.

- [ ] **Step 1: Group the strips**

Replace the `ForEach(score.parts)` walk with one over the model's strips, grouped by `partIndex` in the engine's order:

```swift
                ForEach(mixerModel.strips.grouped(), id: \.partIndex) { group in
                    let staves = staffAddresses(partIndex: group.partIndex)
                    if group.strips.count == 1, staves.count == 1 {
                        // One strip, one staff: everything on one row, the shape the mixer has always had.
                        stripRow(group.strips[0], label: group.strips[0].partName, staves: staves)
                    } else {
                        // A header appears only when a part is not one-to-one — which is also the only place
                        // left that corresponds to a SET of staves, so it carries their eyes.
                        HStack {
                            Text(group.partName).font(.headline)
                            Spacer()
                            ForEach(Array(staves.enumerated()), id: \.element) { index, address in
                                StaffVisibilityButton(
                                    layoutModel: layoutModel, address: address, staffNumber: index + 1,
                                )
                            }
                        }
                        ForEach(group.strips) { strip in
                            // No label when the part has one strip: the header already named it, and for a
                            // grand staff the two strings are the same word.
                            stripRow(strip, label: group.strips.count == 1 ? nil : strip.instrumentName, staves: [])
                        }
                    }
                }
```

Add the grouping helper in the same file:

```swift
private extension [MixerStrip] {
    struct PartGroup: Identifiable {
        let partIndex: Int
        let partName: String
        let strips: [MixerStrip]
        var id: Int { partIndex }
    }

    /// Strips bucketed by part, keeping the engine's order — by part, then by ordinal — rather than sorting.
    func grouped() -> [PartGroup] {
        var order: [Int] = []
        var byPart: [Int: [MixerStrip]] = [:]
        for strip in self {
            if byPart[strip.id.partIndex] == nil { order.append(strip.id.partIndex) }
            byPart[strip.id.partIndex, default: []].append(strip)
        }
        return order.map { PartGroup(partIndex: $0, partName: byPart[$0]![0].partName, strips: byPart[$0]!) }
    }
}
```

- [ ] **Step 2: Rewrite the row**

`stripRow(_:label:staves:)` replaces `staffRow(address:)`: the label when non-nil, the slider bound to `mixerModel.volume(for: strip.id)` with `defaultVolume(for:)` as its reset, the `S` / `M` buttons calling `toggleSolo` / `toggleMute`, `ProgramPicker(mixerModel:strip:)`, and — only for the collapsed single-row case — the one eye from `staves`. Keep every modifier that is there today (`.tint`, `.disabled(isDisabled)`, the `ReaderHintCoordinator.shared.markUsed(.mixer)` calls, the accessibility labels).

- [ ] **Step 3: Take a strip in the picker**

`ProgramPicker` takes `strip: MixerStrip` instead of `partIndex: Int` / `isDrums: Bool`, reads `strip.isDrums` to choose between `drumKitSections` and the melodic sections, and calls `mixerModel.setProgram(_:for: strip.id)` / `clearProgramOverride(for: strip.id)` where it called the per-part methods. The catalogs themselves do not change.

- [ ] **Step 4: Label the eyes**

`StaffVisibilityButton` gains `let staffNumber: Int` and puts it in its accessibility label, so several in one header are distinguishable:

```swift
        .accessibilityLabel(Text("reader.inspector.staffVisibility.numbered \(staffNumber)", bundle: .module))
```

Add the key to `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings` for every language the file already carries, following the naming scheme `module.feature.thing`. English: `"Staff %lld visibility"`.

- [ ] **Step 5: Check it renders**

Update the `#Preview` at the bottom of `PlaybackInspectorScreen.swift` to build a model with three strips — a one-strip/one-staff part, a one-strip/two-staff part, and a two-strip part — then render it with `mcp__xcode__RenderPreview` and read the PNG. Confirm: the first draws one row, the second a header with two eyes over an unlabelled row, the third a header with one eye over two labelled rows.

- [ ] **Step 6: Run the Reader suite and build the app**

Run the Reader suite, then the app build.
Expected: both PASS / BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add -A Packages/Features/Reader
git commit -m "feat(reader): draw one mixer row per strip, grouped under a part header when needed"
```

---

### Task 11: Re-pin to the released 1.11.0

**Blocked** until swift-sheet-music tags 1.11.0. That package's `Android audio module` CI is red for an unrelated reason — see `~/Desktop/ssm-android-ci-red-handoff.md`. Do not start this task before `git ls-remote --tags` shows the tag.

**Files:**
- Modify: `Packages/Domain/Package.swift`, `Packages/Infrastructure/Package.swift`, `Packages/Features/{Editor,Library,Reader}/Package.swift`, `project.yml`

- [ ] **Step 1: Confirm the tag exists**

```bash
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music ls-remote --tags origin | grep 1.11.0
```

Expected: a line for `refs/tags/1.11.0`. If absent, stop.

- [ ] **Step 2: Re-pin**

```bash
~/.claude/bin/ssm-local-pin.sh "$PWD" --version 1.11.0
```

- [ ] **Step 3: Verify**

Run the app build plus the Domain, Infrastructure, Reader, Editor and Library suites.
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/*/Package.swift Packages/Features/*/Package.swift project.yml
git commit -m "chore(deps): bump swift-sheet-music to 1.11.0"
```

---

## Verification before calling this done

- [ ] App build SUCCEEDED.
- [ ] Domain, Infrastructure, Reader, Editor, Library suites all PASS.
- [ ] `python3 Scripts/parity-report.py` leaves no diff.
- [ ] Manual, on a simulator or device — none of this is reachable by test:
  - a single-staff-per-part score (any of the a cappella arrangements) draws the same number of rows as before, and each slider, M, S and picker still works;
  - a piano grand staff draws a header with two eyes over one row, and hiding either staff still works;
  - the five-part arrangement with piano/accordion changes draws eleven rows, and the accordion rows change the accordion's sound;
  - a drum part's kit picker actually changes the sound — this exercises the swift-sheet-music drum fix, which no test can hear;
  - reopening a score restores the volumes and programs that were set.

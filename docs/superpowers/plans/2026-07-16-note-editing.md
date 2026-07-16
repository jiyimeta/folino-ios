# Note Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship v1 of in-place note editing per the approved spec `docs/superpowers/specs/2026-07-16-note-editing-design.md` (architecture Option 1, all §11 defaults accepted): tap-to-select ("Caret & Pad"), note input / delete / duration / pitch (keys + staff drag), chords, ties, tuplets, accidentals, a voice picker, audition, undo/redo, and debounced autosave to `.mscx`/`.mscz` — with the `Editor` Feature package providing the view model + chrome, the Reader providing a minimal injection seam, and App composing the two.

**Architecture:** Option 1 — Reader overlay seam + App composition. The engine (`swift-sheet-music`, pinned `be336454aa5400300a34b48eca14860d7ad4acbd`) already ships the whole editing command set (`ScoreEditor`, `InputNote`, `SetNotePitch`, `SetAccidental`, `SetChordDuration`/`SetRestDuration`, `DeleteVoiceElement`, `AddNoteToChord`/`RemoveNoteFromChord`, `SetTie`, `CreateTuplet`/`RemoveTuplet`, `CompositeEditCommand`), the selection model (`ScoreSelection`, `ScoreItemID`, `ScoreHitTester`), and MSCX/MSCZ serialization (`MSCXEncoder`, `MSCZWriter`, `SheetMusic.exportMSCX/exportMSCZ`). folino's work: fill the `ScoreFileGateway.saveScore` stub (Infrastructure), build `EditorViewModel` + chrome in the reserved `Editor` package (Domain + `SheetMusicUI` carve-out), add a `ReaderEditingHost` seam to Reader, and wire everything in `App/AppShellView.swift`. Reader never imports Editor; Editor never imports Reader.

**Tech Stack:** Swift 6.3, iOS 26+, SwiftUI + `@Observable`, Swift Testing, `SheetMusicCore` (re-exported by Domain), `SheetMusicUI`/`SheetMusicLayout` (Feature carve-out), Liquid Glass (`glassEffect`), SF Symbols.

**Working directory:** `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/note-editing` (branch `worktree-note-editing`). All paths below are relative to this root unless noted.

---

## Global Constraints

Copied from `CLAUDE.md` / `docs/engineering/module-architecture.md` — these are hard rules for every task:

- **Swift 6.3, iOS 26+**, universal iPad + iPhone, bundle id `com.KeyNumber.Folino`.
- **Build the app:** `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build` (run from repo root; regenerate the project with `xcodegen generate` after any `project.yml` change).
- **Test one Swift package in isolation:** `xcodebuild test -scheme <Pkg|Pkg-Package> -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` **run from the package directory**. `swift test` does NOT work in this repo (SwiftLint build-tool plugin needs a macOS host context the SwiftPM CLI can't satisfy). Scheme names: single-product package = product name (`Editor`, `Reader`, `Domain`); multi-product package = `<PackageName>-Package` (`Infrastructure-Package`). Run a single suite by appending `-only-testing:<TestTarget>/<SuiteName>`.
- **App builds can false-SUCCEED on edited packages** (incremental skip). After editing a package, verify with that package's own scheme and confirm `Compiling` appears in the log (project memory `feedback_verify_feature_package_scheme`).
- **New tests use Swift Testing** — `import Testing`, `@Suite`, `@Test`, `#expect`, `#require`. No new XCTest.
- **Screens/ + Views/ split** in Feature packages: `Screens/` = navigable / presentation-state roots, `Views/` = reusable components. Reference implementation: `Packages/Features/Library/Sources/Library/`.
- **Module boundaries (forbidden):** Feature → Feature; Feature → Infrastructure; Domain → anything above it; ScoreUI → Feature/Infrastructure/App; Utility → anything in-repo. Features may NOT import `swift-sheet-music` model/I/O modules directly — **carve-out:** Feature packages MAY depend directly on `SheetMusicUI` (and transitively import `SheetMusicLayout`/`SheetMusicCore`), as Reader already does.
- **Dependency injection:** pure constructor injection; no DI library; `EnvironmentValues` never used as a service locator for view models.
- **Bumping/adding a SwiftPM dependency:** update the relevant `Package.swift` AND the entry under `packages:` in `project.yml` to the same version/revision. (The ssm pin `be336454aa5400300a34b48eca14860d7ad4acbd` already exists in `project.yml:48-50`; Editor's `Package.swift` must use exactly that revision.)
- **No partial / hunk-level staging** (`git add -p` forbidden). Stage whole files only; the pre-commit hook runs SwiftFormat + `swiftlint --fix` and writes fixes back — if the hook modifies files, re-stage the whole files and commit again.
- **Lowercase `folino`** anywhere a user can read the brand. Never surface internal feature names (Reader/Editor) in user-facing copy — use natural language ("音符を編集", not "Editor").
- **Localization:** user-facing strings via `Text("key", bundle: .module)` with keys in the `module.feature.thing` scheme, stored in the package's `Resources/Localizable.xcstrings` with en/ja/ko/zh-Hans/zh-Hant entries (mirror `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings`).
- **Visual language:** iOS 26 Liquid Glass (`.glassEffect(.regular.interactive())` on button pills, `.glassEffect(.regular, in: shape)` on cards — see `ReaderTransportControl.swift:151,209` and `ReaderTopOverlay.swift`), SF Symbols for icons, follow Reader chrome spacing (44 pt glyph buttons, 12 pt cluster spacing).
- **Comment style:** reflow `//` and `///` paragraphs at the 120-column SwiftLint budget; preserve `// MARK:` and directives.
- **Auto-commit policy:** this IS a spec/plan implementation, so per-task commits are expected. Commit after every task with a conventional message; do not push.

## Context for the Implementer

- **Read the spec first:** `docs/superpowers/specs/2026-07-16-note-editing-design.md`. Everything below implements it; §5 (interaction), §8 (persistence), §9 Option 1 (architecture), §11 defaults (all accepted).
- **Two `ScoreItemID` types exist.** `Domain.ScoreItemID` (library row UUID, in `Packages/Domain/Sources/Domain/IDs.swift`) and `SheetMusicCore.ScoreItemID` (`enum { case note(NoteID); case rest(RestID); case tuplet(TupletID); case clef(ClefAnchor) }`). Domain `@_exported import SheetMusicCore`, so both are visible wherever `Domain` is imported. **Always qualify** (`Domain.ScoreItemID` / `SheetMusicCore.ScoreItemID`) in new code that mentions either — Reader already does this (`ReaderViewModel.swift:305`).
- **Rests are empty chords.** `VoiceElement.chord(Chord)` with `chord.notes.isEmpty` is a rest; `VoiceElement.rest(duration:)` is sugar that builds one (`SheetMusicCore/Score/VoiceElement.swift:49-51`). `DeleteVoiceElement` turns a chord into a same-duration rest.
- **Engine IDs are positional** (`staff/measureIndex/voiceIndex/elementIndex[/noteIndexInChord]`). After every applied command, re-derive selection from `ScoreEditor.lastAffectedLocation: VoiceElementID?` — never reuse a pre-edit ID.
- **Editing renders the raw score.** While editing, the Reader displays the editor's live `Score` with **no transpose, no hidden-staves filter, no multi-measure-rest collapse** (each of those either changes positional addressing — `filtered(hidingStaves:)` re-addresses staves — or breaks hit-testing). This also delivers spec §11-3 (written-pitch editing + transpose lock) for free: the transpose stepper lives in the Visual Inspector, whose top-overlay entry is hidden during edit mode. Clef overrides are also suspended during editing (they replace element `[0]` in place — index-safe — but suspending keeps the display pipeline to a single input; they restore on exit).
- **Edit mode uses the vertical container only.** Entering edit mode presents the score in `VerticalScoreContainer` regardless of the persisted layout mode (the `@AppStorage` value is untouched and the user's page/horizontal mode returns on exit). Rationale: continuous scroll is the natural editing canvas — a note edit reflows the layout, which in page mode can shuffle pagination under the user's finger — and it keeps the seam to one container. This is a v1 presentation scoping decision within spec §5.8's "one responsive feature" frame.
- **Layout cache invalidation gotcha:** `VerticalScoreContainer.TaskKey.scoreSignature` hashes only structure (`parts.count`, staff count, `division`, opening clefs, transpose). A note edit changes none of those, so without a new `editGeneration` input the layout would never rebuild after an edit. Task 12 adds it.
- **The engine's `playPreview` needs the fresh score.** `PlaybackEngine.playPreview(noteID:in:duration:velocity:)` resolves pitch against the `Score` you pass in, but the existing Domain method `playPreview(noteID:duration:)` passes the controller's `loadedScore` — stale after edits (a freshly-input note would resolve to the old rest and play nothing). Task 2 adds a score-parameterized Domain method.
- **`ScoreItem.contentHash` is `let`** (`Packages/Domain/Sources/Domain/Models/ScoreItem.swift:21`) with a "never edited after import" doc comment. Editing invalidates that: Task 10 rebuilds the row via the public memberwise init (same `id`, new hash/size) and updates the doc comment.
- **ssm clone for reference:** `~/Developer/Personal/swift-packages/swift-sheet-music` — its `main` contains the pin `be336454` as an ancestor and none of the Editing/Selection/MSCX files differ from the pin, so the clone's sources are authoritative for the signatures quoted below.
- **Layout-render tests need font install** (project memory): any test that runs `LayoutEngine.layout(...)` must reference `SheetMusicLayoutApple.install` first or it hits a FontMetrics-provider precondition crash. Task 8 wires this.

### Engine API quick reference (verified at the pin — do not re-invent)

```swift
// SheetMusicCore (re-exported by Domain)
@MainActor public final class ScoreEditor {
    public private(set) var score: Score
    public private(set) var lastAffectedLocation: VoiceElementID?
    public init(score: Score)
    public var canUndo: Bool { get }
    public var canRedo: Bool { get }
    public func apply(_ command: any EditCommand) throws
    public func undo() throws
    public func redo() throws
}
public struct VoiceElementID: Hashable, Sendable {
    public let staff: StaffAddress; public let measureIndex: Int
    public let voiceIndex: Int; public let elementIndex: Int
    public init(staff: StaffAddress, measureIndex: Int, voiceIndex: Int, elementIndex: Int)
    public init(_ id: RestID); public init(_ id: NoteID)
}
public struct NoteID: Hashable, Sendable {   // + noteIndexInChord
    public init(staff: StaffAddress, measureIndex: Int, voiceIndex: Int, elementIndex: Int, noteIndexInChord: Int)
}
public struct RestID: Hashable, Sendable {
    public init(staff: StaffAddress, measureIndex: Int, voiceIndex: Int, elementIndex: Int)
}
public struct InputNote: EditCommand { public init(at location: RestID, pitch: Int, tpc: Int) }
public struct SetNotePitch: EditCommand { public init(at location: NoteID, pitch: Int, tpc: Int, accidental: Accidental? = nil) }
public struct SetAccidental: EditCommand { public init(at location: NoteID, accidental: Accidental?) }
public struct SetChordDuration: EditCommand { public init(at location: VoiceElementID, duration: NoteDuration) }
public struct SetRestDuration: EditCommand { public init(at location: VoiceElementID, duration: NoteDuration) }
public struct DeleteVoiceElement: EditCommand { public init(at location: VoiceElementID) }
public struct AddNoteToChord: EditCommand { public init(at location: VoiceElementID, pitch: Int, tpc: Int, accidental: Accidental? = nil) }
public struct RemoveNoteFromChord: EditCommand { public init(at location: NoteID) }
public struct SetTie: EditCommand { public init(from sourceID: NoteID, to targetID: NoteID, sourceTieForward: Int?, targetTieBack: Int?) }
public struct CreateTuplet: EditCommand { public init(at location: VoiceElementID, actualNotes: Int, normalNotes: Int) }
public struct RemoveTuplet: EditCommand { public init(at location: VoiceElementID) }
public struct CompositeEditCommand: EditCommand { public init(commands: [any EditCommand], location: VoiceElementID) }
public enum NoteInputKeyMap {
    public static func pitch(forLetter letter: Character, octave: Int) -> (pitch: Int, tpc: Int)?
    public static func duration(forCharacter character: String) -> NoteDuration?
}
public enum PitchSpelling {
    public static func shiftedTpc(from priorPitch: Int, priorTpc: Int, to newPitch: Int, in keySig: Int = 0) -> Int
    public static func respelled(from note: Note, with accidental: Accidental?) -> (pitch: Int, tpc: Int)
    public static func displayedAccidental(forTpc tpc: Int, in keySig: Int) -> Accidental?
}
extension Note { public func shifted(bySemitones delta: Int, in keySig: Int = 0) -> Note? }
extension Score {
    public subscript(id: VoiceElementID) -> VoiceElement? { get set }
    public subscript(noteID: NoteID) -> Note? { get }
    public subscript(restID: RestID) -> Chord? { get }
    public func activeKey(staff: StaffAddress, measureIndex: Int) -> Int
    public func activeKey(at noteID: NoteID) -> Int
}
// Accidental cases used in v1: .flat, .natural, .sharp, .doubleSharp, .doubleFlat
// NoteDuration cases used in v1: .whole, .half, .quarter, .eighth, .sixteenth, .thirtySecond, .sixtyFourth, .measure
// Note(pitch:tpc:accidental:...) / Chord(duration:notes:) / ChordNotes is ExpressibleByArrayLiteral with tryAppend(_:) -> Bool

// SheetMusicUI (Feature carve-out)
public enum ScoreSelection: Sendable, Equatable { case none; case single(ScoreItemID); case range(anchor:target:); case multi(Set<ScoreItemID>) }
public struct ScoreHitTester: Sendable {
    public let document: LayoutDocument
    public init(document: LayoutDocument)
    public func hitTest(at point: CGPoint) -> ScoreHitTarget?    // notehead → rest → beam → flag → stem → tuplet → clef
    public func itemID(at point: CGPoint) -> ScoreItemID?        // filtered to .note / .rest / .tuplet / .clef
    public func itemIDs(in rect: CGRect) -> [ScoreItemID]        // zero-size rect returns []
}
public struct ScoreView: View {
    public init(document: LayoutDocument, score: Score, options: ScoreViewOptions = .init(),
                selection: ScoreSelection = .none, voiceColors: [Int: Color] = [:],
                playbackCursor: ScoreCursor? = nil, playbackCursorColor: Color = Color.blue.opacity(0.15))
}

// SheetMusicLayout (transitively importable — Reader precedent, VerticalScoreContainer.swift:8)
public func nearestCursor(at point: CGPoint, in document: LayoutDocument) -> ScoreCursor?
extension LayoutDocument {
    public func cursorFrame(for cursor: ScoreCursor, in score: Score) -> CGRect?  // Y spans the whole system
    public func chordStemOrigin(at id: VoiceElementID) -> CGPoint?
}
// LayoutSystem: public let origin/size/measures/staffOrigins: [CGPoint]/staffAddresses: [StaffAddress]/sp: CGFloat
// LayoutMeasure elements are pattern-matchable: case .chord(notes, dur, stem, stemOrigin, _, _, isBeamed, voiceIdx, _, _, _),
// case .rest(duration, origin, _, restID, _) — exactly as ScoreHitTester.swift matches them.

// SheetMusic / SheetMusicMSCX (Infrastructure only)
public static func SheetMusic.exportMSCX(_ score: Score, to url: URL) throws
public static func SheetMusic.exportMSCZ(_ score: Score, to url: URL) throws   // MSCX semantic round-trip: reparse == input
```

---

## Task Overview

| # | Task | Layer | Verification |
| --- | --- | --- | --- |
| 1 | Wire `LiveScoreFileGateway.saveScore` | Infrastructure | TDD round-trip test |
| 2 | Score-parameterized `playPreview` on `PlaybackController` | Domain + Infra | TDD (Domain test) |
| 3 | Editor package scaffolding + `EditorViewModel` session core | Editor | TDD |
| 4 | Selection re-derivation + auto-advance helpers | Editor | TDD |
| 5 | Note input, delete, duration change | Editor | TDD |
| 6 | Pitch: semitone/octave keys, staff-step drag math, accidentals | Editor | TDD |
| 7 | Chords, ties, tuplets, voices | Editor | TDD |
| 8 | Tap → selection hit-test mapping | Editor | TDD (real `LayoutDocument`) |
| 9 | Audition | Editor | TDD (fake controller) |
| 10 | Autosave + `ScoreItem` refresh + MusicXML sibling policy | Editor + Domain doc | TDD |
| 11 | Reader seam 1: `ReaderEditingHost` + edit-mode lifecycle | Reader | TDD (VM) + build |
| 12 | Reader seam 2: score-surface wiring (tap, selection, caret, drag) | Reader | Preview render |
| 13 | Editor chrome: bottom pad (iPhone/iPad) | Editor | Preview render |
| 14 | Editor chrome: callout, iPad palette, voice picker, top cluster, strings | Editor | Preview render |
| 15 | App composition: `EditableReaderScreen` + `project.yml` | App | Full app build |
| 16 | Polish: loupe, hover, system undo gestures, one-time notice | Editor + Reader | Preview + build |
| 17 | Final gate: all package tests + app build + manual checklist | all | commands below |

---

### Task 1: Wire `LiveScoreFileGateway.saveScore` (TDD)

The Domain protocol `ScoreFileGateway.saveScore(_:fileURL:format:)` (`Packages/Domain/Sources/Domain/Protocols/ScoreFileGateway.swift:71`) is already declared; the live implementation throws `unsupportedFormat` for everything. Fill it with `SheetMusic.exportMSCX/exportMSCZ`, off-main.

**Files**

- Modify: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreFileGateway.swift` (lines 97–100, the `saveScore` stub; also the doc comment)
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreFileGatewayTests.swift` (lines 99–112, replace the `save score throws unsupported format in V 1` test)
- Modify: `Packages/Domain/Sources/Domain/Protocols/ScoreFileGateway.swift` (lines 66–71, doc comment only — the "v1 throws for every format" paragraph is now wrong; no signature change)

**Interfaces**

- Consumes: `SheetMusic.exportMSCX(_ score: Score, to url: URL) throws`, `SheetMusic.exportMSCZ(_ score: Score, to url: URL) throws` (already `import SheetMusic` in this file), `DomainError.scoreWriteFailed(reason: String)`, `DomainError.unsupportedFormat(String)`.
- Produces: working `public func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) async throws` for `.mscx`/`.mscz`; still throws `unsupportedFormat` for `.musicXML`/`.mxl`/`.midi`/`.pdf` (the format *policy* — routing a MusicXML source to a sibling `.mscz` — is the Editor's job in Task 10; the gateway stays a dumb format writer).

**Steps**

- [ ] In `LiveScoreFileGatewayTests.swift`, replace the test at lines 99–112 with three tests (the existing `Fixtures` and `TempDirectory` helpers in `Tests/InfrastructureTests/TestSupport/` are already used by this file):

```swift
@Test func `save score round trips MSCX semantically`() async throws {
    let tmp = try TempDirectory()
    let gateway = LiveScoreFileGateway()
    let score = try SheetMusic.loadScore(mscxData: Fixtures.minimalMSCXData())
    let outURL = tmp.url.appending(path: "out.mscx")
    try await gateway.saveScore(score, fileURL: outURL, format: .mscx)
    let reloaded = try await gateway.loadScore(fileURL: outURL)
    #expect(reloaded.score == score)
}

@Test func `save score round trips MSCZ semantically`() async throws {
    let tmp = try TempDirectory()
    let gateway = LiveScoreFileGateway()
    let score = try SheetMusic.loadScore(mscxData: Fixtures.minimalMSCXData())
    let outURL = tmp.url.appending(path: "out.mscz")
    try await gateway.saveScore(score, fileURL: outURL, format: .mscz)
    let reloaded = try await gateway.loadScore(fileURL: outURL)
    #expect(reloaded.score == score)
}

@Test func `save score still rejects encoder-less formats`() async throws {
    let tmp = try TempDirectory()
    let gateway = LiveScoreFileGateway()
    let score = try SheetMusic.loadScore(mscxData: Fixtures.minimalMSCXData())
    for format in [ScoreFormat.musicXML, .mxl, .midi, .pdf] {
        do {
            try await gateway.saveScore(score, fileURL: tmp.url.appending(path: "x.bin"), format: format)
            Issue.record("expected throw for \(format)")
        } catch DomainError.unsupportedFormat {
            // Expected.
        }
    }
}
```

- [ ] Run and watch the first two fail (from `Packages/Infrastructure`): `xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/LiveScoreFileGatewayTests`
- [ ] Implement `saveScore`, replacing lines 97–100:

```swift
public func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) async throws {
    switch format {
    case .mscx, .mscz:
        try await Task.detached(priority: .userInitiated) {
            do {
                if format == .mscx {
                    try SheetMusic.exportMSCX(score, to: fileURL)
                } else {
                    try SheetMusic.exportMSCZ(score, to: fileURL)
                }
            } catch {
                throw DomainError.scoreWriteFailed(reason: "\(error)")
            }
        }.value
    case .musicXML, .mxl, .midi, .pdf:
        // No upstream encoder for these formats. The Editor saves such sources as a sibling `.mscz` instead
        // (format policy lives in the Editor feature, not here).
        throw DomainError.unsupportedFormat(format.canonicalExtension)
    }
}
```

- [ ] Run the same command again; all three tests pass.
- [ ] Update the stale doc comments: in `ScoreFileGateway.swift:66-71` describe the real contract ("Writes `.mscx`/`.mscz` via the engine's encoder — semantic round-trip guaranteed; throws `DomainError.unsupportedFormat` for formats with no encoder (MusicXML/MXL/MIDI/PDF) and `DomainError.scoreWriteFailed` on I/O or encode failure"); shrink `LiveScoreFileGateway.swift`'s old "The Editor plan will fill this in" comment accordingly.
- [ ] Commit: `feat(infrastructure): implement ScoreFileGateway.saveScore for mscx/mscz`

---

### Task 2: Score-parameterized `playPreview` on `PlaybackController` (TDD)

Audition must sound pitches from the **edited** score; the existing `playPreview(noteID:duration:)` resolves against the controller's `loadedScore` (stale during editing). Add an overload that takes the score explicitly — the engine API `PlaybackEngine.playPreview(noteID:in:duration:velocity:)` already accepts one (`SheetMusicAudioApple/PlaybackEngine.swift:682`).

**Files**

- Modify: `Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift` (insert after the existing `playPreview` at lines 49–54)
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController+Preview.swift` (whole file is 15 lines)
- Modify: `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift` (near lines 95–99)
- Modify: `Packages/Domain/Tests/DomainTests/Protocols/AudioProtocolsTests.swift` (its private `FakePlaybackController`, method list around line 37)

**Interfaces**

- Produces (Domain protocol requirement):

```swift
/// Like `playPreview(noteID:duration:)`, but resolves the `NoteID` against the caller-supplied `score` instead of the
/// score loaded into the engine. Used by note editing, where the engine's loaded score is stale mid-session: the
/// edited score has the fresh pitches, while the engine's per-staff sampler graph is still valid because v1 editing
/// never adds or removes staves. No-op when the engine has no prepared graph.
func playPreview(noteID: NoteID, in score: Score, duration: TimeInterval) async
```

- Consumes (Infrastructure impl): `engine.playPreview(noteID: NoteID, in: Score, duration: TimeInterval, velocity: UInt8)` — pass through with default velocity, exactly as the existing method does.

**Steps**

- [ ] Add a failing assertion to `AudioProtocolsTests.swift`: extend its `FakePlaybackController` with a recording implementation and assert the call is observable:

```swift
private(set) var scorePreviewCalls: [(noteID: NoteID, duration: TimeInterval)] = []
func playPreview(noteID: NoteID, in _: Score, duration: TimeInterval) {
    scorePreviewCalls.append((noteID, duration))
}
```

  and in the existing test body (`playback controller sets cursor and tempo`, or a new sibling test) call it with a `NoteID(staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0)` on `Score(division: 480)` and `#expect(controller.scorePreviewCalls.count == 1)`. First add ONLY the protocol requirement to `PlaybackController.swift` and run the Domain tests — the fake no longer conforms → compile failure is the red step.
- [ ] Run (from `Packages/Domain`): `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` — confirm the conformance error.
- [ ] Add the fake method + test assertion above; run again → green.
- [ ] Implement in `LivePlaybackController+Preview.swift` (append to the existing extension):

```swift
public func playPreview(noteID: NoteID, in score: Score, duration: TimeInterval) {
    // Editing-mode preview: the caller's score carries the fresh pitches; the engine's sampler graph (built at
    // load time) is still addressable because v1 editing never changes the staff count.
    engine.playPreview(noteID: noteID, in: score, duration: duration)
}
```

- [ ] Update `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift` — add next to the existing preview recorder:

```swift
private(set) var recordedScorePreviewCalls: [(noteID: NoteID, duration: TimeInterval)] = []

func playPreview(noteID: NoteID, in _: Score, duration: TimeInterval) {
    recordedScorePreviewCalls.append((noteID: noteID, duration: duration))
}
```

- [ ] Verify Reader still compiles+passes (from `Packages/Features/Reader`): `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`
- [ ] Verify Infrastructure builds (from `Packages/Infrastructure`): `xcodebuild build -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`
- [ ] Commit: `feat(domain): add score-parameterized playPreview for edit-mode audition`

---

### Task 3: Editor package scaffolding + `EditorViewModel` session core (TDD)

Fill the reserved `Editor` package: add the ssm dependency (`SheetMusicUI` carve-out, same pin), localization scaffolding, the test fixture, and the `EditorViewModel` session skeleton (begin/end session, apply-through-editor, undo/redo, mutation generation, `onScoreChanged`).

**Files**

- Modify: `Packages/Features/Editor/Package.swift` (whole file — 31 lines today)
- Delete: `Packages/Features/Editor/Sources/Editor/Placeholder.swift`
- Create: `Packages/Features/Editor/Sources/Editor/Editor.swift` (module marker, keeps the existing smoke test compiling)
- Create: `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift`
- Create: `Packages/Features/Editor/Sources/Editor/Resources/Localizable.xcstrings` (empty skeleton: `{"sourceLanguage":"en","strings":{},"version":"1.0"}` — keys land in Tasks 13/14)
- Create: `Packages/Features/Editor/Tests/EditorTests/Support/EditorFixtures.swift`
- Create: `Packages/Features/Editor/Tests/EditorTests/EditorViewModelSessionTests.swift`

**Interfaces**

- Produces `Package.swift` (full replacement — note `defaultLocalization`, resources, the ssm pin identical to `project.yml:48-50`, and the test-only `SheetMusicLayoutApple` product used from Task 8 on):

```swift
// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "Editor",
    defaultLocalization: "en",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "Editor", targets: ["Editor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", exact: "0.63.2"),
        .package(path: "../../Domain"),
        .package(path: "../../Utility"),
        .package(
            url: "https://github.com/jiyimeta/swift-sheet-music.git",
            revision: "be336454aa5400300a34b48eca14860d7ad4acbd",
        ),
    ],
    targets: [
        .target(
            name: "Editor",
            dependencies: [
                "Domain",
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "UtilityUI", package: "Utility"),
                .product(name: "SheetMusicUI", package: "swift-sheet-music"),
            ],
            resources: [.process("Resources")],
            plugins: swiftLintPlugins,
        ),
        .testTarget(
            name: "EditorTests",
            dependencies: [
                "Editor",
                .product(name: "SheetMusicLayoutApple", package: "swift-sheet-music"),
            ],
        ),
    ],
)
```

- Produces `EditorViewModel` core (public surface — later tasks extend it in same-type extension files, mirroring the `ReaderViewModel+*.swift` convention):

```swift
import Domain
import Foundation
import Observation
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI

/// Owns the engine `ScoreEditor` for one editing session: applies commands, manages selection / voice / arming
/// state, re-derives selection after every mutation, and drives autosave. Created once per Reader screen by the App
/// composition root; `beginSession(score:)` / `endSession()` bracket each entry into edit mode.
@MainActor
@Observable
public final class EditorViewModel {
    public private(set) var editor: ScoreEditor?
    /// The editor's live score, or nil outside a session. Views and the Reader seam render THIS score while editing.
    public var score: Score? { editor?.score }
    /// Bumped on every applied / undone / redone command. The Reader includes it in its layout task key so the
    /// score re-lays-out after edits that don't change the structural score signature.
    public private(set) var generation = 0
    public var isSessionActive: Bool { editor != nil }

    // Selection (rendered by the Reader through the seam).
    public private(set) var selection: ScoreSelection = .none
    public private(set) var selectedItem: SheetMusicCore.ScoreItemID?

    // Arming state (Tasks 5/7). internal(set), not private(set): the ops live in same-type extensions in OTHER
    // files (`EditorViewModel+Input.swift` etc.), and Swift's `private` does not span files.
    public internal(set) var armedDuration: NoteDuration?
    public internal(set) var isAddToChordArmed = false
    public var activeVoice = 0

    // Stored autosave / audition state — declared HERE (extensions cannot add stored properties); used by
    // Tasks 9/10: `@ObservationIgnored var autosaveTask: Task<Void, Never>?`,
    // `@ObservationIgnored var auditionTask: Task<Void, Never>?`, `@ObservationIgnored var isDirty = false`,
    // and `public internal(set) var didSaveAsSiblingMSCZ = false`.

    public var canUndo: Bool { editor?.canUndo ?? false }
    public var canRedo: Bool { editor?.canRedo ?? false }

    // Wired by the App composition root.
    /// Returns the Reader's current LayoutDocument for hit-testing (Task 8).
    public var documentProvider: @MainActor () -> LayoutDocument? = { nil }
    /// Fired after every score mutation with the fresh score (App mirrors it into the Reader seam).
    public var onScoreChanged: @MainActor (Score) -> Void = { _ in }
    /// Fired whenever selection changes (App mirrors it into the Reader seam).
    public var onSelectionChanged: @MainActor (ScoreSelection, SheetMusicCore.ScoreItemID?) -> Void = { _, _ in }

    @ObservationIgnored let gateway: any ScoreFileGateway
    @ObservationIgnored let repository: any ScoreLibraryRepository
    @ObservationIgnored let playback: (any PlaybackController)?
    /// Internal (not private) so `EditorViewModel+Persistence.swift` can replace it after a save refreshes the row.
    @ObservationIgnored var scoreItem: ScoreItem
    @ObservationIgnored let scoresDirectory: URL

    public init(
        scoreItem: ScoreItem,
        scoresDirectory: URL,
        gateway: any ScoreFileGateway,
        repository: any ScoreLibraryRepository,
        playback: (any PlaybackController)?,
    )

    public func beginSession(score: Score)
    /// Flushes any pending autosave (Task 10) and tears the session down.
    public func endSession() async

    public func undo()
    public func redo()

    /// Central apply choke point: every command goes through here so selection re-derivation, generation bump,
    /// onScoreChanged, and (Task 10) autosave scheduling can never be skipped. Internal — ops extensions call it.
    func applyCommand(_ command: any EditCommand)
}
```

  `applyCommand` body: `guard let editor else { return }`; `try editor.apply(command)` in a do/catch (on `SheetMusicError.invalidEdit` just return — a refused edit leaves the score untouched by the engine's contract; no user-facing error in v1); then `generation += 1`, re-derive selection (Task 4 helper — until then set `selection = .none`), fire `onScoreChanged(editor.score)`. `undo()`/`redo()` mirror this (guard `canUndo`/`canRedo` first). `beginSession` sets `editor = ScoreEditor(score: score)`, resets selection/arming/generation. `endSession` awaits the (Task 10) flush — until then just sets `editor = nil`.

- Produces `EditorFixtures` (test support; copies the engine's own editing-test fixture shape, buildable without `@testable` because every model init is public):

```swift
import Domain  // re-exports SheetMusicCore

enum EditorFixtures {
    static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    /// One part, one staff, one measure of four quarter rests in 4/4.
    /// Voice elements: [0] timeSignature(4/4), [1..4] rest(quarter).
    static func fourQuarterRests() -> Score {
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
        ])
        let measure = Measure(voices: [voice])
        let staff = Staff(measures: [measure])
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])
        return Score(division: 480, parts: [part])
    }

    /// Same, but element index 1 is a quarter chord on C4 (pitch 60, tpc 14).
    static func chordAtIndex1() -> Score {
        var score = fourQuarterRests()
        let id = VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        score[id] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
        return score
    }

    static func restID(element: Int) -> RestID {
        RestID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    static func noteID(element: Int, noteIndex: Int = 0) -> NoteID {
        NoteID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element, noteIndexInChord: noteIndex)
    }
}
```

**Steps**

- [ ] Replace `Package.swift` with the content above; delete `Placeholder.swift`; create `Editor.swift` containing `enum EditorModule { static let isLinked = true }` (the existing `EditorTests.swift` smoke test keeps passing).
- [ ] Create the empty `Resources/Localizable.xcstrings` skeleton and `EditorFixtures.swift` as above.
- [ ] Write the failing session test `EditorViewModelSessionTests.swift`:

```swift
@testable import Editor
import Domain
import Testing

@MainActor
@Suite("EditorViewModel session")
struct EditorViewModelSessionTests {
    private func makeViewModel() -> EditorViewModel {
        EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),   // add to EditorFixtures: any ScoreItem with localFileName "x.mscz"
            scoresDirectory: URL(filePath: "/tmp"),
            gateway: FakeScoreFileGateway(),          // add minimal fake: records saveScore calls, loadScore unimplemented-fatalError
            repository: FakeScoreLibraryRepository(), // add minimal fake: stores saved items in an array
            playback: nil,
        )
    }

    @Test func `beginSession arms the editor and applyCommand mutates + notifies`() throws {
        let vm = makeViewModel()
        var changedScores: [Score] = []
        vm.onScoreChanged = { changedScores.append($0) }
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        #expect(vm.isSessionActive)
        #expect(vm.generation == 0)
        vm.applyCommand(InputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14))
        #expect(vm.generation == 1)
        #expect(changedScores.count == 1)
        let note = try #require(vm.score?[EditorFixtures.noteID(element: 1)])
        #expect(note.pitch == 60)
    }

    @Test func `undo and redo round trip and bump generation`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        vm.applyCommand(InputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14))
        #expect(vm.canUndo && !vm.canRedo)
        vm.undo()
        #expect(!vm.canUndo && vm.canRedo)
        #expect(vm.score == EditorFixtures.fourQuarterRests())
        vm.redo()
        #expect(vm.canUndo && !vm.canRedo)
        #expect(vm.generation == 3)
    }

    @Test func `invalid edit is swallowed and mutates nothing`() {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.fourQuarterRests())
        // Element 1 is a rest, not a note — SetNotePitch must refuse; the VM must not bump generation.
        vm.applyCommand(SetNotePitch(at: EditorFixtures.noteID(element: 1), pitch: 61, tpc: 21))
        #expect(vm.generation == 0)
        #expect(vm.score == EditorFixtures.fourQuarterRests())
    }
}
```

  Also add to `EditorFixtures`: `static func sampleItem() -> ScoreItem` (use the full memberwise init from `ScoreItem.swift:39-60` with dummy values, `localFileName: "score.mscz"`, `contentHash: "0"`), plus the two minimal fakes in `Tests/EditorTests/Support/Fakes.swift` — `FakeScoreFileGateway: ScoreFileGateway` (record `savedCalls: [(Score, URL, ScoreFormat)]`; `detectFormat` delegates to `ScoreFormat.detect`; `loadFileMetadata`/`loadScore` throw `DomainError.unsupportedFormat("test")`) and `FakeScoreLibraryRepository: ScoreLibraryRepository` (copy the shape of `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakeScoreLibraryRepository.swift`, trimmed to stored arrays + recorded `saveScoreItem` calls).
- [ ] Run (from `Packages/Features/Editor`): `xcodebuild test -scheme Editor -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` — fails (no `EditorViewModel`).
- [ ] Implement `EditorViewModel.swift` per the Interfaces block; run again → green (the `generation == 3` expectation: apply=1, undo=2, redo=3).
- [ ] Commit: `feat(editor): package scaffolding + EditorViewModel session core`

---

### Task 4: Selection re-derivation + auto-advance helpers (TDD)

Positional IDs drift after every mutation. Centralize (a) "what should be selected after this command" from `lastAffectedLocation`, and (b) "the next timed element" for auto-advance (spec §11-5: advance after pitch-key input, not after drag).

**Files**

- Create: `Packages/Features/Editor/Sources/Editor/SelectionRederivation.swift`
- Create: `Packages/Features/Editor/Sources/Editor/ElementNavigator.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift` (`applyCommand` / `undo` / `redo` call the helper; add internal `func select(_ item: SheetMusicCore.ScoreItemID?)` that sets `selection`/`selectedItem` and fires `onSelectionChanged`)
- Create: `Packages/Features/Editor/Tests/EditorTests/SelectionRederivationTests.swift`
- Create: `Packages/Features/Editor/Tests/EditorTests/ElementNavigatorTests.swift`

**Interfaces**

```swift
/// Maps the engine's post-mutation `lastAffectedLocation` back to a selectable item against the CURRENT score.
enum SelectionRederivation {
    /// nil when the location no longer resolves (e.g. undo of an input at a spliced index).
    /// - chord with notes → .note(noteIndexInChord: min(previousNoteIndex ?? 0, notes.count - 1))
    /// - empty chord (rest) → .rest
    /// - non-timed element or out of range → nil
    static func item(
        at location: VoiceElementID,
        in score: Score,
        preferringNoteIndex previousNoteIndex: Int?,
    ) -> SheetMusicCore.ScoreItemID?
}

/// Voice-order walking for caret auto-advance.
enum ElementNavigator {
    /// The next chord/rest slot after `location` in the same voice, skipping non-timed elements
    /// (clef / key sig / time sig / barline...), continuing into the next measure's same voice.
    /// nil at the end of the staff.
    static func nextTimedElement(after location: VoiceElementID, in score: Score) -> VoiceElementID?
}
```

**Steps**

- [ ] Write failing tests. `SelectionRederivationTests`: (1) location of `chordAtIndex1()` element 1 → `.note(EditorFixtures.noteID(element: 1))`; (2) same score element 2 (a rest) → `.rest(EditorFixtures.restID(element: 2))`; (3) element 0 (time signature) → nil; (4) elementIndex 99 → nil; (5) `preferringNoteIndex: 5` on a 1-note chord clamps to note index 0. `ElementNavigatorTests`: (1) after element 1 in `fourQuarterRests()` → element 2; (2) after element 4 (last) → nil (single-measure fixture); (3) two-measure fixture (add a second measure to the fixture inline in the test: `score.parts[0].staves[0].measures.append(Measure(voices: [Voice(elements: [.rest(duration: .measure)])]))`) — after element 4 of measure 0 → `VoiceElementID(staff: staff0, measureIndex: 1, voiceIndex: 0, elementIndex: 0)`; (4) skipping: a measure whose voice starts with `.clef(...)` — next timed element is the following rest [verify: `Clef` has a usable public init — `Clef(concertClefType: "G")` is used by `Score+DisplayTransforms.swift:283`; if the initializer needs more arguments, build the fixture with a `.keySignature(KeySignature(concertKey: 0))` leading element instead, which has a known public init].
- [ ] Run the Editor scheme → red. Implement both helpers (walk `score[staff]?.measures[...].voices[voiceIndex].elements`, using `VoiceElement.tickCount(division:) != nil` — public, `VoiceElement.swift:74` — as the "timed element" predicate). Run → green.
- [ ] Wire into the VM: `applyCommand` and `undo`/`redo` end with `select(SelectionRederivation.item(at: editor.lastAffectedLocation ?? <unchanged>, in: editor.score, preferringNoteIndex: <previous selectedItem's noteIndexInChord if it was a .note at the same slot>))`. Add a VM test to `EditorViewModelSessionTests`: after `applyCommand(InputNote(...))` at rest 1, `selectedItem == .note(EditorFixtures.noteID(element: 1))` and `selection == .single(.note(EditorFixtures.noteID(element: 1)))`.
- [ ] Run the full Editor scheme → green.
- [ ] Commit: `feat(editor): selection re-derivation + voice-order navigation`

---

### Task 5: Note input, delete, duration change (TDD)

The pad's core operations, per spec §5.3. All in a same-type extension `EditorViewModel+Input.swift`.

**Files**

- Create: `Packages/Features/Editor/Sources/Editor/NoteInputPlanner.swift`
- Create: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Input.swift`
- Create: `Packages/Features/Editor/Tests/EditorTests/NoteInputPlannerTests.swift`
- Create: `Packages/Features/Editor/Tests/EditorTests/EditorViewModelInputTests.swift`

**Interfaces**

```swift
/// Chooses the octave for a letter key: the candidate pitch closest to the reference (previous note), ties resolved
/// upward. Reference nil → octave 4 (MuseScore's default entry octave; NoteInputKeyMap octave 4 contains middle C).
enum NoteInputPlanner {
    static func pitch(forLetter letter: Character, nearestTo referencePitch: Int?) -> (pitch: Int, tpc: Int)?
}

extension EditorViewModel {
    /// Letter key C…B. Rest selected → InputNote (wrapped with SetRestDuration in a CompositeEditCommand when a
    /// different duration is armed). Note selected + add-to-chord armed → AddNoteToChord (Task 7). Note selected,
    /// not armed → SetNotePitch to that letter's in-key pitch nearest the current pitch. Auto-advances to the next
    /// timed element afterwards (spec §11-5: on after keys).
    public func inputPitch(letter: Character)

    /// ⌫. Multi-note chord + .note selection → RemoveNoteFromChord; single-note chord or whole-element selection →
    /// DeleteVoiceElement (same-duration rest, measure length invariant); .tuplet selection → RemoveTuplet.
    /// Selection stays on the affected slot (now a rest) via re-derivation.
    public func deleteSelection()

    /// Duration key. Applies SetChordDuration / SetRestDuration to the selection AND arms `armedDuration` for the
    /// next input. With no selection, only arms.
    public func setDuration(_ duration: NoteDuration)

    /// Reference pitch for octave choice: the previous chord's first note walking backwards in voice order from the
    /// selection, else nil. Internal.
    func referencePitch(before location: VoiceElementID) -> Int?
}
```

**Steps**

- [ ] `NoteInputPlannerTests` (red first): reference 60 (C4) + "b" → (59, 19) (B3, distance 1 beats B4 distance 11); reference 60 + "f" → (65, 13); reference 59 + "f" → tie 53/65 → picks 65 (upward); reference nil + "c" → (60, 14); "x" → nil. Implement by evaluating `NoteInputKeyMap.pitch(forLetter:octave:)` over octaves 0…8 and minimizing `abs(pitch - reference)`.
- [ ] `EditorViewModelInputTests` (red first, building on the Task 3/4 harness — every test: `makeViewModel()`, `beginSession`, set selection via the internal `select(...)`):
  - **input on rest, no armed duration:** select `.rest(restID(element: 1))` in `fourQuarterRests()`; `inputPitch(letter: "c")` → element 1 is a C4 quarter chord; selection auto-advanced to `.rest(restID(element: 2))`; `generation == 1` (one undo step).
  - **input with armed duration:** `setDuration(.eighth)` (arms; nothing selected → no mutation), select rest 1, `inputPitch(letter: "c")` → ONE composite undo step: element 1 is an eighth C4 chord, element 2 is the eighth remainder rest (the engine's `SetRestDuration` rebalance), and `vm.undo()` once restores `fourQuarterRests()` exactly.
  - **input on rest equal to armed duration:** armed `.quarter`, rest is `.quarter` → plain `InputNote` (assert `generation` bumps once and undo-once restores).
  - **letter on selected note (no chord arm):** `chordAtIndex1()`, select `.note(noteID(element: 1))`, `inputPitch(letter: "d")` → note pitch 62, tpc 16; selection advanced to element 2.
  - **delete whole chord:** `chordAtIndex1()`, select the note, chord has 1 note → `deleteSelection()` → element 1 `isRest`, duration `.quarter`; selection is `.rest(restID(element: 1))`.
  - **duration change on chord:** `chordAtIndex1()`, select note, `setDuration(.eighth)` → element 1 chord duration `.eighth`, element 2 is an added eighth rest, `armedDuration == .eighth`.
  - **duration change on rest:** `fourQuarterRests()`, select rest 1, `setDuration(.half)` → element 1 is a half rest and the voice still sums to a full measure (elements 2… consumed per the engine's lengthen algorithm); undo restores.
- [ ] Run Editor scheme → red; implement `EditorViewModel+Input.swift`. The composite path builds `CompositeEditCommand(commands: [SetRestDuration(at: veID, duration: armed), InputNote(at: restID, pitch: p, tpc: t)], location: veID)` — `SetRestDuration` keeps the target at the same `elementIndex`, so the `RestID` stays valid for the `InputNote` that follows. In-key letter targeting for the note-selected case reuses `StaffStepPitch.inKeyTpc` — until Task 6 lands, implement the small `inKeyTpc(naturalTpc:keySig:)` helper here (tpc ≡ naturalTpc mod 7, shifted into `13+keySig ... 19+keySig`) and let Task 6 move it into `StaffStepPitch`. Auto-advance: `if let next = ElementNavigator.nextTimedElement(after: affected, in: score) { select(SelectionRederivation.item(at: next, in: score, preferringNoteIndex: nil)) }`.
- [ ] Run → green. Commit: `feat(editor): note input, delete, and duration commands`

---

### Task 6: Pitch — semitone/octave keys, staff-step drag math, accidentals (TDD)

**Files**

- Create: `Packages/Features/Editor/Sources/Editor/StaffStepPitch.swift`
- Create: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Pitch.swift`
- Create: `Packages/Features/Editor/Tests/EditorTests/StaffStepPitchTests.swift`
- Create: `Packages/Features/Editor/Tests/EditorTests/EditorViewModelPitchTests.swift`

**Interfaces**

```swift
/// Diatonic (staff-line/space) pitch math for the notehead drag gesture. One staff step = one diatonic letter step.
/// The result is spelled IN KEY: the tpc for a letter under concert key K (−7…+7) is the unique value ≡ the letter's
/// natural tpc (mod 7) lying in 13+K ... 19+K (naturals occupy 13…19 at K = 0; each sharp shifts the window up by
/// one, each flat down by one).
enum StaffStepPitch {
    /// steps > 0 = up. nil when the result leaves MIDI 0…127.
    static func diatonicShift(from note: Note, bySteps steps: Int, keySig: Int) -> (pitch: Int, tpc: Int)?
    static func inKeyTpc(naturalTpc: Int, keySig: Int) -> Int
}

extension EditorViewModel {
    /// ▴/▾ keys: ±1 semitone via Note.shifted(bySemitones:in:) (MuseScore arrow-key spelling). No auto-advance.
    public func shiftPitch(bySemitones delta: Int)
    /// Long-press ▴/▾: ±1 octave, same tpc/accidental. No auto-advance.
    public func shiftOctave(by octaves: Int)
    /// Drag-commit from the Reader overlay (staff steps, positive = up). Applies SetNotePitch with the in-key
    /// spelling + displayedAccidental. No auto-advance (spec §11-5: off after drag).
    public func commitPitchDrag(steps: Int)
    /// ♭ ♮ ♯ (long-press 𝄫 𝄪) → SetAccidental. nil clears the glyph.
    public func setAccidental(_ accidental: Accidental?)
}
```

**Steps**

- [ ] `StaffStepPitchTests` (red): C major (K=0): C4(60,14)+1→D4(62,16); +2→E4(64,18); −1→B3(59,19); +7→C5(72,14). G major (K=1): E4(64,18)+1→F♯4(66,20). F major (K=−1): A4(69,17)+1→B♭4(70,12). Range: G9-ish overflow returns nil. `inKeyTpc`: (14, 0)→14; (13, 1)→20; (19, −1)→12.
- [ ] Implement `StaffStepPitch` (letter index from tpc via the table `[3,0,4,1,5,2,6][((tpc + 1) % 7 + 7) % 7]`, natural tpcs `[14,16,18,13,15,17,19]`, natural semitones `[0,2,4,5,7,9,11]`, octave carry on letter wrap); move the Task 5 `inKeyTpc` here. Run → green.
- [ ] `EditorViewModelPitchTests` (red): on `chordAtIndex1()` with the note selected —
  - `shiftPitch(bySemitones: 1)` → pitch 61, tpc `PitchSpelling.shiftedTpc(from: 60, priorTpc: 14, to: 61, in: 0)` (= 21, C♯), and the note's `accidental == .sharp` (Note.shifted refreshes it); selection unchanged (still element 1).
  - `shiftPitch` at MIDI edge: put pitch 127 first via a direct `applyCommand(SetNotePitch(at:..., pitch: 127, tpc: 19))`, then `shiftPitch(bySemitones: 1)` → no mutation (`generation` unchanged from before the call).
  - `shiftOctave(by: 1)` → pitch 72, tpc 14, accidental unchanged.
  - `commitPitchDrag(steps: 2)` → E4 (64, 18), accidental nil (in key), selection still element 1.
  - `setAccidental(.sharp)` → pitch 61, tpc 21 (respelled C♯), note.accidental == .sharp; `setAccidental(nil)` afterwards → pitch/tpc unchanged, accidental nil.
  - every op is a single undo step.
- [ ] Implement `EditorViewModel+Pitch.swift`: all four fetch the selected `.note(noteID)` (else no-op), read `keySig = editor.score.activeKey(at: noteID)`, build the appropriate `SetNotePitch`/`SetAccidental`, and go through `applyCommand`. `commitPitchDrag` sets `accidental: PitchSpelling.displayedAccidental(forTpc: newTpc, in: keySig)`. Run → green.
- [ ] Commit: `feat(editor): pitch keys, staff-step drag math, accidentals`

---

### Task 7: Chords, ties, tuplets, voices (TDD)

**Files**

- Create: `Packages/Features/Editor/Sources/Editor/IntervalPlanner.swift`
- Create: `Packages/Features/Editor/Sources/Editor/TiePlanner.swift`
- Create: `Packages/Features/Editor/Sources/Editor/EditorViewModel+ChordTieTuplet.swift`
- Create: `Packages/Features/Editor/Tests/EditorTests/IntervalPlannerTests.swift`
- Create: `Packages/Features/Editor/Tests/EditorTests/TiePlannerTests.swift`
- Create: `Packages/Features/Editor/Tests/EditorTests/EditorViewModelChordTests.swift`

**Interfaces**

```swift
public enum EditorInterval: Sendable { case third, octave }

/// Client-side pitch/tpc computation for the iPad interval shortcuts (spec §5.4): the engine has no interval command,
/// so the client computes the added note and issues AddNoteToChord.
enum IntervalPlanner {
    /// Diatonic third above, spelled in key (letter + 2, StaffStepPitch.inKeyTpc). nil past MIDI 127.
    static func diatonicThirdAbove(_ note: Note, keySig: Int) -> (pitch: Int, tpc: Int)?
    /// Perfect octave above, same tpc. nil past MIDI 127.
    static func octaveAbove(_ note: Note) -> (pitch: Int, tpc: Int)?
}

/// Finds the tie partner: the next chord (voice order, may cross the barline via ElementNavigator) containing a note
/// at the same pitch. Returns that note's NoteID, or nil (→ tie button dimmed, spec §5.4).
enum TiePlanner {
    static func tieTarget(for noteID: NoteID, in score: Score) -> NoteID?
}

extension EditorViewModel {
    /// ＋音: arms add-to-chord — the next pitch key / drag ADDS to the selected chord instead of replacing.
    public func toggleAddToChord()
    /// −音 → RemoveNoteFromChord on the selected notehead (last note leaves a rest, engine-canonical).
    public func removeSelectedNoteFromChord()
    /// iPad +3度 / +8度 → AddNoteToChord with IntervalPlanner's pitch.
    public func addIntervalNote(_ interval: EditorInterval)
    /// Whether the selected note has a same-pitch successor (drives the tie button's enabled state).
    public var canTie: Bool { get }
    /// Adds the tie when absent (SetTie ... sourceTieForward: 1, targetTieBack: 1), removes it when present
    /// (nil / nil) — read the selected note's `tieForward` to decide.
    public func toggleTie()
    public var isSelectionInTuplet: Bool { get }
    /// One-tap triplet = createTuplet(actualNotes: 3); long-press grid passes 5 / 6 / 7.
    /// normalNotes: 3→2, 5→4, 6→4, 7→4.
    public func createTuplet(actualNotes: Int)
    public func removeTuplet()
}
```

**Steps**

- [ ] `IntervalPlannerTests` (red): C4(60,14) K=0 → E4(64,18); E4(64,18) K=0 → G4(67,15); D4(62,16) K=2 → F♯4(66,20); A4(69,17) K=−1 → C5(72,14); octaveAbove C4 → (72,14); octaveAbove G♯8(pitch 116..≤115 ok) boundary → nil for pitch > 115. Implement via `StaffStepPitch.diatonicShift(from:bySteps: 2, keySig:)` (already spelled in key) and run → green.
- [ ] `TiePlannerTests` (red): build a score with two consecutive C4 quarter chords (mutate `fourQuarterRests()` elements 1 and 2) → target is `noteID(element: 2)`; consecutive C4-then-D4 → nil; C4 at measure end followed by C4 at the next measure's start (two-measure fixture) → the cross-barline NoteID. Implement using `ElementNavigator.nextTimedElement` + `chord.notes.firstIndex(where: { $0.pitch == source.pitch })`. Run → green.
- [ ] `EditorViewModelChordTests` (red):
  - **arm + add:** `chordAtIndex1()`, select note, `toggleAddToChord()` (→ `isAddToChordArmed`), `inputPitch(letter: "e")` → chord has notes [C4, E4], arming cleared, selection = the ADDED note (`noteIndexInChord: 1`), NO auto-advance in chord-arm mode.
  - **duplicate pitch add refused:** armed, `inputPitch(letter: "c")` (same pitch) → engine throws invalidEdit → swallowed, generation unchanged, arming cleared.
  - **remove:** two-note chord (C4+E4), select `.note(noteIndex: 1)`, `removeSelectedNoteFromChord()` → chord has 1 note; removing the last note → element `isRest`.
  - **interval:** select C4 note, `addIntervalNote(.third)` → notes [C4, E4]; `.octave` → C5 added.
  - **tie toggle:** two consecutive C4 chords; select first note → `canTie == true`; `toggleTie()` → source `tieForward == 1`, target `tieBack == 1`; `toggleTie()` again → both nil. C4-then-D4 → `canTie == false` and `toggleTie()` is a no-op.
  - **tuplet:** `chordAtIndex1()`, select note, `createTuplet(actualNotes: 3)` → voice has a `Tuplet(normalNotes: 2, actualNotes: 3, ...)` entry and elements 1–3 are the members (first carries C4); `isSelectionInTuplet == true`; `removeTuplet()` → back to a single quarter chord; undo/redo round-trips both.
- [ ] Implement `EditorViewModel+ChordTieTuplet.swift` (the chord-armed branch of `inputPitch` from Task 5 now routes here: `AddNoteToChord(at: VoiceElementID(noteID), pitch: p, tpc: t, accidental: PitchSpelling.displayedAccidental(forTpc: t, in: keySig))`). `isSelectionInTuplet`: check `score[staff]?.measures[m].voices[v].tuplets.contains { $0.startIndex <= e && e <= $0.endIndex }`. Run → green.
- [ ] Commit: `feat(editor): chord build, ties, tuplets`

---

### Task 8: Tap → selection hit-test mapping (TDD, real `LayoutDocument`)

`handleTap(at:)` maps a document-space point to a selection via `ScoreHitTester`, honoring: ~22 pt slop, rests as first-class targets, empty-staff tap = deselect, and active-voice preference in multi-voice measures.

**Files**

- Create: `Packages/Features/Editor/Sources/Editor/EditorViewModel+HitTest.swift`
- Create: `Packages/Features/Editor/Tests/EditorTests/Support/LayoutTestSupport.swift`
- Create: `Packages/Features/Editor/Tests/EditorTests/EditorViewModelHitTestTests.swift`

**Interfaces**

```swift
extension EditorViewModel {
    /// Tap in LayoutDocument coordinates (the Reader's score-surface space). Resolution:
    /// 1. `ScoreHitTester.hitTest(at:)` ladder (notehead → rest → beam → flag → stem → tuplet → clef).
    ///    .stem/.flag/.beam resolve to their first NoteID; .clef is ignored in v1 (no clef editing UI).
    /// 2. If the hit's voiceIndex ≠ activeVoice and `itemIDs(in:)` over a 44×44 slop rect contains an item of the
    ///    active voice, prefer the first such item (spec §5.5 — the picker targets a voice).
    /// 3. No hit → deselect (spec §5.2: tap empty staff = deselect).
    public func handleTap(at point: CGPoint)
}
```

- Consumes: `documentProvider()` (wired by App; the tests wire it to a locally-built document), `ScoreHitTester(document:)`, `itemID(at:)`, `hitTest(at:)`, `itemIDs(in:)` — exact signatures in the quick reference. Test support consumes `LayoutEngine.layout(score:options:availableWidth:)` (`SheetMusicLayout`) and `SheetMusicLayoutApple.install` (font metrics provider — REQUIRED before any layout in tests, per project memory `project_sheet_music_layout_install_in_tests`).

**Steps**

- [ ] `LayoutTestSupport.swift`:

```swift
import SheetMusicLayout
import SheetMusicLayoutApple
import SheetMusicUI

@MainActor
enum LayoutTestSupport {
    static func document(for score: Score, width: CGFloat = 800) -> LayoutDocument {
        _ = SheetMusicLayoutApple.install
        return LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(staffSize: 14, wrapToViewWidth: true),
            availableWidth: width,
        )
    }

    /// Document-space center of the notehead / rest for an item, found the same way ScoreHitTester scans elements —
    /// so tests can tap "exactly on" an item without hard-coding coordinates.
    static func anchorPoint(of item: SheetMusicCore.ScoreItemID, in document: LayoutDocument) -> CGPoint?
}
```

  `anchorPoint` iterates `document.systems` → `system.measures` → `measure.elements`, matching `.chord(notes, ...)` by `notes[i].noteID` and `.rest(_, origin, _, restID, _)` by `restID`, returning `system.origin + measure.origin + element origin` (mirror `ScoreHitTester.hitNote/hitRest` at `ScoreHitTester.swift:193-234`, including `n.mirrorDx(stem:sp:)` for noteheads).
- [ ] `EditorViewModelHitTestTests` (red) — `@MainActor` suite; each test builds the score, `vm.beginSession(score:)`, builds `let doc = LayoutTestSupport.document(for: score)`, wires `vm.documentProvider = { doc }`:
  - **tap a notehead selects it:** `chordAtIndex1()` → tap `anchorPoint(of: .note(noteID(element: 1)))` → `selectedItem == .note(...)`.
  - **tap a rest selects it:** `fourQuarterRests()` → tap the rest 2 anchor → `.rest(restID(element: 2))`.
  - **tap empty space deselects:** select something first, tap `CGPoint(x: anchor.x, y: anchor.y + 200)` (below the single system, outside every hit zone) → `selection == .none`.
  - **active-voice preference:** build a two-voice measure (voice 0: four quarter rests; voice 1: `Voice(elements: [.rest(duration: .measure)])` appended to the measure's `voices`), set `vm.activeVoice = 1`, tap near a voice-0 rest → the selected item's `voiceIndex == 1` when a voice-1 item is inside the 44×44 slop rect; with `activeVoice = 0` the same tap picks voice 0.
- [ ] Run → red; implement `EditorViewModel+HitTest.swift` per the interface (slop rect `CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)`). Run → green.
- [ ] Commit: `feat(editor): tap-to-select hit-test mapping`

---

### Task 9: Audition (TDD)

Sound the resulting pitch on note input and pitch change (spec §5.6), through the current soundfont, via the Task 2 API.

**Files**

- Create: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Audition.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift` (add the stored `@ObservationIgnored var auditionTask: Task<Void, Never>?` — extensions cannot add stored properties)
- Create: `Packages/Features/Editor/Tests/EditorTests/Support/FakePlaybackController.swift` (copy `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift` verbatim — it already implements both `playPreview` methods after Task 2; keep it `final class FakePlaybackController: PlaybackController` under `EditorTests`)
- Create: `Packages/Features/Editor/Tests/EditorTests/EditorViewModelAuditionTests.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Input.swift`, `+Pitch.swift`, `+ChordTieTuplet.swift` (call the audition hook)

**Interfaces**

```swift
extension EditorViewModel {
    /// Fire-and-forget preview of the note at `noteID` in the CURRENT edited score, 0.5 s, through the injected
    /// PlaybackController (nil-safe). Called after InputNote, SetNotePitch (keys + drag), SetAccidental,
    /// AddNoteToChord, and interval adds — NOT after delete / duration / tie / tuplet.
    func audition(_ noteID: NoteID)
}
```

  Implementation: `guard let playback, let score = self.score else { return }`; `Task { await playback.playPreview(noteID: noteID, in: score, duration: 0.5) }`. Call sites pass the freshly re-derived selection's NoteID (for `inputPitch` on a rest that is `SelectionRederivation.item(at: affectedLocation, ...)` BEFORE auto-advance — capture it before advancing).

**Steps**

- [ ] `EditorViewModelAuditionTests` (red): make the VM with `playback: fake` —
  - input on rest → `fake.recordedScorePreviewCalls.count == 1`, `noteID == EditorFixtures.noteID(element: 1)`, `duration == 0.5` (the test awaits: `try await Task.sleep(for: .milliseconds(50))` or better, make `audition` synchronous by calling the fake through an awaited Task — simplest deterministic form: have `audition` store `auditionTask: Task<Void, Never>?` and the test `await vm.auditionTask?.value`).
  - `shiftPitch(bySemitones: 1)` on a selected note → one more call, with the SAME NoteID (pitch changed in place).
  - `deleteSelection()` → no additional call.
  - `playback: nil` VM → all ops safe, no crash.
- [ ] Implement; run Editor scheme → green.
- [ ] Commit: `feat(editor): audition on input and pitch change`

---

### Task 10: Autosave + `ScoreItem` refresh + MusicXML sibling policy (TDD)

Spec §8: debounced autosave during editing; `.mscx`/`.mscz` save in place; `.musicxml`/`.mxl`/`.mid` sources save as a sibling `<id>.mscz` on first edit (silent, one-time note — the notice UI lands in Task 16); after each save refresh the `ScoreItem` row (`contentHash`, `sizeBytes`, and `localFileName` when the sibling copy is created). `lengthBeats` cannot change in v1 (no measure add/remove), so hash/size/filename are the complete refresh.

**Files**

- Create: `Packages/Features/Editor/Sources/Editor/EditorViewModel+Persistence.swift`
- Create: `Packages/Features/Editor/Sources/Editor/EditorFileFacts.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift` (`applyCommand`/`undo`/`redo` end with `scheduleAutosave()`; `endSession` awaits `flushPendingSave()`; the stored autosave state — `autosaveTask`, `isDirty`, `didSaveAsSiblingMSCZ` — lives HERE per the Task 3 comment, since extensions cannot add stored properties)
- Modify: `Packages/Domain/Sources/Domain/Models/ScoreItem.swift` (lines 19–21: doc comment only — "Never edited after import" becomes "Recomputed when note editing rewrites the file; rebuilt via the memberwise initializer because the field is immutable per instance")
- Create: `Packages/Features/Editor/Tests/EditorTests/EditorViewModelPersistenceTests.swift`

**Interfaces**

```swift
import CryptoKit

/// SHA-256 + size of a file on disk, matching the importer's hex-digest format
/// (Packages/Infrastructure/Sources/Persistence/LiveScoreFileImporter.swift:137-158).
enum EditorFileFacts {
    static func hashAndSize(of url: URL) throws -> (contentHash: String, sizeBytes: Int64)
}

extension EditorViewModel {
    /// Debounced 2 s after the last mutation; cancelled+rescheduled on each. Mirrors the Reader's annotation
    /// debounce pattern (ReaderViewModel+AnnotationPersistence.swift:17-34).
    func scheduleAutosave()
    /// Cancel the debounce and write now. Safe when nothing is pending. Called by endSession and (Task 15) on
    /// scene-background.
    public func flushPendingSave() async
    // `didSaveAsSiblingMSCZ` (true once a non-MSCX/MSCZ source has been rewritten as a sibling .mscz — drives the
    // Task 16 one-time notice) is the stored `public internal(set)` property declared on the class in Task 3.
    /// Save format + URL policy. Internal, pure, unit-tested:
    ///  - .mscx / .mscz  → same file, same format
    ///  - anything else  → (<localFileName stem>.mscz, .mscz)
    static func saveDestination(for item: ScoreItem, scoresDirectory: URL) -> (url: URL, format: ScoreFormat, isSiblingCopy: Bool)
}
```

  Save body (single choke point `performSave()`): `guard let score = self.score, isDirty else { return }` → compute destination → `try await gateway.saveScore(score, fileURL: dest.url, format: dest.format)` → `let facts = try EditorFileFacts.hashAndSize(of: dest.url)` → rebuild the item with the full memberwise init (`ScoreItem(id: scoreItem.id, title: scoreItem.title, ..., localFileName: dest.isSiblingCopy ? dest.url.lastPathComponent : scoreItem.localFileName, contentHash: facts.contentHash, sizeBytes: facts.sizeBytes, ...)`) → `try await repository.saveScoreItem(newItem)` → `scoreItem = newItem`; set `didSaveAsSiblingMSCZ` when `dest.isSiblingCopy`; track `isDirty` (set in `applyCommand`/`undo`/`redo`, cleared on successful save). Errors: `catch { /* keep isDirty true; retry on next debounce/flush */ }`.

**Steps**

- [ ] `EditorViewModelPersistenceTests` (red):
  - **destination policy (pure):** item `localFileName: "ABC.mscz"` → same URL `.mscz`, not sibling; `"ABC.mscx"` → `.mscx`; `"ABC.musicxml"` → `"ABC.mscz"` sibling `.mscz`; `"ABC.mid"` → sibling.
  - **hashAndSize:** write 5 known bytes to a temp file → `sizeBytes == 5` and `contentHash == <precomputed SHA-256 hex of those bytes>` (compute the expected constant with CryptoKit inline in the test).
  - **flush saves through the gateway and refreshes the row:** real temp dir as `scoresDirectory`, REAL `LiveScoreFileGateway`? No — Editor cannot import Infrastructure. Extend `FakeScoreFileGateway.saveScore` to actually `try Data("saved".utf8).write(to: fileURL)` in addition to recording, so hash/size are real. Then: begin session, apply one InputNote, `await vm.flushPendingSave()` → gateway recorded one call `(score, <dir>/score.mscz, .mscz)`; repository recorded one `saveScoreItem` whose `contentHash` == hash of "saved" bytes and whose `id == scoreItem.id`.
  - **sibling copy updates localFileName + flag:** item with `localFileName: "song.musicxml"` → after flush, saved item's `localFileName == "song.mscz"`, `didSaveAsSiblingMSCZ == true`.
  - **debounce coalesces:** apply three commands back-to-back, then `await vm.flushPendingSave()` → exactly ONE gateway save call.
  - **clean session saves nothing:** begin + `flushPendingSave()` with no edits → zero gateway calls.
- [ ] Implement; run Editor scheme → green.
- [ ] Update the `ScoreItem.contentHash` doc comment as described.
- [ ] Run Domain scheme (doc-only change, but the package must still build): `xcodebuild build -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` from `Packages/Domain`.
- [ ] Commit: `feat(editor): debounced autosave with ScoreItem refresh and mscz sibling policy`

---

### Task 11: Reader seam 1 — `ReaderEditingHost` + edit-mode lifecycle

Reader gains the injection seam (spec §9 Option 1): a public host object, entry/exit in the chrome, forced-vertical presentation, transport/top-overlay swap, annotation-ink dimming, and score adoption + engine reload on exit. Reader does NOT import Editor.

**Files**

- Create: `Packages/Features/Reader/Sources/Reader/ReaderEditingHost.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift` (init lines 99–143: two new parameters; body lines 145–267: chrome swap + exit observation; `content` lines 269–351: editing branch)
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift` (lines 76–91 `loadedActions`: add the edit button; new `onStartEditing` closure property)
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` (add `adoptEditedScore` near `advance`, after line 360)
- Modify: `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings` (one new key)
- Create: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelEditingTests.swift`

**Interfaces**

```swift
// ReaderEditingHost.swift
import Observation
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Injection seam for the note-editing feature (design spec §9, Option 1). The Reader owns edit-mode lifecycle and
/// score presentation; the App composition root connects this host to the Editor feature's view model. The Reader
/// never sees Editor types and vice versa.
@MainActor
@Observable
public final class ReaderEditingHost {
    public init() {}

    /// True while edit mode is active. Set by the Reader (entry button / exit).
    public internal(set) var isEditing = false

    // Written by the App (mirroring EditorViewModel outputs), read by the Reader:
    /// The editor's live score. While editing the Reader renders THIS raw score (no transpose / hidden staves /
    /// multi-measure-rest collapse) so positional IDs stay valid.
    public var editedScore: Score?
    /// Bumped per mutation; included in the vertical container's layout task key.
    public var editGeneration = 0
    public var selection: ScoreSelection = .none
    /// The caret target (insertion indicator drawn by the Reader's editing overlay).
    public var caretItem: SheetMusicCore.ScoreItemID?

    // Written by the Reader, read by the App/Editor:
    /// Latest LayoutDocument of the editing surface (published by VerticalScoreContainer).
    public internal(set) var document: LayoutDocument?
    /// Screen-space (global) frame of the current selection anchor, for positioning the iPhone callout.
    public internal(set) var selectionScreenFrame: CGRect?

    // App-wired callbacks:
    public var onBeginEditing: @MainActor (Score) -> Void = { _ in }
    public var onEndEditing: @MainActor () -> Void = {}
    public var onTap: @MainActor (CGPoint) -> Void = { _ in }
    /// Staff-step drag commit from the pitch-drag handle; positive steps = up.
    public var onPitchDragCommit: @MainActor (Int) -> Void = { _ in }

    /// The editing chrome's 完了 requests exit through here (the chrome is App-injected and cannot call Reader code).
    public private(set) var isExitRequested = false
    public func requestExit() { isExitRequested = true }
    func resetExitRequest() { isExitRequested = false }
}

/// Context handed to the App's chrome builder each body pass.
public struct ReaderEditingChromeContext {
    public let selectionScreenFrame: CGRect?
}

// ReaderRootScreen — new init parameters (defaults preserve every existing call site):
public init(
    scoreItem: ScoreItem,
    /* ...existing 15 parameters unchanged... */
    scoreContentOverride: AnyView? = nil,
    editingHost: ReaderEditingHost? = nil,
    editingChrome: ((ReaderEditingChromeContext) -> AnyView)? = nil,
)

// ReaderViewModel — internal:
/// Adopt the edited score as the loaded score and re-prepare the audio engine against it (the engine's sequencer
/// still holds the pre-edit score). Mirrors the advance(to:) reload sequence without swapping the item.
func adoptEditedScore(_ score: Score) async {
    loadState = .loaded(score)
    recomputeVisibleScore()
    await playbackSession.releaseEngine()
    await playbackSession.prepareForPlayback()
    pipSession.armIfReady()
}
```

**Steps**

- [ ] TDD the VM piece first — `ReaderViewModelEditingTests.swift` (model on `ReaderAdvanceTests`-style setup with `FakePlaybackController`, `FakeScoreLibraryRepository`, `FakeScoreFileGateway` from `Tests/ReaderTests/Fakes/`): load a score, then `await vm.adoptEditedScore(edited)` → `vm.loadState.score == edited`, `vm.visibleScore == edited` (transpose 0 default), `fake.releaseEngineCount == 1`, and a second engine `load` happened (`fake.loadCount == 2`). Run Reader scheme → red → implement `adoptEditedScore` → green.
- [ ] Create `ReaderEditingHost.swift` as specified.
- [ ] `ReaderTopOverlay.swift`: add `var onStartEditing: (() -> Void)? = nil` (nil hides the button, so previews and PDF readers are unaffected). In `loadedActions(score:)` insert, between `scoreActionButtons()` and `annotationToggleButton()`:

```swift
if let onStartEditing {
    overlayButton(
        systemImage: "square.and.pencil",
        label: Text("reader.toolbar.edit.start", bundle: .module),
        action: onStartEditing,
    )
    .glassEffect(.regular.interactive())
}
```

- [ ] Add the key to Reader's `Localizable.xcstrings` (mirror the JSON shape of `reader.toolbar.back`): `reader.toolbar.edit.start` = en "Edit notes" / ja "音符を編集" / ko "음표 편집" / zh-Hans "编辑音符" / zh-Hant "編輯音符".
- [ ] `ReaderRootScreen.swift` integration:
  - Store the two new init parameters.
  - `startEditing()` (private): `guard case let .loaded(score) = viewModel.loadState, let host = editingHost else { return }`; `Task { if viewModel.playbackSession.isPlaying { await viewModel.playbackSession.togglePlayback() }; viewModel.endAnnotationSessionIfNeeded(); host.editedScore = score; host.editGeneration += 1; host.isEditing = true; host.onBeginEditing(score) }`.
  - `finishEditing()` (private): `guard let host = editingHost else { return }`; `Task { host.onEndEditing(); if let edited = host.editedScore { await viewModel.adoptEditedScore(edited) }; host.isEditing = false; host.selection = .none; host.caretItem = nil; host.resetExitRequest() }`.
  - Body: pass `onStartEditing: editingHost == nil ? nil : { startEditing() }` to `ReaderTopOverlay`; hide `ReaderTopOverlay` and `ReaderTransportControl` while `editingHost?.isEditing == true` (same opacity-0 + `allowsHitTesting(false)` treatment the transport already uses for `isAnnotating`, `ReaderRootScreen.swift:177-182`); overlay the chrome inside the ZStack after the transport VStack:

```swift
if let host = editingHost, host.isEditing, let editingChrome {
    editingChrome(ReaderEditingChromeContext(selectionScreenFrame: host.selectionScreenFrame))
        .transition(.opacity)
}
```

  - Observe exit: `.onChange(of: editingHost?.isExitRequested ?? false) { _, requested in if requested { finishEditing() } }`.
  - `content`: before the `switch layoutMode`, branch the editing presentation (forced vertical, forced-raw inputs):

```swift
if let host = editingHost, host.isEditing, let editScore = host.editedScore {
    VerticalScoreContainer(
        score: editScore,
        staffSize: viewModel.layoutModel.staffSize,
        honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
        collapseMultiMeasureRests: false,          // collapsed runs break positional selection
        showInvisibleElements: showInvisibleElements,
        playbackCursor: nil,                       // no playback while editing
        scrollAnchorCursor: nil,
        autoFollowEnabled: false,
        transposeSemitones: 0,                     // written-pitch editing (spec §11-3)
        bottomControlClearance: bottomControlContentHeight,
        viewModel: viewModel,
        editingHost: host,                         // Task 12 parameter
    )
} else { /* existing switch unchanged */ }
```

  (Until Task 12 adds the `editingHost` parameter, pass everything else and leave a `// Task 12 wires editingHost` comment — or land Tasks 11+12 back-to-back before building; the per-task build gate below assumes the parameter exists as a no-op optional added HERE: add `var editingHost: ReaderEditingHost? = nil` to `VerticalScoreContainer` now, unused until Task 12.)
  - Dim annotation ink while editing (spec §5.9): in `VerticalScoreContainer.annotationSpec(viewport:)` the created `AnnotationOverlaySpec` gains `isInkDimmed: editingHost?.isEditing == true` — add the field to `AnnotationOverlaySpec` (`Screens/Vertical/AnnotationCanvasView.swift:26-35`, default `false`) and in `AnnotationCanvasController.update(spec:scroll:pinch:)` set `canvas.alpha = spec.isInkDimmed ? 0.4 : 1.0` and `canvas.isUserInteractionEnabled = !spec.isInkDimmed && spec.isAnnotating`.
- [ ] Build + test the Reader package (from `Packages/Features/Reader`): `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` — confirm `Compiling Reader` appears (false-SUCCEEDED guard).
- [ ] Commit: `feat(reader): editing seam host + edit-mode lifecycle`

---

### Task 12: Reader seam 2 — score-surface wiring (tap, selection, caret, rest tint, pitch drag)

Wire the vertical surface: route taps to the host while editing, render selection through `ScoreView(selection:voiceColors:)`, draw the caret / rest tint / drag handle in a new overlay, publish the `LayoutDocument`, and invalidate layout on `editGeneration`.

**Files**

- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalScoreContainer.swift` (props lines 29–52: the Task 11 `editingHost` param is used now; `.task(id:)` lines 105–113 + `TaskKey` lines 402–435: add `editGeneration`; `rebuildLayout` lines 304–315 and `eagerLayoutIfNeeded` lines 294–302: publish the document)
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalZoomedSurface.swift` (lines 8–23 props; `scoreSurface` lines 56–80; `tapSeekGesture` lines 82–89)
- Create: `Packages/Features/Reader/Sources/Reader/Views/EditingSelectionOverlay.swift`
- Create: `Packages/Features/Reader/Sources/Reader/Views/EditingSelectionOverlayPreviews.swift`

**Interfaces**

```swift
// VerticalScoreContainer additions
var editingHost: ReaderEditingHost? = nil          // added (unused) in Task 11
// TaskKey gains: let editGeneration: Int          // and its init parameter; include in the struct's Hashable identity
// .task(id: TaskKey(..., editGeneration: editingHost?.editGeneration ?? 0))
// rebuildLayout / eagerLayoutIfNeeded end with: editingHost?.document = newDoc   // internal(set) — same module

// VerticalZoomedSurface additions
let editingHost: ReaderEditingHost?                // passed through from the container
// ScoreView call gains:
//   selection: editingHost?.isEditing == true ? (editingHost?.selection ?? .none) : .none,
//   voiceColors: Self.editingVoiceColors,
// where: static let editingVoiceColors: [Int: Color] = [0: .accentColor, 1: .accentColor, 2: .accentColor, 3: .accentColor]
// (SelectionRenderState.color(for:voiceIndex:) tints ONLY selected items — non-selected rendering is unchanged.)
// tapSeekGesture branches:
//   if let host = editingHost, host.isEditing { host.onTap(value.location) }   // document coords == surface coords
//   else { existing setManualCursor path }
// scoreSurface ZStack gains, after the ScoreView:
//   if let host = editingHost, host.isEditing {
//       EditingSelectionOverlay(host: host, score: score, document: doc)
//   }

// EditingSelectionOverlay — all geometry in document coordinates (it lives inside the scaled surface, the same
// space the tap gesture reports in, so no zoom conversion is needed anywhere):
struct EditingSelectionOverlay: View {
    let host: ReaderEditingHost
    let score: Score
    let document: LayoutDocument
}
```

Overlay contents (concrete):

1. **Rest tint** (spec §5.2 "advertise tap to input here"): enumerate rests once per document via a private helper `static func restAnchors(in document: LayoutDocument) -> [(id: RestID, point: CGPoint, sp: CGFloat)]` (walk `document.systems`/`measures`/`elements`, matching `case let .rest(_, origin, _, restID, _)` exactly as `ScoreHitTester.hitRest` does at `ScoreHitTester.swift:216-234`). Render each as `Circle().fill(Color.accentColor.opacity(0.12)).frame(width: sp * 3.6, height: sp * 3.6).position(anchor)`.
2. **Caret** (spec §5.2): when `host.caretItem` maps to a frame — `document.cursorFrame(for: .item(caretItem), in: score)` gives the X column (its Y spans the whole system, `CursorFrame.swift:13`); narrow the Y band to the item's own staff via `staffBand(for: item.staff, measureIndex: item.measureIndex)` — find the `LayoutSystem` whose measures contain `measureIndex`, then `flatIndex = system.staffAddresses.firstIndex(of: staff)`, band = `system.origin.y + system.staffOrigins[flatIndex].y - sp` to `+ 4 * sp + sp` (staff height is 4 sp). Draw `RoundedRectangle(cornerRadius: 1).fill(Color.accentColor).frame(width: 2, height: band.height)` at `x = frame.minX - sp * 0.8`, plus a small downward-pointing triangle cap (Path) at the band top. Animate position with `.animation(.snappy(duration: 0.15), value: host.caretItem)`.
3. **Selection screen-frame publisher** (feeds the iPhone callout): attach to the caret view `.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { host.selectionScreenFrame = $0 }`; when `caretItem == nil` set it back to nil via `.onChange(of: host.caretItem)`.
4. **Pitch-drag handle** (spec §5.3 drag = the delight path): only when `host.selection` is `.single(.note(noteID))`. Position an invisible `Color.clear.contentShape(Circle()).frame(width: 44, height: 44)` at the notehead anchor — private helper `noteheadAnchor(of: NoteID) -> CGPoint?` matching `case let .chord(notes, _, stem, _, _, _, _, _, _, _, _)` and using `n.origin + n.mirrorDx(stem:sp:)` like `ScoreHitTester.hitNote` (`ScoreHitTester.swift:193-214`). Gesture:

```swift
@State private var dragSteps: Int?

.gesture(
    DragGesture(minimumDistance: 0, coordinateSpace: .named("scoreSurface"))
        .onChanged { value in
            // One staff step (line ↔ space) = sp / 2 in document coords; screen-up = pitch-up.
            dragSteps = Int((-value.translation.height / (sp / 2)).rounded())
        }
        .onEnded { value in
            let steps = Int((-value.translation.height / (sp / 2)).rounded())
            dragSteps = nil
            if steps != 0 { host.onPitchDragCommit(steps) }
        }
)
.sensoryFeedback(.selection, trigger: dragSteps)   // haptic tick per snapped step (spec §5.3)
```

5. **Ghost notehead** during drag: when `dragSteps != nil`, draw `Ellipse().stroke(Color.accentColor, lineWidth: 1.5).frame(width: sp * 2.4, height: sp * 1.8)` at `anchor.y - CGFloat(dragSteps!) * sp / 2` (snapped to the staff-step grid by construction).

**Steps**

- [ ] Apply the container/surface modifications (`editingHost` pass-through, `TaskKey.editGeneration`, document publish, tap branch, `selection:`/`voiceColors:` arguments, overlay mount).
- [ ] Implement `EditingSelectionOverlay.swift` per the five items above (single file; the two anchor helpers are `private static` funcs in the same file; cache `restAnchors` with a `private let` computed in `init` since `document` is immutable per view value).
- [ ] `EditingSelectionOverlayPreviews.swift` — a productive `#Preview` that needs no Reader plumbing:

```swift
#if DEBUG
import SheetMusicLayoutApple

#Preview("Editing overlay — caret on rest 2") {
    let score: Score = {
        var s = /* inline copy of EditorFixtures.fourQuarterRests() shape, with a C4 chord at element 1 */
        return s
    }()
    let _ = SheetMusicLayoutApple.install
    let doc = LayoutEngine.layout(
        score: score, options: ScoreViewOptions(staffSize: 14, wrapToViewWidth: true), availableWidth: 700,
    )
    let host = ReaderEditingHost()
    let _ = {
        host.isEditing = true
        host.selection = .single(.rest(RestID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 0, elementIndex: 2,
        )))
        host.caretItem = .rest(RestID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 0, elementIndex: 2,
        ))
    }()
    return ZStack(alignment: .topLeading) {
        ScoreView(document: doc, score: score, selection: host.selection,
                  voiceColors: [0: .accentColor, 1: .accentColor, 2: .accentColor, 3: .accentColor])
        EditingSelectionOverlay(host: host, score: score, document: doc)
    }
    .frame(width: 700)
    .padding()
}
#endif
```

  (`SheetMusicLayoutApple` is transitively available to Reader — it is already a declared product dependency in Reader's `Package.swift:38`.)
- [ ] Render the preview via `mcp__xcode__RenderPreview` on `EditingSelectionOverlayPreviews.swift` and `Read` the PNG: confirm (a) the selected rest is tinted accent, (b) a 2 pt caret bar sits left of rest 2 spanning one staff height, (c) every rest shows the faint tint disc. Iterate until correct.
- [ ] Run Reader tests (scheme `Reader`, same command as Task 11) — existing suites must stay green (the seam defaults keep non-editing behavior byte-identical).
- [ ] Commit: `feat(reader): editing surface wiring — tap routing, selection render, caret, pitch drag`

---

### Task 13: Editor chrome — bottom pad (iPhone two-row / iPad one-row)

Spec §5.8. One component set arranged by size class. The pad's total content height must stay ≤ 114 pt (`ReaderTransportControl.expandedContentHeight` — the Reader's bottom clearance while editing reuses that constant, Task 11 passed `bottomControlContentHeight` unchanged).

**Files**

- Create: `Packages/Features/Editor/Sources/Editor/Views/EditorPadView.swift`
- Create: `Packages/Features/Editor/Sources/Editor/Views/EditorPadButtons.swift` (shared button styles + glyph helpers)
- Modify: `Packages/Features/Editor/Sources/Editor/Resources/Localizable.xcstrings` (pad keys, table below)

**Interfaces**

```swift
/// Bottom editing pad. iPhone (compact width): two 44 pt rows — durations row + pitch/octave/delete row.
/// iPad (regular width): one 44 pt row with all keys. Liquid Glass card, floating over the score.
public struct EditorPadView: View {
    @Bindable private var viewModel: EditorViewModel
    public init(viewModel: EditorViewModel)
}
```

Concrete structure (implementer follows this shape; tune spacing against previews):

```swift
@Environment(\.horizontalSizeClass) private var horizontalSizeClass

private static let durations: [(NoteDuration, String, LocalizedStringKey)] = [
    (.whole, "𝅝", "editor.duration.whole"), (.half, "𝅗𝅥", "editor.duration.half"),
    (.quarter, "♩", "editor.duration.quarter"), (.eighth, "♪", "editor.duration.eighth"),
    (.sixteenth, "𝅘𝅥𝅯", "editor.duration.sixteenth"), (.thirtySecond, "𝅘𝅥𝅰", "editor.duration.thirtySecond"),
    (.sixtyFourth, "𝅘𝅥𝅱", "editor.duration.sixtyFourth"),
]
private static let pitchLetters: [Character] = ["C", "D", "E", "F", "G", "A", "B"]

var body: some View {
    Group {
        if horizontalSizeClass == .regular {
            HStack(spacing: 6) { durationKeys; Divider().frame(height: 28); pitchKeys; Divider().frame(height: 28); pitchStepKeys; deleteKey }
        } else {
            VStack(spacing: 6) {
                HStack(spacing: 4) { durationKeys }
                HStack(spacing: 4) { pitchKeys; pitchStepKeys; deleteKey }
            }
        }
    }
    .padding(10)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
    .padding(.horizontal)
}
```

- `durationKeys`: `ForEach` over `Self.durations` → `Button { viewModel.setDuration(d) } label: { Text(verbatim: glyph).font(.system(size: 22)) }` with a selected-state background capsule when `viewModel.armedDuration == d` (`Capsule().fill(Color.accentColor.opacity(0.25))`), `.accessibilityLabel(Text(key, bundle: .module))`, min tap target 40×44 via `.frame(minWidth: 40, minHeight: 44)`.
- `pitchKeys`: `ForEach` over letters → `Button { viewModel.inputPitch(letter: Character(c.lowercased())) } label: { Text(verbatim: String(c)).font(.system(size: 17, weight: .semibold, design: .rounded)) }` same frame.
- `pitchStepKeys`: two buttons — SF Symbols `chevron.up` / `chevron.down`, action `viewModel.shiftPitch(bySemitones: ±1)`, long-press (`.simultaneousGesture(LongPressGesture().onEnded { _ in viewModel.shiftOctave(by: ±1) })`) for ±octave (spec §5.3), labels `editor.pad.pitchUp`/`editor.pad.pitchDown`.
- `deleteKey`: SF Symbol `delete.backward`, action `viewModel.deleteSelection()`, label `editor.pad.delete`, `.tint(.primary)`.
- Note glyphs are Unicode musical symbols (U+1D15D…U+1D164 family) rendered by the system fallback font — acceptable v1 stand-ins for the spec's "crisp custom glyphs"; a custom SF Symbol pass is listed as a follow-up in the final checklist.

Localization keys added this task (values for en / ja / ko / zh-Hans / zh-Hant):

| key | en | ja | ko | zh-Hans | zh-Hant |
| --- | --- | --- | --- | --- | --- |
| editor.duration.whole | Whole note | 全音符 | 온음표 | 全音符 | 全音符 |
| editor.duration.half | Half note | 2分音符 | 2분음표 | 二分音符 | 二分音符 |
| editor.duration.quarter | Quarter note | 4分音符 | 4분음표 | 四分音符 | 四分音符 |
| editor.duration.eighth | Eighth note | 8分音符 | 8분음표 | 八分音符 | 八分音符 |
| editor.duration.sixteenth | 16th note | 16分音符 | 16분음표 | 十六分音符 | 十六分音符 |
| editor.duration.thirtySecond | 32nd note | 32分音符 | 32분음표 | 三十二分音符 | 三十二分音符 |
| editor.duration.sixtyFourth | 64th note | 64分音符 | 64분음표 | 六十四分音符 | 六十四分音符 |
| editor.pad.pitchUp | Raise pitch | 音を上げる | 음 높이기 | 升高音高 | 升高音高 |
| editor.pad.pitchDown | Lower pitch | 音を下げる | 음 내리기 | 降低音高 | 降低音高 |
| editor.pad.delete | Delete | 削除 | 삭제 | 删除 | 刪除 |

**Steps**

- [ ] Implement `EditorPadButtons.swift` (a `PadKeyStyle: ButtonStyle` giving the pressed-state scale + the armed capsule) and `EditorPadView.swift` per the structure above; add the xcstrings entries.
- [ ] Add two `#Preview`s in `EditorPadView.swift`: "pad · compact" (wrap in `.environment(\.horizontalSizeClass, .compact)`, frame width 390) and "pad · regular" (width 900), each with a `EditorViewModel` built from the Task 3 test-style fakes — previews live in the source target, so add a tiny `#if DEBUG` `PreviewEditorFactory.makeViewModel()` in `EditorPadView.swift` that constructs the VM with `NoopScoreFileGateway`/`NoopRepository` defined inline under `#if DEBUG` (Feature-test fakes are not visible to the source target).
- [ ] Render both previews via `mcp__xcode__RenderPreview` + `Read` the PNGs: two rows on compact / one row on regular, glass card visible, armed duration capsule shows after tapping is not verifiable statically — check visual states by setting `viewModel.setDuration(.eighth)` in the preview factory before returning.
- [ ] Editor package still tests green (scheme `Editor`).
- [ ] Commit: `feat(editor): bottom editing pad`

---

### Task 14: Editor chrome — callout / palette, voice picker, top cluster, readout

Spec §5.4/§5.5/§5.7/§5.8: contextual ops in a floating callout (iPhone) anchored beside the selection, a persistent right-edge palette (iPad) with the live selection readout and interval shortcuts, the voice picker, and the top-right undo/redo/完了 cluster. This task also assembles the full-screen chrome root the App will inject.

**Files**

- Create: `Packages/Features/Editor/Sources/Editor/Screens/EditorChromeView.swift`
- Create: `Packages/Features/Editor/Sources/Editor/Views/EditorContextOps.swift` (the shared op buttons: accidentals / chord / tie / tuplet — used by both callout and palette)
- Create: `Packages/Features/Editor/Sources/Editor/Views/EditorCalloutView.swift`
- Create: `Packages/Features/Editor/Sources/Editor/Views/EditorPaletteView.swift`
- Create: `Packages/Features/Editor/Sources/Editor/Views/EditorVoicePicker.swift`
- Create: `Packages/Features/Editor/Sources/Editor/NoteNameFormatter.swift`
- Create: `Packages/Features/Editor/Tests/EditorTests/NoteNameFormatterTests.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/Resources/Localizable.xcstrings`

**Interfaces**

```swift
/// Full-screen editing chrome. Injected into the Reader seam by the App. Layout:
///  - top-right: undo / redo / 完了 glass cluster (mirrors ReaderTopOverlay's 44 pt buttons + 12 pt spacing)
///  - bottom: EditorPadView
///  - compact width: EditorCalloutView floating near `selectionAnchor` (global-space rect from the seam context)
///  - regular width: EditorPaletteView docked to the trailing edge, vertically centered
public struct EditorChromeView: View {
    public init(viewModel: EditorViewModel, selectionAnchor: CGRect?, onDone: @escaping () -> Void)
}

/// "E♭4 · 4分音符 · m.12 · 声部 1" (spec §5.8). Letter from tpc (line-of-fifths math shared with StaffStepPitch),
/// accidental glyph from alteration, octave from MIDI pitch (octave 4 contains middle C).
enum NoteNameFormatter {
    static func name(pitch: Int, tpc: Int) -> String            // "E♭4"
    static func readout(for item: SheetMusicCore.ScoreItemID, in score: Score) -> String
}

struct EditorVoicePicker: View {   // segmented 1…4 bound to viewModel.activeVoice (spec §5.5)
    @Bindable var viewModel: EditorViewModel
}
```

Concrete content decisions:

- **EditorContextOps** exposes one row/column of buttons built from the VM: ♭ ♮ ♯ (`viewModel.setAccidental(.flat/.natural/.sharp)`; long-press on ♭/♯ → 𝄫/𝄪 via `LongPressGesture` like the octave keys), ＋音 (`toggleAddToChord()`, shows armed state with the accent capsule), −音 (`removeSelectedNoteFromChord()`), tie (`toggleTie()`, `.disabled(!viewModel.canTie)`, SF Symbol `point.topleft.down.curvedto.point.bottomright.up` — verify glyph reads as a tie in preview, else `link`), tuplet (tap → `viewModel.isSelectionInTuplet ? removeTuplet() : createTuplet(actualNotes: 3)`; long-press menu via `Menu` with primaryAction — offering 5/6/7 → `createTuplet(actualNotes:)`). Accidental glyphs are text: "♭" "♮" "♯" "𝄫" "𝄪".
- **EditorCalloutView** (compact): a horizontal glass capsule of `EditorContextOps` + a trailing `⋯` `Menu` containing `EditorVoicePicker` (`Picker` with `.pickerStyle(.segmented)` inside the menu falls back to inline rows; that is fine). Positioned by `EditorChromeView` with a `GeometryReader`: convert the global `selectionAnchor` into local space (`anchor.midY - proxy.frame(in: .global).minY`), clamp so the callout stays ≥ 8 pt inside the safe area and above the pad; hide entirely when `viewModel.selectedItem == nil` or the anchor is nil.
- **EditorPaletteView** (regular): a vertical glass card, trailing-docked: selection readout (`Text(verbatim: NoteNameFormatter.readout(...))`, `.font(.footnote.monospacedDigit())`, "editor.palette.noSelection" fallback), `EditorContextOps` in a 3-column `LazyVGrid`, `+3度` / `+8度` buttons (`viewModel.addIntervalNote(.third/.octave)`, labels `editor.palette.addThird`/`editor.palette.addOctave`), and `EditorVoicePicker` (segmented, inline).
- **Top cluster** in `EditorChromeView`: `arrow.uturn.backward` (`viewModel.undo()`, `.disabled(!viewModel.canUndo)`), `arrow.uturn.forward` (redo, mirrored), and a `完了` text button (`Text("editor.chrome.done", bundle: .module)`, `.fontWeight(.semibold)`) calling `onDone` — one `HStack(spacing: 0)` inside `.glassEffect(.regular.interactive())`, aligned `.topTrailing` with the same `.padding(.horizontal).padding(.top, 4)` as `ReaderTopOverlay.swift:67-69`.

Localization keys added this task:

| key | en | ja | ko | zh-Hans | zh-Hant |
| --- | --- | --- | --- | --- | --- |
| editor.chrome.done | Done | 完了 | 완료 | 完成 | 完成 |
| editor.chrome.undo | Undo | 取り消す | 실행 취소 | 撤销 | 撤銷 |
| editor.chrome.redo | Redo | やり直す | 다시 실행 | 重做 | 重做 |
| editor.ops.addToChord | Add chord note | 和音に音を追加 | 화음에 음 추가 | 添加和弦音 | 加入和弦音 |
| editor.ops.removeFromChord | Remove chord note | 和音から音を削除 | 화음에서 음 제거 | 移除和弦音 | 移除和弦音 |
| editor.ops.tie | Tie | タイ | 붙임줄 | 延音线 | 連結線 |
| editor.ops.tuplet | Tuplet | 連符 | 잇단음표 | 连音 | 連音 |
| editor.ops.accidentalFlat | Flat | フラット | 플랫 | 降号 | 降記號 |
| editor.ops.accidentalNatural | Natural | ナチュラル | 제자리표 | 还原号 | 還原記號 |
| editor.ops.accidentalSharp | Sharp | シャープ | 샤프 | 升号 | 升記號 |
| editor.palette.addThird | +3rd | +3度 | +3도 | +三度 | +三度 |
| editor.palette.addOctave | +8ve | +8度 | +8도 | +八度 | +八度 |
| editor.palette.noSelection | Tap a note or rest | 音符か休符をタップ | 음표나 쉼표를 탭 | 点按音符或休止符 | 點按音符或休止符 |
| editor.voice.label | Voice | 声部 | 성부 | 声部 | 聲部 |
| editor.voice.n | Voice %lld | 声部 %lld | 성부 %lld | 声部 %lld | 聲部 %lld |
| editor.notice.savedAsMscz | Edits are saved as a MuseScore (.mscz) copy next to the original file. | 編集内容は元のファイルの隣に MuseScore (.mscz) 形式のコピーとして保存されます。 | 편집 내용은 원본 파일 옆에 MuseScore(.mscz) 사본으로 저장됩니다. | 编辑内容将保存为原文件旁的 MuseScore (.mscz) 副本。 | 編輯內容將儲存為原始檔案旁的 MuseScore (.mscz) 副本。 |
| editor.readout.measure | m.%lld | %lld小節 | %lld마디 | 第%lld小节 | 第%lld小節 |

(readout format: `"\(noteName) · \(durationName) · \(measureLabel) · \(voiceLabel)"` — duration names reuse the Task 13 `editor.duration.*` keys via `String(localized:bundle:)`; measure label uses `editor.readout.measure` with `measureIndex + 1`; voice via `editor.voice.n` with `voiceIndex + 1`.)

**Steps**

- [ ] TDD `NoteNameFormatter` first: (60,14)→"C4"; (61,21)→"C♯4"; (61,9)→"D♭4"; (70,12)→"B♭4"; (72,14)→"C5"; readout on `chordAtIndex1()` note → "C4 · 4分音符…" — assert with `String(localized:)` lookups rather than hard-coded Japanese so the test is locale-independent: assert the string CONTAINS "C4" and the localized duration name. Run → red → implement → green.
- [ ] Implement the five views per the Interfaces block; add the xcstrings entries.
- [ ] `#Preview`s: "chrome · compact / rest selected" (390×844, anchor rect at (120, 300, 20, 20)), "chrome · regular / note selected" (1180×820). Use the Task 13 preview factory; pre-seed a session + selection so the callout/palette/readout are populated.
- [ ] `mcp__xcode__RenderPreview` + `Read` each PNG: callout floats beside the anchor with all ops; palette docks trailing with readout + intervals + voice picker; top cluster shows undo/redo/完了; nothing overlaps the pad.
- [ ] Editor scheme tests still green.
- [ ] Commit: `feat(editor): callout, palette, voice picker, and chrome root`

---

### Task 15: App composition — `EditableReaderScreen` + `project.yml`

Wire host ↔ view model at the composition root (the ONLY place Editor and Reader meet), per spec §9.

**Files**

- Modify: `project.yml` (Folino target dependencies, lines 123–140: add the `SheetMusicUI` product; the Editor package is already a dependency at line 131)
- Create: `App/EditableReaderScreen.swift`
- Modify: `App/AppShellView.swift` (lines 377–404 `makeReader` returns the new wrapper)

**Interfaces**

```swift
// project.yml — under the Folino target's dependencies, after the existing swift-sheet-music entry (line 135-136):
//   - package: swift-sheet-music
//     product: SheetMusicUI
// (FolinoScreenshot already lists SheetMusicUI/SheetMusicLayout at lines 246-249 — no change needed there. The main
//  target needs SheetMusicUI so App source can import it; SheetMusicLayout stays transitively importable, the same
//  precedent Reader itself relies on.)

// App/EditableReaderScreen.swift
import Domain
import Editor
import Reader
import SheetMusicUI
import SwiftUI

/// Composition-root wrapper that mounts a ReaderRootScreen with the note-editing seam filled in: one
/// ReaderEditingHost + one EditorViewModel per Reader instance, wired by closure so Reader and Editor stay
/// mutually unaware (module-architecture Option 1).
struct EditableReaderScreen: View {
    @State private var editingHost = ReaderEditingHost()
    @State private var editorViewModel: EditorViewModel
    @State private var isWired = false
    private let readerBuilder: (ReaderEditingHost, @escaping (ReaderEditingChromeContext) -> AnyView) -> ReaderRootScreen

    init(
        item: ScoreItem,
        scoresDirectory: URL,
        gateway: any ScoreFileGateway,
        repository: any ScoreLibraryRepository,
        playbackController: (any PlaybackController)?,
        readerBuilder: @escaping (ReaderEditingHost, @escaping (ReaderEditingChromeContext) -> AnyView) -> ReaderRootScreen,
    ) {
        _editorViewModel = State(wrappedValue: EditorViewModel(
            scoreItem: item,
            scoresDirectory: scoresDirectory,
            gateway: gateway,
            repository: repository,
            playback: playbackController,
        ))
        self.readerBuilder = readerBuilder
    }

    var body: some View {
        readerBuilder(editingHost) { context in
            AnyView(EditorChromeView(
                viewModel: editorViewModel,
                selectionAnchor: context.selectionScreenFrame,
                onDone: { [editingHost] in editingHost.requestExit() },
            ))
        }
        .onAppear { wireOnce() }
    }

    private func wireOnce() {
        guard !isWired else { return }
        isWired = true
        let host = editingHost
        let vm = editorViewModel
        host.onBeginEditing = { score in vm.beginSession(score: score) }
        host.onEndEditing = { Task { await vm.endSession() } }
        host.onTap = { point in vm.handleTap(at: point) }
        host.onPitchDragCommit = { steps in vm.commitPitchDrag(steps: steps) }
        vm.documentProvider = { host.document }
        vm.onScoreChanged = { score in
            host.editedScore = score
            host.editGeneration += 1
        }
        vm.onSelectionChanged = { selection, item in
            host.selection = selection
            host.caretItem = item
        }
    }
}
```

`AppShellView.makeReader` change: keep its exact signature and internals, but return the wrapper — construct `ReaderRootScreen` inside the `readerBuilder` closure with the two new arguments appended (`editingHost: host, editingChrome: chrome`) and every existing argument unchanged; then:

```swift
private func makeReader(
    item: ScoreItem, playlistID: PlaylistID?,
    onBack: (() -> Void)? = nil, hidesBackButton: Bool = false, leadingIsSidebarToggle: Bool = false,
) -> some View {
    EditableReaderScreen(
        item: item,
        scoresDirectory: scoresDirectory,
        gateway: gateway,
        repository: repository,
        playbackController: bootstrap.playbackController,
    ) { host, chrome in
        ReaderRootScreen(
            scoreItem: item, repository: repository, gateway: gateway, shareService: shareService,
            metadataReader: metadataReader, annotationStore: annotationStore, scoresDirectory: scoresDirectory,
            playbackController: bootstrap.playbackController, pdfPlaybackParser: bootstrap.pdfPlaybackParser,
            museScoreGeneralProvider: bootstrap.museScoreGeneralProvider, playlistID: playlistID,
            analytics: bootstrap.analytics ?? NoopAnalytics(),
            openedFrom: playlistID != nil ? .playlist : .libraryAll,
            onBack: onBack, hidesBackButton: hidesBackButton, leadingIsSidebarToggle: leadingIsSidebarToggle,
            editingHost: host, editingChrome: chrome,
        )
    }
}
```

(The `.id(item.id)` at the split-view call site — `AppShellView.swift:421` — already forces fresh `@State` per score, which now also rebuilds host + editor VM. PDFs never show the edit button because `ReaderTopOverlay` only adds it on the `.loaded` path.)

**Steps**

- [ ] Edit `project.yml` (add the `SheetMusicUI` product to the Folino target) and run `xcodegen generate` from the repo root.
- [ ] Create `App/EditableReaderScreen.swift`; rewrite `makeReader` as above.
- [ ] Background-flush hook: in `EditableReaderScreen`, add `@Environment(\.scenePhase)` and `.onChange(of: scenePhase) { _, phase in if phase != .active { Task { await editorViewModel.flushPendingSave() } } }` — autosave survives app backgrounding mid-edit (spec §8).
- [ ] Full app build from repo root: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build` → BUILD SUCCEEDED.
- [ ] Per-package verification (false-SUCCEEDED guard): run the `Editor` and `Reader` scheme test commands once more from their package dirs.
- [ ] Commit: `feat(app): compose note editing into the Reader seam`

---

### Task 16: Polish — loupe, Pencil hover, system undo gestures, one-time notice

The remaining spec §5.2/§5.7/§11-2 items, each small and concrete.

**Files**

- Create: `Packages/Features/Reader/Sources/Reader/Views/EditingLoupeView.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Views/EditingSelectionOverlay.swift` (mount loupe + hover)
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderEditingHost.swift` (hover item passthrough)
- Modify: `Packages/Features/Editor/Sources/Editor/Screens/EditorChromeView.swift` (undoManager bridge + one-time notice)
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift` (system-undo registration helpers)

**Interfaces & concrete work**

1. **Long-press loupe (spec §5.2):** `EditingLoupeView` renders the already-computed document magnified — `ScoreView(document: document, score: score)` inside a 120×120 `Circle()` clip with `.scaleEffect(2)` and `.offset(x: 60 - point.x * 2, y: 60 - point.y * 2)` so the pressed point sits centered at 2×, with a glass rim (`.glassEffect(.regular, in: Circle())`) hovering 80 pt above the finger. Mount in `EditingSelectionOverlay` behind a `SequenceGesture(LongPressGesture(minimumDuration: 0.4), DragGesture(minimumDistance: 0, coordinateSpace: .named("scoreSurface")))` attached to the overlay's background `Color.clear.contentShape(Rectangle())` — while active track the finger point in `@State`, on end call `host.onTap(finalPoint)` (selection then resolves through the normal Task 8 slop path; the magnified view makes the target visible, the hit-test slop does the disambiguation). [verify: the overlay background gesture must not swallow the plain taps handled by `VerticalZoomedSurface.tapSeekGesture` — if it does, attach the sequence gesture with `.simultaneousGesture` instead.]
2. **Pencil hover pre-highlight (spec §5.2):** on the same overlay background add `.onContinuousHover(coordinateSpace: .named("scoreSurface")) { phase in ... }` → `host.onHover?(point / nil)`. Add `public var onHover: (@MainActor (CGPoint?) -> Void)? = nil` to `ReaderEditingHost` and `public var hoverItem: SheetMusicCore.ScoreItemID?` (plain `public var` — the App writes it, like `selection`/`caretItem`); App wires `host.onHover = { p in host.hoverItem = p.flatMap { vm.hoverItem(at: $0) } }` where `EditorViewModel.hoverItem(at:)` is `handleTap`'s resolution WITHOUT mutating selection (extract the shared private resolver in Task 8's file). Render: overlay draws a soft `Circle().fill(Color.accentColor.opacity(0.18))` (diameter 2.4 sp) at the hover item's anchor.
3. **System three-finger undo/redo (spec §5.7):** in `EditorChromeView` add `@Environment(\.undoManager) private var undoManager` and `.onChange(of: viewModel.generation) { _, _ in viewModel.registerSystemUndo(with: undoManager) }`. On `EditorViewModel`:

```swift
/// Bridges ScoreEditor's own stacks to the system UndoManager so three-finger swipe gestures work. Each mutation
/// registers one undo action; performing it re-registers the redo symmetrically. The ScoreEditor remains the
/// source of truth — the UndoManager holds only trampolines.
func registerSystemUndo(with manager: UndoManager?) {
    guard let manager else { return }
    manager.registerUndo(withTarget: self) { vm in
        vm.undo()
        manager.registerUndo(withTarget: vm) { vm2 in
            vm2.redo()
            vm2.registerSystemUndo(with: manager)
        }
    }
}
```

   Also call `undoManager?.removeAllActions(withTarget: viewModel)` from `EditorChromeView.onDisappear` so stale trampolines never outlive the session. [verify: three-finger swipe on device triggers the registered action inside the glass overlay hierarchy — if the gesture doesn't reach it, note the limitation in the PR and keep the on-screen buttons as the primary path.]
4. **One-time sibling-mscz notice (spec §11-2):** in `EditorChromeView`, `.onChange(of: viewModel.didSaveAsSiblingMSCZ) { _, saved in if saved { showsSiblingNotice = true } }` + a top-center glass banner `Text("editor.notice.savedAsMscz", bundle: .module)` auto-dismissing after 4 s (same pattern as `DrainBannerView` — `.task { try? await Task.sleep(for: .seconds(4)); showsSiblingNotice = false }`). Gate "one-time per install" with `@AppStorage("editorSiblingMSCZNoticeShown")`.

**Steps**

- [ ] Implement items 1–4.
- [ ] Add a `#Preview` for `EditingLoupeView` (reuse the Task 12 preview harness, loupe centered on the chord) → `RenderPreview` + `Read`: 2× magnification centered on the pressed point, glass rim visible.
- [ ] Run Reader + Editor package test schemes; full app build (all three commands as in Task 15).
- [ ] Commit: `feat(editing): loupe, hover pre-highlight, system undo bridge, sibling-save notice`

---

### Task 17: Final gate — full test sweep + manual device checklist

**Files** — none created; this is the verification task.

**Steps**

- [ ] From `Packages/Features/Editor`: `xcodebuild test -scheme Editor -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` → all green.
- [ ] From `Packages/Features/Reader`: `xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` → all green (pre-existing suites unaffected).
- [ ] From `Packages/Infrastructure`: `xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:InfrastructureTests/LiveScoreFileGatewayTests` → green.
- [ ] From `Packages/Domain`: `xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` → green.
- [ ] From repo root: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build` → BUILD SUCCEEDED.
- [ ] Confirm the working tree has no stray files (`git status`), every task landed as its own commit, and nothing was pushed.
- [ ] Report completion to the user with the manual checklist below (per project memory `feedback_no_simulator_launch`, do NOT launch the simulator — device verification is the user's).

---

## Manual verification checklist (device-only — hand to the user)

Gesture feel and audio cannot be judged in previews or the simulator. On a physical iPhone AND iPad:

1. **Entry/exit:** open an `.mscz` score → pencil-square button in the top overlay enters edit mode (playback pauses, transport fades, ink dims to ~40 % and ignores touches); 完了 returns to reading with the previous layout mode restored and the edits visible.
2. **Pitch-drag feel (spec risk §13):** select a note, drag the notehead vertically — ghost notehead snaps line/space with a haptic tick per step; release commits; the drag must reliably win over scroll-pan when starting on the selected notehead (if the scroll steals it, that's the `[verify]` in Task 12/16 — report back).
3. **Audition:** each note input and pitch change sounds the new pitch through the current soundfont at a comfortable volume; no audition during an active playback session.
4. **Autosave:** make edits, background the app (or wait > 2 s), force-quit, reopen → edits persisted. Edit a `.musicxml` score → one-time "saved as .mscz copy" banner; the library row now opens the `.mscz`.
5. **Undo:** on-screen undo/redo; three-finger swipe left/right while editing.
6. **iPhone vs iPad presentation:** iPhone shows the two-row pad + floating callout near the selection; iPad shows the one-row pad + right-edge palette with live readout ("C4 · 4分音符 · 1小節 · 声部 1") and +3度/+8度.
7. **Selection visuals:** selected note/rest tinted with the Reader's accent highlight; caret bar beside it; rests visibly tinted as input slots; long-press loupe magnifies dense chords; Pencil hover pre-highlights (iPad).
8. **Voices:** on a two-voice score, the voice picker switches the tap-preference and input voice; the other voice still renders.
9. **Safety rails:** tuplet member duration keys refuse politely (nothing happens, score intact); PDF scores show no edit button; transpose is inactive during editing and restores after 完了.

Known v1 follow-ups (not bugs): custom SF Symbol glyphs for the duration keys; marquee/range delete (spec §11-4 deferred); measure add/remove + beaming (needs upstream engine work, spec §10); Android parity (edit logic already isolated in shared-liftable Swift per the parity rule).

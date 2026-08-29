# SP0 — Edit-Intent Determinism Spike (swift-sheet-music) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove — on a real Android device — that a `Score` can be kept in sync across the JNI boundary by relaying scalar edit *intents* rather than serialized commands, and land the primitives that make it possible.

**Architecture:** A new `ScoreEditSession` in `SheetMusicCore` wraps `ScoreEditor` and applies an `EditIntent` value. `EditIntent` is a small scalar sum type with a `@WireFormatChoice` projection, so Kotlin can carry one across JNI as bytes. `Score.stableFingerprint` gives both sides a cheap way to assert they agree. Seven JNI entry points expose the session behind an existing score handle. Nothing in Folino changes in this sub-plan.

**Tech Stack:** Swift 6.3, swift-sheet-music (`SheetMusicCore`, `SheetMusicAndroidJNI`), swift-wirelet `@WireFormat*` macros, swift-java jextract, Kotlin/Gradle (`Android/SheetMusicAndroid`), Swift Testing, AndroidJUnit4.

## Global Constraints

- **All work happens in the ssm worktree** `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing` (branch `android-note-editing`, off `origin/main` `75befe54` = ssm 1.8.0). Never in the primary ssm checkout. Use absolute paths or `git -C <worktree>`.
- **No Folino changes in SP0.** Folino re-pins in SP2.
- Host builds and tests use `xcrun swift …`. Android cross-compilation and on-device tests use the release toolchain, which the repo's own scripts already prepend: `/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin`.
- Swift Testing (`import Testing`, `@Test`, `#expect`) for new Swift tests. `--filter` matches the **type** name, not the `@Suite` display name.
- No randomness and no clock reads anywhere in the replay tests — a determinism test that is itself nondeterministic proves nothing.
- The wire discriminator order in `EditIntentWire` is **append-only**. SP1 adds the remaining intents; it must not renumber existing cases.
- Comment paragraphs reflow at 120 columns (repo convention), American spelling except where an Apple/framework API name dictates otherwise.

## Scope note

SP0 lands a *vertical slice* of the intent vocabulary — note input, duration
change, delete, and composite. The remaining intents (pitch, accidental, chord,
tie, tuplet) and the accidental-renotation pass that `ScoreEditSession.apply`
will eventually bundle onto every edit arrive in SP1, when the seven planners
move from Folino into `SheetMusicCore`. The *interfaces* built here are final;
SP1 adds cases and re-generates the golden fingerprints in Task 10.

## File structure

| File | Responsibility |
| --- | --- |
| `Sources/SheetMusicCore/Editing/ScoreEditor.swift` (modify) | Drop `@MainActor` so a session can run on a JNI thread. |
| `Sources/SheetMusicCore/Editing/EditIntent.swift` (create) | The scalar intent vocabulary. |
| `Sources/SheetMusicCore/Editing/ScoreEditSession.swift` (create) | Intent → command planning, apply/undo/redo, `lastAffectedLocation`. |
| `Sources/SheetMusicCore/Score/ScoreFingerprint.swift` (create) | `Score.stableFingerprint` — deterministic FNV-1a over what editing can change. |
| `Sources/SheetMusicCore/SheetMusicEngine.swift` (create) | `SheetMusicEngine.versionStamp` — the build-identity gate. |
| `Sources/SheetMusicAndroidJNI/Editing/EditIntentCodec.swift` (create) | `@WireFormatChoice EditIntentWire` + `EditIntentCodec`. |
| `Sources/SheetMusicAndroidJNI/Editing/EditSessionBridge.swift` (create) | The seven JNI entry points. |
| `Android/SheetMusicAndroid/src/main/kotlin/.../SheetMusicJNI.kt` (modify) | Kotlin facade for the new entry points. |
| `Android/SheetMusicAndroid/src/androidTest/kotlin/.../EditSessionReplayTest.kt` (create) | Device-side JNI replay against committed goldens. |
| `Android/SheetMusicAndroid/build.gradle.kts` (modify) | Enable instrumented tests for this module. |
| `Tests/SheetMusicTests/EditingTests/…` (create) | Host tests for each of the above. |

---

### Task 1: De-isolate `ScoreEditor`

`ScoreEditor` is `@MainActor` today. In a Swift-on-Android JNI process nothing
pumps a main runloop, so a `@MainActor` hop never resumes — a JNI entry point
must be able to drive the editor synchronously on whatever thread Kotlin calls
from. The class stays a `final class` (the reason the annotation cites for
class-ness — a stable reference for `UndoManager` — is unaffected).

**Files:**
- Modify: `Sources/SheetMusicCore/Editing/ScoreEditor.swift:11-13`
- Test: `Tests/SheetMusicTests/EditingTests/ScoreEditorOffMainActorTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `ScoreEditor` usable from a nonisolated synchronous context. Its API is otherwise unchanged: `init(score:)`, `score`, `canUndo`, `canRedo`, `lastAffectedLocation`, `apply(_:) throws`, `undo() throws`, `redo() throws`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/EditingTests/ScoreEditorOffMainActorTests.swift`:

```swift
@testable import SheetMusicCore
import Testing

/// The Android JNI process has no main-actor executor: a `@MainActor` hop from a JNI entry point is scheduled and
/// never resumed. `ScoreEditor` therefore has to be drivable from a plain synchronous nonisolated context, which is
/// exactly what this suite is — no `@MainActor` annotation, no `await`.
@Suite("ScoreEditor off the main actor")
struct ScoreEditorOffMainActorTests {
    @Test("a nonisolated caller can construct and drive the editor")
    func drivesFromNonisolatedContext() throws {
        let editor = ScoreEditor(score: EditingFixtures.fourQuarterRests())
        try editor.apply(InputNote(
            at: RestID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 1,
            ),
            pitch: 60,
            tpc: 14,
        ))
        #expect(editor.canUndo)
        try editor.undo()
        #expect(editor.canUndo == false)
        #expect(editor.canRedo)
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter ScoreEditorOffMainActorTests
```

Expected: a **compile** failure, along the lines of `call to main actor-isolated
initializer 'init(score:)' in a synchronous nonisolated context`. That compile
error is the failing test — it is precisely the condition the JNI entry point
would hit.

- [ ] **Step 3: Remove the isolation**

In `Sources/SheetMusicCore/Editing/ScoreEditor.swift`, delete the `@MainActor`
attribute above `public final class ScoreEditor` and replace the sentence in the
doc comment that explains it:

```swift
/// `ScoreEditor` is a `final class` so a host app can keep a stable reference to register with `UndoManager`.
///
/// Deliberately NOT `@MainActor`. The Android JNI process pumps no main runloop, so a main-actor hop from an entry
/// point is scheduled and never resumed; the editor has to be drivable synchronously from whatever thread calls in.
/// It is not `Sendable` — hold one per isolation domain, which is what both hosts do.
public final class ScoreEditor {
```

- [ ] **Step 4: Fix the call sites the change surfaces**

`ScoreEditor` is referenced in three places besides the new test:
`Tests/SheetMusicTests/EditingTests/ScoreEditorTests.swift`,
`Tests/SheetMusicTests/EditingTests/CompositeEditCommandTests.swift`, and
`Examples/Apple/SheetMusicExample/macOS/NoteInputController.swift`. All three
are `@MainActor` contexts, and calling a nonisolated class from one is legal, so
expect no edits — but build them to be sure:

```
xcrun swift build --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing
```

Expected: build succeeds. If a call site now warns about non-Sendable capture,
keep the value inside its actor rather than adding `@unchecked Sendable`.

- [ ] **Step 5: Run the editing tests**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter ScoreEditor
```

Expected: `ScoreEditorTests` and `ScoreEditorOffMainActorTests` both PASS.

- [ ] **Step 6: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing add Sources/SheetMusicCore/Editing/ScoreEditor.swift Tests/SheetMusicTests/EditingTests/ScoreEditorOffMainActorTests.swift
```

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -m "refactor(editing): drop @MainActor from ScoreEditor so a JNI thread can drive it"
```

---

### Task 2: `Score.stableFingerprint`

The divergence check both sides run. Deliberately **not** `Hashable`/`Hasher`:
Swift seeds those per process, and the whole point is to compare a value across
two runtime images. FNV-1a over a canonical walk instead.

It hashes what editing can change — element kind, timing, pitch, spelling, ties,
tuplet ratios — not the entire model. A field this walk ignores can still differ
without being noticed; that only weakens detection, and every mutation this
feature makes is covered.

**Files:**
- Create: `Sources/SheetMusicCore/Score/ScoreFingerprint.swift`
- Test: `Tests/SheetMusicTests/EditingTests/ScoreFingerprintTests.swift`

**Interfaces:**
- Consumes: `Score`, `VoiceElement`, `NoteDuration`, `Accidental` from `SheetMusicCore`.
- Produces: `Score.stableFingerprint: Int64`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/EditingTests/ScoreFingerprintTests.swift`:

```swift
@testable import SheetMusicCore
import Testing

@Suite("Score.stableFingerprint")
struct ScoreFingerprintTests {
    private static let restAt1 = RestID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 0, elementIndex: 1,
    )

    @Test("equal scores fingerprint equally")
    func equalScoresAgree() {
        let a = EditingFixtures.fourQuarterRests()
        let b = EditingFixtures.fourQuarterRests()
        #expect(a.stableFingerprint == b.stableFingerprint)
    }

    @Test("a written note changes the fingerprint")
    func editChangesFingerprint() throws {
        var score = EditingFixtures.fourQuarterRests()
        let before = score.stableFingerprint
        _ = try InputNote(at: Self.restAt1, pitch: 60, tpc: 14).apply(to: &score)
        #expect(score.stableFingerprint != before)
    }

    @Test("undoing an edit restores the fingerprint")
    func undoRestoresFingerprint() throws {
        var score = EditingFixtures.fourQuarterRests()
        let before = score.stableFingerprint
        let inverse = try InputNote(at: Self.restAt1, pitch: 60, tpc: 14).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score.stableFingerprint == before)
    }

    @Test("pitch and spelling are both in the hash")
    func pitchAndSpellingCount() throws {
        var sharp = EditingFixtures.fourQuarterRests()
        var flat = EditingFixtures.fourQuarterRests()
        _ = try InputNote(at: Self.restAt1, pitch: 61, tpc: 21).apply(to: &sharp) // C#
        _ = try InputNote(at: Self.restAt1, pitch: 61, tpc: 9).apply(to: &flat) // Db
        #expect(sharp.stableFingerprint != flat.stableFingerprint)
    }

    @Test("the fingerprint is stable across repeated reads")
    func repeatedReadsAgree() {
        let score = EditingFixtures.fourQuarterRests()
        #expect(score.stableFingerprint == score.stableFingerprint)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter ScoreFingerprintTests
```

Expected: compile failure — `value of type 'Score' has no member 'stableFingerprint'`.

- [ ] **Step 3: Implement it**

Create `Sources/SheetMusicCore/Score/ScoreFingerprint.swift`:

```swift
import Foundation

/// A deterministic 64-bit digest of everything score *editing* can change, for comparing two copies of a score that
/// live in different processes or — on Android — in two separately linked images of this module.
///
/// Deliberately not built on `Hashable` / `Hasher`: those are seeded per process, so two images would disagree about
/// identical scores. FNV-1a is fixed by its constants and gives the same answer everywhere.
///
/// Scope is the mutable musical content — element kind, timing, pitch, spelling, ties, tuplet ratios. Engraving
/// trivia the edit commands never touch is out, which keeps the walk cheap. A difference this walk cannot see is a
/// missed detection, never a false alarm.
extension Score {
    public var stableFingerprint: Int64 {
        var hash = FNV1a()
        for part in parts {
            for staff in part.staves {
                hash.combine(staff.measures.count)
                for measure in staff.measures {
                    hash.combine(measure.voices.count)
                    for voice in measure.voices {
                        hash.combine(voice.elements.count)
                        for element in voice.elements {
                            hash.combine(element)
                        }
                        hash.combine(voice.tuplets.count)
                        for tuplet in voice.tuplets {
                            hash.combine(tuplet.actualNotes)
                            hash.combine(tuplet.normalNotes)
                            hash.combine(tuplet.startElementIndex)
                            hash.combine(tuplet.endElementIndex)
                        }
                    }
                }
            }
        }
        return Int64(bitPattern: hash.value)
    }
}

/// FNV-1a, 64-bit. Fixed constants, no seed — that is the whole point.
private struct FNV1a {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func combine(_ byte: UInt8) {
        value ^= UInt64(byte)
        value &*= 0x0000_0100_0000_01b3
    }

    mutating func combine(_ int: Int) {
        var bits = UInt64(bitPattern: Int64(int))
        for _ in 0 ..< 8 {
            combine(UInt8(truncatingIfNeeded: bits))
            bits >>= 8
        }
    }

    mutating func combine(_ flag: Bool) {
        combine(flag ? 1 : 0)
    }

    mutating func combine(_ duration: NoteDuration) {
        switch duration {
        case .whole: combine(1)
        case .half: combine(2)
        case .quarter: combine(3)
        case .eighth: combine(4)
        case .sixteenth: combine(5)
        case .thirtySecond: combine(6)
        case .sixtyFourth: combine(7)
        case .oneTwentyEighth: combine(8)
        case .twoFiftySixth: combine(9)
        case .measure: combine(10)
        case let .fraction(f):
            combine(11)
            combine(f.numerator)
            combine(f.denominator)
        }
    }

    mutating func combine(_ note: Note) {
        combine(note.pitch)
        combine(note.tpc)
        combine(note.accidental.map { Int($0.rawValue.hashSeed) } ?? -1)
        combine(note.tieForward ?? -1)
        combine(note.tieBack ?? -1)
    }

    mutating func combine(_ element: VoiceElement) {
        switch element {
        case let .chord(chord):
            combine(0)
            combine(chord.duration)
            combine(chord.notes.count)
            for note in chord.notes { combine(note) }
        case .keySignature: combine(1)
        case .timeSignature: combine(2)
        case .clef: combine(3)
        case .barLine: combine(4)
        case .dynamic: combine(5)
        case .spanner: combine(6)
        case .measureRepeat: combine(7)
        case .fermata: combine(8)
        case .breath: combine(9)
        case .harmony: combine(10)
        default: combine(99)
        }
    }
}

/// A stable integer for an accidental's spelling, independent of `Hashable`'s per-process seed.
private extension String {
    var hashSeed: Int {
        var h = 0
        for byte in utf8 { h = h &* 31 &+ Int(byte) }
        return h
    }
}
```

- [ ] **Step 4: Reconcile the walk with the real model**

The code above assumes shapes this repo may spell differently. Before running,
check each against the source and adjust in place:

- `Voice.tuplets` and `Tuplet.actualNotes` / `normalNotes` / `startElementIndex` / `endElementIndex` — read `Sources/SheetMusicCore/Score/Tuplet.swift` and the voice type that holds them.
- `Note.accidental` — read `Sources/SheetMusicCore/Score/Accidental.swift`. If `Accidental` is a `String`-raw-valued enum the code as written works; if it is `Int`-raw-valued, replace the line with `combine(note.accidental.map { Int($0.rawValue) } ?? -1)`; if it is a struct, hash its stored fields.
- `Chord.notes` is a `ChordNotes` collection — confirm it is `Sequence` of `Note`.
- `VoiceElement`'s full case list — the `default: combine(99)` arm exists so an unlisted case cannot crash the walk, but every case that carries *timing* must be listed explicitly or two different scores could collide. Cross-check against `Sources/SheetMusicCore/Score/VoiceElement.swift` and add any missing case.

- [ ] **Step 5: Run the tests**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter ScoreFingerprintTests
```

Expected: all five PASS.

- [ ] **Step 6: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing add Sources/SheetMusicCore/Score/ScoreFingerprint.swift Tests/SheetMusicTests/EditingTests/ScoreFingerprintTests.swift
```

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -m "feat(editing): add Score.stableFingerprint for cross-image divergence checks"
```

---

### Task 3: `EditIntent` and `ScoreEditSession`

The intent vocabulary and the choke point that turns one into commands and
applies it. This is the type both platforms will drive.

**Files:**
- Create: `Sources/SheetMusicCore/Editing/EditIntent.swift`
- Create: `Sources/SheetMusicCore/Editing/ScoreEditSession.swift`
- Test: `Tests/SheetMusicTests/EditingTests/ScoreEditSessionTests.swift`

**Interfaces:**
- Consumes: `ScoreEditor` (Task 1), `Score.stableFingerprint` (Task 2).
- Produces:
  - `enum EditIntent: Sendable, Equatable` with cases `inputNote(at: RestID, pitch: Int, tpc: Int, duration: NoteDuration?)`, `setRestDuration(at: VoiceElementID, duration: NoteDuration)`, `setChordDuration(at: VoiceElementID, duration: NoteDuration)`, `delete(at: VoiceElementID)`, `composite([EditIntent])`
  - `final class ScoreEditSession` with `init(score: Score)`, `var score: Score { get }`, `private(set) var lastAffectedLocation: VoiceElementID?`, `@discardableResult func apply(_ intent: EditIntent) -> Bool`, `func undo() -> Bool`, `func redo() -> Bool`, `var canUndo: Bool`, `var canRedo: Bool`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/EditingTests/ScoreEditSessionTests.swift`:

```swift
@testable import SheetMusicCore
import Testing

@Suite("ScoreEditSession")
struct ScoreEditSessionTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let restAt1 = RestID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
    private static let slotAt1 = VoiceElementID(restAt1)

    @Test("inputNote writes a chord into the slot")
    func inputNoteWrites() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        #expect(session.apply(.inputNote(at: Self.restAt1, pitch: 60, tpc: 14, duration: nil)))
        guard case .chord = session.score[Self.slotAt1] else {
            Issue.record("expected a chord in the slot")
            return
        }
        #expect(session.lastAffectedLocation == Self.slotAt1)
    }

    @Test("inputNote with a duration retimes the slot in the same undo step")
    func inputNoteWithDurationIsOneStep() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        #expect(session.apply(.inputNote(at: Self.restAt1, pitch: 60, tpc: 14, duration: .half)))
        guard case let .chord(chord) = session.score[Self.slotAt1] else {
            Issue.record("expected a chord in the slot")
            return
        }
        #expect(chord.duration == .half)
        #expect(session.undo())
        #expect(session.canUndo == false) // one step, not two
    }

    @Test("a refused intent leaves the score untouched and reports false")
    func refusedIntentIsANoOp() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        let before = session.score.stableFingerprint
        let outOfRange = VoiceElementID(staff: Self.staff, measureIndex: 99, voiceIndex: 0, elementIndex: 0)
        #expect(session.apply(.delete(at: outOfRange)) == false)
        #expect(session.score.stableFingerprint == before)
        #expect(session.canUndo == false)
    }

    @Test("composite applies as one undo step")
    func compositeIsOneStep() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        let before = session.score.stableFingerprint
        #expect(session.apply(.composite([
            .inputNote(at: Self.restAt1, pitch: 60, tpc: 14, duration: nil),
            .setChordDuration(at: Self.slotAt1, duration: .half),
        ])))
        #expect(session.undo())
        #expect(session.score.stableFingerprint == before)
    }

    @Test("undo then redo returns to the edited fingerprint")
    func undoRedoRoundTrips() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        #expect(session.apply(.inputNote(at: Self.restAt1, pitch: 60, tpc: 14, duration: nil)))
        let edited = session.score.stableFingerprint
        #expect(session.undo())
        #expect(session.redo())
        #expect(session.score.stableFingerprint == edited)
    }

    @Test("undo on an empty stack reports false rather than throwing")
    func undoOnEmptyStack() {
        let session = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        #expect(session.undo() == false)
        #expect(session.redo() == false)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter ScoreEditSessionTests
```

Expected: compile failure — `cannot find 'ScoreEditSession' in scope`.

- [ ] **Step 3: Write `EditIntent`**

Create `Sources/SheetMusicCore/Editing/EditIntent.swift`:

```swift
import Foundation

/// What a host asked the score to become — the unit of editing that crosses a process or image boundary.
///
/// An intent is deliberately *scalar*: identities and numbers only, never a slice of the score. That is what lets an
/// Android host relay one to a second copy of this module as a handful of bytes, and lets both copies plan it into
/// the same commands rather than shipping the commands themselves. The heavy commands — the ones carrying whole
/// `VoiceElement` subtrees — are built on each side from these scalars and never travel.
///
/// The case order is part of the wire format (`EditIntentWire`). Append; never renumber.
public enum EditIntent: Sendable, Equatable {
    /// Write a note into a rest slot. `duration` retimes the slot in the same undo step; `nil` keeps the slot's
    /// current length.
    case inputNote(at: RestID, pitch: Int, tpc: Int, duration: NoteDuration?)
    case setRestDuration(at: VoiceElementID, duration: NoteDuration)
    case setChordDuration(at: VoiceElementID, duration: NoteDuration)
    case delete(at: VoiceElementID)
    /// Several intents as one undo step.
    indirect case composite([EditIntent])
}
```

- [ ] **Step 4: Write `ScoreEditSession`**

Create `Sources/SheetMusicCore/Editing/ScoreEditSession.swift`:

```swift
import Foundation

/// One editing session over a score: turns an `EditIntent` into the commands that realize it and applies them as a
/// single undoable step.
///
/// This is the choke point both platforms share. iOS drives one directly; an Android host drives an authoritative one
/// in its own image and relays each applied intent to a mirror session behind the score handle, so the two stay
/// byte-identical while only the layout is recomputed.
///
/// Not `@MainActor` and not `Sendable` — hold one per isolation domain. See `ScoreEditor` for why.
public final class ScoreEditSession {
    private let editor: ScoreEditor

    public init(score: Score) {
        editor = ScoreEditor(score: score)
    }

    public var score: Score {
        editor.score
    }

    /// The voice slot the last applied / undone / redone intent touched, or `nil` before the first one lands.
    public var lastAffectedLocation: VoiceElementID? {
        editor.lastAffectedLocation
    }

    public var canUndo: Bool { editor.canUndo }
    public var canRedo: Bool { editor.canRedo }

    /// Applies `intent` as one undo step. Returns `false` — leaving the score untouched, by the engine's contract —
    /// when the intent names nothing the score can act on. A refused intent is not an error: the caller simply has
    /// nothing to relay, so a mirror session stays in step by doing nothing too.
    @discardableResult
    public func apply(_ intent: EditIntent) -> Bool {
        guard let command = Self.command(for: intent, in: editor.score) else { return false }
        do {
            try editor.apply(command)
        } catch {
            return false
        }
        return true
    }

    public func undo() -> Bool {
        guard editor.canUndo else { return false }
        do { try editor.undo() } catch { return false }
        return true
    }

    public func redo() -> Bool {
        guard editor.canRedo else { return false }
        do { try editor.redo() } catch { return false }
        return true
    }

    /// Plans an intent against `score`. `nil` when the intent has nothing to do — an empty composite, or a composite
    /// whose members all planned to nothing.
    private static func command(for intent: EditIntent, in score: Score) -> (any EditCommand)? {
        switch intent {
        case let .inputNote(location, pitch, tpc, duration):
            let write = InputNote(at: location, pitch: pitch, tpc: tpc)
            guard let duration else { return write }
            let slot = VoiceElementID(location)
            // A length change inside a tuplet is refused by the engine, and the refusal takes the note write down
            // with it — the second and later notes of a triplet simply never appear. Inside a tuplet the note is
            // written at whatever length the slot already has.
            guard !isInTuplet(slot, in: score) else { return write }
            return CompositeEditCommand(
                commands: [SetRestDuration(at: slot, duration: duration), write],
                location: slot,
            )
        case let .setRestDuration(location, duration):
            return SetRestDuration(at: location, duration: duration)
        case let .setChordDuration(location, duration):
            return SetChordDuration(at: location, duration: duration)
        case let .delete(location):
            return DeleteVoiceElement(at: location)
        case let .composite(intents):
            let commands = intents.compactMap { command(for: $0, in: score) }
            guard let first = commands.first else { return nil }
            guard commands.count > 1 else { return first }
            return CompositeEditCommand(commands: commands, location: first.affectedLocation)
        }
    }

    /// Whether `slot` sits inside a tuplet in `score`.
    private static func isInTuplet(_ slot: VoiceElementID, in score: Score) -> Bool {
        guard let staff = score[slot.staff],
              staff.measures.indices.contains(slot.measureIndex)
        else { return false }
        let voices = staff.measures[slot.measureIndex].voices
        guard voices.indices.contains(slot.voiceIndex) else { return false }
        return voices[slot.voiceIndex].tuplets.contains {
            slot.elementIndex >= $0.startElementIndex && slot.elementIndex <= $0.endElementIndex
        }
    }
}
```

- [ ] **Step 5: Reconcile with the real model**

As in Task 2 Step 4, `Voice.tuplets` and the tuplet's index properties may be
spelled differently. Read `Sources/SheetMusicCore/Score/Tuplet.swift` and the
voice type, and fix `isInTuplet` to match. Keep the *behavior* — "is this slot
covered by a tuplet" — whatever the spelling.

Also confirm the composite's `location:` argument label against
`Sources/SheetMusicCore/Editing/CompositeEditCommand.swift`.

- [ ] **Step 6: Run the tests**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter ScoreEditSessionTests
```

Expected: all six PASS.

- [ ] **Step 7: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing add Sources/SheetMusicCore/Editing/EditIntent.swift Sources/SheetMusicCore/Editing/ScoreEditSession.swift Tests/SheetMusicTests/EditingTests/ScoreEditSessionTests.swift
```

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -m "feat(editing): add EditIntent and ScoreEditSession"
```

---

### Task 4: The replay script and the determinism test

Two independent sessions, seeded from the same file bytes, fed the same steps,
must agree at every step. This is the property the whole Android design rests
on, and the script built here is reused on the device in Task 10.

**Files:**
- Create: `Tests/SheetMusicTests/EditingTests/EditReplayScript.swift`
- Test: `Tests/SheetMusicTests/EditingTests/EditReplayDeterminismTests.swift`

**Interfaces:**
- Consumes: `ScoreEditSession`, `EditIntent`, `Score.stableFingerprint`.
- Produces (test-target only): `enum EditReplayStep { case intent(EditIntent), undo, redo }` and `EditReplayScript.standard(staff:) -> [EditReplayStep]`, `EditReplayScript.fingerprints(of:startingFrom:) -> [Int64]`.

- [ ] **Step 1: Write the script builder**

Create `Tests/SheetMusicTests/EditingTests/EditReplayScript.swift`:

```swift
@testable import SheetMusicCore
import Foundation

/// One step of a scripted editing session.
enum EditReplayStep {
    case intent(EditIntent)
    case undo
    case redo
}

/// A fixed, hand-rolled sequence of edits used to prove that two sessions fed the same steps agree at every step.
///
/// Everything here is derived from the step index — no randomness, no clock. A determinism test that is itself
/// nondeterministic proves nothing, and the same script has to be reproducible on a device months later.
enum EditReplayScript {
    /// 100 steps over the first four measures: write, retime, delete, and periodically undo/redo. Steps that the
    /// engine refuses (a slot that a previous delete removed, say) are part of the point — a refusal must be refused
    /// identically on both sides.
    static func standard(staff: StaffAddress) -> [EditReplayStep] {
        let durations: [NoteDuration] = [.quarter, .eighth, .half, .sixteenth]
        var steps: [EditReplayStep] = []
        for index in 0 ..< 100 {
            let measureIndex = (index / 8) % 4
            let elementIndex = 1 + (index % 3)
            let slot = VoiceElementID(
                staff: staff, measureIndex: measureIndex, voiceIndex: 0, elementIndex: elementIndex,
            )
            let rest = RestID(
                staff: staff, measureIndex: measureIndex, voiceIndex: 0, elementIndex: elementIndex,
            )
            switch index % 7 {
            case 0, 1, 2:
                steps.append(.intent(.inputNote(
                    at: rest,
                    pitch: 60 + (index % 12),
                    tpc: 14,
                    duration: durations[index % durations.count],
                )))
            case 3:
                steps.append(.intent(.setChordDuration(at: slot, duration: durations[(index + 1) % durations.count])))
            case 4:
                steps.append(.intent(.composite([
                    .delete(at: slot),
                    .setRestDuration(at: slot, duration: .quarter),
                ])))
            case 5:
                steps.append(.undo)
            default:
                steps.append(.redo)
            }
        }
        return steps
    }

    /// Runs `steps` against a session seeded with `score` and returns the fingerprint after each step. The initial
    /// fingerprint is element 0, so the array is `steps.count + 1` long.
    static func fingerprints(of steps: [EditReplayStep], startingFrom score: Score) -> [Int64] {
        let session = ScoreEditSession(score: score)
        var out = [session.score.stableFingerprint]
        for step in steps {
            switch step {
            case let .intent(intent): _ = session.apply(intent)
            case .undo: _ = session.undo()
            case .redo: _ = session.redo()
            }
            out.append(session.score.stableFingerprint)
        }
        return out
    }
}
```

- [ ] **Step 2: Write the failing determinism test**

Create `Tests/SheetMusicTests/EditingTests/EditReplayDeterminismTests.swift`:

```swift
@testable import SheetMusicCore
import Foundation
import Testing

@Suite("Edit replay determinism")
struct EditReplayDeterminismTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    /// The fixture both this suite and the device-side replay (SP0 Task 10) start from.
    private static func fixtureScore() throws -> Score {
        let url = try #require(Bundle.module.url(forResource: "midi01", withExtension: "mscx"))
        return try MSCXParser.parse(data: Data(contentsOf: url))
    }

    @Test("two sessions fed the same steps agree at every step")
    func twoSessionsAgree() throws {
        let score = try Self.fixtureScore()
        let steps = EditReplayScript.standard(staff: Self.staff)
        let a = EditReplayScript.fingerprints(of: steps, startingFrom: score)
        let b = EditReplayScript.fingerprints(of: steps, startingFrom: try Self.fixtureScore())
        #expect(a == b)
        #expect(a.count == steps.count + 1)
    }

    @Test("the script actually edits something")
    func scriptIsNotInert() throws {
        let score = try Self.fixtureScore()
        let prints = EditReplayScript.fingerprints(
            of: EditReplayScript.standard(staff: Self.staff), startingFrom: score,
        )
        #expect(prints.last != prints.first)
        #expect(Set(prints).count >= 10)
    }
}
```

- [ ] **Step 3: Run it**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter EditReplayDeterminismTests
```

Expected: PASS. If it fails to compile, fix the fixture-loading call to match
how neighboring suites read `Tests/SheetMusicTests/Resources/*.mscx` — grep for
`forResource:` in `Tests/SheetMusicTests` and copy the idiom, including the
parser's real entry-point name.

If `scriptIsNotInert` fails because too many steps were refused, print the
per-step refusals and shift `elementIndex` to a range the fixture actually has
(`midi01.mscx` is a 4/4 fixture; measure 0 element 0 is typically a clef or time
signature, which is why the script starts at element 1).

- [ ] **Step 4: Run the same suite on an Android device**

Connect the Pixel (see the repo's own `Scripts/android-test.sh` header for the
one-time NDK sysroot setup) and run:

```
/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing/Scripts/android-test.sh aarch64
```

Expected: the full `SheetMusicTests` suite runs on-device and the two new suites
PASS there too. This is what rules out an arm64/Android-Foundation difference in
the walk (integer widths, `String.utf8`, `Fraction` arithmetic) before any of it
is wired to Kotlin.

- [ ] **Step 5: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing add Tests/SheetMusicTests/EditingTests/EditReplayScript.swift Tests/SheetMusicTests/EditingTests/EditReplayDeterminismTests.swift
```

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -m "test(editing): prove intent replay is deterministic on host and device"
```

---

### Task 5: `EditIntentWire`

The byte projection of `EditIntent`, following the existing
`ScoreItemIDCodec.swift` pattern exactly — including its reusable
`VoiceElementIDWire` / `RestIDWire` / `StaffAddressWire`.

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/Editing/EditIntentCodec.swift`
- Test: `Tests/SheetMusicTests/AndroidJNI/EditIntentCodecTests.swift`

**Interfaces:**
- Consumes: `EditIntent` (Task 3); `RestIDWire`, `VoiceElementIDWire` from `Sources/SheetMusicAndroidJNI/Audio/ScoreItemIDCodec.swift`.
- Produces: `EditIntentCodec.encode(_ intent: EditIntent) -> Data`, `EditIntentCodec.decode(_ data: Data) throws -> EditIntent`, and `@WireFormatChoice enum EditIntentWire`.

- [ ] **Step 1: Write the failing round-trip test**

Create `Tests/SheetMusicTests/AndroidJNI/EditIntentCodecTests.swift`:

```swift
@testable import SheetMusicAndroidJNI
@testable import SheetMusicCore
import Foundation
import Testing

@Suite("EditIntentCodec")
struct EditIntentCodecTests {
    private static let staff = StaffAddress(partIndex: 1, staffIndexInPart: 0)
    private static let rest = RestID(staff: staff, measureIndex: 3, voiceIndex: 2, elementIndex: 5)
    private static let slot = VoiceElementID(rest)

    private static let cases: [EditIntent] = [
        .inputNote(at: rest, pitch: 60, tpc: 14, duration: nil),
        .inputNote(at: rest, pitch: 61, tpc: 21, duration: .eighth),
        .inputNote(at: rest, pitch: 62, tpc: 16, duration: .fraction(Fraction(numerator: 3, denominator: 8))),
        .setRestDuration(at: slot, duration: .measure),
        .setChordDuration(at: slot, duration: .whole),
        .delete(at: slot),
        .composite([.delete(at: slot), .setRestDuration(at: slot, duration: .quarter)]),
    ]

    @Test("every intent survives an encode/decode round trip", arguments: cases)
    func roundTrips(intent: EditIntent) throws {
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
    }

    @Test("a decoded intent applies exactly as the original does")
    func decodedIntentAppliesIdentically() throws {
        let direct = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        let viaWire = ScoreEditSession(score: EditingFixtures.fourQuarterRests())
        let intent = EditIntent.inputNote(
            at: RestID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 0, voiceIndex: 0, elementIndex: 1,
            ),
            pitch: 60, tpc: 14, duration: .half,
        )
        _ = direct.apply(intent)
        _ = viaWire.apply(try EditIntentCodec.decode(EditIntentCodec.encode(intent)))
        #expect(direct.score.stableFingerprint == viaWire.score.stableFingerprint)
    }

    @Test("garbage bytes throw rather than decoding to something plausible")
    func garbageThrows() {
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(Data([0xff, 0xff, 0xff]))
        }
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter EditIntentCodecTests
```

Expected: compile failure — `cannot find 'EditIntentCodec' in scope`.

- [ ] **Step 3: Implement the codec**

Create `Sources/SheetMusicAndroidJNI/Editing/EditIntentCodec.swift`. Read
`Sources/SheetMusicAndroidJNI/Audio/ScoreItemIDCodec.swift` first and mirror its
structure — the `@WireFormatChoice` wire enum, the `init(from:)` / `decoded()`
pair, and the public codec enum:

```swift
import Foundation
import SheetMusicCore
import Wirelet

/// Codec for `EditIntent` — the only thing that crosses the JNI boundary during an edit session.
///
/// Scalars only, by design: an intent names slots and numbers, never a slice of the score, so both images plan it
/// into the same commands instead of shipping the commands. See `EditIntent` for why that matters.
///
/// The `@WireFormatChoice` discriminator order is part of the format. Append new intents; never renumber.
public enum EditIntentCodec {
    public static func encode(_ intent: EditIntent) -> Data {
        EditIntentWire(from: intent).encodeToData()
    }

    public static func decode(_ data: Data) throws -> EditIntent {
        try EditIntentWire(decoding: data).decoded()
    }
}

/// `NoteDuration` as a discriminator plus an optional fraction. `.fraction` is the only case with a payload, so the
/// two numerator/denominator fields are zero for every other case.
@WireFormat
struct NoteDurationWire {
    var kind: UInt8
    var numerator: Int32
    var denominator: Int32
}

@WireFormatChoice
enum EditIntentWire {
    case inputNote(InputNoteIntentWire)
    case setRestDuration(SlotDurationIntentWire)
    case setChordDuration(SlotDurationIntentWire)
    case delete(VoiceElementIDWire)
    case composite(CompositeIntentWire)
}

@WireFormat
struct InputNoteIntentWire {
    var location: RestIDWire
    var pitch: Int32
    var tpc: Int32
    /// 0 = keep the slot's length, 1 = retime it to `duration`.
    var hasDuration: UInt8
    var duration: NoteDurationWire
}

@WireFormat
struct SlotDurationIntentWire {
    var location: VoiceElementIDWire
    var duration: NoteDurationWire
}

@WireFormat
struct CompositeIntentWire {
    var members: [EditIntentWire]
}
```

Then add the `init(from:)` / `decoded()` conversions for each of the five wire
types and for `NoteDurationWire`, mapping the duration cases to the same
discriminators `ScoreFingerprint`'s walk uses (`whole` = 1 … `measure` = 10,
`fraction` = 11) so the two never disagree about what a number means.

- [ ] **Step 4: Run the tests**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter EditIntentCodecTests
```

Expected: all nine PASS (seven parameterized cases plus two).

If `@WireFormatChoice` rejects the recursive `CompositeIntentWire` (an array of
the enum that contains it), break the recursion by encoding the composite's
members as a `[Data]` of already-encoded child intents — one extra indirection,
no change to `EditIntentCodec`'s public surface.

- [ ] **Step 5: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing add Sources/SheetMusicAndroidJNI/Editing/EditIntentCodec.swift Tests/SheetMusicTests/AndroidJNI/EditIntentCodecTests.swift
```

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -m "feat(android): add the EditIntent wire codec"
```

---

### Task 6: `SheetMusicEngine.versionStamp`

The gate that refuses an edit session when the two images are different builds.
A stale `.so` has already bricked this app once; this makes it a refusal rather
than silent divergence.

**Files:**
- Create: `Sources/SheetMusicCore/SheetMusicEngine.swift`
- Test: `Tests/SheetMusicTests/EditingTests/SheetMusicEngineTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum SheetMusicEngine { public static let version: String; public static var versionStamp: Int64 }`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/EditingTests/SheetMusicEngineTests.swift`:

```swift
@testable import SheetMusicCore
import Testing

@Suite("SheetMusicEngine")
struct SheetMusicEngineTests {
    @Test("the stamp is stable across reads")
    func stampIsStable() {
        #expect(SheetMusicEngine.versionStamp == SheetMusicEngine.versionStamp)
    }

    @Test("the stamp is non-zero")
    func stampIsNonZero() {
        #expect(SheetMusicEngine.versionStamp != 0)
    }

    @Test("the version string matches the released version")
    func versionMatchesRelease() {
        #expect(SheetMusicEngine.version == "1.9.0")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter SheetMusicEngineTests
```

Expected: compile failure — `cannot find 'SheetMusicEngine' in scope`.

- [ ] **Step 3: Implement it**

Create `Sources/SheetMusicCore/SheetMusicEngine.swift`:

```swift
import Foundation

/// Build identity for this copy of the engine.
///
/// On Android two separately linked images of this module coexist in one process — one inside the library's own
/// `.so`, one inside the host app's. They stay in step only because they are the same build. A host compares its
/// compiled-in stamp with the one it reads over JNI before opening an edit session, and refuses to open one on a
/// mismatch: a stale `.so` should be a locked feature and a log line, never a score that silently diverges.
public enum SheetMusicEngine {
    /// Bumped by the release process alongside `CHANGELOG.md`.
    public static let version = "1.9.0"

    /// `version` as a fixed 64-bit number — FNV-1a, so both images agree without a seed.
    public static var versionStamp: Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in version.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return Int64(bitPattern: hash)
    }
}
```

- [ ] **Step 4: Reconcile the version with the repo's own**

`1.9.0` above is the version this branch will release as (1.8.0 is what Folino
pins today, and this branch changes the API). Confirm against `CHANGELOG.md`'s
unreleased heading and the repo's release convention; if the next version is
something else, use that and update the test's expected string to match.

Add a line to `CHANGELOG.md` under the unreleased heading noting the new
`SheetMusicEngine.version` constant, so the next release cannot forget to bump
it.

- [ ] **Step 5: Run the tests**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter SheetMusicEngineTests
```

Expected: all three PASS.

- [ ] **Step 6: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing add Sources/SheetMusicCore/SheetMusicEngine.swift Tests/SheetMusicTests/EditingTests/SheetMusicEngineTests.swift CHANGELOG.md
```

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -m "feat(editing): add SheetMusicEngine.versionStamp for the build-identity gate"
```

---

### Task 7: The JNI entry points

Seven `public func`s in `SheetMusicAndroidJNI`, following `AnchorBridge.swift`'s
shape: plain functions over an `Int64` handle and `Data`, jextract-exported.

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/Editing/EditSessionBridge.swift`
- Modify: `Sources/SheetMusicAndroidJNI/swift-java.config` (if it lists exported functions explicitly)
- Test: `Tests/SheetMusicTests/AndroidJNI/EditSessionBridgeTests.swift`

**Interfaces:**
- Consumes: `ScoreEditSession`, `EditIntentCodec`, `SheetMusicEngine`, and the existing `scoreTable` / `LayoutDocumentCache` in `Sources/SheetMusicAndroidJNI/JNISymbols.swift`.
- Produces:
  - `nativeBeginEditSession(scoreHandle: Int64) -> Bool`
  - `nativeApplyEditIntent(scoreHandle: Int64, intentBytes: Data) -> Bool`
  - `nativeEditUndo(scoreHandle: Int64) -> Bool`
  - `nativeEditRedo(scoreHandle: Int64) -> Bool`
  - `nativeEndEditSession(scoreHandle: Int64)`
  - `nativeScoreFingerprint(scoreHandle: Int64) -> Int64`
  - `nativeEngineVersionStamp() -> Int64`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/AndroidJNI/EditSessionBridgeTests.swift`:

```swift
@testable import SheetMusicAndroidJNI
@testable import SheetMusicCore
import Foundation
import Testing

/// Drives the JNI entry points as plain Swift functions on the host — the same code the device calls, minus the
/// Kotlin hop. Handles are created through the shipped `nativeLoadScore` so the table's lifetime rules are exercised
/// too.
@Suite("EditSessionBridge")
struct EditSessionBridgeTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func loadedHandle() throws -> Int64 {
        let url = try #require(Bundle.module.url(forResource: "midi01", withExtension: "mscx"))
        let handle = nativeLoadScore(bytes: try Data(contentsOf: url))
        #expect(handle != 0)
        return handle
    }

    @Test("an intent applied through the bridge moves the fingerprint")
    func applyMovesFingerprint() throws {
        let handle = try Self.loadedHandle()
        defer { nativeReleaseScore(handle: handle) }
        #expect(nativeBeginEditSession(scoreHandle: handle))
        let before = nativeScoreFingerprint(scoreHandle: handle)
        let intent = EditIntent.inputNote(
            at: RestID(staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1),
            pitch: 60, tpc: 14, duration: .quarter,
        )
        #expect(nativeApplyEditIntent(scoreHandle: handle, intentBytes: EditIntentCodec.encode(intent)))
        #expect(nativeScoreFingerprint(scoreHandle: handle) != before)
        nativeEndEditSession(scoreHandle: handle)
    }

    @Test("undo through the bridge restores the fingerprint")
    func undoRestores() throws {
        let handle = try Self.loadedHandle()
        defer { nativeReleaseScore(handle: handle) }
        #expect(nativeBeginEditSession(scoreHandle: handle))
        let before = nativeScoreFingerprint(scoreHandle: handle)
        let intent = EditIntent.inputNote(
            at: RestID(staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1),
            pitch: 60, tpc: 14, duration: .quarter,
        )
        _ = nativeApplyEditIntent(scoreHandle: handle, intentBytes: EditIntentCodec.encode(intent))
        #expect(nativeEditUndo(scoreHandle: handle))
        #expect(nativeScoreFingerprint(scoreHandle: handle) == before)
        nativeEndEditSession(scoreHandle: handle)
    }

    @Test("applying without a session reports false")
    func applyWithoutSession() throws {
        let handle = try Self.loadedHandle()
        defer { nativeReleaseScore(handle: handle) }
        let intent = EditIntent.delete(at: VoiceElementID(
            staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        ))
        #expect(nativeApplyEditIntent(scoreHandle: handle, intentBytes: EditIntentCodec.encode(intent)) == false)
    }

    @Test("an unknown handle is refused rather than crashing")
    func unknownHandleIsRefused() {
        #expect(nativeBeginEditSession(scoreHandle: 999_999) == false)
        #expect(nativeScoreFingerprint(scoreHandle: 999_999) == 0)
        nativeEndEditSession(scoreHandle: 999_999)
    }

    @Test("garbage intent bytes are refused")
    func garbageIntentIsRefused() throws {
        let handle = try Self.loadedHandle()
        defer { nativeReleaseScore(handle: handle) }
        #expect(nativeBeginEditSession(scoreHandle: handle))
        #expect(nativeApplyEditIntent(scoreHandle: handle, intentBytes: Data([0xff, 0x00])) == false)
        nativeEndEditSession(scoreHandle: handle)
    }

    @Test("the version stamp matches the engine's")
    func versionStampMatches() {
        #expect(nativeEngineVersionStamp() == SheetMusicEngine.versionStamp)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter EditSessionBridgeTests
```

Expected: compile failure — `cannot find 'nativeBeginEditSession' in scope`.

- [ ] **Step 3: Implement the bridge**

Create `Sources/SheetMusicAndroidJNI/Editing/EditSessionBridge.swift`:

```swift
import Foundation
import SheetMusicCore

/// Edit-session JNI bridge. A host that is editing keeps the authoritative score in its own image and relays each
/// applied intent here, so the score behind this handle stays byte-identical and only the layout has to be recomputed
/// — no new handle, no re-parse, and every downstream consumer of the handle (MIDI render, timeline, cursor) keeps
/// working across an edit.
///
/// The session lives beside the score rather than inside it so a host that never edits pays nothing.
///
/// Sessions are keyed by the score handle they mirror rather than held in the generic `HandleTable`, because the key
/// is the caller's existing score handle, not a new one.
private nonisolated(unsafe) var editSessions: [Int64: ScoreEditSession] = [:]
private let editSessionsLock = NSLock()

private func withSessions<T>(_ body: (inout [Int64: ScoreEditSession]) -> T) -> T {
    editSessionsLock.lock()
    defer { editSessionsLock.unlock() }
    return body(&editSessions)
}

/// Opens a mirror edit session over the score behind `scoreHandle`. Returns `false` for an unknown handle.
/// Idempotent: opening twice replaces the session, which is what a host restarting a session wants.
public func nativeBeginEditSession(scoreHandle: Int64) -> Bool {
    guard let score = scoreTable.value(for: scoreHandle) else { return false }
    withSessions { $0[scoreHandle] = ScoreEditSession(score: score) }
    return true
}

/// Applies one relayed intent. Returns `false` when there is no session, the bytes don't decode, or the engine
/// refuses the edit — all three leave the score untouched, which is exactly what the authoritative side did too.
public func nativeApplyEditIntent(scoreHandle: Int64, intentBytes: Data) -> Bool {
    guard let session = withSessions({ $0[scoreHandle] }) else { return false }
    guard let intent = try? EditIntentCodec.decode(intentBytes) else { return false }
    guard session.apply(intent) else { return false }
    publish(session.score, to: scoreHandle)
    return true
}

public func nativeEditUndo(scoreHandle: Int64) -> Bool {
    guard let session = withSessions({ $0[scoreHandle] }), session.undo() else { return false }
    publish(session.score, to: scoreHandle)
    return true
}

public func nativeEditRedo(scoreHandle: Int64) -> Bool {
    guard let session = withSessions({ $0[scoreHandle] }), session.redo() else { return false }
    publish(session.score, to: scoreHandle)
    return true
}

/// Drops the session. The score keeps whatever the session last wrote — ending a session is not a revert.
public func nativeEndEditSession(scoreHandle: Int64) {
    withSessions { $0[scoreHandle] = nil }
}

/// The digest the host compares against its own copy. `0` for an unknown handle — a value no real score produces
/// often enough to matter, and the host treats "unknown handle" as a mismatch anyway.
public func nativeScoreFingerprint(scoreHandle: Int64) -> Int64 {
    guard let score = scoreTable.value(for: scoreHandle) else { return 0 }
    return score.stableFingerprint
}

/// This image's build identity. A host compares it with its own before opening a session.
public func nativeEngineVersionStamp() -> Int64 {
    SheetMusicEngine.versionStamp
}

/// Writes the mutated score back into the handle and drops the stale layout, so the next `nativeComputeLayout`
/// re-engraves. Everything downstream keys off the same handle, which is the point of mirroring rather than
/// reloading.
private func publish(_ score: Score, to scoreHandle: Int64) {
    scoreTable.replace(scoreHandle, with: score)
    LayoutDocumentCache.release(scoreHandle)
}
```

- [ ] **Step 4: Add `HandleTable.replace` if it doesn't exist**

Read `HandleTable` (grep for `final class HandleTable` under
`Sources/SheetMusicAndroidJNI/`). If it has no `replace(_:with:)`, add one
beside `insert` / `value(for:)` / `release`, taking the same lock:

```swift
/// Swaps the value behind an existing handle. A no-op for an unknown handle — the caller has already checked.
func replace(_ handle: Int64, with value: Value) {
    lock.lock()
    defer { lock.unlock() }
    guard storage[handle] != nil else { return }
    storage[handle] = value
}
```

Match the existing property names (`storage`, `lock`) rather than inventing new
ones.

- [ ] **Step 5: Run the tests**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter EditSessionBridgeTests
```

Expected: all six PASS.

- [ ] **Step 6: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing add Sources/SheetMusicAndroidJNI
```

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing add Tests/SheetMusicTests/AndroidJNI/EditSessionBridgeTests.swift
```

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -m "feat(android): expose the edit session over JNI"
```

---

### Task 8: Cross-build the `.so` and check the exported signatures

The point of this task is that jextract emits the seven functions with the
signatures the Kotlin facade will declare. A signature mismatch here shows up on
device as `UnsatisfiedLinkError`, which is a much worse place to find it.

**Files:**
- No source changes expected. If the build fails, fix the source it names.

**Interfaces:**
- Consumes: Task 7's entry points.
- Produces: `libSheetMusicAndroidJNI.so` for arm64 with the seven symbols, and generated Java bindings under the module's staging directory.

- [ ] **Step 1: Cross-build**

```
/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing/Scripts/android-build-libs.sh
```

Expected: SUCCESS for both ABIs. Read the script's header first — it prepends
the 6.3.3 release toolchain and expects the Android SDK artifact bundle to be
staged; the Xcode-bundled Swift cannot build these.

- [ ] **Step 2: Confirm the symbols made it in**

```
nm -D --defined-only /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing/Android/SheetMusicAndroid/src/main/jniLibs/arm64-v8a/libSheetMusicAndroidJNI.so
```

Pipe-free is fine; scan the output for `nativeApplyEditIntent`,
`nativeBeginEditSession`, `nativeEditUndo`, `nativeEditRedo`,
`nativeEndEditSession`, `nativeScoreFingerprint`, `nativeEngineVersionStamp`,
and for `JNI_OnLoad`. If the `.so` path differs, find it with `find … -name
'libSheetMusicAndroidJNI.so'`.

- [ ] **Step 3: Read the generated bindings**

Find the jextract output for the new functions:

```
rg -n "nativeApplyEditIntent|nativeEngineVersionStamp" /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing/Android/SheetMusicAndroid/src/main
```

Note the exact Java parameter and return types — `Data` maps to swift-java's
`SwiftData`, `Int64` to `long`, `Bool` to `boolean`. Task 9's Kotlin facade must
match these exactly.

- [ ] **Step 4: Commit any staged artifacts the repo tracks**

Check whether generated bindings and `jniLibs` are gitignored here:

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing status --short
```

If nothing is listed, there is nothing to commit and this task ends. If sources
were fixed to make the build pass, commit those:

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -am "fix(android): make the edit-session bridge cross-compile"
```

---

### Task 9: Kotlin facade

**Files:**
- Modify: `Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/SheetMusicJNI.kt`
- Test: none of its own — Task 10 exercises it.

**Interfaces:**
- Consumes: the generated bindings from Task 8.
- Produces, on `object SheetMusicJNI`:
  - `fun nativeBeginEditSession(scoreHandle: Long): Boolean`
  - `fun nativeApplyEditIntent(scoreHandle: Long, intentBytes: ByteArray): Boolean`
  - `fun nativeEditUndo(scoreHandle: Long): Boolean`
  - `fun nativeEditRedo(scoreHandle: Long): Boolean`
  - `fun nativeEndEditSession(scoreHandle: Long)`
  - `fun nativeScoreFingerprint(scoreHandle: Long): Long`
  - `fun nativeEngineVersionStamp(): Long`

- [ ] **Step 1: Read the existing facade**

Open `SheetMusicJNI.kt` and study `nativeInstallSMuFLMetrics` (line ~85) — it
shows the arena and `SwiftData.fromByteArray` idiom for a `Data` parameter, and
whatever `object SheetMusicJNI` does about library loading.

- [ ] **Step 2: Add the seven functions**

Follow that idiom exactly. The one taking bytes looks like:

```kotlin
/**
 * Relays one edit intent into the mirror session behind [scoreHandle]. Returns false when no session is open,
 * the bytes don't decode, or the engine refused the edit — in every case the mirror's score is untouched, which
 * is what the authoritative side did too, so the two stay in step.
 */
fun nativeApplyEditIntent(scoreHandle: Long, intentBytes: ByteArray): Boolean {
    SwiftArena.ofConfined().use { arena ->
        return SwiftJavaJNI.nativeApplyEditIntent(scoreHandle, SwiftData.fromByteArray(intentBytes, arena))
    }
}
```

Match the arena construction the neighboring function uses rather than the line
above if they differ. The six functions without a `Data` parameter need no arena
and delegate directly.

- [ ] **Step 3: Compile the module**

```
/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing/Android/gradlew -p /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing/Android :SheetMusicAndroid:compileDebugKotlin --no-daemon
```

Expected: BUILD SUCCESSFUL. An "unresolved reference" here means the Java
signature differs from what Step 2 assumed — go back to Task 8 Step 3 and copy
the real one.

- [ ] **Step 4: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing add Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/SheetMusicJNI.kt
```

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -m "feat(android): add the Kotlin facade for the edit session"
```

---

### Task 10: Device replay through the JNI boundary

The acceptance test for SP0. A short, hand-written sequence driven from Kotlin
must produce the same fingerprints the host produced from the same sequence in
Swift. That is the end-to-end claim: intent bytes crossing the boundary keep two
copies of a score identical.

**Files:**
- Create: `Tests/SheetMusicTests/AndroidJNI/EditReplayGoldenTests.swift`
- Modify: `Android/SheetMusicAndroid/build.gradle.kts`
- Create: `Android/SheetMusicAndroid/src/androidTest/kotlin/io/github/jiyimeta/sheetmusic/EditSessionReplayTest.kt`
- Create: `Android/SheetMusicAndroid/src/androidTest/assets/midi01.mscx` (copy of the test fixture)

**Interfaces:**
- Consumes: everything above.
- Produces: a committed golden array of nine fingerprints shared by the Swift and Kotlin tests.

- [ ] **Step 1: Write the Swift golden generator**

Create `Tests/SheetMusicTests/AndroidJNI/EditReplayGoldenTests.swift`. It runs
an eight-step sequence — short enough to transcribe into Kotlin by hand and read
in review — and prints the fingerprints:

```swift
@testable import SheetMusicAndroidJNI
@testable import SheetMusicCore
import Foundation
import Testing

/// The host half of SP0's acceptance test. The eight steps here are mirrored, step for step, by
/// `EditSessionReplayTest.kt`; the fingerprints this prints are the goldens that test asserts. Keep the two in sync —
/// if you change a step here, re-run this and paste the new goldens there.
@Suite("Edit replay goldens")
struct EditReplayGoldenTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func rest(_ measure: Int, _ element: Int) -> RestID {
        RestID(staff: staff, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(rest(measure, element))
    }

    /// The eight steps, in order. `nil` means undo; see `run`.
    static let steps: [EditIntent?] = [
        .inputNote(at: rest(0, 1), pitch: 60, tpc: 14, duration: .quarter),
        .inputNote(at: rest(0, 2), pitch: 62, tpc: 16, duration: .eighth),
        .setChordDuration(at: slot(0, 1), duration: .half),
        .delete(at: slot(0, 2)),
        nil,
        .composite([
            .inputNote(at: rest(1, 1), pitch: 64, tpc: 18, duration: .quarter),
            .setChordDuration(at: slot(1, 1), duration: .eighth),
        ]),
        nil,
        .inputNote(at: rest(1, 1), pitch: 67, tpc: 15, duration: .quarter),
    ]

    @Test("print the goldens for the Kotlin replay test")
    func printGoldens() throws {
        let url = try #require(Bundle.module.url(forResource: "midi01", withExtension: "mscx"))
        let handle = nativeLoadScore(bytes: try Data(contentsOf: url))
        defer { nativeReleaseScore(handle: handle) }
        #expect(nativeBeginEditSession(scoreHandle: handle))
        var prints = [nativeScoreFingerprint(scoreHandle: handle)]
        for step in Self.steps {
            if let step {
                _ = nativeApplyEditIntent(scoreHandle: handle, intentBytes: EditIntentCodec.encode(step))
            } else {
                _ = nativeEditUndo(scoreHandle: handle)
            }
            prints.append(nativeScoreFingerprint(scoreHandle: handle))
        }
        nativeEndEditSession(scoreHandle: handle)
        print("GOLDENS: " + prints.map(String.init).joined(separator: ", "))
        #expect(prints.count == 9)
        #expect(Set(prints).count >= 5)
    }
}
```

- [ ] **Step 2: Run it and capture the goldens**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing --filter EditReplayGoldenTests
```

Expected: PASS, with a `GOLDENS: …` line of nine comma-separated numbers. Copy
that line — Step 5 pastes it into the Kotlin test.

If `Set(prints).count >= 5` fails, the fixture's measure 0 / measure 1 do not
have elements at index 1 and 2 in voice 0. Print
`session.score[slot(0, 1)]` to see what is there and shift the indices; then
re-run and capture the new goldens.

- [ ] **Step 3: Stage the fixture as an androidTest asset**

```
mkdir -p /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing/Android/SheetMusicAndroid/src/androidTest/assets
```

```
cp /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing/Tests/SheetMusicTests/Resources/midi01.mscx /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing/Android/SheetMusicAndroid/src/androidTest/assets/midi01.mscx
```

- [ ] **Step 4: Enable instrumented tests for the module**

In `Android/SheetMusicAndroid/build.gradle.kts`, copy the two pieces
`SheetMusicAudioAndroid/build.gradle.kts` already has — the runner in
`defaultConfig`:

```kotlin
testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
```

and the dependencies:

```kotlin
androidTestImplementation("androidx.test.ext:junit:1.1.5")
androidTestImplementation("androidx.test:runner:1.5.2")
```

- [ ] **Step 5: Write the Kotlin replay test**

Create
`Android/SheetMusicAndroid/src/androidTest/kotlin/io/github/jiyimeta/sheetmusic/EditSessionReplayTest.kt`.
Paste the goldens from Step 2 into `EXPECTED`, and encode each intent by hand —
the wire is small enough that hand-encoding is the honest test: if Kotlin can
build these bytes, so can Folino.

```kotlin
package io.github.jiyimeta.sheetmusic

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * SP0's acceptance test: the same eight editing steps that `EditReplayGoldenTests.swift` runs on the host, driven
 * here from Kotlin across the JNI boundary. Equal fingerprints at every step is the claim the whole Android editing
 * design rests on — that relaying scalar intents keeps two copies of a score identical.
 *
 * The goldens are pasted from that Swift test's output. If a step changes, re-run it and paste again.
 */
@RunWith(AndroidJUnit4::class)
class EditSessionReplayTest {
    @Test
    fun replayMatchesHostGoldens() {
        val context = InstrumentationRegistry.getInstrumentation().context
        val bytes = context.assets.open("midi01.mscx").use { it.readBytes() }
        val handle = SheetMusicJNI.nativeLoadScore(bytes)
        assertTrue("score failed to parse", handle != 0L)
        try {
            assertTrue(SheetMusicJNI.nativeBeginEditSession(handle))
            val actual = mutableListOf(SheetMusicJNI.nativeScoreFingerprint(handle))
            for (step in STEPS) {
                if (step == null) {
                    SheetMusicJNI.nativeEditUndo(handle)
                } else {
                    SheetMusicJNI.nativeApplyEditIntent(handle, step)
                }
                actual.add(SheetMusicJNI.nativeScoreFingerprint(handle))
            }
            assertEquals(EXPECTED.toList(), actual.toList())
        } finally {
            SheetMusicJNI.nativeEndEditSession(handle)
            SheetMusicJNI.nativeReleaseScore(handle)
        }
    }

    @Test
    fun versionStampIsNonZero() {
        assertTrue(SheetMusicJNI.nativeEngineVersionStamp() != 0L)
    }

    private companion object {
        // Paste the nine numbers printed by EditReplayGoldenTests.printGoldens.
        val EXPECTED = longArrayOf(/* GOLDENS */)

        /** null = undo. Byte layouts mirror EditIntentCodec's @WireFormatChoice discriminators. */
        val STEPS: List<ByteArray?> = listOf(
            inputNote(measure = 0, element = 1, pitch = 60, tpc = 14, duration = DUR_QUARTER),
            inputNote(measure = 0, element = 2, pitch = 62, tpc = 16, duration = DUR_EIGHTH),
            setChordDuration(measure = 0, element = 1, duration = DUR_HALF),
            delete(measure = 0, element = 2),
            null,
            composite(
                inputNote(measure = 1, element = 1, pitch = 64, tpc = 18, duration = DUR_QUARTER),
                setChordDuration(measure = 1, element = 1, duration = DUR_EIGHTH),
            ),
            null,
            inputNote(measure = 1, element = 1, pitch = 67, tpc = 15, duration = DUR_QUARTER),
        )
    }
}
```

Then write the encoder helpers in the same file, against the byte layout Task 5
produced. Read `EditIntentCodec.swift` and the `@WireFormatChoice` doc comment
in `ScoreItemIDCodec.swift`, which shows how to read a generated layout, and
match it field for field. `WireArray`-style framing is not involved here: a
single intent is one `EditIntentWire`.

Written against the layout as designed in Task 5 — a `u8` discriminator, then
the case payload, with `StaffAddress` as two `i32`s and every other scalar an
`i32` in little-endian order — the helpers look like this. Correct the field
order and widths if the generated layout differs:

```kotlin
private const val DISC_INPUT_NOTE: Byte = 0
private const val DISC_SET_REST_DURATION: Byte = 1
private const val DISC_SET_CHORD_DURATION: Byte = 2
private const val DISC_DELETE: Byte = 3
private const val DISC_COMPOSITE: Byte = 4

// NoteDuration discriminators — the same numbering ScoreFingerprint's walk uses.
private const val DUR_WHOLE = 1
private const val DUR_HALF = 2
private const val DUR_QUARTER = 3
private const val DUR_EIGHTH = 4

private fun buffer(size: Int): ByteBuffer =
    ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)

/** StaffAddress(partIndex, staffIndexInPart) — part 0, staff 0 for this fixture. */
private fun ByteBuffer.putStaff(): ByteBuffer = putInt(0).putInt(0)

/** VoiceElementIDWire / RestIDWire: staff + measureIndex + voiceIndex + elementIndex. */
private fun ByteBuffer.putSlot(measure: Int, element: Int): ByteBuffer =
    putStaff().putInt(measure).putInt(0).putInt(element)

/** NoteDurationWire: kind + numerator + denominator. Only `.fraction` uses the last two. */
private fun ByteBuffer.putDuration(kind: Int): ByteBuffer =
    put(kind.toByte()).putInt(0).putInt(0)

private fun inputNote(measure: Int, element: Int, pitch: Int, tpc: Int, duration: Int): ByteArray =
    buffer(1 + 16 + 4 + 4 + 1 + 9)
        .put(DISC_INPUT_NOTE)
        .putSlot(measure, element)
        .putInt(pitch)
        .putInt(tpc)
        .put(1) // hasDuration
        .putDuration(duration)
        .array()

private fun setChordDuration(measure: Int, element: Int, duration: Int): ByteArray =
    buffer(1 + 16 + 9)
        .put(DISC_SET_CHORD_DURATION)
        .putSlot(measure, element)
        .putDuration(duration)
        .array()

private fun delete(measure: Int, element: Int): ByteArray =
    buffer(1 + 16)
        .put(DISC_DELETE)
        .putSlot(measure, element)
        .array()

/** CompositeIntentWire holds a wire array: i32 count, then each member's bytes. */
private fun composite(vararg members: ByteArray): ByteArray {
    val body = members.sumOf { it.size }
    val out = buffer(1 + 4 + body).put(DISC_COMPOSITE).putInt(members.size)
    members.forEach { out.put(it) }
    return out.array()
}
```

- [ ] **Step 6: Run it on the device**

```
/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing/Android/gradlew -p /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing/Android :SheetMusicAndroid:connectedDebugAndroidTest --no-daemon
```

Expected: both tests PASS.

Diagnosis if they don't:
- `UnsatisfiedLinkError` on the first call → the `.so` predates the Swift change or `JNI_OnLoad` is missing. Re-run Task 8 Step 1, then Step 2's `nm` check.
- `nativeApplyEditIntent` returns false everywhere → the hand-encoded bytes don't match the wire. Add a temporary entry point that echoes a decoded intent back as a string, or compare against the bytes `EditIntentCodec.encode` produces for the same intent in the Swift test (print them as hex).
- Fingerprints diverge at exactly one step → that step's bytes decode to a *different valid* intent. Print the decoded intent for that step.
- Fingerprints diverge from the first step (index 0, before any edit) → the fixture bytes differ. Confirm the asset is byte-identical to the Tests resource.

- [ ] **Step 7: Commit**

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing add Tests/SheetMusicTests/AndroidJNI/EditReplayGoldenTests.swift Android/SheetMusicAndroid
```

```
git -C /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing commit -m "test(android): replay edit intents over JNI against host goldens"
```

---

### Task 11: Close out SP0

- [ ] **Step 1: Run the whole host suite**

```
xcrun swift test --package-path /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing
```

Expected: no regressions. Task 1 touched a shipped type, so this is the gate on
it.

- [ ] **Step 2: Run the whole suite on the device**

```
/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/android-note-editing/Scripts/android-test.sh aarch64
```

Expected: no regressions.

- [ ] **Step 3: Record what SP0 established**

Append to `docs/superpowers/plans/2026-08-06-android-note-editing-sp0.md` (this
file, in the Folino worktree) a short "Findings" section: whether replay held on
device, the fingerprint walk's measured cost if it was noticeable, and anything
about the wire or the toolchain the next sub-plan needs to know. SP1 and SP3
read this before starting.

- [ ] **Step 4: Report, and do not tag yet**

SP0 does not tag or push. SP1 lands on the same ssm branch and the two release
together, because Folino cannot consume SP0 without SP1's planners and geometry.
Report status and hand back.

---

## Findings — SP0 as executed (2026-08-06)

**The acceptance test passes on hardware.** Ten editing steps, encoded in Swift and relayed as opaque bytes from
Kotlin over JNI, produce byte-identical score fingerprints on a physical Pixel 8a at every step. Replay across the
boundary is sound, and the rest of the Android design can be built on it. Both full suites are green: host 2286
tests, and the same suite cross-compiled and run on the device, 0 failures either side.

### What the plan got wrong

- **`ScoreEditor` was `@MainActor`.** Not in the plan; found while writing it, and a hard prerequisite — a JNI
  process pumps no main runloop, so the hop would never resume. Task 1 removed it. Note the knock-on: a
  `@MainActor final class` is implicitly `Sendable`, and it no longer is. That is a source-breaking change for
  consumers, now recorded in the CHANGELOG.
- **The wire is not fixed-width little-endian.** Task 10's Kotlin encoder sketch was wrong: swift-wirelet emits
  protobuf-style TLV with LEB128 varints and zig-zag signed integers. Three older codec files in ssm still carry
  stale fixed-width comments; `EditIntentCodec.swift`'s doc comment is now the only accurate description in the repo.
- **Kotlin should never have been encoding intents at all.** The shipping data flow has Folino's core apply an
  intent and hand Kotlin the bytes to relay — Kotlin is a courier. Task 10 was re-specified so the Swift test writes
  committed `step-N.bin` assets and Kotlin relays them, which is both simpler and a more faithful test.
- **`midi01.mscx` has one measure and no rests**, not the four measures the plan assumed. Every task that touched it
  re-aimed its indices. `.inputNote` needs a rest, which only exists after a `.delete` at the same slot.
- **`HandleTable` is backed by a serial `DispatchQueue`** (`queue`/`storage`), not the `lock`/`storage` the drafts
  guessed.

### What SP1 must carry

- **Confirm `CrossBarInputPlanner` intercepts before the composite is built.** `SetRestDuration` refuses for four
  reasons besides tuplets, and each refusal takes the note write down with it. iOS avoids the common case only
  because `writeCrossingBarline` runs first. Ruled by the user: keep parity, verify the interception in SP1.
- **Introduce a richer fixture before citing `EditReplayDeterminismTests` as proof.** One measure, one voice, one
  staff, no rests, no tuplets, no `.locationShift` — the determinism claim is narrower than it reads.
- **`ScoreEditSession.apply` does not yet bundle `MeasureAccidentals` repairs.** Expected (the planners move in SP1),
  but it means this branch alone cannot drive real editing.
- **Extend `stableFingerprint` when new intents land.** Its exclusion list is now enumerated in the file. SP1's
  `ReplaceVoiceElements` carries whole `VoiceElement` subtrees — articulations, grace notes, lyrics — none of which
  the walk currently sees.

### What SP3 must carry

- **Treat any `false` from apply/undo/redo as "resync now."** The authoritative side only emits intents it already
  applied, so a refusal downstream is always an anomaly, never a benign no-op. `lastRefusalReason` was added for
  exactly this diagnostic.
- **The stale-layout race is newly reachable.** `nativeComputeLayout` reads the score and writes
  `LayoutDocumentCache` without the edit lock. Before this branch the score behind a handle never changed, so the
  cache could never go stale; now a compute in flight when an edit lands can cache a layout of the old score against
  a handle whose score is new. **The fingerprint check cannot detect this** — it compares scores, not layouts. The
  cheap fix is a per-handle generation in ssm's cache.
- **Begin/end must be strictly paired across both sides.** Re-opening a session re-seeds the mirror from the current
  score and discards its undo stack; if the authoritative session survives that, a later relayed undo returns `false`
  while the authoritative score has reverted.
- **`FolinoEditorJNI` will need `JNI_OnLoad`.** ssm's `.so` does not have one — swift-java puts it in
  `libSwiftJava.so` — but `@WireletObservable`'s `RegisterNatives` is a different mechanism, and the gradle-codegen-
  before-`.so` ordering trap applies there.
- **Leave a `// PARITY(android):` marker** at the divergence point per CLAUDE.md's ledger convention, and delete it
  when the Android half lands.

### Open decision for the user

`EditIntentCodec` is `public` in `SheetMusicAndroidJNI`, a product that only exists under
`SWIFT_SHEET_MUSIC_ANDROID=1` and which Folino does not link. So the side that must *produce* the bytes has no
access to the encoder, and the spec's §6.2 currently plans a second, independent `@WireFormat EditIntentWire` inside
`FolinoEditorJNI` — two hand-maintained declarations of one frozen schema in two repos, whose failure mode is a
silent misdecode caught only on the fingerprint sampling interval. See the section below.

### Smaller things left deliberately undone

Three stale wire-layout comments in ssm (`ScoreItemIDCodec`, `PathIDCodecs`, `StaffAddressCodec`) claim fixed-width
payloads the macros do not emit. The Android cross-compile resolves to the co-installed `swift-6.3.2-RELEASE_android`
SDK bundle rather than 6.3.3, because the build script's `PATH` pin fixes the compiler but not SwiftPM's bundle
selection; harmless here, worth remembering if something toolchain-shaped appears later.

## Self-review

**Spec coverage.** SP0's bullet in the spec's §11 names: `EditIntent` + wire for
a vertical slice (Tasks 3, 5), `ScoreEditSession` (Task 3), `stableFingerprint`
(Task 2), the version stamp (Task 6), the session JNI entry points (Task 7), and
the on-device replay acceptance (Tasks 4, 10). All covered. The spec's §5.3
table lists nine JNI entry points; the three geometry ones
(`nativeEditingHitTest`, `nativeEditingCaretFrame`, `nativeEncodeDrawProgram`)
belong to SP1 by the same §11, and are deliberately absent here.

**Additions beyond the spec.** Task 1 (de-isolating `ScoreEditor`) is not in the
spec — it was found while writing this plan and is a hard prerequisite: a
`@MainActor` session cannot be driven from a JNI thread. Task 8 (cross-build and
symbol check) is implied by "the JNI shape" but worth its own gate. Both are
noted here so the spec's §11 can be amended when SP0 reports.

**Known deviation from the final design.** `ScoreEditSession.apply` does not yet
bundle `MeasureAccidentals` renotation — that planner moves to ssm in SP1. Task
10's goldens are therefore regenerated in SP1. Called out in the Scope note.

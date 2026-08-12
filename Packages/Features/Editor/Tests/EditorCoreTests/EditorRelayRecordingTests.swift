import Domain
@testable import EditorCore
import Foundation
import SheetMusicCore
import Testing

/// The Android relay's contract on the core: it must be able to learn exactly which intents landed, in order, and
/// nothing else — a refused edit relays nothing (or the mirror diverges), and undo/redo relay as their own native
/// calls rather than as intents.
@Suite("Editor relay recording")
struct EditorRelayRecordingTests {
    @Test func `recording is off by default`() throws {
        let core = EditorCoreFixtures.makeCore()
        core.beginSession(score: EditorCoreFixtures.fourQuarterRests())
        try core.select(EditorCoreFixtures.firstRestItem(in: #require(core.score)))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")
        #expect(core.takeRelayIntents().isEmpty)
    }

    @Test func `an applied intent is recorded once`() throws {
        let core = EditorCoreFixtures.makeCore(recordsRelayIntents: true)
        core.beginSession(score: EditorCoreFixtures.fourQuarterRests())
        try core.select(EditorCoreFixtures.firstRestItem(in: #require(core.score)))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")
        let drained = core.takeRelayIntents()
        #expect(drained.count == 1)
        if case .inputNote = drained[0] {} else { Issue.record("expected .inputNote, got \(drained[0])") }
    }

    @Test func `draining leaves nothing behind`() throws {
        let core = EditorCoreFixtures.makeCore(recordsRelayIntents: true)
        core.beginSession(score: EditorCoreFixtures.fourQuarterRests())
        try core.select(EditorCoreFixtures.firstRestItem(in: #require(core.score)))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")
        _ = core.takeRelayIntents()
        #expect(core.takeRelayIntents().isEmpty)
    }

    /// Neither key has a caret or a selection to act on, so both `EditorSessionCore+Input` methods `guard`-return
    /// before ever calling `apply(_:)`. This covers that inert-convenience-method path — a real but different path
    /// from the engine refusing a well-formed intent, which the next test covers.
    @Test func `an inert key records nothing`() {
        let core = EditorCoreFixtures.makeCore(recordsRelayIntents: true)
        core.beginSession(score: EditorCoreFixtures.fourQuarterRests())
        // No selection and no caret: every op is inert, so nothing may be relayed.
        core.inputPitch(letter: "C")
        core.deleteSelection()
        #expect(core.takeRelayIntents().isEmpty)
    }

    /// Where the previous test covers a convenience method that never reaches `apply(_:)`, this drives `apply(_:)`
    /// itself with a well-formed intent the ENGINE refuses: `.removeTuplet(at:)` on element index 1, a plain rest
    /// that sits in no tuplet (`fourQuarterRests()` has none), so `RemoveTuplet.apply(to:)` throws and
    /// `ScoreEditSession.apply` returns `false`. This is the refusal `apply`'s `guard let session, session.apply
    /// (intent) else { return nil }` exists for — the property the whole Android relay depends on, since a
    /// refusal that reached the mirror would diverge the two scores.
    @Test func `an intent the engine refuses is not recorded`() {
        let core = EditorCoreFixtures.makeCore(recordsRelayIntents: true)
        core.beginSession(score: EditorCoreFixtures.fourQuarterRests())
        let refused = core.apply(.removeTuplet(at: VoiceElementID(EditorCoreFixtures.restID(element: 1))))
        #expect(refused == nil)
        #expect(core.takeRelayIntents().isEmpty)
    }

    @Test func `undo and redo record nothing`() throws {
        let core = EditorCoreFixtures.makeCore(recordsRelayIntents: true)
        core.beginSession(score: EditorCoreFixtures.fourQuarterRests())
        try core.select(EditorCoreFixtures.firstRestItem(in: #require(core.score)))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")
        _ = core.takeRelayIntents()
        core.undo()
        core.redo()
        #expect(core.takeRelayIntents().isEmpty)
    }

    /// Two letters typed in a run write into two DIFFERENT rest slots — input advances the caret after each write
    /// (spec §11-5) — so the two drained intents' `at:` targets confirm both landed, and in the order they landed,
    /// not just that the count came out to two.
    @Test func `intents drain in the order they landed`() throws {
        let core = EditorCoreFixtures.makeCore(recordsRelayIntents: true)
        core.beginSession(score: EditorCoreFixtures.fourQuarterRests())
        try core.select(EditorCoreFixtures.firstRestItem(in: #require(core.score)))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")
        core.inputPitch(letter: "D")
        let drained = core.takeRelayIntents()
        #expect(drained.count == 2)
        guard case let .inputNote(at: first, _, _, _) = drained[0] else {
            Issue.record("expected .inputNote, got \(drained[0])")
            return
        }
        guard case let .inputNote(at: second, _, _, _) = drained[1] else {
            Issue.record("expected .inputNote, got \(drained[1])")
            return
        }
        #expect(first == EditorCoreFixtures.restID(element: 1))
        #expect(second == EditorCoreFixtures.restID(element: 2))
    }

    @Test func `beginning a session clears what the last one left`() throws {
        let core = EditorCoreFixtures.makeCore(recordsRelayIntents: true)
        core.beginSession(score: EditorCoreFixtures.fourQuarterRests())
        try core.select(EditorCoreFixtures.firstRestItem(in: #require(core.score)))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")
        core.beginSession(score: EditorCoreFixtures.fourQuarterRests())
        #expect(core.takeRelayIntents().isEmpty)
    }
}

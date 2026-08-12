import Domain
@testable import EditorCore
import Foundation
import SheetMusicCore
import Testing

/// The Android relay's contract on the core: it must be able to learn exactly which intents landed, in order, and
/// nothing else — a refused edit relays nothing (or the mirror diverges), and undo/redo relay as their own native
/// calls rather than as intents.
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

    @Test func `a refused intent is not recorded`() {
        let core = EditorCoreFixtures.makeCore(recordsRelayIntents: true)
        core.beginSession(score: EditorCoreFixtures.fourQuarterRests())
        // No selection and no caret: every op is inert, so nothing may be relayed.
        core.inputPitch(letter: "C")
        core.deleteSelection()
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

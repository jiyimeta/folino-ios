import Domain
@testable import EditorCore
import Foundation
import SheetMusicCore
import Testing

/// Which operations leave a note to preview (spec §5.6), asserted on the core rather than on a host.
///
/// The decision is the core's precisely so the two platforms cannot answer it differently — `EditorViewModel`
/// drains `pendingAudition` on Apple and `EditorBridge`/`EditSessionRelay` drain it on Android, and neither adds a
/// rule of its own. Android was silent through the whole edit pad for exactly as long as nothing over there drained
/// it, which is the failure these pin against.
@Suite("Editor audition decisions")
struct EditorAuditionDecisionTests {
    private func openedCore() -> EditorSessionCore {
        let core = EditorCoreFixtures.makeCore()
        core.beginSession(score: EditorCoreFixtures.fourQuarterRests())
        return core
    }

    // MARK: - Ops that sound

    @Test func `note input queues the note it just wrote`() throws {
        let core = openedCore()
        try core.select(EditorCoreFixtures.firstRestItem(in: #require(core.score)))
        core.setDuration(.quarter)

        core.inputPitch(letter: "C")

        #expect(core.takePendingAudition() == EditorCoreFixtures.noteID(element: 1))
    }

    @Test func `a pitch shift queues the note it retuned`() throws {
        let core = openedCore()
        try core.select(EditorCoreFixtures.firstRestItem(in: #require(core.score)))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")
        _ = core.takePendingAudition()

        core.shiftPitch(bySemitones: 1)

        #expect(core.takePendingAudition() == EditorCoreFixtures.noteID(element: 1))
    }

    @Test func `an accidental queues the note it respelled`() throws {
        let core = openedCore()
        try core.select(EditorCoreFixtures.firstRestItem(in: #require(core.score)))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")
        _ = core.takePendingAudition()

        core.setAccidental(.sharp)

        #expect(core.takePendingAudition() == EditorCoreFixtures.noteID(element: 1))
    }

    // MARK: - Ops that stay silent

    /// Delete, undo and redo produce no "resulting pitch" worth sounding. Undo in particular would otherwise
    /// preview whatever the reverted edit had left selected.
    @Test func `delete, undo and redo queue nothing`() throws {
        let core = openedCore()
        try core.select(EditorCoreFixtures.firstRestItem(in: #require(core.score)))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")
        _ = core.takePendingAudition()

        core.deleteSelection()
        #expect(core.takePendingAudition() == nil)

        core.undo()
        #expect(core.takePendingAudition() == nil)

        core.redo()
        #expect(core.takePendingAudition() == nil)
    }

    @Test func `a refused pitch shift queues nothing`() throws {
        let core = openedCore()
        try core.select(EditorCoreFixtures.firstRestItem(in: #require(core.score)))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")
        _ = core.takePendingAudition()
        // Far past MIDI 127: `Note.shifted` refuses, `revision` does not move, so there is nothing to sound.
        for _ in 0 ..< 200 {
            core.shiftPitch(bySemitones: 1)
        }
        _ = core.takePendingAudition()

        core.shiftPitch(bySemitones: 1)

        #expect(core.takePendingAudition() == nil)
    }

    // MARK: - The tap

    @Test func `tapping a note queues it`() throws {
        let core = openedCore()
        try core.select(EditorCoreFixtures.firstRestItem(in: #require(core.score)))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")
        _ = core.takePendingAudition()

        core.selectFromTap(.note(EditorCoreFixtures.noteID(element: 1)))

        #expect(core.takePendingAudition() == EditorCoreFixtures.noteID(element: 1))
    }

    @Test func `tapping a rest or empty paper queues nothing`() throws {
        let core = openedCore()

        try core.selectFromTap(EditorCoreFixtures.firstRestItem(in: #require(core.score)))
        #expect(core.takePendingAudition() == nil)

        core.selectFromTap(nil)
        #expect(core.takePendingAudition() == nil)
    }

    /// A one-shot preview on top of a continuous transport is the one case the tap deliberately skips — the same
    /// rule the Reader's tap-to-seek follows outside edit mode.
    @Test func `tapping a note during playback queues nothing`() throws {
        let core = openedCore()
        try core.select(EditorCoreFixtures.firstRestItem(in: #require(core.score)))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")
        _ = core.takePendingAudition()
        core.isPlaybackActive = true

        core.selectFromTap(.note(EditorCoreFixtures.noteID(element: 1)))

        #expect(core.takePendingAudition() == nil)
    }

    // MARK: - Draining

    @Test func `draining leaves nothing behind`() throws {
        let core = openedCore()
        try core.select(EditorCoreFixtures.firstRestItem(in: #require(core.score)))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")

        #expect(core.takePendingAudition() != nil)
        #expect(core.takePendingAudition() == nil)
    }
}

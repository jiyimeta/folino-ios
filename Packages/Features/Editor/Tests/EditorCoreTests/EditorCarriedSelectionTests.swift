import Domain
@testable import EditorCore
import Foundation
import SheetMusicCore
import Testing

/// Carrying the reader's last tap-to-seek into the session that follows — the reason edit mode opens on the note you
/// were looking at rather than on an inert pad.
///
/// Asserted on the core because both hosts route through it: `EditorViewModel.selectItem` on Apple,
/// `EditorBridge.selectCarriedItem` on Android. Android opened every session blank for exactly as long as this
/// rule lived in the App's iOS-only wiring.
@Suite("Editor carried selection")
struct EditorCarriedSelectionTests {
    private func openedCore() -> EditorSessionCore {
        let core = EditorCoreFixtures.makeCore()
        core.beginSession(score: EditorCoreFixtures.fourQuarterRests())
        return core
    }

    @Test func `an item the score still contains is selected`() throws {
        let core = openedCore()
        let item = try EditorCoreFixtures.firstRestItem(in: #require(core.score))

        core.selectCarriedItem(item)

        #expect(core.selectedItem == item)
        #expect(core.caretItem == item)
    }

    @Test func `nothing carried leaves the session blank`() {
        let core = openedCore()

        core.selectCarriedItem(nil)

        #expect(core.selectedItem == nil)
        #expect(core.hasEditTarget == false)
    }

    /// Engine IDs are positional, so a tap remembered before an edit (or before a different score was opened) can
    /// name a slot that is no longer there. Selecting it anyway would arm the pad against nothing.
    @Test func `an item this score no longer contains is dropped`() {
        let core = openedCore()
        let pastTheEnd = SheetMusicCore.ScoreItemID.rest(EditorCoreFixtures.restID(measure: 7, element: 3))

        core.selectCarriedItem(pastTheEnd)

        #expect(core.selectedItem == nil)
    }

    /// The difference from `selectFromTap`, and the whole reason this is its own entry point: a tap asked to hear
    /// that note, opening a session did not.
    @Test func `carrying a selection sounds nothing`() throws {
        let core = openedCore()
        let score = try #require(core.score)
        core.select(EditorCoreFixtures.firstRestItem(in: score))
        core.setDuration(.quarter)
        core.inputPitch(letter: "C")
        _ = core.takePendingAudition()
        let note = SheetMusicCore.ScoreItemID.note(EditorCoreFixtures.noteID(element: 1))

        core.selectCarriedItem(note)

        #expect(core.selectedItem == note)
        #expect(core.takePendingAudition() == nil)
    }
}

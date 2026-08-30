import Domain
@testable import Editor
import Foundation
import Testing

/// The instruments sheet's view-model layer (Task 11): the rows it lists, and the three operations it drives —
/// add, remove and reorder a part. Each goes through `EditorViewModel.apply`, so what these assert is the adapter
/// on top of the engine intents, not the intents themselves (`swift-sheet-music` owns those tests).
@MainActor
@Suite("EditorViewModel parts")
struct EditorPartsTests {
    private func makeViewModel() -> EditorViewModel {
        EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: URL(filePath: "/tmp"),
            gateway: FakeScoreFileGateway(),
            repository: FakeScoreLibraryRepository(),
            originalStore: FakeScoreOriginalStore(),
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
        )
    }

    @Test
    func `addPart appends to the end and the rows refresh`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.parts(named: ["Flute", "Oboe"]))

        viewModel.addPart(EditorFixtures.partPlan(named: "Bassoon"))

        #expect(viewModel.partRows.count == 3)
        #expect(viewModel.partRows.map(\.name) == ["Flute", "Oboe", "Bassoon"])
        // `index` is the part index the intents address by, and it has to track the row's position, not its identity.
        #expect(viewModel.partRows.map(\.index) == [0, 1, 2])
        #expect(viewModel.partRows.last?.staffAddresses == [StaffAddress(partIndex: 2, staffIndexInPart: 0)])
    }

    /// Does the rename reach the SCORE, not just the row it was typed into — the thing the reader's first-system
    /// label and the inspector both read.
    @Test
    func `renamePart writes both names onto the score`() throws {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.parts(named: ["Flute", "Oboe"]))

        viewModel.renamePart(at: 0, longName: "なおき", shortName: "な")

        let score = try #require(viewModel.score)
        #expect(score.parts[0].instrument.longName == "なおき")
        #expect(score.parts[0].instrument.shortName == "な")
        #expect(viewModel.partRows.map(\.name) == ["なおき", "Oboe"])
    }

    @Test
    func `removePart is refused on a score's last part`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.parts(named: ["Flute"]))

        #expect(viewModel.canRemovePart == false)
        viewModel.removePart(at: 0)

        #expect(viewModel.partRows.count == 1)
        #expect(viewModel.partRows.map(\.name) == ["Flute"])
    }

    @Test
    func `removePart drops the named part once the score has more than one`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.parts(named: ["Flute", "Oboe"]))

        #expect(viewModel.canRemovePart)
        viewModel.removePart(at: 0)

        #expect(viewModel.partRows.map(\.name) == ["Oboe"])
    }

    @Test
    func `movePart maps List offsets, including SwiftUI's off-by-one`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.parts(named: ["Flute", "Oboe", "Bassoon"]))

        // `List.onMove` names the destination as a gap BEFORE the row currently at that index, so dragging row 0
        // below row 1 arrives as `toOffset: 2` and means part index 1.
        viewModel.movePart(fromOffsets: IndexSet(integer: 0), toOffset: 2)

        #expect(viewModel.partRows.map(\.name) == ["Oboe", "Flute", "Bassoon"])
    }

    @Test
    func `movePart upward needs no adjustment`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.parts(named: ["Flute", "Oboe", "Bassoon"]))

        viewModel.movePart(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        #expect(viewModel.partRows.map(\.name) == ["Bassoon", "Flute", "Oboe"])
    }

    @Test
    func `a move that lands where it started is not an edit`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.parts(named: ["Flute", "Oboe"]))
        let depthBefore = viewModel.sessionEditDepth

        viewModel.movePart(fromOffsets: IndexSet(integer: 0), toOffset: 1)

        #expect(viewModel.partRows.map(\.name) == ["Flute", "Oboe"])
        #expect(viewModel.sessionEditDepth == depthBefore)
    }

    @Test
    func `row identity is the part id, so it survives a reorder`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.parts(named: ["Flute", "Oboe"]))
        let idsBefore = viewModel.partRows.map(\.id)

        viewModel.movePart(fromOffsets: IndexSet(integer: 0), toOffset: 2)

        #expect(viewModel.partRows.map(\.id) == idsBefore.reversed())
    }

    @Test
    func `a multi-staff part lists one address per staff`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.parts(named: ["Flute", "Piano"], twoStavesAt: 1))

        #expect(viewModel.partRows.map(\.staffAddresses.count) == [1, 2])
        #expect(viewModel.partRows[1].staffAddresses == [
            StaffAddress(partIndex: 1, staffIndexInPart: 0),
            StaffAddress(partIndex: 1, staffIndexInPart: 1),
        ])
    }

    // MARK: - The selection and the caret survive a part operation
    //
    // Every part command reports element 0 of bar 0 as its affected location, which on a real score is a key or
    // time signature — and `SelectionRederivation.item` answers nil for anything that isn't a timed element. So
    // `apply`'s own re-derivation clears BOTH markers unless the op puts them back, and a cleared caret means an
    // inert input pad. These are the tests that would have caught that.

    @Test
    func `adding a part leaves the selection and caret where they were`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.parts(named: ["Flute", "Oboe"]))
        viewModel.select(.rest(EditorFixtures.restID(element: 2)))
        let selectedBefore = viewModel.selectedItem
        let caretBefore = viewModel.caretItem

        viewModel.addPart(EditorFixtures.partPlan(named: "Bassoon"))

        #expect(viewModel.selectedItem == selectedBefore)
        #expect(viewModel.caretItem == caretBefore)
    }

    @Test
    func `removing a part above the selection shifts the markers down one part`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.parts(named: ["Flute", "Oboe"]))
        viewModel.select(.rest(EditorFixtures.restID(part: 1, element: 2)))

        viewModel.removePart(at: 0)

        #expect(viewModel.selectedItem == .rest(EditorFixtures.restID(part: 0, element: 2)))
        #expect(viewModel.caretItem == .rest(EditorFixtures.restID(part: 0, element: 2)))
    }

    @Test
    func `removing the part the selection is in clears the markers`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.parts(named: ["Flute", "Oboe"]))
        viewModel.select(.rest(EditorFixtures.restID(part: 1, element: 2)))

        viewModel.removePart(at: 1)

        #expect(viewModel.selectedItem == nil)
        #expect(viewModel.caretItem == nil)
    }

    @Test
    func `moving the selected part carries the selection with it`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.parts(named: ["Flute", "Oboe", "Bassoon"]))
        viewModel.select(.rest(EditorFixtures.restID(part: 0, element: 2)))

        viewModel.movePart(fromOffsets: IndexSet(integer: 0), toOffset: 3) // Flute to the bottom

        #expect(viewModel.partRows.map(\.name) == ["Oboe", "Bassoon", "Flute"])
        #expect(viewModel.selectedItem == .rest(EditorFixtures.restID(part: 2, element: 2)))
        #expect(viewModel.caretItem == .rest(EditorFixtures.restID(part: 2, element: 2)))
    }

    @Test
    func `a part the move steps over carries its selection the other way`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.parts(named: ["Flute", "Oboe", "Bassoon"]))
        viewModel.select(.rest(EditorFixtures.restID(part: 2, element: 2))) // the Bassoon

        viewModel.movePart(fromOffsets: IndexSet(integer: 0), toOffset: 3) // Flute past it, so it moves up one

        #expect(viewModel.partRows.map(\.name) == ["Oboe", "Bassoon", "Flute"])
        #expect(viewModel.selectedItem == .rest(EditorFixtures.restID(part: 1, element: 2)))
    }

    @Test
    func `a part outside the moved span keeps its selection`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.parts(named: ["Flute", "Oboe", "Bassoon"]))
        viewModel.select(.rest(EditorFixtures.restID(part: 2, element: 2))) // the Bassoon
        let selectedBefore = viewModel.selectedItem

        viewModel.movePart(fromOffsets: IndexSet(integer: 1), toOffset: 0) // Oboe above Flute — the Bassoon is clear

        #expect(viewModel.partRows.map(\.name) == ["Oboe", "Flute", "Bassoon"])
        #expect(viewModel.selectedItem == selectedBefore)
    }

    @Test
    func `part operations are undoable through the shared apply choke point`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.parts(named: ["Flute", "Oboe"]))

        viewModel.addPart(EditorFixtures.partPlan(named: "Bassoon"))
        #expect(viewModel.canUndo)

        viewModel.undo()

        #expect(viewModel.partRows.map(\.name) == ["Flute", "Oboe"])
    }
}

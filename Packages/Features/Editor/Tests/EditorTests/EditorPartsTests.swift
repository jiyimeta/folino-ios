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
    func `part operations are undoable through the shared apply choke point`() {
        let viewModel = makeViewModel()
        viewModel.beginSession(score: EditorFixtures.parts(named: ["Flute", "Oboe"]))

        viewModel.addPart(EditorFixtures.partPlan(named: "Bassoon"))
        #expect(viewModel.canUndo)

        viewModel.undo()

        #expect(viewModel.partRows.map(\.name) == ["Flute", "Oboe"])
    }
}

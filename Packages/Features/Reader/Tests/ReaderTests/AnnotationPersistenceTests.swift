import Domain
import Foundation
@testable import Reader
import Testing

private actor FakeAnnotationStore: AnnotationStore {
    private(set) var layers: [ScoreItemID: AnnotationLayer] = [:]
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    func annotationLayer(forScoreItem id: ScoreItemID) throws -> AnnotationLayer? {
        layers[id]
    }

    func saveAnnotationLayer(_ layer: AnnotationLayer) throws {
        saveCount += 1
        layers[layer.scoreItemID] = layer
    }

    func deleteAnnotationLayer(forScoreItem id: ScoreItemID) throws {
        deleteCount += 1
        layers.removeValue(forKey: id)
    }
}

@MainActor
struct AnnotationPersistenceTests {
    private static func makeVM(scoreID: ScoreItemID, annotationStore: any AnnotationStore) -> ReaderViewModel {
        let item = ScoreItem(
            id: scoreID,
            title: "test",
            composer: nil,
            instrumentationSummary: nil,
            localFileName: "t.mid",
            contentHash: "h",
            sizeBytes: 0,
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
        return ReaderViewModel(
            scoreItem: item,
            repository: FakeScoreLibraryRepository(),
            gateway: FakeScoreFileGateway(),
            annotationStore: annotationStore,
            scoresDirectory: URL(fileURLWithPath: "/dev/null"),
        )
    }

    @Test func `loads persisted drawing data into the observable property`() async throws {
        let store = FakeAnnotationStore()
        let scoreID = ScoreItemID()
        let data = Data([0x01, 0x02, 0x03])
        try await store.saveAnnotationLayer(
            AnnotationLayer(
                scoreItemID: scoreID,
                drawings: [DrawingAnchor(anchor: ReaderViewModel.makeSentinelAnchor(), encodedDrawing: data)],
                textBoxes: [],
                updatedAt: Date(timeIntervalSince1970: 0),
            ),
        )
        let vm = Self.makeVM(scoreID: scoreID, annotationStore: store)
        await vm.loadAnnotations()
        #expect(vm.annotationDrawingData == data)
    }

    @Test func `debounced change persists one layer with the drawing data`() async throws {
        let store = FakeAnnotationStore()
        let scoreID = ScoreItemID()
        let vm = Self.makeVM(scoreID: scoreID, annotationStore: store)
        let data = Data([0xAA, 0xBB])
        vm.annotationDrawingDidChange(data, isEmpty: false)
        await vm.flushPendingAnnotationSave()
        let saved = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(saved?.drawings.first?.encodedDrawing == data)
        #expect(await store.saveCount == 1)
    }

    @Test func `empty drawing deletes the layer`() async throws {
        let store = FakeAnnotationStore()
        let scoreID = ScoreItemID()
        try await store.saveAnnotationLayer(
            AnnotationLayer(
                scoreItemID: scoreID,
                drawings: [DrawingAnchor(anchor: ReaderViewModel.makeSentinelAnchor(), encodedDrawing: Data([0x01]))],
                textBoxes: [],
                updatedAt: Date(timeIntervalSince1970: 0),
            ),
        )
        let vm = Self.makeVM(scoreID: scoreID, annotationStore: store)
        vm.annotationDrawingDidChange(Data(), isEmpty: true)
        await vm.flushPendingAnnotationSave()
        let after = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(after == nil)
        #expect(await store.deleteCount == 1)
    }
}

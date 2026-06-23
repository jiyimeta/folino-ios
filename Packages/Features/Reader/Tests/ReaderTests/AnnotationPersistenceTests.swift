import Domain
import Foundation
@testable import Reader
import Testing

private actor FakeAnnotationStore: AnnotationStore {
    private(set) var layers: [ScoreItemID: AnnotationLayer] = [:]
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    // swiftlint:disable async_without_await
    func annotationLayer(forScoreItem id: ScoreItemID) async throws -> AnnotationLayer? {
        layers[id]
    }

    func saveAnnotationLayer(_ layer: AnnotationLayer) async throws {
        saveCount += 1
        layers[layer.scoreItemID] = layer
    }

    func deleteAnnotationLayer(forScoreItem id: ScoreItemID) async throws {
        deleteCount += 1
        layers.removeValue(forKey: id)
    }
    // swiftlint:enable async_without_await
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

    private static func anchor() -> MusicalAnchor {
        MusicalAnchor(
            measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0,
        )
    }

    @Test func `loads persisted drawings into the observable property`() async throws {
        let store = FakeAnnotationStore()
        let scoreID = ScoreItemID()
        let drawings = [DrawingAnchor(anchor: Self.anchor(), encodedDrawing: Data([0x01, 0x02]))]
        try await store.saveAnnotationLayer(AnnotationLayer(
            scoreItemID: scoreID, drawings: drawings, textBoxes: [], updatedAt: Date(timeIntervalSince1970: 0),
        ))
        let vm = Self.makeVM(scoreID: scoreID, annotationStore: store)
        await vm.loadAnnotations()
        #expect(vm.annotationDrawings == drawings)
    }

    @Test func `debounced change persists one layer with the drawings`() async throws {
        let store = FakeAnnotationStore()
        let scoreID = ScoreItemID()
        let vm = Self.makeVM(scoreID: scoreID, annotationStore: store)
        let drawings = [DrawingAnchor(anchor: Self.anchor(), encodedDrawing: Data([0xAA]))]
        vm.annotationDrawingsDidChange(drawings)
        await vm.flushPendingAnnotationSave()
        let saved = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(saved?.drawings == drawings)
        #expect(await store.saveCount == 1)
    }

    @Test func `empty drawings deletes the layer`() async throws {
        let store = FakeAnnotationStore()
        let scoreID = ScoreItemID()
        try await store.saveAnnotationLayer(AnnotationLayer(
            scoreItemID: scoreID,
            drawings: [DrawingAnchor(anchor: Self.anchor(), encodedDrawing: Data([0x01]))],
            textBoxes: [], updatedAt: Date(timeIntervalSince1970: 0),
        ))
        let vm = Self.makeVM(scoreID: scoreID, annotationStore: store)
        vm.annotationDrawingsDidChange([])
        await vm.flushPendingAnnotationSave()
        #expect(try await store.annotationLayer(forScoreItem: scoreID) == nil)
        #expect(await store.deleteCount == 1)
    }
}

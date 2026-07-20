import Domain
import Foundation
@testable import Reader
import Testing

/// In-memory `AnnotationBlobStore` for the VM persistence tests. Access is serialized by the coordinator (one store
/// call at a time) and the VM awaits the change registration before flushing; the lock keeps counter/payload reads
/// data-race-clean across the actor boundary regardless.
private final class FakeBlobStore: AnnotationBlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ScoreItemID: Data] = [:]
    private var _saveCount = 0
    private var _deleteCount = 0

    var saveCount: Int {
        lock.withLock { _saveCount }
    }

    var deleteCount: Int {
        lock.withLock { _deleteCount }
    }

    func preStore(_ payload: Data, for id: ScoreItemID) {
        lock.withLock { stored[id] = payload }
    }

    func storedPayload(for id: ScoreItemID) -> Data? {
        lock.withLock { stored[id] }
    }

    func load(scoreID: ScoreItemID) throws -> Data? {
        lock.withLock { stored[scoreID] }
    }

    func save(scoreID: ScoreItemID, updatedAt _: Date, payload: Data) throws {
        lock.withLock { _saveCount += 1; stored[scoreID] = payload }
    }

    func delete(scoreID: ScoreItemID) throws {
        lock.withLock { _deleteCount += 1; stored[scoreID] = nil }
    }
}

@MainActor
struct AnnotationPersistenceTests {
    private static func makeVM(scoreID: ScoreItemID, store: any AnnotationBlobStore) -> ReaderViewModel {
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
            annotationCoordinator: AnnotationSaveCoordinator(store: store),
            scoresDirectory: URL(fileURLWithPath: "/dev/null"),
        )
    }

    private static func anchor() -> MusicalAnchor {
        MusicalAnchor(
            measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0,
        )
    }

    @Test func `loads persisted drawings into the observable property`() async {
        let store = FakeBlobStore()
        let scoreID = ScoreItemID()
        let drawings = [DrawingAnchor(kind: .musical(Self.anchor()), encodedDrawing: Data([0x01, 0x02]))]
        store.preStore(AnnotationLayerCodec.encode(drawings: drawings, textBoxes: []), for: scoreID)
        let vm = Self.makeVM(scoreID: scoreID, store: store)
        await vm.loadAnnotations()
        #expect(vm.annotationDrawings == drawings)
    }

    @Test func `debounced change persists one layer with the drawings`() async throws {
        let store = FakeBlobStore()
        let scoreID = ScoreItemID()
        let vm = Self.makeVM(scoreID: scoreID, store: store)
        let drawings = [DrawingAnchor(kind: .musical(Self.anchor()), encodedDrawing: Data([0xAA]))]
        vm.annotationDrawingsDidChange(drawings)
        await vm.flushPendingAnnotationSave()
        let payload = try #require(store.storedPayload(for: scoreID))
        #expect(AnnotationLayerCodec.decode(payload)?.drawings == drawings)
        #expect(store.saveCount == 1)
    }

    @Test func `empty drawings deletes the layer`() async {
        let store = FakeBlobStore()
        let scoreID = ScoreItemID()
        store.preStore(
            AnnotationLayerCodec.encode(
                drawings: [DrawingAnchor(kind: .musical(Self.anchor()), encodedDrawing: Data([0x01]))],
                textBoxes: [],
            ),
            for: scoreID,
        )
        let vm = Self.makeVM(scoreID: scoreID, store: store)
        vm.annotationDrawingsDidChange([])
        await vm.flushPendingAnnotationSave()
        #expect(store.storedPayload(for: scoreID) == nil)
        #expect(store.deleteCount == 1)
    }
}

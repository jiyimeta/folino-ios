import Domain
import Foundation
import Testing

@Suite("AnnotationSaveCoordinator")
struct AnnotationSaveCoordinatorTests {
    /// Records the coordinator's writes. Access is serialized by the coordinator (it awaits one store call at a time)
    /// and the tests read only after a sleep that lets the save settle; the lock keeps it data-race-clean regardless.
    final class FakeBlobStore: AnnotationBlobStore, @unchecked Sendable {
        private let lock = NSLock()
        private var _saves: [(ScoreItemID, Data)] = []
        private var _deletes: [ScoreItemID] = []
        var stored: [ScoreItemID: Data] = [:]

        var saves: [(ScoreItemID, Data)] {
            lock.withLock { _saves }
        }

        var deletes: [ScoreItemID] {
            lock.withLock { _deletes }
        }

        func load(scoreID: ScoreItemID) throws -> Data? {
            lock.withLock { stored[scoreID] }
        }

        func save(scoreID: ScoreItemID, updatedAt: Date, payload: Data) throws {
            lock.withLock { _saves.append((scoreID, payload)); stored[scoreID] = payload }
        }

        func delete(scoreID: ScoreItemID) throws {
            lock.withLock { _deletes.append(scoreID); stored[scoreID] = nil }
        }
    }

    private func drawing(_ dxSp: Double) -> DrawingAnchor {
        DrawingAnchor(
            kind: .musical(MusicalAnchor(
                measureIndex: 0, tickInMeasure: 0, partIndex: 0,
                staffIndexInPart: 0, dxSp: dxSp, verticalOffsetSp: 0,
            )),
            encodedDrawing: Data([0x46, 0x49, 0x4E, 0x4B]),
        )
    }

    private let scoreID = ScoreItemID(rawValue: UUID())

    @Test
    func `rapid changes within the debounce window coalesce into a single save (last wins)`() async throws {
        let store = FakeBlobStore()
        let coordinator = AnnotationSaveCoordinator(store: store, debounce: .milliseconds(30))
        await coordinator.drawingsDidChange([drawing(1)], scoreID: scoreID)
        await coordinator.drawingsDidChange([drawing(1), drawing(2)], scoreID: scoreID)
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.saves.count == 1)
        #expect(AnnotationLayerCodec.decode(store.saves[0].1)?.drawings.count == 2)
    }

    @Test
    func `an empty drawing set deletes the layer instead of storing it`() async throws {
        let store = FakeBlobStore()
        let coordinator = AnnotationSaveCoordinator(store: store, debounce: .milliseconds(30))
        await coordinator.drawingsDidChange([], scoreID: scoreID)
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.deletes == [scoreID])
        #expect(store.saves.isEmpty)
    }

    @Test
    func `flush writes the pending change immediately, bypassing the debounce`() async {
        let store = FakeBlobStore()
        let coordinator = AnnotationSaveCoordinator(store: store, debounce: .seconds(10))
        await coordinator.drawingsDidChange([drawing(1)], scoreID: scoreID)
        await coordinator.flush()
        #expect(store.saves.count == 1)
    }

    @Test
    func `load decodes the stored payload back to the drawings`() async {
        let store = FakeBlobStore()
        let d = drawing(3)
        store.stored[scoreID] = AnnotationLayerCodec.encode(drawings: [d], textBoxes: [])
        let coordinator = AnnotationSaveCoordinator(store: store, debounce: .milliseconds(30))
        let loaded = await coordinator.load(scoreID: scoreID)
        #expect(loaded == [d])
    }
}

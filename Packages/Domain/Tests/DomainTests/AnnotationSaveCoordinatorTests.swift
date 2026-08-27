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

    /// Waits for the debounce to fire, up to a generous ceiling, rather than sleeping a fixed 150 ms and asserting.
    /// The fixed sleep was a real flake: these are the only tests in the module that wait on wall-clock time, so under
    /// a full parallel run the 30 ms debounce can simply not have been scheduled yet when the sleep ends. Polling
    /// keeps the fast path fast (one 10 ms tick in practice) and the slow path merely slow instead of red. It still
    /// proves what the test is for — a fixed number of writes for two rapid changes — because it stops on the FIRST
    /// write and the extra one, if the debounce were broken, would have to arrive inside the remaining budget.
    private func waitForWrite(_ store: FakeBlobStore) async throws {
        for _ in 0 ..< 200 where store.saves.isEmpty && store.deletes.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        // A moment for a SECOND write to show up if the debounce failed to coalesce.
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test
    func `rapid changes within the debounce window coalesce into a single save (last wins)`() async throws {
        let store = FakeBlobStore()
        let coordinator = AnnotationSaveCoordinator(store: store, debounce: .milliseconds(30))
        await coordinator.drawingsDidChange([drawing(1)], scoreID: scoreID)
        await coordinator.drawingsDidChange([drawing(1), drawing(2)], scoreID: scoreID)
        try await waitForWrite(store)
        #expect(store.saves.count == 1)
        #expect(AnnotationLayerCodec.decode(store.saves.first?.1 ?? Data())?.drawings.count == 2)
    }

    @Test
    func `an empty drawing set deletes the layer instead of storing it`() async throws {
        let store = FakeBlobStore()
        let coordinator = AnnotationSaveCoordinator(store: store, debounce: .milliseconds(30))
        await coordinator.drawingsDidChange([], scoreID: scoreID)
        try await waitForWrite(store)
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

    // MARK: - reload: a store failure told apart from "there is no ink"

    /// What the part-index re-seed hangs on. `load` answers `[]` to both, which would have the caller replace the
    /// live model with nothing on the strength of one unlucky read — and the next capture would make that permanent.
    @Test
    func `reload reports a store failure as nil rather than as no ink`() async {
        let store = ThrowingBlobStore()
        let coordinator = AnnotationSaveCoordinator(store: store, debounce: .milliseconds(30))
        #expect(await coordinator.reload(scoreID: scoreID) == nil)
        // The collapsing answer the open path still wants.
        #expect(await coordinator.load(scoreID: scoreID) == [])
    }

    @Test
    func `reload reports a missing or unreadable layer as no ink`() async {
        let store = FakeBlobStore()
        let coordinator = AnnotationSaveCoordinator(store: store, debounce: .milliseconds(30))
        #expect(await coordinator.reload(scoreID: scoreID) == [])
        store.stored[scoreID] = Data("not a layer".utf8)
        #expect(await coordinator.reload(scoreID: scoreID) == [])
    }
}

/// Fails every read, for `reload`'s failure case.
private struct ThrowingBlobStore: AnnotationBlobStore {
    func load(scoreID _: ScoreItemID) throws -> Data? {
        throw DomainError.persistenceFailed(reason: "boom")
    }

    func save(scoreID _: ScoreItemID, updatedAt _: Date, payload _: Data) throws {}
    func delete(scoreID _: ScoreItemID) throws {}
}

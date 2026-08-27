import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

/// The ink half of the part-index migration as the Reader sees it: while the Editor is reconciling the stored layer,
/// this process must not write one — and once it has, this process has to drop the copy it is holding and re-read.
///
/// The same shape as `ReaderViewModelPartRemapReloadTests` does for the preferences row, with one difference that
/// matters: a capture arriving inside the hold window is DROPPED rather than queued, because it is the whole canvas
/// re-anchored against a layout that was still showing the ink through pre-migration anchors.
@MainActor
struct ReaderAnnotationPartRemapTests {
    /// In-memory `AnnotationBlobStore` with an injectable read failure, so the re-seed's refusal path can be driven.
    private final class FakeStore: AnnotationBlobStore, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Domain.ScoreItemID: Data] = [:]
        private var _saveCount = 0
        private var _loadError: Error?

        var saveCount: Int {
            lock.withLock { _saveCount }
        }

        var loadError: Error? {
            get { lock.withLock { _loadError } }
            set { lock.withLock { _loadError = newValue } }
        }

        func put(_ payload: Data, for id: Domain.ScoreItemID) {
            lock.withLock { stored[id] = payload }
        }

        func payload(for id: Domain.ScoreItemID) -> Data? {
            lock.withLock { stored[id] }
        }

        func load(scoreID: Domain.ScoreItemID) throws -> Data? {
            try lock.withLock {
                if let error = _loadError {
                    throw error
                }
                return stored[scoreID]
            }
        }

        func save(scoreID: Domain.ScoreItemID, updatedAt _: Date, payload: Data) throws {
            lock.withLock { _saveCount += 1; stored[scoreID] = payload }
        }

        func delete(scoreID: Domain.ScoreItemID) throws {
            lock.withLock { _saveCount += 1; stored[scoreID] = nil }
        }
    }

    private func makeItem() -> ScoreItem {
        ScoreItem(
            title: "Test", composer: nil, instrumentationSummary: nil,
            localFileName: "test.mscx", contentHash: "hash",
            sizeBytes: 0, lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
    }

    private func makeVM(item: ScoreItem, store: FakeStore) -> ReaderViewModel {
        ReaderViewModel(
            scoreItem: item,
            repository: FakeScoreLibraryRepository(),
            gateway: FakeScoreFileGateway(),
            annotationCoordinator: AnnotationSaveCoordinator(store: store),
            scoresDirectory: URL(filePath: "/tmp"),
        )
    }

    private func stroke(part: Int, staff: Int = 0, byte: UInt8 = 0xAB) -> DrawingAnchor {
        DrawingAnchor(
            kind: .musical(MusicalAnchor(
                measureIndex: 1, tickInMeasure: 0, partIndex: part, staffIndexInPart: staff,
                dxSp: 0, verticalOffsetSp: 0,
            )),
            encodedDrawing: Data([byte]),
        )
    }

    private func partIndices(_ drawings: [DrawingAnchor]) -> [Int] {
        drawings.compactMap {
            guard case let .musical(anchor) = $0.kind else { return nil }
            return anchor.partIndex
        }
    }

    // MARK: - The hold

    /// The corrupting write. A capture taken while the migration is unsettled describes the wrong staves whichever
    /// numbering it happens to be in, so it never reaches the store — and never displaces the model either.
    @Test func `a capture arriving while a migration is unsettled is dropped`() async {
        let item = makeItem()
        let store = FakeStore()
        let original = [stroke(part: 2, staff: 1)]
        store.put(AnnotationLayerCodec.encode(drawings: original, textBoxes: []), for: item.id)
        let vm = makeVM(item: item, store: store)
        await vm.loadAnnotations()
        vm.setPartMigrationPendingProvider { true }

        vm.annotationDrawingsDidChange([stroke(part: 0, byte: 0xEE)])
        await vm.flushPendingAnnotationSave()

        #expect(store.saveCount == 0)
        #expect(vm.annotationDrawings == original)
    }

    @Test func `a capture is persisted again once the hold is down`() async {
        let item = makeItem()
        let store = FakeStore()
        let vm = makeVM(item: item, store: store)
        var isPending = true
        vm.setPartMigrationPendingProvider { isPending }

        vm.annotationDrawingsDidChange([stroke(part: 0)])
        await vm.flushPendingAnnotationSave()
        #expect(store.saveCount == 0)

        isPending = false
        vm.annotationDrawingsDidChange([stroke(part: 0)])
        await vm.flushPendingAnnotationSave()
        #expect(store.saveCount == 1)
    }

    // MARK: - The re-seed

    /// The covering scenario from the Reader's side: the Editor has rewritten the layer under this process, and the
    /// reload has to pick THAT up rather than keep projecting the anchors it loaded the score with.
    @Test func `the reload re-seeds the ink from the migrated layer`() async {
        let item = makeItem()
        let store = FakeStore()
        store.put(
            AnnotationLayerCodec.encode(
                drawings: [stroke(part: 0), stroke(part: 2, staff: 1)], textBoxes: [],
            ),
            for: item.id,
        )
        let vm = makeVM(item: item, store: store)
        await vm.loadAnnotations()
        #expect(partIndices(vm.annotationDrawings) == [0, 2])
        let ticketBefore = vm.annotationReseedTicket

        // What the Editor's save does to the store while this process holds the pre-migration copy.
        store.put(
            AnnotationLayerCodec.encode(
                drawings: AnnotationLayers.remappingParts([0: nil, 1: 0, 2: 1], in: vm.annotationDrawings),
                textBoxes: [],
            ),
            for: item.id,
        )

        await vm.reloadPreferencesAfterPartRemap(authoredHiddenStaves: []) { true }

        #expect(partIndices(vm.annotationDrawings) == [1])
        // And the canvas is asked to reproject: the model moved under it, which no other trigger would catch.
        #expect(vm.annotationReseedTicket == ticketBefore + 1)
    }

    /// A layer the migration emptied (every stroke belonged to the removed part) is DELETED, and the re-seed has to
    /// accept that as the answer — the ink really is gone with the instrument.
    @Test func `a layer the migration emptied re-seeds as no ink`() async {
        let item = makeItem()
        let store = FakeStore()
        store.put(AnnotationLayerCodec.encode(drawings: [stroke(part: 0)], textBoxes: []), for: item.id)
        let vm = makeVM(item: item, store: store)
        await vm.loadAnnotations()

        try? store.delete(scoreID: item.id)
        await vm.reloadPreferencesAfterPartRemap(authoredHiddenStaves: []) { true }

        #expect(vm.annotationDrawings.isEmpty)
    }

    /// The one this exists for. A failed read must NOT be taken for "no ink": overwriting the live model with an
    /// empty set would make the next capture persist that emptiness and delete the score's ink for good.
    @Test func `a failed re-read leaves the ink alone`() async {
        let item = makeItem()
        let store = FakeStore()
        let original = [stroke(part: 2, staff: 1)]
        store.put(AnnotationLayerCodec.encode(drawings: original, textBoxes: []), for: item.id)
        let vm = makeVM(item: item, store: store)
        await vm.loadAnnotations()
        let ticketBefore = vm.annotationReseedTicket

        store.loadError = DomainError.persistenceFailed(reason: "boom")
        await vm.reloadPreferencesAfterPartRemap(authoredHiddenStaves: []) { true }

        #expect(vm.annotationDrawings == original)
        #expect(vm.annotationReseedTicket == ticketBefore)
    }
}

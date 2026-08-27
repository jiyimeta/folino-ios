import Domain // re-exports SheetMusicCore
@testable import Editor
import Foundation
import Testing

/// The ink half of the part-index problem. Every annotation stroke is pinned to a `MusicalAnchor` that names its staff
/// by part INDEX, so a part add / remove / reorder renumbers it exactly as it renumbers the preferences row — and the
/// same save choke point reconciles both, through one mapping consumed once. See
/// `EditorViewModel.migratePartIndexedState`.
@MainActor
@Suite("Editor annotation migration")
struct EditorAnnotationMigrationTests {
    private func makeTempScoresDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "editor-ink-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeViewModel(
        item: ScoreItem,
        directory: URL,
        repository: FakeScoreLibraryRepository,
        annotations: FakeAnnotationBlobStore,
    ) -> EditorViewModel {
        EditorViewModel(
            scoreItem: item,
            scoresDirectory: directory,
            gateway: FakeScoreFileGateway(),
            repository: repository,
            originalStore: FakeScoreOriginalStore(),
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
            annotationStore: annotations,
        )
    }

    private func stroke(part: Int, staff: Int = 0, byte: UInt8 = 0xAB) -> DrawingAnchor {
        DrawingAnchor(
            kind: .musical(MusicalAnchor(
                measureIndex: 2, tickInMeasure: 0, partIndex: part, staffIndexInPart: staff,
                dxSp: 0, verticalOffsetSp: -3,
            )),
            encodedDrawing: Data([byte]),
        )
    }

    private func storedStrokes(
        _ store: FakeAnnotationBlobStore, for id: Domain.ScoreItemID,
    ) -> [DrawingAnchor] {
        guard let data = store.payloads[id], let decoded = AnnotationLayerCodec.decode(data) else { return [] }
        return decoded.drawings
    }

    private func partIndices(_ drawings: [DrawingAnchor]) -> [Int] {
        drawings.compactMap {
            guard case let .musical(anchor) = $0.kind else { return nil }
            return anchor.partIndex
        }
    }

    // MARK: - The covering scenario

    /// A stroke on the piano's lower staff (part 2, staff 1) has to end up on part 1, staff 1 once the part above it
    /// is deleted — and the deleted part's own ink has to go with it.
    @Test func `ink below a removed part follows it to the new index`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let annotations = FakeAnnotationBlobStore()
        let item = EditorFixtures.sampleItem()
        annotations.payloads[item.id] = AnnotationLayerCodec.encode(
            drawings: [stroke(part: 0, byte: 0x01), stroke(part: 1, byte: 0x02), stroke(part: 2, staff: 1, byte: 0x03)],
            textBoxes: [],
        )
        let vm = makeViewModel(item: item, directory: dir, repository: repository, annotations: annotations)
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        vm.removePart(at: 0)
        await vm.partEditCommitTask?.value

        let migrated = storedStrokes(annotations, for: item.id)
        #expect(partIndices(migrated) == [0, 1])
        // The bytes ride through, so a migrated stroke is the SAME stroke — and the one on the removed part is gone.
        #expect(migrated.map(\.encodedDrawing) == [Data([0x02]), Data([0x03])])
        guard case let .musical(piano) = migrated[1].kind else {
            Issue.record("expected a musical anchor")
            return
        }
        #expect(piano.staffIndexInPart == 1)
    }

    @Test func `a reorder moves the ink with its part`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let annotations = FakeAnnotationBlobStore()
        let item = EditorFixtures.sampleItem()
        annotations.payloads[item.id] = AnnotationLayerCodec.encode(
            drawings: [stroke(part: 0)], textBoxes: [],
        )
        let vm = makeViewModel(item: item, directory: dir, repository: repository, annotations: annotations)
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"]))

        // Drag the first row to the end (`toOffset` is a gap index against the pre-move array).
        vm.movePart(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        await vm.partEditCommitTask?.value

        #expect(partIndices(storedStrokes(annotations, for: item.id)) == [2])
    }

    /// Ink on the only part that is removed leaves nothing to store, and an empty layer is deleted rather than
    /// written — the same empty→delete policy `AnnotationSaveCoordinator` applies on the Reader side.
    @Test func `a removal that empties the layer deletes it`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let annotations = FakeAnnotationBlobStore()
        let item = EditorFixtures.sampleItem()
        annotations.payloads[item.id] = AnnotationLayerCodec.encode(drawings: [stroke(part: 0)], textBoxes: [])
        let vm = makeViewModel(item: item, directory: dir, repository: repository, annotations: annotations)
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin"]))

        vm.removePart(at: 0)
        await vm.partEditCommitTask?.value

        #expect(annotations.deleted == [item.id])
        #expect(annotations.payloads[item.id] == nil)
    }

    /// An item read out of a PDF carries page-anchored ink in the same array. A PDF page has no parts, so that half
    /// must survive a part removal untouched — dropping it would delete the original rendition's annotations.
    @Test func `page-anchored ink survives a part removal`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let annotations = FakeAnnotationBlobStore()
        let item = EditorFixtures.sampleItem()
        let page = DrawingAnchor(kind: .page(PageAnchor(pageIndex: 1)), encodedDrawing: Data([0x09]))
        annotations.payloads[item.id] = AnnotationLayerCodec.encode(
            drawings: [stroke(part: 0), page], textBoxes: [],
        )
        let vm = makeViewModel(item: item, directory: dir, repository: repository, annotations: annotations)
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin"]))

        vm.removePart(at: 0)
        await vm.partEditCommitTask?.value

        let migrated = storedStrokes(annotations, for: item.id)
        #expect(migrated.count == 1)
        #expect(migrated.first?.kind == .page(PageAnchor(pageIndex: 1)))
    }

    /// Ink that a part operation cannot move is not rewritten at all: bumping the layer's `updated_at` on every
    /// instrument added would tell the sync something changed when nothing did.
    @Test func `an all-page-anchored layer is left byte-identical`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let annotations = FakeAnnotationBlobStore()
        let item = EditorFixtures.sampleItem()
        let original = AnnotationLayerCodec.encode(
            drawings: [DrawingAnchor(kind: .page(PageAnchor(pageIndex: 0)), encodedDrawing: Data([0x07]))],
            textBoxes: [],
        )
        annotations.payloads[item.id] = original
        let vm = makeViewModel(item: item, directory: dir, repository: repository, annotations: annotations)
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin"]))

        vm.removePart(at: 0)
        await vm.partEditCommitTask?.value

        #expect(annotations.saveCount == 0)
        #expect(annotations.deleted.isEmpty)
        #expect(annotations.payloads[item.id] == original)
    }

    // MARK: - When the migration must NOT run

    @Test func `a note edit alone leaves the ink untouched`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let annotations = FakeAnnotationBlobStore()
        let item = EditorFixtures.sampleItem()
        let original = AnnotationLayerCodec.encode(drawings: [stroke(part: 0)], textBoxes: [])
        annotations.payloads[item.id] = original
        let vm = makeViewModel(item: item, directory: dir, repository: repository, annotations: annotations)
        vm.beginSession(score: EditorFixtures.fourQuarterRests())

        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))
        await vm.flushPendingSave()

        #expect(annotations.saveCount == 0)
        #expect(annotations.payloads[item.id] == original)
    }

    /// A score that was never annotated has no layer at all. That is not a failure — the mapping is still consumed
    /// (the preferences half did its work), and nothing is written where there was nothing.
    @Test func `a score with no ink still migrates its preferences and consumes the mapping`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let annotations = FakeAnnotationBlobStore()
        let item = EditorFixtures.sampleItem()
        repository.readerPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, hiddenStaves: [StaffAddress(partIndex: 2, staffIndexInPart: 1)],
        )
        let vm = makeViewModel(item: item, directory: dir, repository: repository, annotations: annotations)
        var notified: [[Int: Int?]?] = []
        vm.onPartIndicesRemapped = { notified.append($0) }
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        vm.removePart(at: 0)
        await vm.partEditCommitTask?.value

        #expect(annotations.saveCount == 0)
        #expect(annotations.deleted.isEmpty)
        let migrated = try #require(repository.readerPreferences[item.id])
        #expect(migrated.hiddenStaves == [StaffAddress(partIndex: 1, staffIndexInPart: 1)])
        #expect(notified == [[0: nil, 1: 0, 2: 1]])
        // Consumed: a second save must not migrate the row a second time.
        vm.markDirtyForTesting()
        await vm.flushPendingSave()
        let again = try #require(repository.readerPreferences[item.id])
        #expect(again.hiddenStaves == [StaffAddress(partIndex: 1, staffIndexInPart: 1)])
    }

    // MARK: - Failure policy: the two halves settle together or not at all

    /// The mapping is consumed once for BOTH halves, so a failed ink write must leave the preferences row exactly as
    /// it was — otherwise the retry would remap the row a second time and point every setting at the wrong part.
    @Test func `a failed ink write rolls the preferences row back and retries whole`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let annotations = FakeAnnotationBlobStore()
        let item = EditorFixtures.sampleItem()
        repository.readerPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, hiddenStaves: [StaffAddress(partIndex: 2, staffIndexInPart: 1)],
        )
        annotations.payloads[item.id] = AnnotationLayerCodec.encode(
            drawings: [stroke(part: 2, staff: 1)], textBoxes: [],
        )
        annotations.saveError = DomainError.persistenceFailed(reason: "disk full")
        let vm = makeViewModel(item: item, directory: dir, repository: repository, annotations: annotations)
        var notified: [[Int: Int?]?] = []
        vm.onPartIndicesRemapped = { notified.append($0) }
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        vm.removePart(at: 0)
        await vm.partEditCommitTask?.value

        // Nothing settled: the row is back in the numbering it was written in, and the host is told nothing landed.
        let rolledBack = try #require(repository.readerPreferences[item.id])
        #expect(rolledBack.hiddenStaves == [StaffAddress(partIndex: 2, staffIndexInPart: 1)])
        #expect(notified == [nil])

        // With the store healthy again, the next save completes BOTH halves exactly once.
        annotations.saveError = nil
        vm.markDirtyForTesting()
        await vm.flushPendingSave()
        let migrated = try #require(repository.readerPreferences[item.id])
        #expect(migrated.hiddenStaves == [StaffAddress(partIndex: 1, staffIndexInPart: 1)])
        #expect(partIndices(storedStrokes(annotations, for: item.id)) == [1])
    }

    /// The mirror case: the preferences write is what fails, so the ink must not be migrated either.
    @Test func `a failed preferences write leaves the ink alone`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let annotations = FakeAnnotationBlobStore()
        let item = EditorFixtures.sampleItem()
        repository.readerPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, hiddenStaves: [StaffAddress(partIndex: 2, staffIndexInPart: 1)],
        )
        repository.readerPreferencesSaveError = DomainError.persistenceFailed(reason: "disk full")
        let original = AnnotationLayerCodec.encode(drawings: [stroke(part: 2, staff: 1)], textBoxes: [])
        annotations.payloads[item.id] = original
        let vm = makeViewModel(item: item, directory: dir, repository: repository, annotations: annotations)
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        vm.removePart(at: 0)
        await vm.partEditCommitTask?.value

        #expect(annotations.saveCount == 0)
        #expect(annotations.payloads[item.id] == original)
    }

    /// An unreadable payload is not an I/O failure and no retry will fix it — the Reader's own loader already treats
    /// it as "no ink". Blocking the mapping on it would strand the preferences row in the old numbering for good.
    @Test func `an unreadable payload does not block the mapping`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let annotations = FakeAnnotationBlobStore()
        let item = EditorFixtures.sampleItem()
        repository.readerPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id, hiddenStaves: [StaffAddress(partIndex: 2, staffIndexInPart: 1)],
        )
        annotations.payloads[item.id] = Data("not a layer".utf8)
        let vm = makeViewModel(item: item, directory: dir, repository: repository, annotations: annotations)
        var notified: [[Int: Int?]?] = []
        vm.onPartIndicesRemapped = { notified.append($0) }
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        vm.removePart(at: 0)
        await vm.partEditCommitTask?.value

        #expect(notified == [[0: nil, 1: 0, 2: 1]])
        let migrated = try #require(repository.readerPreferences[item.id])
        #expect(migrated.hiddenStaves == [StaffAddress(partIndex: 1, staffIndexInPart: 1)])
        // Left exactly as found: rewriting bytes we could not read would be a guess.
        #expect(annotations.payloads[item.id] == Data("not a layer".utf8))
    }

    // MARK: - Ordering: the host drains its own writer before the migration reads

    /// The Reader's annotation writes are debounced, so one registered just before the part edit can still be in the
    /// air. It has to land BEFORE the migration reads — landing after would overwrite the migrated layer with the old
    /// numbering, and the mapping is consumed by then. The commit awaits the host's drain for exactly that reason.
    @Test func `the host drains before the migration reads`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let annotations = FakeAnnotationBlobStore()
        let item = EditorFixtures.sampleItem()
        let vm = makeViewModel(item: item, directory: dir, repository: repository, annotations: annotations)
        var order: [String] = []
        vm.onPartMigrationWillRun = {
            order.append("drain")
            annotations.payloads[item.id] = AnnotationLayerCodec.encode(
                drawings: [stroke(part: 2, staff: 1)], textBoxes: [],
            )
        }
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        vm.removePart(at: 0)
        await vm.partEditCommitTask?.value
        order.append("settled")

        #expect(order == ["drain", "settled"])
        // The drain's own write is what got migrated, which is the whole point of awaiting it.
        #expect(partIndices(storedStrokes(annotations, for: item.id)) == [1])
    }
}

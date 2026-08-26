import Domain // re-exports SheetMusicCore
@testable import Editor
import Foundation
import Testing

/// The durable half of the part-index problem: `ReaderPreferences` keys everything the reader sets per staff or per
/// mixer strip by part INDEX, and adding / removing / reordering a part renumbers those indices in the file. The save
/// choke point is where the two are reconciled — see `EditorViewModel.migratePartIndexedPreferences`.
@MainActor
@Suite("Editor preference migration")
struct EditorPreferenceMigrationTests {
    private func makeTempScoresDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "editor-prefs-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeViewModel(
        item: ScoreItem,
        directory: URL,
        repository: FakeScoreLibraryRepository,
    ) -> EditorViewModel {
        EditorViewModel(
            scoreItem: item,
            scoresDirectory: directory,
            gateway: FakeScoreFileGateway(),
            repository: repository,
            originalStore: FakeScoreOriginalStore(),
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
        )
    }

    /// A three-part score whose last part is a piano (two staves), with the piano's LOWER staff hidden and a volume
    /// set on its strip — the exact shape Task 11's review named as the corruption case.
    private func pianoPreferences(for id: Domain.ScoreItemID) -> ReaderPreferences {
        ReaderPreferences(
            scoreItemID: id,
            hiddenStaves: [StaffAddress(partIndex: 2, staffIndexInPart: 1)],
            stripVolumeOverrides: [MixerStripID(partIndex: 2, instrumentOrdinal: 0): 0.4],
            staffClefOverrides: [StaffAddress(partIndex: 2, staffIndexInPart: 1): "F"],
        )
    }

    // MARK: - The Task 11 scenario, end to end at the save seam

    @Test func `deleting a part above the piano follows its hidden staff to the new index`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let item = EditorFixtures.sampleItem()
        repository.readerPreferences[item.id] = pianoPreferences(for: item.id)
        let vm = makeViewModel(item: item, directory: dir, repository: repository)
        var notified: [[Int: Int?]] = []
        vm.onPartIndicesRemapped = { notified.append($0) }
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        vm.removePart(at: 0)
        await vm.flushPendingSave()

        let migrated = try #require(repository.readerPreferences[item.id])
        #expect(migrated.hiddenStaves == [StaffAddress(partIndex: 1, staffIndexInPart: 1)])
        #expect(migrated.stripVolumeOverrides == [MixerStripID(partIndex: 1, instrumentOrdinal: 0): 0.4])
        #expect(migrated.staffClefOverrides == [StaffAddress(partIndex: 1, staffIndexInPart: 1): "F"])
        let mapping = try #require(notified.first)
        #expect(notified.count == 1)
        #expect(mapping == [0: nil, 1: 0, 2: 1])
    }

    @Test func `rows belonging to the removed part are dropped`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let item = EditorFixtures.sampleItem()
        repository.readerPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id,
            hiddenStaves: [StaffAddress(partIndex: 0, staffIndexInPart: 0)],
            stripProgramOverrides: [MixerStripID(partIndex: 0, instrumentOrdinal: 0): 40],
        )
        let vm = makeViewModel(item: item, directory: dir, repository: repository)
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin"]))

        vm.removePart(at: 0)
        await vm.flushPendingSave()

        let migrated = try #require(repository.readerPreferences[item.id])
        #expect(migrated.hiddenStaves.isEmpty)
        #expect(migrated.stripProgramOverrides.isEmpty)
    }

    @Test func `a reorder rides the permutation`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let item = EditorFixtures.sampleItem()
        repository.readerPreferences[item.id] = ReaderPreferences(
            scoreItemID: item.id,
            hiddenStaves: [StaffAddress(partIndex: 0, staffIndexInPart: 0)],
        )
        let vm = makeViewModel(item: item, directory: dir, repository: repository)
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"]))

        // Drag the first row to the end: `toOffset` is a gap index against the pre-move array, so 3 means "after
        // the last row" — part 0 lands on index 2.
        vm.movePart(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        await vm.flushPendingSave()

        let migrated = try #require(repository.readerPreferences[item.id])
        #expect(migrated.hiddenStaves == [StaffAddress(partIndex: 2, staffIndexInPart: 0)])
    }

    // MARK: - When the migration must NOT run

    @Test func `a note edit alone writes no preferences and notifies nobody`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let item = EditorFixtures.sampleItem()
        let original = pianoPreferences(for: item.id)
        repository.readerPreferences[item.id] = original
        let vm = makeViewModel(item: item, directory: dir, repository: repository)
        var notified = 0
        vm.onPartIndicesRemapped = { _ in notified += 1 }
        vm.beginSession(score: EditorFixtures.fourQuarterRests())

        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))
        await vm.flushPendingSave()

        #expect(repository.savedReaderPreferences.isEmpty)
        #expect(repository.readerPreferences[item.id] == original)
        #expect(notified == 0)
    }

    /// Appending a part renumbers nothing the baseline knew about, so `isPartMappingIdentity` stays true and the row
    /// is left alone — a rewrite there would be a no-op write on every instrument added.
    @Test func `appending a part leaves the row untouched`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let item = EditorFixtures.sampleItem()
        repository.readerPreferences[item.id] = pianoPreferences(for: item.id)
        let vm = makeViewModel(item: item, directory: dir, repository: repository)
        var notified = 0
        vm.onPartIndicesRemapped = { _ in notified += 1 }
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        vm.addPart(EditorFixtures.partPlan(named: "Cello"))
        await vm.flushPendingSave()

        #expect(repository.savedReaderPreferences.isEmpty)
        #expect(notified == 0)
    }

    /// A part removed and put back by undo maps to itself, because the map is derived by diffing `Part.id`s.
    @Test func `undoing the removal makes the mapping identity again`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let item = EditorFixtures.sampleItem()
        let original = pianoPreferences(for: item.id)
        repository.readerPreferences[item.id] = original
        let vm = makeViewModel(item: item, directory: dir, repository: repository)
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        vm.removePart(at: 0)
        vm.undo()
        await vm.flushPendingSave()

        #expect(repository.savedReaderPreferences.isEmpty)
        #expect(repository.readerPreferences[item.id] == original)
    }

    // MARK: - Consumption

    @Test func `the mapping is consumed so the next save does not migrate twice`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let item = EditorFixtures.sampleItem()
        repository.readerPreferences[item.id] = pianoPreferences(for: item.id)
        let vm = makeViewModel(item: item, directory: dir, repository: repository)
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        vm.removePart(at: 0)
        await vm.flushPendingSave()
        #expect(repository.savedReaderPreferences.count == 1)

        // A later, part-unrelated edit must not move the addresses a second time.
        vm.apply(.inputNote(at: EditorFixtures.restID(part: 0, element: 1), pitch: 60, tpc: 14, duration: nil))
        await vm.flushPendingSave()

        #expect(repository.savedReaderPreferences.count == 1)
        let migrated = try #require(repository.readerPreferences[item.id])
        #expect(migrated.hiddenStaves == [StaffAddress(partIndex: 1, staffIndexInPart: 1)])
    }

    /// No row at all is still a consume point: nothing to migrate, and leaving the map unconsumed would make the
    /// NEXT part operation report a stale cumulative map against a row written since.
    @Test func `no stored row still consumes and still notifies`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let item = EditorFixtures.sampleItem()
        let vm = makeViewModel(item: item, directory: dir, repository: repository)
        var notified: [[Int: Int?]] = []
        vm.onPartIndicesRemapped = { notified.append($0) }
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin"]))

        vm.removePart(at: 0)
        await vm.flushPendingSave()

        #expect(repository.savedReaderPreferences.isEmpty)
        #expect(notified.count == 1)
        #expect(vm.session?.isPartMappingIdentity == true)
    }

    @Test func `a failed preferences write leaves the mapping for the next save`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let item = EditorFixtures.sampleItem()
        repository.readerPreferences[item.id] = pianoPreferences(for: item.id)
        repository.readerPreferencesSaveError = DomainError.persistenceFailed(reason: "boom")
        let vm = makeViewModel(item: item, directory: dir, repository: repository)
        var notified = 0
        vm.onPartIndicesRemapped = { _ in notified += 1 }
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        vm.removePart(at: 0)
        await vm.flushPendingSave()

        #expect(notified == 0)
        #expect(vm.session?.isPartMappingIdentity == false)
        // The row is untouched — the failed write never landed.
        #expect(repository.readerPreferences[item.id]?.hiddenStaves == [
            StaffAddress(partIndex: 2, staffIndexInPart: 1),
        ])

        // The next save retries with the same cumulative map, and now succeeds.
        repository.readerPreferencesSaveError = nil
        vm.apply(.inputNote(at: EditorFixtures.restID(part: 0, element: 1), pitch: 60, tpc: 14, duration: nil))
        await vm.flushPendingSave()

        #expect(notified == 1)
        let migrated = try #require(repository.readerPreferences[item.id])
        #expect(migrated.hiddenStaves == [StaffAddress(partIndex: 1, staffIndexInPart: 1)])
    }
}

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
        originalStore: FakeScoreOriginalStore = FakeScoreOriginalStore(),
    ) -> EditorViewModel {
        EditorViewModel(
            scoreItem: item,
            scoresDirectory: directory,
            gateway: FakeScoreFileGateway(),
            repository: repository,
            originalStore: originalStore,
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
        var notified: [[Int: Int?]?] = []
        vm.onPartIndicesRemapped = { notified.append($0) }
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        vm.removePart(at: 0)
        await vm.partEditCommitTask?.value

        let migrated = try #require(repository.readerPreferences[item.id])
        #expect(migrated.hiddenStaves == [StaffAddress(partIndex: 1, staffIndexInPart: 1)])
        #expect(migrated.stripVolumeOverrides == [MixerStripID(partIndex: 1, instrumentOrdinal: 0): 0.4])
        #expect(migrated.staffClefOverrides == [StaffAddress(partIndex: 1, staffIndexInPart: 1): "F"])
        #expect(notified.count == 1)
        let mapping = try #require(notified.first)
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
        await vm.partEditCommitTask?.value

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
        await vm.partEditCommitTask?.value

        let migrated = try #require(repository.readerPreferences[item.id])
        #expect(migrated.hiddenStaves == [StaffAddress(partIndex: 2, staffIndexInPart: 0)])
    }

    // MARK: - The hold (review Critical 1)

    /// A part op must not ride the two-second debounce. The window between the edit and the migration is one the
    /// Reader may not write the row in, so it has to be as short as a save — not as long as a debounce.
    @Test func `a part op writes immediately instead of waiting for the debounce`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let item = EditorFixtures.sampleItem()
        repository.readerPreferences[item.id] = pianoPreferences(for: item.id)
        let vm = makeViewModel(item: item, directory: dir, repository: repository)
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        vm.removePart(at: 0)
        // NO explicit flush: joining the op's own commit is the whole point.
        await vm.partEditCommitTask?.value

        #expect(repository.savedScoreItems.count == 1)
        #expect(repository.readerPreferences[item.id]?.hiddenStaves == [
            StaffAddress(partIndex: 1, staffIndexInPart: 1),
        ])
    }

    @Test func `the hold is raised at the op and lowered when its save settles`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let item = EditorFixtures.sampleItem()
        repository.readerPreferences[item.id] = pianoPreferences(for: item.id)
        let vm = makeViewModel(item: item, directory: dir, repository: repository)
        var holds: [Bool] = []
        vm.onPartMappingPendingChanged = { holds.append($0) }
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        vm.removePart(at: 0)
        #expect(holds == [true])
        await vm.partEditCommitTask?.value

        #expect(holds == [true, false])
    }

    /// Overlapping part ops nest. The first op's settle must not lift the hold while a second op's numbering is
    /// still unreconciled — hence a count rather than a flag.
    @Test func `overlapping part ops keep the hold up until the last one settles`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let item = EditorFixtures.sampleItem()
        let vm = makeViewModel(item: item, directory: dir, repository: repository)
        var holds: [Bool] = []
        vm.onPartMappingPendingChanged = { holds.append($0) }
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"]))

        vm.removePart(at: 0)
        vm.removePart(at: 0)
        // Exactly one raise for the two edits, and nothing lowered yet.
        #expect(holds == [true])

        await vm.partEditCommitTask?.value

        #expect(holds == [true, false])
    }

    /// The hold has to come down even when the save did nothing at all, or the Reader would never write again.
    @Test func `the hold is lowered even when the save declines to run`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let vm = makeViewModel(item: EditorFixtures.sampleItem(), directory: dir, repository: repository)
        var holds: [Bool] = []
        var settled: [Bool] = []
        vm.onPartMappingPendingChanged = { holds.append($0) }
        vm.onPartIndicesRemapped = { settled.append($0 != nil) }
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin"]))
        // A revert in progress makes `performSave` return at its entry guard — the save runs, writes nothing, and
        // the settle still has to happen.
        vm.isReverting = true

        vm.removePart(at: 0)
        await vm.partEditCommitTask?.value

        #expect(holds == [true, false])
        #expect(settled == [false])
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
        var holds = 0
        vm.onPartIndicesRemapped = { _ in notified += 1 }
        vm.onPartMappingPendingChanged = { _ in holds += 1 }
        vm.beginSession(score: EditorFixtures.fourQuarterRests())

        vm.apply(.inputNote(at: EditorFixtures.restID(element: 1), pitch: 60, tpc: 14, duration: nil))
        await vm.flushPendingSave()

        #expect(repository.savedReaderPreferences.isEmpty)
        #expect(repository.readerPreferences[item.id] == original)
        #expect(notified == 0)
        #expect(holds == 0)
    }

    /// Appending a part renumbers nothing the baseline knew about, so `isPartMappingIdentity` stays true and the row
    /// is left alone — a rewrite there would be a no-op write on every instrument added. The hold still cycles, and
    /// the settle still fires with no mapping, because the Reader has to be released either way.
    @Test func `appending a part leaves the row untouched`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let item = EditorFixtures.sampleItem()
        repository.readerPreferences[item.id] = pianoPreferences(for: item.id)
        let vm = makeViewModel(item: item, directory: dir, repository: repository)
        var settled: [Bool] = []
        var holds: [Bool] = []
        vm.onPartIndicesRemapped = { settled.append($0 != nil) }
        vm.onPartMappingPendingChanged = { holds.append($0) }
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        vm.addPart(EditorFixtures.partPlan(named: "Cello"))
        await vm.partEditCommitTask?.value

        #expect(repository.savedReaderPreferences.isEmpty)
        #expect(settled == [false])
        #expect(holds == [true, false])
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
        await vm.partEditCommitTask?.value
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
        await vm.partEditCommitTask?.value
        #expect(repository.savedReaderPreferences.count == 1)

        // A later, part-unrelated edit must not move the addresses a second time.
        vm.apply(.inputNote(at: EditorFixtures.restID(part: 0, element: 1), pitch: 60, tpc: 14, duration: nil))
        await vm.flushPendingSave()

        #expect(repository.savedReaderPreferences.count == 1)
        let migrated = try #require(repository.readerPreferences[item.id])
        #expect(migrated.hiddenStaves == [StaffAddress(partIndex: 1, staffIndexInPart: 1)])
    }

    /// No row at all is still a consume point: nothing to migrate, and leaving the map unconsumed would make the
    /// NEXT part operation report a stale cumulative map against a row written since. Nothing was written, so the
    /// settle carries no mapping — the host has nothing to re-read, only a hold to drop.
    @Test func `no stored row still consumes and still settles`() async {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let item = EditorFixtures.sampleItem()
        let vm = makeViewModel(item: item, directory: dir, repository: repository)
        var settled: [Bool] = []
        vm.onPartIndicesRemapped = { settled.append($0 != nil) }
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin"]))

        vm.removePart(at: 0)
        await vm.partEditCommitTask?.value

        #expect(repository.savedReaderPreferences.isEmpty)
        #expect(settled == [false])
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
        var settled: [Bool] = []
        vm.onPartIndicesRemapped = { settled.append($0 != nil) }
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        vm.removePart(at: 0)
        await vm.partEditCommitTask?.value

        // Settled (the hold must lift) but with nothing to re-read, and the map is still standing.
        #expect(settled == [false])
        #expect(vm.session?.isPartMappingIdentity == false)
        #expect(repository.readerPreferences[item.id]?.hiddenStaves == [
            StaffAddress(partIndex: 2, staffIndexInPart: 1),
        ])

        // The next save retries with the same cumulative map, and now succeeds.
        repository.readerPreferencesSaveError = nil
        vm.apply(.inputNote(at: EditorFixtures.restID(part: 0, element: 1), pitch: 60, tpc: 14, duration: nil))
        await vm.flushPendingSave()

        let migrated = try #require(repository.readerPreferences[item.id])
        #expect(migrated.hiddenStaves == [StaffAddress(partIndex: 1, staffIndexInPart: 1)])
    }

    /// A failed prefs write is retried once more as the session ends. `performSave` leaves the map standing on the
    /// assumption that a later save will pick it up — but the score write succeeded, so `isDirty` is false and
    /// there may never be one. Dropping the session would strand the row in the old numbering for good
    /// (review Important 3).
    @Test func `ending the session retries a preferences write that failed`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let item = EditorFixtures.sampleItem()
        repository.readerPreferences[item.id] = pianoPreferences(for: item.id)
        repository.readerPreferencesSaveError = DomainError.persistenceFailed(reason: "boom")
        let vm = makeViewModel(item: item, directory: dir, repository: repository)
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        vm.removePart(at: 0)
        await vm.partEditCommitTask?.value
        #expect(repository.readerPreferences[item.id]?.hiddenStaves == [
            StaffAddress(partIndex: 2, staffIndexInPart: 1),
        ])

        repository.readerPreferencesSaveError = nil
        await vm.endSession()

        let migrated = try #require(repository.readerPreferences[item.id])
        #expect(migrated.hiddenStaves == [StaffAddress(partIndex: 1, staffIndexInPart: 1)])
    }

    // MARK: - The session the migration reads (review Important 1)

    /// `performSave` pins the session at entry alongside the score. A `beginSession` landing in one of its two
    /// suspension windows installs a session whose part-id baseline is the POST-edit order — reading `self.session`
    /// at the migration would find that one, see identity, and leave the row in the numbering the file has left.
    @Test func `the migration reads the session the save started with`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let item = EditorFixtures.sampleItem()
        repository.readerPreferences[item.id] = pianoPreferences(for: item.id)
        let originalStore = FakeScoreOriginalStore()
        let gate = CaptureGate()
        originalStore.captureGate = gate
        let vm = makeViewModel(item: item, directory: dir, repository: repository, originalStore: originalStore)
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        vm.removePart(at: 0)
        // The op's own flush is now suspended inside `captureOriginalIfNeeded`, past `performSave`'s entry guard.
        await gate.waitUntilEntered()
        // A fresh session over the POST-edit parts: its baseline is [Violin, Piano], so its mapping is identity.
        vm.beginSession(score: EditorFixtures.parts(named: ["Violin", "Piano"], twoStavesAt: 1))
        await gate.open()
        await vm.partEditCommitTask?.value

        let migrated = try #require(repository.readerPreferences[item.id])
        #expect(migrated.hiddenStaves == [StaffAddress(partIndex: 1, staffIndexInPart: 1)])
    }

    /// `unwindSessionEdits`'s snapshot gear throws the session away and starts a fresh one over the session-open
    /// score. A mapping still standing at that moment is the row's only route back: the fresh session baselines on
    /// the restored parts, so it reads identity forever. Migrating before the swap is what keeps the row and the
    /// restored file in the same numbering (review Important 1).
    @Test func `the snapshot gear migrates before it replaces the session`() async throws {
        let dir = makeTempScoresDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repository = FakeScoreLibraryRepository()
        let item = EditorFixtures.sampleItem()
        repository.readerPreferences[item.id] = pianoPreferences(for: item.id)
        let vm = makeViewModel(item: item, directory: dir, repository: repository)
        vm.beginSession(score: EditorFixtures.parts(named: ["Flute", "Violin", "Piano"], twoStavesAt: 2))

        // Remove and save: the row moves to the two-part numbering and the session re-baselines onto it.
        vm.removePart(at: 0)
        await vm.partEditCommitTask?.value
        #expect(repository.readerPreferences[item.id]?.hiddenStaves == [
            StaffAddress(partIndex: 1, staffIndexInPart: 1),
        ])

        // Put the part back and leave a depth the undo stack can no longer consume — the one state the snapshot
        // gear exists for.
        vm.undo()
        vm.previewSeedSessionEdit()
        await vm.unwindSessionEdits()

        // The row is back in the three-part numbering the restored score has.
        let restored = try #require(repository.readerPreferences[item.id])
        #expect(restored.hiddenStaves == [StaffAddress(partIndex: 2, staffIndexInPart: 1)])
        #expect(vm.session?.isPartMappingIdentity == true)
    }
}

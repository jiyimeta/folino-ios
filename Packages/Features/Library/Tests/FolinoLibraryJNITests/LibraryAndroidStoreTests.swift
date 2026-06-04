@testable import FolinoLibraryJNI
import Foundation
import Testing

/// No-op export primitives so the suite can keep constructing the store with a
/// single backend argument; export routing is covered by `ExportScoreTests`.
private final class NoopPdfRenderer: ScorePdfRenderer {
    func renderPdf(_: String, _: String) -> Bool {
        false
    }
}

private final class NoopAudioExporter: ScoreAudioFileExporter {
    func exportAudio(_: String, _: String) -> Bool {
        false
    }
}

extension LibraryAndroidStore {
    /// Test convenience: construct with no-op export primitives.
    fileprivate convenience init(store: LibraryStore) {
        self.init(store: store, pdfRenderer: NoopPdfRenderer(), audioExporter: NoopAudioExporter())
    }
}

/// In-memory fake of the Kotlin/Room backend. Records the copied files so the
/// store's file-naming + copy orchestration can be asserted on the host.
private final class FakeLibraryStore: LibraryStore {
    var records: [ScoreRecordWire] = []
    var copiedFiles: [(sourcePath: String, localFileName: String)] = []
    var removedFiles: [String] = []

    func loadAll() -> [ScoreRecordWire] {
        records
    }

    func upsert(_ record: ScoreRecordWire) {
        if let idx = records.firstIndex(where: { $0.id == record.id }) {
            records[idx] = record
        } else {
            records.append(record)
        }
    }

    func copyImportedFile(fromPath sourcePath: String, localFileName: String) {
        copiedFiles.append((sourcePath, localFileName))
    }

    func removeFile(localFileName: String) {
        removedFiles.append(localFileName)
    }

    func scoresDirectoryPath() -> String {
        "/tmp"
    }

    func deleteRecord(id: String) {
        records.removeAll { $0.id == id }
    }

    var playlistRecords: [PlaylistRecordWire] = []
    var playlistItems: [PlaylistItemWire] = []

    func loadPlaylists() -> [PlaylistRecordWire] {
        playlistRecords
    }

    func loadPlaylistItems() -> [PlaylistItemWire] {
        playlistItems.sorted {
            $0.playlistId == $1.playlistId ? $0.position < $1.position : $0.playlistId < $1.playlistId
        }
    }

    func upsertPlaylist(_ record: PlaylistRecordWire) {
        if let idx = playlistRecords.firstIndex(where: { $0.id == record.id }) {
            playlistRecords[idx] = record
        } else {
            playlistRecords.append(record)
        }
    }

    func replacePlaylistItems(_ playlistId: String, _ items: [PlaylistItemWire]) {
        playlistItems.removeAll { $0.playlistId == playlistId }
        playlistItems.append(contentsOf: items)
    }

    func deletePlaylist(id: String) {
        playlistRecords.removeAll { $0.id == id }
        playlistItems.removeAll { $0.playlistId == id }
    }

    var tagRecords: [TagRecordWire] = []
    var tagItems: [TagItemWire] = []

    func loadTags() -> [TagRecordWire] {
        tagRecords
    }

    func upsertTag(_ record: TagRecordWire) {
        if let idx = tagRecords.firstIndex(where: { $0.id == record.id }) {
            tagRecords[idx] = record
        } else {
            tagRecords.append(record)
        }
    }

    func deleteTag(id: String) {
        tagRecords.removeAll { $0.id == id }
        tagItems.removeAll { $0.tagId == id }
    }

    func loadTagItems() -> [TagItemWire] {
        tagItems
    }

    func replaceTagItems(_ tagId: String, _ items: [TagItemWire]) {
        tagItems.removeAll { $0.tagId == tagId }
        tagItems.append(contentsOf: items)
    }
}

struct LibraryAndroidStoreTests {
    /// The fixture's on-disk path (importScore takes a filesystem path).
    private func samplePath() throws -> String {
        try #require(Bundle.module.url(forResource: "sample", withExtension: "mscz")).path
    }

    @Test func `init hydrates live rows from the backend`() {
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(id: "a", title: "A", subtitle: "", composer: "", localFileName: "a.mscz", deletedAt: 0),
            ScoreRecordWire(id: "b", title: "B", subtitle: "", composer: "", localFileName: "b.mscz", deletedAt: 123),
        ]
        let store = LibraryAndroidStore(store: backend)
        // Only the live row (deletedAt == 0) is displayed.
        #expect(store.scores.map(\.id) == ["a"])
    }

    @Test func `import derives fields, names the file <id>.mscz, persists a live record`() throws {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)
        try store.importScore(samplePath())

        #expect(store.scores.count == 1)
        let row = try #require(store.scores.first)
        // Title is the file name (sans extension) — matches the iOS importer,
        // NOT the score's workTitle metaTag ("アイデア#0131").
        #expect(row.title == "sample")
        #expect(row.composer == "Kiichi")

        let record = try #require(backend.records.first)
        #expect(record.deletedAt == 0)
        #expect(record.localFileName == "\(record.id).mscz")
        #expect(record.id == row.id)
        // The imported file was copied under the same name.
        #expect(backend.copiedFiles.count == 1)
        #expect(backend.copiedFiles.first?.localFileName == record.localFileName)
    }

    @Test func `delete soft-deletes: row hidden, record kept with deletedAt set, file NOT removed`() throws {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)
        try store.importScore(samplePath())
        let id = try #require(store.scores.first?.id)

        store.delete(id)

        #expect(store.scores.isEmpty) // hidden from display
        let record = try #require(backend.records.first { $0.id == id })
        #expect(record.deletedAt > 0) // soft-deleted
        #expect(backend.removedFiles.isEmpty) // file retained
    }

    @Test func `restore clears deletedAt and re-shows the row`() throws {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)
        try store.importScore(samplePath())
        let id = try #require(store.scores.first?.id)
        store.delete(id)
        #expect(store.scores.isEmpty)

        store.restore(id)

        #expect(store.scores.map(\.id) == [id])
        let record = try #require(backend.records.first { $0.id == id })
        #expect(record.deletedAt == 0)
    }

    @Test func `import of nonexistent path is ignored`() {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)
        store.importScore("/no/such/file.mscz")
        #expect(store.scores.isEmpty)
        #expect(backend.records.isEmpty)
    }

    @Test func `delete unknown id is a no-op`() {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)
        store.delete("nonexistent")
        #expect(store.scores.isEmpty)
        #expect(backend.records.isEmpty)
    }

    @Test func `deletedScores lists soft-deleted rows sorted by deletedAt descending`() {
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(
                id: "old",
                title: "Old",
                subtitle: "",
                composer: "",
                localFileName: "old.mscz",
                deletedAt: 100,
            ),
            ScoreRecordWire(
                id: "live",
                title: "Live",
                subtitle: "",
                composer: "",
                localFileName: "live.mscz",
                deletedAt: 0,
            ),
            ScoreRecordWire(
                id: "new",
                title: "New",
                subtitle: "",
                composer: "",
                localFileName: "new.mscz",
                deletedAt: 200,
            ),
        ]
        let store = LibraryAndroidStore(store: backend)
        #expect(store.scores.map(\.id) == ["live"])
        // most-recently-deleted first
        #expect(store.deletedScores.map(\.id) == ["new", "old"])
    }

    @Test func `permanentlyDelete removes the record and its file, dropping it from both lists`() {
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(id: "x", title: "X", subtitle: "", composer: "", localFileName: "x.mscz", deletedAt: 50),
        ]
        let store = LibraryAndroidStore(store: backend)
        #expect(store.deletedScores.map(\.id) == ["x"])

        store.permanentlyDelete("x")

        #expect(store.deletedScores.isEmpty)
        #expect(store.scores.isEmpty)
        #expect(backend.records.isEmpty) // record deleted
        #expect(backend.removedFiles == ["x.mscz"]) // file removed
    }

    @Test func `permanentlyDelete unknown id is a no-op`() {
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(id: "x", title: "X", subtitle: "", composer: "", localFileName: "x.mscz", deletedAt: 50),
        ]
        let store = LibraryAndroidStore(store: backend)
        store.permanentlyDelete("nope")
        #expect(backend.records.map(\.id) == ["x"])
        #expect(backend.removedFiles.isEmpty)
    }

    @Test func `restoreMany clears deletedAt for all given ids in one pass`() {
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(id: "a", title: "A", subtitle: "", composer: "", localFileName: "a.mscz", deletedAt: 10),
            ScoreRecordWire(id: "b", title: "B", subtitle: "", composer: "", localFileName: "b.mscz", deletedAt: 20),
        ]
        let store = LibraryAndroidStore(store: backend)
        #expect(store.deletedScores.count == 2)

        store.restoreMany(["a", "b"])

        #expect(store.deletedScores.isEmpty)
        #expect(Set(store.scores.map(\.id)) == ["a", "b"])
        #expect(backend.records.allSatisfy { $0.deletedAt == 0 })
    }

    @Test func `permanentlyDeleteMany purges all given ids and their files`() {
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(id: "a", title: "A", subtitle: "", composer: "", localFileName: "a.mscz", deletedAt: 10),
            ScoreRecordWire(id: "b", title: "B", subtitle: "", composer: "", localFileName: "b.mscz", deletedAt: 20),
            ScoreRecordWire(id: "c", title: "C", subtitle: "", composer: "", localFileName: "c.mscz", deletedAt: 0),
        ]
        let store = LibraryAndroidStore(store: backend)

        store.permanentlyDeleteMany(["a", "b"])

        #expect(backend.records.map(\.id) == ["c"]) // live row untouched
        #expect(Set(backend.removedFiles) == ["a.mscz", "b.mscz"])
        #expect(store.deletedScores.isEmpty)
        #expect(store.scores.map(\.id) == ["c"])
    }

    @Test func `createPlaylist adds a name-sorted row with zero live members`() {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)

        store.createPlaylist("Recital")
        store.createPlaylist("Daily")
        store.createPlaylist("   ") // blank ignored

        #expect(store.playlists.map(\.name) == ["Daily", "Recital"]) // localizedStandardCompare
        #expect(store.playlists.allSatisfy { $0.memberCount == 0 })
        #expect(backend.playlistRecords.count == 2)
    }

    @Test func `renamePlaylist updates the name; blank is ignored`() throws {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)
        store.createPlaylist("Old")
        let id = try #require(store.playlists.first).id

        store.renamePlaylist(id, "New")
        #expect(store.playlists.map(\.name) == ["New"])

        store.renamePlaylist(id, "  ")
        #expect(store.playlists.map(\.name) == ["New"]) // unchanged
    }

    @Test func `deletePlaylist removes the row and its membership`() throws {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)
        store.createPlaylist("P")
        let id = try #require(store.playlists.first).id

        store.deletePlaylist(id)
        #expect(store.playlists.isEmpty)
        #expect(backend.playlistRecords.isEmpty)
    }

    @Test func `addToPlaylist appends unique; bulkAdd de-dupes; createWithScores seeds membership`() throws {
        let idA = "00000000-0000-0000-0000-000000000001"
        let idB = "00000000-0000-0000-0000-000000000002"
        let idC = "00000000-0000-0000-0000-000000000003"
        let backend = FakeLibraryStore()
        backend.records = [(idA, "a"), (idB, "b"), (idC, "c")].map { id, title in
            ScoreRecordWire(id: id, title: title, subtitle: "", composer: "", localFileName: "\(id).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createPlaylist("P")
        let pid = try #require(store.playlists.first).id

        store.addToPlaylist(idA, pid)
        store.addToPlaylist(idA, pid) // duplicate ignored
        store.bulkAddToPlaylist(pid, [idB, idA, idC]) // only idB, idC new
        #expect(store.playlists.first?.memberCount == 3)

        store.removeFromPlaylist(idB, pid)
        #expect(store.playlists.first?.memberCount == 2)

        store.createPlaylistWithScores("Q", [idC, idC, idA])
        let q = try #require(store.playlists.first { $0.name == "Q" })
        #expect(q.memberCount == 2) // idC, idA (de-duped)
    }

    @Test func `selectPlaylist exposes ordered live items`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let b = "00000000-0000-0000-0000-0000000000b2"
        let c = "00000000-0000-0000-0000-0000000000c3"
        let backend = FakeLibraryStore()
        backend.records = [a, b, c].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createPlaylist("P")
        let pid = try #require(store.playlists.first).id
        store.bulkAddToPlaylist(pid, [a, b, c])

        store.selectPlaylist(pid)
        #expect(store.selectedPlaylistItems.map(\.id) == [a, b, c])
    }

    @Test func `setPlaylistOrder reorders live members`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let b = "00000000-0000-0000-0000-0000000000b2"
        let c = "00000000-0000-0000-0000-0000000000c3"
        let backend = FakeLibraryStore()
        backend.records = [a, b, c].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createPlaylist("P")
        let pid = try #require(store.playlists.first).id
        store.bulkAddToPlaylist(pid, [a, b, c])
        store.selectPlaylist(pid)

        store.setPlaylistOrder(pid, [c, a, b])
        #expect(store.selectedPlaylistItems.map(\.id) == [c, a, b])
    }

    @Test func `beginAddToPlaylist marks playlists containing the score`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let b = "00000000-0000-0000-0000-0000000000b2"
        let backend = FakeLibraryStore()
        backend.records = [a, b].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createPlaylist("P")
        let pid = try #require(store.playlists.first).id
        store.addToPlaylist(a, pid)

        store.beginAddToPlaylist(a)
        #expect(store.addSheetPlaylists.map(\.contains) == [true])
        store.beginAddToPlaylist(b)
        #expect(store.addSheetPlaylists.map(\.contains) == [false])

        store.beginBulkAddToPlaylist()
        #expect(store.addSheetPlaylists.map(\.contains) == [false])
    }

    @Test func `soft-deleting a member updates selected items and member count`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let b = "00000000-0000-0000-0000-0000000000b2"
        let c = "00000000-0000-0000-0000-0000000000c3"
        let backend = FakeLibraryStore()
        backend.records = [a, b, c].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createPlaylist("P")
        let pid = try #require(store.playlists.first).id
        store.bulkAddToPlaylist(pid, [a, b, c])
        store.selectPlaylist(pid)
        #expect(store.selectedPlaylistItems.map(\.id) == [a, b, c])

        store.delete(b) // soft-delete a playlist member
        #expect(store.selectedPlaylistItems.map(\.id) == [a, c])
        #expect(store.playlists.first?.memberCount == 2)
    }

    @Test func `deleteMany soft-deletes all and updates playlist counts`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let b = "00000000-0000-0000-0000-0000000000b2"
        let c = "00000000-0000-0000-0000-0000000000c3"
        let backend = FakeLibraryStore()
        backend.records = [a, b, c].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createPlaylist("P")
        let pid = try #require(store.playlists.first).id
        store.bulkAddToPlaylist(pid, [a, b, c])

        store.deleteMany([a, b])
        #expect(Set(store.scores.map(\.id)) == [c])
        #expect(store.deletedScores.count == 2)
        #expect(store.playlists.first?.memberCount == 1)
    }

    @Test func `createTag adds a name-sorted row; blank ignored; default color`() {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)

        store.createTag("Recital")
        store.createTag("Daily")
        store.createTag("   ") // blank ignored

        #expect(store.tags.map(\.name) == ["Daily", "Recital"]) // localizedStandardCompare
        #expect(store.tags.allSatisfy { $0.memberCount == 0 })
        #expect(store.tags.allSatisfy { $0.colorHex == "#5856D6" })
        #expect(backend.tagRecords.count == 2)
    }

    @Test func `renameTag updates name keeping color; blank ignored`() throws {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)
        store.createTag("Old")
        let id = try #require(store.tags.first).id

        store.renameTag(id, "New")
        #expect(store.tags.map(\.name) == ["New"])
        #expect(store.tags.first?.colorHex == "#5856D6") // color preserved

        store.renameTag(id, "  ")
        #expect(store.tags.map(\.name) == ["New"]) // unchanged
    }

    @Test func `deleteTag removes the row and its membership`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(id: a, title: "A", subtitle: "", composer: "", localFileName: "\(a).mscz", deletedAt: 0),
        ]
        let store = LibraryAndroidStore(store: backend)
        store.createTag("P")
        let id = try #require(store.tags.first).id
        store.setTagAssigned(a, id, true)
        #expect(store.tags.first?.memberCount == 1)

        store.deleteTag(id)
        #expect(store.tags.isEmpty)
        #expect(backend.tagRecords.isEmpty)
        #expect(backend.tagItems.isEmpty) // membership cascaded
    }

    @Test func `bulkAddTag unions scores into a tag without duplicates`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let b = "00000000-0000-0000-0000-0000000000b2"
        let c = "00000000-0000-0000-0000-0000000000c3"
        let backend = FakeLibraryStore()
        backend.records = [a, b, c].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createTag("T")
        let t = try #require(store.tags.first).id

        store.setTagAssigned(a, t, true)
        store.bulkAddTag(t, [a, b, c]) // a already present → not duplicated
        #expect(store.tags.first?.memberCount == 3)
        #expect(backend.tagItems.count(where: { $0.tagId == t }) == 3)
    }

    @Test func `bulkAddTag with empty inputs is a no-op`() throws {
        let backend = FakeLibraryStore()
        let store = LibraryAndroidStore(store: backend)
        store.createTag("T")
        let t = try #require(store.tags.first).id

        store.bulkAddTag(t, [])
        #expect(store.tags.first?.memberCount == 0)
        #expect(backend.tagItems.isEmpty)
    }

    @Test func `tag member count excludes soft-deleted scores`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let b = "00000000-0000-0000-0000-0000000000b2"
        let backend = FakeLibraryStore()
        backend.records = [a, b].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createTag("T")
        let t = try #require(store.tags.first).id
        store.bulkAddTag(t, [a, b])
        #expect(store.tags.first?.memberCount == 2)

        store.delete(a) // soft-delete a member
        #expect(store.tags.first?.memberCount == 1) // excluded from live count
    }

    @Test func `selectTag exposes its live members sorted by title`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let b = "00000000-0000-0000-0000-0000000000b2"
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(
                id: a,
                title: "Zebra",
                subtitle: "",
                composer: "",
                localFileName: "\(a).mscz",
                deletedAt: 0,
            ),
            ScoreRecordWire(
                id: b,
                title: "Apple",
                subtitle: "",
                composer: "",
                localFileName: "\(b).mscz",
                deletedAt: 0,
            ),
        ]
        let store = LibraryAndroidStore(store: backend)
        store.createTag("T")
        let t = try #require(store.tags.first).id
        store.bulkAddTag(t, [a, b])

        store.selectTag(t)
        // title-sorted: "Apple" (b) then "Zebra" (a)
        #expect(store.selectedTagItems.map(\.id) == [b, a])
    }

    @Test func `beginEditTags marks tags containing the focused score`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let b = "00000000-0000-0000-0000-0000000000b2"
        let backend = FakeLibraryStore()
        backend.records = [a, b].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createTag("T")
        let t = try #require(store.tags.first).id
        store.setTagAssigned(a, t, true)

        store.beginEditTags(a)
        #expect(store.editSheetTags.map(\.contains) == [true])
        store.beginEditTags(b)
        #expect(store.editSheetTags.map(\.contains) == [false])

        store.beginBulkEditTags()
        #expect(store.editSheetTags.map(\.contains) == [false]) // bulk: nothing pre-checked
    }

    @Test func `bulk soft-delete updates tag member count`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let b = "00000000-0000-0000-0000-0000000000b2"
        let c = "00000000-0000-0000-0000-0000000000c3"
        let backend = FakeLibraryStore()
        backend.records = [a, b, c].map {
            ScoreRecordWire(id: $0, title: $0, subtitle: "", composer: "", localFileName: "\($0).mscz", deletedAt: 0)
        }
        let store = LibraryAndroidStore(store: backend)
        store.createTag("T")
        let t = try #require(store.tags.first).id
        store.bulkAddTag(t, [a, b, c])
        #expect(store.tags.first?.memberCount == 3)

        store.deleteMany([a, b])
        #expect(store.tags.first?.memberCount == 1) // only c is live

        store.restoreMany([a, b])
        #expect(store.tags.first?.memberCount == 3) // back to live
    }

    @Test func `permanent purge keeps tag rows but drops purged members from count`() throws {
        let a = "00000000-0000-0000-0000-0000000000a1"
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(id: a, title: "A", subtitle: "", composer: "", localFileName: "\(a).mscz", deletedAt: 0),
        ]
        let store = LibraryAndroidStore(store: backend)
        store.createTag("T")
        let t = try #require(store.tags.first).id
        store.bulkAddTag(t, [a])
        #expect(store.tags.first?.memberCount == 1) // a is a live member

        store.permanentlyDelete(a)
        #expect(store.tags.map(\.name) == ["T"]) // tag row survives the purge
        #expect(store.tags.first?.memberCount == 0) // purged member drops from the count
    }
}

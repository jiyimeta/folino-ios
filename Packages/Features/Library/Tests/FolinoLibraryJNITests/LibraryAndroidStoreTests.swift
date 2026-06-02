@testable import FolinoLibraryJNI
import Foundation
import Testing

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

    func deleteRecord(id: String) {
        records.removeAll { $0.id == id }
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
}

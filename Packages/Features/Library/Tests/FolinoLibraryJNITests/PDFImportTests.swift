@testable import FolinoLibraryJNI
import Foundation
import Testing

/// No-op export primitives so the suite can construct the store with the full initializer (mirrors
/// `LibraryAndroidStoreTests`'s equivalents; export routing itself is covered by `ExportScoreTests`).
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

/// In-memory fake of the Kotlin/Room backend, trimmed to what the import path touches. Each JNI test file keeps
/// its own minimal fake rather than sharing one (see `LibraryAndroidStoreTests.FakeLibraryStore`).
private final class FakePDFImportStore: LibraryStore {
    var records: [ScoreRecordWire] = []
    var copiedFiles: [(sourcePath: String, localFileName: String)] = []

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

    func sha256(path _: String) -> String {
        ""
    }

    func removeFile(localFileName _: String) {}

    func scoresDirectoryPath() -> String {
        "/tmp"
    }

    func deleteRecord(id: String) {
        records.removeAll { $0.id == id }
    }

    func loadPlaylists() -> [PlaylistRecordWire] {
        []
    }

    func loadPlaylistItems() -> [PlaylistItemWire] {
        []
    }

    func upsertPlaylist(_: PlaylistRecordWire) {}
    func replacePlaylistItems(_: String, _: [PlaylistItemWire]) {}
    func deletePlaylist(id _: String) {}

    func loadTags() -> [TagRecordWire] {
        []
    }

    func upsertTag(_: TagRecordWire) {}
    func deleteTag(id _: String) {}

    func loadTagItems() -> [TagItemWire] {
        []
    }

    func replaceTagItems(_: String, _: [TagItemWire]) {}
}

struct PDFImportTests {
    private func fixtureURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "sample", withExtension: "pdf"))
    }

    private func makeStore(_ backend: FakePDFImportStore) -> LibraryAndroidStore {
        LibraryAndroidStore(store: backend, pdfRenderer: NoopPdfRenderer(), audioExporter: NoopAudioExporter())
    }

    @Test func `imports a PDF as a live record`() throws {
        let backend = FakePDFImportStore()
        let store = makeStore(backend)
        _ = try store.importScore(fixtureURL().path)

        #expect(store.scores.count == 1)
        #expect(backend.records.count(where: { $0.deletedAt == 0 }) == 1)
    }

    /// iOS `LiveScoreFileImporter` prefers the PDF's `/Title` over the filename ("sample").
    @Test func `title comes from the document title, not the filename`() throws {
        let backend = FakePDFImportStore()
        let store = makeStore(backend)
        _ = try store.importScore(fixtureURL().path)

        #expect(store.scores.first?.title == "Sample Title")
    }

    /// Same "<id>.<canonicalExtension>" convention iOS uses — the extension is what tells the Reader which loader
    /// to use, so it must be `.pdf`, not `.mscz`.
    @Test func `stores the file with a pdf extension`() throws {
        let backend = FakePDFImportStore()
        let store = makeStore(backend)
        _ = try store.importScore(fixtureURL().path)

        let record = try #require(backend.records.first)
        #expect(record.localFileName.hasSuffix(".pdf"))
        #expect(backend.copiedFiles.first?.localFileName == record.localFileName)
    }

    @Test func `analytics reports the pdf format`() throws {
        let backend = FakePDFImportStore()
        let store = makeStore(backend)
        let event = try store.importScore(fixtureURL().path)
        #expect(event.name == "score_imported")
    }

    @Test func `unreadable bytes fail cleanly`() throws {
        let backend = FakePDFImportStore()
        let store = makeStore(backend)
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID()).pdf")
        try Data("not a pdf".utf8).write(to: junk)

        let event = store.importScore(junk.path)

        #expect(event.name == "score_import_failed")
        #expect(backend.records.isEmpty)
        #expect(store.scores.isEmpty)
    }

    /// The existing MuseScore path must be untouched by the new PDF branch.
    @Test func `mscz still imports`() throws {
        let backend = FakePDFImportStore()
        let store = makeStore(backend)
        let url = try #require(Bundle.module.url(forResource: "sample", withExtension: "mscz"))

        _ = store.importScore(url.path)

        let record = try #require(backend.records.first)
        #expect(record.localFileName.hasSuffix(".mscz"))
    }

    /// The list row Kotlin renders must flag PDF items so it can show the "PDF" label without re-deriving
    /// format from the filename itself.
    @Test func `rows flag pdf items`() throws {
        let backend = FakePDFImportStore()
        let store = makeStore(backend)
        _ = try store.importScore(fixtureURL().path)

        let row = try #require(store.scores.first)
        #expect(row.isPdf)
    }

    /// The MuseScore path must not be flagged as a PDF.
    @Test func `rows do not flag mscz items as pdf`() throws {
        let backend = FakePDFImportStore()
        let store = makeStore(backend)
        let url = try #require(Bundle.module.url(forResource: "sample", withExtension: "mscz"))
        _ = store.importScore(url.path)

        let row = try #require(store.scores.first)
        #expect(row.isPdf == false)
    }
}

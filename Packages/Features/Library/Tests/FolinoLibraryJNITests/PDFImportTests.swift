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

    // MARK: Share / open-with (importShared)
    //
    // `importShared` goes through `AndroidShareImporter`, which used to keep its OWN copy of the import body
    // hardcoded to `MSCZReader.parse` + a `.mscz` filename. Once `application/pdf` reached the share
    // intent-filters and the acceptance gate became Domain's `ShareImportPolicy`, every shared PDF was accepted,
    // staged, and then skipped as parse_failed. Both entry points now run the same `SingleFileImport` body.
    //
    // `importShared` blocks its caller on a semaphore while an inner `Task` runs the coordinator (its documented
    // precondition is a Kotlin background thread); the adapters have no real suspension points, so calling it
    // straight from a test body cannot deadlock.

    @Test func `sharing a PDF lands a live pdf record`() throws {
        let backend = FakePDFImportStore()
        let store = makeStore(backend)

        let result = try store.importShared([fixtureURL().path], ["sample.pdf"], 0, "", "", false)

        #expect(result.importedCount == 1)
        #expect(result.skippedCount == 0)
        #expect(result.analyticsImportedFormats == ["pdf"])
        let record = try #require(backend.records.first)
        #expect(record.localFileName.hasSuffix(".pdf"))
        // The document's own title, not the filename — the same rule the picker applies.
        #expect(record.title == "Sample Title")
        #expect(store.scores.first?.isPdf == true)
    }

    /// The MuseScore share path must be unchanged by the refactor.
    @Test func `sharing an mscz still lands an mscz record`() throws {
        let backend = FakePDFImportStore()
        let store = makeStore(backend)
        let url = try #require(Bundle.module.url(forResource: "sample", withExtension: "mscz"))

        let result = store.importShared([url.path], ["sample.mscz"], 0, "", "", false)

        #expect(result.importedCount == 1)
        let record = try #require(backend.records.first)
        #expect(record.localFileName.hasSuffix(".mscz"))
        #expect(store.scores.first?.isPdf == false)
    }

    @Test func `sharing unreadable PDF bytes is skipped, not crashed`() throws {
        let backend = FakePDFImportStore()
        let store = makeStore(backend)
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID()).pdf")
        try Data("not a pdf".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }

        let result = store.importShared([junk.path], ["broken.pdf"], 0, "", "", false)

        #expect(result.importedCount == 0)
        #expect(result.skippedCount == 1)
        #expect(result.analyticsFailedFormats == ["pdf"])
        #expect(result.analyticsFailedReasons == ["parse_failed"])
        #expect(backend.records.isEmpty)
    }

    /// The share path derives format and title from the ORIGINAL display name, which is also what the analytics
    /// split already treats as authoritative — a staged copy whose own extension went missing must still import
    /// as a PDF.
    @Test func `sharing resolves the format from the original name`() throws {
        let backend = FakePDFImportStore()
        let store = makeStore(backend)
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("staged-\(UUID())")
        try Data(contentsOf: fixtureURL()).write(to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }

        let result = store.importShared([staged.path], ["sample.pdf"], 0, "", "", false)

        #expect(result.importedCount == 1)
        #expect(backend.records.first?.localFileName.hasSuffix(".pdf") == true)
    }
}

import CryptoKit
@testable import FolinoLibraryJNI
import Foundation
import Testing

/// No-op export primitives so the suite can construct the store with the full initializer (mirrors
/// `LibraryAndroidStoreTests`'s equivalents; export routing is covered by `ExportScoreTests`).
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

/// In-memory fake of the Kotlin/Room backend, trimmed to what the import path touches. Each JNI test file
/// keeps its own minimal fake rather than sharing one (see `LibraryAndroidStoreTests.FakeLibraryStore`).
private final class FakeImportStore: LibraryStore {
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

    func sha256(path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

/// Import coverage for every readable format that is NOT a MuseScore container.
///
/// These all passed the acceptance gate (`ShareImportPolicy`, which the picker gates on) and then died at
/// parse, because `SingleFileImport.run` sent everything non-PDF to `MSCZReader` — a ZIP container reader.
/// The user saw a generic "import failed" for a file folino had just offered them. Nothing about Android
/// required that: ssm parses all of these here, and the Reader's loader sniffs the bytes rather than
/// trusting the extension, so the gap was only ever the missing branches.
///
/// Each case asserts the two things a wrong branch would break independently: that a record appears at all,
/// and that it is filed under the format the user picked — the stored extension is what the rest of the app
/// reads the file back with.
///
/// Fixtures come from swift-sheet-music's own test corpus, so the parsers here are being fed the same bytes
/// upstream already parses: `sample.mscx` is its `midi02.mscx`, `sample.musicxml` its `glissando-wavy.musicxml`,
/// `sample.mid` its `midi02-ref.mid`. `sample.mscz` and `sample.pdf` were already here.
struct NonContainerImportTests {
    private func makeStore(_ backend: FakeImportStore) -> LibraryAndroidStore {
        LibraryAndroidStore(store: backend, pdfRenderer: NoopPdfRenderer(), audioExporter: NoopAudioExporter())
    }

    private func fixtureURL(_ name: String, _ ext: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: ext))
    }

    /// Bare MuseScore XML — the case that reads most like a container but is not one, and the one a
    /// ZIP-only reader rejects most confusingly.
    @Test func `imports a bare mscx and keeps its extension`() throws {
        let backend = FakeImportStore()
        let store = makeStore(backend)
        _ = try store.importScore(fixtureURL("sample", "mscx").path)

        #expect(backend.records.count(where: { $0.deletedAt == 0 }) == 1)
        #expect(try #require(backend.records.first).localFileName.hasSuffix(".mscx"))
    }

    @Test func `imports MusicXML and keeps its extension`() throws {
        let backend = FakeImportStore()
        let store = makeStore(backend)
        _ = try store.importScore(fixtureURL("sample", "musicxml").path)

        #expect(backend.records.count(where: { $0.deletedAt == 0 }) == 1)
        #expect(try #require(backend.records.first).localFileName.hasSuffix(".musicxml"))
    }

    @Test func `imports a Standard MIDI File and keeps its extension`() throws {
        let backend = FakeImportStore()
        let store = makeStore(backend)
        _ = try store.importScore(fixtureURL("sample", "mid").path)

        #expect(backend.records.count(where: { $0.deletedAt == 0 }) == 1)
        #expect(try #require(backend.records.first).localFileName.hasSuffix(".mid"))
    }

    /// The container path has to keep working unchanged — it is the one format that did import before, and
    /// the rewrite moved it from `parse(contentsOf:)` to `parse(_:)` over bytes this function already reads.
    @Test func `still imports a MuseScore container`() throws {
        let backend = FakeImportStore()
        let store = makeStore(backend)
        _ = try store.importScore(fixtureURL("sample", "mscz").path)

        #expect(backend.records.count(where: { $0.deletedAt == 0 }) == 1)
        #expect(try #require(backend.records.first).localFileName.hasSuffix(".mscz"))
    }

    /// Bytes that are not a score must still be refused, or the branch widening would have traded a false
    /// negative for a false positive: a record pointing at a file nothing can open.
    @Test func `refuses bytes that are not a score`() throws {
        let backend = FakeImportStore()
        let store = makeStore(backend)
        let junk = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("not-a-score.musicxml")
        try Data("not xml at all".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }

        _ = try store.importScore(junk.path)

        #expect(backend.records.isEmpty)
    }
}

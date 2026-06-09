@testable import FolinoLibraryJNI
import Foundation
import Testing

/// Recording fake for the Android-only PDF rasterization primitive. Writes a
/// placeholder file so the orchestration's "non-empty output" contract holds.
private final class FakePdfRenderer: ScorePdfRenderer {
    var lastArgs: (String, String)?
    func renderPdf(_ scoreFilePath: String, _ outPath: String) -> Bool {
        lastArgs = (scoreFilePath, outPath)
        return FileManager.default.createFile(atPath: outPath, contents: Data("PDF".utf8))
    }
}

/// Recording fake for the Android-only M4A audio-export primitive.
private final class FakeAudioExporter: ScoreAudioFileExporter {
    var lastArgs: (String, String)?
    func exportAudio(_ scoreFilePath: String, _ outPath: String) -> Bool {
        lastArgs = (scoreFilePath, outPath)
        return FileManager.default.createFile(atPath: outPath, contents: Data("M4A".utf8))
    }
}

/// Fake backend with a real on-disk scores directory: the test seeds it by
/// copying the `sample.mscz` fixture in as `<id>.mscz`, mirroring what the
/// Kotlin/Room backend does on import.
private final class FakeExportStore: LibraryStore {
    let dir: URL
    var records: [ScoreRecordWire] = []

    init() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func scoresDirectoryPath() -> String {
        dir.path
    }

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

    func copyImportedFile(fromPath _: String, localFileName _: String) {}
    func removeFile(localFileName _: String) {}
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

struct ExportScoreTests {
    /// The store under test plus its recording fakes, seeded score id, and a
    /// fresh output directory.
    private struct Fixture {
        let store: LibraryAndroidStore
        let pdf: FakePdfRenderer
        let audio: FakeAudioExporter
        let id: String
        let outDir: URL
    }

    /// Seed the backend with the `sample.mscz` fixture copied in as `<id>.mscz`.
    /// The fixture is a MuseScore **v3** score (`<museScore version="3.02">`,
    /// programVersion 3.6.2).
    private func makeFixture() throws -> Fixture {
        let fixture = try #require(Bundle.module.url(forResource: "sample", withExtension: "mscz"))
        let backend = FakeExportStore()
        let id = "00000000-0000-0000-0000-0000000000ab"
        let local = "\(id).mscz"
        try FileManager.default.copyItem(at: fixture, to: backend.dir.appendingPathComponent(local))
        backend.records = [
            ScoreRecordWire(
                id: id, title: "My Song", subtitle: "", composer: "",
                localFileName: local, deletedAt: 0, lastOpenedAt: 0,
            ),
        ]
        let pdf = FakePdfRenderer()
        let audio = FakeAudioExporter()
        let store = LibraryAndroidStore(store: backend, pdfRenderer: pdf, audioExporter: audio)
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        return Fixture(store: store, pdf: pdf, audio: audio, id: id, outDir: outDir)
    }

    private func fixtureBytes() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "sample", withExtension: "mscz"))
        return try Data(contentsOf: url)
    }

    @Test func `midi export produces mid file`() throws {
        let f = try makeFixture()
        let path = f.store.exportScore(f.id, "midi", f.outDir.path)
        #expect(path.hasSuffix(".mid"))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(!data.isEmpty)
        // MIDI was encoded, not a copy of the source mscz bytes.
        #expect(try data != fixtureBytes())
    }

    @Test func `mscz 4 export produces mscz file`() throws {
        let f = try makeFixture()
        let path = f.store.exportScore(f.id, "museScoreV4", f.outDir.path)
        #expect(path.hasSuffix(".mscz"))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(!data.isEmpty)
    }

    @Test func `pdf routes to injected renderer`() throws {
        let f = try makeFixture()
        let path = f.store.exportScore(f.id, "pdf", f.outDir.path)
        let args = try #require(f.pdf.lastArgs)
        #expect(args.0.hasSuffix(".mscz"))
        #expect(args.1.hasSuffix(".pdf"))
        #expect(path == args.1)
    }

    @Test func `audio routes to injected exporter`() throws {
        let f = try makeFixture()
        let path = f.store.exportScore(f.id, "audioM4A", f.outDir.path)
        let args = try #require(f.audio.lastArgs)
        #expect(args.1.hasSuffix(".m4a"))
        #expect(path == args.1)
    }

    @Test func `unknown id returns empty string`() throws {
        let f = try makeFixture()
        #expect(f.store.exportScore("nope", "midi", f.outDir.path).isEmpty)
    }

    @Test func `unknown format returns empty string`() throws {
        let f = try makeFixture()
        #expect(f.store.exportScore(f.id, "garbage", f.outDir.path).isEmpty)
    }

    @Test func `export formats returns all five with original flag`() throws {
        let f = try makeFixture()
        let formats = f.store.exportFormats(f.id)
        #expect(formats.map(\.format) == ["museScoreV4", "museScoreV3", "pdf", "midi", "audioM4A"])
        // The fixture is a MuseScore v3 score, so only museScoreV3 is the original.
        #expect(formats.first { $0.format == "museScoreV3" }?.isOriginal == true)
        #expect(formats.filter(\.isOriginal).map(\.format) == ["museScoreV3"])
    }

    @Test func `export formats unknown id returns empty`() throws {
        let f = try makeFixture()
        #expect(f.store.exportFormats("nope").isEmpty)
    }

    @Test func `museScoreV3 export copies source bytes verbatim`() throws {
        let f = try makeFixture()
        let path = f.store.exportScore(f.id, "museScoreV3", f.outDir.path)
        #expect(path.hasSuffix(".mscz"))
        let returnedURL = URL(fileURLWithPath: path)
        let sourceURL = try #require(Bundle.module.url(forResource: "sample", withExtension: "mscz"))
        let exportedData = try Data(contentsOf: returnedURL)
        let originalData = try Data(contentsOf: sourceURL)
        #expect(exportedData == originalData)
    }
}

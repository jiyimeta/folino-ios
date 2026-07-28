import Domain
@testable import FolinoLibraryJNI
import Foundation
import Testing

/// No-op export primitives so the suite can construct the store with a single
/// backend argument; export routing is covered by `ExportScoreTests`.
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

/// Minimal in-memory backend exposing only the score-record surface `isAcceptedScoreFilename` touches (none — it is
/// a pure Domain query); the other protocol members are unused empty stubs.
private final class FakeLibraryStore: LibraryStore {
    var records: [ScoreRecordWire] = []

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

extension LibraryAndroidStore {
    /// Test convenience: construct with no-op export primitives.
    fileprivate convenience init(store: LibraryStore) {
        self.init(store: store, pdfRenderer: NoopPdfRenderer(), audioExporter: NoopAudioExporter())
    }
}

private func makeStore() -> LibraryAndroidStore {
    LibraryAndroidStore(store: FakeLibraryStore())
}

struct AcceptedFormatsTests {
    @Test func `accepts every domain extension`() {
        let store = makeStore()
        for ext in ShareImportPolicy.acceptedExtensions {
            #expect(store.isAcceptedScoreFilename("score.\(ext)"))
        }
    }

    @Test func `accepts PDF`() {
        #expect(makeStore().isAcceptedScoreFilename("Prelude.pdf"))
    }

    @Test func `is case insensitive`() {
        #expect(makeStore().isAcceptedScoreFilename("Prelude.PDF"))
    }

    @Test func `rejects unrelated files`() {
        let store = makeStore()
        #expect(!store.isAcceptedScoreFilename("photo.jpg"))
        #expect(!store.isAcceptedScoreFilename("noextension"))
    }
}

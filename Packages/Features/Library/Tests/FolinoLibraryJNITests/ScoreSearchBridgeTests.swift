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

extension LibraryAndroidStore {
    /// Test convenience: construct with no-op export primitives.
    fileprivate convenience init(store: LibraryStore) {
        self.init(store: store, pdfRenderer: NoopPdfRenderer(), audioExporter: NoopAudioExporter())
    }
}

/// Minimal in-memory backend exposing only the score-record surface the search
/// filter touches; the other protocol members are unused empty stubs.
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

struct ScoreSearchBridgeTests {
    @Test func `setSearchQuery filters scores by title; empty query restores all`() {
        let backend = FakeLibraryStore()
        backend.records = [
            ScoreRecordWire(
                id: "sonata",
                title: "Moonlight Sonata",
                subtitle: "",
                composer: "Beethoven",
                localFileName: "sonata.mscz",
                deletedAt: 0,
            ),
            ScoreRecordWire(
                id: "prelude",
                title: "Prelude",
                subtitle: "",
                composer: "Chopin",
                localFileName: "prelude.mscz",
                deletedAt: 0,
            ),
        ]
        let store = LibraryAndroidStore(store: backend)
        // Both live rows visible before any search.
        #expect(Set(store.scores.map(\.id)) == ["sonata", "prelude"])

        store.setSearchQuery("sonata")
        #expect(store.scores.map(\.id) == ["sonata"])

        // Empty query restores everything.
        store.setSearchQuery("")
        #expect(Set(store.scores.map(\.id)) == ["sonata", "prelude"])
    }
}

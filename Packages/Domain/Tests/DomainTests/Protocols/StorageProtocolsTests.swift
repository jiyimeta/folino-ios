@testable import Domain
import Foundation
import Observation
import Testing

/// In-memory fake conforming to `ScoreLibraryRepository`. Living inside the
/// test target ensures the protocol's shape compiles for at least one
/// concrete implementor and exercises the observable surface.
@MainActor
@Observable
private final class FakeScoreLibraryRepository: ScoreLibraryRepository {
    var scoreItems: [ScoreItem] = []
    var tags: [Domain.Tag] = []
    var playlists: [Playlist] = []

    func refresh() throws { /* no-op */ }

    func saveScoreItem(_ item: ScoreItem) throws {
        if let idx = scoreItems.firstIndex(where: { $0.id == item.id }) {
            scoreItems[idx] = item
        } else {
            scoreItems.append(item)
        }
    }

    func deleteScoreItem(id: ScoreItemID) throws {
        scoreItems.removeAll { $0.id == id }
    }

    func saveTag(_ tag: Domain.Tag) throws {
        if let idx = tags.firstIndex(where: { $0.id == tag.id }) {
            tags[idx] = tag
        } else {
            tags.append(tag)
        }
    }

    func deleteTag(id: TagID) throws { tags.removeAll { $0.id == id } }

    func savePlaylist(_ playlist: Playlist) throws {
        if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[idx] = playlist
        } else {
            playlists.append(playlist)
        }
    }

    func deletePlaylist(id: PlaylistID) throws {
        playlists.removeAll { $0.id == id }
    }

    func scoreItems(matchingContentHash contentHash: String) throws -> [ScoreItem] {
        scoreItems.filter { $0.contentHash == contentHash }
    }

    func loadReaderPreferences(for scoreItemID: ScoreItemID) throws -> ReaderPreferences? { nil }
    func saveReaderPreferences(_ preferences: ReaderPreferences) throws {}
}

private actor FakeAnnotationStore: AnnotationStore {
    var layers: [ScoreItemID: AnnotationLayer] = [:]

    func annotationLayer(forScoreItem id: ScoreItemID) throws -> AnnotationLayer? {
        layers[id]
    }

    func saveAnnotationLayer(_ layer: AnnotationLayer) throws {
        layers[layer.scoreItemID] = layer
    }

    func deleteAnnotationLayer(forScoreItem id: ScoreItemID) throws {
        layers.removeValue(forKey: id)
    }
}

@Suite @MainActor struct StorageProtocolsTests {
    private func sampleItem(hash: String = String(repeating: "0", count: 64)) -> ScoreItem {
        ScoreItem(
            title: "x", composer: nil, instrumentationSummary: nil,
            localFileName: "x.mid", contentHash: hash, sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
    }

    @Test func libraryRepositoryRoundTripsItems() async throws {
        let repo: any ScoreLibraryRepository = FakeScoreLibraryRepository()
        let item = sampleItem()
        try await repo.saveScoreItem(item)
        #expect(repo.scoreItems.contains { $0.id == item.id })
        try await repo.deleteScoreItem(id: item.id)
        #expect(repo.scoreItems.isEmpty)
    }

    @Test func contentHashLookupReturnsAllMatches() async throws {
        let repo: any ScoreLibraryRepository = FakeScoreLibraryRepository()
        let h = "abc123"
        try await repo.saveScoreItem(sampleItem(hash: h))
        try await repo.saveScoreItem(sampleItem(hash: h))
        try await repo.saveScoreItem(sampleItem(hash: "other"))
        let dups = try await repo.scoreItems(matchingContentHash: h)
        #expect(dups.count == 2)
    }
}

@Suite struct AnnotationStoreProtocolTests {
    @Test func annotationStoreRoundTripsLayers() async throws {
        let store: any AnnotationStore = FakeAnnotationStore()
        let scoreID = ScoreItemID()
        let layer = AnnotationLayer(
            scoreItemID: scoreID, drawings: [], textBoxes: [],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await store.saveAnnotationLayer(layer)
        let fetched = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(fetched == layer)
        try await store.deleteAnnotationLayer(forScoreItem: scoreID)
        let removed = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(removed == nil)
    }
}

@testable import Domain
import Foundation
import Testing

/// In-memory fake conforming to `ScoreLibraryRepository`. Living inside the
/// test target ensures the protocol's shape compiles for at least one
/// concrete implementor.
private actor FakeScoreLibraryRepository: ScoreLibraryRepository {
    var items: [ScoreItemID: ScoreItem] = [:]
    var tags: [TagID: Domain.Tag] = [:]
    var playlists: [PlaylistID: Playlist] = [:]

    func allScoreItems() throws -> [ScoreItem] { Array(items.values) }
    func scoreItem(id: ScoreItemID) throws -> ScoreItem? { items[id] }
    func saveScoreItem(_ item: ScoreItem) throws { items[item.id] = item }
    func deleteScoreItem(id: ScoreItemID) throws { items.removeValue(forKey: id) }

    func allTags() throws -> [Domain.Tag] { Array(tags.values) }
    func saveTag(_ tag: Domain.Tag) throws { tags[tag.id] = tag }
    func deleteTag(id: TagID) throws { tags.removeValue(forKey: id) }

    func allPlaylists() throws -> [Playlist] { Array(playlists.values) }
    func savePlaylist(_ playlist: Playlist) throws { playlists[playlist.id] = playlist }
    func deletePlaylist(id: PlaylistID) throws { playlists.removeValue(forKey: id) }
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

@Suite struct StorageProtocolsTests {
    @Test func libraryRepositoryRoundTripsItems() async throws {
        let repo: any ScoreLibraryRepository = FakeScoreLibraryRepository()
        let item = ScoreItem(
            title: "x", composer: nil, instrumentationSummary: nil,
            format: .midi, localFileName: "x.mid", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
        try await repo.saveScoreItem(item)
        let fetched = try await repo.scoreItem(id: item.id)
        #expect(fetched == item)
        try await repo.deleteScoreItem(id: item.id)
        let removed = try await repo.scoreItem(id: item.id)
        #expect(removed == nil)
    }

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

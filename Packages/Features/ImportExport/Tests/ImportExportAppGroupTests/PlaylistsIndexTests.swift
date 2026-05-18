import Domain
import Foundation
@testable import ImportExportAppGroup
import Testing

@Suite("PlaylistsIndex")
struct PlaylistsIndexTests {
    @Test func `encodes and decodes round trip`() throws {
        let original = PlaylistsIndex(
            schemaVersion: 1,
            playlists: [
                .init(id: PlaylistID(), name: "Practice"),
                .init(id: PlaylistID(), name: "Jazz"),
            ],
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlaylistsIndex.self, from: data)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.playlists.count == 2)
        #expect(decoded.playlists[0].name == "Practice")
        #expect(decoded.playlists[0].id == original.playlists[0].id)
    }

    @Test func `empty playlists round trip`() throws {
        let original = PlaylistsIndex(schemaVersion: 1, playlists: [])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlaylistsIndex.self, from: data)
        #expect(decoded.playlists.isEmpty)
    }
}

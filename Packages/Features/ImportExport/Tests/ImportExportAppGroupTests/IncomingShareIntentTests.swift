import Domain
import Foundation
@testable import ImportExportAppGroup
import Testing

@Suite("IncomingShareIntent")
struct IncomingShareIntentTests {
    @Test func `encodes and decodes with existing playlist`() throws {
        let original = IncomingShareIntent(
            schemaVersion: 1,
            token: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            playlistID: PlaylistID(),
            newPlaylistName: nil,
            openAfter: true,
            files: [
                .init(relativePath: "files/song.mscz", originalName: "song.mscz"),
            ],
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IncomingShareIntent.self, from: data)
        #expect(decoded.token == original.token)
        #expect(decoded.playlistID == original.playlistID)
        #expect(decoded.newPlaylistName == nil)
        #expect(decoded.openAfter == true)
        #expect(decoded.files == original.files)
    }

    @Test func `encodes and decodes with new playlist name`() throws {
        let original = IncomingShareIntent(
            schemaVersion: 1,
            token: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            playlistID: nil,
            newPlaylistName: "Smoke test",
            openAfter: false,
            files: [],
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IncomingShareIntent.self, from: data)
        #expect(decoded.newPlaylistName == "Smoke test")
        #expect(decoded.playlistID == nil)
        #expect(decoded.openAfter == false)
    }

    @Test func `encodes and decodes library only`() throws {
        let original = IncomingShareIntent(
            schemaVersion: 1,
            token: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            playlistID: nil,
            newPlaylistName: nil,
            openAfter: true,
            files: [
                .init(relativePath: "files/a.mscz", originalName: "a.mscz"),
                .init(relativePath: "files/b.musicxml", originalName: "b.musicxml"),
            ],
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IncomingShareIntent.self, from: data)
        #expect(decoded.files.count == 2)
        #expect(decoded.playlistID == nil && decoded.newPlaylistName == nil)
    }
}

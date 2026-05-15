import Domain
import Foundation
@testable import ImportExport
import ImportExportAppGroup
import Testing

@MainActor
@Suite("PlaylistsIndexWriter")
struct PlaylistsIndexWriterTests {
    @Test func `writes playlists index file atomically`() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "share-ext-writer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writer = PlaylistsIndexWriter(appGroupContainer: tmp)
        let playlists = [
            Playlist(name: "P1", orderedScoreItemIDs: [], createdAt: .now),
            Playlist(name: "P2", orderedScoreItemIDs: [], createdAt: .now),
        ]

        await writer.publish(playlists: playlists)

        let url = AppGroupPaths.playlistsIndexURL(in: tmp)
        let data = try Data(contentsOf: url)
        let index = try JSONDecoder().decode(PlaylistsIndex.self, from: data)
        #expect(index.schemaVersion == 1)
        #expect(index.playlists.map(\.name) == ["P1", "P2"])
    }

    @Test func `overwrites existing file`() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "share-ext-writer-overwrite-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writer = PlaylistsIndexWriter(appGroupContainer: tmp)
        await writer.publish(playlists: [
            Playlist(name: "old", orderedScoreItemIDs: [], createdAt: .now),
        ])
        await writer.publish(playlists: [
            Playlist(name: "new", orderedScoreItemIDs: [], createdAt: .now),
        ])

        let url = AppGroupPaths.playlistsIndexURL(in: tmp)
        let data = try Data(contentsOf: url)
        let index = try JSONDecoder().decode(PlaylistsIndex.self, from: data)
        #expect(index.playlists.map(\.name) == ["new"])
    }
}

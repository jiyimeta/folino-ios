// Tests/ImportExportShareUITests/ShareSessionTests.swift
import Domain
import Foundation
import ImportExportAppGroup
@testable import ImportExportShareUI
import Testing
import UtilityCore

@MainActor
@Suite("ShareSession")
struct ShareSessionTests {
    struct FixedClock: Clock {
        let date: Date
        func now() -> Date {
            date
        }
    }

    func makeContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "share-session-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func `load playlists returns empty when index missing`() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let session = ShareSession(appGroupContainer: container, clock: FixedClock(date: .now))
        #expect(session.loadPlaylists().isEmpty)
    }

    @Test func `load playlists reads existing index`() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let entries = [
            PlaylistsIndex.Entry(id: PlaylistID(), name: "A"),
            PlaylistsIndex.Entry(id: PlaylistID(), name: "B"),
        ]
        let index = PlaylistsIndex(schemaVersion: 1, playlists: entries)
        let data = try JSONEncoder().encode(index)
        try data.write(to: AppGroupPaths.playlistsIndexURL(in: container))

        let session = ShareSession(appGroupContainer: container, clock: FixedClock(date: .now))
        #expect(session.loadPlaylists().map(\.name) == ["A", "B"])
    }

    @Test func `finalize writes intent for library only save`() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let clock = FixedClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        let session = ShareSession(appGroupContainer: container, clock: clock)
        let token = UUID()
        let filesURL = AppGroupPaths.tokenFilesURL(token: token, in: container)
        try FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: filesURL.appending(path: "a.mscz"))

        let url = try session.finalize(
            token: token,
            files: [.init(relativePath: "files/a.mscz", originalName: "a.mscz")],
            decision: .save(.libraryOnly),
        )

        #expect(url.scheme == "folino")
        let intentData = try Data(contentsOf: AppGroupPaths.tokenIntentURL(token: token, in: container))
        let intent = try JSONDecoder().decode(IncomingShareIntent.self, from: intentData)
        #expect(intent.token == token)
        #expect(intent.openAfter == false)
        #expect(intent.playlistID == nil)
        #expect(intent.newPlaylistName == nil)
    }

    @Test func `finalize writes intent for save and open with new playlist`() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let session = ShareSession(appGroupContainer: container, clock: FixedClock(date: .now))
        let token = UUID()
        let filesURL = AppGroupPaths.tokenFilesURL(token: token, in: container)
        try FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: filesURL.appending(path: "a.mscz"))

        _ = try session.finalize(
            token: token,
            files: [.init(relativePath: "files/a.mscz", originalName: "a.mscz")],
            decision: .saveAndOpen(.createNew(name: "Brand new")),
        )

        let intentData = try Data(contentsOf: AppGroupPaths.tokenIntentURL(token: token, in: container))
        let intent = try JSONDecoder().decode(IncomingShareIntent.self, from: intentData)
        #expect(intent.openAfter == true)
        #expect(intent.newPlaylistName == "Brand new")
        #expect(intent.playlistID == nil)
    }

    @Test func `discard removes token directory`() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let session = ShareSession(appGroupContainer: container, clock: FixedClock(date: .now))
        let token = UUID()
        let filesURL = AppGroupPaths.tokenFilesURL(token: token, in: container)
        try FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: filesURL.appending(path: "a.mscz"))

        session.discard(token: token)

        #expect(!FileManager.default.fileExists(atPath: AppGroupPaths.tokenURL(token: token, in: container).path))
    }
}

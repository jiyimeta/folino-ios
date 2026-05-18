import Domain
import Foundation

public struct IncomingShareIntent: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let token: UUID
    public let createdAt: Date
    public let playlistID: PlaylistID?
    public let newPlaylistName: String?
    public let openAfter: Bool
    public let files: [File]

    public init(
        schemaVersion: Int,
        token: UUID,
        createdAt: Date,
        playlistID: PlaylistID?,
        newPlaylistName: String?,
        openAfter: Bool,
        files: [File],
    ) {
        self.schemaVersion = schemaVersion
        self.token = token
        self.createdAt = createdAt
        self.playlistID = playlistID
        self.newPlaylistName = newPlaylistName
        self.openAfter = openAfter
        self.files = files
    }

    public struct File: Codable, Sendable, Equatable {
        public let relativePath: String
        public let originalName: String

        public init(relativePath: String, originalName: String) {
            self.relativePath = relativePath
            self.originalName = originalName
        }
    }
}

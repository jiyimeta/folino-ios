import Domain
import Foundation

public struct PlaylistsIndex: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let playlists: [Entry]

    public init(schemaVersion: Int, playlists: [Entry]) {
        self.schemaVersion = schemaVersion
        self.playlists = playlists
    }

    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public let id: PlaylistID
        public let name: String

        public init(id: PlaylistID, name: String) {
            self.id = id
            self.name = name
        }
    }
}

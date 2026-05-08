import Domain
import Foundation

/// Route enum for Library's NavigationStack destinations.
/// Public + Codable so the App layer can persist `NavigationPath` instances
/// containing these values.
public enum LibraryRoute: Hashable, Codable, Sendable {
    case allScores
    case tags
    case tagDetail(TagID)
    case playlists
    case playlistDetail(PlaylistID)
}

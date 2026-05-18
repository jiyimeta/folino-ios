import Domain
import Foundation

/// Route enum for Library's NavigationStack destinations.
/// Defined here (not inside `LibraryRootScreen`) so `TagsListView` and
/// `PlaylistsListView` can `NavigationLink(value: LibraryRoute.…)` without
/// importing the screen.
/// Public + Codable so the App layer can persist `NavigationPath` instances
/// containing these values.
enum LibraryRoute: Hashable, Codable {
    case allScores
    case favorites
    case tags
    case tagDetail(TagID)
    case playlists
    case playlistDetail(PlaylistID)
    case recentlyDeleted
}

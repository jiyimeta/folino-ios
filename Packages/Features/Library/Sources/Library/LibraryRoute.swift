import Domain
import Foundation

/// Internal route enum for Library's NavigationStack destinations.
/// Defined here (not inside `LibraryRootView`) so `TagsListView` and
/// `PlaylistsListView` can `NavigationLink(value: LibraryRoute.…)`
/// without importing the root view.
enum LibraryRoute: Hashable {
    case allScores
    case tags
    case tagDetail(TagID)
    case playlists
    case playlistDetail(PlaylistID)
}

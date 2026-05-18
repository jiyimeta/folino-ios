import Domain
import SwiftUI

/// Routing for `LibraryRoute` from the root screen. Extracted from
/// `LibraryRootScreen` to keep that file under SwiftLint's file-length
/// budget.
@MainActor
@ViewBuilder
func libraryRootDestination(
    for route: LibraryRoute,
    viewModel: LibraryViewModel,
    onOpenScore: @escaping (ScoreItem) -> Void,
    onEditTags: @escaping (ScoreItem) -> Void,
    onAddToPlaylist: @escaping (ScoreItem) -> Void,
) -> some View {
    switch route {
    case .allScores:
        AllScoresScreen(
            library: viewModel,
            onOpen: onOpenScore,
            onEditTags: onEditTags,
            onAddToPlaylist: onAddToPlaylist,
        )
    case .favorites:
        FavoritesScreen(
            library: viewModel,
            onOpen: onOpenScore,
            onEditTags: onEditTags,
            onAddToPlaylist: onAddToPlaylist,
        )
    case .tags:
        TagsListScreen(library: viewModel)
    case let .tagDetail(tagID):
        if let tag = viewModel.repository.tags.first(where: { $0.id == tagID }) {
            TagDetailScreen(
                tag: tag,
                library: viewModel,
                onOpen: onOpenScore,
                onEditTags: onEditTags,
                onAddToPlaylist: onAddToPlaylist,
                onTagDeleted: { /* NavigationStack pops automatically when destination renders 'Tag not found' */ },
            )
        } else {
            ContentUnavailableView {
                Label {
                    Text("library.tag.notFound", bundle: .module)
                } icon: {
                    Image(systemName: "tag.slash")
                }
            }
        }
    case .playlists:
        PlaylistsListScreen(library: viewModel)
    case .recentlyDeleted:
        RecentlyDeletedScreen(library: viewModel, onOpen: onOpenScore)
    case let .playlistDetail(playlistID):
        if let playlist = viewModel.repository.playlists.first(where: { $0.id == playlistID }) {
            PlaylistDetailScreen(
                playlist: playlist,
                library: viewModel,
                onOpen: onOpenScore,
                onPlaylistDeleted: { /* same comment as tag */ },
            )
        } else {
            ContentUnavailableView {
                Label {
                    Text("library.playlist.notFound", bundle: .module)
                } icon: {
                    Image(systemName: "music.note.list")
                }
            }
        }
    }
}

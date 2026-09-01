import Domain
import SwiftUI

/// Routing for `LibraryRoute` from the root screen. Extracted from `LibraryRootScreen` to keep that file under
/// SwiftLint's file-length budget.
@MainActor
@ViewBuilder
func libraryRootDestination(
    for route: LibraryRoute,
    viewModel: LibraryViewModel,
    onOpenScore: @escaping (ScoreItem) -> Void,
    onEditTags: @escaping (ScoreItem) -> Void,
    onAddToPlaylist: @escaping (ScoreItem) -> Void,
    onOpenInPlaylist: @escaping (ScoreItem, PlaylistID) -> Void,
) -> some View {
    switch route {
    case .allScores:
        AllScoresScreen(
            library: viewModel,
            onOpen: onOpenScore,
            // Mirrors `onOpen`, and stays that way: this whole file is the iOS root screen's push destinations,
            // and iOS has no second window to open into. The Mac reaches these same leaf screens from
            // `MacLibraryBrowser`, which passes a real `openWindow(value:)` closure here instead.
            onOpenInNewWindow: onOpenScore,
            onEditTags: onEditTags,
            onAddToPlaylist: onAddToPlaylist,
        )
    case .favorites:
        FavoritesScreen(
            library: viewModel,
            onOpen: onOpenScore,
            onOpenInNewWindow: onOpenScore,
            onEditTags: onEditTags,
            onAddToPlaylist: onAddToPlaylist,
        )
    case .tags:
        TagsListScreen(library: viewModel)
    case let .tagDetail(tagID):
        tagDetailDestination(
            tagID: tagID,
            viewModel: viewModel,
            onOpenScore: onOpenScore,
            onEditTags: onEditTags,
            onAddToPlaylist: onAddToPlaylist,
        )
    case .playlists:
        PlaylistsListScreen(library: viewModel)
    case .recentlyDeleted:
        RecentlyDeletedScreen(library: viewModel, onOpen: onOpenScore, onOpenInNewWindow: onOpenScore)
    case let .playlistDetail(playlistID):
        playlistDetailDestination(playlistID: playlistID, viewModel: viewModel, onOpenInPlaylist: onOpenInPlaylist)
    }
}

/// Split out of `libraryRootDestination` to keep that function's body under SwiftLint's `function_body_length` budget.
@MainActor
@ViewBuilder
private func tagDetailDestination(
    tagID: TagID,
    viewModel: LibraryViewModel,
    onOpenScore: @escaping (ScoreItem) -> Void,
    onEditTags: @escaping (ScoreItem) -> Void,
    onAddToPlaylist: @escaping (ScoreItem) -> Void,
) -> some View {
    if let tag = viewModel.repository.tags.first(where: { $0.id == tagID }) {
        TagDetailScreen(
            tag: tag,
            library: viewModel,
            onOpen: onOpenScore,
            onOpenInNewWindow: onOpenScore,
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
}

/// Split out of `libraryRootDestination` for the same reason as `tagDetailDestination` above.
@MainActor
@ViewBuilder
private func playlistDetailDestination(
    playlistID: PlaylistID,
    viewModel: LibraryViewModel,
    onOpenInPlaylist: @escaping (ScoreItem, PlaylistID) -> Void,
) -> some View {
    if let playlist = viewModel.repository.playlists.first(where: { $0.id == playlistID }) {
        PlaylistDetailScreen(
            playlist: playlist,
            library: viewModel,
            onOpenInPlaylist: onOpenInPlaylist,
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

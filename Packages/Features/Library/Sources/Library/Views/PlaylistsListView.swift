import Domain
import SwiftUI
import UtilityUI

struct PlaylistsListView: View {
    let playlists: [Playlist]
    let onCreate: (String) -> Void
    let onDelete: (Playlist) -> Void

    @State private var pendingDelete: Playlist?

    var body: some View {
        Group {
            if playlists.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("library.playlists.empty.title", bundle: .module)
                    } icon: {
                        Image(systemName: "music.note.list")
                    }
                } description: {
                    Text("library.playlists.empty.hint", bundle: .module)
                }
            } else {
                List {
                    ForEach(playlists) { playlist in
                        NavigationLink(value: LibraryRoute.playlistDetail(playlist.id)) {
                            HStack {
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(.tint)
                                Text(playlist.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(playlist.orderedScoreItemIDs.count, format: .number)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = playlist
                            } label: {
                                Label {
                                    L10n.Common.delete
                                } icon: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(Text("library.playlists", bundle: .module))
        .createEntityToolbar(copy: .playlist, onCreate: onCreate)
        .alert(
            Text(String(
                localized: "library.score.delete.title",
                defaultValue: "Delete \"\(pendingDelete?.name ?? "")\"?",
                bundle: .module
            )),
            isPresented: deleteAlertBinding,
            presenting: pendingDelete
        ) { playlist in
            Button(role: .destructive) {
                onDelete(playlist)
            } label: {
                L10n.Common.delete
            }
            Button(role: .cancel) {} label: {
                L10n.Common.cancel
            }
        } message: { _ in
            Text("library.playlist.delete.message", bundle: .module)
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { isPresented in if !isPresented { pendingDelete = nil } }
        )
    }
}

#if DEBUG
    private struct PlaylistsListViewPreviewHost: View {
        let playlists: [Playlist]
        var body: some View {
            NavigationStack {
                PlaylistsListView(
                    playlists: playlists,
                    onCreate: { _ in },
                    onDelete: { _ in }
                )
            }
        }
    }

    #Preview("Filled") {
        PlaylistsListViewPreviewHost(playlists: [
            Playlist(name: "Daily warm-up", orderedScoreItemIDs: [], createdAt: Date()),
            Playlist(name: "Recital set", orderedScoreItemIDs: [], createdAt: Date()),
        ])
    }

    #Preview("Empty") {
        PlaylistsListViewPreviewHost(playlists: [])
    }
#endif

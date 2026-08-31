import Domain
import SwiftUI
import UtilityUI

struct AddToPlaylistSheet: View {
    let scoreTitle: String
    let scoreItemID: ScoreItemID
    let allPlaylists: [Playlist]
    let onToggle: (Playlist) -> Void
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text(navigationTitleText))
                .inlineNavigationTitleCompat()
                .toolbar { doneToolbar }
        }
        .listSheetSizeCompat()
    }

    private var navigationTitleText: String {
        String(
            localized: "library.playlist.addOne.title",
            defaultValue: "Add \"\(scoreTitle)\" to Playlist",
            bundle: .module,
        )
    }

    private var content: some View {
        List {
            Section {
                ForEach(allPlaylists) { playlist in
                    Button {
                        onToggle(playlist)
                    } label: {
                        HStack {
                            Image(
                                systemName: playlist.orderedScoreItemIDs.contains(scoreItemID)
                                    ? "checkmark.circle.fill"
                                    : "circle",
                            )
                            .foregroundStyle(.tint)
                            Text(playlist.name)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                }
            }
            Section {
                InlineCreateRow(
                    name: $newPlaylistName,
                    placeholder: "library.playlist.create.placeholder",
                    onCreate: onCreate,
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailingCompat) {
            Button { dismiss() } label: { L10n.Common.done }
        }
    }
}

#if DEBUG
#Preview {
    struct Host: View {
        @State private var playlists: [Playlist]
        let scoreID: ScoreItemID
        init() {
            let scoreID = ScoreItemID()
            self.scoreID = scoreID
            _playlists = State(initialValue: [
                Playlist(name: "Daily warm-up", orderedScoreItemIDs: [scoreID], createdAt: Date()),
                Playlist(name: "Recital set", orderedScoreItemIDs: [], createdAt: Date()),
            ])
        }

        var body: some View {
            AddToPlaylistSheet(
                scoreTitle: "Clair de Lune",
                scoreItemID: scoreID,
                allPlaylists: playlists,
                onToggle: { _ in },
                onCreate: { _ in },
            )
        }
    }
    return Host()
}
#endif

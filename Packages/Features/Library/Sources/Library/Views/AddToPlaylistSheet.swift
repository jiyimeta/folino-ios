import Domain
import SwiftUI

struct AddToPlaylistSheet: View {
    let scoreTitle: String
    let scoreItemID: ScoreItemID
    let allPlaylists: [Playlist]
    let onToggle: (Playlist) -> Void
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newPlaylistName: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(allPlaylists) { playlist in
                        Button {
                            onToggle(playlist)
                        } label: {
                            HStack {
                                Image(systemName: playlist.orderedScoreItemIDs.contains(scoreItemID)
                                    ? "checkmark.circle.fill"
                                    : "circle")
                                    .foregroundStyle(.tint)
                                Text(playlist.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                    }
                }
                Section {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                        TextField(text: $newPlaylistName) { Text("New playlist", bundle: .module) }
                            .submitLabel(.done)
                            .onSubmit { commitNewPlaylist() }
                        Button {
                            commitNewPlaylist()
                        } label: {
                            Text("Create", bundle: .module)
                        }
                        .buttonStyle(.borderless)
                        .disabled(trimmedNewPlaylistName.isEmpty)
                    }
                }
            }
            .navigationTitle(Text("Add \"\(scoreTitle)\" to Playlist", bundle: .module))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar { doneToolbar }
        }
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Button { dismiss() } label: { Text("Done", bundle: .module) }
            }
        #else
            ToolbarItem(placement: .automatic) {
                Button { dismiss() } label: { Text("Done", bundle: .module) }
            }
        #endif
    }

    private var trimmedNewPlaylistName: String {
        newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitNewPlaylist() {
        let trimmed = trimmedNewPlaylistName
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        newPlaylistName = ""
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
                    onCreate: { _ in }
                )
            }
        }
        return Host()
    }
#endif

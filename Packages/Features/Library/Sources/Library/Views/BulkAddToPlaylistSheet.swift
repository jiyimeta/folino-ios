import Domain
import SwiftUI

struct BulkAddToPlaylistSheet: View {
    let selectionCount: Int
    let selectedIDs: Set<ScoreItemID>
    let allPlaylists: [Playlist]
    let onPick: (Playlist) -> Void
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newPlaylistName: String = ""

    var body: some View {
        NavigationStack {
            List {
                playlistsSection
                createSection
            }
            .navigationTitle(Text("Add \(selectionCount) scores to playlist", bundle: .module))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar { cancelToolbarItem }
        }
    }

    @ViewBuilder
    private var playlistsSection: some View {
        Section {
            ForEach(allPlaylists) { playlist in
                Button { onPick(playlist) } label: {
                    HStack {
                        Image(systemName: "music.note.list")
                            .foregroundStyle(.tint)
                        Text(playlist.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        let already = playlist.orderedScoreItemIDs.filter { selectedIDs.contains($0) }.count
                        if already > 0 {
                            Text("\(already)/\(selectionCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var createSection: some View {
        Section {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.tint)
                TextField(text: $newPlaylistName) { Text("New playlist", bundle: .module) }
                    .submitLabel(.done)
                    .onSubmit { commitNewPlaylist() }
                Button { commitNewPlaylist() } label: {
                    Text("Create", bundle: .module)
                }
                .buttonStyle(.borderless)
                .disabled(trimmedNewPlaylistName.isEmpty)
            }
        }
    }

    @ToolbarContentBuilder
    private var cancelToolbarItem: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Button { dismiss() } label: { Text("Cancel", bundle: .module) }
            }
        #else
            ToolbarItem(placement: .automatic) {
                Button { dismiss() } label: { Text("Cancel", bundle: .module) }
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
            let scoreA = ScoreItemID()
            let scoreB = ScoreItemID()
            var body: some View {
                BulkAddToPlaylistSheet(
                    selectionCount: 2,
                    selectedIDs: [scoreA, scoreB],
                    allPlaylists: [
                        Playlist(name: "Daily warm-up", orderedScoreItemIDs: [scoreA], createdAt: Date()),
                        Playlist(name: "Recital set", orderedScoreItemIDs: [], createdAt: Date()),
                    ],
                    onPick: { _ in },
                    onCreate: { _ in }
                )
            }
        }
        return Host()
    }
#endif

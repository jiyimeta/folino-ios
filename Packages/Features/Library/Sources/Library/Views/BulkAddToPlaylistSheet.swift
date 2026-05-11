import Domain
import SwiftUI
import UtilityUI

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
            .navigationTitle(Text(String(
                localized: "library.playlist.addBulk.title",
                defaultValue: "Add \(selectionCount) scores to playlist",
                bundle: .module,
            )))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { cancelToolbarItem }
        }
    }

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
                        let already = playlist.orderedScoreItemIDs.count(where: { selectedIDs.contains($0) })
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

    private var createSection: some View {
        Section {
            InlineCreateRow(
                name: $newPlaylistName,
                placeholder: "library.playlist.create.placeholder",
                onCreate: onCreate,
            )
        }
    }

    @ToolbarContentBuilder
    private var cancelToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { dismiss() } label: { L10n.Common.cancel }
        }
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
                onCreate: { _ in },
            )
        }
    }
    return Host()
}
#endif

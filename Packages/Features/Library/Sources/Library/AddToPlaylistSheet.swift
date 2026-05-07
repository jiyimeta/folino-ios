import Domain
import SwiftUI

struct AddToPlaylistSheet: View {
    let scoreItem: ScoreItem
    let library: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var newPlaylistName: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.repository.playlists) { playlist in
                        Button {
                            Task { await toggle(playlist) }
                        } label: {
                            HStack {
                                Image(systemName: playlist.orderedScoreItemIDs.contains(scoreItem.id)
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
                            .onSubmit { Task { await commitNewPlaylist() } }
                    }
                }
            }
            .navigationTitle(Text("Add \"\(scoreItem.title)\" to Playlist", bundle: .module))
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

    private func toggle(_ playlist: Playlist) async {
        var updated = playlist
        if let idx = updated.orderedScoreItemIDs.firstIndex(of: scoreItem.id) {
            updated.orderedScoreItemIDs.remove(at: idx)
        } else {
            updated.orderedScoreItemIDs.append(scoreItem.id)
        }
        do {
            try await library.repository.savePlaylist(updated)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func commitNewPlaylist() async {
        let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let playlist = Playlist(
            name: trimmed,
            orderedScoreItemIDs: [scoreItem.id],
            createdAt: Date()
        )
        do {
            try await library.repository.savePlaylist(playlist)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return
        }
        newPlaylistName = ""
    }
}

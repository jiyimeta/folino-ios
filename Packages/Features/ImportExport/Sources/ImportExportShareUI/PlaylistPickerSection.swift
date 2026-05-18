import Domain
import ImportExportAppGroup
import SwiftUI

struct PlaylistPickerSection: View {
    let entries: [PlaylistsIndex.Entry]
    @Binding var selection: PlaylistChoice
    @State private var newName = ""

    var body: some View {
        Section {
            noPlaylistRow
            ForEach(entries) { entry in
                entryRow(entry)
            }
            newPlaylistField
        } header: {
            Text("share_extension.picker.title", bundle: .module)
        }
    }

    private var noPlaylistRow: some View {
        selectionRow(
            label: Text("share_extension.picker.no_playlist", bundle: .module),
            isSelected: selection == .libraryOnly,
            iconSystemName: "text.badge.xmark",
            action: { selection = .libraryOnly },
        )
    }

    private func entryRow(_ entry: PlaylistsIndex.Entry) -> some View {
        selectionRow(
            label: Text(entry.name),
            isSelected: selection == .existing(entry.id),
            iconSystemName: "music.note.list",
            action: { selection = .existing(entry.id) },
        )
    }

    private var newPlaylistField: some View {
        HStack(spacing: 8) {
            Label {
                TextField(
                    "share_extension.picker.new_playlist_placeholder",
                    text: $newName,
                    prompt: Text("share_extension.picker.new_playlist_placeholder", bundle: .module),
                )
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .onChange(of: newName) { _, value in
                    if value.trimmingCharacters(in: .whitespaces).isEmpty {
                        selection = .libraryOnly
                    } else {
                        selection = .createNew(name: value)
                    }
                }
            } icon: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.tint)
            }

            Spacer(minLength: 8)

            if case .createNew = selection {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
    }

    private func selectionRow(
        label: Text,
        isSelected: Bool,
        iconSystemName: String,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Label {
                    label.foregroundStyle(.primary)
                } icon: {
                    Image(systemName: iconSystemName)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
extension PlaylistID {
    static let dummy1 = PlaylistID(rawValue: UUID())
    static let dummy2 = PlaylistID(rawValue: UUID())
}

#Preview {
    @Previewable @State var selection = PlaylistChoice.existing(.dummy1)

    Form {
        PlaylistPickerSection(
            entries: [
                PlaylistsIndex.Entry(id: .dummy1, name: "Playlist 1"),
                PlaylistsIndex.Entry(id: .dummy2, name: "Playlist 2"),
            ],
            selection: $selection,
        )
    }
}
#endif

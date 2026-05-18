// Sources/ImportExportShareUI/PlaylistPicker.swift
import Domain
import ImportExportAppGroup
import SwiftUI

struct PlaylistPicker: View {
    let entries: [PlaylistsIndex.Entry]
    @Binding var selection: PlaylistChoice
    @State private var newName = ""
    @State private var creatingNew = false

    var body: some View {
        Group {
            noPlaylistRow
            ForEach(entries) { entry in
                entryRow(entry)
            }
            newPlaylistSection
        }
    }

    private var noPlaylistRow: some View {
        selectionRow(
            label: Text("share_extension.picker.library_only", bundle: .module),
            isSelected: selection == .libraryOnly,
            action: { selection = .libraryOnly },
        )
    }

    private func entryRow(_ entry: PlaylistsIndex.Entry) -> some View {
        selectionRow(
            label: Text(entry.name),
            isSelected: selection == .existing(entry.id),
            action: { selection = .existing(entry.id) },
        )
    }

    @ViewBuilder
    private var newPlaylistSection: some View {
        if creatingNew {
            newPlaylistField
        } else {
            newPlaylistButton
        }
    }

    private var newPlaylistField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.tint)
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
        }
    }

    private var newPlaylistButton: some View {
        Button {
            creatingNew = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                Text("share_extension.picker.new_playlist", bundle: .module)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectionRow(label: Text, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                label
                    .foregroundStyle(.primary)
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

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
        VStack(alignment: .leading, spacing: 6) {
            Text("share_extension.picker.title", bundle: .module)
                .font(.headline)
            VStack(spacing: 0) {
                libraryOnlyRow
                entryRows
                Divider().padding(.leading, 32)
                newPlaylistSection
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var libraryOnlyRow: some View {
        row(
            label: Text("share_extension.picker.library_only", bundle: .module),
            isSelected: selection == .libraryOnly,
            action: { selection = .libraryOnly },
        )
    }

    private var entryRows: some View {
        ForEach(entries) { entry in
            Divider().padding(.leading, 32)
            row(
                label: Text(entry.name),
                isSelected: selection == .existing(entry.id),
                action: { selection = .existing(entry.id) },
            )
        }
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
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }

    private var newPlaylistButton: some View {
        Button {
            creatingNew = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                Text("share_extension.picker.new_playlist", bundle: .module)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func row(label: Text, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                label
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

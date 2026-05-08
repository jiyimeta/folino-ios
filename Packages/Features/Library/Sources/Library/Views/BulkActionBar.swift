import SwiftUI

struct BulkActionBar: View {
    let selectionCount: Int
    let onAddToPlaylist: () -> Void
    let onEditTags: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            barButton(systemImage: "music.note.list", labelKey: "Add to Playlist", action: onAddToPlaylist)
            barButton(systemImage: "tag", labelKey: "Tags", action: onEditTags)
            barButton(systemImage: "trash", labelKey: "Delete", role: .destructive, action: onDelete)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.bar)
        .disabled(selectionCount == 0)
    }

    @ViewBuilder
    private func barButton(
        systemImage: String,
        labelKey: LocalizedStringKey,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(labelKey, bundle: .module)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
    #Preview("Enabled") {
        BulkActionBar(selectionCount: 3, onAddToPlaylist: {}, onEditTags: {}, onDelete: {})
    }

    #Preview("Disabled") {
        BulkActionBar(selectionCount: 0, onAddToPlaylist: {}, onEditTags: {}, onDelete: {})
    }
#endif

import SwiftUI

struct BulkActionBar: View {
    let selectionCount: Int
    let onAddToPlaylist: () -> Void
    let onEditTags: () -> Void
    let onDelete: () -> Void

    var body: some View {
        #if os(iOS)
            iOSBody
        #else
            macOSBody
        #endif
    }

    #if os(iOS)
        @ViewBuilder
        private var iOSBody: some View {
            HStack(spacing: 12) {
                HStack(spacing: 0) {
                    iconButton(
                        systemImage: "music.note.list",
                        labelKey: "Add to Playlist",
                        action: onAddToPlaylist
                    )
                    iconButton(
                        systemImage: "tag",
                        labelKey: "Tags",
                        action: onEditTags
                    )
                }
                .glassEffect(.regular.interactive())

                Spacer(minLength: 0)

                iconButton(
                    systemImage: "trash",
                    labelKey: "Delete",
                    role: .destructive,
                    action: onDelete
                )
                .glassEffect(.regular.interactive())
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 8)
            .disabled(selectionCount == 0)
        }

        @ViewBuilder
        private func iconButton(
            systemImage: String,
            labelKey: LocalizedStringKey,
            role: ButtonRole? = nil,
            action: @escaping () -> Void
        ) -> some View {
            Button(role: role, action: action) {
                Image(systemName: systemImage)
                    .frame(width: 48, height: 48)
            }
            .tint(role == .destructive ? .red : .primary)
            .accessibilityLabel(Text(labelKey, bundle: .module))
        }
    #else
        @ViewBuilder
        private var macOSBody: some View {
            HStack {
                Button("Add to Playlist", action: onAddToPlaylist)
                Button("Tags", action: onEditTags)
                Spacer()
                Button("Delete", role: .destructive, action: onDelete)
            }
            .padding()
            .disabled(selectionCount == 0)
        }
    #endif
}

#if DEBUG && os(iOS)
    #Preview("Enabled") {
        NavigationStack {
            List {
                Text("Foo")
            }
            .safeAreaInset(edge: .bottom) {
                BulkActionBar(selectionCount: 3, onAddToPlaylist: {}, onEditTags: {}, onDelete: {})
            }
            .searchable(text: .constant("Foo"))
        }
    }

    #Preview("Disabled") {
        BulkActionBar(selectionCount: 0, onAddToPlaylist: {}, onEditTags: {}, onDelete: {})
    }
#endif

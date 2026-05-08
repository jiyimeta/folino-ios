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
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        constructiveButton(
                            systemImage: "music.note.list",
                            labelKey: "Add to Playlist",
                            action: onAddToPlaylist
                        )
                        constructiveButton(
                            systemImage: "tag",
                            labelKey: "Tags",
                            action: onEditTags
                        )
                    }
                }

                Spacer(minLength: 0)

                destructiveButton(
                    systemImage: "trash",
                    labelKey: "Delete",
                    action: onDelete
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .disabled(selectionCount == 0)
        }

        @ViewBuilder
        private func constructiveButton(
            systemImage: String,
            labelKey: LocalizedStringKey,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                Image(systemName: systemImage)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(Text(labelKey, bundle: .module))
        }

        @ViewBuilder
        private func destructiveButton(
            systemImage: String,
            labelKey: LocalizedStringKey,
            action: @escaping () -> Void
        ) -> some View {
            Button(role: .destructive, action: action) {
                Image(systemName: systemImage)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(.red)
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
        BulkActionBar(selectionCount: 3, onAddToPlaylist: {}, onEditTags: {}, onDelete: {})
    }

    #Preview("Disabled") {
        BulkActionBar(selectionCount: 0, onAddToPlaylist: {}, onEditTags: {}, onDelete: {})
    }
#endif

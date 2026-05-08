import Domain
import SwiftUI
import UtilityUI

struct BulkActionBar: View {
    let selectionCount: Int
    let availableShareFormats: [ScoreShareFormat]
    let onShare: (ScoreShareFormat) -> Void
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
                Menu {
                    actionMenuContent
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 48, height: 48)
                }
                .tint(.primary)
                .accessibilityLabel(L10n.Common.more)
                .glassEffect(.regular.interactive())

                Spacer(minLength: 0)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: 48, height: 48)
                }
                .tint(.red)
                .accessibilityLabel(L10n.Common.delete)
                .glassEffect(.regular.interactive())
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 8)
            .disabled(selectionCount == 0)
        }

        @ViewBuilder
        private var actionMenuContent: some View {
            if !availableShareFormats.isEmpty {
                ForEach(availableShareFormats, id: \.self) { format in
                    Button {
                        onShare(format)
                    } label: {
                        bulkShareFormatLabel(format)
                    }
                }
                Divider()
            }
            Button(action: onAddToPlaylist) {
                Label {
                    Text("library.playlist.add.actionEllipsis", bundle: .module)
                } icon: {
                    Image(systemName: "music.note.list")
                }
            }
            Button(action: onEditTags) {
                Label {
                    Text("library.tags.add.action", bundle: .module)
                } icon: {
                    Image(systemName: "tag")
                }
            }
        }
    #else
        @ViewBuilder
        private var macOSBody: some View {
            HStack {
                Menu {
                    Button(action: onAddToPlaylist) {
                        Text("library.playlist.add.action", bundle: .module)
                    }
                    Button(action: onEditTags) {
                        Text("library.tags.add.action", bundle: .module)
                    }
                } label: {
                    L10n.Common.more
                }
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    L10n.Common.delete
                }
            }
            .padding()
            .disabled(selectionCount == 0)
        }
    #endif
}

@MainActor
@ViewBuilder
private func bulkShareFormatLabel(_ format: ScoreShareFormat) -> some View {
    switch format {
    case .museScoreV4:
        Label { Text("library.format.musescore4", bundle: .module) } icon: { Image(systemName: "doc.zipper") }
    case .museScoreV3:
        Label { Text("library.format.musescore3", bundle: .module) } icon: { Image(systemName: "doc.zipper") }
    case .pdf:
        Label { Text("library.format.pdf", bundle: .module) } icon: { Image(systemName: "doc.richtext") }
    case .midi:
        Label { Text("library.format.midi", bundle: .module) } icon: { Image(systemName: "pianokeys") }
    }
}

#if DEBUG && os(iOS)
    #Preview("Enabled") {
        NavigationStack {
            List {
                Text("Foo")
            }
            .safeAreaInset(edge: .bottom) {
                BulkActionBar(
                    selectionCount: 3,
                    availableShareFormats: [.pdf, .midi],
                    onShare: { _ in },
                    onAddToPlaylist: {},
                    onEditTags: {},
                    onDelete: {}
                )
            }
            .searchable(text: .constant("Foo"))
        }
    }

    #Preview("Disabled") {
        BulkActionBar(
            selectionCount: 0,
            availableShareFormats: [],
            onShare: { _ in },
            onAddToPlaylist: {},
            onEditTags: {},
            onDelete: {}
        )
    }
#endif

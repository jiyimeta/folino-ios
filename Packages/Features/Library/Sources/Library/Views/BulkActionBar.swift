import Domain
import SwiftUI
import UtilityUI

struct BulkActionBar: View {
    let selectionCount: Int
    let availableShareFormats: [ScoreShareFormat]
    let onShare: (ScoreShareFormat) -> Void
    let onAddToPlaylist: () -> Void
    let onEditTags: () -> Void
    let allFavorited: Bool
    let onFavorite: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                actionMenuContent
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 48, height: 48)
            }
            .tint(.primary)
            .accessibilityLabel(L10n.Common.more)
            .interactiveGlassCompat()

            Spacer(minLength: 0)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .frame(width: 48, height: 48)
            }
            .tint(.red)
            .accessibilityLabel(L10n.Common.delete)
            .interactiveGlassCompat()
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
        Button(action: onFavorite) {
            Label {
                let key: LocalizedStringKey = allFavorited
                    ? "library.score.unfavorite.action"
                    : "library.score.favorite.action"
                Text(key, bundle: .module)
            } icon: {
                Image(systemName: allFavorited ? "star.slash" : "star")
            }
        }
    }
}

/// Shared with `ScoreListView`'s macOS-only bulk context menu, which offers the same share formats.
@MainActor
@ViewBuilder
func bulkShareFormatLabel(_ format: ScoreShareFormat) -> some View {
    switch format {
    case .museScoreV4:
        Label { Text("library.format.musescore4", bundle: .module) } icon: { Image(systemName: "doc.zipper") }
    case .museScoreV3:
        Label { Text("library.format.musescore3", bundle: .module) } icon: { Image(systemName: "doc.zipper") }
    case .pdf:
        Label { Text("library.format.pdf", bundle: .module) } icon: { Image(systemName: "doc.richtext") }
    case .midi:
        Label { Text("library.format.midi", bundle: .module) } icon: { Image(systemName: "pianokeys") }
    case .audioM4A:
        Label { Text("library.format.m4a", bundle: .module) } icon: { Image(systemName: "waveform") }
    }
}

#if DEBUG
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
                allFavorited: false,
                onFavorite: {},
                onDelete: {},
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
        allFavorited: false,
        onFavorite: {},
        onDelete: {},
    )
}
#endif

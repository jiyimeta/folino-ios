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

    private var actionMenuContent: some View {
        bulkActionMenuItems(
            availableShareFormats: availableShareFormats,
            onShare: onShare,
            onAddToPlaylist: onAddToPlaylist,
            onEditTags: onEditTags,
            allFavorited: allFavorited,
            onFavorite: onFavorite,
        )
    }
}

/// Share (if any formats are available) / Add to Playlist / Edit Tags / Favorite-Unfavorite — the single source
/// of truth for "what are the bulk actions", shared between this bar's overflow menu (iOS) and the macOS-only bulk
/// context menus in `ScoreListView` / `PlaylistDetailView` (via `bulkActionsContextMenuItems`). Delete is
/// deliberately NOT here: this bar draws it as its own trash button outside the menu, while the macOS context menu
/// draws it as a plain menu item — two different shapes for the same one action, each still calling the same
/// `LibraryViewModel` method, so unifying it would force one of the two shapes onto the other for no shared benefit.
@MainActor
@ViewBuilder
func bulkActionMenuItems(
    availableShareFormats: [ScoreShareFormat],
    onShare: @escaping (ScoreShareFormat) -> Void,
    onAddToPlaylist: @escaping () -> Void,
    onEditTags: @escaping () -> Void,
    allFavorited: Bool,
    onFavorite: @escaping () -> Void,
) -> some View {
    // PARITY(macos): bulk Share formats — every format here ends in `ScoreShareTarget`, which only
    //   `ActivityViewControllerRepresentable` knows how to present, and that is iOS-only (see its own marker). The
    //   rows are omitted on macOS rather than shown opening an empty sheet; restoring them is the same one step as
    //   the row menu's Share — an `NSSharingServicePicker` behind `ScoreShareTarget`.
    #if os(iOS)
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
    #endif
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

#if os(macOS)
/// The bulk actions as the content of a right-click menu: `bulkActionMenuItems` plus the Delete the bar draws as a
/// separate trash button. `ScoreListView` and `PlaylistDetailView` both right-click into the same menu, so it lives
/// here once — the two screens differ only in what their `onDelete` does (soft-delete vs. a remove-or-delete
/// prompt), which is the closure they pass in, not the markup.
@MainActor
@ViewBuilder
func bulkActionsContextMenuItems(
    availableShareFormats: [ScoreShareFormat],
    onShare: @escaping (ScoreShareFormat) -> Void,
    onAddToPlaylist: @escaping () -> Void,
    onEditTags: @escaping () -> Void,
    allFavorited: Bool,
    onFavorite: @escaping () -> Void,
    onDelete: @escaping () -> Void,
) -> some View {
    bulkActionMenuItems(
        availableShareFormats: availableShareFormats,
        onShare: onShare,
        onAddToPlaylist: onAddToPlaylist,
        onEditTags: onEditTags,
        allFavorited: allFavorited,
        onFavorite: onFavorite,
    )
    Divider()
    Button(role: .destructive, action: onDelete) {
        Label {
            L10n.Common.delete
        } icon: {
            Image(systemName: "trash")
        }
    }
}
#endif

// Only the iOS branch of `bulkActionMenuItems` draws share rows, so this label switch has no macOS caller.
#if os(iOS)
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
    case .audioM4A:
        Label { Text("library.format.m4a", bundle: .module) } icon: { Image(systemName: "waveform") }
    }
}
#endif

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

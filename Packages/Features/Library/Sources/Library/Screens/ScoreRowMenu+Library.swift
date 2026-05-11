import Domain
import SwiftUI

/// Screen-tier convenience that wires `LibraryViewModel` into the pure
/// `scoreRowMenu` builder. Used by every Screen that renders a score row.
@MainActor
func scoreRowMenu(
    item: ScoreItem,
    library: LibraryViewModel,
    onOpen: @escaping (ScoreItem) -> Void,
    onRename: @escaping (ScoreItem) -> Void,
    onEditTags: @escaping (ScoreItem) -> Void,
    onAddToPlaylist: @escaping (ScoreItem) -> Void,
    onRequestDelete: ((ScoreItem) -> Void)?,
) -> some View {
    scoreRowMenu(
        item: item,
        loadShareFormats: { [shareService = library.shareService] in
            await shareService.availableFormats(for: item)
        },
        onOpen: onOpen,
        onToggleFavorite: { item in Task { await library.toggleFavorite(item) } },
        onRename: onRename,
        onEditTags: onEditTags,
        onAddToPlaylist: onAddToPlaylist,
        onShare: { format in Task { await library.requestShare(item, format: format) } },
        onRequestDelete: onRequestDelete,
    )
}

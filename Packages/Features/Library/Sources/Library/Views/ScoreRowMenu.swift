import Domain
import ScoreUI
import SwiftUI
import UtilityUI

/// Pure menu builder used by the trailing ellipsis menus and context-menus across the Library feature. Takes plain
/// Domain values and closures so it can be reused from any Screen and rendered in `#Preview`.
@MainActor
@ViewBuilder
func scoreRowMenu(
    item: ScoreItem,
    loadShareFormats: @escaping @Sendable () async -> [ScoreShareFormatOption],
    onOpen: @escaping (ScoreItem) -> Void,
    onToggleFavorite: @escaping (ScoreItem) -> Void,
    onEditInfo: @escaping (ScoreItem) -> Void,
    onEditTags: @escaping (ScoreItem) -> Void,
    onAddToPlaylist: @escaping (ScoreItem) -> Void,
    onShare: @escaping (ScoreShareFormat) -> Void,
    onRequestDelete: ((ScoreItem) -> Void)?,
) -> some View {
    Button { onOpen(item) } label: {
        Label {
            L10n.Common.open
        } icon: {
            Image(systemName: "music.note")
        }
    }
    Button { onToggleFavorite(item) } label: {
        Label {
            Text(item.isFavorite ? "library.score.unfavorite.action" : "library.score.favorite.action", bundle: .module)
        } icon: {
            Image(systemName: item.isFavorite ? "star.slash" : "star")
        }
    }
    Button { onEditInfo(item) } label: {
        Label {
            Text("library.score.editInfo.action", bundle: .module)
        } icon: {
            Image(systemName: "square.and.pencil")
        }
    }
    Button { onEditTags(item) } label: {
        Label {
            Text("library.tags.edit.action", bundle: .module)
        } icon: {
            Image(systemName: "tag")
        }
    }
    Button { onAddToPlaylist(item) } label: {
        Label {
            Text("library.playlist.add.actionEllipsis", bundle: .module)
        } icon: {
            Image(systemName: "music.note.list")
        }
    }

    Divider()
    ShareSubmenu(loadFormats: loadShareFormats, onShare: onShare)

    if let onRequestDelete {
        Divider()
        Button(role: .destructive) { onRequestDelete(item) } label: {
            Label {
                L10n.Common.delete
            } icon: {
                Image(systemName: "trash")
            }
        }
    }
}

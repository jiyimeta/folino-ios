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
    onOpenInVocalTuner: @escaping () -> Void,
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

    // PARITY(macos): score-row Share and Open in VocalTuner — both end in `ScoreShareTarget`, which only
    //   `ActivityViewControllerRepresentable` knows how to present, and that is iOS-only (see its own marker); the
    //   Mac has no VocalTuner to hand off to either, so its `VocalTunerHandoff` is the no-op one and the row would
    //   do nothing at all. The whole submenu is omitted on macOS rather than left opening an empty sheet. What
    //   macOS needs is an `NSSharingServicePicker` behind `ScoreShareTarget`; the companion row comes back with it
    //   only if VocalTuner ships a Mac app.
    #if os(iOS)
    Divider()
    ShareSubmenu(
        loadFormats: loadShareFormats, onShare: onShare, companionAction: onOpenInVocalTuner,
    )
    #endif

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

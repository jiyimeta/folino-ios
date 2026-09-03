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
    let companionHandoff = companionHandoffAction(onOpenInVocalTuner)

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

    // PARITY(macos): score-row Open in VocalTuner — the companion row is omitted on macOS because the Mac's
    //   `VocalTunerHandoff` is the no-op one: the hand-off rides the cross-app App Group, which the Mac does not
    //   join (`AppPaths.sharedContainer` is nil there, Ⅷ §2). It comes back with the App Group tasks, and only if
    //   VocalTuner ships a Mac app.
    Divider()
    ShareSubmenu(
        loadFormats: loadShareFormats, onShare: onShare, companionAction: companionHandoff,
    )

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

/// `nil` on macOS — see the marker at the call site. A computed value rather than an `#if` inside the call, because
/// an `#if` in a view builder's argument list is what SwiftFormat's `--ifdef no-indent` fights on every commit.
private func companionHandoffAction(_ action: @escaping () -> Void) -> (() -> Void)? {
    #if os(iOS)
    action
    #else
    nil
    #endif
}

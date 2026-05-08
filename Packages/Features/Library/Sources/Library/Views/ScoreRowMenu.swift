import Domain
import SwiftUI
import UtilityUI

/// Pure menu builder used by the trailing ellipsis menus and context-menus
/// across the Library feature. Takes plain Domain values and closures so it
/// can be reused from any Screen and rendered in `#Preview`.
@MainActor
@ViewBuilder
func scoreRowMenu(
    item: ScoreItem,
    availableFormats: [ScoreShareFormat],
    onOpen: @escaping (ScoreItem) -> Void,
    onToggleFavorite: @escaping (ScoreItem) -> Void,
    onEditTags: @escaping (ScoreItem) -> Void,
    onAddToPlaylist: @escaping (ScoreItem) -> Void,
    onShare: @escaping (ScoreShareFormat) -> Void,
    onRequestDelete: ((ScoreItem) -> Void)?
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
    shareSubmenu(
        availableFormats: availableFormats,
        onShare: onShare
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

@MainActor
@ViewBuilder
private func shareSubmenu(
    availableFormats: [ScoreShareFormat],
    onShare: @escaping (ScoreShareFormat) -> Void
) -> some View {
    Menu {
        ForEach(availableFormats, id: \.self) { format in
            Button {
                onShare(format)
            } label: {
                shareMenuLabel(format: format)
            }
        }
    } label: {
        Label {
            L10n.Common.share
        } icon: {
            Image(systemName: "square.and.arrow.up")
        }
    }
}

@MainActor
@ViewBuilder
private func shareMenuLabel(format: ScoreShareFormat) -> some View {
    switch format {
    case .msczOriginal:
        Label { Text("library.format.musescore", bundle: .module) } icon: { Image(systemName: "doc.zipper") }
    case .msczMuseScore4:
        Label { Text("library.format.musescore4", bundle: .module) } icon: { Image(systemName: "doc.zipper") }
    case .msczMuseScore3:
        Label { Text("library.format.musescore3", bundle: .module) } icon: { Image(systemName: "doc.zipper") }
    case .pdf:
        Label { Text("library.format.pdf", bundle: .module) } icon: { Image(systemName: "doc.richtext") }
    case .midi:
        Label { Text("library.format.midi", bundle: .module) } icon: { Image(systemName: "pianokeys") }
    }
}

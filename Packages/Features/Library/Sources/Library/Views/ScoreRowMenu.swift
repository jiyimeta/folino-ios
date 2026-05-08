import Domain
import SwiftUI

/// Pure menu builder used by the trailing ellipsis menus and context-menus
/// across the Library feature. Takes plain Domain values and closures so it
/// can be reused from any Screen and rendered in `#Preview`.
@MainActor
@ViewBuilder
func scoreRowMenu(
    item: ScoreItem,
    availableFormats: [ScoreShareFormat],
    resolvedSourceFormat: ScoreFormat,
    onOpen: @escaping (ScoreItem) -> Void,
    onToggleFavorite: @escaping (ScoreItem) -> Void,
    onEditTags: @escaping (ScoreItem) -> Void,
    onAddToPlaylist: @escaping (ScoreItem) -> Void,
    onShare: @escaping (ScoreShareFormat) -> Void,
    onRequestDelete: ((ScoreItem) -> Void)?
) -> some View {
    Button { onOpen(item) } label: {
        Label {
            Text("Open", bundle: .module)
        } icon: {
            Image(systemName: "music.note")
        }
    }
    Button { onToggleFavorite(item) } label: {
        Label {
            Text(item.isFavorite ? "Unfavorite" : "Favorite", bundle: .module)
        } icon: {
            Image(systemName: item.isFavorite ? "star.slash" : "star")
        }
    }
    Button { onEditTags(item) } label: {
        Label {
            Text("Edit Tags…", bundle: .module)
        } icon: {
            Image(systemName: "tag")
        }
    }
    Button { onAddToPlaylist(item) } label: {
        Label {
            Text("Add to Playlist…", bundle: .module)
        } icon: {
            Image(systemName: "music.note.list")
        }
    }

    Divider()
    shareSubmenu(
        availableFormats: availableFormats,
        resolvedSourceFormat: resolvedSourceFormat,
        onShare: onShare
    )

    if let onRequestDelete {
        Divider()
        Button(role: .destructive) { onRequestDelete(item) } label: {
            Label {
                Text("Delete", bundle: .module)
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
    resolvedSourceFormat: ScoreFormat,
    onShare: @escaping (ScoreShareFormat) -> Void
) -> some View {
    Menu {
        ForEach(availableFormats, id: \.self) { format in
            Button {
                onShare(format)
            } label: {
                shareMenuLabel(format: format, resolvedSourceFormat: resolvedSourceFormat)
            }
        }
    } label: {
        Label {
            Text("Share…", bundle: .module)
        } icon: {
            Image(systemName: "square.and.arrow.up")
        }
    }
}

@MainActor
@ViewBuilder
private func shareMenuLabel(
    format: ScoreShareFormat,
    resolvedSourceFormat: ScoreFormat
) -> some View {
    switch format {
    case .sourceFormat:
        switch resolvedSourceFormat {
        case .mscz, .mscx:
            Label("MuseScore (.mscz)", systemImage: "doc.zipper")
        case .musicXML:
            Label("MusicXML (.musicxml)", systemImage: "doc.text")
        case .mxl:
            Label("MusicXML (.mxl)", systemImage: "doc.zipper")
        case .midi:
            Label("MIDI", systemImage: "pianokeys")
        }
    case .pdf:
        Label("PDF", systemImage: "doc.richtext")
    case .midi:
        Label("MIDI", systemImage: "pianokeys")
    }
}

import Domain
import SwiftUI

/// Single source of truth for the row menu used by both context-menus
/// and trailing ellipsis menus across the Library feature.
@MainActor
@ViewBuilder
func scoreRowMenu(
    item: ScoreItem,
    library: LibraryViewModel,
    onOpen: @escaping (ScoreItem) -> Void,
    onEditTags: @escaping (ScoreItem) -> Void,
    onAddToPlaylist: @escaping (ScoreItem) -> Void,
    onRequestDelete: ((ScoreItem) -> Void)?
) -> some View {
    Button { onOpen(item) } label: {
        Label {
            Text("Open", bundle: .module)
        } icon: {
            Image(systemName: "music.note")
        }
    }
    Button { Task { await library.toggleFavorite(item) } } label: {
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
    shareSubmenu(item: item, library: library)

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
private func shareSubmenu(item: ScoreItem, library: LibraryViewModel) -> some View {
    Menu {
        ForEach(library.shareService.availableFormats(for: item), id: \.self) { format in
            Button {
                Task { await library.requestShare(item, format: format) }
            } label: {
                shareMenuLabel(item: item, format: format, library: library)
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
    item: ScoreItem,
    format: ScoreShareFormat,
    library: LibraryViewModel
) -> some View {
    switch format {
    case .sourceFormat:
        let resolved = library.shareService.resolvedSourceFormat(for: item)
        switch resolved {
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

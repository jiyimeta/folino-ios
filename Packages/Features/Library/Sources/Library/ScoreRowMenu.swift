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
        Label("Open", systemImage: "music.note")
    }
    Button { Task { await library.toggleFavorite(item) } } label: {
        Label(
            item.isFavorite ? "Unfavorite" : "Favorite",
            systemImage: item.isFavorite ? "star.slash" : "star"
        )
    }
    Button { onEditTags(item) } label: {
        Label("Edit Tags…", systemImage: "tag")
    }
    Button { onAddToPlaylist(item) } label: {
        Label("Add to Playlist…", systemImage: "music.note.list")
    }

    Divider()
    shareSubmenu(item: item, library: library)

    if let onRequestDelete {
        Divider()
        Button(role: .destructive) { onRequestDelete(item) } label: {
            Label("Delete", systemImage: "trash")
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
        Label("Share…", systemImage: "square.and.arrow.up")
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

import Domain
import SwiftUI

struct BulkActionBar: View {
    let selectionCount: Int
    let availableShareFormats: [ScoreShareFormat]
    let onShare: (ScoreShareFormat) -> Void
    let onAddToPlaylist: () -> Void
    let onEditTags: () -> Void
    let onDelete: () -> Void

    var body: some View {
        #if os(iOS)
            iOSBody
        #else
            macOSBody
        #endif
    }

    #if os(iOS)
        @ViewBuilder
        private var iOSBody: some View {
            HStack(spacing: 12) {
                Menu {
                    actionMenuContent
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 48, height: 48)
                }
                .tint(.primary)
                .accessibilityLabel(Text("More", bundle: .module))
                .glassEffect(.regular.interactive())

                Spacer(minLength: 0)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: 48, height: 48)
                }
                .tint(.red)
                .accessibilityLabel(Text("Delete", bundle: .module))
                .glassEffect(.regular.interactive())
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
                    Text("Add to Playlist…", bundle: .module)
                } icon: {
                    Image(systemName: "music.note.list")
                }
            }
            Button(action: onEditTags) {
                Label {
                    Text("Add Tags…", bundle: .module)
                } icon: {
                    Image(systemName: "tag")
                }
            }
        }
    #else
        @ViewBuilder
        private var macOSBody: some View {
            HStack {
                Menu("More") {
                    Button("Add to Playlist", action: onAddToPlaylist)
                    Button("Add Tags", action: onEditTags)
                }
                Spacer()
                Button("Delete", role: .destructive, action: onDelete)
            }
            .padding()
            .disabled(selectionCount == 0)
        }
    #endif
}

@MainActor
@ViewBuilder
private func bulkShareFormatLabel(_ format: ScoreShareFormat) -> some View {
    switch format {
    case .sourceFormat:
        Label {
            Text("Original Format", bundle: .module)
        } icon: {
            Image(systemName: "doc")
        }
    case .pdf:
        Label("PDF", systemImage: "doc.richtext")
    case .midi:
        Label("MIDI", systemImage: "pianokeys")
    }
}

#if DEBUG && os(iOS)
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
                    onDelete: {}
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
            onDelete: {}
        )
    }
#endif

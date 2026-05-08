import Domain
import SwiftUI
import UtilityUI

struct TagsListView: View {
    let tags: [Tag]
    let memberCount: (Tag) -> Int
    let onCreate: (String) -> Void

    @State private var isCreating = false
    @State private var newTagName: String = ""

    var body: some View {
        Group {
            if tags.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("library.tags.empty.title", bundle: .module)
                    } icon: {
                        Image(systemName: "tag")
                    }
                } description: {
                    Text("library.tags.empty.hint", bundle: .module)
                }
            } else {
                List {
                    ForEach(tags) { tag in
                        NavigationLink(value: LibraryRoute.tagDetail(tag.id)) {
                            HStack {
                                Image(systemName: "tag.fill")
                                    .foregroundStyle(.tint)
                                Text(tag.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(memberCount(tag), format: .number)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(Text("library.tags", bundle: .module))
        .toolbar { newTagToolbar }
        .alert(Text("library.tag.create.title", bundle: .module), isPresented: $isCreating) {
            TextField(text: $newTagName) { Text("library.tag.namePlaceholder", bundle: .module) }
            Button {
                let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onCreate(trimmed)
                newTagName = ""
            } label: {
                L10n.Common.add
            }
            Button(role: .cancel) {} label: { L10n.Common.cancel }
        } message: {
            Text("library.tag.create.message", bundle: .module)
        }
    }

    @ToolbarContentBuilder
    private var newTagToolbar: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) { newTagButton }
        #else
            ToolbarItem(placement: .automatic) { newTagButton }
        #endif
    }

    private var newTagButton: some View {
        Button {
            newTagName = ""
            isCreating = true
        } label: {
            Image(systemName: "plus").accessibilityLabel(Text("library.tag.create.title", bundle: .module))
        }
    }
}

#if DEBUG
    private struct TagsListViewPreviewHost: View {
        let tags: [Tag]
        var body: some View {
            NavigationStack {
                TagsListView(
                    tags: tags,
                    memberCount: { _ in Int.random(in: 0 ... 12) },
                    onCreate: { _ in }
                )
            }
        }
    }

    #Preview("Filled") {
        TagsListViewPreviewHost(tags: [
            Tag(name: "Practice", colorHex: "#5856D6"),
            Tag(name: "Recital", colorHex: "#FF9500"),
            Tag(name: "Sight reading", colorHex: "#34C759"),
        ])
    }

    #Preview("Empty") {
        TagsListViewPreviewHost(tags: [])
    }
#endif

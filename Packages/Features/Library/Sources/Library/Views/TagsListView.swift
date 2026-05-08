import Domain
import SwiftUI
import UtilityUI

struct TagsListView: View {
    let tags: [Tag]
    let memberCount: (Tag) -> Int
    let onCreate: (String) -> Void

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
        .createEntityToolbar(copy: .tag, onCreate: onCreate)
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

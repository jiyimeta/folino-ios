import Domain
import SwiftUI

struct TagsListScreen: View {
    let library: LibraryViewModel

    var body: some View {
        TagsListView(
            tags: sortedTags,
            memberCount: memberCount(of:),
            onCreate: { name in
                Task { await library.createTag(name: name) }
            }
        )
    }

    private var sortedTags: [Tag] {
        library.repository.tags.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func memberCount(of tag: Tag) -> Int {
        library.repository.scoreItems.reduce(0) { acc, item in
            acc + (item.tagIDs.contains(tag.id) ? 1 : 0)
        }
    }
}

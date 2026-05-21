import Domain
import Foundation
import LibraryLogic
import SwiftUI

struct BulkEditTagsScreen: View {
    let selectedIDs: Set<ScoreItemID>
    let library: LibraryStore
    let onCommit: () -> Void

    var body: some View {
        BulkEditTagsSheet(
            selectionCount: selectedIDs.count,
            allTags: library.tags,
            onCommit: { tagIDs in Task { await commitUnion(tagIDs) } },
            onCreateTag: { name in Task { await commitCreate(name) } },
        )
    }

    private func commitUnion(_ tagIDs: Set<TagID>) async {
        await library.bulkAddTags(selectedIDs, tagIDs: tagIDs)
        onCommit()
    }

    private func commitCreate(_ name: String) async {
        let tag = Tag(name: name, colorHex: "#5856D6")
        await library.saveTag(tag)
        guard library.tags.contains(where: { $0.id == tag.id }) else { return }
        await library.bulkAddTags(selectedIDs, tagIDs: [tag.id])
        onCommit()
    }
}

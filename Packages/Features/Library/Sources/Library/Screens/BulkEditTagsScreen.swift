import Domain
import Foundation
import SwiftUI
import UtilityCore

struct BulkEditTagsScreen: View {
    let selectedIDs: Set<ScoreItemID>
    let library: LibraryViewModel
    let onCommit: () -> Void

    var body: some View {
        BulkEditTagsSheet(
            selectionCount: selectedIDs.count,
            allTags: library.repository.tags,
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
        do {
            try await library.repository.saveTag(tag)
            library.analytics.log(.tagCreated(source: .bulkEdit))
        } catch {
            library.currentError = error
            return
        }
        await library.bulkAddTags(selectedIDs, tagIDs: [tag.id])
        onCommit()
    }
}

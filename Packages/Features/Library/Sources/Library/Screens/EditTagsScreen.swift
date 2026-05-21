import Domain
import LibraryLogic
import SwiftUI

struct EditTagsScreen: View {
    let scoreItem: ScoreItem
    let library: LibraryStore

    var body: some View {
        EditTagsSheet(
            scoreTitle: scoreItem.title,
            assignedTagIDs: currentScoreItem().tagIDs,
            allTags: library.tags,
            onToggle: { tag in Task { await toggle(tag) } },
            onCreate: { name in Task { await commitNewTag(name) } },
        )
    }

    private func toggle(_ tag: Tag) async {
        var updated = currentScoreItem()
        if updated.tagIDs.contains(tag.id) {
            updated.tagIDs.remove(tag.id)
        } else {
            updated.tagIDs.insert(tag.id)
        }
        await library.save(updated)
    }

    private func commitNewTag(_ name: String) async {
        let tag = Tag(name: name, colorHex: "#5856D6")
        await library.saveTag(tag)
        // Only proceed to assign the tag if it was actually persisted (no error).
        guard library.tags.contains(where: { $0.id == tag.id }) else { return }
        var updated = currentScoreItem()
        updated.tagIDs.insert(tag.id)
        await library.save(updated)
    }

    /// Re-read from the repository on each operation in case other operations have mutated the score's tagIDs while
    /// this sheet is open.
    private func currentScoreItem() -> ScoreItem {
        library.scoreItems.first(where: { $0.id == scoreItem.id }) ?? scoreItem
    }
}

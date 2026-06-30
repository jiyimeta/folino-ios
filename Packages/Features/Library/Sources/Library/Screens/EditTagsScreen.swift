import Domain
import SwiftUI
import UtilityCore

struct EditTagsScreen: View {
    let scoreItem: ScoreItem
    let library: LibraryViewModel

    var body: some View {
        EditTagsSheet(
            scoreTitle: scoreItem.title,
            assignedTagIDs: currentScoreItem().tagIDs,
            allTags: library.repository.tags,
            onToggle: { tag in Task { await toggle(tag) } },
            onCreate: { name in Task { await commitNewTag(name) } },
        )
    }

    private func toggle(_ tag: Tag) async {
        var updated = currentScoreItem()
        let wasAssigned = updated.tagIDs.contains(tag.id)
        if wasAssigned {
            updated.tagIDs.remove(tag.id)
        } else {
            updated.tagIDs.insert(tag.id)
        }
        do {
            try await library.repository.saveScoreItem(updated)
            if wasAssigned {
                library.analytics.log(.tagUnassigned(source: .scoreRowMenu, count: 1))
            } else {
                library.analytics.log(.tagAssigned(source: .scoreRowMenu, count: 1))
            }
        } catch {
            library.currentError = error
        }
    }

    private func commitNewTag(_ name: String) async {
        let tag = Tag(name: name, colorHex: "#5856D6")
        do {
            try await library.repository.saveTag(tag)
        } catch {
            return
        }
        library.analytics.log(.tagCreated(source: .scoreRowMenu))
        var updated = currentScoreItem()
        updated.tagIDs.insert(tag.id)
        do {
            try await library.repository.saveScoreItem(updated)
            library.analytics.log(.tagAssigned(source: .scoreRowMenu, count: 1))
        } catch {
            library.currentError = error
        }
    }

    /// Re-read from the repository on each operation in case other operations have mutated the score's tagIDs while
    /// this sheet is open.
    private func currentScoreItem() -> ScoreItem {
        library.repository.scoreItems.first(where: { $0.id == scoreItem.id }) ?? scoreItem
    }
}

import Domain
import SwiftUI

struct EditTagsSheet: View {
    let scoreItem: ScoreItem
    let library: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var newTagName: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.repository.tags) { tag in
                        Button {
                            Task { await toggle(tag) }
                        } label: {
                            HStack {
                                Image(
                                    systemName: scoreItem.tagIDs.contains(tag.id)
                                        ? "checkmark.circle.fill" : "circle"
                                )
                                .foregroundStyle(.tint)
                                Text(tag.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                    }
                }
                Section {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                        TextField("New tag", text: $newTagName)
                            .submitLabel(.done)
                            .onSubmit { Task { await commitNewTag() } }
                    }
                }
            }
            .navigationTitle("Tags for \"\(scoreItem.title)\"")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar { doneToolbar }
        }
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        #else
            ToolbarItem(placement: .automatic) {
                Button("Done") { dismiss() }
            }
        #endif
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

    private func commitNewTag() async {
        let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tag = Tag(name: trimmed, colorHex: "#5856D6")
        do {
            try await library.repository.saveTag(tag)
        } catch {
            return
        }
        var updated = currentScoreItem()
        updated.tagIDs.insert(tag.id)
        await library.save(updated)
        newTagName = ""
    }

    /// Re-read from the repository on each operation in case other operations
    /// have mutated the score's tagIDs while this sheet is open.
    private func currentScoreItem() -> ScoreItem {
        library.repository.scoreItems.first(where: { $0.id == scoreItem.id }) ?? scoreItem
    }
}

import Domain
import SwiftUI
import UtilityUI

struct EditTagsSheet: View {
    let scoreTitle: String
    let assignedTagIDs: Set<TagID>
    let allTags: [Tag]
    let onToggle: (Tag) -> Void
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newTagName: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(allTags) { tag in
                        Button {
                            onToggle(tag)
                        } label: {
                            HStack {
                                Image(
                                    systemName: assignedTagIDs.contains(tag.id)
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
                        TextField(text: $newTagName) { Text("library.tag.create.placeholder", bundle: .module) }
                            .submitLabel(.done)
                            .onSubmit { commitNewTag() }
                    }
                }
            }
            .navigationTitle(Text(String(
                localized: "library.tags.editScore.title",
                defaultValue: "Tags for \"\(scoreTitle)\"",
                bundle: .module
            )))
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
                Button { dismiss() } label: { L10n.Common.done }
            }
        #else
            ToolbarItem(placement: .automatic) {
                Button { dismiss() } label: { L10n.Common.done }
            }
        #endif
    }

    private func commitNewTag() {
        let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        newTagName = ""
    }
}

#if DEBUG
    #Preview("Mixed selection") {
        struct Host: View {
            @State private var assigned: Set<TagID>
            let tags: [Tag]
            init() {
                let tags = [
                    Tag(name: "Practice", colorHex: "#5856D6"),
                    Tag(name: "Recital", colorHex: "#FF9500"),
                    Tag(name: "Sight reading", colorHex: "#34C759"),
                ]
                self.tags = tags
                _assigned = State(initialValue: [tags[0].id])
            }

            var body: some View {
                EditTagsSheet(
                    scoreTitle: "Clair de Lune",
                    assignedTagIDs: assigned,
                    allTags: tags,
                    onToggle: { tag in
                        if assigned.contains(tag.id) { assigned.remove(tag.id) } else { assigned.insert(tag.id) }
                    },
                    onCreate: { _ in }
                )
            }
        }
        return Host()
    }
#endif

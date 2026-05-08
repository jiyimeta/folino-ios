import Domain
import SwiftUI

struct BulkEditTagsSheet: View {
    let selectionCount: Int
    let allTags: [Tag]
    let onCommit: (Set<TagID>) -> Void
    let onCreateTag: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var checked: Set<TagID> = []
    @State private var newTagName: String = ""

    var body: some View {
        NavigationStack {
            List {
                tagsSection
                createSection
            }
            .navigationTitle(Text("Tags for \(selectionCount) scores", bundle: .module))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar { toolbarItems }
        }
    }

    @ViewBuilder
    private var tagsSection: some View {
        Section {
            ForEach(allTags) { tag in
                Button {
                    if checked.contains(tag.id) { checked.remove(tag.id) } else { checked.insert(tag.id) }
                } label: {
                    HStack {
                        Image(systemName: checked.contains(tag.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(.tint)
                        Text(tag.name)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var createSection: some View {
        Section {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.tint)
                TextField(text: $newTagName) { Text("New tag", bundle: .module) }
                    .submitLabel(.done)
                    .onSubmit { commitNewTag() }
                Button { commitNewTag() } label: {
                    Text("Create", bundle: .module)
                }
                .buttonStyle(.borderless)
                .disabled(trimmedNewTagName.isEmpty)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Text("Cancel", bundle: .module) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { onCommit(checked) } label: { Text("Done", bundle: .module) }
                    .disabled(checked.isEmpty)
            }
        #else
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Text("Cancel", bundle: .module) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button { onCommit(checked) } label: { Text("Done", bundle: .module) }
                    .disabled(checked.isEmpty)
            }
        #endif
    }

    private var trimmedNewTagName: String {
        newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitNewTag() {
        let trimmed = trimmedNewTagName
        guard !trimmed.isEmpty else { return }
        onCreateTag(trimmed)
        newTagName = ""
    }
}

#if DEBUG
    #Preview {
        BulkEditTagsSheet(
            selectionCount: 3,
            allTags: [
                Tag(name: "Practice", colorHex: "#5856D6"),
                Tag(name: "Recital", colorHex: "#FF9500"),
            ],
            onCommit: { _ in },
            onCreateTag: { _ in }
        )
    }
#endif

import Domain
import SwiftUI
import UtilityUI

struct BulkEditTagsSheet: View {
    let selectionCount: Int
    let allTags: [Tag]
    let onCommit: (Set<TagID>) -> Void
    let onCreateTag: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var checked: Set<TagID> = []
    @State private var newTagName = ""

    var body: some View {
        NavigationStack {
            List {
                tagsSection
                createSection
            }
            .navigationTitle(Text(String(
                localized: "library.tags.editBulk.title",
                defaultValue: "Tags for \(selectionCount) scores",
                bundle: .module,
            )))
            .inlineNavigationTitleCompat()
            .toolbar { toolbarItems }
        }
        .listSheetSizeCompat()
    }

    private var tagsSection: some View {
        Section {
            ForEach(allTags) { tag in
                Button {
                    if checked.contains(tag.id) {
                        checked.remove(tag.id)
                    } else {
                        checked.insert(tag.id)
                    }
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

    private var createSection: some View {
        Section {
            InlineCreateRow(
                name: $newTagName,
                placeholder: "library.tag.create.placeholder",
                onCreate: onCreateTag,
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: { L10n.Common.cancel }
        }
        // Stays on the compat helper: `.confirmationAction` renders this Done semibold on iOS, where it is
        // regular today — measured against this file's preview (Task 16). See `PlatformToolbarCompat`.
        ToolbarItem(placement: .topBarTrailingCompat) {
            Button { onCommit(checked) } label: { L10n.Common.done }
                .disabled(checked.isEmpty)
        }
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
        onCreateTag: { _ in },
    )
}
#endif

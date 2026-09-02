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
    @State private var newTagName = ""

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
                                        ? "checkmark.circle.fill" : "circle",
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
                    InlineCreateRow(
                        name: $newTagName,
                        placeholder: "library.tag.create.placeholder",
                        onCreate: onCreate,
                    )
                }
            }
            .navigationTitle(Text(String(
                localized: "library.tags.editScore.title",
                defaultValue: "Tags for \"\(scoreTitle)\"",
                bundle: .module,
            )))
            .inlineNavigationTitleCompat()
            .toolbar { doneToolbar }
        }
        .listSheetSizeCompat()
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        // Stays on the compat helper: `.confirmationAction` renders this Done semibold on iOS, where it is
        // regular today — 1492 pixels, all inside the button, measured against this file's preview (Task 16).
        // See `PlatformViewCompat`.
        ToolbarItem(placement: .topBarTrailingCompat) {
            Button { dismiss() } label: { L10n.Common.done }
        }
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
                    if assigned.contains(tag.id) {
                        assigned.remove(tag.id)
                    } else {
                        assigned.insert(tag.id)
                    }
                },
                onCreate: { _ in },
            )
        }
    }
    return Host()
}
#endif

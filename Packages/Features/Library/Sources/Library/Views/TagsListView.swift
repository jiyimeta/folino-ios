import Domain
import SwiftUI
import UtilityUI

struct TagsListView: View {
    let tags: [Tag]
    let memberCount: (Tag) -> Int
    let onCreate: (String) -> Void
    let onDelete: (Tag) -> Void

    @State private var pendingDelete: Tag?

    var body: some View {
        Group {
            if tags.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("library.tags.empty.title", bundle: .module)
                    } icon: {
                        Image(systemName: "tag")
                    }
                } description: {
                    Text("library.tags.empty.hint", bundle: .module)
                }
            } else {
                List {
                    ForEach(tags) { tag in
                        NavigationLink(value: LibraryRoute.tagDetail(tag.id)) {
                            HStack {
                                Image(systemName: "tag.fill")
                                    .foregroundStyle(.tint)
                                Text(tag.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(memberCount(tag), format: .number)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // No `role: .destructive` — see `LibraryRootScreen.sectionRow`.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                pendingDelete = tag
                            } label: {
                                Label {
                                    L10n.Common.delete
                                } icon: {
                                    Image(systemName: "trash")
                                }
                            }
                            .tint(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle(Text("library.tags", bundle: .module))
        .createEntityToolbar(copy: .tag, onCreate: onCreate)
        .alert(
            Text(String(
                localized: "library.score.delete.title",
                defaultValue: "Delete \"\(pendingDelete?.name ?? "")\"?",
                bundle: .module,
            )),
            isPresented: deleteAlertBinding,
            presenting: pendingDelete,
        ) { tag in
            Button(role: .destructive) {
                onDelete(tag)
            } label: {
                L10n.Common.delete
            }
            Button(role: .cancel) {} label: {
                L10n.Common.cancel
            }
        } message: { _ in
            Text("library.tag.delete.message", bundle: .module)
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { isPresented in if !isPresented { pendingDelete = nil } },
        )
    }
}

#if DEBUG
private struct TagsListViewPreviewHost: View {
    let tags: [Tag]
    var body: some View {
        NavigationStack {
            TagsListView(
                tags: tags,
                memberCount: { _ in Int.random(in: 0 ... 12) },
                onCreate: { _ in },
                onDelete: { _ in },
            )
        }
    }
}

#Preview("Filled") {
    TagsListViewPreviewHost(tags: [
        Tag(name: "Practice", colorHex: "#5856D6"),
        Tag(name: "Recital", colorHex: "#FF9500"),
        Tag(name: "Sight reading", colorHex: "#34C759"),
    ])
}

#Preview("Empty") {
    TagsListViewPreviewHost(tags: [])
}
#endif

import Domain
import SwiftUI

struct TagsListView: View {
    let library: LibraryViewModel

    @State private var isCreating = false
    @State private var newTagName: String = ""

    var body: some View {
        Group {
            if sortedTags.isEmpty {
                ContentUnavailableView {
                    Label("No Tags", systemImage: "tag")
                } description: {
                    Text("Add tags from a score's context menu, or tap + above.")
                }
            } else {
                List {
                    ForEach(sortedTags) { tag in
                        NavigationLink(value: LibraryRoute.tagDetail(tag.id)) {
                            HStack {
                                Image(systemName: "tag.fill")
                                    .foregroundStyle(.tint)
                                Text(tag.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(memberCount(of: tag), format: .number)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Tags")
        .toolbar { newTagToolbar }
        .alert("New Tag", isPresented: $isCreating) {
            TextField("Tag name", text: $newTagName)
            Button("Add") { Task { await commit() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new tag.")
        }
    }

    @ToolbarContentBuilder
    private var newTagToolbar: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) { newTagButton }
        #else
            ToolbarItem(placement: .automatic) { newTagButton }
        #endif
    }

    private var newTagButton: some View {
        Button {
            newTagName = ""
            isCreating = true
        } label: {
            Image(systemName: "plus").accessibilityLabel("New Tag")
        }
    }

    private var sortedTags: [Tag] {
        library.repository.tags.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func memberCount(of tag: Tag) -> Int {
        library.repository.scoreItems.reduce(0) { acc, item in
            acc + (item.tagIDs.contains(tag.id) ? 1 : 0)
        }
    }

    private func commit() async {
        let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tag = Tag(name: trimmed, colorHex: "#5856D6")
        do {
            try await library.repository.saveTag(tag)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}

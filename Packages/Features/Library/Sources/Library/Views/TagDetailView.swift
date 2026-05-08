import Domain
import SwiftUI

struct TagDetailView<Content: View>: View {
    let tagName: String
    let onRename: (String) -> Void
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isRenaming = false
    @State private var renameText: String = ""
    @State private var isConfirmingDelete = false

    var body: some View {
        content()
            .navigationTitle(tagName)
            .toolbar { editMenuToolbar }
            .alert(Text("Rename Tag", bundle: .module), isPresented: $isRenaming) {
                TextField(text: $renameText) { Text("Tag name", bundle: .module) }
                Button {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed != tagName else { return }
                    onRename(trimmed)
                } label: { Text("Save", bundle: .module) }
                Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
            }
            .alert(
                Text("Delete \"\(tagName)\"?", bundle: .module),
                isPresented: $isConfirmingDelete
            ) {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Text("Delete", bundle: .module)
                }
                Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
            } message: {
                Text("Scores keep their data; only the tag and its assignments are removed.", bundle: .module)
            }
    }

    @ToolbarContentBuilder
    private var editMenuToolbar: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) { editMenu }
        #else
            ToolbarItem(placement: .automatic) { editMenu }
        #endif
    }

    private var editMenu: some View {
        Menu {
            Button {
                renameText = tagName
                isRenaming = true
            } label: {
                Label {
                    Text("Rename…", bundle: .module)
                } icon: {
                    Image(systemName: "pencil")
                }
            }
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label {
                    Text("Delete Tag", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .accessibilityLabel(Text("Edit Tag", bundle: .module))
        }
    }
}

#if DEBUG
    #Preview {
        NavigationStack {
            TagDetailView(
                tagName: "Practice",
                onRename: { _ in },
                onDelete: {}
            ) {
                List {
                    Text("Score A")
                    Text("Score B")
                }
            }
        }
    }
#endif

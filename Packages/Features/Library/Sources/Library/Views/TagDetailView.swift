import Domain
import SwiftUI
import UtilityUI

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
            .alert(Text("library.tag.rename.title", bundle: .module), isPresented: $isRenaming) {
                TextField(text: $renameText) { Text("library.tag.namePlaceholder", bundle: .module) }
                Button {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed != tagName else { return }
                    onRename(trimmed)
                } label: { L10n.Common.save }
                Button(role: .cancel) {} label: { L10n.Common.cancel }
            }
            .alert(
                Text(String(
                    localized: "library.score.delete.title",
                    defaultValue: "Delete \"\(tagName)\"?",
                    bundle: .module
                )),
                isPresented: $isConfirmingDelete
            ) {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    L10n.Common.delete
                }
                Button(role: .cancel) {} label: { L10n.Common.cancel }
            } message: {
                Text("library.tag.delete.message", bundle: .module)
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
                    L10n.Common.rename
                } icon: {
                    Image(systemName: "pencil")
                }
            }
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label {
                    Text("library.tag.delete.action", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .accessibilityLabel(Text("library.tag.edit.title", bundle: .module))
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

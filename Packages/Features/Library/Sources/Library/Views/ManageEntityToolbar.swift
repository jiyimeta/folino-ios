import SwiftUI
import UtilityUI

/// Localization keys for the leading "manage" ellipsis menu shown on
/// `PlaylistDetailView` / `TagDetailView`. Literals stay at the struct-init
/// sites so xcstringstool keeps extracting them.
struct ManageEntityCopy {
    let editAccessibilityLabelKey: LocalizedStringKey
    let renameTitleKey: LocalizedStringKey
    let renamePlaceholderKey: LocalizedStringKey
    let deleteActionKey: LocalizedStringKey
    let deleteMessageKey: LocalizedStringKey

    nonisolated(unsafe) static let playlist = ManageEntityCopy(
        editAccessibilityLabelKey: "library.playlist.edit.title",
        renameTitleKey: "library.playlist.rename.title",
        renamePlaceholderKey: "library.playlist.namePlaceholder",
        deleteActionKey: "library.playlist.delete.action",
        deleteMessageKey: "library.playlist.delete.message"
    )

    nonisolated(unsafe) static let tag = ManageEntityCopy(
        editAccessibilityLabelKey: "library.tag.edit.title",
        renameTitleKey: "library.tag.rename.title",
        renamePlaceholderKey: "library.tag.namePlaceholder",
        deleteActionKey: "library.tag.delete.action",
        deleteMessageKey: "library.tag.delete.message"
    )
}

private struct ManageEntityToolbarModifier: ViewModifier {
    let entityName: String
    let copy: ManageEntityCopy
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var isRenaming = false
    @State private var renameText: String = ""
    @State private var isConfirmingDelete = false

    func body(content: Content) -> some View {
        content
            .toolbar { manageToolbar }
            .alert(
                Text(copy.renameTitleKey, bundle: .module),
                isPresented: $isRenaming
            ) {
                TextField(text: $renameText) {
                    Text(copy.renamePlaceholderKey, bundle: .module)
                }
                Button {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed != entityName else { return }
                    onRename(trimmed)
                } label: { L10n.Common.save }
                Button(role: .cancel) {} label: { L10n.Common.cancel }
            }
            .alert(
                Text(String(
                    localized: "library.score.delete.title",
                    defaultValue: "Delete \"\(entityName)\"?",
                    bundle: .module
                )),
                isPresented: $isConfirmingDelete
            ) {
                Button(role: .destructive) {
                    onDelete()
                } label: { L10n.Common.delete }
                Button(role: .cancel) {} label: { L10n.Common.cancel }
            } message: {
                Text(copy.deleteMessageKey, bundle: .module)
            }
    }

    @ToolbarContentBuilder
    private var manageToolbar: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarLeading) { manageMenu }
        #else
            ToolbarItem(placement: .automatic) { manageMenu }
        #endif
    }

    private var manageMenu: some View {
        Menu {
            Button {
                renameText = entityName
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
                    Text(copy.deleteActionKey, bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .accessibilityLabel(Text(copy.editAccessibilityLabelKey, bundle: .module))
        }
    }
}

extension View {
    func manageEntityToolbar(
        entityName: String,
        copy: ManageEntityCopy,
        onRename: @escaping (String) -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        modifier(ManageEntityToolbarModifier(
            entityName: entityName,
            copy: copy,
            onRename: onRename,
            onDelete: onDelete
        ))
    }
}

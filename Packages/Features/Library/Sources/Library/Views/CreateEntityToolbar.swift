import SwiftUI
import UtilityUI

/// Localization keys for the trailing "+" create-entity toolbar shown on `PlaylistsListView` / `TagsListView`. Literals
/// stay at the struct-init sites so xcstringstool keeps extracting them.
struct CreateEntityCopy {
    let createTitleKey: LocalizedStringKey
    let createMessageKey: LocalizedStringKey
    let placeholderKey: LocalizedStringKey

    nonisolated(unsafe) static let playlist = CreateEntityCopy(
        createTitleKey: "library.playlist.create.title",
        createMessageKey: "library.playlist.create.message",
        placeholderKey: "library.playlist.namePlaceholder",
    )

    nonisolated(unsafe) static let tag = CreateEntityCopy(
        createTitleKey: "library.tag.create.title",
        createMessageKey: "library.tag.create.message",
        placeholderKey: "library.tag.namePlaceholder",
    )
}

private struct CreateEntityToolbarModifier: ViewModifier {
    let copy: CreateEntityCopy
    let onCreate: (String) -> Void

    @State private var isCreating = false
    @State private var newName = ""

    func body(content: Content) -> some View {
        content
            .toolbar { createToolbar }
            .alert(
                Text(copy.createTitleKey, bundle: .module),
                isPresented: $isCreating,
            ) {
                TextField(text: $newName) {
                    Text(copy.placeholderKey, bundle: .module)
                }
                Button {
                    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onCreate(trimmed)
                    newName = ""
                } label: {
                    L10n.Common.add
                }
                Button(role: .cancel) {} label: { L10n.Common.cancel }
            } message: {
                Text(copy.createMessageKey, bundle: .module)
            }
    }

    @ToolbarContentBuilder
    private var createToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailingCompat) { createButton }
    }

    private var createButton: some View {
        Button {
            newName = ""
            isCreating = true
        } label: {
            Image(systemName: "plus")
                .accessibilityLabel(Text(copy.createTitleKey, bundle: .module))
        }
    }
}

extension View {
    func createEntityToolbar(
        copy: CreateEntityCopy,
        onCreate: @escaping (String) -> Void,
    ) -> some View {
        modifier(CreateEntityToolbarModifier(copy: copy, onCreate: onCreate))
    }
}

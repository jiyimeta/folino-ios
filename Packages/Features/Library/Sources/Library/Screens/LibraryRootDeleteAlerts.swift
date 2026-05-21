import Domain
import LibraryLogic
import SwiftUI
import UtilityUI

/// Two confirmation alerts (playlist / tag) used by the Library root's swipe-to-delete actions. Score deletion is soft
/// (no confirmation) — the Recently Deleted screen handles permanent-delete confirmation via popover.
@MainActor
struct LibraryRootDeleteAlerts: ViewModifier {
    let viewModel: LibraryStore
    @Binding var pendingDeletePlaylist: Playlist?
    @Binding var pendingDeleteTag: Tag?

    func body(content: Content) -> some View {
        content
            .modifier(PlaylistAlert(viewModel: viewModel, pending: $pendingDeletePlaylist))
            .modifier(TagAlert(viewModel: viewModel, pending: $pendingDeleteTag))
    }
}

@MainActor
private struct PlaylistAlert: ViewModifier {
    let viewModel: LibraryStore
    @Binding var pending: Playlist?

    func body(content: Content) -> some View {
        content.alert(
            Text(String(
                localized: "library.score.delete.title",
                defaultValue: "Delete \"\(pending?.name ?? "")\"?",
                bundle: .module,
            )),
            isPresented: presentationBinding($pending),
            presenting: pending,
        ) { playlist in
            Button(role: .destructive) {
                Task { await viewModel.deletePlaylist(playlist) }
            } label: { L10n.Common.delete }
            Button(role: .cancel) {} label: { L10n.Common.cancel }
        } message: { _ in
            Text("library.playlist.delete.message", bundle: .module)
        }
    }
}

@MainActor
private struct TagAlert: ViewModifier {
    let viewModel: LibraryStore
    @Binding var pending: Tag?

    func body(content: Content) -> some View {
        content.alert(
            Text(String(
                localized: "library.score.delete.title",
                defaultValue: "Delete \"\(pending?.name ?? "")\"?",
                bundle: .module,
            )),
            isPresented: presentationBinding($pending),
            presenting: pending,
        ) { tag in
            Button(role: .destructive) {
                Task { await viewModel.deleteTag(tag) }
            } label: { L10n.Common.delete }
            Button(role: .cancel) {} label: { L10n.Common.cancel }
        } message: { _ in
            Text("library.tag.delete.message", bundle: .module)
        }
    }
}

private func presentationBinding<Value>(_ source: Binding<Value?>) -> Binding<Bool> {
    Binding(
        get: { source.wrappedValue != nil },
        set: { isPresented in if !isPresented { source.wrappedValue = nil } },
    )
}

extension View {
    @MainActor
    func libraryRootDeleteAlerts(
        viewModel: LibraryStore,
        pendingDeletePlaylist: Binding<Playlist?>,
        pendingDeleteTag: Binding<Tag?>,
    ) -> some View {
        modifier(LibraryRootDeleteAlerts(
            viewModel: viewModel,
            pendingDeletePlaylist: pendingDeletePlaylist,
            pendingDeleteTag: pendingDeleteTag,
        ))
    }
}

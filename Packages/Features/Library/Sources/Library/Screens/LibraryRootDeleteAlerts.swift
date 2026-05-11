import Domain
import SwiftUI
import UtilityUI

/// Three confirmation alerts (playlist / tag / score) used by the Library
/// root's swipe-to-delete actions. Extracted from `LibraryRootScreen` to
/// keep that file under SwiftLint's file-length budget.
@MainActor
struct LibraryRootDeleteAlerts: ViewModifier {
    let viewModel: LibraryViewModel
    @Binding var pendingDeletePlaylist: Playlist?
    @Binding var pendingDeleteTag: Tag?
    @Binding var pendingDeleteScore: ScoreItem?

    func body(content: Content) -> some View {
        content
            .modifier(PlaylistAlert(viewModel: viewModel, pending: $pendingDeletePlaylist))
            .modifier(TagAlert(viewModel: viewModel, pending: $pendingDeleteTag))
            .modifier(ScoreAlert(viewModel: viewModel, pending: $pendingDeleteScore))
    }
}

@MainActor
private struct PlaylistAlert: ViewModifier {
    let viewModel: LibraryViewModel
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
    let viewModel: LibraryViewModel
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

@MainActor
private struct ScoreAlert: ViewModifier {
    let viewModel: LibraryViewModel
    @Binding var pending: ScoreItem?

    func body(content: Content) -> some View {
        content.alert(
            Text(String(
                localized: "library.score.delete.title",
                defaultValue: "Delete \"\(pending?.title ?? "")\"?",
                bundle: .module,
            )),
            isPresented: presentationBinding($pending),
            presenting: pending,
        ) { item in
            Button(role: .destructive) {
                Task { await viewModel.delete(item) }
            } label: { L10n.Common.delete }
            Button(role: .cancel) {} label: { L10n.Common.cancel }
        } message: { _ in
            Text("library.score.delete.message", bundle: .module)
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
        viewModel: LibraryViewModel,
        pendingDeletePlaylist: Binding<Playlist?>,
        pendingDeleteTag: Binding<Tag?>,
        pendingDeleteScore: Binding<ScoreItem?>,
    ) -> some View {
        modifier(LibraryRootDeleteAlerts(
            viewModel: viewModel,
            pendingDeletePlaylist: pendingDeletePlaylist,
            pendingDeleteTag: pendingDeleteTag,
            pendingDeleteScore: pendingDeleteScore,
        ))
    }
}

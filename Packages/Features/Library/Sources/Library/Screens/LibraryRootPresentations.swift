import Domain
import ScoreUI
import SwiftUI
import UtilityUI

/// Bundles the Library root's tag/playlist sheets, import alerts, create-playlist/tag alerts, and the
/// share-preparation overlay into a single modifier so they no longer inflate `LibraryRootScreen.body`. Each
/// presentation is its own sub-modifier, so it reads only the binding it drives and toggling one (e.g. the
/// create-playlist alert) re-evaluates only that sub-modifier — not the `NavigationStack` content it wraps. Mirrors
/// the existing `libraryRootDeleteAlerts` / `editScoreInfoSheet` modifiers so the screen wires it with one line.
@MainActor
struct LibraryRootPresentations: ViewModifier {
    let viewModel: LibraryViewModel
    @Binding var editTagsTarget: ScoreItem?
    @Binding var addToPlaylistTarget: ScoreItem?
    @Binding var isCreatingPlaylist: Bool
    @Binding var newPlaylistName: String
    @Binding var isCreatingTag: Bool
    @Binding var newTagName: String

    func body(content: Content) -> some View {
        content
            .sheet(item: $editTagsTarget) { item in
                EditTagsScreen(scoreItem: item, library: viewModel)
            }
            .sheet(item: $addToPlaylistTarget) { item in
                AddToPlaylistScreen(scoreItem: item, library: viewModel)
            }
            .sheet(isPresented: isNewScoreSheetPresentedBinding) {
                NewScoreSheet(viewModel: viewModel)
            }
            .modifier(ImportErrorAlert(viewModel: viewModel))
            .modifier(CreatePlaylistAlert(
                viewModel: viewModel,
                isPresented: $isCreatingPlaylist,
                name: $newPlaylistName,
            ))
            .modifier(CreateTagAlert(viewModel: viewModel, isPresented: $isCreatingTag, name: $newTagName))
            .modifier(DuplicateImportAlert(viewModel: viewModel))
            .modifier(SharePreparation(viewModel: viewModel))
    }

    /// `viewModel` is a plain `let` here (only `SharePreparation` needs `@Bindable`), so the "New score" sheet's
    /// binding is hand-rolled the same way `ImportErrorAlert.presentationBinding` is below.
    private var isNewScoreSheetPresentedBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isNewScoreSheetPresented },
            set: { viewModel.isNewScoreSheetPresented = $0 },
        )
    }
}

@MainActor
private struct ImportErrorAlert: ViewModifier {
    let viewModel: LibraryViewModel

    func body(content: Content) -> some View {
        content.alert(
            Text("library.title", bundle: .module),
            isPresented: presentationBinding,
            presenting: viewModel.currentError,
        ) { _ in
            Button { viewModel.currentError = nil } label: {
                L10n.Common.ok
            }
        } message: { error in
            Text(describeLibraryError(error))
        }
    }

    /// Gated on `!isNewScoreSheetPresented`: while `NewScoreSheet` is up it owns presenting `currentError` itself
    /// (SwiftUI won't surface an alert from a view already presenting a sheet), so this root-level alert stays
    /// suppressed rather than racing the sheet's own alert over the same shared error.
    private var presentationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.currentError != nil && !viewModel.isNewScoreSheetPresented },
            set: { isPresented in
                guard !isPresented else { return }
                viewModel.currentError = nil
            },
        )
    }
}

@MainActor
private struct CreatePlaylistAlert: ViewModifier {
    let viewModel: LibraryViewModel
    @Binding var isPresented: Bool
    @Binding var name: String

    func body(content: Content) -> some View {
        content.alert(Text("library.playlist.create.title", bundle: .module), isPresented: $isPresented) {
            TextField(text: $name) { Text("library.playlist.namePlaceholder", bundle: .module) }
            Button {
                let enteredName = name
                name = ""
                Task { await viewModel.createPlaylist(name: enteredName) }
            } label: { L10n.Common.add }
            Button(role: .cancel) { name = "" } label: { L10n.Common.cancel }
        } message: {
            Text("library.playlist.create.message", bundle: .module)
        }
    }
}

@MainActor
private struct CreateTagAlert: ViewModifier {
    let viewModel: LibraryViewModel
    @Binding var isPresented: Bool
    @Binding var name: String

    func body(content: Content) -> some View {
        content.alert(Text("library.tag.create.title", bundle: .module), isPresented: $isPresented) {
            TextField(text: $name) { Text("library.tag.namePlaceholder", bundle: .module) }
            Button {
                let enteredName = name
                name = ""
                Task { await viewModel.createTag(name: enteredName) }
            } label: { L10n.Common.add }
            Button(role: .cancel) { name = "" } label: { L10n.Common.cancel }
        } message: {
            Text("library.tag.create.message", bundle: .module)
        }
    }
}

@MainActor
private struct DuplicateImportAlert: ViewModifier {
    let viewModel: LibraryViewModel

    func body(content: Content) -> some View {
        content.alert(
            Text("library.import.duplicate.title", bundle: .module),
            isPresented: presentationBinding,
            presenting: viewModel.duplicatePrompt,
        ) { prompt in
            Button {
                viewModel.duplicatePrompt = nil
                Task { await viewModel.commit(plan: prompt.plan, decision: .openExisting(prompt.existing.id)) }
            } label: {
                L10n.Common.open
            }
            Button {
                viewModel.duplicatePrompt = nil
                Task { await viewModel.commit(plan: prompt.plan, decision: .importAsNew) }
            } label: {
                Text("library.import.duplicate.importAsDuplicate", bundle: .module)
            }
            Button(role: .cancel) {
                viewModel.duplicatePrompt = nil
            } label: {
                L10n.Common.cancel
            }
        } message: { prompt in
            Text(String(
                localized: "library.import.duplicate.message",
                defaultValue: "\"\(prompt.existing.title)\" is already imported. What do you want to do?",
                bundle: .module,
            ))
        }
    }

    private var presentationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.duplicatePrompt != nil },
            set: { isPresented in
                guard !isPresented else { return }
                viewModel.duplicatePrompt = nil
            },
        )
    }
}

@MainActor
private struct SharePreparation: ViewModifier {
    @Bindable var viewModel: LibraryViewModel

    func body(content: Content) -> some View {
        content
            .overlay {
                if viewModel.isPreparingShare {
                    ProgressView { Text("library.score.preparing", bundle: .module) }
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
            }
            .scoreExportPresentation(target: $viewModel.shareTarget)
    }
}

extension View {
    @MainActor
    func libraryRootPresentations(
        viewModel: LibraryViewModel,
        editTagsTarget: Binding<ScoreItem?>,
        addToPlaylistTarget: Binding<ScoreItem?>,
        isCreatingPlaylist: Binding<Bool>,
        newPlaylistName: Binding<String>,
        isCreatingTag: Binding<Bool>,
        newTagName: Binding<String>,
    ) -> some View {
        modifier(LibraryRootPresentations(
            viewModel: viewModel,
            editTagsTarget: editTagsTarget,
            addToPlaylistTarget: addToPlaylistTarget,
            isCreatingPlaylist: isCreatingPlaylist,
            newPlaylistName: newPlaylistName,
            isCreatingTag: isCreatingTag,
            newTagName: newTagName,
        ))
    }
}

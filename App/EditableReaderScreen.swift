import Domain
import Editor
import Reader
import SheetMusicUI
import SwiftUI

/// Composition-root wrapper that mounts a ReaderRootScreen with the note-editing seam filled in: one
/// ReaderEditingHost + one EditorViewModel per Reader instance, wired by closure so Reader and Editor stay mutually
/// unaware (module-architecture Option 1). This is the ONLY place the Editor and Reader features meet.
@MainActor
struct EditableReaderScreen: View {
    /// Builds the Editor feature's chrome overlay from the current seam context (score-info bar, keyboard, 完了).
    typealias ChromeBuilder = (ReaderEditingChromeContext) -> AnyView

    @State private var editingHost = ReaderEditingHost()
    @State private var editorViewModel: EditorViewModel
    @State private var isWired = false
    @Environment(\.scenePhase) private var scenePhase
    private let readerBuilder: (ReaderEditingHost, @escaping ChromeBuilder) -> ReaderRootScreen

    init(
        item: ScoreItem,
        scoresDirectory: URL,
        gateway: any ScoreFileGateway,
        repository: any ScoreLibraryRepository,
        playbackController: (any PlaybackController)?,
        readerBuilder: @escaping (ReaderEditingHost, @escaping ChromeBuilder) -> ReaderRootScreen,
    ) {
        _editorViewModel = State(wrappedValue: EditorViewModel(
            scoreItem: item,
            scoresDirectory: scoresDirectory,
            gateway: gateway,
            repository: repository,
            playback: playbackController,
        ))
        self.readerBuilder = readerBuilder
    }

    var body: some View {
        readerBuilder(editingHost) { context in
            AnyView(EditorChromeView(
                viewModel: editorViewModel,
                selectionAnchor: context.selectionScreenFrame,
                onDone: { [editingHost] in editingHost.requestExit() },
            ))
        }
        .onAppear { wireOnce() }
        .onChange(of: scenePhase) { _, phase in
            // Autosave survives app backgrounding mid-edit (spec §8): flush whenever the scene leaves .active,
            // regardless of whether an edit session is currently open (flushPendingSave() is a no-op otherwise).
            if phase != .active {
                Task { await editorViewModel.flushPendingSave() }
            }
        }
    }

    /// Connects the host (Reader → App) to the view model (App → Editor) exactly once per instance. `.onAppear` can
    /// technically fire more than once (e.g. after a transient view removal/reinsertion), so this guards against
    /// re-wiring and losing state.
    private func wireOnce() {
        guard !isWired else { return }
        isWired = true
        let host = editingHost
        let vm = editorViewModel
        host.onBeginEditing = { score in vm.beginSession(score: score) }
        host.onEndEditing = { Task { await vm.endSession() } }
        host.onTap = { point in vm.handleTap(at: point) }
        host.onPitchDragCommit = { steps in vm.commitPitchDrag(steps: steps) }
        vm.documentProvider = { host.document }
        vm.onScoreChanged = { score in
            host.editedScore = score
            host.editGeneration += 1
        }
        vm.onSelectionChanged = { selection, item in
            host.selection = selection
            host.caretItem = item
        }
    }
}

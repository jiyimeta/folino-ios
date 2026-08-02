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
                bottomTransportClearance: context.bottomTransportClearance,
                onDone: { [editingHost] in editingHost.requestExit() },
                onClusterInsetsChange: { [editingHost] top, bottom in
                    editingHost.editingChromeTopInset = top
                    editingHost.editingChromeBottomInset = bottom
                },
                onNoteInputAnchorChange: { [editingHost] frame in
                    editingHost.noteInputAnchorFrame = frame
                },
            ))
        }
        .onAppear { wireOnce() }
        // The Reader owns the transport; the Editor only needs to know whether it's running, so the pad can go inert
        // while the cursor moves. Mirrored here because neither feature imports the other.
        .onChange(of: editingHost.isPlaying, initial: true) { _, isPlaying in
            editorViewModel.isPlaybackActive = isPlaying
        }
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
        host.onBeginEditing = { [weak vm, weak host] score in
            guard let vm else { return }
            vm.beginSession(score: score)
            // Carry the reader's last tap into the session: the note under the playhead is almost always the one the
            // user came here to change.
            vm.selectItem(host?.pendingSelection)
        }
        host.onRevealNoteInputPad = { [weak vm] in
            vm?.requestPadReveal()
        }
        host.onEndEditing = { [weak vm] in
            guard let vm else { return }
            Task { await vm.endSession() }
        }
        host.onTap = { [weak vm] point in
            guard let vm else { return }
            vm.handleTap(at: point)
        }
        host.onTapOutsideScore = { [weak vm] in
            vm?.deselect()
        }
        // Straight from the Reader's overlay into the view model, with no SwiftUI body in between: this fires on every
        // scroll and zoom frame, and anything that read it in a body would re-render the score at that rate.
        host.onSelectionAnchorChanged = { [weak vm] anchor in
            vm?.selectionAnchor = anchor
        }
        vm.documentProvider = { [weak host] in
            guard let host else { return nil }
            return host.document
        }
        vm.onScoreChanged = { [weak host] score in
            guard let host else { return }
            host.editedScore = score
            host.editGeneration += 1
        }
        // Two markers, not one: `selection` tints the item the editing keys act on, `caret` draws the insertion bar
        // where the next note lands. They coincide until a run of input pulls the caret ahead of the selection.
        vm.onSelectionChanged = { [weak host] selection, caret in
            guard let host else { return }
            host.selection = selection
            host.caretItem = caret
        }
    }
}

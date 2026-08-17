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
    /// Kept only so `wireOnce()` can re-read this instance's row before every edit session (Critical 1 review fix)
    /// — see the comment there. The same instance the App handed to `readerBuilder`'s `ReaderRootScreen`, so its
    /// live cache already carries whatever that Reader (or the Library, via the same shared repository) last wrote.
    private let repository: any ScoreLibraryRepository

    init(
        item: ScoreItem,
        scoresDirectory: URL,
        gateway: any ScoreFileGateway,
        repository: any ScoreLibraryRepository,
        originalStore: any ScoreOriginalStore,
        playbackController: (any PlaybackController)?,
        readerBuilder: @escaping (ReaderEditingHost, @escaping ChromeBuilder) -> ReaderRootScreen,
    ) {
        _editorViewModel = State(wrappedValue: EditorViewModel(
            scoreItem: item,
            scoresDirectory: scoresDirectory,
            gateway: gateway,
            repository: repository,
            originalStore: originalStore,
            playback: playbackController,
        ))
        self.repository = repository
        self.readerBuilder = readerBuilder
    }

    var body: some View {
        readerBuilder(editingHost) { context in
            AnyView(EditorChromeView(
                viewModel: editorViewModel,
                bottomTransportClearance: context.bottomTransportClearance,
                hasMusicalAnnotations: editingHost.hasMusicalAnnotationsProvider(),
                onDone: { [editingHost] in editingHost.requestExit() },
                onClusterInsetsChange: { [editingHost] top, bottom in
                    editingHost.editingChromeTopInset = top
                    editingHost.editingChromeBottomInset = bottom
                },
                // Stubbed: the Editor's chrome has no drawing surface yet (it lost the navigation bar it filled and
                // gets its own strip in a later task), so it cannot report a frame for `noteInputAnchorFrame` — this
                // callback still fires with a bar ordinal, which is no longer meaningful, and is ignored.
                onNoteInputBarOrderChange: { _ in },
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
        host.onBeginEditing = { [weak vm, weak host, repository] score in
            guard let vm else { return }
            // Re-seed the row before acting on it. `editorViewModel` is created once and reused for every edit
            // session this screen opens, so without this its `scoreItem` is whatever it was at `init` (or its own
            // last save) — stale the moment a revert lands through the score-info sheet, which writes through the
            // Reader's or the Library's OWN copy of the row, never this one. A stale `scoreItem` still names a
            // sidecar the store has already deleted, so the next autosave's capture step sees "already captured"
            // and skips it, silently overwriting the just-restored original with no backup (Critical 1 review fix).
            // `repository` is the same live instance passed into `readerBuilder`'s `ReaderRootScreen`, so its
            // observed cache already carries whatever was last written by the time the user gets back into edit
            // mode. This also fixes the milder pre-existing bug where a title edited in the sheet was clobbered by
            // this view model's next save.
            if let freshRow = repository.scoreItems.first(where: { $0.id == vm.scoreItemID }) {
                vm.refreshRow(freshRow)
            }
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
        // The other half of a completed revert: the Editor rewrote the file and the row, but has no way to make the
        // Reader — which is still drawing the edited score it already had in memory — notice.
        vm.onRevertCompleted = { [weak host] item in
            host?.requestReloadAfterRevert(item)
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
        // The document above is laid out from whatever the Reader is SHOWING, which drops the staves the reader has
        // hidden and renumbers the rest; the view model edits (and saves) the score entire. The host owns that
        // conversion because only the Reader knows the current visibility.
        vm.displayToSourceItem = { [weak host] item in
            guard let host else { return item }
            return host.sourceItem(for: item)
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

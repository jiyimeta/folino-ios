import Domain
import Editor
import Reader
import SheetMusicUI
import SwiftUI
import UtilityUI

/// Composition-root wrapper that mounts a ReaderRootScreen with the note-editing seam filled in: one
/// ReaderEditingHost + one EditorViewModel per Reader instance, wired by closure so Reader and Editor stay mutually
/// unaware (module-architecture Option 1). This is the ONLY place the Editor and Reader features meet.
@MainActor
struct EditableReaderScreen: View {
    /// Builds the Editor feature's chrome overlay from the current seam context (score-info bar, keyboard, 完了),
    /// or its top-strip row (voice, pad toggle, undo / redo, and — where there is no cutout tier — 完了 / revert
    /// too) — same context type, two different slots in the Reader's tree.
    typealias ChromeBuilder = (ReaderEditingChromeContext) -> AnyView
    /// Builds the cutout tier's editing-session content (完了 leading, revert trailing) for the Reader's OWN
    /// `ReaderCutoutTier` to draw — see `ReaderRootScreen.editingCutoutTier` and review Important 4. A distinct
    /// return type from `ChromeBuilder` because `ReaderCutoutTier` needs the leading and trailing pieces kept apart,
    /// not one combined, type-erased view.
    typealias CutoutTierBuilder = (ReaderEditingChromeContext) -> ReaderEditingCutoutTierContent

    @State private var editingHost = ReaderEditingHost()
    @State private var editorViewModel: EditorViewModel
    @State private var isWired = false
    @Environment(\.scenePhase) private var scenePhase
    /// Second `ChromeBuilder` is the top-strip row; the first is the pad overlay. `CutoutTierBuilder` is next, and the
    /// trailing `Bool` is `startInEditMode`, forwarded straight through to whatever `ReaderRootScreen` the closure
    /// builds — `ReadyShell.makeReader` is the only writer of that closure, and it owns the actual `ReaderRootScreen`
    /// construction, so this instance's own `startInEditMode` has to ride along as an argument rather than being
    /// something this type could apply itself.
    private let readerBuilder: (
        ReaderEditingHost, @escaping ChromeBuilder, @escaping ChromeBuilder, @escaping CutoutTierBuilder, Bool,
    ) -> ReaderRootScreen
    /// Kept only so `wireOnce()` can re-read this instance's row before every edit session (Critical 1 review fix)
    /// — see the comment there. The same instance the App handed to `readerBuilder`'s `ReaderRootScreen`, so its
    /// live cache already carries whatever that Reader (or the Library, via the same shared repository) last wrote.
    private let repository: any ScoreLibraryRepository
    /// One-shot: opens straight into an edit session for a score that was just created (spec: a scratch score should
    /// land on the editing surface, not the score view). Forwarded into `readerBuilder`; see its doc comment.
    private let startInEditMode: Bool

    init(
        item: ScoreItem,
        scoresDirectory: URL,
        gateway: any ScoreFileGateway,
        repository: any ScoreLibraryRepository,
        originalStore: any ScoreOriginalStore,
        historyStore: any ScoreEditHistoryStore,
        playbackController: (any PlaybackController)?,
        startInEditMode: Bool = false,
        readerBuilder: @escaping (
            ReaderEditingHost, @escaping ChromeBuilder, @escaping ChromeBuilder, @escaping CutoutTierBuilder, Bool,
        ) -> ReaderRootScreen,
    ) {
        _editorViewModel = State(wrappedValue: EditorViewModel(
            scoreItem: item,
            scoresDirectory: scoresDirectory,
            gateway: gateway,
            repository: repository,
            originalStore: originalStore,
            historyStore: historyStore,
            playback: playbackController,
        ))
        self.repository = repository
        self.startInEditMode = startInEditMode
        self.readerBuilder = readerBuilder
    }

    var body: some View {
        readerBuilder(editingHost, { [editingHost] context in
            AnyView(EditorChromeView(
                viewModel: editorViewModel,
                bottomTransportClearance: context.bottomTransportClearance,
                onClusterInsetsChange: { top, bottom in
                    editingHost.editingChromeTopInset = top
                    editingHost.editingChromeBottomInset = bottom
                },
            ))
        }, { [editingHost] context in
            AnyView(EditorTopBarView(
                viewModel: editorViewModel,
                hasMusicalAnnotations: editingHost.hasMusicalAnnotationsProvider(),
                hasCutoutTier: context.hasCutoutTier,
                onDone: { editingHost.requestExit() },
                onNoteInputAnchorFrameChange: { editingHost.noteInputAnchorFrame = $0 },
            ))
        }, { [editingHost] _ in
            // `inCutoutBand` rather than a glass modifier applied out here: each control carries exactly one surface
            // of its own (完了 a glass pill, revert a filled red capsule), sized to the band. Wrapping them in glass
            // from this call site drew a second, larger pill behind revert's red one — two stacked shapes for one
            // control.
            ReaderEditingCutoutTierContent(
                leading: AnyView(EditorDiscardButton(
                    viewModel: editorViewModel,
                    onExit: { editingHost.requestExit() },
                    inCutoutBand: true,
                )),
                trailing: AnyView(EditorSessionEndButton(
                    viewModel: editorViewModel,
                    onExit: { editingHost.requestExit() },
                    hasMusicalAnnotations: editingHost.hasMusicalAnnotationsProvider(),
                    inCutoutBand: true,
                )),
            )
        }, startInEditMode)
            .onAppear { wireOnce() }
            // The Reader owns the transport; the Editor only needs to know whether it's running, so the pad can go
            // inert while the cursor moves. Mirrored here because neither feature imports the other.
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
        wirePartEditSeams(host: host, vm: vm)
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
        // The instruments sheet lists the score's parts (the Editor's business) with a visibility switch per staff
        // (the Reader's). Both halves land in one list, so the two seams meet here — the same place the addressing
        // conversion above does, and for the same reason: neither feature can see the other.
        vm.isStaffVisible = { [weak host] address in
            host?.isStaffVisible(address) ?? true
        }
        vm.onToggleStaffVisibility = { [weak host] address in
            host?.onToggleStaffVisibility(address)
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

    /// The part add / remove / reorder half of the seam, split out of `wireOnce()` to keep it inside SwiftLint's
    /// `function_body_length` budget.
    ///
    /// The Editor migrates the persisted `ReaderPreferences` row onto the new part numbering, but the Reader is
    /// holding the very same state in memory — and that copy is what its next preference write would persist. Two
    /// seams, because the window between the edit and the migration is one the Reader must not write in at all, not
    /// merely one it has to re-read after: a write stamped in the new numbering that beats the migration is remapped
    /// a second time onto a different part, and one stamped in the old numbering that follows it overwrites the
    /// migrated row after the map has been consumed, so nothing ever retries.
    /// The hold is raised from the Editor and released by the Reader, deliberately asymmetrically: the Editor knows
    /// when the row stops being trustworthy, but only the Reader knows when its own in-memory copy has caught up.
    /// `isPartMappingSettled` is how the release asks the Editor whether a LATER part edit has since raised it again.
    private func wirePartEditSeams(host: ReaderEditingHost, vm: EditorViewModel) {
        vm.onPartEditApplied = { [weak host] in
            host?.raisePartMappingHold()
        }
        host.isPartMappingSettled = { [weak vm] in
            vm?.hasUnsettledPartEdits != true
        }
        vm.onPartIndicesRemapped = { [weak host] _ in
            host?.requestReloadAfterPartRemap()
        }
    }
}

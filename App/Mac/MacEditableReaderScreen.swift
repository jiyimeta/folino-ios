import Domain
import Editor
import Reader
import SwiftUI
import UtilityCore

/// What the menus act on: the editor behind the key score window, and the two confirmations the File menu's
/// Revert To items arm. Published as a `focusedSceneValue` by every score window so `MacEditingMenus` reads the
/// right editor when several score windows are open — and reads `nil` when none is key.
///
/// A class, and one instance per screen: the focused value has to be the SAME object on every body pass, or each
/// pass republishes a new value and the menus rebuild for nothing. `MacEditableReaderScreen` holds it in `@State`
/// and fills the two closures in `wireOnce()`.
@MainActor
final class MacEditingTarget {
    let editor: EditorViewModel
    let host: ReaderEditingHost
    /// Called by File ▸ Revert To ▸ Last Opened; the screen owns the confirmation this arms.
    var confirmDiscard: () -> Void = {}
    /// Called by File ▸ Revert To ▸ Original; the screen owns the confirmation this arms.
    var confirmRevert: () -> Void = {}

    init(editor: EditorViewModel, host: ReaderEditingHost) {
        self.editor = editor
        self.host = host
    }
}

private struct MacEditingTargetKey: FocusedValueKey {
    typealias Value = MacEditingTarget
}

extension FocusedValues {
    var macEditingTarget: MacEditingTarget? {
        get { self[MacEditingTargetKey.self] }
        set { self[MacEditingTargetKey.self] = newValue }
    }
}

/// The Mac sibling of `App/iOS/EditableReaderScreen.swift`: one `ReaderEditingHost` + one `EditorViewModel` per
/// score window, wired by the shared `wireEditingSeam`, handed into `MacReaderRootScreen`. No chrome builders — the
/// Mac has no pad, no top strip and no cutout tier; its editing controls are the menu bar and the keyboard.
@MainActor
struct MacEditableReaderScreen: View {
    let item: ScoreItem
    let bootstrap: AppBootstrap

    @State private var editingHost: ReaderEditingHost
    @State private var editorViewModel: EditorViewModel
    /// The focused value the menus read. Created here rather than computed in `body` so every pass publishes one
    /// and the same object — see `MacEditingTarget`.
    @State private var editingTarget: MacEditingTarget
    @State private var isWired = false
    /// `true` once this window has opened an edit session at least once. Read only by `onDisappear`'s fallback
    /// unregister — see the comment there.
    @State private var didOpenSession = false
    @State private var isConfirmingDiscard = false
    @State private var isConfirmingRevert = false
    /// The window's undo manager, which is what SwiftUI's own Edit ▸ Undo / Redo items drive (design §5.2). The
    /// session stays the source of truth; the manager holds only `registerSystemUndo`'s trampolines.
    @Environment(\.undoManager) private var undoManager

    /// The adapters this screen needs, unwrapped once in `init` (same guarantee, and the same guard, as
    /// `MacShellView.init`) rather than force-unwrapped at every use site in `body`.
    private let repository: any ScoreLibraryRepository
    private let originalStore: any ScoreOriginalStore
    private let gateway: any ScoreFileGateway
    private let shareService: any ScoreShareService
    private let metadataReader: any ScoreMetadataReading
    private let annotationCoordinator: AnnotationSaveCoordinator
    private let analytics: any Analytics

    init(item: ScoreItem, bootstrap: AppBootstrap) {
        self.item = item
        self.bootstrap = bootstrap
        // Non-nil for the same reason `MacShellView.init`'s are: this screen is only ever built from that view's
        // `content`, which `FolinoMacApp` only reaches once `bootstrap.isReady` is true, and `AppBootstrap.start()`
        // populates every adapter synchronously before flipping that flag.
        guard let repository = bootstrap.repository,
              let gateway = bootstrap.gateway,
              let originalStore = bootstrap.originalStore,
              let shareService = bootstrap.shareService,
              let metadataReader = bootstrap.metadataReader,
              let annotationCoordinator = bootstrap.annotationCoordinator
        else {
            fatalError("MacEditableReaderScreen built before AppBootstrap finished starting")
        }
        self.repository = repository
        self.originalStore = originalStore
        self.gateway = gateway
        self.shareService = shareService
        self.metadataReader = metadataReader
        self.annotationCoordinator = annotationCoordinator
        analytics = bootstrap.analytics ?? NoopAnalytics()
        // The host, the view model and the target are built here as locals first so all three `@State`s can be
        // seeded with the very same instances — the target has to name the objects the seam is wired against.
        let host = ReaderEditingHost()
        let viewModel = EditorViewModel(
            scoreItem: item,
            scoresDirectory: AppPaths.scoresDirectory,
            gateway: gateway,
            repository: repository,
            originalStore: originalStore,
            historyStore: bootstrap.editHistoryStore,
            playback: bootstrap.playbackController,
            annotationStore: bootstrap.annotationStore,
        )
        _editingHost = State(wrappedValue: host)
        _editorViewModel = State(wrappedValue: viewModel)
        _editingTarget = State(wrappedValue: MacEditingTarget(editor: viewModel, host: host))
    }

    var body: some View {
        MacReaderRootScreen(
            scoreItem: item,
            repository: repository,
            originalStore: originalStore,
            gateway: gateway,
            shareService: shareService,
            metadataReader: metadataReader,
            annotationCoordinator: annotationCoordinator,
            scoresDirectory: AppPaths.scoresDirectory,
            playbackController: bootstrap.playbackController,
            // The same OMR parser the iOS shell passes. It is what gives an imported PDF its on-PDF cursor and
            // click-to-seek; without it the document still reads, it just carries no musical positions.
            pdfPlaybackParser: bootstrap.pdfPlaybackParser,
            editingHost: editingHost,
            analytics: analytics,
        )
        .editorSheets(viewModel: editorViewModel)
        // Bare-key delivery, shape B (the bench's provisional answer — see
        // `docs/superpowers/plans/2026-09-02-macos-edit-session-bench.md`): the letters and digits are view-level
        // `.keyboardShortcut`s inside this window's tree, so a focused text field in a sheet keeps the letter.
        // Modifier-bearing shortcuts stay on the menu items, in `MacEditingMenus`.
        .background(MacEditingKeyMap(target: editingTarget))
        // Scene-scoped, deliberately: a menu command must find the KEY WINDOW's editor whether or not the score
        // surface itself holds view focus.
        .focusedSceneValue(\.macEditingTarget, editingTarget)
        .confirmationDialog(
            Text("mac.revert.lastOpened.title"),
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible,
        ) {
            Button(role: .destructive) {
                Task {
                    await editorViewModel.discardSessionEdits()
                    // The session survives the discard (it is unwound, not closed), so nothing else takes the
                    // trampolines down — and every one of them would now undo an edit that no longer exists.
                    // Revert To ▸ Original does not need this: its reload ends the session and opens a new one,
                    // which the `isEditing` handler below already re-arms from scratch.
                    undoManager?.removeAllActions(withTarget: editorViewModel)
                }
            } label: {
                Text("mac.revert.lastOpened.action")
            }
        } message: {
            Text(editorViewModel.discardConfirmationMessage)
        }
        .confirmationDialog(
            Text("mac.revert.original.title"),
            isPresented: $isConfirmingRevert,
            titleVisibility: .visible,
        ) {
            Button(role: .destructive) {
                Task { await editorViewModel.revertToOriginal() }
            } label: {
                Text("mac.revert.original.action")
            }
        } message: {
            Text(editorViewModel.revertConfirmationMessage(
                hasMusicalAnnotations: editingHost.hasMusicalAnnotationsProvider(),
            ))
        }
        .onAppear {
            wireOnce()
            // Registration is idempotent and lives OUTSIDE `wireOnce`'s one-shot guard deliberately: a window that
            // disappears and reappears (AppKit tabbing moves a window between tab groups) runs `onDisappear`, which
            // may unregister. If the re-register rode the guard, that window would be gone from the registry for
            // good and ⌘Q's flush would skip its pending autosave.
            MacEditorRegistry.shared.register(editorViewModel, for: item.id)
        }
        // The Reader owns the transport; the Editor only needs to know whether it is running. Mirrored here
        // because neither feature imports the other.
        .onChange(of: editingHost.isPlaying, initial: true) { _, isPlaying in
            editorViewModel.isPlaybackActive = isPlaying
        }
        // The SESSION boundary, which on the Mac is not the screen's boundary. The iOS chrome can arm the undo
        // bridge in its own `onAppear` because that chrome mounts only once `beginSession` has already run; this
        // screen mounts BEFORE the session opens (`MacReaderRootScreen.task` → `beginEditingIfLoaded`), so arming
        // on appear would read `canUndo` on a view model with no session and arm nothing at all — leaving
        // Edit ▸ Undo dead on a reopened score whose retained history is undoable from the first frame.
        //
        // `isEditing` is set true immediately before `onBeginEditing`, and `beginSession` runs synchronously
        // inside it, so by the time SwiftUI delivers this change the adopted session is in place. The false edge
        // is the symmetric teardown: a revert (which closes and reopens the session on this same view model) and
        // the window's close both go through it, so no trampoline outlives the session that registered it.
        .onChange(of: editingHost.isEditing, initial: true) { _, editing in
            if editing {
                didOpenSession = true
                // Re-registration matters here, not just in `onAppear`: Revert To ▸ Original ends the session and
                // opens a new one, and the ended session's flush unregisters.
                MacEditorRegistry.shared.register(editorViewModel, for: item.id)
                // An adopted history is undoable the moment the session opens, but the system UndoManager only
                // learns about edits when a trampoline is registered — and that happens per NEWLY applied edit.
                // So the retained stack is armed here, ONE TRAMPOLINE PER STEP: each ⌘Z consumes exactly one and
                // registers only a redo (a second undo registered from inside an undo operation would land on the
                // redo stack, and one registered after it would wipe that stack), so a single trampoline would
                // offer a single step of a history several edits deep. The Mac needs this more than iOS does:
                // there is no undo button here at all.
                armSystemUndoForRetainedHistory()
            } else {
                undoManager?.removeAllActions(withTarget: editorViewModel)
            }
        }
        // The system Undo / Redo items drive the session through the same trampolines the iOS chrome registers,
        // re-registered only on a genuinely NEW edit — see `EditorViewModel.appliedEditCount`. NOT on undo /
        // redo, which also bump `generation`: re-registering there would double up with `registerSystemUndo`'s own
        // symmetric re-registration and drift the system stack from the session's real depth.
        //
        // Guarded on a RISE, not on any change: `beginSession` resets the count to 0, so a session that opens
        // after N edits (a revert's reload, or adopting a retained history) publishes N → 0 and would otherwise
        // register a trampoline for an edit that is not there. The `isEditing` handler above owns that case.
        .onChange(of: editorViewModel.appliedEditCount) { oldValue, newValue in
            guard newValue > oldValue else { return }
            editorViewModel.registerSystemUndo(with: undoManager)
        }
        // ⌘Z is the one editing path with no control to grey out, so it is closed while the transport runs: the
        // trampolines come off, and one is armed again after. Without this an undo would rewrite the score under a
        // cursor already reading from the pre-undo engine. Same guard the iOS chrome applies to the three-finger
        // swipe, for the same reason.
        .onChange(of: editorViewModel.isPlaybackActive) { _, isPlaying in
            if isPlaying {
                undoManager?.removeAllActions(withTarget: editorViewModel)
            } else {
                // Everything came off, so everything goes back on — the whole stack, not one step of it.
                armSystemUndoForRetainedHistory()
            }
        }
        // The registry entry normally comes off at the END of `endSession`'s flush (`wireOnce`), not here. This is
        // only the fallback for a window that never opened a session at all — a PDF-only row, or one whose load
        // failed — where `onEndEditing` never fires and the entry would otherwise outlive the window forever.
        //
        // `didOpenSession` rather than `!editingHost.isEditing`: the Reader clears `isEditing` synchronously inside
        // its own `onDisappear`, before this one runs, so reading it here cannot tell "no session was ever opened"
        // from "the session just closed and its flush is still in flight" — and unregistering in the second case is
        // exactly the quit-time race this whole change exists to close.
        .onDisappear {
            guard !didOpenSession else { return }
            MacEditorRegistry.shared.unregister(editorViewModel, for: item.id)
        }
    }

    /// Arms one `UndoManager` trampoline for every step the session can still undo, so Edit ▸ Undo reaches the whole
    /// retained history rather than its last step.
    ///
    /// Called where the manager holds none of this view model's actions — a session that just opened, or playback
    /// that just stripped them — never to top up a stack that already has some, which would double-count. A fresh
    /// session counts zero and registers nothing.
    private func armSystemUndoForRetainedHistory() {
        for _ in 0 ..< editorViewModel.undoableStepCount {
            editorViewModel.registerSystemUndo(with: undoManager)
        }
    }

    /// Connects the host (Reader → App) to the view model (App → Editor) exactly once per instance and fills the
    /// menus' target. `.onAppear` can fire more than once (a transient removal and reinsertion), so this guards
    /// against re-wiring; the registry registration next to the call site is deliberately not guarded.
    private func wireOnce() {
        guard !isWired else { return }
        isWired = true
        wireEditingSeam(host: editingHost, viewModel: editorViewModel, repository: repository, analytics: analytics)
        // Mac-only override of the shared seam's `onEndEditing`, which is a fire-and-forget `Task { await
        // vm.endSession() }`. iOS can leave it at that — the view model outlives the session there. Here the entry
        // in `MacEditorRegistry` is what `applicationShouldTerminate` iterates, and it must stay up until this
        // session's flush has actually landed: unregistering any earlier (at `onDisappear`, as this screen used to)
        // lets a ⌘Q issued right after a window close reply "terminate now" over an in-flight save.
        let vm = editorViewModel
        let id = item.id
        editingHost.onEndEditing = { [weak vm, weak host = editingHost] in
            guard let vm else { return }
            Task {
                await vm.endSession()
                // A revert closes the session and reopens it on this same view model; if editing has resumed by
                // the time this flush lands, the entry belongs to the NEW session and must stay.
                guard host?.isEditing != true else { return }
                MacEditorRegistry.shared.unregister(vm, for: id)
            }
        }
        // Bindings, not `self`: a closure that captured this view whole would capture `_editingTarget`'s own State
        // box with it, and the target — which holds the closure — would then keep itself, the editor and the host
        // alive for the life of the process. Every closed score window would leak its session.
        let discard = $isConfirmingDiscard
        let revert = $isConfirmingRevert
        editingTarget.confirmDiscard = { discard.wrappedValue = true }
        editingTarget.confirmRevert = { revert.wrappedValue = true }
    }
}

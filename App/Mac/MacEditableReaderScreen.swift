import Domain
import Editor
import Library
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
    /// The process's one `LibraryViewModel`, taken so this screen owns the whole composition of a score window.
    /// Nothing inside it reads the view model yet — the window's File ▸ Import publication lives one level up, in
    /// `MacShellView`, because that is the level a window's focused scene values belong to.
    let libraryVM: LibraryViewModel

    @State private var editingHost: ReaderEditingHost
    @State private var editorViewModel: EditorViewModel
    /// The focused value the menus read. Created here rather than computed in `body` so every pass publishes one
    /// and the same object — see `MacEditingTarget`.
    @State private var editingTarget: MacEditingTarget
    @State private var isWired = false
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

    init(item: ScoreItem, bootstrap: AppBootstrap, libraryVM: LibraryViewModel) {
        self.item = item
        self.bootstrap = bootstrap
        self.libraryVM = libraryVM
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
                Task { await editorViewModel.discardSessionEdits() }
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
            // unregisters. If the re-register rode the guard, that window would be gone from the registry for good
            // and ⌘Q's flush would skip its pending autosave.
            MacEditorRegistry.shared.register(editorViewModel, for: item.id)
            // An adopted history is undoable the moment the session opens, but the system UndoManager only learns
            // about edits when a trampoline is registered — and that happens per NEWLY applied edit. Arm one
            // initial trampoline when the session already has history; `registerSystemUndo`'s symmetric
            // re-registration handles everything after. The Mac needs this more than iOS does: there is no undo
            // button here at all, so an unarmed manager means Edit ▸ Undo is simply dead on a reopened score.
            if editorViewModel.canUndo {
                editorViewModel.registerSystemUndo(with: undoManager)
            }
        }
        // The Reader owns the transport; the Editor only needs to know whether it is running. Mirrored here
        // because neither feature imports the other.
        .onChange(of: editingHost.isPlaying, initial: true) { _, isPlaying in
            editorViewModel.isPlaybackActive = isPlaying
        }
        // The system Undo / Redo items drive the session through the same trampolines the iOS chrome registers,
        // re-registered only on a genuinely NEW edit — see `EditorViewModel.appliedEditCount`. NOT on undo /
        // redo, which also bump `generation`: re-registering there would double up with `registerSystemUndo`'s own
        // symmetric re-registration and drift the system stack from the session's real depth.
        .onChange(of: editorViewModel.appliedEditCount) { _, _ in
            editorViewModel.registerSystemUndo(with: undoManager)
        }
        // ⌘Z is the one editing path with no control to grey out, so it is closed while the transport runs: the
        // trampolines come off, and one is armed again after. Without this an undo would rewrite the score under a
        // cursor already reading from the pre-undo engine. Same guard the iOS chrome applies to the three-finger
        // swipe, for the same reason.
        .onChange(of: editorViewModel.isPlaybackActive) { _, isPlaying in
            if isPlaying {
                undoManager?.removeAllActions(withTarget: editorViewModel)
            } else if editorViewModel.canUndo {
                editorViewModel.registerSystemUndo(with: undoManager)
            }
        }
        .onDisappear {
            MacEditorRegistry.shared.unregister(for: item.id)
        }
    }

    /// Connects the host (Reader → App) to the view model (App → Editor) exactly once per instance and fills the
    /// menus' target. `.onAppear` can fire more than once (a transient removal and reinsertion), so this guards
    /// against re-wiring; the registry registration next to the call site is deliberately not guarded.
    private func wireOnce() {
        guard !isWired else { return }
        isWired = true
        wireEditingSeam(host: editingHost, viewModel: editorViewModel, repository: repository, analytics: analytics)
        // Bindings, not `self`: a closure that captured this view whole would capture `_editingTarget`'s own State
        // box with it, and the target — which holds the closure — would then keep itself, the editor and the host
        // alive for the life of the process. Every closed score window would leak its session.
        let discard = $isConfirmingDiscard
        let revert = $isConfirmingRevert
        editingTarget.confirmDiscard = { discard.wrappedValue = true }
        editingTarget.confirmRevert = { revert.wrappedValue = true }
    }
}

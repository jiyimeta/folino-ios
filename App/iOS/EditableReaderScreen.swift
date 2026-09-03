import Domain
import Editor
import Reader
import SheetMusicUI
import SwiftUI
import UtilityCore
import UtilityUI

/// Composition-root wrapper that mounts a ReaderRootScreen with the note-editing seam filled in: one
/// ReaderEditingHost + one EditorViewModel per Reader instance, wired by closure so Reader and Editor stay mutually
/// unaware (module-architecture Option 1). This is the ONLY place the Editor and Reader features meet.
@MainActor
struct EditableReaderScreen: View {
    /// Builds the Editor feature's chrome overlay from the current seam context (score-info bar, keyboard, 完了),
    /// or its top-strip row (voice, undo / redo, and — where there is no cutout tier — 完了 / revert too) — same
    /// context type, two different slots in the Reader's tree.
    typealias ChromeBuilder = (ReaderEditingChromeContext) -> AnyView
    /// Builds the cutout tier's editing-session content (完了 leading, revert trailing) for the Reader's OWN
    /// `ReaderCutoutTier` to draw — see `ReaderRootScreen.editingCutoutTier`. A distinct
    /// return type from `ChromeBuilder` because `ReaderCutoutTier` needs the leading and trailing pieces kept apart,
    /// not one combined, type-erased view.
    typealias CutoutTierBuilder = (ReaderEditingChromeContext) -> ReaderEditingCutoutTierContent

    @State private var editingHost: ReaderEditingHost
    @State private var editorViewModel: EditorViewModel
    /// The focused value the iPad menu bar reads (Ⅳb §3, Task 6). Built once — not computed in `body` — so every
    /// pass publishes the same object; see `AppCommandContext`'s doc comment for why a rebuilt instance would make
    /// the menus rebuild for nothing.
    @State private var commandContext: AppCommandContext
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
    /// The Editor logs nothing itself — it reports what the user did through closures, and this is where those become
    /// events. Kept for `wireOnce()`, the same way `repository` is.
    private let analytics: any Analytics
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
        // The score's ink, for the Editor's part-index migration only — a part add / remove / reorder renumbers the
        // staff each stroke is anchored to exactly as it renumbers the preferences row.
        //
        // Required here, unlike the Editor view model's own defaulted parameter: every real screen has ink to migrate,
        // and a default at this layer would let a wiring site forget it and silently ship the bug this exists to fix.
        // A host that genuinely has no store passes `nil` and says why.
        annotationStore: (any AnnotationBlobStore)?,
        analytics: any Analytics = NoopAnalytics(),
        startInEditMode: Bool = false,
        readerBuilder: @escaping (
            ReaderEditingHost, @escaping ChromeBuilder, @escaping ChromeBuilder, @escaping CutoutTierBuilder, Bool,
        ) -> ReaderRootScreen,
    ) {
        // Built as locals first so `editingHost`, `editorViewModel` and `commandContext` can all be seeded with the
        // very same instances — the context has to name the objects the menu bar's enablement rule reads (same
        // reason `MacEditableReaderScreen.init` does this).
        let host = ReaderEditingHost()
        let viewModel = EditorViewModel(
            scoreItem: item,
            scoresDirectory: scoresDirectory,
            gateway: gateway,
            repository: repository,
            originalStore: originalStore,
            historyStore: historyStore,
            playback: playbackController,
            annotationStore: annotationStore,
        )
        _editingHost = State(wrappedValue: host)
        _editorViewModel = State(wrappedValue: viewModel)
        _commandContext = State(wrappedValue: AppCommandContext(editor: viewModel, host: host))
        self.repository = repository
        self.analytics = analytics
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
                onPadAnchorFrameChange: { editingHost.noteInputPadFrame = $0 },
                onPadHandleAnchorFrameChange: { editingHost.noteInputPadHandleFrame = $0 },
                onPadDockMoved: { editingHost.notePadDockMoved() },
                onPadTucked: { editingHost.notePadTucked() },
                onPadRestored: { editingHost.notePadRestored() },
            ))
        }, { [editingHost] context in
            AnyView(EditorTopBarView(
                viewModel: editorViewModel,
                hasMusicalAnnotations: editingHost.hasMusicalAnnotationsProvider(),
                hasCutoutTier: context.hasCutoutTier,
                trailingAccessory: context.trailingAccessory,
                onDone: { editingHost.requestExit() },
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
            // Scene-scoped, matching the Mac's own publication (`MacEditableReaderScreen`): a menu command has to
            // find the key window's editor whether or not the score surface itself holds view focus.
            .focusedSceneValue(\.appCommandContext, commandContext)
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
        wireEditingSeam(host: editingHost, viewModel: editorViewModel, repository: repository, analytics: analytics)
    }
}

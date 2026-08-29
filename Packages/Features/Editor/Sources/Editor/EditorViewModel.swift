import Domain
import EditorCore
import Foundation
import Observation
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI

/// The Apple face of one editing session: an `@Observable` mirror of `EditorSessionCore`, plus the things that only
/// this platform has — the audio preview, the autosave timer, the hit-test's `LayoutDocument`, and the two callbacks
/// the Reader seam is wired to.
///
/// A mirror rather than a set of computed properties. Observation tracks *stored* property access, and the core is a
/// plain class it cannot see into: computing `score` from `core.session` would register no dependency, and every view
/// derived from it — the callout's length readout, `canTie`, `isCaretInTuplet` — would be computed once and never
/// again. `syncFromCore()` after each call is what makes the views recompute.
///
/// The public surface is unchanged from before the split, deliberately: `EditorChromeView`, `EditorPadView`,
/// `EditorCalloutView`, `EditorContextOps`, `SelectionCalloutLayer` and the App's `EditableReaderScreen` all drive
/// this type, and none of them is in this refactor's scope.
@MainActor
@Observable
public final class EditorViewModel {
    @ObservationIgnored let core: EditorSessionCore

    /// The session's live score, or nil outside a session. Views and the Reader seam render THIS score while editing.
    ///
    /// The `generation` read is load-bearing, not decoration — it is the stored property that registers the
    /// Observation dependency the core cannot.
    public var score: Score? {
        _ = generation
        return core.score
    }

    /// Bumped on every applied / undone / redone intent. The Reader includes it in its layout task key so the score
    /// re-lays-out after edits that don't change the structural score signature.
    public private(set) var generation = 0

    /// Bumped ONLY by a successful apply — never by `undo()`/`redo()`. Distinct from `generation` (which bumps on all
    /// three) because `EditorChromeView`'s system-undo bridge must re-register its `UndoManager` trampoline only on a
    /// genuinely NEW edit; re-registering after undo/redo would double up with `registerSystemUndo`'s own symmetric
    /// re-registration and drift the system stack from the session's real depth.
    public private(set) var appliedEditCount = 0

    /// This adapter's copy of `core.selectionRevision`. Not public: nothing outside reads it, and it exists only so
    /// `syncFromCore` can tell "the selection was placed again" from "the selection happens to be equal".
    private var selectionRevision = 0

    public var isSessionActive: Bool {
        _ = generation
        return core.isSessionActive
    }

    // Selection and caret, both rendered by the Reader through the seam — the selection as a tint on the item, the
    // caret as an insertion bar in front of a slot.
    public private(set) var selection: ScoreSelection = .none
    public private(set) var selectedItem: SheetMusicCore.ScoreItemID?
    public private(set) var caretItem: SheetMusicCore.ScoreItemID?

    /// Whether the pad has anything at all to act on. With neither a caret nor a selection there is no slot to write
    /// into and no item to edit, so every key is inert.
    public var hasEditTarget: Bool {
        caretItem != nil || selectedItem != nil
    }

    /// Whether the SELECTION names a notehead — the shape ⌫ / ♯ / ♭ need.
    public var isNoteSelected: Bool {
        if case .note = selectedItem { true } else { false }
    }

    /// Whether the floating callout has anything to stand beside.
    public var hasSelectionCallout: Bool {
        EditorSessionCore.slot(of: selectedItem) != nil
    }

    public private(set) var armedDuration: NoteDuration?
    public private(set) var armedDots = 0
    public private(set) var isAddToChordArmed = false
    public private(set) var armedTuplet = 3

    public var activeVoice = 0 {
        didSet { core.activeVoice = activeVoice }
    }

    /// Where the selected item currently sits on screen, in global coordinates — mirrored in by the composition root
    /// from the Reader's editing overlay, which is the only place that knows the document→screen transform. Drives
    /// the floating ♯ / ♭ callout's position; nil whenever nothing is selected.
    ///
    /// Republished on every scroll and zoom frame, so read it ONLY from the leaf view that draws the callout (see
    /// `SelectionCalloutLayer`) — reading it from a container's body re-renders that container at frame rate.
    public var selectionAnchor: CGRect?

    /// Mirrored from the reader's transport by the composition root. Setting it hands the fact to the core, which
    /// drops the selection when playback starts.
    public var isPlaybackActive = false {
        didSet {
            guard isPlaybackActive != oldValue else { return }
            core.isPlaybackActive = isPlaybackActive
            syncFromCore()
        }
    }

    /// True once a non-MSCX/MSCZ source has been rewritten as a sibling `.mscz` file. One-way: never reset, since it
    /// drives the one-time "saved as .mscz" notice.
    public private(set) var didSaveAsSiblingMSCZ = false

    // MARK: - Revert and discard
    //
    // The decisions are the core's (`EditorSessionCore+Revert.swift`) — what counts as an edit, what unwinding means,
    // what a revert does to the session. What lives here is what needs a screen or a run loop: the two confirmation
    // flags the sheets bind to, the message a failure shows, and the tasks a revert has to outrun.

    /// Whether this session has moved the score away from where it opened.
    public var sessionHasEdits: Bool {
        _ = generation
        return core.sessionHasEdits
    }

    /// What leaving the session should offer to do — drives the end-of-session buttons.
    public var sessionEndMode: EditorSessionEndMode {
        _ = generation
        return core.sessionEndMode
    }

    /// Whether the row records an original to go back to. Mirrored so the button that offers it re-renders.
    public internal(set) var hasCapturedOriginal = false

    public var canRevertToOriginal: Bool {
        hasCapturedOriginal
    }

    /// True when the original is what a PDF conversion produced rather than a file the user supplied — the warning
    /// copy differs, so the sheet asks.
    var revertsToConversionOutput: Bool {
        core.scoreItem.originalProvenance == .conversionOutput
    }

    public func revertWarnings(hasMusicalAnnotations: Bool) -> RevertWarnings {
        RevertPolicy.warnings(for: core.scoreItem, hasMusicalAnnotations: hasMusicalAnnotations)
    }

    /// Set when a revert could not be written. Nil the rest of the time.
    public internal(set) var revertError: String?

    public var isConfirmingRevert = false
    public var isConfirmingDiscard = false

    /// Fired once a revert has restored the file and the row, so the host can re-read the score it now names.
    public var onRevertCompleted: @MainActor (ScoreItem) -> Void = { _ in }

    /// The save currently in flight, if any. A revert awaits it before touching the file: cancelling `autosaveTask`
    /// does not reach a call already past `performSave()`'s entry guard.
    @ObservationIgnored var inFlightSaveTask: Task<Void, Never>?

    /// Whether the score has changed since the last successful save. Read by the revert tests to assert that a
    /// revert leaves nothing pending.
    var isDirty: Bool {
        core.isDirty
    }

    /// Applied minus undone since the session opened. Read by the cross-session-undo tests, which are about exactly
    /// this counter surviving (or not) an entry boundary.
    var sessionEditDepth: Int {
        _ = generation
        return core.sessionEditDepth
    }

    /// The live engine session, for the tests that assert on its identity across an entry — adoption means the very
    /// same object comes back, which no amount of score comparison can show.
    var session: ScoreEditSession? {
        core.session
    }

    #if DEBUG
    func previewSeedSessionEdit() {
        core.seedSessionEditDepthForPreview()
        syncFromCore()
    }

    var appliedIntents: [EditIntent] { core.appliedIntents }

    func markDirtyForTesting() {
        core.markDirtyForTesting()
    }

    func forgetSessionOpenScoreForTesting() {
        core.forgetSessionOpenScoreForTesting()
    }
    #endif

    /// Set synchronously by `performPendingAudition()` so tests can deterministically `await vm.auditionTask?.value`
    /// instead of racing a fire-and-forget preview.
    @ObservationIgnored var auditionTask: Task<Void, Never>?
    @ObservationIgnored var autosaveTask: Task<Void, Never>?

    /// Bumped when something outside the Editor asks for the input pad — today, the host's note-input coach mark
    /// being tapped. A counter rather than a `Bool` so a second request still lands after the user has closed the pad
    /// again; the chrome owns the actual `editorPadVisible` state and watches this.
    public private(set) var padRevealRequests = 0

    /// Asks the chrome to bring the input pad up. Safe to call whether or not the pad is already showing.
    public func requestPadReveal() {
        padRevealRequests += 1
    }

    public var canUndo: Bool {
        _ = generation
        return core.canUndo
    }

    public var canRedo: Bool {
        _ = generation
        return core.canRedo
    }

    /// Wired by the App composition root. Returns the Reader's current LayoutDocument for hit-testing.
    public var documentProvider: @MainActor () -> LayoutDocument? = { nil }
    /// Re-addresses an item resolved against that document into the score's own addressing, or `nil` if it can't be
    /// placed there.
    ///
    /// The two spaces can differ: the Reader may render a staff-filtered rendition of the score (the reader hid a
    /// staff) while this view model edits — and saves — the score entire. Filtering renumbers `StaffAddress`, so a
    /// hit test against the rendered document names a staff by its position on screen, not its position in the file.
    /// The default is identity, which is exactly right when nothing is filtered; the App supplies the real mapping.
    public var displayToSourceItem: @MainActor (SheetMusicCore.ScoreItemID) -> SheetMusicCore.ScoreItemID? = { $0 }
    /// Fired after every score mutation with the fresh score (App mirrors it into the Reader seam).
    public var onScoreChanged: @MainActor (Score) -> Void = { _ in }
    /// Fired whenever the selection or the caret changes (App mirrors both into the Reader seam: the first argument
    /// tints the selected item, the second draws the insertion caret).
    public var onSelectionChanged: @MainActor (ScoreSelection, SheetMusicCore.ScoreItemID?) -> Void = { _, _ in }

    /// The audio seam. The other two — the digest and the writer — belong to the core, which is what decides when a
    /// save is due; this one stays here because sounding a note needs a `Task` and an audio session.
    @ObservationIgnored let audition: (any NoteAuditioning)?
    @ObservationIgnored let repository: any ScoreLibraryRepository

    /// Keeps a finished session's undo stack alive so reopening the same unchanged file can undo across the gap.
    /// Held here rather than in the core because the protocol is `@MainActor` by design — its `ScoreEditSession` is
    /// non-`Sendable` — and the core also runs on Android's JNI thread. See `EditorSessionCore.beginSession`.
    @ObservationIgnored let historyStore: any ScoreEditHistoryStore

    public init(
        scoreItem: ScoreItem,
        scoresDirectory: URL,
        gateway: any ScoreFileGateway,
        repository: any ScoreLibraryRepository,
        originalStore: any ScoreOriginalStore,
        historyStore: any ScoreEditHistoryStore,
        playback: (any PlaybackController)?,
    ) {
        core = EditorSessionCore(
            scoreItem: scoreItem,
            scoresDirectory: scoresDirectory,
            fileFacts: EditorFileFacts(),
            writer: GatewayScoreWriter(gateway: gateway, repository: repository),
            originals: originalStore,
        )
        self.historyStore = historyStore
        self.repository = repository
        audition = playback.map(PlaybackAudition.init(controller:))
        hasCapturedOriginal = core.hasCapturedOriginal
    }

    /// Stable identity of the row this session's saves and captures act on — safe to read from outside the module
    /// without exposing the whole (frequently stale) row itself.
    public var scoreItemID: Domain.ScoreItemID {
        core.scoreItem.id
    }

    /// The library row as the last save left it.
    public var scoreItem: ScoreItem {
        _ = generation
        return core.scoreItem
    }

    /// Re-seeds the row the next capture/save acts on. Call before `beginSession` — see the core's own doc for the
    /// staleness this closes.
    public func refreshRow(_ item: ScoreItem) {
        core.refreshRow(item)
        hasCapturedOriginal = core.hasCapturedOriginal
    }

    // MARK: - Lifecycle

    public func beginSession(score: Score) {
        // Keyed on the content hash, so a file that changed underneath us gets a fresh session rather than an undo
        // stack addressed to notes that have moved.
        let retained = historyStore.session(for: core.scoreItem.id, contentHash: core.scoreItem.contentHash)
        let adopted = core.beginSession(score: score, adopting: retained)
        core.activeVoice = activeVoice
        // Opening a session is not an edit: match the counter first so `syncFromCore` neither announces a score nor
        // arms the autosave timer for it. The one announcement an open owes the host is the adopted score below.
        generation = core.revision
        syncFromCore()
        // A resumed session opens on the score the PREVIOUS one left, not the one just parsed off disk, so the host
        // has to be told about it — `syncFromCore` only announces a score the revision moved.
        if let adopted { onScoreChanged(adopted) }
        Task { await reconcileCapturedOriginal() }
    }

    /// Adopts an original that is on disk but missing from the row, and persists the row that names it.
    public func reconcileCapturedOriginal() async {
        guard let adopted = await core.reconcileCapturedOriginal() else { return }
        hasCapturedOriginal = true
        try? await repository.saveScoreItem(adopted)
    }

    /// Flushes any pending autosave and tears the session down.
    public func endSession() async {
        // Captured BEFORE the flush: that flush is a real file write the caller does not wait for, so by the time it
        // returns the user can already be in a new session — which must be neither deposited nor torn down.
        guard let ending = core.session else { return }
        await flushPendingSave()
        if core.shouldRetain(ending) {
            historyStore.retain(ending, for: core.scoreItem.id, contentHash: core.scoreItem.contentHash)
        }
        core.endSession(ifStillOn: ending)
        syncFromCore()
    }

    public func undo() {
        core.undo()
        syncFromCore()
    }

    public func redo() {
        core.redo()
        syncFromCore()
    }

    /// Bridges the session's own stacks to the system UndoManager so three-finger swipe gestures work. Each mutation
    /// registers one undo action; performing it re-registers the redo symmetrically. The session remains the source
    /// of truth — the UndoManager holds only trampolines.
    func registerSystemUndo(with manager: UndoManager?) {
        guard let manager else { return }
        manager.registerUndo(withTarget: self) { vm in
            vm.undo()
            manager.registerUndo(withTarget: vm) { vm2 in
                vm2.redo()
                vm2.registerSystemUndo(with: manager)
            }
        }
    }

    // MARK: - The mirror

    /// Re-reads everything the core owns, performs the side effects it asked for, and fires the two seam callbacks
    /// when it says something moved.
    ///
    /// **Selection is announced before the score.** That is the shipped order — `apply` used to call
    /// `rederiveSelection()` (which fired `onSelectionChanged` through `place`) before `onScoreChanged` — and it is
    /// not an accident: the Reader host sets `editedScore` and `selection` from these two callbacks, and a selection
    /// arriving before its score names an item the host cannot resolve yet. Keeping the order keeps that working.
    func syncFromCore() {
        let scoreMoved = generation != core.revision
        let selectionMoved = selectionRevision != core.selectionRevision
        generation = core.revision
        appliedEditCount = core.appliedIntentCount
        selectionRevision = core.selectionRevision
        selectedItem = core.selectedItem
        caretItem = core.caretItem
        selection = core.selectedItem.map(ScoreSelection.single) ?? .none
        armedDuration = core.armedDuration
        armedDots = core.armedDots
        isAddToChordArmed = core.isAddToChordArmed
        armedTuplet = core.armedTuplet
        didSaveAsSiblingMSCZ = core.didSaveAsSiblingMSCZ
        hasCapturedOriginal = core.hasCapturedOriginal
        performPendingAudition()
        if selectionMoved { onSelectionChanged(selection, caretItem) }
        if scoreMoved, let score = core.score {
            onScoreChanged(score)
            scheduleAutosave()
        }
    }
}

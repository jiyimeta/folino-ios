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

    public init(
        scoreItem: ScoreItem,
        scoresDirectory: URL,
        gateway: any ScoreFileGateway,
        repository: any ScoreLibraryRepository,
        playback: (any PlaybackController)?,
    ) {
        core = EditorSessionCore(
            scoreItem: scoreItem,
            scoresDirectory: scoresDirectory,
            fileFacts: EditorFileFacts(),
            writer: GatewayScoreWriter(gateway: gateway, repository: repository),
        )
        audition = playback.map(PlaybackAudition.init(controller:))
    }

    // MARK: - Lifecycle

    public func beginSession(score: Score) {
        core.beginSession(score: score)
        core.activeVoice = activeVoice
        syncFromCore()
    }

    /// Flushes any pending autosave and tears the session down.
    public func endSession() async {
        await flushPendingSave()
        core.endSession()
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
        performPendingAudition()
        if selectionMoved { onSelectionChanged(selection, caretItem) }
        if scoreMoved, let score = core.score {
            onScoreChanged(score)
            scheduleAutosave()
        }
    }
}

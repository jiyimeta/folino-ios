import Domain
import Foundation
import Observation
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI

/// Owns the engine `ScoreEditSession` for one editing session: applies commands, manages selection / voice / arming
/// state, re-derives selection after every mutation, and drives autosave. Created once per Reader screen by the App
/// composition root; `beginSession(score:)` / `endSession()` bracket each entry into edit mode.
@MainActor
@Observable
public final class EditorViewModel {
    /// The engine session for one editing entry — `ScoreEditSession` plans each `EditIntent` into commands and owns
    /// both undo stacks. Internal: views read the derived `score` / `canUndo` / `canRedo`, never the session itself.
    var session: ScoreEditSession?

    /// A value snapshot of the score this session opened on, taken by `beginSession` on BOTH the fresh and the
    /// adopted path and dropped when the session ends — one `Score` copy per session.
    ///
    /// It exists because the undo/redo stacks are NOT a sufficient snapshot once history outlives a session:
    /// `ScoreEditor.apply` clears the redo stack, so a session that undid below its own start and then typed a note
    /// has nothing left to redo back with. See `unwindSessionEdits()`, which lands on this when its loops cannot.
    @ObservationIgnored var sessionOpenScore: Score?
    /// The session's live score, or nil outside a session. Views and the Reader seam render THIS score while editing.
    ///
    /// The `generation` read is load-bearing, not decoration. `ScoreEditSession` is a plain class, so mutating the
    /// score inside it changes nothing Observation can see — the `session` reference is the same object it was.
    /// Anything a view derives from the score (the callout's length readout and its highlighted key, `canTie`,
    /// `isCaretInTuplet`) would then be computed once and never again: change a note's length with the tray open and
    /// the tray kept showing the old one. Touching `generation` — a stored property this type bumps on every applied
    /// edit, undo and redo — registers the dependency that makes those views recompute.
    public var score: Score? {
        _ = generation
        return session?.score
    }

    /// Bumped on every applied / undone / redone command. The Reader includes it in its layout task key so the
    /// score re-lays-out after edits that don't change the structural score signature.
    ///
    /// internal(set) for the same reason as the selection and arming state below: `unwindSessionEdits()` lives
    /// beside the discard path it serves, and Swift's `private` does not span files.
    public internal(set) var generation = 0

    /// Bumped ONLY by `apply`'s success path — never by `undo()`/`redo()`. Distinct from `generation` (which
    /// bumps on all three) because `EditorChromeView`'s system-undo bridge must re-register its `UndoManager`
    /// trampoline only on a genuinely NEW edit; re-registering after undo/redo would double up with
    /// `registerSystemUndo`'s own symmetric re-registration and drift the system stack from `ScoreEditSession`'s
    /// real depth (Task 16 review fix).
    public private(set) var appliedEditCount = 0

    /// The session's signed net offset from its starting score: incremented by `apply` and `redo()`, decremented
    /// by `undo()`, reset by `beginSession`. NEGATIVE when the session has undone below its own start — adopted
    /// history makes that reachable — which is still a change to the score this session made.
    ///
    /// Observed, and maintained here rather than read from the session, because the strip's session-end control
    /// switches on it (through `sessionHasEdits`, which uses it as its fast path and the session-open snapshot as
    /// its authority): a mutation inside `ScoreEditSession` (a reference type from another module) notifies
    /// nothing, so a view bound to `canUndo` only refreshes when something else in the same body pass happens to
    /// change. This is what makes "the moment you change something, the control changes" true.
    ///
    /// internal(set) for `unwindSessionEdits()`'s sake (see `generation`). Written by four places: the three that
    /// move it one step (`apply`, `undo`, `redo`) and the unwind. None of them may zero it without having moved
    /// the score with it — see the unwind.
    public internal(set) var sessionEditDepth = 0

    public var isSessionActive: Bool {
        session != nil
    }

    #if DEBUG
    /// Puts a preview into the "this session changed something" state without running a real edit. Here rather than
    /// beside the previews that use it because `sessionEditDepth`'s setter is internal to this module.
    func previewSeedSessionEdit() {
        sessionEditDepth = 1
    }

    /// Marks the session as having something to write, for a test that needs a save to actually run without going
    /// through a real edit command. `isDirty` is file-private, hence this.
    func markDirtyForTesting() {
        isDirty = true
    }

    /// Drops the session-open snapshot, leaving a session the unwind has no way to land — the one state
    /// `unwindSessionEdits()`'s "never zero a depth the loops did not consume" branch exists for, and which no
    /// production path can reach (`beginSession` always takes the snapshot). Lets a test prove the discard path
    /// refuses to persist a score it failed to unwind.
    func forgetSessionOpenScoreForTesting() {
        sessionOpenScore = nil
    }

    /// Every intent handed to `apply(_:)`, in order, refused ones included — the seam the intent-construction tests
    /// read. DEBUG-only: release builds carry neither the array nor its appends.
    @ObservationIgnored private(set) var appliedIntents: [EditIntent] = []
    #endif

    // Selection and caret (both rendered by the Reader through the seam — the selection as a tint on the item, the
    // caret as an insertion bar in front of a slot).
    //
    // They are two different things and only coincide when you pick a target explicitly (tap, ← / →). The caret is
    // where the NEXT note lands; the selection is the note the editing keys act on. Writing a run of notes moves the
    // caret on after each one while the selection stays on the note just written — so ♯ / ♭ / ⌫ keep addressing what
    // you just played rather than the empty slot ahead of it.
    // internal(set), not private(set): `EditorViewModel+Revert.swift` clears all three directly to tear a session
    // down without routing through `place(selection:caret:)` (which would fire `onSelectionChanged` and re-arm from
    // a selection that no longer exists once the editor is gone).
    public internal(set) var selection: ScoreSelection = .none
    public internal(set) var selectedItem: SheetMusicCore.ScoreItemID?
    public internal(set) var caretItem: SheetMusicCore.ScoreItemID?

    // Arming state (Tasks 5/7). internal(set), not private(set): the ops live in same-type extensions in OTHER
    // files (`EditorViewModel+Input.swift` etc.), and Swift's `private` does not span files.
    //
    // The armed duration describes what the NEXT note or rest will be — it never reaches back and re-times what is
    // already written. Base value and augmentation dots are held apart (rather than as one dotted `.fraction`) so
    // the two keys can light independently: a dot rides on whichever length is armed.
    public internal(set) var armedDuration: NoteDuration?
    public internal(set) var armedDots = 0
    public internal(set) var isAddToChordArmed = false

    /// The tuplet the key writes on a plain tap, and the number it wears. Triplets to begin with, since that is what
    /// these parts are full of — but a piece that wants quintuplets wants them repeatedly, so the last size chosen
    /// from the long-press menu becomes the tap. Deliberately NOT reset by `beginSession`: it is a preference about
    /// how you are writing, not state about one score.
    public internal(set) var armedTuplet = 3

    /// The duration input actually writes: the armed length with its dots applied. `nil` until a length is armed —
    /// which, thanks to `armFromSelectionIfNeeded`, means only before the first thing is picked in a session.
    var armedInputDuration: NoteDuration? {
        guard let armedDuration else { return nil }
        return armedDots > 0 ? armedDuration.dotted(armedDots) : armedDuration
    }

    public var activeVoice = 0

    /// Where the selected item currently sits on screen, in global coordinates — mirrored in by the composition root
    /// from the Reader's editing overlay, which is the only place that knows the document→screen transform. Drives
    /// the floating ♯ / ♭ callout's position; nil whenever nothing is selected.
    ///
    /// Republished on every scroll and zoom frame, so read it ONLY from the leaf view that draws the callout (see
    /// `SelectionCalloutLayer`) — reading it from a container's body re-renders that container at frame rate.
    public var selectionAnchor: CGRect?

    /// Mirrored from the reader's transport by the composition root. Editing and playback coexist — you can hear the
    /// passage you're writing without leaving edit mode — but the pad's keys go inert while the cursor runs: applying
    /// an edit mid-playback reflows the score out from under the cursor, and the audition preview would fight the
    /// playing engine for the same notes.
    ///
    /// Starting playback also drops the selection. The transport seeks to the selected note before it starts (see
    /// `ReaderRootScreen`'s `startCursorProvider`), and from that moment the playhead — not the selection — is where
    /// the music is; leaving a stale highlight on the note you started from just competes with it. It also means the
    /// pad and callout fold away on their own rather than sitting there inert for the length of the piece.
    public var isPlaybackActive = false {
        didSet {
            guard isPlaybackActive, isPlaybackActive != oldValue else { return }
            select(nil)
        }
    }

    /// Stored audition state (Task 9) — declared HERE (extensions cannot add stored properties). Set synchronously
    /// by `audition(_:)` (`EditorViewModel+Audition.swift`) so tests can deterministically `await
    /// vm.auditionTask?.value` instead of racing a fire-and-forget preview.
    @ObservationIgnored var auditionTask: Task<Void, Never>?

    // Stored autosave state (Task 10) — declared HERE (extensions cannot add stored properties).
    @ObservationIgnored var autosaveTask: Task<Void, Never>?
    @ObservationIgnored var isDirty = false
    /// True from the moment `revertToOriginal()` commits to reverting until the session ends. `performSave()`
    /// honours it both at entry and again after its one suspension point, so a debounce or scene-background flush
    /// that lands mid-revert finds nothing to do instead of racing the store's file swap (Critical 2 review fix).
    @ObservationIgnored var isReverting = false
    /// The `Task` wrapping whichever `performSave()` call is currently running, from either trigger site below —
    /// so `revertToOriginal()` can wait for it to finish before touching the file itself. `performSave()` is a
    /// plain `async` method with two call sites, neither of which is itself a `Task`, so this is the one handle
    /// common to both (Critical 2 review fix).
    @ObservationIgnored var inFlightSaveTask: Task<Void, Never>?
    /// True once a non-MSCX/MSCZ source has been rewritten as a sibling `.mscz` file. One-way: never reset, since
    /// it drives the Task 16 one-time "saved as .mscz" notice.
    public internal(set) var didSaveAsSiblingMSCZ = false
    /// True once this session was ended by ✕ — `discardSessionEdits()` ran. Read by `endSession()`'s deposit guard,
    /// because the ✕ exit path still runs `endSession()` (`EditorDiscardButton` → `requestExit()` → `onEndEditing`):
    /// a discarded session's history — the redo of the discarded edits included — must not survive into the next
    /// session. Reset by `beginSession`.
    @ObservationIgnored var didDiscardSession = false

    public var canUndo: Bool {
        session?.canUndo ?? false
    }

    public var canRedo: Bool {
        session?.canRedo ?? false
    }

    /// Wired by the App composition root.
    /// Returns the Reader's current LayoutDocument for hit-testing (Task 8).
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
    /// Fired after a successful revert with the rebuilt row. The App mirrors it into the Reader, which reloads the
    /// score from disk — the Editor cannot reach the Reader directly.
    public var onRevertCompleted: @MainActor (ScoreItem) -> Void = { _ in }
    /// Set when a revert failed, for the chrome to surface. Cleared at the start of each attempt.
    public internal(set) var revertError: String?
    /// Drives the revert confirmation dialog. On the view model, not view-local `@State`, so `EditorRevertButton`
    /// (cutout tier OR `EditorTopBarView`'s row) and the dialog (always on `EditorTopBarView`'s root) share it.
    public var isConfirmingRevert = false
    /// Drives the discard confirmation ✕ raises when the session has edits. Same reasoning as `isConfirmingRevert`:
    /// the button and the dialog live in different tiers, so the flag cannot be view-local.
    public var isConfirmingDiscard = false
    /// `true` when THIS session's first save is what captured the original sidecar — i.e. before this session the
    /// score had never been edited. Discarding such a session has to take the sidecar back out, or the score would
    /// keep offering "revert to original" while being byte-identical to it.
    @ObservationIgnored var capturedOriginalThisSession = false

    @ObservationIgnored let gateway: any ScoreFileGateway
    @ObservationIgnored let repository: any ScoreLibraryRepository
    @ObservationIgnored let playback: (any PlaybackController)?
    @ObservationIgnored let originalStore: any ScoreOriginalStore
    @ObservationIgnored let historyStore: any ScoreEditHistoryStore
    /// Mirrors `scoreItem.canRevertToOriginal` as an OBSERVED property. `scoreItem` is `@ObservationIgnored`, so a
    /// toolbar reading it directly would not re-evaluate when the session's first autosave captures the original —
    /// the `⋯` item would not appear until the chrome happened to rebuild for some other reason.
    public internal(set) var hasCapturedOriginal: Bool
    /// Internal (not private) so `EditorViewModel+Persistence.swift` can replace it after a save refreshes the row.
    @ObservationIgnored var scoreItem: ScoreItem
    @ObservationIgnored let scoresDirectory: URL

    public init(
        scoreItem: ScoreItem,
        scoresDirectory: URL,
        gateway: any ScoreFileGateway,
        repository: any ScoreLibraryRepository,
        originalStore: any ScoreOriginalStore,
        historyStore: any ScoreEditHistoryStore,
        playback: (any PlaybackController)?,
    ) {
        self.scoreItem = scoreItem
        self.scoresDirectory = scoresDirectory
        self.gateway = gateway
        self.repository = repository
        self.originalStore = originalStore
        self.historyStore = historyStore
        self.playback = playback
        hasCapturedOriginal = scoreItem.canRevertToOriginal
    }

    public func beginSession(score: Score) {
        // A retained session is adopted as-is, and from that moment ITS score is the session's score — the `score:`
        // argument is dropped. The hash guard only proves the FILE has not changed since the deposit; it says
        // nothing about `parse(bytes) == session.score`, and the store is process-wide, so the two can legitimately
        // be different objects (✓ out of a score, close the Reader, reopen it from the Library: the Reader parses
        // from disk while this adopts the previous Reader's in-memory score). `onScoreChanged` below is what makes
        // the host definitionally show the adopted score rather than discover the difference at the first undo.
        //
        // A miss — nothing retained, or the file rewritten out-of-band since the deposit (revert, re-import,
        // version restore, PDF re-read) — starts fresh. `scoreItem.contentHash` is current here because the host
        // re-seeds the row (`refreshRow`) before every `beginSession` (`EditableReaderScreen.wireOnce()`).
        let adopted = historyStore.session(for: scoreItem.id, contentHash: scoreItem.contentHash)
        session = adopted ?? ScoreEditSession(score: score)
        // Both paths, because both need a way back: the fresh session's stack bottom would do, the adopted one's
        // would not (it is the PREVIOUS session's start), and `unwindSessionEdits()` must not have to tell them
        // apart.
        sessionOpenScore = session?.score
        generation = 0
        appliedEditCount = 0
        sessionEditDepth = 0
        didDiscardSession = false
        capturedOriginalThisSession = false
        // Fire-and-forget: the strip's revert offer is derived from the row, and the row can be behind what is
        // actually on disk. Nothing downstream waits on this — when it finds something, the control changes.
        Task { await reconcileCapturedOriginal() }
        selection = .none
        selectedItem = nil
        caretItem = nil
        armedDuration = nil
        armedDots = 0
        isAddToChordArmed = false
        // Only on the adopted path: a fresh session's score IS the argument the host just handed in, so telling it
        // about its own score would cost a re-layout for nothing.
        if let adopted {
            onScoreChanged(adopted.score)
        }
    }

    /// Flushes any pending autosave, deposits the session for the next entry on this score, and drops it.
    ///
    /// The ending session is captured up front and everything below acts on THAT object, never on a re-read of
    /// `self.session`. The caller is fire-and-forget (`EditableReaderScreen`: `Task { await vm.endSession() }`) and
    /// the flush is an unbounded await — a real gateway write plus a repository save — so a `beginSession` can
    /// legitimately land in that window. Re-reading `self.session` afterwards would deposit the NEW, live session
    /// into the store and then null it out, leaving a user who has just entered edit mode with a dead editor. The
    /// identity check before the teardown is the other half: only the session this call is ending may be cleared,
    /// which also makes a second `endSession()` a no-op rather than a second deposit. (The flush itself has to run
    /// BEFORE the teardown, not after the capture — `performSave()` writes `self.score`, which is the session's.)
    public func endSession() async {
        guard let ending = session else { return }
        await flushPendingSave()
        depositIfWorthKeeping(ending)
        guard session === ending else { return }
        session = nil
        sessionOpenScore = nil
    }

    /// Deposits the session — only when the flush left nothing unsaved (a failed final save discards the session,
    /// exactly today's failure contract: a retained history must describe bytes that are actually on disk) and the
    /// session has any history at all (an untouched session has nothing worth a slot). `scoreItem.contentHash` is
    /// the digest of exactly the bytes `session.score` was last saved as, because `flushPendingSave()` ran first.
    private func depositIfWorthKeeping(_ session: ScoreEditSession) {
        guard !didDiscardSession, !isDirty, session.canUndo || session.canRedo else { return }
        historyStore.retain(session, for: scoreItem.id, contentHash: scoreItem.contentHash)
    }

    public func undo() {
        // `session.undo()` guards `canUndo` and reports an engine failure as `false`, preserving the old contract:
        // a swallowed failure must not fire a false generation bump / onSelectionChanged / onScoreChanged.
        guard let session, session.undo() else { return }
        sessionEditDepth -= 1
        generation += 1
        rederiveSelection()
        onScoreChanged(session.score)
        isDirty = true
        scheduleAutosave()
    }

    public func redo() {
        guard let session, session.redo() else { return }
        sessionEditDepth += 1
        generation += 1
        rederiveSelection()
        onScoreChanged(session.score)
        isDirty = true
        scheduleAutosave()
    }

    /// Bridges ScoreEditSession's own stacks to the system UndoManager so three-finger swipe gestures work. Each
    /// mutation registers one undo action; performing it re-registers the redo symmetrically. The ScoreEditSession
    /// remains the source of truth — the UndoManager holds only trampolines.
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

    /// Central apply choke point: every edit goes through here so selection re-derivation, generation bump,
    /// `onScoreChanged`, and autosave scheduling can never be skipped. Internal — ops extensions call it. Returns
    /// `false` when the session refused the intent; the engine's contract leaves the score untouched, so no side
    /// effect fires (`session.lastRefusalReason` carries the diagnostic when debugging a refusal). The session owns
    /// the planning — cross-bar chains, full-measure collapse, `.measure` promotion, tie-chain retuning — AND the
    /// accidental renotation pass that used to be a private helper on this type before the engine swap.
    @discardableResult
    func apply(_ intent: EditIntent) -> Bool {
        #if DEBUG
        appliedIntents.append(intent)
        #endif
        guard let session, session.apply(intent) else { return false }
        generation += 1
        appliedEditCount += 1
        sessionEditDepth += 1
        rederiveSelection()
        onScoreChanged(session.score)
        isDirty = true
        scheduleAutosave()
        return true
    }
}

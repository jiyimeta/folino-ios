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
    public private(set) var generation = 0

    /// Bumped ONLY by `apply`'s success path — never by `undo()`/`redo()`. Distinct from `generation` (which
    /// bumps on all three) because `EditorChromeView`'s system-undo bridge must re-register its `UndoManager`
    /// trampoline only on a genuinely NEW edit; re-registering after undo/redo would double up with
    /// `registerSystemUndo`'s own symmetric re-registration and drift the system stack from `ScoreEditSession`'s
    /// real depth (Task 16 review fix).
    public private(set) var appliedEditCount = 0

    /// How deep this session's undo stack is: incremented by `apply` and `redo()`, decremented by `undo()`,
    /// reset by `beginSession`. Distinct from `appliedEditCount`, which only ever counts up.
    ///
    /// Observed, and maintained here rather than read from `ScoreEditSession.canUndo`, because the strip's
    /// session-end control switches on it: a mutation inside `ScoreEditSession` (a reference type from another
    /// module) notifies nothing, so a view bound to `canUndo` only refreshes when something else in the same body
    /// pass happens to change. This is what makes "the moment you change something, the control changes" true.
    public private(set) var sessionEditDepth = 0

    /// Whether this session has anything of its own to throw away — the difference between ✕ closing the session
    /// and ✕ asking first.
    public var sessionHasEdits: Bool {
        sessionEditDepth > 0
    }

    public var isSessionActive: Bool {
        session != nil
    }

    #if DEBUG
    /// Puts a preview into the "this session changed something" state without running a real edit. Here rather than
    /// beside the previews that use it because `sessionEditDepth`'s setter is private to this file.
    func previewSeedSessionEdit() {
        sessionEditDepth = 1
    }

    /// Marks the session as having something to write, for a test that needs a save to actually run without going
    /// through a real edit command. `isDirty` is file-private, hence this.
    func markDirtyForTesting() {
        isDirty = true
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

    /// Bumped when something outside the Editor asks for the input pad — today, the host's note-input coach mark being
    /// tapped. A counter rather than a `Bool` so a second request still lands after the user has closed the pad again;
    /// the chrome owns the actual `editorPadVisible` state and watches this.
    public private(set) var padRevealRequests = 0

    /// Asks the chrome to bring the input pad up. Safe to call whether or not the pad is already showing.
    public func requestPadReveal() {
        padRevealRequests += 1
    }

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
        // A retained session is adopted as-is: the hash matched the very bytes `score` was parsed from, so its
        // `score` is value-equal to what the Reader just loaded. A miss — nothing retained, or the file rewritten
        // out-of-band since the deposit (revert, re-import, version restore, PDF re-read) — starts fresh.
        // `scoreItem.contentHash` is current here because the host re-seeds the row (`refreshRow`) before every
        // `beginSession` (`EditableReaderScreen.wireOnce()`).
        session = historyStore.session(for: scoreItem.id, contentHash: scoreItem.contentHash)
            ?? ScoreEditSession(score: score)
        generation = 0
        appliedEditCount = 0
        sessionEditDepth = 0
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
    }

    /// Flushes any pending autosave, deposits the session for the next entry on this score, and drops it.
    public func endSession() async {
        await flushPendingSave()
        depositSessionIfWorthKeeping()
        session = nil
    }

    /// Deposits the session — only when the flush left nothing unsaved (a failed final save discards the session,
    /// exactly today's failure contract: a retained history must describe bytes that are actually on disk) and the
    /// session has any history at all (an untouched session has nothing worth a slot). `scoreItem.contentHash` is
    /// the digest of exactly the bytes `session.score` was last saved as, because `flushPendingSave()` ran first.
    private func depositSessionIfWorthKeeping() {
        guard let session, !isDirty, session.canUndo || session.canRedo else { return }
        historyStore.retain(session, for: scoreItem.id, contentHash: scoreItem.contentHash)
    }

    public func undo() {
        // `session.undo()` guards `canUndo` and reports an engine failure as `false`, preserving the old contract:
        // a swallowed failure must not fire a false generation bump / onSelectionChanged / onScoreChanged.
        guard let session, session.undo() else { return }
        sessionEditDepth = max(0, sessionEditDepth - 1)
        generation += 1
        rederiveSelection()
        onScoreChanged(session.score)
        isDirty = true
        scheduleAutosave()
    }

    /// Unwinds this session's whole undo stack at once, notifying the host a single time at the end.
    ///
    /// Lives here, next to `undo()`, because `sessionEditDepth`, `generation` and `rederiveSelection` are all
    /// file-private to this type — and because the loop is the same operation as `undo()`, just without a stopping
    /// point. `discardSessionEdits()` owns the rest of the story (the disk, the sidecar); this owns the score.
    ///
    /// One notification rather than one per step: the host re-lays the score out on every `onScoreChanged`, so a
    /// long session would otherwise redraw the whole thing once per edit on the way back.
    func unwindSessionEdits() {
        guard let session else { return }
        while session.canUndo {
            guard session.undo() else { break }
        }
        sessionEditDepth = 0
        generation += 1
        rederiveSelection()
        onScoreChanged(session.score)
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

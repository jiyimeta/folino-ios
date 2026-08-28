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

    /// Bumped on every applied / undone / redone command, for the life of this view model, and NEVER reset.
    ///
    /// `generation` and `appliedEditCount` both go back to zero at `beginSession`, which makes them useless as the
    /// "did anything land while I was suspended?" sentinel `performSave` needs: a `beginSession` arriving in one of
    /// its awaits would move the counter backwards and read as a mutation. This one only ever goes up, so comparing
    /// it across a suspension answers exactly the question asked.
    @ObservationIgnored var mutationTicket = 0

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
    ///
    /// internal(set) for the same reason as `generation` and `sessionEditDepth` below: `beginSession` resets it and
    /// lives in `EditorViewModel+Session.swift`, and Swift's `private` does not span files. Still write-restricted
    /// to this module — `apply`'s success path is the only thing that increments it.
    public internal(set) var appliedEditCount = 0

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
    /// What the most recent `migratePartIndexedState` actually wrote, or `nil` when it wrote nothing. Read once
    /// by the part op's own commit, which reports it through `onPartIndicesRemapped` and clears it — a stored relay
    /// rather than a return value because the save that performs the migration is not the call that has to report it
    /// (a debounce tick or a `flushPendingSave` from anywhere can be the one that runs it).
    @ObservationIgnored var lastAppliedPartMapping: [Int: Int?]?
    /// How many part edits have been applied but not yet had their save settle. A count, not a flag, because each op
    /// flushes its own save and an op applied while an earlier flush is still running would otherwise see that
    /// earlier settle lift the host's hold while its own numbering is still unreconciled.
    @ObservationIgnored var unsettledPartEdits = 0
    /// The part op's own commit — its immediate flush plus the settle that follows. Fire-and-forget in production;
    /// stored for the same reason `auditionTask` is, so a test can `await vm.partEditCommitTask?.value` instead of
    /// racing it. Chained onto the previous one so overlapping ops settle in the order they were applied.
    @ObservationIgnored var partEditCommitTask: Task<Void, Never>?

    /// True once a non-MSCX/MSCZ source has been rewritten as a sibling `.mscz` file. One-way: never reset, since
    /// it drives the Task 16 one-time "saved as .mscz" notice.
    public internal(set) var didSaveAsSiblingMSCZ = false
    /// True once this session was ended by ✕ — `discardSessionEdits()` ran. Read by `endSession()`'s deposit guard,
    /// because the ✕ exit path still runs `endSession()` (`EditorDiscardButton` → `requestExit()` → `onEndEditing`):
    /// a discarded session's history — the redo of the discarded edits included — must not survive into the next
    /// session. Reset by `beginSession`.
    @ObservationIgnored var didDiscardSession = false

    /// Bumped when something outside the Editor asks for the input pad — today, the host's note-input coach mark being
    /// tapped. A counter rather than a `Bool` so a second request still lands after the user has closed the pad again;
    /// the chrome owns the actual `editorPadVisible` state and watches this.
    public private(set) var padRevealRequests = 0

    /// Asks the chrome to bring the input pad up. Safe to call whether or not the pad is already showing.
    public func requestPadReveal() {
        padRevealRequests += 1
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
    /// Raised the instant a part add / remove / reorder is applied (or an undo / redo puts the parts somewhere the
    /// preferences row has not been told about) — the start of the window in which the score and the row disagree
    /// about what a part index means.
    ///
    /// BOTH directions of that disagreement corrupt the row, which is why the host has to stop writing it rather
    /// than merely re-read it afterwards. A Reader write stamped in the NEW numbering that lands before the
    /// migration reads gets remapped a second time and ends up pointing at a different part; one stamped in the OLD
    /// numbering that lands after it clobbers the migrated row — and the map has been consumed by then, so nothing
    /// ever retries and the row is wrong for good.
    ///
    /// **Raise only.** The Editor cannot say when it is safe to lower it: the row is settled at the end of the save,
    /// but the host's own in-memory copy is not settled until it has re-read that row, and between the two it is
    /// still holding the pre-migration addresses. So the release belongs to whoever performs the re-read — see
    /// `hasUnsettledPartEdits`, which is how it asks whether a LATER part edit has since raised it again.
    public var onPartEditApplied: @MainActor () -> Void = {}
    /// Awaited once per part edit, after the hold is up and BEFORE the migration reads. The host uses it to land
    /// whatever it still has in the air — the Reader's annotation saves are debounced, so a capture registered just
    /// before the part edit can still be sitting in that debounce, and a write that lands AFTER the migration read
    /// would overwrite the migrated layer with the old numbering, with the mapping consumed and nothing left to retry.
    /// Draining here rather than at the release is what puts it on the right side of the read.
    public var onPartMigrationWillRun: @MainActor () async -> Void = {}
    /// Fired for a part edit the USER asked for, with which of the three it was. Distinct from `onPartEditApplied`,
    /// which also covers an undo / redo that moved the parts — that is the same bookkeeping problem but not a new
    /// instrumentation decision, and counting it would double every edit that gets undone.
    ///
    /// A closure rather than an analytics client on this view model: the Editor logs nothing itself, and the App
    /// composition root already owns the one `Analytics` instance.
    public var onPartsEdited: @MainActor (PartEditAction) -> Void = { _ in }
    /// Fired when the persisted `ReaderPreferences` row may have moved under the host: once per part edit as its
    /// save settles, and again from `endSession`'s retry if that is what finally lands the migration.
    ///
    /// `mapping` is the `[oldPartIndex: newPartIndex?]` map the row was rewritten through (`nil` at a key = the part
    /// is gone), or `nil` when nothing was written — the edit renumbered nothing, there was no row, or the write
    /// failed. It fires either way, because the host has to be told to let go of whatever it held even when there is
    /// nothing new to read.
    ///
    /// The row on disk is only half of the problem: the Reader holds the very same part-indexed state IN MEMORY
    /// (`LayoutSettingsModel.hiddenStaves` / `staffClefOverrides`, the mixer's strip overlays) for the length of the
    /// session, and that copy is what the next preference write persists. The App mirrors this into the Reader,
    /// which re-seeds those models from the row — the Editor cannot reach the Reader directly.
    public var onPartIndicesRemapped: @MainActor ([Int: Int?]?) -> Void = { _ in }
    /// Set when a revert failed, for the chrome to surface. Cleared at the start of each attempt.
    public internal(set) var revertError: String?
    /// Drives the revert confirmation dialog. On the view model, not view-local `@State`, so `EditorRevertButton`
    /// (cutout tier OR `EditorTopBarView`'s row) and the dialog (always on `EditorTopBarView`'s root) share it.
    public var isConfirmingRevert = false
    /// Drives the discard confirmation ✕ raises when the session has edits. Same reasoning as `isConfirmingRevert`:
    /// the button and the dialog live in different tiers, so the flag cannot be view-local.
    public var isConfirmingDiscard = false
    /// Drives the instruments sheet. On the view model for the same reason as `isConfirmingRevert`: the button that
    /// opens it folds into the overflow `Menu` at narrow widths, and a `@State` flag owned by a control that can
    /// disappear takes the open sheet with it.
    public var isInstrumentsSheetPresented = false
    /// Drives the key-signature sheet, and the time-signature one. On the view model for the same reason as
    /// `isInstrumentsSheetPresented`: the rows that raise them fold into the overflow `Menu`. OPENING either clears
    /// the last refusal — that alert belongs to the attempt that raised it, not to the next visit.
    ///
    /// `oldValue` is what makes that "opening" rather than "is open": SwiftUI writes a presentation binding whenever
    /// it re-reads it, and a redundant `true → true` write would otherwise wipe the refusal the sheet is at that
    /// moment showing.
    public var isKeySignatureSheetPresented = false {
        didSet { signatureSheetPresentationChanged(from: oldValue, to: isKeySignatureSheetPresented) }
    }

    public var isTimeSignatureSheetPresented = false {
        didSet { signatureSheetPresentationChanged(from: oldValue, to: isTimeSignatureSheetPresented) }
    }

    /// Drives the rehearsal-mark sheet. On the view model for the same reason the signature flags are: the row that
    /// raises it folds into the overflow `Menu`, and a `@State` flag owned by a control that can disappear takes the
    /// open sheet with it. No refusal to clear on open, unlike those two — the sheet has no reachable refusal (see
    /// `EditorViewModel+RehearsalMarks.swift`).
    var isRehearsalMarkSheetPresented = false

    /// Why the last signature apply was refused, or `nil` when it landed — or was the quiet no-op ssm reports as
    /// `.nothingToApply` (see `EditorViewModel+Signatures.swift`, which owns both the writes and that distinction).
    public var lastSignatureRefusal: EditRefusal?
    /// Fired after a signature change lands, as `("key"|"time", "set"|"remove")`. A closure rather than an analytics
    /// client, for the reason `onPartsEdited` gives: the Editor logs nothing itself.
    public var onSignatureChanged: ((String, String) -> Void)?
    /// Fired after a rehearsal-mark edit lands, as `"set"` or `"remove"`. A closure rather than an analytics client,
    /// for the reason `onPartsEdited` gives: the Editor logs nothing itself.
    public var onRehearsalMarkEdited: ((String) -> Void)?
    /// Whether the Reader is SHOWING this staff, and the flip for it — wired by the App to the Reader's per-score
    /// layout settings, the same store its own inspector toggles. Visibility is a reading preference, not a property
    /// of the file, and this package cannot import Reader; the defaults suit an Editor with no Reader behind it.
    public var isStaffVisible: @MainActor (StaffAddress) -> Bool = { _ in true }
    public var onToggleStaffVisibility: @MainActor (StaffAddress) -> Void = { _ in }
    /// `true` when THIS session's first save is what captured the original sidecar — i.e. before this session the
    /// score had never been edited. Discarding such a session has to take the sidecar back out, or the score would
    /// keep offering "revert to original" while being byte-identical to it.
    @ObservationIgnored var capturedOriginalThisSession = false

    @ObservationIgnored let gateway: any ScoreFileGateway
    @ObservationIgnored let repository: any ScoreLibraryRepository
    /// The score's ink, as raw payload bytes — the same face and table the Reader's `AnnotationSaveCoordinator` writes
    /// through. Read and rewritten by the part-index migration only; the Editor never otherwise touches ink.
    /// `nil` for a host with no annotation storage behind it (previews, most tests), which simply has none to migrate.
    @ObservationIgnored let annotationStore: (any AnnotationBlobStore)?
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
        annotationStore: (any AnnotationBlobStore)? = nil,
    ) {
        self.scoreItem = scoreItem
        self.scoresDirectory = scoresDirectory
        self.gateway = gateway
        self.repository = repository
        self.originalStore = originalStore
        self.historyStore = historyStore
        self.playback = playback
        self.annotationStore = annotationStore
        hasCapturedOriginal = scoreItem.canRevertToOriginal
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
        mutationTicket += 1
        appliedEditCount += 1
        sessionEditDepth += 1
        rederiveSelection()
        onScoreChanged(session.score)
        isDirty = true
        scheduleAutosave()
        return true
    }
}

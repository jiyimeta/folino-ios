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
    public internal(set) var generation = 0

    /// Bumped ONLY by a successful apply — never by `undo()`/`redo()`. Distinct from `generation` (which bumps on all
    /// three) because `EditorChromeView`'s system-undo bridge must re-register its `UndoManager` trampoline only on a
    /// genuinely NEW edit; re-registering after undo/redo would double up with `registerSystemUndo`'s own symmetric
    /// re-registration and drift the system stack from the session's real depth.
    public internal(set) var appliedEditCount = 0

    /// This adapter's copy of `core.selectionRevision`. Not public: nothing outside the module reads it, and it
    /// exists only so `syncFromCore` can tell "the selection was placed again" from "the selection happens to be
    /// equal". Internal rather than private because the mirror that writes it lives in its own file, and Swift's
    /// `private` does not span files — the same reason the mirrored counters above are `internal(set)`.
    var selectionRevision = 0

    public var isSessionActive: Bool {
        _ = generation
        return core.isSessionActive
    }

    // Selection and caret, both rendered by the Reader through the seam — the selection as a tint on the item, the
    // caret as an insertion bar in front of a slot.
    public internal(set) var selection: ScoreSelection = .none
    public internal(set) var selectedItem: SheetMusicCore.ScoreItemID?
    public internal(set) var caretItem: SheetMusicCore.ScoreItemID?

    /// Whether the pad has anything at all to act on. With neither a caret nor a selection there is no slot to write
    /// into and no item to edit, so every key is inert.
    public var hasEditTarget: Bool {
        caretItem != nil || selectedItem != nil
    }

    /// Whether the SELECTION names a notehead — the shape ⌫ / ♯ / ♭ need.
    public var isNoteSelected: Bool {
        if case .note = selectedItem {
            true
        } else {
            false
        }
    }

    /// Whether the floating callout has anything to stand beside.
    public var hasSelectionCallout: Bool {
        EditorSessionCore.slot(of: selectedItem) != nil
    }

    public internal(set) var armedDuration: NoteDuration?
    public internal(set) var armedDots = 0
    public internal(set) var isAddToChordArmed = false
    public internal(set) var armedTuplet = 3

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
    public internal(set) var didSaveAsSiblingMSCZ = false

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

    /// Fired once a revert has restored the file and the row, so the host can re-read the score it now names.
    public var onRevertCompleted: @MainActor (ScoreItem) -> Void = { _ in }

    /// The save currently in flight, if any. A revert awaits it before touching the file: cancelling `autosaveTask`
    /// does not reach a call already past `performSave()`'s entry guard.
    @ObservationIgnored var inFlightSaveTask: Task<Void, Never>?

    /// What the most recent `migratePartIndexedState` actually wrote, or `nil` when it wrote nothing. Read once by
    /// the part op's own commit, which reports it through `onPartIndicesRemapped` and clears it — a stored relay
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

    var appliedIntents: [EditIntent] {
        core.appliedIntents
    }

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
    public internal(set) var padRevealRequests = 0

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

    /// Raised the moment a part edit lands, so the host stops reading its part-indexed state until the migration
    /// that follows has settled. A save that ran with the host's pre-migration addresses would clobber the migrated
    /// row, and the map is consumed by then, so nothing would ever retry.
    ///
    /// **Raise only.** The Editor cannot say when it is safe to lower it: the row is settled at the end of the save,
    /// but the host's own in-memory copy is not settled until it has re-read that row, and between the two it is
    /// still holding the pre-migration addresses. So the release belongs to whoever performs the re-read — see
    /// `hasUnsettledPartEdits`, which is how it asks whether a LATER part edit has since raised it again.
    public var onPartEditApplied: @MainActor () -> Void = {}
    /// Awaited once per part edit, after the hold is up and BEFORE the migration reads. The host uses it to land
    /// whatever it still has in the air — the Reader's annotation saves are debounced, so a capture registered just
    /// before the part edit can still be sitting in that debounce, and a write that lands AFTER the migration read
    /// would overwrite the migrated layer with the old numbering, with the mapping consumed and nothing left to
    /// retry. Draining here rather than at the release is what puts it on the right side of the read.
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

    /// The audio seam. The other two — the digest and the writer — belong to the core, which is what decides when a
    /// save is due; this one stays here because sounding a note needs a `Task` and an audio session.
    @ObservationIgnored let audition: (any NoteAuditioning)?
    @ObservationIgnored let repository: any ScoreLibraryRepository
    /// The score's ink, as raw payload bytes — the same face and table the Reader's `AnnotationSaveCoordinator`
    /// writes through. Read and rewritten by the part-index migration only; the Editor never otherwise touches ink.
    /// `nil` for a host with no annotation storage behind it (previews, most tests), which simply has none to
    /// migrate.
    @ObservationIgnored let annotationStore: (any AnnotationBlobStore)?

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
        annotationStore: (any AnnotationBlobStore)? = nil,
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
        self.annotationStore = annotationStore
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
}

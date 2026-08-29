import Domain
import Foundation
import SheetMusicCore

/// One editing session's whole mind: the score being edited, what is selected, what the pad has armed, and every
/// operation the keys perform — named as `EditIntent`s and applied through `ScoreEditSession`.
///
/// Platform-neutral on purpose. There is no SwiftUI here, no Observation, and no `Task`: an Apple adapter
/// (`EditorViewModel`) mirrors this into `@Observable` state, and SP3's Android bridge will project the same
/// counters through `@WireletObservable`. The three things that genuinely need a platform — sounding a note,
/// digesting a file, writing one — are the seams in `EditorSeams.swift`.
///
/// **Deliberately owns no concurrency.** The ops are synchronous and leave their side effects as requests the host
/// drains: `pendingAudition` for the preview, `isDirty` for the save. A `Task` spawned in here would have to run
/// somewhere, and on Android that somewhere is a JNI thread with no run loop to return to — the failure the plan
/// warns about, moved from a deadlock at runtime to a design that cannot express it.
///
/// Not `Sendable`, like the `ScoreEditSession` it holds: one per isolation domain.
public final class EditorSessionCore {
    // MARK: - The session

    public internal(set) var session: ScoreEditSession?

    public var score: Score? {
        session?.score
    }

    public var isSessionActive: Bool {
        session != nil
    }

    public var canUndo: Bool {
        session?.canUndo ?? false
    }

    public var canRedo: Bool {
        session?.canRedo ?? false
    }

    // MARK: - Counters the host mirrors

    /// Bumped on every applied, undone or redone intent. The Reader includes the adapter's copy in its layout task
    /// key, so a score re-lays-out after edits that don't change its structural signature.
    public internal(set) var revision = 0

    /// Bumped ONLY by a successful `apply` — never by undo or redo. Distinct from `revision` because the system-undo
    /// bridge must re-register its `UndoManager` trampoline on a genuinely NEW edit and not on a replay of one.
    public private(set) var appliedIntentCount = 0

    /// Bumped on every applied, undone or redone intent, for the life of this core, and NEVER reset.
    ///
    /// `revision` goes back to zero at `beginSession`, which makes it useless as the "did anything land while I was
    /// suspended?" sentinel `performSave` needs: a `beginSession` arriving in one of its awaits would move the
    /// counter backwards and read as a mutation. This one only ever goes up, so comparing it across a suspension
    /// answers exactly the question asked.
    public private(set) var mutationTicket = 0

    /// Bumped by every `place(selection:caret:)`, whether or not the values changed. The host needs the
    /// unconditional signal: the shipped `onSelectionChanged` fires on every placement, and a mirror that only
    /// noticed *differences* would quietly drop the repeats.
    public internal(set) var selectionRevision = 0

    // MARK: - Selection and caret

    // Two different things, coinciding only when a target is picked explicitly (tap, ← / →). The caret is where the
    // NEXT note lands; the selection is the note the editing keys act on. Writing a run of notes moves the caret on
    // after each one while the selection stays on the note just written — so ♯ / ♭ / ⌫ keep addressing what you just
    // played rather than the empty slot ahead of it.
    public internal(set) var selectedItem: SheetMusicCore.ScoreItemID?
    public internal(set) var caretItem: SheetMusicCore.ScoreItemID?

    /// Where the caret actually is: a column — `(staff, measureIndex, tick)` — rather than a slot in one voice.
    ///
    /// Stored rather than derived from `caretItem`, because a slot cannot express "beat 2 of an empty bar": that
    /// bar holds one measure rest whose only slot begins at tick 0, and deriving the column would round every
    /// mid-slot position back to its slot's start, silently undoing the step that put it there. `place` keeps the
    /// two in step for every ordinary placement; the column stepper sets this directly when it lands between
    /// onsets.
    ///
    /// `caretItem` remains what is DRAWN — the slot covering this column in the caret's own voice — which is what
    /// the seam renders and what a single-voice staff has always shown.
    public internal(set) var caretColumn: ScoreColumn?

    /// Whether the pad has anything at all to act on. With neither a caret nor a selection there is no slot to write
    /// into and no item to edit, so every key is inert (there is nothing for one to mean).
    public var hasEditTarget: Bool {
        caretItem != nil || selectedItem != nil
    }

    /// Whether the SELECTION names a notehead — the shape ⌫ / ♯ / ♭ need. False for a rest, a tuplet bracket, or an
    /// empty selection, which is what gates those three keys: with the caret running ahead of the selection, "there
    /// is a caret" no longer implies "there is a note to sharpen".
    public var isNoteSelected: Bool {
        if case .note = selectedItem {
            true
        } else {
            false
        }
    }

    /// Whether the floating callout has anything to stand beside. The card is pinned to one timed slot and edits
    /// THAT slot's length, which a rest has exactly as a note does — so it shows for both, and only drops the pitch
    /// steps and the tie key on a rest. A tuplet bracket names no slot, and neither does an empty selection.
    public var hasSelectionCallout: Bool {
        Self.slot(of: selectedItem) != nil
    }

    // MARK: - Arming state

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

    /// The drum pad's keys, in order. Seeded by the host from what it persisted (the layout is global, not
    /// per-score) and read back through `resolvedDrumPadLayout`, which takes each key's engraving from the open
    /// score's own kit.
    public var drumPadLayout = DrumPadLayout.default

    /// Mirrored in from the host's transport. Editing and playback coexist — you can hear the passage you're writing
    /// without leaving edit mode — but the pad's keys go inert while the cursor runs: applying an edit mid-playback
    /// reflows the score out from under the cursor, and the preview would fight the playing engine for the same
    /// notes.
    ///
    /// Starting playback also drops the selection. The transport seeks to the selected note before it starts, and
    /// from that moment the playhead — not the selection — is where the music is; leaving a stale highlight on the
    /// note you started from just competes with it.
    public var isPlaybackActive = false {
        didSet {
            guard isPlaybackActive, isPlaybackActive != oldValue else { return }
            select(nil)
        }
    }

    // MARK: - What this session started from, and how far it has moved

    /// The score as it stood when this session opened — the baseline `discardSessionEdits()` unwinds back to, and
    /// what `isAtSessionOpenScore` compares against. Not the FILE's contents: a session adopted from the history
    /// store opens on a score that already carries the previous session's edits, and discarding must return to that,
    /// not to disk.
    public internal(set) var sessionOpenScore: Score?

    /// Applied minus undone since the session opened. Zero means "back where we started" as far as the command stack
    /// is concerned — but not on its own proof of it, since an adopted session can be at depth 0 on a different
    /// score; `sessionHasEdits` checks both.
    public internal(set) var sessionEditDepth = 0

    /// Set once `discardSessionEdits()` has run, so `endSession()` does not then deposit the session it just undid
    /// into the history store and offer it back on the next open.
    public internal(set) var didDiscardSession = false

    /// True from the moment a revert starts until it finishes. `performSave` refuses while it is set — twice, once
    /// on entry and once after its only suspension point — so an autosave already in flight cannot write the edited
    /// score back over the original the revert just restored.
    public internal(set) var isReverting = false

    /// Whether the row currently records an original to revert to.
    public internal(set) var hasCapturedOriginal: Bool

    /// Whether it was THIS session that first put a sidecar there. `discardSessionEdits()` has to take it back out
    /// again, or a score whose only edits were just thrown away would go on offering to revert to an original it is
    /// already identical to.
    public internal(set) var capturedOriginalThisSession = false

    // MARK: - Side effects the host performs

    /// The note the last op decided should be previewed, or `nil` when it decided nothing should. The host takes it,
    /// clears it, and sounds it through `NoteAuditioning` — the decision is the core's, the audio session is not.
    public internal(set) var pendingAudition: NoteID?

    /// Whether the score has changed since the last successful save. The host debounces on this; `performSave()` is
    /// a no-op while it is false, so a stray flush after a save costs nothing.
    public internal(set) var isDirty = false

    /// True once a non-MSCX/MSCZ source has been rewritten as a sibling `.mscz` file. One-way: never reset, since it
    /// drives the host's one-time "saved as .mscz" notice.
    public internal(set) var didSaveAsSiblingMSCZ = false

    /// The intents applied since the host last drained them, in the order they landed.
    ///
    /// Android only, and off unless asked for. An Android host is authoritative for the score and must replay every
    /// landed intent into the mirror session behind ssm's score handle; iOS has no mirror and never drains, so
    /// recording unconditionally would grow this array for the life of a session. Refused intents are absent by
    /// construction — `apply` records only on the success path — which is the property the relay depends on: a
    /// refusal that reached the mirror would diverge the two copies.
    ///
    /// Undo and redo are deliberately NOT recorded. The mirror keeps its own stacks (it was fed identical intents),
    /// so they relay as `nativeEditUndo` / `nativeEditRedo`, not as replayed edits.
    private var relayIntents: [EditIntent] = []

    /// Whether this core records what it applies. Set once at construction by the Android bridge.
    private let recordsRelayIntents: Bool

    /// Takes the pending preview, leaving none behind.
    public func takePendingAudition() -> NoteID? {
        defer { pendingAudition = nil }
        return pendingAudition
    }

    /// Takes the intents applied since the last call, leaving none behind. The Android bridge calls this after every
    /// op and hands the frames to Kotlin to relay; see `EditorBridge.sync()`.
    public func takeRelayIntents() -> [EditIntent] {
        defer { relayIntents.removeAll() }
        return relayIntents
    }

    /// Marks the score as saved. Called by `performSave` once the write and the row refresh have both landed.
    func markSaved() {
        isDirty = false
    }

    #if DEBUG
    /// Every intent `apply` was ASKED to land, refusals included — the construction tests assert on what the ops
    /// built, which is a different question from what the engine accepted.
    public private(set) var appliedIntents: [EditIntent] = []

    /// Marks the score dirty without editing it, so a test can drive the save path from a known state.
    public func markDirtyForTesting() {
        isDirty = true
    }

    /// Forgets the score this session opened on, so a test can reach `unwindSessionEdits`' rebuild-refusal branch.
    public func forgetSessionOpenScoreForTesting() {
        sessionOpenScore = nil
    }
    #endif

    // MARK: - Dependencies

    @usableFromInline let fileFacts: any FileFactsProviding
    @usableFromInline let writer: any ScoreFileWriting

    /// Captures and restores the pre-edit copy of the file. Optional: Android has no originals store yet, and a
    /// `nil` one simply means every save skips the capture and nothing is revertable.
    @usableFromInline let originals: (any ScoreOriginalStore)?

    /// The library row this session is editing. `internal(set)` so the persistence extension can replace it after a
    /// save refreshes it, readable so a host can show what it now says.
    public internal(set) var scoreItem: ScoreItem
    let scoresDirectory: URL

    public init(
        scoreItem: ScoreItem,
        scoresDirectory: URL,
        fileFacts: any FileFactsProviding,
        writer: any ScoreFileWriting,
        originals: (any ScoreOriginalStore)? = nil,
        recordsRelayIntents: Bool = false,
    ) {
        self.scoreItem = scoreItem
        self.scoresDirectory = scoresDirectory
        self.fileFacts = fileFacts
        self.writer = writer
        self.originals = originals
        self.recordsRelayIntents = recordsRelayIntents
        hasCapturedOriginal = scoreItem.canRevertToOriginal
    }

    // MARK: - Lifecycle

    /// Opens a session over `score` — or resumes `adopting`, a session a host kept from a previous entry.
    ///
    /// The store that keeps those sessions is the HOST's, not this type's: `ScoreEditHistoryStore` is `@MainActor`
    /// (its `ScoreEditSession` is deliberately non-`Sendable`), and this core also runs on a JNI thread. So the host
    /// does the lookup and hands the answer in. Passing `nil` — always, on Android — simply opens a fresh session.
    ///
    /// The adopted score is returned so the host can publish it: a resumed session opens on the score the previous
    /// one LEFT, which is not the `score` the caller just parsed off disk.
    @discardableResult
    public func beginSession(score: Score, adopting adopted: ScoreEditSession? = nil) -> Score? {
        session = adopted ?? ScoreEditSession(score: score)
        sessionOpenScore = session?.score
        sessionEditDepth = 0
        didDiscardSession = false
        capturedOriginalThisSession = false
        revision = 0
        appliedIntentCount = 0
        selectionRevision = 0
        selectedItem = nil
        caretItem = nil
        armedDuration = nil
        armedDots = 0
        isAddToChordArmed = false
        pendingAudition = nil
        relayIntents.removeAll()
        return adopted?.score
    }

    /// Tears the session down. The host flushes any pending save FIRST — the debounce is its timer, not this type's.
    ///
    /// The host reads `shouldRetain(_:)` first if it keeps a history store; this only tears down.
    public func endSession() {
        session = nil
        sessionOpenScore = nil
    }

    /// Tears down, but only while `ending` is still the live session.
    ///
    /// Ending a session flushes a save first, and that is a real file write the user does not wait for: they can be
    /// back in edit mode, on a NEW session, before `endSession` resumes. Tearing down unconditionally at that point
    /// would close the editor they are looking at.
    public func endSession(ifStillOn ending: ScoreEditSession) {
        guard session === ending else { return }
        endSession()
    }

    /// Whether `ending` is worth depositing for a later entry.
    ///
    /// Something on its stacks, so reopening the same unchanged file can undo across the gap — but not while the
    /// score is still dirty (its edits are not yet on disk, so the content hash it would be keyed on is about to
    /// change), and not one that was just discarded.
    public func shouldRetain(_ ending: ScoreEditSession) -> Bool {
        !didDiscardSession && !isDirty && (ending.canUndo || ending.canRedo)
    }

    public func undo() {
        // The `guard`'s second clause carries the contract a `do { try … } catch { return }` used to: a refused undo
        // must not bump a revision or move the selection.
        guard let session, session.undo() else { return }
        sessionEditDepth -= 1
        revision += 1
        mutationTicket += 1
        rederiveSelection()
        isDirty = true
    }

    public func redo() {
        guard let session, session.redo() else { return }
        sessionEditDepth += 1
        revision += 1
        mutationTicket += 1
        rederiveSelection()
        isDirty = true
    }

    /// Central apply choke point: every edit goes through here, so selection re-derivation, the revision bump and the
    /// dirty flag can never be skipped.
    ///
    /// Returns the intent when it landed and `nil` when the session refused it. The return value is what an Android
    /// host relays to the mirror session behind ssm's score handle (SP3) — a refused intent must not be relayed, or
    /// the two copies diverge. On iOS nothing reads it, and a refusal stays silent: the engine leaves the score
    /// untouched by contract, and v1 shows no error.
    @discardableResult
    public func apply(_ intent: EditIntent) -> EditIntent? {
        #if DEBUG
        appliedIntents.append(intent)
        #endif
        guard let session, session.apply(intent) else { return nil }
        revision += 1
        mutationTicket += 1
        appliedIntentCount += 1
        sessionEditDepth += 1
        if recordsRelayIntents {
            relayIntents.append(intent)
        }
        rederiveSelection()
        isDirty = true
        return intent
    }
}

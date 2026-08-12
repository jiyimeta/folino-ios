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

    public private(set) var session: ScoreEditSession?

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
    public private(set) var revision = 0

    /// Bumped ONLY by a successful `apply` — never by undo or redo. Distinct from `revision` because the system-undo
    /// bridge must re-register its `UndoManager` trampoline on a genuinely NEW edit and not on a replay of one.
    public private(set) var appliedIntentCount = 0

    /// Bumped by every `place(selection:caret:)`, whether or not the values changed. The host needs the
    /// unconditional signal: the shipped `onSelectionChanged` fires on every placement, and a mirror that only
    /// noticed *differences* would quietly drop the repeats.
    public private(set) var selectionRevision = 0

    // MARK: - Selection and caret

    // Two different things, coinciding only when a target is picked explicitly (tap, ← / →). The caret is where the
    // NEXT note lands; the selection is the note the editing keys act on. Writing a run of notes moves the caret on
    // after each one while the selection stays on the note just written — so ♯ / ♭ / ⌫ keep addressing what you just
    // played rather than the empty slot ahead of it.
    public private(set) var selectedItem: SheetMusicCore.ScoreItemID?
    public private(set) var caretItem: SheetMusicCore.ScoreItemID?

    /// Whether the pad has anything at all to act on. With neither a caret nor a selection there is no slot to write
    /// into and no item to edit, so every key is inert (there is nothing for one to mean).
    public var hasEditTarget: Bool {
        caretItem != nil || selectedItem != nil
    }

    /// Whether the SELECTION names a notehead — the shape ⌫ / ♯ / ♭ need. False for a rest, a tuplet bracket, or an
    /// empty selection, which is what gates those three keys: with the caret running ahead of the selection, "there
    /// is a caret" no longer implies "there is a note to sharpen".
    public var isNoteSelected: Bool {
        if case .note = selectedItem { true } else { false }
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

    // MARK: - Side effects the host performs

    /// The note the last op decided should be previewed, or `nil` when it decided nothing should. The host takes it,
    /// clears it, and sounds it through `NoteAuditioning` — the decision is the core's, the audio session is not.
    public private(set) var pendingAudition: NoteID?

    /// Whether the score has changed since the last successful save. The host debounces on this; `performSave()` is
    /// a no-op while it is false, so a stray flush after a save costs nothing.
    public private(set) var isDirty = false

    /// True once a non-MSCX/MSCZ source has been rewritten as a sibling `.mscz` file. One-way: never reset, since it
    /// drives the host's one-time "saved as .mscz" notice.
    public internal(set) var didSaveAsSiblingMSCZ = false

    /// Takes the pending preview, leaving none behind.
    public func takePendingAudition() -> NoteID? {
        defer { pendingAudition = nil }
        return pendingAudition
    }

    /// Marks the score as saved. Called by `performSave` once the write and the row refresh have both landed.
    func markSaved() {
        isDirty = false
    }

    // MARK: - Dependencies

    @usableFromInline let fileFacts: any FileFactsProviding
    @usableFromInline let writer: any ScoreFileWriting
    /// The library row this session is editing. `internal(set)` so the persistence extension can replace it after a
    /// save refreshes it, readable so a host can show what it now says.
    public internal(set) var scoreItem: ScoreItem
    let scoresDirectory: URL

    public init(
        scoreItem: ScoreItem,
        scoresDirectory: URL,
        fileFacts: any FileFactsProviding,
        writer: any ScoreFileWriting,
    ) {
        self.scoreItem = scoreItem
        self.scoresDirectory = scoresDirectory
        self.fileFacts = fileFacts
        self.writer = writer
    }

    // MARK: - Lifecycle

    public func beginSession(score: Score) {
        session = ScoreEditSession(score: score)
        revision = 0
        appliedIntentCount = 0
        selectionRevision = 0
        selectedItem = nil
        caretItem = nil
        armedDuration = nil
        armedDots = 0
        isAddToChordArmed = false
        pendingAudition = nil
    }

    /// Tears the session down. The host flushes any pending save FIRST — the debounce is its timer, not this type's.
    public func endSession() {
        session = nil
    }

    public func undo() {
        // The `guard`'s second clause carries the contract a `do { try … } catch { return }` used to: a refused undo
        // must not bump a revision or move the selection.
        guard let session, session.undo() else { return }
        revision += 1
        rederiveSelection()
        isDirty = true
    }

    public func redo() {
        guard let session, session.redo() else { return }
        revision += 1
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
        guard let session, session.apply(intent) else { return nil }
        revision += 1
        appliedIntentCount += 1
        rederiveSelection()
        isDirty = true
        return intent
    }

    // MARK: - Selection re-derivation

    /// Re-derives the selection and the caret from the engine's post-mutation `lastAffectedLocation`. Engine IDs are
    /// positional, so a stored selection can drift after any mutation — after every apply/undo/redo both are
    /// recomputed against the current score. When no slot was touched (`lastAffectedLocation == nil`) they are
    /// preserved rather than cleared.
    ///
    /// Which of the two followed the intent depends on which one it was aimed at. The keys are split between them
    /// (duration / tuplet write at the caret, ⌫ / ♯ / ♭ / tie edit the selection), so re-deriving both from the
    /// affected slot would collapse the lead the caret holds during a run of input: a duration key would drag the
    /// selection off the note just written, and ♯ would drag the caret back onto it, making the next letter overwrite
    /// what was just sharpened. Whichever one wasn't aimed at keeps its own slot; when the two already share a slot —
    /// the ordinary case, and every case before the first note of a run — both follow.
    private func rederiveSelection() {
        guard let session, let location = session.lastAffectedLocation else { return }
        let score = session.score
        let affected = SelectionRederivation.item(
            at: location, in: score, preferringNoteIndex: previousNoteIndex(at: location),
        )
        let selectionSlot = Self.slot(of: selectedItem)
        let caretSlot = Self.slot(of: caretItem)
        if caretSlot == location, selectionSlot != location {
            place(selection: rederived(selectionSlot, in: score) ?? affected, caret: affected)
        } else if selectionSlot == location, caretSlot != location {
            place(selection: affected, caret: rederived(caretSlot, in: score) ?? affected)
        } else {
            select(affected)
        }
    }

    /// Re-resolves a slot the intent did NOT target against the mutated score. `nil` when the slot was spliced away
    /// (the caller then falls back to the affected location, so neither marker is left dangling).
    private func rederived(_ slot: VoiceElementID?, in score: Score) -> SheetMusicCore.ScoreItemID? {
        guard let slot else { return nil }
        return SelectionRederivation.item(at: slot, in: score, preferringNoteIndex: nil)
    }

    /// The voice slot an item occupies. Tuplet brackets (and clefs, which never reach the selection) don't name a
    /// single slot, so they resolve to `nil`.
    public static func slot(of item: SheetMusicCore.ScoreItemID?) -> VoiceElementID? {
        switch item {
        case let .note(id): VoiceElementID(id)
        case let .rest(id): VoiceElementID(id)
        case .tuplet, .clef, .none: nil
        }
    }

    /// The `noteIndexInChord` of the current selection when it is a `.note` anchored at exactly `location`, so
    /// re-derivation can keep the caret on the same chord tone across edits that add or remove siblings.
    private func previousNoteIndex(at location: VoiceElementID) -> Int? {
        guard case let .note(noteID)? = selectedItem,
              noteID.staff == location.staff,
              noteID.measureIndex == location.measureIndex,
              noteID.voiceIndex == location.voiceIndex,
              noteID.elementIndex == location.elementIndex
        else { return nil }
        return noteID.noteIndexInChord
    }

    /// Picks `item` explicitly — caret and selection land together. Every path that names a target directly (tap,
    /// ← / →, post-intent re-derivation) goes through here; only note input deliberately splits the two, via
    /// `place(selection:caret:)`.
    public func select(_ item: SheetMusicCore.ScoreItemID?) {
        place(selection: item, caret: item)
    }

    /// Sets selection and caret independently. The only caller that passes different values is note input, which
    /// leaves the selection on the note it just wrote and moves the caret to the next slot.
    func place(selection item: SheetMusicCore.ScoreItemID?, caret: SheetMusicCore.ScoreItemID?) {
        selectedItem = item
        caretItem = caret
        armFromSelectionIfNeeded()
        selectionRevision += 1
    }

    /// Arms the length keys from whatever was just picked, but ONLY while nothing is armed yet — which in practice
    /// means the first note or rest touched in a session. A pad that opens with no length lit has no answer to "what
    /// will the next note be", and making the first pick supply it beats making the user state it twice; after that
    /// the armed length is the user's own choice and selecting other notes must not quietly overwrite it.
    private func armFromSelectionIfNeeded() {
        guard armedDuration == nil, let score, let slot = Self.slot(of: selectedItem),
              case let .chord(chord)? = score[slot]
        else { return }
        // `.fraction` durations carry their dots (and any tuplet scaling) baked in; split them back into the base
        // value a key can light plus the dot count the dot key can light.
        let split = DurationInterpretation.split(chord.duration)
        armedDuration = split.base
        armedDots = split.dots
    }

    // MARK: - Auditioning (the decision, not the sound)

    /// Marks `noteID` as the note to preview. `EditorViewModel` sounds it; on Android the bridge does.
    public func audition(_ noteID: NoteID) {
        guard session != nil else { return }
        pendingAudition = noteID
    }

    /// Call-site helper for the pitch-changing ops: previews the current `.note` selection, but only when the last
    /// `apply` actually mutated the score (`revision` advanced past `previousRevision`). A refused edit — an
    /// out-of-range shift, say — leaves nothing to sound.
    func auditionSelectedNote(unlessStillAt previousRevision: Int) {
        guard revision != previousRevision, case let .note(noteID)? = selectedItem else { return }
        audition(noteID)
    }
}

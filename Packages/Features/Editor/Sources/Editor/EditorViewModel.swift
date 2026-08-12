import Domain
import EditorCore
import Foundation
import Observation
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI

/// Owns the engine's `ScoreEditSession` for one editing session: names the intents each key means, manages
/// selection / voice / arming state, re-derives selection after every mutation, and drives autosave. Created once
/// per Reader screen by the App composition root; `beginSession(score:)` / `endSession()` bracket each entry into
/// edit mode.
///
/// The keys name *intents*, not commands. Everything between an op and the engine — cross-bar interception, the
/// `.measure` promotion for a bar-filling rest, the full-measure-rest collapse, the accidental renotation pass — is
/// `ScoreEditSession.apply`'s job, and both platforms plan the same commands from the same scalars. That is what
/// stops iOS and Android from drifting: there is one planner, not two.
@MainActor
@Observable
public final class EditorViewModel {
    public private(set) var session: ScoreEditSession?
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

    /// Bumped ONLY by `apply(_:)`'s success path — never by `undo()`/`redo()`. Distinct from `generation` (which
    /// bumps on all three) because `EditorChromeView`'s system-undo bridge must re-register its `UndoManager`
    /// trampoline only on a genuinely NEW edit; re-registering after undo/redo would double up with
    /// `registerSystemUndo`'s own symmetric re-registration and drift the system stack from the session's real
    /// depth (Task 16 review fix).
    public private(set) var appliedEditCount = 0
    public var isSessionActive: Bool {
        session != nil
    }

    // Selection and caret (both rendered by the Reader through the seam — the selection as a tint on the item, the
    // caret as an insertion bar in front of a slot).
    //
    // They are two different things and only coincide when you pick a target explicitly (tap, ← / →). The caret is
    // where the NEXT note lands; the selection is the note the editing keys act on. Writing a run of notes moves the
    // caret on after each one while the selection stays on the note just written — so ♯ / ♭ / ⌫ keep addressing what
    // you just played rather than the empty slot ahead of it.
    public private(set) var selection: ScoreSelection = .none
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
    /// steps and the tie key on a rest (see `EditorCalloutView`). A tuplet bracket names no slot, and neither does
    /// an empty selection.
    public var hasSelectionCallout: Bool {
        Self.slot(of: selectedItem) != nil
    }

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

    // The three seams the editing logic reaches its platform through (`EditorCore/EditorSeams.swift`). The
    // initializer still takes the gateway / repository / controller the App composition root has, and narrows them
    // here — the App is not this refactor's business, and the adapters are three lines each.
    @ObservationIgnored let audition: (any NoteAuditioning)?
    @ObservationIgnored let fileFacts: any FileFactsProviding
    @ObservationIgnored let writer: any ScoreFileWriting
    /// Internal (not private) so `EditorViewModel+Persistence.swift` can replace it after a save refreshes the row.
    @ObservationIgnored var scoreItem: ScoreItem
    @ObservationIgnored let scoresDirectory: URL

    public init(
        scoreItem: ScoreItem,
        scoresDirectory: URL,
        gateway: any ScoreFileGateway,
        repository: any ScoreLibraryRepository,
        playback: (any PlaybackController)?,
    ) {
        self.scoreItem = scoreItem
        self.scoresDirectory = scoresDirectory
        audition = playback.map(PlaybackAudition.init(controller:))
        fileFacts = EditorFileFacts()
        writer = GatewayScoreWriter(gateway: gateway, repository: repository)
    }

    public func beginSession(score: Score) {
        session = ScoreEditSession(score: score)
        generation = 0
        appliedEditCount = 0
        selection = .none
        selectedItem = nil
        caretItem = nil
        armedDuration = nil
        armedDots = 0
        isAddToChordArmed = false
    }

    /// Flushes any pending autosave (Task 10) and tears the session down.
    public func endSession() async {
        await flushPendingSave()
        session = nil
    }

    public func undo() {
        // The `guard`'s second clause carries the same contract the old `do { try … } catch { return }` did: a
        // refused undo must not fire a generation bump, `onSelectionChanged` or `onScoreChanged`.
        guard let session, session.undo() else { return }
        generation += 1
        rederiveSelection()
        onScoreChanged(session.score)
        isDirty = true
        scheduleAutosave()
    }

    public func redo() {
        guard let session, session.redo() else { return }
        generation += 1
        rederiveSelection()
        onScoreChanged(session.score)
        isDirty = true
        scheduleAutosave()
    }

    /// Bridges the session's own stacks to the system UndoManager so three-finger swipe gestures work. Each mutation
    /// registers one undo action; performing it re-registers the redo symmetrically. The session remains the
    /// source of truth — the UndoManager holds only trampolines.
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

    /// Central apply choke point: every edit goes through here, so selection re-derivation, the generation bump,
    /// `onScoreChanged` and autosave scheduling can never be skipped. Internal — the ops extensions call it.
    ///
    /// Returns the intent when it landed and `nil` when the session refused it. The return value is what an Android
    /// host relays to the mirror session behind ssm's score handle (SP3) — a refused intent must not be relayed, or
    /// the two copies diverge. On iOS nothing reads it, and a refusal stays silent: the engine leaves the score
    /// untouched by contract, and v1 shows no error.
    ///
    /// The accidental renotation pass that used to hang here is `ScoreEditSession.apply`'s job now, from the same
    /// `MeasureAccidentals` this used to call.
    @discardableResult
    func apply(_ intent: EditIntent) -> EditIntent? {
        guard let session, session.apply(intent) else { return nil }
        generation += 1
        appliedEditCount += 1
        rederiveSelection()
        onScoreChanged(session.score)
        isDirty = true
        scheduleAutosave()
        return intent
    }

    /// Re-derives the selection and the caret from the engine's post-mutation `lastAffectedLocation`. Engine IDs are
    /// positional, so a stored selection can drift after any mutation — after every apply/undo/redo both are
    /// recomputed against the current score. When no slot was touched (`lastAffectedLocation == nil`) they are
    /// preserved rather than cleared.
    ///
    /// Which of the two followed the command depends on which one it was aimed at. The keys are split between them
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

    /// Re-resolves a slot that the command did NOT target against the mutated score. `nil` when the slot was spliced
    /// away (the caller then falls back to the affected location, so neither marker is left dangling).
    private func rederived(_ slot: VoiceElementID?, in score: Score) -> SheetMusicCore.ScoreItemID? {
        guard let slot else { return nil }
        return SelectionRederivation.item(at: slot, in: score, preferringNoteIndex: nil)
    }

    /// The voice slot an item occupies. Tuplet brackets (and clefs, which never reach the selection) don't name a
    /// single slot, so they resolve to `nil`.
    static func slot(of item: SheetMusicCore.ScoreItemID?) -> VoiceElementID? {
        switch item {
        case let .note(id): VoiceElementID(id)
        case let .rest(id): VoiceElementID(id)
        case .tuplet, .clef, .none: nil
        }
    }

    /// The `noteIndexInChord` of the current selection when it is a `.note` anchored at exactly `location`,
    /// so re-derivation can keep the caret on the same chord tone across edits that add/remove siblings.
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
    /// ← / →, post-command re-derivation) goes through here; only note input deliberately splits the two, via
    /// `place(selection:caret:)`. Internal (not private) so the ops extensions in sibling files can drive selection.
    func select(_ item: SheetMusicCore.ScoreItemID?) {
        place(selection: item, caret: item)
    }

    /// Sets selection and caret independently and notifies. The only caller that passes different values is note
    /// input, which leaves the selection on the note it just wrote and moves the caret to the next slot.
    func place(selection item: SheetMusicCore.ScoreItemID?, caret: SheetMusicCore.ScoreItemID?) {
        selection = item.map(ScoreSelection.single) ?? .none
        selectedItem = item
        caretItem = caret
        armFromSelectionIfNeeded()
        onSelectionChanged(selection, caret)
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
}

import Domain
import Foundation
import Observation
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI

/// Owns the engine `ScoreEditor` for one editing session: applies commands, manages selection / voice / arming
/// state, re-derives selection after every mutation, and drives autosave. Created once per Reader screen by the App
/// composition root; `beginSession(score:)` / `endSession()` bracket each entry into edit mode.
@MainActor
@Observable
public final class EditorViewModel {
    public private(set) var editor: ScoreEditor?
    /// The editor's live score, or nil outside a session. Views and the Reader seam render THIS score while editing.
    public var score: Score? {
        editor?.score
    }

    /// Bumped on every applied / undone / redone command. The Reader includes it in its layout task key so the
    /// score re-lays-out after edits that don't change the structural score signature.
    public private(set) var generation = 0
    public var isSessionActive: Bool {
        editor != nil
    }

    // Selection (rendered by the Reader through the seam).
    public private(set) var selection: ScoreSelection = .none
    public private(set) var selectedItem: SheetMusicCore.ScoreItemID?

    // Arming state (Tasks 5/7). internal(set), not private(set): the ops live in same-type extensions in OTHER
    // files (`EditorViewModel+Input.swift` etc.), and Swift's `private` does not span files.
    public internal(set) var armedDuration: NoteDuration?
    public internal(set) var isAddToChordArmed = false
    public var activeVoice = 0

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

    public var canUndo: Bool {
        editor?.canUndo ?? false
    }

    public var canRedo: Bool {
        editor?.canRedo ?? false
    }

    /// Wired by the App composition root.
    /// Returns the Reader's current LayoutDocument for hit-testing (Task 8).
    public var documentProvider: @MainActor () -> LayoutDocument? = { nil }
    /// Fired after every score mutation with the fresh score (App mirrors it into the Reader seam).
    public var onScoreChanged: @MainActor (Score) -> Void = { _ in }
    /// Fired whenever selection changes (App mirrors it into the Reader seam).
    public var onSelectionChanged: @MainActor (ScoreSelection, SheetMusicCore.ScoreItemID?) -> Void = { _, _ in }

    @ObservationIgnored let gateway: any ScoreFileGateway
    @ObservationIgnored let repository: any ScoreLibraryRepository
    @ObservationIgnored let playback: (any PlaybackController)?
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
        self.gateway = gateway
        self.repository = repository
        self.playback = playback
    }

    public func beginSession(score: Score) {
        editor = ScoreEditor(score: score)
        generation = 0
        selection = .none
        selectedItem = nil
        armedDuration = nil
        isAddToChordArmed = false
    }

    /// Flushes any pending autosave (Task 10) and tears the session down.
    public func endSession() async {
        await flushPendingSave()
        editor = nil
    }

    public func undo() {
        guard let editor, editor.canUndo else { return }
        // Mirror applyCommand's do/catch contract: a swallowed engine failure must not fire a false
        // generation bump / onSelectionChanged / onScoreChanged (Task 3 review parity fix).
        do { try editor.undo() } catch { return }
        generation += 1
        rederiveSelection()
        onScoreChanged(editor.score)
        isDirty = true
        scheduleAutosave()
    }

    public func redo() {
        guard let editor, editor.canRedo else { return }
        do { try editor.redo() } catch { return }
        generation += 1
        rederiveSelection()
        onScoreChanged(editor.score)
        isDirty = true
        scheduleAutosave()
    }

    /// Bridges ScoreEditor's own stacks to the system UndoManager so three-finger swipe gestures work. Each mutation
    /// registers one undo action; performing it re-registers the redo symmetrically. The ScoreEditor remains the
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

    /// Central apply choke point: every command goes through here so selection re-derivation, generation bump,
    /// onScoreChanged, and autosave scheduling can never be skipped. Internal — ops extensions call it.
    func applyCommand(_ command: any EditCommand) {
        guard let editor else { return }
        do {
            try editor.apply(command)
        } catch SheetMusicError.invalidEdit {
            // A refused edit leaves the score untouched by the engine's contract — no user-facing error in v1.
            return
        } catch {
            return
        }
        generation += 1
        rederiveSelection()
        onScoreChanged(editor.score)
        isDirty = true
        scheduleAutosave()
    }

    /// Re-derives the selection from the engine's post-mutation `lastAffectedLocation`. Engine IDs are
    /// positional, so a stored selection can drift after any mutation — after every apply/undo/redo the
    /// selection is recomputed against the current score. When no slot was touched
    /// (`lastAffectedLocation == nil`) the current selection is preserved rather than cleared.
    private func rederiveSelection() {
        guard let editor, let location = editor.lastAffectedLocation else { return }
        select(
            SelectionRederivation.item(
                at: location,
                in: editor.score,
                preferringNoteIndex: previousNoteIndex(at: location),
            ),
        )
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

    /// Sets `selection` / `selectedItem` and notifies. Internal (not private) so Tasks 5-10's ops
    /// extensions in sibling files can drive selection directly (e.g. after a hit-test tap).
    func select(_ item: SheetMusicCore.ScoreItemID?) {
        selection = item.map(ScoreSelection.single) ?? .none
        selectedItem = item
        onSelectionChanged(selection, selectedItem)
    }
}

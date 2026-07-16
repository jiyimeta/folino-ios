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

    // Stored autosave / audition state — declared HERE (extensions cannot add stored properties); used by
    // Tasks 9/10: `@ObservationIgnored var autosaveTask: Task<Void, Never>?`,
    // `@ObservationIgnored var auditionTask: Task<Void, Never>?`, `@ObservationIgnored var isDirty = false`,
    // and `public internal(set) var didSaveAsSiblingMSCZ = false`.

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

    // swiftlint:disable async_without_await
    /// Flushes any pending autosave (Task 10) and tears the session down.
    public func endSession() async {
        editor = nil
    }

    // swiftlint:enable async_without_await

    public func undo() {
        guard let editor, editor.canUndo else { return }
        try? editor.undo()
        generation += 1
        selection = .none
        onScoreChanged(editor.score)
    }

    public func redo() {
        guard let editor, editor.canRedo else { return }
        try? editor.redo()
        generation += 1
        selection = .none
        onScoreChanged(editor.score)
    }

    /// Central apply choke point: every command goes through here so selection re-derivation, generation bump,
    /// onScoreChanged, and (Task 10) autosave scheduling can never be skipped. Internal — ops extensions call it.
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
        selection = .none
        onScoreChanged(editor.score)
    }
}

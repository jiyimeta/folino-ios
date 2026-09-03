import Domain
import Foundation
import SheetMusicCore

/// Throwing away a session's edits, and going back to the file as it was imported.
///
/// Two different undos with two different scopes, which is why both live here rather than in a host: "discard" walks
/// this session's own command stack back to where it opened, while "revert" replaces the file with the copy the
/// originals store kept. Everything below is the decision and the state change; the `Task` that awaits an in-flight
/// save, the confirmation sheet and the error string all stay with the host, which has a run loop and a screen.
extension EditorSessionCore {
    // MARK: - What this session has actually changed

    /// Whether this session has moved the score away from where it opened.
    ///
    /// Two questions, because neither answers it alone: the command stack can be back at depth 0 while the score
    /// differs (an adopted session opens mid-stack), and the score can compare equal while the stack is not (an edit
    /// and its inverse). Either one being "moved" counts as edited.
    public var sessionHasEdits: Bool {
        guard isSessionActive else { return false }
        if sessionEditDepth != 0 {
            return true
        }
        return !isAtSessionOpenScore
    }

    /// Whether the score currently equals the one this session opened on.
    public var isAtSessionOpenScore: Bool {
        guard let session, let sessionOpenScore else { return false }
        return session.score == sessionOpenScore
    }

    /// What leaving the session should offer to do — the three-way answer a host's end-of-session buttons render.
    public var sessionEndMode: EditorSessionEndMode {
        if sessionHasEdits {
            return .commitEdited
        }
        if hasCapturedOriginal {
            return .revert
        }
        return .commitUnchanged
    }

    // MARK: - Discarding this session's own edits

    /// Walks the command stack back to where the session opened, and rebuilds the session outright if that does not
    /// land exactly there.
    ///
    /// The rebuild is not belt-and-braces: an adopted session's stack reaches back past this session's start, so
    /// undoing `sessionEditDepth` steps is only correct while every one of them belongs to this session. If the
    /// count and the score disagree afterwards, the score is what the user means by "as I found it".
    ///
    /// Returns the part-index mapping the host still owes its part-indexed state, or `nil` when nothing moved. The
    /// rebuild throws this session away and its part-id baseline with it, and a mapping still standing at that moment
    /// is the row's ONLY route back: the score jumps to the session-open parts while the row sits in whatever
    /// numbering the last consume left it in, and the replacement session baselines on the post-jump parts — so it
    /// would read identity forever and nothing would ever reconcile them. Reachable whenever a part edit was saved
    /// and then discarded.
    ///
    /// The destination is the SNAPSHOT's parts, not the session's current ones. The session's own map ends wherever
    /// this session happens to have left the score, and the gear only runs when that is NOT the snapshot — so
    /// migrating with it alone would land the row in an intermediate numbering that no file ever has. Composing it
    /// with "where the current parts sit in the snapshot" puts the row into the numbering the restored score has. A
    /// part this session removed and the snapshot still carries is dropped rather than restored: its id is gone from
    /// the current score, so nothing here can name it.
    ///
    /// Performing the migration is the host's — it reads and rewrites stores this core cannot see.
    @discardableResult
    public func unwindSessionEdits() -> [Int: Int?]? {
        guard let session else { return nil }
        while sessionEditDepth > 0, session.undo() {
            sessionEditDepth -= 1
        }
        while sessionEditDepth < 0, session.redo() {
            sessionEditDepth += 1
        }
        var owedMapping: [Int: Int?]?
        if let sessionOpenScore, sessionEditDepth != 0 || session.score != sessionOpenScore {
            let restore = Self.partIndexMapping(from: session.score, to: sessionOpenScore)
            let mapping = Self.composing(session.partIndexMapping, restore)
            owedMapping = mapping.allSatisfy { $0.value == $0.key } ? nil : mapping
            self.session = ScoreEditSession(score: sessionOpenScore)
            sessionEditDepth = 0
            // The rebuilt session carries no stack at all, so whatever the adopted one brought went with it.
            sessionOpenUndoStepCount = 0
        }
        revision += 1
        rederiveSelection()
        return owedMapping
    }

    /// Where each of `from`'s parts sits in `to`, by `Part.id`; `nil` = `to` does not have it. The same shape
    /// `ScoreEditSession.partIndexMapping` produces, computed between two scores the caller holds rather than
    /// against the session's own baseline.
    ///
    /// Duplicate ids on either side yield the identity map, for the reason `ScoreEditSession` documents: a
    /// `firstIndex(of:)` answer over duplicates is a plausible-looking lie, and moving one part's preferences onto
    /// another is worse than not migrating.
    public static func partIndexMapping(from: Score, to: Score) -> [Int: Int?] {
        let source = from.parts.map(\.id)
        let destination = to.parts.map(\.id)
        guard Set(source).count == source.count, Set(destination).count == destination.count else {
            return Dictionary(uniqueKeysWithValues: source.indices.map { ($0, Optional($0)) })
        }
        return Dictionary(
            uniqueKeysWithValues: source.enumerated().map { ($0.offset, destination.firstIndex(of: $0.element)) },
        )
    }

    /// `first` followed by `second`, as one map. A key `first` sends to `nil` stays `nil`; so does one whose
    /// destination `second` does not know about.
    public static func composing(_ first: [Int: Int?], _ second: [Int: Int?]) -> [Int: Int?] {
        first.mapValues { intermediate -> Int? in
            // Two unwraps, two different questions: did `first` keep this part, and does `second` know where the
            // index it landed on goes. Written as one `guard` because a `?? nil` reads as redundant and SwiftLint
            // strips it.
            guard let intermediate, let destination = second[intermediate] else { return nil }
            return destination
        }
    }

    /// Marks the session discarded, so `sessionToRetain` stops offering it: a retained stack that reaches back
    /// through edits the user has just thrown away is not something to hand them again. Dropping what a host's
    /// history store already holds for this row is the host's half — see `beginSession(score:adopting:)`.
    public func markSessionDiscarded() {
        didDiscardSession = true
    }

    /// Re-dirties the score so the host's flush writes the unwound version over the edited file. Called only once
    /// `unwindSessionEdits()` has confirmed it landed back at the opening score.
    public func markDirtyForDiscardFlush() {
        isDirty = true
    }

    /// Takes back the original this session captured, once its edits have been thrown away. Returns the row to
    /// persist, or `nil` when there is nothing to take back.
    public func discardOriginalCapturedThisSession(
        isolation: isolated (any Actor)? = #isolation,
    ) async -> ScoreItem? {
        guard capturedOriginalThisSession, let originals else { return nil }
        guard let cleared = try? await originals.discardOriginal(for: scoreItem) else { return nil }
        scoreItem = cleared
        hasCapturedOriginal = false
        capturedOriginalThisSession = false
        return cleared
    }

    #if DEBUG
    /// Puts the session at depth 1 so a preview can render the "you have edits" branch without applying one.
    public func seedSessionEditDepthForPreview() {
        sessionEditDepth = 1
    }
    #endif

    // MARK: - Reverting to the imported original

    /// Adopts an original that is on disk but missing from the row. Returns the row to persist, or `nil` when there
    /// was nothing to adopt.
    ///
    /// A capture is three steps — copy the sidecar, write the score, update the row — and only the first two are on
    /// the path that must complete. Kill the app in between and the edit survives while the row forgets its
    /// original, with the sidecar sitting right there and nothing looking for it. Reconciling when a session opens
    /// closes that window.
    public func reconcileCapturedOriginal(isolation: isolated (any Actor)? = #isolation) async -> ScoreItem? {
        guard !hasCapturedOriginal, !isReverting, let originals else { return nil }
        let adopted = await originals.adoptOrphanedOriginal(for: scoreItem)
        guard adopted.canRevertToOriginal else { return nil }
        scoreItem = adopted
        hasCapturedOriginal = true
        return adopted
    }

    /// Latches the revert before anything is awaited, so a save that starts while the host is still joining the one
    /// already in flight refuses at `performSave`'s entry guard instead of racing the store's file swap.
    public func beginReverting() {
        isReverting = true
    }

    /// Restores the file from its original and tears the session down. Returns the row to persist.
    ///
    /// Throws whatever the store threw, leaving `isReverting` cleared so the host can resume autosaving: a revert
    /// that could not write is a revert that did not happen, and the session it was called on is still live.
    ///
    /// A host that keeps a history store must invalidate this row's entry itself — the session this replaces is
    /// addressed to a score that no longer exists.
    public func revertToOriginal(isolation: isolated (any Actor)? = #isolation) async throws -> ScoreItem {
        guard let originals else { throw EditorRevertUnavailable() }
        isReverting = true
        let reverted: ScoreItem
        do {
            reverted = try await originals.revertToOriginal(scoreItem, restoringScoreInfo: false)
        } catch {
            isReverting = false
            throw error
        }
        scoreItem = reverted
        hasCapturedOriginal = false
        isDirty = false
        isReverting = false
        // The session's stacks are addressed to notes in the score that was just replaced, so it goes with it.
        session = nil
        sessionOpenScore = nil
        sessionEditDepth = 0
        sessionOpenUndoStepCount = 0
        select(nil)
        revision += 1
        return reverted
    }
}

/// What leaving an editing session should offer to do.
public enum EditorSessionEndMode: Sendable {
    /// Nothing was changed and there is no original to go back to — just leave.
    case commitUnchanged
    /// Nothing was changed in THIS session, but an earlier one left an original to revert to.
    case revert
    /// This session changed the score; leaving keeps those edits.
    case commitEdited
}

/// Thrown by `revertToOriginal()` on a core built without an originals store — Android, today.
public struct EditorRevertUnavailable: Error, Sendable {
    public init() {}
}

import Domain
import Editor
import Foundation

/// The live editors of this process, keyed by score. Bookkeeping, not a shared-editor scheme: with one window per
/// score (design §3) there is never more than one entry per id. It exists for two things — `MacAppDelegate`'s
/// quit-time flush, which has to find every open editor, and the register / unregister pair that keeps a window
/// closed and reopened from racing its predecessor's `endSession`.
@MainActor
final class MacEditorRegistry {
    /// The process's one registry. Production code must go through this — a fresh `MacEditorRegistry()` exists only
    /// so tests can exercise `register` / `unregister` / `flushAll` against an empty, isolated instance.
    static let shared = MacEditorRegistry()

    private var byScore: [ScoreItem.ID: EditorViewModel] = [:]

    var editors: [EditorViewModel] {
        Array(byScore.values)
    }

    func register(_ editor: EditorViewModel, for id: ScoreItem.ID) {
        byScore[id] = editor
    }

    func unregister(for id: ScoreItem.ID) {
        byScore[id] = nil
    }

    /// Flushes every editor's pending autosave, bounded: a flush that never returns must not hang quit (design §9).
    ///
    /// This is a race, not a cancel-and-await: `EditorViewModel.flushPendingSave()` is not cooperatively
    /// cancellable (its body runs straight through to the write with no cancellation check), so cancelling the
    /// flush task and awaiting it would still block on whatever `await` it happens to be suspended on — exactly the
    /// hang the timeout exists to prevent. `raceAgainstTimeout` below is what actually returns early: a flush that
    /// outlives `timeout` keeps running after `flushAll` returns, and the process may then exit mid-write if quit
    /// proceeds; that is the accepted trade against a hung quit (design §9).
    ///
    /// `byScore.values` has no defined order, so "flush every editor" is what this does — not "flush them in a
    /// particular order".
    func flushAll(timeout: Duration) async {
        let editors = editors
        guard !editors.isEmpty else { return }
        await Self.raceAgainstTimeout(timeout) {
            for editor in editors {
                await editor.flushPendingSave()
            }
        }
    }
}

extension MacEditorRegistry {
    /// Runs `operation` and returns when it finishes OR when `timeout` elapses, whichever is first. A losing
    /// operation is NOT cancelled and keeps running after this returns (it cannot be — see `flushAll`).
    ///
    /// **Why not `withTaskGroup`.** A task group implicitly awaits every child before `withTaskGroup` returns, even
    /// after `cancelAll()` — so if the timer wins, cancelling the flush child only marks it cancelled, and this
    /// function would still block until that non-cancellable flush finishes on its own. That defeats the entire
    /// point of the timeout: quit would hang in exactly the branch this exists to bound. Two unstructured `Task`s
    /// racing to resume one continuation have no such join — whichever calls `gate.resume()` first is the one that
    /// unblocks the caller, and the other keeps running to completion on its own, unobserved.
    static func raceAgainstTimeout(_ timeout: Duration, operation: @escaping @MainActor () async -> Void) async {
        let gate = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.arm(continuation)
            Task { @MainActor in
                await operation()
                gate.resume()
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                gate.resume()
            }
        }
    }
}

/// Resumes a continuation at most once. `@MainActor` so the two racing tasks cannot resume concurrently.
@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<Void, Never>?

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

import Domain
import Editor
import Foundation

/// The live editors of this process, keyed by score. Bookkeeping, not a shared-editor scheme: with one window per
/// score (design §3) there is never more than one entry per id. It exists for two things — `MacAppDelegate`'s
/// quit-time flush, which has to find every open editor, and the register / unregister pair that keeps a window
/// closed and reopened from racing its predecessor's `endSession`.
@MainActor
final class MacEditorRegistry {
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
    /// hang the timeout exists to prevent. Instead, two child tasks race: one runs every editor's flush in order,
    /// the other just sleeps for `timeout`. Whichever finishes first wins `group.next()`, and `cancelAll()` then
    /// cancels the loser — which stops the timer if the flushes won, but does nothing to a flush already in flight
    /// if the timer won. A flush that outlives the timeout keeps running in the background after this function
    /// returns, and the process may exit mid-write if quit proceeds; that is the accepted trade against a hung
    /// quit (design §9).
    func flushAll(timeout: Duration) async {
        let editors = editors
        guard !editors.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await Self.flushEachInOrder(editors)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            // First child to finish wins: the flush completing, or the timer expiring. The loser is cancelled
            // (a flush ignores cancellation and simply keeps writing in the background; a timer stops).
            await group.next()
            group.cancelAll()
        }
    }

    /// Factored out of `flushAll`'s task-group closure: a `for` loop over a captured `[EditorViewModel]` written
    /// directly inside that closure trips a Swift 6 compiler limitation ("pattern that the region-based isolation
    /// checker does not understand how to check") — moving the loop into its own `@MainActor` function avoids it.
    @MainActor
    private static func flushEachInOrder(_ editors: [EditorViewModel]) async {
        for editor in editors {
            await editor.flushPendingSave()
        }
    }
}

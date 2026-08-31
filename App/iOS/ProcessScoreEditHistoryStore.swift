import Domain
import Foundation
import UIKit

/// Retains each score's `ScoreEditSession` across Editor entries, for the process lifetime — the undo history a
/// session carries survives ✓-and-reopen. Memory-only by design; killing the app drops every history.
///
/// LRU-bounded at three deposited sessions because a retained session holds a full in-memory `Score` copy — the
/// spec budgets ~7 MB for the worst score we ship, so three slots is ≈ 21 MB worst case and typically well under
/// 1.5 MB. The open session is checked out (see the protocol) and never counts against the cap.
///
/// An `NSObject` subclass only for the selector-based notification observation below, which keeps the memory-
/// warning sweep synchronous and testable (posting on an injected center runs the handler inline).
@MainActor
final class ProcessScoreEditHistoryStore: NSObject, ScoreEditHistoryStore {
    private struct Entry {
        let id: ScoreItemID
        let contentHash: String
        let session: ScoreEditSession
    }

    /// Most-recently deposited last.
    private var entries: [Entry] = []
    private let capacity: Int

    init(capacity: Int = 3, notificationCenter: NotificationCenter = .default) {
        self.capacity = capacity
        super.init()
        // Memory pressure empties the store: the deposited sessions are a convenience cache, and "bounded until
        // jetsam disagrees" is not bounded. Same contract as a kill; the checked-out session is unaffected — the
        // store does not own it.
        //
        // This observer is never removed. That is correct only because this store is process-lifetime composition
        // state (one instance, created once in `AppBootstrap`, alive until the app dies) — a future refactor that
        // gives it a shorter lifetime must add `removeObserver` explicitly rather than inherit this omission.
        notificationCenter.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
        )
    }

    func session(for id: ScoreItemID, contentHash: String) -> ScoreEditSession? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = entries.remove(at: index)
        // A hash mismatch means the file was rewritten out-of-band since the deposit (revert, re-import, version
        // restore, PDF re-read): the history no longer relates to the bytes on disk, so the stale entry is dropped
        // rather than left to mislead a later asker.
        guard entry.contentHash == contentHash else { return nil }
        return entry.session
    }

    func retain(_ session: ScoreEditSession, for id: ScoreItemID, contentHash: String) {
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, contentHash: contentHash, session: session))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func invalidate(_ id: ScoreItemID) {
        entries.removeAll { $0.id == id }
    }

    /// UIKit posts this on the main thread, so the `@MainActor` isolation holds dynamically.
    @objc private func handleMemoryWarning() {
        entries.removeAll()
    }
}

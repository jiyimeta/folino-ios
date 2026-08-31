import Domain
import Foundation

// PARITY(macos): memory-pressure eviction — the iOS store empties itself on
//   `UIApplication.didReceiveMemoryWarningNotification`; this Mac counterpart has no equivalent trigger yet. A
//   `DispatchSource.makeMemoryPressureSource` listener would restore parity if the Mac Editor's process footprint
//   ever needs the same defense; until then the LRU cap alone bounds the store.

/// Retains each score's `ScoreEditSession` across Editor entries, for the process lifetime — the undo history a
/// session carries survives ✓-and-reopen. Memory-only by design; quitting the app drops every history.
///
/// LRU-bounded at three deposited sessions, mirroring the iOS `ProcessScoreEditHistoryStore` in `App/iOS` — see that
/// file for the sizing rationale. The open session is checked out (see the protocol) and never counts against the
/// cap.
@MainActor
final class ProcessScoreEditHistoryStore: ScoreEditHistoryStore {
    private struct Entry {
        let id: ScoreItemID
        let contentHash: String
        let session: ScoreEditSession
    }

    /// Most-recently deposited last.
    private var entries: [Entry] = []
    private let capacity: Int

    init(capacity: Int = 3) {
        self.capacity = capacity
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
}

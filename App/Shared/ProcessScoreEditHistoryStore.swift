import Domain
import Foundation
#if os(iOS)
import UIKit
#endif

/// Retains each score's `ScoreEditSession` across Editor entries, for the process lifetime — the undo history a
/// session carries survives ✓-and-reopen. Memory-only by design; killing (or quitting) the app drops every history.
///
/// LRU-bounded at three deposited sessions because a retained session holds a full in-memory `Score` copy — the
/// spec budgets ~7 MB for the worst score we ship, so three slots is ≈ 21 MB worst case and typically well under
/// 1.5 MB. The open session is checked out (see the protocol) and never counts against the cap.
///
/// This logic is shared across platforms rather than paired: the LRU cache, the hash-mismatch-drop rule, and the
/// protocol conformance are one piece of cross-session-undo semantics a user can observe on either platform, and
/// duplicating them risked drift. The one genuine platform difference — iOS empties the store on a memory-pressure
/// notification, macOS has no such trigger yet — is small enough to live behind the `#if os(iOS)` in `init` below.
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

    // PARITY(macos): memory-pressure eviction — iOS empties this store on
    //   `UIApplication.didReceiveMemoryWarningNotification`; macOS has no equivalent trigger yet. A
    //   `DispatchSource.makeMemoryPressureSource` listener would restore parity if the Mac Editor's process
    //   footprint ever needs the same defense; until then the LRU cap alone bounds the store there.
    init(capacity: Int = 3, notificationCenter: NotificationCenter = .default) {
        self.capacity = capacity
        #if os(iOS)
        // This observer is never removed. That is correct only because this store is process-lifetime composition
        // state (one instance, created once in `AppBootstrap`, alive until the app dies) — a future refactor that
        // gives it a shorter lifetime must add `removeObserver` explicitly rather than inherit this omission.
        // Block-based registration (rather than an `NSObject` + `@objc` selector target) keeps this type free of
        // any UIKit-only base class, so the rest of the file — and the macOS build — stay unaffected.
        notificationCenter.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil,
        ) { [weak self] _ in
            // UIKit posts this on the main thread, so the `@MainActor` isolation holds dynamically.
            self?.entries.removeAll()
        }
        #endif
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

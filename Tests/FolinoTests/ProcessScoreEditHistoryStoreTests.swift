import Domain
@testable import folino
import Foundation
import Testing
import UIKit

/// The process-lifetime session store: an LRU of three deposited sessions, checkout-on-read, hash-guarded, and
/// swept empty on a memory warning. Sessions are compared by identity — the store retains and returns the same
/// object, never a copy.
@MainActor
struct ProcessScoreEditHistoryStoreTests {
    private func makeSession() -> ScoreEditSession {
        ScoreEditSession(score: Score(division: 480, parts: []))
    }

    @Test func `a deposited session is checked out exactly once`() {
        let store = ProcessScoreEditHistoryStore()
        let id = ScoreItemID()
        let session = makeSession()
        store.retain(session, for: id, contentHash: "h")
        #expect(store.session(for: id, contentHash: "h") === session)
        // Checked out: a second concurrent asker (iPad split-view double-open) finds nothing.
        #expect(store.session(for: id, contentHash: "h") == nil)
    }

    @Test func `a contentHash mismatch drops the stale entry and returns nil`() {
        let store = ProcessScoreEditHistoryStore()
        let id = ScoreItemID()
        store.retain(makeSession(), for: id, contentHash: "deposited")
        #expect(store.session(for: id, contentHash: "different") == nil)
        // The stale entry is gone, not waiting to mislead a later asker with the old hash.
        #expect(store.session(for: id, contentHash: "deposited") == nil)
    }

    @Test func `a fourth deposit evicts the least-recently-used entry`() {
        let store = ProcessScoreEditHistoryStore()
        let ids = (0 ..< 4).map { _ in ScoreItemID() }
        let sessions = (0 ..< 4).map { _ in makeSession() }
        for index in 0 ..< 4 {
            store.retain(sessions[index], for: ids[index], contentHash: "h")
        }
        #expect(store.session(for: ids[0], contentHash: "h") == nil) // evicted
        #expect(store.session(for: ids[1], contentHash: "h") === sessions[1])
        #expect(store.session(for: ids[2], contentHash: "h") === sessions[2])
        #expect(store.session(for: ids[3], contentHash: "h") === sessions[3])
    }

    @Test func `re-depositing a score refreshes its recency and replaces its entry`() {
        let store = ProcessScoreEditHistoryStore()
        let ids = (0 ..< 4).map { _ in ScoreItemID() }
        let first = makeSession()
        let replacement = makeSession()
        store.retain(first, for: ids[0], contentHash: "h")
        store.retain(makeSession(), for: ids[1], contentHash: "h")
        store.retain(makeSession(), for: ids[2], contentHash: "h")
        // Re-deposit id 0: it becomes most-recent and holds ONE slot, not two.
        store.retain(replacement, for: ids[0], contentHash: "h2")
        store.retain(makeSession(), for: ids[3], contentHash: "h")
        // ids[1] was the least-recent at the fourth deposit — it went, id 0 stayed, under its new hash.
        #expect(store.session(for: ids[1], contentHash: "h") == nil)
        #expect(store.session(for: ids[0], contentHash: "h2") === replacement)
    }

    @Test func `invalidate empties the entry`() {
        let store = ProcessScoreEditHistoryStore()
        let id = ScoreItemID()
        store.retain(makeSession(), for: id, contentHash: "h")
        store.invalidate(id)
        #expect(store.session(for: id, contentHash: "h") == nil)
    }

    @Test func `a memory warning empties the store`() {
        let center = NotificationCenter()
        let store = ProcessScoreEditHistoryStore(notificationCenter: center)
        let id = ScoreItemID()
        store.retain(makeSession(), for: id, contentHash: "h")
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #expect(store.session(for: id, contentHash: "h") == nil)
    }
}

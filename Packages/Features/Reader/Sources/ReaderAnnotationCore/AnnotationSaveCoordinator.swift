import Domain
import Foundation

/// The single shared annotation save policy both platforms drive: assemble a layer from the current drawings, coalesce
/// rapid edits with a debounce, delete instead of storing an empty layer, and flush immediately at score-swap /
/// teardown. iOS's `ReaderViewModel` and Android's `@WireletObservable` bridge each own one over their platform's
/// `AnnotationBlobStore`, so the cadence + assembly + payload codec live in exactly one place — no mirrored Kotlin or
/// second Swift copy. Text boxes are always empty in v1 (musical-only annotations); the layer body still records the
/// field for forward compatibility.
///
/// Concurrency: an `actor`, so `pending` / `saveTask` are race-free regardless of the calling thread. `persist` clears
/// `pending` before its first `await`, so a debounce firing and a concurrent `flush` never double-write. Callers
/// deliver `drawingsDidChange` in order (both platforms call from their UI event source); out-of-order delivery is
/// benign — the debounce coalesces and the next change / `flush` reconciles.
public actor AnnotationSaveCoordinator {
    private let store: any AnnotationBlobStore
    private let debounce: Duration
    private let now: @Sendable () -> Date
    private var pending: (scoreID: ScoreItemID, drawings: [DrawingAnchor])?
    private var saveTask: Task<Void, Never>?

    public init(
        store: any AnnotationBlobStore,
        debounce: Duration = .milliseconds(500),
        now: @Sendable @escaping () -> Date = { Date() },
    ) {
        self.store = store
        self.debounce = debounce
        self.now = now
    }

    /// The currently stored drawings for a score (empty on miss / undecodable payload). Called when a score opens.
    public func load(scoreID: ScoreItemID) async -> [DrawingAnchor] {
        guard let data = try? await store.load(scoreID: scoreID),
              let decoded = AnnotationLayerCodec.decode(data)
        else { return [] }
        return decoded.drawings
    }

    /// Record a change and (re)arm the debounce. The most recent call within one debounce window wins.
    public func drawingsDidChange(_ drawings: [DrawingAnchor], scoreID: ScoreItemID) {
        pending = (scoreID, drawings)
        saveTask?.cancel()
        let delay = debounce
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await self?.persist()
        }
    }

    /// Write any pending change immediately (score-swap / teardown), bypassing the debounce.
    public func flush() async {
        saveTask?.cancel()
        saveTask = nil
        await persist()
    }

    private func persist() async {
        guard let (scoreID, drawings) = pending else { return }
        pending = nil
        do {
            if drawings.isEmpty {
                try await store.delete(scoreID: scoreID)
            } else {
                let payload = AnnotationLayerCodec.encode(drawings: drawings, textBoxes: [])
                try await store.save(scoreID: scoreID, updatedAt: now(), payload: payload)
            }
        } catch {
            // Best-effort persistence, matching iOS's `try?` policy: a failed save is retried on the next change /
            // flush and never surfaced to the drawing UI.
        }
    }
}

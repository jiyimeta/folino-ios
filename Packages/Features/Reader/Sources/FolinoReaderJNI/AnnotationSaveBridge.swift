import Domain
import Foundation
import Observation
import WireletObservable

/// Android-side annotation save bridge, mirroring how iOS's `ReaderViewModel` drives the shared save policy. It owns
/// one `Domain.AnnotationSaveCoordinator` (the single cross-platform debounce + assembly + empty→delete policy) over a
/// Room blob store injected from Kotlin (`AnnotationPersistenceStore` via `@WireletProvided`). No cadence or codec is
/// reimplemented here — the coordinator is the only place that logic lives, so Android and iOS persist identically.
///
/// Write-only in v1 (Sub-plan D): Kotlin pushes drawing changes / open / flush down; there is no observable `state`
/// StateFlow because nothing is projected back to Compose yet. Sub-plan E adds the read path (rehydrating stored
/// drawings on open). The `@WireletObservable` bridges emitter is happy with zero observable properties — it emits
/// the constructor and the `@WireletExpose` invoke bridges.
@WireletObservable
@Observable
public final class AnnotationSaveBridge {
    @ObservationIgnored private let coordinator: AnnotationSaveCoordinator
    @ObservationIgnored private var scoreId = ""

    public init(store: AnnotationPersistenceStore) {
        coordinator = AnnotationSaveCoordinator(store: WireletBackedBlobStore(provided: store))
    }

    // MARK: - Open / lifecycle

    /// Marks `scoreId` as the active score. Primes the coordinator's load path for the score (the loaded drawings are
    /// not projected to Compose in D — Sub-plan E wires that read path). Fire-and-forget: the coordinator is an actor,
    /// so the sync `@WireletExpose` boundary can't await it.
    @WireletExpose
    public func open(scoreId: String) {
        self.scoreId = scoreId
        let coordinator = coordinator
        let id = ScoreItemID(rawValue: UUID(uuidString: scoreId) ?? UUID())
        Task { _ = await coordinator.load(scoreID: id) }
    }

    // MARK: - Drawing changes (Kotlin -> Swift)

    /// Records the current annotation layer's drawings and (re)arms the coordinator's debounce. Rebuilds each neutral
    /// `DrawingAnchor` from its wire fields, the same `MusicalAnchor` mapping `nativeAnnotationDisplayTransforms` uses.
    /// Fire-and-forget for the same actor reason as `open`; the debounce coalesces rapid calls.
    @WireletExpose
    public func drawingsChanged(_ wires: [DrawingAnchorWire]) {
        let drawings = wires.map { wire -> DrawingAnchor in
            let anchor = MusicalAnchor(
                measureIndex: Int(wire.measureIndex),
                tickInMeasure: Int(wire.tickInMeasure),
                partIndex: Int(wire.partIndex),
                staffIndexInPart: Int(wire.staffIndexInPart),
                dxSp: wire.dxSp,
                verticalOffsetSp: wire.verticalOffsetSp,
            )
            return DrawingAnchor(kind: .musical(anchor), encodedDrawing: wire.encodedDrawing)
        }
        let coordinator = coordinator
        let id = ScoreItemID(rawValue: UUID(uuidString: scoreId) ?? UUID())
        Task { await coordinator.drawingsDidChange(drawings, scoreID: id) }
    }

    // MARK: - Flush (Kotlin -> Swift)

    /// Requests an immediate write of any pending change, bypassing the debounce (score-swap / teardown).
    ///
    /// KNOWN v1 LIMITATION — fire-and-forget: the coordinator is an `actor`, and a synchronous `@WireletExpose` cannot
    /// await, so the spawned `Task` may still be running when this returns. The debounced save covers normal editing;
    /// Kotlin should call `flush()` early (e.g. in `onPause`, before teardown) so the `Task` has time to complete
    /// before the process/Activity is torn down. Making this awaitable is deferred until the wirelet boundary grows a
    /// suspending-call shape.
    @WireletExpose
    public func flush() {
        let coordinator = coordinator
        Task { await coordinator.flush() }
    }
}

/// Adapts the synchronous Kotlin-backed `AnnotationPersistenceStore` (`@WireletProvided`) to the async
/// `Domain.AnnotationBlobStore` the coordinator writes through. Blob I/O only — no policy. Empty `Data` from Kotlin
/// means "no layer stored", which the coordinator treats as `nil`.
///
/// `@unchecked Sendable`: `AnnotationBlobStore` refines `Sendable`, but the wrapped `@WireletProvided` proxy (a thin
/// JNI forwarder) is not intrinsically `Sendable`. It is safe to pass across concurrency domains because the only
/// holder is `AnnotationSaveCoordinator`, an `actor`, which serializes every call into the store.
private struct WireletBackedBlobStore: AnnotationBlobStore, @unchecked Sendable {
    let provided: AnnotationPersistenceStore

    func load(scoreID: ScoreItemID) throws -> Data? {
        let bytes = provided.loadBytes(scoreId: scoreID.rawValue.uuidString)
        return bytes.isEmpty ? nil : bytes
    }

    func save(scoreID: ScoreItemID, updatedAt: Date, payload: Data) throws {
        provided.saveBytes(
            scoreId: scoreID.rawValue.uuidString,
            updatedAtMillis: Int64(updatedAt.timeIntervalSince1970 * 1000),
            bytes: payload,
        )
    }

    func delete(scoreID: ScoreItemID) throws {
        provided.delete(scoreId: scoreID.rawValue.uuidString)
    }
}

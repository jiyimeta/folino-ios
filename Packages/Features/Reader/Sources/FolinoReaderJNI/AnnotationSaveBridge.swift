import Dispatch
import Domain
import Foundation
import Observation
import ReaderAnnotationCore
import WireletObservable

/// Android-side annotation save bridge, mirroring how iOS's `ReaderViewModel` drives the shared save policy. It owns
/// one `Domain.AnnotationSaveCoordinator` (the single cross-platform debounce + assembly + empty→delete policy) over a
/// Room blob store injected from Kotlin (`AnnotationPersistenceStore` via `@WireletProvided`). No cadence or codec is
/// reimplemented here — the coordinator is the only place that logic lives, so Android and iOS persist identically.
///
/// Write-only in v1 (Sub-plan D): Kotlin pushes drawing changes / open / flush down. Sub-plan E adds the read path —
/// `loadedDrawings` is an observable property that `@WireletObservable` projects to a Kotlin StateFlow, rehydrating
/// the dry overlay's persisted strokes when a score opens.
@WireletObservable
@Observable
public final class AnnotationSaveBridge {
    @ObservationIgnored private let coordinator: AnnotationSaveCoordinator
    @ObservationIgnored private var scoreId = ""

    /// Observable read path (Sub-plan E): drawings loaded for the active score, projected to a Kotlin StateFlow by
    /// @WireletObservable. Seeds the dry overlay on open. Written on the main actor after the async load resolves.
    /// internal(set) (not private(set)): swift-wirelet 0.3.2's ObservableSchemaParser treats every stored `var` as
    /// mutable — it ignores per-accessor access — and emits a same-module _set bridge, so private(set) fails the
    /// arm64 FolinoReaderJNI build.
    public internal(set) var loadedDrawings: [DrawingAnchorWire] = []

    public init(store: AnnotationPersistenceStore) {
        coordinator = AnnotationSaveCoordinator(store: WireletBackedBlobStore(provided: store))
    }

    // MARK: - Open / lifecycle

    /// Marks `scoreId` as the active score and rehydrates its persisted drawings into `loadedDrawings`, projected to
    /// Compose via the `@WireletObservable` StateFlow.
    ///
    /// The load runs SYNCHRONOUSLY: `loadedDrawings` is populated before `open()` returns, so the Kotlin StateFlow
    /// collector that `ReaderViewModel.onAnnotationOpened` starts immediately after this call reads the loaded value.
    ///
    /// Why not the async `Task { @MainActor in … }` shape used before: the Android JNI process pumps no main runloop,
    /// so there is NO MainActor executor. A `Task { @MainActor in … }` is created but never scheduled — its body never
    /// runs — so `coordinator.load` was never called and persisted strokes silently failed to rehydrate on reopen /
    /// relaunch (the write path was unaffected: `drawingsChanged` / `flush` use a plain `Task {}` on the global
    /// executor, which does run on Android). Bridge the `actor` coordinator to this synchronous boundary with a
    /// `DispatchSemaphore`, mirroring `LibraryAndroidStore.importShared`: the store's `load` is a synchronous Room read
    /// over JNI with no real suspension point, so the cooperative pool that runs the Task cannot starve on the blocked
    /// caller and no deadlock is possible. Kotlin invokes `open()` off the main thread, so the brief block never
    /// touches the UI thread.
    @WireletExpose
    public func open(scoreId: String) {
        self.scoreId = scoreId
        let id = ScoreItemID(rawValue: UUID(uuidString: scoreId) ?? UUID())
        let coordinator = coordinator
        let box = LoadedDrawingsBox()
        let sem = DispatchSemaphore(value: 0)
        Task {
            box.drawings = await coordinator.load(scoreID: id)
            sem.signal()
        }
        sem.wait()
        loadedDrawings = box.drawings.map(Self.wire(from:))
    }

    /// Maps a `Domain.DrawingAnchor` to its `DrawingAnchorWire` projection, `.musical` and `.page` alike, via the
    /// shared (host-tested) `AnchorKindWireCoding.wireFields(for:)` — see its doc comment for why this mapping lives
    /// in `ReaderAnnotationCore` rather than as an inline branch here.
    private static func wire(from drawing: DrawingAnchor) -> DrawingAnchorWire {
        let fields = AnchorKindWireCoding.wireFields(for: drawing.kind)
        return DrawingAnchorWire(
            measureIndex: fields.measureIndex, tickInMeasure: fields.tickInMeasure,
            partIndex: fields.partIndex, staffIndexInPart: fields.staffIndexInPart,
            dxSp: fields.dxSp, verticalOffsetSp: fields.verticalOffsetSp, encodedDrawing: drawing.encodedDrawing,
            anchorKind: fields.anchorKind, pageIndex: fields.pageIndex,
        )
    }

    // MARK: - Drawing changes (Kotlin -> Swift)

    /// Records the current annotation layer's drawings and (re)arms the coordinator's debounce. Rebuilds each neutral
    /// `DrawingAnchor` from its wire fields via `AnchorKindWireCoding.kind(_:)` — `.musical` and `.page` alike, so a
    /// PDF page anchor pushed down from Kotlin round-trips instead of being silently coerced to `.musical`.
    /// Fire-and-forget for the same actor reason as `open`; the debounce coalesces rapid calls.
    @WireletExpose
    public func drawingsChanged(_ wires: [DrawingAnchorWire]) {
        let drawings = wires.map { wire -> DrawingAnchor in
            let fields = AnchorKindWireCoding.WireFields(
                anchorKind: wire.anchorKind, pageIndex: wire.pageIndex,
                measureIndex: wire.measureIndex, tickInMeasure: wire.tickInMeasure,
                partIndex: wire.partIndex, staffIndexInPart: wire.staffIndexInPart,
                dxSp: wire.dxSp, verticalOffsetSp: wire.verticalOffsetSp,
            )
            return DrawingAnchor(kind: AnchorKindWireCoding.kind(fields), encodedDrawing: wire.encodedDrawing)
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

/// Reference box that lets the escaping load `Task` hand its result back across the `DispatchSemaphore` to the
/// synchronous `open()` caller. `@unchecked Sendable`: `drawings` is written once by the Task and read once by the
/// caller after `sem.wait()`, with the semaphore providing the happens-before edge.
private final class LoadedDrawingsBox: @unchecked Sendable {
    var drawings: [DrawingAnchor] = []
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

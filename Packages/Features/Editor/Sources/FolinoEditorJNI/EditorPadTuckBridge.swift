import EditorCore
import Foundation
import Observation
import WireletObservable

/// Android's face of `EditorPadTuckGeometry` — the thresholds and release decisions behind the note pad's
/// PiP-style side tuck, so Compose runs the same arithmetic SwiftUI does instead of a Kotlin retelling of it.
///
/// **Deliberately not a method on `EditorBridge`.** That object is confined to the single `folino-edit` executor
/// (`ConfinedEditSessionOps`) because its ops and `takeRelayFrames()` are a pair; a gesture's release decision
/// asked for there would queue behind whatever the editing thread is doing — a 200 ms save on a real device — and
/// the pad would stick to the finger after it lifted. This type holds no state at all, so Compose calls it straight
/// from the UI thread.
///
/// Kotlin calls it **twice per gesture**, not per frame: once at the start for the threshold and the tucked rest
/// offset, once at the release for the decision. Everything in between is adding a translation to a cached number,
/// which is not a decision and so is not shared.
@WireletObservable
@Observable
public final class EditorPadTuckBridge {
    public init() {}

    /// `min(width, height) * 0.2` — see `EditorPadTuckGeometry.threshold`.
    @WireletExpose
    public func tuckThreshold(viewportWidth: Double, viewportHeight: Double) -> Double {
        EditorPadTuckGeometry.threshold(viewportWidth: viewportWidth, viewportHeight: viewportHeight)
    }

    /// Where a tucked pad rests. `peek` is how much of the card stays on screen — Android's sliver; iOS passes 0 and
    /// leaves a pull tab instead.
    @WireletExpose
    public func tuckRestOffsetX(
        sideRawIndex: Int32, viewportWidth: Double, padWidth: Double, margin: Double, peek: Double,
    ) -> Double {
        EditorPadTuckGeometry.restOffsetX(
            side: EditorPadTuckSide(rawIndex: sideRawIndex),
            viewportWidth: viewportWidth,
            padWidth: padWidth,
            margin: margin,
            peek: peek,
        )
    }

    /// The release decision for an expanded pad, as `EditorPadTuckSide.rawIndex` — or **-1** for "this was a
    /// reposition, not a dismissal". A sentinel rather than a nullable return because the wire vocabulary is
    /// integers and a third state is what `nil` means here; the two real sides keep their own discriminators.
    @WireletExpose
    public func tuckDestinationRawIndex(
        translationX: Double,
        projectedTranslationX: Double,
        velocityX: Double,
        velocityY: Double,
        threshold: Double,
    ) -> Int32 {
        EditorPadTuckGeometry.tuckDestination(
            translationX: translationX,
            projectedTranslationX: projectedTranslationX,
            velocityX: velocityX,
            velocityY: velocityY,
            threshold: threshold,
        )?.rawIndex ?? -1
    }

    /// Whether releasing a tucked pad's drag brings it back out.
    @WireletExpose
    public func restoresFromTuck(
        sideRawIndex: Int32, projectedTranslationX: Double, threshold: Double,
    ) -> Bool {
        EditorPadTuckGeometry.restoresFromTuck(
            side: EditorPadTuckSide(rawIndex: sideRawIndex),
            projectedTranslationX: projectedTranslationX,
            threshold: threshold,
        )
    }
}

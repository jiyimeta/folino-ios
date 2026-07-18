import Domain
import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// An `AnchorResolving` seeded with values Kotlin already fetched from ssm's anchor-primitive JNI: the resolved
/// `MusicalAnchor` for a captured stroke, and the document-space reference point + `sp` for each anchor. It lets the
/// Android JNI path reuse `AnnotationAnchoringCore.capture` / `display` unchanged — the same code iOS runs in-process —
/// with no re-implemented math.
///
/// - `resolveAnchor(at:)` returns `resolvedAnchor` regardless of the point: on Android the stroke's representative
///   point was already resolved to this anchor by `SheetMusicJNI.nativeResolveAnchor`, so the core's re-resolution is a
///   no-op that hands back the prefetched value.
/// - `referencePoint(for:)` looks the anchor up in `referencePoints`; a missing entry (ssm's `spMm == 0` miss) yields
///   `nil`, so the core drops that stroke / skips that transform.
public struct PrefetchedAnchorResolver: AnchorResolving {
    private let resolvedAnchor: MusicalAnchor?
    private let referencePoints: [MusicalAnchor: (point: CGPoint, sp: CGFloat)]

    public init(
        resolvedAnchor: MusicalAnchor?,
        referencePoints: [MusicalAnchor: (point: CGPoint, sp: CGFloat)],
    ) {
        self.resolvedAnchor = resolvedAnchor
        self.referencePoints = referencePoints
    }

    public func resolveAnchor(at point: CGPoint) -> MusicalAnchor? {
        resolvedAnchor
    }

    public func referencePoint(for anchor: MusicalAnchor) -> (point: CGPoint, sp: CGFloat)? {
        referencePoints[anchor]
    }
}

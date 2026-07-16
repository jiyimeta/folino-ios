import CoreGraphics
import Domain
import SheetMusicLayout

/// iOS `AnchorResolving` backed by an in-process `LayoutDocument`. Bridges ssm's `ResolvedAnchor` to the Domain
/// `MusicalAnchor` (the six fields map 1:1) and forwards `anchorReferencePoint`. Android supplies a different resolver
/// (values pre-fetched from ssm's anchor-primitive JNI); the neutral `AnnotationAnchoringCore` is identical on both.
struct LayoutDocumentAnchorResolver: AnchorResolving {
    let document: LayoutDocument

    func resolveAnchor(at point: CGPoint) -> MusicalAnchor? {
        guard let r = document.resolveAnchor(at: point) else { return nil }
        return MusicalAnchor(
            measureIndex: r.measureIndex,
            tickInMeasure: r.tickInMeasure,
            partIndex: r.partIndex,
            staffIndexInPart: r.staffIndexInPart,
            dxSp: Double(r.dxSp),
            verticalOffsetSp: Double(r.verticalOffsetSp),
        )
    }

    func referencePoint(for anchor: MusicalAnchor) -> (point: CGPoint, sp: CGFloat)? {
        document.anchorReferencePoint(
            measureIndex: anchor.measureIndex,
            tickInMeasure: anchor.tickInMeasure,
            partIndex: anchor.partIndex,
            staffIndexInPart: anchor.staffIndexInPart,
        )
    }
}

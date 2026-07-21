import Domain
import Foundation
import ReaderAnnotationCore
import Wirelet

#if !canImport(CoreGraphics)
// On Android, Foundation's CoreGraphics shim also exports `CGFloat` / `CGPoint`, which clashes with
// `ReaderAnnotationCore`'s own stubs. Anchor to the core's definitions so the geometry types resolve to the ones the
// annotation core uses. iOS has real CoreGraphics and skips this block (this target is Android-only regardless).
private typealias CGFloat = ReaderAnnotationCore.CGFloat
private typealias CGPoint = ReaderAnnotationCore.CGPoint
#endif

// swift-java (jextract) entry points for Android freehand annotation. Each is a thin Data-in / Data-out marshaller:
// decode the neutral `InkStroke` / `DrawingAnchor` / ssm anchor wire bytes, call the shared `AnnotationAnchoringCore`
// (the exact math iOS runs in-process), re-encode. Kotlin plumbs ssm's raw `SheetMusicJNI` output bytes straight into
// these calls — no math in Kotlin. See `AnnotationWire.swift` for the wire contract and the parent Phase-2 plan's
// Spike-1 data flow. Empty `Data` is the miss / undecodable signal throughout.

/// The bbox-center document-millimetre point a wet stroke anchors to. Kotlin sends it to
/// `SheetMusicJNI.nativeResolveAnchor`. Empty `Data` if the stroke fails to decode.
public func nativeAnnotationRepresentativePoint(strokeBytes: Data) -> Data {
    guard let stroke = try? InkStrokeCodec.decode(strokeBytes) else { return Data() }
    let point = AnnotationAnchoringCore.representativePoint(of: stroke)
    return PointMmWire(xMm: Double(point.x), yMm: Double(point.y)).encodeToData()
}

/// Capture one wet stroke into a persistable `DrawingAnchor`. `resolvedAnchorBytes` = ssm `ResolvedAnchorWire`;
/// `refPointBytes` = ssm `AnchorRefPointWire` (document mm). Composes the anchor point `P = ref + (dxSp, voSp)·sp` and
/// normalizes the geometry to anchor-relative sp — all in the shared core, via a single-entry
/// `PrefetchedAnchorResolver`. Empty `Data` when an input doesn't decode, the reference point missed (`spMm == 0`), or
/// the core drops the stroke.
public func nativeAnnotationCapture(strokeBytes: Data, resolvedAnchorBytes: Data, refPointBytes: Data) -> Data {
    guard let stroke = try? InkStrokeCodec.decode(strokeBytes),
          let resolved = try? ResolvedAnchorWire(decoding: resolvedAnchorBytes),
          let ref = try? AnchorRefPointWire(decoding: refPointBytes),
          ref.spMm > 0
    else { return Data() }

    let anchor = MusicalAnchor(
        measureIndex: Int(resolved.measureIndex), tickInMeasure: Int(resolved.tickInMeasure),
        partIndex: Int(resolved.partIndex), staffIndexInPart: Int(resolved.staffIndexInPart),
        dxSp: resolved.dxSp, verticalOffsetSp: resolved.verticalOffsetSp,
    )
    let resolver = PrefetchedAnchorResolver(
        resolvedAnchor: anchor,
        referencePoints: [anchor: (CGPoint(x: ref.xMm, y: ref.yMm), CGFloat(ref.spMm))],
    )

    guard let drawing = AnnotationAnchoringCore.capture(strokes: [stroke], using: resolver).first else {
        return Data()
    }
    return DrawingAnchorWire(
        measureIndex: resolved.measureIndex, tickInMeasure: resolved.tickInMeasure,
        partIndex: resolved.partIndex, staffIndexInPart: resolved.staffIndexInPart,
        dxSp: resolved.dxSp, verticalOffsetSp: resolved.verticalOffsetSp,
        encodedDrawing: drawing.encodedDrawing,
    ).encodeToData()
}

/// Compute the display transform for a whole annotation layer in one call — the reflow hot path. `drawingsBytes` =
/// `[DrawingAnchorWire]` (what capture produced / Room stored); `refPointsBytes` = ssm `[AnchorRefPointWire]`,
/// positionally aligned with the drawings' anchors. Output `[StrokeTransformWire]` is positionally aligned with the
/// input; `sp == 0` marks a drawing the caller skips this frame (kept, pruned on next save). Empty `Data` if the inputs
/// don't decode or their counts differ.
public func nativeAnnotationDisplayTransforms(drawingsBytes: Data, refPointsBytes: Data) -> Data {
    guard let wires = try? [DrawingAnchorWire](decoding: drawingsBytes),
          let refs = try? [AnchorRefPointWire](decoding: refPointsBytes),
          wires.count == refs.count
    else { return Data() }

    var drawings: [DrawingAnchor] = []
    var referencePoints: [MusicalAnchor: (point: CGPoint, sp: CGFloat)] = [:]
    drawings.reserveCapacity(wires.count)
    for (wire, ref) in zip(wires, refs) {
        let anchor = MusicalAnchor(
            measureIndex: Int(wire.measureIndex), tickInMeasure: Int(wire.tickInMeasure),
            partIndex: Int(wire.partIndex), staffIndexInPart: Int(wire.staffIndexInPart),
            dxSp: wire.dxSp, verticalOffsetSp: wire.verticalOffsetSp,
        )
        drawings.append(DrawingAnchor(kind: .musical(anchor), encodedDrawing: wire.encodedDrawing))
        if ref.spMm > 0 {
            referencePoints[anchor] = (CGPoint(x: ref.xMm, y: ref.yMm), CGFloat(ref.spMm))
        }
    }

    let resolver = PrefetchedAnchorResolver(resolvedAnchor: nil, referencePoints: referencePoints)
    let transforms = AnnotationAnchoringCore.display(drawings, using: resolver)
    let out = transforms.map { transform -> StrokeTransformWire in
        guard let transform else { return StrokeTransformWire(sp: 0, px: 0, py: 0) }
        return StrokeTransformWire(sp: Double(transform.sp), px: Double(transform.px), py: Double(transform.py))
    }
    return out.encodeToData()
}

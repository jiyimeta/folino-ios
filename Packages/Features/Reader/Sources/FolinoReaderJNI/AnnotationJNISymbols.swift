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

/// Cut the eraser path out of an annotation layer — the reflow-independent partial-eraser hot path. Anchor-kind
/// agnostic: a musical AND a page anchor both decode/encode through `AnchorKindWireCoding`, and
/// `AnnotationEraseCore.erase` itself never inspects `DrawingAnchorKind` beyond carrying it through to each surviving
/// fragment unchanged (see that function's own `DrawingAnchor(kind: drawing.kind, ...)` — a fragment's kind, and for
/// a page anchor its `pageIndex`, can never migrate or degrade to a different kind by construction).
/// `drawingsBytes` = `[DrawingAnchorWire]` (the layer being erased); `transformsBytes` = `[StrokeTransformWire]`,
/// positionally aligned with the drawings (what `nativeAnnotationDisplayTransforms` /
/// `nativePdfAnnotationDisplayTransforms` returns for the same layer, so the hit test runs in the display space the
/// user actually saw); `requestBytes` = `EraseRequestWire`, the eraser's display-space polyline plus its geometric
/// radius. A `sp == 0` transform entry — an anchor that can't currently place — maps to `nil`, matching the display
/// path's "unresolved this frame" convention; that drawing passes through the erase untouched. Empty `Data` if any
/// input fails to decode or the drawings/transforms counts differ.
public func nativeAnnotationErase(drawingsBytes: Data, transformsBytes: Data, requestBytes: Data) -> Data {
    guard let drawingWires = try? [DrawingAnchorWire](decoding: drawingsBytes),
          let transformWires = try? [StrokeTransformWire](decoding: transformsBytes),
          let request = try? EraseRequestWire(decoding: requestBytes),
          drawingWires.count == transformWires.count,
          request.xMm.count == request.yMm.count
    else { return Data() }

    let drawings = drawingWires.map { wire in
        DrawingAnchor(
            kind: AnchorKindWireCoding.kind(
                anchorKind: wire.anchorKind, pageIndex: wire.pageIndex,
                measureIndex: wire.measureIndex, tickInMeasure: wire.tickInMeasure,
                partIndex: wire.partIndex, staffIndexInPart: wire.staffIndexInPart,
                dxSp: wire.dxSp, verticalOffsetSp: wire.verticalOffsetSp,
            ),
            encodedDrawing: wire.encodedDrawing,
        )
    }
    let transforms = transformWires.map { wire -> StrokeTransform? in
        guard wire.sp != 0 else { return nil }
        return StrokeTransform(sp: CGFloat(wire.sp), px: CGFloat(wire.px), py: CGFloat(wire.py))
    }
    let path = zip(request.xMm, request.yMm).map { CGPoint(x: CGFloat($0), y: CGFloat($1)) }

    let result = AnnotationEraseCore.erase(
        drawings, transforms: transforms, path: path, radiusMm: CGFloat(request.radiusMm),
    )

    let outWires = result.drawings.map { drawing -> DrawingAnchorWire in
        let fields = AnchorKindWireCoding.wireFields(for: drawing.kind)
        return DrawingAnchorWire(
            measureIndex: fields.measureIndex, tickInMeasure: fields.tickInMeasure,
            partIndex: fields.partIndex, staffIndexInPart: fields.staffIndexInPart,
            dxSp: fields.dxSp, verticalOffsetSp: fields.verticalOffsetSp,
            encodedDrawing: drawing.encodedDrawing,
            anchorKind: fields.anchorKind, pageIndex: fields.pageIndex,
        )
    }

    return EraseResultWire(
        drawings: outWires, changedIndices: result.changedIndices.map { Int32($0) },
    ).encodeToData()
}

/// Place a stored (anchor-relative sp) InkStroke into document-mm using its display transform, so the
/// caller can re-resolve an anchor for it (phase-2 erase re-anchoring). `strokeBytes` = neutral
/// InkStroke FINK; `transformBytes` = `StrokeTransformWire`. Returns document-mm FINK, empty on a decode
/// miss. A `sp == 0` transform (unresolved this layout) also returns empty — an unplaceable stroke.
public func nativeAnnotationPlace(strokeBytes: Data, transformBytes: Data) -> Data {
    guard let stroke = try? InkStrokeCodec.decode(strokeBytes),
          let t = try? StrokeTransformWire(decoding: transformBytes),
          t.sp != 0
    else { return Data() }
    let placed = AnnotationAnchoringCore.place(
        stroke, with: StrokeTransform(sp: CGFloat(t.sp), px: CGFloat(t.px), py: CGFloat(t.py)),
    )
    return InkStrokeCodec.encode(placed)
}

/// Encode a raw androidx.ink stroke (document-mm geometry) into neutral `InkStroke` FINK bytes. Kotlin builds
/// `RawInkStrokeWire` from a finished `Stroke`; this is the ONLY encode path so the codec never duplicates into Kotlin.
/// Empty `Data` if the wire fails to decode.
public func nativeEncodeInkStroke(rawBytes: Data) -> Data {
    guard let wire = try? RawInkStrokeWire(decoding: rawBytes) else { return Data() }
    return InkStrokeCodec.encode(wire.fields.toInkStroke())
}

/// Decode neutral `InkStroke` FINK bytes back to a `RawInkStrokeWire` Kotlin rebuilds a `Stroke` from. Empty `Data`
/// if the bytes don't decode.
public func nativeDecodeInkStroke(finkBytes: Data) -> Data {
    guard let stroke = try? InkStrokeCodec.decode(finkBytes) else { return Data() }
    return RawInkStrokeWire(InkStrokeRawFields(stroke)).encodeToData()
}

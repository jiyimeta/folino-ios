import Foundation
import Wirelet

// @WireFormat TLV structs for the annotation JNI boundary. Two of them — `ResolvedAnchorWire` and
// `AnchorRefPointWire` — mirror swift-sheet-music v1.1.1's `Sources/SheetMusicAndroidJNI/AnchorCodecs.swift` field for
// field: they are the byte contract between ssm's `.so` and this one. Kotlin plumbs ssm's raw `nativeResolveAnchor` /
// `nativeAnchorReferencePoint` output straight into the capture/display calls here, so this side decodes them. The
// other three are Folino's own boundary types (Kotlin decodes them via Folino-generated codecs). Field order IS the
// wire contract — do not reorder.

/// Mirrors ssm `ResolvedAnchorWire` — output of `SheetMusicJNI.nativeResolveAnchor`. Its six fields map 1:1 to
/// `Domain.MusicalAnchor`. `dxSp` / `verticalOffsetSp` are unit-neutral sp multiples (no unit conversion).
@WireFormat
public struct ResolvedAnchorWire: Equatable {
    public let measureIndex: Int32
    public let tickInMeasure: Int32
    public let partIndex: Int32
    public let staffIndexInPart: Int32
    public let dxSp: Double
    public let verticalOffsetSp: Double

    public init(
        measureIndex: Int32, tickInMeasure: Int32, partIndex: Int32,
        staffIndexInPart: Int32, dxSp: Double, verticalOffsetSp: Double,
    ) {
        self.measureIndex = measureIndex
        self.tickInMeasure = tickInMeasure
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
        self.dxSp = dxSp
        self.verticalOffsetSp = verticalOffsetSp
    }
}

/// Mirrors ssm `AnchorRefPointWire` — an element of `SheetMusicJNI.nativeAnchorReferencePoint`'s output array. The
/// reference point + staff-space are in document millimetres. `spMm == 0` is the miss sentinel (the anchor did not
/// resolve in the current layout); the array stays positionally aligned with the input identities.
@WireFormat
public struct AnchorRefPointWire: Equatable {
    public let xMm: Double
    public let yMm: Double
    public let spMm: Double

    public init(xMm: Double, yMm: Double, spMm: Double) {
        self.xMm = xMm
        self.yMm = yMm
        self.spMm = spMm
    }
}

/// A document-millimetre point — output of `nativeAnnotationRepresentativePoint`. Kotlin sends it to
/// `SheetMusicJNI.nativeResolveAnchor`.
@WireFormat
public struct PointMmWire: Equatable {
    public let xMm: Double
    public let yMm: Double

    public init(xMm: Double, yMm: Double) {
        self.xMm = xMm
        self.yMm = yMm
    }
}

/// A captured, persistable annotation stroke — output of `nativeAnnotationCapture` and the per-stroke element of
/// `nativeAnnotationDisplayTransforms`'s input. Carries the six `MusicalAnchor` fields plus the normalized `InkStroke`
/// FINK bytes (`Domain.InkStrokeCodec`). This is the payload shape Sub-plan D persists in Room.
@WireFormat
public struct DrawingAnchorWire: Equatable {
    public let measureIndex: Int32
    public let tickInMeasure: Int32
    public let partIndex: Int32
    public let staffIndexInPart: Int32
    public let dxSp: Double
    public let verticalOffsetSp: Double
    public let encodedDrawing: Data

    public init(
        measureIndex: Int32, tickInMeasure: Int32, partIndex: Int32,
        staffIndexInPart: Int32, dxSp: Double, verticalOffsetSp: Double, encodedDrawing: Data,
    ) {
        self.measureIndex = measureIndex
        self.tickInMeasure = tickInMeasure
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
        self.dxSp = dxSp
        self.verticalOffsetSp = verticalOffsetSp
        self.encodedDrawing = encodedDrawing
    }
}

/// A per-stroke display placement — an element of `nativeAnnotationDisplayTransforms`'s output, positionally aligned
/// with the input drawings. Matches `ReaderAnnotationCore.StrokeTransform`: scale by `sp` about the origin, then
/// translate by `(px, py)` (document mm). `sp == 0` marks an unresolved drawing the caller skips this frame.
@WireFormat
public struct StrokeTransformWire: Equatable {
    public let sp: Double
    public let px: Double
    public let py: Double

    public init(sp: Double, px: Double, py: Double) {
        self.sp = sp
        self.px = px
        self.py = py
    }
}

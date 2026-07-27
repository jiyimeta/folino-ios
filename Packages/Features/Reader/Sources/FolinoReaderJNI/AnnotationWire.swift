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
/// FINK bytes (`Domain.InkStrokeCodec`). This is the payload shape Sub-plan D persists in Room. `anchorKind` /
/// `pageIndex` extend the same wire struct to carry PDF page anchors too (Task 10): `anchorKind` is `0` for a musical
/// anchor (the original shape; the six `MusicalAnchor` fields are meaningful) or `1` for a page anchor (`pageIndex` is
/// meaningful, the musical fields are zero). Both new fields default in the memberwise init so every pre-existing
/// musical call site keeps compiling unchanged. Use the `.page(pageIndex:encodedDrawing:)` convenience for the PDF
/// case instead of setting `anchorKind` by hand.
@WireFormat
public struct DrawingAnchorWire: Equatable {
    public let measureIndex: Int32
    public let tickInMeasure: Int32
    public let partIndex: Int32
    public let staffIndexInPart: Int32
    public let dxSp: Double
    public let verticalOffsetSp: Double
    public let encodedDrawing: Data
    public let anchorKind: Int32
    public let pageIndex: Int32

    public init(
        measureIndex: Int32, tickInMeasure: Int32, partIndex: Int32,
        staffIndexInPart: Int32, dxSp: Double, verticalOffsetSp: Double, encodedDrawing: Data,
        anchorKind: Int32 = 0, pageIndex: Int32 = -1,
    ) {
        self.measureIndex = measureIndex
        self.tickInMeasure = tickInMeasure
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
        self.dxSp = dxSp
        self.verticalOffsetSp = verticalOffsetSp
        self.encodedDrawing = encodedDrawing
        self.anchorKind = anchorKind
        self.pageIndex = pageIndex
    }
}

extension DrawingAnchorWire {
    /// Convenience constructor for a PDF page anchor. The musical fields are meaningless zeros — `anchorKind == 1`
    /// is what tells the reader to ignore them. Not part of the wire schema (no Kotlin counterpart needed), so this
    /// stays `internal` — only `PdfAnnotationBridge.nativePdfAnnotationCapture` calls it.
    static func page(pageIndex: Int32, encodedDrawing: Data) -> DrawingAnchorWire {
        DrawingAnchorWire(
            measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
            dxSp: 0, verticalOffsetSp: 0, encodedDrawing: encodedDrawing,
            anchorKind: 1, pageIndex: pageIndex,
        )
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

/// One eraser gesture sample batch: the centerline in document mm plus the eraser's geometric radius. Input to
/// `nativeAnnotationErase`.
@WireFormat
public struct EraseRequestWire: Equatable {
    public let xMm: [Double]
    public let yMm: [Double]
    public let radiusMm: Double

    public init(xMm: [Double], yMm: [Double], radiusMm: Double) {
        self.xMm = xMm
        self.yMm = yMm
        self.radiusMm = radiusMm
    }
}

/// Result of an erase: the replacement layer plus which of its entries changed geometry. Output of
/// `nativeAnnotationErase`; see `ReaderAnnotationCore.EraseResult` for the field semantics `changedIndices` mirrors.
@WireFormat
public struct EraseResultWire: Equatable {
    public let drawings: [DrawingAnchorWire]
    public let changedIndices: [Int32]

    public init(drawings: [DrawingAnchorWire], changedIndices: [Int32]) {
        self.drawings = drawings
        self.changedIndices = changedIndices
    }
}

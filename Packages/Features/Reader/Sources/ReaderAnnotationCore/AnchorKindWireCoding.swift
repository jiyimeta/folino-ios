import Domain
import Foundation

/// Bridges the flat wire fields `FolinoReaderJNI.DrawingAnchorWire` (and its generated Kotlin counterpart) carry
/// to and from `Domain.DrawingAnchorKind`. Deliberately pulled out of `FolinoReaderJNI`: that target depends on
/// `swift-java`'s jextract plugin, which declares macOS as its only supported platform (no iOS), and host-testing it
/// on macOS cascades a macOS-platform requirement through packages (`Utility`, `ScoreUI`) that aren't declared
/// macOS-clean — so `FolinoReaderJNI` can only be verified via the real Android arm64 cross-compile, never a host
/// test run. The "which kind is this" branch is exactly the kind of pure decision that must not live only inside
/// that untestable target: both `PdfAnnotationBridge` (the display path) and `AnnotationSaveBridge` (the
/// persistence read/write path) call this instead of branching on `anchorKind` themselves.
///
/// Wire convention (matches `DrawingAnchorWire`'s own doc comment): `anchorKind == 0` is musical (the six
/// `MusicalAnchor` fields are meaningful; `pageIndex` is the `-1` placeholder), `anchorKind == 1` is page
/// (`pageIndex` is meaningful; the six musical fields are zero). Any `anchorKind` other than `pageAnchorKind` is
/// treated as musical, matching the wire's documented default — this is the guard that keeps a musical wire from
/// being coerced into `.page(pageIndex: 0)` by `PageAnchor`'s negative-clamping `init`.
public enum AnchorKindWireCoding {
    public static let musicalAnchorKind: Int32 = 0
    public static let pageAnchorKind: Int32 = 1

    /// Plain-value mirror of `DrawingAnchorWire`'s anchor-selecting fields (everything except `encodedDrawing`),
    /// kept Wirelet-free so this whole file stays host-testable.
    public struct WireFields: Equatable, Sendable {
        public let anchorKind: Int32
        public let pageIndex: Int32
        public let measureIndex: Int32
        public let tickInMeasure: Int32
        public let partIndex: Int32
        public let staffIndexInPart: Int32
        public let dxSp: Double
        public let verticalOffsetSp: Double

        public init(
            anchorKind: Int32, pageIndex: Int32,
            measureIndex: Int32, tickInMeasure: Int32, partIndex: Int32, staffIndexInPart: Int32,
            dxSp: Double, verticalOffsetSp: Double,
        ) {
            self.anchorKind = anchorKind
            self.pageIndex = pageIndex
            self.measureIndex = measureIndex
            self.tickInMeasure = tickInMeasure
            self.partIndex = partIndex
            self.staffIndexInPart = staffIndexInPart
            self.dxSp = dxSp
            self.verticalOffsetSp = verticalOffsetSp
        }
    }

    /// Wire fields → `DrawingAnchorKind`.
    public static func kind(
        anchorKind: Int32, pageIndex: Int32,
        measureIndex: Int32, tickInMeasure: Int32, partIndex: Int32, staffIndexInPart: Int32,
        dxSp: Double, verticalOffsetSp: Double,
    ) -> DrawingAnchorKind {
        guard anchorKind == pageAnchorKind else {
            return .musical(MusicalAnchor(
                measureIndex: Int(measureIndex), tickInMeasure: Int(tickInMeasure),
                partIndex: Int(partIndex), staffIndexInPart: Int(staffIndexInPart),
                dxSp: dxSp, verticalOffsetSp: verticalOffsetSp,
            ))
        }
        return .page(PageAnchor(pageIndex: Int(pageIndex)))
    }

    /// Convenience overload taking the fields pre-packed as `WireFields`.
    public static func kind(_ fields: WireFields) -> DrawingAnchorKind {
        kind(
            anchorKind: fields.anchorKind, pageIndex: fields.pageIndex,
            measureIndex: fields.measureIndex, tickInMeasure: fields.tickInMeasure,
            partIndex: fields.partIndex, staffIndexInPart: fields.staffIndexInPart,
            dxSp: fields.dxSp, verticalOffsetSp: fields.verticalOffsetSp,
        )
    }

    /// `DrawingAnchorKind` → wire fields, the inverse of `kind(anchorKind:pageIndex:...)`. The non-selected side's
    /// fields are zeroed — matching `DrawingAnchorWire.page`'s convention for the musical fields, and its mirror for
    /// `pageIndex`.
    public static func wireFields(for kind: DrawingAnchorKind) -> WireFields {
        switch kind {
        case let .musical(anchor):
            WireFields(
                anchorKind: musicalAnchorKind, pageIndex: -1,
                measureIndex: Int32(anchor.measureIndex), tickInMeasure: Int32(anchor.tickInMeasure),
                partIndex: Int32(anchor.partIndex), staffIndexInPart: Int32(anchor.staffIndexInPart),
                dxSp: anchor.dxSp, verticalOffsetSp: anchor.verticalOffsetSp,
            )
        case let .page(anchor):
            WireFields(
                anchorKind: pageAnchorKind, pageIndex: Int32(anchor.pageIndex),
                measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
                dxSp: 0, verticalOffsetSp: 0,
            )
        }
    }
}

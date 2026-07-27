import Domain
import Foundation

/// Platform-neutral raw stroke geometry the Android JNI seam marshals — the exact channels an androidx.ink `Stroke`
/// carries, as `Double` arrays for wire simplicity. Converts to/from `Domain.InkStroke` so the FINK codec
/// (`Domain.InkStrokeCodec`) stays the single encode path and Kotlin never reimplements it (iOS/Android parity).
///
/// Lives in `ReaderAnnotationCore` (not `FolinoReaderJNI`) so it is host-testable; `FolinoReaderJNI`'s `@WireFormat`
/// `RawInkStrokeWire` mirrors these fields and delegates the mapping here. Geometry is document-mm at capture,
/// anchor-relative sp after a decode round-trip — this type is unit-agnostic.
public struct InkStrokeRawFields: Equatable {
    public var tool: UInt8
    public var colorRGBA: UInt32
    public var baseWidthSp: Double
    public var opacity: Double
    public var x: [Double]
    public var y: [Double]
    public var width: [Double]
    public var force: [Double]
    public var timeMillis: [Int32]

    public init(
        tool: UInt8, colorRGBA: UInt32, baseWidthSp: Double, opacity: Double,
        x: [Double], y: [Double], width: [Double], force: [Double], timeMillis: [Int32],
    ) {
        self.tool = tool
        self.colorRGBA = colorRGBA
        self.baseWidthSp = baseWidthSp
        self.opacity = opacity
        self.x = x
        self.y = y
        self.width = width
        self.force = force
        self.timeMillis = timeMillis
    }

    /// Build a `Domain.InkStroke` (Float geometry), narrowing Double→Float and clamping `timeMillis` into UInt16.
    public func toInkStroke() -> InkStroke {
        InkStroke(
            tool: InkStroke.Tool(rawValue: tool) ?? .pen,
            colorRGBA: colorRGBA,
            baseWidthSp: Float(baseWidthSp),
            opacity: Float(opacity),
            x: x.map(Float.init), y: y.map(Float.init), width: width.map(Float.init),
            force: force.map(Float.init), azimuth: [], altitude: [],
            timeMillis: timeMillis.map { UInt16(clamping: Int($0)) },
        )
    }

    /// Read a `Domain.InkStroke` back into raw fields (widening Float→Double). `azimuth`/`altitude` are dropped
    /// (androidx.ink v1 doesn't feed them; they stay empty on the Android path).
    public init(_ s: InkStroke) {
        self.init(
            tool: s.tool.rawValue,
            colorRGBA: s.colorRGBA,
            baseWidthSp: Double(s.baseWidthSp),
            opacity: Double(s.opacity),
            x: s.x.map(Double.init), y: s.y.map(Double.init), width: s.width.map(Double.init),
            force: s.force.map(Double.init), timeMillis: s.timeMillis.map { Int32($0) },
        )
    }
}

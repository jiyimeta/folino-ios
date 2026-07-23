import Foundation
import ReaderAnnotationCore
import Wirelet

/// @WireFormat mirror of `ReaderAnnotationCore.InkStrokeRawFields` — raw androidx.ink stroke geometry crossing the JNI
/// boundary in BOTH directions (Kotlin builds it from a finished `Stroke`; rebuilds a `Stroke` from it). Swift is the
/// only side that touches the `InkStroke` FINK bytes; the field mapping lives in `InkStrokeRawFields` (host-tested).
/// Field order IS the wire contract — do not reorder.
@WireFormat
public struct RawInkStrokeWire: Equatable {
    public let tool: UInt8
    public let colorRGBA: UInt32
    public let baseWidthSp: Double
    public let opacity: Double
    public let x: [Double]
    public let y: [Double]
    public let width: [Double]
    public let force: [Double]
    public let timeMillis: [Int32]

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
}

extension RawInkStrokeWire {
    init(_ f: InkStrokeRawFields) {
        self.init(
            tool: f.tool, colorRGBA: f.colorRGBA, baseWidthSp: f.baseWidthSp, opacity: f.opacity,
            x: f.x, y: f.y, width: f.width, force: f.force, timeMillis: f.timeMillis,
        )
    }

    var fields: InkStrokeRawFields {
        InkStrokeRawFields(
            tool: tool, colorRGBA: colorRGBA, baseWidthSp: baseWidthSp, opacity: opacity,
            x: x, y: y, width: width, force: force, timeMillis: timeMillis,
        )
    }
}

import Foundation

/// A single free-hand stroke in a platform-neutral, engine-agnostic form. Geometry is stored anchor-relative in
/// staff-space (sp) units — the same baked coordinate space iOS previously stored a normalized `PKDrawing` in. This is
/// the shared on-disk stroke representation for both iOS (PencilKit) and Android (androidx.ink); each platform bridges
/// its native stroke to/from this type. Cross-rendered ink is faithful, not pixel-identical.
public struct InkStroke: Hashable, Sendable {
    /// Superset of the PencilKit ink types existing iOS data can contain, so migration is non-lossy.
    public enum Tool: UInt8, Hashable, Sendable {
        case pen = 0
        case marker = 1 // highlighter
        case pencil = 2
        case monoline = 3
        case fountainPen = 4
        case watercolor = 5
        case crayon = 6
    }

    public var tool: Tool
    /// Canonical light-appearance sRGB, 0xRRGGBBAA packed. Each platform applies its own dark-mode adaptation.
    public var colorRGBA: UInt32
    /// Nominal brush width in sp.
    public var baseWidthSp: Float
    /// Stroke opacity, 0…1.
    public var opacity: Float

    // Structure-of-arrays; all present arrays share `count`. `force`/`azimuth`/`altitude`/`timeMillis` may be empty
    // when the source device didn't provide that channel.
    public var x: [Float]
    public var y: [Float]
    public var width: [Float]
    public var force: [Float]
    public var azimuth: [Float]
    public var altitude: [Float]
    public var timeMillis: [UInt16]

    public init(
        tool: Tool, colorRGBA: UInt32, baseWidthSp: Float, opacity: Float,
        x: [Float], y: [Float], width: [Float],
        force: [Float], azimuth: [Float], altitude: [Float], timeMillis: [UInt16],
    ) {
        self.tool = tool
        self.colorRGBA = colorRGBA
        self.baseWidthSp = baseWidthSp
        self.opacity = opacity
        self.x = x
        self.y = y
        self.width = width
        self.force = force
        self.azimuth = azimuth
        self.altitude = altitude
        self.timeMillis = timeMillis
    }
}

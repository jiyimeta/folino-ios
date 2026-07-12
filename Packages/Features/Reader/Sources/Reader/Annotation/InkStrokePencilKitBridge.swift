import Domain
import PencilKit
import UIKit

/// Bridges a single baked `PKStroke` (geometry already in anchor-relative sp) to/from the neutral `InkStroke`, and the
/// stored-blob helpers the anchoring + migrator use. Geometry is stored as dense on-curve samples (~`sampleSpacingSp`
/// apart) so the format re-ingests convergently into either engine's smoothing — faithful, not pixel-identical.
public enum InkStrokePencilKitBridge {
    /// Sample spacing in sp for dense interpolation. Small enough that reconstruction is visually exact; tune if
    /// needed.
    private static let sampleSpacingSp: CGFloat = 0.5

    static func inkStroke(from stroke: PKStroke) -> InkStroke {
        let samples = Array(stroke.path.interpolatedPoints(by: .distance(sampleSpacingSp)))
        let points = samples.isEmpty ? Array(stroke.path) : samples

        var x = [Float](); var y = [Float](); var width = [Float]()
        var force = [Float](); var azimuth = [Float](); var altitude = [Float](); var time = [UInt16]()
        x.reserveCapacity(points.count); y.reserveCapacity(points.count); width.reserveCapacity(points.count)
        for p in points {
            x.append(Float(p.location.x))
            y.append(Float(p.location.y))
            width.append(Float(p.size.width))
            force.append(Float(p.force))
            azimuth.append(Float(p.azimuth))
            altitude.append(Float(p.altitude))
            time.append(UInt16(clamping: Int((p.timeOffset * 1000).rounded())))
        }

        return InkStroke(
            tool: tool(from: stroke.ink.inkType),
            colorRGBA: rgba(from: stroke.ink.color),
            baseWidthSp: Float(nominalWidth(of: stroke)),
            opacity: 1,
            x: x, y: y, width: width, force: force, azimuth: azimuth, altitude: altitude, timeMillis: time,
        )
    }

    static func pkStroke(from ink: InkStroke) -> PKStroke {
        let n = ink.x.count
        var points = [PKStrokePoint]()
        points.reserveCapacity(n)
        for i in 0 ..< n {
            let w = i < ink.width.count ? CGFloat(ink.width[i]) : CGFloat(ink.baseWidthSp)
            let f = i < ink.force.count ? CGFloat(ink.force[i]) : 1
            let az = i < ink.azimuth.count ? CGFloat(ink.azimuth[i]) : 0
            let al = i < ink.altitude.count ? CGFloat(ink.altitude[i]) : .pi / 2
            let t = i < ink.timeMillis.count ? Double(ink.timeMillis[i]) / 1000 : 0
            points.append(PKStrokePoint(
                location: CGPoint(x: CGFloat(ink.x[i]), y: CGFloat(ink.y[i])),
                timeOffset: t, size: CGSize(width: w, height: w),
                opacity: CGFloat(ink.opacity), force: f, azimuth: az, altitude: al,
            ))
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        return PKStroke(ink: PKInk(inkType(from: ink.tool), color: color(from: ink.colorRGBA)), path: path)
    }

    // MARK: - Stored-blob helpers (the PencilKit⇄bytes boundary)

    static func encodeStoredDrawing(_ drawing: PKDrawing) -> Data {
        assert(drawing.strokes.count <= 1, "encodeStoredDrawing expects a baked single-stroke drawing")
        guard let stroke = drawing.strokes.first else { return drawing.dataRepresentation() }
        return InkStrokeCodec.encode(inkStroke(from: stroke))
    }

    static func decodeStoredDrawing(_ data: Data) -> PKDrawing? {
        if InkStrokeCodec.isInkStroke(data) {
            guard let ink = try? InkStrokeCodec.decode(data) else { return nil }
            return PKDrawing(strokes: [pkStroke(from: ink)])
        }
        return try? PKDrawing(data: data)
    }

    public static func inkStrokeDataFromLegacyPKDrawing(_ data: Data) -> Data? {
        guard !InkStrokeCodec.isInkStroke(data) else { return nil }
        guard let drawing = try? PKDrawing(data: data) else { return nil }
        guard !drawing.strokes.isEmpty else { return nil }
        return encodeStoredDrawing(drawing)
    }

    // MARK: - Ink-type & color mapping

    private static func tool(from t: PKInkingTool.InkType) -> InkStroke.Tool {
        switch t {
        case .pen: .pen
        case .marker: .marker
        case .pencil: .pencil
        case .monoline: .monoline
        case .fountainPen: .fountainPen
        case .watercolor: .watercolor
        case .crayon: .crayon
        @unknown default: .pen
        }
    }

    private static func inkType(from tool: InkStroke.Tool) -> PKInkingTool.InkType {
        switch tool {
        case .pen: .pen
        case .marker: .marker
        case .pencil: .pencil
        case .monoline: .monoline
        case .fountainPen: .fountainPen
        case .watercolor: .watercolor
        case .crayon: .crayon
        }
    }

    private static func nominalWidth(of stroke: PKStroke) -> CGFloat {
        stroke.path.first?.size.width ?? 1
    }

    private static func rgba(from color: UIColor) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        if !resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
            // Not RGB-convertible (e.g. a pattern or grayscale-only color) — fall back to opaque
            // black rather than silently emitting transparent black.
            r = 0; g = 0; b = 0; a = 1
        }
        func c(_ v: CGFloat) -> UInt32 {
            UInt32((max(0, min(1, v)) * 255).rounded())
        }
        return (c(r) << 24) | (c(g) << 16) | (c(b) << 8) | c(a)
    }

    private static func color(from rgba: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((rgba >> 24) & 0xFF) / 255,
            green: CGFloat((rgba >> 16) & 0xFF) / 255,
            blue: CGFloat((rgba >> 8) & 0xFF) / 255,
            alpha: CGFloat(rgba & 0xFF) / 255,
        )
    }
}

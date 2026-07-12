import Domain
import PencilKit
@testable import Reader
import Testing

struct InkStrokePencilKitBridgeTests {
    private func stroke(inkType: PKInkingTool.InkType, color: UIColor) -> PKStroke {
        let pts = [
            PKStrokePoint(
                location: CGPoint(x: 0, y: 0),
                timeOffset: 0,
                size: CGSize(width: 2, height: 2),
                opacity: 1,
                force: 0.3,
                azimuth: 0,
                altitude: .pi / 2,
            ),
            PKStrokePoint(
                location: CGPoint(x: 1, y: 0.5),
                timeOffset: 0.008,
                size: CGSize(width: 2, height: 2),
                opacity: 1,
                force: 0.6,
                azimuth: 0,
                altitude: .pi / 2,
            ),
            PKStrokePoint(
                location: CGPoint(x: 2, y: -0.4),
                timeOffset: 0.016,
                size: CGSize(width: 2, height: 2),
                opacity: 1,
                force: 0.5,
                azimuth: 0,
                altitude: .pi / 2,
            ),
        ]
        let path = PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSince1970: 0))
        return PKStroke(ink: PKInk(inkType, color: color), path: path)
    }

    @Test func `highlighter round trips shape and tool`() throws {
        let original = stroke(inkType: .marker, color: .systemBlue)
        let ink = InkStrokePencilKitBridge.inkStroke(from: original)
        #expect(ink.tool == .marker)
        let rebuilt = InkStrokePencilKitBridge.pkStroke(from: ink)
        // Faithful, not pixel-identical: endpoints within a small sp tolerance.
        let a = rebuilt.path.interpolatedPoints(by: .distance(0.5)).map(\.location)
        #expect(try abs(#require(a.first?.x) - 0) < 0.2)
        #expect(try abs(#require(a.last?.x) - 2) < 0.2)
        #expect(rebuilt.ink.inkType == .marker)
    }

    @Test func `pen round trips color`() {
        let original = stroke(inkType: .pen, color: UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        let ink = InkStrokePencilKitBridge.inkStroke(from: original)
        let rebuilt = InkStrokePencilKitBridge.pkStroke(from: ink)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
        rebuilt.ink.color.getRed(&r, green: &g, blue: &b, alpha: &alpha)
        #expect(abs(r - 0.2) < 0.02)
        #expect(abs(g - 0.4) < 0.02)
        #expect(abs(b - 0.8) < 0.02)
    }

    @Test func `encode produces ink stroke bytes`() {
        let drawing = PKDrawing(strokes: [stroke(inkType: .pen, color: .black)])
        let data = InkStrokePencilKitBridge.encodeStoredDrawing(drawing)
        #expect(InkStrokeCodec.isInkStroke(data))
    }

    @Test func `decode reads both formats`() {
        let drawing = PKDrawing(strokes: [stroke(inkType: .pen, color: .black)])
        let neutral = InkStrokePencilKitBridge.encodeStoredDrawing(drawing)
        let legacy = drawing.dataRepresentation()
        #expect(InkStrokePencilKitBridge.decodeStoredDrawing(neutral) != nil)
        #expect(InkStrokePencilKitBridge.decodeStoredDrawing(legacy) != nil)
    }

    @Test func `migrator transcodes legacy only`() throws {
        let drawing = PKDrawing(strokes: [stroke(inkType: .pen, color: .black)])
        let legacy = drawing.dataRepresentation()
        let neutral = InkStrokePencilKitBridge.encodeStoredDrawing(drawing)
        let transcoded = InkStrokePencilKitBridge.inkStrokeDataFromLegacyPKDrawing(legacy)
        #expect(transcoded != nil)
        #expect(try InkStrokeCodec.isInkStroke(#require(transcoded)))
        // Already-neutral input is left alone.
        #expect(InkStrokePencilKitBridge.inkStrokeDataFromLegacyPKDrawing(neutral) == nil)
    }

    @Test func `migrator returns nil for zero-stroke legacy input`() {
        let empty = PKDrawing()
        let legacy = empty.dataRepresentation()
        #expect(InkStrokePencilKitBridge.inkStrokeDataFromLegacyPKDrawing(legacy) == nil)
    }
}

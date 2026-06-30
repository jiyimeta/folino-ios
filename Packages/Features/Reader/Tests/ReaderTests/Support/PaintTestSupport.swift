import CoreGraphics
import PencilKit

/// Builds trivial `PKStroke`s for annotation projection tests.
enum PaintTestSupport {
    /// A short two-point stroke centred on `point` (renderBounds.center ≈ `point`).
    static func dot(at point: CGPoint) -> PKStroke {
        let p1 = PKStrokePoint(
            location: CGPoint(x: point.x - 1, y: point.y - 1), timeOffset: 0,
            size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: 0,
        )
        let p2 = PKStrokePoint(
            location: CGPoint(x: point.x + 1, y: point.y + 1), timeOffset: 0.01,
            size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: 0,
        )
        let path = PKStrokePath(controlPoints: [p1, p2], creationDate: Date(timeIntervalSince1970: 0))
        return PKStroke(ink: PKInk(.pen, color: .black), path: path)
    }
}

extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

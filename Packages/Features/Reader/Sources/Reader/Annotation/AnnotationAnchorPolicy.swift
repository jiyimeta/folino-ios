import CoreGraphics
import PencilKit

/// Chooses the single document-space point a stroke is anchored to. v1 = the stroke's bounding-box center (centroid):
/// direction-independent, lands a circle's anchor on the note it encircles, and splits any rigid-reflow overhang to
/// both sides of center. Isolated here so the heuristic (leading point, nearest-note snapping, …) can change later
/// WITHOUT changing the stored format — the anchor is always a `MusicalAnchor`, so existing ink stays compatible.
enum AnnotationAnchorPolicy {
    static func representativePoint(of stroke: PKStroke) -> CGPoint {
        let b = stroke.renderBounds
        return CGPoint(x: b.midX, y: b.midY)
    }
}

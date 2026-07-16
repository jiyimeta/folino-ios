import Domain
import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if !canImport(CoreGraphics)
// Android has no CoreGraphics. Provide the minimal geometry primitives the neutral core uses (CGPoint / CGFloat)
// so it cross-compiles without pulling in a heavy layout dependency. iOS compiles this block out and uses the real
// CoreGraphics types; the core never touches CGRect / CGAffineTransform (it carries its own `StrokeTransform`).
public typealias CGFloat = Double
public struct CGPoint: Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    public static let zero = CGPoint(x: 0, y: 0)
}
#endif

// Platform-neutral anchoring core for freehand annotation. Operates on the shared `InkStroke` and an injected
// `AnchorResolving` — NO PencilKit, NO `LayoutDocument` — so it compiles for both the Apple and Android toolchains and
// is the single source of truth both platforms call. iOS wraps it with thin `PKStroke ↔ InkStroke` adapters
// (`AnnotationAnchoring`); Android calls it from `FolinoReaderJNI` with a resolver seeded from ssm's anchor-primitive
// JNI. Capture: each stroke → one `DrawingAnchor` whose geometry is normalized to (origin = the resolved anchor point
// `P`, unit = the layout's `sp`). Display: per drawing, the transform placing that normalized geometry into the
// current layout. Round-trip at the same layout is exact.

/// Abstracts the layout so the core needs no `LayoutDocument` (which lives in `SheetMusicLayout` on iOS and inside
/// ssm's `.so` on Android). `referencePoint` returns the BASE reference point (staff top at the tick column) + `sp`;
/// the core composes the anchor's `dxSp` / `verticalOffsetSp` offsets on top (so the composition formula is shared,
/// not duplicated per platform).
public protocol AnchorResolving {
    /// Continuous musical position for a document-space point (never snaps to a playable event). `nil` when the layout
    /// has no systems / staves / measures.
    func resolveAnchor(at point: CGPoint) -> MusicalAnchor?
    /// Document-space base reference point + `sp` for an anchor's `(measure, tick, part, staff)`. `nil` when the
    /// measure or staff is absent from the current layout (out-of-range index, hidden staff).
    func referencePoint(for anchor: MusicalAnchor) -> (point: CGPoint, sp: CGFloat)?
}

/// A per-stroke display placement: uniform scale by `sp` about the origin, then translate by `(px, py)`. Maps
/// anchor-relative sp geometry into the current layout's document space. Android applies it with `Canvas.concat` over
/// cached geometry; iOS bakes it into the stroke's points via the PencilKit adapter.
public struct StrokeTransform: Equatable, Sendable {
    public let sp: CGFloat
    public let px: CGFloat
    public let py: CGFloat

    public init(sp: CGFloat, px: CGFloat, py: CGFloat) {
        self.sp = sp
        self.px = px
        self.py = py
    }
}

public enum AnnotationAnchoringCore {
    /// The single document point a stroke anchors to: its geometry bounding-box center. Direction-independent; lands a
    /// circle's anchor on the note it encircles, and splits rigid-reflow overhang to both sides of center. (Neutralized
    /// from the old `PKStroke.renderBounds` heuristic onto the stored on-curve samples; the half-stroke-width padding
    /// `renderBounds` added cancels at the center, so both platforms agree.) `.zero` for an empty stroke.
    public static func representativePoint(of stroke: InkStroke) -> CGPoint {
        guard let minX = stroke.x.min(), let maxX = stroke.x.max(),
              let minY = stroke.y.min(), let maxY = stroke.y.max()
        else { return .zero }
        return CGPoint(x: CGFloat(minX + maxX) / 2, y: CGFloat(minY + maxY) / 2)
    }

    /// Resolved anchor point `P` (base reference + the anchor's sp offsets) and the layout `sp`. `nil` when the anchor
    /// can't resolve in the current layout.
    public static func anchorPoint(
        for anchor: MusicalAnchor, using resolver: AnchorResolving,
    ) -> (point: CGPoint, sp: CGFloat)? {
        guard let ref = resolver.referencePoint(for: anchor) else { return nil }
        let point = CGPoint(
            x: ref.point.x + CGFloat(anchor.dxSp) * ref.sp,
            y: ref.point.y + CGFloat(anchor.verticalOffsetSp) * ref.sp,
        )
        return (point, ref.sp)
    }

    /// Capture: each stroke (document-space geometry) → one `DrawingAnchor`. Resolve the representative point to a
    /// `MusicalAnchor`, normalize the geometry to anchor-relative sp (translate by `-P`, scale by `1/sp`), encode the
    /// neutral `InkStroke`. Strokes whose representative point can't resolve are dropped.
    public static func capture(strokes: [InkStroke], using resolver: AnchorResolving) -> [DrawingAnchor] {
        strokes.compactMap { stroke in
            let rep = representativePoint(of: stroke)
            guard let anchor = resolver.resolveAnchor(at: rep),
                  let (point, sp) = anchorPoint(for: anchor, using: resolver), sp > 0
            else { return nil }
            let stored = normalized(stroke, origin: point, sp: sp)
            return DrawingAnchor(kind: .musical(anchor), encodedDrawing: InkStrokeCodec.encode(stored))
        }
    }

    /// Display: for each drawing, the transform placing its normalized geometry into the current layout. Positionally
    /// aligned with `drawings`; `nil` where the anchor can't resolve (the caller skips it and prunes on the next save).
    public static func display(_ drawings: [DrawingAnchor], using resolver: AnchorResolving) -> [StrokeTransform?] {
        drawings.map { drawing in
            guard case let .musical(anchor) = drawing.kind,
                  let (point, sp) = anchorPoint(for: anchor, using: resolver), sp > 0
            else { return nil }
            return StrokeTransform(sp: sp, px: point.x, py: point.y)
        }
    }

    /// Split anchors into those whose resolved point falls in the page band `[pageStartY, pageEndY)` and the rest.
    /// Anchors that fail to resolve go to `offPage` (preserved, never dropped) so a page-scoped re-capture can't delete
    /// ink it cannot currently place.
    public static func partitionByPage(
        _ drawings: [DrawingAnchor], using resolver: AnchorResolving, pageStartY: CGFloat, pageEndY: CGFloat,
    ) -> (onPage: [DrawingAnchor], offPage: [DrawingAnchor]) {
        var onPage: [DrawingAnchor] = []
        var offPage: [DrawingAnchor] = []
        for drawing in drawings {
            guard case let .musical(anchor) = drawing.kind,
                  let (point, _) = anchorPoint(for: anchor, using: resolver),
                  point.y >= pageStartY, point.y < pageEndY
            else { offPage.append(drawing); continue }
            onPage.append(drawing)
        }
        return (onPage, offPage)
    }

    /// Place normalized (anchor-relative sp) geometry into document space with `transform` (scale by `sp`, translate by
    /// `P`). The inverse of the normalization `capture` applies. Width scales with `sp`; the translate does not touch
    /// widths.
    public static func place(_ stroke: InkStroke, with transform: StrokeTransform) -> InkStroke {
        var out = stroke
        out.x = stroke.x.map { Float(CGFloat($0) * transform.sp + transform.px) }
        out.y = stroke.y.map { Float(CGFloat($0) * transform.sp + transform.py) }
        out.width = stroke.width.map { Float(CGFloat($0) * transform.sp) }
        out.baseWidthSp = Float(CGFloat(stroke.baseWidthSp) * transform.sp)
        return out
    }

    /// Normalize document-space geometry to anchor-relative sp (translate by `-P`, scale by `1/sp`). Inverse of
    /// `place`. `sp > 0` is the caller's precondition.
    static func normalized(_ stroke: InkStroke, origin point: CGPoint, sp: CGFloat) -> InkStroke {
        let invSp = 1 / sp
        var out = stroke
        out.x = stroke.x.map { Float((CGFloat($0) - point.x) * invSp) }
        out.y = stroke.y.map { Float((CGFloat($0) - point.y) * invSp) }
        out.width = stroke.width.map { Float(CGFloat($0) * invSp) }
        out.baseWidthSp = Float(CGFloat(stroke.baseWidthSp) * invSp)
        return out
    }
}

import Domain
import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if !canImport(CoreGraphics)
/// Android has no CoreGraphics. `CGFloat` / `CGPoint` are already shimmed module-wide by `AnnotationAnchoringCore`;
/// this adds the `CGRect` / `CGAffineTransform` primitives `PageAnchoringCore` needs on top of those. iOS compiles
/// this block out and uses the real CoreGraphics types.
public struct CGRect: Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: CGFloat {
        min(x, x + width)
    }

    public var minY: CGFloat {
        min(y, y + height)
    }

    public var maxX: CGFloat {
        max(x, x + width)
    }

    public var maxY: CGFloat {
        max(y, y + height)
    }

    public var midX: CGFloat {
        (minX + maxX) / 2
    }

    public var midY: CGFloat {
        (minY + maxY) / 2
    }

    /// Matches Apple's documented `CGRect.contains(_:)`: inside on the min edges, outside on the max edges.
    public func contains(_ point: CGPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }
}

public struct CGAffineTransform: Hashable, Sendable {
    public var a: CGFloat
    public var b: CGFloat
    public var c: CGFloat
    public var d: CGFloat
    public var tx: CGFloat
    public var ty: CGFloat

    public static let identity = CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public init(translationX tx: CGFloat, y ty: CGFloat) {
        self.init(a: 1, b: 0, c: 0, d: 1, tx: tx, ty: ty)
    }

    public init(scaleX sx: CGFloat, y sy: CGFloat) {
        self.init(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
    }

    /// `self.concatenating(t2)`: applying the result is equivalent to applying `self` then `t2`.
    public func concatenating(_ t2: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(
            a: a * t2.a + b * t2.c,
            b: a * t2.b + b * t2.d,
            c: c * t2.a + d * t2.c,
            d: c * t2.b + d * t2.d,
            tx: tx * t2.a + ty * t2.c + t2.tx,
            ty: tx * t2.b + ty * t2.d + t2.ty,
        )
    }
}

extension CGPoint {
    public func applying(_ t: CGAffineTransform) -> CGPoint {
        CGPoint(x: t.a * x + t.c * y + t.tx, y: t.b * x + t.d * y + t.ty)
    }
}
#endif

/// Platform-neutral page-anchor geometry for fixed-layout PDF pages, the sibling of `AnnotationAnchoringCore` (musical
/// anchoring). Operates on the shared `InkStroke` / `DrawingAnchor` primitives — NO PencilKit, NO PDFKit — so it
/// cross-compiles for the Apple and Android toolchains and is the single source of truth both platforms call. iOS
/// wraps it with a thin `PKStroke ↔ InkStroke` adapter (`PDFAnnotationAnchoring`); Android calls it from
/// `FolinoReaderJNI`. Capture: each stroke → one `DrawingAnchor` whose `PageAnchor` is the page its centroid lands on
/// and whose `encodedDrawing` is the stroke normalized to that page's own frame (origin = page top-left, unit = page
/// width). Display: the transform placing that normalized geometry back into a page's CURRENT content-space frame.
/// Because normalization is a fraction of page width, the same stroke renders at the correct spot and size at any
/// committed zoom — the zoom factor cancels.
public enum PageAnchoringCore {
    /// The page a stroke belongs to: the frame that contains the centroid, else the page whose vertical extent is
    /// nearest (covers the inter-page gap). Vertical distance is measured to the frame's nearest edge (0 while inside
    /// the band, clamped distance to top/bottom otherwise), so a centroid at the exact midpoint of the gap ties on
    /// distance and resolves to the upper page via `firstIndex`. `nil` only when there are no pages.
    public static func pageIndex(forCentroid centroid: CGPoint, pageFrames: [CGRect]) -> Int? {
        guard !pageFrames.isEmpty else { return nil }
        if let hit = pageFrames.firstIndex(where: { $0.contains(centroid) }) { return hit }
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, frame) in pageFrames.enumerated() {
            let clampedY = min(max(centroid.y, frame.minY), frame.maxY)
            let d = abs(clampedY - centroid.y)
            if d < bestDist {
                bestDist = d
                best = i
            }
        }
        return best
    }

    /// content→page-fraction: translate by `-origin`, then scale by `1/width`.
    public static func normalizeTransform(pageFrame: CGRect) -> CGAffineTransform? {
        guard pageFrame.width > 0 else { return nil }
        return CGAffineTransform(translationX: -pageFrame.minX, y: -pageFrame.minY)
            .concatenating(CGAffineTransform(scaleX: 1 / pageFrame.width, y: 1 / pageFrame.width))
    }

    /// page-fraction→content: scale by `width`, then translate by `+origin`.
    public static func displayTransform(pageFrame: CGRect) -> CGAffineTransform? {
        guard pageFrame.width > 0 else { return nil }
        return CGAffineTransform(scaleX: pageFrame.width, y: pageFrame.width)
            .concatenating(CGAffineTransform(translationX: pageFrame.minX, y: pageFrame.minY))
    }

    /// Capture: each stroke (content-space geometry) → one `DrawingAnchor`. Resolves the representative point (the
    /// bounding-box center shared with `AnnotationAnchoringCore`) to a page via `pageIndex(forCentroid:pageFrames:)`,
    /// then normalizes to that page. Strokes whose centroid can't resolve to a page (empty `pageFrames`) are dropped.
    public static func capture(strokes: [InkStroke], pageFrames: [CGRect]) -> [DrawingAnchor] {
        strokes.compactMap { stroke in
            let centroid = AnnotationAnchoringCore.representativePoint(of: stroke)
            guard let index = pageIndex(forCentroid: centroid, pageFrames: pageFrames) else { return nil }
            return capturePage(strokes: [stroke], pageIndex: index, pageFrame: pageFrames[index]).first
        }
    }

    /// Capture strokes already known to belong to `pageIndex` (band-space / paged-mode capture, where the visible
    /// page is known rather than resolved from the centroid), normalized to `pageFrame`.
    public static func capturePage(strokes: [InkStroke], pageIndex: Int, pageFrame: CGRect) -> [DrawingAnchor] {
        guard let normalize = normalizeTransform(pageFrame: pageFrame) else { return [] }
        return strokes.map { stroke in
            DrawingAnchor(
                kind: .page(PageAnchor(pageIndex: pageIndex)),
                encodedDrawing: InkStrokeCodec.encode(transformed(stroke, by: normalize)),
            )
        }
    }

    /// Split anchors into those on `pageIndex` and the rest (off-page anchors preserved for the merge).
    public static func partitionByPage(
        _ drawings: [DrawingAnchor], pageIndex: Int,
    ) -> (onPage: [DrawingAnchor], offPage: [DrawingAnchor]) {
        var onPage: [DrawingAnchor] = []
        var offPage: [DrawingAnchor] = []
        for drawing in drawings {
            if case let .page(anchor) = drawing.kind, anchor.pageIndex == pageIndex {
                onPage.append(drawing)
            } else {
                offPage.append(drawing)
            }
        }
        return (onPage, offPage)
    }

    /// The display transform for each drawing, positionally aligned with `drawings`. `nil` where the drawing isn't a
    /// `.page` anchor, or its page index is out of range for `pageFrames` (the caller skips it).
    public static func displayTransforms(_ drawings: [DrawingAnchor], pageFrames: [CGRect]) -> [CGAffineTransform?] {
        drawings.map { drawing in
            guard case let .page(anchor) = drawing.kind, anchor.pageIndex < pageFrames.count else { return nil }
            return displayTransform(pageFrame: pageFrames[anchor.pageIndex])
        }
    }

    /// `displayTransforms` results projected into the `StrokeTransform` shape `AnnotationAnchoringCore.display`
    /// already uses (scale `sp`, translate `(px, py)`) — exactly what a `displayTransform(pageFrame:)` affine
    /// transform's `a`/`tx`/`ty` carry under its scale-then-translate composition. `nil` wherever `displayTransforms`
    /// returns `nil` (not a `.page` anchor — including a `.musical` anchor a caller mistakenly fed in — or its page
    /// index is out of range for `pageFrames`). Lets JNI bridges reuse the same Data-shaped output the musical path
    /// already produces, with no `CGAffineTransform` decomposition of their own.
    public static func displayStrokeTransforms(
        _ drawings: [DrawingAnchor], pageFrames: [CGRect],
    ) -> [StrokeTransform?] {
        displayTransforms(drawings, pageFrames: pageFrames).map { transform in
            guard let transform else { return nil }
            return StrokeTransform(sp: transform.a, px: transform.tx, py: transform.ty)
        }
    }

    /// Bake `transform` directly into a stroke's content-space geometry (positions, and — via the transform's implied
    /// uniform scale — width). The neutral `InkStroke` has no separate transform slot (unlike `PKStroke.transform`),
    /// so normalization is always applied straight to the arrays. Uses `zip` (not indexed access) so a
    /// caller-supplied `InkStroke` with mismatched `x`/`y` counts — never true today via `InkStrokeCodec`, but not
    /// structurally guaranteed once Task 10 builds these from JNI wire arrays — degrades instead of trapping,
    /// mirroring `AnnotationAnchoringCore.normalized`'s independent `.map`s. `.squareRoot()` (not the free `sqrt`
    /// function) needs no libm import, which matters on the Android cross-compile toolchain.
    private static func transformed(_ stroke: InkStroke, by transform: CGAffineTransform) -> InkStroke {
        var out = stroke
        let placed = zip(stroke.x, stroke.y).map { x, y in
            CGPoint(x: CGFloat(x), y: CGFloat(y)).applying(transform)
        }
        out.x = placed.map { Float($0.x) }
        out.y = placed.map { Float($0.y) }
        let det = transform.a * transform.d - transform.b * transform.c
        let widthScale = Float(abs(det).squareRoot())
        out.width = stroke.width.map { $0 * widthScale }
        out.baseWidthSp = stroke.baseWidthSp * widthScale
        return out
    }
}

import CoreGraphics
import UIKit

struct PinchCommitInput {
    let baseZoom: CGFloat
    let magnification: CGFloat
    let startLocation: CGPoint
    let currentOffset: CGPoint
    let offsetX: CGFloat
    let offsetY: CGFloat
}

struct PinchCommitResult {
    let targetZoom: CGFloat
    let ratio: CGFloat
    /// Anchor-preserving scroll target BEFORE per-container clamping (vertical/paged clamp `max(0,·)`; horizontal
    /// clamps Y against its post-commit inset). Mirrors the formula the three score `commitPinch`s share.
    let rawScrollTarget: CGPoint
    let isBounceBack: Bool
    let snapToUnit: Bool
    /// `combined / targetZoom` — the magnification to compensate to at the snap-to-unit instant so the visible scale is
    /// invariant before the frame-by-frame decay to 1. Only meaningful when `snapToUnit`.
    let compensatedMag: CGFloat
}

/// The pinch-commit math shared by all reader modes (vertical / horizontal / paged, score + PDF). The view-side
/// orchestration (which offset axes to reset, `animateReset` vs `withAnimation`, the async hop) stays per-mode in the
/// container/shell; this provides the numbers so the geometry can never diverge again.
enum ReaderPinchCommit {
    static func resolve(_ input: PinchCommitInput) -> PinchCommitResult {
        let combined = input.baseZoom * input.magnification
        let targetZoom: CGFloat = combined < 1.05 ? 1.0 : combined
        let ratio = input.baseZoom == 0 ? 1 : targetZoom / input.baseZoom
        let rawScrollTarget = CGPoint(
            x: input.currentOffset.x + input.startLocation.x * (ratio - 1) - input.offsetX,
            y: input.currentOffset.y + input.startLocation.y * (ratio - 1) - input.offsetY,
        )
        return PinchCommitResult(
            targetZoom: targetZoom,
            ratio: ratio,
            rawScrollTarget: rawScrollTarget,
            isBounceBack: targetZoom <= 1.0 && input.baseZoom <= 1.0,
            snapToUnit: targetZoom <= 1.0,
            compensatedMag: targetZoom == 0 ? 1 : combined / targetZoom,
        )
    }

    /// Clamp a requested scroll offset into `UIScrollView`'s valid `contentOffset` range and report the residual the
    /// clamp removed. Mirrors the range `UIScrollView` itself enforces — `[-inset.left, contentSize - bounds +
    /// inset.right]` per axis (`max`-guarded so a content-fits-viewport axis collapses to a single point) — so this is
    /// the single source of truth for both `ScoreScrollHost`'s pre-clamp and the pinch-commit re-anchor.
    ///
    /// `residual = clamped - raw`. It is `.zero` exactly when `raw` was already in range (the seamless-commit fast
    /// path). When non-zero — the user overscrolled past a content edge during the pinch — it is the screen-space
    /// vector the commit must fold into the live `.offset` (then ease to zero) so the content stays put at release and
    /// animates to the edge-aligned rest instead of snapping there in a single frame. Sign: `.offset(+x)` moves content
    /// right, `contentOffset(+x)` moves it left, so seeding `pinch.offset = residual` cancels the clamp shift exactly.
    static func clampScrollTarget(
        _ raw: CGPoint,
        contentSize: CGSize,
        bounds: CGSize,
        inset: UIEdgeInsets,
    ) -> (clamped: CGPoint, residual: CGPoint) {
        let minX = -inset.left
        let maxX = max(minX, contentSize.width + inset.right - bounds.width)
        let minY = -inset.top
        let maxY = max(minY, contentSize.height + inset.bottom - bounds.height)
        let clamped = CGPoint(
            x: max(minX, min(maxX, raw.x)),
            y: max(minY, min(maxY, raw.y)),
        )
        let residual = CGPoint(x: clamped.x - raw.x, y: clamped.y - raw.y)
        return (clamped, residual)
    }
}

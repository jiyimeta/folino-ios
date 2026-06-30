import CoreGraphics

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
}

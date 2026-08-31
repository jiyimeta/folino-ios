// PARITY(macos): PiP frame renderer — renders video frames for `ScorePiPCoordinator`, which is itself iOS/tvOS-only
//   AVKit machinery (see the marker on that file). No macOS reading surface (Ⅳ) needs a pixel-buffer frame
//   renderer.

#if os(iOS)
import CoreGraphics
import CoreVideo
import Domain
import QuartzCore
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI
import UIKit

/// Renders a horizontal-mode frame of the score directly into a `CVPixelBuffer` via Core Graphics — no window or
/// view-tree dependency. `ScoreLayerBuilder.buildSystem(...)` produces a `CALayer` we can `render(in:)` into any
/// CGContext, including off-screen pixel-buffer-backed ones. SwiftUI / UIKit are only reached at init to resolve
/// `Color.accentColor` for the cursor fill so it matches what the Reader paints on-screen.
///
/// Horizontal layout is single-system, so we lay out once at init, build the system layer once, and per-frame just blit
/// + draw the cursor rectangle on top.
@MainActor
final class ScorePiPFrameRenderer {
    /// Distance in pt from the left edge of the PiP window at which the cursor's measure is parked when playback is
    /// running.
    private static let cursorLeadingInsetPt: CGFloat = 80
    /// Vertical breathing room above & below the system inside the PiP window.
    private static let verticalPaddingPt: CGFloat = 16
    /// Upper bound on buffer height. Beyond this, the score is uniformly scaled down so it fits — keeps the PiP window
    /// from growing taller than wider screens want to support.
    private static let maxPixelHeightPt: CGFloat = 800
    /// AVKit needs non-trivial dimensions; floor each pixel-buffer axis here so very small scores don't degenerate the
    /// pipeline.
    private static let minPixelDimensionPt: CGFloat = 80
    /// Multiplier applied via `scoreScale` to shrink the drawn music inside the PiP buffer. The PiP window's on-screen
    /// size is fixed by the buffer's *aspect ratio* (not its pixel dimensions), so the only way to land the staff at
    /// Reader-parity is to occupy a smaller fraction of the buffer. The unavoidable consequence is more top/ bottom
    /// whitespace in the PiP window — that's a property of the fixed-window-height invariant, not a bug. Tune
    /// empirically. Paired with `aspectNumerator = 6` (flatter PiP window) and `pointHeightMultiplier = 0.9` (tighter
    /// buffer): 0.88 lands the staff a hair above Reader-parity while leaving just enough room for the padding above &
    /// below. With the older `aspectNumerator = 4`, 0.67 was the equivalent target.
    private static let pipStaffShrinkFactor: CGFloat = 0.88
    /// Multiplier applied to the buffer's "natural" point height (system + verticalPadding*2). 1.0 leaves a margin
    /// equal to `verticalPaddingPt` on each side of the system; values < 1 shave that margin (and proportionally the
    /// buffer width via `aspect`), so the PiP window's on-screen real estate is less dominated by whitespace. At 0.9
    /// the buffer's natural margin is consumed almost exactly by the `pipStaffShrinkFactor = 0.88` shrink — the drawn
    /// music ends up filling the usable area.
    private static let pointHeightMultiplier: CGFloat = 0.9
    /// Lowest buffer aspect (most square / tall) we'll produce. Going narrower than this makes the PiP window awkwardly
    /// tall; instead we cap aspect here and let the renderer shrink the score uniformly to fit the resulting buffer
    /// height.
    private static let minAspect: CGFloat = 1.0
    /// Widest buffer aspect we'll produce. Pushed beyond Apple's HIG 1.78:1 guideline because (a) AVKit happily renders
    /// the wider window, and (b) wider buffer → flatter PiP window → less vertical whitespace around the (deliberately
    /// shrunk) staff. See `pipStaffShrinkFactor` for the other half of the trade-off.
    private static let maxAspect: CGFloat = 6.0
    /// Numerator for the staff-count → aspect heuristic. Picked so 1-staff scores hit `maxAspect`, 2-staff scores land
    /// at 3:1 (flat enough to keep on-screen whitespace modest), and orchestral scores still degrade smoothly toward
    /// square.
    private static let aspectNumerator: CGFloat = 6.0
    /// Pixels per content point. AVKit upscales the buffer to fit the PiP window on screen; rendering at 2x means AVKit
    /// downscales instead, which produces crisp edges on stems/staff lines without changing the apparent size of the
    /// music.
    private static let pixelDensity: CGFloat = 2.0
    /// Per-tick fraction of the remaining distance to consume during auto-scroll animation. Tuned so ~0.25s of pump (15
    /// ticks at 60fps) closes ~90% of the gap, matching the on-screen horizontal Reader's `easeInOut` feel.
    private static let scrollSmoothingFactor: CGFloat = 0.14
    /// Below this remaining-distance threshold (in document pt), the scroll offset snaps to the target and the
    /// animation ends.
    private static let scrollSnapThresholdPt: CGFloat = 0.5

    let pixelSize: CGSize

    private let score: Score
    private let pool: CVPixelBufferPool
    private let document: LayoutDocument
    private let system: LayoutSystem
    private let scoreLayer: CALayer
    /// Resolved at init from `Color.accentColor` (the same color the Reader passes to `ScoreView` as
    /// `playbackCursorColor`) so the PiP cursor matches the on-screen one. Drawn fully opaque — the PiP window is small
    /// enough that a translucent overlay reads as a blurry smear instead of a distinct cursor. Kept as a `CGColor` so
    /// the hot path in `renderFrame` doesn't reallocate per frame.
    private let cursorFillColor: CGColor
    /// Logical size of the renderable area, in CG points. The actual pixel buffer is `pointSize × pixelDensity` — see
    /// init.
    private let pointSize: CGSize
    /// Uniform scale applied to the system layer (and cursor rect) when the score would otherwise overflow the buffer's
    /// usable height.
    private let scoreScale: CGFloat
    /// Leading edge of the viewport in document X coordinates. Animates toward `targetScrollOffsetDocX` so the visible
    /// window slides smoothly when the cursor walks off the end.
    private var scrollOffsetDocX: CGFloat = 0
    /// Destination for the auto-scroll animation. Updated whenever the cursor's measure overflows the viewport.
    private var targetScrollOffsetDocX: CGFloat = 0

    /// True while the viewport is still sliding toward its target. The pump uses this to keep rendering frames between
    /// cursor changes; otherwise the animation would freeze on the first post-cursor tick.
    var isAnimatingScroll: Bool {
        abs(targetScrollOffsetDocX - scrollOffsetDocX) > Self.scrollSnapThresholdPt
    }

    /// Off-main-actor portion of construction. `LayoutEngine.layout` is the heaviest step on the PiP rearm path;
    /// isolating it here lets `ScorePiPCoordinator.arm` compute the document on a detached task and only hop back to
    /// the main actor to assemble the MainActor-only state (`CALayer`, `CVPixelBufferPool`, `UIColor`). Without this
    /// split, every Visual Inspector staff toggle (and any path that flows through `armPiPIfReady`) blocks main for
    /// ~100ms of layout work even though that work has no UI dependencies.
    struct Prepared {
        let options: ScoreViewOptions
        let document: LayoutDocument
        let firstSystem: LayoutSystem
    }

    nonisolated static func prepare(
        score: Score,
        staffSize: CGFloat,
        collapseMultiMeasureRests: Bool,
        showInvisibleElements: Bool,
        showAllMeasureNumbers: Bool,
    ) throws -> Prepared {
        let opts = ScoreViewOptions(
            staffSize: staffSize, systemGap: staffSize * 1.25,
            wrapToViewWidth: false, includeTitleFrame: false,
            breakPolicy: .ignoreAll,
            breakIndicatorVisibility: .none,
            multiMeasureRest: collapseMultiMeasureRests
                ? .collapse(minimumMeasures: ReaderPreferences.multiMeasureRestThreshold)
                : .disabled,
            showsInvisibleElements: showInvisibleElements,
            measureNumbers: showAllMeasureNumbers ? .everyMeasure : .systemStart,
        )
        let naturalWidth = LayoutEngine.naturalContentWidth(score: score, options: opts)
        let document = LayoutEngine.layout(
            score: score, options: opts, availableWidth: naturalWidth,
        )
        guard let firstSystem = document.systems.first else {
            throw NSError(
                domain: "ScorePiPFrameRenderer", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Layout produced no systems"],
            )
        }
        return Prepared(options: opts, document: document, firstSystem: firstSystem)
    }

    /// Convenience that runs `prepare` synchronously and chains into the `Prepared`-taking init. Used by tests where
    /// the off-main split would just add noise; production code goes through `ScorePiPCoordinator.arm` which calls
    /// `prepare` on a detached task.
    convenience init(
        score: Score,
        staffSize: CGFloat,
        collapseMultiMeasureRests: Bool,
        showInvisibleElements: Bool,
        showAllMeasureNumbers: Bool,
    ) throws {
        let prepared = try Self.prepare(
            score: score, staffSize: staffSize,
            collapseMultiMeasureRests: collapseMultiMeasureRests,
            showInvisibleElements: showInvisibleElements,
            showAllMeasureNumbers: showAllMeasureNumbers,
        )
        try self.init(score: score, prepared: prepared)
    }

    init(score: Score, prepared: Prepared) throws {
        self.score = score
        document = prepared.document
        let firstSystem = prepared.firstSystem
        system = firstSystem

        // Adaptive PiP buffer size driven by staff count, with both an aspect floor (so the window never gets
        // uncomfortably tall on orchestral scores) and an absolute height cap. When the natural system is too tall to
        // fit, `scoreScale` shrinks the drawn music uniformly so it still fits inside the buffer. Lower-bound the
        // dimensions just enough to keep AVKit happy — the rest is content-driven.
        let staffCount = max(1, firstSystem.staffOrigins.count)
        let rawHeight = ceil(
            (firstSystem.size.height + Self.verticalPaddingPt * 2) * Self.pointHeightMultiplier,
        )
        let pointHeight = min(Self.maxPixelHeightPt, max(Self.minPixelDimensionPt, rawHeight))
        let aspect = CGFloat(pipWindowAspect(
            staffCount: staffCount,
            aspectNumerator: Double(Self.aspectNumerator),
            minAspect: Double(Self.minAspect),
            maxAspect: Double(Self.maxAspect),
        ))
        let pointWidth = max(Self.minPixelDimensionPt, ceil(pointHeight * aspect))
        pointSize = CGSize(width: pointWidth, height: pointHeight)
        // Buffer pixels = points × density. AVKit downscales for the PiP window; the extra resolution prevents the
        // stems and staff lines from blurring on the way through.
        pixelSize = CGSize(
            width: Self.roundUpToEven(pointWidth * Self.pixelDensity),
            height: Self.roundUpToEven(pointHeight * Self.pixelDensity),
        )
        // Shrink to the configured fraction by default; only fall back to a tighter fit-scale when even the shrunk
        // system would overflow the buffer's usable height (orchestral edge case).
        let usableHeight = pointHeight - Self.verticalPaddingPt * 2
        scoreScale = min(Self.pipStaffShrinkFactor, usableHeight / firstSystem.size.height)

        pool = try Self.makePool(size: pixelSize)
        scoreLayer = ScoreLayerBuilder.buildSystem(firstSystem, metrics: document.metrics)
        cursorFillColor = UIColor(Color.accentColor).cgColor
    }

    func renderFrame(playbackCursor: ScoreCursor?, lookaheadCursor: ScoreCursor?) -> CVPixelBuffer? {
        var maybe: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybe) == kCVReturnSuccess,
              let buffer = maybe else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: base,
            width: Int(pixelSize.width),
            height: Int(pixelSize.height),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: info,
        ) else { return nil }

        // White background — overdraws whatever the pool returns.
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: pixelSize))

        // Scale into the point coordinate system; everything that follows can reason in points, with `pixelDensity`
        // translating to pixel positions automatically.
        ctx.scaleBy(x: Self.pixelDensity, y: Self.pixelDensity)
        // CGContext default is bottom-left; CALayer & cursor frames are top-left. Flip so positive Y goes downward.
        ctx.translateBy(x: 0, y: pointSize.height)
        ctx.scaleBy(x: 1, y: -1)

        // Rendered cursor stays on the real playback position — lookahead only drives scroll targeting.
        let cursorFrame = playbackCursor.flatMap {
            document.cursorFrame(for: $0, in: score)
        }
        advanceScroll(realCursor: playbackCursor, lookaheadCursor: lookaheadCursor)
        // Center the (scaled) system vertically; viewport's left edge sits at `scrollOffsetDocX` in document coords.
        let scaledSystemHeight = system.size.height * scoreScale
        let shiftY = (pointSize.height - scaledSystemHeight) / 2
        let shiftX = -scrollOffsetDocX * scoreScale

        ctx.saveGState()
        ctx.translateBy(x: shiftX, y: shiftY)
        ctx.scaleBy(x: scoreScale, y: scoreScale)
        ctx.translateBy(x: system.origin.x, y: system.origin.y)
        scoreLayer.render(in: ctx)
        ctx.restoreGState()

        if let frame = cursorFrame {
            ctx.setFillColor(cursorFillColor)
            ctx.fill(CGRect(
                x: shiftX + frame.minX * scoreScale,
                y: shiftY + frame.minY * scoreScale,
                width: frame.width * scoreScale,
                height: frame.height * scoreScale,
            ))
        }
        return buffer
    }

    /// Update `targetScrollOffsetDocX` based on the real cursor's measure and an optional lookahead cursor, then lerp
    /// `scrollOffsetDocX` toward the target. When `lookaheadCursor` is present (playback running), left-aligns the
    /// playing measure ~2 beats early via a latched 2-stage trigger (the real OR the lookahead measure overflowing
    /// the viewport's right edge). Without it (paused / no anchor), falls back to the reactive overflow-triggered
    /// left-align. Idiom matches `HorizontalScoreContainer`, but latched for PiP's per-frame re-evaluation.
    private func advanceScroll(realCursor: ScoreCursor?, lookaheadCursor: ScoreCursor?) {
        if let realCursor, let realMeasure = measureDocRect(for: realCursor) {
            let viewportWidthDoc = pointSize.width / scoreScale
            let padDoc = 8 * document.metrics.sp
            if let lookaheadCursor, let lookMeasure = measureDocRect(for: lookaheadCursor) {
                // Playback: left-align the playing measure ~2 beats early, fired by a 2-stage trigger (the real OR
                // the lookahead measure has overflowed the viewport's right edge). PiP re-evaluates this every
                // frame while the lerp runs, so the target must be LATCHED: only update it when a scroll is needed,
                // then hold it at the real measure's left edge so the lerp completes there. (Unlike the SwiftUI
                // one-shot callers, PiP can't use `scrollOffsetPinningSystemTop`'s "return current when visible"
                // result directly — once the lookahead measure scrolls into view mid-lerp it would collapse the
                // target to the current offset and strand the playing measure short of the left edge.)
                let realMin = realMeasure.minX - scrollOffsetDocX
                let realMax = realMeasure.maxX - scrollOffsetDocX
                let realVisible = isAnchorFullyVisible(
                    anchorMin: realMin, anchorMax: realMax,
                    anchorSize: realMeasure.width, viewportSize: viewportWidthDoc,
                )
                let lookaheadVisible = (lookMeasure.maxX - scrollOffsetDocX) <= viewportWidthDoc
                if !realVisible || !lookaheadVisible {
                    targetScrollOffsetDocX = max(0, realMeasure.minX - padDoc)
                }
            } else {
                // Paused / no lookahead: reactive left-align when the real measure overflows (today's behavior).
                let anchorMin = realMeasure.minX - scrollOffsetDocX
                let anchorMax = realMeasure.maxX - scrollOffsetDocX
                if !isAnchorFullyVisible(
                    anchorMin: anchorMin, anchorMax: anchorMax,
                    anchorSize: realMeasure.width, viewportSize: viewportWidthDoc,
                ) {
                    targetScrollOffsetDocX = max(0, realMeasure.minX - padDoc)
                }
            }
        }
        let delta = targetScrollOffsetDocX - scrollOffsetDocX
        if abs(delta) < Self.scrollSnapThresholdPt {
            scrollOffsetDocX = targetScrollOffsetDocX
        } else {
            scrollOffsetDocX += delta * Self.scrollSmoothingFactor
        }
    }

    /// Document-space rect of the measure the cursor is parked on, regardless of `.item` vs `.beat`. Used to decide
    /// whether to auto-scroll: the trigger is "the measure overflows the viewport", not "the cursor itself crosses an
    /// edge".
    private func measureDocRect(for cursor: ScoreCursor) -> CGRect? {
        guard let firstSystem = document.systems.first,
              let measure = firstSystem.measures.first(where: {
                  $0.measureIndex == cursor.measureIndex
              })
        else { return nil }
        return CGRect(
            x: firstSystem.origin.x + measure.origin.x,
            y: firstSystem.origin.y + measure.origin.y,
            width: measure.width,
            height: firstSystem.size.height,
        )
    }

    private static func roundUpToEven(_ value: CGFloat) -> CGFloat {
        let n = Int(value.rounded(.up))
        return CGFloat(n + (n % 2))
    }

    private static func makePool(size: CGSize) throws -> CVPixelBufferPool {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw NSError(
                domain: "ScorePiPFrameRenderer",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferPool create failed"],
            )
        }
        return pool
    }
}
#endif

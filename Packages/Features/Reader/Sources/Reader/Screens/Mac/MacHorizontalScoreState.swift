// PARITY(macos): horizontal mode's supporting state — these types carry only what the Mac strip needs today
//   (geometry, the sticky pane's bracket, the fit-magnification seed). The annotation canvas and note-editing seam
//   that horizontal mode still lacks would each add state here; see `MacHorizontalScoreContainer`.

#if os(macOS)
import Domain
import PencilKit
import SheetMusicCore
import SheetMusicLayout
import SwiftUI

/// Geometry constants for the Mac's horizontal strip.
enum MacHorizontalMetrics {
    /// Padding, in unmagnified document points, between the engraving and the edges of the hosted content. The sticky
    /// pane's own leading / top padding matches it exactly, which is what puts the pane's white area at the same
    /// corner as the score's — see `MacStickyPaneGeometry`.
    static let contentInset: CGFloat = 16

    /// Magnification that fits the strip's HEIGHT in the window, clamped to what the scroll view allows and never
    /// enlarging past 1.0.
    ///
    /// Height, not width, and that is the mode's whole shape: a horizontally engraved score is arbitrarily wide by
    /// construction, so fitting its width would open every score at the minimum magnification. What a reader wants to
    /// see on opening is one screenful of music at a readable size, with the rest of it to the right.
    static func fitMagnification(documentSize: CGSize, viewport: CGSize) -> CGFloat {
        let framedHeight = documentSize.height + contentInset * 2
        guard framedHeight > 0, viewport.height > 0 else { return 1 }
        let fit = min(viewport.height / framedHeight, 1.0)
        return min(max(fit, MacScoreMagnification.minimum), MacScoreMagnification.maximum)
    }
}

/// Everything the horizontal strip needs that must reach it WITHOUT the container's body being the courier.
///
/// The strip lives inside one `NSHostingView` whose `rootView` is reassigned only when the engraving changes (see
/// `MagnifyingScoreScrollView.contentGeneration`), so a value handed down through the content closure is frozen at
/// that moment. Anything that moves more often than the engraving — the playback cursor, the ink, the band of ink
/// worth rasterizing — has to arrive through observation instead.
///
/// **One object, five properties, and observation is per-property, which is the point.** The container reads
/// `document` and `measureContexts` to place the sticky pane; the strip reads `cursor`, `ink` and `inkBand` and
/// nothing else. A playback tick therefore invalidates the strip and not the container's sticky pane, and installing a
/// new engraving invalidates both — each exactly once. (The page deck splits its cursor into one observable per sheet
/// for the same reason it cannot do this: it has N leaves reading one property, where this mode has one.)
@MainActor
@Observable
final class MacHorizontalScoreState {
    /// The strip's engraving, laid out at the score's natural width, or `nil` before the first layout lands.
    var document: LayoutDocument?
    /// Per-measure clef / key / time / part-label state, cached per engraving because `StickyHeaderView` would
    /// otherwise recompute it `O(measures × staves)` on every scrolled point.
    var measureContexts: [LayoutMeasureContext] = []
    /// Committed ink, already projected into `document`'s space. Read by the strip, written only from the relayout
    /// task and the annotation-layer watcher — never from a body that reads the cursor.
    var ink = PKDrawing()
    /// The horizontal window of `ink` worth rasterizing, snapped to `MacScoreInkOverlay`'s column grid so it changes
    /// once per column of travel rather than once per scrolled point.
    var inkBand: CGRect = .zero
    /// The playback cursor. The strip's own read; the container writes it and never reads it back.
    var cursor: ScoreCursor?
}

/// Where the sticky pane sits, and whether it is on screen at all.
///
/// **Everything pivots on the bracket**, which sits half a space to the LEFT of the first staff's leading edge (see
/// swift-sheet-music's `ScoreLayerBuilder.drawBracket`). The pane appears exactly when the score's bracket reaches the
/// window's leading edge, and is drawn shifted so its own bracket lands at that same X — so at the instant of the
/// handover the pane is superimposed on what it is replacing, and the swap has no visible seam. Reproduced from
/// swift-sheet-music's macOS example container,
/// `Examples/Apple/SheetMusicExample/macOS/HorizontalScoreContainer.swift`.
struct MacStickyPaneGeometry {
    /// The bracket's X in the hosted content's own unmagnified coordinates — document X plus the strip's inset.
    ///
    /// **Taken from the FIRST system, which in this mode is the only one — measured, not assumed.** The container
    /// passes `breakPolicy: .honor`, so the obvious worry is a score with an explicit `<LayoutBreak>line` engraving
    /// to a second row that this pane would then be misaligned against. It cannot happen here, and the reason is
    /// structural rather than incidental: the engraver gates BOTH of its system-ending paths on `wrapToViewWidth`
    /// (`LayoutEngine+Packing.swift:310` for explicit breaks, `:234` for the balanced-span lookahead, plus the
    /// width-driven wraps), and horizontal mode passes `wrapToViewWidth: false`. ssm's own comment at that gate says
    /// so outright — line breaks are ignored in single-line layouts, "mirroring MuseScore's `LayoutMode::LINE` /
    /// `LayoutMode::HORIZONTAL_FIXED` branch where `lineBreak = false` regardless of the flag". Page breaks take the
    /// same gated path (`measureForcesLineBreak` covers both, and it has exactly one call site in the packer).
    ///
    /// Confirmed against ssm 2.3.1 on `testSingleNoteDynamics.mscx` — 38 measures carrying nine explicit
    /// `<LayoutBreak><subtype>line</subtype>` — engraved in this mode's exact configuration at the Mac's default
    /// staff size: **one system**, a 2136 pt strip, with `.honor` and `.ignoreAll` producing byte-identical geometry.
    ///
    /// So `.first` is correct rather than lucky. If a future ssm ever lets a second system through here, this pane
    /// would slide out of alignment once the reader scrolls onto that row, and the fix is to select the system
    /// containing `scroll.y` instead — the scan in `MacHorizontalScoreContainer.measureRect` is the shape to copy.
    let bracketHostingX: CGFloat
    /// Score-relative X (unmagnified) of the leftmost visible score pixel, floored at the start of the document so an
    /// elastic over-scroll to the left does not run the measure lookup off the front.
    let scoreScrollX: CGFloat
    /// False below the threshold: the bracket and everything after it are still in their natural unscrolled positions
    /// there, so a pane would only duplicate what is already on screen.
    let isVisible: Bool

    init(document: LayoutDocument, scrollX: CGFloat) {
        let inset = MacHorizontalMetrics.contentInset
        let staffStartDocX = document.systems.first?.staffOrigins.first?.x ?? 0
        bracketHostingX = inset + staffStartDocX - document.metrics.sp / 2
        scoreScrollX = max(0, scrollX - inset)
        isVisible = scrollX > bracketHostingX
    }
}

/// Identity for the fit-to-window seed: it needs both the window and the engraving, and the engraving is `nil` until
/// the first layout lands, which is exactly the moment the seed becomes possible.
struct MacHorizontalFitKey: Equatable {
    let viewport: CGSize
    let documentSize: CGSize?
}

/// Identity for the `.task(id:)` that re-engraves the score. The window is deliberately absent: horizontal mode lays
/// the score out at its natural width, so a resize changes what is visible and nothing about the engraving.
struct MacHorizontalLayoutKey: Hashable {
    let scoreSignature: Int
    let size: CGFloat
    let honorLayoutBreaks: Bool
    let collapseMultiMeasureRests: Bool
    let showInvisibleElements: Bool
    let showAllMeasureNumbers: Bool
    let transposeSemitones: Int

    init(
        score: Score,
        size: CGFloat,
        honorLayoutBreaks: Bool,
        collapseMultiMeasureRests: Bool,
        showInvisibleElements: Bool,
        showAllMeasureNumbers: Bool,
        transposeSemitones: Int,
    ) {
        // `Score` is Equatable but not Hashable. Same cheap identity proxy the other containers use: structural shape
        // plus opening clefs, which is what makes a clef override re-trigger the task.
        scoreSignature = score.parts.count
            ^ (score.totalStaffCount << 8)
            ^ (score.division << 16)
            ^ score.openingClefSignature
            ^ (transposeSemitones << 24)
        self.size = size
        self.honorLayoutBreaks = honorLayoutBreaks
        self.collapseMultiMeasureRests = collapseMultiMeasureRests
        self.showInvisibleElements = showInvisibleElements
        self.showAllMeasureNumbers = showAllMeasureNumbers
        self.transposeSemitones = transposeSemitones
    }
}
#endif

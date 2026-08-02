import CoreGraphics
import SheetMusicCore
import SheetMusicLayout

/// Off-main engraving service for one score surface, holding the `LayoutCache` that makes a re-engrave incremental.
///
/// **Why this exists.** `LayoutEngine.layout` is `O(measures)` from scratch: on an iPad mini a single note edit
/// re-engraved the whole score in ~350 ms, and the reader ran that on every keystroke. The engine already ships a
/// per-measure / per-system cache (`LayoutCache`) that reduces a one-measure edit to rebuilding the one system it
/// touched — the reader just never kept a cache to hand it. Holding one here is the whole fix.
///
/// **Why an actor.** The cache is documented as "must not be shared across concurrent layout calls": it is rebuilt in
/// place on every call, so two overlapping calls would corrupt each other's entries. The containers drive layout from
/// `.task(id:)`, and cancelling that task does not stop a re-engrave already in flight — so overlap is reachable
/// whenever edits arrive faster than the score can be laid out. An actor serializes the calls; each `layout` body is
/// synchronous, so it runs to completion without interleaving.
///
/// Instances are per score surface (`@State` on the container), so the cache lives exactly as long as the view that
/// reads from it and dies with a mode switch.
actor ScoreRelayoutEngine {
    private let cache = LayoutCache()

    /// Engrave `score` into `availableWidth`. Measures and systems whose inputs are unchanged since the previous call
    /// on this instance are served from the cache.
    func layout(
        score: Score,
        options: ScoreViewOptions,
        availableWidth: CGFloat,
    ) -> LayoutDocument {
        LayoutEngine.layout(
            score: score, options: options, availableWidth: availableWidth, cache: cache,
        )
    }

    /// Horizontal mode: engrave at the score's own uncompressed width so systems never wrap. The width walk is part of
    /// the same serialized step because it is an input to the layout it precedes.
    func layoutAtNaturalWidth(
        score: Score,
        options: ScoreViewOptions,
    ) -> LayoutDocument {
        let natural = LayoutEngine.naturalContentWidth(score: score, options: options)
        return LayoutEngine.layout(
            score: score, options: options, availableWidth: natural, cache: cache,
        )
    }
}

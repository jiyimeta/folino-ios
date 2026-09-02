// PARITY(macos): page-mode reader extras — the Mac deck draws every page with its committed ink and lets the scroll
//   view magnify them, and nothing else. Two gaps against the iOS `PagedScoreContainer`: no page-turn affordance at all
//   (its tap zones and swipe are touch idioms that should not be ported, but no key, menu item or button stands in for
//   them yet — see `PageTapOverlay`), and no live annotation canvas (Ⅴ). Zoom is not a gap: it lives on
//   `NSScrollView.magnification` here, which is why the pinch-commit has no counterpart.

#if os(macOS)
import Domain
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// Paper geometry for the Mac's page deck.
///
/// **The page is a fixed sheet, not the window.** iOS paginates to the viewport, because a phone or an iPad shows one
/// page at a time and the page may as well be the screen. The Mac shows a deck of sheets that the user magnifies, so
/// the sheet has to have a size of its own that does not move when the window is resized — otherwise every resize
/// re-paginates the score and the page the reader was looking at is a different page afterwards.
///
/// A4 at 72 dpi is that size: it is the paper the engraving would be printed on, and it makes the deck's proportions
/// the proportions of the printed score.
enum MacPageDeckMetrics {
    /// A4 in points (210 x 297 mm at 72 dpi).
    static let paperSize = CGSize(width: 595.28, height: 841.89)
    /// Half an inch of paper margin on every side, the printed-score convention.
    static let margin: CGFloat = 36
    /// Gap between two sheets in the deck.
    static let pageGap: CGFloat = 24
    /// Breathing room between the deck and the scroll view's edges.
    static let deckPadding: CGFloat = 24

    /// The printable area inside one sheet: what the score is engraved into and what pagination measures against.
    static var contentSize: CGSize {
        CGSize(width: paperSize.width - margin * 2, height: paperSize.height - margin * 2)
    }

    /// The drawn sheet size for a document of the given engraved width. Honoring the engraver's authored breaks can
    /// leave `doc.size.width` wider than the width it was engraved for; widening the sheet rather than clipping keeps
    /// every notehead on the paper.
    static func pageSize(forDocumentWidth width: CGFloat) -> CGSize {
        CGSize(width: max(paperSize.width, width + margin * 2), height: paperSize.height)
    }

    /// Origin of page `index` in the deck's own (unmagnified) coordinate space — the space a scroll-to-visible
    /// rectangle has to be expressed in.
    static func pageOrigin(index: Int, pageSize: CGSize) -> CGPoint {
        CGPoint(x: deckPadding + CGFloat(index) * (pageSize.width + pageGap), y: deckPadding)
    }

    /// Magnification that fits one whole sheet in the window, clamped to what the scroll view allows and never
    /// enlarging past 1.0 — a small score should open at actual size, not blown up to fill the window.
    static func fitMagnification(pageSize: CGSize, viewport: CGSize) -> CGFloat {
        let availableWidth = viewport.width - deckPadding * 2
        let availableHeight = viewport.height - deckPadding * 2
        guard pageSize.width > 0, pageSize.height > 0, availableWidth > 0, availableHeight > 0 else { return 1 }
        let fit = min(availableWidth / pageSize.width, availableHeight / pageSize.height, 1.0)
        return MacScoreMagnification.clamped(fit)
    }
}

/// One sheet's cursor. The observable a single page leaf reads, and the smallest thing a playback tick can invalidate.
@MainActor
@Observable
final class MacPageCursorSlot {
    /// The cursor when it is on THIS page, `nil` otherwise. Never the deck-wide cursor.
    var cursor: ScoreCursor?
}

/// The deck's playback cursor, held as one observable slot per sheet.
///
/// The deck lives inside one `NSHostingView` whose `rootView` is only reassigned when the engraving changes (see
/// `MagnifyingScoreScrollView.contentGeneration`). Passing the cursor down as a value would therefore either strand it
/// — the deck would keep the cursor it was built with — or force a full rootView rebuild on every playback tick.
/// Routing it through observation instead invalidates only what reads it.
///
/// **Per sheet, not one shared property, and that is the whole point.** Observation invalidates on the READ, so a
/// single `cursor` here would be read by every sheet's leaf and re-render all of them on every tick — and each leaf
/// drives `SystemLayerView.updateNSView` for every system on its page, which opens a `CATransaction` per system even
/// when the diff early-outs. iOS gets away with the shared read because its paged reader has one page on screen; this
/// deck has all of them. With a slot per sheet, a tick touches the sheet the cursor is on (and, when it crosses a page
/// boundary, the one it left) and nothing else.
///
/// This type is deliberately NOT `@Observable` itself — only the slots are. Anything that observed the container here
/// would be back to a deck-wide invalidation.
@MainActor
final class MacPageDeckCursorState {
    private var slots: [MacPageCursorSlot] = []
    /// Which sheet currently holds the cursor, so it can be cleared when the cursor moves off it.
    private var occupiedPage: Int?

    /// Re-sizes the slot array for a fresh engraving. Called from `rebuildLayout`, never from a view body — a body
    /// that allocated a slot would be mutating state while rendering.
    func resize(pageCount: Int) {
        slots = (0 ..< max(0, pageCount)).map { _ in MacPageCursorSlot() }
        occupiedPage = nil
    }

    /// The slot for a sheet. A pure read: `resize` has already allocated it.
    func slot(forPage index: Int) -> MacPageCursorSlot? {
        slots.indices.contains(index) ? slots[index] : nil
    }

    /// Place the cursor on `page`, clearing whichever sheet held it before. Passing `page: nil` clears it entirely
    /// (no cursor, or a cursor whose measure resolves to no engraved system).
    func place(cursor: ScoreCursor?, onPage page: Int?) {
        if let occupiedPage, occupiedPage != page {
            slot(forPage: occupiedPage)?.cursor = nil
        }
        occupiedPage = page
        guard let page, let slot = slot(forPage: page) else { return }
        slot.cursor = cursor
    }
}

/// The Mac's page-mode score viewport, and the Mac reader's default: the engraved score cut into sheets of paper and
/// laid out as one horizontal deck inside an `NSScrollView` that magnifies it.
///
/// **Horizontal by default** because that is what MuseScore does and what swift-sheet-music's own deck does — a
/// left-to-right run of pages reads as a score laid out on a desk, where a vertical run reads as a scrolling document
/// and is what Vertical mode already is.
///
/// **The zoom is the scroll view's, not the content's.** See `MagnifyingScoreScrollView`: AppKit re-rasterizes the
/// layer tree at the current magnification, so the engraving is redrawn sharp at 4x rather than a 1x raster being
/// stretched. Nothing here may apply a `scaleEffect` for zoom.
struct MacPagedScoreContainer: View {
    let score: Score
    let staffSize: CGFloat
    let honorLayoutBreaks: Bool
    let collapseMultiMeasureRests: Bool
    let showInvisibleElements: Bool
    let showAllMeasureNumbers: Bool
    /// The highlight cursor. Mirrored into `cursorState` and handed to the leaves from there; this view never reads it
    /// off the view model.
    let playbackCursor: ScoreCursor?
    /// Lookahead anchor used to bring the next page into view early during playback. `nil` when not playing, in which
    /// case page-follow falls back to `playbackCursor`.
    let pageAnchorCursor: ScoreCursor?
    /// User opt-out: when false, continuous playback no longer scrolls the deck.
    let autoFollowEnabled: Bool
    /// Transpose offset in semitones. Only used to invalidate the layout cache via `MacScoreLayoutKey` — the score
    /// passed in is already transposed.
    let transposeSemitones: Int
    /// Which edit `score` is while note editing, 0 otherwise. Keyed on INSTEAD of `editingHost.editGeneration` — see
    /// `ReaderEditingDisplay.version`.
    var editingScoreVersion = 0
    let viewModel: ReaderViewModel
    /// The note-editing seam. `nil` keeps this container byte-identical to the read-only reader (previews, tests).
    /// With a host, clicks route to `editingHost.onTap`, the rebuilt `LayoutDocument` is published to
    /// `editingHost.document` for hit-testing, and the surface tints the selection and draws the caret.
    var editingHost: ReaderEditingHost?

    /// Layout output — observable, not `@State`; see `ScoreLayoutState`.
    @State private var layoutState = ScoreLayoutState()
    /// Off-main engraver holding this surface's incremental `LayoutCache`; see `ScoreRelayoutEngine`.
    @State private var relayoutEngine = ScoreRelayoutEngine()
    @State private var cursorState = MacPageDeckCursorState()
    @State private var magnification: CGFloat = 1.0
    /// Fit-to-window is applied once, when the first engraving lands. A later window resize deliberately does not
    /// refit: a document viewer that re-zooms itself while the user drags the window edge is fighting them.
    @State private var hasSeededMagnification = false
    /// Bumped on every installed engraving; the only thing that makes the host rebuild the deck. See
    /// `MagnifyingScoreScrollView.contentGeneration`.
    @State private var layoutGeneration = 0
    @State private var scrollRequest: MacScoreScrollRequest?
    @State private var scrollToken = 0

    var body: some View {
        GeometryReader { proxy in
            deck(viewport: proxy.size)
        }
    }

    private func deck(viewport: CGSize) -> some View {
        let sheet = pageSize ?? MacPageDeckMetrics.paperSize
        return MagnifyingScoreScrollView(
            magnification: $magnification,
            contentGeneration: layoutGeneration,
            scrollRequest: scrollRequest,
        ) {
            MacPageDeck(
                viewModel: viewModel,
                cursorState: cursorState,
                document: layoutState.document,
                pages: layoutState.pages,
                score: score,
                scoreOptions: scoreOptions,
                pageSize: sheet,
                editingHost: editingHost,
            )
        }
        // The desk the sheets lie on. `MagnifyingScoreScrollView` sets `drawsBackground = false`, so this is the one
        // ground behind the deck — see `MacReaderGround` for why it is grey and why the root paints none.
        .background(MacReaderGround.desk)
        .task(id: layoutKey) {
            await rebuildLayout()
        }
        .onChange(of: playbackCursor, initial: true) { _, _ in
            placeCursor()
        }
        // The stored ink lands from `loadAnnotations()` a beat after the score does, which can be after the deck's
        // first engraving is already installed. `MacPageDeck` reads `annotationDrawings` in its body, so observation
        // ought to redraw the sheets on its own — but the deck lives in a hand-built `NSHostingView` whose root view
        // this container replaces only on a generation bump, and ink that fails to appear is indistinguishable from
        // ink that was lost. Bumping the generation makes it certain. Once per open, not per tick.
        .onChange(of: viewModel.annotationDrawings) { _, _ in
            layoutGeneration += 1
        }
        .onChange(of: MacDeckFitKey(viewport: viewport, pageSize: pageSize), initial: true) { _, key in
            seedMagnification(key)
        }
        .onChange(of: [playbackCursor, pageAnchorCursor]) { old, new in
            guard readerShouldFollowPlayback(
                autoFollowEnabled: autoFollowEnabled,
                isPlaybackDriven: pageAnchorCursor != nil,
                cursorMoved: old[0] != new[0],
                followSuspended: viewModel.playbackSession.isPlaybackFollowSuspended,
            ) else { return }
            scrollToPage(containing: pageAnchorCursor ?? playbackCursor)
        }
    }

    /// The drawn sheet size, or `nil` until the first engraving lands.
    private var pageSize: CGSize? {
        guard let doc = layoutState.document, !layoutState.pages.isEmpty else { return nil }
        return MacPageDeckMetrics.pageSize(forDocumentWidth: doc.size.width)
    }

    private func seedMagnification(_ key: MacDeckFitKey) {
        guard !hasSeededMagnification, let sheet = key.pageSize,
              key.viewport.width > 0, key.viewport.height > 0
        else { return }
        hasSeededMagnification = true
        magnification = MacPageDeckMetrics.fitMagnification(pageSize: sheet, viewport: key.viewport)
    }

    private var scoreOptions: ScoreViewOptions {
        MacScoreEngraving.options(
            staffSize: staffSize,
            honorLayoutBreaks: honorLayoutBreaks,
            collapseMultiMeasureRests: collapseMultiMeasureRests,
            showInvisibleElements: showInvisibleElements,
            showAllMeasureNumbers: showAllMeasureNumbers,
        )
    }

    /// No `width`: the sheet is a fixed size, so a resize changes the magnification the user sees and nothing about
    /// the pagination.
    private var layoutKey: MacScoreLayoutKey {
        MacScoreLayoutKey(
            score: score,
            size: staffSize,
            honorLayoutBreaks: honorLayoutBreaks,
            collapseMultiMeasureRests: collapseMultiMeasureRests,
            showInvisibleElements: showInvisibleElements,
            showAllMeasureNumbers: showAllMeasureNumbers,
            transposeSemitones: transposeSemitones,
            editingScoreVersion: editingScoreVersion,
        )
    }

    /// Engrave into the sheet's printable width, then cut the systems into sheets by its printable height. Neither
    /// depends on the window, so resizing never re-paginates.
    private func rebuildLayout() async {
        let content = MacPageDeckMetrics.contentSize
        let policy: LayoutBreakPolicy = honorLayoutBreaks ? .honor : .ignoreAll
        let newDoc = await relayoutEngine.layout(
            score: score, options: scoreOptions, availableWidth: content.width,
        )
        guard !Task.isCancelled else { return }
        let newPages = LayoutPaginator.paginate(
            systems: newDoc.systems, pageHeight: content.height, policy: policy,
        )
        layoutState.document = newDoc
        layoutState.pages = newPages
        editingHost?.document = newDoc
        // Slots first, then the generation bump: the deck's body reads the slots, so they have to exist for the page
        // count it is about to draw. Re-placing the cursor afterwards is what keeps it visible across a re-engrave —
        // `resize` drops the old slots, and nothing else would put it back.
        cursorState.resize(pageCount: newPages.count)
        layoutGeneration += 1
        placeCursor()
    }

    /// Hand the cursor to the slot of the sheet that owns it, and to no other. See `MacPageDeckCursorState`.
    private func placeCursor() {
        cursorState.place(cursor: playbackCursor, onPage: playbackCursor.flatMap(pageIndex(containing:)))
    }

    /// The sheet a cursor's measure is engraved on, or `nil` when the layout has no system for it.
    private func pageIndex(containing cursor: ScoreCursor) -> Int? {
        guard let doc = layoutState.document else { return nil }
        let measure = measureIndex(of: cursor)
        guard let system = doc.systems.firstIndex(where: { layoutSystem in
            layoutSystem.measures.contains { $0.measureIndex == measure }
        }) else { return nil }
        return layoutState.pages.firstIndex { $0.contains(system) }
    }

    /// Bring the sheet holding `cursor` into view. The Mac's answer to the iOS container's page turn: there is one
    /// deck rather than one visible page, so "turning to a page" is scrolling it into the window.
    private func scrollToPage(containing cursor: ScoreCursor?) {
        guard let cursor, let sheet = pageSize, let target = pageIndex(containing: cursor) else { return }
        scrollToken += 1
        scrollRequest = MacScoreScrollRequest(
            token: scrollToken,
            target: .visible(CGRect(
                origin: MacPageDeckMetrics.pageOrigin(index: target, pageSize: sheet),
                size: sheet,
            )),
        )
    }
}

/// Identity for the fit-to-window seed: it needs both the window and the sheet, and the sheet is `nil` until the
/// first engraving lands, which is exactly the moment the seed becomes possible.
private struct MacDeckFitKey: Equatable {
    let viewport: CGSize
    let pageSize: CGSize?
}

#endif

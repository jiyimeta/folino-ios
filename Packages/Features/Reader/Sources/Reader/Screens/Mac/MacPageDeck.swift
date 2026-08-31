#if os(macOS)
import Domain
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// The deck itself: every sheet, side by side. This is the `NSHostingView`'s root view, so its body runs only when the
/// engraving changes — which is why the per-sheet sub-documents are built here rather than inside the leaves that
/// redraw on a playback tick.
struct MacPageDeck: View {
    let viewModel: ReaderViewModel
    let cursorState: MacPageDeckCursorState
    let document: LayoutDocument?
    let pages: [Range<Int>]
    let score: Score
    let scoreOptions: ScoreViewOptions
    let pageSize: CGSize

    var body: some View {
        if let doc = document, !pages.isEmpty {
            HStack(alignment: .top, spacing: MacPageDeckMetrics.pageGap) {
                ForEach(pages.indices, id: \.self) { index in
                    MacScorePage(
                        viewModel: viewModel,
                        // The sheet's OWN cursor slot, resolved here where nothing reads its value — the deck's body
                        // must not depend on the cursor, or a tick would rebuild every sheet. See
                        // `MacPageDeckCursorState`.
                        cursorSlot: cursorState.slot(forPage: index),
                        pageDocument: pageDocument(forPage: index, in: doc),
                        pageStartY: PagedPageGeometry.pageStartY(forPage: index, pages: pages, doc: doc),
                        pageNumber: index + 1,
                        score: score,
                        scoreOptions: scoreOptions,
                        pageSize: pageSize,
                    )
                }
            }
            .padding(MacPageDeckMetrics.deckPadding)
        } else {
            ProgressView()
                .controlSize(.large)
                .padding(80)
        }
    }

    /// A sub-document holding only this page's systems. Same trick the iOS `PagedZoomedSurface` uses and for the same
    /// reason — a `ScoreView` over the full document would build a `SystemLayerView` for every system in the score, on
    /// every sheet, multiplying the deck's layout cost by its page count. `size` stays the full document's so the
    /// systems keep their document-space `origin.y` and the `-pageStartY` offset still lands them correctly.
    private func pageDocument(forPage index: Int, in doc: LayoutDocument) -> LayoutDocument {
        LayoutDocument(
            size: doc.size,
            systems: Array(doc.systems[pages[index]]),
            metrics: doc.metrics,
            titleFrame: index == 0 ? doc.titleFrame : nil,
        )
    }
}

/// One sheet of paper: the white card, its edge, and the page number beneath it. Deliberately does NOT read the
/// cursor — the leaf inside it does, so a playback tick redraws the engraving without re-laying-out the card.
struct MacScorePage: View {
    let viewModel: ReaderViewModel
    let cursorSlot: MacPageCursorSlot?
    let pageDocument: LayoutDocument
    let pageStartY: CGFloat
    let pageNumber: Int
    let score: Score
    let scoreOptions: ScoreViewOptions
    let pageSize: CGSize

    var body: some View {
        VStack(spacing: 6) {
            card
            Text(pageNumber, format: .number)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var card: some View {
        let content = CGSize(
            width: pageSize.width - MacPageDeckMetrics.margin * 2,
            height: pageSize.height - MacPageDeckMetrics.margin * 2,
        )
        // The paper. This is the sheet, not the reading surface's ground — the ground is painted once at
        // `MacReaderRootScreen` and this container adds none of its own. The iOS paged surface paints the same white
        // for the same reason: the run-out beneath the last system on a page is still page.
        return MacPageScoreLayer(
            viewModel: viewModel,
            cursorSlot: cursorSlot,
            pageDocument: pageDocument,
            pageStartY: pageStartY,
            score: score,
            scoreOptions: scoreOptions,
            contentSize: content,
        )
        .frame(width: content.width, height: content.height, alignment: .topLeading)
        .clipped()
        .padding(MacPageDeckMetrics.margin)
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .background(Color.white)
        .overlay(Rectangle().stroke(Color.gray.opacity(0.35), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }
}

/// The engraving on one sheet. Everything that changes more often than the layout does is confined here: the playback
/// cursor and the AB-loop markers.
struct MacPageScoreLayer: View {
    let viewModel: ReaderViewModel
    let cursorSlot: MacPageCursorSlot?
    let pageDocument: LayoutDocument
    let pageStartY: CGFloat
    let score: Score
    let scoreOptions: ScoreViewOptions
    let contentSize: CGSize

    /// The name the click-to-seek gesture reads its location in: the full document's own coordinate space, which is
    /// what `nearestCursor` expects. The sheet is a window onto it, opened by the `-pageStartY` offset below.
    private static let coordinateSpace = "macScorePage"

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScoreView(
                document: pageDocument, score: score, options: scoreOptions,
                // The ONLY cursor read in the deck, and it is this sheet's own slot — `nil` on every sheet the cursor
                // is not on. See `MacPageDeckCursorState` for why it is not one shared property.
                playbackCursor: cursorSlot?.cursor, playbackCursorColor: .accentColor.opacity(0.6),
            )
            .gesture(tapSeekGesture())

            if viewModel.repeatModel.mode == .abLoop {
                LoopRegionOverlay(document: pageDocument, range: viewModel.repeatModel.abRange)
                LoopBoundaryMarkers(
                    document: pageDocument,
                    start: viewModel.repeatModel.pendingRepeatA,
                    end: viewModel.repeatModel.pendingRepeatB,
                )
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .frame(width: contentSize.width, height: pageDocument.size.height, alignment: .topLeading)
        .offset(y: -pageStartY)
    }

    /// Click-to-seek. With no playback controller wired on the Mac yet this still moves the displayed cursor —
    /// `ReaderPlaybackSession.setManualCursor` guards every `controller` call.
    private func tapSeekGesture() -> some Gesture {
        SpatialTapGesture(coordinateSpace: .named(Self.coordinateSpace))
            .onEnded { value in
                // The named space spans the whole document, and `.clipped()` clips drawing but not hit testing — a
                // click on the blank paper below this page's last system would otherwise resolve to a system on the
                // next sheet and move the cursor somewhere the user did not click. Same guard the iOS paged surface
                // states at length.
                let pageEndY = pageStartY + contentSize.height
                guard value.location.y >= pageStartY, value.location.y <= pageEndY else { return }
                guard let cursor = nearestCursor(at: value.location, in: pageDocument) else { return }
                viewModel.playbackSession.setManualCursor(cursor)
            }
    }
}
#endif

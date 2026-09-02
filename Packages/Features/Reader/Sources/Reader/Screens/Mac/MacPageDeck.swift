#if os(macOS)
import Domain
import PencilKit
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// The deck itself: every sheet, side by side. This is the `NSHostingView`'s root view, so its body runs only when the
/// engraving changes — or when the score's committed ink is replaced, which happens once per open — which is why the
/// per-sheet sub-documents and the projected ink are built here rather than inside the leaves that redraw on a
/// playback tick.
struct MacPageDeck: View {
    let viewModel: ReaderViewModel
    let cursorState: MacPageDeckCursorState
    let document: LayoutDocument?
    let pages: [Range<Int>]
    let score: Score
    let scoreOptions: ScoreViewOptions
    let pageSize: CGSize
    /// The host scroll view's live magnification, forwarded to every sheet so a click can be divided back into
    /// document space. Held by reference, not passed as a value, for the reason the cursor is: the deck is this
    /// `NSHostingView`'s root view and is rebuilt only on a generation bump, so a zoom captured as a value here would
    /// be the zoom the deck was built with. Read only inside a click handler, never in a body.
    let viewportState: MacScoreViewportState
    /// The note-editing seam, forwarded to every sheet. See `MacPagedScoreContainer.editingHost`.
    let editingHost: ReaderEditingHost?

    var body: some View {
        if let doc = document, !pages.isEmpty {
            // Projected ONCE for the whole deck, not per sheet: the projection decodes and places every stored
            // stroke, and doing that 27 times for a 27-page score would pay for the whole layer per page.
            // `MacScoreInkOverlay` picks each sheet's share out of it by geometry.
            let ink = MacScoreEngraving.projectedInk(viewModel, into: doc)
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
                        ink: ink,
                        viewportState: viewportState,
                        editingHost: editingHost,
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
    /// The whole score's committed ink, already projected into document space by the deck. This sheet draws its own
    /// share of it — see `MacScoreInkOverlay`.
    let ink: PKDrawing
    /// The host scroll view's live magnification. See `MacPageDeck.viewportState`.
    let viewportState: MacScoreViewportState
    /// The note-editing seam. See `MacPagedScoreContainer.editingHost`.
    let editingHost: ReaderEditingHost?

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
        // The paper. This is the sheet, not the desk — the desk is `MacReaderGround.desk`, painted once behind the
        // whole deck by `MacPagedScoreContainer`. Both come from `MacReaderGround` by name rather than as a literal
        // `Color.white`, so a retune of "what paper is" reaches the sheet and the vertical scroll together. The iOS
        // paged surface paints the same white for the same reason: the run-out beneath the last system is still page.
        return MacPageScoreLayer(
            viewModel: viewModel,
            cursorSlot: cursorSlot,
            pageDocument: pageDocument,
            pageStartY: pageStartY,
            score: score,
            scoreOptions: scoreOptions,
            contentSize: content,
            ink: ink,
            viewportState: viewportState,
            editingHost: editingHost,
        )
        .frame(width: content.width, height: content.height, alignment: .topLeading)
        .clipped()
        .padding(MacPageDeckMetrics.margin)
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .background(MacReaderGround.paper)
        .background(editingDeselectCatcher(host: editingHost))
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
    /// The whole score's committed ink in document space; this layer draws the band the sheet shows.
    let ink: PKDrawing
    /// The host scroll view's live magnification, read only inside the click handler. See `MacPageDeck.viewportState`.
    let viewportState: MacScoreViewportState
    /// The note-editing seam. Read INSIDE `body` (never handed down as a value), because this layer is inside the
    /// deck's `NSHostingView` root and is rebuilt only when the container bumps `layoutGeneration` — a body read of
    /// this `@Observable` object is what registers the dependency that redraws the sheet when the selection moves.
    let editingHost: ReaderEditingHost?

    /// The name the click-to-seek gesture reads its location in: the full document's own coordinate space, which is
    /// what `nearestCursor` expects. The sheet is a window onto it, opened by the `-pageStartY` offset below.
    private static let coordinateSpace = "macScorePage"

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScoreView(
                document: pageDocument, score: score, options: scoreOptions,
                // `displaySelection`, not `selection`: the editor addresses the unfiltered score, this document is
                // laid out from the staff-filtered one. See `ReaderEditingHost.displayItem(for:)`.
                selection: editingHost?.isEditing == true ? (editingHost?.displaySelection ?? .none) : .none,
                voiceColors: ReaderEditingPresentation.voiceColors,
                // The ONLY cursor read in the deck, and it is this sheet's own slot — `nil` on every sheet the cursor
                // is not on. See `MacPageDeckCursorState` for why it is not one shared property.
                playbackCursor: cursorSlot?.cursor, playbackCursorColor: .accentColor.opacity(0.6),
            )
            .gesture(tapSeekGesture())

            // Committed ink over the notation. The band is what this sheet shows of the document, so a stroke drawn
            // across a page boundary appears on both sheets and is clipped by each — the card's `.clipped()` does
            // that, the same way it clips the engraving.
            MacScoreInkOverlay(
                drawing: ink,
                surfaceSize: CGSize(width: contentSize.width, height: pageDocument.size.height),
                band: CGRect(x: 0, y: pageStartY, width: contentSize.width, height: contentSize.height),
            )

            if viewModel.repeatModel.mode == .abLoop {
                LoopRegionOverlay(document: pageDocument, range: viewModel.repeatModel.abRange)
                LoopBoundaryMarkers(
                    document: pageDocument,
                    start: viewModel.repeatModel.pendingRepeatA,
                    end: viewModel.repeatModel.pendingRepeatB,
                )
            }

            // Last in the stack — over `ScoreView`, which paints itself opaque white. The caret blends
            // (`EditingSelectionOverlay`), it does not sit on top by z-order.
            if let host = editingHost, host.isEditing {
                EditingSelectionOverlay(host: host, score: score, document: pageDocument)
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .frame(width: contentSize.width, height: pageDocument.size.height, alignment: .topLeading)
        .offset(y: -pageStartY)
    }

    /// Click-to-seek, or a selection while editing. With no playback controller wired on the Mac yet this still
    /// moves the displayed cursor — `ReaderPlaybackSession.setManualCursor` guards every `controller` call.
    ///
    /// `pageDocument` keeps the full document's `size` and the systems' document-space origins (see
    /// `MacPageDeck.pageDocument(forPage:in:)`), so the point handed to `editingHost.onTap` is already in the space
    /// `editingHitTest` expects — once the magnification has been divided out.
    ///
    /// **That division is not optional and it is not a rounding correction.** SwiftUI reports a hosted gesture's
    /// location multiplied by the enclosing `NSScrollView`'s magnification, so at 2x every click resolved to a point
    /// twice as far down and across the document as the one the reader aimed at — the deeper into the page, the
    /// further off. See `MacScoreMagnification.documentPoint(fromHosted:magnification:)` for the measurement. The
    /// page-band guard below has to use the converted point too, or a click on the second sheet at 2x would fail the
    /// guard on the first sheet and pass it on a sheet the reader never touched.
    private func tapSeekGesture() -> some Gesture {
        SpatialTapGesture(coordinateSpace: .named(Self.coordinateSpace))
            .onEnded { value in
                let point = MacScoreMagnification.documentPoint(
                    fromHosted: value.location, magnification: viewportState.magnification,
                )
                // The named space spans the whole document, and `.clipped()` clips drawing but not hit testing — a
                // click on the blank paper below this page's last system would otherwise resolve to a system on the
                // next sheet and move the cursor somewhere the user did not click. Same guard the iOS paged surface
                // states at length.
                let pageEndY = pageStartY + contentSize.height
                guard point.y >= pageStartY, point.y <= pageEndY else { return }
                if let host = editingHost, host.wantsScoreTaps {
                    host.onTap(point)
                    return
                }
                guard let cursor = nearestCursor(at: point, in: pageDocument) else { return }
                viewModel.playbackSession.setManualCursor(cursor)
                editingHost?.rememberTappedItem(cursor)
            }
    }
}
#endif

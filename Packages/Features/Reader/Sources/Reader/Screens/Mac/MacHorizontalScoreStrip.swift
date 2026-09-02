// PARITY(macos): horizontal mode's live annotation canvas — the strip draws the staves, the committed ink, the
//   selection and the caret; the live canvas the iOS `HorizontalZoomedSurface` mounts here is Ⅴ's.

#if os(macOS)
import Domain
import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// The engraved strip itself: this is the `NSHostingView`'s root view, so its body runs only when the container bumps
/// the generation. Everything that moves more often reaches it through `MacHorizontalScoreState`, and each such read
/// is confined to the leaf that needs it.
struct MacHorizontalScoreStrip: View {
    let viewModel: ReaderViewModel
    let state: MacHorizontalScoreState
    /// Handed down as a value, not read off `state`: the strip is rebuilt when the engraving changes and at no other
    /// time, so observing it here would buy nothing and would tie the strip to a property the container also reads.
    let document: LayoutDocument?
    let score: Score
    let scoreOptions: ScoreViewOptions
    /// Read ONLY inside the click handler, never in `body` — see `tapSeekGesture`. A gesture action runs outside
    /// SwiftUI's observation tracking, so touching it there registers no dependency and no scroll frame reaches the
    /// engraving through it.
    let viewportState: MacScoreViewportState
    /// The note-editing seam. Read INSIDE `body` (never handed down as a value), because the strip is the
    /// `NSHostingView`'s root and is rebuilt only when the container bumps `layoutGeneration` — a body read of this
    /// `@Observable` object is what registers the dependency that redraws the strip when the selection moves.
    let editingHost: ReaderEditingHost?

    /// The name the click-to-seek gesture reads its location in: the un-padded `ScoreView` frame, which is the
    /// `LayoutDocument`'s own coordinate space.
    private static let coordinateSpace = "macHorizontalStrip"

    var body: some View {
        if let document {
            ZStack(alignment: .topLeading) {
                ScoreView(
                    document: document, score: score, options: scoreOptions,
                    // `displaySelection`, not `selection`: the editor addresses the unfiltered score, this document is
                    // laid out from the staff-filtered one. See `ReaderEditingHost.displayItem(for:)`.
                    selection: editingHost?.isEditing == true ? (editingHost?.displaySelection ?? .none) : .none,
                    voiceColors: ReaderEditingPresentation.voiceColors,
                    // The only cursor read in the hosted tree, and the reason `state.cursor` exists.
                    playbackCursor: state.cursor, playbackCursorColor: .accentColor.opacity(0.6),
                )
                .gesture(tapSeekGesture(document: document))

                // Committed ink over the notation, banded to the column the window shows. Its own view so that a
                // scroll past a column boundary invalidates this leaf and not the engraving beside it.
                MacHorizontalInkLayer(state: state, surfaceSize: document.size)

                if viewModel.repeatModel.mode == .abLoop {
                    LoopRegionOverlay(document: document, range: viewModel.repeatModel.abRange)
                    LoopBoundaryMarkers(
                        document: document,
                        start: viewModel.repeatModel.pendingRepeatA,
                        end: viewModel.repeatModel.pendingRepeatB,
                    )
                }

                // Last in the stack — over `ScoreView`, which paints itself opaque white. The caret blends
                // (`EditingSelectionOverlay`), it does not sit on top by z-order.
                if let host = editingHost, host.isEditing {
                    EditingSelectionOverlay(host: host, score: score, document: document)
                }
            }
            .coordinateSpace(name: Self.coordinateSpace)
            .frame(width: document.size.width, height: document.size.height, alignment: .topLeading)
            .padding(MacHorizontalMetrics.contentInset)
            .background(editingDeselectCatcher(host: editingHost))
            // The strip's paper runs edge to edge inside the scroll view, so AppKit's overlay scroller rides on white
            // and would vanish in dark appearance. Pinned on the scroll view itself, exactly as the vertical
            // container does it and for the same reason — see `MacScrollViewAppearance`.
            .background(
                MacScrollViewAppearance(appearance: .aqua)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false),
            )
        } else {
            ProgressView()
                .controlSize(.large)
                .padding(80)
        }
    }

    /// Click-to-seek, in the document's own space.
    ///
    /// **Clicks that land under the sticky pane are rejected, and that is a correctness rule rather than a polish
    /// one.** The pane is `allowsHitTesting(false)` — deliberately, so it can never swallow a scroll — which means a
    /// click on it falls straight through to the music it is covering, and that music is by definition scrolled
    /// past: clicking the frozen part labels would seek to a measure the reader cannot see. Guarding here rather
    /// than trying to swallow the click on the pane keeps the fix independent of how AppKit and SwiftUI order hit
    /// testing between a representable and the SwiftUI siblings drawn over it.
    ///
    /// The covered span is `[scoreScrollX, stickyTrailingX]` — the same trailing edge that drives which measure the
    /// pane displays, so the guard and the pane can never disagree about where the pane ends. This mirrors
    /// `MacPageScoreLayer`'s guard against clicks on the blank paper below a sheet's last system: a named coordinate
    /// space is wider than what the reader can act on, and the gesture is where that gets reconciled.
    ///
    /// While editing, a click that clears the pane is a selection, not a seek.
    private func tapSeekGesture(document: LayoutDocument) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .named(Self.coordinateSpace))
            .onEnded { value in
                guard !isUnderStickyPane(documentX: value.location.x, document: document) else { return }
                if let host = editingHost, host.wantsScoreTaps {
                    host.onTap(value.location)
                    return
                }
                guard let cursor = nearestCursor(at: value.location, in: document) else { return }
                viewModel.playbackSession.setManualCursor(cursor)
                editingHost?.rememberTappedItem(cursor)
            }
    }

    /// Whether `documentX` is hidden behind the sticky pane at the current scroll offset. False whenever the pane is
    /// not on screen, which is every scroll position before the score's own bracket reaches the leading edge.
    private func isUnderStickyPane(documentX: CGFloat, document: LayoutDocument) -> Bool {
        guard !state.measureContexts.isEmpty else { return false }
        let geometry = MacStickyPaneGeometry(document: document, scrollX: viewportState.scroll.x)
        guard geometry.isVisible else { return false }
        return documentX < document.stickyTrailingX(
            scoreScrollX: geometry.scoreScrollX,
            measureContexts: state.measureContexts,
        )
    }
}

/// The ink layer, split out so that reading the band and the drawing invalidates this view alone.
///
/// Both come off `MacHorizontalScoreState`, which means a scroll that crosses a column boundary re-renders this and
/// nothing else in the strip — not the engraving, and not the loop overlays.
private struct MacHorizontalInkLayer: View {
    let state: MacHorizontalScoreState
    let surfaceSize: CGSize

    var body: some View {
        MacScoreInkOverlay(drawing: state.ink, surfaceSize: surfaceSize, band: state.inkBand)
    }
}
#endif

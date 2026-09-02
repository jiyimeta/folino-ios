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
    /// The note-editing seam. Read INSIDE `body` (never handed down as a value), because the strip is the
    /// `NSHostingView`'s root and is rebuilt only when the container bumps `layoutGeneration` — a body read of this
    /// `@Observable` object is what registers the dependency that redraws the strip when the selection moves.
    let editingHost: ReaderEditingHost?

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
            .frame(width: document.size.width, height: document.size.height, alignment: .topLeading)
            .padding(MacHorizontalMetrics.contentInset)
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

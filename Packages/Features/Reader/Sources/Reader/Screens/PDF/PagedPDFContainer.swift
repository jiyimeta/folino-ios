import PDFKit
import SwiftUI

/// Page-mode PDF viewing: one physical PDF page per reader page, with the same tap-zone page turn, zoom reset, and turn
/// animation as the score paged reader. Page boundaries come straight from the PDF page count instead of system
/// pagination.
///
/// Unlike `PagedScoreContainer`, page mode shows a single fixed-layout page at a time, so it does not ride
/// `ScoreScrollHost` (there is no continuous content to scroll). Pinch is a local `MagnifyGesture` feeding the same
/// committed-zoom model the score containers use; a page turn resets that zoom back to `1`.
struct PagedPDFContainer: View {
    let document: PDFDocument
    @Bindable var viewModel: ReaderViewModel

    @State private var provider: PDFPageProvider?
    @State private var pageState = PageState()
    @State private var pinch = PinchState()
    @State private var committedZoom: CGFloat = 1

    private static let pageTransition: Animation = .easeOut(duration: 0.18)

    var body: some View {
        GeometryReader { geo in
            let provider = ensureProvider()
            ZStack {
                currentPage(provider: provider, viewport: geo.size)
                    .scaleEffect(pinch.magnification * committedZoom, anchor: pinch.anchor)
                    .gesture(magnifyGesture)
                TapOverlay(
                    viewport: geo.size,
                    onFirstPage: { goTo(0) },
                    onPrevPage: { turn(by: -1, pageCount: provider.pageCount) },
                    onLastPage: { goTo(provider.pageCount - 1) },
                    onNextPage: { turn(by: 1, pageCount: provider.pageCount) },
                    currentPageNumber: clampedIndex(provider.pageCount) + 1,
                    totalPages: max(provider.pageCount, 1),
                )
            }
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinch.magnification == 1, value.magnification != 1 {
                    pinch.cancelResetAnimation()
                    pinch.anchor = value.startAnchor
                }
                pinch.magnification = value.magnification
            }
            .onEnded { value in
                committedZoom = clampZoom(committedZoom * value.magnification)
                pinch.magnification = 1
            }
    }

    private func currentPage(provider: PDFPageProvider, viewport: CGSize) -> some View {
        let index = clampedIndex(provider.pageCount)
        let size = provider.pageSize(index)
        // Fit the page within the viewport (contain). Committed zoom is applied via `scaleEffect` so a re-rasterize at
        // the new scale keeps the bitmap crisp on commit.
        let fit = fitScale(page: size, viewport: viewport)
        let width = size.width * fit
        let height = size.height * fit
        return PDFPagePageImage(
            provider: provider,
            index: index,
            width: width,
            height: height,
            zoom: committedZoom,
        )
        .frame(width: width, height: height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fitScale(page: CGSize, viewport: CGSize) -> CGFloat {
        guard page.width > 0, page.height > 0 else { return 1 }
        return min(viewport.width / page.width, viewport.height / page.height)
    }

    private func clampedIndex(_ pageCount: Int) -> Int {
        min(max(pageState.pageIndex, 0), max(pageCount - 1, 0))
    }

    private func turn(by delta: Int, pageCount: Int) {
        goTo(min(max(pageState.pageIndex + delta, 0), max(pageCount - 1, 0)))
    }

    private func goTo(_ index: Int) {
        committedZoom = 1
        pinch.magnification = 1
        pinch.anchor = .center
        withAnimation(Self.pageTransition) { pageState.pageIndex = index }
    }

    private func ensureProvider() -> PDFPageProvider {
        if let provider { return provider }
        let new = PDFPageProvider(document: document)
        DispatchQueue.main.async { provider = new }
        return new
    }

    private func clampZoom(_ z: CGFloat) -> CGFloat {
        min(max(z, 1), 6)
    }
}

/// One PDF page rendered to fit `width` × `height` points. Re-rasterizes via the provider whenever the fitted width
/// (× display scale × committed zoom) changes, so content stays sharp at the committed zoom level.
private struct PDFPagePageImage: View {
    let provider: PDFPageProvider
    let index: Int
    let width: CGFloat
    let height: CGFloat
    let zoom: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let size = provider.pageSize(index)
        let targetScale = max(0.1, (width / max(size.width, 1)) * displayScale * zoom)
        return Group {
            if let cg = provider.image(pageIndex: index, targetScale: targetScale) {
                Image(decorative: cg, scale: displayScale).resizable()
            } else {
                Color(.secondarySystemBackground)
            }
        }
        .frame(width: width, height: height)
    }
}

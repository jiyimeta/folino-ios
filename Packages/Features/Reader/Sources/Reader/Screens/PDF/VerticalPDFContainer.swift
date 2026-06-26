import PDFKit
import SwiftUI

/// Vertical-continuous PDF viewing. Pages are stacked at viewport width and scrolled vertically, riding the shared
/// `ScoreScrollHost` scroll/pinch infrastructure so zoom and gestures match the score reader. Distinct from the score
/// vertical *reflow* (PDFs are fixed-layout): here "vertical" just means a continuous scroll of fixed pages.
struct VerticalPDFContainer: View {
    let document: PDFDocument
    @Bindable var viewModel: ReaderViewModel

    @State private var provider: PDFPageProvider?
    @State private var contentOffset: CGPoint = .zero
    @State private var contentInsetTop: CGFloat = 0
    @State private var pendingScroll: ScoreScrollCommand?
    @State private var pinch = PinchState()
    @State private var committedZoom: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let provider = ensureProvider()
            let baseWidth = geo.size.width
            ScoreScrollHost(
                contentOffset: $contentOffset,
                contentInsetTop: $contentInsetTop,
                pendingScroll: $pendingScroll,
                alwaysBounceVertical: true,
                alwaysBounceHorizontal: false,
                centerVertically: false,
                centerHorizontally: true,
                expectedContentSize: { expectedSize(provider: provider, baseWidth: baseWidth) },
                onPinchBegan: { anchor, _ in
                    pinch.cancelResetAnimation()
                    pinch.anchor = anchor
                    pinch.magnification = 1
                },
                onPinchChanged: { scale, _ in pinch.magnification = scale },
                onPinchEnded: { scale, _, _ in
                    committedZoom = clampZoom(committedZoom * scale)
                    pinch.magnification = 1
                },
                annotationOverlay: nil,
            ) {
                pageStack(provider: provider, baseWidth: baseWidth)
                    .scaleEffect(pinch.magnification, anchor: pinch.anchor)
            }
        }
    }

    private func pageStack(provider: PDFPageProvider, baseWidth: CGFloat) -> some View {
        let width = baseWidth * committedZoom
        return VStack(spacing: 8) {
            ForEach(0 ..< provider.pageCount, id: \.self) { index in
                PDFPageImage(provider: provider, index: index, width: width)
            }
        }
    }

    private func expectedSize(provider: PDFPageProvider, baseWidth: CGFloat) -> CGSize {
        let width = baseWidth * committedZoom
        var height: CGFloat = 0
        for i in 0 ..< provider.pageCount {
            let size = provider.pageSize(i)
            height += size.height == 0 ? 0 : width * (size.height / size.width)
            height += 8
        }
        return CGSize(width: width, height: height)
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

/// One page rendered at `width` points. Re-rasterizes via the provider whenever the on-screen width (× display scale)
/// changes, so content is sharp at the committed zoom level.
private struct PDFPageImage: View {
    let provider: PDFPageProvider
    let index: Int
    let width: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let size = provider.pageSize(index)
        let height = size.width == 0 ? width : width * (size.height / size.width)
        let targetScale = max(0.1, (width / max(size.width, 1)) * displayScale)
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

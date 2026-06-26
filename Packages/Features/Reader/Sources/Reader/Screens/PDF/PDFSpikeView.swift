import PDFKit
import SwiftUI

/// Spike: a single PDF page in a Canvas under a live `.scaleEffect`, to confirm on-device that vector drawing stays
/// sharp and pinches smoothly before the reader refactor. Not shipped — used only for the Phase 0 device check.
struct PDFSpikeView: View {
    let document: PDFDocument
    @State private var zoom: CGFloat = 1
    @GestureState private var live: CGFloat = 1

    var body: some View {
        Group {
            if let page = document.page(at: 0) {
                PDFPageCanvas(page: page)
                    .scaleEffect(zoom * live, anchor: .center)
                    .gesture(
                        MagnifyGesture()
                            .updating($live) { value, state, _ in state = value.magnification }
                            .onEnded { value in zoom = max(1, min(6, zoom * value.magnification)) },
                    )
            } else {
                Text(verbatim: "no page")
            }
        }
    }
}
